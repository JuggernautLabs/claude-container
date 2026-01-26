#!/usr/bin/env bash
# claude-container platform detection
# Source this file after utils.sh

# Platform variables (set by detect_platform)
PLATFORM=""
IS_CI=false

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Darwin)
            PLATFORM="macos"
            ;;
        Linux)
            PLATFORM="linux"
            # Detect WSL
            if grep -qi microsoft /proc/version 2>/dev/null; then
                PLATFORM="wsl"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            PLATFORM="windows"
            ;;
        *)
            PLATFORM="unknown"
            ;;
    esac
}

# CI environment detection
detect_ci() {
    if [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]]; then
        IS_CI=true
    else
        IS_CI=false
    fi
}

# Get host UID dynamically (platform-aware)
get_host_uid() {
    case "$PLATFORM" in
        windows)
            echo "1000"  # Default for Windows containers
            ;;
        *)
            id -u
            ;;
    esac
}

# Get host GID dynamically (platform-aware)
get_host_gid() {
    case "$PLATFORM" in
        windows)
            echo "1000"  # Default for Windows containers
            ;;
        *)
            id -g
            ;;
    esac
}

# Platform-specific SSH socket arguments
get_ssh_socket_args() {
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        return
    fi

    case "$PLATFORM" in
        macos)
            # macOS Docker Desktop uses a special socket path
            echo "-v /run/host-services/ssh-auth.sock:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent"
            ;;
        linux|wsl)
            # Linux/WSL can directly mount the SSH socket
            echo "-v $SSH_AUTH_SOCK:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent"
            ;;
        windows)
            # Windows named pipe - not directly supported, skip SSH forwarding
            echo ""
            ;;
        *)
            # Unknown platform - try direct mount as fallback
            echo "-v $SSH_AUTH_SOCK:/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent"
            ;;
    esac
}

# Auto-initialize on source
detect_platform
detect_ci
