#!/usr/bin/env bash
# Subcommand: reconcile
# Merge multiple sessions into a unified branch sequentially
#
# Usage:
#   claude-container reconcile <branch> [session...] [options]
#   claude-container reconcile main s1 s2 s3          # process named sessions
#   claude-container reconcile main                    # auto-discover sessions
#   claude-container reconcile main --dry-run          # preview what would happen
#   claude-container reconcile --continue              # resume interrupted reconcile

cmd_reconcile() {
    local target_branch=""
    local sessions=()
    local force=false
    local dry_run=false
    local yes=false
    local do_continue=false
    local include_patterns=()
    local exclude_patterns=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --continue)
                do_continue=true
                shift
                ;;
            --force|-f)
                force=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --yes|-y)
                yes=true
                shift
                ;;
            --include)
                if [[ -z "${2:-}" ]]; then
                    error "--include requires a regex pattern"
                    return 1
                fi
                include_patterns+=("$2")
                shift 2
                ;;
            --exclude)
                if [[ -z "${2:-}" ]]; then
                    error "--exclude requires a regex pattern"
                    return 1
                fi
                exclude_patterns+=("$2")
                shift 2
                ;;
            --help|-h)
                _reconcile_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container reconcile --help' for usage"
                return 1
                ;;
            *)
                # First positional = target branch, rest = session names
                if [[ -z "$target_branch" ]]; then
                    target_branch="$1"
                else
                    sessions+=("$1")
                fi
                shift
                ;;
        esac
    done

    # --continue mode: resume from plan file
    if $do_continue; then
        _reconcile_resume
        return $?
    fi

    if [[ -z "$target_branch" ]]; then
        error "Target branch required"
        echo "Usage: claude-container reconcile <branch> [session...] [options]"
        return 1
    fi

    # Check for existing plan file
    if [[ -f "$CONFIG_DIR/.reconcile-plan" ]]; then
        error "A reconcile is already in progress"
        echo "Run 'claude-container reconcile --continue' to resume"
        echo "Or delete $CONFIG_DIR/.reconcile-plan to start fresh"
        return 1
    fi

    # Auto-discover sessions if none specified
    if [[ ${#sessions[@]} -eq 0 ]]; then
        info "Discovering sessions with unmerged work..."
        local discovered=()
        _reconcile_discover discovered "$target_branch"

        if [[ ${#discovered[@]} -eq 0 ]]; then
            info "No sessions with unmerged work found"
            return 0
        fi

        sessions=("${discovered[@]}")
    fi

    # Apply include/exclude filters
    if [[ ${#include_patterns[@]} -gt 0 || ${#exclude_patterns[@]} -gt 0 ]]; then
        local filtered=()
        for s in "${sessions[@]}"; do
            # Exclude takes priority — check it first
            local excluded=false
            for pat in "${exclude_patterns[@]}"; do
                if [[ "$s" =~ $pat ]]; then
                    excluded=true
                    break
                fi
            done
            $excluded && continue

            # If include patterns given, session must match at least one
            if [[ ${#include_patterns[@]} -gt 0 ]]; then
                local included=false
                for pat in "${include_patterns[@]}"; do
                    if [[ "$s" =~ $pat ]]; then
                        included=true
                        break
                    fi
                done
                $included || continue
            fi

            filtered+=("$s")
        done

        if [[ ${#filtered[@]} -eq 0 ]]; then
            info "No sessions matched after applying include/exclude filters"
            return 0
        fi

        sessions=("${filtered[@]}")
    fi

    # Confirmation
    echo ""
    info "Reconcile plan:"
    echo "  Target branch: $target_branch"
    echo "  Sessions (${#sessions[@]}):"
    for s in "${sessions[@]}"; do
        echo "    - $s"
    done
    echo ""

    if $dry_run; then
        info "Dry run — checking each session..."
        echo ""
        _reconcile_dry_run "$target_branch" "$force" "${sessions[@]}"
        return 0
    fi

    if ! $yes; then
        read -r -p "Proceed? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
            info "Aborted"
            return 0
        fi
    fi

    # Write plan file and start processing
    _reconcile_write_plan "$target_branch" "$force" "${sessions[@]}"
    echo ""
    _reconcile_process_next
}

_reconcile_discover() {
    local -n _out_sessions=$1
    local target_branch="$2"

    local volumes
    volumes=$(docker volume ls -q 2>/dev/null | grep "^claude-session-" || true)
    [[ -z "$volumes" ]] && return

    while IFS= read -r volume; do
        local session_name
        session_name=$(extract_session_name "$volume")
        [[ -z "$session_name" ]] && continue

        # Check if session has unmerged work
        local heads
        heads=$(get_session_heads "$volume" 2>/dev/null) || continue
        [[ -z "$heads" ]] && continue

        local has_unmerged=false
        while IFS='|' read -r proj_name proj_head; do
            [[ -z "$proj_name" ]] && continue

            # Resolve host path for this project
            local host_path
            host_path=$(resolve_repo_host_path "$proj_name" "$volume")
            [[ -z "$host_path" || ! -d "$host_path" ]] && continue

            local status
            status=$(check_repo_sync_status "$proj_name" "$proj_head" "$host_path" "$session_name")

            case "$status" in
                not_extracted|extracted_only)
                    has_unmerged=true
                    break
                    ;;
            esac
        done <<< "$heads"

        if $has_unmerged; then
            _out_sessions+=("$session_name")
        fi
    done <<< "$volumes"
}

_reconcile_dry_run() {
    local target_branch="$1"
    local force="$2"
    shift 2
    local sessions=("$@")

    for session_name in "${sessions[@]}"; do
        local volume="claude-session-${session_name}"

        if ! docker volume inspect "$volume" &>/dev/null; then
            warn "  $session_name: session not found (would skip)"
            continue
        fi

        info "  $session_name: checking..."

        # Read config without extracting (non-destructive)
        local config_content
        config_content=$(read_session_config "$volume")
        if [[ -z "$config_content" ]]; then
            warn "  $session_name: no config (would skip)"
            continue
        fi

        local projects
        projects=$(parse_session_projects "$config_content")
        local would_conflict=false
        local not_extracted=false

        while IFS='|' read -r proj_name proj_path; do
            [[ -z "$proj_name" ]] && continue
            [[ ! -d "$proj_path" ]] && continue

            # Check if session branch exists on host
            if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
                # Session branch not extracted yet — need to extract first to test
                not_extracted=true
                continue
            fi

            # Check if already merged
            if git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
                if git -C "$proj_path" merge-base --is-ancestor "$session_name" "$target_branch" 2>/dev/null; then
                    continue
                fi
            fi

            # Check if target branch exists for merge test
            if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
                continue  # Would create branch — no conflict
            fi

            # Fast-forward check
            if git -C "$proj_path" merge-base --is-ancestor "$target_branch" "$session_name" 2>/dev/null; then
                continue  # Would fast-forward — no conflict
            fi

            # Dry-run merge test
            local current_branch
            current_branch=$(git -C "$proj_path" symbolic-ref --short HEAD 2>/dev/null || echo "")

            if [[ "$current_branch" != "$target_branch" ]]; then
                git -C "$proj_path" checkout "$target_branch" 2>/dev/null || continue
            fi

            if ! git -C "$proj_path" merge --no-commit --no-ff "$session_name" 2>/dev/null; then
                git -C "$proj_path" merge --abort 2>/dev/null || true
                would_conflict=true
            else
                git -C "$proj_path" merge --abort 2>/dev/null || true
            fi

            if [[ "$current_branch" != "$target_branch" ]]; then
                git -C "$proj_path" checkout "$current_branch" 2>/dev/null || true
            fi
        done <<< "$projects"

        if $would_conflict; then
            warn "  $session_name: would need container resolution (conflicts)"
        elif $not_extracted; then
            info "  $session_name: needs extraction first (run without --dry-run to process)"
        else
            success "  $session_name: would merge cleanly"
        fi
    done
}

_reconcile_process_next() {
    # Read plan
    local target_branch="" plan_force=""
    local -a plan_sessions=()
    local -a plan_statuses=()
    _reconcile_read_plan target_branch plan_force plan_sessions plan_statuses

    # Find first pending session
    local idx=-1
    for i in "${!plan_statuses[@]}"; do
        if [[ "${plan_statuses[$i]}" == "pending" ]]; then
            idx=$i
            break
        fi
    done

    if [[ $idx -eq -1 ]]; then
        # All done
        _reconcile_summary
        rm -f "$CONFIG_DIR/.reconcile-plan"
        return 0
    fi

    local session_name="${plan_sessions[$idx]}"
    local volume="claude-session-${session_name}"

    _reconcile_update_plan "$session_name" "in_progress"

    # Check session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        warn "Session not found: $session_name (skipping)"
        _reconcile_update_plan "$session_name" "completed"
        _reconcile_process_next
        return $?
    fi

    echo ""
    info "Processing session: $session_name"
    echo ""

    # Phase 1: Extract
    local extract_args=("$session_name")
    if [[ "$plan_force" == "true" ]]; then
        extract_args+=(--force)
    fi
    session_extract "${extract_args[@]}"
    echo ""

    # Phase 2: Auto-merge into target
    session_auto_merge "$session_name" "$target_branch"
    local rc=$?

    if [[ $rc -eq 2 ]]; then
        # Conflicts — need container resolution
        info "Conflicts detected — launching container for resolution..."
        _reconcile_update_plan "$session_name" "in_container"

        # Merge target INTO session (so Claude can resolve conflicts inside container)
        session_merge_into "$session_name" "$target_branch"
        local merge_rc=$?

        if [[ $merge_rc -eq 1 ]]; then
            # session_merge_into returns 1 = clean merge (no container needed)
            # This means conflicts were only in the opposite direction
            info "Clean merge — extracting and continuing..."
            session_extract "$session_name" --force
            echo ""
            session_auto_merge "$session_name" "$target_branch"
            _reconcile_update_plan "$session_name" "completed"
            _reconcile_process_next
            return $?
        fi

        # Conflicts/dirty — exec into container for Claude to resolve
        # The exit handler will: extract, auto-merge, then exec reconcile --continue
        export AGENT_TASK="resolve-conflicts"
        exec "$0" --session "$session_name" --auto-merge
        # exec replaces process — no code runs after this
    fi

    # Clean merge (or error) — mark completed and continue
    _reconcile_update_plan "$session_name" "completed"
    _reconcile_process_next
}

_reconcile_resume() {
    if [[ ! -f "$CONFIG_DIR/.reconcile-plan" ]]; then
        error "No reconcile in progress"
        echo "Start one with: claude-container reconcile <branch> [sessions...]"
        return 1
    fi

    info "Resuming reconcile..."

    # Read plan and mark any in_container session as completed
    local target_branch="" plan_force=""
    local -a plan_sessions=()
    local -a plan_statuses=()
    _reconcile_read_plan target_branch plan_force plan_sessions plan_statuses

    for i in "${!plan_statuses[@]}"; do
        if [[ "${plan_statuses[$i]}" == "in_container" || "${plan_statuses[$i]}" == "in_progress" ]]; then
            _reconcile_update_plan "${plan_sessions[$i]}" "completed"
        fi
    done

    _reconcile_process_next
}

_reconcile_write_plan() {
    local target_branch="$1"
    local force="$2"
    shift 2
    local sessions=("$@")

    mkdir -p "$CONFIG_DIR"

    {
        echo "target=$target_branch"
        echo "force=$force"
        for s in "${sessions[@]}"; do
            echo "$s|pending"
        done
    } > "$CONFIG_DIR/.reconcile-plan"
}

_reconcile_read_plan() {
    local -n _target=$1
    local -n _force=$2
    local -n _sessions=$3
    local -n _statuses=$4

    while IFS= read -r line; do
        if [[ "$line" == target=* ]]; then
            _target="${line#target=}"
        elif [[ "$line" == force=* ]]; then
            _force="${line#force=}"
        elif [[ "$line" == *"|"* ]]; then
            _sessions+=("${line%%|*}")
            _statuses+=("${line#*|}")
        fi
    done < "$CONFIG_DIR/.reconcile-plan"
}

_reconcile_update_plan() {
    local session="$1"
    local new_status="$2"
    local plan_file="$CONFIG_DIR/.reconcile-plan"

    # Use sed to update the status in-place
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/^${session}|.*$/${session}|${new_status}/" "$plan_file"
    else
        sed -i "s/^${session}|.*$/${session}|${new_status}/" "$plan_file"
    fi
}

_reconcile_summary() {
    local target_branch="" plan_force=""
    local -a plan_sessions=()
    local -a plan_statuses=()
    _reconcile_read_plan target_branch plan_force plan_sessions plan_statuses

    echo ""
    success "Reconcile complete!"
    echo ""
    echo "  Target: $target_branch"
    echo "  Sessions processed: ${#plan_sessions[@]}"
    for i in "${!plan_sessions[@]}"; do
        echo "    ${plan_sessions[$i]}: ${plan_statuses[$i]}"
    done
}

_reconcile_help() {
    cat <<EOF
Usage: claude-container reconcile <branch> [session...] [options]

Merge multiple sessions into a unified branch, sequentially.

Each session is extracted and auto-merged into the target branch. If conflicts
are detected, a container is launched for Claude to resolve them. After the
container exits, reconcile continues with remaining sessions.

Arguments:
  branch                   Target branch to merge all sessions into (required)
  session...               Session names to process (optional — auto-discovers if omitted)

Options:
  --include <regex>        Only process sessions matching regex (repeatable)
  --exclude <regex>        Skip sessions matching regex (repeatable, wins over --include)
  --force, -f              Force extraction even if branches diverged
  --dry-run                Show what would happen without merging
  --yes, -y                Skip confirmation prompt
  --continue               Resume an interrupted reconcile from the plan file
  --help, -h               Show this help

Processing Order:
  Sessions are processed sequentially in the order given (or discovery order).
  Each merge changes the target branch, so order matters. Control priority by
  listing sessions explicitly.

Conflict Resolution:
  When a session would conflict with the target branch, reconcile:
  1. Merges the target INTO the session (inside the container)
  2. Launches a container for Claude to resolve conflicts
  3. On container exit, extracts and merges back (guaranteed clean)
  4. Continues with remaining sessions via --continue

  Conflicts only happen inside containers — never on the host.

Plan File:
  State is persisted to ~/.config/claude-container/.reconcile-plan so that
  interrupted reconciles can be resumed with --continue. The plan file is
  deleted when all sessions are processed.

Examples:
  # Reconcile specific sessions into main
  claude-container reconcile main feature-auth feature-ui bugfix-api

  # Auto-discover and reconcile all sessions
  claude-container reconcile main

  # Preview without doing anything
  claude-container reconcile main --dry-run

  # Resume after container exit or interruption
  claude-container reconcile --continue

  # Skip confirmation
  claude-container reconcile main s1 s2 --yes

  # Only reconcile feature sessions
  claude-container reconcile main --include 'feature-.*'

  # Reconcile everything except WIP sessions
  claude-container reconcile main --exclude 'wip-.*'

  # Combine: features only, but not the experimental ones
  claude-container reconcile main --include 'feature-' --exclude 'experiment'
EOF
}
