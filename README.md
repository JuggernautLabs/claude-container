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

# 4. Pull changes to host and merge into main
claude-container pull -s my-feature main

# 5. Or just extract as a branch
claude-container pull -s my-feature
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
 PULL & MERGE                     VERIFY
 claude-container pull            claude-container status
 -s my-feature main               -s my-feature main
         │                                  │
         ▼                                  ▼
 ┌──────────────────┐             ┌──────────────────┐
 │  Extract branches│             │  Compare hashes  │
 │  + auto-merge    │             │  session vs host │
 └──────────────────┘             └──────────────────┘

 If dirty or conflicts:
 claude-container pull -s my-feature main --reconcile
 → stash dirty work → merge → launch Claude for conflicts → fin
```

### Long-Running Sessions: Syncing with Upstream

For long-lived sessions where the upstream branch has changed:

```bash
# Rebase session onto updated main
claude-container push -s my-feature main --rebase

# Claude resolves any rebase conflicts interactively
# Then pull the rebased work
claude-container pull -s my-feature --force
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
claude-container status -s my-feature main

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
claude-container status -s my-feature main --repo repo-a
```

### 4a. Clean path — pull and merge

If your host repos are clean and the session already incorporates `main`:

```bash
claude-container pull -s my-feature main
```

This extracts session branches to each host repo, then merges them into `main`. For each repo:
- Creates/updates a `my-feature` branch matching the session HEAD
- Merges `my-feature` into `main` via `git merge --no-edit`
- Skips repos where nothing changed
- **Skips** repos where the merge would conflict — tells you to resolve in-container first

If any repos are skipped due to conflicts:

```bash
# Merge main INTO the session (Claude resolves conflicts in-container)
claude-container push -s my-feature main --merge

# Then pull again (now guaranteed clean)
claude-container pull -s my-feature main
```

### 4b. Messy path — reconcile

If your host repos have uncommitted changes or you expect conflicts, use `--reconcile`:

```bash
claude-container pull -s my-feature main --reconcile
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
claude-container status -s my-feature main

# Classification view — synced, unchanged, extracted-only, pending, missing
claude-container status -s my-feature
```

### Summary

```bash
# start
claude-container -s my-feature --discover-repos ~/dev/myorg --dir ~/dev/myorg/repo-a

# work, exit

# pull session branches to host
claude-container pull -s my-feature

# merge main into session first (Claude resolves conflicts)
claude-container push -s my-feature main --merge

# now merge into main on host (guaranteed clean)
claude-container pull -s my-feature main

# verify
claude-container status -s my-feature main
```

## Subcommands

### push

Push host changes into a container session (host → container).

```bash
claude-container push -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| `--repo <name>[,<branch>]` | Only push this repo, optionally from a specific branch |
| `--ff` | Fast-forward from host branch (default) |
| `--rebase` | Rebase session onto host branch |
| `--merge` | Merge host branch into session |
| `--force, -f` | Force operation (reset diverged repos to host HEAD) |

Repo names support partial matching (`synapse` matches `org/synapse`). Ambiguous matches are rejected with a list of candidates.

### pull

Pull session changes to host (container → host).

```bash
claude-container pull -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| `--reconcile, -R` | Stash dirty work, merge, resolve conflicts, merge back |
| `--force, -f` | Force extraction even if branches diverged |

No branch = extract only. With branch = extract + auto-merge.

### status

Check sync state (read-only, no changes).

```bash
claude-container status -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| `--repo <name>` | Filter to a single repo |

No branch = sync classification. With branch = hash comparison.

### reconcile

Merge multiple sessions into a unified branch, sequentially.

```bash
claude-container reconcile <branch> [session...] [options]
```

| Flag | Description |
|------|-------------|
| `--include <regex>` | Only process matching sessions (repeatable) |
| `--exclude <regex>` | Skip matching sessions (repeatable, wins over include) |
| `--dry-run` | Preview what would happen without merging |
| `--yes, -y` | Skip confirmation prompt |
| `--continue` | Resume an interrupted reconcile |
| `--force, -f` | Force extraction even if branches diverged |

Omit session names to auto-discover all sessions with unmerged work.

## Workflow Guides

Detailed guides for common workflows:

- **[Data Transfer Overview](docs/workflows/data-transfer.md)** -- How data moves between host and container, choosing the right tool
- **[Basic Session](docs/workflows/basic-session.md)** -- Create, work, pull, merge
- **[Multi-Project](docs/workflows/multi-project.md)** -- Discover repos, work across multiple repos, handle new repos
- **[Reconcile](docs/workflows/reconcile.md)** -- Merge with dirty worktrees and conflicts, AI-assisted resolution
- **[Multi-Session Reconcile](docs/workflows/multi-session-reconcile.md)** -- Merge multiple sessions into one branch
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
# List all sessions
claude-container list

# Pull session to host (extract branches)
claude-container pull -s my-feature
claude-container pull -s my-feature --force  # Overwrite existing branches

# Pull and merge into main
claude-container pull -s my-feature main

# Push host changes into session
claude-container push -s my-feature main              # Fast-forward
claude-container push -s my-feature main --rebase     # Rebase onto main
claude-container push -s my-feature develop --rebase  # Rebase onto develop
claude-container push -s my-feature --repo api,main   # Push main into one repo
claude-container push -s my-feature --repo api --force # Force-reset one repo

# Reconcile multiple sessions into main
claude-container reconcile main s1 s2 s3              # Named sessions
claude-container reconcile main                       # Auto-discover
claude-container reconcile main --dry-run             # Preview
claude-container reconcile --continue                 # Resume

# Check sync state
claude-container status -s my-feature main

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
claude-container list

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

# Exit and pull your changes
./claude-container pull -s dev-feature main
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
# Push main into session (rebase)
./claude-container push -s dev-feature main --rebase

# Pull updated work
./claude-container pull -s dev-feature --force
```

## Security

- **Tokens**: Stored in file mount, not environment variables
- **Git remotes**: Stripped from cloned repos (Claude can't push)
- **Rootish mode**: Non-root user with passwordless sudo
- **Isolation**: Changes stay in volumes until explicitly extracted

## License

MIT
