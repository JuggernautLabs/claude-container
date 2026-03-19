#!/usr/bin/env bash
# Pull preview functions: status check and diffstat verification

# Read-only status check — compares container HEADs vs host without extracting
# Usage: _pull_status <session_name> [repo_filter]
_pull_status() {
    local session_name="$1"
    local repo_filter="${2:-}"
    local volume="claude-session-${session_name}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    # Get container HEADs (single docker run)
    local _session_heads
    _session_heads=$(get_session_heads "$volume")

    if [[ -z "$_session_heads" ]]; then
        info "No repos found in session"
        return 0
    fi

    # Read config for project list and paths
    local config_content
    config_content=$(read_session_config "$volume")
    local projects=""
    if [[ -n "$config_content" ]] && command -v yq &>/dev/null; then
        projects=$(parse_session_projects "$config_content")
    fi
    [[ -n "$repo_filter" ]] && projects=$(augment_projects_from_volume "$volume" "$projects" "$repo_filter")

    # Build session HEAD lookup
    declare -A _head_map
    while IFS='|' read -r _sname _shead; do
        [[ -z "$_sname" ]] && continue
        _head_map[$_sname]="$_shead"
    done <<< "$_session_heads"

    local _up_to_date=0 _changed=0 _diverged=0 _not_extracted=0

    # Iterate repos
    local -a _repos_to_check=()
    if [[ -n "$projects" ]]; then
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_pname" ]] && continue
            _repos_to_check+=("$_pname|$_ppath")
        done <<< "$projects"
    fi
    # Also check session repos not in config
    for _sname in "${!_head_map[@]}"; do
        local _found=false
        for _entry in "${_repos_to_check[@]}"; do
            [[ "${_entry%%|*}" == "$_sname" ]] && _found=true && break
        done
        if ! $_found; then
            local _host_path=""
            if [[ -n "$projects" ]]; then
                _host_path=$(resolve_repo_host_path "$_sname" "$projects")
            fi
            _repos_to_check+=("$_sname|$_host_path")
        fi
    done

    # Header
    _rule "status: ${session_name}"
    echo ""

    local _first_repo=true

    for _entry in "${_repos_to_check[@]}"; do
        local _name="${_entry%%|*}"
        local _path="${_entry#*|}"

        # Apply repo filter
        if [[ -n "$repo_filter" ]]; then
            [[ "$_name" != *"$repo_filter"* ]] && continue
        fi

        local _s_head="${_head_map[$_name]:-}"
        if [[ -z "$_s_head" ]]; then
            continue  # repo not in container
        fi

        local _short_c="${_s_head:0:7}"

        if [[ -z "$_path" || ! -d "$_path" ]]; then
            $_first_repo || echo ""
            _first_repo=false
            echo -e "  ${BLUE}$_name${NC}"
            echo -e "    ${DIM}container:${_short_c}${NC}"
            echo -e "    ${YELLOW}!${NC} host path missing"
            _not_extracted=$((_not_extracted + 1))
            continue
        fi

        # Compare with host session branch
        local _h_head=""
        if git -C "$_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
            _h_head=$(git -C "$_path" rev-parse "refs/heads/$session_name" 2>/dev/null)
        fi

        # Also show target branch HEAD if it exists
        local _t_head=""
        _t_head=$(git -C "$_path" rev-parse "refs/heads/main" 2>/dev/null || echo "")

        # Blank line between repos
        $_first_repo || echo ""
        _first_repo=false

        # Repo name
        echo -e "  ${BLUE}$_name${NC}"

        # Hashes on their own dim line
        local _hash_parts=()
        _hash_parts+=("container:${_short_c}")
        [[ -n "$_h_head" ]] && _hash_parts+=("session:${_h_head:0:7}")
        [[ -n "$_t_head" ]] && _hash_parts+=("main:${_t_head:0:7}")
        echo -e "    ${DIM}${_hash_parts[*]}${NC}"

        if [[ -z "$_h_head" ]]; then
            echo -e "    ${YELLOW}!${NC} not yet extracted"
            _not_extracted=$((_not_extracted + 1))
        elif [[ "$_s_head" == "$_h_head" ]]; then
            echo -e "    ${GREEN}✓${NC} up to date"
            _up_to_date=$((_up_to_date + 1))
        elif git -C "$_path" merge-base --is-ancestor "$_h_head" "$_s_head" 2>/dev/null; then
            local _ahead
            _ahead=$(git -C "$_path" rev-list --count "$_h_head".."$_s_head" 2>/dev/null || echo "?")
            echo -e "    ${BLUE}→${NC} container ahead by $_ahead commit(s)"
            _changed=$((_changed + 1))
        elif git -C "$_path" merge-base --is-ancestor "$_s_head" "$_h_head" 2>/dev/null; then
            local _ahead
            _ahead=$(git -C "$_path" rev-list --count "$_s_head".."$_h_head" 2>/dev/null || echo "?")
            echo -e "    ${DIM}← host ahead by $_ahead commit(s)${NC}"
            _changed=$((_changed + 1))
        else
            local _merge_base
            _merge_base=$(git -C "$_path" merge-base "$_h_head" "$_s_head" 2>/dev/null || echo "")
            local _c_ahead=0 _h_ahead=0
            if [[ -n "$_merge_base" ]]; then
                _c_ahead=$(git -C "$_path" rev-list --count "$_merge_base".."$_s_head" 2>/dev/null || echo "?")
                _h_ahead=$(git -C "$_path" rev-list --count "$_merge_base".."$_h_head" 2>/dev/null || echo "?")
            fi
            echo -e "    ${YELLOW}!${NC} diverged (container +${_c_ahead}, host +${_h_ahead})"
            _diverged=$((_diverged + 1))
        fi
    done

    # Footer
    echo ""
    _rule

    local _parts=()
    [[ $_up_to_date -gt 0 ]] && _parts+=("${_up_to_date} up to date")
    [[ $_changed -gt 0 ]] && _parts+=("${_changed} changed")
    [[ $_diverged -gt 0 ]] && _parts+=("${_diverged} diverged")
    [[ $_not_extracted -gt 0 ]] && _parts+=("${_not_extracted} not extracted")

    if [[ ${#_parts[@]} -gt 0 ]]; then
        local _line
        _line=$(IFS=', '; echo "${_parts[*]}")
        if [[ $_diverged -eq 0 && $_not_extracted -eq 0 ]]; then
            success "$_line"
        else
            warn "$_line"
        fi
    fi
}

# Show per-repo diffstat of session vs target branch for --verify
_verify_diffstat() {
    local session_name="$1"
    local target_branch="$2"
    local result_dir="$3"
    local repo_filter="${4:-}"
    local volume="claude-session-${session_name}"

    local config_content
    config_content=$(read_session_config "$volume")
    local projects=""
    if [[ -n "$config_content" ]]; then
        projects=$(parse_session_projects "$config_content")
    fi
    [[ -n "$repo_filter" ]] && projects=$(augment_projects_from_volume "$volume" "$projects" "$repo_filter")

    local _total_files=0 _total_adds=0 _total_dels=0
    local _shown=0

    while IFS='|' read -r _pname _ppath; do
        [[ -z "$_pname" ]] && continue
        repo_matches_filter "$_pname" "$repo_filter" || continue
        [[ ! -d "$_ppath" ]] && continue

        # Check session branch exists and target branch exists
        git -C "$_ppath" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null || continue
        git -C "$_ppath" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null || continue

        # Get diffstat: what session would change on target
        local _stat
        _stat=$(git -C "$_ppath" diff --stat "$target_branch".."$session_name" 2>/dev/null)
        [[ -z "$_stat" ]] && continue

        # Parse summary line for totals
        local _summary
        _summary=$(echo "$_stat" | tail -1)

        if [[ $_shown -eq 0 ]]; then
            echo -e "${DIM}session → ${target_branch} diff:${NC}"
            _shown=1
        fi
        echo -e "  ${BLUE}$_pname${NC}"
        # Show file list (indented), skip summary line
        echo "$_stat" | sed '$d' | sed 's/^/    /'
        echo "    $_summary"
        echo ""

        # Accumulate totals
        local _f _a _d
        _f=$(echo "$_summary" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo 0)
        _a=$(echo "$_summary" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
        _d=$(echo "$_summary" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)
        _total_files=$((_total_files + ${_f:-0}))
        _total_adds=$((_total_adds + ${_a:-0}))
        _total_dels=$((_total_dels + ${_d:-0}))
    done <<< "$projects"

    if [[ $_total_files -gt 0 ]]; then
        info "Total: $_total_files file(s), +$_total_adds -$_total_dels"
    fi
    # Return total files so caller can skip prompt if 0
    return $(( _total_files > 0 ? 0 : 1 ))
}
