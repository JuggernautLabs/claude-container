---
name: container-setup
description: Interactive setup wizard for claude-container sessions. Use when the user wants to configure and prepare a containerized Claude session. Collects session parameters, validates the configuration, and saves the command for execution after exiting.
argument-hint: [session-name]
allowed-tools:
  - AskUserQuestion
  - Bash
  - Read
  - Write
  - Glob
---

# Container Setup Skill

You are helping the user set up a claude-container session. This is an interactive process that will:

1. Collect configuration preferences
2. Validate and prepare the session with `--no-run`
3. Output the session name and command for the user to run after exiting

## Important Context

- **claude-container** runs Claude Code in an isolated Docker container
- The user is CURRENTLY inside Claude Code, so we cannot start the container from here
- Git-based session isolation is the **default** - every session requires `-s <name>`
- The `--no-run` flag prepares the session without starting the container
- After setup, the user just needs `claude-container -s <name>` to start

## Step 1: Gather Information

Use `AskUserQuestion` to collect the following. If the user provided a session name as an argument, skip that question.

### Required: Session Name
- Should be lowercase, alphanumeric with hyphens
- If name matches an existing git branch, that branch will be cloned

### Optional: Starting Branch
- `--from <branch>` creates session from specific branch

### Required: Repository Source
1. **Current directory** (default)
2. **Discover repos** — `--discover-repos <dir>` finds all git repos
3. **Specific repos** — `-a <path>` (repeatable)
4. **Config file** — `--config .claude-projects.yml`

### Optional: Runtime Mode
1. **Rootish** (default) — passwordless sudo
2. **User mode** — `--as-user`, non-root
3. **Root** — `--as-root`

### Optional: Features
- `--continue` — Continue existing conversation
- `--dirty` — Capture uncommitted host changes as WIP commit
- `--docker` — Mount Docker socket
- `--port <port>` — Expose ports (repeatable, persisted). Formats: `3000` or `8080:80`
- `--dockerfile [path]` — Custom Dockerfile
- `--clone-from <session>` — Clone volumes from existing session

## Step 2: Build and Validate

```bash
claude-container -s <name> [options] --no-run
```

## Step 3: Output

```
Session prepared: <session-name>

To start:
1. Exit Claude Code (type 'exit' or Ctrl+D)
2. Run: claude-container -s <session-name>
```

---

# Quick Reference

## Session Creation

```bash
claude-container -s my-feature                         # current dir
claude-container -s my-feature --from feature-branch   # specific branch
claude-container -s my-feature --discover-repos ~/dev  # auto-discover
claude-container -s my-feature -a ~/dev/app -a ~/dev/lib  # specific repos
claude-container -s my-feature --config .claude-projects.yml  # config file
claude-container -s my-feature --dirty                 # capture uncommitted
claude-container -s new --clone-from old               # clone session
```

## Running Sessions

```bash
claude-container -s my-feature                    # start/resume
claude-container -s my-feature --continue         # continue conversation
claude-container -s my-feature --docker           # with Docker access
claude-container -s my-feature --port 3000        # expose port (persisted)
claude-container -s my-feature --dockerfile       # custom Dockerfile
claude-container -s my-feature --shell            # bash instead of claude
claude-container -s my-feature --bash-exec "cmd"  # run command and exit
claude-container -s my-feature -- -p "prompt"     # pass args to claude
```

## Pulling: Container → Host

```bash
claude-container pull -s X                    # extract only
claude-container pull -s X main               # extract + squash-merge
claude-container pull -s X main --verify      # confirm before merge
claude-container pull -s X main --no-squash   # regular merge (full history)
claude-container pull -s X --status           # read-only check
claude-container pull -s X main --dry-run     # preview
claude-container pull -s X main --reconcile   # full conflict resolution cycle
claude-container pull -s X main --reconcile --verify  # reconcile with confirm
claude-container pull -s X --repo gamma       # single repo
```

## Pushing: Host → Container

```bash
claude-container push -s X main               # fast-forward (default)
claude-container push -s X main --merge       # merge into session (Claude resolves)
claude-container push -s X main --rebase      # rebase session onto main
claude-container push -s X main --as host/main  # serve branch, agent merges
claude-container push -s X --repo api,main    # single repo from specific branch
claude-container push -s X --repo api --force # force-reset diverged repo
```

## Watching: Live Sync

```bash
claude-container watch -s X -- claude-container pull -s X main           # auto-pull
claude-container watch -s X --repo gamma -i 2 -- claude-container pull -s X  # fast poll
claude-container watch -s X -- sh -c 'claude-container pull -s X && bun build'  # chain
claude-container watch -s X -- claude-container push -s X main --as host/main   # serve
```

## Session Management

```bash
claude-container list                         # list sessions
claude-container list --sizes                 # with disk usage
claude-container list --name-only             # names only
claude-container -s X --delete --yes          # delete
claude-container -s 'test-.*' --delete --regex  # pattern delete
claude-container remove -s X --include '*tui*'  # remove repos
claude-container -s X --repair                # fix corrupted config
claude-container -s X --restart               # restart (fix permissions)
claude-container -s X --import ~/.claude      # import session data
claude-container status -s X main             # hash comparison
claude-container status -s X --dirty          # check uncommitted
claude-container image -s X                   # show Docker image
```

## Multi-Session Reconcile

```bash
claude-container reconcile main s1 s2 s3      # merge sessions into main
claude-container reconcile main               # auto-discover
claude-container reconcile main --dry-run     # preview
claude-container reconcile --continue         # resume interrupted
```

## Config File Format

```yaml
version: "1"
main: my-app
dockerfile: ./Dockerfile.dev
projects:
  my-app:
    path: ./my-app
  shared-lib:
    path: ../shared-lib
```

## Command Quick Reference

| Task | Command |
|------|---------|
| Create session | `claude-container -s NAME` |
| From branch | `claude-container -s NAME --from BRANCH` |
| Resume + continue | `claude-container -s NAME --continue` |
| Discover repos | `claude-container -s NAME --discover-repos DIR` |
| Pull + merge | `claude-container pull -s NAME main` |
| Pull + verify | `claude-container pull -s NAME main --verify` |
| Pull + reconcile | `claude-container pull -s NAME main --reconcile` |
| Push (ff) | `claude-container push -s NAME main` |
| Push (merge) | `claude-container push -s NAME main --merge` |
| Push (serve) | `claude-container push -s NAME main --as host/main` |
| Watch + pull | `claude-container watch -s NAME -- claude-container pull -s NAME main` |
| Status | `claude-container status -s NAME main` |
| Delete | `claude-container -s NAME --delete -y` |
| List | `claude-container list` |
| Clone session | `claude-container -s NEW --clone-from OLD` |
| Expose port | `claude-container -s NAME --port 3000` |
| Docker access | `claude-container -s NAME --docker` |
| Custom image | `claude-container -s NAME --dockerfile` |
| Shell only | `claude-container -s NAME --shell` |
| Dirty capture | `claude-container -s NAME --dirty` |
| Remove repos | `claude-container remove -s NAME --include PATTERN` |
| Repair | `claude-container -s NAME --repair` |
| Image info | `claude-container image -s NAME` |
