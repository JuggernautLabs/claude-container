# CAGE-2: Agent CLI Interface Spec

blocked_by: []
unlocks: [CAGE-6, CAGE-8]

## Scope

Define the interface contract that any agent wrapper must implement. An agent is a CLI binary named `cage-agent-<name>` on PATH. Cage discovers agents by scanning PATH for this prefix.

## The Spec

### Discovery

```bash
cage-agent-<name>            # binary on PATH
```

Cage finds agents with: `which cage-agent-* 2>/dev/null` or PATH scan.

### Commands

Every agent binary MUST implement these subcommands:

#### `info`

```bash
cage-agent-claude info
```

Prints JSON to stdout:

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
  "caches": [
    "/home/developer/.cargo",
    "/home/developer/.npm"
  ]
}
```

Fields:
- `name`: display name
- `version`: wrapper version
- `image`: preferred Docker base image (cage pulls/builds this)
- `needs.sudo`: cage sets up passwordless sudo (rootish trick)
- `needs.docker`: cage mounts Docker socket
- `needs.network`: container gets network access (vs `--network none`)
- `needs.ssh_agent`: cage forwards SSH agent
- `caches`: paths the agent wants as shared volumes (build caches). Cage maps these to global shared volumes.

#### `auth check`

```bash
cage-agent-claude auth check
# exit 0 = auth valid
# exit 1 = auth missing/expired
```

No stdout required. Exit code only.

#### `auth setup`

```bash
cage-agent-claude auth setup
```

Interactive flow to configure credentials. Runs on host. May prompt the user, open a browser, etc. Agent-specific.

#### `auth inject`

```bash
cage-agent-claude auth inject <container-name>
```

Inject credentials into the specified container. The wrapper decides how:
- Claude: mount token file at `/run/secrets/claude_token:ro`
- Aider: set `ANTHROPIC_API_KEY` env var
- Shell: no-op

This runs on the host. It can call `docker cp`, `docker exec`, or add env vars. Cage calls this BEFORE starting the container.

#### `setup`

```bash
cage-agent-claude setup <workspace-path>
```

One-time setup inside the container. Cage calls this via `docker exec` after container creation. The wrapper installs agent-specific config:
- Claude: write `.claude.json`, install `fin` equivalent
- Aider: write `.aider.conf.yml`
- Shell: no-op

This runs INSIDE the container (via `cage container exec`).

#### `run`

```bash
cage-agent-claude run --workspace /workspace [--prompt "..."] [--resume]
```

Start the agent. This runs INSIDE the container as the entrypoint. The wrapper translates args to the underlying tool:

```bash
# cage-agent-claude translates to:
claude --dangerously-skip-permissions --prompt "..." /workspace

# cage-agent-aider translates to:
cd /workspace && aider --message "..."

# cage-agent-shell translates to:
cd /workspace && exec /bin/bash
```

Flags:
- `--workspace <path>`: required. Where repos live.
- `--prompt <text>`: optional. Initial task/message.
- `--resume`: continue previous conversation (agent-specific behavior).

The wrapper also:
- Reads `/workspace/.cage/inbox/task.json` if `--prompt` not given
- Installs the `fin` command (or equivalent) that writes to `/workspace/.cage/outbox/`

### Exit Behavior

The agent process IS PID 1 (or close to it). When it exits:
- Exit 0 = normal completion
- Exit non-zero = error/crash
- Before exiting, agent MAY write to `/workspace/.cage/outbox/done.json`

Cage reads outbox after container stops. See CAGE-8 for protocol.

## Agent Wrapper Structure

A minimal agent wrapper (e.g., `cage-agent-shell`) is ~50 lines:

```bash
#!/usr/bin/env bash
# cage-agent-shell — trivial agent wrapper

case "$1" in
  info)
    cat <<'EOF'
{"name":"shell","version":"1.0.0","image":"ubuntu:22.04","needs":{"sudo":true,"docker":false,"network":true,"ssh_agent":true},"caches":[]}
EOF
    ;;
  auth)
    case "$2" in
      check) exit 0 ;;
      setup) echo "No auth needed for shell." ;;
      inject) ;; # no-op
    esac
    ;;
  setup)
    ;; # no-op
  run)
    shift
    local workspace=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --workspace) workspace="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cd "$workspace" && exec /bin/bash
    ;;
  *)
    echo "Unknown command: $1" >&2
    exit 1
    ;;
esac
```

## Acceptance Criteria

- [ ] Spec document finalized and versioned (v1)
- [ ] `cage-agent-shell` reference implementation (trivial, validates the spec)
- [ ] `cage agent list` discovers agents on PATH
- [ ] `cage agent info <name>` calls `cage-agent-<name> info` and parses JSON
- [ ] Spec supports future extension without breaking existing wrappers (unknown fields ignored)
