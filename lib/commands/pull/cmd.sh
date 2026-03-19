#!/usr/bin/env bash
# Subcommand: pull
# Pull session changes from container to host (container -> host)
#
# Usage:
#   claude-container pull -s <session> [branch] [options]
#   claude-container pull -s myproj                      # extract only
#   claude-container pull -s myproj main                 # extract + merge into main
#   claude-container pull -s myproj main --reconcile     # full reconcile cycle
#   claude-container pull -s myproj --status             # read-only status check

cmd_pull() {
    local session_name=""
    local branch=""
    local repo_filter=""
    local reconcile=false
    local force=false
    local dry_run=false
    local squash=true
    local status_only=false
    local verify=false
    local discuss=false
    local show_prompt=false
    local extract_discovered=false
    local enable_session_only=false
    local at_commitish=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --repo)
                # Accumulate: --repo a --repo b or --repo a,b,c
                if [[ -n "$repo_filter" ]]; then
                    repo_filter="${repo_filter},$2"
                else
                    repo_filter="$2"
                fi
                shift 2
                ;;
            --reconcile|-R)
                reconcile=true
                shift
                ;;
            --force|-f)
                force=true
                shift
                ;;
            --squash)
                squash=true
                shift
                ;;
            --no-squash)
                squash=false
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --status)
                status_only=true
                shift
                ;;
            --verify)
                verify=true
                shift
                ;;
            --discuss)
                discuss=true
                verify=true  # discuss implies verify
                shift
                ;;
            --extract)
                extract_discovered=true
                shift
                ;;
            --show-prompt)
                show_prompt=true
                shift
                ;;
            --enable-session-only)
                enable_session_only=true
                shift
                ;;
            --at)
                at_commitish="$2"
                shift 2
                ;;
            --help|-h)
                _pull_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container pull --help' for usage"
                return 1
                ;;
            *)
                # Positional arg = branch name
                if [[ -z "$branch" ]]; then
                    branch="$1"
                else
                    error "Unexpected argument: $1"
                    echo "Run 'claude-container pull --help' for usage"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Session name required: use --session <name>"
        echo "Run 'claude-container pull --help' for usage"
        return 1
    fi

    # Dry-run and verify require a branch (nothing to preview/confirm without a merge target)
    if $dry_run && [[ -z "$branch" ]]; then
        error "--dry-run requires a target branch"
        echo "Usage: claude-container pull -s <session> <branch> --dry-run"
        return 1
    fi

    # Status check mode — read-only, no extraction or merge
    if $status_only; then
        _pull_status "$session_name" "$repo_filter"
        return $?
    fi

    # Discover repos created inside the container and register them
    local _disc_volume="claude-session-${session_name}"
    local _disc_cfg
    _disc_cfg=$(read_session_config "$_disc_volume")
    local _disc_proj=""
    if [[ -n "$_disc_cfg" ]]; then
        _disc_proj=$(parse_session_projects "$_disc_cfg")
    fi
    discover_and_register "$_disc_volume" "$_disc_cfg" "$_disc_proj"
    if $extract_discovered; then
        # Re-read config after discover_and_register wrote it
        local _promo_cfg
        _promo_cfg=$(read_session_config "$_disc_volume")
        promote_discovered_repos "$_disc_volume" "$_promo_cfg" "$repo_filter"
    fi

    # Extract-only --verify: show status preview and confirm before extracting
    # Skip prompt when non-interactive (e.g. called from watch)
    if $verify && [[ -z "$branch" ]]; then
        _pull_status "$session_name" "$repo_filter"
        if $_PULL_STATUS_HAS_CHANGES && [[ -t 0 ]]; then
            echo ""
            printf "Extract session branches to host? [y/N] "
            local _ext_answer
            read -r _ext_answer
            case "$_ext_answer" in
                [yY]|[yY][eE][sS])
                    info "Extracting..."
                    ;;
                *)
                    info "Aborted."
                    return 0
                    ;;
            esac
        elif ! $_PULL_STATUS_HAS_CHANGES; then
            return 0
        fi
    fi

    # Extract session branches to host repos
    local extract_args=("$session_name")
    if $force; then
        extract_args+=(--force)
    fi
    # When merging into a target branch, always force-extract.
    # The session branch is just transport — container is source of truth.
    # Main is protected by merge conflict detection.
    if [[ -n "$branch" ]]; then
        extract_args+=(--force)
    fi
    if [[ -n "$repo_filter" ]]; then
        extract_args+=(--repo "$repo_filter")
    fi
    if [[ -n "$at_commitish" ]]; then
        extract_args+=(--at "$at_commitish")
    fi

    if $reconcile; then
        # Reconcile mode requires a branch
        if [[ -z "$branch" ]]; then
            error "--reconcile requires a target branch"
            echo "Usage: claude-container pull -s <session> <branch> --reconcile"
            return 1
        fi
        if $dry_run; then
            _pull_reconcile_preview "$session_name" "$branch" "$repo_filter" "$show_prompt"
            return $?
        fi
        # Reconcile uses legacy (non-unified) output
        _pull_reconcile "$session_name" "$branch" "$force" "$verify"
        return $?
    fi

    # --- Unified reporting mode ---
    local _pull_result_dir
    _pull_result_dir=$(mktemp -d)
    trap "rm -rf '$_pull_result_dir'" RETURN

    if [[ -n "$branch" && -n "$at_commitish" ]]; then
        info "Pulling session '$session_name' @ $at_commitish into '$branch'..."
    elif [[ -n "$branch" ]]; then
        info "Pulling session '$session_name' into '$branch'..."
    elif [[ -n "$at_commitish" ]]; then
        info "Pulling session '$session_name' @ $at_commitish..."
    else
        info "Pulling session '$session_name'..."
    fi
    echo ""

    # Capture pre-extraction status (container vs session vs target) BEFORE extraction
    # Extraction flattens the container→session delta — we need this for the report
    local _pre_heads
    _pre_heads=$(get_session_heads "claude-session-${session_name}")
    if [[ -n "$_pre_heads" ]]; then
        local _pre_cfg
        _pre_cfg=$(read_session_config "claude-session-${session_name}")
        local _pre_projects=""
        [[ -n "$_pre_cfg" ]] && _pre_projects=$(parse_session_projects "$_pre_cfg")

        while IFS='|' read -r _ph_name _ph_head; do
            [[ -z "$_ph_name" ]] && continue
            local _ph_path
            _ph_path=$(echo "$_pre_projects" | grep "^${_ph_name}|" | head -1 | cut -d'|' -f2)
            detect_pre_extract_status "$_ph_name" "$_ph_head" "${_ph_path:-}" "$session_name" "${branch:-}" "$_pull_result_dir"
        done <<< "$_pre_heads"
    fi

    # Extract with result tracking
    extract_args+=(--result-dir "$_pull_result_dir")
    # Suppress extraction noise when verify/dry-run — the report speaks for itself
    if ($verify || $dry_run) && [[ -n "$branch" ]]; then
        extract_args+=(--quiet)
    fi
    session_extract "${extract_args[@]}"

    # If branch specified, dry-run merge first to populate results + show preview
    local _merge_rc=0
    if [[ -n "$branch" ]]; then
        # Dry-run: populate merge results without changing anything
        session_auto_merge "$session_name" "$branch" true "$repo_filter" "$squash" "$_pull_result_dir" 2>/dev/null || true

        if $dry_run || $verify; then
            # Show preview report + diffstat for --dry-run and --verify
            echo ""
            _pull_report "$session_name" "$branch" "$_pull_result_dir" "$repo_filter"
            echo ""
            _verify_diffstat "$session_name" "$branch" "$_pull_result_dir" "$repo_filter" || true
        fi

        if $dry_run; then
            return 0
        fi

        if $discuss; then
            echo ""
            local _discuss_prompt
            _discuss_prompt=$(_pull_discuss_prompt "$session_name" "$branch" "$_pull_result_dir" "$repo_filter")
            info "Launching Claude to discuss merge state..."
            echo ""
            claude "$_discuss_prompt"
            echo ""
        fi

        if $verify; then
            # Check if there's actually anything to merge
            local _has_mergeable=false
            for _vf in "$_pull_result_dir"/*; do
                [[ -f "$_vf" ]] || continue
                [[ "$_vf" == *.detail ]] && continue
                local _vf_name
                _vf_name=$(grep "^repo_name=" "$_vf" 2>/dev/null | tail -1 | cut -d= -f2-)
                repo_matches_filter "$_vf_name" "$repo_filter" || continue
                local _vm
                _vm=$(grep "^merge_detail=" "$_vf" 2>/dev/null | tail -1 | cut -d= -f2-)
                case "$_vm" in
                    "squash-merge"*|"fast-forward"*|"merge cleanly"*|"squash-merged"*)
                        _has_mergeable=true
                        break
                        ;;
                esac
            done

            if $_has_mergeable; then
                echo ""
                if $enable_session_only; then
                    printf "Merge into '%s'? [(s)ession only / y / N] " "$branch"
                else
                    printf "Merge into '%s'? [y/N] " "$branch"
                fi
                local _answer
                read -r _answer
                case "$_answer" in
                    [yY]|[yY][eE][sS])
                        info "Merging..."
                        ;;
                    [sS])
                        info "Session branches extracted, merge skipped."
                        info "To merge later: claude-container pull -s $session_name $branch"
                        return 0
                        ;;
                    *)
                        info "Aborted. Session branches extracted but not merged."
                        info "To merge later: claude-container pull -s $session_name $branch"
                        return 0
                        ;;
                esac
            else
                echo ""
                info "Nothing to merge."
                return 0
            fi
        fi

        # Real merge
        session_auto_merge "$session_name" "$branch" false "$repo_filter" "$squash" "$_pull_result_dir" || _merge_rc=$?

        # Show final report with actual results
        echo ""
        _pull_report "$session_name" "$branch" "$_pull_result_dir" "$repo_filter"
        echo ""
        _verify_diffstat "$session_name" "$branch" "$_pull_result_dir" "$repo_filter" || true
    else
        # Extract-only: just show extraction report
        echo ""
        _pull_report "$session_name" "" "$_pull_result_dir" "$repo_filter"
    fi

    return $_merge_rc
}
