# ARCH-7: Orchestrator Rewrite

blocked_by: [ARCH-3, ARCH-4, ARCH-5, ARCH-6]
unlocks: [ARCH-8]

## Goal

Rewrite the main `claude-container` script as a thin orchestrator that calls standalone scripts in sequence. No inline docker commands, no inline git operations, no state management. Just flow control and user interaction.

## Target: ~200 lines

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib/core/contract.sh"
source "$(dirname "$0")/lib/core/constants.sh"

# Parse flags
parse_args "$@"

# Subcommand dispatch (pull, push, sync, session, repos, watch, etc.)
if [[ -n "$SUBCOMMAND" ]]; then
    exec "$SCRIPT_DIR/lib/commands/$SUBCOMMAND" "$@"
fi

# Main launch flow
cc-session-config "$SESSION_NAME" load || cc_fail "Session not found"

# Build image if needed
if [[ -n "$DOCKERFILE" ]]; then
    cc-image-build "$IMAGE_NAME" "$DOCKERFILE" "$CONTEXT_DIR"
fi

# Validate image
cc-image-validate "$IMAGE_NAME" || cc_fail "Image invalid"

# Inject token
TOKEN_MOUNT=$(cc-token-inject "$TOKEN" "$CC_CACHE_DIR")

# Check existing container
CHECK_RESULT=$(cc-container-check "$CONTAINER_NAME" "$IMAGE_NAME" "$SCRIPT_DIR")
if [[ $(echo "$CHECK_RESULT" | jq -r '.ok') != "true" ]]; then
    echo "$CHECK_RESULT" | jq -r '.reasons[]'
    cc-container-remove "$CONTAINER_NAME" || cc_fail "Cannot proceed with stale container"
fi

# Create or resume
if docker ps -aq --filter "name=^${CONTAINER_NAME}$" | grep -q .; then
    docker start -ai "$CONTAINER_NAME"
else
    cc-container-create "$CONTAINER_NAME" "$IMAGE_NAME" $TOKEN_MOUNT "${DOCKER_ARGS[@]}"
fi

# Post-exit handling
cc-session-post-exit "$SESSION_NAME"
```

## Key Design Principles

1. **No docker commands in the orchestrator** — all docker interactions go through lifecycle scripts
2. **No git commands in the orchestrator** — all git interactions go through sync scripts
3. **No inline state management** — session config is read/written by `cc-session-config`
4. **Error handling is explicit** — each script call checked, clear error messages
5. **User interaction only in the orchestrator** — scripts are headless by default

## Acceptance Criteria

1. Main script under 300 lines (including arg parsing)
2. Every docker/git operation delegated to a script
3. No `docker rm -f` in the orchestrator
4. No `set -e` — explicit error handling
5. Subcommands dispatch to their own scripts
6. Post-exit handling (merge cleanup, agent result) is a separate script

## Files

| File | Purpose |
|------|---------|
| `bin/claude-container` | New thin orchestrator |
| `claude-container.bak` | Old monolith (kept for reference during transition) |
