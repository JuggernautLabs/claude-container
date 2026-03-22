#!/usr/bin/env bash
# Shared constants — single source of truth for naming conventions, paths, and defaults.
# Source this in every script that needs claude-container conventions.

CC_BASE_IMAGE="ghcr.io/hypermemetic/claude-container:latest"
CC_GIT_IMAGE="${GIT_UTIL_IMAGE:-alpine/git}"
CC_CONFIG_DIR="${CC_CONFIG_DIR:-$HOME/.config/claude-container}"
CC_CACHE_DIR="${CC_CACHE_DIR:-$CC_CONFIG_DIR/cache}"
CC_SESSIONS_DIR="${CC_SESSIONS_DIR:-$CC_CONFIG_DIR/sessions}"

# Volume naming
cc_session_volume()  { echo "claude-session-$1"; }
cc_state_volume()    { echo "claude-state-$1"; }
cc_cargo_volume()    { echo "claude-cargo-$1"; }
cc_npm_volume()      { echo "claude-npm-$1"; }
cc_pip_volume()      { echo "claude-pip-$1"; }
cc_container_name()  { echo "claude-session-ctr-$1"; }

# Required binaries in the image (no fallback)
CC_REQUIRED_BINARIES=(gosu git claude bash)
# Optional binaries (warning only)
CC_OPTIONAL_BINARIES=(python3 sudo docker)
