# SYNC-4: Container State Guards

blocked_by: []
unlocks: [SYNC-6]

## Problem

Sync doesn't guard against two container-level states that block operations:

1. **Merge in progress** (`MERGE_HEAD` exists): The container has an unfinished merge. Pushing or reconciling into it would corrupt state. Currently classified as `container_dirty` with a warning, but the warning doesn't tell the user how to fix it.

2. **Running container**: If a container is actively running (Claude is working), sync operations that modify the container volume (push, reconcile) would race with the running session. The `pull --reconcile` path already handles this (stop + replace), but sync doesn't.

## Case Table

| Case | Container | Host | Detection | Sync Action | Status |
|------|-----------|------|-----------|-------------|--------|
| **Container merging** | MERGE_HEAD exists | — | `merging=yes` | warn, skip | this ticket |

## Gap Table

| Gap | Scenario | What happens now | What should happen |
|-----|----------|-----------------|-------------------|
| Reconcile + running container | Diverged repo needs merge but container is active | Falls through to `session_merge_into` which may hit the running container | Should warn/stop like reconcile does |

## Acceptance Criteria

1. Merge-in-progress repos show clear message: "merge in progress — enter container to resolve or abort"
2. When sync needs to modify the container (push or reconcile) and a container is running:
   - With `--verify` (default): ask "Stop running container? [y/N]"
   - With `--no-verify`: skip those repos with a warning
3. After stopping a container for sync, the container can be restarted normally

## Implementation

### Merge-in-progress handling

In `classify_repo_sync_state`, change the `container_dirty` classification for merging repos to include actionable guidance:
```
sync_detail = "merge in progress — run: claude-container -s $session --shell, then git merge --abort or git commit"
```

### Running container guard

In `execute_sync`, before Phase 2 (push) and Phase 3 (reconcile):
1. Check `docker ps -q --filter "name=^claude-session-ctr-${session_name}$"`
2. If running and `verify=true`: prompt to stop
3. If running and `verify=false`: skip push/reconcile repos, warn

## Files

| File | Changes |
|------|---------|
| `lib/commands/sync/classify.sh` | Better merge-in-progress detail |
| `lib/commands/sync/execute.sh` | Running container check before push/reconcile |
| `lib/commands/sync/cmd.sh` | Pass verify flag to execute |
