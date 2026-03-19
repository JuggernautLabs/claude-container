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

    # Extract with result tracking
    extract_args+=(--result-dir "$_pull_result_dir")
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
