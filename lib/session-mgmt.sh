#!/usr/bin/env bash
# claude-container session management module - List, delete, restart, diff, and merge sessions
# Source this file after utils.sh and git-ops.sh
#
# Dependencies:
#   - utils.sh must be sourced first (provides: info, success, warn, error)
#   - git-ops.sh must be sourced first (provides: diff_git_session, merge_git_session)
#
# This module provides functions for managing claude-container sessions:
#   - session_cleanup: Clean up all claude-container Docker volumes
#   - session_list: List all sessions with disk usage
#   - session_delete: Delete a specific session and its volumes
#   - session_restart: Restart a session with permission fixes
#   - session_diff: Show diff between session and source repo
#   - session_merge: Merge session commits back to source repo

# Clean up all claude-container resources (volumes)
# Usage: session_cleanup
session_cleanup() {
    echo "Cleaning up claude-container resources..."

    # List volumes
    local volumes
    volumes=$(docker volume ls -q | grep -E "^(claude-session-|claude-state-|claude-cargo-|claude-npm-|claude-pip-|session-data-)" || true)

    if [[ -z "$volumes" ]]; then
        echo "No volumes to clean up"
        return 0
    fi

    echo "Found volumes:"
    echo "$volumes" | sed 's/^/  /'
    echo ""

    read -p "Delete all? [y/n] " confirm
    if [[ "$confirm" == "y" ]]; then
        echo "$volumes" | xargs docker volume rm
        echo "Done"
    else
        echo "Cancelled"
    fi
}

# List all sessions with disk usage
# Usage: session_list
session_list() {
    # Get all claude volumes
    local all_volumes
    all_volumes=$(docker volume ls -q | grep -E "^(claude-session-|claude-state-|claude-cargo-|claude-npm-|claude-pip-)" || true)

    if [[ -z "$all_volumes" ]]; then
        echo "No claude-container sessions found."
        return 0
    fi

    # Extract unique session names
    declare -A sessions
    while read -r vol; do
        [[ -z "$vol" ]] && continue
        local session_name=""
        case "$vol" in
            claude-session-*) session_name="${vol#claude-session-}" ;;
            claude-state-*)   session_name="${vol#claude-state-}" ;;
            claude-cargo-*)   session_name="${vol#claude-cargo-}" ;;
            claude-npm-*)     session_name="${vol#claude-npm-}" ;;
            claude-pip-*)     session_name="${vol#claude-pip-}" ;;
        esac
        [[ -n "$session_name" ]] && sessions[$session_name]=1
    done <<< "$all_volumes"

    # Build mount arguments for all volumes at once
    echo "Scanning $(echo "$all_volumes" | wc -l | tr -d ' ') volumes..."
    local mount_args=""
    local vol_list=""
    while read -r vol; do
        [[ -z "$vol" ]] && continue
        mount_args="$mount_args -v $vol:/$vol:ro"
        vol_list="$vol_list $vol"
    done <<< "$all_volumes"

    # Get all sizes in one container run (much faster!)
    local sizes
    sizes=$(docker run --rm $mount_args alpine sh -c '
        for dir in /claude-*/; do
            [ -d "$dir" ] || continue
            name=$(basename "$dir")
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo "$name $size"
        done
    ' 2>/dev/null || echo "")

    # Parse sizes into associative array
    declare -A vol_sizes
    while read -r vol size; do
        [[ -z "$vol" ]] && continue
        vol_sizes[$vol]="$size"
    done <<< "$sizes"

    # Display table
    echo ""
    printf "%-30s %10s %10s %10s %10s %10s\n" "SESSION" "WORKSPACE" "STATE" "CARGO" "NPM" "PIP"
    printf "%-30s %10s %10s %10s %10s %10s\n" "-------" "---------" "-----" "-----" "---" "---"

    for session in $(echo "${!sessions[@]}" | tr ' ' '\n' | sort); do
        local ws="${vol_sizes[claude-session-$session]:-"-"}"
        local st="${vol_sizes[claude-state-$session]:-"-"}"
        local ca="${vol_sizes[claude-cargo-$session]:-"-"}"
        local np="${vol_sizes[claude-npm-$session]:-"-"}"
        local pi="${vol_sizes[claude-pip-$session]:-"-"}"
        printf "%-30s %10s %10s %10s %10s %10s\n" "$session" "$ws" "$st" "$ca" "$np" "$pi"
    done

    # Calculate total size across all volumes
    local total_human
    total_human=$(docker run --rm $mount_args alpine sh -c 'du -sch /claude-*/ 2>/dev/null | tail -1 | cut -f1' 2>/dev/null || echo "?")

    echo ""
    echo "Total disk usage: $total_human"
    echo ""
    echo "Commands:"
    echo "  Delete session:  ./claude-container --delete-session <name>"
    echo "  Delete all:      ./claude-container --cleanup"
}

# Delete a specific session and all its volumes
# Usage: session_delete <session_name>
session_delete() {
    local session="$1"

    if [[ -z "$session" ]]; then
        echo "Error: session_delete requires a session name"
        echo "Usage: session_delete <name>"
        return 1
    fi

    local deleted=false

    # Try to delete all possible volume patterns for this session
    for pattern in "claude-session-${session}" "claude-state-${session}" "claude-cargo-${session}" "claude-npm-${session}" "claude-pip-${session}" "session-data-${session}"; do
        if docker volume inspect "$pattern" &>/dev/null; then
            docker volume rm "$pattern"
            echo "Deleted: $pattern"
            deleted=true
        fi
    done

    if ! $deleted; then
        echo "No volumes found for session: $session"
        return 1
    fi
    echo "Done"
}

# Restart a session with permission fixes
# Usage: session_restart <session_name> <script_path> [extra_args...]
# Note: script_path is the path to claude-container script for re-exec
session_restart() {
    local session="$1"
    local script_path="$2"
    shift 2
    local extra_args=("$@")

    if [[ -z "$session" ]]; then
        echo "Error: session_restart requires a session name"
        echo "Usage: session_restart <name> <script_path> [options]"
        return 1
    fi

    if [[ -z "$script_path" ]]; then
        echo "Error: session_restart requires script path for re-exec"
        return 1
    fi

    # Find and stop any running container for this session
    local running
    running=$(docker ps -q --filter "name=claude-dev-" 2>/dev/null || true)
    if [[ -n "$running" ]]; then
        info "Stopping running container..."
        docker stop $running >/dev/null 2>&1 || true
    fi

    # Fix permissions on existing volumes before restart
    info "Fixing volume permissions..."
    docker run --rm \
        -v "claude-cargo-${session}:/cargo" \
        -v "claude-npm-${session}:/npm" \
        -v "claude-pip-${session}:/pip" \
        -v "claude-state-${session}:/state" \
        alpine sh -c 'chown -R 1000:1000 /cargo /npm /pip /state 2>/dev/null || true'

    # Re-exec with same session + continue + any extra args
    info "Restarting session: $session"
    exec "$script_path" --git-session "$session" --continue "${extra_args[@]}"
}

# Show diff between git session and original repo
# Usage: session_diff <session_name> [source_dir] [project_filter]
# Note: Calls diff_git_session from git-ops.sh
session_diff() {
    local session_name="$1"
    local source_dir="${2:-$(pwd)}"
    local project_filter="${3:-}"

    if [[ -z "$session_name" ]]; then
        echo "Error: session_diff requires a session name"
        echo "Usage: session_diff <name> [source_dir] [project-name]"
        return 1
    fi

    diff_git_session "$session_name" "$source_dir" "$project_filter"
}

# Merge session commits back to original repo
# Usage: session_merge <session_name> [source_dir] [--into <branch>] [--auto]
# Note: Calls merge_git_session from git-ops.sh
session_merge() {
    local session_name="$1"
    shift

    if [[ -z "$session_name" ]]; then
        echo "Error: session_merge requires a session name"
        echo "Usage: session_merge <name> [--into <branch>] [--auto]"
        return 1
    fi

    local source_dir="$(pwd)"
    local target_branch=""
    local auto_mode=false

    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --into)
                target_branch="$2"
                shift 2
                ;;
            --auto)
                auto_mode=true
                shift
                ;;
            *)
                # Assume it's the source directory if not an option
                if [[ ! "$1" =~ ^-- ]]; then
                    source_dir="$1"
                fi
                shift
                ;;
        esac
    done

    merge_git_session "$session_name" "$source_dir" "$target_branch" "$auto_mode"
}
