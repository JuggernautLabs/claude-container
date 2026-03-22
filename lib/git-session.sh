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

# Write a repo manifest (root_commit|dirname) for all git repos in a session volume.
# Used to detect renames/additions/deletions between creation and extraction.
# Arguments:
#   $1 - volume name
write_repo_manifest() {
    local volume="$1"
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"
    local host_uid
    host_uid=$(get_host_uid)

    docker run --rm --entrypoint sh \
        --user "$host_uid:$host_uid" \
        -v "$volume:/session" \
        "$git_image" \
        -c '
            git config --global --add safe.directory "*"
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                # Get path relative to /session (e.g. "org/repo" or "repo")
                name="${d#/session/}"
                name="${name%/}"
                root=$(cd "$d" && git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
                [ -n "$root" ] && echo "${root}|${name}"
            done | sort > /session/.repo-manifest
        ' 2>/dev/null || true
}

# Read current repo manifest from a session volume.
# Returns: root_commit|dirname lines (or empty)
# Arguments:
#   $1 - volume name
read_repo_manifest() {
    local volume="$1"
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"

    docker run --rm --entrypoint sh -v "$volume:/session:ro" "$git_image" \
        -c 'cat /session/.repo-manifest' 2>/dev/null || true
}

# Scan current repo state in a session volume (live, not from saved manifest).
# Returns: root_commit|dirname lines
# Arguments:
#   $1 - volume name
scan_repo_manifest() {
    local volume="$1"
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"

    docker run --rm --entrypoint sh \
        -v "$volume:/session:ro" \
        "$git_image" \
        -c '
            git config --global --add safe.directory "*"
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"
                name="${name%/}"
                root=$(cd "$d" && git rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
                [ -n "$root" ] && echo "${root}|${name}"
            done | sort
        ' 2>/dev/null || true
}

# Diff two repo manifests and report changes.
# Arguments:
#   $1 - old manifest (string, newline-separated)
#   $2 - new manifest (string, newline-separated)
# Prints changes to stdout. Returns 0 if changes found, 1 if identical.
diff_repo_manifests() {
    local old_manifest="$1"
    local new_manifest="$2"
    local has_changes=false

    # Build associative arrays: hash→name
    declare -A old_by_hash new_by_hash old_by_name new_by_name
    while IFS='|' read -r hash name; do
        [[ -z "$hash" ]] && continue
        old_by_hash[$hash]="$name"
        old_by_name[$name]="$hash"
    done <<< "$old_manifest"

    while IFS='|' read -r hash name; do
        [[ -z "$hash" ]] && continue
        new_by_hash[$hash]="$name"
        new_by_name[$name]="$hash"
    done <<< "$new_manifest"

    # Detect renames: same hash, different name
    for hash in "${!old_by_hash[@]}"; do
        local old_name="${old_by_hash[$hash]}"
        if [[ -n "${new_by_hash[$hash]:-}" ]]; then
            local new_name="${new_by_hash[$hash]}"
            if [[ "$old_name" != "$new_name" ]]; then
                info "  Renamed: $old_name → $new_name"
                has_changes=true
            fi
        fi
    done

    # Detect deletions: hash in old but not in new
    for hash in "${!old_by_hash[@]}"; do
        if [[ -z "${new_by_hash[$hash]:-}" ]]; then
            warn "  Deleted: ${old_by_hash[$hash]}"
            has_changes=true
        fi
    done

    # Detect additions: hash in new but not in old
    for hash in "${!new_by_hash[@]}"; do
        if [[ -z "${old_by_hash[$hash]:-}" ]]; then
            info "  Added: ${new_by_hash[$hash]}"
            has_changes=true
        fi
    done

    $has_changes && return 0 || return 1
}

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

# Apply host working tree state (uncommitted changes) into a session volume as a WIP commit.
# Copies modified/untracked files, removes deleted tracked files, then commits.
# Arguments:
#   $1 - source_path: absolute path to host git repo
#   $2 - volume: Docker volume name
#   $3 - project_name: directory name inside the volume (e.g. "myrepo")
# Returns:
#   0 on success or clean tree, 1 on failure (non-fatal, warns only)
_apply_dirty_overlay() {
    local source_path="$1"
    local volume="$2"
    local project_name="$3"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
    local host_uid
    host_uid=$(get_host_uid)

    # Host-side check: skip if working tree is clean
    if [[ -z "$(git -C "$source_path" status --porcelain 2>/dev/null)" ]]; then
        return 0
    fi

    info "Applying uncommitted changes to '$project_name'..."

    # Single docker run: copy changed/untracked files, remove deleted, commit
    if ! docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$source_path:/source:ro" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c '
            set -e
            cd "/session/'"$project_name"'"
            git config --local safe.directory "*"

            # Copy modified/added tracked files (exclude deleted)
            git -C /source diff --name-only --diff-filter=d HEAD 2>/dev/null | while IFS= read -r f; do
                [ -z "$f" ] && continue
                mkdir -p "$(dirname "$f")"
                cp "/source/$f" "$f"
            done

            # Remove deleted tracked files
            git -C /source diff --name-only --diff-filter=D HEAD 2>/dev/null | while IFS= read -r f; do
                [ -z "$f" ] && continue
                rm -f "$f"
            done

            # Copy untracked files (respects .gitignore)
            git -C /source ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r f; do
                [ -z "$f" ] && continue
                mkdir -p "$(dirname "$f")"
                cp "/source/$f" "$f"
            done

            # Stage and commit (skip if nothing changed)
            git add -A
            if ! git diff --cached --quiet; then
                git commit -m "WIP: uncommitted changes from host" --no-verify
            fi
        ' 2>&1; then
        warn "Failed to apply dirty overlay to '$project_name' (non-fatal)"
        return 1
    fi

    success "  Applied uncommitted changes to '$project_name'"
    return 0
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
        # 1. If --from flag specified, use that (highest priority)
        # 2. If source_branch specified in config, use that
        # 3. Else if session name matches a branch in the repo, use that
        # 4. Else use whatever is checked out (HEAD)
        local clone_branch="$source_branch"
        if [[ -n "${FROM_BRANCH:-}" ]]; then
            clone_branch="$FROM_BRANCH"
        elif [[ -z "$clone_branch" ]] && [[ -n "$name" ]]; then
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

    # Write repo manifest for rename/change detection on extract
    write_repo_manifest "$volume"

    # Apply uncommitted host changes if --dirty was specified
    if ${DIRTY_SESSION:-false}; then
        while IFS='|' read -r proj_name proj_path proj_branch proj_track proj_source; do
            [[ -z "$proj_name" ]] && continue
            # Skip projects that failed to clone (no .git dir)
            docker run --rm -v "$volume:/session:ro" "$git_image" \
                sh -c "test -d '/session/$proj_name/.git'" 2>/dev/null || continue
            _apply_dirty_overlay "$proj_path" "$volume" "$proj_name"
        done <<< "$projects"
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

    # If CONFIG_FILE was already set (e.g. by --discover-repos in main script),
    # use it directly — don't re-discover.
    if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
        create_multi_project_session "$name" "$CONFIG_FILE"
        return $?
    fi

    # Check for --discover-repos flags (highest priority)
    if [[ ${#DISCOVER_REPOS_DIRS[@]} -gt 0 ]]; then
        local discovered_config
        discovered_config=$(discover_repos_multi "${DISCOVER_REPOS_DIRS[@]}")
        create_multi_project_session "$name" "$discovered_config"
        rm -f "$discovered_config"  # Clean up temp file
        return $?
    fi

    # Check for multi-project config file (skip if --no-config)
    local config_file
    if ! ${NO_CONFIG:-false} && config_file=$(find_config_file "$source_dir"); then
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

    # Get project name from directory basename
    local project_name
    project_name=$(basename "$source_dir")
    local abs_source_dir
    abs_source_dir=$(cd "$source_dir" && pwd)

    # Initialize volume with correct ownership (volumes are created as root)
    docker run --rm \
        -v "$volume:/session" \
        "$git_image" \
        chown "$host_uid:$host_uid" /session

    # Store config file for consistent structure (even single-project uses /session/{name}/)
    local temp_config="$CACHE_DIR/session-config-$$.yml"
    mkdir -p "$CACHE_DIR"
    cat > "$temp_config" << EOF
version: "1"
projects:
  ${project_name}:
    path: ${abs_source_dir}
EOF

    docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$temp_config:/tmp/config.yml:ro" \
        -v "$volume:/session" \
        "$git_image" \
        cp /tmp/config.yml /session/.claude-projects.yml 2>/dev/null
    rm -f "$temp_config"

    # Store main project name for container startup
    docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "echo '$project_name' > /session/.main-project" 2>/dev/null

    # Determine which branch to clone:
    # 1. If --from flag specified, use that (highest priority)
    # 2. Else if session name matches a branch in the repo, use that
    # 3. Else use whatever is checked out (HEAD)
    local branch_flag=""
    if [[ -n "${FROM_BRANCH:-}" ]]; then
        branch_flag="--branch $FROM_BRANCH"
        info "Cloning repository (branch: $FROM_BRANCH)..."
    elif git -C "$source_dir" show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
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

    # Clone into /session/{project_name}/ for consistent structure
    if ! clone_output=$(docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$source_mount_arg" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "
            git -c safe.directory='*' clone --depth 1 $branch_flag /source '/session/$project_name' &&
            cd '/session/$project_name' &&
            git remote remove origin 2>/dev/null || true &&
            git config user.email 'claude@container' &&
            git config user.name 'Claude'
        " 2>&1); then
        error "Git clone failed:"
        echo "$clone_output" >&2
        docker volume rm "$volume" >/dev/null 2>&1
        exit 1
    fi

    # Write repo manifest for rename/change detection on extract
    write_repo_manifest "$volume"

    # Apply uncommitted host changes if --dirty was specified
    if ${DIRTY_SESSION:-false}; then
        _apply_dirty_overlay "$abs_source_dir" "$volume" "$project_name"
    fi

    success "Git session created: $name"
}
