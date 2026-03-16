# claude-container

Run Claude Code in an isolated Docker container with full filesystem access, without risking your host system.

## Why?

Claude Code's `--dangerously-skip-permissions` flag lets Claude work autonomously, but running it directly on your machine means Claude can modify any file. `claude-container` provides:

- **Isolation**: Claude operates in a container with a cloned copy of your repo
- **Safety**: Changes stay in the container until you explicitly extract them
- **Persistence**: Conversation history, caches, and changes survive container restarts
- **Flexibility**: Extract changes as a branch, then review and merge normally

## Common Workflows

### The basics: start → work → pull

```bash
# Start a session
claude-container -s my-feature --discover-repos ~/dev/myorg

# Claude works in the container... exit when done

# Pull changes and squash-merge into main
claude-container pull -s my-feature main
```

### Live development: watch changes as they happen

```bash
# In terminal 1: run your dev server
cd ~/dev/myorg/plexus-gamma && bun dev

# In terminal 2: watch for container changes, auto-pull
claude-container watch -s my-feature --repo gamma -i 2 -- \
  claude-container pull -s my-feature main
```

### Keep sessions up to date with main

```bash
# Fast-forward (if session is behind main)
claude-container push -s my-feature main

# Merge main into session (Claude resolves conflicts)
claude-container push -s my-feature main --merge

# Serve main as a branch the agent can merge at its own pace
claude-container push -s my-feature main --as host/main
# Agent inside container runs: git merge host/main
```

### Handle conflicts

```bash
# Option A: full reconcile (stash, merge, resolve, merge back)
claude-container pull -s my-feature main --reconcile

# Option B: push main into session, let Claude resolve, then pull clean
claude-container push -s my-feature main --merge
claude-container pull -s my-feature main
```

## Installation

```bash
git clone https://github.com/juggernautlabs/claude-container.git
cd claude-container

# Add to PATH
export PATH="$PATH:$(pwd)"

# Or symlink
ln -s $(pwd)/claude-container /usr/local/bin/
```

### Prerequisites

**Required:**
- Docker (Docker Desktop, Colima, or native Docker)
- A Claude Code OAuth token (set `CLAUDE_CODE_OAUTH_TOKEN`)

**Required for multi-project sessions:**
- `yq` - YAML processor
  ```bash
  brew install yq          # macOS
  sudo apt-get install yq  # Ubuntu/Debian
  ```

**Optional:**
- `pv` - Shows progress during extraction
  ```bash
  brew install pv          # macOS
  sudo apt-get install pv  # Ubuntu/Debian
  ```

## Subcommands

### pull — container → host

Extract session branches and optionally merge into a target branch.

```bash
claude-container pull -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| `--status` | Read-only check: compare container vs host (no extraction) |
| `--repo <name>` | Only pull this repo (partial name OK) |
| `--reconcile, -R` | Full cycle: stash, merge, resolve conflicts, merge back |
| `--squash` | Squash-merge into target (default) |
| `--no-squash` | Regular merge (preserves full commit history) |
| `--dry-run` | Preview what would happen |
| `--force, -f` | Force extraction if branches diverged |

**Squash-merge tracking**: Repeat pulls only merge NEW commits since the last squash. No conflicts from re-merging old work.

**Auto-force when merging**: When a target branch is specified, extraction automatically force-updates the session branch from the container. The session branch is just transport — main is protected by conflict detection.

**Output format**: Unified per-repo report showing extract/merge/action lines with commit hashes:
```
  hypermemetic/plexus-gamma  container:abc1234  session:abc1234  main:def5678
    extract:  ✓ updated (3 commits, 5 files)
    merge:    ✓ synapse-cc-ux → main: squash-merged into main (3 new)

✓ 1 pulled into main
```

### push — host → container

Push host changes into a container session.

```bash
claude-container push -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| `--repo <name>[,<branch>]` | Only push this repo, optionally from a specific branch |
| `--as <branch>` | Don't merge — place host branch in container as `<branch>` |
| `--ff` | Fast-forward from host branch (default) |
| `--merge` | Merge host branch into session (launches container if conflicts) |
| `--rebase` | Rebase session onto host branch (launches container if conflicts) |
| `--force, -f` | Force operation (reset diverged repos to host HEAD) |

**`--as` for agent-driven merges**: Places the host branch in the container without merging. The agent decides when and how to merge:
```bash
claude-container push -s my-feature main --as host/main
# Agent runs: git merge host/main
```

### watch — trigger commands on session changes

Watch a session for new commits and run a command when changes are detected.

```bash
claude-container watch -s <session> [options] -- <command...>
```

| Flag | Description |
|------|-------------|
| `--repo <name>` | Only watch this repo |
| `--interval, -i <secs>` | Poll interval (default: 5) |

Changes that arrive while the command is running are coalesced — the command re-runs once after completion, not once per change.

```bash
# Pull on every change
claude-container watch -s my-feature -- claude-container pull -s my-feature main

# Watch one repo, fast polling
claude-container watch -s my-feature --repo gamma -i 2 -- \
  claude-container pull -s my-feature

# Chain with a build
claude-container watch -s my-feature --repo gamma -- sh -c \
  'claude-container pull -s my-feature && cd ~/dev/myproj && bun run build'

# Serve host branch to agent whenever local main changes
claude-container watch -s my-feature -- \
  claude-container push -s my-feature main --as host/main
```

### status — read-only sync check

```bash
claude-container status -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| `--repo <name>` | Filter to a single repo |

No branch = sync classification. With branch = hash comparison.

### list — show all sessions

```bash
claude-container list
```

Shows sessions with last commit and edit times.

### reconcile — merge multiple sessions

```bash
claude-container reconcile <branch> [session...] [options]
```

| Flag | Description |
|------|-------------|
| `--include <regex>` | Only process matching sessions |
| `--exclude <regex>` | Skip matching sessions |
| `--dry-run` | Preview without merging |
| `--yes, -y` | Skip confirmation |
| `--continue` | Resume interrupted reconcile |

## How Pull + Squash Works

When you `pull -s X main`, the session's commits are squash-merged into a single commit on main:

1. **First pull**: `git merge --squash` + commit. Saves a squash-base ref.
2. **Repeat pulls**: Cherry-picks only commits AFTER the squash-base. One commit per pull, carrying the original session commit messages.
3. **Conflict detection**: Dry-runs the merge first. If it would conflict, reports the files and suggests `--reconcile`.

The squash-base ref (`refs/claude-container/squash-base/<session>`) tracks what was already merged. If the session branch is force-extracted from a different lineage, stale refs are automatically cleared.

## Starting Sessions

```bash
# Single project (clones current directory)
claude-container -s my-feature

# Start from a specific branch
claude-container -s post-feature --from feature-branch

# Resume and continue conversation
claude-container -s my-feature --continue

# Multiple projects via discovery
claude-container -s my-feature --discover-repos ~/dev/myproject

# Multiple projects via config file
claude-container -s my-feature --config .claude-projects.yml
```

## Multi-Project Sessions

Work across multiple repositories in a single session:

```yaml
# .claude-projects.yml
version: "1"
main: backend/api
dockerfile: ./Dockerfile.dev    # Optional: custom Dockerfile
projects:
  backend/api:
    path: ~/dev/api
  backend/workers:
    path: ~/dev/workers
  frontend/web:
    path: ~/dev/webapp
```

```bash
# Start multi-project session
claude-container -s fullstack-feature

# Or auto-discover
claude-container -s my-feature --discover-repos ~/dev/myproject
```

Inside the container:
```
/workspace/
├── backend/
│   ├── api/        # Main project (initial working directory)
│   └── workers/
└── frontend/
    └── web/
```

## Session Management

```bash
# List all sessions
claude-container list

# Delete a session
claude-container -s my-feature --delete
claude-container -s my-feature --delete --yes     # Skip confirmation
claude-container -s 'test-.*' --delete --regex    # Pattern match

# Repair corrupted session config
claude-container -s my-feature --repair

# Restart session (fixes permissions)
claude-container -s my-feature --restart

# Import claude-code session data
claude-container -s my-feature --import ~/.claude
```

## Options

| Flag | Description |
|------|-------------|
| `-s, --session <name>` | Session name (required) |
| `--from <branch>` | Create session from specific branch |
| `-c, --continue` | Continue the most recent conversation |
| `--discover-repos <dir>` | Auto-discover git repos in directory |
| `-C, --config <path>` | Path to `.claude-projects.yml` |
| `-a, --add-repo <path>` | Add a repo to the session |
| `--no-git-session` | Mount cwd directly (no isolation) |
| `--shell, --bash` | Start bash instead of Claude |
| `--docker` | Mount Docker socket |
| `--dockerfile [path]` | Use Dockerfile (auto-detected or from config) |
| `--no-run` | Set up session without starting |
| `-f, --force` | Overwrite existing branches/data |
| `-y, --yes` | Skip confirmation prompts |
| `-r, --regex` | Use regex pattern matching |

## Architecture

Claude Container implements an **embedded agent** pattern:

- **Host program** (`claude-container`): Orchestrates isolated environments
- **Embedded agent** (Claude Code): Operates on cloned source code
- **Isolation boundary**: Container + git clone (no remotes)
- **Extraction point**: Changes become branches for human review

See [docs/architecture.md](docs/architecture.md) for detailed documentation.

## Troubleshooting

### Permission Errors

```bash
claude-container -s my-feature --restart
```

### Token Issues

```bash
# Verify setup
claude-container --verify

# Check token
echo $CLAUDE_CODE_OAUTH_TOKEN
```

### Extraction Shows "No Changes"

This means the session content matches the original repo HEAD. No branch is created for repos without changes.

### Corrupted Session Config

If you see paths like `/path/to/repo||true|`:
```bash
claude-container -s my-feature --repair
```

## Security

- **Tokens**: Stored in file mount, not environment variables
- **Git remotes**: Stripped from cloned repos (Claude can't push)
- **Rootish mode**: Non-root user with passwordless sudo
- **Isolation**: Changes stay in volumes until explicitly extracted
- **Workspace trust**: Auto-accepted inside containers (safe — isolated environment)

## License

MIT
