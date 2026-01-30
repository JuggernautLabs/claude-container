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

    while IFS='|' read -r project_name source_path _branch project_track; do
        # Skip untracked projects
        if [[ "${project_track:-true}" != "true" ]]; then
            echo "Project: $project_name (untracked)"
            echo "  (not tracked for merging)"
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
    local target_branch="${3:-}"
    local auto_mode="${4:-false}"
    local no_run="${5:-false}"
    local volume="claude-session-${name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    info "Merging multi-project session: $name"
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

    # Parse config
    local temp_config="$CACHE_DIR/temp-config-$$.yml"
    mkdir -p "$CACHE_DIR"
    echo "$config_data" > "$temp_config"

    local projects
    projects=$(parse_config_file "$temp_config")
    rm -f "$temp_config"

    # Collect project info into arrays (avoiding docker calls in read loop)
    local -a project_names=()
    local -a project_paths=()
    local -a project_branches=()
    local -a project_track=()

    while IFS='|' read -r pname ppath pbranch ptrack; do
        project_names+=("$pname")
        project_paths+=("$ppath")
        project_branches+=("$pbranch")
        project_track+=("${ptrack:-true}")
    done <<< "$projects"

    # Now get status for each project (docker calls outside the read loop)
    local -a project_commits=()
    local has_changes=false

    echo "Projects to merge:"
    for i in "${!project_names[@]}"; do
        local pname="${project_names[$i]}"
        local ptrack="${project_track[$i]}"

        # Skip untracked projects
        if [[ "$ptrack" != "true" ]]; then
            echo "  [-] $pname (untracked)"
            project_commits+=("0")
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
        local commit_count="${project_commits[$i]}"

        # Skip untracked projects
        if [[ "$ptrack" != "true" ]]; then
            continue
        fi

        if [[ "$commit_count" -eq 0 ]]; then
            continue
        fi

        echo ""

        # Verify source path is a git repo
        if ! is_git_repo "$ppath"; then
            error "Source is not a git repo: $ppath"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Determine merge target path (handle worktrees)
        local merge_branch="${target_branch:-$pbranch}"
        local merge_path="$ppath"

        if [[ -n "$merge_branch" ]]; then
            local worktree_path
            worktree_path=$(find_worktree_for_branch "$ppath" "$merge_branch")

            if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
                info "Using worktree: $worktree_path (branch: $merge_branch)"
                merge_path="$worktree_path"
            else
                cd "$ppath"
                if git show-ref --verify --quiet "refs/heads/$merge_branch"; then
                    info "Switching to branch: $merge_branch"
                    git checkout "$merge_branch"
                else
                    info "Creating branch: $merge_branch"
                    git checkout -b "$merge_branch"
                fi
            fi
        fi

        # Perform the merge
        if merge_volume_to_target "$volume" "$pname" "$merge_path"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
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
    local target_branch="${3:-}"
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

    # Handle target branch
    if [[ -n "$target_branch" ]]; then
        info "Merging session '$name' into branch: $target_branch"
        cd "$target_dir"
        # Create branch if it doesn't exist, or switch to it
        if git show-ref --verify --quiet "refs/heads/$target_branch"; then
            info "Switching to existing branch: $target_branch"
            git checkout "$target_branch"
        else
            info "Creating new branch: $target_branch"
            git checkout -b "$target_branch"
        fi
    else
        info "Merging session '$name' into: $target_dir (current branch)"
    fi
    echo ""

    # Get repo name for merge point tracking
    local repo_name
    repo_name=$(basename "$target_dir")

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

            # Apply patches to target
            cd "$target_dir"
            local patch_count
            patch_count=$(ls -1 "$patch_dir"/*.patch 2>/dev/null | wc -l | tr -d ' ')

            if [[ "$patch_count" -eq 0 ]]; then
                warn "No patches to apply"
                return 0
            fi

            for patch in "$patch_dir"/*.patch; do
                if git am "$patch"; then
                    success "Applied: $(basename "$patch")"
                else
                    error "Failed to apply: $(basename "$patch")"
                    echo "Run 'git am --abort' to cancel or 'git am --skip' to skip this patch"
                    return 1
                fi
            done

            success "Successfully merged $patch_count commit(s)"

            # Update merge point so next merge only gets new commits
            local host_uid
            host_uid=$(get_host_uid)
            docker run --rm \
                --user "$host_uid:$host_uid" \
                -v "$volume:/session" \
                "$git_image" \
                sh -c "cd /session && git rev-parse HEAD > '/session/.last-merge-${repo_name}'" 2>/dev/null \
                || warn "Could not update merge point"

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
            ;;
        select|s|S)
            warn "Interactive selection not yet implemented"
            echo "Use 'git cherry-pick' manually after inspecting the session"
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
}
