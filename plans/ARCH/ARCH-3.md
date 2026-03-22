# ARCH-3: Lifecycle Scripts (Image, Container, Token)

blocked_by: [ARCH-2]
unlocks: [ARCH-7]

## Goal

Extract container lifecycle management into standalone scripts. Each handles exactly one concern, has explicit contracts, and never silently destroys data.

## Scripts

### 1. `lib/lifecycle/cc-image-validate`

```
USAGE: cc-image-validate <image> [--json]
READS: Docker image (runs test containers)
WRITES: nothing
DESTROYS: nothing
```

Checks:
- Critical: gosu, git, claude, bash
- Soft: python3, sudo, docker CLI
- Returns structured result (valid/invalid with reasons)

Extracted from: `_validate_image()` in main script (lines 956-1006)

### 2. `lib/lifecycle/cc-container-check`

```
USAGE: cc-container-check <container_name> <image_name> <script_dir> [--json]
READS: Docker container metadata (inspect)
WRITES: nothing
DESTROYS: nothing
```

Checks (the 6 conditions):
1. Image ID matches current image
2. Image name matches
3. Entrypoint mount path matches script dir
4. Container user is root (0:0)
5. No stale CONTINUE_SESSION env
6. No corrupted token mounts
7. Critical tools present in image

Returns: `{"ok": true}` or `{"ok": false, "reasons": [...], "action": "rebuild|warn"}`

Extracted from: stale detection block in main script (lines 1122-1205)

### 3. `lib/lifecycle/cc-container-create`

```
USAGE: cc-container-create <container_name> <image> [docker_args...]
READS: nothing (pure creation)
WRITES: creates a Docker container
DESTROYS: nothing (refuses if container already exists)
```

Guarantees:
- Always `--user 0:0`
- Mounts entrypoint + agent-run from script dir
- Sets all required env vars
- Names container deterministically

Extracted from: `docker run` call in main script (line 1230)

### 4. `lib/lifecycle/cc-container-remove`

```
USAGE: cc-container-remove <container_name> [--force]
READS: container state, workspace volume (for uncommitted work check)
WRITES: nothing
DESTROYS: the container (AFTER confirmation)
```

Behavior:
- Shows what container it would remove and why
- Checks for uncommitted non-git work in workspace volume
- Interactive: asks "Remove container? [y/N]"
- Non-interactive without --force: refuses
- Non-interactive with --force: proceeds
- Always preserves volumes

Extracted from: 6 `docker rm -f` calls scattered through main script

### 5. `lib/lifecycle/cc-token-inject`

```
USAGE: cc-token-inject <token> <cache_dir>
READS: cache dir for stale tokens
WRITES: token file at <cache_dir>/token-$$
DESTROYS: stale token directories (safe — they're broken)
```

Returns: the mount arg (`-v /path/token:/run/secrets/claude_token:ro`)

Extracted from: `inject_token_securely()` in auth.sh

## Acceptance Criteria

1. Each script is executable, has contract header, sources `contract.sh`
2. `cc-container-remove` ALWAYS requires confirmation or `--force` — no exceptions
3. `cc-container-check` returns structured data, doesn't modify anything
4. `cc-image-validate` can be run independently: `cc-image-validate myimage`
5. Main script calls these instead of inline logic
6. All 6 `docker rm -f` calls in main script replaced with `cc-container-remove`

## Files

| File | Extracted from |
|------|---------------|
| `lib/lifecycle/cc-image-validate` | `_validate_image()` in claude-container |
| `lib/lifecycle/cc-container-check` | stale detection block in claude-container |
| `lib/lifecycle/cc-container-create` | `docker run` in claude-container |
| `lib/lifecycle/cc-container-remove` | 6x `docker rm -f` in claude-container |
| `lib/lifecycle/cc-token-inject` | `inject_token_securely()` in auth.sh |
