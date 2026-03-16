#!/usr/bin/env bash
# Subcommand: watch
# Watch a session for changes, run a command when they occur
#
# Usage:
#   claude-container watch -s <session> [options] -- <command...>
#   claude-container watch -s myproj -- claude-container pull -s myproj main
#   claude-container watch -s myproj --repo gamma -i 2 -- bun run build

cmd_watch() {
    local session_name=""
    local repo_filter=""
    local interval=5
    local -a user_cmd=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --)
                shift
                user_cmd=("$@")
                break
                ;;
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --repo)
                repo_filter="$2"
                shift 2
                ;;
            --interval|-i)
                interval="$2"
                shift 2
                ;;
            --help|-h)
                _watch_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container watch --help' for usage"
                return 1
                ;;
            *)
                error "Unexpected argument: $1 (put command after --)"
                return 1
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Session name required: use --session <name>"
        return 1
    fi

    if [[ ${#user_cmd[@]} -eq 0 ]]; then
        error "Command required after --"
        echo "Example: claude-container watch -s $session_name -- claude-container pull -s $session_name main"
        return 1
    fi

    local volume="claude-session-${session_name}"
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    # Get initial HEADs
    declare -A _prev_heads
    local _heads
    _heads=$(get_session_heads "$volume")
    while IFS='|' read -r _name _head; do
        [[ -z "$_name" ]] && continue
        [[ -n "$repo_filter" && "$_name" != *"$repo_filter"* ]] && continue
        _prev_heads[$_name]="$_head"
    done <<< "$_heads"

    local _repo_count=${#_prev_heads[@]}
    local _label="session '${session_name}'"
    [[ -n "$repo_filter" ]] && _label="$_label (repo: $repo_filter)"

    info "Watching $_label (${_repo_count} repo(s), every ${interval}s)"
    info "Command: ${user_cmd[*]}"
    info "Press Ctrl+C to stop"
    echo ""

    # Run the command once on startup
    _watch_run_cmd "${user_cmd[@]}"

    # Poll loop
    local _queued=false
    while true; do
        sleep "$interval"

        # Check for changes
        local _changed=false
        local -a _changed_repos=()
        _heads=$(get_session_heads "$volume")

        while IFS='|' read -r _name _head; do
            [[ -z "$_name" ]] && continue
            [[ -n "$repo_filter" && "$_name" != *"$repo_filter"* ]] && continue

            local _prev="${_prev_heads[$_name]:-}"
            if [[ "$_head" != "$_prev" ]]; then
                _changed=true
                _changed_repos+=("$_name")
                _prev_heads[$_name]="$_head"
            fi
        done <<< "$_heads"

        if $_changed; then
            local _ts
            _ts=$(date +%H:%M:%S)
            echo ""
            info "[$_ts] Change detected: ${_changed_repos[*]}"
            _watch_run_cmd "${user_cmd[@]}"

            # After command finishes, check if more changes arrived during execution.
            # Keep draining until stable.
            while true; do
                local _more=false
                _heads=$(get_session_heads "$volume")
                while IFS='|' read -r _name _head; do
                    [[ -z "$_name" ]] && continue
                    [[ -n "$repo_filter" && "$_name" != *"$repo_filter"* ]] && continue
                    if [[ "$_head" != "${_prev_heads[$_name]:-}" ]]; then
                        _more=true
                        _prev_heads[$_name]="$_head"
                    fi
                done <<< "$_heads"

                if $_more; then
                    _ts=$(date +%H:%M:%S)
                    info "[$_ts] Queued changes detected, re-running..."
                    _watch_run_cmd "${user_cmd[@]}"
                else
                    break
                fi
            done
        fi
    done
}

_watch_run_cmd() {
    local _ts
    _ts=$(date +%H:%M:%S)
    echo -e "${BLUE}[$_ts] Running: $*${NC}"
    "$@"
    local _rc=$?
    _ts=$(date +%H:%M:%S)
    if [[ $_rc -eq 0 ]]; then
        echo -e "${GREEN}[$_ts] Done (exit 0)${NC}"
    else
        echo -e "${YELLOW}[$_ts] Done (exit $_rc)${NC}"
    fi
    return $_rc
}

_watch_help() {
    cat <<EOF
Usage: claude-container watch -s <session> [options] -- <command...>

Watch a session for new commits, run a command when changes are detected.
Changes that arrive while the command is running are queued and trigger
a re-run after the current execution finishes.

Options:
  --session, -s <name>     Session name (required)
  --repo <name>            Only watch this repo (partial name OK)
  --interval, -i <secs>    Poll interval in seconds (default: 5)
  --help, -h               Show this help

The command runs once on startup, then again whenever a change is detected.
Multiple rapid changes are coalesced — if changes arrive while the command
is running, it re-runs once after completion (not once per change).

Examples:
  # Pull and merge into main whenever session changes
  claude-container watch -s myproj -- claude-container pull -s myproj main

  # Watch one repo, extract only
  claude-container watch -s myproj --repo gamma -- claude-container pull -s myproj

  # Run a build after extracting
  claude-container watch -s myproj --repo gamma -- sh -c \\
    'claude-container pull -s myproj && cd ~/dev/myproj && bun run build'

  # Faster polling
  claude-container watch -s myproj -i 2 -- claude-container pull -s myproj main
EOF
}
