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

# ============================================================================
# Git-Native Sync Functions (fetch/merge based, no patches)
# ============================================================================

# Sync session to local using git fetch
# Mounts local repo into container, fetches from it, and resets session to match
# Arguments:
#   $1 - volume name
#   $2 - project name (empty string for single-project)
#   $3 - local repo path
#   $4 - branch name (optional, defaults to current branch)
# Returns:
#   0 on success, 1 on failure
sync_local_to_session() {
    local volume="$1"
    local project_name="$2"
    local local_path="$3"
    local branch="${4:-}"

    # Get current branch if not specified
    if [[ -z "$branch" ]]; then
        branch=$(git -C "$local_path" rev-parse --abbrev-ref HEAD)
    fi

    local local_head
    local_head=$(git -C "$local_path" rev-parse HEAD)

    info "Syncing local ($branch) → session..."

    # Build session path
    local session_path="/session"
    [[ -n "$project_name" ]] && session_path="/session/$project_name"

    # Mount both local and session, fetch and reset
    local output
    output=$(docker run --rm \
        -v "$volume:/session" \
        -v "$local_path:/local:ro" \
        ${IMAGE_NAME:-$DEFAULT_IMAGE} sh -c "
            git config --global --add safe.directory '*'
            cd $session_path

            # Add local as remote (ignore if exists)
            git remote add local /local 2>/dev/null || git remote set-url local /local

            # Fetch from local
            git fetch local $branch --quiet

            # Check if we need to update
            LOCAL_HEAD=\$(git rev-parse local/$branch 2>/dev/null)
            SESSION_HEAD=\$(git rev-parse HEAD 2>/dev/null)

            if [ \"\$LOCAL_HEAD\" = \"\$SESSION_HEAD\" ]; then
                echo 'ALREADY_SYNCED:0'
                exit 0
            fi

            # Count commits to push
            COUNT=\$(git rev-list --count HEAD..\$LOCAL_HEAD 2>/dev/null || echo 0)

            # Reset session to match local
            git reset --hard local/$branch >/dev/null
            echo \"SYNCED:\$COUNT\"
        " 2>/dev/null)

    local status="${output%%:*}"
    local count="${output##*:}"

    case "$status" in
        ALREADY_SYNCED)
            # Silent - nothing to do
            return 0
            ;;
        SYNCED)
            success "Pushed $count commit(s) to session"
            return 0
            ;;
        *)
            error "Failed to sync local to session"
            return 1
            ;;
    esac
}

# Sync session changes to local using git fetch
# Mounts session into local context, fetches from it, and merges/fast-forwards
# Arguments:
#   $1 - volume name
#   $2 - project name (empty string for single-project)
#   $3 - local repo path (worktree path)
#   $4 - branch name
# Returns:
#   0 on success (or already synced), 1 on failure
#   Outputs: SYNCED, ALREADY_SYNCED, CONFLICT, or error
sync_session_to_local() {
    local volume="$1"
    local project_name="$2"
    local local_path="$3"
    local branch="${4:-}"

    # Get current branch if not specified
    if [[ -z "$branch" ]]; then
        branch=$(git -C "$local_path" rev-parse --abbrev-ref HEAD)
    fi

    # Build session path
    local session_path="/session"
    [[ -n "$project_name" ]] && session_path="/session/$project_name"

    info "Syncing session → local ($branch)..."

    # Mount both session and local, fetch from session and merge
    local output
    output=$(docker run --rm \
        -v "$volume:/session:ro" \
        -v "$local_path:/local" \
        ${IMAGE_NAME:-$DEFAULT_IMAGE} sh -c "
            git config --global --add safe.directory '*'
            cd /local

            # Add session as remote (ignore if exists)
            git remote add session $session_path 2>/dev/null || git remote set-url session $session_path

            # Fetch from session
            git fetch session HEAD --quiet 2>/dev/null

            # Get commit info
            SESSION_HEAD=\$(git rev-parse FETCH_HEAD 2>/dev/null)
            LOCAL_HEAD=\$(git rev-parse HEAD 2>/dev/null)

            # Same commit = already synced
            if [ \"\$SESSION_HEAD\" = \"\$LOCAL_HEAD\" ]; then
                echo 'ALREADY_SYNCED:0'
                exit 0
            fi

            # Check if local is ancestor of session (can fast-forward)
            if git merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
                COMMIT_COUNT=\$(git rev-list --count HEAD..FETCH_HEAD)
                git merge --ff-only FETCH_HEAD --quiet 2>/dev/null
                echo \"SYNCED:\$COMMIT_COUNT\"
                exit 0
            fi

            # Check if session is ancestor of local (local is ahead)
            if git merge-base --is-ancestor FETCH_HEAD HEAD 2>/dev/null; then
                echo 'LOCAL_AHEAD:0'
                exit 0
            fi

            # Diverged - try to merge
            COMMIT_COUNT=\$(git rev-list --count HEAD..FETCH_HEAD)
            if git merge FETCH_HEAD -m 'Merge session changes' --quiet 2>/dev/null; then
                echo \"MERGED:\$COMMIT_COUNT\"
                exit 0
            else
                git merge --abort 2>/dev/null
                echo 'CONFLICT:0'
                exit 1
            fi
        " 2>/dev/null)

    local result=$?
    local status="${output%%:*}"
    local count="${output##*:}"

    case "$status" in
        ALREADY_SYNCED)
            success "Already synced"
            return 0
            ;;
        SYNCED)
            success "Fast-forwarded $count commit(s) from session"
            return 0
            ;;
        MERGED)
            success "Merged $count commit(s) from session"
            return 0
            ;;
        LOCAL_AHEAD)
            success "Local is ahead of session (nothing to merge)"
            return 0
            ;;
        CONFLICT)
            error "Merge conflict - session and local have diverged"
            echo "  Resolve manually or sync local to session first"
            return 1
            ;;
        *)
            error "Sync failed: $output"
            return 1
            ;;
    esac
}

# Bidirectional sync: ensure local and session are in sync
# First syncs local→session, then session→local
# Arguments:
#   $1 - volume name
#   $2 - project name (empty string for single-project)
#   $3 - local repo path
#   $4 - branch name (optional)
# Returns:
#   0 on success, 1 on failure
bidirectional_sync() {
    local volume="$1"
    local project_name="$2"
    local local_path="$3"
    local branch="${4:-}"

    # First: push local to session (so session has latest local changes)
    if ! sync_local_to_session "$volume" "$project_name" "$local_path" "$branch"; then
        return 1
    fi

    # Then: pull session to local (in case session had changes local didn't)
    if ! sync_session_to_local "$volume" "$project_name" "$local_path" "$branch"; then
        return 1
    fi

    return 0
}

# Compare session and local, return sync status
# Arguments:
#   $1 - volume name
#   $2 - project name
#   $3 - local repo path
# Returns:
#   Outputs one of: SYNCED, SESSION_AHEAD:<count>, LOCAL_AHEAD:<count>, DIVERGED
#   Exit 0 on success, 1 on error
get_sync_status() {
    local volume="$1"
    local project_name="$2"
    local local_path="$3"

    local session_path="/session"
    [[ -n "$project_name" ]] && session_path="/session/$project_name"

    docker run --rm \
        -v "$volume:/session:ro" \
        -v "$local_path:/local:ro" \
        ${IMAGE_NAME:-$DEFAULT_IMAGE} sh -c "
            git config --global --add safe.directory '*'

            SESSION_TREE=\$(cd $session_path && git rev-parse HEAD^{tree} 2>/dev/null)
            LOCAL_TREE=\$(cd /local && git rev-parse HEAD^{tree} 2>/dev/null)

            if [ \"\$SESSION_TREE\" = \"\$LOCAL_TREE\" ]; then
                echo 'SYNCED'
                exit 0
            fi

            # Add remotes for comparison
            cd /local
            git remote add session $session_path 2>/dev/null || true
            git fetch session HEAD --quiet 2>/dev/null

            # Check relationships
            if git merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
                COUNT=\$(git rev-list --count HEAD..FETCH_HEAD)
                echo \"SESSION_AHEAD:\$COUNT\"
            elif git merge-base --is-ancestor FETCH_HEAD HEAD 2>/dev/null; then
                COUNT=\$(git rev-list --count FETCH_HEAD..HEAD)
                echo \"LOCAL_AHEAD:\$COUNT\"
            else
                echo 'DIVERGED'
            fi
        " 2>/dev/null
}

# Merge a single project from session volume to target directory
# Uses git-native fetch/merge instead of patches
# Arguments:
#   $1 - volume name
#   $2 - project name (empty string for single-project sessions)
#   $3 - target directory (repo path or worktree path)
#   $4 - git image (unused, kept for compatibility)
# Returns:
#   0 on success, 1 on failure
merge_session_project() {
    local volume="$1"
    local project_name="$2"
    local target_path="$3"
    local git_image="$4"  # unused but kept for API compatibility

    # First sync local to session (so session has any local changes)
    sync_local_to_session "$volume" "$project_name" "$target_path" || return 1

    # Then sync session to local (pull any session changes)
    sync_session_to_local "$volume" "$project_name" "$target_path" || return 1

    # Verify sync succeeded
    verify_sync "$volume" "$project_name" "$target_path"
}

# Verify that local and session are in sync
# Arguments:
#   $1 - volume name
#   $2 - project name
#   $3 - local repo path
# Returns:
#   0 if synced, 1 if not
verify_sync() {
    local volume="$1"
    local project_name="$2"
    local local_path="$3"

    local session_path="/session"
    [[ -n "$project_name" ]] && session_path="/session/$project_name"

    # Get both HEADs and compare
    local local_head session_head
    local_head=$(git -C "$local_path" rev-parse HEAD 2>/dev/null)
    session_head=$(docker run --rm -v "$volume:/session:ro" \
        ${IMAGE_NAME:-$DEFAULT_IMAGE} sh -c "
            git config --global --add safe.directory '*'
            cd $session_path && git rev-parse HEAD
        " 2>/dev/null)

    if [[ "$local_head" == "$session_head" ]]; then
        success "Verified: local and session at $local_head"
        return 0
    else
        error "Sync verification failed!"
        echo "  Local:   $local_head"
        echo "  Session: $session_head"
        return 1
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

# Merge multi-project session commits back to source repositories
merge_multi_project_session() {
    local name="$1"
    local target_dir="$2"
    local target_branch="${3:-$name}"  # Default to session name if --into not specified
    local auto_mode="${4:-false}"
    local no_run="${5:-false}"
    local from_branch="${6:-HEAD}"     # Default to HEAD if --from not specified
    local volume="claude-session-${name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    info "Merging multi-project session: $name"
    info "Target branch: $target_branch"
    if [[ "$from_branch" != "HEAD" ]]; then
        info "Creating from: $from_branch"
    fi
    echo ""

    # Load session config (with host config merge if present)
    local projects
    projects=$(load_session_config "$name")

    # Collect project info into arrays (avoiding docker calls in read loop)
    local -a project_names=()
    local -a project_paths=()
    local -a project_branches=()
    local -a project_track=()
    local -a project_source=()

    while IFS='|' read -r pname ppath pbranch ptrack psource; do
        project_names+=("$pname")
        project_paths+=("$ppath")
        project_branches+=("$pbranch")
        project_track+=("${ptrack:-true}")
        project_source+=("${psource:-}")
    done <<< "$projects"

    # Get status for each project in PARALLEL with live output
    local -a project_status=()
    local -a project_counts=()
    local has_changes=false
    local status_dir
    status_dir=$(mktemp -d)

    echo "Projects:"

    # Launch parallel status checks with immediate output
    local -a pids=()
    for i in "${!project_names[@]}"; do
        local pname="${project_names[$i]}"
        local ppath="${project_paths[$i]}"
        local ptrack="${project_track[$i]}"
        local psource="${project_source[$i]}"

        # Skip untracked projects (no async needed)
        if [[ "$ptrack" != "true" ]]; then
            echo "SKIP:0" > "$status_dir/$i"
            echo "  [-] $pname (untracked)"
            continue
        fi

        # Handle discovered repos
        if [[ "$psource" == "discovered" ]]; then
            (
                commit_count=$(get_total_commits "$volume" "$pname" 2>/dev/null)
                echo "NEW:$commit_count" > "$status_dir/$i"
                echo "  [+] $pname (NEW repo - $commit_count commit(s), will extract)"
            ) &
            pids+=($!)
            continue
        fi

        # Get sync status async with immediate output
        (
            result=$(get_sync_status "$volume" "$pname" "$ppath" 2>/dev/null)
            echo "$result" > "$status_dir/$i"
            status="${result%%:*}"
            count="${result##*:}"
            [[ "$count" == "$status" ]] && count="0"
            case "$status" in
                SYNCED)       echo "  [✓] $pname (synced)" ;;
                SESSION_AHEAD) echo "  [↓] $pname ($count commit(s) to pull from session)" ;;
                LOCAL_AHEAD)  echo "  [↑] $pname ($count commit(s) to push to session)" ;;
                DIVERGED)     echo "  [!] $pname (diverged - needs sync)" ;;
                *)            echo "  [?] $pname (checking...)" ;;
            esac
        ) &
        pids+=($!)
    done

    # Wait for all status checks to complete
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    # Collect results into arrays (for later use)
    for i in "${!project_names[@]}"; do
        local sync_result
        sync_result=$(cat "$status_dir/$i" 2>/dev/null || echo "UNKNOWN:0")
        local status="${sync_result%%:*}"
        local count="${sync_result##*:}"
        [[ "$count" == "$status" ]] && count="0"

        project_status+=("$status")
        project_counts+=("$count")

        if [[ "$status" != "SYNCED" && "$status" != "SKIP" ]]; then
            has_changes=true
        fi
    done

    rm -rf "$status_dir"

    if ! $has_changes; then
        warn "No changes to merge in any project"
        return 0
    fi

    # --no-run mode: just show summary and exit
    if [[ "$no_run" == "true" ]]; then
        echo ""
        info "Dry run complete. Use without --no-run to merge."
        return 0
    fi

    echo ""

    # Confirm merge
    if [[ "$auto_mode" == "true" ]]; then
        choice="y"
    else
        read -p "Merge all selected? [y/n] " choice
    fi

    if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
        echo "Cancelled"
        return 0
    fi

    # Sync projects in PARALLEL with live output
    local sync_dir
    sync_dir=$(mktemp -d)
    local -a sync_pids=()
    local projects_to_sync=0

    # Count projects needing sync
    for i in "${!project_names[@]}"; do
        local status="${project_status[$i]}"
        if [[ "$status" != "SYNCED" && "$status" != "SKIP" ]]; then
            projects_to_sync=$((projects_to_sync + 1))
        fi
    done

    if [[ $projects_to_sync -eq 0 ]]; then
        echo ""
        success "All projects already synced"
        rm -rf "$sync_dir"
        return 0
    fi

    echo ""
    echo "Syncing:"

    # Launch parallel syncs with immediate output
    for i in "${!project_names[@]}"; do
        local pname="${project_names[$i]}"
        local ppath="${project_paths[$i]}"
        local ptrack="${project_track[$i]}"
        local status="${project_status[$i]}"

        # Skip untracked and already synced
        if [[ "$ptrack" != "true" ]] || [[ "$status" == "SYNCED" ]] || [[ "$status" == "SKIP" ]]; then
            continue
        fi

        # Launch sync in background with live output
        (
            result="FAIL"

            # Handle discovered repos
            if [[ "$status" == "NEW" ]]; then
                if extract_repo_from_session "$volume" "$pname" "$ppath" "$git_image" >/dev/null 2>&1; then
                    echo "  [✓] $pname extracted to $ppath"
                    echo "OK:extracted" > "$sync_dir/$i"
                else
                    echo "  [✗] $pname extraction failed"
                    echo "FAIL:extract" > "$sync_dir/$i"
                fi
                exit 0
            fi

            # Verify source path is a git repo
            if ! is_git_repo "$ppath"; then
                echo "  [✗] $pname not a git repo at $ppath"
                echo "FAIL:not a git repo" > "$sync_dir/$i"
                exit 1
            fi

            # Create worktree for target branch
            worktree_dir=$(create_or_find_worktree "$ppath" "$target_branch" "$from_branch" "$pname" 2>/dev/null)
            if [[ $? -ne 0 ]]; then
                echo "  [✗] $pname worktree creation failed"
                echo "FAIL:worktree" > "$sync_dir/$i"
                exit 1
            fi

            # Perform bidirectional sync
            if sync_local_to_session "$volume" "$pname" "$worktree_dir" >/dev/null 2>&1 && \
               sync_session_to_local "$volume" "$pname" "$worktree_dir" >/dev/null 2>&1; then
                # Verify
                local_head=$(git -C "$worktree_dir" rev-parse HEAD 2>/dev/null)
                session_head=$(docker run --rm -v "$volume:/session:ro" \
                    ${IMAGE_NAME:-$DEFAULT_IMAGE} sh -c "
                        git config --global --add safe.directory '*'
                        cd /session/$pname && git rev-parse HEAD
                    " 2>/dev/null)
                if [[ "$local_head" == "$session_head" ]]; then
                    echo "  [✓] $pname synced at ${local_head:0:7}"
                    echo "OK:$local_head" > "$sync_dir/$i"
                else
                    echo "  [✗] $pname verification failed (local: ${local_head:0:7}, session: ${session_head:0:7})"
                    echo "FAIL:verify" > "$sync_dir/$i"
                fi
            else
                echo "  [✗] $pname sync failed"
                echo "FAIL:sync" > "$sync_dir/$i"
            fi

            # Clean up worktree
            cleanup_worktree "$ppath" "$worktree_dir" "$created_worktree" "$pname" 2>/dev/null
        ) &
        sync_pids+=($!)
    done

    # Wait for all syncs to complete
    for pid in "${sync_pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    # Count results
    local success_count=0
    local fail_count=0

    for i in "${!project_names[@]}"; do
        local status="${project_status[$i]}"
        if [[ "$status" == "SYNCED" ]] || [[ "$status" == "SKIP" ]]; then
            continue
        fi

        local result
        result=$(cat "$sync_dir/$i" 2>/dev/null || echo "FAIL:unknown")
        local res_status="${result%%:*}"

        if [[ "$res_status" == "OK" ]]; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    rm -rf "$sync_dir"

    echo ""
    if [[ $fail_count -eq 0 ]]; then
        if [[ $success_count -eq 0 ]]; then
            success "All projects already synced"
        else
            success "Successfully synced $success_count project(s)"
        fi

        if [[ "$auto_mode" != "true" ]]; then
            echo ""
            read -p "Delete session '$name'? [y/n] " delete_choice
            if [[ "$delete_choice" == "y" ]]; then
                docker volume rm "$volume" >/dev/null
                success "Session deleted: $name"
            fi
        fi
    else
        error "Sync completed with errors ($success_count succeeded, $fail_count failed)"
        return 1
    fi
}

# Merge session commits back to original repo
merge_git_session() {
    local name="$1"
    local target_dir="$2"
    local target_branch="${3:-$name}"  # Default to session name if --into not specified
    local auto_mode="${4:-false}"
    local no_run="${5:-false}"
    local from_branch="${6:-HEAD}"     # Default to HEAD if --from not specified
    local volume="claude-session-${name}"

    # Check if session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $name"
        exit 1
    fi

    # Check if this is a multi-project session
    if has_multi_project_config "$volume"; then
        merge_multi_project_session "$name" "$target_dir" "$target_branch" "$auto_mode" "$no_run" "$from_branch"
        return $?
    fi

    # Check if target is a git repo
    if ! is_git_repo "$target_dir"; then
        error "Target directory is not a git repository: $target_dir"
        exit 1
    fi

    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Get repo name for tracking
    local repo_name
    repo_name=$(basename "$target_dir")

    info "Merging session '$name' into branch: $target_branch"
    if [[ "$from_branch" != "HEAD" ]]; then
        info "Creating from: $from_branch"
    fi

    # Use worktree approach to avoid conflicts with uncommitted changes
    local merge_path
    merge_path=$(create_or_find_worktree "$target_dir" "$target_branch" "$from_branch" "$repo_name")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    echo ""

    # Get sync status
    local sync_status
    sync_status=$(get_sync_status "$volume" "" "$merge_path" 2>/dev/null)
    local status="${sync_status%%:*}"
    local count="${sync_status##*:}"
    [[ "$count" == "$status" ]] && count="0"

    if $no_run; then
        # Show sync status for dry run
        echo "=== Sync Status ==="
        case "$status" in
            SYNCED) echo "  Already synced" ;;
            SESSION_AHEAD) echo "  Session has $count commit(s) to pull" ;;
            LOCAL_AHEAD) echo "  Local has $count commit(s) to push" ;;
            DIVERGED) echo "  Diverged - will attempt merge" ;;
        esac
        echo ""
        info "Dry run - not syncing"
        return 0
    fi

    if [[ "$auto_mode" == "true" ]]; then
        choice="y"
    else
        # Show status for interactive mode
        echo "=== Sync Status ==="
        case "$status" in
            SYNCED)
                success "Already synced"
                cleanup_worktree "$target_dir" "$merge_path" "$created_worktree" "$repo_name"
                return 0
                ;;
            SESSION_AHEAD) echo "  Session has $count commit(s) to pull" ;;
            LOCAL_AHEAD) echo "  Local has $count commit(s) to push to session" ;;
            DIVERGED) echo "  Diverged - will attempt bidirectional sync" ;;
        esac
        echo ""
        read -p "Sync? [y/n] " choice
    fi

    case "$choice" in
        y|Y)
            # Use shared sync function (empty project name for single-project)
            if merge_session_project "$volume" "" "$merge_path" "$git_image"; then
                success "Successfully synced branch '$target_branch'"
                cleanup_worktree "$target_dir" "$merge_path" "$created_worktree" "$repo_name"
            else
                warn "Sync had issues - worktree preserved: $merge_path"
                return 1
            fi

            # In auto mode, don't prompt to delete (preserve session for --continue)
            if [[ "$auto_mode" != "true" ]]; then
                echo ""
                read -p "Delete session '$name'? [y/n] " delete_choice
                if [[ "$delete_choice" == "y" ]]; then
                    docker volume rm "$volume" >/dev/null
                    success "Session deleted: $name"
                fi
            fi
            ;;
        n|N)
            echo "Cancelled"
            cleanup_worktree "$target_dir" "$merge_path" "$created_worktree" "$repo_name"
            ;;
        *)
            echo "Invalid choice"
            cleanup_worktree "$target_dir" "$merge_path" "$created_worktree" "$repo_name"
            ;;
    esac
}
