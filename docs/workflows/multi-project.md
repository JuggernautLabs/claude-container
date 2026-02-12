# Multi-Project Workflow

Work across multiple repositories in a single session.

## Discover repos automatically

```bash
claude-container -s my-feature \
  --discover-repos ~/dev/myorg \
  --dir ~/dev/myorg/main-repo
```

- `--discover-repos` walks the directory tree, finds every `.git` repo
- `--dir` sets which repo Claude starts in (the main project)
- All repos are bundled into the session volume

## Or use a config file

```yaml
# .claude-projects.yml
version: "1"
main: backend/api
projects:
  backend/api:
    path: ~/dev/api
  backend/workers:
    path: ~/dev/workers
  frontend/web:
    path: ~/dev/webapp
```

```bash
claude-container -s my-feature --config .claude-projects.yml
```

## Inside the container

```
/workspace/
  backend/
    api/         # Main project (initial working directory)
    workers/
  frontend/
    web/
```

Claude can work across all repos. Commits in any repo are tracked.

## Add repos to an existing session

```bash
claude-container -s my-feature --add-repo ~/dev/another-repo
```

## Extract and merge

Works the same as single-repo, but operates on all repos:

```bash
# Extract + merge all repos into main
claude-container merge -s my-feature --branch main
```

Each repo gets a `my-feature` branch. Repos with no changes are skipped.

## Verify all repos

```bash
# Hash comparison across all repos
claude-container merge -s my-feature --check main

# Check a single repo
claude-container merge -s my-feature --check main --repo synapse
```

## New repos created in-session

If Claude creates a new repo inside the container (e.g., `git init new-project`), extraction detects it via manifest comparison and:

1. Infers the host path from sibling repos (same org prefix)
2. Clones it to the host
3. Creates `main` and session-named branches
