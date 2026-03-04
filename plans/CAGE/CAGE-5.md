# CAGE-5: High-Level Session Commands

blocked_by: [CAGE-3, CAGE-4, CAGE-8]
unlocks: []

## Scope

Implement the user-facing session commands. These compose volume, container, and agent primitives into simple workflows. Sessions are the primary abstraction — users never think about volumes or containers directly.

## Session Config

```yaml
# ~/.config/cage/sessions/<name>.yml
agent: claude
volume: <name>          # defaults to session name
repos:
  synapse:
    host: /Users/me/dev/synapse
  vox:
    host: /Users/me/dev/vox
```

Session config extends volume config with agent binding. Creating a session creates the volume config too.

## Commands

### `cage -s <name> run`

Create (if needed) and start an interactive session.

```bash
cage -s myproj run                              # default agent, resume if exists
cage -s myproj run --agent aider                # specific agent
cage -s myproj run --prompt "fix the auth bug"  # initial task
cage -s myproj run --resume                     # continue previous conversation
cage -s myproj run --repo ~/dev/synapse --repo ~/dev/vox   # create with repos
cage -s myproj run --discover ~/dev/myorg       # create with discovered repos
```

Flow:
```
1. if session config doesn't exist:
     require --repo or --discover (error otherwise)
     write ~/.config/cage/sessions/<name>.yml
     cage volume create <name> --repo ...

2. if container doesn't exist:
     cage container create <name>

3. if --prompt:
     write to /workspace/.cage/inbox/task.json (via utility container)

4. cage container start <name>
     (agent runs, user interacts)

5. agent exits → container stays running

6. read /workspace/.cage/outbox/ (report any messages)

7. print: "cage -s <name> extract       # get your changes"
          "cage -s <name> run --resume  # continue working"
```

### `cage -s <name> stop`

```bash
cage -s myproj stop
```

Stop the container. Everything preserved. Volume accessible for sync.

Flow:
```
1. cage container stop <name>
2. print: "Session stopped. Volume intact."
```

### `cage -s <name> delete`

```bash
cage -s myproj delete
cage -s myproj delete --keep-volume   # destroy container, keep workspace
```

Flow:
```
1. confirm (unless --yes)
2. cage container rm <name>
3. if not --keep-volume:
     cage volume delete <name>
4. rm ~/.config/cage/sessions/<name>.yml
```

### `cage -s <name> info`

```bash
cage -s myproj info
```

Show session details: agent, repos, container state, last activity, volume size.

### `cage -s <name> extract [<branch>]`

Pull session changes to host.

```bash
cage -s myproj extract              # create session-named branches on host
cage -s myproj extract main         # extract + merge into main (clean only)
cage -s myproj extract --force      # overwrite diverged branches
```

Flow (extract only):
```
1. cage volume bundle <name>           # create git bundles from volume
2. for each repo:
     cd <host-repo>
     git fetch <bundle>
     git branch <session-name> FETCH_HEAD   # create/update session branch
3. report: "Created branch '<name>' on N repos"
```

Flow (extract + merge into branch):
```
1. extract (above)
2. for each repo:
     cd <host-repo>
     git checkout <branch>
     git merge --ff-only <session-name>   # only clean merges
     if fails:
       report: "Cannot fast-forward <repo>. Run: cage -s <name> land <branch>"
3. report results
```

### `cage -s <name> inject <branch>`

Push host branch changes into session.

```bash
cage -s myproj inject main                # fast-forward
cage -s myproj inject main --rebase       # rebase session onto main
cage -s myproj inject main --merge        # merge main into session
cage -s myproj inject main --repo synapse # single repo
cage -s myproj inject main --force        # force-reset diverged repos
```

Flow (fast-forward, default):
```
1. cage volume fetch <name> <branch>
2. cage volume ff <name> <branch>
3. report per-repo results
4. if any diverged:
     suggest: --rebase, --merge, or --force
```

Flow (rebase):
```
1. cage volume fetch <name> <branch>
2. cage volume rebase <name> <branch>
3. if conflicts:
     write conflict summary to .cage/inbox/task.json
     cage container start <name>   # agent resolves
4. if clean:
     report success
```

Flow (merge):
```
1. cage volume fetch <name> <branch>
2. cage volume merge <name> <branch>
3. if conflicts:
     write conflict summary to .cage/inbox/task.json
     cage container start <name>   # agent resolves
4. if clean:
     report success
```

### `cage -s <name> land <branch>`

Safe merge: guarantee branch is never dirty.

```bash
cage -s myproj land main
```

This is the "merge feature onto main without ever leaving main dirty" operation.

Flow:
```
1. cage volume fetch <name> <branch>      # get latest main into volume
2. cage volume merge <name> <branch>      # merge main INTO session

3. if conflicts:
     write task to .cage/inbox/task.json:
       "Merge main into session. Resolve conflicts. Run fin when done."
     cage container start <name>           # agent resolves
     wait for agent exit
     read .cage/outbox/done.json
     if not complete: abort, report

4. # Session now contains branch as ancestor
   cage volume bundle <name>              # extract
   for each repo:
     cd <host-repo>
     git fetch <bundle>
     git checkout <branch>
     git merge --ff-only FETCH_HEAD       # GUARANTEED fast-forward

5. report: "Landed <name> onto <branch>"
```

The guarantee: step 2 merges branch INTO session. After resolution, session's HEAD has branch as ancestor. Step 4's `--ff-only` cannot fail.

### `cage -s <name> diff [<branch>]`

```bash
cage -s myproj diff              # session state classification
cage -s myproj diff main         # compare against specific branch
cage -s myproj diff --repo vox   # single repo
```

Read-only. No changes made. Shows per-repo status.

Flow:
```
1. cage volume heads <name>
2. for each repo:
     compare volume HEAD vs host branch HEAD
     classify: match / host-ahead / session-ahead / diverged / missing
3. print table
```

### `cage list`

```bash
cage list
cage list --name-only
```

List all sessions with: name, agent, state (running/stopped/no-container), repo count.

Scan `~/.config/cage/sessions/*.yml` + cross-reference Docker containers.

## Error Handling

- `run` with no repos and no existing session: error with usage hint
- `extract` on non-existent session: error
- `inject` when volume doesn't exist: error
- `land` when branch can't be fetched: error
- `delete` on running container: confirm, then stop+rm

## Acceptance Criteria

- [ ] `cage -s X run` creates volume+container on first use, resumes on subsequent
- [ ] `cage -s X run --prompt` writes task to inbox, agent receives it
- [ ] `cage -s X stop` stops container, preserves state
- [ ] `cage -s X delete` cleans up everything (or keeps volume with flag)
- [ ] `cage -s X extract` creates session-named branches on host
- [ ] `cage -s X extract main` merges into main (clean only, ff-only)
- [ ] `cage -s X inject main` fast-forwards session from host
- [ ] `cage -s X inject main --rebase` rebases with conflict handling
- [ ] `cage -s X inject main --merge` merges with conflict handling
- [ ] `cage -s X land main` does safe merge (never leaves main dirty)
- [ ] `cage -s X diff` shows comparison table
- [ ] `cage list` shows all sessions
- [ ] Conflict resolution launches container with task in inbox
- [ ] Post-resolution reads outbox for completion status
