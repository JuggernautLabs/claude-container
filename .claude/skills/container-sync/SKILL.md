---
name: container-sync
description: Sync a claude-container session with upstream changes. Use when the user wants to rebase their session work onto an updated branch, pull in upstream changes, or resolve merge conflicts. Handles long-running sessions where main/develop has been updated.
argument-hint: <session-name> [branch]
allowed-tools:
  - AskUserQuestion
  - Bash
  - Read
  - Glob
---

# Container Sync Skill

You are helping the user sync their claude-container session with upstream changes. This is useful for long-running sessions where the original branch (main, develop, etc.) has been updated.

## What `push --rebase` Does

The `push <branch> --rebase` command:

1. **Mounts original repos** read-only as `upstream` remote
2. **Checks for uncommitted changes** (skips rebase if dirty, warns user)
3. **Fetches** the target branch from upstream
4. **Rebases** session work onto the updated branch
5. **Reports** conflicts (if any) for Claude to resolve
6. **Starts** the container for interactive conflict resolution

After resolving conflicts and exiting, the user should pull with `--force`.

## Step 1: Identify Session and Branch

If not provided as arguments, ask the user:

### Session Name
- Which session to sync
- Use `claude-container --sessions` to list available sessions

### Target Branch
- Which branch to rebase onto (default: `main`)
- Common choices: `main`, `master`, `develop`

## Step 2: Check Prerequisites

Before running sync, verify:

```bash
# Check session exists
docker volume inspect claude-session-<name> >/dev/null 2>&1

# Check yq is available (required for multi-project)
command -v yq >/dev/null 2>&1
```

## Step 3: Run Push with Rebase

Execute the push command:

```bash
claude-container push -s <session-name> <branch> --rebase
```

This will output something like:

```
→ Syncing session 'my-feature' with branch 'main'...

  → Syncing project-a...
✓   project-a rebased successfully
  → Syncing project-b...
⚠   project-b has conflicts (Claude will resolve)
  → Syncing project-c...
⚠   project-c has uncommitted changes (will need manual commit/stash)
      ?? newfile.txt
      M  modified.txt

1 project(s) have conflicts for Claude to resolve
1 project(s) have uncommitted changes (commit or stash in session)

→ Starting container for review...
```

## Step 4: Conflict Resolution (if needed)

If there are conflicts, the user will need to resolve them inside the container. Provide guidance:

### Finding Conflicts
```bash
# Find files with conflict markers
grep -r "<<<<<<< HEAD" /workspace

# Check git status
cd /workspace/<project>
git status
```

### Resolving Conflicts
1. Edit conflicted files, removing `<<<<<<<`, `=======`, `>>>>>>>` markers
2. Choose the correct code or merge manually
3. Stage resolved files: `git add <files>`
4. Continue rebase: `git rebase --continue`
5. If stuck, abort: `git rebase --abort`

### After Resolution
```bash
# Verify clean state
git status
git log --oneline -5
```

## Step 5: Post-Sync Instructions

After the user exits the container, remind them to pull with `--force`:

```
To update branches with rebased changes:
  claude-container pull -s <session-name> --force
```

The `--force` flag is needed because the branch already exists from previous extraction.

---

# Quick Reference

## Push Commands

```bash
# Fast-forward from host (session branch)
claude-container push -s my-feature

# Rebase onto main
claude-container push -s my-feature main --rebase

# Rebase onto develop
claude-container push -s my-feature develop --rebase

# Merge main into session
claude-container push -s my-feature main --merge
```

## After Sync Workflow

```bash
# 1. Push with rebase
claude-container push -s my-feature main --rebase

# 2. (In container) Resolve any conflicts
#    Claude will help with this

# 3. Exit container
exit

# 4. Pull updated work
claude-container pull -s my-feature --force
```

## Conflict Resolution Inside Container

```bash
# Find conflicts
grep -r "<<<<<<< HEAD" .

# Check status
git status

# After editing, stage and continue
git add .
git rebase --continue

# If something goes wrong
git rebase --abort
```

## Common Scenarios

### Clean Rebase (No Conflicts)
```
✓ project-a rebased successfully
✓ All projects rebased cleanly
```

### With Conflicts
```
⚠ project-a has conflicts (Claude will resolve)
1 project(s) have conflicts for Claude to resolve
```

### Uncommitted Changes
```
⚠ project-a has uncommitted changes (will need manual commit/stash)
      ?? newfile.txt
1 project(s) have uncommitted changes (commit or stash in session)
```
The session starts so you can commit or stash the changes inside the container.

### Branch Not Found
```
⚠ Skipping project-a (branch 'nonexistent' not found)
```

### Original Repo Moved
```
⚠ Skipping project-a (original not found: /old/path)
```

## Troubleshooting

### "Session not found"
The session doesn't exist. Check available sessions:
```bash
claude-container --sessions
```

### "No .claude-projects.yml found"
Single-project sessions aren't yet supported for sync. This feature works with multi-project sessions.

### "yq required"
Install yq for YAML parsing:
```bash
brew install yq          # macOS
sudo apt-get install yq  # Ubuntu/Debian
```

### Rebase stuck mid-way
If a previous sync was interrupted:
```bash
# Inside container
cd /workspace/<project>
git rebase --abort
```
Then try push --rebase again.

## Legacy Command Mapping

| Old | New |
|-----|-----|
| `--sync <branch>` | `push <branch> --rebase` |
| `--refresh [branch]` | `push [branch]` |
| `--merge-into <branch>` | `push <branch> --merge` |
| `--extract --force` | `pull --force` |
