# SYNC-5: Container-Only and Host-Only Repo Handling

blocked_by: []
unlocks: [SYNC-6]

## Problem

Sync classifies repos that exist on only one side (`container_only`, `host_only`) but `execute_sync` doesn't implement the actions for them.

## Case Table

| Case | Container | Host | Detection | Sync Action | Status |
|------|-----------|------|-----------|-------------|--------|
| **Container only** | repo exists | no host path | `host_path` empty or missing | clone from container | this ticket |
| **Host only** | no repo | repo exists | `container_head` empty | push to container | this ticket |

## Gap Table

| Gap | Scenario | What happens now | What should happen |
|-----|----------|-----------------|-------------------|
| Container only + no host dir | Container created a repo, host path doesn't exist | `clone_from_container` action set but `execute_sync` doesn't implement it | Should extract/clone to inferred host path |
| Host only | Host has repo not in container config | `push_to_container` action set but `execute_sync` doesn't implement it | Should `session_add_repo` |

## Acceptance Criteria

### Container-only repos
1. Sync detects repos in the container with no host path
2. Resolves a host path using `resolve_repo_host_path` (org-sibling inference)
3. Extracts/clones the repo to that path
4. Updates `.claude-projects.yml` in the volume with the resolved path
5. Shows the inferred path and asks for confirmation

### Host-only repos
1. Sync detects repos on the host that aren't in the container
2. This requires knowing what repos the user EXPECTS to be in the container — can't just scan the whole filesystem
3. For now: only handle repos in `.claude-projects.yml` that have a host path but no container HEAD
4. Uses `session_add_repo` to clone from host into container
5. Shows the repo and asks for confirmation

## Implementation

### Container-only
In `execute_sync`, add a phase between push and reconcile:
```bash
for _repo in "${_clone_repos[@]}"; do
    local _inferred_path
    _inferred_path=$(resolve_repo_host_path "$_repo" "$projects")
    info "  ← $_repo → $_inferred_path"
    session_extract "$session_name" --repo "$_repo" --force
done
```

The extraction will create the host repo at the inferred path. Need to ensure the extraction handles missing host dirs (creates them).

### Host-only
This is trickier — `session_add_repo` clones the host repo into the container volume and updates the config. But sync would need to detect "host repos not in container" which requires comparing the config project list against... what? The user's filesystem is unbounded.

**Decision**: host-only handling is opt-in via `sync --add-repo /path/to/repo`. Don't auto-detect. The `repos add` command already does this.

## Files

| File | Changes |
|------|---------|
| `lib/commands/sync/execute.sh` | Clone-from-container implementation |
| `lib/commands/sync/classify.sh` | Possibly improve container-only path resolution |
| `lib/session-mgmt.sh` | Ensure extraction handles missing host dirs |
