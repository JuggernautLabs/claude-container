# Reconcile Workflow

Merge session work into a target branch when your host repos are dirty or there are conflicts.

## The problem

`claude-container merge -s my-feature --branch main` fails in two cases:
1. **Dirty worktrees** on the host (uncommitted changes)
2. **Merge conflicts** between session work and the target branch

## The solution

```bash
claude-container merge -s my-feature --reconcile main
```

## What happens

### Phase 1: Extract

Session branches are extracted to every host repo.

### Phase 2: Stash dirty work

For each host repo with uncommitted changes:
- Creates a branch named `main-my-feature-stash-<timestamp>`
- Commits all dirty files there
- Returns to the original branch (now clean)

Your uncommitted work is safe and recoverable:

```bash
git log main-my-feature-stash-1707580800
```

### Phase 3: Merge target into session

Inside the Docker volume, merges the target branch (`main`) into each session repo. This brings the session up to date with upstream.

**If clean**: extracts the merged result and auto-merges into the target. Done.

**If conflicts**: launches a Claude container session with a prompt describing every conflict.

### Phase 4: Claude resolves conflicts (if needed)

Claude sees a prompt like:

```
Branch 'main' was merged into this session. Here is what happened:

  CONFLICT: repo-a (merge conflicts)
  OK: repo-b (merged)

1 project(s) have merge conflicts that need resolution.
Resolve all merge conflicts autonomously...
```

Claude resolves the `<<<<<<< HEAD` markers, commits, then signals completion:

```bash
fin "resolved config merge conflict in repo-a"
```

### Phase 5: Auto-merge

The exit handler extracts the resolved state and auto-merges into the target branch. Since the session branch now contains the target's commits, this is typically a fast-forward.

## The `fin` command

Available inside any merge-into or reconcile container session.

```bash
fin "description of what was resolved"
```

- Writes a completion marker
- Terminates the container
- The description appears in the exit handler output

## When to use reconcile vs. plain merge

| Situation | Use |
|-----------|-----|
| Clean host repos, no conflicts expected | `merge -s X --branch main` |
| Dirty host repos | `merge -s X --reconcile main` |
| Conflicts likely (diverged branches) | `merge -s X --reconcile main` |
| Want Claude to handle everything | `merge -s X --reconcile main` |
