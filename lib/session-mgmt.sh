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

# ============================================================================
# Volume Utility Functions
# ============================================================================
# These functions provide reusable patterns for extracting session names
# from volume names and performing set operations on volume/session lists.

# Extract session name from a Docker volume name
# Arguments:
#   $1 - volume name (e.g., "claude-session-foo", "claude-state-bar")
# Returns: session name without prefix, or empty string
# Examples:
#   extract_session_name "claude-session-myproject" => "myproject"
#   extract_session_name "claude-state-test" => "test"
#   extract_session_name "unrelated-volume" => ""
extract_session_name() {
    local volume="$1"
    case "$volume" in
        claude-session-*) echo "${volume#claude-session-}" ;;
        claude-state-*)   echo "${volume#claude-state-}" ;;
        claude-cargo-*)   echo "${volume#claude-cargo-}" ;;
        claude-npm-*)     echo "${volume#claude-npm-}" ;;
        claude-pip-*)     echo "${volume#claude-pip-}" ;;
        session-data-*)   echo "${volume#session-data-}" ;;
        *) echo "" ;;
    esac
}

# Map a list of volumes to unique session names
# Arguments:
#   $1 - newline-separated volume names
# Returns: unique session names, sorted
# Examples:
#   map_volumes_to_sessions "claude-session-foo\nclaude-state-foo\nclaude-session-bar"
#   => "bar\nfoo"
map_volumes_to_sessions() {
    local volumes="$1"

    while read -r vol; do
        [[ -z "$vol" ]] && continue
        local name=$(extract_session_name "$vol")
        [[ -n "$name" ]] && echo "$name"
    done <<< "$volumes" | sort -u
}

# Filter items not in exclude set
# Arguments:
#   $1 - items (newline-separated)
#   $2 - exclude set (newline-separated)
# Returns: items not in exclude set
# Examples:
#   filter_not_in_set "a\nb\nc" "b\nd" => "a\nc"
filter_not_in_set() {
    local items="$1"
    local exclude_set="$2"

    while read -r item; do
        [[ -z "$item" ]] && continue
        echo "$exclude_set" | grep -q "^${item}$" || echo "$item"
    done <<< "$items"
}

# ============================================================================
# Session Management Functions
# ============================================================================

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

# Clean up unused claude-container volumes (not mounted by any running container)
# Usage: session_cleanup_unused [--yes]
session_cleanup_unused() {
    local skip_confirm=false
    [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && skip_confirm=true

    echo "Finding unused claude-container volumes..."

    # Get all claude volumes
    local all_volumes
    all_volumes=$(docker volume ls -q | grep -E "^(claude-session-|claude-state-|claude-cargo-|claude-npm-|claude-pip-|session-data-)" || true)

    if [[ -z "$all_volumes" ]]; then
        echo "No claude-container volumes found"
        return 0
    fi

    # Get volumes currently in use by running containers
    local used_volumes
    used_volumes=$(docker ps -q | xargs -r docker inspect 2>/dev/null | \
        grep -oE '"Name": "claude-[^"]+"|"Name": "session-data-[^"]+"' | \
        cut -d'"' -f4 | sort -u || true)

    # Find unused volumes
    local unused_volumes=()
    while read -r vol; do
        [[ -z "$vol" ]] && continue
        # Check if volume is NOT in used list (avoid ! for zsh compatibility)
        if echo "$used_volumes" | grep -q "^${vol}$"; then
            : # Volume is in use, skip
        else
            unused_volumes+=("$vol")
        fi
    done <<< "$all_volumes"

    if [[ ${#unused_volumes[@]} -eq 0 ]]; then
        echo "No unused volumes found (all volumes are currently in use)"
        return 0
    fi

    # Show what will be deleted with sizes
    local total_count=$(echo "$all_volumes" | wc -l | tr -d ' ')
    local used_count=$(echo "$used_volumes" | grep -c . || echo 0)
    echo ""
    echo "Total volumes: $total_count"
    echo "In use: $used_count"
    echo "Unused: ${#unused_volumes[@]}"
    echo ""
    echo "Calculating sizes..."

    # Build mount arguments for all unused volumes at once (much faster!)
    local mount_args=""
    for vol in "${unused_volumes[@]}"; do
        mount_args="$mount_args -v $vol:/$vol"
    done

    # Get all sizes in one container run
    local sizes
    sizes=$(docker run --rm $mount_args alpine sh -c '
        total=0
        for dir in /claude-* /session-data-*; do
            [ -d "$dir" ] || continue
            name=$(basename "$dir")
            bytes=$(du -sb "$dir" 2>/dev/null | cut -f1)
            bytes=${bytes:-0}
            human=$(du -sh "$dir" 2>/dev/null | cut -f1)
            human=${human:-?}
            total=$((total + bytes))
            echo "$name|$human"
        done
        # Output total in human readable
        if [ $total -gt 1073741824 ]; then
            echo "TOTAL|$((total / 1073741824))G"
        elif [ $total -gt 1048576 ]; then
            echo "TOTAL|$((total / 1048576))M"
        elif [ $total -gt 1024 ]; then
            echo "TOTAL|$((total / 1024))K"
        else
            echo "TOTAL|${total}B"
        fi
    ' 2>/dev/null || echo "")

    echo ""
    echo "Volumes to delete:"
    local total_human="unknown"
    while IFS='|' read -r name size; do
        [[ -z "$name" ]] && continue
        if [[ "$name" == "TOTAL" ]]; then
            total_human="$size"
        else
            printf "  %-50s %10s\n" "$name" "$size"
        fi
    done <<< "$sizes"
    echo ""
    echo "Total size to free: $total_human"
    echo ""

    # Confirm unless --yes
    if ! $skip_confirm; then
        read -p "Delete ${#unused_volumes[@]} unused volume(s)? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled"
            return 0
        fi
    fi

    # Delete unused volumes
    for vol in "${unused_volumes[@]}"; do
        if docker volume rm "$vol" 2>/dev/null; then
            echo "Deleted: $vol"
        else
            echo "Failed to delete: $vol (may still be in use)"
        fi
    done
    echo "Done"
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
# Usage: session_delete <session_name> [--regex] [--yes]
session_delete() {
    local session="$1"
    local use_regex=false
    local skip_confirm=false

    # Parse flags
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --regex|-r) use_regex=true; shift ;;
            --yes|-y) skip_confirm=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$session" ]]; then
        echo "Error: session_delete requires a session name"
        echo "Usage: session_delete <name> [--regex] [--yes]"
        return 1
    fi

    local volumes_to_delete=()

    if $use_regex; then
        # Regex mode: find all matching volumes
        while IFS= read -r vol; do
            [[ -n "$vol" ]] && volumes_to_delete+=("$vol")
        done < <(docker volume ls -q | grep -E "$session")
    else
        # Strict mode: exact session name match
        for pattern in "claude-session-${session}" "claude-state-${session}" "claude-cargo-${session}" "claude-npm-${session}" "claude-pip-${session}" "session-data-${session}"; do
            if docker volume inspect "$pattern" &>/dev/null; then
                volumes_to_delete+=("$pattern")
            fi
        done
    fi

    if [[ ${#volumes_to_delete[@]} -eq 0 ]]; then
        echo "No volumes found for session: $session (already deleted)"
        return 0
    fi

    # Show what will be deleted
    echo "Volumes to delete:"
    for vol in "${volumes_to_delete[@]}"; do
        echo "  - $vol"
    done
    echo ""

    # Confirm unless --yes
    if ! $skip_confirm; then
        read -p "Delete these ${#volumes_to_delete[@]} volume(s)? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled"
            return 0
        fi
    fi

    # Stop any containers using these volumes
    for vol in "${volumes_to_delete[@]}"; do
        local containers
        containers=$(docker ps -aq --filter "volume=$vol" 2>/dev/null || true)
        if [[ -n "$containers" ]]; then
            echo "Stopping containers using $vol..."
            echo "$containers" | xargs docker rm -f 2>/dev/null || true
        fi
    done

    # Delete
    for vol in "${volumes_to_delete[@]}"; do
        docker volume rm "$vol"
        echo "Deleted: $vol"
    done
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

# Add a new repo to an existing session
# Usage: session_add_repo <session_name> <repo_path> [workspace_path]
# Arguments:
#   $1 - session name
#   $2 - path to git repository to add
#   $3 - optional workspace path (defaults to repo basename)
session_add_repo() {
    local session="$1"
    local repo_path="$2"
    local workspace_path="${3:-}"
    local volume="claude-session-${session}"

    if [[ -z "$session" ]] || [[ -z "$repo_path" ]]; then
        error "Usage: session_add_repo <session_name> <repo_path> [workspace_path]"
        return 1
    fi

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session"
        return 1
    fi

    # Verify repo exists and is a git repo (handles worktrees too)
    if ! is_git_repo "$repo_path"; then
        error "Not a git repository: $repo_path"
        return 1
    fi

    # Get absolute path
    local abs_repo_path
    abs_repo_path=$(cd "$repo_path" && pwd)

    # Handle worktrees: clone from main repo and checkout the branch
    local source_repo_path="$abs_repo_path"
    local branch_to_checkout=""

    if is_git_worktree "$abs_repo_path"; then
        source_repo_path=$(get_main_repo_path "$abs_repo_path")
        branch_to_checkout=$(get_git_branch "$abs_repo_path")
        info "Detected worktree, using main repo: $source_repo_path (branch: $branch_to_checkout)"
    fi

    # Default workspace path to repo basename
    if [[ -z "$workspace_path" ]]; then
        workspace_path=$(basename "$abs_repo_path")
    fi

    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
    local host_uid
    host_uid=$(get_host_uid)

    # Check if path already exists in session
    local exists
    exists=$(docker run --rm \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c "test -d '/session/$workspace_path' && echo 'yes' || echo 'no'")

    if [[ "$exists" == "yes" ]]; then
        error "Path already exists in session: $workspace_path"
        return 1
    fi

    info "Adding repo to session: $workspace_path"

    # Build clone command - with optional branch checkout for worktrees
    local clone_cmd="
        mkdir -p /session/$(dirname "$workspace_path") && \
        git -c safe.directory='*' clone --depth 1 /source '/session/$workspace_path'"

    if [[ -n "$branch_to_checkout" ]]; then
        clone_cmd="
            mkdir -p /session/$(dirname "$workspace_path") && \
            git -c safe.directory='*' clone --depth 1 --branch '$branch_to_checkout' /source '/session/$workspace_path'"
    fi

    clone_cmd="$clone_cmd && \
        cd '/session/$workspace_path' && \
        git remote remove origin 2>/dev/null || true && \
        git config user.email 'claude@container' && \
        git config user.name 'Claude' && \
        du -sh '/session/$workspace_path' | cut -f1"

    # Clone the repo into the session
    local clone_output
    if ! clone_output=$(docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$source_repo_path:/source:ro" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "$clone_cmd" 2>&1); then
        error "Failed to clone repo:"
        echo "$clone_output" >&2
        return 1
    fi

    local size=$(echo "$clone_output" | tail -1)
    success "Added: $workspace_path ($size)"

    # Update .claude-projects.yml if it exists
    # For worktrees, store main repo path + branch so merge works correctly
    local config_path="$source_repo_path"
    local config_branch="$branch_to_checkout"

    docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "
            if [[ -f /session/.claude-projects.yml ]]; then
                echo '  \"$workspace_path\":' >> /session/.claude-projects.yml
                echo '    path: $config_path' >> /session/.claude-projects.yml
                if [[ -n '$config_branch' ]]; then
                    echo '    branch: $config_branch' >> /session/.claude-projects.yml
                fi
            fi
        " 2>/dev/null || true
}

# Merge session commits back to original repo
# Usage: session_merge <session_name> [source_dir] [--into <branch>] [--from <branch>] [--auto] [--no-run]
# Note: Calls merge_git_session from git-ops.sh
session_merge() {
    local session_name="$1"
    shift

    if [[ -z "$session_name" ]]; then
        echo "Error: session_merge requires a session name"
        echo "Usage: session_merge <name> [--into <branch>] [--from <branch>] [--auto] [--no-run]"
        return 1
    fi

    local source_dir="$(pwd)"
    local target_branch=""
    local from_branch=""
    local auto_mode=false
    local no_run=false

    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --into)
                target_branch="$2"
                shift 2
                ;;
            --from)
                from_branch="$2"
                shift 2
                ;;
            --auto|--yes|-y)
                auto_mode=true
                shift
                ;;
            --no-run|--dry-run)
                no_run=true
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

    merge_git_session "$session_name" "$source_dir" "$target_branch" "$auto_mode" "$no_run" "$from_branch"
}

# Import a claude-code session into a container session
# Usage: session_import <source_path> <session_name> [--force]
# Arguments:
#   $1 - source path (e.g., ~/.claude or path to session backup)
#   $2 - target session name
#   --force - overwrite existing session state
session_import() {
    local source_path="$1"
    local session_name="$2"
    local force=false

    # Parse flags
    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$source_path" ]] || [[ -z "$session_name" ]]; then
        error "Usage: session_import <source_path> <session_name> [--force]"
        echo ""
        echo "Examples:"
        echo "  # Import from local claude session"
        echo "  ./claude-container --import-session ~/.claude my-session"
        echo ""
        echo "  # Import from backup directory"
        echo "  ./claude-container --import-session /backups/claude-session-2024 my-session"
        return 1
    fi

    # Expand ~ to home directory
    source_path="${source_path/#\~/$HOME}"

    # Verify source exists and is a directory
    if [[ ! -d "$source_path" ]]; then
        error "Source path does not exist or is not a directory: $source_path"
        return 1
    fi

    # Check for key session files to validate it's a claude session
    local has_session_files=false
    if [[ -f "$source_path/history.jsonl" ]] || [[ -d "$source_path/session-env" ]]; then
        has_session_files=true
    fi

    if ! $has_session_files; then
        warn "Source path does not contain expected claude session files (history.jsonl, session-env/)"
        read -p "Continue anyway? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled"
            return 0
        fi
    fi

    local state_volume="claude-state-${session_name}"

    # Check if volume already exists
    if docker volume inspect "$state_volume" &>/dev/null; then
        if ! $force; then
            error "Session state already exists: $session_name"
            echo "Use --force to overwrite existing session state"
            return 1
        else
            warn "Overwriting existing session state: $session_name"
        fi
    else
        info "Creating new session state volume: $state_volume"
        docker volume create "$state_volume" >/dev/null
    fi

    # Get absolute path for source
    local abs_source_path
    abs_source_path=$(cd "$source_path" && pwd)

    info "Importing session data from: $abs_source_path"
    info "Target: $state_volume"

    # Copy session data into volume using tar to handle nested containers
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
    local copy_output

    # Create tar archive of source and pipe into container
    if ! copy_output=$(cd "$abs_source_path" && tar -cf - . 2>/dev/null | docker run --rm -i \
        -v "$state_volume:/target" \
        "$git_image" \
        sh -c '
            cd /target
            tar -xf - 2>&1
            echo "---"
            echo "Files imported:"
            ls -lah /target/ 2>&1
            echo "---"
            echo "Disk usage:"
            du -sh /target/ 2>&1
        ' 2>&1); then
        error "Failed to import session:"
        echo "$copy_output" >&2
        return 1
    fi

    echo "$copy_output"
    echo ""
    success "Session imported successfully!"
    echo ""
    echo "To use this session, run:"
    echo "  ./claude-container -s $session_name --continue"
    echo ""
    echo "The --continue flag will load the conversation history from the imported session."
}

# Scan session for new repos not in config
# Usage: session_scan <session_name>
# Discovers git repos in session volume, compares against config,
# prompts for destination paths for new repos, updates config
session_scan() {
    local session_name="$1"
    local volume="claude-session-${session_name}"

    if [[ -z "$session_name" ]]; then
        error "session_scan requires a session name"
        echo "Usage: session_scan <name>"
        return 1
    fi

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    info "Scanning session: $session_name"

    # Get list of all git repos in the session
    local repos_in_session
    repos_in_session=$(docker run --rm \
        -v "$volume:/workspace:ro" \
        alpine sh -c '
            cd /workspace
            for dir in */; do
                [ -d "$dir/.git" ] && echo "${dir%/}"
            done
        ' 2>/dev/null | sort)

    if [[ -z "$repos_in_session" ]]; then
        warn "No git repositories found in session"
        return 0
    fi

    # Get list of repos from session config
    local config_repos=""
    local config_file=""

    # Check for config in session volume
    local has_config
    has_config=$(docker run --rm \
        -v "$volume:/workspace:ro" \
        alpine sh -c 'test -f /workspace/.claude-projects.yml && echo "yes" || echo "no"')

    if [[ "$has_config" == "yes" ]]; then
        # Extract repo names from config
        config_repos=$(docker run --rm \
            -v "$volume:/workspace:ro" \
            alpine sh -c '
                grep -E "^  [a-zA-Z0-9_/-]+:" /workspace/.claude-projects.yml 2>/dev/null | \
                sed "s/://g" | sed "s/^ *//" | sort
            ' 2>/dev/null || echo "")
        config_file="/workspace/.claude-projects.yml"
    fi

    # Also check session config dir on host
    local host_config=""
    local host_config_path="$SESSIONS_CONFIG_DIR/${session_name}.yml"
    if [[ -f "$host_config_path" ]]; then
        host_config="$host_config_path"
        local host_repos
        host_repos=$(grep -E "^  [a-zA-Z0-9_/-]+:" "$host_config" 2>/dev/null | \
            sed 's/://g' | sed 's/^ *//' | sort || echo "")
        if [[ -n "$host_repos" ]]; then
            config_repos=$(echo -e "${config_repos}\n${host_repos}" | sort -u | grep -v '^$')
            config_file="$host_config"
        fi
    fi

    # Compare and categorize
    local known_repos=()
    local new_repos=()

    while read -r repo; do
        [[ -z "$repo" ]] && continue
        if echo "$config_repos" | grep -q "^${repo}$"; then
            known_repos+=("$repo")
        else
            new_repos+=("$repo")
        fi
    done <<< "$repos_in_session"

    # Display results
    echo ""
    echo "=== Known repos (in config) ==="
    if [[ ${#known_repos[@]} -eq 0 ]]; then
        echo "  (none)"
    else
        for repo in "${known_repos[@]}"; do
            echo "  ✓ $repo"
        done
    fi

    echo ""
    echo "=== New repos (not in config) ==="
    if [[ ${#new_repos[@]} -eq 0 ]]; then
        echo "  (none)"
        return 0
    fi

    for repo in "${new_repos[@]}"; do
        echo "  + $repo"
    done

    echo ""

    # Prompt for each new repo
    local updated_config=false
    for repo in "${new_repos[@]}"; do
        echo ""
        echo "New repo: $repo"
        read -p "  Destination path (empty to skip): " dest_path

        if [[ -z "$dest_path" ]]; then
            echo "  Skipped"
            continue
        fi

        # Expand ~ to home directory
        dest_path="${dest_path/#\~/$HOME}"

        # Make absolute if relative
        if [[ ! "$dest_path" = /* ]]; then
            dest_path="$(pwd)/$dest_path"
        fi

        # Confirm
        echo "  Will extract to: $dest_path"
        read -p "  Confirm? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "  Skipped"
            continue
        fi

        # Add to config file
        if [[ -n "$host_config" ]]; then
            # Append to existing host config
            echo "" >> "$host_config"
            echo "  # Discovered from session" >> "$host_config"
            echo "  $repo:" >> "$host_config"
            echo "    path: $dest_path" >> "$host_config"
            echo "    source: discovered" >> "$host_config"
            success "Added $repo -> $dest_path to config"
            updated_config=true
        else
            # Create new config file
            host_config="$host_config_path"
            mkdir -p "$SESSIONS_CONFIG_DIR"
            cat > "$host_config" << EOF
version: "1"
projects:
  # Discovered from session scan
  $repo:
    path: $dest_path
    source: discovered
EOF
            success "Created config: $host_config"
            success "Added $repo -> $dest_path"
            updated_config=true
        fi
    done

    if $updated_config; then
        echo ""
        success "Config updated: $host_config"
        echo ""
        echo "To extract new repos, run:"
        echo "  claude-container --merge-session $session_name"
    fi
}
