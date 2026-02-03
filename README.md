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
┌─────────────────────────────────────────────────────────────────┐
│  1. CREATE SESSION                                              │
│     claude-container -s my-feature                              │
│     → Clones repo into Docker volume                            │
│     → Strips git remotes (Claude can't push)                    │
│     → Starts Claude Code in container                           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  2. WORK IN CONTAINER                                           │
│     Claude has full access to:                                  │
│     • Read/write any file in /workspace                         │
│     • Run any shell command                                     │
│     • Install packages (apt, npm, pip, cargo)                   │
│     • Make git commits                                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  3. EXIT & EXTRACT                                              │
│     claude-container -s my-feature --extract                    │
│     → Creates branch 'my-feature' in original repo              │
│     → Shows commit count and files changed                      │
│     → Skips repos with no changes                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  4. USE GIT NORMALLY                                            │
│     git checkout my-feature                                     │
│     git log main..my-feature                                    │
│     git merge my-feature                                        │
└─────────────────────────────────────────────────────────────────┘
```

## Commands

### Starting Sessions

```bash
# Single project (clones current directory)
claude-container -s my-feature

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
| `-c, --continue` | Continue the most recent conversation |
| `--discover-repos <dir>` | Auto-discover git repos in directory |
| `-C, --config <path>` | Path to `.claude-projects.yml` |
| `-a, --add-repo <path>` | Add a repo to the session |
| `--no-git-session` | Mount cwd directly (no isolation) |
| `--shell, --bash` | Start bash instead of Claude |
| `--docker` | Mount Docker socket |
| `--dockerfile [path]` | Use custom Dockerfile |
| `-b, --build` | Force rebuild image |
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

## Security

- **Tokens**: Stored in file mount, not environment variables
- **Git remotes**: Stripped from cloned repos (Claude can't push)
- **Rootish mode**: Non-root user with passwordless sudo
- **Isolation**: Changes stay in volumes until explicitly extracted

## License

MIT
