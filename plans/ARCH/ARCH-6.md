# ARCH-6: Sync Scripts (Snapshot, Classify, Diff, Extract, Merge)

blocked_by: [ARCH-2]
unlocks: [ARCH-7]

## Goal

The sync system is already the cleanest part of the codebase (built during this session). Extract the remaining functions into standalone scripts that can be called independently.

## Scripts

### 1. `lib/sync/cc-snapshot`

```
USAGE: cc-snapshot <volume> <session_name> <target_branch> <output_dir> [--repo <filter>]
READS: Docker volume (one docker run), host git repos
WRITES: result files in output_dir via cc_result_set
DESTROYS: nothing
```

Already exists as `snapshot_session_state()` in session-discovery.sh. Extract to standalone.

### 2. `lib/sync/cc-classify`

```
USAGE: cc-classify <result_dir> <repo_name> <session_name> <target_branch>
READS: result files from snapshot
WRITES: sync_state, sync_action, sync_detail to result dir
DESTROYS: nothing
```

Already exists as `classify_repo_sync_state()` in sync/classify.sh. Make callable standalone.

### 3. `lib/sync/cc-diff`

```
USAGE: cc-diff <result_dir> <repo_name> <direction> <format>
READS: result files from snapshot, host git repos
WRITES: diff output to stdout
DESTROYS: nothing
```

Already exists as `snapshot_diff()` in session-discovery.sh. Extract.

### 4. `lib/sync/cc-extract`

```
USAGE: cc-extract <session_name> [--repo <filter>] [--force] [--quiet] [--result-dir <dir>]
READS: Docker volume, host git repos
WRITES: creates/updates session branches on host repos, result files
DESTROYS: nothing (force-updates branches, but that's the point)
```

Already exists as `session_extract()` / `_extract_multi_project_direct()` in session-mgmt.sh. The largest and most complex extraction logic.

### 5. `lib/sync/cc-merge`

```
USAGE: cc-merge <session_name> <target_branch> [--dry-run] [--repo <filter>] [--squash]
READS: host git repos (session branch, target branch)
WRITES: merges session into target (or dry-run detection)
DESTROYS: modifies target branch (with confirmation in verify mode)
```

Already exists as `session_auto_merge()` / `detect_repo_merge_status()` in session-mgmt.sh + merge-detect.sh.

### 6. `lib/sync/cc-merge-into`

```
USAGE: cc-merge-into <session_name> <target_branch> [--repo <filter>]
READS: host git repos, Docker volume
WRITES: merges host branch INTO container repos (reverse direction)
DESTROYS: modifies container git state (inside volume)
```

Already exists as `session_merge_into()` in session-mgmt.sh.

## Migration Path

These functions already exist and work. The extraction is:
1. Move function to standalone script
2. Add contract header
3. Source `contract.sh` for logging/guards
4. Update callers to call the script instead of the function
5. Keep the function as a thin wrapper during transition

## Acceptance Criteria

1. Each script callable independently from the command line
2. `cc-snapshot` produces identical output to `snapshot_session_state()`
3. `cc-extract` handles all existing extraction cases (bundle, clone, diverged)
4. `cc-merge` handles squash-base, cherry-pick, 3-way merge
5. Zero behavior changes — this is a refactor, not a rewrite

## Files

| File | Extracted from |
|------|---------------|
| `lib/sync/cc-snapshot` | `snapshot_session_state()` in session-discovery.sh |
| `lib/sync/cc-classify` | `classify_repo_sync_state()` in sync/classify.sh |
| `lib/sync/cc-diff` | `snapshot_diff()` in session-discovery.sh |
| `lib/sync/cc-extract` | `session_extract()` + `_extract_multi_project_direct()` |
| `lib/sync/cc-merge` | `session_auto_merge()` + `detect_repo_merge_status()` |
| `lib/sync/cc-merge-into` | `session_merge_into()` |
