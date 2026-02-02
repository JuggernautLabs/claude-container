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

# Export patches from session volume for a project
# Compares session against target branch to determine what needs merging:
#   - If target tree == session HEAD tree: already caught up
#   - If target tree matches a session ancestor: export patches from that point
#   - If target tree matches no session commit: diverged, error
# Arguments:
#   $1 - volume name
#   $2 - project name (path within volume, defaults to "" for single-project)
#   $3 - git image
#   $4 - target tree hash (from target branch HEAD)
# Returns:
#   Prints patch file path to stdout (on success)
#   Returns 0 on success (patches to apply), 1 on failure, 2 if caught up, 3 if diverged
export_session_patches() {
    local volume="$1"
    local project_name="$2"
    local git_image="$3"
    local target_tree="$4"

    local patch_file
    patch_file=$(mktemp)

    # Generate patches, comparing against target tree
    docker_run_git "$volume" "$project_name" "
        TARGET_TREE='$target_tree'
        SESSION_HEAD_TREE=\$(git rev-parse HEAD^{tree} 2>/dev/null)

        # Case 1: Already caught up
        if [ \"\$SESSION_HEAD_TREE\" = \"\$TARGET_TREE\" ]; then
            echo 'CAUGHT_UP'
            exit 0
        fi

        # Case 2: Find where target tree matches in session history
        # Walk through all commits from HEAD back to initial
        MERGE_BASE=''
        for commit in \$(git rev-list HEAD); do
            commit_tree=\$(git rev-parse \"\$commit^{tree}\" 2>/dev/null)
            if [ \"\$commit_tree\" = \"\$TARGET_TREE\" ]; then
                MERGE_BASE=\"\$commit\"
                break
            fi
        done

        # Case 3: Target tree doesn't match any session commit
        # Return session HEAD tree so caller can check if local is ahead
        if [ -z \"\$MERGE_BASE\" ]; then
            echo \"NO_MATCH:\$SESSION_HEAD_TREE\"
            exit 0
        fi

        # Generate patches from merge base to HEAD
        PATCH_COUNT=\$(git rev-list --count \"\$MERGE_BASE..HEAD\" 2>/dev/null || echo 0)

        if [ \"\$PATCH_COUNT\" = \"0\" ]; then
            echo 'CAUGHT_UP'
            exit 0
        fi

        echo \"PATCHES:\$PATCH_COUNT\"
        git format-patch --stdout \"\$MERGE_BASE..HEAD\"
    " > "$patch_file"

    # Check first line for status
    local first_line
    first_line=$(head -1 "$patch_file")

    if [[ "$first_line" == "CAUGHT_UP" ]]; then
        rm -f "$patch_file"
        return 2
    fi

    if [[ "$first_line" == NO_MATCH:* ]]; then
        # Return session tree hash for caller to check if local is ahead
        echo "${first_line#NO_MATCH:}"
        rm -f "$patch_file"
        return 3
    fi

    if [[ "$first_line" != "PATCHES:"* ]]; then
        error "Unexpected response from container"
        rm -f "$patch_file"
        return 1
    fi

    echo "$patch_file"
    return 0
}

# Apply patches to a worktree using git am
# Arguments:
#   $1 - patch file path
#   $2 - worktree directory (where to apply patches)
# Returns:
#   0 on success, 1 on failure
apply_patches() {
    local patch_file="$1"
    local worktree_dir="$2"

    # Extract patch count from first line
    local first_line
    first_line=$(head -1 "$patch_file")
    local patch_count="${first_line#PATCHES:}"

    info "Applying $patch_count patch(es)..."

    # Remove the status line and apply patches
    cd "$worktree_dir"
    if tail -n +2 "$patch_file" | git am --3way; then
        success "Merged $patch_count commit(s)"
        return 0
    else
        error "Merge failed - resolve conflicts and run: git am --continue"
        return 1
    fi
}

# Merge a single project from session volume to target directory
# This is the core merge logic shared by both single and multi-project merges
# Arguments:
#   $1 - volume name
#   $2 - project name (empty string for single-project sessions)
#   $3 - target directory (repo path or worktree path)
#   $4 - git image
# Returns:
#   0 on success, 1 on failure
merge_session_project() {
    local volume="$1"
    local project_name="$2"
    local target_path="$3"
    local git_image="$4"

    local display_name="${project_name:-session}"
    info "Merging $display_name to $target_path"

    # Get target branch tree hash for comparison
    local target_tree
    target_tree=$(git -C "$target_path" rev-parse HEAD^{tree} 2>/dev/null)
    if [[ -z "$target_tree" ]]; then
        error "  Failed to get target branch tree hash"
        return 1
    fi

    # Export patches from session (comparing against target)
    local patch_file
    patch_file=$(export_session_patches "$volume" "$project_name" "$git_image" "$target_tree")
    local export_result=$?

    if [[ $export_result -eq 2 ]]; then
        success "Already caught up"
        return 0
    elif [[ $export_result -eq 3 ]]; then
        # patch_file contains session tree hash - check if local is ahead
        local session_tree="$patch_file"
        # Check if session tree exists in local history
        if git -C "$target_path" log --format='%T' | grep -q "^${session_tree}$"; then
            success "Already caught up (local is ahead of session)"
            return 0
        else
            error "Session and target branch have diverged"
            echo "  The target branch contains changes not in the session."
            echo "  This can happen if the branch was modified outside the session."
            return 1
        fi
    elif [[ $export_result -ne 0 ]]; then
        error "  Failed to export patches"
        return 1
    fi

    # Apply patches to target
    trap "rm -f '$patch_file'" RETURN
    if apply_patches "$patch_file" "$target_path"; then
        return 0
    else
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

    # Now get status for each project (docker calls outside the read loop)
    local -a project_commits=()
    local has_changes=false

    echo "Projects to merge:"
    for i in "${!project_names[@]}"; do
        local pname="${project_names[$i]}"
        local ptrack="${project_track[$i]}"
        local psource="${project_source[$i]}"

        # Skip untracked projects
        if [[ "$ptrack" != "true" ]]; then
            echo "  [-] $pname (untracked)"
            project_commits+=("0")
            continue
        fi

        # Handle discovered repos (new repos created in session)
        if [[ "$psource" == "discovered" ]]; then
            local commit_count
            commit_count=$(get_total_commits "$volume" "$pname")
            project_commits+=("$commit_count")
            echo "  [+] $pname (NEW - $commit_count commits, will extract)"
            has_changes=true
            continue
        fi

        local commit_count
        commit_count=$(get_session_status "$volume" "$pname")
        project_commits+=("$commit_count")

        if [[ "$commit_count" -gt 0 ]]; then
            echo "  [x] $pname ($commit_count commits)"
            has_changes=true
        else
            echo "  [ ] $pname (no new commits)"
        fi
    done

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

    # Merge each project with commits
    local success_count=0
    local fail_count=0

    for i in "${!project_names[@]}"; do
        local pname="${project_names[$i]}"
        local ppath="${project_paths[$i]}"
        local pbranch="${project_branches[$i]}"
        local ptrack="${project_track[$i]}"
        local psource="${project_source[$i]}"
        local commit_count="${project_commits[$i]}"

        # Skip untracked projects
        if [[ "$ptrack" != "true" ]]; then
            continue
        fi

        if [[ "$commit_count" -eq 0 ]]; then
            continue
        fi

        echo ""

        # Handle discovered repos (new repos created in session) - extract instead of merge
        if [[ "$psource" == "discovered" ]]; then
            if extract_repo_from_session "$volume" "$pname" "$ppath" "$git_image"; then
                success_count=$((success_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
            continue
        fi

        # Verify source path is a git repo
        if ! is_git_repo "$ppath"; then
            error "Source is not a git repo: $ppath"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Create worktree for target branch
        local worktree_dir
        worktree_dir=$(create_or_find_worktree "$ppath" "$target_branch" "$from_branch" "$pname")
        if [[ $? -ne 0 ]]; then
            error "Failed to create worktree for $pname"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Perform the merge in the worktree
        if merge_session_project "$volume" "$pname" "$worktree_dir" "$git_image"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi

        # Clean up temp worktree (branch remains)
        cleanup_worktree "$ppath" "$worktree_dir" "$created_worktree" "$pname"
    done

    echo ""
    if [[ $fail_count -eq 0 ]]; then
        success "Successfully merged all projects ($success_count projects)"

        if [[ "$auto_mode" != "true" ]]; then
            echo ""
            read -p "Delete session '$name'? [y/n] " delete_choice
            if [[ "$delete_choice" == "y" ]]; then
                docker volume rm "$volume" >/dev/null
                success "Session deleted: $name"
            fi
        fi
    else
        error "Merge completed with errors ($success_count succeeded, $fail_count failed)"
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

    if $no_run; then
        # Show what would be merged for dry run
        echo "=== Commits in session ==="
        show_session_commits "$volume" "" "count"
        echo ""
        info "Dry run - not applying changes"
        return 0
    fi

    if [[ "$auto_mode" == "true" ]]; then
        # In auto mode, skip upfront commit list - merge logic will report what happens
        choice="y"
    else
        # Show commits for interactive mode
        echo "=== Commits in session ==="
        show_session_commits "$volume" "" "count"
        echo ""
        read -p "Merge all commits? [y/n/select] " choice
    fi

    case "$choice" in
        y|Y)
            # Use shared merge function (empty project name for single-project)
            if merge_session_project "$volume" "" "$merge_path" "$git_image"; then
                success "Successfully merged to branch '$target_branch'"
                # Clean up worktree if we created it
                cleanup_worktree "$target_dir" "$merge_path" "$created_worktree" "$repo_name"
            else
                # Don't clean up worktree on failure - user needs to resolve
                warn "Worktree preserved for conflict resolution: $merge_path"
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
        select|s|S)
            warn "Interactive selection not yet implemented"
            echo "Use 'git cherry-pick' manually after inspecting the session"
            cleanup_worktree "$target_dir" "$merge_path" "$created_worktree" "$repo_name"
            ;;
        *)
            echo "Invalid choice"
            cleanup_worktree "$target_dir" "$merge_path" "$created_worktree" "$repo_name"
            ;;
    esac
}
