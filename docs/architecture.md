# Architecture

## Design Philosophy

Claude-container is a **host program with an embedded agent**. The host program orchestrates isolated Docker environments where Claude Code operates on source code without risk to original repositories. The agent becomes the primary interface: the developer provides high-level direction while the agent handles implementation.

```
Host System (trusted)          Container (agent sandbox)
─────────────────────          ─────────────────────────
Original repositories    ──>   Cloned copies (no remotes)
User credentials         ──>   OAuth token only
Full filesystem          ──>   Session volume only
Docker socket            ──>   Optional, explicit opt-in
```

**Core invariant**: Host repos are never modified during a session. All changes live in Docker volumes until explicitly extracted via `pull`.

**Why git clone, not bind mounts**: Bind-mounting host directories lets the agent modify originals directly. Git clone provides snapshot isolation, change tracking via commits, and a review gate before integration. Remotes are stripped so the agent cannot push anywhere.

**Why an embedded agent**: Containment (mistakes are recoverable), persistence (conversation history survives across invocations), integration (full access to dev tools inside container), and safety (explicit extraction required to affect host).

## Subcommands

| Subcommand | Purpose |
|------------|---------|
| `pull` | Extract session changes to host repos (container to host) |
| `push` | Push host changes into session (host to container) |
| `status` | Check sync state between session and host (read-only) |
| `watch` | Watch session for changes and auto-extract |
| `repos` | Show repos in a session with container state from snapshot |
| `list` | List all sessions (with optional `--sizes` for disk usage) |
| `remove` | Remove repos from a session |
| `serve` | Push a host branch into session under a different name |
| `reconcile` | Merge multiple sessions into a target branch sequentially |
| `image` | Show or manage the Docker image for a session |

Subcommands are dispatched by matching the first positional argument against files/directories in `lib/commands/`. Each subcommand sources its own module and calls `cmd_<name>`.

## Session Lifecycle

```
create ──> work ──> exit ──> pull ──> push ──> re-enter ──> pull ──> delete
                              |         |
                              v         v
                          host repos  session repos
                          get branches get host updates
```

### Create

```bash
claude-container -s my-feature
claude-container -s my-feature --discover-repos ~/dev     # auto-discover
claude-container -s my-feature -a ~/repo1 -a ~/repo2      # explicit repos
```

1. Docker volumes created (5 per session).
2. Repos cloned into session volume via `git bundle` (only git data, no build artifacts). Full history preserved (no `--depth 1`) to support merge/rebase. Branch selection via `--from <branch>` or current HEAD.
3. All remotes stripped from cloned repos.
4. `.claude-projects.yml` written to volume root (tracks repo-to-host-path mappings).
5. `.repo-manifest` written (root commit hashes for change detection).
6. `.main-project` marker set (determines initial working directory).
7. Container launched with Claude Code.

If the volume already exists, creation is skipped entirely (early return). `--continue` resumes the most recent Claude conversation. Session metadata (ports, user mode, dockerfile) reloaded from the `.env` file.

### Work

Inside the container, the agent receives instructions, reads/modifies files, runs builds and tests, and commits to local git. The developer guides with high-level goals and can exit/resume at will.

### Extract and Integrate

`pull` extracts session changes as branches in host repos. Standard git workflow (rebase, merge, push) handles integration. The developer maintains full control over what gets merged.

### Delete

```bash
claude-container -s my-feature --delete [--yes]
claude-container -s 'test-.*' --delete --regex     # pattern match
```

Deletes all 5 volumes plus metadata. Stops running containers first.

## Volumes

Each session creates 5 Docker volumes:

| Volume | Mount Point | Purpose |
|--------|-------------|---------|
| `claude-session-{name}` | `/workspace` | Git repos + config files |
| `claude-state-{name}` | `/home/developer/.claude` | Conversation history, settings |
| `claude-cargo-{name}` | `/home/developer/.cargo` | Rust cargo cache |
| `claude-npm-{name}` | `/home/developer/.npm` | Node npm cache |
| `claude-pip-{name}` | `/home/developer/.cache/pip` | Python pip cache |

All volumes persist across container restarts. Cache volumes are per-session (not global) to avoid permission conflicts.

### Volume Layout

```
/workspace/
  .claude-projects.yml          # Config: project name -> host path mappings
  .repo-manifest                # Root-commit|name pairs (written at creation)
  .sync-branch                  # Marker: set during push --rebase
  .merge-into-branch            # Marker: set during push --merge
  .merge-into-summary           # Claude prompt for conflict resolution
  .merge-into-mounts            # Dirty project mounts for exec-back
  .main-project                 # Which project to cd into on container start
  alpha/                        # Git repo (1-level nesting)
  org/beta/                     # Git repo (2-level org/repo nesting)
```

## Extraction Pipeline

Extraction transfers session changes from Docker volumes back to host repositories. It uses `git bundle` to transfer only git data, ignoring `node_modules`, build artifacts, and other non-git content.

### Four Phases

**Phase 1 -- Manifest diff.** Compare `.repo-manifest` (saved at creation) against current volume state. Detect renames (same root commit, different directory name), additions (repos created inside container), and deletions.

**Phase 2 -- Get HEADs.** Single `docker run` scans all repos in the volume for current HEAD hash and `.git` size. Only repos whose HEAD differs from the host branch HEAD proceed to bundling. Unchanged repos are skipped (major performance win).

**Phase 3 -- Bundle changed repos.** Single `docker run` creates bundles in parallel for all changed repos. On the host side, `git fetch <bundle> HEAD` then create/update the session-named branch.

**Phase 4 -- Extract new repos.** Repos found in the volume but not in the original config get bundled and either branched into existing host repos (via org-sibling path inference) or cloned as new repos. New entries are auto-registered in `.claude-projects.yml` inside the volume.

### Branch Update Logic

When extracting to an existing branch: fast-forward is always allowed (session ahead). Diverged state requires `--force`. If the target branch is currently checked out, `git reset --hard FETCH_HEAD` is used instead of `git branch -f`.

### Repo Manifest System

The `.repo-manifest` file is a fingerprint of repos at a known point in time. Each line is `root_commit_hash|directory_name`, sorted alphabetically. The root commit (`git rev-list --max-parents=0 HEAD`) is the repo's identity -- it never changes regardless of branch, commits, or renames.

| Function | Purpose |
|----------|---------|
| `write_repo_manifest($volume)` | Scan all repos in volume, write `.repo-manifest` |
| `read_repo_manifest($volume)` | Read saved manifest from volume |
| `scan_repo_manifest($volume)` | Scan current repo state (live, not from saved file) |
| `diff_repo_manifests($old, $new)` | Compare two manifests, report changes |

Written at session creation (baseline), after extraction (updated state), and after `push --ff` (after fast-forward).

Without the manifest, extraction cannot distinguish "repo renamed inside container" from "new repo + deleted repo" -- they look the same to a naive directory scan.

### Repo Discovery

Five shared functions in `lib/session-discovery.sh` handle config reading and repo resolution:

- **`read_session_config(volume)`** -- reads `.claude-projects.yml` from a volume via `docker run ... cat`.
- **`parse_session_projects(config_content)`** -- parses YAML into `name|path` pairs via `yq eval`.
- **`get_session_heads(volume)`** -- single `docker run` scanning `/session/*/` and `/session/*/*/` for git repos, returning `name|HEAD` pairs.
- **`resolve_repo_host_path(repo_name, projects)`** -- resolves host path: (1) config lookup, (2) org-sibling inference (find `org/*` in config, use parent + basename), (3) CWD fallback.
- **`check_repo_sync_status()`** -- classifies sync state: `unchanged`, `synced`, `extracted_only`, `not_extracted`, or `missing`.

### Auto-Discovery

```bash
claude-container -s my-feature --discover-repos ~/dev/myorg
```

Walks directory one level deep, finds `.git` directories, names repos as `{dirname}/{reponame}`. Skips git worktrees. Warns about large `.git` directories (>10MB).

## Push/Pull Data Flow

### Pull: Container to Host

```bash
claude-container pull -s <session> [branch] [options]
```

**Extract only** (`pull -s X`): Creates/updates a session-named branch in each host repo that has changes. Runs the four-phase extraction pipeline.

**Extract + auto-merge** (`pull -s X main`): Extracts branches, then merges each into the target branch on host. Only clean merges are performed. If a merge would conflict, the repo is skipped with guidance to resolve in-container first.

**Reconcile** (`pull -s X main --reconcile`): Full cycle. Phase 1: extract session branches. Phase 2: stash dirty host work (creates `main-{session}-stash-{timestamp}` branches with WIP commits). Phase 3: merge target into session via `session_merge_into()` -- clean merges auto-complete; conflicts launch the container for Claude to resolve.

**Dry-run** (`pull -s X main --dry-run`): Shows what would happen without extracting or merging.

**Squash-merge tracking**: Pull defaults to `--squash`. Squash merges collapse session history into a single commit on the target branch. Use `--no-squash` to preserve full commit history.

**Repo filter** (`--repo gamma`): Partial name matching. `gamma` matches `hypermemetic/plexus-gamma` via substring. Exact match takes priority; ambiguous matches are rejected. Supports multiple: `--repo a --repo b` or `--repo a,b,c`.

### Push: Host to Container

```bash
claude-container push -s <session> [branch] [options]
```

**Fast-forward (`--ff`, default)**: Fast-forward session repos from a host branch. No container launch needed. Per-repo: add host as `_host` remote, fetch target branch, compare HEADs. Same HEAD skips, ancestor fast-forwards, diverged warns.

**Merge (`--merge`)**: Merge a host branch into each session repo. Single utility image scan checks merge-in-progress and dirty status. Host-side ancestor check skips already-up-to-date repos. Per-repo merge via docker run. If conflicts: write markers (`.merge-into-branch`, `.merge-into-summary`, `.merge-into-mounts`), launch container for Claude to resolve. The utility image defaults to `alpine/git` but is configurable via the `GIT_UTIL_IMAGE` environment variable.

**Rebase (`--rebase`)**: Rebase session branches onto a host branch. Executes `git rebase upstream/{branch}` per repo. Conflicts launch the container with `.sync-branch` marker.

**Serve** (`serve` subcommand): Make a host branch available inside the session volume for the agent to fetch and merge at its own pace.

On diverge (ff mode):
```
push -s X --merge       Merge host branch into session
push -s X --rebase      Rebase session onto host branch
push -s X --ff --force  Force-reset session to host HEAD (discards session changes)
```

### Agentic Merge (Conflict Resolution)

When `push --merge`, `push --rebase`, or `pull --reconcile` encounters conflicts, Claude resolves them inside the container.

```
conflicts detected
      |
      v
Write markers to volume:
  .merge-into-branch    (target branch)
  .merge-into-summary   (Claude's prompt)
  .merge-into-mounts    (dirty repos to mount)
      |
      v
exec claude-container -s {session} --auto-merge
      |
      v
Container launches with initial prompt.
Claude sees: "These repos have conflicts: ..."
Claude resolves <<<<<<< markers.
Claude runs: fin "resolved merge conflicts"
      |
      v
Exit handler:
  1. Check .reconcile-complete marker
  2. session_extract --force
  3. session_auto_merge into target branch
  4. Clean up .merge-into-* markers
```

Claude receives a structured prompt: `OK` (merged cleanly), `CONFLICT` (resolve markers), `DIRTY` (uncommitted changes, host repo mounted read-only at `/host/{repo-name}`), or `SKIP` (no target branch).

The `fin` command (installed at `/usr/local/bin/fin`) writes a description to `/workspace/.reconcile-complete` and kills PID 1 to terminate the container. The exit handler detects the marker and performs extraction + merge.

### Session Snapshot

All container state reading is centralized in `snapshot_session_state()` (`lib/session-discovery.sh`). One `docker run` scans every repo for HEAD, dirty state, merge status, and `.git` size. Local git ops then compute host-side state (session branch, target branch, squash-base, ancestry). Results are written per-repo to a temp dir via `_pull_result_set()`.

All commands (`pull`, `push`, `status`, `reconcile`, `repos`) read from the snapshot. Diffs are computed via `snapshot_diff()` which accounts for squash-base to avoid double-counting already-squashed content.

### Multi-Session Reconcile

```bash
claude-container reconcile <branch> [session...] [options]
```

Merges multiple sessions into a single target branch, sequentially. Auto-discovers sessions with unmerged work if none specified. Supports `--include`/`--exclude` regex filters. Writes a plan to `~/.config/claude-container/.reconcile-plan` (survives interruptions; `--continue` resumes from last completed session).

Per session: extract, auto-merge into target. If conflicts, merge target into session, launch container for Claude to resolve, then extract + merge on exit.

## Multi-Project

### Config Format

```yaml
version: "1"
main: backend/api                    # initial working directory
dockerfile: ./Dockerfile.dev         # optional custom image
projects:
  backend/api:
    path: ~/dev/api
    branch: feature-branch           # optional: clone from specific branch
    track: true                      # optional: include in merge operations (default: true)
  backend/workers:
    path: ~/dev/workers
  frontend/web:
    path: ~/dev/webapp
```

### Config Discovery Order

1. `--config <path>` (explicit flag)
2. `--discover-repos <dir>` (auto-generate)
3. `./.claude-projects.yml`
4. `./.devcontainer/claude-projects.yml`
5. Single-project mode (current directory)

### Container Layout

```
/workspace/
  backend/
    api/          <- main project (initial cwd)
    workers/
  frontend/
    web/
  .claude-projects.yml
  .repo-manifest
  .main-project
```

Extraction creates branches in each original repository that had changes.

## Security Model

### Token Handling

Token source priority (checked in order):

1. `--token <token>` flag
2. `CLAUDE_CODE_OAUTH_TOKEN` env var
3. `~/.config/claude-container/token` file
4. macOS Keychain
5. Interactive OAuth flow

**Secure injection**: Token written to temp file, mounted as `/run/secrets/claude_token:ro`. Not visible in `docker inspect` environment. Cleaned up via trap on INT/TERM.

### Remote Stripping

All git remotes are removed from cloned repos inside the container. The agent cannot push to any remote. Changes only leave the container through explicit `pull` extraction, which the host program controls.

### User Modes (Rootish)

| Flag | User | Sudo | Default |
|------|------|------|---------|
| `--as-rootish` | `developer` | passwordless sudo | **yes** |
| `--as-user` | `developer` | no | |
| `--as-root` | `root` | n/a | |

The `developer` user is created with UID matching the host user to avoid permission issues on volumes.

### Nested Container Support

Claude-container detects when it is running inside another container and adjusts token passing automatically.

**Detection**: Checks for `/.dockerenv`, Docker/containerd markers in `/proc/1/cgroup`, and container environment variables in `/proc/1/environ`. Implemented in `lib/container-detect.sh`.

**Normal mode (host)**: Token stored in temp file with 600 permissions, mounted read-only at `/run/secrets/claude_token`. Not visible in `docker inspect`.

**Nested mode (container-in-container)**: File mounts between containers are not possible, so the token is passed via `CLAUDE_CODE_OAUTH_TOKEN_NESTED` environment variable. The inner container's entrypoint exports it as `CLAUDE_CODE_OAUTH_TOKEN`. This is visible in `docker inspect` -- a deliberate security trade-off for nested functionality.

No user configuration is needed. The system detects the environment and switches modes automatically.

### Trust Assumptions

1. Claude Code is trusted to not be intentionally malicious.
2. Container isolation is sufficient for the threat model (dev workstation, not production).
3. Git history is the audit log for all agent modifications.
4. Human review before merge catches problematic changes.

## Session Import

```bash
claude-container -s my-session --import ~/.claude
claude-container -s my-session --import /path/to/backup --force
```

Imports existing claude-code session data into a container's state volume. Useful for migrating conversations from standalone claude-code to containers, sharing session history, or restoring from backups.

Claude-code sessions (stored in `~/.claude`) contain `history.jsonl` (conversation history), `session-env/` (environment state), `plans/`, and `projects/` (project-specific data).

**Import flow**: Validate source contains claude session files. Create Docker volume `claude-state-{name}`. Copy session data via tar streaming.

**Usage**: After import, `--continue` loads the conversation. The state volume is mounted at `/home/developer/.claude`, where Claude reads `history.jsonl` to restore context.

`--force` overwrites an existing state volume.
