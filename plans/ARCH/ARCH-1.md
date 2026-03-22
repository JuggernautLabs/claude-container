# ARCH-1: Epic Overview — Standalone Script Architecture

## Goal

Decompose the 1400-line monolith into standalone scripts with clear contracts. Each script has one job, explicit inputs/outputs, never silently destroys data, and is independently testable.

## Current Problems

1. **No data guarantees** — container removal happens in 6 places with different conditions, some silent
2. **Tangled state** — image validation, container lifecycle, volume management, session config, user setup all share variables in one script
3. **Untestable** — can't test image validation without also running container creation
4. **Invisible failures** — `set -e` kills the script with no context; stale detection passes but container is broken
5. **No contracts** — nothing defines what an image must provide, what a volume must contain, what the entrypoint expects

## Target Architecture

```
bin/
  claude-container              ← thin orchestrator (~200 lines)

lib/lifecycle/                  ← container lifecycle (standalone scripts)
  cc-image-validate
  cc-container-check
  cc-container-create
  cc-container-remove
  cc-token-inject

lib/session/                    ← session management (standalone scripts)
  cc-session-create
  cc-session-discover
  cc-session-config
  cc-session-add-repo

lib/sync/                       ← sync system (already mostly standalone)
  cc-snapshot                   ← snapshot_session_state
  cc-classify                   ← classify_repo_sync_state
  cc-diff                       ← snapshot_diff
  cc-extract                    ← session_extract / _extract_multi_project_direct
  cc-merge                      ← session_auto_merge / detect_repo_merge_status

lib/container/                  ← inside-container scripts
  cc-entrypoint                 ← entrypoint.sh (already standalone)
  cc-agent-run                  ← agent-run.sh (already standalone)
```

## Script Contract Format

Every standalone script follows this contract:

```bash
#!/usr/bin/env bash
# cc-<name> — <one-line description>
#
# INPUTS:
#   $1 - <arg description>
#   $2 - <arg description>
#   --flag - <flag description>
#   stdin: <what it reads, if anything>
#
# OUTPUTS:
#   stdout: <what it writes>
#   exit 0: <what success means>
#   exit 1: <what failure means>
#
# READS:
#   <files/volumes/docker state it reads>
#
# WRITES:
#   <files/volumes/docker state it creates or modifies>
#
# DESTROYS:
#   <what it can delete — MUST be listed>
#   NEVER destroys anything without --force or interactive confirmation
```

## Dependency DAG

```
ARCH-2 (contracts + shared lib)
    │
    ├──→ ARCH-3 (lifecycle scripts)     ──┐
    ├──→ ARCH-4 (session scripts)       ──┤
    ├──→ ARCH-5 (entrypoint rewrite)    ──┼──→ ARCH-7 (orchestrator rewrite)
    └──→ ARCH-6 (sync scripts)          ──┘
                                               │
                                               └──→ ARCH-8 (subcommand rewiring)
```

ARCH-3 through ARCH-6 are parallelizable (all depend only on ARCH-2).
ARCH-7 depends on all of them. ARCH-8 depends on ARCH-7.

## Tickets

- ARCH-1 — this overview
- ARCH-2 — contracts library + shared utilities
- ARCH-3 — lifecycle scripts (image, container, token)
- ARCH-4 — session scripts (create, discover, config, add-repo)
- ARCH-5 — entrypoint rewrite (clean separation of root vs developer phases)
- ARCH-6 — sync scripts (snapshot, classify, diff, extract, merge)
- ARCH-7 — orchestrator rewrite (thin claude-container)
- ARCH-8 — subcommand rewiring (pull, push, sync, session, repos, watch)
