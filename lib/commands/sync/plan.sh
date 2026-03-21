#!/usr/bin/env bash
# Sync plan — render the sync plan and verify prompt

# Show the sync plan for all repos.
# Usage: show_sync_plan <session_name> <target_branch> <result_dir> [repo_filter]
show_sync_plan() {
    local session_name="$1"
    local target_branch="$2"
    local result_dir="$3"
    local repo_filter="${4:-}"

    local _skip=0 _pull=0 _push=0 _reconcile=0 _warn=0 _clone=0

    _rule "sync: ${session_name} ↔ ${target_branch}"
    echo ""

    # Collect repos from result files
    local -a _repos=()
    for _sf in "$result_dir"/*; do
        [[ -f "$_sf" ]] || continue
        local _name
        _name=$(grep "^repo_name=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
        [[ -z "$_name" ]] && continue
        repo_matches_filter "$_name" "$repo_filter" || continue
        _repos+=("$_name")
    done

    # Render each repo
    local _first=true
    for _repo in "${_repos[@]}"; do
        local _state _action _detail
        _state=$(_pull_result_get "$result_dir" "$_repo" "sync_state")
        _action=$(_pull_result_get "$result_dir" "$_repo" "sync_action")
        _detail=$(_pull_result_get "$result_dir" "$_repo" "sync_detail")

        # Build hash line
        local _c_head _s_head _t_head
        _c_head=$(_pull_result_get "$result_dir" "$_repo" "container_head")
        _s_head=$(_pull_result_get "$result_dir" "$_repo" "session_head")
        _t_head=$(_pull_result_get "$result_dir" "$_repo" "target_head")

        # Resolve display path
        local _host_path _rel_path
        _host_path=$(_pull_result_get "$result_dir" "$_repo" "host_path")
        _rel_path="${_repo##*/}"
        if [[ -n "$_host_path" ]]; then
            _rel_path=$(python3 -c "import os; print(os.path.relpath('$_host_path', '$(pwd)'))" 2>/dev/null || echo "${_host_path/#$HOME/~}")
        fi

        case "$_action" in
            skip)
                case "$_state" in
                    identical|squash_identical)
                        _skip=$((_skip + 1))
                        # Only show if repo filter is active
                        if [[ -n "$repo_filter" ]]; then
                            echo -e "  ${GREEN}✓${NC} ${_rel_path} — ${_detail}"
                            [[ -n "$_c_head" ]] && echo -e "    ${DIM}container:${_c_head:0:7}  ${target_branch}:${_t_head:0:7}${NC}"
                        fi
                        ;;
                    discovered)
                        echo -e "  ${YELLOW}○${NC} ${_rel_path} — ${_detail}"
                        _skip=$((_skip + 1))
                        ;;
                esac
                ;;
            pull)
                echo -e "  ${BLUE}←${NC} ${_rel_path} — ${_detail}"
                echo -e "    ${DIM}container:${_c_head:0:7}  ${target_branch}:${_t_head:0:7}${NC}"
                local _diff
                _diff=$(snapshot_diff "$result_dir" "$_repo" "outbound" "summary")
                [[ -n "$_diff" ]] && echo -e "    ${DIM}${_diff}${NC}"
                _pull=$((_pull + 1))
                ;;
            push)
                echo -e "  ${BLUE}→${NC} ${_rel_path} — ${_detail}"
                echo -e "    ${DIM}container:${_c_head:0:7}  ${target_branch}:${_t_head:0:7}${NC}"
                local _diff
                _diff=$(snapshot_diff "$result_dir" "$_repo" "inbound" "summary")
                [[ -n "$_diff" ]] && echo -e "    ${DIM}${_diff}${NC}"
                _push=$((_push + 1))
                ;;
            reconcile)
                echo -e "  ${YELLOW}↔${NC} ${_rel_path} — ${_detail}"
                echo -e "    ${DIM}container:${_c_head:0:7}  ${target_branch}:${_t_head:0:7}${NC}"
                local _out_diff _in_diff
                _out_diff=$(snapshot_diff "$result_dir" "$_repo" "outbound" "summary")
                _in_diff=$(snapshot_diff "$result_dir" "$_repo" "inbound" "summary")
                [[ -n "$_out_diff" ]] && echo -e "    ${DIM}session → ${target_branch}: ${_out_diff}${NC}"
                [[ -n "$_in_diff" ]] && echo -e "    ${DIM}${target_branch} → session: ${_in_diff}${NC}"
                _reconcile=$((_reconcile + 1))
                ;;
            warn)
                echo -e "  ${YELLOW}!${NC} ${_rel_path} — ${_detail}"
                [[ -n "$_c_head" ]] && echo -e "    ${DIM}container:${_c_head:0:7}${NC}"
                _warn=$((_warn + 1))
                ;;
            clone_from_container)
                echo -e "  ${BLUE}←${NC} ${_rel_path} — ${_detail}"
                _clone=$((_clone + 1))
                ;;
            push_to_container)
                echo -e "  ${BLUE}→${NC} ${_rel_path} — ${_detail}"
                _push=$((_push + 1))
                ;;
        esac
    done

    # Footer
    echo ""
    _rule

    [[ $_skip -gt 0 ]] && echo -e "${DIM}${_skip} already synced${NC}"

    local _parts=()
    [[ $_pull -gt 0 ]] && _parts+=("${_pull} to pull")
    [[ $_push -gt 0 ]] && _parts+=("${_push} to push")
    [[ $_reconcile -gt 0 ]] && _parts+=("${_reconcile} to reconcile")
    [[ $_clone -gt 0 ]] && _parts+=("${_clone} to clone")
    [[ $_warn -gt 0 ]] && _parts+=("${_warn} warning(s)")

    if [[ ${#_parts[@]} -gt 0 ]]; then
        local _line
        _line=$(IFS=', '; echo "${_parts[*]}")
        if [[ $_reconcile -gt 0 || $_warn -gt 0 ]]; then
            warn "$_line"
        else
            info "$_line"
        fi
    else
        success "Everything in sync"
    fi

    # Export counts for caller
    _SYNC_PULL=$_pull
    _SYNC_PUSH=$_push
    _SYNC_RECONCILE=$_reconcile
    _SYNC_WARN=$_warn
    _SYNC_CLONE=$_clone
    _SYNC_TOTAL=$((_pull + _push + _reconcile + _clone))
}
