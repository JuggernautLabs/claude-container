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
#   - DISCOVER_REPOS_DIR: directory to scan for repos (set via --discover-repos flag)
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
    {
        echo 'version: "1"'
        echo 'projects:'
        while IFS='|' read -r proj_name proj_path; do
            [[ -z "$proj_name" ]] && continue
            echo "  ${proj_name}:"
            echo "    path: ${proj_path}"
        done <<< "$projects"
    } > "$temp_config"

    # Copy via mounted temp file (works for any size)
    if ! docker run --rm \
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

    # Clone each project into its subdirectory
    local project_count=0
    while IFS='|' read -r project_name source_path; do
        [[ -z "$project_name" ]] && continue  # Skip empty lines
        project_count=$((project_count + 1))

        info "Cloning project '$project_name' from $source_path..."

        # Clone repo into /session/{project_name}/
        local clone_output
        if ! clone_output=$(docker run --rm \
            -v "$source_path:/source:ro" \
            -v "$volume:/session" \
            "$git_image" \
            sh -c "git config --global --add safe.directory '*' && \
                   git clone /source /session/$project_name" 2>&1); then
            error "Failed to clone project '$project_name':"
            echo "$clone_output" >&2
            docker volume rm "$volume" >/dev/null 2>&1
            exit 1
        fi

        # Configure the cloned repo
        docker run --rm \
            -v "$volume:/session" \
            "$git_image" \
            sh -c "
                cd /session/$project_name
                git config --global --add safe.directory '*'
                git remote remove origin 2>/dev/null || true
                git config user.email 'claude@container'
                git config user.name 'Claude'
            "

        success "  Cloned: $project_name"
    done <<< "$projects"

    # Fix ownership for all projects in one batch operation
    info "Fixing ownership..."
    docker run --rm \
        -v "$volume:/session" \
        -e "HOST_UID=$host_uid" \
        "$git_image" \
        sh -c 'chown -R ${HOST_UID:-1000}:${HOST_UID:-1000} /session'

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

    # Check for --discover-repos flag (highest priority)
    if [[ -n "${DISCOVER_REPOS_DIR:-}" ]]; then
        local discovered_config
        discovered_config=$(discover_repos_in_dir "$DISCOVER_REPOS_DIR")
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
    if [[ ! -d "$source_dir/.git" ]]; then
        error "Source directory is not a git repository: $source_dir"
        exit 1
    fi

    info "Creating git session: $name"
    docker volume create "$volume" >/dev/null

    # Clone repo into volume, strip remotes for safety
    # Use main image (has git) instead of pulling alpine/git
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
    info "Cloning repository into session volume..."

    # Run clone and capture exit status
    # Mark /source as safe to avoid "dubious ownership" errors (container user != host user)
    local host_uid
    host_uid=$(get_host_uid)
    local clone_output
    if ! clone_output=$(docker run --rm \
        -v "$source_dir:/source:ro" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c 'git config --global --add safe.directory "*" && git clone /source /session' 2>&1); then
        error "Git clone failed:"
        echo "$clone_output" >&2
        docker volume rm "$volume" >/dev/null 2>&1
        exit 1
    fi

    # Configure the cloned repo and fix ownership for developer user
    docker run --rm \
        -v "$volume:/session" \
        -e "HOST_UID=$host_uid" \
        "$git_image" \
        sh -c '
            cd /session
            git config --global --add safe.directory "*"
            git remote remove origin 2>/dev/null || true
            git config user.email "claude@container"
            git config user.name "Claude"
            chown -R ${HOST_UID:-1000}:${HOST_UID:-1000} /session
        '

    success "Git session created: $name"
}
