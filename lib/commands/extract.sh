#!/usr/bin/env bash
# Subcommand: extract
# Extract session branches to host repos, optionally auto-merge
#
# Usage:
#   claude-container extract -s <session> [options]
#   claude-container extract -s myproj                # extract session branches
#   claude-container extract -s myproj --auto-merge   # extract + merge into main
#   claude-container extract -s myproj --auto-merge develop  # extract + merge into develop

cmd_extract() {
    local session_name=""
    local force=false
    local auto_merge=false
    local auto_merge_branch="main"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --force|-f)
                force=true
                shift
                ;;
            --auto-merge)
                auto_merge=true
                # Optional branch argument (default: main)
                if [[ -n "${2:-}" ]] && [[ ! "$2" =~ ^- ]]; then
                    auto_merge_branch="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --help|-h)
                _extract_help
                return 0
                ;;
            *)
                error "Unknown option: $1"
                echo "Run 'claude-container extract --help' for usage"
                return 1
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Session name required: use --session <name>"
        echo "Run 'claude-container extract --help' for usage"
        return 1
    fi

    # Extract session branches to host repos
    local extract_args=("$session_name")
    if $force; then
        extract_args+=(--force)
    fi
    session_extract "${extract_args[@]}"

    # Optionally merge into target branch
    if $auto_merge; then
        echo ""
        session_auto_merge "$session_name" "$auto_merge_branch"
    fi
}

_extract_help() {
    cat <<EOF
Usage: claude-container extract -s <session> [options]

Extract session branches from container volumes into host repositories.
Optionally merge the extracted branches into a target branch.

Options:
  --session, -s <name>     Session name (required)
  --force, -f              Force extraction even if branches diverged
  --auto-merge [branch]    After extracting, merge into branch (default: main)
  --help, -h               Show this help

Examples:
  # Extract session branches to host repos
  claude-container extract -s myproj

  # Extract and merge into main
  claude-container extract -s myproj --auto-merge

  # Extract and merge into develop
  claude-container extract -s myproj --auto-merge develop

  # Force re-extract (overwrite diverged branches)
  claude-container extract -s myproj --force
EOF
}
