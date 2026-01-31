#!/usr/bin/env bash
# claude-container git-ops module - Git session diff and merge operations
# Source this file after utils.sh and config.sh
#
# Dependencies:
#   - utils.sh must be sourced first (provides: info, success, warn, error, get_main_repo_path)
#   - config.sh must be sourced first (provides: parse_config_file)
#
# Required globals:
#   - CACHE_DIR: directory for caching temporary files
#   - IMAGE_NAME or DEFAULT_IMAGE: Docker image for git operations

# Get the merge point (base commit) for a project in a session
# Arguments:
#   $1 - volume name
#   $2 - project name
# Returns:
#   Commit hash (stdout) or empty if not found
get_merge_point() {
    local volume="$1"
    local project_name="$2"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    docker run --rm \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c "cat /session/.last-merge-${project_name} 2>/dev/null || echo ''" 2>/dev/null
}

# Direct merge from volume repo to target path
# This mounts both in a single container and performs the merge directly
merge_volume_to_target() {
    local volume="$1"
    local project_name="$2"
    local target_path="$3"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    info "Merging $project_name from container to $target_path"

    # Create temp file for patches
    local patch_file
    patch_file=$(mktemp)
    trap "rm -f '$patch_file'" RETURN

    # Generate patches from container
    local result
    result=$(docker run --rm \
        -v "$volume:/session:ro" \
        --entrypoint sh \
        "$git_image" \
        -c '
            git config --global --add safe.directory "*"
            cd /session/'"$project_name"'
            SESSION_HEAD=$(git rev-parse HEAD)

            # Check for merge point marker
            MERGE_POINT=""
            if [ -f /session/.last-merge-'"$project_name"' ]; then
                MERGE_POINT=$(cat /session/.last-merge-'"$project_name"')
            fi

            # Check if anything to merge
            if [ -n "$MERGE_POINT" ] && [ "$SESSION_HEAD" = "$MERGE_POINT" ]; then
                echo "NO_CHANGES:0"
                exit 0
            fi

            # Generate patches
            if [ -n "$MERGE_POINT" ]; then
                PATCH_COUNT=$(git rev-list --count "$MERGE_POINT..HEAD" 2>/dev/null || echo 0)
                if [ "$PATCH_COUNT" = "0" ]; then
                    echo "NO_CHANGES:0"
                    exit 0
                fi
                echo "PATCHES:$PATCH_COUNT"
                git format-patch --stdout "$MERGE_POINT..HEAD"
            else
                INITIAL=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                PATCH_COUNT=$(git rev-list --count "$INITIAL..HEAD" 2>/dev/null || echo 0)
                echo "PATCHES:$PATCH_COUNT"
                git format-patch --stdout "$INITIAL..HEAD"
            fi
        ' 2>/dev/null > "$patch_file")

    # Check first line for status
    local first_line
    first_line=$(head -1 "$patch_file")

    if [[ "$first_line" == "NO_CHANGES:"* ]]; then
        echo "  (no new commits)"
        return 0
    fi

    if [[ "$first_line" != "PATCHES:"* ]]; then
        error "  Unexpected response from container"
        return 1
    fi

    local patch_count="${first_line#PATCHES:}"
    info "  Applying $patch_count patch(es)..."

    # Remove the status line and apply patches
    cd "$target_path"
    if tail -n +2 "$patch_file" | git am --3way; then
        success "  Merged $patch_count commit(s)"

        # Record the merge point
        docker run --rm \
            -v "$volume:/session" \
            --entrypoint sh \
            "$git_image" \
            -c '
                git config --global --add safe.directory "*"
                cd /session/'"$project_name"'
                git rev-parse HEAD > /session/.last-merge-'"$project_name"'
            ' 2>/dev/null
        return 0
    else
        error "  Merge failed - resolve conflicts and run: git am --continue"
        return 1
    fi
}

# Get session project status (commits pending merge)
get_session_status() {
    local volume="$1"
    local project_name="$2"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    docker run --rm \
        -v "$volume:/session:ro" \
        --entrypoint sh \
        "$git_image" \
        -c '
            git config --global --add safe.directory "*"
            cd /session/'"$project_name"' 2>/dev/null || exit 1

            SESSION_HEAD=$(git rev-parse HEAD)

            # Check for merge point marker
            if [ -f /session/.last-merge-'"$project_name"' ]; then
                MERGE_POINT=$(cat /session/.last-merge-'"$project_name"')
                if [ "$SESSION_HEAD" = "$MERGE_POINT" ]; then
                    echo "0"
                else
                    git rev-list --count "$MERGE_POINT..HEAD" 2>/dev/null || echo "0"
                fi
            else
                # No merge point - count from initial commit
                INITIAL=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                git rev-list --count "$INITIAL..HEAD" 2>/dev/null || echo "0"
            fi
        ' 2>/dev/null || echo "0"
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
has_multi_project_config() {
    local volume="$1"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Check if .claude-projects.yml exists in volume
    docker run --rm \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c 'test -f /session/.claude-projects.yml' 2>/dev/null
}

# Show diff for multi-project session
diff_multi_project_session() {
    local name="$1"
    local source_dir="$2"
    local project_filter="${3:-}"
    local volume="claude-session-${name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Extract config from volume to get project mappings
    local config_data
    config_data=$(docker run --rm \
        -v "$volume:/session:ro" \
        --entrypoint sh \
        "$git_image" \
        -c 'cat /session/.claude-projects.yml' 2>/dev/null) || {
        error "Failed to read config from session volume"
        exit 1
    }

    # Parse config to get project list (name|path pairs)
    local projects
    # Create temp file for config
    local temp_config="$CACHE_DIR/temp-config-$$.yml"
    mkdir -p "$CACHE_DIR"
    echo "$config_data" > "$temp_config"
    trap "rm -f '$temp_config'" RETURN

    projects=$(parse_config_file "$temp_config")

    # If project filter specified, show detailed diff for that project only
    if [[ -n "$project_filter" ]]; then
        local found=false
        while IFS='|' read -r project_name source_path _branch; do
            if [[ "$project_name" == "$project_filter" ]]; then
                found=true
                info "Comparing project '$project_name' with source: $source_path"
                echo ""

                # Show commits made in this project
                echo "=== Commits in session (project: $project_name) ==="
                docker run --rm \
                    -v "$volume:/session:ro" \
                    "$git_image" \
                    sh -c "
                        git config --global --add safe.directory '*'
                        cd /session/$project_name
                        initial=\$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                        git log --oneline \"\$initial\"..HEAD 2>/dev/null || git log --oneline -10
                    "

                echo ""
                echo "=== File changes (session vs source) ==="
                docker run --rm \
                    -v "$source_path:/source:ro" \
                    -v "$volume:/session:ro" \
                    "$git_image" \
                    sh -c "
                        git config --global --add safe.directory '*'
                        cd /session/$project_name
                        git remote add source /source 2>/dev/null || true
                        git fetch source --quiet 2>/dev/null || true
                        git diff --stat source/HEAD HEAD 2>/dev/null || \
                            echo '  (unable to compare - source may not be a git repo)'
                    "
                break
            fi
        done <<< "$projects"

        if ! $found; then
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

    while IFS='|' read -r project_name source_path _branch project_track project_source; do
        # Skip untracked projects
        if [[ "${project_track:-true}" != "true" ]]; then
            echo "Project: $project_name (untracked)"
            echo "  (not tracked for merging)"
            echo ""
            continue
        fi

        # Handle discovered repos (new repos created in session)
        if [[ "$project_source" == "discovered" ]]; then
            local commit_count
            commit_count=$(docker run --rm \
                -v "$volume:/session:ro" \
                "$git_image" \
                sh -c "
                    git config --global --add safe.directory '*'
                    cd /session/$project_name 2>/dev/null && git rev-list --count HEAD 2>/dev/null || echo 0
                " 2>/dev/null) || echo "0"
            echo "Project: $project_name (NEW - $commit_count commits)"
            echo "  Will extract to: $source_path"
            docker run --rm \
                -v "$volume:/session:ro" \
                "$git_image" \
                sh -c "
                    git config --global --add safe.directory '*'
                    cd /session/$project_name
                    git log --oneline -5 2>/dev/null | sed 's/^/  /'
                " 2>/dev/null
            echo ""
            continue
        fi

        # First check for a recorded merge point (from previous merges)
        local merge_point
        merge_point=$(get_last_merge_point "$volume" "$project_name")

        # Count NEW commits since last merge point
        local commit_count
        local commit_range=""
        if [[ -n "$merge_point" ]]; then
            # Use recorded merge point - this is the most reliable
            commit_count=$(docker run --rm \
                -v "$volume:/session:ro" \
                -e "MERGE_POINT=$merge_point" \
                "$git_image" \
                sh -c '
                    git config --global --add safe.directory "*"
                    cd /session/'"$project_name"' 2>/dev/null || exit 0
                    container_head=$(git rev-parse HEAD 2>/dev/null)
                    if [ "$container_head" = "$MERGE_POINT" ]; then
                        echo 0
                    else
                        git rev-list --count "$MERGE_POINT..HEAD" 2>/dev/null || echo 0
                    fi
                ' < /dev/null) || echo "0"
            commit_range="$merge_point..HEAD"
        else
            # No merge point - fall back to counting all commits (first merge)
            commit_count=$(docker run --rm \
                -v "$volume:/session:ro" \
                "$git_image" \
                sh -c '
                    git config --global --add safe.directory "*"
                    cd /session/'"$project_name"' 2>/dev/null || exit 0
                    initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                    git rev-list --count "$initial..HEAD" 2>/dev/null || echo 0
                ' < /dev/null) || echo "0"
        fi

        echo "Project: $project_name ($commit_count new commits)"

        if [[ "$commit_count" -gt 0 ]]; then
            # Show commit messages since merge point (or all if no merge point)
            docker run --rm \
                -v "$volume:/session:ro" \
                -e "MERGE_POINT=$merge_point" \
                "$git_image" \
                sh -c '
                    git config --global --add safe.directory "*"
                    cd /session/'"$project_name"'
                    if [ -n "$MERGE_POINT" ]; then
                        git log --oneline "$MERGE_POINT..HEAD" 2>/dev/null | sed "s/^/  /"
                    else
                        initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                        git log --oneline "$initial..HEAD" 2>/dev/null | sed "s/^/  /"
                    fi
                ' < /dev/null
        else
            echo "  (no new commits)"
        fi
        echo ""
    done <<< "$projects"

    echo "Tip: Use --diff-session $name <project-name> to see detailed changes for a specific project"
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
    docker run --rm \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c '
            git config --global --add safe.directory "*"
            cd /session
            # Get the initial commit (the clone point)
            initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
            # Show commits after initial
            git log --oneline "$initial"..HEAD 2>/dev/null || git log --oneline -10
        '

    echo ""
    echo "=== File changes (session vs source) ==="
    docker run --rm \
        -v "$source_dir:/source:ro" \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c '
            git config --global --add safe.directory "*"
            cd /session
            # Create a temporary remote to compare
            git remote add source /source 2>/dev/null || true
            git fetch source --quiet 2>/dev/null || true
            # Show diff against source
            git diff --stat source/HEAD HEAD 2>/dev/null || \
                echo "  (unable to compare - source may not be a git repo)"
        '
}

# Merge multi-project session commits back to source repositories
merge_multi_project_session() {
    local name="$1"
    local target_dir="$2"
    local target_branch="${3:-$name}"  # Default to session name if --into not specified
    local auto_mode="${4:-false}"
    local no_run="${5:-false}"
    local volume="claude-session-${name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    info "Merging multi-project session: $name"
    info "Target branch: $target_branch"
    echo ""

    # Extract config from volume (single docker call)
    local config_data
    config_data=$(docker run --rm \
        -v "$volume:/session:ro" \
        --entrypoint sh \
        "$git_image" \
        -c 'cat /session/.claude-projects.yml' 2>/dev/null) || {
        error "Failed to read config from session volume"
        exit 1
    }

    # Parse config from session volume
    local temp_config="$CACHE_DIR/temp-config-$$.yml"
    mkdir -p "$CACHE_DIR"
    echo "$config_data" > "$temp_config"

    local projects
    projects=$(parse_config_file "$temp_config")
    rm -f "$temp_config"

    # Also check host config dir for discovered repos
    local host_config="$SESSIONS_CONFIG_DIR/${name}.yml"
    if [[ -f "$host_config" ]]; then
        local host_projects
        host_projects=$(parse_config_file "$host_config" 2>/dev/null) || true
        if [[ -n "$host_projects" ]]; then
            # Append host config projects (discovered repos)
            projects="${projects}
${host_projects}"
        fi
    fi

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
            commit_count=$(docker run --rm \
                -v "$volume:/session:ro" \
                "$git_image" \
                sh -c "
                    git config --global --add safe.directory '*'
                    cd /session/$pname 2>/dev/null && git rev-list --count HEAD 2>/dev/null || echo 0
                " 2>/dev/null) || echo "0"
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

        # Get merge point (base commit the session was cloned from)
        local merge_point
        merge_point=$(get_merge_point "$volume" "$pname")

        if [[ -z "$merge_point" ]]; then
            warn "No merge point found for $pname - skipping (cannot determine base commit)"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Use worktree approach: create temp worktree at merge point, apply patches, remove worktree
        local merge_branch="$target_branch"
        local worktree_dir="$CACHE_DIR/worktree-$$-${pname//\//-}"
        local existing_worktree=""
        local created_worktree=false

        # Check if branch already has a worktree
        existing_worktree=$(cd "$ppath" && git worktree list --porcelain 2>/dev/null | grep -A2 "^worktree " | grep -B1 "branch refs/heads/$merge_branch" | head -1 | sed 's/worktree //' || true)

        if [[ -n "$existing_worktree" && -d "$existing_worktree" ]]; then
            # Use existing worktree for this branch
            info "Using existing worktree: $existing_worktree (branch: $merge_branch)"
            worktree_dir="$existing_worktree"
        elif (cd "$ppath" && git show-ref --verify --quiet "refs/heads/$merge_branch" 2>/dev/null); then
            # Branch exists but no worktree - create temp worktree for it
            info "Creating temp worktree for existing branch: $merge_branch"
            mkdir -p "$worktree_dir"
            if ! (cd "$ppath" && git worktree add "$worktree_dir" "$merge_branch" 2>/dev/null); then
                error "Failed to create worktree for $pname"
                fail_count=$((fail_count + 1))
                continue
            fi
            created_worktree=true
        else
            # Branch doesn't exist - create new branch from merge point in temp worktree
            info "Creating branch '$merge_branch' from merge point in temp worktree"
            mkdir -p "$worktree_dir"
            if ! (cd "$ppath" && git worktree add "$worktree_dir" -b "$merge_branch" "$merge_point" 2>/dev/null); then
                error "Failed to create worktree for $pname"
                rm -rf "$worktree_dir"
                fail_count=$((fail_count + 1))
                continue
            fi
            created_worktree=true
        fi

        # Perform the merge in the worktree
        if merge_volume_to_target "$volume" "$pname" "$worktree_dir"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi

        # Clean up temp worktree (branch remains)
        if $created_worktree; then
            info "Cleaning up temp worktree for $pname"
            (cd "$ppath" && git worktree remove "$worktree_dir" 2>/dev/null) || rm -rf "$worktree_dir"
        fi
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
    local volume="claude-session-${name}"

    # Check if session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $name"
        exit 1
    fi

    # Check if this is a multi-project session
    if has_multi_project_config "$volume"; then
        merge_multi_project_session "$name" "$target_dir" "$target_branch" "$auto_mode" "$no_run"
        return $?
    fi

    # Check if target is a git repo
    if ! is_git_repo "$target_dir"; then
        error "Target directory is not a git repository: $target_dir"
        exit 1
    fi

    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Get repo name for merge point tracking
    local repo_name
    repo_name=$(basename "$target_dir")

    # Get merge point (base commit the session was cloned from)
    local merge_point
    merge_point=$(get_merge_point "$volume" "$repo_name")

    info "Merging session '$name' into branch: $target_branch"

    # Use worktree approach to avoid conflicts with uncommitted changes
    local worktree_dir="$CACHE_DIR/worktree-$$-${repo_name}"
    local merge_path=""
    local created_worktree=false

    # Check if branch already has a worktree
    local existing_worktree=""
    existing_worktree=$(cd "$target_dir" && git worktree list --porcelain 2>/dev/null | grep -A2 "^worktree " | grep -B1 "branch refs/heads/$target_branch" | head -1 | sed 's/worktree //' || true)

    if [[ -n "$existing_worktree" && -d "$existing_worktree" ]]; then
        info "Using existing worktree: $existing_worktree"
        merge_path="$existing_worktree"
    elif (cd "$target_dir" && git show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null); then
        # Branch exists but no worktree - create temp worktree
        info "Creating temp worktree for existing branch: $target_branch"
        mkdir -p "$worktree_dir"
        if ! (cd "$target_dir" && git worktree add "$worktree_dir" "$target_branch" 2>/dev/null); then
            error "Failed to create worktree"
            exit 1
        fi
        merge_path="$worktree_dir"
        created_worktree=true
    else
        # Branch doesn't exist - create from merge point (or HEAD if no merge point)
        local base_commit="${merge_point:-HEAD}"
        info "Creating branch '$target_branch' from ${merge_point:+merge point}${merge_point:-HEAD} in temp worktree"
        mkdir -p "$worktree_dir"
        if ! (cd "$target_dir" && git worktree add "$worktree_dir" -b "$target_branch" "$base_commit" 2>/dev/null); then
            error "Failed to create worktree"
            rm -rf "$worktree_dir"
            exit 1
        fi
        merge_path="$worktree_dir"
        created_worktree=true
    fi
    echo ""

    # Show what will be merged (only commits since last merge point)
    echo "=== Commits to merge ==="
    docker run --rm \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c '
            git config --global --add safe.directory "*"
            cd /session
            MERGE_POINT=""
            if [ -f /session/.last-merge-'"$repo_name"' ]; then
                MERGE_POINT=$(cat /session/.last-merge-'"$repo_name"')
            fi
            if [ -n "$MERGE_POINT" ]; then
                COUNT=$(git rev-list --count "$MERGE_POINT"..HEAD 2>/dev/null || echo "0")
                if [ "$COUNT" = "0" ]; then
                    echo "(no new commits since last merge)"
                else
                    git log --oneline "$MERGE_POINT"..HEAD 2>/dev/null
                fi
            else
                # No merge point - show recent commits as warning
                echo "(WARNING: no merge point found, showing last 10 commits)"
                git log --oneline -10
            fi
        '

    echo ""

    if $no_run; then
        info "Dry run - not applying changes"
        return 0
    fi

    if [[ "$auto_mode" == "true" ]]; then
        choice="y"
    else
        read -p "Merge all commits? [y/n/select] " choice
    fi

    case "$choice" in
        y|Y)
            info "Exporting and applying patches..."

            # Create temp directory for patches
            # Use Docker-accessible path (mktemp -d creates /var/folders/... on macOS which Docker can't mount)
            local patch_cache="$CACHE_DIR"
            mkdir -p "$patch_cache"
            local patch_dir="$patch_cache/merge-$$-$(date +%s)"
            mkdir -p "$patch_dir"
            trap "rm -rf $patch_dir" RETURN

            # Export patches from session (only commits since merge point)
            docker run --rm \
                -v "$volume:/session:ro" \
                -v "$patch_dir:/patches" \
                "$git_image" \
                sh -c '
                    git config --global --add safe.directory "*"
                    cd /session
                    MERGE_POINT=""
                    if [ -f /session/.last-merge-'"$repo_name"' ]; then
                        MERGE_POINT=$(cat /session/.last-merge-'"$repo_name"')
                    fi
                    if [ -n "$MERGE_POINT" ]; then
                        git format-patch -o /patches "$MERGE_POINT"..HEAD 2>/dev/null
                    else
                        # Fallback: export all commits (will likely fail on merge)
                        initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                        git format-patch -o /patches "$initial"..HEAD 2>/dev/null
                    fi
                '

            # Apply patches to worktree
            cd "$merge_path"
            local patch_count
            patch_count=$(ls -1 "$patch_dir"/*.patch 2>/dev/null | wc -l | tr -d ' ')

            if [[ "$patch_count" -eq 0 ]]; then
                warn "No patches to apply"
                # Clean up worktree if we created it
                if $created_worktree; then
                    (cd "$target_dir" && git worktree remove "$worktree_dir" 2>/dev/null) || rm -rf "$worktree_dir"
                fi
                return 0
            fi

            local apply_failed=false
            for patch in "$patch_dir"/*.patch; do
                if git am "$patch"; then
                    success "Applied: $(basename "$patch")"
                else
                    error "Failed to apply: $(basename "$patch")"
                    echo "Resolve conflicts in: $merge_path"
                    echo "Then run: git am --continue"
                    echo "Or skip: git am --skip"
                    apply_failed=true
                    break
                fi
            done

            if $apply_failed; then
                # Don't clean up worktree on failure - user needs to resolve
                warn "Worktree preserved for conflict resolution: $merge_path"
                return 1
            fi

            success "Successfully merged $patch_count commit(s) to branch '$target_branch'"

            # Update merge point so next merge only gets new commits
            local host_uid
            host_uid=$(get_host_uid)
            docker run --rm \
                --user "$host_uid:$host_uid" \
                -v "$volume:/session" \
                "$git_image" \
                sh -c "cd /session && git rev-parse HEAD > '/session/.last-merge-${repo_name}'" 2>/dev/null \
                || warn "Could not update merge point"

            # Clean up worktree if we created it
            if $created_worktree; then
                info "Cleaning up temp worktree"
                (cd "$target_dir" && git worktree remove "$worktree_dir" 2>/dev/null) || rm -rf "$worktree_dir"
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
            # Clean up worktree if we created it
            if $created_worktree; then
                (cd "$target_dir" && git worktree remove "$worktree_dir" 2>/dev/null) || rm -rf "$worktree_dir"
            fi
            ;;
        select|s|S)
            warn "Interactive selection not yet implemented"
            echo "Use 'git cherry-pick' manually after inspecting the session"
            # Clean up worktree if we created it
            if $created_worktree; then
                (cd "$target_dir" && git worktree remove "$worktree_dir" 2>/dev/null) || rm -rf "$worktree_dir"
            fi
            ;;
        *)
            echo "Invalid choice"
            # Clean up worktree if we created it
            if $created_worktree; then
                (cd "$target_dir" && git worktree remove "$worktree_dir" 2>/dev/null) || rm -rf "$worktree_dir"
            fi
            ;;
    esac
}
