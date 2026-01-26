#!/usr/bin/env bash
# claude-container git-ops module - Git session diff and merge operations
# Source this file after utils.sh and config.sh
#
# Dependencies:
#   - utils.sh must be sourced first (provides: info, success, warn, error)
#   - config.sh must be sourced first (provides: parse_config_file)
#
# Required globals:
#   - CACHE_DIR: directory for caching temporary files
#   - IMAGE_NAME or DEFAULT_IMAGE: Docker image for git operations

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
        "$git_image" \
        cat /session/.claude-projects.yml 2>/dev/null) || {
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
        while IFS='|' read -r project_name source_path; do
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
            while IFS='|' read -r project_name source_path; do
                echo "  - $project_name"
            done <<< "$projects"
            exit 1
        fi
        return 0
    fi

    # No filter - show summary of all projects
    info "Multi-project session: $name"
    echo ""

    while IFS='|' read -r project_name source_path; do
        # Count commits in this project
        local commit_count
        commit_count=$(docker run --rm \
            -v "$volume:/session:ro" \
            "$git_image" \
            sh -c "
                git config --global --add safe.directory '*'
                cd /session/$project_name 2>/dev/null || exit 0
                initial=\$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                git rev-list --count \"\$initial\"..HEAD 2>/dev/null || echo 0
            ") || echo "0"

        echo "Project: $project_name ($commit_count commits)"

        if [[ "$commit_count" -gt 0 ]]; then
            # Show commit messages
            docker run --rm \
                -v "$volume:/session:ro" \
                "$git_image" \
                sh -c "
                    git config --global --add safe.directory '*'
                    cd /session/$project_name
                    initial=\$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                    git log --oneline \"\$initial\"..HEAD 2>/dev/null | sed 's/^/  /'
                "
        else
            echo "  (no changes)"
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
    local volume="claude-session-${name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    info "Merging multi-project session: $name"
    echo ""

    # Extract config from volume
    local config_data
    config_data=$(docker run --rm \
        -v "$volume:/session:ro" \
        "$git_image" \
        cat /session/.claude-projects.yml 2>/dev/null) || {
        error "Failed to read config from session volume"
        exit 1
    }

    # Parse config
    local temp_config="$CACHE_DIR/temp-config-$$.yml"
    mkdir -p "$CACHE_DIR"
    echo "$config_data" > "$temp_config"
    trap "rm -f '$temp_config'" RETURN

    local projects
    projects=$(parse_config_file "$temp_config")

    # Analyze each project to see which have commits
    declare -A project_commits
    declare -A project_paths
    local has_changes=false

    echo "Projects to merge:"
    while IFS='|' read -r project_name source_path; do
        project_paths[$project_name]="$source_path"

        # Count commits
        local commit_count
        commit_count=$(docker run --rm \
            -v "$volume:/session:ro" \
            "$git_image" \
            sh -c "
                git config --global --add safe.directory '*'
                cd /session/$project_name 2>/dev/null || exit 0
                initial=\$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                git rev-list --count \"\$initial\"..HEAD 2>/dev/null || echo 0
            ") || echo "0"

        project_commits[$project_name]=$commit_count

        if [[ "$commit_count" -gt 0 ]]; then
            echo "  [x] $project_name ($commit_count commits)"
            has_changes=true
        else
            echo "  [ ] $project_name (0 commits - skipped)"
        fi
    done <<< "$projects"

    if ! $has_changes; then
        warn "No changes to merge in any project"
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

    # Prepare patch directory
    local patch_cache="$CACHE_DIR"
    mkdir -p "$patch_cache"
    local patch_dir="$patch_cache/merge-multi-$$-$(date +%s)"
    mkdir -p "$patch_dir"
    trap "rm -rf $patch_dir $temp_config" RETURN

    # Merge each project with commits
    local success_count=0
    local fail_count=0

    for project_name in "${!project_commits[@]}"; do
        local commit_count="${project_commits[$project_name]}"
        if [[ "$commit_count" -eq 0 ]]; then
            continue
        fi

        local source_path="${project_paths[$project_name]}"
        echo ""
        info "Merging project: $project_name"

        # Verify source path is a git repo
        if [[ ! -d "$source_path/.git" ]]; then
            error "  Source is not a git repo: $source_path"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Handle branch switching if specified
        if [[ -n "$target_branch" ]]; then
            cd "$source_path"
            if git show-ref --verify --quiet "refs/heads/$target_branch"; then
                info "  Switching to existing branch: $target_branch"
                git checkout "$target_branch"
            else
                info "  Creating new branch: $target_branch"
                git checkout -b "$target_branch"
            fi
        fi

        # Create project-specific patch directory
        local project_patch_dir="$patch_dir/$project_name"
        mkdir -p "$project_patch_dir"

        # Export patches from session
        docker run --rm \
            -v "$volume:/session:ro" \
            -v "$project_patch_dir:/patches" \
            "$git_image" \
            sh -c "
                git config --global --add safe.directory '*'
                cd /session/$project_name
                initial=\$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                git format-patch -o /patches \"\$initial\"..HEAD 2>/dev/null || \
                    git format-patch -o /patches -10
            "

        # Apply patches
        cd "$source_path"
        local patch_count
        patch_count=$(ls -1 "$project_patch_dir"/*.patch 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$patch_count" -eq 0 ]]; then
            warn "  No patches to apply for $project_name"
            continue
        fi

        local project_success=true
        for patch in "$project_patch_dir"/*.patch; do
            if git am "$patch"; then
                success "  Applied: $(basename "$patch")"
            else
                error "  Failed to apply: $(basename "$patch")"
                echo "  Run 'git am --abort' to cancel in: $source_path"
                project_success=false
                break
            fi
        done

        if $project_success; then
            success "  Merged $patch_count commit(s) to $project_name"
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
    local volume="claude-session-${name}"

    # Check if session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $name"
        exit 1
    fi

    # Check if this is a multi-project session
    if has_multi_project_config "$volume"; then
        merge_multi_project_session "$name" "$target_dir" "$target_branch" "$auto_mode"
        return $?
    fi

    # Check if target is a git repo
    if [[ ! -d "$target_dir/.git" ]]; then
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

    # Show what will be merged
    echo "=== Commits to merge ==="
    docker run --rm \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c '
            git config --global --add safe.directory "*"
            cd /session
            initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
            git log --oneline "$initial"..HEAD 2>/dev/null || git log --oneline -10
        '

    echo ""

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

            # Export patches from session
            docker run --rm \
                -v "$volume:/session:ro" \
                -v "$patch_dir:/patches" \
                "$git_image" \
                sh -c '
                    git config --global --add safe.directory "*"
                    cd /session
                    initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                    git format-patch -o /patches "$initial"..HEAD 2>/dev/null || \
                        git format-patch -o /patches -10
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
