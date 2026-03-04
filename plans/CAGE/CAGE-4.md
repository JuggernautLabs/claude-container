# CAGE-4: Container Primitives

blocked_by: [CAGE-3]
unlocks: [CAGE-5, CAGE-7]

## Scope

Implement persistent container lifecycle management. A container binds a volume to an agent in an isolated Docker environment. Containers persist across invocations (stop/start, not create/destroy).

## Container Naming

```
cage-<session-name>           # container name
cage-workspace-<session-name> # workspace volume (from CAGE-3)
```

## Shared Cache Volumes

Created once, mounted into ALL containers:

```
cage-cargo-cache   → /home/developer/.cargo
cage-npm-cache     → /home/developer/.npm
cage-pip-cache     → /home/developer/.cache/pip
cage-cabal-cache   → /home/developer/.cabal
cage-go-cache      → /home/developer/go
```

Additional caches declared by agent via `info.caches[]` are also mounted as shared volumes, named `cage-cache-<hash-of-path>`.

These are created lazily on first container creation that needs them.

## Commands

### `cage container create <session-name>`

```bash
cage container create myproj --volume myproj --agent claude
```

Steps:

1. **Read agent info**: `cage-agent-claude info` → get image, needs, caches
2. **Pull/build image**: `docker pull <image>` or build from Dockerfile
3. **Ensure shared caches exist**: `docker volume create` for each cache
4. **Build docker create args**:

```bash
docker create \
  --name cage-myproj \
  -v cage-workspace-myproj:/workspace \
  # Shared caches
  -v cage-cargo-cache:/home/developer/.cargo \
  -v cage-npm-cache:/home/developer/.npm \
  -v cage-pip-cache:/home/developer/.cache/pip \
  -v cage-cabal-cache:/home/developer/.cabal \
  -v cage-go-cache:/home/developer/go \
  # Conditionals from agent needs
  -v /var/run/docker.sock:/var/run/docker.sock \  # if needs.docker
  -v /run/host-services/ssh-auth.sock:/ssh-agent \ # if needs.ssh_agent (macOS)
  -e SSH_AUTH_SOCK=/ssh-agent \
  # Host config (read-only)
  -v ~/.gitconfig:/home/developer/.gitconfig:ro \
  -v ~/.ssh:/home/developer/.ssh:ro \
  # Environment
  -e HOST_UID=$(id -u) \
  -e CAGE_SESSION=myproj \
  -e CAGE_AGENT=claude \
  # Interactive
  -it \
  <image> \
  /bin/bash  # entrypoint is bash; agent run is via docker exec
```

5. **Run environment setup** (rootish trick, etc.):

```bash
docker start cage-myproj
docker exec cage-myproj /bin/bash -c '
  # Create developer user with host UID
  groupadd -g 61000 developer 2>/dev/null || true
  useradd -u $HOST_UID -g 61000 -m -s /bin/bash developer 2>/dev/null || true
  chown -R developer:developer /home/developer

  # Passwordless sudo (if agent needs it)
  echo "developer ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/developer
  chmod 0440 /etc/sudoers.d/developer

  # Git safe directory
  git config --global --add safe.directory "*"

  # Docker socket permissions (if mounted)
  [[ -S /var/run/docker.sock ]] && chmod 666 /var/run/docker.sock

  # Workspace ownership
  chown developer:developer /workspace

  # Create .cage directories
  mkdir -p /workspace/.cage/inbox /workspace/.cage/outbox /workspace/.cage/control
'
```

6. **Agent setup**: `cage-agent-claude setup /workspace` (via `docker exec`)
7. **Auth injection**: `cage-agent-claude auth inject cage-myproj`
8. **Stop container**: `docker stop cage-myproj` (ready for `start`)

### `cage container start <session-name>`

```bash
cage container start myproj
```

Attach interactively to the persistent container and run the agent:

1. **Re-inject auth** (tokens may have expired): `cage-agent-claude auth inject cage-myproj`
2. **Start container**: `docker start cage-myproj` (if stopped)
3. **Exec agent**:

```bash
docker exec -it cage-myproj \
  gosu developer \
  cage-agent-claude run --workspace /workspace [--prompt "..." | --resume]
```

Wait for agent process to exit. Container stays running (PID 1 is bash).

Alternative: if agent needs to be PID 1, use `docker exec` and then `docker stop` after.

**Key difference from claude-container**: the container stays alive after the agent exits. This means:
- Environment state persists (installed packages)
- You can `docker exec` into it for debugging
- `cage container stop` is a separate explicit step

### `cage container stop <session-name>`

```bash
cage container stop myproj
```

1. `docker stop cage-myproj`

Container persists. All filesystem state retained. Volume still accessible for sync operations.

### `cage container rm <session-name>`

```bash
cage container rm myproj
```

1. `docker stop cage-myproj` (if running)
2. `docker rm cage-myproj`

Does NOT delete the workspace volume. Volume and container have independent lifecycles.

### `cage container exec <session-name> <command>`

```bash
cage container exec myproj bash
cage container exec myproj ls /workspace
cage container exec myproj apt-get install ripgrep
```

Run a command in the container (must be running or startable).

1. `docker start cage-myproj` (if stopped)
2. `docker exec -it cage-myproj gosu developer <command>`

### `cage container list`

```bash
cage container list
```

List all cage containers with status (running/stopped), associated volume, agent.

`docker ps -a --filter "name=cage-" --format ...`

### `cage container inspect <session-name>`

```bash
cage container inspect myproj
```

Show: image, agent, volume, state, created date, cache mounts.

## Platform-Specific Handling

### macOS (Docker Desktop)
- SSH agent: `/run/host-services/ssh-auth.sock`
- Docker socket: query `docker context inspect` for actual path
- UID: `id -u`

### Linux
- SSH agent: direct mount of `$SSH_AUTH_SOCK`
- Docker socket: `/var/run/docker.sock`
- UID: `id -u`

### WSL
- SSH agent: same as Linux
- Docker socket: may be Windows named pipe (skip)
- UID: `id -u`

## Container Lifecycle State Machine

```
                  create
(not exists) ──────────────► stopped
                                │
                    start       │  stop
                 ┌──────────►  running ◄──────────┐
                 │              │                   │
                 │              │ exec              │
                 │              │ (agent runs)      │
                 │              │                   │
                 │              ▼                   │
                 │         agent exits              │
                 │         (container still running)│
                 │              │                   │
                 │              │ stop              │
                 └── stopped ◄─┘                   │
                      │                             │
                      │ rm                          │
                      ▼                             │
                 (not exists)                       │
```

## Acceptance Criteria

- [ ] `cage container create` builds container with correct mounts and env
- [ ] Rootish trick: developer user with passwordless sudo
- [ ] UID mapping: container user matches host UID
- [ ] Shared cache volumes mounted in all containers
- [ ] Agent-declared caches from `info` also mounted
- [ ] `cage container start` attaches interactively, runs agent
- [ ] `cage container stop` stops without destroying
- [ ] `cage container rm` destroys container, keeps volume
- [ ] `cage container exec` runs arbitrary commands
- [ ] SSH agent forwarding works on macOS and Linux
- [ ] Docker socket forwarding works when requested
- [ ] Platform detection (macOS/Linux/WSL) handles differences
