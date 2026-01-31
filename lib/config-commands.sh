#!/usr/bin/env bash
# claude-container config commands - modify session config from inside container
# Source this file after utils.sh and config.sh
#
# These commands are designed to be run from inside the container
# to modify /workspace/.claude-projects.yml
#
# Dependencies:
#   - utils.sh must be sourced first (provides: info, success, warn, error)

# Config file location (can be overridden by CLAUDE_SESSION_CONFIG env var)
get_config_file() {
    echo "${CLAUDE_SESSION_CONFIG:-/workspace/.claude-projects.yml}"
}

# Check if running inside container
is_inside_container() {
    [[ -f "/.dockerenv" ]] || [[ -f "/run/.containerenv" ]]
}

# Show current config
config_show() {
    local config_file=$(get_config_file)

    if [[ ! -f "$config_file" ]]; then
        error "Config file not found: $config_file"
        return 1
    fi

    echo "=== Session Config ==="
    echo "File: $config_file"
    echo ""

    if command -v yq &>/dev/null; then
        # Pretty print with yq
        echo "Metadata:"
        yq eval '._meta' "$config_file" 2>/dev/null | sed 's/^/  /'
        echo ""
        echo "Projects:"
        yq eval '.projects | to_entries | .[] | "  " + .key + ": track=" + ((.value.track // true) | tostring) + (if .value.main then " (main)" else "" end)' "$config_file" 2>/dev/null
    else
        # Fallback: just cat the file
        cat "$config_file"
    fi
}

# Set track status for a repo
# Arguments:
#   $1 - repo name
#   $2 - track value (true/false)
config_set_track() {
    local repo_name="$1"
    local track_value="$2"
    local config_file=$(get_config_file)

    if [[ ! -f "$config_file" ]]; then
        error "Config file not found: $config_file"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for config modification"
        echo "Install with: apt-get install yq"
        return 1
    fi

    # Check if project exists
    local exists
    exists=$(yq eval ".projects.\"$repo_name\" // \"\"" "$config_file" 2>/dev/null)
    if [[ -z "$exists" ]] || [[ "$exists" == "null" ]]; then
        error "Project not found: $repo_name"
        echo "Available projects:"
        yq eval '.projects | keys | .[]' "$config_file" 2>/dev/null | sed 's/^/  /'
        return 1
    fi

    # Update track value and modified timestamp
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    yq eval -i "
        .projects.\"$repo_name\".track = $track_value |
        ._meta.modified = \"$timestamp\"
    " "$config_file"

    success "Set $repo_name track=$track_value"
}

# Enable tracking for a repo
config_track() {
    local repo_name="$1"
    if [[ -z "$repo_name" ]]; then
        error "Usage: claude-container config track <repo>"
        return 1
    fi
    config_set_track "$repo_name" "true"
}

# Disable tracking for a repo
config_untrack() {
    local repo_name="$1"
    if [[ -z "$repo_name" ]]; then
        error "Usage: claude-container config untrack <repo>"
        return 1
    fi
    config_set_track "$repo_name" "false"
}

# Set main project
config_set_main() {
    local repo_name="$1"
    local config_file=$(get_config_file)

    if [[ -z "$repo_name" ]]; then
        error "Usage: claude-container config set-main <repo>"
        return 1
    fi

    if [[ ! -f "$config_file" ]]; then
        error "Config file not found: $config_file"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for config modification"
        return 1
    fi

    # Check if project exists
    local exists
    exists=$(yq eval ".projects.\"$repo_name\" // \"\"" "$config_file" 2>/dev/null)
    if [[ -z "$exists" ]] || [[ "$exists" == "null" ]]; then
        error "Project not found: $repo_name"
        return 1
    fi

    # Remove main from all projects, set on target
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    yq eval -i "
        .projects[].main = false |
        .projects.\"$repo_name\".main = true |
        ._meta.modified = \"$timestamp\"
    " "$config_file"

    # Also update .main-project file
    echo "$repo_name" > /workspace/.main-project

    success "Set main project: $repo_name"
}

# Add a discovered repo to config
config_add_repo() {
    local dest_path="$1"
    local repo_name="${2:-}"
    local config_file=$(get_config_file)

    if [[ -z "$dest_path" ]]; then
        error "Usage: claude-container config add-repo <dest-path> [name]"
        return 1
    fi

    if [[ ! -f "$config_file" ]]; then
        error "Config file not found: $config_file"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for config modification"
        return 1
    fi

    # Default name to basename of dest path
    if [[ -z "$repo_name" ]]; then
        repo_name=$(basename "$dest_path")
    fi

    # Check if project already exists
    local exists
    exists=$(yq eval ".projects.\"$repo_name\" // \"\"" "$config_file" 2>/dev/null)
    if [[ -n "$exists" ]] && [[ "$exists" != "null" ]]; then
        error "Project already exists: $repo_name"
        return 1
    fi

    # Add the project
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    yq eval -i "
        .projects.\"$repo_name\".path = \"$dest_path\" |
        .projects.\"$repo_name\".source = \"discovered\" |
        .projects.\"$repo_name\".track = true |
        ._meta.modified = \"$timestamp\"
    " "$config_file"

    success "Added discovered repo: $repo_name -> $dest_path"
}

# Remove a repo from config
config_remove_repo() {
    local repo_name="$1"
    local config_file=$(get_config_file)

    if [[ -z "$repo_name" ]]; then
        error "Usage: claude-container config remove-repo <name>"
        return 1
    fi

    if [[ ! -f "$config_file" ]]; then
        error "Config file not found: $config_file"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for config modification"
        return 1
    fi

    # Check if project exists
    local exists
    exists=$(yq eval ".projects.\"$repo_name\" // \"\"" "$config_file" 2>/dev/null)
    if [[ -z "$exists" ]] || [[ "$exists" == "null" ]]; then
        error "Project not found: $repo_name"
        return 1
    fi

    # Remove the project
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    yq eval -i "
        del(.projects.\"$repo_name\") |
        ._meta.modified = \"$timestamp\"
    " "$config_file"

    success "Removed repo: $repo_name"
}

# Handle config subcommand
handle_config_command() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$subcmd" in
        show)
            config_show
            ;;
        track)
            config_track "$@"
            ;;
        untrack)
            config_untrack "$@"
            ;;
        set-main)
            config_set_main "$@"
            ;;
        add-repo)
            config_add_repo "$@"
            ;;
        remove-repo)
            config_remove_repo "$@"
            ;;
        ""|help)
            cat <<EOF
Usage: claude-container config <command> [args]

Commands:
  show                 Show current config
  track <repo>         Enable tracking for repo
  untrack <repo>       Disable tracking for repo
  set-main <repo>      Set main project
  add-repo <path> [n]  Add discovered repo
  remove-repo <name>   Remove repo from config

These commands modify /workspace/.claude-projects.yml
EOF
            ;;
        *)
            error "Unknown config command: $subcmd"
            echo "Run 'claude-container config help' for usage"
            return 1
            ;;
    esac
}
