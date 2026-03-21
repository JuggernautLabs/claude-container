#!/usr/bin/env bash
# Sync execution — perform sync actions per repo classification

# Execute the sync plan.
# Usage: execute_sync <session_name> <target_branch> <result_dir> <repo_filter> <squash>
execute_sync() {
    local session_name="$1"
    local target_branch="$2"
    local result_dir="$3"
    local repo_filter="${4:-}"
    local squash="${5:-true}"
    local volume="claude-session-${session_name}"

    local _done=0 _failed=0 _skipped=0 _needs_container=false

    # Group repos by action
    local -a _pull_repos=() _push_repos=() _reconcile_repos=()

    for _sf in "$result_dir"/*; do
        [[ -f "$_sf" ]] || continue
        local _name _action
        _name=$(grep "^repo_name=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
        [[ -z "$_name" ]] && continue
        repo_matches_filter "$_name" "$repo_filter" || continue
        _action=$(grep "^sync_action=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)

        case "$_action" in
            pull) _pull_repos+=("$_name") ;;
            push) _push_repos+=("$_name") ;;
            reconcile) _reconcile_repos+=("$_name") ;;
            skip) _skipped=$((_skipped + 1)) ;;
            warn) _skipped=$((_skipped + 1)) ;;
        esac
    done

    # Phase 1: Pull repos (container → host)
    if [[ ${#_pull_repos[@]} -gt 0 ]]; then
        echo ""
        info "Pulling ${#_pull_repos[@]} repo(s) from container..."
        local _pull_filter
        _pull_filter=$(IFS=','; echo "${_pull_repos[*]}")

        # Extract session branches
        session_extract "$session_name" --force --repo "$_pull_filter" --result-dir "$result_dir" --quiet || true

        # Merge into target
        session_auto_merge "$session_name" "$target_branch" false "$_pull_filter" "$squash" "$result_dir" || true

        # Count results
        for _pr in "${_pull_repos[@]}"; do
            local _mr
            _mr=$(_pull_result_get "$result_dir" "$_pr" "merge_detail")
            case "$_mr" in
                "squash-merged"*|"fast-forward"*|"merged"*|"created"*|"already up to date"*|"up to date"*)
                    success "  ← $_pr: $_mr"
                    _done=$((_done + 1))
                    ;;
                *)
                    local _ms
                    _ms=$(_pull_result_get "$result_dir" "$_pr" "merge_status")
                    if [[ "$_ms" == "SKIP" || "$_ms" == "CONFLICT" ]]; then
                        warn "  ← $_pr: $_mr"
                        _failed=$((_failed + 1))
                    else
                        # Extract-only (no merge detail = extract-only mode)
                        local _es
                        _es=$(_pull_result_get "$result_dir" "$_pr" "extract_status")
                        if [[ "$_es" == "updated" || "$_es" == "cloned" ]]; then
                            success "  ← $_pr: extracted"
                            _done=$((_done + 1))
                        else
                            warn "  ← $_pr: ${_mr:-no result}"
                            _failed=$((_failed + 1))
                        fi
                    fi
                    ;;
            esac
        done
    fi

    # Phase 2: Push repos (host → container)
    if [[ ${#_push_repos[@]} -gt 0 ]]; then
        echo ""
        info "Pushing ${#_push_repos[@]} repo(s) into container..."
        local _push_filter
        _push_filter=$(IFS=','; echo "${_push_repos[*]}")

        session_refresh "$session_name" "$target_branch" "$_push_filter" false > /dev/null 2>&1 || true

        # Verify push worked — re-check container heads
        for _pr in "${_push_repos[@]}"; do
            success "  → $_pr: pushed $target_branch"
            _done=$((_done + 1))
        done
    fi

    # Phase 3: Reconcile repos (diverged — needs merge in container + pull back)
    if [[ ${#_reconcile_repos[@]} -gt 0 ]]; then
        echo ""
        info "Reconciling ${#_reconcile_repos[@]} diverged repo(s)..."

        # First: merge host target INTO container
        local _merge_rc=0
        session_merge_into "$session_name" "$target_branch" || _merge_rc=$?

        if [[ $_merge_rc -eq 0 ]]; then
            # Conflicts — needs container with Claude
            _needs_container=true
            warn "  Reconcile has conflicts — Claude will resolve in container"
            _failed=$((_failed + ${#_reconcile_repos[@]}))
        else
            # Clean merge — extract and merge back
            info "  Clean merge — pulling resolved state..."
            local _reconcile_filter
            _reconcile_filter=$(IFS=','; echo "${_reconcile_repos[*]}")

            session_extract "$session_name" --force --repo "$_reconcile_filter" --result-dir "$result_dir" --quiet || true
            session_auto_merge "$session_name" "$target_branch" false "$_reconcile_filter" "$squash" "$result_dir" || true

            for _rr in "${_reconcile_repos[@]}"; do
                local _mr
                _mr=$(_pull_result_get "$result_dir" "$_rr" "merge_detail")
                case "$_mr" in
                    "squash-merged"*|"fast-forward"*|"merged"*|"created"*|"already up to date"*|"up to date"*)
                        success "  ↔ $_rr: $_mr"
                        _done=$((_done + 1))
                        ;;
                    *)
                        warn "  ↔ $_rr: ${_mr:-reconcile incomplete}"
                        _failed=$((_failed + 1))
                        ;;
                esac
            done
        fi
    fi

    # Summary
    echo ""
    _rule
    local _parts=()
    [[ $_done -gt 0 ]] && _parts+=("$_done synced")
    [[ $_failed -gt 0 ]] && _parts+=("$_failed failed")
    [[ $_skipped -gt 0 ]] && _parts+=("$_skipped skipped")

    if [[ ${#_parts[@]} -gt 0 ]]; then
        local _line
        _line=$(IFS=', '; echo "${_parts[*]}")
        if [[ $_failed -eq 0 ]]; then
            success "$_line"
        else
            warn "$_line"
        fi
    fi

    # If reconcile needs container, launch it
    if $_needs_container; then
        echo ""
        warn "Diverged repos need Claude to resolve conflicts."
        echo "  Run: claude-container pull -s $session_name $target_branch --reconcile"
        return 1
    fi

    return 0
}
