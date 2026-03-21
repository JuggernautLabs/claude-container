# SYNC-1: Bidirectional Session Sync

## Goal

One command — `claude-container sync` — that makes host and container identical. It handles all divergence cases, asks the user what to do when ambiguous, and leaves both sides consistent when done.

## Mental Model

```
host main ←──── sync ────→ container HEAD
                 ↕
          always converge
```

`sync` is NOT pull-then-push or push-then-pull. It's a single operation that:
1. Reads both sides (snapshot)
2. Classifies each repo's state
3. Determines the action per repo
4. Asks the user when ambiguous
5. Executes all actions
6. Verifies both sides match

## Per-Repo State Classification

Every repo falls into exactly one of these states:

| State | Container | Host | Action |
|-------|-----------|------|--------|
| `identical` | HEAD == main HEAD | — | Nothing |
| `container_ahead` | Has commits host doesn't | Host is ancestor | Pull: extract + merge |
| `host_ahead` | Is ancestor of host | Host has commits | Push: ff into container |
| `diverged` | Both have unique commits | Neither is ancestor | Reconcile: merge in container, then pull |
| `container_only` | Has repo | No host repo | Clone from container |
| `host_only` | No repo | Has repo | Push into container |
| `container_dirty` | Uncommitted changes | — | Warn, skip (or commit first) |
| `host_dirty` | — | Uncommitted changes | Warn, skip (or stash) |

The `diverged` case is the hard one. This is where squash-merge history creates false divergence — container and host have different commit histories but possibly identical content.

## Squash-Aware Divergence

After a squash-merge, `session..main` shows the squash commit as "ahead" even though the content is identical. `sync` must distinguish:

- **True divergence**: both sides changed different files → needs reconcile
- **Squash artifact**: content is identical but histories differ → nothing to do
- **Partial divergence**: squash happened + new work on one side → only sync the new work

The snapshot already has `container_in_target`, `external_ahead`, and `squash_base` — use these.

## Command Interface

```bash
# Sync all repos
claude-container sync -s myproj main

# Sync specific repos
claude-container sync -s myproj main --repo gamma

# Preview only
claude-container sync -s myproj main --dry-run

# Skip confirmation (automation)
claude-container sync -s myproj main --no-verify

# With watch (detect changes, auto-sync)
claude-container watch -s myproj --repo gamma -- claude-container sync -s myproj main --repo gamma --no-verify
```

## Execution Flow

```
1. snapshot_session_state()         ← one docker run
2. classify_repo_sync_state()      ← per-repo, from snapshot
3. show_sync_plan()                ← render plan, ask user
4. execute_sync()                  ← per action type:
   ├─ identical:       skip
   ├─ container_ahead: session_extract + session_auto_merge
   ├─ host_ahead:      session_refresh (ff into container)
   ├─ diverged:        session_merge_into + session_extract + session_auto_merge
   ├─ container_only:  extract (creates host repo)
   └─ host_only:       session_add_repo (pushes into container)
5. verify_sync()                   ← re-snapshot, confirm both sides match
```

## Key Design Decisions

### 1. Diverged repos need user intent

When both sides changed, `sync` can't guess which side wins. Options:
- **Merge** (default): merge host into container, then pull result back
- **Container wins**: force-extract, overwriting host changes
- **Host wins**: force-push, overwriting container changes

The verify prompt shows the divergence and asks. For automation (watch), a policy flag like `--on-diverge merge|container|host` controls behavior.

### 2. Sync is atomic per-repo, not per-session

Each repo syncs independently. If gamma succeeds but synapse fails, gamma stays synced and synapse gets reported as failed. No all-or-nothing.

### 3. Sync uses existing primitives

No new docker operations. `sync` orchestrates:
- `snapshot_session_state` (read state)
- `snapshot_diff` (show changes)
- `session_extract` (container → host)
- `session_auto_merge` (merge into target)
- `session_refresh` (host → container ff)
- `session_merge_into` (host → container merge)

### 4. Sync report matches the unified UI

Uses `_pull_result_set/get`, `_rule()`, hash lines, `snapshot_diff` — same visual style as pull/push.

## Files

| File | Purpose |
|------|---------|
| `lib/commands/sync/cmd.sh` | Entry point, flag parsing |
| `lib/commands/sync/classify.sh` | Per-repo state classification from snapshot |
| `lib/commands/sync/plan.sh` | Render sync plan, verify prompt |
| `lib/commands/sync/execute.sh` | Execute actions per classification |
| `lib/commands/sync/report.sh` | Post-sync verification report |

## Blocked By

Nothing — all primitives exist from v1.0.

## Unlocks

- Watch + sync for continuous bidirectional sync
- `--on-diverge` policy for fully automated sync
