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
Ask for a session name if not provided.
- Should be lowercase, alphanumeric with hyphens
- Examples: `my-feature`, `bugfix-123`, `refactor-auth`
- **Branch matching**: If the session name matches an existing git branch, that branch will be cloned

### Optional: Starting Branch
Ask if they want to start from a specific branch (adds `--from <branch>` flag).
- Use when the session name doesn't match the branch they want to clone
- Example: `--from feature-xyz` creates session from `feature-xyz` branch

### Required: Repository Source
Ask how they want to specify repositories:

1. **Current directory** (default) - Clone the repo in the current working directory
2. **Discover repos** - Auto-discover all git repos in a parent directory
3. **Specific repos** - Add specific repos with `-a` flag
4. **Config file** - Use an existing `.claude-projects.yml`

### Optional: Runtime Mode
1. **Rootish** (default) - Run with passwordless sudo for package installs
2. **User mode** - Run as non-root developer user
3. **Root** - Run as actual root

### Optional: Continue Conversation
Ask if they want to continue an existing conversation (adds `--continue` flag).

### Optional: Dirty Changes
Ask if they want to capture uncommitted host changes into the session as a WIP commit (adds `--dirty` flag).

### Optional: Docker Access
Ask if they need Docker commands inside the container (adds `--docker` flag).

### Optional: Port Exposure
Ask if they need to expose any ports (e.g., web servers, APIs). Each port adds `--port <port>`.
- `--port 3000` maps port 3000 on both host and container
- `--port 8080:80` maps host 8080 to container 80
- Ports are persisted in session metadata — they stick across re-entries
- Multiple `--port` flags can be stacked

### Optional: Custom Dockerfile
Ask if they want a custom Dockerfile instead of the default image.

## Step 2: Build the Command

Construct the command based on answers:

```bash
claude-container -s <session-name> [options]
```

Options:
- `--from <branch>` - start from specific branch
- `--discover-repos <path>` - repo discovery
- `-a <path>` - add specific repos (repeatable)
- `--config <path>` - config file
- `--as-user` - user mode
- `--continue` - continue conversation
- `--docker` - Docker access
- `--port <port>` - expose port (repeatable)
- `--dirty` - capture uncommitted host changes as a WIP commit
- `--config-only` - generate config file only, don't create session
- `--no-interactive` - exit with error if no token found
- `--no-config` - skip auto-discovery of .claude-projects.yml
- `--dockerfile [path]` - custom Dockerfile

## Step 3: Validate with --no-run

Run with `--no-run` to validate and prepare:

```bash
claude-container -s <name> [options] --no-run
```

This:
- Verifies OAuth token
- Checks Docker availability
- Validates config (if multi-project)
- Creates session volume
- Clones repositories
- Configures git

If validation fails, show the error and help fix it.

## Step 4: Output Session Info

After successful `--no-run`:

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
# Basic (current directory)
claude-container -s my-feature

# Start from specific branch
claude-container -s post-feature --from feature-branch

# Multi-project with discovery
claude-container -s my-feature --discover-repos ~/dev/myproject

# Specific repos
claude-container -s my-feature -a ~/dev/app -a ~/dev/lib

# Config file
claude-container -s my-feature --config .claude-projects.yml

# Capture uncommitted host changes
claude-container -s my-feature --dirty

# Prepare without starting
claude-container -s my-feature --no-run
```

## Running Sessions

```bash
# Start/resume
claude-container -s my-feature

# Continue conversation
claude-container -s my-feature --continue

# With Docker access
claude-container -s my-feature --docker

# Expose ports (persisted across re-entries)
claude-container -s my-feature --port 3000 --port 8080:80

# Custom Dockerfile
claude-container -s my-feature --dockerfile

# Clone an existing session (e.g., to add ports to running work)
claude-container -s new-session --clone-from old-session --port 3000
```

## Pulling Changes to Host

```bash
# Pull (extract) as branch
claude-container pull -s my-feature

# Force overwrite existing branch
claude-container pull -s my-feature --force

# Pull and merge into main
claude-container pull -s my-feature main
```

Output:
```
✓ myproject → branch 'my-feature' (3 commit(s), 7 file(s))

To see changes:  git log main..my-feature
Checkout:        git checkout my-feature
Merge:           git merge my-feature
```

## Pushing Host Changes into Session

For long-running sessions where upstream has changed:

```bash
# Fast-forward from host
claude-container push -s my-feature

# Rebase session onto main
claude-container push -s my-feature main --rebase

# Rebase onto develop
claude-container push -s my-feature develop --rebase
```

Rebase:
- Fetches latest changes from original repos
- Rebases session work onto updated branch
- Claude resolves any conflicts interactively
- After resolving, pull with `--force` to update branches

## Session Management

```bash
# List sessions (fast: names + last opened, sorted by most recent)
claude-container list

# List with disk usage (slower — scans volumes)
claude-container list --sizes

# List names only
claude-container list --name-only

# Delete session
claude-container -s my-feature --delete
claude-container -s my-feature --delete --yes

# Remove repos from session
claude-container remove -s my-feature --include cllient          # remove matching
claude-container remove -s my-feature --include juggernaut --exclude substrate  # combine
claude-container remove -s my-feature --include '*tui*' --dry-run  # preview

# Repair corrupted config
claude-container -s my-feature --repair

# Restart (fix permissions)
claude-container -s my-feature --restart

# Import session data
claude-container -s my-feature --import ~/.claude
```

## Config File Format

```yaml
version: "1"
main: my-app
dockerfile: ./Dockerfile.dev    # Optional: auto-builds when changed
projects:
  my-app:
    path: ./my-app
  shared-lib:
    path: ../shared-lib
  docs:
    path: ../docs
```

## Workflow Summary

```
1. Create:  claude-container -s my-feature
2. Work:    (inside container with Claude)
3. Exit:    exit
4. Pull:    claude-container pull -s my-feature main

Long-running sessions:
1. Push:    claude-container push -s my-feature main --rebase
2. Work:    (Claude resolves conflicts if any)
3. Exit:    exit
4. Pull:    claude-container pull -s my-feature --force
```

## Command Quick Reference

| Task | Command |
|------|---------|
| Create session | `claude-container -s NAME` |
| From specific branch | `claude-container -s NAME --from BRANCH` |
| Resume + continue | `claude-container -s NAME --continue` |
| Discover repos | `claude-container -s NAME --discover-repos DIR` |
| Prepare only | `claude-container -s NAME --no-run` |
| Pull to host | `claude-container pull -s NAME` |
| Pull + merge into main | `claude-container pull -s NAME main` |
| Pull (overwrite) | `claude-container pull -s NAME --force` |
| Push from host (ff) | `claude-container push -s NAME` |
| Push + rebase | `claude-container push -s NAME main --rebase` |
| Check sync state | `claude-container status -s NAME main` |
| Delete session | `claude-container -s NAME --delete -y` |
| Remove repos | `claude-container remove -s NAME --include PATTERN` |
| Repair session | `claude-container -s NAME --repair` |
| List sessions | `claude-container list` |
| List with sizes | `claude-container list --sizes` |
| Clone session | `claude-container -s NEW --clone-from OLD` |
| Expose ports | `claude-container -s NAME --port 3000` |
| With Docker | `claude-container -s NAME --docker` |
| Custom Dockerfile | `claude-container -s NAME --dockerfile` |
| Start with dirty changes | `claude-container -s NAME --dirty` |
| Show session image | `claude-container image -s NAME` |
| Shell only | `claude-container -s NAME --shell` |
