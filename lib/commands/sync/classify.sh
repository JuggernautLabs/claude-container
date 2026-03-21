#!/usr/bin/env bash
# Sync classification — determine per-repo sync state from snapshot

# Classify one repo's sync state from snapshot data.
# Writes sync_state and sync_action to the result dir.
#
# Usage: classify_repo_sync_state <result_dir> <repo_name> <session_name> <target_branch>
#
# Result keys written:
#   sync_state   = identical | container_ahead | host_ahead | diverged |
#                  squash_identical | container_only | host_only |
#                  container_dirty | host_dirty
#   sync_action  = skip | pull | push | reconcile | clone_from_container |
#                  push_to_container | warn
#   sync_detail  = human-readable explanation
classify_repo_sync_state() {
    local result_dir="$1"
    local repo_name="$2"
    local session_name="$3"
    local target_branch="$4"

    local _c_head _s_head _t_head _dirty _merging _host_dirty
    local _container_known _container_in_target _ext_ahead _host_path _extract_en
    _c_head=$(_pull_result_get "$result_dir" "$repo_name" "container_head")
    _s_head=$(_pull_result_get "$result_dir" "$repo_name" "session_head")
    _t_head=$(_pull_result_get "$result_dir" "$repo_name" "target_head")
    _dirty=$(_pull_result_get "$result_dir" "$repo_name" "dirty_count")
    _merging=$(_pull_result_get "$result_dir" "$repo_name" "merging")
    _host_dirty=$(_pull_result_get "$result_dir" "$repo_name" "host_dirty")
    _container_known=$(_pull_result_get "$result_dir" "$repo_name" "container_known")
    _container_in_target=$(_pull_result_get "$result_dir" "$repo_name" "container_in_target")
    _ext_ahead=$(_pull_result_get "$result_dir" "$repo_name" "external_ahead")
    _host_path=$(_pull_result_get "$result_dir" "$repo_name" "host_path")
    _extract_en=$(_pull_result_get "$result_dir" "$repo_name" "extract_enabled")

    _sync_write() {
        _pull_result_set "$result_dir" "$repo_name" "sync_state" "$1"
        _pull_result_set "$result_dir" "$repo_name" "sync_action" "$2"
        _pull_result_set "$result_dir" "$repo_name" "sync_detail" "$3"
    }

    # Extract disabled — discovered repo
    if [[ "$_extract_en" == "false" ]]; then
        _sync_write "discovered" "skip" "extract: false (use pull --extract to enable)"
        return 0
    fi

    # Container dirty — can't sync safely
    if [[ "${_dirty:-0}" -gt 0 ]]; then
        _sync_write "container_dirty" "warn" "$_dirty uncommitted file(s) in container"
        return 0
    fi

    # Merge in progress in container
    if [[ "${_merging:-no}" == "yes" ]]; then
        _sync_write "container_dirty" "warn" "merge in progress in container"
        return 0
    fi

    # Host dirty — can't merge into target
    if [[ "${_host_dirty}" == "true" ]]; then
        _sync_write "host_dirty" "warn" "host has uncommitted changes"
        return 0
    fi

    # No container HEAD — repo only on host
    if [[ -z "$_c_head" ]]; then
        _sync_write "host_only" "push_to_container" "repo exists on host but not in container"
        return 0
    fi

    # No host path — repo only in container
    if [[ -z "$_host_path" || ! -d "$_host_path" ]]; then
        _sync_write "container_only" "clone_from_container" "repo in container, no host path"
        return 0
    fi

    # Both exist — compare HEADs
    # First: does container HEAD match host target branch?
    if [[ -n "$_t_head" && "$_c_head" == "$_t_head" ]]; then
        _sync_write "identical" "skip" "container and $target_branch are identical"
        return 0
    fi

    # Container HEAD matches session branch (and session == target, or no session branch)
    if [[ -n "$_s_head" && "$_c_head" == "$_s_head" && -n "$_t_head" ]]; then
        # Session is synced with container. Check session vs target.
        if git -C "$_host_path" merge-base --is-ancestor "$_s_head" "$_t_head" 2>/dev/null; then
            # Session is ancestor of target — host is ahead
            local _h_count
            _h_count=$(git -C "$_host_path" rev-list --count "$_s_head".."$_t_head" 2>/dev/null || echo "?")
            # But are those "ahead" commits just our squash-merges?
            if [[ "${_ext_ahead:-0}" -eq 0 && "$_h_count" != "0" ]]; then
                # All ahead commits are squash-merges — content may be identical
                if git -C "$_host_path" diff --quiet "$_s_head" "$_t_head" -- 2>/dev/null; then
                    _sync_write "squash_identical" "skip" "content identical (squash history differs)"
                else
                    _sync_write "host_ahead" "push" "$_h_count commit(s) on $target_branch not in session (squash + new work)"
                fi
            elif [[ "$_h_count" == "0" ]]; then
                _sync_write "identical" "skip" "session and $target_branch at same commit"
            else
                _sync_write "host_ahead" "push" "$_h_count commit(s) on $target_branch not in session"
            fi
            return 0
        elif git -C "$_host_path" merge-base --is-ancestor "$_t_head" "$_s_head" 2>/dev/null; then
            # Target is ancestor of session — container is ahead
            local _c_count
            _c_count=$(git -C "$_host_path" rev-list --count "$_t_head".."$_s_head" 2>/dev/null || echo "?")
            _sync_write "container_ahead" "pull" "$_c_count commit(s) in session not in $target_branch"
            return 0
        fi
    fi

    # Container HEAD not known on host — definitely has new work
    if [[ "$_container_known" != "true" ]]; then
        if [[ -z "$_s_head" ]]; then
            _sync_write "container_ahead" "pull" "container has work not yet extracted"
        else
            _sync_write "container_ahead" "pull" "container has new commits (not on host)"
        fi
        return 0
    fi

    # Both known — check ancestry
    local _compare_target="${_t_head:-$_s_head}"
    [[ -z "$_compare_target" ]] && { _sync_write "container_ahead" "pull" "no target branch to compare"; return 0; }

    if git -C "$_host_path" merge-base --is-ancestor "$_compare_target" "$_c_head" 2>/dev/null; then
        # Target is ancestor of container — container ahead
        local _ahead
        _ahead=$(git -C "$_host_path" rev-list --count "$_compare_target".."$_c_head" 2>/dev/null || echo "?")
        _sync_write "container_ahead" "pull" "$_ahead commit(s) ahead of $target_branch"
        return 0
    fi

    if git -C "$_host_path" merge-base --is-ancestor "$_c_head" "$_compare_target" 2>/dev/null; then
        # Container is ancestor of target — host ahead
        local _ahead
        _ahead=$(git -C "$_host_path" rev-list --count "$_c_head".."$_compare_target" 2>/dev/null || echo "?")
        # Check if all ahead commits are squash-merges
        if [[ "${_ext_ahead:-0}" -eq 0 ]]; then
            if git -C "$_host_path" diff --quiet "$_c_head" "$_compare_target" -- 2>/dev/null; then
                _sync_write "squash_identical" "skip" "content identical (squash history differs)"
            else
                _sync_write "host_ahead" "push" "$_ahead commit(s) on $target_branch (squash + new work)"
            fi
        else
            _sync_write "host_ahead" "push" "$_ahead commit(s) on $target_branch not in container"
        fi
        return 0
    fi

    # Neither is ancestor — true divergence
    # Check if content is actually identical despite diverged history
    if git -C "$_host_path" diff --quiet "$_c_head" "$_compare_target" -- 2>/dev/null; then
        _sync_write "squash_identical" "skip" "content identical (histories diverged)"
        return 0
    fi

    # Real divergence with content differences
    local _merge_base
    _merge_base=$(git -C "$_host_path" merge-base "$_c_head" "$_compare_target" 2>/dev/null || echo "")
    local _c_ahead="?" _h_ahead="?"
    if [[ -n "$_merge_base" ]]; then
        _c_ahead=$(git -C "$_host_path" rev-list --count "$_merge_base".."$_c_head" 2>/dev/null || echo "?")
        _h_ahead=$(git -C "$_host_path" rev-list --count "$_merge_base".."$_compare_target" 2>/dev/null || echo "?")
    fi
    _sync_write "diverged" "reconcile" "container +${_c_ahead}, $target_branch +${_h_ahead}"
}
