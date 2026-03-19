# Unified Session Snapshot

## Problem

Container state reading was scattered across 12+ separate `docker run` invocations, each with slightly different logic. Every command (pull, push, status, watch, reconcile) independently:

1. Ran its own docker container to scan `/session/*/` for git HEADs
2. Performed its own git comparisons (ancestry, squash detection, tree diffs)
3. Rendered results immediately with inline data

This caused three classes of bugs:

- **Lying reports**: "extracted" when extraction silently failed, "up to date" when the container had new work, "2 ready" followed by "Nothing to merge"
- **Hidden repos**: repos that should be visible were filtered out by inconsistent logic
- **Squash blindness**: every `git diff` used raw `session..target` ranges, double-counting content that was already squash-merged

Root cause: data collection, analysis, and rendering were tangled together in every command. There was no shared data layer.

## Solution

### `snapshot_session_state()` — one function, one docker run

**File**: `lib/session-discovery.sh`

```
snapshot_session_state <volume> <session_name> <target_branch> <output_dir> [repo_filter]
```

One docker run reads ALL container state:

```
name | container_head | dirty_count | merging | git_size_mb
```

Then local git ops (no docker, fast) compute per-repo:

| Key | Source | What it means |
|-----|--------|---------------|
| `container_head` | docker scan | Container's current HEAD |
| `dirty_count` | docker scan | Uncommitted files in container |
| `merging` | docker scan | MERGE_HEAD present |
| `git_size_mb` | docker scan | .git directory size |
| `session_head` | local git | Host session branch HEAD |
| `target_head` | local git | Host target branch HEAD |
| `squash_base` | local git | `refs/claude-container/squash-base/{session}` |
| `host_dirty` | local git | Host repo has uncommitted changes |
| `container_known` | local git | Container HEAD exists in host repo |
| `container_in_target` | local git | Container HEAD is ancestor of or tree-identical to target |
| `external_ahead` | local git | Non-squash commits on target ahead of session |
| `extract_enabled` | config | `false` if `extract: false` in `.claude-projects.yml` |
| `pre_status` | local git | `ahead`, `up_to_date`, `rebased`, `not_extracted` |
| `pre_new_commits` | local git | Count of container commits not on session branch |
| `host_path` | config | Resolved host filesystem path |

All written to the result dir via `_pull_result_set()`. Downstream functions read with `_pull_result_get()` — zero docker calls, zero git calls.

### `snapshot_diff()` — squash-aware diffing

**File**: `lib/session-discovery.sh`

```
snapshot_diff <result_dir> <repo_name> <direction> <format>
```

Every session-vs-target diff in the codebase now goes through this function. It reads `squash_base`, `session_head`, and `target_head` from the snapshot, then:

- **With squash-base** (valid ancestor of session): diffs from `squash_base` to session for outbound, showing only new work since last sync. Raw `target..session` would double-count content that was already squash-merged.
- **Without squash-base**: falls back to direct tree comparison `target..session`.

Directions:
- `outbound` — what session would change on target (session→target)
- `inbound` — what target has that session doesn't (target→session)

Formats: `stat`, `summary` (last line), `names`, `count`, `full`

### `container_in_target` — pre-merge classification

The snapshot computes whether the container's new work is already in the target branch (ancestor check + tree identity). Consumers use this to avoid false "ready to merge" counts when extraction landed commits that were already squash-merged into target.

### `extract_enabled` — config-driven extraction flag

The snapshot reads `extract: false` from `.claude-projects.yml` via `parse_session_projects_full()`. All consumers (report, status, preview) can check this to properly classify discovered repos without waiting for the extraction phase to set `extract_status=discovered`.

## Data flow

```
snapshot_session_state()          ← ONE docker run + local git ops
  writes per-repo keys to result_dir
        │
        ├─ session_extract()      ← reads snapshot for HEAD comparison
        │   appends: extract_status, extract_commits, extract_files
        │
        ├─ detect_repo_merge_status()  ← unchanged, still does real git ops
        │   appends: merge_status, merge_detail, conflict_files
        │
        ├─ snapshot_diff()        ← reads snapshot for squash-aware base
        │   returns diff output on stdout
        │
        └─ render functions       ← PURE: read snapshot + results only
            _pull_report(), _pull_status(), _verify_diffstat(),
            _push_preview(), _push_report(), etc.
```

## Bugs fixed

### 1. Silent extraction failure (`git bundle create <SHA>`)

**File**: `lib/session-mgmt.sh`, bundle creation in `_extract_multi_project_direct()`

`git bundle create file.bundle <SHA>` silently produces an empty bundle because git requires a ref name, not a bare hash. Changed to `git bundle create file.bundle HEAD` after checking out the target ref. This was causing repos with new container commits to never get extracted — the report said "extracted" but nothing happened.

### 2. "N ready" / "Nothing to merge" contradiction

**File**: `lib/commands/pull/report.sh`

The report counted repos with `pre_new_commits > 0` as "ready" even when `merge_detail` said "already up to date". The verify logic only counts repos with actual merge operations (squash-merge, fast-forward). Fixed: "up to date" merge results increment `_unchanged`, not `_ready`. Informational lines still show (with hashes) but don't inflate the ready count.

### 3. `detect_pre_extract_status()` removed

**File**: `lib/merge-detect.sh` (deleted function, 80 lines)

This function duplicated the container-vs-session comparison that `snapshot_session_state` now does. It was called per-repo with its own git ops. Absorbed into the snapshot — same keys (`pre_status`, `pre_new_commits`, `container_head`, `pre_session_head`, `pre_target_head`) are now set by the unified function.

### 4. `set -e` interaction with `while read` EOF

**File**: `lib/session-discovery.sh`

The main script uses `set -e`. The `while read` loop in `snapshot_session_state` exits with return code 1 at EOF, which under `set -e` propagated as a function failure, causing `_pull_status` to exit silently. Fixed with `|| true` on the `done <<< "$_container_scan"` line.

### 5. Inline squash detection scattered across 6 files

Every file that needed to know "are the ahead commits just our squash-merges?" had its own inline loop:

```bash
while IFS= read -r _line; do
    echo "$_line" | grep -qE "^[0-9a-f]+ ${session_name} → " || _external=true
done <<< "$(git log --oneline session..target)"
```

All replaced with reading `external_ahead` from the snapshot, computed once by `count_external_ahead()` during snapshot creation.

## Files modified

| File | Changes |
|------|---------|
| `lib/session-discovery.sh` | +`snapshot_session_state()`, +`snapshot_diff()` |
| `lib/merge-detect.sh` | -`detect_pre_extract_status()` (deleted) |
| `lib/session-mgmt.sh` | Bundle fix (`HEAD` not SHA), Phase 1 uses snapshot |
| `lib/commands/pull/cmd.sh` | Snapshot replaces pre-extraction HEAD capture |
| `lib/commands/pull/report.sh` | Pure render from snapshot, fixed ready/unchanged counting |
| `lib/commands/pull/preview.sh` | `_pull_status` + `_verify_diffstat` use snapshot |
| `lib/commands/pull/prompt.sh` | Reads `external_ahead` + uses `snapshot_diff` |
| `lib/commands/pull/reconcile.sh` | Uses snapshot for merge/dirty scan + `snapshot_diff` |
| `lib/commands/push/cmd.sh` | Unchanged (delegates to preview/report) |
| `lib/commands/push/preview.sh` | Uses snapshot for merge/dirty/ancestry |
| `lib/commands/push/report.sh` | Uses snapshot for post-merge HEADs |
| `lib/commands/push/prompt.sh` | Uses snapshot + `snapshot_diff` |
| `lib/commands/status.sh` | Uses snapshot for `_status_check` + `_status_verify` |
| `lib/commands/watch.sh` | Unchanged (lightweight polling, no full snapshot) |

## Intentionally unchanged

- **`watch.sh`**: Polls `get_session_heads()` every N seconds. A full snapshot would be too heavy for polling. The watch detects HEAD changes, then delegates to pull which does the snapshot.
- **`session_merge_into()` Phases 3-4**: Write operations (ancestry check + merge inside container). These must run inside docker — they modify the session volume.
- **`_extract_multi_project_direct()` Phase 2**: Has its own docker run for HEAD+size that also handles `--at` commitish and bundling optimization. Kept separate because extraction needs to compare before/after, not just read current state.
- **Extraction diffs in `session-mgmt.sh`**: Seven `git diff old_head..new_head` calls that show what extraction changed (before vs after). These compare the old session branch HEAD to the new one — a different concern from session-vs-target diffs. Correct as-is.
