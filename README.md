# claude-container

Run Claude Code in an isolated Docker container. Claude gets full autonomous access to cloned repos without touching your host filesystem. Changes stay in the container until you explicitly pull them out.

## Quick Start

```bash
claude-container -s my-feature                    # create session from cwd
# Claude works autonomously in the container...
claude-container pull -s my-feature main           # squash-merge into main
```

## Installation

### Prerequisites

- **Docker** (Docker Desktop, Colima, or native)
- **Claude Code OAuth token** -- set `CLAUDE_CODE_OAUTH_TOKEN`
- **yq** -- required for multi-project sessions (`brew install yq` / `apt install yq`)
- **pv** -- optional, shows progress during extraction (`brew install pv`)

### Install

```bash
git clone https://github.com/juggernautlabs/claude-container.git
cd claude-container
export PATH="$PATH:$(pwd)"
# Or: ln -s $(pwd)/claude-container /usr/local/bin/
```

## Workflows

### Basic session: create, resume, extract, merge

```bash
# Start a session (clones cwd into a container)
claude-container -s my-feature

# Resume an existing session and continue the conversation
claude-container -s my-feature --continue

# Extract session branches to host (no merge)
claude-container pull -s my-feature

# Extract and squash-merge into main
claude-container pull -s my-feature main

# Preview before merging
claude-container pull -s my-feature main --verify

# Extract + discuss merge state with Claude before deciding
claude-container pull -s my-feature main --discuss
```

### Live development with watch

Watch a session for commits and auto-pull on every change. Changes that arrive during command execution are coalesced -- the command re-runs once after completion.

```bash
# Auto-pull into main whenever Claude commits
claude-container watch -s my-feature -- claude-container pull -s my-feature main

# Watch one repo, fast polling, chain with a build
claude-container watch -s my-feature --repo gamma -i 2 -- sh -c \
  'claude-container pull -s my-feature main && cd ~/dev/myproj && bun run build'
```

### Sync session with host (push)

Push brings host changes into the container. Four strategies, mutually exclusive:

```bash
# Fast-forward (default) -- fails if diverged
claude-container push -s my-feature main

# Merge main into session -- launches container if conflicts
claude-container push -s my-feature main --merge

# Rebase session onto main -- launches container if conflicts
claude-container push -s my-feature main --rebase

# Serve main as a branch the agent can merge at its own pace
claude-container push -s my-feature main --as host/main
# Agent inside container: git merge host/main
```

### Conflict resolution

Conflicts are always resolved inside the container where Claude can help, never on your host.

```bash
# Option A: push main into session, let Claude resolve, then pull clean
claude-container push -s my-feature main --merge
claude-container pull -s my-feature main

# Option B: full reconcile cycle (stash, merge, resolve, merge back)
claude-container pull -s my-feature main --reconcile
```

### Multi-project sessions

Work across multiple repositories in a single session:

```bash
# Auto-discover git repos in a directory
claude-container -s my-feature --discover-repos ~/dev/myorg

# Or add repos individually
claude-container -s my-feature -a ~/dev/api -a ~/dev/frontend

# Or use a config file
claude-container -s my-feature --config .claude-projects.yml
```

Config file format:

```yaml
# .claude-projects.yml
version: "1"
main: backend/api
dockerfile: ./Dockerfile.dev    # optional
projects:
  backend/api:
    path: ~/dev/api
  backend/workers:
    path: ~/dev/workers
  frontend/web:
    path: ~/dev/webapp
```

Inside the container, repos are laid out under `/workspace/`:

```
/workspace/
  backend/
    api/        # main project (initial working directory)
    workers/
  frontend/
    web/
```

### Repo management

Manage repos in an existing session without recreating it:

```bash
# List repos in a session
claude-container repos -s my-feature

# Add repos by path
claude-container repos -s my-feature add --repo ~/dev/org/repo1,~/dev/org/repo2

# Remove repos by name (partial match OK)
claude-container repos -s my-feature remove --repo old-thing

# Find repos the agent created inside the session
claude-container repos -s my-feature discover

# Extract discovered repos to host
claude-container pull -s my-feature --extract
claude-container pull -s my-feature --extract --repo new-thing
```

## Command Reference

### Session Creation

```
claude-container -s <name> [options] [-- <claude-args>]
```

| Flag | Description |
|------|-------------|
| `-s, --session <name>` | Session name (required) |
| `--from <branch>` | Create session from a specific branch |
| `-c, --continue` | Continue the most recent conversation |
| `-a, --add-repo <path>` | Add a repo (repeatable) |
| `--discover-repos <dir>` | Auto-discover git repos in directory (repeatable) |
| `-C, --config <path>` | Path to `.claude-projects.yml` |
| `--dirty` | Capture uncommitted host changes as a WIP commit in the session |
| `--dockerfile [path]` | Build and use a custom Dockerfile (auto-detected or from config) |
| `--docker` | Mount Docker socket for host Docker access |
| `-p, --port <port>` | Expose a port (e.g. `3000`, `8080:80`). Persisted across restarts. |
| `--clone-from <session>` | Clone volumes from an existing session |
| `--shell, --bash` | Start bash instead of Claude |
| `--bash-exec <cmd>` | Execute a bash command and exit |
| `--no-git-session` | Mount cwd directly (no git clone isolation) |
| `--no-run` | Set up session without starting the container |
| `--no-config` | Skip auto-discovery of `.claude-projects.yml` |
| `--as-user` | Run as non-root developer (no sudo) |
| `--as-rootish` | Developer with passwordless sudo (default) |
| `--as-root` | Run as actual root |
| `-- <args>` | Pass remaining args to Claude (e.g. `-- -p "explain this"`) |

### pull -- container to host

```
claude-container pull -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| *(no branch)* | Extract session branches to host repos only |
| `<branch>` | Extract + squash-merge into target branch |
| `--extract` | Extract repos discovered in-session (created by agent). Combine with `--repo` for specific repos. |
| `--verify` | Show preview, then prompt before merging |
| `--discuss` | Preview + launch Claude to discuss merge state before deciding |
| `--reconcile, -R` | Full cycle: stash, merge target into session, resolve conflicts, merge back |
| `--squash` | Squash-merge into target (default) |
| `--no-squash` | Regular merge (preserves full commit history) |
| `--repo <name>` | Only pull this repo (partial name OK, repeatable) |
| `--status` | Read-only comparison, no extraction |
| `--dry-run` | Preview what would happen |
| `--force, -f` | Force extraction if branches diverged |

### push -- host to container

```
claude-container push -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| `--ff` | Fast-forward from host branch (default) |
| `--merge` | Merge host branch into session. Launches container on conflicts. |
| `--rebase` | Rebase session onto host branch. Launches container on conflicts. |
| `--as <branch>` | Place host branch in container as `<branch>` without merging |
| `--verify` | Preview and confirm before proceeding |
| `--discuss` | Preview + launch Claude to discuss merge state |
| `--dry-run` | Preview only |
| `--repo <name>[,<branch>]` | Only push this repo, optionally from a specific host branch |
| `--force, -f` | Force operation (reset diverged repos to host HEAD) |

### watch

```
claude-container watch -s <session> [options] -- <command...>
```

| Flag | Description |
|------|-------------|
| `--repo <name>` | Only watch this repo |
| `--interval, -i <secs>` | Poll interval (default: 5) |

Runs the command once on startup, then again on every detected change.

### status

```
claude-container status -s <session> [branch] [options]
```

| Flag | Description |
|------|-------------|
| *(no branch)* | Sync classification: synced/unchanged/extracted-only/not-extracted/missing |
| `<branch>` | Hash comparison against host branch with ancestry info |
| `--dirty` | Check which host repos have uncommitted changes |
| `--repo <name>` | Filter to a single repo |

Exit code 0 = all synced, 1 = at least one mismatch or pending.

### list

```bash
claude-container list                  # sessions with last-active time
claude-container list --sizes          # include disk usage (slower)
claude-container list --name-only      # just names (for scripting)
```

### repos

```
claude-container repos -s <session> <action> [options]
```

| Action | Description |
|--------|-------------|
| `list` (default) | List repos in session, flag discovered-but-unextracted repos |
| `add --repo <paths>` | Add repos by path (comma-separated or repeat `--repo`) |
| `remove --repo <names>` | Remove repos by name (partial match) |
| `discover` | Find repos agent created inside the session, prompt to promote for extraction |

Supports `--dry-run` and `--force` on all actions.

### remove

```
claude-container remove -s <session> --include <pattern> [--exclude <pattern>]
```

Bulk-remove repos using glob patterns. `--exclude` overrides `--include`.

```bash
claude-container remove -s myproj --include 'juggernautlabs/*' --exclude substrate
claude-container remove -s myproj --include '*tui*' --dry-run
```

### serve

```
claude-container serve -s <session> [branch] [--repo <name>]
```

Bundle host git branches and drop them into the session volume. The agent can then fetch and merge at its own pace:

```bash
claude-container serve -s my-feature main
# Inside container: sh /session/.host/.fetch-host && git merge host/main
```

Combine with `watch` for continuous serving:

```bash
claude-container watch -s my-feature -- claude-container serve -s my-feature main
```

### image

```bash
claude-container image -s my-feature   # show image for a session
claude-container image                 # list all running sessions and their images
```

### reconcile -- merge multiple sessions

```
claude-container reconcile <branch> [session...] [options]
```

| Flag | Description |
|------|-------------|
| `--include <regex>` | Only process matching sessions (repeatable) |
| `--exclude <regex>` | Skip matching sessions (repeatable, wins over include) |
| `--dry-run` | Preview without merging |
| `--yes, -y` | Skip confirmation |
| `--continue` | Resume interrupted reconcile |
| `--force, -f` | Force extraction |

Sessions are processed sequentially. When conflicts are detected, a container is launched for Claude to resolve them. After exit, `--continue` picks up where it left off. If no sessions are listed, auto-discovers sessions with unmerged work.

### Session management

```bash
claude-container -s my-feature --delete             # delete session volumes
claude-container -s my-feature --delete --yes        # skip confirmation
claude-container -s 'test-.*' --delete --regex       # pattern match
claude-container -s my-feature --repair              # fix corrupted config
claude-container -s my-feature --restart             # restart (fixes permissions)
claude-container -s my-feature --import ~/.claude     # import session data
claude-container -s new-feat --clone-from old-feat   # clone volumes from another session
```

## How Squash-Merge Works

When you `pull -s X main`, the session's commits are squash-merged into a single commit on main:

1. **First pull**: `git merge --squash` + commit. Saves a squash-base ref.
2. **Repeat pulls**: Cherry-picks only commits AFTER the squash-base. One commit per pull, carrying the original session commit messages.
3. **Conflict detection**: Dry-runs the merge first. If it would conflict, reports the files and suggests `--reconcile`.

The squash-base ref (`refs/claude-container/squash-base/<session>`) tracks what was already merged. If the session branch is force-extracted from a different lineage, stale refs are automatically cleared.

## Security

- **Tokens**: Stored in file mount, not environment variables
- **Git remotes**: Stripped from cloned repos (Claude cannot push to your remotes)
- **Rootish mode**: Non-root user with passwordless sudo (default)
- **Isolation**: Changes stay in volumes until explicitly extracted
- **Workspace trust**: Auto-accepted inside containers (safe -- isolated environment)

## License

MIT
