# Data Transfer Overview

How data moves between your host repos and the container session volume.

```
                    HOST                          CONTAINER
                 (your repos)                   (docker volume)
                     |                               |
                     |                               |
  ---------------- HOST -> CONTAINER (push) ----------------------------
                     |                               |
  session create     | --- bundle repos ---------->  |  initial clone
  --discover-repos   |                               |
                     |                               |
  push [branch]      | --- fetch + fast-forward -->  |  pull latest from
                     |     (default: session branch) |  host into session
                     |                               |
  push <br> --rebase | --- fetch + rebase -------->  |  rebase session onto
                     |     (Claude resolves)         |  updated upstream
                     |                               |
  push <br> --merge  | --- fetch + merge --------->  |  merge target branch
                     |     (Claude resolves)         |  into session
                     |                               |
  --add-repo <path>  | --- clone single repo ----->  |  add repo to session
                     |                               |
                     |                               |
  ---------------- CONTAINER -> HOST (pull) ----------------------------
                     |                               |
  pull               | <-- git bundle -------------- |  create session-named
                     |     (branch per repo)         |  branches on host
                     |                               |
  pull <branch>      | <-- bundle + merge ---------- |  extract then merge
                     |     (into target branch)      |  into target branch
                     |                               |
                     |                               |
  ---------------- BIDIRECTIONAL -------------------------------------------
                     |                               |
  pull <branch>      | <-- extract ----------------  |
    --reconcile      | --- stash dirty work          |
                     | --- merge target into ------>  |  merge + resolve
                     | <-- extract resolved --------  |  then merge back
                     | --- auto-merge into target    |
                     |                               |
                     |                               |
  ---------------- MULTI-SESSION (reconcile) --------------------------------
                     |                               |
  reconcile <branch> | <-- extract each session ---  |
    [sessions...]    | --- auto-merge into target    |  sequential:
                     | --- container if conflicts -> |  each merge changes
                     | <-- extract + merge back ---  |  the target branch
                     |     (repeats for each session)|
                     |                               |
                     |                               |
  ---------------- READ-ONLY (status) ------------------------------------
                     |                               |
  status <branch>    |    compare hashes             |  no data transferred
  status             |    classify sync state        |
```

## Command Reference

| Command | Direction | Strategy | Claude? |
|---------|-----------|----------|---------|
| session create | host -> container | bundle clone | no |
| `--add-repo` | host -> container | clone | no |
| `push [branch]` | host -> container | fetch + fast-forward | no |
| `push <branch> --rebase` | host -> container | fetch + rebase | yes, if conflicts |
| `push <branch> --merge` | host -> container | fetch + merge | yes, if conflicts |
| `pull` | container -> host | git bundle | no |
| `pull <branch>` | container -> host | bundle + merge (skips conflicts) | no |
| `pull <branch> --reconcile` | both | extract, merge, resolve, merge back | yes, if conflicts |
| `reconcile <branch> [sessions]` | both | sequential multi-session merge | yes, if conflicts |
| `status <branch>` | read-only | hash comparison | no |
| `status` | read-only | sync classification | no |

## Choosing the Right Tool

**"I need to get host changes into the container"**
- Small update, no conflicts: `push`
- Upstream moved significantly: `push main --rebase`
- Need to merge a specific branch in: `push main --merge`

**"I need to get container work onto the host"**
- Just want branches: `pull`
- Want branches merged into a target: `pull main` (skips repos that would conflict)
- Host is dirty or conflicts expected: `pull main --reconcile`

**Recommended merge-into-main workflow:**
1. `push -s X main --merge` — merge main INTO session (Claude resolves conflicts)
2. `pull -s X` — extract session branches to host
3. `pull -s X main` — merge into main (guaranteed clean, session already has main)

**"I need to merge multiple sessions into one branch"**
- Preview: `reconcile main --dry-run`
- Merge all: `reconcile main`
- Specific sessions: `reconcile main s1 s2 s3`
- Filter by pattern: `reconcile main --include 'feature-.*' --exclude 'wip'`

**"I need to check if things are in sync"**
- Hash-level comparison: `status main`
- Sync state classification: `status`

## Legacy Command Mapping

| Old | New |
|-----|-----|
| `--refresh [branch]` | `push [branch]` |
| `--sync <branch>` | `push <branch> --rebase` |
| `--merge-into <branch>` | `push <branch> --merge` |
| `--extract` | `pull` |
| `--extract --auto-merge main` | `pull main` |
| `merge --branch main` | `pull main` |
| `merge --reconcile main` | `pull main --reconcile` |
| `merge --check main` | `status main` |
| `merge --verify` | `status` |
