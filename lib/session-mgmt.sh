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
#   - session_extract: Extract session to worktree for manual merge
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
        echo "  claude-container --import-session ~/.claude my-session"
        echo ""
        echo "  # Import from backup directory"
        echo "  claude-container --import-session /backups/claude-session-2024 my-session"
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

# Extract session to a worktree (one-way copy)
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
    local temp_dir="$CACHE_DIR/extract-$$"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    # Create temp extraction directory
    mkdir -p "$temp_dir"
    trap "rm -rf '$temp_dir'" EXIT

    # Get session size for progress display
    local session_size
    session_size=$(docker run --rm -v "$volume:/session:ro" "$git_image" \
        du -sb /session 2>/dev/null | cut -f1)
    local session_size_human
    session_size_human=$(docker run --rm -v "$volume:/session:ro" "$git_image" \
        du -sh /session 2>/dev/null | cut -f1)

    info "Extracting session '$session_name' ($session_size_human)..."

    # Extract using tar pipe
    local extract_status
    if command -v pv &>/dev/null && [[ -n "$session_size" ]]; then
        docker run --rm \
            -v "$volume:/session:ro" \
            "$git_image" \
            tar -C /session -cf - . 2>/dev/null | pv -s "$session_size" | tar -C "$temp_dir" -xf -
        extract_status=$?
    else
        docker run --rm \
            -v "$volume:/session:ro" \
            "$git_image" \
            tar -C /session -cf - . 2>/dev/null | tar -C "$temp_dir" -xf -
        extract_status=$?
    fi

    if [[ $extract_status -ne 0 ]]; then
        error "Failed to extract session"
        return 1
    fi

    # Check if multi-project (has .claude-projects.yml)
    if [[ -f "$temp_dir/.claude-projects.yml" ]]; then
        _extract_multi_project "$session_name" "$temp_dir" "$force"
    else
        _extract_single_project "$session_name" "$temp_dir" "$force"
    fi
}

# Extract single-project session into original repo as branch
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

    # Fetch from temp and create branch
    info "Creating branch '$session_name'..."
    git -C "$target_repo" fetch "$temp_dir" HEAD 2>/dev/null
    git -C "$target_repo" branch "$session_name" FETCH_HEAD 2>/dev/null

    # Get change summary
    local current_head
    current_head=$(git -C "$target_repo" rev-parse HEAD 2>/dev/null)
    local session_head
    session_head=$(git -C "$target_repo" rev-parse "$session_name" 2>/dev/null)

    if [[ "$current_head" == "$session_head" ]]; then
        success "Created branch: $session_name (no changes)"
    else
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
    fi

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

        # Fetch and create branch
        if git -C "$proj_path" fetch "$session_proj_dir" HEAD 2>/dev/null && \
           git -C "$proj_path" branch "$session_name" FETCH_HEAD 2>/dev/null; then

            # Get change summary comparing session branch to current HEAD
            local current_head
            current_head=$(git -C "$proj_path" rev-parse HEAD 2>/dev/null)
            local session_head
            session_head=$(git -C "$proj_path" rev-parse "$session_name" 2>/dev/null)

            local change_info=""
            if [[ "$current_head" == "$session_head" ]]; then
                change_info="(no changes)"
            else
                # Count commits and changed files
                local commit_count
                commit_count=$(git -C "$proj_path" rev-list --count "$current_head".."$session_name" 2>/dev/null || echo "0")
                local files_changed
                files_changed=$(git -C "$proj_path" diff --stat --name-only "$current_head".."$session_name" 2>/dev/null | wc -l | tr -d ' ')

                if [[ "$commit_count" == "0" && "$files_changed" == "0" ]]; then
                    change_info="(no changes)"
                else
                    change_info="($commit_count commit(s), $files_changed file(s))"
                fi
            fi

            success "  $proj_name → branch '$session_name' $change_info"
            success_count=$((success_count + 1))
        else
            error "  $proj_name failed"
            fail_count=$((fail_count + 1))
        fi
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
