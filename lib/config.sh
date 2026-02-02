#!/usr/bin/env bash
# claude-container config module - YAML parsing and multi-project configuration
# Source this file after utils.sh and platform.sh
#
# Dependencies:
#   - utils.sh must be sourced first (provides: info, success, warn, error)
#   - platform.sh must be sourced first (provides: PLATFORM)
#
# Required globals:
#   - CACHE_DIR: directory for caching temporary files
#   - PLATFORM: detected platform (macos, linux, wsl, windows)
#
# Optional globals:
#   - CONFIG_FILE: path to config file (set via --config flag)

# Check if YAML parser is available (yq or python3 with yaml)
check_yaml_parser_available() {
    if command -v yq &>/dev/null; then
        return 0
    elif command -v python3 &>/dev/null && python3 -c "import yaml" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Show helpful message for installing YAML parser
show_yaml_parser_install_help() {
    error "No YAML parser found. Multi-project sessions require 'yq' or 'python3' with PyYAML."
    echo ""
    echo "Installation options:"
    echo ""
    echo "Option 1: Install yq (recommended)"
    case "$PLATFORM" in
        macos)
            echo "  brew install yq"
            ;;
        linux|wsl)
            echo "  # Ubuntu/Debian:"
            echo "  sudo apt-get install yq"
            echo ""
            echo "  # Or using snap:"
            echo "  sudo snap install yq"
            ;;
        *)
            echo "  See: https://github.com/mikefarah/yq#install"
            ;;
    esac
    echo ""
    echo "Option 2: Install Python PyYAML"
    echo "  pip3 install pyyaml"
    echo "  # or: python3 -m pip install pyyaml"
    echo ""
}

# Get human-readable size of a directory
# Arguments:
#   $1 - directory path
# Returns:
#   Size string (e.g., "4.5M", "1.2G")
get_dir_size() {
    du -sh "$1" 2>/dev/null | cut -f1
}

# Convert size string to bytes for comparison
# Arguments:
#   $1 - size string (e.g., "4.5M", "1.2G")
# Returns:
#   Size in bytes (approximate)
size_to_bytes() {
    local size="$1"
    local num="${size%[KMGTP]*}"
    local unit="${size##*[0-9.]}"

    # Remove any trailing 'B' or 'i' (e.g., "MiB" -> "M")
    unit="${unit%%[Bi]*}"

    # Compute and truncate to integer (bash doesn't handle decimals)
    local result
    case "$unit" in
        K) result=$(echo "$num * 1024" | bc 2>/dev/null) ;;
        M) result=$(echo "$num * 1024 * 1024" | bc 2>/dev/null) ;;
        G) result=$(echo "$num * 1024 * 1024 * 1024" | bc 2>/dev/null) ;;
        T) result=$(echo "$num * 1024 * 1024 * 1024 * 1024" | bc 2>/dev/null) ;;
        *) result="${num%.*}" ;;  # Assume bytes
    esac
    # Truncate decimal portion for bash arithmetic
    echo "${result%.*}"
}

# Size threshold for warnings (10MB in bytes)
SIZE_WARN_THRESHOLD=$((10 * 1024 * 1024))

# Discover all git repositories in multiple directories
# Uses each directory's basename as prefix for its repos
# Arguments:
#   $@ - directories to scan for git repos
# Returns:
#   Path to temporary config file (stdout)
#   Projects output format: prefix/repo_name|absolute_source_path
discover_repos_multi() {
    local search_dirs=("$@")
    local temp_config="$CACHE_DIR/discovered-config-$$.yml"

    mkdir -p "$CACHE_DIR"

    local found_count=0
    local projects=""
    local large_repos=()

    for search_dir in "${search_dirs[@]}"; do
        # Use basename of search dir as prefix
        local prefix
        prefix=$(basename "$(cd "$search_dir" && pwd)")

        info "Discovering in: $search_dir → $prefix/" >&2

        for dir in "$search_dir"/*/; do
            if is_git_repo "$dir"; then
                # Skip worktrees by default (only add them explicitly via --add-repo)
                if is_git_worktree "$dir"; then
                    info "  ⊘ $(basename "$dir") (worktree, skipped)" >&2
                    continue
                fi

                local repo_name
                repo_name=$(basename "$dir")
                local abs_repo_path
                abs_repo_path=$(cd "$dir" && pwd)

                # Workspace path: prefix/repo_name
                local workspace_path="$prefix/$repo_name"

                # Check .git size
                local git_size
                git_size=$(get_dir_size "$dir/.git")
                local git_bytes
                git_bytes=$(size_to_bytes "$git_size")

                if [[ "$git_bytes" -gt "$SIZE_WARN_THRESHOLD" ]]; then
                    warn "  ⚠ $workspace_path (.git: $git_size)" >&2
                    large_repos+=("$workspace_path: .git=$git_size")
                else
                    info "  ✓ $workspace_path ($git_size)" >&2
                fi

                projects+="$workspace_path|$abs_repo_path"$'\n'
                found_count=$((found_count + 1))
            fi
        done
    done

    if [[ $found_count -eq 0 ]]; then
        error "No git repositories found" >&2
        exit 1
    fi

    # Warn about large repos
    if [[ ${#large_repos[@]} -gt 0 ]]; then
        echo "" >&2
        warn "Found ${#large_repos[@]} repo(s) with .git > 10MB (may slow cloning):" >&2
        for repo in "${large_repos[@]}"; do
            warn "  $repo" >&2
        done
        warn "Consider: git filter-repo --path target/ --invert-paths --force" >&2
        echo "" >&2
    fi

    success "Discovered $found_count repositories" >&2

    # Generate temporary config file
    cat > "$temp_config" << 'EOF'
version: "1"
projects:
EOF

    while IFS='|' read -r rel_path abs_path; do
        [[ -z "$rel_path" ]] && continue
        echo "  \"$rel_path\":" >> "$temp_config"
        echo "    path: $abs_path" >> "$temp_config"
    done <<< "$projects"

    echo "$temp_config"
}

# Discover all git repositories in a directory and generate config
# (Legacy single-directory version, calls discover_repos_multi)
# Arguments:
#   $1 - search directory to scan for git repos
# Returns:
#   Path to temporary config file (stdout)
discover_repos_in_dir() {
    discover_repos_multi "$1"
}

# Find .claude-projects.yml config file
# Search order: --config flag > ./.claude-projects.yml > ./.devcontainer/claude-projects.yml
# Arguments:
#   $1 - search directory (optional, defaults to current directory)
# Returns:
#   Path to config file (stdout) or exits with error
find_config_file() {
    local search_dir="${1:-.}"
    local config_file=""

    # If CONFIG_FILE is set via --config flag, use it directly
    if [[ -n "${CONFIG_FILE:-}" ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            echo "$CONFIG_FILE"
            return 0
        else
            error "Config file not found: $CONFIG_FILE"
            exit 1
        fi
    fi

    # Search in standard locations
    for candidate in \
        "$search_dir/.claude-projects.yml" \
        "$search_dir/.devcontainer/claude-projects.yml" \
        "$search_dir/claude-projects.yml"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    # Not found - return empty (will fall back to single-repo mode)
    return 1
}

# Parse YAML config file and extract project mappings
# Returns newline-delimited format: "project_name|absolute_path|branch|track|source"
# Arguments:
#   $1 - path to config file
# Returns:
#   Project mappings (stdout), one per line: "name|path|branch|track|source"
#   (branch may be empty, track is "true" or "false", source is "" or "discovered")
parse_config_file() {
    local config_file="$1"
    local config_dir
    config_dir="$(cd "$(dirname "$config_file")" && pwd)"

    # Try yq first (most robust), fall back to Python
    if command -v yq &>/dev/null; then
        # Parse with yq: extract project names, paths, optional branch, track flag, and source
        local yq_output
        yq_output=$(yq eval '.projects | to_entries | .[] | .key + "|" + .value.path + "|" + (.value.branch // "") + "|" + ((.value.track // true) | tostring) + "|" + (.value.source // "")' "$config_file" 2>/dev/null) || {
            error "Failed to parse config file with yq"
            exit 1
        }

        # Resolve relative paths to absolute (but not for discovered repos - they specify destination)
        while IFS='|' read -r proj_name proj_path proj_branch proj_track proj_source; do
            # For discovered repos, path is the destination - don't resolve it
            if [[ "$proj_source" != "discovered" && "$proj_path" != /* ]]; then
                proj_path="$(cd "$config_dir" && cd "$proj_path" && pwd)"
            fi
            echo "$proj_name|$proj_path|$proj_branch|$proj_track|$proj_source"
        done <<< "$yq_output"
    elif command -v python3 &>/dev/null; then
        # Fallback to Python
        python3 -c "
import sys, yaml, os

try:
    with open('$config_file', 'r') as f:
        config = yaml.safe_load(f)

    if not config or 'projects' not in config:
        print('Error: Config must have \"projects\" key', file=sys.stderr)
        sys.exit(1)

    for name, info in config['projects'].items():
        if not isinstance(info, dict) or 'path' not in info:
            print(f'Error: Project \"{name}\" missing \"path\" field', file=sys.stderr)
            sys.exit(1)

        path = info['path']
        branch = info.get('branch', '')
        track = str(info.get('track', True)).lower()
        source = info.get('source', '')
        # Resolve relative paths (but not for discovered repos - they specify destination)
        if source != 'discovered' and not os.path.isabs(path):
            path = os.path.abspath(os.path.join('$config_dir', path))

        print(f'{name}|{path}|{branch}|{track}|{source}')
except yaml.YAMLError as e:
    print(f'Error: Invalid YAML: {e}', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" || {
            error "Failed to parse config file with Python"
            exit 1
        }
    else
        show_yaml_parser_install_help
        exit 1
    fi
}

# Validate config file and all project paths
# Arguments:
#   $1 - path to config file
# Returns:
#   Success message or exits with error
validate_config() {
    local config_file="$1"
    local projects

    # Check for YAML parser before proceeding
    if ! check_yaml_parser_available; then
        show_yaml_parser_install_help
        exit 1
    fi

    info "Validating multi-project config..."

    # Parse projects
    if ! projects=$(parse_config_file "$config_file"); then
        error "Failed to parse config file"
        exit 1
    fi

    if [[ -z "$projects" ]]; then
        error "No projects defined in config file"
        exit 1
    fi

    # Track project names to check for duplicates
    declare -A seen_names

    # Validate each project
    while IFS='|' read -r proj_name proj_path _branch _track; do
        # Check for duplicate names
        if [[ -n "${seen_names[$proj_name]:-}" ]]; then
            error "Duplicate project name: $proj_name"
            exit 1
        fi
        seen_names[$proj_name]=1

        # Check for reserved names
        case "$proj_name" in
            .git|.claude|.devcontainer|workspace|session)
                error "Reserved project name: $proj_name"
                exit 1
                ;;
        esac

        # Validate path exists
        if [[ ! -d "$proj_path" ]]; then
            error "Project '$proj_name': path does not exist: $proj_path"
            exit 1
        fi

        # Validate it's a git repo
        if ! is_git_repo "$proj_path"; then
            error "Project '$proj_name': not a git repository: $proj_path"
            exit 1
        fi

        info "  Validated: $proj_name: $proj_path"
    done <<< "$projects"

    success "Config validation passed"
}

# Get the main project name from config
# Returns the project marked with "main: true", or the first project if none marked
# Arguments:
#   $1 - path to config file
# Returns:
#   Project name (stdout)
get_main_project() {
    local config_file="$1"

    if command -v yq &>/dev/null; then
        # Try to find project with main: true
        local main_proj
        main_proj=$(yq eval '.projects | to_entries | .[] | select(.value.main == true) | .key' "$config_file" 2>/dev/null | head -1)

        if [[ -n "$main_proj" ]]; then
            echo "$main_proj"
        else
            # Fall back to first project
            yq eval '.projects | keys | .[0]' "$config_file" 2>/dev/null
        fi
    elif command -v python3 &>/dev/null; then
        python3 -c "
import yaml
with open('$config_file', 'r') as f:
    config = yaml.safe_load(f)
projects = config.get('projects', {})
# Find main project
for name, info in projects.items():
    if isinstance(info, dict) and info.get('main'):
        print(name)
        exit(0)
# Fall back to first project
if projects:
    print(list(projects.keys())[0])
" 2>/dev/null
    fi
}

# ============================================================================
# Project Iteration Utilities
# ============================================================================
# These functions consolidate the 7+ project parsing loops across the codebase
# that parse the pipe-delimited format: name|path|branch|track|source
#
# Project format specification:
#   name|path|branch|track|source
#   - name:   project name (required)
#   - path:   absolute path to project (required)
#   - branch: git branch name (optional, may be empty)
#   - track:  "true" or "false" for merge tracking (defaults to "true")
#   - source: "" or "discovered" for discovery source (optional)
# ============================================================================

# Iterate over projects with callback function
#
# Provides a clean abstraction for processing each project in a project list.
# The callback function receives parsed project fields as positional parameters
# plus any additional arguments passed to for_each_project.
#
# Arguments:
#   $1 - projects string (pipe-delimited: name|path|branch|track|source)
#   $2 - callback function name
#   $@ - additional args passed to callback
#
# Callback signature:
#   callback_function proj_name proj_path proj_branch proj_track proj_source [additional_args...]
#
# Returns:
#   Exit code of last callback invocation
#
# Example usage:
#   # Define callback function
#   my_callback() {
#       local name=$1 path=$2 branch=$3 track=$4 source=$5
#       echo "Processing: $name at $path"
#   }
#
#   # Iterate over projects
#   for_each_project "$projects" my_callback
#
#   # With additional arguments
#   process_with_flag() {
#       local name=$1 path=$2 branch=$3 track=$4 source=$5
#       local flag=$6
#       echo "$name: $flag"
#   }
#   for_each_project "$projects" process_with_flag "--verbose"
for_each_project() {
    local projects="$1"
    local callback="$2"
    shift 2
    local callback_args=("$@")

    # Handle empty project list gracefully
    [[ -z "$projects" ]] && return 0

    while IFS='|' read -r pname ppath pbranch ptrack psource; do
        [[ -z "$pname" ]] && continue
        "$callback" "$pname" "$ppath" "$pbranch" "$ptrack" "$psource" "${callback_args[@]}"
    done <<< "$projects"
}

# Find a project by name in project list
#
# Searches through the project list and returns the full project line
# (pipe-delimited) for the matching project name.
#
# Arguments:
#   $1 - projects string (pipe-delimited: name|path|branch|track|source)
#   $2 - target project name
#
# Returns:
#   0 and outputs project line (name|path|branch|track|source) if found
#   1 if not found
#
# Example usage:
#   if project_line=$(find_project "$projects" "my-app"); then
#       echo "Found: $project_line"
#       # Parse the fields
#       IFS='|' read -r name path branch track source <<< "$project_line"
#       echo "Path: $path"
#   else
#       echo "Project not found"
#   fi
find_project() {
    local projects="$1"
    local target_name="$2"

    # Handle empty project list gracefully
    [[ -z "$projects" ]] && return 1

    while IFS='|' read -r pname ppath pbranch ptrack psource; do
        if [[ "$pname" == "$target_name" ]]; then
            echo "$pname|$ppath|$pbranch|$ptrack|$psource"
            return 0
        fi
    done <<< "$projects"

    return 1
}

# Check if a project is tracked for merging
#
# Projects can be marked as untracked (track: false) to exclude them from
# merge operations. This function checks the track flag, defaulting to true
# if the flag is empty or unset.
#
# Arguments:
#   $1 - track flag ("true", "false", or empty defaults to "true")
#
# Returns:
#   0 if tracked (track is "true" or empty)
#   1 if not tracked (track is "false")
#
# Example usage:
#   if is_project_tracked "$track_flag"; then
#       echo "Project will be merged"
#   else
#       echo "Project is untracked, skipping merge"
#   fi
#
#   # In a loop
#   while IFS='|' read -r name path branch track source; do
#       is_project_tracked "$track" || continue
#       echo "Processing tracked project: $name"
#   done <<< "$projects"
is_project_tracked() {
    local track_flag="$1"
    [[ "${track_flag:-true}" == "true" ]]
}

# Filter projects to only tracked ones
#
# Returns a new project list containing only projects where track != "false".
# Preserves the original pipe-delimited format for each project.
#
# Arguments:
#   $1 - projects string (pipe-delimited: name|path|branch|track|source)
#
# Returns:
#   Filtered project list (stdout), one per line
#
# Example usage:
#   # Get only tracked projects
#   tracked_projects=$(filter_tracked_projects "$all_projects")
#
#   # Count tracked projects
#   tracked_count=$(filter_tracked_projects "$projects" | wc -l)
#
#   # Chain with other operations
#   filter_tracked_projects "$projects" | while IFS='|' read -r name path _; do
#       echo "Tracked: $name"
#   done
#
#   # Composable with for_each_project
#   tracked=$(filter_tracked_projects "$projects")
#   for_each_project "$tracked" process_callback
filter_tracked_projects() {
    local projects="$1"

    # Handle empty project list gracefully
    [[ -z "$projects" ]] && return 0

    while IFS='|' read -r pname ppath pbranch ptrack psource; do
        [[ -z "$pname" ]] && continue
        is_project_tracked "$ptrack" && echo "$pname|$ppath|$pbranch|$ptrack|$psource"
    done <<< "$projects"
}
