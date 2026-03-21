# SYNC-1: Epic Overview — Bidirectional Session Sync

## Goal

One command — `claude-container sync` — that makes host and container identical. It handles all divergence cases, asks the user what to do when ambiguous, and leaves both sides consistent when done.

## Current State

The `sync` command exists on `feat/sync` with classification, plan display, and execution for pull and push paths. Reconcile path delegates to existing `session_merge_into`.

## Case Coverage

| Case | Container | Host | Detection | Sync Action | Status |
|------|-----------|------|-----------|-------------|--------|
| **Identical** | HEAD == main HEAD | same | direct SHA compare | skip | ✓ done |
| **Squash identical** | different SHA | different SHA | `git diff --quiet` shows no content diff | skip | ✓ done |
| **Container ahead (linear)** | commits after main | main is ancestor | `merge-base --is-ancestor` | extract + squash-merge into main | ✓ done |
| **Container ahead (unknown)** | commits not on host | `cat-file` fails | `container_known=false` | extract (bundle) + merge | ✓ done |
| **Host ahead (linear)** | main is ancestor | commits after container | `merge-base --is-ancestor` reverse | ff push into container | ✓ done |
| **Host ahead (squash artifacts)** | ancestor of main | main has squash commits | `external_ahead=0` + content differs | push (real new work after squash) | SYNC-2 |
| **Host ahead (squash only)** | ancestor of main | only squash commits ahead | `external_ahead=0` + `diff --quiet` | skip (squash_identical) | ✓ done |
| **Diverged (true)** | both have unique commits | content differs | neither is ancestor + `diff` not quiet | reconcile: merge main into container, then pull back | SYNC-3 |
| **Diverged (conflict)** | both changed same files | merge fails | `session_merge_into` returns 0 (conflicts) | warn, suggest `pull --reconcile` | SYNC-3 |
| **Container dirty** | uncommitted files | — | `dirty_count > 0` | warn, skip | ✓ done |
| **Container merging** | MERGE_HEAD exists | — | `merging=yes` | warn, skip | SYNC-4 |
| **Host dirty** | — | uncommitted files | `host_dirty=true` | warn, skip | ✓ done |
| **Container only** | repo exists | no host path | `host_path` empty or missing | clone from container | SYNC-5 |
| **Host only** | no repo | repo exists | `container_head` empty | push to container | SYNC-5 |
| **Extract disabled** | exists | exists | `extract_enabled=false` | skip with hint | ✓ done |
| **Rebased** | different SHA | different SHA | not ancestor but `diff --quiet` on session head | classified as squash_identical | ✓ done |

## Gaps

| Gap | Scenario | What happens now | What should happen | Ticket |
|-----|----------|-----------------|-------------------|--------|
| Container only + no host dir | Container created a repo, host path doesn't exist | `clone_from_container` action set but `execute_sync` doesn't implement it | Should extract/clone to inferred host path | SYNC-5 |
| Host only | Host has repo not in container config | `push_to_container` action set but `execute_sync` doesn't implement it | Should `session_add_repo` | SYNC-5 |
| Partial reconcile failure | Some repos reconcile clean, some conflict | All reconcile repos go through `session_merge_into` which operates on ALL repos | Should scope merge-into to filtered repos | SYNC-3 |
| Reconcile + running container | Diverged repo needs merge but container is active | Falls through to `session_merge_into` which may hit the running container | Should warn/stop like reconcile does | SYNC-4 |

## Dependency DAG

```
SYNC-2 (squash edge cases)     ──┐
SYNC-3 (reconcile integration) ──┼──→ SYNC-6 (watch + auto-sync)
SYNC-4 (container state guards) ─┤
SYNC-5 (repo add/clone)         ─┘
```

SYNC-2 through SYNC-5 can be done in parallel. SYNC-6 depends on all of them.

## Tickets

- SYNC-1 — this overview
- SYNC-2 — squash edge cases in push path
- SYNC-3 — reconcile integration with scoped merge-into
- SYNC-4 — container state guards (merging, running container)
- SYNC-5 — container-only and host-only repo handling
- SYNC-6 — watch + auto-sync with divergence policy
