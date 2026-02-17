#!/usr/bin/env bash
# Subcommand: list
# List all claude-container sessions
#
# Usage:
#   claude-container list                  # full table with sizes
#   claude-container list --name-only      # just session names

cmd_list() {
    local name_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name-only|-n)
                name_only=true
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

    session_list "$name_only"
}

_list_help() {
    cat <<EOF
Usage: claude-container list [options]

List all claude-container sessions.

Options:
  --name-only, -n    Print only session names (no sizes, fast)
  --help, -h         Show this help

Examples:
  # Full table with disk usage per volume
  claude-container list

  # Just session names (fast, no Docker scan)
  claude-container list --name-only

  # Use in scripts
  for s in \$(claude-container list --name-only); do
    claude-container status -s "\$s"
  done
EOF
}
