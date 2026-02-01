# claude-container

Run Claude Code in an isolated Docker container with full filesystem access, without risking your host system.

---

## WARNING: Don't Let Claude Delete Your Sessions

If you're using claude-container to develop claude-container itself, **be very careful with session management commands**.

Claude has access to `--delete-session`, `--cleanup`, and `--cleanup-unused` commands. If you ask Claude to "clean up" or it decides to tidy up test artifacts, it may delete your running sessions - including the one it's running in.

**True story:** While developing this tool, we ran:
```bash
./claude-container --delete-session "test-" --regex --yes
```

This killed two running Claude containers that were using those volumes. All uncommitted work in those sessions was lost.

**Safe practices:**
- Don't ask Claude to clean up sessions without reviewing the command first
- Use `--list-sessions` to see what's running before any delete operation
- Name your important sessions distinctively (not `test`, `temp`, etc.)
- Commit/merge work before running cleanup commands

---

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

# 2. Start a session (git-based isolation is the default)
./claude-container -s my-feature

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

Git-based session isolation is the **default**. Every session requires a name via `-s <name>`.

### Standard Session (Recommended)

```bash
# Create an isolated session - changes stay in Docker volume
./claude-container -s feature-name
```

This:
1. Creates a Docker volume `claude-session-feature-name`
2. Clones your current repo into it (uses matching branch if exists)
3. Strips git remotes (Claude can't push)
4. Starts Claude with full permissions

### Direct Mount (No Isolation)

```bash
# Mount current directory directly - changes affect your files immediately
./claude-container --no-git-session
```

### Resuming a Session

```bash
# Resume the session and continue the conversation
./claude-container -s feature-name --continue

# If you hit permission issues, use restart
./claude-container --restart-session feature-name
```

### Branch Behavior

When creating a session, the branch to clone is determined by:
1. **Config `branch` field** - if specified in `.claude-projects.yml`
2. **Session name matches branch** - if a branch matching the session name exists, it's used
3. **Current HEAD** - otherwise, clone whatever is checked out

```bash
# If branch "my-feature" exists, it will be cloned
./claude-container -s my-feature
```

### Session Options

| Flag | Description |
|------|-------------|
| `-s, --session <name>` | Session name (required) |
| `--no-git-session` | Disable git isolation, mount cwd directly |
| `--discover-repos <dir>` | Auto-discover all git repos in directory |
| `--config, -C <path>` | Explicit path to `.claude-projects.yml` config file |
| `--config-only` | Generate config file only, output path |
| `--continue, -c` | Continue the most recent Claude conversation |
| `--as-rootish` | Run as user with fake-root capabilities (default) |
| `--as-root` | Run as actual root user (disables rootish) |
| `--enable-docker` | Mount Docker socket for host Docker access |
| `--build, -b` | Force rebuild the container image |
| `--sessions` | List all sessions with disk usage |
| `--delete-session <name>` | Delete a session and all its volumes |
| `--import-session <path> <name>` | Import a claude-code session into a container |

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

System packages work out of the box (rootish mode is the default):

```bash
./claude-container -s my-feature
```

Inside the container, Claude can install packages:
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
./claude-container -s feature-name --auto-sync claude/feature-name
```

## Multi-Project Sessions

Work across multiple related repositories (e.g., frontend + backend + shared libraries) in a single Claude session. This enables Claude to make coordinated changes across your entire codebase, understanding dependencies and relationships between different projects.

### Why Use Multi-Project Sessions?

**Perfect for:**
- Full-stack applications (frontend + backend + shared types)
- Microservices architectures (multiple service repos)
- Monorepo-style workflows (multiple packages in separate repos)
- Library ecosystems (core library + plugins + examples)
- Coordinated refactoring across multiple repos

**Benefits:**
- Claude sees the full context across all repositories
- Make type-safe changes across frontend/backend boundaries
- Coordinate API changes with client updates
- Refactor shared code and update all consumers simultaneously
- Single conversation history for the entire feature

### Quick Start

```bash
# 1. Create config file listing your repos
cat > .claude-projects.yml << 'EOF'
version: "1"
projects:
  frontend:
    path: ./frontend
  backend:
    path: ./backend
  shared:
    path: ./shared
EOF

# 2. Start multi-project session
./claude-container -s fullstack-feature

# 3. Claude can now see and modify all three repos
# Inside container: /workspace/frontend/, /workspace/backend/, /workspace/shared/

# 4. Review changes across all projects
./claude-container --diff-session fullstack-feature

# 5. Merge changes back to all source repos
./claude-container --merge-session fullstack-feature
```

### Configuration File

Create a `.claude-projects.yml` file in your project root:

```yaml
version: "1"
projects:
  frontend:
    path: ./frontend          # Relative to config file location
  backend:
    path: ./backend
  shared-lib:
    path: ../shared-library   # Can reference parent directories
  mobile:
    path: /absolute/path/to/mobile  # Absolute paths work too
```

**Path Resolution:**
- Relative paths (starting with `./` or `../`) are resolved relative to the config file location
- Absolute paths (starting with `/`) are used as-is
- All paths must point to valid git repositories

**Config Discovery Order:**
1. `--config <path>` CLI flag (highest priority)
2. `./.claude-projects.yml`
3. `./.devcontainer/claude-projects.yml`
4. `./claude-projects.yml`
5. Falls back to single-repo mode if no config found

### Example: Monorepo-Style Workspace

For a directory structure like:
```
~/dev/myproject/
├── .claude-projects.yml
├── frontend/          # React app
├── backend/           # Node.js API
├── mobile/            # React Native app
└── shared/            # Shared TypeScript types
```

Config file:
```yaml
version: "1"
projects:
  frontend:
    path: ./frontend
  backend:
    path: ./backend
  mobile:
    path: ./mobile
  shared:
    path: ./shared
```

Inside the container:
```
/workspace/
├── frontend/      # Full clone of frontend repo
├── backend/       # Full clone of backend repo
├── mobile/        # Full clone of mobile repo
└── shared/        # Full clone of shared repo
```

### Example: All Repos in a Directory (Easy Way)

Use `--discover-repos` to automatically find and clone all git repos in a directory - **no config file needed!**

```bash
# Single command - discovers all git repos automatically
./claude-container -s my-feature --discover-repos ~/dev/hypermemetic
```

Output:
```
→ Discovering git repositories in: ~/dev/hypermemetic
→   ✓ Found: hub-codegen
→   ✓ Found: hub-core
→   ✓ Found: hub-macro
→   ✓ Found: substrate
→   ✓ Found: synapse
... (discovers all repos)
✓ Discovered 10 repositories
→ Creating multi-project session: my-feature
→ Cloning project 'hub-codegen'...
✓   ✓ Cloned: hub-codegen
...
✓ Multi-project session created: my-feature (10 projects)
```

### Example: All Repos in a Directory (Config File)

If you prefer a config file (useful for sharing with team or excluding certain repos):

```bash
# Generate config for all git repos in a directory
cd ~/dev/hypermemetic

cat > .claude-projects.yml << 'EOF'
version: "1"
projects:
EOF

for dir in */; do
    if [[ -d "$dir/.git" ]]; then
        name=$(basename "$dir")
        echo "  $name:" >> .claude-projects.yml
        echo "    path: ./$dir" >> .claude-projects.yml
    fi
done

# Then start session (config auto-detected)
./claude-container -s hypermemetic-all
```

### Creating a Multi-Project Session

```bash
# Auto-discover repos in a directory (no config needed!)
./claude-container -s feature-name --discover-repos ~/dev/myprojects

# Auto-detect config in current directory
./claude-container -s feature-name

# Explicit config path
./claude-container -s feature-name --config ~/my-projects.yml

# Create session without starting container (for testing)
./claude-container -s feature-name --no-run
```

**What happens during creation:**
1. Validates the config file (YAML syntax, required fields)
2. Checks all project paths exist and are git repositories
3. Creates a Docker volume for the session
4. Stores the config (with absolute paths) in the volume
5. Clones each repository into `/workspace/{project-name}/`
6. Configures git in each repo (user, email, strips remotes)
7. Fixes file ownership for the host user

**Output example:**
```
→ Multi-project config detected: /Users/you/dev/.claude-projects.yml
→ Validating multi-project config...
→   ✓ frontend: /Users/you/dev/frontend
→   ✓ backend: /Users/you/dev/backend
→   ✓ shared: /Users/you/dev/shared
✓ Config validation passed
→ Creating multi-project session: my-feature
→ Storing config in session volume...
→ Config stored successfully
→ Cloning project 'frontend' from /Users/you/dev/frontend...
✓   ✓ Cloned: frontend
→ Cloning project 'backend' from /Users/you/dev/backend...
✓   ✓ Cloned: backend
→ Cloning project 'shared' from /Users/you/dev/shared...
✓   ✓ Cloned: shared
→ Fixing ownership...
✓ Multi-project session created: my-feature (3 projects)
```

### Working with Multi-Project Sessions

Once inside the container, Claude can work across all projects:

```
You: Add a new User type to shared, update the backend API to use it,
     and update the frontend to consume the new API

Claude: I'll coordinate changes across all three repos:

1. First, I'll add the User type to shared:
> cd /workspace/shared
> [creates types/user.ts]
> git add types/user.ts
> git commit -m "Add User type definition"

2. Now update the backend to use it:
> cd /workspace/backend
> [updates API routes to use User type]
> git add src/routes/users.ts
> git commit -m "Update API to use shared User type"

3. Finally, update the frontend:
> cd /workspace/frontend
> [updates React components]
> git add src/components/UserProfile.tsx
> git commit -m "Update frontend to use new User type"

All three projects are now in sync with the new User type!
```

### Viewing Changes

**Summary view** (shows all projects):
```bash
./claude-container --diff-session feature-name
```

Output:
```
→ Multi-project session: feature-name

Project: frontend (2 commits)
  abc1234 Add login form
  def5678 Update styles

Project: backend (1 commit)
  ghi9012 Add auth endpoint

Project: shared (1 commit)
  jkl3456 Add User type

Project: mobile (0 commits)
  (no changes)

Tip: Use --diff-session feature-name <project-name> to see detailed changes for a specific project
```

**Detailed view** (specific project):
```bash
./claude-container --diff-session feature-name frontend
```

Shows detailed diff and file changes for just the `frontend` project:
```
=== Commits in session ===
abc1234 Add login form
def5678 Update styles

=== File changes (session vs source) ===
 src/components/Login.tsx  | 45 +++++++++++++++++++++---------
 src/styles/login.css      | 12 ++++++++
 2 files changed, 42 insertions(+), 15 deletions(-)

[detailed diff output...]
```

**Check specific project:**
```bash
# Quick check if a project has changes
./claude-container --diff-session feature-name backend | grep "commits"
```

### Merging Changes

**Interactive merge** (select which projects to merge):
```bash
./claude-container --merge-session feature-name
```

Output:
```
=== Merging multi-project session: feature-name ===

Projects to merge:
  [x] frontend (2 commits)
  [x] backend (1 commit)
  [x] shared (1 commit)
  [ ] mobile (0 commits - skipped)

Merge all selected? [y/n/select] y

→ Merging project: frontend
  Applied: 0001-Add-login-form.patch
  Applied: 0002-Update-styles.patch
✓ Merged 2 commit(s) to frontend

→ Merging project: backend
  Applied: 0001-Add-auth-endpoint.patch
✓ Merged 1 commit(s) to backend

→ Merging project: shared
  Applied: 0001-Add-User-type.patch
✓ Merged 1 commit(s) to shared

✓ Successfully merged all projects (3 projects)

Delete session 'feature-name'? [y/n]
```

**Auto-merge** (merge all projects with commits, no prompts):
```bash
./claude-container --merge-session feature-name --auto
```

**Merge to specific branch** (creates/switches branch in each project):
```bash
./claude-container --merge-session feature-name --into claude/feature-name
```

This will:
- Create or switch to branch `claude/feature-name` in each project
- Apply commits to that branch
- Leave you ready to review and push

**Selective merge** (just one project):
```bash
# First, copy patches manually
./claude-container-cp feature-name:/workspace/frontend/.git/patches ./frontend-patches

# Then apply manually in your source repo
cd ~/dev/frontend
git am ./frontend-patches/*.patch
```

### Merge Behavior

**Per-project merging:**
- Each project is merged independently to its source repository
- Projects without commits are automatically skipped
- Merge uses `git format-patch` and `git am` (preserves commit metadata)
- If a merge fails in one project, others continue
- Failed merges show instructions for manual resolution

**Conflict resolution:**
```
→ Merging project: frontend
  Applied: 0001-Add-login-form.patch
  Failed to apply: 0002-Update-styles.patch
  Run 'git am --abort' to cancel in: /Users/you/dev/frontend

✗ Merge completed with errors (1 succeeded, 1 failed)
```

To resolve:
```bash
cd ~/dev/frontend
git am --show-current-patch    # See what failed
# Fix conflicts manually
git add .
git am --continue
```

### Requirements and Validation

**Config file requirements:**
- Valid YAML syntax (version: "1")
- `projects` key with at least one project
- Each project must have a `path` field
- Project names must be unique

**Project requirements:**
- Path must exist on filesystem
- Path must be a git repository (has `.git` directory)
- No reserved names: `.git`, `.claude`, `.devcontainer`, `workspace`, `session`

**Validation errors:**
```bash
# Missing repo
✗ Project 'frontend': path does not exist: /Users/you/dev/frontend

# Not a git repo
✗ Project 'backend': not a git repository: /Users/you/dev/backend

# Duplicate name
✗ Duplicate project name: shared

# Reserved name
✗ Reserved project name: workspace
```

### Real-World Examples

#### Example 1: Full-Stack Feature Development

**Setup:**
```yaml
# .claude-projects.yml
version: "1"
projects:
  web:
    path: ./web-app
  api:
    path: ./api-server
  types:
    path: ./shared-types
```

**Workflow:**
```bash
# Start session
./claude-container -s user-authentication

# Inside container, ask Claude:
"Implement user authentication with JWT tokens. Add the auth endpoints
to the API, update shared types, and create a login form in the web app."

# Claude makes coordinated changes across all three repos with commits

# Exit and review
./claude-container --diff-session user-authentication

# Merge to feature branches
./claude-container --merge-session user-authentication --into feature/auth

# Push all branches
cd ~/dev/web-app && git push -u origin feature/auth
cd ~/dev/api-server && git push -u origin feature/auth
cd ~/dev/shared-types && git push -u origin feature/auth
```

#### Example 2: Microservices Update

**Setup:**
```yaml
# .claude-projects.yml
version: "1"
projects:
  users-service:
    path: ./services/users
  orders-service:
    path: ./services/orders
  notifications-service:
    path: ./services/notifications
  shared-proto:
    path: ./proto
```

**Workflow:**
```bash
./claude-container -s add-user-preferences

# Ask Claude:
"Add user preferences to the proto definitions, update the users service
to store them, and update notifications service to respect user
notification preferences"

# Claude updates all affected services + proto definitions

./claude-container --merge-session add-user-preferences --auto
```

#### Example 3: Library Refactoring

**Setup:**
```yaml
# .claude-projects.yml
version: "1"
projects:
  core:
    path: ./packages/core
  plugin-auth:
    path: ./packages/plugin-auth
  plugin-storage:
    path: ./packages/plugin-storage
  examples:
    path: ./examples
```

**Workflow:**
```bash
./claude-container -s refactor-plugin-api

# Ask Claude:
"Refactor the plugin API in core to use async/await instead of callbacks.
Update all plugins and examples to use the new API."

# Review changes per project
./claude-container --diff-session refactor-plugin-api core
./claude-container --diff-session refactor-plugin-api plugin-auth

# Merge
./claude-container --merge-session refactor-plugin-api
```

### Tips and Best Practices

**Start small:**
- Begin with 2-3 related repos
- Verify the workflow before adding more projects

**Use descriptive session names:**
```bash
# Good
./claude-container -s add-graphql-api-and-client

# Less helpful
./claude-container -s test
```

**Review before merging:**
```bash
# Always check the diff first
./claude-container --diff-session my-feature

# Review each project individually
./claude-container --diff-session my-feature frontend
./claude-container --diff-session my-feature backend
```

**Use feature branches:**
```bash
# Merge to branches for review
./claude-container --merge-session my-feature --into claude/my-feature

# Then review and test before merging to main
```

**Keep sessions focused:**
- One session = one feature/task
- Don't accumulate too many unrelated changes
- Merge or discard sessions regularly

**Config in version control:**
```bash
# Commit the config for team use
git add .claude-projects.yml
git commit -m "Add multi-project config for claude-container"
```

### Troubleshooting Multi-Project Sessions

**Config not detected:**
```bash
# Specify explicitly
./claude-container -s my-feature --config ./.claude-projects.yml

# Check file location and name
ls -la .claude-projects.yml
```

**YAML parsing errors:**
```bash
# Validate YAML syntax
yq eval .claude-projects.yml

# Or with Python
python3 -c "import yaml; yaml.safe_load(open('.claude-projects.yml'))"
```

**"No YAML parser found" error:**
```bash
# Install yq (recommended)
brew install yq  # macOS
sudo apt-get install yq  # Ubuntu/Debian

# Or install PyYAML
pip3 install pyyaml
```

**Projects not cloning:**
```bash
# Check all paths exist
for proj in frontend backend shared; do
    ls -ld ./$proj
done

# Check they're git repos
for proj in frontend backend shared; do
    ls -la ./$proj/.git
done
```

**Merge conflicts:**
```bash
# Per-project conflict resolution
cd ~/dev/frontend
git am --show-current-patch
# Fix conflicts
git add .
git am --continue
```

**Want to exclude a project temporarily:**
```yaml
# Comment it out in the config
version: "1"
projects:
  frontend:
    path: ./frontend
  backend:
    path: ./backend
  # shared:
  #   path: ./shared  # Temporarily disabled
```

### Limitations

**What multi-project sessions DON'T do:**
- Don't enforce consistency checks across repos
- Don't validate cross-repo references
- Don't handle git submodules specially (they're cloned as independent projects)
- Don't support non-git repositories
- Don't support nested project structures (project within a project)

**Current limits:**
- No hard limit on number of projects (tested with 10+)
- Each project is cloned independently (disk space scales linearly)
- Merge is sequential (not parallel)

### Single vs Multi-Project Mode

When no `.claude-projects.yml` config file exists, single-repo mode is used (clones current directory). When a config file exists, multi-project mode automatically enables.

```bash
# No config file = clone current repo only
./claude-container -s feature-name

# With config file = clone all configured projects
./claude-container -s feature-name
```

To temporarily disable multi-project mode, rename or remove the config file, or use `--no-git-session` for direct mount.

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

### List Sessions with Disk Usage

```bash
./claude-container --sessions
# or: ./claude-container --list-sessions
```

Output shows disk usage per volume type:
```
SESSION                         WORKSPACE      STATE      CARGO        NPM        PIP
-------                         ---------      -----      -----        ---        ---
cllient-review                       4.1G       4.0K       4.0K       4.0K       4.0K
default                                 -      30.1M     212.1M       1.5M       4.0K
hypermemetic-all                     7.6G          -          -          -          -
my-feature                          25.1M          -          -          -          -

Total disk usage: 14.8G

Commands:
  Delete session:  ./claude-container --delete-session <name>
  Delete all:      ./claude-container --cleanup
```

**Column meanings:**
- **WORKSPACE**: Your cloned repos (`/workspace/*`)
- **STATE**: Claude conversation history and settings
- **CARGO/NPM/PIP**: Package manager caches (shared across sessions by default)

### Delete a Session

```bash
./claude-container --delete-session feature-name
```

This deletes all volumes associated with the session (workspace, state, and caches).

### Import a Session

Import an existing claude-code session (conversation history, plans, etc.) into a container:

```bash
# Import from your local claude session
./claude-container --import-session ~/.claude my-session

# Import from a backup
./claude-container --import-session /path/to/backup my-session

# Force overwrite existing session
./claude-container --import-session ~/.claude my-session --force
```

After importing, use the session with `--continue` to load the conversation history:

```bash
./claude-container -s my-session --continue
```

The imported session data includes conversation history, plans, todos, and environment state. This is useful for:
- Migrating conversations from standalone claude-code to containers
- Sharing session context between environments
- Restoring from backups

See [SESSION_IMPORT.md](SESSION_IMPORT.md) for detailed documentation and testing instructions.

### Clean Up All Sessions

```bash
./claude-container --cleanup
```

Lists all claude-container volumes and prompts before deleting.

## Common Workflows

### Feature Development

```bash
# 1. Start isolated session
./claude-container -s new-feature 
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
./claude-container -s debug-issue-123

# 2. Have Claude investigate and fix
#    "Investigate why users are getting 500 errors on /api/checkout"

# 3. If the fix is good, merge it
./claude-container --merge-session debug-issue-123

# 4. If not useful, just delete
./claude-container --delete-session debug-issue-123
```

## Skill Integration

Claude Code can help you configure and launch container sessions through an interactive skill. This provides a guided setup experience where Claude asks questions about your session needs, validates the configuration, and outputs the command to run.

### How It Works

1. **Inside Claude Code**: Run the `/container-setup` skill (or ask Claude to set up a container session)
2. **Claude collects information**: Session name, repos, runtime options, etc.
3. **Validation**: Claude runs `--no-run` to verify the configuration works (clones repos, creates volumes)
4. **Output**: Claude displays the session name and full command, optionally copying to clipboard
5. **Run the container**: Execute the command to start your pre-configured session

### Example Workflow

```bash
# 1. Start Claude Code normally
claude

# 2. Inside Claude Code, use the skill
> /container-setup

# Claude asks:
# - What should the session be named?
# - Where are your repositories?

# 3. Claude validates with --no-run, outputs:
#    Session ready: my-feature
#    Run: claude-container -s my-feature
#    (copied to clipboard)

# 4. Exit Claude Code and run the command
claude-container -s my-feature
```

Since `--no-run` already clones all repos and sets up the session, the final command just resumes the existing session and starts the container.

### Extracting Generated Artifacts

```bash
# 1. Have Claude generate documentation, reports, etc.
./claude-container -s docs

# 2. Copy out the generated files
./claude-container-cp docs:/workspace/generated-docs ./docs

# 3. Delete the session (we just wanted the files)
./claude-container --delete-session docs
```

### Sharing State Across Sessions

```bash
# Multiple git sessions can share conversation history
./claude-container -s experiment-1 --session shared-context
./claude-container -s experiment-2 --session shared-context

# Both sessions will have access to the same Claude conversation history
```

## Using a Custom Dockerfile

By default, claude-container uses the pre-built default image. To use a custom Dockerfile, use the `--dockerfile` flag.

Create a Dockerfile with your project-specific dependencies:

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
# Use local Dockerfile (searches ./Dockerfile, ./.devcontainer/Dockerfile, ./docker/Dockerfile)
./claude-container -s my-feature --dockerfile

# Use a specific Dockerfile
./claude-container -s my-feature -f ./custom/Dockerfile

# Force rebuild
./claude-container -s my-feature --dockerfile --build
```

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
./claude-container --build -s feature-name

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
