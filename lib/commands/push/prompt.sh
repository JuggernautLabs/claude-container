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

    local prompt=""
    prompt+="You are reviewing a claude-container push operation."
    prompt+=$'\n'"Session: $session_name"
    prompt+=$'\n'"Direction: merging host '$source_branch' INTO the container session"
    prompt+=$'\n'"This brings upstream changes from the host into the agent's working environment."
    prompt+=$'\n'
    prompt+=$'\n'"Here is the current state of each repo:"
    prompt+=$'\n'

    # Scan session for current state
    local _util_image="${GIT_UTIL_IMAGE:-alpine/git}"
    local _scan
    _scan=$(docker run --rm --entrypoint sh \
        -e HOME=/tmp \
        -v "$volume:/session:ro" "$_util_image" \
        -c '
            git config --global --add safe.directory "*"
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"; name="${name%/}"
                head=$(cd "$d" && git rev-parse --short HEAD 2>/dev/null)
                dirty=$(cd "$d" && git status --porcelain 2>/dev/null | wc -l | tr -d " ")
                merging="no"
                [ -f "$d/.git/MERGE_HEAD" ] && merging="yes"
                echo "$name|$head|$dirty|$merging"
            done
        ' 2>/dev/null) || true

    declare -A _session_heads _session_dirty _session_merging
    while IFS='|' read -r _sn _sh _sd _sm; do
        [[ -z "$_sn" ]] && continue
        _session_heads[$_sn]="$_sh"
        _session_dirty[$_sn]="${_sd:-0}"
        _session_merging[$_sn]="$_sm"
    done <<< "$_scan"

    local _active_count=0

    if [[ -n "$projects" ]]; then
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_pname" ]] && continue
            repo_matches_filter "$_pname" "$repo_filter" || continue

            # Check if host has commits session doesn't
            local _host_ahead=0
            if [[ -d "$_ppath" ]] && git -C "$_ppath" show-ref --verify --quiet "refs/heads/$source_branch" 2>/dev/null; then
                _host_ahead=$(git -C "$_ppath" rev-list --count "$session_name".."$source_branch" 2>/dev/null || echo "0")
            fi

            # Skip repos where host has nothing new and session is clean
            if [[ "$_host_ahead" -eq 0 ]] && \
               [[ "${_session_dirty[$_pname]:-0}" -eq 0 ]] && \
               [[ "${_session_merging[$_pname]:-no}" == "no" ]]; then
                continue
            fi

            _active_count=$((_active_count + 1))
            prompt+=$'\n'"## $_pname"
            prompt+=$'\n'"  session HEAD: ${_session_heads[$_pname]:-unknown}"

            if [[ "${_session_merging[$_pname]:-no}" == "yes" ]]; then
                prompt+=$'\n'"  WARNING: merge already in progress in session"
            fi
            if [[ "${_session_dirty[$_pname]:-0}" -gt 0 ]]; then
                prompt+=$'\n'"  WARNING: ${_session_dirty[$_pname]} uncommitted file(s) in session"
            fi

            if [[ "$_host_ahead" -gt 0 && -d "$_ppath" ]]; then
                prompt+=$'\n'"  host '$source_branch' has $_host_ahead commit(s) to merge:"
                local _log
                _log=$(git -C "$_ppath" log --oneline "$session_name".."$source_branch" 2>/dev/null | head -10)
                [[ -n "$_log" ]] && prompt+=$'\n'"$(echo "$_log" | sed 's/^/    /')"

                local _stat
                _stat=$(git -C "$_ppath" diff --stat "$session_name".."$source_branch" 2>/dev/null)
                [[ -n "$_stat" ]] && prompt+=$'\n'"  diff:"$'\n'"$(echo "$_stat" | sed 's/^/    /')"
            elif [[ "$_host_ahead" -eq 0 ]]; then
                prompt+=$'\n'"  host '$source_branch': up to date with session"
            fi
        done <<< "$projects"
    fi

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
