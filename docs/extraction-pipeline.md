# Extraction Pipeline

How session changes get from Docker volumes back to host repositories.

## Volume Layout

Each session lives in a Docker volume named `claude-session-{name}`:

```
/session/
  .claude-projects.yml          # Config: project name → host path mappings
  .repo-manifest                # Root-commit|name pairs (written at session creation)
  .sync-branch                  # Marker: set during --sync, cleaned on exit
  .merge-into-branch            # Marker: set during --merge-into, cleaned on exit
  .merge-into-summary           # Claude prompt for conflict resolution
  .main-project                 # Which project to cd into on container start
  alpha/                        # Git repo (1-level nesting)
  org/beta/                     # Git repo (2-level org/repo nesting)
```

## Config Format (.claude-projects.yml)

```yaml
version: "1"
projects:
  alpha:
    path: /Users/dev/repos/alpha
    branch: main               # optional: branch that was active at session creation
    track: origin/main         # optional: tracking branch
    source: /Users/dev/repos/alpha  # optional: original source path
  org/beta:
    path: /Users/dev/repos/org/beta
```

The `path` field maps back to the host filesystem. This is how extraction knows where to put things.

## Discovery Algorithm (lib/session-discovery.sh)

Five shared functions handle all config reading and repo discovery:

### read_session_config(volume)
Reads `.claude-projects.yml` from a session volume via `docker run ... cat`. Returns YAML content on stdout, empty string if not found.

### parse_session_projects(config_content)
Parses the YAML into `name|path` pairs via `yq eval`. Output:
```
alpha|/Users/dev/repos/alpha
org/beta|/Users/dev/repos/org/beta
```

### get_session_heads(volume)
Single `docker run` that scans `/session/*/` and `/session/*/*/` for git repos. Returns `name|HEAD` pairs:
```
alpha|abc123...
org/beta|def456...
bonus-repo|789abc...
```

### resolve_repo_host_path(repo_name, projects)
Resolves where a repo lives on the host, checked in order:
1. **Config lookup**: exact match in `projects` name|path pairs
2. **Org-sibling inference**: if `repo_name` is `org/new-repo`, find any config project matching `org/*`, use its parent directory + repo basename
3. **CWD fallback**: `$(pwd)/repo_basename`

### check_repo_sync_status(session_head, host_path, session_name, target_branch)
Returns one of:
- **missing**: host repo doesn't exist at the resolved path
- **unchanged**: session HEAD matches host HEAD, or session is ancestor of host (no new work)
- **synced**: session branch extracted AND merged into target branch
- **extracted_only**: session branch exists on host with matching HEAD, but not merged into target
- **not_extracted**: session has changes that haven't been extracted yet

## Bundle Creation Flow

Extraction uses `git bundle` to transfer only git data (ignoring node_modules, build artifacts, etc.):

1. **Validate**: check each config project exists on host
2. **Bundle**: single `docker run` creates bundles in parallel for all projects (`git bundle create ... HEAD`)
3. **Fetch + branch**: for each project on the host, `git fetch <bundle> HEAD` then create/update the session-named branch
4. **New repos**: compare live volume scan against saved `.repo-manifest` to find repos created inside the session. These get bundled and either branched into existing host repos (org-sibling inference) or cloned as new repos.

## Branch Update Logic

When extracting to an existing branch:
- **Fast-forward**: always allowed (session is ahead of existing branch)
- **Diverged**: requires `--force` flag (session and branch have diverged)
- **Checked out**: uses `git reset --hard FETCH_HEAD` instead of `git branch -f`

## New Repo Detection

Uses the repo manifest system (`lib/git-session.sh`):

1. At session creation, `write_repo_manifest` saves `root_commit|name` pairs to `.repo-manifest`
2. At extraction, `scan_repo_manifest` gets the live state
3. `diff_repo_manifests` compares to find additions, deletions, and renames (same root commit, different name)
4. New repos (in live scan but not in saved manifest or config) get extracted via the bundle flow with org-sibling path resolution

## Sync Status Classification

Used by `merge --verify` and the post-exit status display:

```
Session HEAD == Host HEAD?          → unchanged
Session is ancestor of Host HEAD?   → unchanged
Session branch missing on host?     → not_extracted
Session branch HEAD != Session HEAD? → not_extracted (stale extraction)
Session branch merged into target?  → synced
Session branch not merged?          → extracted_only
Host path doesn't exist?            → missing
```

## CLI Entry Points

| Command | What it does |
|---------|-------------|
| `claude-container -s X --extract` | Extract session branches (flag-based) |
| `claude-container extract -s X` | Extract session branches (subcommand) |
| `claude-container extract -s X --auto-merge` | Extract + merge into main |
| `claude-container merge -s X` | Extract + merge into session-named branch |
| `claude-container merge -s X --branch main` | Extract + merge into main |
| `claude-container merge -s X --verify` | Check sync status (read-only) |
| `claude-container -s X --extract --auto-merge develop` | Extract + merge into develop (flag-based) |
