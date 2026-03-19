#!/usr/bin/env bash
# Pull reconcile — full reconcile cycle and preview

# Preview what reconcile would do — compact, only shows repos needing attention
_pull_reconcile_preview() {
    local session_name="$1"
    local target_branch="$2"
    local repo_filter="${3:-}"
    local show_prompt="${4:-false}"
    local volume="claude-session-${session_name}"

    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    info "Reconcile preview: '$session_name' ↔ '$target_branch'"
    echo ""

    # Read config
    local config_content
    config_content=$(read_session_config "$volume")
    if [[ -z "$config_content" ]]; then
        error "No config in session"
        return 1
    fi
    local projects
    projects=$(parse_session_projects "$config_content")
    [[ -n "$repo_filter" ]] && projects=$(augment_projects_from_volume "$volume" "$projects" "$repo_filter")

    # Get session scan (dirty/merge status)
    local _util_image="${GIT_UTIL_IMAGE:-alpine/git}"
    local _merge_scan
    _merge_scan=$(docker run --rm --entrypoint sh \
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

    declare -A _merge_status _dirty_count
    while IFS='|' read -r _sname _smerge _sdirty; do
        [[ -z "$_sname" ]] && continue
        _merge_status[$_sname]="$_smerge"
        _dirty_count[$_sname]="$_sdirty"
    done <<< "$_merge_scan"

    # Dry-run session->main merge (same detection as pull --verify)
    local _preview_dir
    _preview_dir=$(mktemp -d)
    session_auto_merge "$session_name" "$target_branch" true "$repo_filter" true "$_preview_dir" 2>/dev/null || true

    # Unified per-repo view: combine both directions
    local _needs_claude=0 _would_merge=0 _would_conflict=0 _up_to_date=0
    local -a _rev_conflict_repos=() _rev_conflict_files=()

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        repo_matches_filter "$proj_name" "$repo_filter" || continue

        # Gather inbound status (main->session)
        local _in_status=""
        if [[ ! -d "$proj_path" ]]; then
            _in_status="skip:host not found"
        elif ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
            _in_status="skip:no $target_branch"
        elif [[ "${_merge_status[$proj_name]:-no}" == "yes" ]]; then
            _in_status="conflict:merge in progress"
        elif [[ "${_dirty_count[$proj_name]:-0}" -gt 0 ]]; then
            _in_status="dirty:${_dirty_count[$proj_name]} uncommitted file(s)"
        else
            # Check if main has commits the session doesn't (merge needed)
            local _main_ahead=0
            _main_ahead=$(git -C "$proj_path" rev-list --count "$session_name".."$target_branch" 2>/dev/null || echo "0")
            if [[ "$_main_ahead" -gt 0 ]]; then
                _in_status="merge:${_main_ahead} commit(s) to merge"
            else
                _in_status="clean"
            fi
        fi

        # Gather outbound status (session->main)
        local _out_status _out_detail _out_files
        _out_status=$(_pull_result_get "$_preview_dir" "$proj_name" "merge_status")
        _out_detail=$(_pull_result_get "$_preview_dir" "$proj_name" "merge_detail")
        _out_files=$(_pull_result_get "$_preview_dir" "$proj_name" "conflict_files")

        # Skip repos that are clean in both directions
        local _skip_target_ahead
        _skip_target_ahead=$(_pull_result_get "$_preview_dir" "$proj_name" "target_ahead")
        if [[ "$_in_status" == "clean" ]]; then
            case "$_out_status" in
                ""|OK)
                    case "$_out_detail" in
                        "already up to date"|"up to date"*)
                            # Check if target-ahead commits are all benign squash-merges
                            local _skip_external=false
                            if [[ -n "$_skip_target_ahead" && "$_skip_target_ahead" != "0" ]]; then
                                local _skip_log
                                _skip_log=$(git -C "$proj_path" log --oneline "$session_name".."$target_branch" 2>/dev/null | head -5)
                                while IFS= read -r _skip_line; do
                                    [[ -z "$_skip_line" ]] && continue
                                    if ! echo "$_skip_line" | grep -qE "^[0-9a-f]+ ${session_name} → "; then
                                        _skip_external=true
                                        break
                                    fi
                                done <<< "$_skip_log"
                            fi
                            if ! $_skip_external; then
                                _up_to_date=$((_up_to_date + 1))
                                continue
                            fi
                            ;;
                    esac
                    ;;
            esac
        fi

        # Show this repo — it needs attention
        local _short_session _short_main
        _short_session=$(git -C "$proj_path" rev-parse --short "$session_name" 2>/dev/null || echo "?")
        _short_main=$(git -C "$proj_path" rev-parse --short "$target_branch" 2>/dev/null || echo "?")
        echo -e "  ${BLUE}$proj_name${NC}  session:${_short_session}  ${target_branch}:${_short_main}"

        # Inbound line
        case "$_in_status" in
            clean)
                echo -e "    ${target_branch} → session:  ${GREEN}✓${NC} clean"
                ;;
            dirty:*)
                echo -e "    ${target_branch} → session:  ${YELLOW}!${NC} ${_in_status#dirty:} (Claude commits first)"
                _needs_claude=$((_needs_claude + 1))
                ;;
            conflict:*)
                echo -e "    ${target_branch} → session:  ${YELLOW}!${NC} ${_in_status#conflict:}"
                _needs_claude=$((_needs_claude + 1))
                ;;
            skip:*)
                echo -e "    ${target_branch} → session:  ${YELLOW}!${NC} skipped (${_in_status#skip:})"
                ;;
        esac

        # Outbound line
        case "$_out_status" in
            OK)
                case "$_out_detail" in
                    "squash-merge"*|"fast-forward"*|"merge cleanly"*)
                        echo -e "    session → ${target_branch}:  ${GREEN}✓${NC} $_out_detail"
                        _would_merge=$((_would_merge + 1))
                        ;;
                    "already up to date"|"up to date"*)
                        echo -e "    session → ${target_branch}:  — nothing to merge"
                        ;;
                    *)
                        echo -e "    session → ${target_branch}:  ${GREEN}✓${NC} $_out_detail"
                        ;;
                esac
                ;;
            CONFLICT)
                echo -e "    session → ${target_branch}:  ${RED}x${NC} conflict${_out_files:+ ($_out_files)}"
                _would_conflict=$((_would_conflict + 1))
                _rev_conflict_repos+=("$proj_name")
                _rev_conflict_files+=("${_out_files:-?}")
                # Diffstat
                local _stat
                _stat=$(git -C "$proj_path" diff --stat "$target_branch".."$session_name" 2>/dev/null)
                if [[ -n "$_stat" ]]; then
                    echo "$_stat" | sed '$d' | sed 's/^/      /'
                    echo "      $(echo "$_stat" | tail -1)"
                fi
                ;;
            SKIP)
                echo -e "    session → ${target_branch}:  ${YELLOW}!${NC} skipped${_out_detail:+ — $_out_detail}"
                ;;
            "")
                # No merge result — repo not in session or filtered out
                ;;
        esac

        # Target-ahead warning: show commits on target that session doesn't have
        local _target_ahead
        _target_ahead=$(_pull_result_get "$_preview_dir" "$proj_name" "target_ahead")
        if [[ -n "$_target_ahead" && "$_target_ahead" != "0" ]]; then
            # Check if all ahead commits are our own squash-merges (benign)
            local _ahead_log _rc_external=0
            _ahead_log=$(git -C "$proj_path" log --oneline "$session_name".."$target_branch" 2>/dev/null | head -5)
            while IFS= read -r _ahead_line; do
                [[ -z "$_ahead_line" ]] && continue
                if ! echo "$_ahead_line" | grep -qE "^[0-9a-f]+ ${session_name} → "; then
                    _rc_external=$((_rc_external + 1))
                fi
            done <<< "$_ahead_log"

            if [[ $_rc_external -gt 0 ]]; then
                echo -e "    ${DIM}· ${target_branch} has ${_target_ahead} commit(s) not in session:${NC}"
                while IFS= read -r _ahead_line; do
                    [[ -n "$_ahead_line" ]] && echo "      $_ahead_line"
                done <<< "$_ahead_log"
                local _risk_stat
                _risk_stat=$(git -C "$proj_path" diff --stat "$session_name".."$target_branch" 2>/dev/null | tail -1)
                [[ -n "$_risk_stat" ]] && echo -e "      ${DIM}$_risk_stat${NC}"
            else
                local _rc_squash_stat
                _rc_squash_stat=$(git -C "$proj_path" diff --stat "$session_name".."$target_branch" 2>/dev/null | tail -1)
                if [[ -n "$_rc_squash_stat" ]]; then
                    echo -e "    ${DIM}${target_branch} +${_target_ahead} (prior squash-merge): $_rc_squash_stat${NC}"
                else
                    echo -e "    ${DIM}${target_branch} +${_target_ahead} (prior squash-merge)${NC}"
                fi
            fi
        fi
        echo ""
    done <<< "$projects"

    rm -rf "$_preview_dir"

    # Summary
    [[ $_up_to_date -gt 0 ]] && info "$_up_to_date repo(s) up to date (hidden)"
    [[ $_would_merge -gt 0 ]] && success "$_would_merge would merge into $target_branch"
    [[ $_would_conflict -gt 0 ]] && warn "$_would_conflict would CONFLICT merging into $target_branch — Claude will be instructed to fix"
    [[ $_needs_claude -gt 0 ]] && warn "$_needs_claude need Claude's attention in container"

    # Build and show Claude's prompt (only with --show-prompt)
    if [[ "$show_prompt" == "true" ]] && [[ $((_needs_claude + _would_conflict)) -gt 0 ]]; then
        echo ""
        info "=== Claude's prompt ==="
        echo ""

        local _prompt="Branch '$target_branch' was merged into this session. Here is what happened:"
        _prompt+=$'\n'

        # Inbound status per repo
        while IFS='|' read -r proj_name proj_path; do
            [[ -z "$proj_name" ]] && continue
            repo_matches_filter "$proj_name" "$repo_filter" || continue
            local _dc="${_dirty_count[$proj_name]:-0}"
            if [[ "${_merge_status[$proj_name]:-no}" == "yes" ]]; then
                _prompt+=$'\n'"  CONFLICT: $proj_name (merge in progress)"
            elif [[ "$_dc" -gt 0 ]]; then
                _prompt+=$'\n'"  DIRTY: $proj_name ($_dc uncommitted changes)"
            fi
        done <<< "$projects"

        # Reverse conflicts
        if [[ ${#_rev_conflict_repos[@]} -gt 0 ]]; then
            _prompt+=$'\n\n'"=== REVERSE MERGE CONFLICTS ==="
            _prompt+=$'\n'"${#_rev_conflict_repos[@]} project(s) will conflict when merging session back into '$target_branch'."
            _prompt+=$'\n'"The host '$target_branch' branch is mounted read-only at /host/{project_name}."
            for _i in "${!_rev_conflict_repos[@]}"; do
                _prompt+=$'\n'"  ${_rev_conflict_repos[$_i]}: ${_rev_conflict_files[$_i]}"
            done
            _prompt+=$'\n\n'"For each reverse-conflict project:"
            _prompt+=$'\n'"1. cd /workspace/{project_name}"
            _prompt+=$'\n'"2. git remote add host /host/{project_name} && git fetch host $target_branch"
            _prompt+=$'\n'"3. git merge host/$target_branch --no-edit"
            _prompt+=$'\n'"4. Resolve conflicts — goal is session contains everything from $target_branch"
            _prompt+=$'\n'"5. git add && git commit"
            _prompt+=$'\n'"6. git remote remove host"
            _prompt+=$'\n\n'"After this, host can fast-forward $target_branch to session — no more squash conflicts."
        fi

        _prompt+=$'\n\n'"When finished: fin \"<brief description>\""

        echo "$_prompt"
    fi
}

_pull_reconcile() {
    local session_name="$1"
    local target_branch="$2"
    local force="$3"
    local verify="${4:-false}"
    local volume="claude-session-${session_name}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    # Phase 1: Extract session branches to host repos (quiet — result-dir suppresses legacy output)
    local _reconcile_result_dir
    _reconcile_result_dir=$(mktemp -d)
    info "Extracting session branches..."
    if [[ "$force" == "true" ]]; then
        session_extract "$session_name" --force --result-dir "$_reconcile_result_dir"
    else
        session_extract "$session_name" --result-dir "$_reconcile_result_dir"
    fi

    # Phase 2: Stash dirty worktrees on host
    _pull_stash_dirty "$session_name" "$target_branch"
    echo ""

    # Phase 3: Merge target INTO session (inside docker volume)
    # session_merge_into returns:
    #   1 = clean merge, no container needed
    #   0 = conflicts/dirty, needs container with Claude
    info "Phase 3: Merging '$target_branch' into session..."
    if ! session_merge_into "$session_name" "$target_branch"; then
        # Clean merge — extract resolved state and auto-merge into target
        info "Clean merge — extracting and merging into '$target_branch'..."
        session_extract "$session_name" --force
        echo ""

        if [[ "$verify" == "true" ]]; then
            # Show dry-run before merging
            info "Dry-run merge into '$target_branch':"
            session_auto_merge "$session_name" "$target_branch" true
            echo ""
            printf "Merge into '%s'? [(s)ession only / y / N] " "$target_branch"
            local _answer
            read -r _answer
            case "$_answer" in
                [yY]|[yY][eE][sS])
                    info "Merging..."
                    ;;
                [sS])
                    info "Session branches extracted, merge skipped."
                    # Clean up marker
                    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
                    docker run --rm -v "$volume:/session" "$git_image" \
                        rm -f /session/.merge-into-branch 2>/dev/null || true
                    return 0
                    ;;
                *)
                    info "Aborted. Session branches extracted but not merged into $target_branch."
                    # Clean up marker
                    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
                    docker run --rm -v "$volume:/session" "$git_image" \
                        rm -f /session/.merge-into-branch 2>/dev/null || true
                    return 0
                    ;;
            esac
        fi

        session_auto_merge "$session_name" "$target_branch"

        # Clean up the .merge-into-branch marker (session_merge_into wrote it)
        local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
        docker run --rm -v "$volume:/session" "$git_image" \
            rm -f /session/.merge-into-branch 2>/dev/null || true
        return 0
    fi

    # Conflicts detected — session_merge_into already wrote:
    #   .merge-into-branch  (target branch name)
    #   .merge-into-summary (Claude's initial prompt with fin instructions)
    #   .merge-into-mounts  (dirty projects needing host mounts)

    # If --verify, write marker so the exit handler knows to prompt
    if [[ "$verify" == "true" ]]; then
        local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
        docker run --rm -v "$volume:/session" "$git_image" \
            sh -c "echo 1 > /session/.merge-verify" 2>/dev/null || true
    fi

    # Exec back into claude-container to launch container for resolution
    info "Launching container for conflict resolution..."
    echo ""
    exec "$0" --session "$session_name" --auto-merge
}

_pull_stash_dirty() {
    local session_name="$1"
    local target_branch="$2"
    local volume="claude-session-${session_name}"

    local config_content
    config_content=$(read_session_config "$volume")
    [[ -z "$config_content" ]] && return 0

    local projects
    projects=$(parse_session_projects "$config_content")
    [[ -z "$projects" ]] && return 0

    local stash_count=0
    local timestamp
    timestamp=$(date +%s)

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        [[ ! -d "$proj_path" ]] && continue

        local dirty
        dirty=$(git -C "$proj_path" status --porcelain 2>/dev/null)
        [[ -z "$dirty" ]] && continue

        local stash_branch="${target_branch}-${session_name}-stash-${timestamp}"
        local current_branch
        current_branch=$(git -C "$proj_path" symbolic-ref --short HEAD 2>/dev/null || echo "")

        info "  $proj_name: stashing uncommitted work"

        git -C "$proj_path" checkout -b "$stash_branch" >/dev/null 2>&1
        git -C "$proj_path" add -A >/dev/null 2>&1
        git -C "$proj_path" commit -m "WIP: stashed by reconcile (session: $session_name)" --no-verify >/dev/null 2>&1
        if [[ -n "$current_branch" ]]; then
            git -C "$proj_path" checkout "$current_branch" >/dev/null 2>&1
        fi

        stash_count=$((stash_count + 1))
    done <<< "$projects"

    if [[ $stash_count -gt 0 ]]; then
        success "  Stashed $stash_count repo(s)"
    else
        info "  All host repos clean"
    fi
}
