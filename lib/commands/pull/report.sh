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
    local _ready=0 _unchanged=0 _needs_attention=0 _conflicts=0 _skipped=0 _target_ahead_count=0

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

    # ── Pass 1: classify repos into buckets ──
    local -a _skip_lines=()    # "repo — reason"
    local -a _ready_repos=()   # repos that will merge
    local -a _conflict_repos=() # repos with conflicts
    local -a _attention_repos=() # repos needing attention (diverged extract, etc.)
    local -a _discovered_repos=() # repos not yet extracted

    for _repo in "${_repo_names[@]}"; do
        local _ext_status _merge_status _merge_detail _conflict_files
        _ext_status=$(_pull_result_get "$result_dir" "$_repo" "extract_status")
        _merge_status=$(_pull_result_get "$result_dir" "$_repo" "merge_status")
        _merge_detail=$(_pull_result_get "$result_dir" "$_repo" "merge_detail")
        _conflict_files=$(_pull_result_get "$result_dir" "$_repo" "conflict_files")

        # Discovered (not extracted)
        if [[ "$_ext_status" == "discovered" ]]; then
            _discovered_repos+=("$_repo")
            continue
        fi

        # Quiet check: unchanged on both extract and merge
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

        # Extract-level attention
        if [[ "$_ext_status" == "diverged" || "$_ext_status" == "failed" ]]; then
            _attention_repos+=("$_repo")
            _needs_attention=$((_needs_attention + 1))
        fi

        # Merge classification
        case "$_merge_status" in
            OK)
                case "$_merge_detail" in
                    "already up to date"|"up to date"*)
                        # up-to-date merge — don't count as ready
                        ;;
                    *)
                        _ready_repos+=("$_repo")
                        _ready=$((_ready + 1))
                        ;;
                esac
                ;;
            SKIP)
                _skip_lines+=("${_repo##*/} — ${_merge_detail}")
                _skipped=$((_skipped + 1))
                ;;
            CONFLICT)
                _conflict_repos+=("$_repo")
                _conflicts=$((_conflicts + 1))
                ;;
        esac

        # Count target-ahead
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

    # Nothing visible at all?
    local _has_content=false
    [[ $_ready -gt 0 || $_skipped -gt 0 || $_conflicts -gt 0 || $_needs_attention -gt 0 || ${#_discovered_repos[@]} -gt 0 ]] && _has_content=true

    # Header
    if [[ -n "$target_branch" ]]; then
        _rule "pull: ${session_name} → ${target_branch}"
    else
        _rule "pull: ${session_name}"
    fi

    # Summary line (right after header)
    local _summary_parts=()
    [[ $_ready -gt 0 ]] && _summary_parts+=("${_ready} ready")
    [[ $_skipped -gt 0 ]] && _summary_parts+=("${_skipped} skipped")
    [[ $_conflicts -gt 0 ]] && _summary_parts+=("${_conflicts} conflict(s)")
    [[ $_needs_attention -gt 0 ]] && _summary_parts+=("${_needs_attention} need attention")

    if [[ ${#_summary_parts[@]} -gt 0 ]]; then
        local _summary_line
        _summary_line=$(IFS=', '; echo "${_summary_parts[*]}")
        if [[ $_needs_attention -eq 0 && $_conflicts -eq 0 && $_skipped -eq 0 ]]; then
            success "$_summary_line"
        elif [[ $_needs_attention -eq 0 && $_conflicts -eq 0 ]]; then
            # Has skips but no real problems
            info "$_summary_line"
        else
            warn "$_summary_line"
        fi
    fi
    if [[ $_unchanged -gt 0 ]]; then
        echo -e "${DIM}${_unchanged} unchanged${NC}"
    fi

    # Skipped repos (compact list)
    if [[ ${#_skip_lines[@]} -gt 0 ]]; then
        echo ""
        echo "  skipped:"
        for _sl in "${_skip_lines[@]}"; do
            echo -e "    ${DIM}${_sl}${NC}"
        done
    fi

    # Discovered repos
    if [[ ${#_discovered_repos[@]} -gt 0 ]]; then
        echo ""
        echo "  discovered (not extracted):"
        for _dr in "${_discovered_repos[@]}"; do
            echo -e "    ${YELLOW}○${NC} ${_dr##*/}"
        done
        echo -e "    ${DIM}→ pull -s ${session_name} --extract${NC}"
    fi

    # Conflicts
    if [[ ${#_conflict_repos[@]} -gt 0 ]]; then
        echo ""
        echo "  conflicts:"
        for _cr in "${_conflict_repos[@]}"; do
            local _cf
            _cf=$(_pull_result_get "$result_dir" "$_cr" "conflict_files")
            echo -e "    ${RED}✗${NC} ${_cr##*/}${_cf:+ ($_cf)}"
        done
        echo -e "    ${DIM}→ pull -s ${session_name} ${target_branch} --reconcile${NC}"
    fi

    # Attention (diverged extract, etc.)
    if [[ ${#_attention_repos[@]} -gt 0 ]]; then
        echo ""
        echo "  need attention:"
        for _ar in "${_attention_repos[@]}"; do
            local _ar_ext _ar_detail
            _ar_ext=$(_pull_result_get "$result_dir" "$_ar" "extract_status")
            _ar_detail=$(_pull_result_get "$result_dir" "$_ar" "extract_detail")
            local _c_ahead _h_ahead
            _c_ahead=$(_pull_result_get "$result_dir" "$_ar" "diverge_container_ahead")
            _h_ahead=$(_pull_result_get "$result_dir" "$_ar" "diverge_host_ahead")
            local _div_info=""
            [[ -n "$_c_ahead" && -n "$_h_ahead" ]] && _div_info=" (container +${_c_ahead}, host +${_h_ahead})"
            echo -e "    ${YELLOW}!${NC} ${_ar##*/} — ${_ar_ext}${_div_info}${_ar_detail:+ — $_ar_detail}"
        done
        echo -e "    ${DIM}→ pull -s ${session_name} --force  (overwrite local)${NC}"
    fi

    # Footer
    echo ""
    _rule

    if [[ $_target_ahead_count -gt 0 ]]; then
        echo -e "${DIM}${target_branch} ahead in ${_target_ahead_count} repo(s) — push --merge to sync${NC}"
    fi

    # Warn about --repo filter terms that matched nothing
    if [[ -n "$repo_filter" ]]; then
        local IFS=','
        for _fterm in $repo_filter; do
            local _fmatched=false
            for _fname in "${_repo_names[@]}"; do
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
