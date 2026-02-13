#!/usr/bin/env bash
# Subcommand: push
# Push host changes into a container session (host → container)
#
# Usage:
#   claude-container push -s <session> [branch] [options]
#   claude-container push -s myproj                     # fast-forward from session-named branch
#   claude-container push -s myproj main                # fast-forward from main
#   claude-container push -s myproj main --rebase       # rebase session onto main
#   claude-container push -s myproj main --merge        # merge main into session

cmd_push() {
    local session_name=""
    local branch=""
    local strategy="ff"  # ff, rebase, merge
    local force=false
    local repo_filter=""
    local repo_branch=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --repo)
                # Parse --repo name[,branch]
                if [[ "$2" == *,* ]]; then
                    repo_filter="${2%%,*}"
                    repo_branch="${2#*,}"
                else
                    repo_filter="$2"
                fi
                shift 2
                ;;
            --ff)
                strategy="ff"
                shift
                ;;
            --rebase)
                strategy="rebase"
                shift
                ;;
            --merge)
                strategy="merge"
                shift
                ;;
            --force|-f)
                force=true
                shift
                ;;
            --help|-h)
                _push_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container push --help' for usage"
                return 1
                ;;
            *)
                # Positional arg = branch name
                if [[ -z "$branch" ]]; then
                    branch="$1"
                else
                    error "Unexpected argument: $1"
                    echo "Run 'claude-container push --help' for usage"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Session name required: use --session <name>"
        echo "Run 'claude-container push --help' for usage"
        return 1
    fi

    case "$strategy" in
        ff)
            # Fast-forward: fetch + ff from host branch
            # repo_branch (from --repo name,branch) overrides positional branch
            local refresh_branch="${repo_branch:-${branch:-$session_name}}"
            session_refresh "$session_name" "$refresh_branch" "$repo_filter" "$force"
            return $?
            ;;
        rebase)
            # Rebase session onto host branch
            local rebase_branch="${branch:-main}"
            session_sync "$session_name" "$rebase_branch"
            # session_sync stores .sync-branch marker and returns to main script
            # for container startup (conflicts need Claude). Exec back.
            exec "$0" --session "$session_name"
            ;;
        merge)
            # Merge host branch into session
            local merge_branch="${branch:-main}"
            if ! session_merge_into "$session_name" "$merge_branch"; then
                # Clean merge — extract resolved state
                session_extract "$session_name" --force
                return 0
            fi
            # Conflicts — exec back for container startup with auto-merge
            exec "$0" --session "$session_name" --auto-merge
            ;;
    esac
}

_push_help() {
    cat <<EOF
Usage: claude-container push -s <session> [branch] [options]

Push host changes into a container session (host → container).

Arguments:
  branch                   Source branch to push from (default: session name for --ff, main for --rebase/--merge)

Options:
  --session, -s <name>     Session name (required)
  --repo <name>[,<branch>] Only push this repo, optionally from a specific branch.
                           Name can be partial (e.g. 'synapse' matches 'org/synapse').
  --ff                     Fast-forward from host branch (default)
  --rebase                 Rebase session onto host branch
  --merge                  Merge host branch into session
  --force, -f              Force operation
  --help, -h               Show this help

Strategies (mutually exclusive):
  --ff (default)   Fetch + fast-forward. No container needed unless diverged.
  --rebase         Rebase session onto upstream. Launches container if conflicts.
  --merge          Merge upstream into session. Launches container if conflicts.

Examples:
  # Fast-forward session from host (session-named branch)
  claude-container push -s myproj

  # Fast-forward from main
  claude-container push -s myproj main

  # Rebase session onto main
  claude-container push -s myproj main --rebase

  # Merge main into session (for conflict resolution)
  claude-container push -s myproj main --merge

  # Push a single repo's main branch into session
  claude-container push -s myproj --repo synapse,main

  # Force-reset a single diverged repo
  claude-container push -s myproj --repo synapse,main --force

Migration from old flags:
  --refresh [branch]    →  push [branch]
  --sync <branch>       →  push <branch> --rebase
  --merge-into <branch> →  push <branch> --merge
EOF
}
