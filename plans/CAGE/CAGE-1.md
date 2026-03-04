# CAGE-1: Epic Overview

## Vision

Cage is a three-layer system for running AI coding agents in isolated environments with bidirectional git sync to the host.

**Volumes** hold git repos. **Agents** are CLI binaries conforming to a spec. **Containers** bind volumes to agents in isolated environments. Sessions are the user-facing abstraction that composes all three.

The user interacts with sessions. The internals are volumes, containers, and agents.

## Principles

- Volumes are the primary data objects. All git sync is volume-level.
- Agents are swappable. Any CLI matching the spec works.
- Containers are persistent (stop/start, not create/destroy).
- Host branches are never left dirty. Conflict resolution always happens in the cage.
- Shared build caches across sessions. Per-session environment state.
- The `.cage/` directory on the workspace volume is the communication protocol.

## Architecture

```
Host                          Container (persistent)
~/.config/cage/               ┌──────────────────────────┐
  sessions/<name>.yml         │  agent (claude/aider/sh)  │
                              │  installed packages       │
  ┌─────────────┐             │  ~/bin, system config     │
  │ host repos  │◄── sync ──► │  /workspace (volume) ─────┤──► cage-workspace-<name>
  │ ~/dev/...   │             │  /workspace/.cage/ (proto) │
  └─────────────┘             │                            │
                              │  /home/developer/.cargo ───┤──► cage-cargo-cache (shared)
                              │  /home/developer/.npm ─────┤──► cage-npm-cache (shared)
                              │  /home/developer/.cabal ───┤──► cage-cabal-cache (shared)
                              │  /home/developer/.cache/pip┤──► cage-pip-cache (shared)
                              │  /home/developer/go ───────┤──► cage-go-cache (shared)
                              └──────────────────────────┘
```

## Command Surface

```bash
# Session lifecycle
cage -s <name> run [--agent X] [--prompt "..."] [--resume]
cage -s <name> stop
cage -s <name> delete
cage -s <name> info

# Sync
cage -s <name> extract [<branch>]        # session → host
cage -s <name> inject <branch>           # host → session (ff)
cage -s <name> inject <branch> --rebase  # rebase onto host branch
cage -s <name> inject <branch> --merge   # merge host branch in
cage -s <name> land <branch>             # safe merge: inject + resolve + ff
cage -s <name> diff [<branch>]           # compare

# Global
cage list
cage agent list
```

## Dependency DAG

```
Phase 1 (parallel, no deps):
  CAGE-2 (Agent CLI spec)
  CAGE-3 (Volume primitives)

Phase 2 (parallel, fan-out):
  CAGE-4 (Container primitives)    ← blocked_by: [CAGE-3]
  CAGE-8 (Communication protocol)  ← blocked_by: [CAGE-2]

Phase 3 (parallel, fan-out):
  CAGE-5 (High-level commands)     ← blocked_by: [CAGE-3, CAGE-4, CAGE-8]
  CAGE-6 (cage-agent-claude)       ← blocked_by: [CAGE-2, CAGE-8]

Phase 4:
  CAGE-7 (Migration from cc)       ← blocked_by: [CAGE-3, CAGE-4, CAGE-6]
```

```
CAGE-2 ──► CAGE-8 ──► CAGE-5
  │                      ▲
  └──► CAGE-6            │
         │               │
CAGE-3 ──► CAGE-4 ──────┘
  │                    │
  └────────────────────┴──► CAGE-7
```

## Tickets

| Ticket | Title | Phase | Blocked By |
|--------|-------|-------|------------|
| CAGE-2 | Agent CLI interface spec | 1 | — |
| CAGE-3 | Volume primitives | 1 | — |
| CAGE-4 | Container primitives | 2 | CAGE-3 |
| CAGE-5 | High-level session commands | 3 | CAGE-3, CAGE-4, CAGE-8 |
| CAGE-6 | cage-agent-claude wrapper | 3 | CAGE-2, CAGE-8 |
| CAGE-7 | Migration from claude-container | 4 | CAGE-3, CAGE-4, CAGE-6 |
| CAGE-8 | Communication protocol (.cage/) | 2 | CAGE-2 |

## Open Decisions

- **Implementation language**: Bash (fast to prototype, matches claude-container) vs Rust (better error handling, testability, matches ecosystem). Could also be a hybrid: Rust for the core, shell for agent wrappers.
- **Config format**: YAML (matches existing) vs TOML (simpler, matches Rust ecosystem).
- **Docker API**: Shell out to `docker` CLI vs use Docker API directly (Rust has bollard crate).
