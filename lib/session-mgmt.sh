#!/usr/bin/env bash
# claude-container session management module - List, delete, restart, extract sessions
# Source this file after utils.sh
#
# Dependencies:
#   - utils.sh must be sourced first (provides: info, success, warn, error)
#   - docker-utils.sh must be sourced first (provides: docker_run_in_volume, get_volume_sizes_batch, etc.)
#
# This module provides functions for managing claude-container sessions:
#   - session_cleanup: Clean up all claude-container Docker volumes
#   - session_list: List all sessions with disk usage
#   - session_delete: Delete a specific session and its volumes
#   - session_restart: Restart a session with permission fixes
#   - session_extract: Extract session changes as branches in original repos
#   - session_import: Import a claude session into container

# Source docker-utils.sh if not already sourced
if [[ -z "$(type -t docker_run_in_volume)" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/docker-utils.sh"
fi

# ============================================================================
# Volume Utility Functions
# ============================================================================

# Extract session name from a Docker volume name
# Arguments:
#   $1 - volume name (e.g., "claude-session-foo", "claude-state-bar")
# Returns: session name without prefix, or empty string
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
    local unused_volumes_str
    unused_volumes_str=$(filter_not_in_set "$all_volumes" "$used_volumes")

    local unused_volumes=()
    while read -r vol; do
        [[ -n "$vol" ]] && unused_volumes+=("$vol")
    done <<< "$unused_volumes_str"

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

    # Get all sizes in one container run
    local unused_volumes_list
    unused_volumes_list=$(printf "%s\n" "${unused_volumes[@]}")
    local sizes
    sizes=$(get_volume_sizes_batch_with_total "$unused_volumes_list")

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
        local session_name=$(extract_session_name "$vol")
        [[ -n "$session_name" ]] && sessions[$session_name]=1
    done <<< "$all_volumes"

    # Get all sizes in one container run
    echo "Scanning $(echo "$all_volumes" | wc -l | tr -d ' ') volumes..."
    local sizes
    sizes=$(get_volume_sizes_batch "$all_volumes")

    # Parse sizes into associative array
    declare -A vol_sizes
    while IFS='|' read -r vol size; do
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

    # Calculate total size
    local total_human="?"
    local sizes_with_total
    sizes_with_total=$(get_volume_sizes_batch_with_total "$all_volumes")
    total_human=$(echo "$sizes_with_total" | grep "^TOTAL|" | cut -d'|' -f2)
    [[ -z "$total_human" ]] && total_human="?"

    echo ""
    echo "Total disk usage: $total_human"
    echo ""
    echo "Commands:"
    echo "  Delete session:  claude-container --delete <name>"
    echo "  Extract session: claude-container --extract <name>"
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

    # Clean up session metadata files
    for vol in "${volumes_to_delete[@]}"; do
        local _sname="${vol#claude-session-}"
        [[ "$_sname" != "$vol" ]] && rm -f "$SESSIONS_CONFIG_DIR/${_sname}.env" "$SESSIONS_CONFIG_DIR/${_sname}.yml"
    done

    echo "Done"
}

# Restart a session with permission fixes
# Usage: session_restart <session_name> <script_path> [extra_args...]
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
    exec "$script_path" --session "$session" --continue "${extra_args[@]}"
}

# Add a new repo to an existing session
# Usage: session_add_repo <session_name> <repo_path> [workspace_path]
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

    # Verify repo exists and is a git repo
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
    exists=$(docker_run_in_volume "$volume" "/session" "$git_image" \
        "test -d '/session/$workspace_path' && echo 'yes' || echo 'no'" "ro")

    if [[ "$exists" == "yes" ]]; then
        error "Path already exists in session: $workspace_path"
        return 1
    fi

    info "Adding repo to session: $workspace_path"

    # Build clone command
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

# Import a claude-code session into a container session
# Usage: session_import <source_path> <session_name> [--force]
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
        echo "  claude-container -s my-session --import ~/.claude"
        echo ""
        echo "  # Import from backup directory"
        echo "  claude-container -s my-session --import /backups/claude-session"
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
    echo "  claude-container -s $session_name --continue"
}

# Sync session with upstream changes for conflict resolution
# Usage: session_sync <session_name> [target_branch]
session_sync() {
    local session_name="$1"
    local target_branch="${2:-main}"
    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        exit 1
    fi

    # Get config content
    local config_content
    config_content=$(docker run --rm -v "$volume:/session:ro" "$git_image" \
        cat /session/.claude-projects.yml 2>/dev/null)

    if [[ -z "$config_content" ]]; then
        error "No .claude-projects.yml found in session"
        echo "Single-project sessions are not yet supported for --sync"
        exit 1
    fi

    info "Syncing session '$session_name' with branch '$target_branch'..."
    echo ""

    # Check for yq
    if ! command -v yq &>/dev/null; then
        error "yq required for multi-project sync"
        exit 1
    fi

    # Parse projects
    local projects
    projects=$(echo "$config_content" | yq eval '.projects | to_entries | .[] | .key + "|" + .value.path' - 2>/dev/null)

    local conflict_count=0
    local success_count=0
    local skip_count=0
    local dirty_count=0

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue

        # Skip if original repo doesn't exist
        if [[ ! -d "$proj_path" ]]; then
            warn "  Skipping $proj_name (original not found: $proj_path)"
            skip_count=$((skip_count + 1))
            continue
        fi

        # Check if target branch exists in original repo
        if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
            warn "  Skipping $proj_name (branch '$target_branch' not found)"
            skip_count=$((skip_count + 1))
            continue
        fi

        info "  Syncing $proj_name..."

        # Check for rebase in progress
        local rebase_in_progress
        rebase_in_progress=$(docker run --rm \
            -v "$volume:/session:ro" \
            "$git_image" \
            sh -c "test -d '/session/$proj_name/.git/rebase-merge' -o -d '/session/$proj_name/.git/rebase-apply' && echo 'yes' || echo 'no'" 2>/dev/null)

        if [[ "$rebase_in_progress" == "yes" ]]; then
            warn "    $proj_name has rebase in progress (use git rebase --continue or --abort)"
            conflict_count=$((conflict_count + 1))
            continue
        fi

        # Check for uncommitted/unstaged changes BEFORE rebasing
        local dirty_status
        dirty_status=$(docker run --rm \
            -v "$volume:/session:ro" \
            "$git_image" \
            sh -c "git config --global --add safe.directory '*' && cd '/session/$proj_name' && git status --porcelain" 2>/dev/null)

        if [[ -n "$dirty_status" ]]; then
            warn "    $proj_name has uncommitted changes (will need manual commit/stash)"
            # Show first few changed files
            echo "$dirty_status" | head -3 | sed 's/^/      /'
            local change_count
            change_count=$(echo "$dirty_status" | wc -l | tr -d ' ')
            if [[ $change_count -gt 3 ]]; then
                echo "      ... and $((change_count - 3)) more"
            fi
            dirty_count=$((dirty_count + 1))
            continue
        fi

        # Add remote, fetch, and rebase in one docker run
        # Mount original repo read-only
        local rebase_output
        local host_uid
        host_uid=$(get_host_uid)

        rebase_output=$(docker run --rm \
            --user "$host_uid:$host_uid" \
            -v "$volume:/session" \
            -v "$proj_path:/upstream:ro" \
            "$git_image" \
            sh -c "
                cd '/session/$proj_name'
                git -c safe.directory='*' remote remove upstream 2>/dev/null || true
                git -c safe.directory='*' remote add upstream /upstream
                git -c safe.directory='*' fetch upstream '$target_branch' 2>&1
                git -c safe.directory='*' rebase 'upstream/$target_branch' 2>&1
            " 2>&1)

        if echo "$rebase_output" | grep -qE "CONFLICT|Merge conflict|could not apply"; then
            warn "    $proj_name has conflicts (Claude will resolve)"
            conflict_count=$((conflict_count + 1))
        elif echo "$rebase_output" | grep -qE "error:|fatal:"; then
            error "    $proj_name rebase failed:"
            echo "$rebase_output" | grep -E "error:|fatal:" | head -3 | sed 's/^/      /'
            skip_count=$((skip_count + 1))
        elif echo "$rebase_output" | grep -q "is up to date"; then
            info "    $proj_name (already up to date)"
            success_count=$((success_count + 1))
        else
            success "    $proj_name rebased successfully"
            success_count=$((success_count + 1))
        fi
    done <<< "$projects"

    echo ""
    if [[ $conflict_count -gt 0 ]]; then
        info "$conflict_count project(s) have conflicts for Claude to resolve"
        echo ""
        echo "Conflict resolution tips for Claude:"
        echo "  - Look for <<<<<<< HEAD markers in files"
        echo "  - After resolving, run: git add <files> && git rebase --continue"
        echo "  - To abort: git rebase --abort"
    fi
    if [[ $success_count -gt 0 ]]; then
        success "$success_count project(s) rebased cleanly"
    fi
    if [[ $skip_count -gt 0 ]]; then
        warn "$skip_count project(s) skipped"
    fi
    if [[ $dirty_count -gt 0 ]]; then
        warn "$dirty_count project(s) have uncommitted changes (commit or stash in session)"
    fi

    # Store sync state for cleanup message on exit
    docker run --rm \
        --user "$(get_host_uid):$(get_host_uid)" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "echo '$target_branch' > /session/.sync-branch" 2>/dev/null || true

    echo ""
    info "Starting container for review..."
    echo ""

    # Return to main script to continue container startup
    # The sync marker will be detected on session exit
}

# Merge a branch into the session for conflict resolution
# Similar to session_sync but uses git merge instead of rebase
# Usage: session_merge_into <session_name> <target_branch>
session_merge_into() {
    local session_name="$1"
    local target_branch="${2:-main}"
    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        exit 1
    fi

    # Get config content
    local config_content
    config_content=$(docker run --rm -v "$volume:/session:ro" "$git_image" \
        cat /session/.claude-projects.yml 2>/dev/null)

    if [[ -z "$config_content" ]]; then
        error "No .claude-projects.yml found in session"
        echo "Single-project sessions are not yet supported for --merge-into"
        exit 1
    fi

    info "Merging branch '$target_branch' into session '$session_name'..."
    echo ""

    # Check for yq
    if ! command -v yq &>/dev/null; then
        error "yq required for multi-project merge"
        exit 1
    fi

    # Parse projects
    local projects
    projects=$(echo "$config_content" | yq eval '.projects | to_entries | .[] | .key + "|" + .value.path' - 2>/dev/null)

    local conflict_count=0
    local success_count=0
    local skip_count=0
    local dirty_count=0

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue

        # Skip if original repo doesn't exist
        if [[ ! -d "$proj_path" ]]; then
            warn "  Skipping $proj_name (original not found: $proj_path)"
            skip_count=$((skip_count + 1))
            continue
        fi

        # Check if target branch exists in original repo
        if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
            warn "  Skipping $proj_name (branch '$target_branch' not found)"
            skip_count=$((skip_count + 1))
            continue
        fi

        info "  Merging into $proj_name..."

        # Check for merge in progress
        local merge_in_progress
        merge_in_progress=$(docker run --rm \
            -v "$volume:/session:ro" \
            "$git_image" \
            sh -c "test -f '/session/$proj_name/.git/MERGE_HEAD' && echo 'yes' || echo 'no'" 2>/dev/null)

        if [[ "$merge_in_progress" == "yes" ]]; then
            warn "    $proj_name has merge in progress (use git commit or git merge --abort)"
            conflict_count=$((conflict_count + 1))
            continue
        fi

        # Check for uncommitted/unstaged changes BEFORE merging
        local dirty_status
        dirty_status=$(docker run --rm \
            -v "$volume:/session:ro" \
            "$git_image" \
            sh -c "git config --global --add safe.directory '*' && cd '/session/$proj_name' && git status --porcelain" 2>/dev/null)

        if [[ -n "$dirty_status" ]]; then
            warn "    $proj_name has uncommitted changes (will need manual commit/stash)"
            echo "$dirty_status" | head -3 | sed 's/^/      /'
            local change_count
            change_count=$(echo "$dirty_status" | wc -l | tr -d ' ')
            if [[ $change_count -gt 3 ]]; then
                echo "      ... and $((change_count - 3)) more"
            fi
            dirty_count=$((dirty_count + 1))
            continue
        fi

        # Add remote, fetch, and merge in one docker run
        local merge_output
        local host_uid
        host_uid=$(get_host_uid)

        merge_output=$(docker run --rm \
            --user "$host_uid:$host_uid" \
            -v "$volume:/session" \
            -v "$proj_path:/upstream:ro" \
            "$git_image" \
            sh -c "
                cd '/session/$proj_name'
                git -c safe.directory='*' remote remove upstream 2>/dev/null || true
                git -c safe.directory='*' remote add upstream /upstream
                git -c safe.directory='*' fetch upstream '$target_branch' 2>&1
                git -c safe.directory='*' merge 'upstream/$target_branch' --no-edit 2>&1 || true
            " 2>&1)

        if echo "$merge_output" | grep -qE "CONFLICT|Merge conflict|Automatic merge failed"; then
            warn "    $proj_name has conflicts (Claude will resolve)"
            conflict_count=$((conflict_count + 1))
        elif echo "$merge_output" | grep -qE "error:|fatal:"; then
            error "    $proj_name merge failed:"
            echo "$merge_output" | grep -E "error:|fatal:" | head -3 | sed 's/^/      /'
            skip_count=$((skip_count + 1))
        elif echo "$merge_output" | grep -q "Already up to date"; then
            info "    $proj_name (already up to date)"
            success_count=$((success_count + 1))
        else
            success "    $proj_name merged successfully"
            success_count=$((success_count + 1))
        fi
    done <<< "$projects"

    echo ""
    if [[ $conflict_count -gt 0 ]]; then
        info "$conflict_count project(s) have conflicts for Claude to resolve"
        echo ""
        echo "Conflict resolution tips for Claude:"
        echo "  - Look for <<<<<<< HEAD markers in files"
        echo "  - After resolving, run: git add <files> && git commit"
        echo "  - To abort: git merge --abort"
    fi
    if [[ $success_count -gt 0 ]]; then
        success "$success_count project(s) merged cleanly"
    fi
    if [[ $skip_count -gt 0 ]]; then
        warn "$skip_count project(s) skipped"
    fi
    if [[ $dirty_count -gt 0 ]]; then
        warn "$dirty_count project(s) have uncommitted changes (commit or stash in session)"
    fi

    # Store merge-into state for cleanup on exit
    docker run --rm \
        --user "$(get_host_uid):$(get_host_uid)" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "echo '$target_branch' > /session/.merge-into-branch" 2>/dev/null || true

    echo ""
    info "Starting container for review..."
    echo ""

    # Return to main script to continue container startup
    # The merge-into marker will be detected on session exit
}

# Extract session changes as branches in original repos
# Uses git bundle to extract only git data (ignores build artifacts)
# Usage: session_extract <session_name> [--force]
session_extract() {
    local session_name="$1"
    local force=false

    # Parse flags
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Usage: session_extract <session_name> [--force]"
        return 1
    fi

    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    info "Extracting session '$session_name'..."

    # Check if multi-project (has .claude-projects.yml)
    local has_config
    has_config=$(docker run --rm -v "$volume:/session:ro" "$git_image" \
        sh -c 'test -f /session/.claude-projects.yml && echo yes || echo no' 2>/dev/null)

    if [[ "$has_config" == "yes" ]]; then
        # Extract just the config file (tiny)
        local config_content
        config_content=$(docker run --rm -v "$volume:/session:ro" "$git_image" \
            cat /session/.claude-projects.yml 2>/dev/null)
        _extract_multi_project_direct "$session_name" "$volume" "$git_image" "$config_content" "$force"
    else
        _extract_single_project_direct "$session_name" "$volume" "$git_image" "$force"
    fi
}

# Extract multi-project session directly from volume (no full extraction)
# Uses git bundle to transfer only git data, ignoring build artifacts
_extract_multi_project_direct() {
    local session_name="$1"
    local volume="$2"
    local git_image="$3"
    local config_content="$4"
    local force="$5"

    info "Multi-project session detected"
    echo ""

    if ! command -v yq &>/dev/null; then
        error "yq required for multi-project extraction"
        return 1
    fi

    # Parse config from content (no temp file needed)
    local projects
    projects=$(echo "$config_content" | yq eval '.projects | to_entries | .[] | .key + "|" + .value.path' - 2>/dev/null)

    local success_count=0
    local fail_count=0
    local bundle_dir="$CACHE_DIR/bundles-$$"
    mkdir -p "$bundle_dir"
    trap "rm -rf '$bundle_dir'" EXIT

    # Phase 1: Validate projects and build list for batch bundle creation
    local _valid_projects=()
    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        if [[ ! -d "$proj_path" ]]; then
            warn "Skipping $proj_name (original repo not found: $proj_path)"
            fail_count=$((fail_count + 1))
            continue
        fi
        _valid_projects+=("$proj_name|$proj_path")
        echo "$proj_name"
    done <<< "$projects" > "$bundle_dir/.projects"

    if [[ ${#_valid_projects[@]} -eq 0 ]]; then
        warn "No valid projects to extract"
        return 0
    fi

    # Phase 2: Create all bundles in a single container run (parallel)
    info "Bundling ${#_valid_projects[@]} project(s)..."
    docker run --rm \
        -v "$volume:/session:ro" \
        -v "$bundle_dir:/bundles" \
        "$git_image" \
        sh -c '
            git config --global --add safe.directory "*"
            while IFS= read -r proj; do
                [ -z "$proj" ] && continue
                safe=$(echo "$proj" | tr "/" "_")
                (
                    if cd "/session/$proj" 2>/dev/null; then
                        git bundle create "/tmp/${safe}.bundle" HEAD 2>/dev/null && \
                            mv "/tmp/${safe}.bundle" "/bundles/${safe}.bundle" 2>/dev/null || true
                    fi
                ) &
            done < /bundles/.projects
            wait
        ' 2>/dev/null || true

    # Phase 3: Process each project on the host (fetch + branch — all local, fast)
    for _entry in "${_valid_projects[@]}"; do
        local proj_name="${_entry%%|*}"
        local proj_path="${_entry#*|}"
        local bundle_file="$bundle_dir/${proj_name//\//_}.bundle"

        # Check bundle was created
        if [[ ! -s "$bundle_file" ]]; then
            warn "  $proj_name (no git data)"
            continue
        fi

        # Fetch from bundle
        if ! git -C "$proj_path" fetch "$bundle_file" HEAD 2>/dev/null; then
            error "  $proj_name fetch failed"
            fail_count=$((fail_count + 1))
            continue
        fi

        local fetched_head
        fetched_head=$(git -C "$proj_path" rev-parse FETCH_HEAD 2>/dev/null)

        # Check if branch already exists
        local _branch_exists=false
        local _branch_checked_out=false
        local _compare_base
        if git -C "$proj_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
            _branch_exists=true
            _compare_base=$(git -C "$proj_path" rev-parse "refs/heads/$session_name" 2>/dev/null)
            local _current_branch
            _current_branch=$(git -C "$proj_path" symbolic-ref --short HEAD 2>/dev/null || echo "")
            [[ "$_current_branch" == "$session_name" ]] && _branch_checked_out=true
        else
            _compare_base=$(git -C "$proj_path" rev-parse HEAD 2>/dev/null)
        fi

        if [[ "$_compare_base" == "$fetched_head" ]]; then
            echo "  $proj_name (no changes)"
            continue
        fi

        # If branch exists, allow fast-forward without --force; require --force for diverged
        if $_branch_exists; then
            if git -C "$proj_path" merge-base --is-ancestor "$_compare_base" "$fetched_head" 2>/dev/null; then
                : # fast-forward — safe to update
            elif [[ "$force" != "true" ]]; then
                warn "Skipping $proj_name (branch '$session_name' has diverged, use --force)"
                fail_count=$((fail_count + 1))
                continue
            fi
        fi

        # Create or update branch
        if $_branch_checked_out; then
            git -C "$proj_path" reset --hard FETCH_HEAD 2>/dev/null
        elif $_branch_exists; then
            git -C "$proj_path" branch -f "$session_name" FETCH_HEAD 2>/dev/null
        else
            if ! git -C "$proj_path" branch "$session_name" FETCH_HEAD 2>/dev/null; then
                error "  $proj_name branch creation failed"
                fail_count=$((fail_count + 1))
                continue
            fi
        fi

        # Count commits and files
        local commit_count
        commit_count=$(git -C "$proj_path" rev-list --count "$_compare_base".."$session_name" 2>/dev/null || echo "0")
        local files_changed
        files_changed=$(git -C "$proj_path" diff --stat --name-only "$_compare_base".."$session_name" 2>/dev/null | wc -l | tr -d ' ')

        if $_branch_checked_out; then
            success "  $proj_name → updated checked-out branch '$session_name' ($commit_count commit(s), $files_changed file(s))"
        elif $_branch_exists; then
            success "  $proj_name → updated branch '$session_name' ($commit_count commit(s), $files_changed file(s))"
        else
            success "  $proj_name → branch '$session_name' ($commit_count commit(s), $files_changed file(s))"
        fi
        success_count=$((success_count + 1))
    done

    echo ""
    if [[ $success_count -gt 0 ]]; then
        success "Created branch '$session_name' in $success_count repo(s)"
        echo ""
        echo "To see changes:  git log main..$session_name"
        echo "Checkout:        git checkout $session_name"
        echo "Merge:           git merge $session_name"
    fi
    if [[ $fail_count -gt 0 ]]; then
        warn "$fail_count repo(s) skipped or failed"
    fi
}

# Extract single-project session directly from volume (legacy fallback)
_extract_single_project_direct() {
    local session_name="$1"
    local volume="$2"
    local git_image="$3"
    local force="$4"

    # For single project without config, user must run from original repo
    local target_repo
    target_repo=$(pwd)

    if ! is_git_repo "$target_repo"; then
        error "Run this from your git repository directory"
        return 1
    fi

    # Create git bundle from volume
    local bundle_file="$CACHE_DIR/extract-$$.bundle"
    mkdir -p "$CACHE_DIR"
    trap "rm -f '$bundle_file'" EXIT

    # Write to temp file then cat to stdout (git can't write directly to /dev/stdout due to lock files)
    if ! docker run --rm -v "$volume:/session:ro" "$git_image" \
        sh -c "git config --global --add safe.directory '*' && cd /session && git bundle create /tmp/out.bundle HEAD && cat /tmp/out.bundle" > "$bundle_file" 2>/dev/null; then
        error "Failed to create git bundle from session"
        return 1
    fi

    # Fetch from bundle
    git -C "$target_repo" fetch "$bundle_file" HEAD 2>/dev/null

    local fetched_head
    fetched_head=$(git -C "$target_repo" rev-parse FETCH_HEAD 2>/dev/null)

    # Check if branch already exists
    local _branch_exists=false
    local _branch_checked_out=false
    local _compare_base
    if git -C "$target_repo" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
        _branch_exists=true
        _compare_base=$(git -C "$target_repo" rev-parse "refs/heads/$session_name" 2>/dev/null)
        local _current_branch
        _current_branch=$(git -C "$target_repo" symbolic-ref --short HEAD 2>/dev/null || echo "")
        [[ "$_current_branch" == "$session_name" ]] && _branch_checked_out=true
    else
        _compare_base=$(git -C "$target_repo" rev-parse HEAD 2>/dev/null)
    fi

    if [[ "$_compare_base" == "$fetched_head" ]]; then
        info "No changes in session (matches current HEAD)"
        return 0
    fi

    # If branch exists, allow fast-forward without --force; require --force for diverged
    if $_branch_exists; then
        if git -C "$target_repo" merge-base --is-ancestor "$_compare_base" "$fetched_head" 2>/dev/null; then
            : # fast-forward — safe to update
        elif [[ "$force" != "true" ]]; then
            error "Branch '$session_name' has diverged from session. Use --force to overwrite."
            return 1
        fi
    fi

    # Create or update branch
    if $_branch_checked_out; then
        git -C "$target_repo" reset --hard FETCH_HEAD 2>/dev/null
    elif $_branch_exists; then
        git -C "$target_repo" branch -f "$session_name" FETCH_HEAD 2>/dev/null
    else
        git -C "$target_repo" branch "$session_name" FETCH_HEAD 2>/dev/null
    fi

    local commit_count
    commit_count=$(git -C "$target_repo" rev-list --count "$_compare_base".."$session_name" 2>/dev/null || echo "0")
    local files_changed
    files_changed=$(git -C "$target_repo" diff --stat --name-only "$_compare_base".."$session_name" 2>/dev/null | wc -l | tr -d ' ')

    if $_branch_checked_out; then
        success "Updated checked-out branch: $session_name ($commit_count commit(s), $files_changed file(s) changed)"
    elif $_branch_exists; then
        success "Updated branch: $session_name ($commit_count commit(s), $files_changed file(s) changed)"
    else
        success "Created branch: $session_name ($commit_count commit(s), $files_changed file(s) changed)"
    fi
    echo ""
    echo "Commits:"
    git -C "$target_repo" log --oneline "$current_head".."$session_name" 2>/dev/null | head -10 || true
    echo ""
    echo "Files changed:"
    git -C "$target_repo" diff --stat "$current_head".."$session_name" 2>/dev/null | tail -20 || true

    echo ""
    echo "To see changes:  git log HEAD..$session_name"
    echo "Checkout:        git checkout $session_name"
    echo "Merge:           git merge $session_name"
}

# Legacy: Extract single-project session into original repo as branch (temp dir based)
_extract_single_project() {
    local session_name="$1"
    local temp_dir="$2"
    local force="$3"

    # For single project, we need to know where the original repo is
    # The user should run this from the original repo directory
    local target_repo
    target_repo=$(pwd)

    if ! is_git_repo "$target_repo"; then
        error "Run this from your git repository directory"
        return 1
    fi

    # Check if branch already exists
    if git -C "$target_repo" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
        if [[ "$force" != "true" ]]; then
            error "Branch '$session_name' already exists. Use --force to overwrite."
            return 1
        fi
        warn "Overwriting existing branch: $session_name"
        git -C "$target_repo" branch -D "$session_name" 2>/dev/null || true
    fi

    # Fetch from temp to check for changes
    git -C "$target_repo" fetch "$temp_dir" HEAD 2>/dev/null

    # Compare FETCH_HEAD to current HEAD
    local current_head
    current_head=$(git -C "$target_repo" rev-parse HEAD 2>/dev/null)
    local fetched_head
    fetched_head=$(git -C "$target_repo" rev-parse FETCH_HEAD 2>/dev/null)

    if [[ "$current_head" == "$fetched_head" ]]; then
        info "No changes in session (matches current HEAD)"
        return 0
    fi

    # Create branch since there are changes
    git -C "$target_repo" branch "$session_name" FETCH_HEAD 2>/dev/null

    local commit_count
    commit_count=$(git -C "$target_repo" rev-list --count "$current_head".."$session_name" 2>/dev/null || echo "0")
    local files_changed
    files_changed=$(git -C "$target_repo" diff --stat --name-only "$current_head".."$session_name" 2>/dev/null | wc -l | tr -d ' ')

    success "Created branch: $session_name ($commit_count commit(s), $files_changed file(s) changed)"
    echo ""
    echo "Commits:"
    git -C "$target_repo" log --oneline "$current_head".."$session_name" 2>/dev/null | head -10 || true
    echo ""
    echo "Files changed:"
    git -C "$target_repo" diff --stat "$current_head".."$session_name" 2>/dev/null | tail -20 || true

    echo ""
    echo "To see changes:  git log HEAD..$session_name"
    echo "Checkout:        git checkout $session_name"
    echo "Merge:           git merge $session_name"
}

# Extract multi-project session into original repos as branches
_extract_multi_project() {
    local session_name="$1"
    local temp_dir="$2"
    local force="$3"

    info "Multi-project session detected"
    echo ""

    # Parse the config to get project paths
    local config_file="$temp_dir/.claude-projects.yml"

    if ! command -v yq &>/dev/null; then
        error "yq required for multi-project extraction"
        return 1
    fi

    # Get project names and their original paths
    local projects
    projects=$(yq eval '.projects | to_entries | .[] | .key + "|" + .value.path' "$config_file" 2>/dev/null)

    local success_count=0
    local fail_count=0

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue

        local session_proj_dir="$temp_dir/$proj_name"

        # Skip if project dir doesn't exist in session
        if [[ ! -d "$session_proj_dir" ]]; then
            warn "Skipping $proj_name (not in session)"
            continue
        fi

        # Check if original repo exists
        if [[ ! -d "$proj_path" ]]; then
            warn "Skipping $proj_name (original repo not found: $proj_path)"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Check if branch already exists
        if git -C "$proj_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
            if [[ "$force" != "true" ]]; then
                warn "Skipping $proj_name (branch '$session_name' exists, use --force)"
                fail_count=$((fail_count + 1))
                continue
            fi
            git -C "$proj_path" branch -D "$session_name" 2>/dev/null || true
        fi

        # Fetch to check for changes
        if ! git -C "$proj_path" fetch "$session_proj_dir" HEAD 2>/dev/null; then
            error "  $proj_name fetch failed"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Compare FETCH_HEAD to current HEAD
        local current_head
        current_head=$(git -C "$proj_path" rev-parse HEAD 2>/dev/null)
        local fetched_head
        fetched_head=$(git -C "$proj_path" rev-parse FETCH_HEAD 2>/dev/null)

        if [[ "$current_head" == "$fetched_head" ]]; then
            echo "  $proj_name (no changes)"
            continue
        fi

        # Create branch since there are changes
        if ! git -C "$proj_path" branch "$session_name" FETCH_HEAD 2>/dev/null; then
            error "  $proj_name branch creation failed"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Count commits and changed files
        local commit_count
        commit_count=$(git -C "$proj_path" rev-list --count "$current_head".."$session_name" 2>/dev/null || echo "0")
        local files_changed
        files_changed=$(git -C "$proj_path" diff --stat --name-only "$current_head".."$session_name" 2>/dev/null | wc -l | tr -d ' ')

        success "  $proj_name → branch '$session_name' ($commit_count commit(s), $files_changed file(s))"
        success_count=$((success_count + 1))
    done <<< "$projects"

    echo ""
    if [[ $success_count -gt 0 ]]; then
        success "Created branch '$session_name' in $success_count repo(s)"
        echo ""
        echo "To see changes:  git log main..$session_name"
        echo "Checkout:        git checkout $session_name"
        echo "Merge:           git merge $session_name"
    fi
    if [[ $fail_count -gt 0 ]]; then
        warn "$fail_count repo(s) skipped or failed"
    fi
}

# Repair corrupted session config (fixes paths with ||true| suffix)
# Usage: session_repair <session_name>
session_repair() {
    local session_name="$1"
    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    if [[ -z "$session_name" ]]; then
        error "Usage: session_repair <session_name>"
        return 1
    fi

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    info "Checking session config..."

    # Check if config has corrupted paths
    local config_content
    config_content=$(docker run --rm -v "$volume:/session:ro" "$git_image" \
        cat /session/.claude-projects.yml 2>/dev/null || echo "")

    if [[ -z "$config_content" ]]; then
        info "No .claude-projects.yml found (single-project session)"
        return 0
    fi

    if ! echo "$config_content" | grep -q '||'; then
        info "Config appears valid (no ||true| corruption detected)"
        return 0
    fi

    info "Found corrupted paths, repairing..."

    # Fix the config by removing ||...| suffix from paths
    local host_uid
    host_uid=$(get_host_uid)

    docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "sed -i 's/||[^|]*|$//' /session/.claude-projects.yml"

    # Verify the fix
    local fixed_content
    fixed_content=$(docker run --rm -v "$volume:/session:ro" "$git_image" \
        cat /session/.claude-projects.yml 2>/dev/null || echo "")

    if echo "$fixed_content" | grep -q '||'; then
        error "Repair incomplete - some paths may still be corrupted"
        return 1
    fi

    success "Config repaired successfully"
    echo ""
    echo "Fixed config:"
    echo "$fixed_content" | head -20
}
