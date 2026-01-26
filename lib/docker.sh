#!/usr/bin/env bash
# claude-container Docker volume management
# Source this file after utils.sh
#
# Manages Docker volumes for session state and development caches.
# Requires: DOCKER_ARGS array to be declared before calling functions.

# Session state persistence - stores conversation history and settings
# Creates a Docker volume for Claude's .claude directory
setup_session_state() {
    local session_name="${1:-default}"
    local state_volume="claude-state-${session_name}"

    # Create volume if it doesn't exist
    docker volume inspect "$state_volume" &>/dev/null || \
        docker volume create "$state_volume" >/dev/null

    # Add to docker args
    DOCKER_ARGS+=("-v" "$state_volume:/home/developer/.claude")
}

# Dev tool caches - persist cargo/npm/pip caches across sessions
# Fixes permission issues (e.g., cargo registry owned by root)
setup_dev_caches() {
    local session_name="${1:-default}"

    for cache in cargo npm pip; do
        local vol="claude-${cache}-${session_name}"
        docker volume inspect "$vol" &>/dev/null || \
            docker volume create "$vol" >/dev/null
    done

    DOCKER_ARGS+=(
        "-v" "claude-cargo-${session_name}:/home/developer/.cargo"
        "-v" "claude-npm-${session_name}:/home/developer/.npm"
        "-v" "claude-pip-${session_name}:/home/developer/.cache/pip"
        "-e" "CARGO_HOME=/home/developer/.cargo"
        "-e" "npm_config_cache=/home/developer/.npm"
        "-e" "PIP_CACHE_DIR=/home/developer/.cache/pip"
    )
}
