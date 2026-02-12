# Data Transfer Overview

How data moves between your host repos and the container session volume.

```
                    HOST                          CONTAINER
                 (your repos)                   (docker volume)
                     |                               |
                     |                               |
  ---------------- HOST -> CONTAINER ---------------------------------
                     |                               |
  session create     | --- bundle repos ---------->  |  initial clone
  --discover-repos   |                               |
                     |                               |
  --refresh [branch] | --- fetch + fast-forward -->  |  pull latest from
                     |     (default: session branch) |  host into session
                     |                               |
  --sync <branch>    | --- fetch + rebase -------->  |  rebase session onto
                     |     (Claude resolves)         |  updated upstream
                     |                               |
  --merge-into <br>  | --- fetch + merge --------->  |  merge target branch
                     |     (Claude resolves)         |  into session
                     |                               |
  --add-repo <path>  | --- clone single repo ----->  |  add repo to session
                     |                               |
                     |                               |
  ---------------- CONTAINER -> HOST ---------------------------------
                     |                               |
  --extract          | <-- git bundle -------------- |  create session-named
  extract -s X       |     (branch per repo)         |  branches on host
                     |                               |
  merge --branch <b> | <-- bundle + merge ---------- |  extract then merge
                     |     (into target branch)      |  into target branch
                     |                               |
                     |                               |
  ---------------- BIDIRECTIONAL -------------------------------------
                     |                               |
  merge --reconcile  | <-- extract ----------------  |
    <branch>         | --- stash dirty work          |
                     | --- merge target into ------>  |  merge + resolve
                     | <-- extract resolved --------  |  then merge back
                     | --- auto-merge into target    |
                     |                               |
                     |                               |
  ---------------- READ-ONLY ----------------------------------------
                     |                               |
  merge --check <b>  |    compare hashes             |  no data transferred
  merge --verify     |    classify sync state        |
```

## Command Reference

| Command | Direction | Strategy | Claude? |
|---------|-----------|----------|---------|
| session create | host -> container | bundle clone | no |
| `--add-repo` | host -> container | clone | no |
| `--refresh [branch]` | host -> container | fetch + fast-forward | no |
| `--sync <branch>` | host -> container | fetch + rebase | yes, if conflicts |
| `--merge-into <branch>` | host -> container | fetch + merge | yes, if conflicts |
| `--extract` | container -> host | git bundle | no |
| `merge --branch <b>` | container -> host | bundle + merge | no |
| `merge --reconcile <b>` | both | extract, merge, resolve, merge back | yes, if conflicts |
| `merge --check` | read-only | hash comparison | no |
| `merge --verify` | read-only | sync classification | no |

## Choosing the Right Tool

**"I need to get host changes into the container"**
- Small update, no conflicts: `--refresh`
- Upstream moved significantly: `--sync main`
- Need to merge a specific branch in: `--merge-into main`

**"I need to get container work onto the host"**
- Just want branches: `--extract`
- Want branches merged into a target: `merge --branch main`
- Host is dirty or conflicts expected: `merge --reconcile main`

**"I need to check if things are in sync"**
- Hash-level comparison: `merge --check main`
- Sync state classification: `merge --verify`
