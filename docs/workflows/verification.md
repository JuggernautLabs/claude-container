# Verification Workflow

Check whether session work has been properly extracted and merged without making any changes.

## Hash check (`status <branch>`)

Compare session commit hashes directly against a host branch:

```bash
claude-container status -s my-feature main
```

Output for each repo:

```
  org/repo-a
    hash:    abc1234def56
    result:  MATCH

  org/repo-b
    session: 111222333444
    host:    555666777888
    result:  MISMATCH (session ahead)

  org/repo-c
    session: aabbccddee00
    host:    (no branch 'main')
    result:  NO BRANCH
```

### Verdicts

| Result | Meaning |
|--------|---------|
| **MATCH** | Hashes are identical |
| **MISMATCH (session ahead)** | Session has commits the host doesn't |
| **MISMATCH (host ahead)** | Host has commits the session doesn't |
| **MISMATCH (diverged)** | Both sides have unique commits |
| **NO BRANCH** | Host repo doesn't have the checked branch |
| **MISSING** | Host repo doesn't exist at all |

### Filter to one repo

```bash
claude-container status -s my-feature main --repo synapse
```

Matches on full name (`org/synapse`) or basename (`synapse`).

### Exit codes

- `0` — all checked repos match
- `1` — at least one mismatch or missing repo

Useful in scripts:

```bash
if claude-container status -s my-feature main; then
  echo "All synced"
else
  echo "Needs attention"
fi
```

## Sync verify (`status`)

Classifies each repo into a sync state:

```bash
claude-container status -s my-feature
```

Output:

```
  org/repo-a: synced
  org/repo-b: extracted but not merged
  org/repo-c: unchanged
  org/repo-d: not extracted

  25/29 ok (20 synced, 5 unchanged), 3 extracted-only, 1 pending, 0 missing
```

### States

| State | Meaning |
|-------|---------|
| **synced** | Session branch extracted AND merged into target |
| **unchanged** | No changes in session (matches host HEAD) |
| **extracted_only** | Branch exists on host but not merged into target |
| **not_extracted** | Session has changes that haven't been extracted |
| **missing** | Host repo not found at resolved path |

## When to use which

| Question | Tool |
|----------|------|
| "Does this specific branch match the session?" | `status -s X main` |
| "Has everything been extracted and merged?" | `status -s X` |
| "Is this one repo in sync?" | `status -s X main --repo <name>` |
| "Quick sanity check in a script" | `status -s X main` (exit code) |
