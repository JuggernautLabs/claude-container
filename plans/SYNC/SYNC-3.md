# SYNC-3: Reconcile Integration with Scoped Merge-Into

blocked_by: []
unlocks: [SYNC-6]

## Problem

When sync finds diverged repos, it calls `session_merge_into` which operates on ALL repos in the session, not just the filtered set. This means `sync --repo gamma` with a diverged gamma triggers a merge-into that also touches every other repo in the container.

Additionally, if the merge has conflicts, `execute_sync` currently just prints a warning and tells the user to run `pull --reconcile` separately. Sync should handle the full reconcile flow inline.

## Case Table

| Case | Container | Host | Detection | Sync Action | Status |
|------|-----------|------|-----------|-------------|--------|
| **Diverged (true)** | both have unique commits | content differs | neither is ancestor + `diff` not quiet | reconcile: merge main into container, then pull back | this ticket |
| **Diverged (conflict)** | both changed same files | merge fails | `session_merge_into` returns 0 (conflicts) | launch container for Claude | this ticket |

## Gap Table

| Gap | Scenario | What happens now | What should happen |
|-----|----------|-----------------|-------------------|
| Partial reconcile failure | Some repos reconcile clean, some conflict | All reconcile repos go through `session_merge_into` which operates on ALL repos | Should scope merge-into to filtered repos |

## Acceptance Criteria

1. `session_merge_into` accepts an optional repo filter and only merges matching repos
2. Sync reconcile path handles clean merges end-to-end (merge into container → extract → merge into host)
3. Sync reconcile path handles conflicts by launching container with Claude (same as `pull --reconcile`)
4. Verify gate shows what Claude will be told before launching
5. Post-reconcile, sync verifies both sides match

## Implementation

### Phase 1: Scoped merge-into

Add `repo_filter` parameter to `session_merge_into()`. In Phase 2 (host-side filtering), skip repos that don't match the filter. In Phase 4 (batch merge), only include matching repos.

### Phase 2: Inline reconcile in sync

In `execute_sync`, when reconcile repos exist:
1. Call `session_merge_into` with the reconcile filter
2. If clean: extract + auto-merge (already implemented)
3. If conflicts: show Claude's prompt (from `.merge-into-summary`), ask user, launch container
4. On container exit: extract + auto-merge + report

### Phase 3: Verify gate

Before launching container, show:
- Which repos have conflicts
- What Claude will be told
- "Launch container for Claude to resolve? [y/N]"

## Files

| File | Changes |
|------|---------|
| `lib/session-mgmt.sh` | `session_merge_into` accepts repo_filter |
| `lib/commands/sync/execute.sh` | Full reconcile flow with container launch |
| `lib/commands/sync/cmd.sh` | Handle container launch exit + post-reconcile verify |
