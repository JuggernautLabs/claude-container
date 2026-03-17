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
        # Reconcile uses legacy (non-unified) output
        _pull_reconcile "$session_name" "$branch" "$force" "$verify"
        return $?
    fi

    if $dry_run; then
        # Dry-run: check what would happen without extracting or merging
        session_auto_merge "$session_name" "$branch" true "$repo_filter" "$squash"
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

    if $verify && [[ -n "$branch" ]]; then
        # --verify: show extract results + diffstat per repo, ask before merging
        echo ""
        _pull_report "$session_name" "" "$_pull_result_dir" "$repo_filter"

        echo ""
        info "Changes that would land on '$branch':"
        echo ""
        if ! _verify_diffstat "$session_name" "$branch" "$_pull_result_dir" "$repo_filter"; then
            info "Nothing to merge."
            return 0
        fi

        echo ""
        printf "Merge into '%s'? [y/N] " "$branch"
        local _answer
        read -r _answer
        case "$_answer" in
            [yY]|[yY][eE][sS])
                info "Merging..."
                ;;
            *)
                info "Aborted. Session branches are extracted but not merged."
                info "To merge later: claude-container pull -s $session_name $branch"
                return 0
                ;;
        esac
    fi

    # If branch specified, merge into target with result tracking
    local _merge_rc=0
    if [[ -n "$branch" ]]; then
        session_auto_merge "$session_name" "$branch" false "$repo_filter" "$squash" "$_pull_result_dir" || _merge_rc=$?
    fi

    # Render unified report
    echo ""
    _pull_report "$session_name" "$branch" "$_pull_result_dir" "$repo_filter"
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

    # Phase 1: Extract session branches to host repos
    info "Phase 1: Extracting session branches..."
    if [[ "$force" == "true" ]]; then
        session_extract "$session_name" --force
    else
        session_extract "$session_name"
    fi
    echo ""

    # Phase 2: Stash dirty worktrees on host
    info "Phase 2: Checking host repos for uncommitted work..."
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

        info "  $proj_name: stashing to branch '$stash_branch'"

        git -C "$proj_path" checkout -b "$stash_branch" 2>/dev/null
        git -C "$proj_path" add -A 2>/dev/null
        git -C "$proj_path" commit -m "WIP: stashed by reconcile (session: $session_name)" --no-verify 2>/dev/null
        if [[ -n "$current_branch" ]]; then
            git -C "$proj_path" checkout "$current_branch" 2>/dev/null
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
