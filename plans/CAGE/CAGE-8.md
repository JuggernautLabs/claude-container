# CAGE-8: Communication Protocol (.cage/ directory)

blocked_by: [CAGE-2]
unlocks: [CAGE-5, CAGE-6]

## Scope

Define the filesystem-based protocol for communication between cage (host) and agents (container). All communication goes through `/workspace/.cage/` on the shared volume.

## Directory Structure

```
/workspace/.cage/
  config.yml          # volume config (cage-managed, read-only to agent)
  manifest            # repo manifest (cage-managed, read-only to agent)

  inbox/              # cage → agent (written by cage before container start)
    task.json         # initial task/prompt
    context/          # additional context files (diffs, summaries, etc.)

  outbox/             # agent → cage (written by agent, read by cage after stop)
    done.json         # completion signal
    progress.json     # optional: incremental progress
    request.json      # optional: agent requests cage action

  control/            # reserved for future real-time communication
```

## Protocol Messages

### cage → agent: `inbox/task.json`

Written by cage before `container start`. Read by agent wrapper on startup.

```json
{
  "version": 1,
  "type": "task",
  "prompt": "Resolve merge conflicts in synapse/ and vox/",
  "context": {
    "operation": "inject-merge",
    "branch": "main",
    "conflicts": [
      {"repo": "synapse", "files": ["src/main.rs", "Cargo.toml"]},
      {"repo": "vox", "files": ["src/lib.rs"]}
    ]
  },
  "on_complete": "fin"
}
```

The agent wrapper reads this and translates to whatever the underlying tool needs:
- Claude: `--prompt <text>` with context appended
- Aider: `--message <text>`
- Shell: print to stdout on login

If `--prompt` is passed to `cage run`, cage writes it here. The agent wrapper always reads from inbox — the prompt flag is just sugar.

### agent → cage: `outbox/done.json`

Written by agent (via `fin` or equivalent) when work is complete.

```json
{
  "version": 1,
  "status": "complete",
  "message": "Resolved all merge conflicts, tests passing",
  "timestamp": "2026-03-01T12:00:00Z"
}
```

Status values:
- `complete` — task done successfully
- `partial` — some work done, more needed
- `error` — agent encountered unrecoverable error

Cage reads this after container stops. Determines next action (extract, continue, abort).

### agent → cage: `outbox/request.json` (future)

Reserved for agent-initiated requests:

```json
{
  "version": 1,
  "action": "extract",
  "reason": "Checkpoint — want to save progress"
}
```

```json
{
  "version": 1,
  "action": "add-repo",
  "repo": "/host/path/to/new-repo"
}
```

Not implemented in v1. The protocol supports it so wrappers can write these without breaking anything.

## The `fin` Command

Each agent wrapper installs a `fin` command (or equivalent) during `setup`. This is the agent-side API for signaling cage:

```bash
fin "resolved all conflicts"
```

Implementation (installed by agent wrapper):

```bash
#!/usr/bin/env bash
# fin — signal task completion to cage
if [[ $# -eq 0 ]]; then
  echo "Usage: fin <description>"
  echo "Signals completion and stops the session."
  exit 1
fi

cat > /workspace/.cage/outbox/done.json <<EOF
{
  "version": 1,
  "status": "complete",
  "message": "$*",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Session complete: $*"
kill 1
```

The `kill 1` sends SIGTERM to PID 1, triggering graceful container shutdown. Cage reads `done.json` after the container stops.

## Ownership and Permissions

- `/workspace/.cage/` created by cage during volume setup
- `inbox/` written by cage (host-side utility container), read by agent
- `outbox/` written by agent, read by cage (host-side utility container after stop)
- `config.yml` and `manifest` are cage-managed, agent reads only
- Agent should not write outside `.cage/outbox/`

## Versioning

All messages include `"version": 1`. Cage and agent wrappers ignore unknown fields. Version bump only for breaking changes.

## Acceptance Criteria

- [ ] `.cage/` directory structure created during volume setup
- [ ] `inbox/task.json` written by cage, read by agent wrappers
- [ ] `outbox/done.json` written by `fin`, read by cage post-exit
- [ ] `fin` command spec defined, installable by any agent wrapper
- [ ] Unknown fields in messages are ignored (forward compatibility)
- [ ] Protocol version documented (v1)
