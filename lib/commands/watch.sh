#!/usr/bin/env bash
# Subcommand: watch
# Watch a session for changes and auto-extract to host (live sync)
#
# Usage:
#   claude-container watch -s <session> [options]
#   claude-container watch -s myproj                    # extract on change
#   claude-container watch -s myproj main               # extract + merge into main on change
#   claude-container watch -s myproj --repo gamma       # only watch one repo
#   claude-container watch -s myproj -i 3               # poll every 3 seconds

cmd_watch() {
    local session_name=""
    local branch=""
    local repo_filter=""
    local interval=5
    local squash=true
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
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
                _watch_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container watch --help' for usage"
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

    local volume="claude-session-${session_name}"
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    # Build extract args (reused each cycle)
    local -a extract_base_args=("$session_name" --force)
    if [[ -n "$repo_filter" ]]; then
        extract_base_args+=(--repo "$repo_filter")
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
    [[ -n "$branch" ]] && _label="$_label → $branch"

    info "Watching $_label (${_repo_count} repo(s), every ${interval}s)"
    info "Press Ctrl+C to stop"
    echo ""

    # Do an initial extraction
    _watch_sync "$session_name" "$branch" "$squash" "$repo_filter" "${extract_base_args[@]}"

    # Poll loop
    local _cycle=0
    while true; do
        sleep "$interval"
        _cycle=$((_cycle + 1))

        # Get current HEADs
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
            info "[$_ts] Change detected in: ${_changed_repos[*]}"
            _watch_sync "$session_name" "$branch" "$squash" "$repo_filter" "${extract_base_args[@]}"
        fi
    done
}

# Run extraction + optional merge, compact output
_watch_sync() {
    local session_name="$1"
    local branch="$2"
    local squash="$3"
    local repo_filter="$4"
    shift 4
    local -a extract_args=("$@")

    # Extract (force, quiet — we just want the files updated)
    session_extract "${extract_args[@]}" 2>/dev/null

    # If branch specified, merge
    if [[ -n "$branch" ]]; then
        local _pull_result_dir
        _pull_result_dir=$(mktemp -d)

        # Re-extract with result tracking for report
        session_extract "${extract_args[@]}" --result-dir "$_pull_result_dir" 2>/dev/null

        local _squash_flag="$squash"
        session_auto_merge "$session_name" "$branch" false "$repo_filter" "$_squash_flag" "$_pull_result_dir" 2>/dev/null || true

        # Compact report
        _watch_report "$session_name" "$branch" "$_pull_result_dir" "$repo_filter"
        rm -rf "$_pull_result_dir"
    else
        # Extract-only: show what changed
        local _ts
        _ts=$(date +%H:%M:%S)
        success "[$_ts] Extracted to host"
    fi
}

# Compact single-line-per-repo report for watch mode
_watch_report() {
    local session_name="$1"
    local target_branch="$2"
    local result_dir="$3"
    local repo_filter="${4:-}"
    local volume="claude-session-${session_name}"

    local config_content
    config_content=$(read_session_config "$volume")
    local projects=""
    if [[ -n "$config_content" ]]; then
        projects=$(parse_session_projects "$config_content")
    fi

    # Collect repo names from result files
    local -a _repo_names=()
    local -A _repo_seen=()
    if [[ -n "$projects" ]]; then
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_pname" ]] && continue
            [[ -n "$repo_filter" && "$_pname" != *"$repo_filter"* ]] && continue
            local _rfile="${result_dir}/${_pname//\//_}"
            if [[ -f "$_rfile" ]]; then
                _repo_names+=("$_pname")
                _repo_seen[$_pname]=1
            fi
        done <<< "$projects"
    fi

    local _ts
    _ts=$(date +%H:%M:%S)

    for _repo in "${_repo_names[@]}"; do
        local _ext_status _merge_status _merge_detail
        _ext_status=$(_pull_result_get "$result_dir" "$_repo" "extract_status")
        _merge_status=$(_pull_result_get "$result_dir" "$_repo" "merge_status")
        _merge_detail=$(_pull_result_get "$result_dir" "$_repo" "merge_detail")
        local _ext_commits
        _ext_commits=$(_pull_result_get "$result_dir" "$_repo" "extract_commits")

        # Compact one-liner per repo
        local _line="[$_ts] $_repo:"
        case "$_ext_status" in
            updated)
                _line="$_line extracted"
                [[ -n "$_ext_commits" && "$_ext_commits" != "0" ]] && _line="$_line (${_ext_commits} commits)"
                ;;
            unchanged) _line="$_line no changes" ;;
            *) _line="$_line extract:$_ext_status" ;;
        esac

        if [[ -n "$target_branch" && -n "$_merge_status" ]]; then
            case "$_merge_status" in
                OK)
                    case "$_merge_detail" in
                        "already up to date"|"squash-merged (no new"*)
                            _line="$_line → up to date"
                            ;;
                        *)
                            _line="$_line → ${_merge_detail}"
                            ;;
                    esac
                    ;;
                CONFLICT)
                    _line="$_line → CONFLICT"
                    ;;
                SKIP)
                    _line="$_line → skipped"
                    ;;
            esac
        fi

        case "$_merge_status" in
            CONFLICT) warn "$_line" ;;
            OK)
                case "$_merge_detail" in
                    "already up to date"|"squash-merged (no new"*) echo -e "  ${BLUE}$_line${NC}" ;;
                    *) success "$_line" ;;
                esac
                ;;
            *) info "$_line" ;;
        esac
    done
}

_watch_help() {
    cat <<EOF
Usage: claude-container watch -s <session> [branch] [options]

Watch a session for changes and auto-extract to host. Enables live
development: run \`bun dev\` or \`cargo watch\` locally while Claude
works in the container — changes appear as they're committed.

Arguments:
  branch                   Target branch to auto-merge into (omit for extract-only)

Options:
  --session, -s <name>     Session name (required)
  --repo <name>            Only watch this repo (partial name OK)
  --interval, -i <secs>    Poll interval in seconds (default: 5)
  --squash                 Squash-merge into target (default)
  --no-squash              Regular merge into target
  --help, -h               Show this help

How it works:
  Polls the container session for new commits. When a change is detected,
  extracts the session branch to host (force-overwrite). If a target branch
  is specified, also auto-merges into it.

  The session branch on host is always force-updated from the container.
  Your target branch (e.g. main) is protected by conflict detection —
  only clean merges are applied.

Examples:
  # Watch and extract only (for bun dev / cargo watch)
  claude-container watch -s myproj --repo gamma

  # Watch, extract, and merge into main
  claude-container watch -s myproj main

  # Faster polling (every 2 seconds)
  claude-container watch -s myproj --repo gamma -i 2

  # Watch all repos in session
  claude-container watch -s myproj
EOF
}
