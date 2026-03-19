# UX-1: Main Command UX Overhaul

## Goal

Fix UX issues in the main `claude-container` command: container persistence by default, better repair, mutual exclusion on actions, verify prompt improvements, and deprecated flag cleanup.

## Dependency DAG

```
UX-2 (container persistence)
UX-3 (mutual exclusion on actions)     → UX-6 (deprecated flag removal)
UX-4 (repair improvements)
UX-5 (verify prompt: session-only option)
UX-7 (restart targets session, not all containers)
```

All tickets are independent except UX-6 depends on UX-3.

---

## Tickets

### UX-2: Container persistence by default
**blocked_by:** []
**unlocks:** []

**Problem:** Containers use `--rm` and are destroyed on exit. Every startup rebuilds `/home/developer`, reinstalls settings, recreates the user account, configures sudo, etc. This is ~5-10 seconds of wasted setup on every resume.

**Change:**
- Default behavior: `docker run` without `--rm`. Name container `claude-session-${SESSION_NAME}` (not `claude-dev-$$`).
- On resume: `docker start -ai claude-session-${SESSION_NAME}` if container exists and image matches. Skip all setup.
- If container doesn't exist or image changed: create new container (current flow).
- Add `--ephemeral` flag: behaves like today (`--rm`, PID-named).
- Add `--rebuild` flag: force-remove existing container and create fresh.
- Persist `EPHEMERAL` in session `.env` metadata so it sticks across runs.

**Key design questions:**
- Container state drift: packages installed during session persist. Is this a feature or a bug? (Probably a feature — it's what the user expects.)
- Image updates: if `ghcr.io/hypermemetic/claude-container:latest` is pulled fresh, old container uses old image. `--rebuild` handles this explicitly.
- Multiple concurrent sessions: each gets its own named container. No conflicts.

**Files:** `claude-container` (lines 106-442 flag parsing, 797-800 docker args, 975-1205 entrypoint)

---

### UX-3: Mutual exclusion on action flags
**blocked_by:** []
**unlocks:** [UX-6]

**Problem:** `--delete`, `--restart`, `--repair`, `--import`, `--extract`, `--sync`, `--refresh`, `--merge-into` all set `ACTION` to a string. If you pass two (e.g., `--delete --restart`), the last one wins silently.

**Change:** After each action flag is parsed, check if `ACTION` is already set. If so, error:
```bash
--delete)
    if [[ -n "$ACTION" ]]; then
        error "Cannot combine --delete with --$ACTION"
        exit 1
    fi
    ACTION="delete"
    shift
    ;;
```

Extract this to a helper to avoid repeating the check 8 times:
```bash
_set_action() {
    if [[ -n "$ACTION" ]]; then
        error "Cannot combine --$1 with --$ACTION"
        exit 1
    fi
    ACTION="$1"
}
```

**Files:** `claude-container` (lines 196-255)

---

### UX-4: Repair improvements
**blocked_by:** []
**unlocks:** []

**Problem:** `session_repair` only fixes one specific corruption pattern (path suffix `||...|`). Users invoke `--repair` expecting a general fix-it tool.

**Change:** Expand repair to check and fix:
1. **Path corruption** (existing) — `||suffix|` pattern in config paths
2. **Volume existence** — verify all 5 volumes exist for the session, report missing ones
3. **Config validity** — check `.claude-projects.yml` is valid YAML (via `yq`)
4. **Permission fixup** — run the same `chown` that `--restart` does (currently only restart fixes perms)
5. **Stale container cleanup** — remove any stopped containers for this session
6. **Session metadata** — verify `.env` file exists and is readable

Output a checklist:
```
✓ Session volume exists
✓ Config file valid (3 repos)
✓ Permissions fixed
✗ State volume missing — recreating
✓ No stale containers
```

**Files:** `lib/session-mgmt.sh` (session_repair, lines ~3498-3556)

---

### UX-5: Verify prompt — session-only option
**blocked_by:** []
**unlocks:** []

**Problem:** When `pull --verify` shows the merge preview and asks `[y/N]`, there's no way to say "extract session branches but skip the merge." `N` aborts entirely but actually does leave session branches extracted — the messaging is confusing.

**Change:** When pulling into a non-session branch (i.e., `$branch` is set), change the prompt to:
```
Merge into 'main'? [(s)ession only / y / N]
```

- `y` / `Y` / `yes` — merge as before
- `s` / `S` — skip merge, keep extracted session branches, print clear message: "Session branches extracted. To merge later: ..."
- `N` / anything else — abort (same as today)

The `s` option is only shown when there's a target branch (the "session only" concept doesn't apply to extract-only pulls).

Update both prompt locations:
1. `lib/commands/pull/cmd.sh` line 233
2. `lib/commands/pull/reconcile.sh` line 319
3. `claude-container` main script line 1315 (post-exit merge prompt)

**Files:** `lib/commands/pull/cmd.sh`, `lib/commands/pull/reconcile.sh`, `claude-container`

---

### UX-6: Remove deprecated flags
**blocked_by:** [UX-3]
**unlocks:** []

**Problem:** Five deprecated flags (`--extract`, `--sync`, `--refresh`, `--merge-into`, `--sessions`) still work with warnings. They add clutter to the help text and case statement.

**Change:**
- Remove the deprecated flags from the case statement
- They'll now hit the `*)` unknown-option handler and error cleanly
- Update help text to remove the "Deprecated" section
- Keep the subcommand equivalents documented in help

**Risk:** Users with muscle memory or scripts using old flags will break. Acceptable since the warnings have been in place.

**Files:** `claude-container` (lines 196-234, 270-273, 322-434 help text)

---

### UX-7: Restart targets session, not all containers
**blocked_by:** []
**unlocks:** []

**Problem:** `session_restart` runs `docker ps -q --filter "name=claude-dev-"` which matches ALL running claude containers, then stops them all. Should only stop the container for the target session.

**Change (depends on UX-2):**
- If UX-2 is done (named containers): `docker stop claude-session-${session}` directly.
- If UX-2 is not done: filter by volume mount: `docker ps -q --filter "volume=claude-session-${session}"`.

**Files:** `lib/session-mgmt.sh` (session_restart, lines 466-471)
