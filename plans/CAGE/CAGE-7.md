# CAGE-7: Migration from claude-container

blocked_by: [CAGE-3, CAGE-4, CAGE-6]
unlocks: []

## Scope

Provide a migration path from existing claude-container sessions to cage. Users should be able to import their sessions without re-cloning repos or losing conversation history.

## What Exists in claude-container

Per session, claude-container creates:

| Docker Volume | Content |
|---------------|---------|
| `claude-session-<name>` | Git repos (workspace) |
| `claude-state-<name>` | Claude conversation history (~/.claude) |
| `claude-cargo-<name>` | Cargo cache |
| `claude-npm-<name>` | npm cache |
| `claude-pip-<name>` | pip cache |

Host config:
| File | Content |
|------|---------|
| `~/.config/claude-container/sessions/<name>.env` | Session flags |
| `~/.config/claude-container/sessions/<name>.yml` | Repo config (YAML) |

Volume internal files:
| File | Content |
|------|---------|
| `.claude-projects.yml` | Repo config (duplicate of host .yml) |
| `.repo-manifest` | Root commit hashes for change detection |
| `.main-project` | Primary repo name |

## Migration Command

```bash
cage import --from-cc <session-name>
cage import --from-cc <session-name> --agent claude   # explicit agent
cage import --from-cc --all                            # migrate everything
```

### Single Session Import

```bash
cage import --from-cc myproj
```

Flow:

1. **Read cc config**:
   - Parse `~/.config/claude-container/sessions/myproj.yml` → repo list
   - Parse `~/.config/claude-container/sessions/myproj.env` → flags

2. **Reuse workspace volume** (rename, don't copy):
   ```bash
   # Can't rename Docker volumes directly. Create new + copy.
   docker volume create cage-workspace-myproj
   docker run --rm \
     -v claude-session-myproj:/src:ro \
     -v cage-workspace-myproj:/dst \
     alpine cp -a /src/. /dst/
   ```

   OR if the user is willing to commit to the migration (faster):
   ```bash
   # Just reference the old volume name in cage config
   # volume: claude-session-myproj (instead of cage-workspace-myproj)
   ```

3. **Write cage session config**:
   ```yaml
   # ~/.config/cage/sessions/myproj.yml
   agent: claude
   volume: myproj
   repos:
     synapse:
       host: /Users/me/dev/synapse
     vox:
       host: /Users/me/dev/vox
   ```

   Repo list extracted from cc's `.yml` config.

4. **Create persistent container**:
   ```bash
   cage container create myproj --volume myproj --agent claude
   ```

5. **Import Claude state into container**:
   The persistent container owns `~/.claude`. Copy from cc state volume:
   ```bash
   docker run --rm \
     -v claude-state-myproj:/src:ro \
     cage-myproj  # target container's filesystem
   ```

   Actually, since the container is persistent, we can `docker cp`:
   ```bash
   docker start cage-myproj
   # Copy state from old volume via utility container + pipe
   docker run --rm -v claude-state-myproj:/state:ro alpine tar -cf - -C /state . \
     | docker exec -i cage-myproj tar -xf - -C /home/developer/.claude/
   docker exec cage-myproj chown -R developer:developer /home/developer/.claude
   docker stop cage-myproj
   ```

6. **Migrate .cage/ protocol files**:
   Convert cc marker files to cage protocol:
   ```bash
   # In workspace volume:
   mkdir -p .cage/inbox .cage/outbox .cage/control
   # Copy manifest
   cp .repo-manifest .cage/manifest
   # Write config
   # (from host-side session config)
   ```

7. **Clean up cc markers**:
   Remove cc-specific files from workspace:
   ```bash
   rm -f .sync-branch .sync-summary .merge-into-branch .merge-into-summary
   rm -f .merge-into-mounts .reconcile-complete .main-project
   ```

8. **Report**:
   ```
   Imported session 'myproj' from claude-container
     Repos: 3 (synapse, vox, claude-container)
     Agent: claude
     State: imported (conversation history preserved)

   Original cc volumes preserved. Delete with:
     docker volume rm claude-session-myproj claude-state-myproj ...
   ```

### Bulk Import

```bash
cage import --from-cc --all
```

Scan `~/.config/claude-container/sessions/*.yml`, import each.

### Shared Cache Migration

claude-container may have per-session caches (`claude-cargo-<name>`) or shared caches (`claude-cargo-shared`).

For shared caches, just reuse:
```bash
# If cage-cargo-cache doesn't exist, seed from cc
docker volume create cage-cargo-cache
docker run --rm \
  -v claude-cargo-shared:/src:ro \
  -v cage-cargo-cache:/dst \
  alpine cp -a /src/. /dst/
```

Per-session caches: ignore (they'll be rebuilt; shared cache is the new model).

## Config Format Translation

### cc `.yml` → cage `sessions/<name>.yml`

cc format:
```yaml
projects:
  synapse:
    path: /Users/me/dev/synapse
    branch: main
  vox:
    path: /Users/me/dev/vox
```

cage format:
```yaml
agent: claude
volume: myproj
repos:
  synapse:
    host: /Users/me/dev/synapse
  vox:
    host: /Users/me/dev/vox
```

Translation: rename `projects` → `repos`, `path` → `host`, drop `branch` (cage tracks branches differently), add `agent` field.

### cc `.env` → cage session config

cc `.env` contains flags like `RUN_AS_ROOTISH=true`, `ENABLE_DOCKER=false`. These map to agent needs:
- `RUN_AS_ROOTISH=true` → `needs.sudo: true` (default for Claude)
- `ENABLE_DOCKER=true` → `needs.docker: true`

Most flags become irrelevant — cage derives them from the agent spec.

## Rollback

Migration is non-destructive. Original cc volumes are preserved. User can:
- Continue using claude-container on old sessions
- Use cage on imported sessions
- Delete old volumes when confident

## Acceptance Criteria

- [ ] `cage import --from-cc <name>` imports single session
- [ ] Workspace volume contents preserved (repos, git history)
- [ ] Claude conversation history migrated into persistent container
- [ ] Host config translated from cc format to cage format
- [ ] cc marker files cleaned from workspace
- [ ] `.cage/` protocol directory created
- [ ] Shared caches migrated (if they exist)
- [ ] `cage import --from-cc --all` batch imports all sessions
- [ ] Original cc volumes preserved (non-destructive)
- [ ] Imported session works with `cage -s <name> run`
