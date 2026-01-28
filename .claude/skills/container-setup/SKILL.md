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
2. Validate and prepare the session with `--no-run` (does discovery, cloning, validation)
3. Output the session name and command for the user to run after exiting

## Important Context

- **claude-container** runs Claude Code in an isolated Docker container
- The user is CURRENTLY inside Claude Code, so we cannot start the container from here
- The `--no-run` flag does all the heavy lifting upfront (discovery, validation, cloning)
- After setup, the user just needs `claude-container --git-session <name>` to start

## Step 1: Gather Information

Use `AskUserQuestion` to collect the following. If the user provided a session name as an argument, skip that question.

### Required: Session Name
Ask for a session name if not provided. This identifies the Docker volume and session.
- Should be lowercase, alphanumeric with hyphens
- Examples: `my-feature`, `bugfix-123`, `refactor-auth`

### Required: Repository Source
Ask how they want to specify repositories:

1. **Current directory** (default) - Clone the repo in the current working directory
2. **Discover repos** - Auto-discover all git repos in a parent directory (e.g., `~/dev/myproject`)
3. **Config file** - Use an existing `.claude-projects.yml` for multi-project setup

If they choose "Discover repos", ask for the directory path.
If they choose "Config file", ask for the path (or use auto-detection).

### Required: Runtime Mode
Ask about runtime mode:

1. **Rootish** (recommended) - Run with fake-root capabilities for installing system packages
2. **User mode** - Run as non-root developer user
3. **Default** - No special mode

### Optional: Continue Conversation
Ask if they want to continue an existing conversation in this session (adds `--continue` flag).

### Optional: Auto-sync Branch
Ask if they want changes auto-merged to a branch on exit. If yes, ask for the branch name.

### Optional: Docker Access
Ask if they need to run Docker commands inside the container (for building images, running tests, etc.).
- If yes, add `--enable-docker` flag
- Mention this mounts the host Docker socket

## Untracked Dependencies

For projects that should be cloned but NOT tracked for merging (libraries, reference repos), use `track: false` in the config:

```yaml
version: "1"
projects:
  my-app:
    path: ./my-app
    main: true

  # These are cloned but changes won't be merged back
  shared-lib:
    path: ../shared-lib
    track: false

  reference-docs:
    path: ../docs
    track: false
```

Untracked projects:
- Are cloned into the session like normal
- Show as `[-] project-name (untracked)` in merge status
- Are skipped during `--merge-session`
- Don't have merge points recorded

## Step 2: Build the Command

Construct the claude-container command based on their answers:

```bash
claude-container --git-session <session-name> [options]
```

Options to include based on answers:
- `--discover-repos <path>` - if they chose repo discovery
- `--config <path>` - if they specified a config file
- `--as-rootish` - if they chose rootish mode
- `--as-user` - if they chose user mode
- `--continue` - if they want to continue existing conversation
- `--auto-sync <branch>` - if they specified an auto-sync branch

## Step 3: Validate with --no-run

Run the command with `--no-run` appended to validate AND prepare the session:

```bash
claude-container --git-session <name> [options] --no-run
```

This does the heavy lifting upfront:
- Verifies the OAuth token is set
- Checks Docker is available
- Validates the config file (if multi-project)
- Creates the session volume
- Clones repositories into the session
- Configures git in each repo

If validation fails, show the error and help the user fix it. Common issues:
- Missing `CLAUDE_CODE_OAUTH_TOKEN` - guide them to run `claude setup-token`
- Docker not running - ask them to start Docker
- Invalid config file - help fix YAML syntax or paths

## Step 4: Output Session Info

After successful `--no-run`, tell the user:

1. The session name
2. The full command to start (for reference)
3. Offer to copy the start command to clipboard

```
Session prepared successfully: <session-name>

To start the container:
1. Exit Claude Code (type 'exit' or press Ctrl+D)
2. Run: claude-container --git-session <session-name>

Full command (for reference):
  claude-container --git-session <name> --discover-repos <path> --as-rootish
```

Then ask if they want the command copied to the clipboard:

```bash
echo "claude-container --git-session <name>" | pbcopy
```

## Example Interaction

```
User: /container-setup

Claude: I'll help you set up a claude-container session.

[Asks: What should the session be named?]
User: feature-auth

[Asks: How do you want to specify repositories?]
User: Discover repos

[Asks: What directory contains your repositories?]
User: ~/dev/myapp

[Asks: What runtime mode do you need?]
User: Rootish (recommended)

[Asks: Continue an existing conversation?]
User: No

Claude: Let me prepare this session...
> claude-container --git-session feature-auth --discover-repos ~/dev/myapp --as-rootish --no-run

[Output shows successful setup - repos discovered, cloned, validated]

Session prepared successfully: feature-auth

To start the container:
1. Exit Claude Code (type 'exit' or press Ctrl+D)
2. Run: claude-container --git-session feature-auth

Full command (for reference):
  claude-container --git-session feature-auth --discover-repos ~/dev/myapp --as-rootish

[Asks: Copy start command to clipboard?]
User: Yes

Claude: Copied to clipboard. Exit and paste to start your session.
```

## Session Lifecycle

### Creating a Session
Sessions are created with `--git-session <name>`. The `--no-run` flag prepares everything without starting:
```bash
claude-container --git-session myproject --no-run
```

### Running a Session
After creation (or to resume), just run:
```bash
claude-container --git-session myproject
```

### Checking for Changes
To see what commits were made in a session:
```bash
claude-container --merge-session myproject --no-run
```

This shows commits pending merge for each project without actually merging.

### Merging Changes Back
When the user is done working in the container and wants to merge changes back:
```bash
claude-container --merge-session myproject --yes
```

This will:
1. Show commits pending for each project
2. Generate patches for new commits (since last merge)
3. Apply patches to the source repos (handles worktrees automatically)
4. Record merge points for future incremental merges

Options:
- `--no-run` - Dry run, just show what would be merged
- `--yes` - Skip confirmation prompts
- `--into <branch>` - Merge into a specific branch

### Deleting a Session
```bash
claude-container --delete-session myproject --yes
```

## Docker Access

If the user needs to run Docker commands inside the container (e.g., for building images, running tests):

```bash
claude-container --git-session myproject --enable-docker
```

This mounts the host's Docker socket into the container.

**Security notes:**
- On **macOS** (Docker Desktop/Colima): Relatively safe - Docker runs in a VM
- On **Linux**: Equivalent to root access on the host - use with caution

The flag auto-detects the socket location:
- `/var/run/docker.sock` (standard)
- `~/.colima/default/docker.sock` (Colima)
- `~/.docker/run/docker.sock` (Docker Desktop)

## Error Handling

### OAuth Token Missing
```
The CLAUDE_CODE_OAUTH_TOKEN environment variable is not set.

To fix this:
1. Exit Claude Code
2. Run: export CLAUDE_CODE_OAUTH_TOKEN=$(claude auth status | grep -o 'oauth:[^ ]*')
   Or: claude setup-token
3. Run this skill again
```

### Docker Not Running
```
Docker doesn't appear to be running.

Please start Docker Desktop (or your Docker daemon) and try again.
```

### Invalid Session Name
If the user provides an invalid session name (spaces, special characters), suggest a corrected version.

### Merge Conflicts
If `--merge-session` fails with patch conflicts:
```
Merge failed - resolve conflicts and run: git am --continue
```

Guide the user to:
1. Go to the affected repo directory
2. Resolve conflicts in the affected files
3. Run `git add <files>` and `git am --continue`
4. Or abort with `git am --abort`

## Quick Reference

| Task | Command |
|------|---------|
| Create session | `claude-container --git-session NAME --no-run` |
| Start session | `claude-container --git-session NAME` |
| Check changes | `claude-container --merge-session NAME --no-run` |
| Merge changes | `claude-container --merge-session NAME --yes` |
| With Docker | `claude-container --git-session NAME --enable-docker` |
| Delete session | `claude-container --delete-session NAME --yes` |
| List sessions | `claude-container --list-sessions` |
