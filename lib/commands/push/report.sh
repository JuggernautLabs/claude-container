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

    # Extract first so host session branches reflect the merge result
    session_extract "$session_name" --force > /dev/null 2>&1 || true

    # Snapshot AFTER extract — now host session branches are current
    local _post_snap_dir
    _post_snap_dir=$(mktemp -d)
    snapshot_session_state "$volume" "$session_name" "$source_branch" "$_post_snap_dir" "$repo_filter"

    local _merged=0 _still_diverged=0

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

        local _post_head _post_session
        _post_head=$(_pull_result_get "$_post_snap_dir" "$proj_name" "container_head")
        _post_session=$(_pull_result_get "$_post_snap_dir" "$proj_name" "session_head")
        [[ -z "$_post_head" ]] && continue
        local _post_short="${_post_head:0:7}"

        # Check: does the container now have main's content?
        local _container_known
        _container_known=$(_pull_result_get "$_post_snap_dir" "$proj_name" "container_known")
        if [[ "$_container_known" == "true" ]] && git -C "$proj_path" merge-base --is-ancestor "$_host_head" "$_post_head" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $proj_name  ${DIM}session:${_post_short}${NC}"
            _merged=$((_merged + 1))
        elif [[ "$_post_head" == "$_host_head" ]] || [[ "$_post_session" == "$_host_head" ]]; then
            echo -e "  ${GREEN}✓${NC} $proj_name  ${DIM}session:${_post_short}${NC}"
            _merged=$((_merged + 1))
        else
            echo -e "  ${DIM}·${NC} $proj_name  ${DIM}still diverged${NC}"
            _still_diverged=$((_still_diverged + 1))
        fi
    done <<< "$projects"

    rm -rf "$_post_snap_dir"

    # Footer
    echo ""
    _rule
    if [[ $_still_diverged -eq 0 ]]; then
        success "$_merged merged from ${source_branch}"
    else
        warn "$_merged merged, $_still_diverged still diverged"
        echo -e "${DIM}Diverged repos: container has merged content but history differs from host.${NC}"
        echo -e "${DIM}Run 'pull -s $session_name $source_branch' to sync back to host.${NC}"
    fi
}
