# claude-container

Run Claude Code in an isolated Docker container with full filesystem access, without risking your host system.

## Why?

Claude Code's `--dangerously-skip-permissions` flag lets Claude work autonomously, but running it directly on your machine means Claude can modify any file. `claude-container` provides:

- **Isolation**: Claude operates in a container with a cloned copy of your repo
- **Safety**: Changes stay in the container until you explicitly merge them
- **Persistence**: Conversation history, caches, and changes survive container restarts
- **Flexibility**: Review, cherry-pick, or discard Claude's changes

## Quick Start

```bash
# 1. Set up authentication
export CLAUDE_CODE_OAUTH_TOKEN=$(claude auth status | grep -o 'oauth:[^ ]*')
# Or run: claude setup-token

# 2. Start a session
./claude-container --git-session my-feature

# 3. Claude is now running in the container - work with it

# 4. After exiting, merge changes back
./claude-container --merge-session my-feature
```

## Installation

```bash
# Clone this repo
git clone https://github.com/hypermemetic/claude-container.git
cd claude-container

# Add to PATH (optional)
export PATH="$PATH:$(pwd)"

# Or symlink to a bin directory
ln -s $(pwd)/claude-container /usr/local/bin/
ln -s $(pwd)/claude-container-cp /usr/local/bin/
```

### Prerequisites

**Required:**
- Docker (Docker Desktop, Colima, or native Docker)
- A Claude Code OAuth token (set `CLAUDE_CODE_OAUTH_TOKEN`)

**Optional (for multi-project sessions):**
- `yq` (YAML processor) - recommended
  - macOS: `brew install yq`
  - Ubuntu/Debian: `sudo apt-get install yq`
  - Other: See https://github.com/mikefarah/yq#install
- OR `python3` with PyYAML: `pip3 install pyyaml`

**Verify your setup:**
```bash
./claude-container --verify
```

This will check for all dependencies including YAML parser availability.

## Starting a Session

### Basic Session (Direct Mount)

```bash
# Mount current directory directly - changes affect your files immediately
./claude-container
```

### Git Session (Recommended)

```bash
# Create an isolated session - changes stay in Docker volume
./claude-container --git-session feature-name
```

This:
1. Creates a Docker volume `claude-session-feature-name`
2. Clones your current repo into it
3. Strips git remotes (Claude can't push)
4. Starts Claude with full permissions

### Resuming a Session

```bash
# Resume the session and continue the conversation
./claude-container --git-session feature-name --continue

# If you hit permission issues, use restart
./claude-container --restart-session feature-name
```

### Session Options

| Flag | Description |
|------|-------------|
| `--git-session, -g <name>` | Create/resume isolated git session |
| `--session, -s <name>` | Override state volume name (for sharing state) |
| `--continue, -c` | Continue the most recent Claude conversation |
| `--as-rootish` | Run as user with fake-root capabilities (recommended) |
| `--build, -b` | Force rebuild the container image |

## Working Inside the Container

Once inside, Claude runs with `--dangerously-skip-permissions`, meaning it can:
- Read and write any file in `/workspace`
- Run any shell command
- Install packages
- Make git commits

### Installing Dependencies

Claude can install dependencies directly:

```
You: Install the project dependencies and set up the development environment

Claude: I'll install the dependencies for this Node.js project.
> npm install
> npm run build
```

For system packages, use `--as-rootish`:

```bash
# Start with rootish mode
./claude-container --git-session my-feature --as-rootish
```

Then inside the container:
```
You: Install postgresql client tools

Claude: I'll install the PostgreSQL client.
> rootish apt-get update
> rootish apt-get install -y postgresql-client
```

The `rootish` wrapper makes commands think they're running as root without actual root privileges.

### Making Changes

Claude can commit changes inside the session:

```
You: Refactor the authentication module and commit your changes

Claude: I'll refactor the auth module...
[makes changes]
> git add -A
> git commit -m "Refactor authentication module"
```

These commits stay in the session volume until you merge them.

## Reviewing Changes

### View Session Diff

```bash
# See what changed in a session compared to your repo
./claude-container --diff-session feature-name
```

Output:
```
=== Commits in session ===
abc1234 Refactor authentication module
def5678 Add unit tests for auth

=== File changes (session vs source) ===
 src/auth/index.ts      | 45 +++++++++++++++++++++---------
 src/auth/middleware.ts | 12 ++++++++
 tests/auth.test.ts     | 89 ++++++++++++++++++++++++++++++++++++++++++++++++++
 3 files changed, 132 insertions(+), 14 deletions(-)
```

### List Session Files

```bash
# List files in the workspace
./claude-container-cp --list feature-name

# List a specific directory
./claude-container-cp --list feature-name /workspace/src
```

## Merging Changes Back

### Merge All Commits

```bash
./claude-container --merge-session feature-name
```

Interactive prompt:
```
=== Commits to merge ===
abc1234 Refactor authentication module
def5678 Add unit tests for auth

Merge all commits? [y/n/select] y
Applied: 0001-Refactor-authentication-module.patch
Applied: 0002-Add-unit-tests-for-auth.patch
Successfully merged 2 commit(s)

Delete session 'feature-name'? [y/n]
```

### Merge to a New Branch

```bash
# Create/switch to branch and apply commits there
./claude-container --merge-session feature-name --into claude/feature-name
```

### Auto-Sync on Exit

```bash
# Automatically merge to a branch when the container exits
./claude-container --git-session feature-name --auto-sync claude/feature-name
```

## Multi-Project Sessions

Work across multiple related repositories (e.g., frontend + backend + shared libraries) in a single Claude session.

### Configuration File

Create a `.claude-projects.yml` file in your project root:

```yaml
version: "1"
projects:
  frontend:
    path: ./frontend          # Relative to config file location
  backend:
    path: /absolute/path/to/backend
  shared-lib:
    path: ../shared-library
```

**Config Discovery Order:**
1. `--config <path>` CLI flag (highest priority)
2. `./.claude-projects.yml`
3. `./.devcontainer/claude-projects.yml`
4. `./claude-projects.yml`
5. Falls back to single-repo mode if no config found

### Creating a Multi-Project Session

```bash
# Auto-detect config in current directory
./claude-container --git-session feature-name

# Explicit config path
./claude-container --git-session feature-name --config ~/my-projects.yml
```

When the config is detected, all specified projects are cloned into the session volume:
```
/workspace/
├── frontend/       # Your frontend repo
├── backend/        # Your backend repo
└── shared-lib/     # Your shared library repo
```

### Viewing Changes

**Summary view** (shows all projects):
```bash
./claude-container --diff-session feature-name
```

Output:
```
Project: frontend (2 commits)
  abc1234 Add login form
  def5678 Update styles

Project: backend (1 commit)
  ghi9012 Add auth endpoint

Project: shared-lib (0 commits)
  (no changes)
```

**Detailed view** (specific project):
```bash
./claude-container --diff-session feature-name frontend
```

Shows detailed diff and file changes for just the `frontend` project.

### Merging Changes

**Interactive merge** (select which projects to merge):
```bash
./claude-container --merge-session feature-name
```

**Auto-merge** (merge all projects with commits):
```bash
./claude-container --merge-session feature-name --auto
```

**Merge to specific branch** (across all projects):
```bash
./claude-container --merge-session feature-name --into claude/feature-name
```

Each project with commits will be merged back to its source repository. Projects without changes are skipped automatically.

### Requirements

- All project paths must exist and be git repositories
- Config file must be valid YAML
- Project names must be unique (no duplicates)
- Reserved names not allowed: `.git`, `.claude`, `.devcontainer`, `workspace`, `session`

### Backward Compatibility

Single-repo mode continues to work exactly as before when no config file exists:

```bash
# No config file = single-repo mode
./claude-container --git-session feature-name
```

## Copying Files

For files that aren't git-tracked (build artifacts, generated files, logs):

### Copy from Session

```bash
# Copy a directory
./claude-container-cp feature-name:/workspace/dist ./dist

# Copy a single file
./claude-container-cp feature-name:/workspace/report.pdf ./report.pdf

# Copy Claude's conversation logs
./claude-container-cp feature-name:/home/developer/.claude ./claude-state
```

### Copy to Session

```bash
# Add test fixtures to a session
./claude-container-cp ./test-data feature-name:/workspace/test-data

# Copy environment file
./claude-container-cp .env.local feature-name:/workspace/.env
```

### Supported Paths

| Container Path | Description |
|----------------|-------------|
| `/workspace/*` | Your cloned repository |
| `/home/developer/.claude/*` | Claude state, conversation history |
| `/home/developer/.cargo/*` | Rust/Cargo cache |
| `/home/developer/.npm/*` | npm cache |
| `/home/developer/.cache/pip/*` | pip cache |

## Session Management

### List Sessions

```bash
./claude-container --list-sessions
```

### Delete a Session

```bash
./claude-container --delete-session feature-name
```

### Clean Up All Sessions

```bash
./claude-container --cleanup
```

## Common Workflows

### Feature Development

```bash
# 1. Start isolated session
./claude-container --git-session new-feature --as-rootish

# 2. Work with Claude to implement the feature
#    Claude commits changes as it works

# 3. Exit (Ctrl+D or type "exit")

# 4. Review what was done
./claude-container --diff-session new-feature

# 5. Merge to a feature branch
./claude-container --merge-session new-feature --into feature/new-feature

# 6. Push and create PR
git push -u origin feature/new-feature
gh pr create
```

### Bug Investigation

```bash
# 1. Start session to investigate
./claude-container --git-session debug-issue-123

# 2. Have Claude investigate and fix
#    "Investigate why users are getting 500 errors on /api/checkout"

# 3. If the fix is good, merge it
./claude-container --merge-session debug-issue-123

# 4. If not useful, just delete
./claude-container --delete-session debug-issue-123
```

### Extracting Generated Artifacts

```bash
# 1. Have Claude generate documentation, reports, etc.
./claude-container --git-session docs

# 2. Copy out the generated files
./claude-container-cp docs:/workspace/generated-docs ./docs

# 3. Delete the session (we just wanted the files)
./claude-container --delete-session docs
```

### Sharing State Across Sessions

```bash
# Multiple git sessions can share conversation history
./claude-container --git-session experiment-1 --session shared-context
./claude-container --git-session experiment-2 --session shared-context

# Both sessions will have access to the same Claude conversation history
```

## Using a Custom Dockerfile

If your project has specific dependencies, create a Dockerfile:

```dockerfile
FROM ghcr.io/hypermemetic/claude-container:latest

# Add project-specific dependencies
RUN apt-get update && apt-get install -y \
    postgresql-client \
    redis-tools

# Pre-install global tools
RUN npm install -g typescript ts-node
```

Then:
```bash
./claude-container --git-session my-feature
# Automatically uses ./Dockerfile if present
```

Search order for Dockerfiles:
1. Explicit path argument
2. `./Dockerfile`
3. `./.devcontainer/Dockerfile`
4. `./docker/Dockerfile`
5. Default image (if none found)

## Troubleshooting

### Permission Errors

```bash
# Restart the session (fixes permissions and continues conversation)
./claude-container --restart-session feature-name
```

### Token Issues

```bash
# Verify your setup
./claude-container --verify

# Check token is set
echo $CLAUDE_CODE_OAUTH_TOKEN
```

### Volume Issues

```bash
# List all volumes
docker volume ls | grep claude

# Inspect a specific volume
docker volume inspect claude-session-feature-name

# Nuclear option: remove all claude volumes
./claude-container --cleanup
```

### Container Won't Start

```bash
# Force rebuild the image
./claude-container --build --git-session feature-name

# Check Docker is running
docker ps
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Required. OAuth token for Claude authentication |

## Security Considerations

- **Tokens**: Stored in a file mount, not environment variables (hidden from `docker inspect`)
- **Git remotes**: Stripped from cloned repos (Claude can't push)
- **Rootish mode**: Fake root via user namespaces, not real root
- **Isolation**: Changes stay in volumes until explicitly merged

## License

MIT
