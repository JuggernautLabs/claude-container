#!/usr/bin/env bash
# Push report — post-merge report showing what was merged

# Post-merge report for push operations
# Usage: _push_report <session_name> <source_branch> [repo_filter]
_push_report() {
    local session_name="$1"
    local source_branch="$2"
    local repo_filter="${3:-}"
    local volume="claude-session-${session_name}"

    local config_content
    config_content=$(read_session_config "$volume")
    if [[ -z "$config_content" ]]; then
        echo ""
        _rule "push: ${source_branch} → ${session_name}"
        success "Done"
        return 0
    fi

    local projects
    projects=$(parse_session_projects "$config_content")
    [[ -n "$repo_filter" ]] && projects=$(augment_projects_from_volume "$volume" "$projects" "$repo_filter")

    # Get post-merge session state via snapshot
    local _post_snap_dir
    _post_snap_dir=$(mktemp -d)
    snapshot_session_state "$volume" "$session_name" "$source_branch" "$_post_snap_dir" "$repo_filter"

    # Check each repo: is host branch now an ancestor of session HEAD?
    local _merged=0 _skipped=0

    echo ""
    _rule "push: ${source_branch} → ${session_name}"
    echo ""

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        repo_matches_filter "$proj_name" "$repo_filter" || continue
        [[ ! -d "$proj_path" ]] && continue

        local _host_head
        _host_head=$(git -C "$proj_path" rev-parse "refs/heads/$source_branch" 2>/dev/null || echo "")
        [[ -z "$_host_head" ]] && continue

        local _post_head
        _post_head=$(_pull_result_get "$_post_snap_dir" "$proj_name" "container_head")
        [[ -z "$_post_head" ]] && continue
        local _post_short="${_post_head:0:7}"

        # Check ancestry: is host branch HEAD now in session?
        local _still_ahead
        _still_ahead=$(git -C "$proj_path" rev-list --count "$session_name".."$source_branch" 2>/dev/null || echo "0")

        if [[ "$_still_ahead" -eq 0 ]]; then
            echo -e "  ${GREEN}✓${NC} $proj_name  ${DIM}session:${_post_short}${NC}"
            _merged=$((_merged + 1))
        else
            echo -e "  ${DIM}·${NC} $proj_name  ${DIM}${_still_ahead} still ahead${NC}"
            _skipped=$((_skipped + 1))
        fi
    done <<< "$projects"

    rm -rf "$_post_snap_dir"

    # Extract silently to sync host session branches
    session_extract "$session_name" --force > /dev/null 2>&1

    # Footer
    echo ""
    _rule
    if [[ $_skipped -eq 0 ]]; then
        success "$_merged merged from ${source_branch}"
    else
        warn "Merged with issues — $_skipped repo(s) may need attention"
    fi
}
