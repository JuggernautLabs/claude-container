# SYNC-6: Watch + Auto-Sync with Divergence Policy

blocked_by: [SYNC-2, SYNC-3, SYNC-4, SYNC-5]
unlocks: []

## Problem

The ideal workflow is continuous sync: watch detects changes, sync runs automatically, both sides stay in lockstep. But today, watch only detects container HEAD changes — it doesn't detect host changes. And when sync encounters diverged repos, it needs user input, which breaks automation.

## Goal

```bash
# Continuous bidirectional sync
claude-container watch -s myproj --sync main

# Same but only specific repos
claude-container watch -s myproj --sync main --repo gamma
```

This watches both container AND host for changes, runs sync automatically, and handles divergence according to a policy.

## Divergence Policy

When both sides changed and automation can't prompt:

| Policy | Flag | Behavior |
|--------|------|----------|
| **pause** (default) | `--on-diverge pause` | Stop syncing the diverged repo, warn, keep syncing others |
| **merge** | `--on-diverge merge` | Auto-reconcile: merge host into container, pull back. Launch container if conflicts. |
| **container** | `--on-diverge container` | Container wins: force-extract, overwrite host |
| **host** | `--on-diverge host` | Host wins: force-push, overwrite container |

## Implementation

### Phase 1: Bidirectional watch

Current `watch.sh` only polls container HEADs via `get_session_heads`. Extend to also check host branch HEADs:

```bash
# Container change detection (existing)
_container_heads=$(get_session_heads "$volume")

# Host change detection (new)
for repo in config_repos; do
    _host_head=$(git -C "$path" rev-parse "$target_branch" 2>/dev/null)
    if [[ "$_host_head" != "${_prev_host_heads[$repo]}" ]]; then
        _changed=true
    fi
done
```

### Phase 2: `--sync` flag on watch

When `--sync <branch>` is passed to watch, instead of running a user command on change, run `sync --no-verify` internally:

```bash
if [[ -n "$sync_branch" ]]; then
    cmd_sync --session "$session_name" "$sync_branch" --no-verify --repo "$repo_filter"
else
    _watch_run_cmd "${user_cmd[@]}" || true
fi
```

### Phase 3: Divergence policy

Pass `--on-diverge` to sync. In `classify_repo_sync_state`, when state is `diverged`:
- `pause`: set `sync_action=skip` with detail "diverged (paused)"
- `merge`: set `sync_action=reconcile` (existing path)
- `container`: set `sync_action=force_pull`
- `host`: set `sync_action=force_push`

Add `force_pull` and `force_push` actions to `execute_sync`.

## Files

| File | Changes |
|------|---------|
| `lib/commands/watch.sh` | Host change detection, `--sync` flag |
| `lib/commands/sync/cmd.sh` | `--on-diverge` flag |
| `lib/commands/sync/classify.sh` | Divergence policy handling |
| `lib/commands/sync/execute.sh` | `force_pull`, `force_push` actions |

## Edge Cases

- Watch interval vs sync duration: if sync takes longer than the watch interval, queue the next check rather than running concurrent syncs
- Container restart during sync: the running container guard (SYNC-4) must handle this
- Rapid changes: debounce host changes (multiple file saves in quick succession should trigger one sync, not many)
