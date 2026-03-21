# SYNC-2: Squash Edge Cases in Push Path

blocked_by: []
unlocks: [SYNC-6]

## Problem

When the host is "ahead" of the container but the ahead commits are squash-merge artifacts, the sync push path doesn't verify whether the content actually differs. It may ff the container to a commit that has identical content but different history, wasting a docker run.

## Case Table

| Case | Container | Host | Detection | Sync Action | Status |
|------|-----------|------|-----------|-------------|--------|
| **Host ahead (squash artifacts)** | ancestor of main | main has squash commits | `external_ahead=0` + content differs | push (real new work after squash) | this ticket |
| **Host ahead (squash only)** | ancestor of main | only squash commits ahead | `external_ahead=0` + `diff --quiet` | skip (squash_identical) | ✓ done |

## Current Behavior

`classify_repo_sync_state` checks `external_ahead` and `diff --quiet` to distinguish squash-only from squash+new-work. The classification is correct. But `execute_sync` does a blind `session_refresh` for all push repos without checking whether the push will actually work (diverged history may cause ff to fail).

## Acceptance Criteria

1. Push path in `execute_sync` detects ff failure and falls back to `--force` or reports clearly
2. After a squash-merge on host, pushing the squash commit into the container either:
   - Succeeds (if container is ancestor of the squash commit), or
   - Is classified as `squash_identical` and skipped (if content is the same)
3. No false "pushed" messages when the push didn't actually change anything

## Implementation

- In `execute_sync` push phase: capture `session_refresh` exit code
- On failure: re-classify as diverged, or retry with `--force` if the user opts in
- Add `--force` flag handling to sync for this case

## Files

| File | Changes |
|------|---------|
| `lib/commands/sync/execute.sh` | Push error handling |
| `lib/commands/sync/classify.sh` | Possibly refine squash detection |
