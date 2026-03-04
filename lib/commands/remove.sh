#!/usr/bin/env bash
# Subcommand: remove
# Remove repos from an existing session
#
# Usage:
#   claude-container remove -s <session> --exclude <pattern> [--exclude <pattern> ...]
#   claude-container remove -s <session> --include <pattern> [--include <pattern> ...]

cmd_remove() {
    local session_name=""
    local -a exclude_patterns=()
    local -a include_patterns=()
    local force=false
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --exclude|-e)
                exclude_patterns+=("$2")
                shift 2
                ;;
            --include|-i)
                include_patterns+=("$2")
                shift 2
                ;;
            --force|-f)
                force=true
                shift
                ;;
            --dry-run|-n)
                dry_run=true
                shift
                ;;
            --help|-h)
                _remove_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container remove --help' for usage"
                return 1
                ;;
            *)
                error "Unexpected argument: $1"
                echo "Run 'claude-container remove --help' for usage"
                return 1
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Session name required: use --session <name>"
        echo "Run 'claude-container remove --help' for usage"
        return 1
    fi

    if [[ ${#exclude_patterns[@]} -eq 0 && ${#include_patterns[@]} -eq 0 ]]; then
        error "At least one --exclude or --include pattern required"
        echo "Run 'claude-container remove --help' for usage"
        return 1
    fi

    local volume="claude-session-${session_name}"
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    # Read current config
    local config_content
    config_content=$(read_session_config "$volume")
    if [[ -z "$config_content" ]]; then
        error "No .claude-projects.yml found in session"
        return 1
    fi

    local projects
    projects=$(parse_session_projects "$config_content")
    if [[ -z "$projects" ]]; then
        error "No projects found in session config"
        return 1
    fi

    # Build removal list
    local -a remove_names=()
    local -a keep_names=()

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        local should_remove=false

        if [[ ${#include_patterns[@]} -gt 0 ]]; then
            # Include = include in removal (matching repos are removed)
            for pattern in "${include_patterns[@]}"; do
                if _match_pattern "$proj_name" "$pattern"; then
                    should_remove=true
                    break
                fi
            done
        fi

        if [[ ${#exclude_patterns[@]} -gt 0 ]]; then
            # Exclude = exclude from removal (matching repos are kept, overrides include)
            for pattern in "${exclude_patterns[@]}"; do
                if _match_pattern "$proj_name" "$pattern"; then
                    should_remove=false
                    break
                fi
            done
        fi

        if $should_remove; then
            remove_names+=("$proj_name")
        else
            keep_names+=("$proj_name")
        fi
    done <<< "$projects"

    if [[ ${#remove_names[@]} -eq 0 ]]; then
        info "No repos matched — nothing to remove"
        return 0
    fi

    if [[ ${#keep_names[@]} -eq 0 ]] && ! $force; then
        error "This would remove ALL repos from the session. Use --force to confirm."
        return 1
    fi

    # Show what will be kept and removed
    echo ""
    info "Session: $session_name"

    if [[ ${#keep_names[@]} -gt 0 ]]; then
        echo ""
        echo "  Keeping (${#keep_names[@]}):"
        for name in "${keep_names[@]}"; do
            success "    $name"
        done
    fi

    echo ""
    echo "  Removing (${#remove_names[@]}):"
    for name in "${remove_names[@]}"; do
        warn "    $name"
    done

    echo ""

    if $dry_run; then
        info "(dry run — no changes made)"
        return 0
    fi

    if ! $force; then
        echo ""
        echo -n "Proceed? [y/N] "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Aborted."
            return 1
        fi
    fi

    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
    local host_uid
    host_uid=$(get_host_uid)

    # Remove directories from volume
    local rm_script=""
    for name in "${remove_names[@]}"; do
        rm_script+="rm -rf '/session/$name'; "
    done

    info "Removing ${#remove_names[@]} repo(s) from volume..."
    docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "$rm_script" 2>/dev/null || true

    # Update config: delete entries via yq
    info "Updating .claude-projects.yml..."
    local updated_config="$config_content"
    for name in "${remove_names[@]}"; do
        updated_config=$(echo "$updated_config" | yq eval "del(.projects.\"$name\")" -)
    done

    echo "$updated_config" | docker run --rm -i \
        --user "$host_uid:$host_uid" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c 'cat > /session/.claude-projects.yml' 2>/dev/null

    echo ""
    success "Removed ${#remove_names[@]} repo(s) from session '$session_name'"
    for name in "${remove_names[@]}"; do
        echo "  - $name"
    done
}

# Match a project name against a pattern
# If pattern contains glob chars (* or ?), match as glob.
# Otherwise, match as substring.
_match_pattern() {
    local name="$1"
    local pattern="$2"

    if [[ "$pattern" == *'*'* || "$pattern" == *'?'* ]]; then
        # Glob mode
        # shellcheck disable=SC2254
        case "$name" in
            $pattern) return 0 ;;
        esac
    else
        # Substring mode
        [[ "$name" == *"$pattern"* ]] && return 0
    fi
    return 1
}

_remove_help() {
    cat <<EOF
Usage: claude-container remove -s <session> --include <pattern> [options]
       claude-container remove -s <session> --include <pattern> --exclude <pattern>

Remove repos from an existing session.

Filters (combinable, exclude takes priority):
  --include, -i <pattern>    Include in removal: remove repos matching pattern (can repeat)
  --exclude, -e <pattern>    Exclude from removal: keep repos matching pattern (overrides include)

Patterns are glob-style (matched against the project name in .claude-projects.yml):
  juggernautlabs/cllient         Exact match
  juggernautlabs/*               All repos under juggernautlabs/
  *tui*                          Any repo with "tui" in the name

Options:
  --session, -s <name>       Session name (required)
  --dry-run, -n              Show what would be removed without changing anything
  --force, -f                Skip confirmation prompt
  --help, -h                 Show this help

Examples:
  # Remove a specific repo
  claude-container remove -s myproj --include cllient

  # Remove multiple repos
  claude-container remove -s myproj -i cllient -i old-thing

  # Remove all repos under an org
  claude-container remove -s myproj --include 'juggernautlabs/*'

  # Remove all juggernautlabs repos except substrate
  claude-container remove -s myproj --include juggernautlabs --exclude substrate

  # Preview what would be removed
  claude-container remove -s myproj --include '*tui*' --dry-run
EOF
}
