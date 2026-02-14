#!/usr/bin/env bash
# Subcommand: status
# Check session sync state (read-only)
#
# Usage:
#   claude-container status -s <session> [branch] [options]
#   claude-container status -s myproj                    # sync state classification
#   claude-container status -s myproj main               # hash comparison against main
#   claude-container status -s myproj main --repo foo    # single repo check

cmd_status() {
    local session_name=""
    local branch=""
    local filter_repo=""
    local check_dirty=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --repo)
                filter_repo="$2"
                shift 2
                ;;
            --dirty)
                check_dirty=true
                shift
                ;;
            --help|-h)
                _status_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container status --help' for usage"
                return 1
                ;;
            *)
                # Positional arg = branch name
                if [[ -z "$branch" ]]; then
                    branch="$1"
                else
                    error "Unexpected argument: $1"
                    echo "Run 'claude-container status --help' for usage"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Session name required: use --session <name>"
        echo "Run 'claude-container status --help' for usage"
        return 1
    fi

    if $check_dirty; then
        _status_dirty "$session_name" "$filter_repo"
    elif [[ -n "$branch" ]]; then
        _status_check "$session_name" "$branch" "$filter_repo"
    else
        _status_verify "$session_name"
    fi
}

_status_check() {
    local session_name="$1"
    local check_branch="$2"
    local filter_repo="$3"
    local volume="claude-session-${session_name}"

    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for status check"
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

_status_verify() {
    local session_name="$1"
    local target_branch="$session_name"
    local volume="claude-session-${session_name}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for status verify"
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
                warn "  $proj_name: extracted but not merged"
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

_status_dirty() {
    local session_name="$1"
    local filter_repo="$2"
    local volume="claude-session-${session_name}"

    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for status check"
        return 1
    fi

    local config=$(read_session_config "$volume")
    local projects=$(parse_session_projects "$config")

    if [[ -z "$projects" ]]; then
        warn "No projects found in session config"
        return 1
    fi

    info "Checking host repos for uncommitted changes..."
    echo ""

    local dirty_count=0
    local clean_count=0
    local total=0

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue

        # Apply repo filter (exact or suffix match)
        if [[ -n "$filter_repo" ]]; then
            local _basename="${proj_name##*/}"
            if [[ "$proj_name" != "$filter_repo" && "$_basename" != "$filter_repo" ]]; then
                continue
            fi
        fi

        total=$((total + 1))

        if [[ ! -d "$proj_path" ]]; then
            warn "  $proj_name: not found ($proj_path)"
            continue
        fi

        local porcelain
        porcelain=$(git -C "$proj_path" status --porcelain 2>/dev/null)

        if [[ -z "$porcelain" ]]; then
            clean_count=$((clean_count + 1))
            continue
        fi

        local file_count
        file_count=$(echo "$porcelain" | wc -l | tr -d ' ')
        dirty_count=$((dirty_count + 1))

        warn "  $proj_name ($file_count files)"
        # Show first few files indented
        echo "$porcelain" | head -5 | while IFS= read -r line; do
            echo "    $line"
        done
        local remaining=$((file_count - 5))
        if [[ $remaining -gt 0 ]]; then
            echo "    ... and $remaining more"
        fi
    done <<< "$projects"

    echo ""
    if [[ $dirty_count -gt 0 ]]; then
        warn "$dirty_count/$total repo(s) have uncommitted changes"
        return 1
    else
        success "All $total repo(s) clean"
        return 0
    fi
}

_status_help() {
    cat <<EOF
Usage: claude-container status -s <session> [branch] [options]

Check session sync state (read-only, no changes made).

Arguments:
  branch                   Compare session against this host branch

Options:
  --session, -s <name>     Session name (required)
  --repo <name>            Filter to a single repo (name or basename)
  --dirty                  Check which host repos have uncommitted changes
  --help, -h               Show this help

Modes:
  No branch        Verify sync state: classifies each repo as
                   synced/unchanged/extracted-only/not-extracted/missing.
  With branch      Hash comparison: compares session HEAD against host branch
                   with ancestry info (host ahead, session ahead, diverged).
  --dirty          Show repos with uncommitted changes on the host.
                   These block pull/auto-merge operations.

Exit code: 0 = all match/synced, 1 = at least one mismatch or pending.

Examples:
  # Check sync state of all repos
  claude-container status -s myproj

  # Compare session against host main branch
  claude-container status -s myproj main

  # Check a single repo against main
  claude-container status -s myproj main --repo synapse

  # Check which repos have uncommitted changes
  claude-container status -s myproj --dirty

  # Check a specific repo for dirty state
  claude-container status -s myproj --dirty --repo synapse

Migration from old commands:
  merge -s X --check main            →  status -s X main
  merge -s X --check main --repo Y   →  status -s X main --repo Y
  merge -s X --verify                →  status -s X
EOF
}
