#!/usr/bin/env bash
# claude-container git session module - git-based session isolation
# Source this file after utils.sh, platform.sh, and config.sh
#
# This module provides git-based session isolation by cloning repositories
# into Docker volumes, supporting both single-repo and multi-project sessions.
#
# Dependencies:
#   - utils.sh must be sourced first (provides: info, success, warn, error)
#   - platform.sh must be sourced first (provides: get_host_uid)
#   - config.sh must be sourced first (provides: find_config_file, validate_config,
#     parse_config_file, discover_repos_in_dir)
#
# Required globals:
#   - CACHE_DIR: directory for caching temporary files
#   - IMAGE_NAME or DEFAULT_IMAGE: Docker image to use for git operations
#
# Optional globals:
#   - DISCOVER_REPOS_DIRS: array of directories to scan for repos (set via --discover-repos flags)
#   - CONFIG_FILE: path to config file (set via --config flag)

# Check if a volume contains multi-project config
# Arguments:
#   $1 - volume name to check
# Returns:
#   0 if .claude-projects.yml exists in volume, 1 otherwise
has_multi_project_config() {
    local volume="$1"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Check if .claude-projects.yml exists in volume
    docker run --rm \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c 'test -f /session/.claude-projects.yml' 2>/dev/null
}

# Create multi-project git session from config file
# Clones multiple repositories into a single session volume based on YAML config
# Arguments:
#   $1 - session name
#   $2 - path to config file
# Returns:
#   0 on success, exits on failure
create_multi_project_session() {
    local name="$1"
    local config_file="$2"
    local volume="claude-session-${name}"

    # Check if session already exists
    if docker volume inspect "$volume" &>/dev/null; then
        info "Resuming existing multi-project session: $name"
        return 0
    fi

    # Validate config first (fail fast)
    validate_config "$config_file"

    # Parse projects
    local projects
    projects=$(parse_config_file "$config_file")

    info "Creating multi-project session: $name"
    docker volume create "$volume" >/dev/null

    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
    local host_uid
    host_uid=$(get_host_uid)

    # Initialize volume with correct ownership (volumes are created as root)
    docker run --rm \
        -v "$volume:/session" \
        "$git_image" \
        chown "$host_uid:$host_uid" /session

    # Verify projects variable is populated
    if [[ -z "$projects" ]]; then
        error "No projects to clone (parse result was empty)"
        docker volume rm "$volume" >/dev/null 2>&1
        exit 1
    fi

    # Create config file with absolute paths using temp file (avoids env var size limits)
    info "Storing config in session volume..."
    local temp_config="$CACHE_DIR/session-config-$$.yml"
    mkdir -p "$CACHE_DIR"

    # Write config to temp file (streaming, not accumulating in memory)
    # Format from parse_config_file: name|path|branch|track|source
    {
        echo 'version: "1"'
        echo 'projects:'
        while IFS='|' read -r proj_name proj_path proj_branch proj_track proj_source; do
            [[ -z "$proj_name" ]] && continue
            echo "  ${proj_name}:"
            echo "    path: ${proj_path}"
        done <<< "$projects"
    } > "$temp_config"

    # Copy via mounted temp file (works for any size), run as target UID
    if ! docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$temp_config:/tmp/config.yml:ro" \
        -v "$volume:/session" \
        "$git_image" \
        cp /tmp/config.yml /session/.claude-projects.yml 2>&1; then
        error "Failed to store config in volume"
        rm -f "$temp_config"
        docker volume rm "$volume" >/dev/null 2>&1
        exit 1
    fi
    rm -f "$temp_config"  # Clean up immediately

    info "Config stored successfully"

    # Store main project name for container startup (determines initial working directory)
    local main_project
    main_project=$(get_main_project "$config_file")
    if [[ -n "$main_project" ]]; then
        docker run --rm \
            --user "$host_uid:$host_uid" \
            -v "$volume:/session" \
            "$git_image" \
            sh -c "echo '$main_project' > /session/.main-project" 2>/dev/null
        info "Main project: $main_project"
    fi

    # Clone all projects in parallel, running as target UID (no chown needed)
    local project_count=0
    local pids=()
    local project_names=()
    local project_track=()
    local log_dir="$CACHE_DIR/clone-logs-$$"
    mkdir -p "$log_dir"

    while IFS='|' read -r project_name source_path source_branch source_track source_source; do
        [[ -z "$project_name" ]] && continue
        project_count=$((project_count + 1))
        project_names+=("$project_name")
        project_track+=("${source_track:-true}")

        # Determine which branch to clone:
        # 1. If source_branch specified in config, use that
        # 2. Else if session name matches a branch in the repo, use that
        # 3. Else use whatever is checked out (HEAD)
        local clone_branch="$source_branch"
        if [[ -z "$clone_branch" ]] && [[ -n "$name" ]]; then
            # Check if a branch matching session name exists
            if git -C "$source_path" show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
                clone_branch="$name"
            fi
        fi

        local branch_info=""
        [[ -n "$clone_branch" ]] && branch_info=" (branch: $clone_branch)"
        info "Cloning '$project_name'$branch_info..."

        # Clone and configure in one docker run, in background
        # Run as target UID so files are created with correct ownership (no chown needed)
        # Use git -c flags instead of --global config (no home dir for arbitrary UID)
        local safe_log_name="${project_name//\//_}"  # Replace / with _ for log filename
        local branch_flag=""
        [[ -n "$clone_branch" ]] && branch_flag="--branch $clone_branch"
        (
            docker run --rm \
                --user "$host_uid:$host_uid" \
                -v "$source_path:/source:ro" \
                -v "$volume:/session" \
                "$git_image" \
                sh -c "
                    mkdir -p /session/$(dirname "$project_name") && \
                    git -c safe.directory='*' clone --depth 1 $branch_flag /source '/session/$project_name' && \
                    cd '/session/$project_name' && \
                    git remote remove origin 2>/dev/null || true && \
                    git config user.email 'claude@container' && \
                    git config user.name 'Claude' && \
                    du -sh '/session/$project_name' | cut -f1
                " > "$log_dir/$safe_log_name.log" 2>&1
            echo $? > "$log_dir/$safe_log_name.status"
        ) &
        pids+=($!)
    done <<< "$projects"

    # Wait for all clones to complete (report as they finish, not in order)
    local failed=0
    local start_time=$SECONDS
    local remaining=${#pids[@]}

    while [[ $remaining -gt 0 ]]; do
        # Wait for any one process to complete
        wait -n "${pids[@]}" 2>/dev/null || true

        # Check which ones finished
        for i in "${!pids[@]}"; do
            [[ -z "${pids[$i]}" ]] && continue  # Already processed
            local safe_log_name="${project_names[$i]//\//_}"
            local status_file="$log_dir/$safe_log_name.status"

            if [[ -f "$status_file" ]]; then
                local elapsed=$((SECONDS - start_time))
                local status=$(cat "$status_file")
                if [[ "$status" == "0" ]]; then
                    local size=$(tail -1 "$log_dir/$safe_log_name.log")
                    success "  ✓ ${project_names[$i]} (${elapsed}s, ${size})"
                else
                    error "  ✗ ${project_names[$i]} failed (${elapsed}s)"
                    cat "$log_dir/$safe_log_name.log" >&2
                    failed=1
                fi
                pids[$i]=""  # Mark as processed
                remaining=$((remaining - 1))
            fi
        done
    done

    rm -rf "$log_dir"

    if [[ "$failed" == "1" ]]; then
        error "Some projects failed to clone"
        docker volume rm "$volume" >/dev/null 2>&1
        exit 1
    fi

    success "Multi-project session created: $name ($project_count projects)"
}

# Git-based session isolation - clones repo into volume, strips remotes
# This replaces privileged overlay mode with a safer git-based approach
# Arguments:
#   $1 - session name
#   $2 - source directory (path to git repository)
# Returns:
#   0 on success, exits on failure
create_git_session() {
    local name="$1"
    local source_dir="$2"
    local volume="claude-session-${name}"

    # Check if source_dir is itself a Docker volume mount (DinD scenario)
    local source_volume_name=""
    if [[ -f /proc/self/mountinfo ]]; then
        source_volume_name=$(grep " $source_dir " /proc/self/mountinfo 2>/dev/null | grep -oP '/var/lib/docker/volumes/\K[^/]+' | head -1 || echo "")
    fi

    # Check for --discover-repos flags (highest priority)
    if [[ ${#DISCOVER_REPOS_DIRS[@]} -gt 0 ]]; then
        local discovered_config
        discovered_config=$(discover_repos_multi "${DISCOVER_REPOS_DIRS[@]}")
        create_multi_project_session "$name" "$discovered_config"
        rm -f "$discovered_config"  # Clean up temp file
        return $?
    fi

    # Check for multi-project config file
    local config_file
    if config_file=$(find_config_file "$source_dir"); then
        info "Multi-project config detected: $config_file"
        create_multi_project_session "$name" "$config_file"
        return $?
    fi

    # Check if session already exists
    if docker volume inspect "$volume" &>/dev/null; then
        info "Resuming existing git session: $name"
        return 0
    fi

    # Verify source directory exists and is a git repo
    if [[ ! -d "$source_dir" ]]; then
        error "Source directory does not exist: $source_dir"
        exit 1
    fi
    if ! is_git_repo "$source_dir"; then
        error "Source directory is not a git repository: $source_dir"
        exit 1
    fi

    info "Creating git session: $name"
    docker volume create "$volume" >/dev/null

    # Clone repo into volume, strip remotes for safety
    # Use main image (has git) instead of pulling alpine/git
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
    local host_uid
    host_uid=$(get_host_uid)

    # Initialize volume with correct ownership (volumes are created as root)
    docker run --rm \
        -v "$volume:/session" \
        "$git_image" \
        chown "$host_uid:$host_uid" /session

    # Check if a branch matching session name exists, use it if so
    local branch_flag=""
    if git -C "$source_dir" show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
        branch_flag="--branch $name"
        info "Cloning repository (branch: $name)..."
    else
        info "Cloning repository into session volume..."
    fi

    # Run clone as target UID so files have correct ownership (no chown needed)
    # Use git -c flags instead of --global config (no home dir for arbitrary UID)
    local clone_output

    # Determine the correct mount argument for source
    local source_mount_arg
    if [[ -n "$source_volume_name" ]]; then
        # DinD scenario: mount volume by name
        source_mount_arg="$source_volume_name:/source:ro"
    else
        # Normal scenario: mount directory by path
        source_mount_arg="$source_dir:/source:ro"
    fi
    if ! clone_output=$(docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$source_mount_arg" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "
            git -c safe.directory='*' clone --depth 1 $branch_flag /source /session &&
            cd /session &&
            git remote remove origin 2>/dev/null || true &&
            git config user.email 'claude@container' &&
            git config user.name 'Claude'
        " 2>&1); then
        error "Git clone failed:"
        echo "$clone_output" >&2
        docker volume rm "$volume" >/dev/null 2>&1
        exit 1
    fi

    success "Git session created: $name"
}
