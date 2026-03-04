#!/usr/bin/env bash
# Subcommand: list
# List all claude-container sessions
#
# Usage:
#   claude-container list                  # fast: names + last opened
#   claude-container list --sizes          # include disk usage (slow)
#   claude-container list --name-only      # just session names

cmd_list() {
    local name_only=false
    local show_sizes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name-only|-n)
                name_only=true
                shift
                ;;
            --sizes|-S)
                show_sizes=true
                shift
                ;;
            --help|-h)
                _list_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container list --help' for usage"
                return 1
                ;;
            *)
                error "Unexpected argument: $1"
                echo "Run 'claude-container list --help' for usage"
                return 1
                ;;
        esac
    done

    session_list "$name_only" "$show_sizes"
}

_list_help() {
    cat <<EOF
Usage: claude-container list [options]

List all claude-container sessions.

Options:
  --sizes, -S        Include disk usage per volume (slow — runs du in container)
  --name-only, -n    Print only session names (no table)
  --help, -h         Show this help

Examples:
  # List sessions with last-opened time (fast)
  claude-container list

  # Include disk usage (slower)
  claude-container list --sizes

  # Just session names
  claude-container list --name-only

  # Use in scripts
  for s in \$(claude-container list --name-only); do
    claude-container status -s "\$s"
  done
EOF
}
