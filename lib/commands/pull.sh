#!/usr/bin/env bash
# Subcommand: pull
# Pull session changes from container to host (container → host)
#
# Usage:
#   claude-container pull -s <session> [branch] [options]
#   claude-container pull -s myproj                      # extract only
#   claude-container pull -s myproj main                 # extract + merge into main
#   claude-container pull -s myproj main --reconcile     # full reconcile cycle
#   claude-container pull -s myproj --status             # read-only status check

cmd_pull() {
    local session_name=""
    local branch=""
    local repo_filter=""
    local reconcile=false
    local force=false
    local dry_run=false
    local squash=true
    local status_only=false
    local verify=false
    local show_prompt=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --repo)
                repo_filter="$2"
                shift 2
                ;;
            --reconcile|-R)
                reconcile=true
                shift
                ;;
            --force|-f)
                force=true
                shift
                ;;
            --squash)
                squash=true
                shift
                ;;
            --no-squash)
                squash=false
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --status)
                status_only=true
                shift
                ;;
            --verify)
                verify=true
                shift
                ;;
            --show-prompt)
                show_prompt=true
                shift
                ;;
            --help|-h)
                _pull_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container pull --help' for usage"
                return 1
                ;;
            *)
                # Positional arg = branch name
                if [[ -z "$branch" ]]; then
                    branch="$1"
                else
                    error "Unexpected argument: $1"
                    echo "Run 'claude-container pull --help' for usage"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Session name required: use --session <name>"
        echo "Run 'claude-container pull --help' for usage"
        return 1
    fi

    # Dry-run requires a branch
    if $dry_run && [[ -z "$branch" ]]; then
        error "--dry-run requires a target branch"
        echo "Usage: claude-container pull -s <session> <branch> --dry-run"
        return 1
    fi

    # Status check mode — read-only, no extraction or merge
    if $status_only; then
        _pull_status "$session_name" "$repo_filter"
        return $?
    fi

    # Extract session branches to host repos
    local extract_args=("$session_name")
    if $force; then
        extract_args+=(--force)
    fi
    # When merging into a target branch, always force-extract.
    # The session branch is just transport — container is source of truth.
    # Main is protected by merge conflict detection.
    if [[ -n "$branch" ]]; then
        extract_args+=(--force)
    fi
    if [[ -n "$repo_filter" ]]; then
        extract_args+=(--repo "$repo_filter")
    fi

    if $reconcile; then
        # Reconcile mode requires a branch
        if [[ -z "$branch" ]]; then
            error "--reconcile requires a target branch"
            echo "Usage: claude-container pull -s <session> <branch> --reconcile"
            return 1
        fi
        if $dry_run; then
            _pull_reconcile_preview "$session_name" "$branch" "$repo_filter" "$show_prompt"
            return $?
        fi
        # Reconcile uses legacy (non-unified) output
        _pull_reconcile "$session_name" "$branch" "$force" "$verify"
        return $?
    fi

    # --- Unified reporting mode ---
    local _pull_result_dir
    _pull_result_dir=$(mktemp -d)
    trap "rm -rf '$_pull_result_dir'" RETURN

    if [[ -n "$branch" ]]; then
        info "Pulling session '$session_name' into '$branch'..."
    else
        info "Pulling session '$session_name'..."
    fi
    echo ""

    # Extract with result tracking
    extract_args+=(--result-dir "$_pull_result_dir")
    session_extract "${extract_args[@]}"

    # If branch specified, dry-run merge first to populate results + show preview
    local _merge_rc=0
    if [[ -n "$branch" ]]; then
        # Dry-run: populate merge results without changing anything
        session_auto_merge "$session_name" "$branch" true "$repo_filter" "$squash" "$_pull_result_dir" 2>/dev/null || true

        # Show full report (extract + merge preview)
        echo ""
        _pull_report "$session_name" "$branch" "$_pull_result_dir" "$repo_filter"

        # Show diffstat of what would change on target
        echo ""
        _verify_diffstat "$session_name" "$branch" "$_pull_result_dir" "$repo_filter" || true

        if $dry_run; then
            # --dry-run: show preview and stop
            return 0
        fi

        if $verify; then
            echo ""
            printf "Merge into '%s'? [y/N] " "$branch"
            local _answer
            read -r _answer
            case "$_answer" in
                [yY]|[yY][eE][sS])
                    info "Merging..."
                    ;;
                *)
                    info "Aborted. Session branches extracted but not merged."
                    info "To merge later: claude-container pull -s $session_name $branch"
                    return 0
                    ;;
            esac
        fi

        # Real merge
        session_auto_merge "$session_name" "$branch" false "$repo_filter" "$squash" "$_pull_result_dir" || _merge_rc=$?

        # Final report (with actual merge results)
        echo ""
        _pull_report "$session_name" "$branch" "$_pull_result_dir" "$repo_filter"
    else
        # Extract-only: just show extraction report
        echo ""
        _pull_report "$session_name" "" "$_pull_result_dir" "$repo_filter"
    fi

    return $_merge_rc
}

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
            [[ -n "$repo_filter" && "$_pname" != "$repo_filter" ]] && continue
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
        local _is_quiet=false
        if [[ "$_ext_status" == "unchanged" || -z "$_ext_status" ]]; then
            case "$_merge_detail" in
                "already up to date"|"no new commits since last squash"|"content identical"*)
                    _is_quiet=true
                    _unchanged=$((_unchanged + 1))
                    ;;
                "") [[ -z "$_merge_status" ]] && _is_quiet=true && _unchanged=$((_unchanged + 1)) ;;
            esac
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

        # Render repo header with hashes
        local _hash_info=""
        if [[ -n "$_container_head" ]]; then
            _hash_info="  container:${_short_container}"
        fi
        if [[ -n "$_session_head" ]]; then
            _hash_info="${_hash_info}  session:${_short_session}"
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
                echo -e "    extract:  ${YELLOW}⚠${NC} diverged${_div_info}"
                _needs_attention=$((_needs_attention + 1))
                ;;
            failed)
                echo -e "    extract:  ${RED}✗${NC} failed${_ext_detail:+ ($_ext_detail)}"
                _needs_attention=$((_needs_attention + 1))
                ;;
            *)
                # No extract result (e.g. status-only check)
                ;;
        esac

        # Merge line (only if target branch was specified)
        if [[ -n "$target_branch" && -n "$_merge_status" ]]; then
            case "$_merge_status" in
                OK)
                    case "$_merge_detail" in
                        "already up to date"|"squash-merged (no new"*)
                            echo -e "    merge:    ${BLUE}—${NC} already up to date"
                            ;;
                        "content identical to"*)
                            echo -e "    merge:    ${BLUE}—${NC} ${_merge_detail} (likely prior squash)"
                            ;;
                        *)
                            echo -e "    merge:    ${GREEN}✓${NC} ${session_name} → ${target_branch}: $_merge_detail"
                            ;;
                    esac
                    ;;
                SKIP)
                    echo -e "    merge:    ${BLUE}—${NC} skipped${_merge_detail:+ (${_merge_detail})}"
                    ;;
                CONFLICT)
                    echo -e "    merge:    ${YELLOW}⚠${NC} ${session_name} → ${target_branch} would conflict${_conflict_files:+ ($_conflict_files)}"
                    _conflicts=$((_conflicts + 1))
                    ;;
            esac
        fi

        # Action line for repos needing attention
        if [[ "$_ext_status" == "diverged" ]]; then
            echo -e "    action:   claude-container pull -s ${session_name} --force"
            echo -e "         or:  claude-container push -s ${session_name} ${target_branch:-main} --merge"
        elif [[ "$_merge_status" == "CONFLICT" ]]; then
            echo -e "    action:   claude-container pull -s ${session_name} ${target_branch} --no-squash"
            echo -e "         or:  claude-container pull -s ${session_name} ${target_branch} --reconcile"
        fi
    done

    # Summary
    echo ""
    local _summary_parts=()
    if [[ $_pulled -gt 0 ]]; then
        _summary_parts+=("$_pulled pulled${target_branch:+ into $target_branch}")
    fi
    if [[ $_unchanged -gt 0 ]]; then
        _summary_parts+=("$_unchanged unchanged")
    fi
    if [[ $_needs_attention -gt 0 ]]; then
        _summary_parts+=("$_needs_attention needs attention")
    fi
    if [[ $_conflicts -gt 0 ]]; then
        _summary_parts+=("$_conflicts would conflict")
    fi

    if [[ ${#_summary_parts[@]} -gt 0 ]]; then
        local _summary_line
        _summary_line=$(IFS=', '; echo "${_summary_parts[*]}")
        if [[ $_needs_attention -eq 0 && $_conflicts -eq 0 ]]; then
            success "$_summary_line"
        else
            warn "$_summary_line"
        fi
    else
        info "No repos processed"
    fi
}

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

    info "Checking session '$session_name'..."
    echo ""

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

        # Build hash display line
        local _short_c="${_s_head:0:7}"
        local _hash_line="  container:${_short_c}"

        if [[ -z "$_path" || ! -d "$_path" ]]; then
            echo -e "  ${BLUE}$_name${NC}  ${_hash_line}"
            echo -e "    status:   ${YELLOW}⚠${NC} host path missing"
            _not_extracted=$((_not_extracted + 1))
            continue
        fi

        # Compare with host session branch
        local _h_head=""
        if git -C "$_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
            _h_head=$(git -C "$_path" rev-parse "refs/heads/$session_name" 2>/dev/null)
        fi
        local _short_h="${_h_head:0:7}"
        [[ -n "$_h_head" ]] && _hash_line="${_hash_line}  session:${_short_h}"

        # Also show target branch HEAD if it exists
        local _t_head=""
        _t_head=$(git -C "$_path" rev-parse "refs/heads/main" 2>/dev/null || echo "")
        [[ -n "$_t_head" ]] && _hash_line="${_hash_line}  main:${_t_head:0:7}"

        echo -e "  ${BLUE}$_name${NC}  ${_hash_line}"

        if [[ -z "$_h_head" ]]; then
            echo -e "    status:   ${YELLOW}⚠${NC} not yet extracted"
            _not_extracted=$((_not_extracted + 1))
        elif [[ "$_s_head" == "$_h_head" ]]; then
            echo -e "    status:   ${GREEN}✓${NC} up to date"
            _up_to_date=$((_up_to_date + 1))
        elif git -C "$_path" merge-base --is-ancestor "$_h_head" "$_s_head" 2>/dev/null; then
            local _ahead
            _ahead=$(git -C "$_path" rev-list --count "$_h_head".."$_s_head" 2>/dev/null || echo "?")
            echo -e "    status:   ${BLUE}→${NC} container ahead by $_ahead commit(s)"
            _changed=$((_changed + 1))
        elif git -C "$_path" merge-base --is-ancestor "$_s_head" "$_h_head" 2>/dev/null; then
            local _ahead
            _ahead=$(git -C "$_path" rev-list --count "$_s_head".."$_h_head" 2>/dev/null || echo "?")
            echo -e "    status:   ${BLUE}←${NC} host ahead by $_ahead commit(s)"
            _changed=$((_changed + 1))
        else
            local _merge_base
            _merge_base=$(git -C "$_path" merge-base "$_h_head" "$_s_head" 2>/dev/null || echo "")
            local _c_ahead=0 _h_ahead=0
            if [[ -n "$_merge_base" ]]; then
                _c_ahead=$(git -C "$_path" rev-list --count "$_merge_base".."$_s_head" 2>/dev/null || echo "?")
                _h_ahead=$(git -C "$_path" rev-list --count "$_merge_base".."$_h_head" 2>/dev/null || echo "?")
            fi
            echo -e "    status:   ${YELLOW}⚠${NC} diverged (container +${_c_ahead}, host +${_h_ahead})"
            _diverged=$((_diverged + 1))
        fi
    done

    # Summary
    echo ""
    local _parts=()
    [[ $_up_to_date -gt 0 ]] && _parts+=("$_up_to_date up to date")
    [[ $_changed -gt 0 ]] && _parts+=("$_changed changed")
    [[ $_diverged -gt 0 ]] && _parts+=("$_diverged diverged")
    [[ $_not_extracted -gt 0 ]] && _parts+=("$_not_extracted not extracted")

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

    local _total_files=0 _total_adds=0 _total_dels=0

    while IFS='|' read -r _pname _ppath; do
        [[ -z "$_pname" ]] && continue
        [[ -n "$repo_filter" && "$_pname" != *"$repo_filter"* ]] && continue
        [[ ! -d "$_ppath" ]] && continue

        # Check session branch exists and target branch exists
        git -C "$_ppath" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null || continue
        git -C "$_ppath" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null || continue

        # Get diffstat between target and session
        local _stat
        _stat=$(git -C "$_ppath" diff --stat "$target_branch".."$session_name" 2>/dev/null)
        [[ -z "$_stat" ]] && continue

        # Parse summary line for totals
        local _summary
        _summary=$(echo "$_stat" | tail -1)

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
    else
        info "No changes to merge"
    fi
    # Return total files so caller can skip prompt if 0
    return $(( _total_files > 0 ? 0 : 1 ))
}

# Preview what reconcile would do — compact, only shows repos needing attention
_pull_reconcile_preview() {
    local session_name="$1"
    local target_branch="$2"
    local repo_filter="${3:-}"
    local show_prompt="${4:-false}"
    local volume="claude-session-${session_name}"

    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    info "Reconcile preview: '$session_name' ↔ '$target_branch'"
    echo ""

    # Read config
    local config_content
    config_content=$(read_session_config "$volume")
    if [[ -z "$config_content" ]]; then
        error "No config in session"
        return 1
    fi
    local projects
    projects=$(parse_session_projects "$config_content")

    # Get session scan (dirty/merge status)
    local _util_image="${GIT_UTIL_IMAGE:-alpine/git}"
    local _merge_scan
    _merge_scan=$(docker run --rm --entrypoint sh \
        -e HOME=/tmp \
        -v "$volume:/session:ro" "$_util_image" \
        -c '
            git config --global --add safe.directory "*"
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"; name="${name%/}"
                merging="no"
                [ -f "$d/.git/MERGE_HEAD" ] && merging="yes"
                dirty=$(cd "$d" && git status --porcelain 2>/dev/null | wc -l | tr -d " ")
                echo "$name|$merging|$dirty"
            done
        ' 2>/dev/null) || true

    declare -A _merge_status _dirty_count
    while IFS='|' read -r _sname _smerge _sdirty; do
        [[ -z "$_sname" ]] && continue
        _merge_status[$_sname]="$_smerge"
        _dirty_count[$_sname]="$_sdirty"
    done <<< "$_merge_scan"

    # Dry-run session→main merge (same detection as pull --verify)
    local _preview_dir
    _preview_dir=$(mktemp -d)
    session_auto_merge "$session_name" "$target_branch" true "$repo_filter" true "$_preview_dir" 2>/dev/null || true

    # Unified per-repo view: combine both directions
    local _needs_claude=0 _would_merge=0 _would_conflict=0 _up_to_date=0
    local -a _rev_conflict_repos=() _rev_conflict_files=()

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        [[ -n "$repo_filter" && "$proj_name" != *"$repo_filter"* ]] && continue

        # Gather inbound status (main→session)
        local _in_status=""
        if [[ ! -d "$proj_path" ]]; then
            _in_status="skip:host not found"
        elif ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
            _in_status="skip:no $target_branch"
        elif [[ "${_merge_status[$proj_name]:-no}" == "yes" ]]; then
            _in_status="conflict:merge in progress"
        elif [[ "${_dirty_count[$proj_name]:-0}" -gt 0 ]]; then
            _in_status="dirty:${_dirty_count[$proj_name]} uncommitted file(s)"
        else
            _in_status="clean"
        fi

        # Gather outbound status (session→main)
        local _out_status _out_detail _out_files
        _out_status=$(_pull_result_get "$_preview_dir" "$proj_name" "merge_status")
        _out_detail=$(_pull_result_get "$_preview_dir" "$proj_name" "merge_detail")
        _out_files=$(_pull_result_get "$_preview_dir" "$proj_name" "conflict_files")

        # Skip repos that are clean in both directions
        if [[ "$_in_status" == "clean" ]]; then
            case "$_out_status" in
                ""|OK)
                    case "$_out_detail" in
                        "already up to date"|"squash-merged (no new"*|"content identical"*)
                            _up_to_date=$((_up_to_date + 1))
                            continue
                            ;;
                    esac
                    ;;
            esac
        fi

        # Show this repo — it needs attention
        local _short_session _short_main
        _short_session=$(git -C "$proj_path" rev-parse --short "$session_name" 2>/dev/null || echo "?")
        _short_main=$(git -C "$proj_path" rev-parse --short "$target_branch" 2>/dev/null || echo "?")
        echo -e "  ${BLUE}$proj_name${NC}  session:${_short_session}  ${target_branch}:${_short_main}"

        # Inbound line
        case "$_in_status" in
            clean)
                echo -e "    ${target_branch} → session:  ${GREEN}✓${NC} clean"
                ;;
            dirty:*)
                echo -e "    ${target_branch} → session:  ${YELLOW}⚠${NC} ${_in_status#dirty:} (Claude commits first)"
                _needs_claude=$((_needs_claude + 1))
                ;;
            conflict:*)
                echo -e "    ${target_branch} → session:  ${YELLOW}⚠${NC} ${_in_status#conflict:}"
                _needs_claude=$((_needs_claude + 1))
                ;;
            skip:*)
                echo -e "    ${target_branch} → session:  ${YELLOW}⚠${NC} skipped (${_in_status#skip:})"
                ;;
        esac

        # Outbound line
        case "$_out_status" in
            OK)
                case "$_out_detail" in
                    "would squash-merge"*|"would merge"*|"would fast-forward"*)
                        echo -e "    session → ${target_branch}:  ${GREEN}✓${NC} $_out_detail"
                        _would_merge=$((_would_merge + 1))
                        ;;
                    *)
                        echo -e "    session → ${target_branch}:  ${BLUE}—${NC} $_out_detail"
                        ;;
                esac
                ;;
            CONFLICT)
                echo -e "    session → ${target_branch}:  ${RED}✗${NC} would conflict${_out_files:+ ($_out_files)}"
                _would_conflict=$((_would_conflict + 1))
                _rev_conflict_repos+=("$proj_name")
                _rev_conflict_files+=("${_out_files:-?}")
                # Diffstat
                local _stat
                _stat=$(git -C "$proj_path" diff --stat "$target_branch".."$session_name" 2>/dev/null)
                if [[ -n "$_stat" ]]; then
                    echo "$_stat" | sed '$d' | sed 's/^/      /'
                    echo "      $(echo "$_stat" | tail -1)"
                fi
                ;;
            SKIP)
                echo -e "    session → ${target_branch}:  ${YELLOW}⚠${NC} skipped${_out_detail:+ ($_out_detail)}"
                ;;
            "")
                # No merge result — repo not in session or filtered out
                ;;
        esac
        echo ""
    done <<< "$projects"

    rm -rf "$_preview_dir"

    # Summary
    [[ $_up_to_date -gt 0 ]] && info "$_up_to_date repo(s) up to date (hidden)"
    [[ $_would_merge -gt 0 ]] && success "$_would_merge would merge into $target_branch"
    [[ $_would_conflict -gt 0 ]] && warn "$_would_conflict would CONFLICT merging into $target_branch — Claude will be instructed to fix"
    [[ $_needs_claude -gt 0 ]] && warn "$_needs_claude need Claude's attention in container"

    # Build and show Claude's prompt (only with --show-prompt)
    if [[ "$show_prompt" == "true" ]] && [[ $((_needs_claude + _would_conflict)) -gt 0 ]]; then
        echo ""
        info "=== Claude's prompt ==="
        echo ""

        local _prompt="Branch '$target_branch' was merged into this session. Here is what happened:"
        _prompt+=$'\n'

        # Inbound status per repo
        while IFS='|' read -r proj_name proj_path; do
            [[ -z "$proj_name" ]] && continue
            [[ -n "$repo_filter" && "$proj_name" != *"$repo_filter"* ]] && continue
            local _dc="${_dirty_count[$proj_name]:-0}"
            if [[ "${_merge_status[$proj_name]:-no}" == "yes" ]]; then
                _prompt+=$'\n'"  CONFLICT: $proj_name (merge in progress)"
            elif [[ "$_dc" -gt 0 ]]; then
                _prompt+=$'\n'"  DIRTY: $proj_name ($_dc uncommitted changes)"
            fi
        done <<< "$projects"

        # Reverse conflicts
        if [[ ${#_rev_conflict_repos[@]} -gt 0 ]]; then
            _prompt+=$'\n\n'"=== REVERSE MERGE CONFLICTS ==="
            _prompt+=$'\n'"${#_rev_conflict_repos[@]} project(s) will conflict when merging session back into '$target_branch'."
            _prompt+=$'\n'"The host '$target_branch' branch is mounted read-only at /host/{project_name}."
            for _i in "${!_rev_conflict_repos[@]}"; do
                _prompt+=$'\n'"  ${_rev_conflict_repos[$_i]}: ${_rev_conflict_files[$_i]}"
            done
            _prompt+=$'\n\n'"For each reverse-conflict project:"
            _prompt+=$'\n'"1. cd /workspace/{project_name}"
            _prompt+=$'\n'"2. git remote add host /host/{project_name} && git fetch host $target_branch"
            _prompt+=$'\n'"3. git merge host/$target_branch --no-edit"
            _prompt+=$'\n'"4. Resolve conflicts — goal is session contains everything from $target_branch"
            _prompt+=$'\n'"5. git add && git commit"
            _prompt+=$'\n'"6. git remote remove host"
            _prompt+=$'\n\n'"After this, host can fast-forward $target_branch to session — no more squash conflicts."
        fi

        _prompt+=$'\n\n'"When finished: fin \"<brief description>\""

        echo "$_prompt"
    fi
}

_pull_reconcile() {
    local session_name="$1"
    local target_branch="$2"
    local force="$3"
    local verify="${4:-false}"
    local volume="claude-session-${session_name}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    # Phase 1: Extract session branches to host repos (quiet — result-dir suppresses legacy output)
    local _reconcile_result_dir
    _reconcile_result_dir=$(mktemp -d)
    info "Extracting session branches..."
    if [[ "$force" == "true" ]]; then
        session_extract "$session_name" --force --result-dir "$_reconcile_result_dir"
    else
        session_extract "$session_name" --result-dir "$_reconcile_result_dir"
    fi

    # Phase 2: Stash dirty worktrees on host
    _pull_stash_dirty "$session_name" "$target_branch"
    echo ""

    # Phase 3: Merge target INTO session (inside docker volume)
    # session_merge_into returns:
    #   1 = clean merge, no container needed
    #   0 = conflicts/dirty, needs container with Claude
    info "Phase 3: Merging '$target_branch' into session..."
    if ! session_merge_into "$session_name" "$target_branch"; then
        # Clean merge — extract resolved state and auto-merge into target
        info "Clean merge — extracting and merging into '$target_branch'..."
        session_extract "$session_name" --force
        echo ""

        if [[ "$verify" == "true" ]]; then
            # Show dry-run before merging
            info "Dry-run merge into '$target_branch':"
            session_auto_merge "$session_name" "$target_branch" true
            echo ""
            printf "Merge into '%s'? [y/N] " "$target_branch"
            local _answer
            read -r _answer
            case "$_answer" in
                [yY]|[yY][eE][sS])
                    info "Merging..."
                    ;;
                *)
                    info "Aborted. Session branches extracted but not merged into $target_branch."
                    # Clean up marker
                    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
                    docker run --rm -v "$volume:/session" "$git_image" \
                        rm -f /session/.merge-into-branch 2>/dev/null || true
                    return 0
                    ;;
            esac
        fi

        session_auto_merge "$session_name" "$target_branch"

        # Clean up the .merge-into-branch marker (session_merge_into wrote it)
        local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
        docker run --rm -v "$volume:/session" "$git_image" \
            rm -f /session/.merge-into-branch 2>/dev/null || true
        return 0
    fi

    # Conflicts detected — session_merge_into already wrote:
    #   .merge-into-branch  (target branch name)
    #   .merge-into-summary (Claude's initial prompt with fin instructions)
    #   .merge-into-mounts  (dirty projects needing host mounts)

    # If --verify, write marker so the exit handler knows to prompt
    if [[ "$verify" == "true" ]]; then
        local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
        docker run --rm -v "$volume:/session" "$git_image" \
            sh -c "echo 1 > /session/.merge-verify" 2>/dev/null || true
    fi

    # Exec back into claude-container to launch container for resolution
    info "Launching container for conflict resolution..."
    echo ""
    exec "$0" --session "$session_name" --auto-merge
}

_pull_stash_dirty() {
    local session_name="$1"
    local target_branch="$2"
    local volume="claude-session-${session_name}"

    local config_content
    config_content=$(read_session_config "$volume")
    [[ -z "$config_content" ]] && return 0

    local projects
    projects=$(parse_session_projects "$config_content")
    [[ -z "$projects" ]] && return 0

    local stash_count=0
    local timestamp
    timestamp=$(date +%s)

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        [[ ! -d "$proj_path" ]] && continue

        local dirty
        dirty=$(git -C "$proj_path" status --porcelain 2>/dev/null)
        [[ -z "$dirty" ]] && continue

        local stash_branch="${target_branch}-${session_name}-stash-${timestamp}"
        local current_branch
        current_branch=$(git -C "$proj_path" symbolic-ref --short HEAD 2>/dev/null || echo "")

        info "  $proj_name: stashing uncommitted work"

        git -C "$proj_path" checkout -b "$stash_branch" >/dev/null 2>&1
        git -C "$proj_path" add -A >/dev/null 2>&1
        git -C "$proj_path" commit -m "WIP: stashed by reconcile (session: $session_name)" --no-verify >/dev/null 2>&1
        if [[ -n "$current_branch" ]]; then
            git -C "$proj_path" checkout "$current_branch" >/dev/null 2>&1
        fi

        stash_count=$((stash_count + 1))
    done <<< "$projects"

    if [[ $stash_count -gt 0 ]]; then
        success "  Stashed $stash_count repo(s)"
    else
        info "  All host repos clean"
    fi
}

_pull_help() {
    cat <<EOF
Usage: claude-container pull -s <session> [branch] [options]

Pull session changes from container to host (container → host).

Arguments:
  branch                   Target branch to merge into (omit for extract-only)

Options:
  --session, -s <name>     Session name (required)
  --repo <name>            Only pull this repo (partial name OK, e.g. 'gamma')
  --status                 Read-only check: compare container vs host (no extraction)
  --reconcile, -R          Full reconcile: stash dirty, merge target into session,
                           launch Claude for conflicts, then merge back
  --squash                 Squash-merge (default). Tracks prior squashes so repeat pulls
                           only merge new commits — no conflicts from squash history.
  --no-squash              Regular merge. Preserves full session commit history on target.
  --verify                 Extract and show results, then ask before merging
  --dry-run                Show what would happen without extracting or merging
  --force, -f              Force extraction even if branches diverged (container wins)
  --help, -h               Show this help

Modes:
  No branch (default)  Extract session branches to host repos only.
  With branch          Extract + auto-merge into the target branch.
                       Only clean merges are performed — repos that would conflict
                       are skipped, and you'll be told to resolve in-container first.
  --status             Read-only check: shows which repos have changed, diverged,
                       or need extraction. No modifications made.
  --reconcile          Extract → stash dirty → merge target into session →
                       resolve conflicts (launches container if needed) → merge back.

Safety:
  Merging into a non-session branch (e.g. main) will only proceed if the merge
  would complete without conflicts. If conflicts are detected, the repo is
  skipped and you'll see:

    claude-container pull -s <session> <branch> --reconcile

  This ensures conflicts are always resolved in the container where Claude can
  help, never on the host where they'd block you.

Examples:
  # Check what's changed (read-only)
  claude-container pull -s myproj --status

  # Extract session branches to host repos
  claude-container pull -s myproj

  # Extract and merge into main (skips repos that would conflict)
  claude-container pull -s myproj main

  # Extract and merge into develop
  claude-container pull -s myproj develop

  # Full reconcile cycle against main
  claude-container pull -s myproj main --reconcile

  # Preview what would happen (no changes made)
  claude-container pull -s myproj main --dry-run

  # Pull a single repo
  claude-container pull -s myproj --repo gamma
  claude-container pull -s myproj main --repo plexus-gamma

  # Force extraction (overwrite diverged branches)
  claude-container pull -s myproj --force

Recommended workflow:
  1. push -s X main --merge   # merge main INTO session (Claude resolves conflicts)
  2. pull -s X                # extract session branches to host
  3. pull -s X main           # merge into main (guaranteed clean, session has main)
EOF
}
