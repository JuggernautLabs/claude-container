#!/usr/bin/env bash
# claude-container authentication - token management and secure injection
# Source this file after utils.sh and platform.sh
#
# Requires: CONFIG_DIR and CACHE_DIR must be set before sourcing
# Provides: inject_token_securely(), ensure_token()

# Token variables (set by ensure_token or command-line args)
# Don't clear CLAUDE_CODE_OAUTH_TOKEN if it's already set (e.g., via --token flag)
TOKEN_FILE=""
TOKEN_TMPFILE=""

# Secure token injection - mounts token as file instead of env var
# This prevents token from being visible in `docker inspect`
# Requires: CACHE_DIR, DOCKER_ARGS array
# Note: When running in a nested container, uses env var instead of file mount
inject_token_securely() {
    local token="$1"

    # Detect if we're running inside a container (nested)
    # If so, we can't mount files from our filesystem into the new container
    if is_running_in_container; then
        info "Nested container detected - passing token via environment"
        DOCKER_ARGS+=("-e" "CLAUDE_CODE_OAUTH_TOKEN_NESTED=$token")
        return 0
    fi

    # Normal operation: mount token as file
    # Use a path that Docker VM can definitely access
    # On macOS with Colima/Docker Desktop, $TMPDIR (/var/folders/...) may not be shared
    # Use $HOME/.cache which is always shared
    local token_dir="$CACHE_DIR"
    mkdir -p "$token_dir"
    chmod 700 "$token_dir"

    TOKEN_TMPFILE="$token_dir/token-$$"
    echo -n "$token" > "$TOKEN_TMPFILE"
    chmod 600 "$TOKEN_TMPFILE"

    # Verify file exists and has content (prevents Docker creating a directory)
    if [[ ! -f "$TOKEN_TMPFILE" ]] || [[ ! -s "$TOKEN_TMPFILE" ]]; then
        error "Failed to create token file"
        exit 1
    fi

    # Don't auto-cleanup - let the token file persist until manual cleanup or system reboot
    # The file is in /cache which is meant for temporary files anyway
    # Cleanup on error signals only
    trap "rm -f '$TOKEN_TMPFILE'" INT TERM

    # Mount as file (must be absolute path for Docker)
    DOCKER_ARGS+=("-v" "$TOKEN_TMPFILE:/run/secrets/claude_token:ro")
}

# Ensure we have a valid OAuth token
# Tries (in order): environment variable, config file, macOS Keychain, interactive OAuth flow
# Requires: CONFIG_DIR, CACHE_DIR, PLATFORM
ensure_token() {
    TOKEN_FILE="$CONFIG_DIR/token"

    # Already have token from environment?
    if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        # Validate token format (should start with sk-ant-oat)
        if [[ "$CLAUDE_CODE_OAUTH_TOKEN" =~ ^sk-ant-oat ]]; then
            info "Using token from environment (${CLAUDE_CODE_OAUTH_TOKEN:0:20}...)"
            export CLAUDE_CODE_OAUTH_TOKEN
            return 0
        else
            warn "Invalid token format in environment, trying other sources..."
            CLAUDE_CODE_OAUTH_TOKEN=""
        fi
    fi

    # Try config file first
    if [[ -f "$TOKEN_FILE" ]]; then
        CLAUDE_CODE_OAUTH_TOKEN=$(cat "$TOKEN_FILE")
        info "Using token from config file"
        export CLAUDE_CODE_OAUTH_TOKEN
        return 0
    fi

    # Try macOS Keychain (where Claude Code stores its OAuth token)
    info "No token found, attempting to fetch from keychain..."
    if [[ "$PLATFORM" == "macos" ]] && command -v security &>/dev/null; then
        # Claude Code stores token with service "claude.ai"
        local fetched_token
        fetched_token=$(security find-generic-password -s "claude.ai" -w 2>/dev/null || true)
        if [[ -n "$fetched_token" ]]; then
            CLAUDE_CODE_OAUTH_TOKEN="$fetched_token"
            # Store for future use
            echo -n "$fetched_token" > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
            success "Token fetched from Keychain and stored in $TOKEN_FILE"
            export CLAUDE_CODE_OAUTH_TOKEN
            return 0
        fi
    fi

    # Final check - still no token? Start auth flow (unless --no-interactive)
    warn "No token found in keychain or config"
    echo ""

    # Check if interactive mode is disabled
    if [[ "${NO_INTERACTIVE:-false}" == "true" ]]; then
        error "No token found and --no-interactive specified"
        echo ""
        echo "Please provide a token via one of:"
        echo "  1. --token <token> flag"
        echo "  2. CLAUDE_CODE_OAUTH_TOKEN environment variable"
        echo "  3. ~/.config/claude-container/token file"
        echo "  4. macOS Keychain (claude.ai)"
        exit 1
    fi

    if ! command -v claude &>/dev/null; then
        error "claude CLI not found"
        echo ""
        echo "Install Claude Code first, then run: claude setup-token"
        exit 1
    fi

    echo "Starting authentication flow..."
    echo ""

    # Capture output to extract token
    local auth_output_file="$CACHE_DIR/auth-output-$$"

    # Use script command to provide a proper PTY for claude setup-token
    if [[ "$PLATFORM" == "macos" ]]; then
        script -q "$auth_output_file" claude setup-token
    else
        script -qc "claude setup-token" "$auth_output_file"
    fi

    # Extract token from output (sk-ant-oat... pattern ending in AA)
    # Token may span multiple lines due to terminal wrapping with ANSI codes
    if [[ -f "$auth_output_file" ]]; then
        # Strip ANSI codes, join lines, then extract token (ends with AA)
        local fetched_token
        fetched_token=$(cat "$auth_output_file" | \
            sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | \
            tr -d '\n\r' | \
            grep -oE 'sk-ant-oat[A-Za-z0-9_-]+AA' | \
            head -1 || true)
        rm -f "$auth_output_file"

        if [[ -n "$fetched_token" ]]; then
            CLAUDE_CODE_OAUTH_TOKEN="$fetched_token"
            echo -n "$fetched_token" > "$TOKEN_FILE"
            chmod 600 "$TOKEN_FILE"
            success "Token saved to $TOKEN_FILE"
            export CLAUDE_CODE_OAUTH_TOKEN
            return 0
        else
            error "Could not extract token from auth output"
            echo "You may need to manually run: claude setup-token"
            echo "Then store the token in: $TOKEN_FILE"
            exit 1
        fi
    else
        error "Auth output file not created"
        exit 1
    fi
}
