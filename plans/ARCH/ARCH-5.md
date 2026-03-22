# ARCH-5: Entrypoint Rewrite

blocked_by: [ARCH-2]
unlocks: [ARCH-7]

## Goal

Clean separation of the entrypoint into phases with clear responsibilities. The current entrypoint mixes root setup, user creation, config writing, ownership fixing, CLAUDE.md injection, and agent launch into one linear script with no error recovery.

## Current Problems

1. Config files written as root, then chowned to developer — fragile, slow on large dirs
2. `.claude.json` was in container filesystem (not volume) — lost on rebuild
3. No separation between "must be root" and "must be developer" operations
4. set -e kills the script with no context when anything fails
5. Heredocs break when passed through `su -c`

## Target Structure

```bash
# Phase 1: Root Setup (must be root)
_phase_root_setup() {
    # Token validation
    # Locale check
    # User creation (groupadd, useradd)
    # Sudo setup (if rootish)
    # Docker socket permissions
    # Install fin command
}

# Phase 2: Config Setup (runs as developer via gosu)
# This is a SEPARATE script so heredocs work and all files are created as developer
_phase_developer_config() {
    # .claude.json (merge into volume, symlink)
    # settings.json (statusline)
    # .gitconfig copy
    # CLAUDE.md injection
    # Working directory resolution
}

# Phase 3: Launch (exec, never returns)
_phase_launch() {
    # Build claude args
    # Check for initial prompt (.merge-into-summary, .sync-summary)
    # exec gosu developer agent-run ...
}
```

## Key Design Decisions

### Developer config as a separate script

Instead of `su developer -c "big heredoc"` (breaks), write a script to `/tmp/cc-developer-setup.sh` and run it via `gosu developer /tmp/cc-developer-setup.sh`. The script has full bash with heredocs, functions, etc.

### .claude.json in volume

- Lives at `/home/developer/.claude/.claude.json` (inside state volume)
- Symlinked from `/home/developer/.claude.json`
- Merge-on-write: reads existing, adds trust entries, writes back
- Survives container rebuilds

### Ownership guarantee

All files under `/home/developer/` that the developer needs to write are either:
- Created by the developer (via the gosu'd setup script), or
- Top-level volume mount points (owned by docker volume system)

Zero chown calls needed.

## Files

| File | Purpose |
|------|---------|
| `lib/container/cc-entrypoint` | Main entrypoint (replaces entrypoint.sh) |
| `lib/container/cc-developer-setup` | Config setup script (runs as developer) |
| `lib/container/cc-agent-run` | Agent wrapper (replaces agent-run.sh) |

## Acceptance Criteria

1. Zero chown calls in entrypoint
2. .claude.json survives container rebuild
3. Config setup works with heredocs (separate script, not su -c)
4. Each phase can fail independently with a clear error
5. set -e replaced with explicit error handling per-phase
