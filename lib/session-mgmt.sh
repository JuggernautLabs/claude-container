#!/usr/bin/env bash
# claude-container session management module - List, delete, restart, extract sessions
# Source this file after utils.sh
#
# Dependencies:
#   - utils.sh must be sourced first (provides: info, success, warn, error)
#   - docker-utils.sh must be sourced first (provides: docker_run_in_volume, get_volume_sizes_batch, etc.)
#
# This module provides functions for managing claude-container sessions:
#   - session_cleanup: Clean up all claude-container Docker volumes
#   - session_list: List all sessions with disk usage
#   - session_delete: Delete a specific session and its volumes
#   - session_restart: Restart a session with permission fixes
#   - session_extract: Extract session changes as branches in original repos
#   - session_import: Import a claude session into container

# Source docker-utils.sh if not already sourced
if [[ -z "$(type -t docker_run_in_volume)" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/docker-utils.sh"
fi

# ============================================================================
# Volume Utility Functions
# ============================================================================

# Extract session name from a Docker volume name
# Arguments:
#   $1 - volume name (e.g., "claude-session-foo", "claude-state-bar")
# Returns: session name without prefix, or empty string
extract_session_name() {
    local volume="$1"
    case "$volume" in
        claude-session-*) echo "${volume#claude-session-}" ;;
        claude-state-*)   echo "${volume#claude-state-}" ;;
        claude-cargo-*)   echo "${volume#claude-cargo-}" ;;
        claude-npm-*)     echo "${volume#claude-npm-}" ;;
        claude-pip-*)     echo "${volume#claude-pip-}" ;;
        session-data-*)   echo "${volume#session-data-}" ;;
        *) echo "" ;;
    esac
}

# Map a list of volumes to unique session names
# Arguments:
#   $1 - newline-separated volume names
# Returns: unique session names, sorted
map_volumes_to_sessions() {
    local volumes="$1"

    while read -r vol; do
        [[ -z "$vol" ]] && continue
        local name=$(extract_session_name "$vol")
        [[ -n "$name" ]] && echo "$name"
    done <<< "$volumes" | sort -u
}

# Filter items not in exclude set
# Arguments:
#   $1 - items (newline-separated)
#   $2 - exclude set (newline-separated)
# Returns: items not in exclude set
filter_not_in_set() {
    local items="$1"
    local exclude_set="$2"

    while read -r item; do
        [[ -z "$item" ]] && continue
        echo "$exclude_set" | grep -q "^${item}$" || echo "$item"
    done <<< "$items"
}

# ============================================================================
# Session Management Functions
# ============================================================================

# Clean up all claude-container resources (volumes)
# Usage: session_cleanup
session_cleanup() {
    echo "Cleaning up claude-container resources..."

    # List volumes
    local volumes
    volumes=$(docker volume ls -q | grep -E "^(claude-session-|claude-state-|claude-cargo-|claude-npm-|claude-pip-|session-data-)" || true)

    if [[ -z "$volumes" ]]; then
        echo "No volumes to clean up"
        return 0
    fi

    echo "Found volumes:"
    echo "$volumes" | sed 's/^/  /'
    echo ""

    read -p "Delete all? [y/n] " confirm
    if [[ "$confirm" == "y" ]]; then
        echo "$volumes" | xargs docker volume rm
        echo "Done"
    else
        echo "Cancelled"
    fi
}

# Clean up unused claude-container volumes (not mounted by any running container)
# Usage: session_cleanup_unused [--yes]
session_cleanup_unused() {
    local skip_confirm=false
    [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && skip_confirm=true

    echo "Finding unused claude-container volumes..."

    # Get all claude volumes
    local all_volumes
    all_volumes=$(docker volume ls -q | grep -E "^(claude-session-|claude-state-|claude-cargo-|claude-npm-|claude-pip-|session-data-)" || true)

    if [[ -z "$all_volumes" ]]; then
        echo "No claude-container volumes found"
        return 0
    fi

    # Get volumes currently in use by running containers
    local used_volumes
    used_volumes=$(docker ps -q | xargs -r docker inspect 2>/dev/null | \
        grep -oE '"Name": "claude-[^"]+"|"Name": "session-data-[^"]+"' | \
        cut -d'"' -f4 | sort -u || true)

    # Find unused volumes
    local unused_volumes_str
    unused_volumes_str=$(filter_not_in_set "$all_volumes" "$used_volumes")

    local unused_volumes=()
    while read -r vol; do
        [[ -n "$vol" ]] && unused_volumes+=("$vol")
    done <<< "$unused_volumes_str"

    if [[ ${#unused_volumes[@]} -eq 0 ]]; then
        echo "No unused volumes found (all volumes are currently in use)"
        return 0
    fi

    # Show what will be deleted with sizes
    local total_count=$(echo "$all_volumes" | wc -l | tr -d ' ')
    local used_count=$(echo "$used_volumes" | grep -c . || echo 0)
    echo ""
    echo "Total volumes: $total_count"
    echo "In use: $used_count"
    echo "Unused: ${#unused_volumes[@]}"
    echo ""
    echo "Calculating sizes..."

    # Get all sizes in one container run
    local unused_volumes_list
    unused_volumes_list=$(printf "%s\n" "${unused_volumes[@]}")
    local sizes
    sizes=$(get_volume_sizes_batch_with_total "$unused_volumes_list")

    echo ""
    echo "Volumes to delete:"
    local total_human="unknown"
    while IFS='|' read -r name size; do
        [[ -z "$name" ]] && continue
        if [[ "$name" == "TOTAL" ]]; then
            total_human="$size"
        else
            printf "  %-50s %10s\n" "$name" "$size"
        fi
    done <<< "$sizes"
    echo ""
    echo "Total size to free: $total_human"
    echo ""

    # Confirm unless --yes
    if ! $skip_confirm; then
        read -p "Delete ${#unused_volumes[@]} unused volume(s)? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled"
            return 0
        fi
    fi

    # Delete unused volumes
    for vol in "${unused_volumes[@]}"; do
        if docker volume rm "$vol" 2>/dev/null; then
            echo "Deleted: $vol"
        else
            echo "Failed to delete: $vol (may still be in use)"
        fi
    done
    echo "Done"
}

# List all sessions with disk usage
# Usage: session_list
session_list() {
    local name_only="${1:-false}"
    local show_sizes="${2:-false}"

    # Get all claude volumes
    local all_volumes
    all_volumes=$(docker volume ls -q | grep -E "^(claude-session-|claude-state-|claude-cargo-|claude-npm-|claude-pip-)" || true)

    if [[ -z "$all_volumes" ]]; then
        echo "No claude-container sessions found."
        return 0
    fi

    # Extract unique session names
    declare -A sessions
    while read -r vol; do
        [[ -z "$vol" ]] && continue
        local session_name=$(extract_session_name "$vol")
        [[ -n "$session_name" ]] && sessions[$session_name]=1
    done <<< "$all_volumes"

    # Name-only mode: just print names and exit
    if [[ "$name_only" == "true" ]]; then
        for session in $(echo "${!sessions[@]}" | tr ' ' '\n' | sort); do
            echo "$session"
        done
        return 0
    fi

    local sessions_config="${SESSIONS_CONFIG_DIR:-$HOME/.config/claude-container/sessions}"

    # Sizes mode: scan volumes (slow)
    declare -A vol_sizes
    local total_human=""
    if [[ "$show_sizes" == "true" ]]; then
        echo "Scanning $(echo "$all_volumes" | wc -l | tr -d ' ') volumes..."
        local sizes_with_total
        sizes_with_total=$(get_volume_sizes_batch_with_total "$all_volumes")

        while IFS='|' read -r vol size; do
            [[ -z "$vol" ]] && continue
            if [[ "$vol" == "TOTAL" ]]; then
                total_human="$size"
            else
                vol_sizes[$vol]="$size"
            fi
        done <<< "$sizes_with_total"
    fi

    # Scan all session volumes in parallel for latest commit + file stat timestamps
    local now_epoch
    now_epoch=$(date +%s)
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"

    _format_relative_time() {
        local epoch="$1"
        if [[ "$epoch" -le 0 ]]; then
            echo "-"
            return
        fi
        local days_ago=$(( (now_epoch - epoch) / 86400 ))
        if [[ $days_ago -eq 0 ]]; then
            local hours_ago=$(( (now_epoch - epoch) / 3600 ))
            if [[ $hours_ago -eq 0 ]]; then
                echo "<1h ago"
            elif [[ $hours_ago -eq 1 ]]; then
                echo "1h ago"
            else
                echo "${hours_ago}h ago"
            fi
        elif [[ $days_ago -eq 1 ]]; then
            echo "yesterday"
        elif [[ $days_ago -lt 30 ]]; then
            echo "${days_ago}d ago"
        else
            date -r "$epoch" "+%Y-%m-%d" 2>/dev/null \
                || date -d "@$epoch" "+%Y-%m-%d" 2>/dev/null \
                || echo "${days_ago}d ago"
        fi
    }

    # Single docker run mounting ALL session volumes — one container startup
    declare -A _last_commit_epoch
    declare -A _last_stat_epoch

    local _vol_args=()
    local _session_list=""
    for _s in "${!sessions[@]}"; do
        _vol_args+=("-v" "claude-session-${_s}:/sessions/${_s}:ro")
        _session_list+="$_s"$'\n'
    done

    local _scan_output
    _scan_output=$(docker run --rm --entrypoint sh \
        "${_vol_args[@]}" "$git_image" \
        -c '
            git config --global --add safe.directory "*"
            for sess_dir in /sessions/*/; do
                [ -d "$sess_dir" ] || continue
                name="${sess_dir#/sessions/}"
                name="${name%/}"
                cmax=0
                for d in "$sess_dir"/*/ "$sess_dir"/*/*/; do
                    [ -d "$d/.git" ] || continue
                    t=$(cd "$d" && git log -1 --format=%ct 2>/dev/null || echo 0)
                    [ "${t:-0}" -gt "$cmax" ] && cmax=${t:-0}
                done
                smax=$(find "$sess_dir" -maxdepth 4 -type f -not -path "*/.git/*" 2>/dev/null | xargs stat -c "%Y" 2>/dev/null | sort -rn | head -1)
                echo "$name|$cmax|${smax:-0}"
            done
        ' 2>/dev/null || true)

    while IFS='|' read -r _name _commit _stat; do
        [[ -z "$_name" ]] && continue
        _last_commit_epoch[$_name]="${_commit:-0}"
        _last_stat_epoch[$_name]="${_stat:-0}"
    done <<< "$_scan_output"

    # Display table — sort by max(commit, stat) descending
    echo ""
    if [[ "$show_sizes" == "true" ]]; then
        printf "%-26s %12s %12s %10s %10s %10s %10s %10s\n" "SESSION" "LAST COMMIT" "LAST EDIT" "WORKSPACE" "STATE" "CARGO" "NPM" "PIP"
        printf "%-26s %12s %12s %10s %10s %10s %10s %10s\n" "-------" "-----------" "---------" "---------" "-----" "-----" "---" "---"
    else
        printf "%-26s %12s %12s\n" "SESSION" "LAST COMMIT" "LAST EDIT"
        printf "%-26s %12s %12s\n" "-------" "-----------" "---------"
    fi

    local _sorted_sessions=""
    for _s in "${!sessions[@]}"; do
        local _c=${_last_commit_epoch[$_s]:-0}
        local _f=${_last_stat_epoch[$_s]:-0}
        local _max=$(( _c > _f ? _c : _f ))
        _sorted_sessions+="$_max $_s"$'\n'
    done
    _sorted_sessions=$(echo "$_sorted_sessions" | sort -t' ' -k1 -rn -k2)

    while read -r _sort_key session; do
        [[ -z "$session" ]] && continue
        local commit_time stat_time
        commit_time=$(_format_relative_time "${_last_commit_epoch[$session]:-0}")
        stat_time=$(_format_relative_time "${_last_stat_epoch[$session]:-0}")

        if [[ "$show_sizes" == "true" ]]; then
            local ws="${vol_sizes[claude-session-$session]:-"-"}"
            local st="${vol_sizes[claude-state-$session]:-"-"}"
            local ca="${vol_sizes[claude-cargo-$session]:-"-"}"
            local np="${vol_sizes[claude-npm-$session]:-"-"}"
            local pi="${vol_sizes[claude-pip-$session]:-"-"}"
            printf "%-26s %12s %12s %10s %10s %10s %10s %10s\n" "$session" "$commit_time" "$stat_time" "$ws" "$st" "$ca" "$np" "$pi"
        else
            printf "%-26s %12s %12s\n" "$session" "$commit_time" "$stat_time"
        fi
    done <<< "$_sorted_sessions"

    echo ""
    if [[ -n "$total_human" ]]; then
        echo "Total disk usage: $total_human"
        echo ""
    fi
    echo "Commands:"
    echo "  Delete session:  claude-container -s <name> --delete"
    echo "  Pull session:    claude-container pull -s <name>"
    if [[ "$show_sizes" != "true" ]]; then
        echo "  Show sizes:      claude-container list --sizes"
    fi
}

# Delete a specific session and all its volumes
# Usage: session_delete <session_name> [--regex] [--yes]
session_delete() {
    local session="$1"
    local use_regex=false
    local skip_confirm=false

    # Parse flags
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --regex|-r) use_regex=true; shift ;;
            --yes|-y) skip_confirm=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$session" ]]; then
        echo "Error: session_delete requires a session name"
        echo "Usage: session_delete <name> [--regex] [--yes]"
        return 1
    fi

    local volumes_to_delete=()

    if $use_regex; then
        # Regex mode: find all matching volumes
        while IFS= read -r vol; do
            [[ -n "$vol" ]] && volumes_to_delete+=("$vol")
        done < <(docker volume ls -q | grep -E "$session")
    else
        # Strict mode: exact session name match
        for pattern in "claude-session-${session}" "claude-state-${session}" "claude-cargo-${session}" "claude-npm-${session}" "claude-pip-${session}" "session-data-${session}"; do
            if docker volume inspect "$pattern" &>/dev/null; then
                volumes_to_delete+=("$pattern")
            fi
        done
    fi

    if [[ ${#volumes_to_delete[@]} -eq 0 ]]; then
        echo "No volumes found for session: $session (already deleted)"
        return 0
    fi

    # Show what will be deleted
    echo "Volumes to delete:"
    for vol in "${volumes_to_delete[@]}"; do
        echo "  - $vol"
    done
    echo ""

    # Confirm unless --yes
    if ! $skip_confirm; then
        read -p "Delete these ${#volumes_to_delete[@]} volume(s)? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled"
            return 0
        fi
    fi

    # Stop any containers using these volumes
    for vol in "${volumes_to_delete[@]}"; do
        local containers
        containers=$(docker ps -aq --filter "volume=$vol" 2>/dev/null || true)
        if [[ -n "$containers" ]]; then
            echo "Stopping containers using $vol..."
            echo "$containers" | xargs docker rm -f 2>/dev/null || true
        fi
    done

    # Delete
    for vol in "${volumes_to_delete[@]}"; do
        docker volume rm "$vol"
        echo "Deleted: $vol"
    done

    # Clean up session metadata files
    for vol in "${volumes_to_delete[@]}"; do
        local _sname="${vol#claude-session-}"
        [[ "$_sname" != "$vol" ]] && rm -f "$SESSIONS_CONFIG_DIR/${_sname}.env" "$SESSIONS_CONFIG_DIR/${_sname}.yml"
    done

    echo "Done"
}

# Restart a session with permission fixes
# Usage: session_restart <session_name> <script_path> [extra_args...]
session_restart() {
    local session="$1"
    local script_path="$2"
    shift 2
    local extra_args=("$@")

    if [[ -z "$session" ]]; then
        echo "Error: session_restart requires a session name"
        echo "Usage: session_restart <name> <script_path> [options]"
        return 1
    fi

    if [[ -z "$script_path" ]]; then
        echo "Error: session_restart requires script path for re-exec"
        return 1
    fi

    # Find and stop any running container for this session
    local running
    running=$(docker ps -q --filter "name=claude-dev-" 2>/dev/null || true)
    if [[ -n "$running" ]]; then
        info "Stopping running container..."
        docker stop $running >/dev/null 2>&1 || true
    fi

    # Fix permissions on existing volumes before restart
    info "Fixing volume permissions..."
    docker run --rm \
        -v "claude-cargo-${session}:/cargo" \
        -v "claude-npm-${session}:/npm" \
        -v "claude-pip-${session}:/pip" \
        -v "claude-state-${session}:/state" \
        alpine sh -c 'chown -R 1000:1000 /cargo /npm /pip /state 2>/dev/null || true'

    # Re-exec with same session + continue + any extra args
    info "Restarting session: $session"
    exec "$script_path" --session "$session" --continue "${extra_args[@]}"
}

# Bulk-add repos to an existing session (parallel cloning)
# Usage: session_add_repos_bulk <session_name> <repos>
#   repos = newline-separated "workspace_name|host_path" pairs
# Skips repos that already exist in the session.
session_add_repos_bulk() {
    local session="$1"
    local repos="$2"
    local volume="claude-session-${session}"

    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session"
        return 1
    fi

    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"
    local host_uid
    host_uid=$(get_host_uid)

    # Read existing session config to filter already-present repos
    local existing_config
    existing_config=$(read_session_config "$volume" 2>/dev/null || true)
    local existing_names=""
    if [[ -n "$existing_config" ]]; then
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_pname" ]] && continue
            existing_names+="$_pname"$'\n'
        done <<< "$(parse_session_projects "$existing_config")"
    fi

    # Collect repos not yet in config
    local -a new_names=()
    local -a new_paths=()
    while IFS='|' read -r ws_name host_path; do
        [[ -z "$ws_name" ]] && continue
        if echo "$existing_names" | grep -qxF "$ws_name"; then
            continue
        fi
        new_names+=("$ws_name")
        new_paths+=("$host_path")
    done <<< "$repos"

    if [[ ${#new_names[@]} -eq 0 ]]; then
        info "All discovered repos already in session"
        return 0
    fi

    # Check which repos already exist in the volume (e.g. from a previous interrupted run)
    local volume_dirs
    volume_dirs=$(docker run --rm --entrypoint sh -v "$volume:/session:ro" "$git_image" \
        -c '
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"
                name="${name%/}"
                echo "$name"
            done
        ' 2>/dev/null) || true

    local -a clone_names=()
    local -a clone_paths=()
    local -a skip_names=()
    for i in "${!new_names[@]}"; do
        if echo "$volume_dirs" | grep -qxF "${new_names[$i]}"; then
            skip_names+=("${new_names[$i]}")
        else
            clone_names+=("${new_names[$i]}")
            clone_paths+=("${new_paths[$i]}")
        fi
    done

    if [[ ${#skip_names[@]} -gt 0 ]]; then
        info "${#skip_names[@]} repo(s) already in volume, registering in config"
    fi

    local failed=0

    # Clone repos that don't exist yet in a SINGLE container
    if [[ ${#clone_names[@]} -gt 0 ]]; then
        info "Cloning ${#clone_names[@]} new repo(s)..."

        local -a docker_mounts=()
        local clone_script=""
        for i in "${!clone_names[@]}"; do
            local proj_name="${clone_names[$i]}"
            local source_path="${clone_paths[$i]}"
            local safe_name="${proj_name//\//_}"
            docker_mounts+=("-v" "$source_path:/sources/$safe_name:ro")
            clone_script+="(
                mkdir -p /session/$(dirname "$proj_name") && \
                git -c safe.directory='*' clone --depth 1 /sources/$safe_name '/session/$proj_name' && \
                cd '/session/$proj_name' && \
                git remote remove origin 2>/dev/null || true && \
                git config user.email 'claude@container' && \
                git config user.name 'Claude' && \
                size=\$(du -sh '/session/$proj_name' | cut -f1) && \
                echo \"OK|$proj_name|\$size\" || echo \"FAIL|$proj_name\"
            ) &
"
        done
        clone_script+="wait"

        local clone_output
        clone_output=$(docker run --rm --entrypoint sh \
            --user "$host_uid:$host_uid" \
            "${docker_mounts[@]}" \
            -v "$volume:/session" \
            "$git_image" \
            -c "$clone_script" 2>&1) || true

        while IFS='|' read -r status name size; do
            [[ -z "$status" ]] && continue
            if [[ "$status" == "OK" ]]; then
                success "  $name ($size)"
            else
                error "  $name failed"
                failed=1
            fi
        done <<< "$clone_output"
    fi

    # Update .claude-projects.yml in one batch
    local config_append=""
    for i in "${!new_names[@]}"; do
        config_append+="  \"${new_names[$i]}\":
    path: ${new_paths[$i]}
"
    done

    if [[ -n "$config_append" ]]; then
        echo "$config_append" | docker run --rm --entrypoint sh -i \
            --user "$host_uid:$host_uid" \
            -v "$volume:/session" \
            "$git_image" \
            -c 'cat >> /session/.claude-projects.yml' 2>/dev/null || true
    fi

    # Update manifest
    write_repo_manifest "$volume"

    if [[ "$failed" == "1" ]]; then
        warn "Some repos failed to clone"
        return 1
    fi

    success "Added ${#new_names[@]} new repo(s) to session '$session'"
}

# Add a new repo to an existing session
# Usage: session_add_repo <session_name> <repo_path> [workspace_path]
session_add_repo() {
    local session="$1"
    local repo_path="$2"
    local workspace_path="${3:-}"
    local volume="claude-session-${session}"

    if [[ -z "$session" ]] || [[ -z "$repo_path" ]]; then
        error "Usage: session_add_repo <session_name> <repo_path> [workspace_path]"
        return 1
    fi

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session"
        return 1
    fi

    # Verify repo exists and is a git repo
    if ! is_git_repo "$repo_path"; then
        error "Not a git repository: $repo_path"
        return 1
    fi

    # Get absolute path
    local abs_repo_path
    abs_repo_path=$(cd "$repo_path" && pwd)

    # Handle worktrees: clone from main repo and checkout the branch
    local source_repo_path="$abs_repo_path"
    local branch_to_checkout=""

    if is_git_worktree "$abs_repo_path"; then
        source_repo_path=$(get_main_repo_path "$abs_repo_path")
        branch_to_checkout=$(get_git_branch "$abs_repo_path")
        info "Detected worktree, using main repo: $source_repo_path (branch: $branch_to_checkout)"
    fi

    # Default workspace path: infer placement from existing session repos
    # Match the deepest common ancestor between the new repo's host path and
    # any existing project's host path, then mirror the relative path under
    # that project's workspace prefix.
    #
    # Example: existing project "juggernautlabs/substrate" at /a/b/juggernautlabs/substrate
    #   add-repo /a/b/juggernautlabs/nested/cage
    #   → common ancestor with /a/b/juggernautlabs/substrate is /a/b/juggernautlabs
    #   → relative suffix: nested/cage
    #   → workspace prefix dirname: juggernautlabs
    #   → result: juggernautlabs/nested/cage
    if [[ -z "$workspace_path" ]]; then
        local repo_basename
        repo_basename=$(basename "$abs_repo_path")

        local _config_content
        _config_content=$(read_session_config "$volume" 2>/dev/null || true)
        local _best_workspace=""
        local _best_depth=0

        if [[ -n "$_config_content" ]]; then
            local _projects
            _projects=$(parse_session_projects "$_config_content")
            while IFS='|' read -r _pname _ppath; do
                [[ -z "$_pname" || -z "$_ppath" ]] && continue
                # Only consider namespaced entries (prefix/name)
                [[ "$_pname" != */* ]] && continue

                # Find longest common path prefix between existing project's
                # host path and the new repo's host path (component-wise)
                local _existing_parent
                _existing_parent=$(dirname "$_ppath")
                local _new_parent
                _new_parent=$(dirname "$abs_repo_path")

                # Split into components and walk
                local _common=""
                local _ep="$_existing_parent"
                local _np="$_new_parent"

                # Build arrays of path components
                local -a _ec=() _nc=()
                while [[ "$_ep" != "/" && -n "$_ep" ]]; do
                    _ec=("$(basename "$_ep")" "${_ec[@]}")
                    _ep=$(dirname "$_ep")
                done
                while [[ "$_np" != "/" && -n "$_np" ]]; do
                    _nc=("$(basename "$_np")" "${_nc[@]}")
                    _np=$(dirname "$_np")
                done

                # Walk from root, counting matching components
                local _depth=0
                local _i=0
                while [[ $_i -lt ${#_ec[@]} && $_i -lt ${#_nc[@]} ]]; do
                    if [[ "${_ec[$_i]}" == "${_nc[$_i]}" ]]; then
                        _depth=$((_depth + 1))
                    else
                        break
                    fi
                    _i=$((_i + 1))
                done

                # The common prefix must cover at least the existing project's parent
                # (i.e., depth >= number of components in existing parent)
                if [[ $_depth -gt $_best_depth && $_depth -ge ${#_ec[@]} ]]; then
                    # New repo is under (or at) the same ancestor as this project
                    # Compute relative path from that ancestor to the new repo
                    # The ancestor has _depth components; the new repo has all of _nc + basename
                    local _rel=""
                    local _j=$_depth
                    while [[ $_j -lt ${#_nc[@]} ]]; do
                        if [[ -n "$_rel" ]]; then
                            _rel="$_rel/${_nc[$_j]}"
                        else
                            _rel="${_nc[$_j]}"
                        fi
                        _j=$((_j + 1))
                    done

                    # Workspace prefix = dirname of existing workspace name (the org part)
                    local _ws_prefix
                    _ws_prefix=$(dirname "$_pname")

                    if [[ -n "$_rel" ]]; then
                        _best_workspace="$_ws_prefix/$_rel/$repo_basename"
                    else
                        _best_workspace="$_ws_prefix/$repo_basename"
                    fi
                    _best_depth=$_depth
                fi
            done <<< "$_projects"
        fi

        if [[ -n "$_best_workspace" ]]; then
            workspace_path="$_best_workspace"
            info "Inferred workspace path '$workspace_path' from sibling repos"
        else
            workspace_path="$repo_basename"
        fi
    fi

    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
    local host_uid
    host_uid=$(get_host_uid)

    # Check if path already exists in session
    local exists
    exists=$(docker_run_in_volume "$volume" "/session" "$git_image" \
        "test -d '/session/$workspace_path' && echo 'yes' || echo 'no'" "ro")

    if [[ "$exists" == "yes" ]]; then
        error "Path already exists in session: $workspace_path"
        return 1
    fi

    info "Adding repo to session: $workspace_path"

    # Build clone command
    local clone_cmd="
        mkdir -p /session/$(dirname "$workspace_path") && \
        git -c safe.directory='*' clone --depth 1 /source '/session/$workspace_path'"

    if [[ -n "$branch_to_checkout" ]]; then
        clone_cmd="
            mkdir -p /session/$(dirname "$workspace_path") && \
            git -c safe.directory='*' clone --depth 1 --branch '$branch_to_checkout' /source '/session/$workspace_path'"
    fi

    clone_cmd="$clone_cmd && \
        cd '/session/$workspace_path' && \
        git remote remove origin 2>/dev/null || true && \
        git config user.email 'claude@container' && \
        git config user.name 'Claude' && \
        du -sh '/session/$workspace_path' | cut -f1"

    # Clone the repo into the session
    local clone_output
    if ! clone_output=$(docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$source_repo_path:/source:ro" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "$clone_cmd" 2>&1); then
        error "Failed to clone repo:"
        echo "$clone_output" >&2
        return 1
    fi

    local size=$(echo "$clone_output" | tail -1)
    success "Added: $workspace_path ($size)"

    # Update .claude-projects.yml if it exists
    local config_path="$source_repo_path"
    local config_branch="$branch_to_checkout"

    docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "
            if [[ -f /session/.claude-projects.yml ]]; then
                echo '  \"$workspace_path\":' >> /session/.claude-projects.yml
                echo '    path: $config_path' >> /session/.claude-projects.yml
                if [[ -n '$config_branch' ]]; then
                    echo '    branch: $config_branch' >> /session/.claude-projects.yml
                fi
            fi
        " 2>/dev/null || true

    # Update manifest so pull doesn't treat this repo as "new"
    write_repo_manifest "$volume"
}

# Import a claude-code session into a container session
# Usage: session_import <source_path> <session_name> [--force]
session_import() {
    local source_path="$1"
    local session_name="$2"
    local force=false

    # Parse flags
    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$source_path" ]] || [[ -z "$session_name" ]]; then
        error "Usage: session_import <source_path> <session_name> [--force]"
        echo ""
        echo "Examples:"
        echo "  # Import from local claude session"
        echo "  claude-container -s my-session --import ~/.claude"
        echo ""
        echo "  # Import from backup directory"
        echo "  claude-container -s my-session --import /backups/claude-session"
        return 1
    fi

    # Expand ~ to home directory
    source_path="${source_path/#\~/$HOME}"

    # Verify source exists and is a directory
    if [[ ! -d "$source_path" ]]; then
        error "Source path does not exist or is not a directory: $source_path"
        return 1
    fi

    # Check for key session files to validate it's a claude session
    local has_session_files=false
    if [[ -f "$source_path/history.jsonl" ]] || [[ -d "$source_path/session-env" ]]; then
        has_session_files=true
    fi

    if ! $has_session_files; then
        warn "Source path does not contain expected claude session files (history.jsonl, session-env/)"
        read -p "Continue anyway? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled"
            return 0
        fi
    fi

    local state_volume="claude-state-${session_name}"

    # Check if volume already exists
    if docker volume inspect "$state_volume" &>/dev/null; then
        if ! $force; then
            error "Session state already exists: $session_name"
            echo "Use --force to overwrite existing session state"
            return 1
        else
            warn "Overwriting existing session state: $session_name"
        fi
    else
        info "Creating new session state volume: $state_volume"
        docker volume create "$state_volume" >/dev/null
    fi

    # Get absolute path for source
    local abs_source_path
    abs_source_path=$(cd "$source_path" && pwd)

    info "Importing session data from: $abs_source_path"
    info "Target: $state_volume"

    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
    local copy_output

    # Create tar archive of source and pipe into container
    if ! copy_output=$(cd "$abs_source_path" && tar -cf - . 2>/dev/null | docker run --rm -i \
        -v "$state_volume:/target" \
        "$git_image" \
        sh -c '
            cd /target
            tar -xf - 2>&1
            echo "---"
            echo "Files imported:"
            ls -lah /target/ 2>&1
            echo "---"
            echo "Disk usage:"
            du -sh /target/ 2>&1
        ' 2>&1); then
        error "Failed to import session:"
        echo "$copy_output" >&2
        return 1
    fi

    echo "$copy_output"
    echo ""
    success "Session imported successfully!"
    echo ""
    echo "To use this session, run:"
    echo "  claude-container -s $session_name --continue"
}

# Sync session with upstream changes for conflict resolution
# Usage: session_sync <session_name> [target_branch]
session_sync() {
    local session_name="$1"
    local target_branch="${2:-main}"
    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        exit 1
    fi

    # Get config content
    local config_content
    config_content=$(read_session_config "$volume")

    if [[ -z "$config_content" ]]; then
        error "No .claude-projects.yml found in session"
        echo "Single-project sessions are not yet supported for push --rebase"
        exit 1
    fi

    info "Syncing session '$session_name' with branch '$target_branch'..."
    echo ""

    # Check for yq
    if ! command -v yq &>/dev/null; then
        error "yq required for multi-project sync"
        exit 1
    fi

    # Parse projects
    local projects
    projects=$(parse_session_projects "$config_content")

    local conflict_count=0
    local success_count=0
    local skip_count=0
    local dirty_count=0
    local -a conflict_projects=()
    local -a dirty_projects=()
    local -a summary_lines=()
    local _util_image="${GIT_UTIL_IMAGE:-alpine/git}"

    # Fast path: get all session HEADs + dirty/rebase status in ONE docker run
    local _sync_scan
    _sync_scan=$(docker run --rm --entrypoint sh \
        -v "$volume:/session:ro" \
        "$_util_image" \
        -c '
            git config --global --add safe.directory "*"
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"
                name="${name%/}"
                head=$(cd "$d" && git rev-parse HEAD 2>/dev/null)
                [ -z "$head" ] && continue
                dirty=$(cd "$d" && git status --porcelain 2>/dev/null | head -1)
                rebase="no"
                [ -d "$d/.git/rebase-merge" ] || [ -d "$d/.git/rebase-apply" ] && rebase="yes"
                echo "$name|$head|${dirty:+dirty}|$rebase"
            done
        ' 2>/dev/null) || true

    # Build lookups
    declare -A _sync_head _sync_dirty _sync_rebase
    while IFS='|' read -r _sn _sh _sd _sr; do
        [[ -z "$_sn" ]] && continue
        _sync_head[$_sn]="$_sh"
        [[ -n "$_sd" ]] && _sync_dirty[$_sn]=1
        [[ "$_sr" == "yes" ]] && _sync_rebase[$_sn]=1
    done <<< "$_sync_scan"

    # Validate projects and find which actually need rebasing
    local -a _need_rebase=()  # "name|path" entries that need docker run

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue

        if [[ ! -d "$proj_path" ]]; then
            warn "  Skipping $proj_name (original not found: $proj_path)"
            skip_count=$((skip_count + 1))
            summary_lines+=("- $proj_name: SKIPPED (original not found)")
            continue
        fi

        if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
            warn "  Skipping $proj_name (branch '$target_branch' not found)"
            skip_count=$((skip_count + 1))
            summary_lines+=("- $proj_name: SKIPPED (branch '$target_branch' not found)")
            continue
        fi

        # Check dirty (from scan)
        if [[ -n "${_sync_dirty[$proj_name]:-}" ]]; then
            warn "  $proj_name has uncommitted changes in session (will need manual commit/stash)"
            dirty_count=$((dirty_count + 1))
            dirty_projects+=("$proj_name")
            summary_lines+=("- $proj_name: DIRTY (uncommitted changes)")
            continue
        fi

        # Fast "already up to date" check: is host's target_branch HEAD an ancestor
        # of the session HEAD? If so, session already contains all target commits.
        local _session_h="${_sync_head[$proj_name]:-}"
        local _target_h
        _target_h=$(git -C "$proj_path" rev-parse "refs/heads/$target_branch" 2>/dev/null || echo "")

        if [[ -n "$_session_h" && -n "$_target_h" ]]; then
            # Check if target branch commit exists in session repo
            # We can't use merge-base across different repos, but if the session
            # was cloned from this host repo, the commit should be reachable.
            # Quick check: if session HEAD == target HEAD, definitely up to date.
            # Otherwise we need to actually run the rebase.
            if [[ "$_session_h" == "$_target_h" ]]; then
                echo -e "  ${BLUE}—${NC} $proj_name (up to date)"
                success_count=$((success_count + 1))
                summary_lines+=("- $proj_name: up to date")
                continue
            fi
            # Check if target is ancestor of session HEAD on the host
            # (works when session branch was extracted to host)
            if git -C "$proj_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
                local _local_session_h
                _local_session_h=$(git -C "$proj_path" rev-parse "refs/heads/$session_name" 2>/dev/null)
                if [[ "$_local_session_h" == "$_session_h" ]] && \
                   git -C "$proj_path" merge-base --is-ancestor "$_target_h" "$_session_h" 2>/dev/null; then
                    echo -e "  ${BLUE}—${NC} $proj_name (up to date)"
                    success_count=$((success_count + 1))
                    summary_lines+=("- $proj_name: up to date")
                    continue
                fi
            fi
        fi

        _need_rebase+=("$proj_name|$proj_path")
    done <<< "$projects"

    # Only run docker containers for repos that actually need rebasing
    if [[ ${#_need_rebase[@]} -gt 0 ]]; then
        info "Rebasing ${#_need_rebase[@]} repo(s)..."
        local host_uid
        host_uid=$(get_host_uid)

        for _entry in "${_need_rebase[@]}"; do
            local proj_name="${_entry%%|*}"
            local proj_path="${_entry#*|}"

            info "  Syncing $proj_name..."

            # Abort stale rebase if needed
            if [[ -n "${_sync_rebase[$proj_name]:-}" ]]; then
                warn "    $proj_name has stale rebase in progress, aborting..."
                docker run --rm --entrypoint sh \
                    --user "$host_uid:$host_uid" \
                    -v "$volume:/session" \
                    "$_util_image" \
                    -c "cd '/session/$proj_name' && git -c safe.directory='*' rebase --abort" 2>/dev/null || true
            fi

            # Rebase: needs full image for potential conflict markers
            local rebase_output
            rebase_output=$(docker run --rm \
                --user "$host_uid:$host_uid" \
                -v "$volume:/session" \
                -v "$proj_path:/upstream:ro" \
                "$git_image" \
                sh -c "
                    cd '/session/$proj_name'
                    git -c safe.directory='*' remote remove upstream 2>/dev/null || true
                    git -c safe.directory='*' remote add upstream /upstream
                    git -c safe.directory='*' fetch upstream '$target_branch' 2>&1
                    git -c safe.directory='*' rebase 'upstream/$target_branch' 2>&1
                    git -c safe.directory='*' remote remove upstream 2>/dev/null || true
                " 2>&1) || true

            if echo "$rebase_output" | grep -qE "CONFLICT|Merge conflict|could not apply"; then
                warn "    $proj_name has conflicts (Claude will resolve)"
                conflict_count=$((conflict_count + 1))
                conflict_projects+=("$proj_name")
                summary_lines+=("- $proj_name: CONFLICTS (needs resolution)")
            elif echo "$rebase_output" | grep -qE "error:|fatal:"; then
                error "    $proj_name rebase failed:"
                echo "$rebase_output" | grep -E "error:|fatal:" | head -3 | sed 's/^/      /'
                skip_count=$((skip_count + 1))
                summary_lines+=("- $proj_name: FAILED")
            elif echo "$rebase_output" | grep -q "is up to date"; then
                success "  $proj_name rebased (already up to date)"
                success_count=$((success_count + 1))
                summary_lines+=("- $proj_name: up to date")
            else
                success "  $proj_name rebased successfully"
                success_count=$((success_count + 1))
                summary_lines+=("- $proj_name: rebased cleanly")
            fi
        done
    fi

    echo ""
    if [[ $conflict_count -gt 0 ]]; then
        info "$conflict_count project(s) have conflicts for Claude to resolve"
    fi
    if [[ $success_count -gt 0 ]]; then
        success "$success_count project(s) rebased cleanly"
    fi
    if [[ $skip_count -gt 0 ]]; then
        warn "$skip_count project(s) skipped"
    fi
    if [[ $dirty_count -gt 0 ]]; then
        warn "$dirty_count project(s) have uncommitted changes (commit or stash in session)"
    fi

    # Store sync state for cleanup message on exit
    local host_uid_sync
    host_uid_sync=$(get_host_uid)
    docker run --rm --entrypoint sh \
        --user "$host_uid_sync:$host_uid_sync" \
        -v "$volume:/session" \
        "$_util_image" \
        -c "echo '$target_branch' > /session/.sync-branch" 2>/dev/null || true

    # Build sync summary as initial prompt for Claude (mirrors merge-into-summary)
    if [[ $conflict_count -gt 0 || $dirty_count -gt 0 ]]; then
        local sync_summary
        sync_summary="Session was rebased onto '$target_branch'. Here is what happened:"
        sync_summary+=$'\n'
        for line in "${summary_lines[@]}"; do
            sync_summary+=$'\n'"  $line"
        done
        if [[ $conflict_count -gt 0 ]]; then
            sync_summary+=$'\n\n'"$conflict_count project(s) have rebase conflicts that need resolution."
            sync_summary+=$'\n\n'"Resolve all rebase conflicts autonomously. The session branch contains the work we want to keep — when conflicts arise, prefer the session (HEAD/ours) side. The '$target_branch' branch changes should be incorporated where they don't conflict, but session work takes priority."
            sync_summary+=$'\n\n'"For each conflicted project:"
            sync_summary+=$'\n'"1. cd /workspace/{project_name}"
            sync_summary+=$'\n'"2. Find all files with <<<<<<< markers: grep -r '<<<<<<< HEAD' ."
            sync_summary+=$'\n'"3. Edit each file to resolve conflicts, keeping our (HEAD) changes"
            sync_summary+=$'\n'"4. git add the resolved files"
            sync_summary+=$'\n'"5. git rebase --continue"
            sync_summary+=$'\n'"6. Repeat steps 2-5 if the rebase surfaces more conflicts"
            sync_summary+=$'\n\n'"Conflicted projects: ${conflict_projects[*]}"
            sync_summary+=$'\n\n'"Do not ask for clarification unless a conflict is genuinely ambiguous (e.g. both sides made substantive changes to the same logic). Just resolve and continue the rebase."
        fi
        if [[ $dirty_count -gt 0 ]]; then
            sync_summary+=$'\n\n'"$dirty_count project(s) had uncommitted changes and were skipped."
            sync_summary+=$'\n'"For each dirty project, commit or stash the changes first, then rebase manually:"
            sync_summary+=$'\n'"1. cd /workspace/{project_name}"
            sync_summary+=$'\n'"2. git stash (or git add -A && git commit -m 'WIP')"
            sync_summary+=$'\n'"3. git rebase upstream/$target_branch"
            sync_summary+=$'\n'"4. git stash pop (if stashed)"
            sync_summary+=$'\n\n'"Dirty projects: ${dirty_projects[*]}"
        fi
        sync_summary+=$'\n\n'"After resolving all conflicts, review the result and run:"
        sync_summary+=$'\n'"  fin \"<brief description of what was resolved>\""
        sync_summary+=$'\n'"This will signal completion and terminate the session."

        # Write sync summary to volume for container startup
        printf '%s' "$sync_summary" | docker run --rm --entrypoint sh -i \
            --user "$host_uid_sync:$host_uid_sync" \
            -v "$volume:/session" \
            "$_util_image" \
            -c 'cat > /session/.sync-summary' 2>/dev/null || true
    fi

    # If everything was clean (no conflicts, no dirty), no need to launch container
    if [[ $conflict_count -eq 0 && $dirty_count -eq 0 ]]; then
        echo ""
        success "Rebase complete — no conflicts, no container needed."
        echo ""
        echo "To pull rebased changes to host:"
        echo "  claude-container pull -s $session_name --force"
        exit 0
    fi

    echo ""
    info "Starting container for conflict resolution..."
    echo ""

    # Return to main script to continue container startup
    # The sync marker will be detected on session exit
}

# Refresh session repos from host (fetch + fast-forward)
# Fetch a specific branch from host repos into session (fast-forward only)
# Usage: session_refresh <session_name> [branch]
# Branch defaults to session_name
session_refresh() {
    local session_name="$1"
    local refresh_branch="${2:-$session_name}"
    local repo_filter="${3:-}"
    local force_reset="${4:-false}"
    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for session refresh"
        return 1
    fi

    local host_uid
    host_uid=$(get_host_uid)

    # Phase 1: Re-discover, remove stale repos, then add new ones
    if [[ ${#DISCOVER_REPOS_DIRS[@]} -gt 0 ]]; then
        info "Re-discovering repos..."

        # Get existing project names and paths from volume config
        local existing_config
        existing_config=$(read_session_config "$volume")

        declare -A _existing_paths _existing_name_by_path
        if [[ -n "$existing_config" ]]; then
            while IFS='|' read -r _name _path; do
                [[ -z "$_path" ]] && continue
                _existing_paths["$_path"]=1
                _existing_name_by_path["$_path"]="$_name"
            done <<< "$(parse_session_projects "$existing_config")"
        fi

        # Run discovery
        local discovered_config
        discovered_config=$(discover_repos_multi "${DISCOVER_REPOS_DIRS[@]}")

        # Parse discovered repos
        local discovered_projects
        discovered_projects=$(parse_config_file "$discovered_config")

        declare -A _discovered_paths
        while IFS='|' read -r proj_name proj_path proj_branch proj_track proj_source; do
            [[ -z "$proj_name" ]] && continue
            _discovered_paths["$proj_path"]=1
        done <<< "$discovered_projects"

        # Step 1: Remove undiscovered repos FIRST (makes room for renames)
        local _remove_names=()
        if ${REMOVE_UNDISCOVERED:-false}; then
            for _path in "${!_existing_paths[@]}"; do
                if [[ -z "${_discovered_paths[$_path]:-}" ]]; then
                    local _rname="${_existing_name_by_path[$_path]}"
                    _remove_names+=("$_rname")
                    warn "  Removing: $_rname (no longer discovered)"
                fi
            done

            if [[ ${#_remove_names[@]} -gt 0 ]]; then
                # Remove directories from volume
                local _rm_script=""
                for _rname in "${_remove_names[@]}"; do
                    _rm_script+="rm -rf '/session/$_rname'; "
                done
                docker run --rm \
                    --user "$host_uid:$host_uid" \
                    -v "$volume:/session" \
                    "$git_image" \
                    sh -c "$_rm_script" 2>/dev/null || true

                # Remove entries from config (yq on host, pipe into container)
                local _updated_config="$existing_config"
                for _rname in "${_remove_names[@]}"; do
                    _updated_config=$(echo "$_updated_config" | yq eval "del(.projects.\"$_rname\")" -)
                done
                echo "$_updated_config" | docker run --rm -i \
                    --user "$host_uid:$host_uid" \
                    -v "$volume:/session" \
                    "$git_image" \
                    sh -c 'cat > /session/.claude-projects.yml' 2>/dev/null

                warn "${#_remove_names[@]} repo(s) removed"
            fi
        else
            # Just warn about undiscovered repos
            for _path in "${!_existing_paths[@]}"; do
                if [[ -z "${_discovered_paths[$_path]:-}" ]]; then
                    info "  Stale: ${_existing_name_by_path[$_path]} (use --remove-undiscovered to clean up)"
                fi
            done
        fi

        # Step 2: Add new repos (after removals, so renames work)
        local new_count=0
        while IFS='|' read -r proj_name proj_path proj_branch proj_track proj_source; do
            [[ -z "$proj_name" ]] && continue
            if [[ -z "${_existing_paths[$proj_path]:-}" ]]; then
                if session_add_repo "$session_name" "$proj_path" "$proj_name" 2>/dev/null; then
                    new_count=$((new_count + 1))
                else
                    warn "  Could not add $proj_name (may already exist in session)"
                fi
            fi
        done <<< "$discovered_projects"

        rm -f "$discovered_config"

        if [[ $new_count -gt 0 ]]; then
            success "$new_count new repo(s) added"
        fi

        if [[ $new_count -eq 0 ]] && [[ ${#_remove_names[@]} -eq 0 ]]; then
            echo "  No changes to session repos"
        fi
        echo ""
    fi

    # Phase 2: Fetch + fast-forward all repos from host
    # Re-read config (may have been updated by phase 1)
    local config_content
    config_content=$(read_session_config "$volume")

    if [[ -z "$config_content" ]]; then
        error "No .claude-projects.yml found in session"
        return 1
    fi

    local projects
    projects=$(parse_session_projects "$config_content")

    # Resolve repo filter before processing
    if [[ -n "$repo_filter" ]]; then
        local _suffix_matches=() _substr_matches=()
        while IFS='|' read -r _rn _rp; do
            [[ -z "$_rn" ]] && continue
            if [[ "$_rn" == "$repo_filter" ]]; then
                _suffix_matches=("$_rn"); break  # exact match
            elif [[ "$_rn" == */"$repo_filter" ]]; then
                _suffix_matches+=("$_rn")
            elif [[ "$_rn" == *"$repo_filter"* ]]; then
                _substr_matches+=("$_rn")
            fi
        done <<< "$projects"

        # Prefer suffix matches; fall back to substring
        local _matches=()
        if [[ ${#_suffix_matches[@]} -gt 0 ]]; then
            _matches=("${_suffix_matches[@]}")
        else
            _matches=("${_substr_matches[@]}")
        fi

        if [[ ${#_matches[@]} -eq 0 ]]; then
            error "No repo matching '$repo_filter' in session"
            return 1
        elif [[ ${#_matches[@]} -gt 1 ]]; then
            error "'$repo_filter' is ambiguous — matches ${#_matches[@]} repos:"
            for _m in "${_matches[@]}"; do
                echo "  $_m"
            done
            echo "Use the full name with --repo to be specific"
            return 1
        fi

        repo_filter="${_matches[0]}"
    fi

    info "Refreshing session '$session_name' from host branch '$refresh_branch'..."
    echo ""

    local success_count=0
    local skip_count=0
    local fail_count=0

    # Build mount args and project list for a single container run
    local _mount_args=("-v" "$volume:/session")
    local _valid_projects=()
    local _refresh_script=""

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue

        # Apply resolved repo filter
        if [[ -n "$repo_filter" && "$proj_name" != "$repo_filter" ]]; then
            continue
        fi

        if [[ ! -d "$proj_path" ]]; then
            warn "  Skipping $proj_name (not found: $proj_path)"
            skip_count=$((skip_count + 1))
            continue
        fi

        # Each host repo gets a unique read-only mount
        local _safe_mount="${proj_name//\//_}"
        _mount_args+=("-v" "$proj_path:/host-${_safe_mount}:ro")
        _valid_projects+=("$proj_name")

        # Build per-project fetch+ff script (runs in parallel inside container)
        _refresh_script+="
        (
            cd '/session/$proj_name' 2>/dev/null || exit 1
            git remote remove _host 2>/dev/null || true
            git remote add _host '/host-${_safe_mount}'
            if ! git fetch _host '$refresh_branch' 2>/dev/null; then
                echo 'SKIP|$proj_name|no branch '\''$refresh_branch'\'' on host'
                exit 0
            fi
            local_head=\$(git rev-parse HEAD)
            remote_head=\$(git rev-parse FETCH_HEAD)
            dirty=\$(git status --porcelain 2>/dev/null)
            if [ -n \"\$dirty\" ]; then
                dirty_count=\$(echo \"\$dirty\" | wc -l | tr -d ' ')
                if [ '$force_reset' != 'true' ]; then
                    echo 'DIRTY|$proj_name|'\$dirty_count' dirty file(s) in session — use --force to override'
                    git remote remove _host 2>/dev/null || true
                    exit 0
                else
                    echo 'WARN|$proj_name|'\$dirty_count' dirty file(s) in session will be discarded'
                fi
            fi
            if [ '$force_reset' = 'true' ]; then
                # Force: unconditionally reset to host HEAD (nuke and replace)
                if [ \"\$local_head\" = \"\$remote_head\" ]; then
                    echo 'SAME|$proj_name|up to date'
                else
                    git checkout . 2>/dev/null
                    git clean -fd 2>/dev/null
                    git reset --hard FETCH_HEAD 2>/dev/null
                    new_head=\$(git rev-parse --short HEAD)
                    if [ \"\$(git rev-parse HEAD)\" = \"\$remote_head\" ]; then
                        echo 'OK|$proj_name|force-reset to host HEAD ('\$new_head')'
                    else
                        echo 'FAIL|$proj_name|force-reset failed (HEAD is '\$new_head', expected '\$(git rev-parse --short FETCH_HEAD)')'
                    fi
                fi
            elif [ \"\$local_head\" = \"\$remote_head\" ]; then
                echo 'SAME|$proj_name|up to date'
            elif git merge-base --is-ancestor \"\$local_head\" FETCH_HEAD; then
                git merge --ff-only FETCH_HEAD 2>/dev/null
                new_head=\$(git rev-parse HEAD)
                if [ \"\$new_head\" = \"\$remote_head\" ]; then
                    count=\$(git rev-list --count \"\$local_head\"..HEAD)
                    echo 'OK|$proj_name|'\$count' new commit(s) ('\$(git rev-parse --short HEAD)')'
                else
                    echo 'FAIL|$proj_name|fast-forward failed (HEAD unchanged, dirty working tree?)'
                fi
            elif git merge-base --is-ancestor FETCH_HEAD \"\$local_head\"; then
                echo 'SAME|$proj_name|up to date'
            else
                echo 'DIVERGE|$proj_name|session and host have diverged'
            fi
            git remote remove _host 2>/dev/null || true
        ) &"
    done <<< "$projects"

    if [[ ${#_valid_projects[@]} -eq 0 ]]; then
        warn "No valid projects to refresh"
        return 0
    fi

    # Run all fetches in a single container, parallel per project
    local refresh_output
    refresh_output=$(docker run --rm \
        --user "$host_uid:$host_uid" \
        "${_mount_args[@]}" \
        "$git_image" \
        sh -c "
            git config --global --add safe.directory '*'
            $_refresh_script
            wait
        " 2>/dev/null)

    # Parse results
    while IFS='|' read -r status proj_name msg; do
        [[ -z "$status" ]] && continue
        case "$status" in
            OK)
                success "  $proj_name ($msg)"
                success_count=$((success_count + 1))
                ;;
            SAME)
                echo "  $proj_name ($msg)"
                ;;
            SKIP)
                warn "  $proj_name ($msg)"
                skip_count=$((skip_count + 1))
                ;;
            DIVERGE)
                warn "  $proj_name ($msg)"
                fail_count=$((fail_count + 1))
                ;;
            FAIL)
                error "  $proj_name ($msg)"
                fail_count=$((fail_count + 1))
                ;;
            DIRTY)
                warn "  $proj_name ($msg)"
                fail_count=$((fail_count + 1))
                ;;
            WARN)
                warn "  $proj_name ($msg)"
                ;;
        esac
    done <<< "$refresh_output"

    # Phase 3: Detect repos created inside the session that aren't in the config
    # (e.g. repos created by Claude during the session)
    local _session_heads
    _session_heads=$(get_session_heads "$volume")

    if [[ -n "$_session_heads" ]]; then
        # Build set of config project names
        declare -A _config_names
        while IFS='|' read -r _cname _cpath; do
            [[ -z "$_cname" ]] && continue
            _config_names["$_cname"]=1
        done <<< "$projects"

        local new_repo_count=0
        while IFS='|' read -r _rname _rhead; do
            [[ -z "$_rname" ]] && continue
            [[ -n "${_config_names[$_rname]:-}" ]] && continue

            # Repo exists in volume but not in config — infer host path and register
            local _host_path
            _host_path=$(resolve_repo_host_path "$_rname" "$projects")

            # Update config via yq
            local _updated_cfg
            _updated_cfg=$(read_session_config "$volume")
            _updated_cfg=$(echo "$_updated_cfg" | yq eval ".projects.\"$_rname\".path = \"$_host_path\"" -)
            echo "$_updated_cfg" | docker run --rm -i \
                --user "$host_uid:$host_uid" \
                -v "$volume:/session" \
                "$git_image" \
                sh -c 'cat > /session/.claude-projects.yml' 2>/dev/null

            success "  $_rname: registered (created in session → $_host_path)"
            new_repo_count=$((new_repo_count + 1))
        done <<< "$_session_heads"

        if [[ $new_repo_count -gt 0 ]]; then
            echo ""
            success "$new_repo_count new repo(s) registered in config"
        fi
    fi

    # Update manifest after refresh
    write_repo_manifest "$volume"

    echo ""
    if [[ $success_count -gt 0 ]]; then
        success "$success_count project(s) updated"
    fi
    if [[ $skip_count -gt 0 ]]; then
        warn "$skip_count project(s) skipped"
    fi
    if [[ $fail_count -gt 0 ]]; then
        warn "$fail_count project(s) diverged — options:"
        echo "  push -s $session_name --merge       Merge host branch into session (launches container if conflicts)"
        echo "  push -s $session_name --rebase       Rebase session onto host branch (launches container if conflicts)"
        echo "  push -s $session_name --ff --force   Force-reset session to host HEAD (discards session changes)"
    fi
}

# Serve a host branch into the container as a named branch (no merge).
# The agent can then: git merge <target_as>
# Usage: session_serve <session_name> <source_branch> <target_as> [repo_filter]
session_serve() {
    local session_name="$1"
    local source_branch="${2:-main}"
    local target_as="${3:-host/$source_branch}"
    local repo_filter="${4:-}"
    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required"
        return 1
    fi

    local config_content
    config_content=$(read_session_config "$volume")
    [[ -z "$config_content" ]] && { error "No config in session"; return 1; }

    local projects
    projects=$(parse_session_projects "$config_content")

    # Resolve repo filter
    if [[ -n "$repo_filter" ]]; then
        local _matches=() _suffix=() _substr=()
        while IFS='|' read -r _rn _rp; do
            [[ -z "$_rn" ]] && continue
            if [[ "$_rn" == "$repo_filter" ]]; then _matches=("$_rn"); break
            elif [[ "$_rn" == */"$repo_filter" ]]; then _suffix+=("$_rn")
            elif [[ "$_rn" == *"$repo_filter"* ]]; then _substr+=("$_rn")
            fi
        done <<< "$projects"
        [[ ${#_matches[@]} -eq 0 ]] && _matches=("${_suffix[@]:-${_substr[@]}}")
        if [[ ${#_matches[@]} -eq 0 ]]; then
            error "No repo matching '$repo_filter'"
            return 1
        elif [[ ${#_matches[@]} -gt 1 ]]; then
            error "'$repo_filter' is ambiguous (${#_matches[@]} matches)"
            return 1
        fi
        repo_filter="${_matches[0]}"
    fi

    info "Serving '$source_branch' as '$target_as' into session '$session_name'..."
    echo ""

    # Build mounts and serve script
    local _mount_args=("-v" "$volume:/session")
    local _serve_script=""
    local -a _valid=()

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        [[ -n "$repo_filter" && "$proj_name" != "$repo_filter" ]] && continue
        [[ ! -d "$proj_path" ]] && { warn "  Skipping $proj_name (not found)"; continue; }

        if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$source_branch" 2>/dev/null; then
            warn "  Skipping $proj_name (no branch '$source_branch')"
            continue
        fi

        local _safe="${proj_name//\//_}"
        _mount_args+=("-v" "$proj_path:/host-${_safe}:ro")
        _valid+=("$proj_name")

        _serve_script+="
        (
            cd '/session/$proj_name' 2>/dev/null || { echo 'SKIP|$proj_name|dir not found'; exit 0; }
            git remote remove _host 2>/dev/null || true
            git remote add _host '/host-${_safe}'
            if ! git fetch _host '$source_branch' 2>/dev/null; then
                echo 'SKIP|$proj_name|fetch failed'
                git remote remove _host 2>/dev/null || true
                exit 0
            fi
            # Create/update the target branch from fetched content
            git branch -f '$target_as' FETCH_HEAD 2>/dev/null
            new_head=\$(git rev-parse --short '$target_as')
            echo 'OK|$proj_name|'\$new_head
            git remote remove _host 2>/dev/null || true
        ) &"
    done <<< "$projects"

    if [[ ${#_valid[@]} -eq 0 ]]; then
        warn "No repos to serve"
        return 0
    fi

    local host_uid
    host_uid=$(get_host_uid)

    local serve_output
    serve_output=$(docker run --rm \
        --user "$host_uid:$host_uid" \
        -e HOME=/tmp \
        "${_mount_args[@]}" \
        "$git_image" \
        sh -c "
            git config --global --add safe.directory '*'
            git config --global user.email 'claude-container@local'
            git config --global user.name 'claude-container'
            $_serve_script
            wait
        " 2>/dev/null)

    local _ok=0 _skip=0
    while IFS='|' read -r _status _name _detail; do
        [[ -z "$_status" ]] && continue
        case "$_status" in
            OK)
                success "  $_name → $target_as ($_detail)"
                _ok=$((_ok + 1))
                ;;
            SKIP)
                warn "  $_name: $_detail"
                _skip=$((_skip + 1))
                ;;
        esac
    done <<< "$serve_output"

    echo ""
    if [[ $_ok -gt 0 ]]; then
        success "$_ok repo(s) served. Agent can: git merge $target_as"
    fi
    [[ $_skip -gt 0 ]] && warn "$_skip repo(s) skipped"
}

# Merge a branch into the session for conflict resolution
# Similar to session_sync but uses git merge instead of rebase
# Usage: session_merge_into <session_name> <target_branch>
session_merge_into() {
    local session_name="$1"
    local target_branch="${2:-main}"
    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        exit 1
    fi

    # Get config content
    local config_content
    config_content=$(read_session_config "$volume")

    if [[ -z "$config_content" ]]; then
        error "No .claude-projects.yml found in session"
        echo "Single-project sessions are not yet supported for push --merge"
        exit 1
    fi

    info "Merging branch '$target_branch' into session '$session_name'..."
    echo ""

    # Check for yq
    if ! command -v yq &>/dev/null; then
        error "yq required for multi-project merge"
        exit 1
    fi

    # Parse projects
    local projects
    projects=$(parse_session_projects "$config_content")

    local conflict_count=0
    local success_count=0
    local skip_count=0
    local dirty_count=0
    local summary_lines=()  # Collect summary for Claude's initial prompt
    local mount_repos=()    # Collect proj_name|proj_path for .merge-into-mounts marker

    # Phase 1: Single fast scan for merge-in-progress + dirty status across all repos
    local _util_image="${GIT_UTIL_IMAGE:-alpine/git}"
    local _merge_scan
    _merge_scan=$(docker run --rm --entrypoint sh \
        -e HOME=/tmp \
        -v "$volume:/session:ro" "$_util_image" \
        -c '
            git config --global --add safe.directory "*"
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"; name="${name%/}"
                merging="no"
                [ -f "$d/.git/MERGE_HEAD" ] && merging="yes"
                dirty=$(cd "$d" && git status --porcelain 2>/dev/null | wc -l | tr -d " ")
                echo "$name|$merging|$dirty"
            done
        ' 2>/dev/null) || true

    # Build lookup maps
    declare -A _merge_status _dirty_file_count
    while IFS='|' read -r _mn _mm _md; do
        [[ -z "$_mn" ]] && continue
        _merge_status[$_mn]="$_mm"
        _dirty_file_count[$_mn]="${_md:-0}"
    done <<< "$_merge_scan"

    # Phase 2: Host-side filtering (NO docker)
    # Classify each repo: skip, dirty, merge-in-progress, or merge candidate
    local merge_candidates=()  # "proj_name|proj_path|host_target_head" for ancestry check + merge
    local host_uid
    host_uid=$(get_host_uid)

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue

        # Skip if original repo doesn't exist
        if [[ ! -d "$proj_path" ]]; then
            warn "  Skipping $proj_name (original not found: $proj_path)"
            summary_lines+=("SKIP: $proj_name (original not found)")
            skip_count=$((skip_count + 1))
            continue
        fi

        # Check if target branch exists in original repo
        if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
            warn "  Skipping $proj_name (branch '$target_branch' not found)"
            summary_lines+=("SKIP: $proj_name (branch '$target_branch' not found)")
            skip_count=$((skip_count + 1))
            continue
        fi

        # Check for merge in progress (from scan)
        if [[ "${_merge_status[$proj_name]:-no}" == "yes" ]]; then
            warn "    $proj_name has merge in progress (use git commit or git merge --abort)"
            summary_lines+=("CONFLICT: $proj_name (merge in progress)")
            EXTRA_DOCKER_ARGS+=("-v" "$proj_path:/host/$proj_name:ro")
            mount_repos+=("$proj_name|$proj_path")
            conflict_count=$((conflict_count + 1))
            continue
        fi

        # Check for uncommitted changes (from scan)
        local _dc="${_dirty_file_count[$proj_name]:-0}"
        if [[ "$_dc" -gt 0 ]]; then
            warn "    $proj_name has $_dc uncommitted file(s) in session — skipping merge, mounting host repo for Claude"
            EXTRA_DOCKER_ARGS+=("-v" "$proj_path:/host/$proj_name:ro")
            mount_repos+=("$proj_name|$proj_path")
            summary_lines+=("DIRTY: $proj_name ($_dc uncommitted changes) — host repo mounted at /host/$proj_name")
            dirty_count=$((dirty_count + 1))
            continue
        fi

        # Merge candidate: get host target head for ancestry check
        local _host_target_head
        _host_target_head=$(git -C "$proj_path" rev-parse "refs/heads/$target_branch" 2>/dev/null || echo "")
        if [[ -n "$_host_target_head" ]]; then
            merge_candidates+=("$proj_name|$proj_path|$_host_target_head")
        else
            warn "  Skipping $proj_name (could not resolve '$target_branch' head)"
            summary_lines+=("SKIP: $proj_name (could not resolve branch head)")
            skip_count=$((skip_count + 1))
        fi
    done <<< "$projects"

    # Phase 3: Batch ancestry check - 1 docker run
    # Pipe "name|host_target_head" lines in, get "name|ancestor" or "name|needs_merge" out
    local needs_merge=()  # "proj_name|proj_path" entries that need actual merge
    declare -A _candidate_path  # proj_name -> proj_path lookup

    if [[ ${#merge_candidates[@]} -gt 0 ]]; then
        # Build input and lookup map
        local ancestry_input=""
        for candidate in "${merge_candidates[@]}"; do
            local _cname _cpath _chead
            IFS='|' read -r _cname _cpath _chead <<< "$candidate"
            _candidate_path[$_cname]="$_cpath"
            ancestry_input+="${_cname}|${_chead}"$'\n'
        done

        local ancestry_output
        ancestry_output=$(printf '%s' "$ancestry_input" | docker run --rm -i --entrypoint sh \
            -e HOME=/tmp \
            -v "$volume:/session:ro" "$_util_image" \
            -c '
                git config --global --add safe.directory "*"
                while IFS="|" read -r name host_head; do
                    [ -z "$name" ] && continue
                    if [ ! -d "/session/$name/.git" ]; then
                        echo "$name|error|no_git_dir"
                        continue
                    fi
                    cd "/session/$name"
                    if git merge-base --is-ancestor "$host_head" HEAD 2>/dev/null; then
                        echo "$name|ancestor"
                    else
                        echo "$name|needs_merge"
                    fi
                done
            ' 2>/dev/null) || true

        # Parse ancestry results
        while IFS='|' read -r _aname _astatus _adetail; do
            [[ -z "$_aname" ]] && continue
            local _apath="${_candidate_path[$_aname]}"
            if [[ "$_astatus" == "ancestor" ]]; then
                summary_lines+=("OK: $_aname (up to date)")
                success_count=$((success_count + 1))
            elif [[ "$_astatus" == "needs_merge" ]]; then
                needs_merge+=("$_aname|$_apath")
            else
                warn "  Skipping $_aname (ancestry check error: $_adetail)"
                summary_lines+=("SKIP: $_aname (ancestry check error)")
                skip_count=$((skip_count + 1))
            fi
        done <<< "$ancestry_output"
    fi

    # Phase 4: Batch merge - 1 docker run
    # Mount session volume + ALL host repos that need merging as -v "$proj_path:/upstream/$proj_name:ro"
    if [[ ${#needs_merge[@]} -gt 0 ]]; then
        info "  Merging ${#needs_merge[@]} repo(s)..."

        # Build docker volume args and input list
        local merge_docker_args=()
        local merge_input=""
        for entry in "${needs_merge[@]}"; do
            local _mname _mpath
            IFS='|' read -r _mname _mpath <<< "$entry"
            merge_docker_args+=("-v" "$_mpath:/upstream/$_mname:ro")
            merge_input+="${_mname}"$'\n'
        done

        local merge_output
        merge_output=$(printf '%s' "$merge_input" | docker run --rm -i \
            --user "$host_uid:$host_uid" \
            -e HOME=/tmp \
            -v "$volume:/session" \
            "${merge_docker_args[@]}" \
            -e "TARGET_BRANCH=$target_branch" \
            "$git_image" \
            sh -c '
                git config --global --add safe.directory "*"
                git config --global user.email "claude-container@local"
                git config --global user.name "claude-container"
                while IFS= read -r name; do
                    [ -z "$name" ] && continue
                    cd "/session/$name" 2>/dev/null || { echo "$name|error|cd failed"; continue; }
                    git remote remove upstream 2>/dev/null || true
                    git remote add upstream "/upstream/$name"
                    fetch_out=$(git fetch upstream "$TARGET_BRANCH" 2>&1) || {
                        echo "$name|error|fetch failed: $(echo "$fetch_out" | tr "\n" " ")"
                        git remote remove upstream 2>/dev/null || true
                        continue
                    }
                    merge_out=$(git merge "upstream/$TARGET_BRANCH" --no-edit 2>&1)
                    merge_rc=$?
                    git remote remove upstream 2>/dev/null || true
                    flat_out=$(echo "$merge_out" | tr "\n" " ")
                    if echo "$merge_out" | grep -qE "CONFLICT|Merge conflict|Automatic merge failed"; then
                        echo "$name|conflict|$flat_out"
                    elif [ $merge_rc -ne 0 ]; then
                        echo "$name|error|$flat_out"
                    elif echo "$merge_out" | grep -q "Already up to date"; then
                        echo "$name|uptodate"
                    else
                        echo "$name|merged"
                    fi
                done
            ' 2>&1) || true

        # Parse merge results
        while IFS='|' read -r _rname _rstatus _rdetail; do
            [[ -z "$_rname" ]] && continue
            local _rpath="${_candidate_path[$_rname]}"
            case "$_rstatus" in
                merged)
                    success "    $_rname merged successfully"
                    summary_lines+=("OK: $_rname (merged)")
                    success_count=$((success_count + 1))
                    ;;
                uptodate)
                    summary_lines+=("OK: $_rname (up to date)")
                    success_count=$((success_count + 1))
                    ;;
                conflict)
                    warn "    $_rname has conflicts (Claude will resolve)"
                    summary_lines+=("CONFLICT: $_rname (merge conflicts)")
                    EXTRA_DOCKER_ARGS+=("-v" "$_rpath:/host/$_rname:ro")
                    mount_repos+=("$_rname|$_rpath")
                    conflict_count=$((conflict_count + 1))
                    ;;
                error)
                    error "    $_rname merge failed: $_rdetail"
                    summary_lines+=("FAIL: $_rname (merge error)")
                    skip_count=$((skip_count + 1))
                    ;;
                *)
                    warn "    $_rname unexpected status: $_rstatus"
                    summary_lines+=("SKIP: $_rname (unexpected status)")
                    skip_count=$((skip_count + 1))
                    ;;
            esac
        done <<< "$merge_output"
    fi

    echo ""
    if [[ $conflict_count -gt 0 ]]; then
        info "$conflict_count project(s) have conflicts for Claude to resolve"
        echo ""
        echo "Conflict resolution tips for Claude:"
        echo "  - Look for <<<<<<< HEAD markers in files"
        echo "  - After resolving, run: git add <files> && git commit"
        echo "  - To abort: git merge --abort"
    fi
    if [[ $success_count -gt 0 ]]; then
        success "$success_count project(s) merged cleanly"
    fi
    if [[ $skip_count -gt 0 ]]; then
        warn "$skip_count project(s) skipped"
    fi
    if [[ $dirty_count -gt 0 ]]; then
        warn "$dirty_count project(s) have uncommitted changes (commit or stash in session)"
    fi

    # Phase 5: Reverse-merge check (session → main on host)
    # Uses the same session_auto_merge dry-run as pull --verify and reconcile --dry-run.
    # One function, one detection path, consistent results everywhere.
    local reverse_conflict_count=0
    local -a reverse_conflict_repos=()
    local -a reverse_conflict_files=()

    info "Checking reverse merge (session → $target_branch)..."

    local _rev_result_dir
    _rev_result_dir=$(mktemp -d)
    session_auto_merge "$session_name" "$target_branch" true "" true "$_rev_result_dir" 2>/dev/null || true

    # Parse results: find conflicts and mount those repos for Claude
    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        [[ ! -d "$proj_path" ]] && continue

        local _rev_status
        _rev_status=$(_pull_result_get "$_rev_result_dir" "$proj_name" "merge_status")
        [[ -z "$_rev_status" ]] && continue

        if [[ "$_rev_status" == "CONFLICT" ]]; then
            local _rev_files
            _rev_files=$(_pull_result_get "$_rev_result_dir" "$proj_name" "conflict_files")
            reverse_conflict_repos+=("$proj_name")
            reverse_conflict_files+=("$_rev_files")
            reverse_conflict_count=$((reverse_conflict_count + 1))
            warn "  $proj_name would conflict merging back into $target_branch${_rev_files:+ ($_rev_files)}"
            # Mount host repo so Claude can examine target branch
            EXTRA_DOCKER_ARGS+=("-v" "$proj_path:/host/$proj_name:ro")
            mount_repos+=("$proj_name|$proj_path")
        fi
    done <<< "$projects"

    rm -rf "$_rev_result_dir"

    if [[ $reverse_conflict_count -gt 0 ]]; then
        warn "$reverse_conflict_count project(s) would conflict merging back into $target_branch"
    else
        success "Reverse merge check passed"
    fi

    # If nothing needs Claude's attention, signal early exit
    if [[ $conflict_count -eq 0 ]] && [[ $dirty_count -eq 0 ]] && [[ $reverse_conflict_count -eq 0 ]]; then
        echo ""
        success "Merge complete — nothing for Claude to resolve."
        # Phase 5 (clean): Write merge-into-branch marker - 1 docker run
        docker run --rm \
            --user "$host_uid:$host_uid" \
            -e HOME=/tmp \
            -v "$volume:/session" \
            "$git_image" \
            sh -c "echo '$target_branch' > /session/.merge-into-branch" 2>/dev/null || true
        return 1  # Signal: no container needed
    fi

    # Build summary for Claude's initial prompt using shared prompt builder
    local _summary_lines_joined=""
    for line in "${summary_lines[@]}"; do
        _summary_lines_joined+="$line"$'\n'
    done
    local _rev_repos_joined="" _rev_files_joined=""
    for _i in "${!reverse_conflict_repos[@]}"; do
        _rev_repos_joined+="${reverse_conflict_repos[$_i]}"$'\n'
        _rev_files_joined+="${reverse_conflict_files[$_i]}"$'\n'
    done

    local merge_summary
    merge_summary=$(\
        _PROMPT_SUMMARY_LINES="$_summary_lines_joined" \
        _PROMPT_CONFLICT_COUNT="$conflict_count" \
        _PROMPT_DIRTY_COUNT="$dirty_count" \
        _PROMPT_REVERSE_REPOS="$_rev_repos_joined" \
        _PROMPT_REVERSE_FILES="$_rev_files_joined" \
        build_reconcile_prompt "$session_name" "$target_branch"
    )

    # Phase 5 (conflicts): Write all markers in 1 docker run
    # Stream branch, mounts, and summary via delimited protocol on stdin
    {
        echo "BRANCH:$target_branch"
        echo "MOUNTS_START"
        if [[ ${#mount_repos[@]} -gt 0 ]]; then
            printf '%s\n' "${mount_repos[@]}"
        fi
        echo "MOUNTS_END"
        echo "SUMMARY_START"
        printf '%s' "$merge_summary"
        echo ""
        echo "SUMMARY_END"
    } | docker run --rm -i \
        --user "$host_uid:$host_uid" \
        -e HOME=/tmp \
        -v "$volume:/session" \
        "$git_image" \
        sh -c '
            branch=""
            mounts=""
            summary=""
            mode="init"
            while IFS= read -r line; do
                case "$mode" in
                    init)
                        case "$line" in
                            BRANCH:*) branch="${line#BRANCH:}" ;;
                            MOUNTS_START) mode="mounts" ;;
                        esac
                        ;;
                    mounts)
                        if [ "$line" = "MOUNTS_END" ]; then
                            mode="pre_summary"
                        else
                            if [ -n "$mounts" ]; then
                                mounts="$mounts
$line"
                            else
                                mounts="$line"
                            fi
                        fi
                        ;;
                    pre_summary)
                        if [ "$line" = "SUMMARY_START" ]; then
                            mode="summary"
                        fi
                        ;;
                    summary)
                        if [ "$line" = "SUMMARY_END" ]; then
                            mode="done"
                        else
                            if [ -n "$summary" ]; then
                                summary="$summary
$line"
                            else
                                summary="$line"
                            fi
                        fi
                        ;;
                esac
            done
            echo "$branch" > /session/.merge-into-branch
            if [ -n "$mounts" ]; then
                echo "$mounts" > /session/.merge-into-mounts
            fi
            if [ -n "$summary" ]; then
                printf "%s" "$summary" > /session/.merge-into-summary
            fi
        ' 2>/dev/null || true

    echo ""
    info "Starting container for review..."
    echo ""

    # Return to main script to continue container startup
    # The merge-into marker will be detected on session exit
}

# Extract session changes as branches in original repos
# Uses git bundle to extract only git data (ignores build artifacts)
# Usage: session_extract <session_name> [--force]
session_extract() {
    local session_name="$1"
    local force=false
    local repo_filter=""
    local result_dir=""

    # Parse flags
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            --repo) repo_filter="$2"; shift 2 ;;
            --result-dir) result_dir="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Usage: session_extract <session_name> [--force]"
        return 1
    fi

    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    if [[ -z "$result_dir" ]]; then
        info "Extracting session '$session_name'..."
    fi
    local _util_image="${GIT_UTIL_IMAGE:-alpine/git}"

    # Detect workspace changes (renames, additions, deletions) since session creation
    local _old_manifest _new_manifest
    _old_manifest=$(read_repo_manifest "$volume")
    if [[ -n "$_old_manifest" ]]; then
        _new_manifest=$(scan_repo_manifest "$volume")
        if diff_repo_manifests "$_old_manifest" "$_new_manifest"; then
            echo ""
        fi
    fi

    # Check if multi-project (has .claude-projects.yml)
    local has_config
    has_config=$(docker run --rm --entrypoint sh -v "$volume:/session:ro" "$_util_image" \
        -c 'test -f /session/.claude-projects.yml && echo yes || echo no' 2>/dev/null)

    if [[ "$has_config" == "yes" ]]; then
        local config_content
        config_content=$(read_session_config "$volume")
        _extract_multi_project_direct "$session_name" "$volume" "$_util_image" "$config_content" "$force" "$_old_manifest" "$repo_filter" "$result_dir"
    else
        _extract_single_project_direct "$session_name" "$volume" "$_util_image" "$force"
    fi
}

# Extract multi-project session directly from volume (no full extraction)
# Uses git bundle to transfer only git data, ignoring build artifacts
_extract_multi_project_direct() {
    local session_name="$1"
    local volume="$2"
    local git_image="$3"
    local config_content="$4"
    local force="$5"
    local old_manifest="${6:-}"
    local repo_filter="${7:-}"
    local result_dir="${8:-}"

    # Resolve partial repo name to full name if filter specified
    if [[ -n "$repo_filter" ]]; then
        local _all_projects
        _all_projects=$(parse_session_projects "$config_content")
        local _rf_suffix_matches=() _rf_substr_matches=()
        while IFS='|' read -r _rn _rp; do
            [[ -z "$_rn" ]] && continue
            if [[ "$_rn" == "$repo_filter" ]]; then
                _rf_suffix_matches=("$_rn"); break  # exact match
            elif [[ "$_rn" == */"$repo_filter" ]]; then
                _rf_suffix_matches+=("$_rn")
            elif [[ "$_rn" == *"$repo_filter"* ]]; then
                _rf_substr_matches+=("$_rn")
            fi
        done <<< "$_all_projects"
        # Prefer suffix matches; fall back to substring
        local _rf_matches=()
        if [[ ${#_rf_suffix_matches[@]} -gt 0 ]]; then
            _rf_matches=("${_rf_suffix_matches[@]}")
        else
            _rf_matches=("${_rf_substr_matches[@]}")
        fi
        if [[ ${#_rf_matches[@]} -eq 0 ]]; then
            error "No repo matching '$repo_filter' in session"
            return 1
        elif [[ ${#_rf_matches[@]} -gt 1 ]]; then
            error "'$repo_filter' is ambiguous — matches ${#_rf_matches[@]} repos:"
            for _m in "${_rf_matches[@]}"; do echo "  $_m"; done
            return 1
        fi
        repo_filter="${_rf_matches[0]}"
    fi

    if [[ -z "$result_dir" ]]; then
        info "Multi-project session detected"
        echo ""
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for multi-project extraction"
        return 1
    fi

    # Parse config from content
    local projects
    projects=$(parse_session_projects "$config_content")

    local success_count=0
    local fail_count=0
    local bundle_dir="$CACHE_DIR/bundles-$$"
    mkdir -p "$bundle_dir"
    trap "rm -rf '$bundle_dir'" EXIT

    # Phase 1: Validate projects and build list for batch bundle creation
    local _valid_projects=()
    local _missing_host_repos=()
    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        # Skip repos not matching filter
        [[ -n "$repo_filter" && "$proj_name" != "$repo_filter" ]] && continue
        if [[ ! -d "$proj_path" ]]; then
            info "  $proj_name: host path missing ($proj_path) — will extract from session"
            _missing_host_repos+=("$proj_name|$proj_path")
            continue
        fi
        _valid_projects+=("$proj_name|$proj_path")
        echo "$proj_name"
    done <<< "$projects" > "$bundle_dir/.projects"

    if [[ ${#_valid_projects[@]} -eq 0 && ${#_missing_host_repos[@]} -eq 0 ]]; then
        if [[ -n "$repo_filter" ]]; then
            warn "No changes for '$repo_filter'"
        else
            warn "No valid projects to extract"
        fi
        return 0
    fi

    # Build config name set (needed by Phase 2 for non-config repo detection + Phase 4)
    declare -A _config_names
    while IFS='|' read -r _pname _ppath; do
        [[ -z "$_pname" ]] && continue
        _config_names[$_pname]=1
    done <<< "$projects"
    for _mhr in "${_missing_host_repos[@]}"; do
        _config_names[${_mhr%%|*}]=1
    done

    # Track non-config repos that need registering in .claude-projects.yml
    local -a _register_repos=()

    # Phase 2: Get session HEADs + .git sizes (single fast docker run), then only bundle changed repos.
    # Docker Desktop volume I/O is slow — bundling all repos takes ~90s for 20+ repos.
    # By comparing HEADs first, we skip repos with no changes (typically most of them).
    local _session_heads
    _session_heads=$(docker run --rm --entrypoint sh \
        -v "$volume:/session:ro" \
        "$git_image" \
        -c '
            git config --global --add safe.directory "*"
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"
                name="${name%/}"
                head=$(cd "$d" && git rev-parse HEAD 2>/dev/null)
                gitsize=$(du -sm "$d/.git" 2>/dev/null | cut -f1)
                [ -n "$head" ] && echo "$name|$head|${gitsize:-0}"
            done
        ' 2>/dev/null) || true

    # Build lookup: session_name → session_head, session_name → .git size (MB)
    declare -A _session_head_map
    declare -A _session_size_map
    while IFS='|' read -r _sname _shead _ssize; do
        [[ -z "$_sname" ]] && continue
        _session_head_map[$_sname]="$_shead"
        _session_size_map[$_sname]="${_ssize:-0}"
    done <<< "$_session_heads"

    # Determine which config repos actually need bundling (HEAD differs from host)
    local -a _need_bundle=()
    for _entry in "${_valid_projects[@]}"; do
        local proj_name="${_entry%%|*}"
        local proj_path="${_entry#*|}"
        local _s_head="${_session_head_map[$proj_name]:-}"
        [[ -z "$_s_head" ]] && continue

        # Compare with host branch HEAD
        local _h_head=""
        if git -C "$proj_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
            _h_head=$(git -C "$proj_path" rev-parse "refs/heads/$session_name" 2>/dev/null)
        else
            _h_head=$(git -C "$proj_path" rev-parse HEAD 2>/dev/null)
        fi

        local _short_s="${_s_head:0:7}"
        local _short_h="${_h_head:0:7}"
        if [[ "$_s_head" != "$_h_head" ]]; then
            _need_bundle+=("$proj_name")
        elif git -C "$proj_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
            if [[ -n "$result_dir" ]]; then
                _pull_result_set "$result_dir" "$proj_name" "repo_name" "$proj_name"
                _pull_result_set "$result_dir" "$proj_name" "extract_status" "unchanged"
                _pull_result_set "$result_dir" "$proj_name" "container_head" "$_s_head"
                _pull_result_set "$result_dir" "$proj_name" "session_head" "$_h_head"
            else
                success "  $proj_name → $session_name @ $_short_h"
            fi
        else
            if [[ -n "$result_dir" ]]; then
                _pull_result_set "$result_dir" "$proj_name" "repo_name" "$proj_name"
                _pull_result_set "$result_dir" "$proj_name" "extract_status" "unchanged"
                _pull_result_set "$result_dir" "$proj_name" "container_head" "$_s_head"
                _pull_result_set "$result_dir" "$proj_name" "session_head" "$_h_head"
            else
                echo -e "  ${BLUE}—${NC} $proj_name $_short_s"
            fi
        fi
    done

    # Also need bundles for Phase 4 repos (not in config).
    # Use manifest to distinguish "known at creation" vs "truly new" repos.
    # Known-at-creation repos that haven't changed on host are skipped (avoids
    # bundling huge unchanged monorepos through slow Docker Desktop I/O).
    declare -A _manifest_names
    if [[ -n "$old_manifest" ]]; then
        while IFS='|' read -r _mhash _mname; do
            [[ -z "$_mname" ]] && continue
            _manifest_names[$_mname]=1
        done <<< "$old_manifest"
    fi

    for _sname in "${!_session_head_map[@]}"; do
        [[ -z "${_config_names[$_sname]:-}" ]] || continue
        # Not in config — check if it was already collected for missing-host
        local _already=false
        for _mhr in "${_missing_host_repos[@]}"; do
            [[ "${_mhr%%|*}" == "$_sname" ]] && _already=true && break
        done
        $_already && continue

        if [[ -n "${_manifest_names[$_sname]:-}" ]]; then
            # Known at creation — check if host repo exists and has diverged
            local _p4_host_path
            _p4_host_path=$(resolve_repo_host_path "$_sname" "$projects")
            if [[ -d "$_p4_host_path" ]] && is_git_repo "$_p4_host_path"; then
                local _p4_h_head=""
                if git -C "$_p4_host_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
                    _p4_h_head=$(git -C "$_p4_host_path" rev-parse "refs/heads/$session_name" 2>/dev/null)
                else
                    _p4_h_head=$(git -C "$_p4_host_path" rev-parse HEAD 2>/dev/null)
                fi
                if [[ "${_session_head_map[$_sname]}" != "$_p4_h_head" ]]; then
                    _need_bundle+=("$_sname")
                else
                    local _short_p4="${_p4_h_head:0:7}"
                    if [[ -n "$result_dir" ]]; then
                        _pull_result_set "$result_dir" "$_sname" "repo_name" "$_sname"
                        _pull_result_set "$result_dir" "$_sname" "extract_status" "unchanged"
                        _pull_result_set "$result_dir" "$_sname" "container_head" "${_session_head_map[$_sname]}"
                        _pull_result_set "$result_dir" "$_sname" "session_head" "$_p4_h_head"
                    elif git -C "$_p4_host_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
                        success "  $_sname → $session_name @ $_short_p4"
                    else
                        echo -e "  ${BLUE}—${NC} $_sname $_short_p4"
                    fi
                    _config_names[$_sname]=1  # prevent Phase 4 from re-collecting
                    _register_repos+=("$_sname|$_p4_host_path")
                fi
            else
                # Host repo gone/missing — needs extraction (direct clone in Phase 4)
                :
            fi
        else
            # Truly new (created inside container) — must bundle
            _need_bundle+=("$_sname")
        fi
    done
    # Missing-host repos also need bundles
    for _mhr in "${_missing_host_repos[@]}"; do
        _need_bundle+=("${_mhr%%|*}")
    done

    # Bundle only changed repos
    if [[ ${#_need_bundle[@]} -gt 0 ]]; then
        # Warn about large repos (>10MB .git) that will be slow to bundle
        for _bname in "${_need_bundle[@]}"; do
            local _bsize="${_session_size_map[$_bname]:-0}"
            if [[ "$_bsize" -gt 10 ]]; then
                warn "  $_bname has ${_bsize}MB .git — bundling may be slow"
            fi
        done
        info "Bundling ${#_need_bundle[@]} changed repo(s)..."
        printf '%s\n' "${_need_bundle[@]}" > "$bundle_dir/.to-bundle"

        docker run --rm --entrypoint sh \
            -v "$volume:/session:ro" \
            -v "$bundle_dir:/bundles" \
            "$git_image" \
            -c '
                git config --global --add safe.directory "*"
                while IFS= read -r name; do
                    [ -z "$name" ] && continue
                    safe=$(echo "$name" | tr "/" "_")
                    cd "/session/$name" 2>/dev/null || continue
                    git bundle create "/tmp/${safe}.bundle" HEAD 2>/dev/null && \
                        mv "/tmp/${safe}.bundle" "/bundles/${safe}.bundle" 2>/dev/null
                done < /bundles/.to-bundle
            ' 2>/dev/null || true
    fi

    # Phase 3: Process each changed project on the host (fetch + branch)
    for _entry in "${_valid_projects[@]}"; do
        local proj_name="${_entry%%|*}"
        local proj_path="${_entry#*|}"
        local bundle_file="$bundle_dir/${proj_name//\//_}.bundle"

        # Skip repos that weren't bundled (no changes)
        if [[ ! -s "$bundle_file" ]]; then
            continue
        fi

        # Fetch from bundle
        if ! git -C "$proj_path" fetch "$bundle_file" HEAD 2>/dev/null; then
            if [[ -n "$result_dir" ]]; then
                _pull_result_set "$result_dir" "$proj_name" "repo_name" "$proj_name"
                _pull_result_set "$result_dir" "$proj_name" "extract_status" "failed"
                _pull_result_set "$result_dir" "$proj_name" "extract_detail" "fetch failed"
                _pull_result_set "$result_dir" "$proj_name" "container_head" "${_session_head_map[$proj_name]:-}"
            else
                error "  $proj_name fetch failed"
            fi
            fail_count=$((fail_count + 1))
            continue
        fi

        local fetched_head
        fetched_head=$(git -C "$proj_path" rev-parse FETCH_HEAD 2>/dev/null)

        # Check if branch already exists
        local _branch_exists=false
        local _branch_checked_out=false
        local _compare_base
        if git -C "$proj_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
            _branch_exists=true
            _compare_base=$(git -C "$proj_path" rev-parse "refs/heads/$session_name" 2>/dev/null)
            local _current_branch
            _current_branch=$(git -C "$proj_path" symbolic-ref --short HEAD 2>/dev/null || echo "")
            [[ "$_current_branch" == "$session_name" ]] && _branch_checked_out=true
        else
            _compare_base=$(git -C "$proj_path" rev-parse HEAD 2>/dev/null)
        fi

        if [[ "$_compare_base" == "$fetched_head" ]]; then
            if [[ -n "$result_dir" ]]; then
                _pull_result_set "$result_dir" "$proj_name" "repo_name" "$proj_name"
                _pull_result_set "$result_dir" "$proj_name" "extract_status" "unchanged"
                _pull_result_set "$result_dir" "$proj_name" "container_head" "$fetched_head"
                _pull_result_set "$result_dir" "$proj_name" "session_head" "$_compare_base"
            else
                echo "  $proj_name (no changes)"
            fi
            continue
        fi

        # If branch exists, allow fast-forward without --force; require --force for diverged
        if $_branch_exists; then
            if git -C "$proj_path" merge-base --is-ancestor "$_compare_base" "$fetched_head" 2>/dev/null; then
                : # fast-forward — safe to update
            elif [[ "$force" != "true" ]]; then
                # Diverged without --force — compute divergence counts
                if [[ -n "$result_dir" ]]; then
                    local _merge_base
                    _merge_base=$(git -C "$proj_path" merge-base "$_compare_base" "$fetched_head" 2>/dev/null || echo "")
                    local _container_ahead=0 _host_ahead=0
                    if [[ -n "$_merge_base" ]]; then
                        _container_ahead=$(git -C "$proj_path" rev-list --count "$_merge_base".."$fetched_head" 2>/dev/null || echo "?")
                        _host_ahead=$(git -C "$proj_path" rev-list --count "$_merge_base".."$_compare_base" 2>/dev/null || echo "?")
                    fi
                    _pull_result_set "$result_dir" "$proj_name" "repo_name" "$proj_name"
                    _pull_result_set "$result_dir" "$proj_name" "extract_status" "diverged"
                    _pull_result_set "$result_dir" "$proj_name" "diverge_container_ahead" "$_container_ahead"
                    _pull_result_set "$result_dir" "$proj_name" "diverge_host_ahead" "$_host_ahead"
                    _pull_result_set "$result_dir" "$proj_name" "container_head" "$fetched_head"
                    _pull_result_set "$result_dir" "$proj_name" "session_head" "$_compare_base"
                else
                    warn "Skipping $proj_name (branch '$session_name' has diverged, use --force)"
                fi
                fail_count=$((fail_count + 1))
                continue
            fi
        fi

        # Create or update branch
        if $_branch_checked_out; then
            git -C "$proj_path" reset --hard FETCH_HEAD 2>/dev/null
        elif $_branch_exists; then
            git -C "$proj_path" branch -f "$session_name" FETCH_HEAD 2>/dev/null
        else
            if ! git -C "$proj_path" branch "$session_name" FETCH_HEAD 2>/dev/null; then
                if [[ -n "$result_dir" ]]; then
                    _pull_result_set "$result_dir" "$proj_name" "repo_name" "$proj_name"
                    _pull_result_set "$result_dir" "$proj_name" "extract_status" "failed"
                    _pull_result_set "$result_dir" "$proj_name" "extract_detail" "branch creation failed"
                    _pull_result_set "$result_dir" "$proj_name" "container_head" "$fetched_head"
                    _pull_result_set "$result_dir" "$proj_name" "session_head" "$_compare_base"
                else
                    error "  $proj_name branch creation failed"
                fi
                fail_count=$((fail_count + 1))
                continue
            fi
        fi

        # Count commits and files
        local commit_count
        commit_count=$(git -C "$proj_path" rev-list --count "$_compare_base".."$session_name" 2>/dev/null || echo "0")
        local files_changed
        files_changed=$(git -C "$proj_path" diff --stat --name-only "$_compare_base".."$session_name" 2>/dev/null | wc -l | tr -d ' ')

        if [[ -n "$result_dir" ]]; then
            _pull_result_set "$result_dir" "$proj_name" "repo_name" "$proj_name"
            _pull_result_set "$result_dir" "$proj_name" "extract_status" "updated"
            _pull_result_set "$result_dir" "$proj_name" "extract_commits" "$commit_count"
            _pull_result_set "$result_dir" "$proj_name" "extract_files" "$files_changed"
            _pull_result_set "$result_dir" "$proj_name" "container_head" "$fetched_head"
            _pull_result_set "$result_dir" "$proj_name" "session_head" "$(git -C "$proj_path" rev-parse "refs/heads/$session_name" 2>/dev/null)"
        else
            if $_branch_checked_out; then
                success "  $proj_name → updated checked-out branch '$session_name' ($commit_count commit(s), $files_changed file(s))"
            elif $_branch_exists; then
                success "  $proj_name → updated branch '$session_name' ($commit_count commit(s), $files_changed file(s))"
            else
                success "  $proj_name → branch '$session_name' ($commit_count commit(s), $files_changed file(s))"
            fi
        fi
        success_count=$((success_count + 1))
    done

    # Phase 4: Extract new repos (created in session) + missing-host repos (in config but host path gone)
    local _new_manifest
    _new_manifest=$(scan_repo_manifest "$volume")

    # Start with missing-host repos from Phase 1
    local _new_repos=()
    for _mhr in "${_missing_host_repos[@]}"; do
        _new_repos+=("${_mhr%%|*}")
    done

    if [[ -n "$_new_manifest" ]]; then
        # Any repo in the volume that's NOT in the config needs extraction
        # (covers both repos created inside the container and repos added
        # via --add-repo/--discover-repos that aren't in config yet)
        while IFS='|' read -r _hash _name; do
            [[ -z "$_name" ]] && continue
            if [[ -z "${_config_names[$_name]:-}" ]]; then
                # Respect --repo filter for non-config repos too
                [[ -n "$repo_filter" && "$_name" != "$repo_filter" && "$_name" != *"$repo_filter"* ]] && continue
                _new_repos+=("$_name")
            fi
        done <<< "$_new_manifest"
    fi

    if [[ ${#_new_repos[@]} -gt 0 ]]; then
        info "Found ${#_new_repos[@]} repo(s) to extract (new or missing host path)"

        for _new_name in "${_new_repos[@]}"; do
            local _safe_name="${_new_name//\//_}"
            local _bundle="$bundle_dir/${_safe_name}.bundle"

            # Determine target: config lookup → org-sibling inference → cwd fallback
            local _target_dir
            _target_dir=$(resolve_repo_host_path "$_new_name" "$projects")

            if [[ -d "$_target_dir" ]] && is_git_repo "$_target_dir"; then
                # Host repo exists — extract as a branch via bundle
                if [[ ! -s "$_bundle" ]]; then
                    if [[ -n "$result_dir" ]]; then
                        _pull_result_set "$result_dir" "$_new_name" "repo_name" "$_new_name"
                        _pull_result_set "$result_dir" "$_new_name" "extract_status" "failed"
                        _pull_result_set "$result_dir" "$_new_name" "extract_detail" "no bundle data"
                    else
                        warn "  $_new_name (no bundle data)"
                    fi
                    fail_count=$((fail_count + 1))
                    continue
                fi
                if ! git -C "$_target_dir" fetch "$_bundle" HEAD 2>/dev/null; then
                    if [[ -n "$result_dir" ]]; then
                        _pull_result_set "$result_dir" "$_new_name" "repo_name" "$_new_name"
                        _pull_result_set "$result_dir" "$_new_name" "extract_status" "failed"
                        _pull_result_set "$result_dir" "$_new_name" "extract_detail" "fetch failed"
                    else
                        error "  $_new_name fetch failed"
                    fi
                    fail_count=$((fail_count + 1))
                    continue
                fi
                local _fetched_head
                _fetched_head=$(git -C "$_target_dir" rev-parse FETCH_HEAD 2>/dev/null)
                local _compare_base
                local _branch_exists=false
                if git -C "$_target_dir" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
                    _compare_base=$(git -C "$_target_dir" rev-parse "refs/heads/$session_name" 2>/dev/null)
                    _branch_exists=true
                else
                    _compare_base=$(git -C "$_target_dir" rev-parse HEAD 2>/dev/null)
                fi
                if [[ "$_compare_base" == "$_fetched_head" ]] && $_branch_exists; then
                    if [[ -n "$result_dir" ]]; then
                        _pull_result_set "$result_dir" "$_new_name" "repo_name" "$_new_name"
                        _pull_result_set "$result_dir" "$_new_name" "extract_status" "unchanged"
                        _pull_result_set "$result_dir" "$_new_name" "container_head" "$_fetched_head"
                        _pull_result_set "$result_dir" "$_new_name" "session_head" "$_compare_base"
                    else
                        echo "  $_new_name (no changes)"
                    fi
                    continue
                fi
                git -C "$_target_dir" branch -f "$session_name" FETCH_HEAD 2>/dev/null
                if [[ -n "$result_dir" ]]; then
                    local _n_commits="?"
                    local _n_files="?"
                    if $_branch_exists; then
                        _n_commits=$(git -C "$_target_dir" rev-list --count "$_compare_base".."$session_name" 2>/dev/null || echo "?")
                        _n_files=$(git -C "$_target_dir" diff --name-only "$_compare_base".."$session_name" 2>/dev/null | wc -l | tr -d ' ')
                    fi
                    _pull_result_set "$result_dir" "$_new_name" "repo_name" "$_new_name"
                    _pull_result_set "$result_dir" "$_new_name" "extract_status" "updated"
                    _pull_result_set "$result_dir" "$_new_name" "extract_commits" "$_n_commits"
                    _pull_result_set "$result_dir" "$_new_name" "extract_files" "$_n_files"
                    _pull_result_set "$result_dir" "$_new_name" "container_head" "$_fetched_head"
                    _pull_result_set "$result_dir" "$_new_name" "session_head" "$(git -C "$_target_dir" rev-parse "$session_name" 2>/dev/null)"
                else
                    if $_branch_exists; then
                        local _n_commits
                        _n_commits=$(git -C "$_target_dir" rev-list --count "$_compare_base".."$session_name" 2>/dev/null || echo "?")
                        success "  $_new_name → branch '$session_name' in $_target_dir ($_n_commits commit(s))"
                    else
                        success "  $_new_name → branch '$session_name' in $_target_dir"
                    fi
                fi
                success_count=$((success_count + 1))
            elif [[ -d "$_target_dir" ]]; then
                if [[ -n "$result_dir" ]]; then
                    _pull_result_set "$result_dir" "$_new_name" "repo_name" "$_new_name"
                    _pull_result_set "$result_dir" "$_new_name" "extract_status" "failed"
                    _pull_result_set "$result_dir" "$_new_name" "extract_detail" "directory exists but not a git repo"
                else
                    warn "  $_new_name → skipped (directory exists but not a git repo: $_target_dir)"
                fi
                fail_count=$((fail_count + 1))
            else
                # Host path missing — direct clone from session volume (avoids slow bundling)
                local _target_parent
                _target_parent=$(dirname "$_target_dir")
                local _target_basename
                _target_basename=$(basename "$_target_dir")
                mkdir -p "$_target_parent"

                local _git_size="${_session_size_map[$_new_name]:-0}"
                if [[ "$_git_size" -gt 10 ]]; then
                    warn "  $_new_name: ${_git_size}MB .git — cloning may be slow"
                fi

                local _git_user_name _git_user_email
                _git_user_name=$(git config user.name 2>/dev/null || echo "Claude")
                _git_user_email=$(git config user.email 2>/dev/null || echo "claude@container")

                if docker run --rm --entrypoint sh \
                    -v "$volume:/session:ro" \
                    -v "$_target_parent:/target" \
                    "$git_image" \
                    -c "
                        git config --global --add safe.directory '*'
                        git clone '/session/$_new_name' '/target/$_target_basename' 2>&1
                        cd '/target/$_target_basename'
                        git remote remove origin 2>/dev/null || true
                        git config user.email '$_git_user_email'
                        git config user.name '$_git_user_name'
                    " 2>/dev/null; then
                    # Set up branches on host
                    git -C "$_target_dir" checkout -b main 2>/dev/null || true
                    git -C "$_target_dir" branch -f "$session_name" HEAD 2>/dev/null || true
                    local _commit_count
                    _commit_count=$(git -C "$_target_dir" rev-list --count HEAD 2>/dev/null || echo "?")
                    if [[ -n "$result_dir" ]]; then
                        local _clone_head
                        _clone_head=$(git -C "$_target_dir" rev-parse HEAD 2>/dev/null || echo "")
                        local _clone_files
                        _clone_files=$(git -C "$_target_dir" ls-files 2>/dev/null | wc -l | tr -d ' ')
                        _pull_result_set "$result_dir" "$_new_name" "repo_name" "$_new_name"
                        _pull_result_set "$result_dir" "$_new_name" "extract_status" "cloned"
                        _pull_result_set "$result_dir" "$_new_name" "extract_commits" "$_commit_count"
                        _pull_result_set "$result_dir" "$_new_name" "extract_files" "$_clone_files"
                        _pull_result_set "$result_dir" "$_new_name" "container_head" "$_clone_head"
                        _pull_result_set "$result_dir" "$_new_name" "session_head" "$_clone_head"
                    else
                        success "  $_new_name → cloned to $_target_dir ($_commit_count commit(s))"
                    fi
                    success_count=$((success_count + 1))
                else
                    if [[ -n "$result_dir" ]]; then
                        _pull_result_set "$result_dir" "$_new_name" "repo_name" "$_new_name"
                        _pull_result_set "$result_dir" "$_new_name" "extract_status" "failed"
                        _pull_result_set "$result_dir" "$_new_name" "extract_detail" "clone failed"
                    else
                        error "  $_new_name → clone failed"
                    fi
                    fail_count=$((fail_count + 1))
                fi
            fi
        done
    fi

    # Register non-config repos in .claude-projects.yml so
    # downstream operations (merge, status, push) see them
    # Includes: Phase 4 extracted repos + repos matched from manifest
    for _new_name in "${_new_repos[@]}"; do
        local _reg_path
        _reg_path=$(resolve_repo_host_path "$_new_name" "$projects")
        [[ ! -d "$_reg_path" ]] && continue
        is_git_repo "$_reg_path" || continue
        [[ -n "${_config_names[$_new_name]:-}" ]] && continue
        _register_repos+=("$_new_name|$_reg_path")
        _config_names[$_new_name]=1
    done

    if [[ ${#_register_repos[@]} -gt 0 ]]; then
        local _updated_cfg
        _updated_cfg=$(read_session_config "$volume")
        local _registered=0
        for _entry in "${_register_repos[@]}"; do
            local _rname="${_entry%%|*}"
            local _rpath="${_entry#*|}"
            _updated_cfg=$(echo "$_updated_cfg" | yq eval ".projects.\"$_rname\".path = \"$_rpath\"" -)
            _registered=$((_registered + 1))
        done
        if [[ $_registered -gt 0 ]]; then
            local _host_uid
            _host_uid=$(get_host_uid)
            echo "$_updated_cfg" | docker run --rm -i --entrypoint sh \
                --user "$_host_uid:$_host_uid" \
                -v "$volume:/session" \
                "$git_image" \
                -c 'cat > /session/.claude-projects.yml' 2>/dev/null
            info "Registered $_registered new repo(s) in session config"
        fi
    fi

    # Update manifest so future pulls know about all repos (including ones
    # added via --add-repo, --discover-repos, or created inside the container)
    write_repo_manifest "$volume"

    # Suppress summary when using unified reporting (result_dir mode)
    if [[ -z "$result_dir" ]]; then
        echo ""
        if [[ $success_count -gt 0 ]]; then
            success "Extracted $success_count repo(s) from session '$session_name'"
            echo ""
            echo "To see changes:  git log main..$session_name"
            echo "Checkout:        git checkout $session_name"
            echo "Merge:           git merge $session_name"
        fi
        if [[ $fail_count -gt 0 ]]; then
            warn "$fail_count repo(s) skipped or failed"
        fi
    fi
}

# Extract single-project session directly from volume (legacy fallback)
_extract_single_project_direct() {
    local session_name="$1"
    local volume="$2"
    local git_image="$3"
    local force="$4"

    # For single project without config, user must run from original repo
    local target_repo
    target_repo=$(pwd)

    if ! is_git_repo "$target_repo"; then
        error "Run this from your git repository directory"
        return 1
    fi

    # Create git bundle from volume
    local bundle_file="$CACHE_DIR/extract-$$.bundle"
    mkdir -p "$CACHE_DIR"
    trap "rm -f '$bundle_file'" EXIT

    # Write to temp file then cat to stdout (git can't write directly to /dev/stdout due to lock files)
    if ! docker run --rm --entrypoint sh -v "$volume:/session:ro" "$git_image" \
        -c "git config --global --add safe.directory '*' && cd /session && git bundle create /tmp/out.bundle HEAD && cat /tmp/out.bundle" > "$bundle_file" 2>/dev/null; then
        error "Failed to create git bundle from session"
        return 1
    fi

    # Fetch from bundle
    git -C "$target_repo" fetch "$bundle_file" HEAD 2>/dev/null

    local fetched_head
    fetched_head=$(git -C "$target_repo" rev-parse FETCH_HEAD 2>/dev/null)

    # Check if branch already exists
    local _branch_exists=false
    local _branch_checked_out=false
    local _compare_base
    if git -C "$target_repo" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
        _branch_exists=true
        _compare_base=$(git -C "$target_repo" rev-parse "refs/heads/$session_name" 2>/dev/null)
        local _current_branch
        _current_branch=$(git -C "$target_repo" symbolic-ref --short HEAD 2>/dev/null || echo "")
        [[ "$_current_branch" == "$session_name" ]] && _branch_checked_out=true
    else
        _compare_base=$(git -C "$target_repo" rev-parse HEAD 2>/dev/null)
    fi

    if [[ "$_compare_base" == "$fetched_head" ]]; then
        info "No changes in session (matches current HEAD)"
        return 0
    fi

    # If branch exists, allow fast-forward without --force; require --force for diverged
    if $_branch_exists; then
        if git -C "$target_repo" merge-base --is-ancestor "$_compare_base" "$fetched_head" 2>/dev/null; then
            : # fast-forward — safe to update
        elif [[ "$force" != "true" ]]; then
            error "Branch '$session_name' has diverged from session. Use --force to overwrite."
            return 1
        fi
    fi

    # Create or update branch
    if $_branch_checked_out; then
        git -C "$target_repo" reset --hard FETCH_HEAD 2>/dev/null
    elif $_branch_exists; then
        git -C "$target_repo" branch -f "$session_name" FETCH_HEAD 2>/dev/null
    else
        git -C "$target_repo" branch "$session_name" FETCH_HEAD 2>/dev/null
    fi

    local commit_count
    commit_count=$(git -C "$target_repo" rev-list --count "$_compare_base".."$session_name" 2>/dev/null || echo "0")
    local files_changed
    files_changed=$(git -C "$target_repo" diff --stat --name-only "$_compare_base".."$session_name" 2>/dev/null | wc -l | tr -d ' ')

    if $_branch_checked_out; then
        success "Updated checked-out branch: $session_name ($commit_count commit(s), $files_changed file(s) changed)"
    elif $_branch_exists; then
        success "Updated branch: $session_name ($commit_count commit(s), $files_changed file(s) changed)"
    else
        success "Created branch: $session_name ($commit_count commit(s), $files_changed file(s) changed)"
    fi
    echo ""
    echo "Commits:"
    git -C "$target_repo" log --oneline "$current_head".."$session_name" 2>/dev/null | head -10 || true
    echo ""
    echo "Files changed:"
    git -C "$target_repo" diff --stat "$current_head".."$session_name" 2>/dev/null | tail -20 || true

    echo ""
    echo "To see changes:  git log HEAD..$session_name"
    echo "Checkout:        git checkout $session_name"
    echo "Merge:           git merge $session_name"
}

# Legacy: Extract single-project session into original repo as branch (temp dir based)
_extract_single_project() {
    local session_name="$1"
    local temp_dir="$2"
    local force="$3"

    # For single project, we need to know where the original repo is
    # The user should run this from the original repo directory
    local target_repo
    target_repo=$(pwd)

    if ! is_git_repo "$target_repo"; then
        error "Run this from your git repository directory"
        return 1
    fi

    # Check if branch already exists
    if git -C "$target_repo" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
        if [[ "$force" != "true" ]]; then
            error "Branch '$session_name' already exists. Use --force to overwrite."
            return 1
        fi
        warn "Overwriting existing branch: $session_name"
        git -C "$target_repo" branch -D "$session_name" 2>/dev/null || true
    fi

    # Fetch from temp to check for changes
    git -C "$target_repo" fetch "$temp_dir" HEAD 2>/dev/null

    # Compare FETCH_HEAD to current HEAD
    local current_head
    current_head=$(git -C "$target_repo" rev-parse HEAD 2>/dev/null)
    local fetched_head
    fetched_head=$(git -C "$target_repo" rev-parse FETCH_HEAD 2>/dev/null)

    if [[ "$current_head" == "$fetched_head" ]]; then
        info "No changes in session (matches current HEAD)"
        return 0
    fi

    # Create branch since there are changes
    git -C "$target_repo" branch "$session_name" FETCH_HEAD 2>/dev/null

    local commit_count
    commit_count=$(git -C "$target_repo" rev-list --count "$current_head".."$session_name" 2>/dev/null || echo "0")
    local files_changed
    files_changed=$(git -C "$target_repo" diff --stat --name-only "$current_head".."$session_name" 2>/dev/null | wc -l | tr -d ' ')

    success "Created branch: $session_name ($commit_count commit(s), $files_changed file(s) changed)"
    echo ""
    echo "Commits:"
    git -C "$target_repo" log --oneline "$current_head".."$session_name" 2>/dev/null | head -10 || true
    echo ""
    echo "Files changed:"
    git -C "$target_repo" diff --stat "$current_head".."$session_name" 2>/dev/null | tail -20 || true

    echo ""
    echo "To see changes:  git log HEAD..$session_name"
    echo "Checkout:        git checkout $session_name"
    echo "Merge:           git merge $session_name"
}

# Extract multi-project session into original repos as branches
_extract_multi_project() {
    local session_name="$1"
    local temp_dir="$2"
    local force="$3"

    info "Multi-project session detected"
    echo ""

    # Parse the config to get project paths
    local config_file="$temp_dir/.claude-projects.yml"

    if ! command -v yq &>/dev/null; then
        error "yq required for multi-project extraction"
        return 1
    fi

    # Get project names and their original paths
    local projects
    projects=$(yq eval '.projects | to_entries | .[] | .key + "|" + .value.path' "$config_file" 2>/dev/null)

    local success_count=0
    local fail_count=0

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue

        local session_proj_dir="$temp_dir/$proj_name"

        # Skip if project dir doesn't exist in session
        if [[ ! -d "$session_proj_dir" ]]; then
            warn "Skipping $proj_name (not in session)"
            continue
        fi

        # Check if original repo exists
        if [[ ! -d "$proj_path" ]]; then
            warn "Skipping $proj_name (original repo not found: $proj_path)"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Check if branch already exists
        if git -C "$proj_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
            if [[ "$force" != "true" ]]; then
                warn "Skipping $proj_name (branch '$session_name' exists, use --force)"
                fail_count=$((fail_count + 1))
                continue
            fi
            git -C "$proj_path" branch -D "$session_name" 2>/dev/null || true
        fi

        # Fetch to check for changes
        if ! git -C "$proj_path" fetch "$session_proj_dir" HEAD 2>/dev/null; then
            error "  $proj_name fetch failed"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Compare FETCH_HEAD to current HEAD
        local current_head
        current_head=$(git -C "$proj_path" rev-parse HEAD 2>/dev/null)
        local fetched_head
        fetched_head=$(git -C "$proj_path" rev-parse FETCH_HEAD 2>/dev/null)

        if [[ "$current_head" == "$fetched_head" ]]; then
            echo "  $proj_name (no changes)"
            continue
        fi

        # Create branch since there are changes
        if ! git -C "$proj_path" branch "$session_name" FETCH_HEAD 2>/dev/null; then
            error "  $proj_name branch creation failed"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Count commits and changed files
        local commit_count
        commit_count=$(git -C "$proj_path" rev-list --count "$current_head".."$session_name" 2>/dev/null || echo "0")
        local files_changed
        files_changed=$(git -C "$proj_path" diff --stat --name-only "$current_head".."$session_name" 2>/dev/null | wc -l | tr -d ' ')

        success "  $proj_name → branch '$session_name' ($commit_count commit(s), $files_changed file(s))"
        success_count=$((success_count + 1))
    done <<< "$projects"

    echo ""
    if [[ $success_count -gt 0 ]]; then
        success "Created branch '$session_name' in $success_count repo(s)"
        echo ""
        echo "To see changes:  git log main..$session_name"
        echo "Checkout:        git checkout $session_name"
        echo "Merge:           git merge $session_name"
    fi
    if [[ $fail_count -gt 0 ]]; then
        warn "$fail_count repo(s) skipped or failed"
    fi
}

# Clone all volumes and metadata from an existing session into a new one
# Usage: session_clone <source_session> <target_session>
session_clone() {
    local source="$1"
    local target="$2"

    if [[ -z "$source" ]] || [[ -z "$target" ]]; then
        error "Usage: session_clone <source_session> <target_session>"
        return 1
    fi

    # Verify source session exists
    if ! docker volume inspect "claude-session-${source}" &>/dev/null; then
        error "Source session not found: $source"
        return 1
    fi

    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Determine which source volumes exist (session is required, others are optional)
    local volume_types=("session" "state" "cargo" "npm" "pip")
    local existing_types=()
    local mount_args=()

    for vtype in "${volume_types[@]}"; do
        local src_vol="claude-${vtype}-${source}"
        local dst_vol="claude-${vtype}-${target}"

        if docker volume inspect "$src_vol" &>/dev/null; then
            existing_types+=("$vtype")
            # Create destination volume
            docker volume create "$dst_vol" >/dev/null 2>&1 || true
            mount_args+=("-v" "${src_vol}:/src-${vtype}:ro" "-v" "${dst_vol}:/dst-${vtype}")
        fi
    done

    info "Cloning session '$source' → '$target' (${#existing_types[@]} volumes)..."

    # Build the parallel copy script
    local copy_script=""
    for vtype in "${existing_types[@]}"; do
        copy_script+="cp -a /src-${vtype}/. /dst-${vtype}/ & "
    done
    copy_script+="wait"

    # Single container run: mount all volumes, copy in parallel
    if ! docker run --rm \
        "${mount_args[@]}" \
        "$git_image" \
        sh -c "$copy_script" 2>&1; then
        error "Volume clone failed"
        return 1
    fi

    # Copy host metadata files (.env, .yml)
    local sessions_dir="${SESSIONS_CONFIG_DIR:-$HOME/.config/claude-container/sessions}"
    if [[ -f "$sessions_dir/${source}.env" ]]; then
        cp "$sessions_dir/${source}.env" "$sessions_dir/${target}.env"
    fi
    if [[ -f "$sessions_dir/${source}.yml" ]]; then
        cp "$sessions_dir/${source}.yml" "$sessions_dir/${target}.yml"
    fi

    # Update .repo-manifest in the cloned session to reflect the new session name
    # (the manifest itself is just root_commit|dirname, no session name embedded, so it's fine as-is)

    success "Session cloned: $source → $target"
}

# Merge session branches into a target branch on the host
# Extracts should have already created the branches; this merges them.
# If the target branch doesn't exist, creates it from the session branch.
# Only performs clean merges — skips repos where conflicts would occur.
# For conflicts, directs user to resolve in-container via push --merge.
# All independent repos are merged in parallel.
# Usage: session_auto_merge <session_name> [target_branch]
session_auto_merge() {
    local session_name="$1"
    local target_branch="${2:-main}"
    local dry_run="${3:-false}"
    local repo_filter="${4:-}"
    local squash="${5:-true}"
    local _unified_result_dir="${6:-}"
    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Read config from volume
    local config_content
    config_content=$(read_session_config "$volume")

    if [[ -z "$config_content" ]]; then
        error "Cannot auto-merge: no .claude-projects.yml in session"
        return 1
    fi

    if ! command -v yq &>/dev/null; then
        error "yq required for auto-merge"
        return 1
    fi

    if [[ -z "$_unified_result_dir" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            info "Dry run: checking merge of '$session_name' into '$target_branch'..."
        else
            info "Merging session '$session_name' into '$target_branch'..."
        fi
        echo ""
    fi

    local projects
    projects=$(parse_session_projects "$config_content")

    # Create temp dir for parallel result collection
    local _result_dir
    _result_dir=$(mktemp -d)
    trap "rm -rf '$_result_dir'" RETURN

    # Resolve partial repo filter against project list
    if [[ -n "$repo_filter" ]]; then
        local _rf_suffix_matches=() _rf_substr_matches=()
        while IFS='|' read -r _rn _rp; do
            [[ -z "$_rn" ]] && continue
            if [[ "$_rn" == "$repo_filter" ]]; then
                _rf_suffix_matches=("$_rn"); break  # exact match
            elif [[ "$_rn" == */"$repo_filter" ]]; then
                _rf_suffix_matches+=("$_rn")
            elif [[ "$_rn" == *"$repo_filter"* ]]; then
                _rf_substr_matches+=("$_rn")
            fi
        done <<< "$projects"
        # Prefer suffix matches; fall back to substring
        local _rf_matches=()
        if [[ ${#_rf_suffix_matches[@]} -gt 0 ]]; then
            _rf_matches=("${_rf_suffix_matches[@]}")
        else
            _rf_matches=("${_rf_substr_matches[@]}")
        fi
        if [[ ${#_rf_matches[@]} -eq 0 ]]; then
            error "No repo matching '$repo_filter' in session"
            return 1
        elif [[ ${#_rf_matches[@]} -gt 1 ]]; then
            error "'$repo_filter' is ambiguous — matches ${#_rf_matches[@]} repos:"
            for _m in "${_rf_matches[@]}"; do echo "  $_m"; done
            return 1
        fi
        repo_filter="${_rf_matches[0]}"
    fi

    # Launch each merge in parallel
    local _pids=()
    local _proj_names=()
    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        [[ -n "$repo_filter" && "$proj_name" != "$repo_filter" ]] && continue

        _proj_names+=("$proj_name")

        # Run each merge in a subshell
        (
            local _result_file="$_result_dir/${proj_name//\//_}"
            local _detect_file
            _detect_file=$(mktemp)

            # Helper: write to both internal result file and unified result dir
            _write_merge_result() {
                local status="$1" name="$2" msg="$3"
                echo "${status}|${name}|${msg}" > "$_result_file"
                if [[ -n "$_unified_result_dir" ]]; then
                    _pull_result_set "$_unified_result_dir" "$name" "merge_status" "$status"
                    _pull_result_set "$_unified_result_dir" "$name" "merge_detail" "$msg"
                    local _t_head
                    _t_head=$(git -C "$proj_path" rev-parse "refs/heads/$target_branch" 2>/dev/null || echo "")
                    [[ -n "$_t_head" ]] && _pull_result_set "$_unified_result_dir" "$name" "target_head" "$_t_head"
                fi
            }

            # If unified reporting: check extract status, skip stale/failed repos
            if [[ -n "$_unified_result_dir" ]]; then
                local _ext_status
                _ext_status=$(_pull_result_get "$_unified_result_dir" "$proj_name" "extract_status")
                case "$_ext_status" in
                    diverged)
                        _write_merge_result "SKIP" "$proj_name" "skipped (stale branch, extraction diverged)"
                        rm -f "$_detect_file"
                        exit 0
                        ;;
                    failed)
                        local _ext_detail
                        _ext_detail=$(_pull_result_get "$_unified_result_dir" "$proj_name" "extract_detail")
                        _write_merge_result "SKIP" "$proj_name" "skipped (extraction failed: $_ext_detail)"
                        rm -f "$_detect_file"
                        exit 0
                        ;;
                esac
            fi

            # --- Detection: uses shared detect_repo_merge_status ---
            detect_repo_merge_status "$proj_path" "$session_name" "$target_branch" "$squash" "$_detect_file"

            local _d_status _d_detail _d_files _d_target _d_target_ahead
            _d_status=$(detect_result_get "$_detect_file" "merge_status")
            _d_detail=$(detect_result_get "$_detect_file" "merge_detail")
            _d_files=$(detect_result_get "$_detect_file" "conflict_files")
            _d_target=$(detect_result_get "$_detect_file" "target_head")
            _d_target_ahead=$(detect_result_get "$_detect_file" "target_ahead")
            rm -f "$_detect_file"

            # Write conflict files to unified result dir
            if [[ -n "$_unified_result_dir" && -n "$_d_files" ]]; then
                _pull_result_set "$_unified_result_dir" "$proj_name" "conflict_files" "$_d_files"
            fi
            # Propagate target-ahead count for reporting
            if [[ -n "$_unified_result_dir" && -n "$_d_target_ahead" && "$_d_target_ahead" != "0" ]]; then
                _pull_result_set "$_unified_result_dir" "$proj_name" "target_ahead" "$_d_target_ahead"
            fi

            # If dry-run or detection says conflict/skip, just report
            if [[ "$dry_run" == "true" ]] || [[ "$_d_status" == "CONFLICT" ]] || [[ "$_d_status" == "SKIP" ]]; then
                _write_merge_result "$_d_status" "$proj_name" "$_d_detail"
                exit 0
            fi

            # Detection says OK — check for special cases
            case "$_d_detail" in
                "already up to date"|"up to date"*)
                    _write_merge_result "OK" "$proj_name" "$_d_detail"
                    exit 0
                    ;;
                "would create"*)
                    git -C "$proj_path" branch "$target_branch" "$session_name" 2>/dev/null
                    _write_merge_result "OK" "$proj_name" "created '$target_branch' from $session_name"
                    exit 0
                    ;;
            esac

            # --- Execution: actually perform the merge ---
            local current_branch
            current_branch=$(git -C "$proj_path" symbolic-ref --short HEAD 2>/dev/null || echo "")
            local _need_checkout_back=false
            if [[ "$current_branch" != "$target_branch" ]]; then
                if ! git -C "$proj_path" checkout "$target_branch" 2>/dev/null; then
                    _write_merge_result "SKIP" "$proj_name" "could not checkout $target_branch"
                    exit 0
                fi
                _need_checkout_back=true
            fi

            # Check if squash-base cherry-pick path
            local _squash_ref="refs/claude-container/squash-base/${session_name}"
            local _squash_base
            _squash_base=$(git -C "$proj_path" rev-parse --verify "$_squash_ref" 2>/dev/null || echo "")
            if [[ -n "$_squash_base" ]] && \
               ! git -C "$proj_path" merge-base --is-ancestor "$_squash_base" "$session_name" 2>/dev/null; then
                git -C "$proj_path" update-ref -d "$_squash_ref" 2>/dev/null || true
                _squash_base=""
            fi

            if [[ "$squash" == "true" && -n "$_squash_base" ]] && \
               git -C "$proj_path" merge-base --is-ancestor "$target_branch" "$session_name" 2>/dev/null; then
                # Target is ancestor of session (e.g. after reconcile merged target into session).
                # Use merge --squash instead of cherry-pick to avoid decomposing merge commits.
                local _ahead
                _ahead=$(git -C "$proj_path" rev-list --count "$target_branch".."$session_name" 2>/dev/null || echo "?")
                git -C "$proj_path" merge --squash "$session_name" >/dev/null 2>&1
                local _squash_msg
                _squash_msg=$(git -C "$proj_path" log --format="%s" "${target_branch}..${session_name}" --no-merges 2>/dev/null | head -20)
                local _commit_out
                _commit_out=$(git -C "$proj_path" commit -m "$(printf '%s\n\n%s' \
                    "$session_name → $target_branch ($_ahead commits)" \
                    "$_squash_msg")" 2>&1) || true
                git -C "$proj_path" update-ref "$_squash_ref" "$(git -C "$proj_path" rev-parse "$session_name")" 2>/dev/null || true
                _write_merge_result "OK" "$proj_name" "squash-merged into $target_branch ($_ahead commits)"
            elif [[ "$squash" == "true" && -n "$_squash_base" ]]; then
                # Incremental squash: cherry-pick new commits
                local _new_count
                _new_count=$(git -C "$proj_path" rev-list --count "${_squash_base}..${session_name}" 2>/dev/null || echo "0")
                git -C "$proj_path" cherry-pick --no-commit "${_squash_base}..${session_name}" >/dev/null 2>&1
                local _squash_msg
                _squash_msg=$(git -C "$proj_path" log --format="%s" "${_squash_base}..${session_name}" 2>/dev/null | head -20)
                local _commit_out
                if [[ "$_new_count" == "1" ]]; then
                    _commit_out=$(git -C "$proj_path" commit -m "$_squash_msg" 2>&1) || true
                else
                    _commit_out=$(git -C "$proj_path" commit -m "$(printf '%s\n\n%s' \
                        "$session_name → $target_branch ($_new_count commits)" \
                        "$_squash_msg")" 2>&1) || true
                fi
                git -C "$proj_path" update-ref "$_squash_ref" "$(git -C "$proj_path" rev-parse "$session_name")" 2>/dev/null || true
                _write_merge_result "OK" "$proj_name" "squash-merged into $target_branch ($_new_count new)"
            elif [[ "$squash" == "true" ]]; then
                # First-time squash
                local _merge_out _merge_rc=0
                _merge_out=$(git -C "$proj_path" merge --squash "$session_name" 2>&1) || _merge_rc=$?
                if [[ $_merge_rc -ne 0 ]]; then
                    git -C "$proj_path" reset --hard HEAD 2>/dev/null || true
                    _write_merge_result "SKIP" "$proj_name" "squash-merge failed unexpectedly"
                elif git -C "$proj_path" diff --cached --quiet 2>/dev/null; then
                    _write_merge_result "OK" "$proj_name" "already up to date"
                else
                    local _commit_out _commit_rc=0
                    _commit_out=$(git -C "$proj_path" commit --no-edit 2>&1) || _commit_rc=$?
                    if [[ $_commit_rc -ne 0 ]]; then
                        git -C "$proj_path" reset --hard HEAD 2>/dev/null || true
                        _write_merge_result "SKIP" "$proj_name" "commit failed after squash"
                    else
                        local _squash_ref="refs/claude-container/squash-base/${session_name}"
                        git -C "$proj_path" update-ref "$_squash_ref" "$(git -C "$proj_path" rev-parse "$session_name")" 2>/dev/null || true
                        _write_merge_result "OK" "$proj_name" "squash-merged into $target_branch"
                        { [[ -n "$_merge_out" ]] && echo "$_merge_out"; [[ -n "$_commit_out" ]] && echo "$_commit_out"; } >> "$_result_file.detail"
                    fi
                fi
            else
                # Regular merge
                local _merge_out
                _merge_out=$(git -C "$proj_path" merge "$session_name" --no-edit 2>&1) || true
                _write_merge_result "OK" "$proj_name" "merged into $target_branch"
                [[ -n "$_merge_out" ]] && echo "$_merge_out" >> "$_result_file.detail"
            fi

            if $_need_checkout_back; then
                git -C "$proj_path" checkout "$current_branch" 2>/dev/null || true
            fi
        ) &
        _pids+=($!)
    done <<< "$projects"

    # Wait for all merges to complete
    for _pid in "${_pids[@]}"; do
        wait "$_pid" 2>/dev/null || true
    done

    # Collect and display results (suppress when unified reporting is active)
    local merge_ok=0
    local merge_skip=0
    local merge_conflict=0

    for proj_name in "${_proj_names[@]}"; do
        local _result_file="$_result_dir/${proj_name//\//_}"
        [[ ! -f "$_result_file" ]] && continue

        local _line
        _line=$(cat "$_result_file")
        local _status="${_line%%|*}"
        local _rest="${_line#*|}"
        local _name="${_rest%%|*}"
        _rest="${_rest#*|}"
        local _msg="${_rest%%|*}"

        case "$_status" in
            OK)
                if [[ -z "$_unified_result_dir" ]]; then
                    success "  $_name: $_msg"
                    if [[ -f "$_result_file.detail" ]]; then
                        while IFS= read -r _detail_line; do
                            echo "    $_detail_line"
                        done < "$_result_file.detail"
                    fi
                fi
                merge_ok=$((merge_ok + 1))
                ;;
            SKIP)
                if [[ -z "$_unified_result_dir" ]]; then
                    warn "  $_name: $_msg (skipped)"
                fi
                merge_skip=$((merge_skip + 1))
                ;;
            CONFLICT)
                if [[ -z "$_unified_result_dir" ]]; then
                    warn "  $_name: $_msg (skipped)"
                fi
                merge_conflict=$((merge_conflict + 1))
                ;;
        esac
    done

    if [[ -z "$_unified_result_dir" ]]; then
        echo ""
        if [[ $merge_ok -gt 0 ]]; then
            success "$merge_ok project(s) merged into $target_branch"
        fi
        if [[ $merge_skip -gt 0 ]]; then
            warn "$merge_skip project(s) skipped"
        fi
        if [[ $merge_conflict -gt 0 ]]; then
            warn "$merge_conflict project(s) would conflict — skipped"
            echo ""
            echo "  Resolve conflicts in-container first, then pull again:"
            echo "    claude-container pull -s $session_name $target_branch --reconcile"
            return 2
        fi
        if [[ $merge_ok -eq 0 && $merge_skip -gt 0 && $merge_conflict -eq 0 ]]; then
            echo "  Hint: extraction was skipped — try 'pull --force' or 'pull --reconcile'"
        fi
    else
        # Return exit code for conflict reporting
        if [[ $merge_conflict -gt 0 ]]; then
            return 2
        fi
    fi
}

# Repair corrupted session config (fixes paths with ||true| suffix)
# Usage: session_repair <session_name>
session_repair() {
    local session_name="$1"
    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    if [[ -z "$session_name" ]]; then
        error "Usage: session_repair <session_name>"
        return 1
    fi

    # Verify session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    info "Checking session config..."

    # Check if config has corrupted paths
    local config_content
    config_content=$(read_session_config "$volume")

    if [[ -z "$config_content" ]]; then
        info "No .claude-projects.yml found (single-project session)"
        return 0
    fi

    if ! echo "$config_content" | grep -q '||'; then
        info "Config appears valid (no ||true| corruption detected)"
        return 0
    fi

    info "Found corrupted paths, repairing..."

    # Fix the config by removing ||...| suffix from paths
    local host_uid
    host_uid=$(get_host_uid)

    docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "sed -i 's/||[^|]*|$//' /session/.claude-projects.yml"

    # Verify the fix
    local fixed_content
    fixed_content=$(read_session_config "$volume")

    if echo "$fixed_content" | grep -q '||'; then
        error "Repair incomplete - some paths may still be corrupted"
        return 1
    fi

    success "Config repaired successfully"
    echo ""
    echo "Fixed config:"
    echo "$fixed_content" | head -20
}
