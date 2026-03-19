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

    # Snapshot all container + host state (single docker run)
    local _pv_snap_dir
    _pv_snap_dir=$(mktemp -d)
    snapshot_session_state "$volume" "$session_name" "$target_branch" "$_pv_snap_dir" "$repo_filter"

    # Phase 2+3: classify repos from snapshot
    local -a _needs_merge=()
    local -a _skip_repos=()
    local -a _problem_repos=()
    local _up_to_date=0

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        repo_matches_filter "$proj_name" "$repo_filter" || continue

        # Read snapshot data
        local _pv_merging _pv_dirty _pv_container_head
        _pv_merging=$(_pull_result_get "$_pv_snap_dir" "$proj_name" "merging")
        _pv_dirty=$(_pull_result_get "$_pv_snap_dir" "$proj_name" "dirty_count")
        _pv_container_head=$(_pull_result_get "$_pv_snap_dir" "$proj_name" "container_head")

        if [[ ! -d "$proj_path" ]]; then
            _skip_repos+=("$proj_name|path not found")
            continue
        fi
        if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
            _skip_repos+=("$proj_name|no '$target_branch' branch")
            continue
        fi
        if [[ "${_pv_merging:-no}" == "yes" ]]; then
            _problem_repos+=("$proj_name|merge in progress in container")
            continue
        fi
        if [[ "${_pv_dirty:-0}" -gt 0 ]]; then
            _problem_repos+=("$proj_name|${_pv_dirty} uncommitted file(s) in container worktree")
            continue
        fi

        # Check if container HEAD is missing (repo not in container)
        if [[ -z "$_pv_container_head" ]]; then
            _skip_repos+=("$proj_name|not in container")
            continue
        fi

        local _host_head
        _host_head=$(git -C "$proj_path" rev-parse "refs/heads/$target_branch" 2>/dev/null || echo "")
        [[ -z "$_host_head" ]] && { _skip_repos+=("$proj_name|cannot resolve HEAD"); continue; }

        # Ancestry check using local git (container HEAD is in snapshot, check if host_head is ancestor)
        local _container_known
        _container_known=$(_pull_result_get "$_pv_snap_dir" "$proj_name" "container_known")
        if [[ "$_container_known" == "true" ]] && git -C "$proj_path" merge-base --is-ancestor "$_host_head" "$_pv_container_head" 2>/dev/null; then
            _up_to_date=$((_up_to_date + 1))
        else
            local _host_count
            _host_count=$(git -C "$proj_path" rev-list --count "$session_name".."$target_branch" 2>/dev/null || echo "?")
            _needs_merge+=("$proj_name|$_host_count")
        fi
    done <<< "$projects"

    rm -rf "$_pv_snap_dir"

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
        return 1
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
