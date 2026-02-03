#!/usr/bin/env bash
# claude-container git-ops module - Git session diff and merge operations
# Source this file after utils.sh and config.sh
#
# Dependencies:
#   - utils.sh must be sourced first (provides: info, success, warn, error, get_main_repo_path)
#   - config.sh must be sourced first (provides: parse_config_file)
#   - docker-utils.sh must be sourced (provides: docker_run_git, docker_run_in_volume)
#
# Required globals:
#   - CACHE_DIR: directory for caching temporary files
#   - IMAGE_NAME or DEFAULT_IMAGE: Docker image for git operations

# Source docker utilities
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIB_DIR/docker-utils.sh"

# Show diff between session and source repository
# Arguments:
#   $1 - volume name (e.g., "claude-session-xyz")
#   $2 - project_path (path within volume, empty string for single-project)
#   $3 - source_path (host path to source repository)
#   $4 - format (optional: "stat" [default], "full", "name-only", etc.)
# Returns:
#   Prints diff output or fallback message
#   Returns 0 on success
show_diff_vs_source() {
    local volume="$1"
    local project_path="$2"
    local source_path="$3"
    local format="${4:-stat}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Construct session path: /session or /session/project_name
    local session_path="/session"
    [[ -n "$project_path" ]] && session_path="/session/$project_path"

    # Construct diff command based on format
    local diff_cmd="git diff --${format} source/HEAD HEAD"

    # This requires mounting both source and session volumes, so we use direct docker run
    # but with the same patterns as docker_run_git for consistency
    docker run --rm \
        -v "$source_path:/source:ro" \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c "
            git config --global --add safe.directory '*'
            cd $session_path
            git remote add source /source 2>/dev/null || true
            git fetch source --quiet 2>/dev/null || true
            $diff_cmd 2>/dev/null || \
                echo '  (unable to compare - source may not be a git repo)'
        " 2>/dev/null
}

# Get session project status (commits pending merge)
get_session_status() {
    local volume="$1"
    local project_name="$2"

    docker_run_git "$volume" "$project_name" '
        # Count all commits from initial commit to HEAD
        INITIAL=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
        git rev-list --count "$INITIAL..HEAD" 2>/dev/null || echo "0"
    ' || echo "0"
}

# Get total commit count for discovered repos (new repos created in session)
# Unlike get_session_status, this counts ALL commits, not from initial
get_total_commits() {
    local volume="$1"
    local project_name="$2"

    docker_run_git "$volume" "$project_name" '
        git rev-list --count HEAD 2>/dev/null || echo "0"
    ' || echo "0"
}

# Get the tree hash of a session's HEAD
# Used to compare session state against target branch
# Arguments:
#   $1 - volume name
#   $2 - project_name (empty string for single-project)
# Returns:
#   Tree hash string on stdout
get_session_tree_hash() {
    local volume="$1"
    local project_name="$2"

    docker_run_git "$volume" "$project_name" '
        git rev-parse HEAD^{tree} 2>/dev/null
    '
}

# Show session commits with various formatting options
# Arguments:
#   $1 - volume: volume name (required)
#   $2 - project_path: path within volume (empty string "" for single-project sessions)
#   $3 - format: "oneline" (default) or "count" (for count-only check)
#   $4 - indent: indentation prefix (default "", use "  " for 2-space indent)
#   $5 - limit: "all" (default) or number for max commits to show
# Output:
#   Prints commits to stdout
# Returns:
#   0 on success
show_session_commits() {
    local volume="$1"
    local project_path="${2:-}"
    local format="${3:-oneline}"
    local indent="${4:-}"
    local limit="${5:-all}"

    # Build sed command for indentation
    local sed_cmd=""
    if [[ -n "$indent" ]]; then
        sed_cmd=" | sed 's/^/$indent/'"
    fi

    # Build the git log command based on format
    if [[ "$format" == "count" ]]; then
        # Count-only format: check count and show log or "(no commits)"
        docker_run_git "$volume" "$project_path" '
            INITIAL=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
            COUNT=$(git rev-list --count "$INITIAL..HEAD" 2>/dev/null || echo "0")
            if [ "$COUNT" = "0" ]; then
                echo "(no commits)"
            else
                git log --oneline "$INITIAL..HEAD" 2>/dev/null
            fi
        '
    else
        # Standard oneline format with optional fallback to -10
        local fallback_cmd=""
        if [[ "$limit" == "all" ]]; then
            fallback_cmd=" || git log --oneline -10"
        fi

        docker_run_git "$volume" "$project_path" '
            initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
            git log --oneline "$initial..HEAD" 2>/dev/null'"$fallback_cmd$sed_cmd"'
        '
    fi
}


# Extract a new repo from session to host filesystem
# Used for repos created inside the session (source: discovered)
# Arguments:
#   $1 - volume name
#   $2 - repo name in session
#   $3 - destination path on host
#   $4 - git image to use
# Returns:
#   0 on success, 1 on failure
extract_repo_from_session() {
    local volume="$1"
    local repo_name="$2"
    local dest_path="$3"
    local git_image="$4"

    info "Extracting new repo: $repo_name -> $dest_path"

    # Check if destination already exists
    if [[ -e "$dest_path" ]]; then
        error "Destination already exists: $dest_path"
        return 1
    fi

    # Create parent directory
    local parent_dir
    parent_dir=$(dirname "$dest_path")
    if [[ ! -d "$parent_dir" ]]; then
        info "  Creating parent directory: $parent_dir"
        mkdir -p "$parent_dir" || {
            error "  Failed to create parent directory"
            return 1
        }
    fi

    # Clone the repo from the volume to a temp location, then move it
    # We use git clone to preserve all git history and metadata
    local temp_clone="$CACHE_DIR/extract-$$-$(date +%s)"
    mkdir -p "$temp_clone"
    trap "rm -rf '$temp_clone'" RETURN

    # Clone from volume to temp directory
    # This requires mounting both session and output volumes, so we use direct docker run
    if ! docker run --rm \
        -v "$volume:/session:ro" \
        -v "$temp_clone:/output" \
        "$git_image" \
        sh -c "
            git config --global --add safe.directory '*'
            git clone /session/$repo_name /output/repo
            cd /output/repo
            # Remove any remote references (they point to container paths)
            git remote remove origin 2>/dev/null || true
        " 2>&1; then
        error "  Failed to clone repo from session"
        return 1
    fi

    # Move to final destination
    if mv "$temp_clone/repo" "$dest_path"; then
        local size
        size=$(du -sh "$dest_path" 2>/dev/null | cut -f1)
        success "  Extracted: $dest_path ($size)"
        return 0
    else
        error "  Failed to move repo to destination"
        return 1
    fi
}

# Check if a volume contains multi-project config
# Load session config from volume and merge with host config
# Extracts .claude-projects.yml from volume, parses it, and merges with host config if present
# Arguments:
#   $1 - session_name: name of the session (without claude-session- prefix)
# Returns:
#   Prints project list in pipe-delimited format (name|path|branch|track|source)
#   Exits on failure (does not return on error)
# Uses globals: CACHE_DIR, SESSIONS_CONFIG_DIR, IMAGE_NAME, DEFAULT_IMAGE
load_session_config() {
    local session_name="$1"
    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Extract config from volume
    local config_data
    config_data=$(docker_run_in_volume "$volume" "/session" "$git_image" 'cat /session/.claude-projects.yml' "ro") || {
        error "Failed to read config from session volume"
        exit 1
    }

    # Create temp file for config
    local temp_config="$CACHE_DIR/temp-config-$$.yml"
    mkdir -p "$CACHE_DIR"
    echo "$config_data" > "$temp_config"
    trap "rm -f '$temp_config'" RETURN

    # Parse config to get project list (name|path pairs)
    local projects
    projects=$(parse_config_file "$temp_config")

    # Also check host config dir for discovered repos
    local host_config="$SESSIONS_CONFIG_DIR/${session_name}.yml"
    if [[ -f "$host_config" ]]; then
        local host_projects
        host_projects=$(parse_config_file "$host_config" 2>/dev/null) || true
        if [[ -n "$host_projects" ]]; then
            # Append host config projects (discovered repos)
            projects="${projects}
${host_projects}"
        fi
    fi

    echo "$projects"
    return 0
}

has_multi_project_config() {
    local volume="$1"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Check if .claude-projects.yml exists in volume
    docker_run_in_volume "$volume" "/session" "$git_image" 'test -f /session/.claude-projects.yml' "ro"
}

# Helper callback for showing project diff summary
# Arguments: $1=project_name $2=source_path $3=branch $4=track $5=source $6=volume
_show_project_diff_summary() {
    local project_name="$1"
    local source_path="$2"
    local _branch="$3"
    local project_track="$4"
    local project_source="$5"
    local volume="$6"

    # Skip untracked projects
    if ! is_project_tracked "$project_track"; then
        echo "Project: $project_name (untracked)"
        echo "  (not tracked for merging)"
        echo ""
        return 0
    fi

    # Handle discovered repos (new repos created in session)
    if [[ "$project_source" == "discovered" ]]; then
        local commit_count
        commit_count=$(get_total_commits "$volume" "$project_name")
        echo "Project: $project_name (NEW - $commit_count commits)"
        echo "  Will extract to: $source_path"
        docker_run_git "$volume" "$project_name" "git log --oneline -5 2>/dev/null | sed 's/^/  /'"
        echo ""
        return 0
    fi

    # Count all commits from initial commit
    local commit_count
    commit_count=$(docker_run_git "$volume" "$project_name" '
        initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
        git rev-list --count "$initial..HEAD" 2>/dev/null || echo 0
    ' < /dev/null) || echo "0"

    echo "Project: $project_name ($commit_count commits)"

    if [[ "$commit_count" -gt 0 ]]; then
        # Show all commit messages
        show_session_commits "$volume" "$project_name" "oneline" "  "
    else
        echo "  (no commits)"
    fi
    echo ""
}

# Show diff for multi-project session
diff_multi_project_session() {
    local name="$1"
    local source_dir="$2"
    local project_filter="${3:-}"
    local volume="claude-session-${name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Load session config (with host config merge if present)
    local projects
    projects=$(load_session_config "$name")

    # If project filter specified, show detailed diff for that project only
    if [[ -n "$project_filter" ]]; then
        local project_line
        if project_line=$(find_project "$projects" "$project_filter"); then
            IFS='|' read -r project_name source_path _branch _track _source <<< "$project_line"
            info "Comparing project '$project_name' with source: $source_path"
            echo ""

            # Show commits made in this project
            echo "=== Commits in session (project: $project_name) ==="
            show_session_commits "$volume" "$project_name"

            echo ""
            echo "=== File changes (session vs source) ==="
            show_diff_vs_source "$volume" "$project_name" "$source_path"
        else
            error "Project not found in session: $project_filter"
            echo "Available projects:"
            while IFS='|' read -r project_name _path _branch; do
                echo "  - $project_name"
            done <<< "$projects"
            exit 1
        fi
        return 0
    fi

    # No filter - show summary of all projects
    info "Multi-project session: $name"
    echo ""

    for_each_project "$projects" _show_project_diff_summary "$volume"

    echo "Tip: Use --diff-session $name <project-name> to see detailed changes for a specific project"
}

# Create or find a worktree for the target branch
# Arguments:
#   $1 - target directory (main repo path)
#   $2 - target branch name
#   $3 - from branch (for new branches)
#   $4 - project name (for temp worktree naming)
# Returns:
#   Prints the worktree path to stdout
#   Returns 0 on success, 1 on failure
# Sets global variable:
#   created_worktree=true if a new temp worktree was created
create_or_find_worktree() {
    local target_dir="$1"
    local target_branch="$2"
    local from_branch="$3"
    local project_name="$4"

    local worktree_dir="$CACHE_DIR/worktree-$$-${project_name//\//-}"
    local existing_worktree=""
    created_worktree=false

    # Check if branch already has a worktree
    existing_worktree=$(cd "$target_dir" && git worktree list --porcelain 2>/dev/null | grep -A2 "^worktree " | grep -B2 "branch refs/heads/$target_branch" | head -1 | sed 's/worktree //' || true)

    if [[ -n "$existing_worktree" && -d "$existing_worktree" ]]; then
        # Use existing worktree for this branch
        info "Using existing worktree: $existing_worktree (branch: $target_branch)"
        echo "$existing_worktree"
        return 0
    elif (cd "$target_dir" && git show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null); then
        # Branch exists but no worktree - create temp worktree for it
        info "Creating temp worktree for existing branch: $target_branch"
        mkdir -p "$worktree_dir"
        if ! (cd "$target_dir" && git worktree add "$worktree_dir" "$target_branch" 2>/dev/null); then
            error "Failed to create worktree"
            return 1
        fi
        created_worktree=true
        echo "$worktree_dir"
        return 0
    else
        # Branch doesn't exist - create new branch from from_branch in temp worktree
        info "Creating branch '$target_branch' from $from_branch in temp worktree"
        mkdir -p "$worktree_dir"
        if ! (cd "$target_dir" && git worktree add "$worktree_dir" -b "$target_branch" "$from_branch" 2>/dev/null); then
            error "Failed to create worktree (branch '$from_branch' may not exist)"
            rm -rf "$worktree_dir"
            return 1
        fi
        created_worktree=true
        echo "$worktree_dir"
        return 0
    fi
}

# Clean up a worktree created by create_or_find_worktree
# Arguments:
#   $1 - target directory (main repo path)
#   $2 - worktree directory
#   $3 - created_worktree flag (true/false)
#   $4 - project name (for logging)
cleanup_worktree() {
    local target_dir="$1"
    local worktree_dir="$2"
    local was_created="$3"
    local project_name="$4"

    if [[ "$was_created" == "true" ]]; then
        info "Cleaning up temp worktree for $project_name"
        (cd "$target_dir" && git worktree remove "$worktree_dir" 2>/dev/null) || rm -rf "$worktree_dir"
    fi
}


# Show diff between git session and original repo
diff_git_session() {
    local name="$1"
    local source_dir="$2"
    local project_filter="${3:-}"
    local volume="claude-session-${name}"

    # Check if session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $name"
        exit 1
    fi

    # Check if this is a multi-project session
    if has_multi_project_config "$volume"; then
        diff_multi_project_session "$name" "$source_dir" "$project_filter"
        return $?
    fi

    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
    info "Comparing session '$name' with source repository..."
    echo ""

    # Show commits made in session
    echo "=== Commits in session ==="
    show_session_commits "$volume" ""

    echo ""
    echo "=== File changes (session vs source) ==="
    show_diff_vs_source "$volume" "" "$source_dir"
}

