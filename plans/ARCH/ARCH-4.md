# ARCH-4: Session Scripts (Create, Discover, Config, Add-Repo)

blocked_by: [ARCH-2]
unlocks: [ARCH-7]

## Goal

Extract session management into standalone scripts. A session is: a named set of volumes + a config file + cloned repos. These scripts manage that state.

## Scripts

### 1. `lib/session/cc-session-create`

```
USAGE: cc-session-create <session_name> <config_file|--discover-repos <dir>>
READS: config file or discovered repos, host git repos
WRITES: session volume (clones repos), .claude-projects.yml, .main-project, .repo-manifest
DESTROYS: nothing (refuses if session already exists, use --force to recreate)
```

Extracted from: `create_git_session()`, `create_multi_project_session()` in git-session.sh

### 2. `lib/session/cc-session-discover`

```
USAGE: cc-session-discover <directory> [--json]
READS: filesystem (scans for git repos)
WRITES: temp config file (stdout or --output)
DESTROYS: nothing
```

Pure function: scans a directory, outputs a config. Doesn't touch volumes.

Extracted from: `discover_repos_multi()` in config.sh

### 3. `lib/session/cc-session-config`

```
USAGE: cc-session-config <session_name> show|get|set|unset [key] [value]
READS: session metadata (.env file), volume config (.claude-projects.yml)
WRITES: session metadata (.env file)
DESTROYS: nothing
```

Manages the session's .env metadata file. Also reads from volume for display.

Extracted from: session metadata reading/writing in main script, `_session_set`/`_session_unset` in session.sh

### 4. `lib/session/cc-session-add-repo`

```
USAGE: cc-session-add-repo <session_name> <repo_path> [<repo_path> ...]
READS: host git repos, session volume
WRITES: clones into session volume, updates .claude-projects.yml
DESTROYS: nothing
```

Extracted from: `session_add_repo()`, `session_add_repos_bulk()` in session-mgmt.sh

### 5. `lib/session/cc-session-volumes`

```
USAGE: cc-session-volumes <session_name> create|check|list|repair
READS: Docker volumes
WRITES: creates volumes (create), fixes permissions (repair)
DESTROYS: nothing (no volume deletion — that's a separate dangerous operation)
```

Manages the 5 volumes per session (session, state, cargo, npm, pip).

Extracted from: volume creation scattered through git-session.sh and session-mgmt.sh

## Acceptance Criteria

1. `cc-session-create` refuses to overwrite an existing session without `--force`
2. `cc-session-discover` is pure — outputs config, doesn't modify state
3. Session config is the single source of truth (not scattered .env + volume + docker inspect)
4. Double-discovery bug is impossible (discovery runs in exactly one place)
5. `cc-session-volumes` can check and repair volume permissions independently

## Files

| File | Extracted from |
|------|---------------|
| `lib/session/cc-session-create` | `create_git_session()`, `create_multi_project_session()` |
| `lib/session/cc-session-discover` | `discover_repos_multi()` |
| `lib/session/cc-session-config` | session metadata in main script + session.sh |
| `lib/session/cc-session-add-repo` | `session_add_repo()`, `session_add_repos_bulk()` |
| `lib/session/cc-session-volumes` | volume creation/repair across git-session.sh |
