# Basic Session Workflow

Create a session, let Claude work, get the changes back.

## Start a session

```bash
# Single repo (current directory)
claude-container -s my-feature

# From a specific branch
claude-container -s post-feature --from feature-branch
```

This clones your repo into a Docker volume, strips git remotes (Claude can't push), and starts Claude Code inside the container.

## Work

Claude has full access inside `/workspace/`:
- Read/write any file
- Run shell commands
- Install packages
- Make git commits

All changes stay inside the container volume. Your host repo is untouched.

## Resume a session

```bash
# Resume with conversation history
claude-container -s my-feature --continue
```

## Extract and merge

```bash
# Extract session work as a branch, then merge into main
claude-container merge -s my-feature --branch main
```

This does two things:
1. **Extract**: creates a `my-feature` branch in your host repo matching the session HEAD
2. **Auto-merge**: merges `my-feature` into `main` via `git merge --no-edit`

If you just want the branch without merging:

```bash
claude-container extract -s my-feature
# or
claude-container -s my-feature --extract
```

## Verify

```bash
# Are session and host in sync?
claude-container merge -s my-feature --check main
```

## Clean up

```bash
# Delete the session volume
claude-container -s my-feature --delete

# Delete all unused sessions
claude-container --cleanup-unused
```
