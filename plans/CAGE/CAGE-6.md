# CAGE-6: cage-agent-claude Wrapper

blocked_by: [CAGE-2, CAGE-8]
unlocks: [CAGE-7]

## Scope

Implement the Claude Code agent wrapper. This is a CLI binary `cage-agent-claude` that implements the agent spec (CAGE-2) and translates between cage's protocol and Claude Code's interface.

## What Claude Code Needs

From surveying claude-container, Claude Code requires:

1. **Auth**: OAuth token at `CLAUDE_CODE_OAUTH_TOKEN` env var or file
2. **Permissions**: `--dangerously-skip-permissions` flag (when running as non-root user)
3. **Config**: `.claude.json` in home dir with onboarding bypassed
4. **State**: `~/.claude/` directory for conversation history
5. **Resume**: `--continue` flag to resume previous conversation
6. **Prompt**: `--prompt` flag for initial message (or `-p`)
7. **Working dir**: `cd` to workspace before running

## Commands

### `info`

```bash
cage-agent-claude info
```

```json
{
  "name": "claude",
  "version": "1.0.0",
  "image": "ghcr.io/hypermemetic/claude-container:latest",
  "needs": {
    "sudo": true,
    "docker": false,
    "network": true,
    "ssh_agent": true
  },
  "caches": []
}
```

Notes:
- `sudo: true` — Claude runs `apt-get install`, `pip install`, etc.
- `docker: false` — default off, but could be enabled with a flag
- `caches: []` — Claude's state lives in the persistent container (not a shared cache). Build caches (cargo, npm) are handled by cage globally.

### `auth check`

```bash
cage-agent-claude auth check
```

Check for valid OAuth token:
1. Check `CLAUDE_CODE_OAUTH_TOKEN` env var
2. Check `~/.config/cage/agents/claude/token`
3. Check macOS Keychain: `security find-generic-password -s "claude.ai"`
4. Exit 0 if found, exit 1 if not

### `auth setup`

```bash
cage-agent-claude auth setup
```

Interactive token acquisition:
1. Try `claude setup-token` (Claude Code's built-in flow)
2. Save to `~/.config/cage/agents/claude/token`

### `auth inject`

```bash
cage-agent-claude auth inject cage-myproj
```

Inject token into container WITHOUT exposing via env vars:

```bash
# Write token to temp file
TOKEN=$(cat ~/.config/cage/agents/claude/token)
TMPFILE=$(mktemp)
echo -n "$TOKEN" > "$TMPFILE"
chmod 600 "$TMPFILE"

# Copy into container
docker cp "$TMPFILE" cage-myproj:/run/secrets/claude_token
docker exec cage-myproj chmod 644 /run/secrets/claude_token
docker exec cage-myproj chown developer:developer /run/secrets/claude_token

# Cleanup
rm -f "$TMPFILE"
```

The `run` command reads from `/run/secrets/claude_token`.

### `setup`

```bash
cage-agent-claude setup /workspace
```

Runs INSIDE the container (via `docker exec`). One-time setup:

```bash
# .claude.json — bypass onboarding, set theme
cat > /home/developer/.claude.json <<'EOF'
{
  "theme": "dark-ansi",
  "hasCompletedOnboarding": true,
  "bypassPermissionsModeAccepted": true
}
EOF
chown developer:developer /home/developer/.claude.json

# Install fin command
cat > /usr/local/bin/fin <<'FINSCRIPT'
#!/usr/bin/env bash
if [[ $# -eq 0 ]]; then
  echo "Usage: fin <description>"
  echo "Signals completion and stops the agent session."
  exit 1
fi
mkdir -p /workspace/.cage/outbox
cat > /workspace/.cage/outbox/done.json <<DONE
{
  "version": 1,
  "status": "complete",
  "message": "$*",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
DONE
echo ""
echo "Session complete: $*"
exit 0
FINSCRIPT
chmod +x /usr/local/bin/fin

# Copy host git config if available
[[ -f /home/developer/.gitconfig ]] || \
  cp /root/.gitconfig /home/developer/.gitconfig 2>/dev/null || true
```

Note: `fin` does `exit 0` instead of `kill 1`. The agent process exits, cage detects this, and the container stays alive (persistent container model). Cage reads `done.json` after agent exit.

### `run`

```bash
cage-agent-claude run --workspace /workspace [--prompt "..."] [--resume]
```

Runs INSIDE the container as the agent entrypoint:

```bash
#!/usr/bin/env bash
WORKSPACE=""
PROMPT=""
RESUME=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --resume) RESUME=true; shift ;;
    *) shift ;;
  esac
done

# Read token
if [[ -f /run/secrets/claude_token ]]; then
  export CLAUDE_CODE_OAUTH_TOKEN=$(cat /run/secrets/claude_token)
fi

# Read inbox if no --prompt given
if [[ -z "$PROMPT" ]] && [[ -f "$WORKSPACE/.cage/inbox/task.json" ]]; then
  # Extract prompt from task.json (requires jq or simple parsing)
  PROMPT=$(jq -r '.prompt // empty' "$WORKSPACE/.cage/inbox/task.json" 2>/dev/null || true)
fi

# Build claude args
CLAUDE_ARGS=(--dangerously-skip-permissions)

if $RESUME; then
  CLAUDE_ARGS+=(--continue)
fi

if [[ -n "$PROMPT" ]]; then
  CLAUDE_ARGS+=(--prompt "$PROMPT")
fi

# Determine working directory
cd "$WORKSPACE"
if [[ -f "$WORKSPACE/.cage/config.yml" ]]; then
  # If single repo, cd into it
  REPO_COUNT=$(ls -d "$WORKSPACE"/*/. 2>/dev/null | wc -l)
  if [[ $REPO_COUNT -eq 1 ]]; then
    cd "$WORKSPACE"/*/
  fi
fi

# Run claude
exec claude "${CLAUDE_ARGS[@]}"
```

## Token Storage

```
~/.config/cage/agents/claude/
  token                    # OAuth token (plain text, 600 perms)
```

## Differences from claude-container

| Aspect | claude-container | cage-agent-claude |
|--------|-----------------|-------------------|
| Token injection | Mounted as volume at create time | `docker cp` before each start |
| User setup | Inline in entrypoint heredoc | `setup` command, once |
| `fin` behavior | `kill 1` (destroys container) | `exit 0` (agent exits, container lives) |
| `.claude.json` | Written every startup | Written once during `setup` |
| Args | Base64-encoded passthrough | Direct `--prompt`/`--resume` flags |
| Working dir | `.main-project` marker | Inferred from config |

## Acceptance Criteria

- [ ] `cage-agent-claude info` returns correct JSON
- [ ] `cage-agent-claude auth check` finds token from env, file, or Keychain
- [ ] `cage-agent-claude auth setup` runs interactive OAuth flow
- [ ] `cage-agent-claude auth inject` copies token securely into container
- [ ] `cage-agent-claude setup` configures `.claude.json` and `fin`
- [ ] `cage-agent-claude run` launches Claude with correct flags
- [ ] `run` reads inbox task when no `--prompt` given
- [ ] `fin` writes to `.cage/outbox/done.json` and exits cleanly
- [ ] Token never visible in `docker inspect` output
