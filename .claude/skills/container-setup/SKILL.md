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

### Optional: Docker Access
Ask if they need Docker commands inside the container (adds `--docker` flag).

### Optional: Custom Dockerfile
Ask if they want a custom Dockerfile instead of the default image.

## Step 2: Build the Command

Construct the command based on answers:

```bash
claude-container -s <session-name> [options]
```

Options:
- `--discover-repos <path>` - repo discovery
- `-a <path>` - add specific repos (repeatable)
- `--config <path>` - config file
- `--as-user` - user mode
- `--continue` - continue conversation
- `--docker` - Docker access
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

# Multi-project with discovery
claude-container -s my-feature --discover-repos ~/dev/myproject

# Specific repos
claude-container -s my-feature -a ~/dev/app -a ~/dev/lib

# Config file
claude-container -s my-feature --config .claude-projects.yml

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

# Custom Dockerfile
claude-container -s my-feature --dockerfile
```

## Extracting Changes

```bash
# Extract as branch
claude-container -s my-feature --extract

# Force overwrite existing branch
claude-container -s my-feature --extract --force
```

Output:
```
✓ myproject → branch 'my-feature' (3 commit(s), 7 file(s))

To see changes:  git log main..my-feature
Checkout:        git checkout my-feature
Merge:           git merge my-feature
```

## Session Management

```bash
# List sessions
claude-container --sessions

# Delete session
claude-container -s my-feature --delete
claude-container -s my-feature --delete --yes

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
4. Extract: claude-container -s my-feature --extract
5. Merge:   git checkout my-feature && git merge my-feature
```

## Command Quick Reference

| Task | Command |
|------|---------|
| Create session | `claude-container -s NAME` |
| Resume + continue | `claude-container -s NAME --continue` |
| Discover repos | `claude-container -s NAME --discover-repos DIR` |
| Prepare only | `claude-container -s NAME --no-run` |
| Extract as branch | `claude-container -s NAME --extract` |
| Extract (overwrite) | `claude-container -s NAME --extract -f` |
| Delete session | `claude-container -s NAME --delete -y` |
| Repair session | `claude-container -s NAME --repair` |
| List sessions | `claude-container --sessions` |
| With Docker | `claude-container -s NAME --docker` |
| Custom Dockerfile | `claude-container -s NAME --dockerfile` |
| Shell only | `claude-container -s NAME --shell` |
