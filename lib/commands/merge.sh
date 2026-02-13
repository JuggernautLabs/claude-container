#!/usr/bin/env bash
# Subcommand: merge
# Extract session branches and merge into host branches
#
# Usage:
#   claude-container merge -s <session> [options]
#   claude-container merge -s myproj                # extract + merge into session branch
#   claude-container merge -s myproj --branch main  # extract + merge into main
#   claude-container merge -s myproj --verify       # check sync status (read-only)

cmd_merge() {
    warn "Deprecated: use 'pull', 'push', or 'status' subcommands instead"
    echo "  merge --branch <b>       → pull -s <session> <b>"
    echo "  merge --reconcile <b>    → pull -s <session> <b> --reconcile"
    echo "  merge --check <b>        → status -s <session> <b>"
    echo "  merge --verify           → status -s <session>"
    echo ""

    local session_name=""
    local target_branch=""
    local verify=false
    local force=false
    local reconcile_branch=""
    local check_branch=""
    local check_repo=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --branch|-b)
                target_branch="$2"
                shift 2
                ;;
            --reconcile|-R)
                reconcile_branch="$2"
                shift 2
                ;;
            --check|-c)
                check_branch="$2"
                shift 2
                ;;
            --repo)
                check_repo="$2"
                shift 2
                ;;
            --verify)
                verify=true
                shift
                ;;
            --force|-f)
                force=true
                shift
                ;;
            --help|-h)
                _merge_help
                return 0
                ;;
            *)
                error "Unknown option: $1"
                echo "Run 'claude-container merge --help' for usage"
                return 1
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Session name required: use --session <name>"
        echo "Run 'claude-container merge --help' for usage"
        return 1
    fi

    # Default target branch to session name
    if [[ -z "$target_branch" ]]; then
        target_branch="$session_name"
    fi

    # Check mode: compare session commit hashes against host branch
    if [[ -n "$check_branch" ]]; then
        _merge_check "$session_name" "$check_branch" "$check_repo"
        return $?
    fi

    # Reconcile mode: extract, stash dirty, merge target into session, resolve conflicts
    if [[ -n "$reconcile_branch" ]]; then
        _merge_reconcile "$session_name" "$reconcile_branch" "$force"
        return $?
    fi

    if $verify; then
        _merge_verify "$session_name" "$target_branch"
        return $?
    fi

    # Extract session branches to host repos
    local extract_args=("$session_name")
    if $force; then
        extract_args+=(--force)
    fi
    session_extract "${extract_args[@]}"

    echo ""

    # Merge into target branch
    session_auto_merge "$session_name" "$target_branch"
}

_merge_check() {
    local session_name="$1"
    local check_branch="$2"
    local filter_repo="$3"
    local volume="claude-session-${session_name}"

    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for check"
        return 1
    fi

    local config=$(read_session_config "$volume")
    local projects=$(parse_session_projects "$config")
    local heads=$(get_session_heads "$volume")

    if [[ -z "$heads" ]]; then
        warn "No git repos found in session volume"
        return 1
    fi

    local match=0
    local mismatch=0
    local no_branch=0
    local missing=0
    local total=0
    local has_mismatch=false

    while IFS='|' read -r repo_name session_head; do
        [[ -z "$repo_name" ]] && continue

        # Filter to specific repo if requested
        if [[ -n "$filter_repo" ]]; then
            # Match on full name or basename
            local _basename="${repo_name##*/}"
            if [[ "$repo_name" != "$filter_repo" ]] && [[ "$_basename" != "$filter_repo" ]]; then
                continue
            fi
        fi

        total=$((total + 1))
        local host_path
        host_path=$(resolve_repo_host_path "$repo_name" "$projects")

        if [[ ! -d "$host_path" ]]; then
            echo "  $repo_name"
            echo "    session: ${session_head:0:12}"
            echo "    host:    (repo not found: $host_path)"
            echo "    result:  MISSING"
            missing=$((missing + 1))
            has_mismatch=true
            continue
        fi

        local host_head=""
        if git -C "$host_path" show-ref --verify --quiet "refs/heads/$check_branch" 2>/dev/null; then
            host_head=$(git -C "$host_path" rev-parse "refs/heads/$check_branch" 2>/dev/null)
        fi

        if [[ -z "$host_head" ]]; then
            echo "  $repo_name"
            echo "    session: ${session_head:0:12}"
            echo "    host:    (no branch '$check_branch')"
            echo "    result:  NO BRANCH"
            no_branch=$((no_branch + 1))
            continue
        fi

        if [[ "$session_head" == "$host_head" ]]; then
            success "  $repo_name"
            echo "    hash:    ${session_head:0:12}"
            echo "    result:  MATCH"
            match=$((match + 1))
        else
            warn "  $repo_name"
            echo "    session: ${session_head:0:12}"
            echo "    host:    ${host_head:0:12}"
            # Show ancestry info
            if git -C "$host_path" merge-base --is-ancestor "$session_head" "$host_head" 2>/dev/null; then
                echo "    result:  MISMATCH (host ahead)"
            elif git -C "$host_path" cat-file -t "$session_head" &>/dev/null && \
                 git -C "$host_path" merge-base --is-ancestor "$host_head" "$session_head" 2>/dev/null; then
                echo "    result:  MISMATCH (session ahead)"
            else
                echo "    result:  MISMATCH (diverged)"
            fi
            mismatch=$((mismatch + 1))
            has_mismatch=true
        fi
    done <<< "$heads"

    if [[ $total -eq 0 ]]; then
        if [[ -n "$filter_repo" ]]; then
            error "Repo '$filter_repo' not found in session"
        else
            warn "No repos found"
        fi
        return 1
    fi

    echo ""
    echo "  $match match, $mismatch mismatch, $no_branch no-branch, $missing missing (of $total)"

    $has_mismatch && return 1
    return 0
}

_merge_reconcile() {
    local session_name="$1"
    local target_branch="$2"
    local force="$3"
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
    _reconcile_stash_dirty "$session_name" "$target_branch"
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
    # Exec back into claude-container to launch container for resolution
    info "Launching container for conflict resolution..."
    echo ""
    exec "$0" --session "$session_name" --auto-merge
}

_reconcile_stash_dirty() {
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

_merge_verify() {
    local session_name="$1"
    local target_branch="$2"
    local volume="claude-session-${session_name}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for merge verify"
        return 1
    fi

    # Read config and scan volume using shared discovery functions
    local config=$(read_session_config "$volume")
    local projects=$(parse_session_projects "$config")
    local heads=$(get_session_heads "$volume")

    if [[ -z "$heads" ]]; then
        warn "No git repos found in session volume"
        return 0
    fi

    # Build ordered lists of repos, heads, and resolved paths
    local _all_names=()
    local _all_heads=()
    local _all_paths=()
    while IFS='|' read -r repo_name repo_head; do
        [[ -z "$repo_name" ]] && continue
        [[ "$repo_head" == "MISSING" ]] && continue
        _all_names+=("$repo_name")
        _all_heads+=("$repo_head")
        _all_paths+=("$(resolve_repo_host_path "$repo_name" "$projects")")
    done <<< "$heads"

    if [[ ${#_all_names[@]} -eq 0 ]]; then
        warn "No repos found in session"
        return 0
    fi

    info "Verifying session '$session_name' against '$target_branch'"
    echo ""

    local synced=0
    local unchanged=0
    local extracted_only=0
    local not_extracted=0
    local missing=0

    local i=0
    for proj_name in "${_all_names[@]}"; do
        local session_head="${_all_heads[$i]}"
        local proj_path="${_all_paths[$i]}"
        i=$((i + 1))

        local status
        status=$(check_repo_sync_status "$session_head" "$proj_path" "$session_name" "$target_branch")

        case "$status" in
            missing)
                echo "  $proj_name: missing (repo not found: $proj_path)"
                missing=$((missing + 1))
                ;;
            unchanged)
                success "  $proj_name: unchanged"
                unchanged=$((unchanged + 1))
                ;;
            synced)
                success "  $proj_name: synced"
                synced=$((synced + 1))
                ;;
            extracted_only)
                warn "  $proj_name: extracted but not merged into $target_branch"
                extracted_only=$((extracted_only + 1))
                ;;
            not_extracted)
                echo "  $proj_name: not extracted"
                not_extracted=$((not_extracted + 1))
                ;;
        esac
    done

    echo ""
    local total=${#_all_names[@]}
    local ok=$((synced + unchanged))
    echo "  $ok/$total ok ($synced synced, $unchanged unchanged), $extracted_only extracted-only, $not_extracted pending, $missing missing"

    if [[ $not_extracted -gt 0 ]] || [[ $missing -gt 0 ]]; then
        return 1
    fi
    return 0
}

_merge_help() {
    cat <<EOF
Usage: claude-container merge -s <session> [options]

Extract session branches from container volumes and merge them into
host repository branches.

Options:
  --session, -s <name>     Session name (required)
  --branch, -b <branch>    Target branch to merge into (default: session name)
  --check, -c <branch>     Compare session commit hashes against host <branch>
  --repo <name>            Filter --check to a single repo (name or basename)
  --reconcile, -R <branch> Reconcile: stash dirty work, merge <branch> into session,
                           launch Claude for conflicts, then merge back
  --verify                 Check sync status without making changes
  --force, -f              Force extraction even if branches diverged
  --help, -h               Show this help

Examples:
  # Extract and merge into session-named branches
  claude-container merge -s myproj

  # Extract and merge into main
  claude-container merge -s myproj --branch main

  # Compare session hashes against host main branch
  claude-container merge -s myproj --check main

  # Check a single repo
  claude-container merge -s myproj --check main --repo synapse

  # Full reconcile cycle against main (handles dirty repos + conflicts)
  claude-container merge -s myproj --reconcile main

  # Check if everything is synced
  claude-container merge -s myproj --verify

  # Force extraction (overwrite diverged branches)
  claude-container merge -s myproj --force
EOF
}
