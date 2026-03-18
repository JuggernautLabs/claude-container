#!/usr/bin/env bash
# Subcommand: push
# Push host changes into a container session (host -> container)
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
                _push_preview "$session_name" "$merge_branch" "$repo_filter"
                if $dry_run; then
                    return 0
                fi

                if $discuss; then
                    echo ""
                    local _push_discuss_dir
                    _push_discuss_dir=$(mktemp -d)
                    session_auto_merge "$session_name" "$merge_branch" true "$repo_filter" true "$_push_discuss_dir" 2>/dev/null || true
                    local _discuss_prompt
                    _discuss_prompt=$(_push_discuss_prompt "$session_name" "$merge_branch" "$_push_discuss_dir" "$repo_filter")
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

            # Capture pre-merge state for reporting (if we didn't already show preview)
            if ! $dry_run && ! $verify; then
                _push_preview "$session_name" "$merge_branch" "$repo_filter"
                echo ""
            fi

            # Run the merge (suppress inline output — preview already showed what will happen)
            local _merge_needs_container=false
            if session_merge_into "$session_name" "$merge_branch" > /dev/null 2>&1; then
                _merge_needs_container=true
            fi

            if $_merge_needs_container; then
                # Conflicts — launch container for Claude
                echo ""
                warn "Merge has conflicts — launching container for Claude to resolve."
                exec "$0" --session "$session_name" --auto-merge
            fi

            # Clean merge — show post-merge report
            _push_report "$session_name" "$merge_branch" "$repo_filter"
            return 0
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
