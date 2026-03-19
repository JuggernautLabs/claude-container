#!/usr/bin/env bash
# Push preview — shows what push --merge would do (read-only)

# Preview what push --merge would do (read-only, mirrors session_merge_into Phases 1-3)
# Shows which repos need merging, which are up to date, which have issues
_push_preview() {
    local session_name="$1"
    local target_branch="$2"
    local repo_filter="${3:-}"
    local volume="claude-session-${session_name}"

    local config_content
    config_content=$(read_session_config "$volume")
    if [[ -z "$config_content" ]]; then
        error "No .claude-projects.yml in session"
        return 1
    fi

    local projects
    projects=$(parse_session_projects "$config_content")
    if [[ -n "$repo_filter" ]]; then
        projects=$(augment_projects_from_volume "$volume" "$projects" "$repo_filter")
    fi

    # Header
    _rule "push: ${target_branch} → ${session_name}"
    echo ""

    # Show discovered (extract: false) repos
    local _disc_full
    _disc_full=$(parse_session_projects_full "$config_content")
    if [[ -n "$_disc_full" ]]; then
        local -a _disc_repos=()
        while IFS='|' read -r _dn _dp _de; do
            [[ -z "$_dn" ]] && continue
            [[ "$_de" == "false" ]] || continue
            _disc_repos+=("$_dn")
        done <<< "$_disc_full"
        if [[ ${#_disc_repos[@]} -gt 0 ]]; then
            for _dr in "${_disc_repos[@]}"; do
                echo -e "  ${BLUE}$_dr${NC}"
                echo -e "    ${YELLOW}○${NC} new in session (not extracted)"
            done
            echo ""
        fi
    fi

    # Phase 1: Scan session for dirty/merge state (1 docker run)
    local _util_image="${GIT_UTIL_IMAGE:-alpine/git}"
    local _scan
    _scan=$(docker run --rm --entrypoint sh \
        -e HOME=/tmp \
        -v "$volume:/session:ro" "$_util_image" \
        -c '
            git config --global --add safe.directory "*"
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"; name="${name%/}"
                merging="no"
                [ -f "$d/.git/MERGE_HEAD" ] && merging="yes"
                dirty=$(cd "$d" && git status --porcelain 2>/dev/null | wc -l | tr -d " ")
                echo "$name|$merging|$dirty"
            done
        ' 2>/dev/null) || true

    declare -A _pv_merge _pv_dirty
    while IFS='|' read -r _sn _sm _sd; do
        [[ -z "$_sn" ]] && continue
        _pv_merge[$_sn]="$_sm"
        _pv_dirty[$_sn]="${_sd:-0}"
    done <<< "$_scan"

    # Phase 2+3: Host-side filter + ancestry check
    local -a _candidates=()
    local -a _skip_repos=()
    local -a _problem_repos=()
    local _up_to_date=0

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        repo_matches_filter "$proj_name" "$repo_filter" || continue

        if [[ ! -d "$proj_path" ]]; then
            _skip_repos+=("$proj_name|path not found")
            continue
        fi
        if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
            _skip_repos+=("$proj_name|no '$target_branch' branch")
            continue
        fi
        if [[ "${_pv_merge[$proj_name]:-no}" == "yes" ]]; then
            _problem_repos+=("$proj_name|merge in progress in container")
            continue
        fi
        if [[ "${_pv_dirty[$proj_name]:-0}" -gt 0 ]]; then
            _problem_repos+=("$proj_name|${_pv_dirty[$proj_name]} uncommitted file(s) in container worktree")
            continue
        fi

        local _host_head
        _host_head=$(git -C "$proj_path" rev-parse "refs/heads/$target_branch" 2>/dev/null || echo "")
        [[ -z "$_host_head" ]] && { _skip_repos+=("$proj_name|cannot resolve HEAD"); continue; }
        _candidates+=("$proj_name|$proj_path|$_host_head")
    done <<< "$projects"

    # Batch ancestry check (1 docker run)
    local -a _needs_merge=()
    if [[ ${#_candidates[@]} -gt 0 ]]; then
        local _ancestry_input=""
        declare -A _candidate_paths
        for _c in "${_candidates[@]}"; do
            local _cn _cp _ch
            IFS='|' read -r _cn _cp _ch <<< "$_c"
            _ancestry_input+="${_cn}|${_ch}"$'\n'
            _candidate_paths[$_cn]="$_cp"
        done

        local _ancestry_out
        _ancestry_out=$(printf '%s' "$_ancestry_input" | docker run --rm -i --entrypoint sh \
            -e HOME=/tmp \
            -v "$volume:/session:ro" "$_util_image" \
            -c '
                git config --global --add safe.directory "*"
                while IFS="|" read -r name host_head; do
                    [ -z "$name" ] && continue
                    [ ! -d "/session/$name/.git" ] && { echo "$name|error"; continue; }
                    cd "/session/$name"
                    session_head=$(git rev-parse HEAD 2>/dev/null)
                    if git merge-base --is-ancestor "$host_head" HEAD 2>/dev/null; then
                        echo "$name|up_to_date|$session_head"
                    else
                        ahead=$(git rev-list --count HEAD.."$host_head" 2>/dev/null || echo "?")
                        echo "$name|needs_merge|$ahead|$session_head"
                    fi
                done
            ' 2>/dev/null) || true

        while IFS='|' read -r _an _as _extra1 _extra2; do
            [[ -z "$_an" ]] && continue
            if [[ "$_as" == "up_to_date" ]]; then
                _up_to_date=$((_up_to_date + 1))
            elif [[ "$_as" == "needs_merge" ]]; then
                local _host_count="?"
                local _hp="${_candidate_paths[$_an]}"
                if [[ -n "$_hp" ]]; then
                    _host_count=$(git -C "$_hp" rev-list --count "$session_name".."$target_branch" 2>/dev/null || echo "?")
                fi
                _needs_merge+=("$_an|$_host_count")
            else
                _skip_repos+=("$_an|ancestry check failed")
            fi
        done <<< "$_ancestry_out"
    fi

    # Render repos
    if [[ ${#_needs_merge[@]} -gt 0 ]]; then
        for _entry in "${_needs_merge[@]}"; do
            local _mn _mc
            IFS='|' read -r _mn _mc <<< "$_entry"
            local _mpath
            _mpath=$(echo "$projects" | grep "^${_mn}|" | head -1 | cut -d'|' -f2)
            local _short_head=""
            [[ -n "$_mpath" ]] && _short_head=$(git -C "$_mpath" log --oneline -1 "$target_branch" 2>/dev/null)
            echo -e "  ${BLUE}$_mn${NC}"
            echo -e "    ${GREEN}✓${NC} ${_mc} commit(s) from ${target_branch}"
            [[ -n "$_short_head" ]] && echo -e "    ${DIM}latest: $_short_head${NC}"
        done
        echo ""
    fi

    if [[ ${#_problem_repos[@]} -gt 0 ]]; then
        for _entry in "${_problem_repos[@]}"; do
            local _pn _pd
            IFS='|' read -r _pn _pd <<< "$_entry"
            echo -e "  ${BLUE}$_pn${NC}"
            echo -e "    ${YELLOW}!${NC} $_pd"
        done
        echo ""
    fi

    if [[ ${#_skip_repos[@]} -gt 0 ]]; then
        for _entry in "${_skip_repos[@]}"; do
            local _sn _sd
            IFS='|' read -r _sn _sd <<< "$_entry"
            echo -e "  ${DIM}$_sn — $_sd${NC}"
        done
        echo ""
    fi

    # Footer
    _rule

    if [[ $_up_to_date -gt 0 ]]; then
        echo -e "${DIM}${_up_to_date} already up to date${NC}"
    fi

    if [[ ${#_needs_merge[@]} -eq 0 && ${#_problem_repos[@]} -eq 0 ]]; then
        info "Nothing to merge — session is up to date with '$target_branch'"
    fi

    # Warn about --repo filter terms that matched nothing
    if [[ -n "$repo_filter" ]]; then
        local _all_proj_names=()
        while IFS='|' read -r _pn _pp; do
            [[ -n "$_pn" ]] && _all_proj_names+=("$_pn")
        done <<< "$projects"
        local IFS=','
        for _fterm in $repo_filter; do
            local _fmatched=false
            for _fname in "${_all_proj_names[@]}"; do
                if [[ "$_fname" == *"$_fterm"* ]]; then
                    _fmatched=true
                    break
                fi
            done
            if ! $_fmatched; then
                warn "no repo matching '$_fterm' found in session"
            fi
        done
    fi
}
