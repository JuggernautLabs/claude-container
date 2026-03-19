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

    # Counters
    local _ready=0 _unchanged=0 _conflicts=0 _skipped=0 _target_ahead_count=0

    # Read config to iterate repos in order
    local config_content
    config_content=$(read_session_config "$volume")
    local projects=""
    if [[ -n "$config_content" ]]; then
        projects=$(parse_session_projects "$config_content")
    fi
    if [[ -n "$repo_filter" ]]; then
        projects=$(augment_projects_from_volume "$volume" "$projects" "$repo_filter")
    fi

    # Collect repo names from result files
    local -a _repo_names=()
    local -A _repo_seen=()
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
    for _rfile in "$result_dir"/*; do
        [[ -f "$_rfile" ]] || continue
        [[ "$_rfile" == *.detail ]] && continue
        local _rname
        _rname=$(grep "^repo_name=" "$_rfile" 2>/dev/null | tail -1 | cut -d= -f2-)
        [[ -z "$_rname" ]] && continue
        if [[ -z "${_repo_seen[$_rname]:-}" ]]; then
            _repo_names+=("$_rname")
            _repo_seen[$_rname]=1
        fi
    done

    # ── Pass 1: classify every repo into exactly one bucket ──
    local -a _skip_lines=()       # "repo — reason"
    local -a _ready_lines=()      # "repo — merge detail (diffstat)"
    local -a _conflict_lines=()   # "repo (conflict files)"
    local -a _discovered_lines=() # "repo"
    local -a _attention_lines=()  # "repo — problem"

    for _repo in "${_repo_names[@]}"; do
        local _ext_status _merge_status _merge_detail _conflict_files
        _ext_status=$(_pull_result_get "$result_dir" "$_repo" "extract_status")
        _merge_status=$(_pull_result_get "$result_dir" "$_repo" "merge_status")
        _merge_detail=$(_pull_result_get "$result_dir" "$_repo" "merge_detail")
        _conflict_files=$(_pull_result_get "$result_dir" "$_repo" "conflict_files")

        local _short_name="${_repo##*/}"

        # Discovered (not extracted) → own bucket
        if [[ "$_ext_status" == "discovered" ]]; then
            _discovered_lines+=("$_short_name")
            continue
        fi

        # Quiet check: unchanged on both extract and merge, no interesting target-ahead
        local _is_quiet=false
        local _rpt_ta
        _rpt_ta=$(_pull_result_get "$result_dir" "$_repo" "target_ahead")
        if [[ -z "$repo_filter" ]] && [[ "$_ext_status" == "unchanged" || -z "$_ext_status" ]]; then
            local _merge_is_noop=false
            case "$_merge_detail" in
                "already up to date"|"up to date"*) _merge_is_noop=true ;;
                "host has uncommitted changes") _merge_is_noop=true ;;
                "") [[ -z "$_merge_status" ]] && _merge_is_noop=true ;;
            esac
            if $_merge_is_noop; then
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

        # Extract-level problems take priority
        if [[ "$_ext_status" == "diverged" ]]; then
            local _c_ahead _h_ahead
            _c_ahead=$(_pull_result_get "$result_dir" "$_repo" "diverge_container_ahead")
            _h_ahead=$(_pull_result_get "$result_dir" "$_repo" "diverge_host_ahead")
            local _div_info=""
            [[ -n "$_c_ahead" && -n "$_h_ahead" ]] && _div_info=" (container +${_c_ahead}, host +${_h_ahead})"
            _attention_lines+=("$_short_name — diverged${_div_info}")
            continue
        fi
        if [[ "$_ext_status" == "failed" ]]; then
            local _ext_detail
            _ext_detail=$(_pull_result_get "$result_dir" "$_repo" "extract_detail")
            _attention_lines+=("$_short_name — extract failed${_ext_detail:+ ($_ext_detail)}")
            continue
        fi

        # Merge classification (every repo lands in exactly one bucket)
        case "$_merge_status" in
            OK)
                case "$_merge_detail" in
                    "already up to date"|"up to date"*)
                        # Merge noop but repo wasn't quiet — must have interesting target-ahead
                        _unchanged=$((_unchanged + 1))
                        ;;
                    *)
                        # Get inline diffstat for the ready line
                        local _rdiff=""
                        local _rpath
                        _rpath=$(echo "$projects" | grep "^${_repo}|" | head -1 | cut -d'|' -f2)
                        if [[ -n "$_rpath" && -d "$_rpath" ]]; then
                            _rdiff=$(git -C "$_rpath" diff --stat "$target_branch".."$session_name" 2>/dev/null | tail -1)
                        fi
                        _ready_lines+=("$_short_name — $_merge_detail${_rdiff:+ | $_rdiff}")
                        _ready=$((_ready + 1))
                        ;;
                esac
                ;;
            SKIP)
                _skip_lines+=("$_short_name — ${_merge_detail}")
                _skipped=$((_skipped + 1))
                ;;
            CONFLICT)
                _conflict_lines+=("$_short_name${_conflict_files:+ ($_conflict_files)}")
                _conflicts=$((_conflicts + 1))
                ;;
            "")
                # No merge status (extract-only pull, no branch target)
                if [[ "$_ext_status" == "updated" || "$_ext_status" == "cloned" || "$_ext_status" == "synced_local" ]]; then
                    local _ext_commits _ext_files
                    _ext_commits=$(_pull_result_get "$result_dir" "$_repo" "extract_commits")
                    _ext_files=$(_pull_result_get "$result_dir" "$_repo" "extract_files")
                    local _einfo=""
                    [[ -n "$_ext_commits" && "$_ext_commits" != "0" ]] && _einfo="${_ext_commits} commits"
                    [[ -n "$_ext_files" && "$_ext_files" != "0" ]] && _einfo="${_einfo:+$_einfo, }${_ext_files} files"
                    _ready_lines+=("$_short_name — extracted${_einfo:+ ($_einfo)}")
                    _ready=$((_ready + 1))
                else
                    _unchanged=$((_unchanged + 1))
                fi
                ;;
        esac

        # Count target-ahead (for the hint in diffstat, not rendered here)
        if [[ -n "$_rpt_ta" && "$_rpt_ta" != "0" ]]; then
            local _ta_proj_path
            _ta_proj_path=$(echo "$projects" | grep "^${_repo}|" | head -1 | cut -d'|' -f2)
            if [[ -n "$_ta_proj_path" && -d "$_ta_proj_path" ]]; then
                local _ta_log _ta_external=0
                _ta_log=$(git -C "$_ta_proj_path" log --oneline "$session_name".."$target_branch" 2>/dev/null | head -5)
                while IFS= read -r _ta_line; do
                    [[ -z "$_ta_line" ]] && continue
                    if ! echo "$_ta_line" | grep -qE "^[0-9a-f]+ ${session_name} → "; then
                        _ta_external=$((_ta_external + 1))
                    fi
                done <<< "$_ta_log"
                [[ $_ta_external -gt 0 ]] && _target_ahead_count=$((_target_ahead_count + 1))
            fi
        fi
    done

    # ── Pass 2: render ──

    local _has_content=false
    [[ $_ready -gt 0 || $_skipped -gt 0 || $_conflicts -gt 0 || ${#_attention_lines[@]} -gt 0 || ${#_discovered_lines[@]} -gt 0 ]] && _has_content=true

    if ! $_has_content; then
        if [[ $_unchanged -gt 0 ]]; then
            echo -e "${DIM}${_unchanged} repo(s) unchanged${NC}"
        else
            echo -e "${DIM}no repos to report${NC}"
        fi
        return 0
    fi

    # Header
    if [[ -n "$target_branch" ]]; then
        _rule "pull: ${session_name} → ${target_branch}"
    else
        _rule "pull: ${session_name}"
    fi

    # Summary line
    local _summary_parts=()
    [[ $_ready -gt 0 ]] && _summary_parts+=("${_ready} ready")
    [[ $_skipped -gt 0 ]] && _summary_parts+=("${_skipped} skipped")
    [[ $_conflicts -gt 0 ]] && _summary_parts+=("${_conflicts} conflict(s)")
    [[ ${#_attention_lines[@]} -gt 0 ]] && _summary_parts+=("${#_attention_lines[@]} need attention")

    if [[ ${#_summary_parts[@]} -gt 0 ]]; then
        local _summary_line
        _summary_line=$(IFS=', '; echo "${_summary_parts[*]}")
        if [[ $_conflicts -eq 0 && ${#_attention_lines[@]} -eq 0 && $_skipped -eq 0 ]]; then
            success "$_summary_line"
        elif [[ $_conflicts -eq 0 && ${#_attention_lines[@]} -eq 0 ]]; then
            info "$_summary_line"
        else
            warn "$_summary_line"
        fi
    fi
    [[ $_unchanged -gt 0 ]] && echo -e "${DIM}${_unchanged} unchanged${NC}"

    # Ready repos
    if [[ ${#_ready_lines[@]} -gt 0 ]]; then
        echo ""
        for _rl in "${_ready_lines[@]}"; do
            echo -e "  ${GREEN}✓${NC} ${_rl}"
        done
    fi

    # Skipped repos
    if [[ ${#_skip_lines[@]} -gt 0 ]]; then
        echo ""
        echo "  skipped:"
        for _sl in "${_skip_lines[@]}"; do
            echo -e "    ${DIM}${_sl}${NC}"
        done
    fi

    # Discovered repos
    if [[ ${#_discovered_lines[@]} -gt 0 ]]; then
        echo ""
        echo "  discovered (not extracted):"
        for _dl in "${_discovered_lines[@]}"; do
            echo -e "    ${YELLOW}○${NC} ${_dl}"
        done
        echo -e "    ${DIM}→ pull -s ${session_name} --extract${NC}"
    fi

    # Conflicts
    if [[ ${#_conflict_lines[@]} -gt 0 ]]; then
        echo ""
        echo "  conflicts:"
        for _cl in "${_conflict_lines[@]}"; do
            echo -e "    ${RED}✗${NC} ${_cl}"
        done
        echo -e "    ${DIM}→ pull -s ${session_name} ${target_branch} --reconcile${NC}"
    fi

    # Attention
    if [[ ${#_attention_lines[@]} -gt 0 ]]; then
        echo ""
        echo "  need attention:"
        for _al in "${_attention_lines[@]}"; do
            echo -e "    ${YELLOW}!${NC} ${_al}"
        done
        echo -e "    ${DIM}→ pull -s ${session_name} --force  (overwrite local)${NC}"
    fi

    # Footer
    echo ""
    _rule

    # Warn about --repo filter terms that matched nothing
    if [[ -n "$repo_filter" ]]; then
        local -a _all_session_repos=()
        if [[ -n "$projects" ]]; then
            while IFS='|' read -r _apname _appath; do
                [[ -n "$_apname" ]] && _all_session_repos+=("$_apname")
            done <<< "$projects"
        fi
        local IFS=','
        for _fterm in $repo_filter; do
            local _fmatched=false
            for _fname in "${_all_session_repos[@]}"; do
                if [[ "$_fname" == *"$_fterm"* ]]; then
                    _fmatched=true
                    break
                fi
            done
            if ! $_fmatched; then
                warn "no repo matching '$_fterm' found in session"
            fi
        done
    fi
}
