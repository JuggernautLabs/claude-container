# Reconcile Workflow

Merge session work into a target branch when your host repos are dirty or there are conflicts.

## The problem

`claude-container pull -s my-feature main` fails in two cases:
1. **Dirty worktrees** on the host (uncommitted changes)
2. **Merge conflicts** between session work and the target branch

## The solution

```bash
claude-container pull -s my-feature main --reconcile
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

## When to use what

| Situation | Use |
|-----------|-----|
| Session already incorporates main | `pull -s X main` |
| Need to incorporate main first | `push -s X main --merge` then `pull -s X main` |
| Dirty host repos | `pull -s X main --reconcile` |
| Conflicts likely (diverged branches) | `push -s X main --merge` (Claude resolves in container) |
| Want Claude to handle everything | `pull -s X main --reconcile` |

`pull main` will **skip** any repo where the merge would conflict and tell you
to run `push main --merge` first. Conflicts are always resolved in the container
where Claude can help — never on the host.
