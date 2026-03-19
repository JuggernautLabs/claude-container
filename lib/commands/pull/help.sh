#!/usr/bin/env bash
# Pull help text

_pull_help() {
    cat <<EOF
Usage: claude-container pull -s <session> [branch] [options]

Pull session changes from container to host (container → host).

Arguments:
  branch                   Target branch to merge into (omit for extract-only)

Options:
  --session, -s <name>     Session name (required)
  --repo <name>            Only pull this repo (partial name OK, e.g. 'gamma')
  --at <commitish>         Extract from a specific commit instead of HEAD.
                           Accepts any git ref: SHA, tag, branch, HEAD~N.
  --status                 Read-only check: compare container vs host (no extraction)
  --reconcile, -R          Full reconcile: stash dirty, merge target into session,
                           launch Claude for conflicts, then merge back
  --squash                 Squash-merge (default). Tracks prior squashes so repeat pulls
                           only merge new commits — no conflicts from squash history.
  --no-squash              Regular merge. Preserves full session commit history on target.
  --verify                 Extract and show results, then ask before merging
  --discuss                Like --verify, but also launches Claude to discuss the diff
  --extract                Extract repos discovered in session (created by agent).
                           Use with --repo to extract specific repos, or alone for all.
  --dry-run                Show what would happen without extracting or merging
  --force, -f              Force extraction even if branches diverged (container wins)
  --help, -h               Show this help

Modes:
  No branch (default)  Extract session branches to host repos only.
  With branch          Extract + auto-merge into the target branch.
                       Only clean merges are performed — repos that would conflict
                       are skipped, and you'll be told to resolve in-container first.
  --status             Read-only check: shows which repos have changed, diverged,
                       or need extraction. No modifications made.
  --reconcile          Extract → stash dirty → merge target into session →
                       resolve conflicts (launches container if needed) → merge back.

Safety:
  Merging into a non-session branch (e.g. main) will only proceed if the merge
  would complete without conflicts. If conflicts are detected, the repo is
  skipped and you'll see:

    claude-container pull -s <session> <branch> --reconcile

  This ensures conflicts are always resolved in the container where Claude can
  help, never on the host where they'd block you.

Examples:
  # Check what's changed (read-only)
  claude-container pull -s myproj --status

  # Extract session branches to host repos
  claude-container pull -s myproj

  # Extract from a specific point in session history
  claude-container pull -s myproj --at HEAD~3
  claude-container pull -s myproj main --at v1.0

  # Extract and merge into main (skips repos that would conflict)
  claude-container pull -s myproj main

  # Review before merging
  claude-container pull -s myproj main --verify

  # Full reconcile cycle against main
  claude-container pull -s myproj main --reconcile

  # Preview what would happen (no changes made)
  claude-container pull -s myproj main --dry-run

  # Pull a single repo
  claude-container pull -s myproj --repo gamma
  claude-container pull -s myproj main --repo plexus-gamma

  # Extract a repo discovered in the session (created by agent)
  claude-container pull -s myproj --extract --repo new-thing

  # Extract ALL discovered repos
  claude-container pull -s myproj --extract

  # Force extraction (overwrite diverged branches)
  claude-container pull -s myproj --force

Recommended workflow:
  1. push -s X main --merge   # merge main INTO session (Claude resolves conflicts)
  2. pull -s X                # extract session branches to host
  3. pull -s X main           # merge into main (guaranteed clean, session has main)
EOF
}
