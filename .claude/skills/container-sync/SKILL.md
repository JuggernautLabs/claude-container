---
name: container-sync
description: Sync a claude-container session with upstream changes. Use when the user wants to pull session work to host, push host changes into a session, watch for live changes, serve branches to agents, reconcile multiple sessions, or resolve merge conflicts.
argument-hint: <session-name> [branch]
allowed-tools:
  - AskUserQuestion
  - Bash
  - Read
  - Glob
---

# Container Sync Skill

You are helping the user sync their claude-container session. This covers all bidirectional data flow between host and container.

## Pull: Container → Host

Pull session changes to host, optionally merge into a target branch.

```bash
claude-container pull -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| `--repo <name>` | Only pull this repo (partial name OK: `gamma` matches `org/gamma`) |
| `--squash` | Squash-merge into target (default). Tracks prior squashes for clean repeats. |
| `--no-squash` | Regular merge. Preserves full session commit history on target. |
| `--verify` | Extract and show results, ask before merging. Works with `--reconcile` too. |
| `--status` | Read-only: compare container vs host without extracting |
| `--dry-run` | Preview without extracting or merging |
| `--reconcile, -R` | Full cycle: stash dirty → merge target into session → Claude resolves → merge back |
| `--force, -f` | Force extraction if branches diverged (container wins) |

### Key behaviors
- **No branch**: extract session branches to host only
- **With branch**: extract + auto-merge. Auto-force-extracts (session branch is just transport; main is protected by conflict detection)
- **Squash-merge tracking**: saves `refs/claude-container/squash-base/<session>` after squash. Repeat pulls only cherry-pick NEW commits since last squash.
- **Stale squash-base detection**: if squash-base is on a different lineage (e.g. after force-extract), automatically clears it
- **`--verify`**: extracts, shows report + dry-run merge, prompts `Merge into 'main'? [y/N]` before proceeding. Also works with `--reconcile`.

### Output format
```
  org/repo  container:abc1234  session:abc1234  main:def5678
    extract:  ✓ updated (3 commits, 5 files)
    merge:    ✓ session → main: squash-merged into main (3 new)
```

### Commit messages on target
- Single commit squashed: uses original session commit message
- Multiple commits: `session → main (N commits)` header with listed messages

## Push: Host → Container

Push host changes into a container session.

```bash
claude-container push -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| `--repo <name>[,<branch>]` | Only push this repo, optionally from specific branch |
| `--as <branch>` | Don't merge — place host branch as a named ref in container |
| `--ff` | Fast-forward from host branch (default) |
| `--merge` | Merge host branch into session (launches container if conflicts) |
| `--rebase` | Rebase session onto host branch (launches container if conflicts) |
| `--force, -f` | Force reset diverged repos to host HEAD |

### Strategies
- **`--ff`** (default): Fetch + fast-forward. If diverged, shows options.
- **`--merge`**: Merge target INTO session. Claude resolves conflicts in container.
- **`--rebase`**: Rebase session onto target. Claude resolves conflicts.
- **`--as <branch>`**: No merge — places host branch in container. Agent merges when ready:
  ```bash
  claude-container push -s myproj main --as host/main
  # Agent inside container: git merge host/main
  ```

## Watch: Trigger Commands on Session Changes

Poll session for new commits and run a command when detected.

```bash
claude-container watch -s <session> [options] -- <command...>
```

| Flag | Description |
|------|-------------|
| `--repo <name>` | Only watch this repo |
| `--interval, -i <secs>` | Poll interval (default: 5) |

- Runs command once on startup
- Coalesces rapid changes (re-runs once after command finishes, not per-change)
- Polls `get_session_heads` (single docker run per check)

```bash
# Auto-pull on every container commit
claude-container watch -s myproj -- claude-container pull -s myproj main

# Watch one repo, fast polling
claude-container watch -s myproj --repo gamma -i 2 -- claude-container pull -s myproj

# Chain with build
claude-container watch -s myproj --repo gamma -- sh -c \
  'claude-container pull -s myproj && cd ~/dev/proj && bun run build'

# Serve host branch to agent whenever local changes
claude-container watch -s myproj -- claude-container push -s myproj main --as host/main
```

## Reconcile: Full Conflict Resolution Cycle

```bash
claude-container pull -s <session> <branch> --reconcile [--verify]
```

1. **Extract** session branches to host
2. **Stash** dirty host worktrees
3. **Merge** target INTO session (batched — 4 docker runs total regardless of repo count)
4. If clean: extract + auto-merge back into target
5. If conflicts: launch container with Claude for resolution, Claude uses `fin` when done
6. With `--verify`: pauses before final merge into target, asks for confirmation

### Batched merge (session_merge_into)
- Phase 1: Single docker run scans all repos for dirty/merge status
- Phase 2: Host-side classification (no docker)
- Phase 3: Single docker run checks ancestry for all candidates
- Phase 4: Single docker run merges all repos (mounts all host repos simultaneously)
- Phase 5: Single docker run writes marker files
- ALL repos with conflicts/dirty get host-mounted for Claude's resolution container

## Multi-Session Reconcile

Merge multiple sessions into a unified branch, sequentially.

```bash
claude-container reconcile <branch> [session...] [options]
```

| Flag | Description |
|------|-------------|
| `--include <regex>` | Only process matching sessions (repeatable) |
| `--exclude <regex>` | Skip matching sessions (repeatable, wins over include) |
| `--dry-run` | Preview without merging |
| `--yes, -y` | Skip confirmation |
| `--continue` | Resume interrupted reconcile |
| `--force, -f` | Force extraction |

- State persisted to `~/.config/claude-container/.reconcile-plan`
- Omit session names to auto-discover sessions with unmerged work

## Status: Read-Only Check

```bash
claude-container status -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| `--repo <name>` | Filter to single repo |
| `--dirty` | Check host repos for uncommitted changes |

- No branch: sync classification (synced/unchanged/extracted-only/not-extracted)
- With branch: hash comparison with ancestry info
- Exit code: 0 = all match, 1 = mismatch

## Common Workflows

### Standard pull cycle
```bash
claude-container pull -s myproj main              # extract + squash-merge
claude-container pull -s myproj main --verify      # same but confirm before merge
```

### Keep session up to date
```bash
claude-container push -s myproj main               # ff (default)
claude-container push -s myproj main --merge        # merge (Claude resolves)
claude-container push -s myproj main --as host/main # serve (agent merges)
```

### Live development
```bash
# Terminal 1: dev server
cd ~/dev/gamma && bun dev

# Terminal 2: watch + auto-pull
claude-container watch -s myproj --repo gamma -i 2 -- \
  claude-container pull -s myproj main
```

### Resolve conflicts
```bash
# Option A: reconcile (Claude resolves in container)
claude-container pull -s myproj main --reconcile --verify

# Option B: push main into session, then pull clean
claude-container push -s myproj main --merge
claude-container pull -s myproj main
```

## Troubleshooting

### "already up to date" when changes exist
- Check squash-base: `git rev-parse --verify refs/claude-container/squash-base/<session>`
- If stale (different lineage), delete: `git update-ref -d refs/claude-container/squash-base/<session>`
- The code auto-clears stale squash-bases, but manual clearing may be needed for edge cases

### Extraction diverged
- When pulling with a target branch, extraction auto-forces (container wins)
- Without a target branch, use `--force` explicitly

### Session not found
```bash
claude-container list   # check available sessions
```

### yq required
```bash
brew install yq          # macOS
sudo apt-get install yq  # Ubuntu/Debian
```
