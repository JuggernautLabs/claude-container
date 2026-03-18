#!/usr/bin/env bash
# Push help text

_push_help() {
    cat <<EOF
Usage: claude-container push -s <session> [branch] [options]

Push host changes into a container session (host → container).

Arguments:
  branch                   Source branch to push from (default: main)

Options:
  --session, -s <name>     Session name (required)
  --repo <name>[,<branch>] Only push this repo, optionally from a specific branch.
                           Name can be partial (e.g. 'synapse' matches 'org/synapse').
  --as <branch>            Don't merge — just place host branch in container as <branch>.
                           Agent in container can merge at its own pace.
  --ff                     Fast-forward from host branch (default)
  --merge                  Merge host branch into session
  --rebase                 Rebase session onto host branch
  --verify                 Preview what merge would do and confirm before proceeding
  --dry-run                Preview only, don't execute
  --discuss                Preview + launch Claude to discuss merge state
  --force, -f              Force operation
  --help, -h               Show this help

Strategies (mutually exclusive):
  --as <branch>      Place host branch in container without merging. The agent can
                     then: git merge <branch>  (e.g. git merge host/main)
  --ff (default)     Fetch + fast-forward. If diverged, shows all available options.
  --merge            Merge upstream into session. Launches container if conflicts.
  --rebase           Rebase session onto upstream. Launches container if conflicts.

Examples:
  # Fast-forward from main (default)
  claude-container push -s myproj main

  # Fast-forward from main (main is default branch)
  claude-container push -s myproj

  # Merge main into session (launches container if conflicts)
  claude-container push -s myproj main --merge

  # Rebase session onto main (launches container if conflicts)
  claude-container push -s myproj main --rebase

  # Push a single repo's main branch into session
  claude-container push -s myproj --repo synapse,main

  # Force-reset a single diverged repo
  claude-container push -s myproj --repo synapse,main --force
EOF
}
