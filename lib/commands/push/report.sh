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
        success "Done — session '$session_name' merged from '$source_branch'"
        return 0
    fi

    local projects
    projects=$(parse_session_projects "$config_content")
    [[ -n "$repo_filter" ]] && projects=$(augment_projects_from_volume "$volume" "$projects" "$repo_filter")

    # Get post-merge session state
    local _util_image="${GIT_UTIL_IMAGE:-alpine/git}"
    local _post_scan
    _post_scan=$(docker run --rm --entrypoint sh \
        -e HOME=/tmp \
        -v "$volume:/session:ro" "$_util_image" \
        -c '
            git config --global --add safe.directory "*"
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"; name="${name%/}"
                head=$(cd "$d" && git rev-parse --short HEAD 2>/dev/null)
                echo "$name|$head"
            done
        ' 2>/dev/null) || true

    declare -A _post_heads
    while IFS='|' read -r _sn _sh; do
        [[ -z "$_sn" ]] && continue
        _post_heads[$_sn]="$_sh"
    done <<< "$_post_scan"

    # Check each repo: is host branch now an ancestor of session HEAD?
    local _merged=0 _skipped=0 _up_to_date=0

    echo ""
    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        repo_matches_filter "$proj_name" "$repo_filter" || continue
        [[ ! -d "$proj_path" ]] && continue

        local _host_head
        _host_head=$(git -C "$proj_path" rev-parse "refs/heads/$source_branch" 2>/dev/null || echo "")
        [[ -z "$_host_head" ]] && continue

        local _post_head="${_post_heads[$proj_name]:-}"
        [[ -z "$_post_head" ]] && continue

        # Check ancestry: is host branch HEAD now in session?
        local _still_ahead
        _still_ahead=$(git -C "$proj_path" rev-list --count "$session_name".."$source_branch" 2>/dev/null || echo "0")

        if [[ "$_still_ahead" -eq 0 ]]; then
            echo -e "  ${GREEN}✓${NC} $proj_name  ${DIM}session:${_post_head}${NC}"
            _merged=$((_merged + 1))
        else
            echo -e "  ${DIM}·${NC} $proj_name  ${DIM}$_still_ahead commit(s) still ahead${NC}"
            _skipped=$((_skipped + 1))
        fi
    done <<< "$projects"

    # Extract silently to sync host session branches
    session_extract "$session_name" --force > /dev/null 2>&1

    # Summary
    echo ""
    if [[ $_skipped -eq 0 ]]; then
        success "Done — session '$session_name' merged from '$source_branch'"
    else
        warn "Merged with issues — $_skipped repo(s) may need attention"
    fi
}
