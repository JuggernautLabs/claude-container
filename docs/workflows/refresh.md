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
| `diverged` | Both sides have unique commits — use `push --rebase` to rebase |
| `no branch 'X' on host` | The requested branch doesn't exist on the host repo |

## Repos created in-session

If Claude created new repos inside the container (e.g., `git init`), push automatically registers them in the session config on first run. Their host paths are inferred from sibling repos with the same org prefix.

## Push strategies

| | `push` (--ff) | `push --rebase` | `push --merge` |
|-|---------------|-----------------|----------------|
| **Strategy** | Fast-forward only | Rebase | Merge |
| **Conflicts** | Skips diverged repos | Claude resolves interactively | Claude resolves interactively |
| **Use case** | Quick update, no divergence | Long-running session, upstream moved | Need to incorporate upstream changes |
| **Container** | No | Yes, if conflicts | Yes, if conflicts |

## Legacy command mapping

| Old | New |
|-----|-----|
| `--refresh [branch]` | `push [branch]` |
| `--sync <branch>` | `push <branch> --rebase` |
| `--merge-into <branch>` | `push <branch> --merge` |
