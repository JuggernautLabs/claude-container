#!/usr/bin/env bash
# Pull discuss prompt — generates plain-text prompt for Claude discussion

# Generate a plain-text prompt summarizing pull state for discussion with Claude.
# Reads from the same result dir as _pull_report.
# Usage: _pull_discuss_prompt <session_name> <target_branch> <result_dir> [repo_filter]
# Output: writes prompt text to stdout
_pull_discuss_prompt() {
    local session_name="$1"
    local target_branch="$2"
    local result_dir="$3"
    local repo_filter="${4:-}"
    local volume="claude-session-${session_name}"

    local config_content projects
    config_content=$(read_session_config "$volume")
    projects=""
    [[ -n "$config_content" ]] && projects=$(parse_session_projects "$config_content")

    local prompt=""
    prompt+="You are reviewing a claude-container session merge."
    prompt+=$'\n'"Session: $session_name"
    prompt+=$'\n'"Direction: merging session into host '$target_branch'"
    prompt+=$'\n'
    prompt+=$'\n'"Here is the current state of each repo that needs attention:"
    prompt+=$'\n'

    # Collect repo names from result files
    local -a _repo_names=()
    local -A _repo_seen=()
    if [[ -n "$projects" ]]; then
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_pname" ]] && continue
            repo_matches_filter "$_pname" "$repo_filter" || continue
            local _rfile="${result_dir}/${_pname//\//_}"
            [[ -f "$_rfile" ]] && _repo_names+=("$_pname") && _repo_seen[$_pname]=1
        done <<< "$projects"
    fi

    local _active_count=0

    for _repo in "${_repo_names[@]}"; do
        local _ext_status _merge_status _merge_detail _conflict_files _target_ahead
        _ext_status=$(_pull_result_get "$result_dir" "$_repo" "extract_status")
        _merge_status=$(_pull_result_get "$result_dir" "$_repo" "merge_status")
        _merge_detail=$(_pull_result_get "$result_dir" "$_repo" "merge_detail")
        _conflict_files=$(_pull_result_get "$result_dir" "$_repo" "conflict_files")
        _target_ahead=$(_pull_result_get "$result_dir" "$_repo" "target_ahead")

        # Skip quiet repos (same logic as _pull_report)
        if [[ "$_ext_status" == "unchanged" || -z "$_ext_status" ]]; then
            case "$_merge_detail" in
                "already up to date"|"up to date"*)
                    local _has_ext=false
                    if [[ -n "$_target_ahead" && "$_target_ahead" != "0" ]]; then
                        local _dp_proj_path
                        _dp_proj_path=$(echo "$projects" | grep "^${_repo}|" | head -1 | cut -d'|' -f2)
                        if [[ -n "$_dp_proj_path" && -d "$_dp_proj_path" ]]; then
                            local _dp_log
                            _dp_log=$(git -C "$_dp_proj_path" log --oneline "$session_name".."$target_branch" 2>/dev/null | head -5)
                            while IFS= read -r _dp_line; do
                                [[ -z "$_dp_line" ]] && continue
                                echo "$_dp_line" | grep -qE "^[0-9a-f]+ ${session_name} → " || _has_ext=true
                            done <<< "$_dp_log"
                        fi
                    fi
                    $_has_ext || continue
                    ;;
                "") [[ -z "$_merge_status" ]] && continue ;;
            esac
        fi

        _active_count=$((_active_count + 1))
        local _proj_path
        _proj_path=$(echo "$projects" | grep "^${_repo}|" | head -1 | cut -d'|' -f2)

        prompt+=$'\n'"## $_repo"
        prompt+=$'\n'"  extract: ${_ext_status:-unchanged}"
        prompt+=$'\n'"  merge: ${_merge_status:-?} — ${_merge_detail:-?}"
        [[ -n "$_conflict_files" ]] && prompt+=$'\n'"  conflict files: $_conflict_files"

        # Inline diffstat (session -> target)
        if [[ -n "$_proj_path" && -d "$_proj_path" ]]; then
            local _ds
            _ds=$(git -C "$_proj_path" diff --stat "$target_branch".."$session_name" 2>/dev/null)
            [[ -n "$_ds" ]] && prompt+=$'\n'"  session → ${target_branch} diff:"$'\n'"$(echo "$_ds" | sed 's/^/    /')"
        fi

        # Target-ahead info
        if [[ -n "$_target_ahead" && "$_target_ahead" != "0" && -n "$_proj_path" && -d "$_proj_path" ]]; then
            prompt+=$'\n'"  ${target_branch} is ${_target_ahead} commit(s) ahead of session:"
            local _al
            _al=$(git -C "$_proj_path" log --oneline "$session_name".."$target_branch" 2>/dev/null | head -10)
            [[ -n "$_al" ]] && prompt+=$'\n'"$(echo "$_al" | sed 's/^/    /')"
            local _rs
            _rs=$(git -C "$_proj_path" diff --stat "$session_name".."$target_branch" 2>/dev/null)
            [[ -n "$_rs" ]] && prompt+=$'\n'"  ${target_branch}-only diff:"$'\n'"$(echo "$_rs" | sed 's/^/    /')"
        fi
    done

    if [[ $_active_count -eq 0 ]]; then
        prompt+=$'\n'"All repos are up to date — no modifications needed."
    fi

    prompt+=$'\n'
    prompt+=$'\n'"The user wants to discuss this state before deciding whether to proceed."
    prompt+=$'\n'"Help them understand what would happen if they merge, what risks exist,"
    prompt+=$'\n'"and answer any questions about the differences between session and target."

    echo "$prompt"
}
