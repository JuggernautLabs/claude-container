# CAGE-3: Volume Primitives

blocked_by: []
unlocks: [CAGE-4, CAGE-5, CAGE-7]

## Scope

Implement all volume-level operations. A volume is a named Docker volume containing git repos with a config file tracking repo→host-path mappings. All operations use utility containers (`docker run --rm`). No persistent container or agent involved.

## Volume Config

Source of truth on host:

```yaml
# ~/.config/cage/volumes/<name>.yml
repos:
  synapse:
    host: /Users/me/dev/synapse
  vox:
    host: /Users/me/dev/vox
  claude-container:
    host: /Users/me/dev/claude-container
```

Also stored inside volume at `/workspace/.cage/config.yml` (copy, for container-side reads).

Docker volume name: `cage-workspace-<name>`

## Commands

### `cage volume create <name>`

Create a new volume and clone repos into it.

```bash
cage volume create myproj --repo ~/dev/synapse --repo ~/dev/vox
cage volume create myproj --discover ~/dev/myorg    # find all git repos under dir
cage volume create myproj --from-config path/to/config.yml
```

Steps:
1. `docker volume create cage-workspace-<name>`
2. Write `~/.config/cage/volumes/<name>.yml`
3. For each repo (parallel where possible):
   - `docker run --rm -v <host-repo>:/source:ro -v cage-workspace-<name>:/workspace <image> git clone /source /workspace/<repo-name>`
4. Write manifest to volume: `/workspace/.cage/manifest` (root-commit-hash|name for each repo)
5. Copy config into volume: `/workspace/.cage/config.yml`

Image for utility containers: a minimal git image (alpine/git or similar). NOT the agent image.

### `cage volume delete <name>`

```bash
cage volume delete myproj
```

1. Check no container is using this volume (error if so)
2. `docker volume rm cage-workspace-<name>`
3. `rm ~/.config/cage/volumes/<name>.yml`

### `cage volume list`

```bash
cage volume list
```

List all volumes with basic info (repo count, size).

Scan `~/.config/cage/volumes/*.yml` + cross-reference `docker volume ls`.

### `cage volume clone <src> <dst>`

```bash
cage volume clone myproj myproj-backup
```

1. `docker volume create cage-workspace-<dst>`
2. `docker run --rm -v cage-workspace-<src>:/src:ro -v cage-workspace-<dst>:/dst <image> cp -a /src/. /dst/`
3. Copy config yml on host, update name.

### `cage volume heads <name>`

```bash
cage volume heads myproj
```

Print each repo's HEAD hash:

```
synapse     a1b2c3d4
vox         e5f6a7b8
```

Implementation: `docker run --rm -v cage-workspace-<name>:/workspace:ro <image>` then `git -C /workspace/<repo> rev-parse HEAD` for each.

### `cage volume manifest <name>`

```bash
cage volume manifest myproj
```

Show saved manifest vs live state. Detect renames, additions, deletions.

### `cage volume diff <name> [<branch>]`

```bash
cage volume diff myproj           # diff against session-named branch on host
cage volume diff myproj main      # diff against main on host
cage volume diff myproj --repo synapse   # single repo
```

Read-only comparison. For each repo:
1. Get session HEAD from volume
2. Get host branch HEAD from host repo
3. Compare: match / host ahead / session ahead / diverged
4. Optionally show commit log between them

No container needed for git operations on the host side. Volume side uses utility container.

### `cage volume bundle <name> [--repo <repo>]`

```bash
cage volume bundle myproj
cage volume bundle myproj --repo synapse
```

Create git bundles from volume repos. Output to temp directory. Return paths.

Implementation: `docker run --rm -v cage-workspace-<name>:/workspace:ro <image> git -C /workspace/<repo> bundle create /tmp/<repo>.bundle HEAD`

Used internally by `extract`.

### `cage volume unbundle <name> <bundle-path> [--repo <repo>]`

Apply a git bundle into the volume. Used internally by `inject`.

### `cage volume fetch <name> <branch> [--repo <repo>]`

```bash
cage volume fetch myproj main
```

Fetch a host branch into volume repos. For each repo:
1. Mount host repo read-only
2. `git fetch /source <branch>` inside volume

### `cage volume ff <name> <branch> [--repo <repo>]`

Fast-forward volume repos to fetched branch.

```bash
cage volume ff myproj main
```

Fails if not fast-forwardable (diverged). Returns per-repo status.

### `cage volume rebase <name> <branch> [--repo <repo>]`

```bash
cage volume rebase myproj main
```

Rebase volume repos onto fetched branch. Returns per-repo status:
- clean: rebase succeeded
- conflicts: rebase aborted, reports conflicting files

### `cage volume merge <name> <branch> [--repo <repo>]`

```bash
cage volume merge myproj main
```

Merge host branch INTO volume repos. Returns per-repo status:
- clean: merge committed
- conflicts: merge left in-progress (agent must resolve)

## Utility Container Image

Volume operations need a minimal image with git. Options:
- `alpine/git` (tiny, standard)
- Build a `cage-util` image with git + coreutils
- Reuse the agent image (heavier but guaranteed compatible)

Decision: use a dedicated lightweight `cage-util` image. Agent images may be large and are agent-specific.

## Error Handling

All volume operations must be atomic or clearly report partial failure:
- Clone: if one repo fails, report which failed, don't delete the volume
- Fetch/rebase/merge: per-repo status, continue on failure
- Delete: refuse if container is using the volume

## Acceptance Criteria

- [ ] `cage volume create` clones repos into Docker volume
- [ ] `cage volume delete` removes volume and host config
- [ ] `cage volume list` shows all volumes
- [ ] `cage volume clone` creates independent copy
- [ ] `cage volume heads` shows per-repo HEADs
- [ ] `cage volume diff` compares volume vs host branches
- [ ] `cage volume fetch` fetches host branches into volume
- [ ] `cage volume ff` fast-forwards volume repos
- [ ] `cage volume rebase` rebases with conflict detection
- [ ] `cage volume merge` merges with conflict detection
- [ ] All operations use utility containers (no persistent container needed)
- [ ] Manifest written at creation, used for rename/addition detection
