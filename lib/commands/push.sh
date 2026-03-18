#!/usr/bin/env bash
# Subcommand: push
# Push host changes into a container session (host → container)
#
# Usage:
#   claude-container push -s <session> [branch] [options]
#   claude-container push -s myproj main                # fast-forward from main (default)
#   claude-container push -s myproj main --merge        # merge main into session
#   claude-container push -s myproj main --rebase       # rebase session onto main

cmd_push() {
    local session_name=""
    local branch=""
    local target_as=""
    local strategy="ff"  # ff, merge, rebase, serve
    local force=false
    local verify=false
    local dry_run=false
    local discuss=false
    local repo_filter=""
    local repo_branch=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --repo)
                # Parse --repo name[,branch] — supports multiple: --repo a --repo b
                local _repo_arg="$2"
                local _repo_name _repo_br=""
                if [[ "$_repo_arg" == *,* ]]; then
                    _repo_name="${_repo_arg%%,*}"
                    _repo_br="${_repo_arg#*,}"
                else
                    _repo_name="$_repo_arg"
                fi
                if [[ -n "$repo_filter" ]]; then
                    repo_filter="${repo_filter},${_repo_name}"
                else
                    repo_filter="$_repo_name"
                fi
                [[ -n "$_repo_br" ]] && repo_branch="$_repo_br"
                shift 2
                ;;
            --as)
                target_as="$2"
                strategy="serve"
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
            --verify)
                verify=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --discuss)
                discuss=true
                verify=true
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
        serve)
            # Serve: push host branch into container as a named branch (no merge)
            local serve_branch="${repo_branch:-${branch:-main}}"
            session_serve "$session_name" "$serve_branch" "$target_as" "$repo_filter"
            return $?
            ;;
        ff)
            # Fast-forward: fetch + ff from host branch (default)
            if $dry_run || $verify; then
                # Preview needs merge path — redirect there
                strategy="merge"
            else
                local refresh_branch="${repo_branch:-${branch:-main}}"
                session_refresh "$session_name" "$refresh_branch" "$repo_filter" "$force"
                return $?
            fi
            ;&  # fall through to merge
        merge)
            # Merge host branch into session
            local merge_branch="${branch:-main}"

            if $dry_run || $verify; then
                # Source pull.sh for preview functions
                source "$(dirname "${BASH_SOURCE[0]}")/pull.sh"
                # Show preview of what merge would do
                _pull_reconcile_preview "$session_name" "$merge_branch" "$repo_filter"
                if $dry_run; then
                    return 0
                fi

                if $discuss; then
                    echo ""
                    # Build result dir for discuss prompt
                    local _push_discuss_dir
                    _push_discuss_dir=$(mktemp -d)
                    session_auto_merge "$session_name" "$merge_branch" true "$repo_filter" true "$_push_discuss_dir" 2>/dev/null || true
                    local _discuss_prompt
                    _discuss_prompt=$(_build_discuss_prompt "$session_name" "$merge_branch" "$_push_discuss_dir" "$repo_filter")
                    rm -rf "$_push_discuss_dir"
                    info "Launching Claude to discuss merge state..."
                    echo ""
                    claude "$_discuss_prompt"
                    echo ""
                fi

                echo ""
                printf "Merge '%s' into session '%s'? [y/N] " "$merge_branch" "$session_name"
                local _answer
                read -r _answer
                case "$_answer" in
                    [yY]|[yY][eE][sS])
                        info "Merging..."
                        ;;
                    *)
                        info "Aborted."
                        return 0
                        ;;
                esac
            fi

            if ! session_merge_into "$session_name" "$merge_branch"; then
                # Clean merge — extract resolved state
                session_extract "$session_name" --force
                return 0
            fi
            # Conflicts — exec back for container startup with auto-merge
            exec "$0" --session "$session_name" --auto-merge
            ;;
        rebase)
            # Rebase session onto host branch
            local rebase_branch="${branch:-main}"
            session_sync "$session_name" "$rebase_branch"
            # session_sync stores .sync-branch marker and returns to main script
            # for container startup (conflicts need Claude). Exec back.
            exec "$0" --session "$session_name"
            ;;
    esac
}

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
