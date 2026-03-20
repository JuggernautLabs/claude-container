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

    # Snapshot all state
    local _status_dir
    _status_dir=$(mktemp -d)
    trap "rm -rf '$_status_dir'" RETURN

    snapshot_session_state "$volume" "$session_name" "" "$_status_dir" "$repo_filter"

    # Check if any repos were found
    local _any_repos=false
    for _sf in "$_status_dir"/*; do
        [[ -f "$_sf" ]] && _any_repos=true && break
    done
    if ! $_any_repos; then
        info "No repos found in session"
        return 0
    fi

    local _up_to_date=0 _changed=0 _diverged=0 _not_extracted=0

    # Header
    _rule "status: ${session_name}"
    echo ""

    local _first_repo=true

    for _sf in "$_status_dir"/*; do
        [[ -f "$_sf" ]] || continue
        local _name
        _name=$(_pull_result_get "$_status_dir" "$(basename "$_sf")" "repo_name")
        # result files use repo_name key but filename has slashes→underscores
        # re-read using the actual filename as the "repo" key won't work — grep by key
        _name=$(grep "^repo_name=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
        [[ -z "$_name" ]] && continue

        local _s_head _session_head _path _container_known
        _s_head=$(grep "^container_head=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
        _session_head=$(grep "^session_head=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
        _path=$(grep "^host_path=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
        _container_known=$(grep "^container_known=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)

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
        [[ -n "$_session_head" ]] && _hash_parts+=("session:${_session_head:0:7}")
        [[ -n "$_t_head" ]] && _hash_parts+=("main:${_t_head:0:7}")
        echo -e "    ${DIM}${_hash_parts[*]}${NC}"

        # Check extract: false (discovered repo)
        local _extract_en
        _extract_en=$(grep "^extract_enabled=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
        if [[ "$_extract_en" == "false" ]]; then
            echo -e "    ${YELLOW}○${NC} extract: false ${DIM}(pull --extract to enable)${NC}"
            _not_extracted=$((_not_extracted + 1))
            continue
        fi

        if [[ -z "$_session_head" ]]; then
            # No session branch on host — check if content is already there
            local _cit_status _target_h
            _cit_status=$(grep "^container_in_target=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
            _target_h=$(grep "^target_head=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
            local _main_h=""
            [[ -n "$_path" ]] && _main_h=$(git -C "$_path" rev-parse HEAD 2>/dev/null || echo "")
            if [[ "$_s_head" == "$_main_h" ]]; then
                echo -e "    ${GREEN}✓${NC} up to date ${DIM}(no session branch, container matches host)${NC}"
                _up_to_date=$((_up_to_date + 1))
            elif [[ "$_cit_status" == "true" ]]; then
                echo -e "    ${GREEN}✓${NC} up to date ${DIM}(no session branch, content already in target)${NC}"
                _up_to_date=$((_up_to_date + 1))
            else
                echo -e "    ${YELLOW}!${NC} not extracted ${DIM}(run: pull -s ${session_name} to create session branch)${NC}"
                _not_extracted=$((_not_extracted + 1))
            fi
        elif [[ "$_s_head" == "$_session_head" ]]; then
            echo -e "    ${GREEN}✓${NC} up to date"
            _up_to_date=$((_up_to_date + 1))
        elif git -C "$_path" merge-base --is-ancestor "$_session_head" "$_s_head" 2>/dev/null; then
            local _ahead
            _ahead=$(git -C "$_path" rev-list --count "$_session_head".."$_s_head" 2>/dev/null || echo "?")
            echo -e "    ${BLUE}→${NC} container ahead by $_ahead commit(s)"
            _changed=$((_changed + 1))
        elif git -C "$_path" merge-base --is-ancestor "$_s_head" "$_session_head" 2>/dev/null; then
            local _ahead
            _ahead=$(git -C "$_path" rev-list --count "$_s_head".."$_session_head" 2>/dev/null || echo "?")
            local _ext_ahead
            _ext_ahead=$(grep "^external_ahead=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
            [[ -z "$_ext_ahead" ]] && _ext_ahead=0
            if [[ "$_ext_ahead" -eq 0 ]]; then
                echo -e "    ${GREEN}✓${NC} up to date ${DIM}(squashed)${NC}"
                _up_to_date=$((_up_to_date + 1))
            else
                echo -e "    ${DIM}← host ahead by $_ahead commit(s)${NC}"
                _changed=$((_changed + 1))
            fi
        else
            local _merge_base
            _merge_base=$(git -C "$_path" merge-base "$_session_head" "$_s_head" 2>/dev/null || echo "")
            local _c_ahead=0 _h_ahead=0
            if [[ -n "$_merge_base" ]]; then
                _c_ahead=$(git -C "$_path" rev-list --count "$_merge_base".."$_s_head" 2>/dev/null || echo "?")
                _h_ahead=$(git -C "$_path" rev-list --count "$_merge_base".."$_session_head" 2>/dev/null || echo "?")
            fi

            if [[ "$_c_ahead" == "0" && "$_h_ahead" == "0" ]]; then
                echo -e "    ${GREEN}✓${NC} up to date ${DIM}(rebased)${NC}"
                _up_to_date=$((_up_to_date + 1))
            elif [[ "$_c_ahead" == "0" ]]; then
                local _ext_ahead
                _ext_ahead=$(grep "^external_ahead=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
                [[ -z "$_ext_ahead" ]] && _ext_ahead=0
                if [[ "$_ext_ahead" -eq 0 ]]; then
                    echo -e "    ${GREEN}✓${NC} up to date ${DIM}(squashed)${NC}"
                    _up_to_date=$((_up_to_date + 1))
                else
                    echo -e "    ${YELLOW}!${NC} diverged (container +${_c_ahead}, host +${_h_ahead})"
                    _diverged=$((_diverged + 1))
                fi
            else
                echo -e "    ${YELLOW}!${NC} diverged (container +${_c_ahead}, host +${_h_ahead})"
                _diverged=$((_diverged + 1))
            fi
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

    # Set global for callers that need to know if extraction is needed
    _PULL_STATUS_HAS_CHANGES=false
    [[ $_changed -gt 0 || $_diverged -gt 0 || $_not_extracted -gt 0 ]] && _PULL_STATUS_HAS_CHANGES=true
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

        # Skip repos whose merge was skipped or had no meaningful result
        if [[ -n "$result_dir" ]]; then
            local _diff_merge_status
            _diff_merge_status=$(_pull_result_get "$result_dir" "$_pname" "merge_status")
            case "$_diff_merge_status" in
                SKIP|CONFLICT) continue ;;
            esac
            local _diff_merge_detail
            _diff_merge_detail=$(_pull_result_get "$result_dir" "$_pname" "merge_detail")
            case "$_diff_merge_detail" in
                "already up to date"|"up to date"*) continue ;;
            esac
        fi

        # Get diffstat: what session would change on target (squash-aware)
        local _stat
        _stat=$(snapshot_diff "$result_dir" "$_pname" "outbound" "stat")
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

    # Target-ahead hint (after diffs, where user will see it last)
    if [[ -n "$result_dir" ]]; then
        local _ta_count=0
        for _rfile in "$result_dir"/*; do
            [[ -f "$_rfile" ]] || continue
            [[ "$_rfile" == *.detail ]] && continue
            local _ta_repo_name
            _ta_repo_name=$(grep "^repo_name=" "$_rfile" 2>/dev/null | tail -1 | cut -d= -f2-)
            [[ -z "$_ta_repo_name" ]] && continue
            repo_matches_filter "$_ta_repo_name" "$repo_filter" || continue
            local _ta_ext
            _ta_ext=$(grep "^external_ahead=" "$_rfile" 2>/dev/null | tail -1 | cut -d= -f2-)
            [[ -n "$_ta_ext" && "$_ta_ext" -gt 0 ]] && _ta_count=$((_ta_count + 1))
        done
        if [[ $_ta_count -gt 0 ]]; then
            echo -e "${DIM}${target_branch} ahead in ${_ta_count} repo(s) — push --merge to sync${NC}"
        fi
    fi

    # Return total files so caller can skip prompt if 0
    return $(( _total_files > 0 ? 0 : 1 ))
}
