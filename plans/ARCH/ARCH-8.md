# ARCH-8: Subcommand Rewiring

blocked_by: [ARCH-7]
unlocks: []

## Goal

Rewrite subcommands (pull, push, sync, session, repos, watch, status) to call standalone scripts instead of sourcing monolith functions. Each subcommand becomes a thin script that orchestrates the sync/lifecycle scripts.

## Example: `cmd_pull` rewrite

```bash
# Before: 350 lines with inline docker runs, git ops, report rendering
cmd_pull() {
    snapshot_session_state ...
    session_extract ...
    session_auto_merge ...
    _pull_report ...
}

# After: ~50 lines calling standalone scripts
cmd_pull() {
    local result_dir=$(mktemp -d)

    cc-snapshot "$volume" "$session" "$branch" "$result_dir" --repo "$filter"

    if ! $dry_run; then
        cc-extract "$session" --repo "$filter" --result-dir "$result_dir" --quiet
    fi

    if [[ -n "$branch" ]]; then
        cc-merge "$session" "$branch" --dry-run --repo "$filter" --result-dir "$result_dir"
    fi

    cc-pull-report "$session" "$branch" "$result_dir" "$filter"

    if $verify && has_mergeable "$result_dir"; then
        cc_confirm "Merge into '$branch'?" || return 0
        cc-merge "$session" "$branch" --repo "$filter" --result-dir "$result_dir"
        cc-pull-report "$session" "$branch" "$result_dir" "$filter"
    fi
}
```

## Subcommands to Rewrite

| Command | Current size | Target size | Calls |
|---------|-------------|-------------|-------|
| pull | 350 lines | ~80 lines | cc-snapshot, cc-extract, cc-merge, cc-pull-report |
| push | 240 lines | ~60 lines | cc-snapshot, cc-push-preview, cc-merge-into |
| sync | 120 lines | ~40 lines | cc-snapshot, cc-classify, cc-extract, cc-merge, cc-merge-into |
| session | 330 lines | ~100 lines | cc-session-config, cc-snapshot, cc-diff |
| repos | 480 lines | ~80 lines | cc-session-add-repo, cc-snapshot |
| status | 420 lines | ~60 lines | cc-snapshot, cc-classify |
| watch | 160 lines | ~80 lines | cc-snapshot (polling), delegates to command |

## Report Rendering

Reports stay as functions (not scripts) since they're pure rendering with no side effects. Move to `lib/render/`:

```
lib/render/
  pull-report.sh     ← _pull_report()
  push-report.sh     ← _push_report(), _push_preview()
  sync-plan.sh       ← show_sync_plan()
  diff-report.sh     ← used by session diff
```

## Acceptance Criteria

1. Each subcommand under 100 lines
2. No direct docker/git calls in subcommands
3. All state reading goes through cc-snapshot
4. All state writing goes through cc-extract/cc-merge/cc-merge-into
5. Report rendering is pure (reads result dir, writes to stdout)
6. Existing tests pass (if any apply)

## Files

| File | Replaces |
|------|----------|
| `lib/commands/pull/cmd.sh` | rewrite |
| `lib/commands/push/cmd.sh` | rewrite |
| `lib/commands/sync/cmd.sh` | rewrite |
| `lib/commands/session.sh` | rewrite |
| `lib/commands/repos.sh` | rewrite |
| `lib/commands/status.sh` | rewrite |
| `lib/commands/watch.sh` | minor update |
| `lib/render/*.sh` | new (extracted from report functions) |
