#!/usr/bin/env bash
# claude-container template operations - template save/load/derive
# Source this file after utils.sh, platform.sh, and config.sh
#
# Dependencies:
#   - utils.sh must be sourced first (provides: info, success, warn, error, is_git_repo)
#   - config.sh must be sourced first (provides: parse_config_file)
#
# Required globals:
#   - CONFIG_DIR: base config directory
#   - TEMPLATES_DIR: where templates are stored

# Resolve repo path from name or path
# Arguments:
#   $1 - input (name or path)
# Returns:
#   Absolute path (stdout) or error (stderr)
resolve_repo_path() {
    local input="$1"

    # If absolute path, use as-is
    if [[ "$input" = /* ]]; then
        if [[ -d "$input" ]]; then
            echo "$input"
            return 0
        else
            error "Directory not found: $input" >&2
            return 1
        fi
    fi

    # If relative path exists, resolve it
    if [[ -d "$input" ]]; then
        echo "$(cd "$input" && pwd)"
        return 0
    fi

    # Search common locations for repo by name
    for search_dir in "$(pwd)/.." "$HOME/dev" "$HOME/projects" "$HOME/repos" "$HOME/src"; do
        if [[ -d "$search_dir/$input" ]]; then
            echo "$(cd "$search_dir/$input" && pwd)"
            return 0
        fi
    done

    error "Could not find repo: $input" >&2
    return 1
}

# List available templates
# Usage: list_templates
list_templates() {
    local templates_dir="${TEMPLATES_DIR:-$HOME/.config/claude-container/templates}"

    if [[ ! -d "$templates_dir" ]] || [[ -z "$(ls -A "$templates_dir" 2>/dev/null)" ]]; then
        echo "No templates found in $templates_dir"
        return 0
    fi

    echo "Available templates:"
    for f in "$templates_dir"/*.yml; do
        [[ -f "$f" ]] || continue
        local name=$(basename "$f" .yml)
        local parent=""
        local project_count=0

        # Try to extract metadata
        if command -v yq &>/dev/null; then
            parent=$(yq eval '._meta.parent // ""' "$f" 2>/dev/null)
            project_count=$(yq eval '.projects | length' "$f" 2>/dev/null)
        fi

        if [[ -n "$parent" ]]; then
            echo "  $name (derived from: $parent, $project_count projects)"
        else
            echo "  $name ($project_count projects)"
        fi
    done
}

# Save session config as a new base template
# Usage: save_template_from_session <template_name> [session_name]
# Arguments:
#   $1 - template name to save as
#   $2 - session name (optional, uses most recent if not specified)
save_template_from_session() {
    local template_name="$1"
    local session_name="${2:-}"

    if [[ -z "$template_name" ]]; then
        error "Template name required"
        echo "Usage: claude-container --save-template <name> [session]"
        return 1
    fi

    local templates_dir="${TEMPLATES_DIR:-$HOME/.config/claude-container/templates}"
    mkdir -p "$templates_dir"

    local template_file="$templates_dir/${template_name}.yml"

    # Check if template already exists
    if [[ -f "$template_file" ]]; then
        warn "Template already exists: $template_name"
        read -p "Overwrite? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled"
            return 0
        fi
    fi

    # Find session config to copy
    local source_config=""

    if [[ -n "$session_name" ]]; then
        # Try session volume first
        local volume="claude-session-${session_name}"
        if docker volume inspect "$volume" &>/dev/null; then
            # Extract config from volume
            local temp_config="$CACHE_DIR/extract-config-$$.yml"
            if docker run --rm -v "$volume:/session:ro" alpine cat /session/.claude-projects.yml > "$temp_config" 2>/dev/null; then
                source_config="$temp_config"
            fi
        fi

        # Fall back to sessions config dir
        if [[ -z "$source_config" ]] && [[ -f "$SESSIONS_CONFIG_DIR/${session_name}.yml" ]]; then
            source_config="$SESSIONS_CONFIG_DIR/${session_name}.yml"
        fi
    else
        # No session specified - check if we're inside a container
        if [[ -f "/workspace/.claude-projects.yml" ]]; then
            source_config="/workspace/.claude-projects.yml"
        else
            error "No session specified and not inside a container"
            echo "Usage: claude-container --save-template <name> [session]"
            return 1
        fi
    fi

    if [[ -z "$source_config" ]] || [[ ! -f "$source_config" ]]; then
        error "Could not find session config"
        return 1
    fi

    # Copy and update metadata to make it a base template
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if command -v yq &>/dev/null; then
        # Use yq to update metadata
        yq eval "
            ._meta.parent = null |
            ._meta.session = null |
            ._meta.created = \"$timestamp\" |
            ._meta.modified = \"$timestamp\"
        " "$source_config" > "$template_file"
    else
        # Fallback: just copy the file
        cp "$source_config" "$template_file"
        warn "yq not available - template saved without metadata updates"
    fi

    # Clean up temp file if we created one
    [[ "$source_config" == "$CACHE_DIR/extract-config-"* ]] && rm -f "$source_config"

    success "Template saved: $template_name"
    echo "  File: $template_file"
}

# Load template and prepare for session
# Arguments:
#   $1 - template file path
#   $2 - session name
# Returns:
#   Path to prepared config file (stdout)
load_template() {
    local template_file="$1"
    local session_name="$2"

    if [[ ! -f "$template_file" ]]; then
        error "Template file not found: $template_file"
        return 1
    fi

    local template_name=$(basename "$template_file" .yml)
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create a working copy with updated metadata
    local prepared_config="$CACHE_DIR/prepared-config-$$.yml"
    mkdir -p "$CACHE_DIR"

    if command -v yq &>/dev/null; then
        yq eval "
            ._meta.parent = \"$template_name\" |
            ._meta.session = \"$session_name\" |
            ._meta.created = \"$timestamp\" |
            ._meta.modified = \"$timestamp\"
        " "$template_file" > "$prepared_config"
    else
        # Fallback: copy and add metadata manually
        cp "$template_file" "$prepared_config"
    fi

    echo "$prepared_config"
}

# Derive template name from parent and session
# Arguments:
#   $1 - parent template name
#   $2 - session name
# Returns:
#   Derived template name (stdout)
derive_template_name() {
    local parent="$1"
    local session="$2"

    if [[ -z "$parent" ]]; then
        echo "$session"
    else
        echo "${parent}-${session}"
    fi
}

# Save derived template on session exit
# Only saves if config was modified from parent template
# Arguments:
#   $1 - session name
#   $2 - volume name
save_derived_template() {
    local session_name="$1"
    local volume="$2"

    local templates_dir="${TEMPLATES_DIR:-$HOME/.config/claude-container/templates}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Extract current config from volume
    local current_config="$CACHE_DIR/current-config-$$.yml"
    mkdir -p "$CACHE_DIR"

    if ! docker run --rm -v "$volume:/session:ro" "$git_image" \
        cat /session/.claude-projects.yml > "$current_config" 2>/dev/null; then
        # No config in session, nothing to save
        rm -f "$current_config"
        return 0
    fi

    # Get parent template name from config
    local parent_name=""
    if command -v yq &>/dev/null; then
        parent_name=$(yq eval '._meta.parent // ""' "$current_config" 2>/dev/null)
    fi

    # If there's a parent, compare to see if changed
    if [[ -n "$parent_name" ]]; then
        local parent_file="$templates_dir/${parent_name}.yml"
        if [[ -f "$parent_file" ]]; then
            # Compare projects sections (ignore metadata)
            local current_projects parent_projects
            if command -v yq &>/dev/null; then
                current_projects=$(yq eval '.projects' "$current_config" 2>/dev/null)
                parent_projects=$(yq eval '.projects' "$parent_file" 2>/dev/null)

                if [[ "$current_projects" == "$parent_projects" ]]; then
                    # No changes, don't save derived template
                    rm -f "$current_config"
                    return 0
                fi
            fi
        fi
    fi

    # Generate derived template name
    local derived_name=$(derive_template_name "$parent_name" "$session_name")
    local derived_file="$templates_dir/${derived_name}.yml"

    # Don't overwrite if exists (could be from a previous run)
    if [[ -f "$derived_file" ]]; then
        info "Derived template already exists: $derived_name"
        rm -f "$current_config"
        return 0
    fi

    # Save derived template
    cp "$current_config" "$derived_file"
    rm -f "$current_config"

    success "Derived template saved: $derived_name"
    echo "  Parent: ${parent_name:-none}"
    echo "  File: $derived_file"
}

# Build project list from multiple sources
# Order of precedence:
#   1. Template (if -t specified)
#   2. --add-repo flags
#   3. --discover-repos directories
#   4. Current directory (unless --empty)
# Returns:
#   Projects in format: "name|path|branch|track|source" per line (stdout)
#   Info/status messages go to stderr
build_project_list() {
    local session_name="$1"
    local workspace_dir="$2"
    local projects=""
    local seen_names=""

    # 1. Start with template if specified
    if [[ -n "${TEMPLATE_FILE:-}" ]] && [[ -f "$TEMPLATE_FILE" ]]; then
        info "Loading template: $(basename "$TEMPLATE_FILE" .yml)" >&2
        projects=$(parse_config_file "$TEMPLATE_FILE")
        # Track seen names
        while IFS='|' read -r name _rest; do
            [[ -n "$name" ]] && seen_names+="$name "
        done <<< "$projects"
    fi

    # 2. Add repos from --add-repo flags
    for repo in "${ADD_REPOS[@]}"; do
        local repo_path
        if ! repo_path=$(resolve_repo_path "$repo"); then
            continue
        fi

        local repo_name=$(basename "$repo_path")

        # Skip if already in list
        if [[ "$seen_names" == *"$repo_name "* ]]; then
            warn "Skipping duplicate: $repo_name" >&2
            continue
        fi

        # Determine track status
        local track="true"
        if $UNTRACKED_MODE; then
            track="false"
            # Check if explicitly tracked
            for t in "${TRACK_REPOS[@]}"; do
                if [[ "$t" == "$repo_name" ]] || [[ "$t" == "$repo_path" ]]; then
                    track="true"
                    break
                fi
            done
        fi

        projects+=$'\n'"$repo_name|$repo_path||$track|"
        seen_names+="$repo_name "
        info "  Adding: $repo_name ($repo_path)" >&2
    done

    # 3. Discover repos if specified (already handled by DISCOVER_REPOS_DIRS earlier)
    # This is handled before build_project_list is called

    # 4. Add current directory (unless --empty or already have projects)
    if ! $EMPTY_MODE && [[ -z "$TEMPLATE_FILE" ]] && [[ ${#ADD_REPOS[@]} -eq 0 ]] && [[ ${#DISCOVER_REPOS_DIRS[@]} -eq 0 ]]; then
        # Only add cwd if no other project sources specified
        if is_git_repo "$workspace_dir"; then
            local cwd_name=$(basename "$workspace_dir")
            if [[ "$seen_names" != *"$cwd_name "* ]]; then
                local track="true"
                $UNTRACKED_MODE && track="false"
                projects+=$'\n'"$cwd_name|$workspace_dir||$track|main"
            fi
        fi
    fi

    echo "$projects"
}

# Generate config file from project list
# Arguments:
#   $1 - output file path
#   $2 - projects (newline-delimited: name|path|branch|track|source)
#   $3 - parent template name (optional)
#   $4 - session name
generate_config_file() {
    local output_file="$1"
    local projects="$2"
    local parent_name="${3:-}"
    local session_name="$4"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    {
        echo 'version: "1"'
        echo ''
        echo '# Template metadata - managed by claude-container'
        echo '_meta:'
        if [[ -n "$parent_name" ]]; then
            echo "  parent: $parent_name"
        else
            echo '  parent: null'
        fi
        echo "  session: $session_name"
        echo "  created: $timestamp"
        echo "  modified: $timestamp"
        echo ''
        echo '# Project definitions - AGENT CAN MODIFY THIS SECTION'
        echo 'projects:'

        local first=true
        while IFS='|' read -r proj_name proj_path proj_branch proj_track proj_source; do
            [[ -z "$proj_name" ]] && continue

            echo "  $proj_name:"
            echo "    path: $proj_path"

            # Add main marker if this is the main project
            if [[ "$proj_source" == "main" ]]; then
                echo "    main: true"
            fi

            # Add track if not default (true)
            if [[ "$proj_track" == "false" ]]; then
                echo "    track: false"
            fi

            # Add branch if specified
            if [[ -n "$proj_branch" ]]; then
                echo "    branch: $proj_branch"
            fi

            # Add source if discovered
            if [[ "$proj_source" == "discovered" ]]; then
                echo "    source: discovered"
            fi
        done <<< "$projects"
    } > "$output_file"
}
