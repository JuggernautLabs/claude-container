#!/usr/bin/env bash
# Pull report — reads result files and renders per-repo output

# Unified pull report — reads result files and renders per-repo output
# Usage: _pull_report <session_name> <branch> <result_dir> [repo_filter]
_pull_report() {
    local session_name="$1"
    local target_branch="$2"
    local result_dir="$3"
    local repo_filter="${4:-}"
    local volume="claude-session-${session_name}"

    # Collect all repos that have result files
    local _pulled=0 _unchanged=0 _needs_attention=0 _conflicts=0

    # Read config to iterate repos in order
    local config_content
    config_content=$(read_session_config "$volume")
    local projects=""
    if [[ -n "$config_content" ]]; then
        projects=$(parse_session_projects "$config_content")
    fi

    # Collect repo names from result files (covers repos not in config too)
    local -a _repo_names=()
    local -A _repo_seen=()
    # First: repos in config order
    if [[ -n "$projects" ]]; then
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_pname" ]] && continue
            repo_matches_filter "$_pname" "$repo_filter" || continue
            local _rfile="${result_dir}/${_pname//\//_}"
            if [[ -f "$_rfile" ]]; then
                _repo_names+=("$_pname")
                _repo_seen[$_pname]=1
            fi
        done <<< "$projects"
    fi
    # Then: any result files for repos not in config
    for _rfile in "$result_dir"/*; do
        [[ -f "$_rfile" ]] || continue
        [[ "$_rfile" == *.detail ]] && continue
        local _rname
        _rname=$(_pull_result_get "$result_dir" "$(basename "$_rfile")" "repo_name" 2>/dev/null)
        # repo_name might be stored with slashes, but file uses underscores
        # Read it directly from the file
        _rname=$(grep "^repo_name=" "$_rfile" 2>/dev/null | tail -1 | cut -d= -f2-)
        [[ -z "$_rname" ]] && continue
        if [[ -z "${_repo_seen[$_rname]:-}" ]]; then
            _repo_names+=("$_rname")
            _repo_seen[$_rname]=1
        fi
    done

    for _repo in "${_repo_names[@]}"; do
        local _ext_status _ext_commits _ext_files _ext_detail
        _ext_status=$(_pull_result_get "$result_dir" "$_repo" "extract_status")
        _ext_commits=$(_pull_result_get "$result_dir" "$_repo" "extract_commits")
        _ext_files=$(_pull_result_get "$result_dir" "$_repo" "extract_files")
        _ext_detail=$(_pull_result_get "$result_dir" "$_repo" "extract_detail")

        local _merge_status _merge_detail _conflict_files
        _merge_status=$(_pull_result_get "$result_dir" "$_repo" "merge_status")
        _merge_detail=$(_pull_result_get "$result_dir" "$_repo" "merge_detail")
        _conflict_files=$(_pull_result_get "$result_dir" "$_repo" "conflict_files")

        # Hide repos that are unchanged on both extract and merge
        # (never hide when --repo filter is active — user explicitly asked for this repo)
        local _is_quiet=false
        local _rpt_ta
        _rpt_ta=$(_pull_result_get "$result_dir" "$_repo" "target_ahead")
        if [[ -z "$repo_filter" ]] && [[ "$_ext_status" == "unchanged" || -z "$_ext_status" ]]; then
            # Candidate for hiding: check merge status
            local _merge_is_noop=false
            case "$_merge_detail" in
                "already up to date"|"up to date"*) _merge_is_noop=true ;;
                "host has uncommitted changes") _merge_is_noop=true ;;  # SKIP but no content change
                "") [[ -z "$_merge_status" ]] && _merge_is_noop=true ;;
            esac

            if $_merge_is_noop; then
                # Check if target-ahead commits are all benign (our squash-merges)
                local _has_external=false
                if [[ -n "$_rpt_ta" && "$_rpt_ta" != "0" ]]; then
                    local _hide_proj_path
                    _hide_proj_path=$(echo "$projects" | grep "^${_repo}|" | head -1 | cut -d'|' -f2)
                    if [[ -n "$_hide_proj_path" && -d "$_hide_proj_path" ]]; then
                        local _hide_log
                        _hide_log=$(git -C "$_hide_proj_path" log --oneline "$session_name".."$target_branch" 2>/dev/null | head -5)
                        while IFS= read -r _hide_line; do
                            [[ -z "$_hide_line" ]] && continue
                            if ! echo "$_hide_line" | grep -qE "^[0-9a-f]+ ${session_name} → "; then
                                _has_external=true
                                break
                            fi
                        done <<< "$_hide_log"
                    fi
                fi
                if ! $_has_external; then
                    _is_quiet=true
                    _unchanged=$((_unchanged + 1))
                fi
            fi
        fi
        if $_is_quiet; then
            continue
        fi

        local _c_ahead _h_ahead
        _c_ahead=$(_pull_result_get "$result_dir" "$_repo" "diverge_container_ahead")
        _h_ahead=$(_pull_result_get "$result_dir" "$_repo" "diverge_host_ahead")

        # Read commit hashes for display
        local _container_head _session_head _target_head
        _container_head=$(_pull_result_get "$result_dir" "$_repo" "container_head")
        _session_head=$(_pull_result_get "$result_dir" "$_repo" "session_head")
        _target_head=$(_pull_result_get "$result_dir" "$_repo" "target_head")
        local _short_container="${_container_head:0:7}"
        local _short_session="${_session_head:0:7}"
        local _short_target="${_target_head:0:7}"

        # Render repo header with hashes (collapse container/session when identical)
        local _hash_info=""
        if [[ -n "$_container_head" && -n "$_session_head" && "$_container_head" == "$_session_head" ]]; then
            _hash_info="  session:${_short_session}"
        else
            [[ -n "$_container_head" ]] && _hash_info="  container:${_short_container}"
            [[ -n "$_session_head" ]] && _hash_info="${_hash_info}  session:${_short_session}"
        fi
        if [[ -n "$_target_head" && -n "$target_branch" ]]; then
            _hash_info="${_hash_info}  ${target_branch}:${_short_target}"
        fi
        echo -e "  ${BLUE}$_repo${NC}${_hash_info}"

        # Extract line
        case "$_ext_status" in
            updated)
                local _ext_info=""
                [[ -n "$_ext_commits" && "$_ext_commits" != "0" ]] && _ext_info="${_ext_commits} commits"
                [[ -n "$_ext_files" && "$_ext_files" != "0" ]] && _ext_info="${_ext_info:+$_ext_info, }${_ext_files} files"
                echo -e "    extract:  ${GREEN}✓${NC} updated${_ext_info:+ ($_ext_info)}"
                _pulled=$((_pulled + 1))
                ;;
            cloned)
                local _ext_info=""
                [[ -n "$_ext_commits" && "$_ext_commits" != "0" ]] && _ext_info="${_ext_commits} commits"
                [[ -n "$_ext_files" && "$_ext_files" != "0" ]] && _ext_info="${_ext_info:+$_ext_info, }${_ext_files} files"
                echo -e "    extract:  ${GREEN}✓${NC} cloned${_ext_info:+ ($_ext_info)}"
                _pulled=$((_pulled + 1))
                ;;
            synced_local)
                echo -e "    extract:  ${GREEN}✓${NC} synced local into container"
                _pulled=$((_pulled + 1))
                ;;
            unchanged)
                echo -e "    extract:  ${BLUE}—${NC} no changes"
                _unchanged=$((_unchanged + 1))
                ;;
            diverged)
                local _div_info=""
                [[ -n "$_c_ahead" && -n "$_h_ahead" ]] && _div_info=" (container +${_c_ahead}, host +${_h_ahead})"
                echo -e "    extract:  ${YELLOW}!${NC} diverged${_div_info}"
                _needs_attention=$((_needs_attention + 1))
                ;;
            failed)
                echo -e "    extract:  ${RED}x${NC} failed${_ext_detail:+ ($_ext_detail)}"
                _needs_attention=$((_needs_attention + 1))
                ;;
            *)
                # No extract result (e.g. status-only check)
                ;;
        esac

        # Merge line (only if target branch was specified)
        if [[ -n "$target_branch" && -n "$_merge_status" ]]; then
            local _show_merge_diff=false
            case "$_merge_status" in
                OK)
                    case "$_merge_detail" in
                        "already up to date"|"up to date"*)
                            echo -e "    merge:    — no modifications needed"
                            ;;
                        "squash-merge"*|"fast-forward"*|"merge cleanly"*)
                            echo -e "    merge:    ${GREEN}✓${NC} $_merge_detail"
                            _show_merge_diff=true
                            ;;
                        *)
                            echo -e "    merge:    ${GREEN}✓${NC} $_merge_detail"
                            _show_merge_diff=true
                            ;;
                    esac
                    ;;
                SKIP)
                    echo -e "    merge:    ${YELLOW}!${NC} skipped${_merge_detail:+ — ${_merge_detail}}"
                    ;;
                CONFLICT)
                    echo -e "    merge:    ${RED}x${NC} conflict${_conflict_files:+ ($_conflict_files)}"
                    _conflicts=$((_conflicts + 1))
                    _show_merge_diff=true
                    ;;
            esac
            # Inline diffstat for repos that will be modified
            if $_show_merge_diff; then
                local _merge_proj_path
                _merge_proj_path=$(echo "$projects" | grep "^${_repo}|" | head -1 | cut -d'|' -f2)
                if [[ -n "$_merge_proj_path" && -d "$_merge_proj_path" ]]; then
                    local _merge_stat
                    _merge_stat=$(git -C "$_merge_proj_path" diff --stat "$target_branch".."$session_name" 2>/dev/null)
                    if [[ -n "$_merge_stat" ]]; then
                        echo "$_merge_stat" | sed '$d' | sed 's/^/              /'
                        echo "              $(echo "$_merge_stat" | tail -1)"
                    fi
                fi
            fi
        fi

        # Target-ahead warning: show commits on target that session doesn't have
        local _rpt_target_ahead
        _rpt_target_ahead=$(_pull_result_get "$result_dir" "$_repo" "target_ahead")
        if [[ -n "$_rpt_target_ahead" && "$_rpt_target_ahead" != "0" ]]; then
            local _rpt_proj_path
            _rpt_proj_path=$(echo "$projects" | grep "^${_repo}|" | head -1 | cut -d'|' -f2)
            if [[ -n "$_rpt_proj_path" && -d "$_rpt_proj_path" ]]; then
                # Check if all ahead commits are our own squash-merges (benign)
                local _rpt_ahead_log _rpt_external=0
                _rpt_ahead_log=$(git -C "$_rpt_proj_path" log --oneline "$session_name".."$target_branch" 2>/dev/null | head -5)
                while IFS= read -r _rpt_line; do
                    [[ -z "$_rpt_line" ]] && continue
                    # Our squash-merge commits match: "session_name -> target (N commits)"
                    if ! echo "$_rpt_line" | grep -qE "^[0-9a-f]+ ${session_name} → "; then
                        _rpt_external=$((_rpt_external + 1))
                    fi
                done <<< "$_rpt_ahead_log"

                if [[ $_rpt_external -gt 0 ]]; then
                    echo -e "    ${YELLOW}! ${target_branch} has ${_rpt_target_ahead} commit(s) not in session:${NC}"
                    while IFS= read -r _rpt_line; do
                        [[ -n "$_rpt_line" ]] && echo "      $_rpt_line"
                    done <<< "$_rpt_ahead_log"
                    local _rpt_risk_stat
                    _rpt_risk_stat=$(git -C "$_rpt_proj_path" diff --stat "$session_name".."$target_branch" 2>/dev/null | tail -1)
                    [[ -n "$_rpt_risk_stat" ]] && echo -e "      ${YELLOW}$_rpt_risk_stat${NC}"
                else
                    local _rpt_squash_stat
                    _rpt_squash_stat=$(git -C "$_rpt_proj_path" diff --stat "$session_name".."$target_branch" 2>/dev/null | tail -1)
                    if [[ -n "$_rpt_squash_stat" ]]; then
                        echo -e "    ${DIM}${target_branch} +${_rpt_target_ahead} (prior squash-merge): $_rpt_squash_stat${NC}"
                    else
                        echo -e "    ${DIM}${target_branch} +${_rpt_target_ahead} (prior squash-merge)${NC}"
                    fi
                fi
            fi
        fi

        # Action line for repos needing attention
        if [[ "$_ext_status" == "diverged" ]]; then
            echo -e "    ${BLUE}fix:${NC}  claude-container pull -s ${session_name} --force  ${DIM}(overwrite local)${NC}"
            echo -e "      or: claude-container push -s ${session_name} ${target_branch:-main} --merge  ${DIM}(merge into session)${NC}"
        elif [[ "$_merge_status" == "CONFLICT" ]]; then
            echo -e "    ${BLUE}fix:${NC}  claude-container pull -s ${session_name} ${target_branch} --reconcile  ${DIM}(Claude resolves conflicts)${NC}"
            echo -e "      or: claude-container pull -s ${session_name} ${target_branch} --no-squash  ${DIM}(merge commit, keep history)${NC}"
        fi
    done

    # Summary
    echo ""
    local _summary_parts=()
    if [[ $_pulled -gt 0 ]]; then
        _summary_parts+=("${_pulled} merged into ${target_branch:-main}")
    fi
    if [[ $_conflicts -gt 0 ]]; then
        _summary_parts+=("${_conflicts} conflict(s)")
    fi
    if [[ $_needs_attention -gt 0 ]]; then
        _summary_parts+=("${_needs_attention} need attention")
    fi

    if [[ ${#_summary_parts[@]} -gt 0 ]]; then
        local _summary_line
        _summary_line=$(IFS=', '; echo "${_summary_parts[*]}")
        if [[ $_needs_attention -eq 0 && $_conflicts -eq 0 ]]; then
            success "$_summary_line"
        else
            warn "$_summary_line"
        fi
    fi
    if [[ $_unchanged -gt 0 ]]; then
        echo -e "${DIM}$_unchanged repo(s) unchanged — no modifications${NC}"
    fi
}
