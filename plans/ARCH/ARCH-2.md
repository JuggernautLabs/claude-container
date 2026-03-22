# ARCH-2: Contracts Library + Shared Utilities

blocked_by: []
unlocks: [ARCH-3, ARCH-4, ARCH-5, ARCH-6]

## Goal

Define the shared contract format and utility functions that all standalone scripts use. This is the foundation — nothing else starts until this is done.

## Deliverables

### 1. `lib/core/contract.sh` — Script contract helpers

```bash
# Every standalone script sources this first
source "$(dirname "$0")/../core/contract.sh"

# Structured output
cc_ok "message"           # exit 0 with message
cc_fail "message"         # exit 1 with message
cc_json '{"key":"val"}'   # structured output for machine consumption

# Confirmation
cc_confirm "Remove container?" || cc_fail "Aborted"
cc_confirm_destructive "This will delete data" || cc_fail "Aborted"

# Logging (to stderr, never stdout — stdout is for data)
cc_info "message"
cc_warn "message"
cc_error "message"
cc_note "message"

# Guards
cc_require_docker          # exits if docker not available
cc_require_volume "$vol"   # exits if volume doesn't exist
cc_require_container "$ctr" # exits if container doesn't exist
cc_require_tty             # exits if not interactive (for destructive ops)
```

### 2. `lib/core/constants.sh` — Shared constants

```bash
CC_BASE_IMAGE="ghcr.io/hypermemetic/claude-container:latest"
CC_GIT_IMAGE="${GIT_UTIL_IMAGE:-alpine/git}"
CC_CONFIG_DIR="$HOME/.config/claude-container"
CC_CACHE_DIR="$CC_CONFIG_DIR/cache"
CC_SESSIONS_DIR="$CC_CONFIG_DIR/sessions"

# Volume naming
cc_session_volume() { echo "claude-session-$1"; }
cc_state_volume() { echo "claude-state-$1"; }
cc_cargo_volume() { echo "claude-cargo-$1"; }
cc_npm_volume() { echo "claude-npm-$1"; }
cc_pip_volume() { echo "claude-pip-$1"; }
cc_container_name() { echo "claude-session-ctr-$1"; }
```

### 3. `lib/core/result.sh` — Result file I/O (from utils.sh)

Move `_pull_result_set`, `_pull_result_get` here as `cc_result_set`, `cc_result_get`.

### 4. Contract documentation format

Every script in `lib/lifecycle/`, `lib/session/`, `lib/sync/` starts with a header block:

```bash
#!/usr/bin/env bash
# cc-image-validate — validate that a Docker image meets the container protocol
#
# USAGE:
#   cc-image-validate <image_name> [--json]
#
# INPUTS:
#   $1 - Docker image name or ID
#   --json - output structured JSON instead of human text
#
# OUTPUTS:
#   stdout: validation results (human or JSON)
#   exit 0: image is valid
#   exit 1: image is missing critical tools
#
# READS:
#   Docker image metadata (docker run --rm to test binaries)
#
# WRITES:
#   nothing
#
# DESTROYS:
#   nothing
```

## Acceptance Criteria

1. `contract.sh` sourced by all scripts — provides logging, confirmation, guards
2. `constants.sh` — single source of truth for naming conventions
3. `result.sh` — result file I/O extracted from utils.sh
4. Every standalone script has a contract header
5. No script uses `echo` for logging (uses `cc_info`/`cc_warn`/`cc_error` instead)
6. stdout is always data, stderr is always human messages

## Files

| File | Purpose |
|------|---------|
| `lib/core/contract.sh` | Script contract helpers |
| `lib/core/constants.sh` | Shared constants and naming |
| `lib/core/result.sh` | Result file I/O |
