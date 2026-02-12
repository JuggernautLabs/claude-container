# claude-container

Run Claude Code in an isolated Docker container with full filesystem access, without risking your host system.

## Why?

Claude Code's `--dangerously-skip-permissions` flag lets Claude work autonomously, but running it directly on your machine means Claude can modify any file. `claude-container` provides:

- **Isolation**: Claude operates in a container with a cloned copy of your repo
- **Safety**: Changes stay in the container until you explicitly extract them
- **Persistence**: Conversation history, caches, and changes survive container restarts
- **Flexibility**: Extract changes as a branch, then review and merge normally

## Quick Start

```bash
# 1. Set up authentication
export CLAUDE_CODE_OAUTH_TOKEN=$(claude auth status | grep -o 'oauth:[^ ]*')

# 2. Start a session
claude-container -s my-feature

# 3. Work with Claude in the container...

# 4. Exit and extract changes as a branch
claude-container -s my-feature --extract

# 5. Use git normally
git checkout my-feature
git merge my-feature
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

## Workflow

```
 CREATE SESSION                    WORK IN CONTAINER
 claude-container -s my-feature    Claude has full access:
 --discover-repos ~/dev/myorg      read/write files, run commands,
                                   install packages, make commits
         │                                  │
         ▼                                  ▼
 ┌──────────────────┐             ┌──────────────────┐
 │  Bundle repos    │────────────▶│  Claude works    │
 │  into volume     │             │  in /workspace   │
 └──────────────────┘             └──────────────────┘
                                            │
                                            ▼
 EXTRACT & MERGE                  VERIFY
 claude-container merge           claude-container merge
 -s my-feature --branch main      -s my-feature --check main
         │                                  │
         ▼                                  ▼
 ┌──────────────────┐             ┌──────────────────┐
 │  Extract branches│             │  Compare hashes  │
 │  + auto-merge    │             │  session vs host │
 └──────────────────┘             └──────────────────┘

 If dirty or conflicts:
 claude-container merge -s my-feature --reconcile main
 → stash dirty work → merge → launch Claude for conflicts → fin
```

### Long-Running Sessions: Syncing with Upstream

For long-lived sessions where the upstream branch has changed:

```bash
# Rebase session onto updated main
claude-container -s my-feature --sync main

# Claude resolves any rebase conflicts interactively
# Then extract the rebased work
claude-container -s my-feature --extract --force
```

## Full Workflow: Session to Merged Code

A complete walkthrough from a dirty workspace to everything merged into `main`.

### 1. Start a session

You have a workspace with several repos. Some have uncommitted work — that's fine.

```bash
claude-container -s my-feature \
  --discover-repos ~/dev/myorg \
  --dir ~/dev/myorg/repo-a
```

- `--discover-repos` walks `~/dev/myorg/`, finds every directory containing `.git`
- `--dir` sets `repo-a` as Claude's working directory inside the container
- Each repo is **bundled** into a Docker volume (git objects only, not build artifacts)
- A manifest is saved so new repos created inside the session can be detected later

Claude starts in the container with all your repos at `/workspace/`.

### 2. Work and exit

Claude works, makes commits, creates files. When done, exit the container (`Ctrl+C` or let Claude finish). Nothing has changed on your host — all work lives in the Docker volume.

### 3. Check status

```bash
# Compare session commit hashes against host main branch
claude-container merge -s my-feature --check main

# Example output:
#   repo-a
#     session: abc1234def56
#     host:    789012345678
#     result:  MISMATCH (session ahead)
#   repo-b
#     hash:    aabbccddee00
#     result:  MATCH
#   repo-c
#     session: 111222333444
#     host:    (no branch 'main')
#     result:  NO BRANCH

# Check a single repo
claude-container merge -s my-feature --check main --repo repo-a
```

### 4a. Clean path — extract and merge

If your host repos are clean (no uncommitted changes) and you don't expect conflicts:

```bash
claude-container merge -s my-feature --branch main
```

This extracts session branches to each host repo, then merges them into `main`. For each repo:
- Creates/updates a `my-feature` branch matching the session HEAD
- Merges `my-feature` into `main` via `git merge --no-edit`
- Skips repos where nothing changed
- **Aborts** if the worktree is dirty or there are merge conflicts

### 4b. Messy path — reconcile

If your host repos have uncommitted changes or you expect conflicts, use `--reconcile`:

```bash
claude-container merge -s my-feature --reconcile main
```

**Phase 1 — Extract**: Creates `my-feature` branches on the host from session data.

**Phase 2 — Stash dirty work**: For each host repo with uncommitted changes:
- Creates a branch `main-my-feature-stash-<timestamp>`
- Commits all dirty files there
- Returns to the original branch — worktree is now clean
- Your uncommitted work is safe on the stash branch

**Phase 3 — Merge target into session**: Merges `main` INTO each session repo (inside the Docker volume). If everything merges cleanly, extracts and auto-merges. Done.

If there are conflicts, a new Claude container launches with a prompt describing every conflict. Claude resolves the `<<<<<<< HEAD` markers, commits, then runs:

```bash
fin "resolved config merge conflict in repo-a"
```

`fin` signals completion and terminates the container. The exit handler extracts the resolved state and auto-merges into `main`.

### 5. Verify

```bash
# Hash comparison — every repo should show MATCH
claude-container merge -s my-feature --check main

# Classification view — synced, unchanged, extracted-only, pending, missing
claude-container merge -s my-feature --verify
```

### Summary

```bash
# start
claude-container -s my-feature --discover-repos ~/dev/myorg --dir ~/dev/myorg/repo-a

# work, exit

# clean path (no dirty repos, no conflicts)
claude-container merge -s my-feature --branch main

# messy path (dirty repos and/or conflicts)
claude-container merge -s my-feature --reconcile main

# verify
claude-container merge -s my-feature --check main
```

## Subcommands

### merge

Extract session work and merge into host branches.

```bash
claude-container merge -s <session> [options]
```

| Flag | Description |
|------|-------------|
| `--branch, -b <branch>` | Target branch to merge into (default: session name) |
| `--check, -c <branch>` | Compare session hashes against host branch |
| `--repo <name>` | Filter `--check` to a single repo |
| `--reconcile, -R <branch>` | Stash dirty work, merge, resolve conflicts, merge back |
| `--verify` | Show sync status for all repos |
| `--force, -f` | Force extraction even if branches diverged |

### extract

Extract session branches without merging.

```bash
claude-container extract -s <session> [--force] [--auto-merge [branch]]
```

## Workflow Guides

Detailed guides for common workflows:

- **[Data Transfer Overview](docs/workflows/data-transfer.md)** -- How data moves between host and container, choosing the right tool
- **[Basic Session](docs/workflows/basic-session.md)** -- Create, work, extract, merge
- **[Multi-Project](docs/workflows/multi-project.md)** -- Discover repos, work across multiple repos, handle new repos
- **[Reconcile](docs/workflows/reconcile.md)** -- Merge with dirty worktrees and conflicts, AI-assisted resolution
- **[Refresh](docs/workflows/refresh.md)** -- Pull host changes into an active session
- **[Verification](docs/workflows/verification.md)** -- Hash checks, sync status, scripting with exit codes

## Commands

### Starting Sessions

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

### Session Management

All session commands use the `--session/-s` flag:

```bash
# List all sessions with disk usage
claude-container --sessions

# Extract session as branch
claude-container -s my-feature --extract
claude-container -s my-feature --extract --force  # Overwrite existing branch

# Sync session with upstream changes (rebase)
claude-container -s my-feature --sync main        # Rebase onto main
claude-container -s my-feature --sync develop     # Rebase onto develop

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

### Global Commands (no session required)

```bash
# List sessions
claude-container --sessions

# Cleanup all volumes
claude-container --cleanup

# Cleanup unused volumes
claude-container --cleanup-unused
claude-container --cleanup-unused --yes
```

### Options

| Flag | Description |
|------|-------------|
| `-s, --session <name>` | Session name (required) |
| `--from <branch>` | Create session from specific branch |
| `-c, --continue` | Continue the most recent conversation |
| `--sync <branch>` | Rebase session onto upstream branch |
| `--discover-repos <dir>` | Auto-discover git repos in directory |
| `-C, --config <path>` | Path to `.claude-projects.yml` |
| `-a, --add-repo <path>` | Add a repo to the session |
| `--no-git-session` | Mount cwd directly (no isolation) |
| `--shell, --bash` | Start bash instead of Claude |
| `--docker` | Mount Docker socket |
| `--dockerfile [path]` | Use Dockerfile (auto-detected or from config) |
| `--no-run` | Set up session without starting |

### Action Modifiers

| Flag | Description |
|------|-------------|
| `-f, --force` | Overwrite existing branches/data |
| `-y, --yes` | Skip confirmation prompts |
| `-r, --regex` | Use regex pattern matching |

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

Extraction creates branches in each repo that has changes:
```
→ Multi-project session detected

  backend/api (no changes)
✓ backend/workers → branch 'fullstack-feature' (2 commit(s), 4 file(s))
✓ frontend/web → branch 'fullstack-feature' (5 commit(s), 12 file(s))

✓ Created branch 'fullstack-feature' in 2 repo(s)
```

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

## Development

To contribute to claude-container using claude-container itself:

```bash
# Clone the repo
git clone https://github.com/juggernautlabs/claude-container.git
cd claude-container

# Create a development session
./claude-container -s dev-feature

# Work with Claude in the container...
# The container has access to the cloned claude-container repo

# Exit and extract your changes
./claude-container -s dev-feature --extract

# Review and merge
git checkout dev-feature
git log main..dev-feature
```

### Running Tests

```bash
# Run all workflow tests
./tests/test-workflows.sh

# Run specific test
./tests/test-workflows.sh sync_uncommitted

# List available tests
./tests/test-workflows.sh --help
```

### Syncing with Upstream

For long-running development sessions:

```bash
# Sync with main branch
./claude-container -s dev-feature --sync main

# Extract updated work
./claude-container -s dev-feature --extract --force
```

## Security

- **Tokens**: Stored in file mount, not environment variables
- **Git remotes**: Stripped from cloned repos (Claude can't push)
- **Rootish mode**: Non-root user with passwordless sudo
- **Isolation**: Changes stay in volumes until explicitly extracted

## License

MIT
