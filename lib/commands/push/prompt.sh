#!/usr/bin/env bash
# Push discuss prompt — generates plain-text prompt for Claude discussion
# Own prompt for push direction: "merging host main into session"

# Generate a plain-text prompt summarizing push state for discussion with Claude.
# Usage: _push_discuss_prompt <session_name> <source_branch> <result_dir> [repo_filter]
# Output: writes prompt text to stdout
_push_discuss_prompt() {
    local session_name="$1"
    local source_branch="$2"
    local result_dir="$3"
    local repo_filter="${4:-}"
    local volume="claude-session-${session_name}"

    local config_content projects
    config_content=$(read_session_config "$volume")
    projects=""
    [[ -n "$config_content" ]] && projects=$(parse_session_projects "$config_content")
    [[ -n "$repo_filter" ]] && projects=$(augment_projects_from_volume "$volume" "$projects" "$repo_filter")

    local prompt=""
    prompt+="You are reviewing a claude-container push operation."
    prompt+=$'\n'"Session: $session_name"
    prompt+=$'\n'"Direction: merging host '$source_branch' INTO the container session"
    prompt+=$'\n'"This brings upstream changes from the host into the agent's working environment."
    prompt+=$'\n'
    prompt+=$'\n'"Here is the current state of each repo:"
    prompt+=$'\n'

    # Use snapshot for session state
    local _prompt_snap_dir
    _prompt_snap_dir=$(mktemp -d)
    snapshot_session_state "$volume" "$session_name" "$source_branch" "$_prompt_snap_dir" "$repo_filter"

    local _active_count=0

    if [[ -n "$projects" ]]; then
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_pname" ]] && continue
            repo_matches_filter "$_pname" "$repo_filter" || continue

            # Read from snapshot
            local _s_head _s_dirty _s_merging
            _s_head=$(_pull_result_get "$_prompt_snap_dir" "$_pname" "container_head")
            _s_dirty=$(_pull_result_get "$_prompt_snap_dir" "$_pname" "dirty_count")
            _s_merging=$(_pull_result_get "$_prompt_snap_dir" "$_pname" "merging")

            # Check if host has commits session doesn't
            local _host_ahead=0
            if [[ -d "$_ppath" ]] && git -C "$_ppath" show-ref --verify --quiet "refs/heads/$source_branch" 2>/dev/null; then
                _host_ahead=$(git -C "$_ppath" rev-list --count "$session_name".."$source_branch" 2>/dev/null || echo "0")
            fi

            # Skip repos where host has nothing new and session is clean
            if [[ "$_host_ahead" -eq 0 ]] && \
               [[ "${_s_dirty:-0}" -eq 0 ]] && \
               [[ "${_s_merging:-no}" == "no" ]]; then
                continue
            fi

            _active_count=$((_active_count + 1))
            prompt+=$'\n'"## $_pname"
            prompt+=$'\n'"  session HEAD: ${_s_head:0:7}"

            if [[ "${_s_merging:-no}" == "yes" ]]; then
                prompt+=$'\n'"  WARNING: merge already in progress in session"
            fi
            if [[ "${_s_dirty:-0}" -gt 0 ]]; then
                prompt+=$'\n'"  WARNING: ${_s_dirty} uncommitted file(s) in session"
            fi

            if [[ "$_host_ahead" -gt 0 && -d "$_ppath" ]]; then
                prompt+=$'\n'"  host '$source_branch' has $_host_ahead commit(s) to merge:"
                local _log
                _log=$(git -C "$_ppath" log --oneline "$session_name".."$source_branch" 2>/dev/null | head -10)
                [[ -n "$_log" ]] && prompt+=$'\n'"$(echo "$_log" | sed 's/^/    /')"

                local _stat
                _stat=$(snapshot_diff "$_prompt_snap_dir" "$_pname" "inbound" "stat")
                [[ -n "$_stat" ]] && prompt+=$'\n'"  diff:"$'\n'"$(echo "$_stat" | sed 's/^/    /')"
            elif [[ "$_host_ahead" -eq 0 ]]; then
                prompt+=$'\n'"  host '$source_branch': up to date with session"
            fi
        done <<< "$projects"
    fi

    rm -rf "$_prompt_snap_dir"

    if [[ $_active_count -eq 0 ]]; then
        prompt+=$'\n'"All repos are up to date — nothing to push."
    fi

    prompt+=$'\n'
    prompt+=$'\n'"The user wants to discuss this state before deciding whether to proceed."
    prompt+=$'\n'"Help them understand:"
    prompt+=$'\n'"- What changes from '$source_branch' will be merged into the session"
    prompt+=$'\n'"- Whether there are potential conflicts with in-progress session work"
    prompt+=$'\n'"- Any risks of merging host changes into the agent's environment"

    echo "$prompt"
}
