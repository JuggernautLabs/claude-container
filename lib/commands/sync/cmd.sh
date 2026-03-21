#!/usr/bin/env bash
# Subcommand: sync
# Bidirectional sync between container and host
#
# Usage:
#   claude-container sync -s <session> <branch> [options]
#   claude-container sync -s myproj main                    # sync all repos
#   claude-container sync -s myproj main --repo gamma       # sync one repo
#   claude-container sync -s myproj main --dry-run          # preview only

cmd_sync() {
    local session_name=""
    local branch=""
    local repo_filter=""
    local dry_run=false
    local verify=true
    local squash=true
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --repo)
                if [[ -n "$repo_filter" ]]; then
                    repo_filter="${repo_filter},$2"
                else
                    repo_filter="$2"
                fi
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --verify)
                verify=true
                shift
                ;;
            --no-verify)
                verify=false
                shift
                ;;
            --squash)
                squash=true
                shift
                ;;
            --no-squash)
                squash=false
                shift
                ;;
            --force|-f)
                force=true
                shift
                ;;
            --help|-h)
                _sync_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container sync --help' for usage"
                return 1
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
                else
                    error "Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Session name required: use --session <name>"
        return 1
    fi
    if [[ -z "$branch" ]]; then
        error "Target branch required"
        echo "Usage: claude-container sync -s <session> <branch>"
        return 1
    fi

    local volume="claude-session-${session_name}"
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    # Step 1: Snapshot all state
    local _sync_dir
    _sync_dir=$(mktemp -d)
    trap "rm -rf '$_sync_dir'" RETURN

    info "Syncing session '$session_name' ↔ '$branch'..."
    echo ""

    snapshot_session_state "$volume" "$session_name" "$branch" "$_sync_dir" "$repo_filter"

    # Step 2: Classify each repo
    for _sf in "$_sync_dir"/*; do
        [[ -f "$_sf" ]] || continue
        local _name
        _name=$(grep "^repo_name=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
        [[ -z "$_name" ]] && continue
        repo_matches_filter "$_name" "$repo_filter" || continue
        classify_repo_sync_state "$_sync_dir" "$_name" "$session_name" "$branch"
    done

    # Step 3: Show the plan
    show_sync_plan "$session_name" "$branch" "$_sync_dir" "$repo_filter"

    if $dry_run; then
        return 0
    fi

    if [[ $_SYNC_TOTAL -eq 0 ]]; then
        return 0
    fi

    # Step 4: Confirm
    if $verify && [[ -t 0 ]]; then
        echo ""
        printf "Proceed with sync? [y/N] "
        local _answer
        read -r _answer
        case "$_answer" in
            [yY]|[yY][eE][sS])
                info "Syncing..."
                ;;
            *)
                info "Aborted."
                return 0
                ;;
        esac
    fi

    # Step 5: Execute
    echo ""
    local _exec_rc=0
    execute_sync "$session_name" "$branch" "$_sync_dir" "$repo_filter" "$squash" || _exec_rc=$?

    return $_exec_rc
}

_sync_help() {
    cat <<'EOF'
Usage: claude-container sync -s <session> <branch> [options]

Bidirectional sync between container and host. Makes both sides identical.

For each repo, sync detects the state and takes the appropriate action:
  - Container ahead  →  pull (extract + merge into host branch)
  - Host ahead       →  push (fast-forward into container)
  - Diverged         →  reconcile (merge in container, then pull back)
  - Identical        →  skip

Arguments:
  branch                   Target branch to sync against (required)

Options:
  --session, -s <name>     Session name (required)
  --repo <name>            Only sync this repo (partial name OK, repeatable)
  --no-verify              Skip confirmation prompt
  --verify                 Show plan and confirm (default)
  --dry-run                Show plan only, no changes
  --squash                 Squash-merge (default)
  --no-squash              Preserve full commit history
  --force, -f              Force sync (overwrite diverged repos)
  --help, -h               Show this help

Examples:
  # Sync all repos against main
  claude-container sync -s myproj main

  # Preview sync plan
  claude-container sync -s myproj main --dry-run

  # Sync one repo
  claude-container sync -s myproj main --repo gamma

  # Automated sync (no prompts)
  claude-container sync -s myproj main --no-verify

  # Watch + auto-sync
  claude-container watch -s myproj --repo gamma -- \
    claude-container sync -s myproj main --repo gamma --no-verify
EOF
}
