# Refresh Workflow

Pull changes from host repos into an active session without restarting.

## When to use

You have a running session and need to bring in changes made on the host:
- You edited files outside the container and want Claude to see them
- Another tool or CI pushed updates to a branch
- You extracted, made fixes on the host, and want to push them back in

## Basic usage

```bash
# Push from the session-named branch (default)
claude-container push -s my-feature
```

This fetches the `my-feature` branch from each host repo and fast-forwards the session copy.

## Specify a branch

```bash
# Push from main instead
claude-container push -s my-feature main
```

## Push a single repo

```bash
# Push only the synapse repo (partial name matching works)
claude-container push -s my-feature --repo synapse

# Push a specific branch into a specific repo
claude-container push -s my-feature --repo synapse,main

# Force-reset a repo to match the host branch
claude-container push -s my-feature --repo synapse,main --force
```

The `--repo` flag accepts `name[,branch]`:
- **`name`** — matches exactly, or by suffix (e.g. `synapse` matches `org/synapse`)
- **`,branch`** — overrides the branch to push from (otherwise uses session name or positional arg)

If the name is ambiguous (matches multiple repos), you'll be told which ones matched and asked to use the full name.

## Push and continue working

```bash
# Push then launch Claude with conversation history
claude-container push -s my-feature
claude-container -s my-feature --continue
```

## What happens

For each repo in the session config:

1. Mounts the host repo read-only into the container
2. Fetches the specified branch (default: session name)
3. Fast-forwards the session copy if possible

### Possible outcomes per repo

| Status | Meaning |
|--------|---------|
| `up to date` | Session and host are at the same commit |
| `N new commit(s)` | Fast-forwarded N commits from host |
| `force-reset to host HEAD` | Session was reset to match host (with `--force`) |
| `diverged` | Both sides have unique commits — use `--force` to reset or `--rebase` to rebase |
| `no branch 'X' on host` | The requested branch doesn't exist on the host repo |

## Repos created in-session

If Claude created new repos inside the container (e.g., `git init`), push automatically registers them in the session config on first run. Their host paths are inferred from sibling repos with the same org prefix.

## Push strategies

| | `push` (--ff) | `push --ff --force` | `push --rebase` | `push --merge` |
|-|---------------|---------------------|-----------------|----------------|
| **Strategy** | Fast-forward only | Reset to host HEAD | Rebase | Merge |
| **Conflicts** | Skips diverged repos | Overwrites session state | Claude resolves interactively | Claude resolves interactively |
| **Use case** | Quick update, no divergence | Reload a repo from a different branch | Long-running session, upstream moved | Need to incorporate upstream changes |
| **Container** | No | No | Yes, if conflicts | Yes, if conflicts |

