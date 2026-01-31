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
- Git-based session isolation is the **default** - every session requires `-s <name>`
- The `--no-run` flag does all the heavy lifting upfront (discovery, validation, cloning)
- After setup, the user just needs `claude-container -s <name>` to start

## Step 1: Gather Information

Use `AskUserQuestion` to collect the following. If the user provided a session name as an argument, skip that question.

### Required: Session Name
Ask for a session name if not provided. This identifies the Docker volume and session.
- Should be lowercase, alphanumeric with hyphens
- Examples: `my-feature`, `bugfix-123`, `refactor-auth`
- **Branch matching**: If the session name matches an existing git branch, that branch will be cloned

### Required: Repository Source
Ask how they want to specify repositories:

1. **Current directory** (default) - Clone the repo in the current working directory
2. **Discover repos** - Auto-discover all git repos in a parent directory (e.g., `~/dev/myproject`)
3. **Config file** - Use an existing `.claude-projects.yml` for multi-project setup

If they choose "Discover repos", ask for the directory path.
If they choose "Config file", ask for the path (or use auto-detection).

### Optional: Tracked vs Untracked
For multi-project setups, ask which repos should be tracked for merging:
- **Tracked repos**: Changes will be merged back to source
- **Untracked repos**: Cloned for reference but changes won't be merged (use `track: false` in config)

### Optional: Runtime Mode
Ask about runtime mode:

1. **Rootish** (default) - Run with fake-root capabilities for installing system packages
2. **User mode** - Run as non-root developer user
3. **Root** - Run as actual root (not recommended)

### Optional: Continue Conversation
Ask if they want to continue an existing conversation in this session (adds `--continue` flag).

### Optional: Auto-sync Branch
Ask if they want changes auto-merged to a branch on exit. If yes, ask for the branch name.

### Optional: Docker Access
Ask if they need to run Docker commands inside the container (for building images, running tests, etc.).
- If yes, add `--enable-docker` flag
- Mention this mounts the host Docker socket

### Optional: Custom Dockerfile
Ask if they want to use a custom Dockerfile instead of the default image.
- Default: uses pre-built `ghcr.io/hypermemetic/claude-container:latest`
- If yes, add `--dockerfile` flag (searches `./Dockerfile`, `./.devcontainer/Dockerfile`, `./docker/Dockerfile`)
- Or `-f <path>` for a specific Dockerfile

## Step 2: Build the Command

Construct the claude-container command based on their answers:

```bash
claude-container -s <session-name> [options]
```

Options to include based on answers:
- `--discover-repos <path>` - if they chose repo discovery
- `--config <path>` - if they specified a config file
- `--as-rootish` - rootish mode (default, can omit)
- `--as-user` - if they chose user mode
- `--continue` - if they want to continue existing conversation
- `--auto-sync <branch>` - if they specified an auto-sync branch
- `--enable-docker` - if they need Docker access inside container
- `--dockerfile [path]` - if they want to use a custom Dockerfile

## Step 3: Validate with --no-run

Run the command with `--no-run` appended to validate AND prepare the session:

```bash
claude-container -s <name> [options] --no-run
```

This does the heavy lifting upfront:
- Verifies the OAuth token is set
- Checks Docker is available
- Validates the config file (if multi-project)
- Creates the session volume
- Clones repositories into the session
- Configures git in each repo

If validation fails, show the error and help the user fix it.

## Step 4: Output Session Info

After successful `--no-run`, tell the user:

1. The session name
2. The full command to start (for reference)
3. Offer to copy the start command to clipboard

```
Session prepared successfully: <session-name>

To start the container:
1. Exit Claude Code (type 'exit' or press Ctrl+D)
2. Run: claude-container -s <session-name>
```

---

# All Workflows

## Session Creation

### Basic Session (current directory)
```bash
claude-container -s my-feature
```

### Multi-Project with Discovery
```bash
claude-container -s my-feature --discover-repos ~/dev/myproject
```

### Multi-Project with Config File
```bash
claude-container -s my-feature --config .claude-projects.yml
```

### Generate Config Only (no session)
```bash
claude-container -s my-feature --discover-repos ~/dev --config-only
# Outputs: ~/.config/claude-container/sessions/my-feature.yml
```

### Prepare Without Starting
```bash
claude-container -s my-feature --no-run
```

## Config File Format

```yaml
version: "1"
projects:
  # Main project - tracked for merging
  my-app:
    path: ./my-app
    main: true

  # Dependency - tracked
  shared-lib:
    path: ../shared-lib

  # Reference only - NOT tracked for merging
  docs:
    path: ../docs
    track: false

  # Specific branch
  feature-branch:
    path: ./other-repo
    branch: develop
```

**Fields:**
- `path` - Path to git repository (relative to config file or absolute)
- `main` - Mark as main project (working directory inside container)
- `track` - Set to `false` to exclude from merge operations
- `branch` - Specific branch to clone (otherwise uses session name match or HEAD)

## Running Sessions

### Start/Resume Session
```bash
claude-container -s my-feature
```

### Resume and Continue Conversation
```bash
claude-container -s my-feature --continue
```

### Start with Docker Access
```bash
claude-container -s my-feature --enable-docker
```

### Start with Custom Dockerfile
```bash
claude-container -s my-feature --dockerfile
claude-container -s my-feature -f ./custom/Dockerfile
```

### Switch Container Image Mid-Session
Session volumes are decoupled from the container image. You can switch images without losing work:

```bash
# Start with default image
claude-container -s my-feature

# ... work, exit ...

# Resume with custom Dockerfile (adds dependencies you need)
claude-container -s my-feature --dockerfile --continue

# Or switch to a specific Dockerfile
claude-container -s my-feature -f ./Dockerfile.rust --continue
```

**Use cases:**
- Started with default image, now need specific tools (PostgreSQL, Redis, etc.)
- Need to test with different runtime versions
- Adding project-specific Dockerfile after initial exploration

The session data (`/workspace`) and conversation history are preserved - only the container environment changes.

### Shell Only (no Claude)
```bash
claude-container -s my-feature --shell
```

### Direct Mount (no git isolation)
```bash
claude-container --no-git-session
```

## Reviewing Changes

### View Diff
```bash
claude-container --diff-session my-feature
claude-container --diff-session my-feature specific-project
```

### Check What Would Be Merged (dry run)
```bash
claude-container --merge-session my-feature --no-run
```

## Merging Changes Back

### Interactive Merge
```bash
claude-container --merge-session my-feature
```

### Auto-Merge (no prompts)
```bash
claude-container --merge-session my-feature --yes
```

### Merge to Specific Branch
```bash
claude-container --merge-session my-feature --into feature/my-feature
```

### Auto-Sync on Container Exit
```bash
claude-container -s my-feature --auto-sync main
```

**Merge behavior:**
- Uses `git format-patch` + `git am` to preserve commit metadata
- Tracks merge points - only merges new commits since last merge
- Handles git worktrees automatically
- Skips repos with `track: false`

## Discovering New Repos

If Claude creates new git repos inside the session, use `--scan` to discover them:

```bash
claude-container -s my-feature --scan
```

This will:
1. List all git repos in the session
2. Compare against the config
3. Show known vs new repos
4. Prompt for destination path for each new repo
5. Update the session config

Then `--merge-session` will include the new repos.

## Adding Repos to Existing Session

```bash
claude-container --add-repo my-feature /path/to/repo [workspace-name]
```

## Session Management

### List All Sessions
```bash
claude-container --list-sessions
claude-container --sessions
```

### Delete a Session
```bash
claude-container --delete-session my-feature
claude-container --delete-session my-feature --yes  # Skip confirmation
claude-container --delete-session "my-.*" --regex   # Pattern match
```

### Restart Session (fix permissions)
```bash
claude-container --restart-session my-feature
```

### Cleanup Unused Volumes
```bash
claude-container --cleanup-unused
claude-container --cleanup-unused --yes
```

### Cleanup All Volumes
```bash
claude-container --cleanup
```

## Branch Behavior

When creating a session, the branch to clone is determined by:

1. **Config `branch` field** - highest priority
2. **Session name matches branch** - if a branch with the session name exists, it's used
3. **Current HEAD** - otherwise, clone whatever is checked out

```bash
# If branch "my-feature" exists in the repo, it will be cloned
claude-container -s my-feature
```

## Error Handling

### OAuth Token Missing
```
export CLAUDE_CODE_OAUTH_TOKEN=$(claude auth status | grep -o 'oauth:[^ ]*')
# Or: claude setup-token
```

### Docker Not Running
Start Docker Desktop or your Docker daemon.

### Merge Conflicts
```bash
cd /path/to/repo
git am --show-current-patch  # See what failed
# Fix conflicts
git add .
git am --continue
# Or abort: git am --abort
```

### Permission Issues
```bash
claude-container --restart-session my-feature
```

## Docker Access

```bash
claude-container -s my-feature --enable-docker
```

**Security notes:**
- **macOS** (Docker Desktop/Colima): Relatively safe - Docker runs in a VM
- **Linux**: Equivalent to root access on the host - use with caution

Socket auto-detection:
- `/var/run/docker.sock` (standard)
- `~/.colima/default/docker.sock` (Colima)
- `~/.docker/run/docker.sock` (Docker Desktop)

## Quick Reference

| Task | Command |
|------|---------|
| Create session | `claude-container -s NAME --no-run` |
| Start session | `claude-container -s NAME` |
| Resume + continue | `claude-container -s NAME --continue` |
| Switch image | `claude-container -s NAME --dockerfile --continue` |
| Discover repos | `claude-container -s NAME --discover-repos DIR` |
| Generate config only | `claude-container -s NAME --discover-repos DIR --config-only` |
| Check changes | `claude-container --diff-session NAME` |
| Dry-run merge | `claude-container --merge-session NAME --no-run` |
| Merge changes | `claude-container --merge-session NAME --yes` |
| Merge to branch | `claude-container --merge-session NAME --into BRANCH` |
| Scan for new repos | `claude-container -s NAME --scan` |
| Add repo to session | `claude-container --add-repo NAME /path/to/repo` |
| With Docker | `claude-container -s NAME --enable-docker` |
| Custom Dockerfile | `claude-container -s NAME --dockerfile` |
| Specific Dockerfile | `claude-container -s NAME -f ./path/Dockerfile` |
| Shell only | `claude-container -s NAME --shell` |
| Direct mount | `claude-container --no-git-session` |
| List sessions | `claude-container --list-sessions` |
| Delete session | `claude-container --delete-session NAME --yes` |
| Restart session | `claude-container --restart-session NAME` |
| Cleanup unused | `claude-container --cleanup-unused --yes` |
