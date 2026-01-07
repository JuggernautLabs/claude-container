# claude-container

Spawn into a Docker container with Claude Code ready to run.

## Quick Start

```bash
# Get an OAuth token on the host
claude setup-token
export CLAUDE_CODE_OAUTH_TOKEN=<token>

# Run container (uses ./Dockerfile)
claude-container

# Verify setup works
claude-container --verify
```

## Features

- **Token-based auth**: Pass OAuth token via environment variable
- **Ephemeral sessions**: No persistent volumes for auth, fresh config each run
- **Non-root execution**: Runs as `developer` user matching host UID
- **Overlay mode**: Isolate changes to a session-specific volume
- **SSH agent forwarding**: Git operations work seamlessly
- **Zero onboarding**: `.claude.json` created with theme and bypass settings

## Usage

```bash
claude-container [options] [dockerfile]

Options:
  --build, -b        Force rebuild the image
  --dir, -d <path>   Use overlay for directory (changes in session volume)
  --verify, -v       Verify container setup works
  --help, -h         Show help

Environment:
  CLAUDE_CODE_OAUTH_TOKEN   OAuth token for authentication (required)
                            Get one with: claude setup-token
```

### Dockerfile Search Order

1. `./Dockerfile`
2. `./.devcontainer/Dockerfile`
3. `./docker/Dockerfile`

## Authentication

Authentication is handled via the `CLAUDE_CODE_OAUTH_TOKEN` environment variable:

1. On your host machine, run `claude setup-token` to get a token
2. Export the token: `export CLAUDE_CODE_OAUTH_TOKEN=<token>`
3. Run `claude-container`

The token is passed into the container and used for authentication. No persistent volumes are needed for credentials.

## Volumes

| Volume | Mount Point | Purpose |
|--------|-------------|---------|
| `session-data-<uuid>` | `/session-data` | Session changes (overlay mode only) |
| Current directory | `/workspace` | Your project files |
| `~/.gitconfig` | `/root/.gitconfig` | Git configuration (ro) |
| `~/.ssh` | `/root/.ssh` | SSH keys (ro) |

## Creating a Compatible Dockerfile

Required packages:

```dockerfile
FROM rust:latest  # or your base image

# Required: gosu for non-root execution
RUN apt-get update && apt-get install -y \
    git curl gosu \
    && rm -rf /var/lib/apt/lists/*

# Node.js (for Claude Code)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

WORKDIR /workspace
CMD ["claude"]
```

## Overlay Mode

Isolate changes to a session-specific volume:

```bash
claude-container --dir ./my-project
```

Creates:
- Source mounted read-only at `/workspace-lower`
- Session volume for writes at `/session-data`
- OverlayFS merged view at `/workspace`

Changes persist in the session volume, source remains untouched.

## Session Workflow

### Starting an Overlay Session

```bash
claude-container --dir ./myproject
```

### What Happens

- Source directory mounted read-only at `/workspace-lower`
- Changes written to session volume (`session-data-<uuid>`)
- Session volume persists after container exits

### Finding Your Session

```bash
docker volume ls | grep session-data
```

### Inspecting Session Changes

```bash
docker run --rm -v session-data-<uuid>:/data alpine ls -la /data/upper
```

The `upper` directory contains all files modified or created during the session.

### Discarding a Session

```bash
docker volume rm session-data-<uuid>
```

## Headless / Streaming JSON Mode

For programmatic control, use streaming JSON mode which bypasses the TUI entirely:

```bash
echo '{"type":"user","message":{"role":"user","content":"List files"}}' | \
  claude -p \
    --input-format stream-json \
    --output-format stream-json \
    --verbose \
    --dangerously-skip-permissions
```

### Protocol

**Input:**
```json
{"type":"user","message":{"role":"user","content":"your prompt"}}
```

**Output messages:**
- `{"type":"system","subtype":"init",...}` - Session init (tools, model)
- `{"type":"assistant","message":{...}}` - Responses (may include tool_use)
- `{"type":"user","message":{...},"tool_use_result":{...}}` - Tool results
- `{"type":"result",...}` - Final result with costs/usage

### Headless Flags

| Flag | Purpose |
|------|---------|
| `-p, --print` | Non-interactive mode |
| `--input-format stream-json` | Accept JSON on stdin |
| `--output-format stream-json` | Emit JSON to stdout |
| `--verbose` | Required for stream-json output |
| `--dangerously-skip-permissions` | Skip permission prompts |
| `-c, --continue` | Resume last session |
| `-r, --resume <id>` | Resume specific session |
| `--max-budget-usd <n>` | Cost limit |

### Full Headless Example

```bash
docker run --rm \
  -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" \
  -v "$(pwd):/workspace" \
  your-image /bin/bash -c '
    groupadd -g 61000 developer 2>/dev/null || true
    useradd -u 501 -g 61000 -m developer 2>/dev/null || true

    cat > /home/developer/.claude.json << EOF
{"theme":"dark-ansi","hasCompletedOnboarding":true,"bypassPermissionsModeAccepted":true}
EOF
    chown developer:developer /home/developer/.claude.json

    echo "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"$PROMPT\"}}" | \
      gosu developer claude -p \
        --input-format stream-json \
        --output-format stream-json \
        --verbose \
        --dangerously-skip-permissions
  '
```

## Troubleshooting

### Token not set
```bash
# Get a token on the host
claude setup-token

# Export it
export CLAUDE_CODE_OAUTH_TOKEN=<token>
```

### Verify setup
```bash
claude-container --verify
```

### Test auth manually
```bash
docker run --rm \
  -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" \
  your-image claude --print "test"
```

## Notes

- Image names: `claude-dev-<project-name>`
- Container removed after exit (`--rm`)
- Non-root user has GID 61000 to avoid conflicts
- `.claude.json` is created fresh each run with dark theme and bypass settings
