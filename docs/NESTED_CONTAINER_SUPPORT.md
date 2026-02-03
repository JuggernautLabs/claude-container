# Nested Container Support

## Overview

`claude-container` now supports running inside another container (nested containers). This allows you to use `claude-container` from within a claude-code session or any other containerized environment.

## How It Works

### Automatic Detection

The system automatically detects if it's running inside a container by checking:
1. Presence of `/.dockerenv` file
2. Docker/containerd markers in `/proc/1/cgroup`
3. Container environment variables in `/proc/1/environ`

When nested execution is detected, token passing switches from file mounts to environment variables.

### Token Passing Modes

**Normal Mode (Host)**:
- Token stored in temporary file: `~/.config/claude-container/cache/token-$$`
- Mounted into container as: `/run/secrets/claude_token:ro`
- Secure: token not visible in `docker inspect`

**Nested Mode (Container-in-Container)**:
- Token passed via environment variable: `CLAUDE_CODE_OAUTH_TOKEN_NESTED`
- Read inside target container and exported as `CLAUDE_CODE_OAUTH_TOKEN`
- Automatic: no user configuration needed

## Usage

### From Host

```bash
# Normal usage
./claude-container --token "$CLAUDE_CODE_OAUTH_TOKEN" -s my-session
```

### From Inside a Container

```bash
# Same command works automatically
./claude-container --token "$CLAUDE_CODE_OAUTH_TOKEN" -s my-session
```

The system detects the nested environment and adjusts automatically.

## Testing Nested Containers

To verify nested container support:

```bash
# From inside a claude-container session:
./claude-container --token "$CLAUDE_CODE_OAUTH_TOKEN" -s test --no-git-session --verify
```

Expected output includes:
```
[→] Nested container detected - passing token via environment
...
=== Token Check ===
  Token source: nested env var
  Token: sk-ant-oat01-...
```

## Implementation Details

### Files Modified

1. **`lib/container-detect.sh`** - New file with detection logic
2. **`lib/auth.sh`** - Updated `inject_token_securely()` to handle nested mode
3. **`claude-container`** - Updated entrypoint to read from both token sources

### Key Functions

**`is_running_in_container()`** (`lib/container-detect.sh`):
```bash
# Returns 0 (true) if running in container, 1 (false) otherwise
if is_running_in_container; then
    # Use nested mode
fi
```

**Token Injection** (`lib/auth.sh:inject_token_securely()`):
```bash
if is_running_in_container; then
    DOCKER_ARGS+=("-e" "CLAUDE_CODE_OAUTH_TOKEN_NESTED=$token")
else
    # Mount token file
    DOCKER_ARGS+=("-v" "$TOKEN_TMPFILE:/run/secrets/claude_token:ro")
fi
```

**Token Reading** (container entrypoint):
```bash
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN_NESTED:-}" ]]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN_NESTED"
elif [[ -f /run/secrets/claude_token ]]; then
    export CLAUDE_CODE_OAUTH_TOKEN=$(cat /run/secrets/claude_token)
fi
```

## Security Considerations

### Normal Mode
- Token stored in temporary file with 600 permissions
- File mounted read-only into container
- Not visible in `docker inspect` output
- File persists in cache (cleaned up manually or on reboot)

### Nested Mode
- Token passed as environment variable
- Visible in `docker inspect` for the container
- Trade-off: nested functionality vs. slight security reduction
- Still more secure than passing via command line args

## Limitations

1. **Environment Visibility**: In nested mode, tokens are visible via `docker inspect`
2. **File Mounts**: Cannot mount files from inside a container to another container
3. **Performance**: Minimal overhead from container detection (~1ms)

## Common Use Cases

### Developing claude-container Itself

```bash
# Start claude-container for development
./claude-container -s claude-dev

# Inside that session, test changes
./claude-container --token "$CLAUDE_CODE_OAUTH_TOKEN" -s test-session --verify
```

### CI/CD Pipelines

```bash
# In a GitHub Actions runner (running in Docker)
- run: |
    ./claude-container \
      --token "${{ secrets.CLAUDE_TOKEN }}" \
      -s ci-test \
      --no-git-session \
      --shell
```

### Development Containers

When using VS Code dev containers or similar:
```bash
# Works seamlessly in dev container environment
./claude-container --token "$CLAUDE_CODE_OAUTH_TOKEN" -s my-work
```

## Troubleshooting

### Token Not Found

If you see "ERROR: No token found":
```bash
# Verify detection is working
./claude-container --token "$CLAUDE_CODE_OAUTH_TOKEN" -s test --verify 2>&1 | grep "Token source"
```

Should show either:
- `Token source: file` (normal mode)
- `Token source: nested env var` (nested mode)

### Container Detection Issues

To manually check if detection works:
```bash
source ./lib/container-detect.sh
if is_running_in_container; then
    echo "Running in container"
else
    echo "Running on host"
fi
```

### Permission Issues

In nested mode, the inner container inherits permissions from the outer container. If you encounter permission issues:

```bash
# Run with --as-root if needed
./claude-container --token "$CLAUDE_CODE_OAUTH_TOKEN" -s test --as-root
```

## Future Enhancements

Potential improvements:
1. Optionally force normal/nested mode with `--nested` or `--no-nested` flags
2. Support for other container runtimes (podman, containerd)
3. Enhanced security for nested mode (encrypted env vars)
4. Automatic cleanup of nested containers on exit
