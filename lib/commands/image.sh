#!/usr/bin/env bash
# Subcommand: image
# Show which Docker image is running (or configured) for a session
#
# Usage:
#   claude-container image -s <session>    # image for a specific session
#   claude-container image                 # images for all running sessions

cmd_image() {
    local session_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --help|-h)
                _image_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container image --help' for usage"
                return 1
                ;;
            *)
                error "Unexpected argument: $1"
                echo "Run 'claude-container image --help' for usage"
                return 1
                ;;
        esac
    done

    if [[ -n "$session_name" ]]; then
        _image_for_session "$session_name"
    else
        _image_all
    fi
}

_image_for_session() {
    local session_name="$1"
    local volume="claude-session-${session_name}"

    # Check if session volume exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    # Find running container(s) using this session volume
    local containers
    containers=$(docker ps --filter "volume=$volume" --format '{{.ID}}|{{.Image}}|{{.Status}}|{{.Names}}' 2>/dev/null)

    if [[ -n "$containers" ]]; then
        info "Session '$session_name' — running"
        echo ""
        while IFS='|' read -r cid image status name; do
            [[ -z "$cid" ]] && continue
            echo "  Container:  $name"
            echo "  Image:      $image"

            # Get full image ID and digest if available
            local image_id
            image_id=$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null)
            if [[ -n "$image_id" ]]; then
                echo "  Image ID:   ${image_id:0:19}..."
            fi

            # Show OCI source label if present (points to Dockerfile repo)
            local source_label
            source_label=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.source"}}' "$image" 2>/dev/null)
            if [[ -n "$source_label" ]] && [[ "$source_label" != "<no value>" ]]; then
                echo "  Source:     $source_label"
            fi

            # Show Dockerfile from session metadata if available
            local env_file="$HOME/.config/claude-container/sessions/${session_name}.env"
            if [[ -f "$env_file" ]]; then
                local saved_dockerfile=""
                while IFS='=' read -r key value; do
                    [[ -z "$key" || "$key" =~ ^# ]] && continue
                    [[ "$key" == "DOCKERFILE" ]] && [[ -n "$value" ]] && saved_dockerfile="$value"
                done < "$env_file"
                if [[ -n "$saved_dockerfile" ]]; then
                    echo "  Dockerfile: $saved_dockerfile"
                fi
            fi

            local created
            created=$(docker inspect --format '{{.Created}}' "$cid" 2>/dev/null | cut -d'.' -f1)
            if [[ -n "$created" ]]; then
                echo "  Started:    $created"
            fi

            echo "  Status:     $status"
        done <<< "$containers"
    else
        # No running container — show configured/expected image
        info "Session '$session_name' — not running"
        echo ""
        _image_configured "$session_name"
    fi
}

_image_configured() {
    local session_name="$1"
    local env_file="$HOME/.config/claude-container/sessions/${session_name}.env"

    local configured_dockerfile=""
    if [[ -f "$env_file" ]]; then
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            if [[ "$key" == "DOCKERFILE" ]] && [[ -n "$value" ]]; then
                configured_dockerfile="$value"
            fi
        done < "$env_file"
    fi

    if [[ -n "$configured_dockerfile" ]]; then
        # Custom Dockerfile — derive expected image name
        local project_name
        project_name=$(basename "$(dirname "$configured_dockerfile")" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        local expected_image="claude-dev-${project_name}"

        echo "  Dockerfile: $configured_dockerfile"

        # Check if the built image exists
        local image_id
        image_id=$(docker images -q "$expected_image" 2>/dev/null)
        if [[ -n "$image_id" ]]; then
            echo "  Image:      $expected_image"
            echo "  Image ID:   $image_id"
        else
            echo "  Image:      $expected_image (not yet built)"
        fi
    else
        echo "  Image:      ${DEFAULT_IMAGE:-ghcr.io/hypermemetic/claude-container:latest} (default)"

        # Check if the default image is pulled
        local image_id
        image_id=$(docker images -q "${DEFAULT_IMAGE:-ghcr.io/hypermemetic/claude-container:latest}" 2>/dev/null)
        if [[ -n "$image_id" ]]; then
            echo "  Image ID:   $image_id"
        else
            echo "  Image ID:   (not pulled)"
        fi
    fi
}

_image_all() {
    # Find all running claude-container sessions
    local containers
    containers=$(docker ps --filter "name=claude-dev" --format '{{.ID}}|{{.Image}}|{{.Status}}|{{.Names}}' 2>/dev/null)

    if [[ -z "$containers" ]]; then
        info "No running claude-container sessions"
        echo ""
        echo "Tip: use 'claude-container image -s <session>' to check a stopped session's configured image"
        return 0
    fi

    info "Running claude-container sessions"
    echo ""

    while IFS='|' read -r cid image status name; do
        [[ -z "$cid" ]] && continue

        # Resolve session name from volume mounts
        local session=""
        local mounts
        mounts=$(docker inspect --format '{{range .Mounts}}{{.Name}}|{{.Destination}}{{"\n"}}{{end}}' "$cid" 2>/dev/null)
        while IFS='|' read -r vol_name vol_dest; do
            if [[ "$vol_name" == claude-session-* ]] && [[ "$vol_dest" == "/workspace" ]]; then
                session="${vol_name#claude-session-}"
                break
            fi
        done <<< "$mounts"

        echo "  Session:    ${session:-unknown}"
        echo "  Container:  $name"
        echo "  Image:      $image"
        echo "  Status:     $status"
        echo ""
    done <<< "$containers"
}

_image_help() {
    cat <<EOF
Usage: claude-container image [options]

Show which Docker image is running (or configured) for a session.

Options:
  --session, -s <name>   Show image for a specific session
  --help, -h             Show this help

When a session is running, shows the actual container image and status.
When a session is stopped, shows the configured/expected image.
Without --session, lists all running claude-container sessions.

Examples:
  # Show image for a specific session
  claude-container image -s myproj

  # List all running sessions and their images
  claude-container image
EOF
}
