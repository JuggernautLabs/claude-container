#!/usr/bin/env bash
# Subcommand: pull
# Pull session changes from container to host (container → host)
#
# Usage:
#   claude-container pull -s <session> [branch] [options]
#   claude-container pull -s myproj                      # extract only
#   claude-container pull -s myproj main                 # extract + merge into main
#   claude-container pull -s myproj main --reconcile     # full reconcile cycle

cmd_pull() {
    local session_name=""
    local branch=""
    local reconcile=false
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --reconcile|-R)
                reconcile=true
                shift
                ;;
            --force|-f)
                force=true
                shift
                ;;
            --help|-h)
                _pull_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container pull --help' for usage"
                return 1
                ;;
            *)
                # Positional arg = branch name
                if [[ -z "$branch" ]]; then
                    branch="$1"
                else
                    error "Unexpected argument: $1"
                    echo "Run 'claude-container pull --help' for usage"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Session name required: use --session <name>"
        echo "Run 'claude-container pull --help' for usage"
        return 1
    fi

    # Extract session branches to host repos
    local extract_args=("$session_name")
    if $force; then
        extract_args+=(--force)
    fi

    if $reconcile; then
        # Reconcile mode requires a branch
        if [[ -z "$branch" ]]; then
            error "--reconcile requires a target branch"
            echo "Usage: claude-container pull -s <session> <branch> --reconcile"
            return 1
        fi
        _pull_reconcile "$session_name" "$branch" "$force"
        return $?
    fi

    # Extract
    session_extract "${extract_args[@]}"

    # If branch specified, also merge into target
    if [[ -n "$branch" ]]; then
        echo ""
        session_auto_merge "$session_name" "$branch"
    fi
}

_pull_reconcile() {
    local session_name="$1"
    local target_branch="$2"
    local force="$3"
    local volume="claude-session-${session_name}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    # Phase 1: Extract session branches to host repos
    info "Phase 1: Extracting session branches..."
    if [[ "$force" == "true" ]]; then
        session_extract "$session_name" --force
    else
        session_extract "$session_name"
    fi
    echo ""

    # Phase 2: Stash dirty worktrees on host
    info "Phase 2: Checking host repos for uncommitted work..."
    _pull_stash_dirty "$session_name" "$target_branch"
    echo ""

    # Phase 3: Merge target INTO session (inside docker volume)
    # session_merge_into returns:
    #   1 = clean merge, no container needed
    #   0 = conflicts/dirty, needs container with Claude
    info "Phase 3: Merging '$target_branch' into session..."
    if ! session_merge_into "$session_name" "$target_branch"; then
        # Clean merge — extract resolved state and auto-merge into target
        info "Clean merge — extracting and merging into '$target_branch'..."
        session_extract "$session_name" --force
        echo ""
        session_auto_merge "$session_name" "$target_branch"

        # Clean up the .merge-into-branch marker (session_merge_into wrote it)
        local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
        docker run --rm -v "$volume:/session" "$git_image" \
            rm -f /session/.merge-into-branch 2>/dev/null || true
        return 0
    fi

    # Conflicts detected — session_merge_into already wrote:
    #   .merge-into-branch  (target branch name)
    #   .merge-into-summary (Claude's initial prompt with fin instructions)
    #   .merge-into-mounts  (dirty projects needing host mounts)
    # Exec back into claude-container to launch container for resolution
    info "Launching container for conflict resolution..."
    echo ""
    exec "$0" --session "$session_name" --auto-merge
}

_pull_stash_dirty() {
    local session_name="$1"
    local target_branch="$2"
    local volume="claude-session-${session_name}"

    local config_content
    config_content=$(read_session_config "$volume")
    [[ -z "$config_content" ]] && return 0

    local projects
    projects=$(parse_session_projects "$config_content")
    [[ -z "$projects" ]] && return 0

    local stash_count=0
    local timestamp
    timestamp=$(date +%s)

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        [[ ! -d "$proj_path" ]] && continue

        local dirty
        dirty=$(git -C "$proj_path" status --porcelain 2>/dev/null)
        [[ -z "$dirty" ]] && continue

        local stash_branch="${target_branch}-${session_name}-stash-${timestamp}"
        local current_branch
        current_branch=$(git -C "$proj_path" symbolic-ref --short HEAD 2>/dev/null || echo "")

        info "  $proj_name: stashing to branch '$stash_branch'"

        git -C "$proj_path" checkout -b "$stash_branch" 2>/dev/null
        git -C "$proj_path" add -A 2>/dev/null
        git -C "$proj_path" commit -m "WIP: stashed by reconcile (session: $session_name)" --no-verify 2>/dev/null
        if [[ -n "$current_branch" ]]; then
            git -C "$proj_path" checkout "$current_branch" 2>/dev/null
        fi

        stash_count=$((stash_count + 1))
    done <<< "$projects"

    if [[ $stash_count -gt 0 ]]; then
        success "  Stashed $stash_count repo(s)"
    else
        info "  All host repos clean"
    fi
}

_pull_help() {
    cat <<EOF
Usage: claude-container pull -s <session> [branch] [options]

Pull session changes from container to host (container → host).

Arguments:
  branch                   Target branch to merge into (omit for extract-only)

Options:
  --session, -s <name>     Session name (required)
  --reconcile, -R          Full reconcile: stash dirty, merge target into session,
                           launch Claude for conflicts, then merge back
  --force, -f              Force extraction even if branches diverged
  --help, -h               Show this help

Modes:
  No branch        Extract session branches to host repos only.
  With branch      Extract + auto-merge into the target branch.
                   Only clean merges are performed — repos that would conflict
                   are skipped, and you'll be told to resolve in-container first.
  --reconcile      Extract → stash dirty → merge target into session →
                   resolve conflicts (launches container if needed) → merge back.

Safety:
  Merging into a non-session branch (e.g. main) will only proceed if the merge
  would complete without conflicts. If conflicts are detected, the repo is
  skipped and you'll see:

    claude-container push -s <session> <branch> --merge
    claude-container pull -s <session> <branch>

  This ensures conflicts are always resolved in the container where Claude can
  help, never on the host where they'd block you.

Examples:
  # Extract session branches to host repos
  claude-container pull -s myproj

  # Extract and merge into main (skips repos that would conflict)
  claude-container pull -s myproj main

  # Extract and merge into develop
  claude-container pull -s myproj develop

  # Full reconcile cycle against main
  claude-container pull -s myproj main --reconcile

  # Force extraction (overwrite diverged branches)
  claude-container pull -s myproj --force

Recommended workflow:
  1. push main --merge     # merge main INTO session (Claude resolves conflicts)
  2. pull                  # extract session branches to host
  3. pull main             # merge into main (guaranteed clean, session has main)

Migration from old commands:
  --extract                    →  pull
  --extract --auto-merge main  →  pull main
  extract -s X --auto-merge    →  pull -s X main
  merge -s X --branch main     →  pull -s X main
  merge -s X --reconcile main  →  pull -s X main --reconcile
EOF
}
