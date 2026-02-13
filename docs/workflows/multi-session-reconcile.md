# Multi-Session Reconcile

Merge multiple concurrent sessions into a single target branch, sequentially.

## The problem

You have several sessions running in parallel — `feature-auth`, `feature-ui`, `bugfix-api` — each producing commits in their own session branches. Merging them into `main` one at a time with `pull` is tedious, and each merge changes `main`, affecting conflict detection for subsequent sessions.

## The solution

```bash
claude-container reconcile main feature-auth feature-ui bugfix-api
```

Or auto-discover all sessions with unmerged work:

```bash
claude-container reconcile main
```

## What happens

For each session, in order:

1. **Extract** session branches to host repos
2. **Auto-merge** into the target branch
3. If clean: mark done, continue to next session
4. If conflicts: merge target INTO session, launch container for Claude to resolve, then continue after exit

```
reconcile main s1 s2 s3
  │
  ├─ s1: extract → auto-merge → clean ✓
  │
  ├─ s2: extract → auto-merge → CONFLICT
  │   ├─ merge main INTO s2 (inside container)
  │   ├─ Claude resolves conflicts, runs 'fin'
  │   └─ exit handler: extract + merge → continue
  │
  └─ s3: extract → auto-merge → clean ✓ done
```

## Conflict resolution

Conflicts only happen inside containers — never on the host.

When a session would conflict with the target branch:
1. The target is merged INTO the session (inside the container)
2. A container launches for Claude to resolve conflicts
3. Claude resolves and runs `fin "description"`
4. The exit handler extracts the resolved state and merges back
5. Reconcile continues automatically with remaining sessions

## Plan file continuation

State is persisted to `~/.config/claude-container/.reconcile-plan` so reconcile survives process boundaries. When a container launches for conflict resolution, the process is replaced (`exec`). After the container exits, the exit handler detects the plan file and runs `reconcile --continue` to resume.

The plan file format:
```
target=main
force=false
session1|completed
session2|in_container
session3|pending
```

Resume manually after an interruption:
```bash
claude-container reconcile --continue
```

## Filtering sessions

Use `--include` and `--exclude` with regex patterns to filter which sessions are processed:

```bash
# Only feature sessions
claude-container reconcile main --include 'feature-.*'

# Everything except WIP
claude-container reconcile main --exclude 'wip-.*'

# Combine: features but not experimental ones
claude-container reconcile main --include 'feature-' --exclude 'experiment'
```

Both flags are repeatable. Exclude wins when a session matches both.

## Dry run

Preview what would happen without making changes:

```bash
claude-container reconcile main --dry-run
```

Output per session:
- `would merge cleanly` — no conflicts expected
- `would need container resolution (conflicts)` — conflicts detected
- `needs extraction first` — session branches not yet on host

Dry run does not extract, merge, or write a plan file.

## Options

| Flag | Description |
|------|-------------|
| `--include <regex>` | Only process matching sessions (repeatable) |
| `--exclude <regex>` | Skip matching sessions (repeatable, wins over include) |
| `--force, -f` | Force extraction even if branches diverged |
| `--dry-run` | Preview without merging |
| `--yes, -y` | Skip confirmation prompt |
| `--continue` | Resume interrupted reconcile |

## Processing order

Sessions are processed sequentially in the order given. Each merge changes the target branch, so order matters. Control priority by listing sessions explicitly. Auto-discovered sessions are processed in Docker volume listing order.

## Examples

```bash
# Reconcile specific sessions in priority order
claude-container reconcile main feature-auth feature-ui bugfix-api

# Auto-discover and reconcile all sessions
claude-container reconcile main

# Preview
claude-container reconcile main --dry-run

# Skip confirmation
claude-container reconcile main s1 s2 --yes

# Only feature branches, excluding experiments
claude-container reconcile main --include 'feature-' --exclude 'experiment'

# Resume after interruption
claude-container reconcile --continue
```

## When to use what

| Situation | Use |
|-----------|-----|
| One session → one branch | `pull -s X main` |
| One session, conflicts expected | `push -s X main --merge` then `pull -s X main` |
| Multiple sessions → one branch | `reconcile main s1 s2 s3` |
| Multiple sessions, auto-discover | `reconcile main` |
| Check before merging | `reconcile main --dry-run` |
