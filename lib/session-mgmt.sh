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

    # Compute last-opened for each session (fast — just stat on host files)
    local now_epoch
    now_epoch=$(date +%s)

    _format_last_opened() {
        local env_file="$1"
        if [[ ! -f "$env_file" ]]; then
            echo "-"
            return
        fi
        local mtime_epoch
        mtime_epoch=$(stat -f %m "$env_file" 2>/dev/null || stat -c %Y "$env_file" 2>/dev/null || echo "0")
        if [[ "$mtime_epoch" -le 0 ]]; then
            echo "-"
            return
        fi
        local days_ago=$(( (now_epoch - mtime_epoch) / 86400 ))
        if [[ $days_ago -eq 0 ]]; then
            echo "today"
        elif [[ $days_ago -eq 1 ]]; then
            echo "yesterday"
        elif [[ $days_ago -lt 30 ]]; then
            echo "${days_ago}d ago"
        else
            date -r "$mtime_epoch" "+%Y-%m-%d" 2>/dev/null \
                || date -d "@$mtime_epoch" "+%Y-%m-%d" 2>/dev/null \
                || echo "${days_ago}d ago"
        fi
    }

    # Display table
    echo ""
    if [[ "$show_sizes" == "true" ]]; then
        printf "%-30s %12s %10s %10s %10s %10s %10s\n" "SESSION" "LAST OPENED" "WORKSPACE" "STATE" "CARGO" "NPM" "PIP"
        printf "%-30s %12s %10s %10s %10s %10s %10s\n" "-------" "-----------" "---------" "-----" "-----" "---" "---"
    else
        printf "%-30s %12s\n" "SESSION" "LAST OPENED"
        printf "%-30s %12s\n" "-------" "-----------"
    fi

    # Sort sessions by most recently used (mtime descending), then alphabetical fallback
    local _sorted_sessions=""
    for _s in "${!sessions[@]}"; do
        local _env="$sessions_config/${_s}.env"
        local _mt=0
        if [[ -f "$_env" ]]; then
            _mt=$(stat -f %m "$_env" 2>/dev/null || stat -c %Y "$_env" 2>/dev/null || echo "0")
        fi
        _sorted_sessions+="$_mt $_s"$'\n'
    done
    _sorted_sessions=$(echo "$_sorted_sessions" | sort -t' ' -k1 -rn -k2)

    while read -r _mtime session; do
        [[ -z "$session" ]] && continue
        local last_opened
        last_opened=$(_format_last_opened "$sessions_config/${session}.env")

        if [[ "$show_sizes" == "true" ]]; then
            local ws="${vol_sizes[claude-session-$session]:-"-"}"
            local st="${vol_sizes[claude-state-$session]:-"-"}"
            local ca="${vol_sizes[claude-cargo-$session]:-"-"}"
            local np="${vol_sizes[claude-npm-$session]:-"-"}"
            local pi="${vol_sizes[claude-pip-$session]:-"-"}"
            printf "%-30s %12s %10s %10s %10s %10s %10s\n" "$session" "$last_opened" "$ws" "$st" "$ca" "$np" "$pi"
        else
            printf "%-30s %12s\n" "$session" "$last_opened"
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
            warn "  $proj_name has uncommitted changes (will need manual commit/stash)"
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
        local _matches=()
        while IFS='|' read -r _rn _rp; do
            [[ -z "$_rn" ]] && continue
            if [[ "$_rn" == "$repo_filter" ]]; then
                # Exact match — use it directly, skip ambiguity check
                _matches=("$_rn")
                break
            elif [[ "$_rn" == */"$repo_filter" ]]; then
                _matches+=("$_rn")
            fi
        done <<< "$projects"

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
                    echo 'DIRTY|$proj_name|'\$dirty_count' dirty file(s) — use --force to override'
                    git remote remove _host 2>/dev/null || true
                    exit 0
                else
                    echo 'WARN|$proj_name|'\$dirty_count' dirty file(s) will be discarded'
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
                echo 'DIVERGE|$proj_name|session and host have diverged (use --force or push --rebase)'
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
        warn "$fail_count project(s) diverged (use push --rebase)"
    fi
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
    local dirty_mounts=()   # Collect proj_name|proj_path for .merge-into-mounts marker

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

        info "  Merging into $proj_name..."

        # Check for merge in progress
        local merge_in_progress
        merge_in_progress=$(docker run --rm \
            -v "$volume:/session:ro" \
            "$git_image" \
            sh -c "test -f '/session/$proj_name/.git/MERGE_HEAD' && echo 'yes' || echo 'no'" 2>/dev/null)

        if [[ "$merge_in_progress" == "yes" ]]; then
            warn "    $proj_name has merge in progress (use git commit or git merge --abort)"
            summary_lines+=("CONFLICT: $proj_name (merge in progress)")
            conflict_count=$((conflict_count + 1))
            continue
        fi

        # Check for uncommitted/unstaged changes BEFORE merging
        local dirty_status
        dirty_status=$(docker run --rm \
            -v "$volume:/session:ro" \
            "$git_image" \
            sh -c "git config --global --add safe.directory '*' && cd '/session/$proj_name' && git status --porcelain" 2>/dev/null)

        if [[ -n "$dirty_status" ]]; then
            warn "    $proj_name has uncommitted changes — skipping merge, mounting host repo for Claude"
            echo "$dirty_status" | head -3 | sed 's/^/      /'
            local change_count
            change_count=$(echo "$dirty_status" | wc -l | tr -d ' ')
            if [[ $change_count -gt 3 ]]; then
                echo "      ... and $((change_count - 3)) more"
            fi
            # Mount the host repo into the container so Claude can handle the merge
            EXTRA_DOCKER_ARGS+=("-v" "$proj_path:/host/$proj_name:ro")
            dirty_mounts+=("$proj_name|$proj_path")
            summary_lines+=("DIRTY: $proj_name ($change_count uncommitted changes) — host repo mounted at /host/$proj_name")
            dirty_count=$((dirty_count + 1))
            continue
        fi

        # Add remote, fetch, and merge in one docker run
        local merge_output
        local host_uid
        host_uid=$(get_host_uid)

        merge_output=$(docker run --rm \
            --user "$host_uid:$host_uid" \
            -v "$volume:/session" \
            -v "$proj_path:/upstream:ro" \
            "$git_image" \
            sh -c "
                cd '/session/$proj_name'
                git -c safe.directory='*' remote remove upstream 2>/dev/null || true
                git -c safe.directory='*' remote add upstream /upstream
                git -c safe.directory='*' fetch upstream '$target_branch' 2>&1
                git -c safe.directory='*' merge 'upstream/$target_branch' --no-edit 2>&1 || true
            " 2>&1)

        if echo "$merge_output" | grep -qE "CONFLICT|Merge conflict|Automatic merge failed"; then
            warn "    $proj_name has conflicts (Claude will resolve)"
            summary_lines+=("CONFLICT: $proj_name (merge conflicts)")
            conflict_count=$((conflict_count + 1))
        elif echo "$merge_output" | grep -qE "error:|fatal:"; then
            error "    $proj_name merge failed:"
            echo "$merge_output" | grep -E "error:|fatal:" | head -3 | sed 's/^/      /'
            summary_lines+=("FAIL: $proj_name (merge error)")
            skip_count=$((skip_count + 1))
        elif echo "$merge_output" | grep -q "Already up to date"; then
            info "    $proj_name (already up to date)"
            summary_lines+=("OK: $proj_name (up to date)")
            success_count=$((success_count + 1))
        else
            success "    $proj_name merged successfully"
            summary_lines+=("OK: $proj_name (merged)")
            success_count=$((success_count + 1))
        fi
    done <<< "$projects"

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

    # If nothing needs Claude's attention, signal early exit
    if [[ $conflict_count -eq 0 ]] && [[ $dirty_count -eq 0 ]]; then
        echo ""
        success "Merge complete — nothing for Claude to resolve."
        # Store merge-into state for extract on exit
        local host_uid
        host_uid=$(get_host_uid)
        docker run --rm \
            --user "$host_uid:$host_uid" \
            -v "$volume:/session" \
            "$git_image" \
            sh -c "echo '$target_branch' > /session/.merge-into-branch" 2>/dev/null || true
        return 1  # Signal: no container needed
    fi

    # Build summary for Claude's initial prompt
    local merge_summary
    merge_summary="Branch '$target_branch' was merged into this session. Here is what happened:"
    merge_summary+=$'\n'
    for line in "${summary_lines[@]}"; do
        merge_summary+=$'\n'"  $line"
    done
    if [[ $conflict_count -gt 0 ]]; then
        merge_summary+=$'\n\n'"$conflict_count project(s) have merge conflicts that need resolution."
        merge_summary+=$'\n\n'"Resolve all merge conflicts autonomously. The session branch contains the work we want to keep — when conflicts arise, prefer the session (HEAD/ours) side. The '$target_branch' branch changes should be incorporated where they don't conflict, but session work takes priority."
        merge_summary+=$'\n\n'"For each conflicted project:"
        merge_summary+=$'\n'"1. Find all files with <<<<<<< markers: grep -r '<<<<<<< HEAD' ."
        merge_summary+=$'\n'"2. Edit each file to resolve conflicts, keeping our (HEAD) changes"
        merge_summary+=$'\n'"3. git add the resolved files"
        merge_summary+=$'\n'"4. git commit to complete the merge"
        merge_summary+=$'\n\n'"Do not ask for clarification unless a conflict is genuinely ambiguous (e.g. both sides made substantive changes to the same logic). Just resolve and commit."
    fi
    if [[ $dirty_count -gt 0 ]]; then
        merge_summary+=$'\n\n'"$dirty_count project(s) had uncommitted changes in the session and could not be auto-merged. The host repos are mounted read-only at /host/{project_name} so you can complete the merge manually."
        merge_summary+=$'\n\n'"For each dirty project:"
        merge_summary+=$'\n'"1. cd /workspace/{project_name}"
        merge_summary+=$'\n'"2. Review uncommitted changes: git status && git diff"
        merge_summary+=$'\n'"3. Commit or stash the uncommitted work: git add -A && git commit -m 'WIP: uncommitted session work'"
        merge_summary+=$'\n'"4. Merge from host: git remote add upstream /host/{project_name} && git fetch upstream $target_branch && git merge upstream/$target_branch --no-edit"
        merge_summary+=$'\n'"5. Resolve any conflicts (prefer session/HEAD side), then git add and git commit"
        merge_summary+=$'\n'"6. Clean up: git remote remove upstream"
    fi
    merge_summary+=$'\n\n'"After resolving all conflicts, review the result:"
    merge_summary+=$'\n'"- Do the merged changes preserve the functionality of the committed session work? Are there any regressions?"
    merge_summary+=$'\n'"- Are there augmentations — new features or behavior introduced by '$target_branch' that extend or change what the session was doing?"
    merge_summary+=$'\n'"- If anything is uncertain — ambiguous conflict resolutions, code that may have changed semantics, or areas where both branches made overlapping changes — present those uncertainties to me with your answers to the above questions."
    merge_summary+=$'\n\n'"When you have finished resolving all conflicts and are satisfied with the result, run:"
    merge_summary+=$'\n'"  fin \"<brief description of what was resolved>\""
    merge_summary+=$'\n'"This will signal completion and terminate the session."

    # Store merge-into state and summary for container startup
    local host_uid
    host_uid=$(get_host_uid)
    docker run --rm \
        --user "$host_uid:$host_uid" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c "echo '$target_branch' > /session/.merge-into-branch" 2>/dev/null || true

    # Write summary to volume (use printf to handle newlines correctly)
    printf '%s' "$merge_summary" | docker run --rm -i \
        --user "$host_uid:$host_uid" \
        -v "$volume:/session" \
        "$git_image" \
        sh -c 'cat > /session/.merge-into-summary' 2>/dev/null || true

    # Write dirty mount info so exec-back can reconstruct EXTRA_DOCKER_ARGS
    if [[ ${#dirty_mounts[@]} -gt 0 ]]; then
        printf '%s\n' "${dirty_mounts[@]}" | docker run --rm -i \
            --user "$host_uid:$host_uid" \
            -v "$volume:/session" \
            "$git_image" \
            sh -c 'cat > /session/.merge-into-mounts' 2>/dev/null || true
    fi

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

    # Parse flags
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
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

    info "Extracting session '$session_name'..."
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
        _extract_multi_project_direct "$session_name" "$volume" "$_util_image" "$config_content" "$force" "$_old_manifest"
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

    info "Multi-project session detected"
    echo ""

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
        if [[ ! -d "$proj_path" ]]; then
            info "  $proj_name: host path missing ($proj_path) — will extract from session"
            _missing_host_repos+=("$proj_name|$proj_path")
            continue
        fi
        _valid_projects+=("$proj_name|$proj_path")
        echo "$proj_name"
    done <<< "$projects" > "$bundle_dir/.projects"

    if [[ ${#_valid_projects[@]} -eq 0 ]]; then
        warn "No valid projects to extract"
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
            success "  $proj_name → $session_name @ $_short_h"
        else
            echo -e "  ${BLUE}—${NC} $proj_name $_short_s"
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
                    if git -C "$_p4_host_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
                        success "  $_sname → $session_name @ $_short_p4"
                    else
                        echo -e "  ${BLUE}—${NC} $_sname $_short_p4"
                    fi
                    _config_names[$_sname]=1  # prevent Phase 4 from re-collecting
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
            error "  $proj_name fetch failed"
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
            echo "  $proj_name (no changes)"
            continue
        fi

        # If branch exists, allow fast-forward without --force; require --force for diverged
        if $_branch_exists; then
            if git -C "$proj_path" merge-base --is-ancestor "$_compare_base" "$fetched_head" 2>/dev/null; then
                : # fast-forward — safe to update
            elif [[ "$force" != "true" ]]; then
                warn "Skipping $proj_name (branch '$session_name' has diverged, use --force)"
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
                error "  $proj_name branch creation failed"
                fail_count=$((fail_count + 1))
                continue
            fi
        fi

        # Count commits and files
        local commit_count
        commit_count=$(git -C "$proj_path" rev-list --count "$_compare_base".."$session_name" 2>/dev/null || echo "0")
        local files_changed
        files_changed=$(git -C "$proj_path" diff --stat --name-only "$_compare_base".."$session_name" 2>/dev/null | wc -l | tr -d ' ')

        if $_branch_checked_out; then
            success "  $proj_name → updated checked-out branch '$session_name' ($commit_count commit(s), $files_changed file(s))"
        elif $_branch_exists; then
            success "  $proj_name → updated branch '$session_name' ($commit_count commit(s), $files_changed file(s))"
        else
            success "  $proj_name → branch '$session_name' ($commit_count commit(s), $files_changed file(s))"
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
                    warn "  $_new_name (no bundle data)"
                    fail_count=$((fail_count + 1))
                    continue
                fi
                if ! git -C "$_target_dir" fetch "$_bundle" HEAD 2>/dev/null; then
                    error "  $_new_name fetch failed"
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
                    echo "  $_new_name (no changes)"
                    continue
                fi
                git -C "$_target_dir" branch -f "$session_name" FETCH_HEAD 2>/dev/null
                if $_branch_exists; then
                    local _n_commits
                    _n_commits=$(git -C "$_target_dir" rev-list --count "$_compare_base".."$session_name" 2>/dev/null || echo "?")
                    success "  $_new_name → branch '$session_name' in $_target_dir ($_n_commits commit(s))"
                else
                    success "  $_new_name → branch '$session_name' in $_target_dir"
                fi
                success_count=$((success_count + 1))
            elif [[ -d "$_target_dir" ]]; then
                warn "  $_new_name → skipped (directory exists but not a git repo: $_target_dir)"
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
                    success "  $_new_name → cloned to $_target_dir ($_commit_count commit(s))"
                    success_count=$((success_count + 1))
                else
                    error "  $_new_name → clone failed"
                    fail_count=$((fail_count + 1))
                fi
            fi
        done
    fi

    # Update manifest so future pulls know about all repos (including ones
    # added via --add-repo, --discover-repos, or created inside the container)
    write_repo_manifest "$volume"

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

    if [[ "$dry_run" == "true" ]]; then
        info "Dry run: checking merge of '$session_name' into '$target_branch'..."
    else
        info "Merging session '$session_name' into '$target_branch'..."
    fi
    echo ""

    local projects
    projects=$(parse_session_projects "$config_content")

    # Create temp dir for parallel result collection
    local _result_dir
    _result_dir=$(mktemp -d)
    trap "rm -rf '$_result_dir'" RETURN

    # Launch each merge in parallel
    local _pids=()
    local _proj_names=()
    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue

        _proj_names+=("$proj_name")

        # Run each merge in a subshell
        (
            local _result_file="$_result_dir/${proj_name//\//_}"

            if [[ ! -d "$proj_path" ]]; then
                echo "SKIP|$proj_name|repo not found: $proj_path" > "$_result_file"
                exit 0
            fi

            # Skip repos where no session branch exists (nothing to merge — unchanged)
            if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
                exit 0
            fi

            # Skip if session is already merged into target (nothing to do)
            if git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
                if git -C "$proj_path" merge-base --is-ancestor "$session_name" "$target_branch" 2>/dev/null; then
                    echo "OK|$proj_name|already up to date" > "$_result_file"
                    exit 0
                fi
            fi

            # Check if target repo is dirty
            local orig_dirty
            orig_dirty=$(git -C "$proj_path" status --porcelain 2>/dev/null)
            if [[ -n "$orig_dirty" ]]; then
                echo "SKIP|$proj_name|host has uncommitted changes" > "$_result_file"
                exit 0
            fi

            # If target branch doesn't exist, create it from session branch
            if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
                if [ '$dry_run' != 'true' ]; then
                    git -C "$proj_path" branch "$target_branch" "$session_name" 2>/dev/null
                fi
                echo "OK|$proj_name|would create '$target_branch' from $session_name" > "$_result_file"
                exit 0
            fi

            # Check if already up to date (session is ancestor of target)
            if git -C "$proj_path" merge-base --is-ancestor "$session_name" "$target_branch" 2>/dev/null; then
                echo "OK|$proj_name|already up to date" > "$_result_file"
                exit 0
            fi

            # Check if this would be a fast-forward (target is ancestor of session)
            local is_ff=false
            if git -C "$proj_path" merge-base --is-ancestor "$target_branch" "$session_name" 2>/dev/null; then
                is_ff=true
            fi

            # If not a fast-forward, dry-run the merge to check for conflicts
            if ! $is_ff; then
                local current_branch
                current_branch=$(git -C "$proj_path" symbolic-ref --short HEAD 2>/dev/null || echo "")

                # Checkout target, try merge --no-commit, check result, abort
                local _checkout_ok=false
                if [[ "$current_branch" == "$target_branch" ]]; then
                    _checkout_ok=true
                elif git -C "$proj_path" checkout "$target_branch" 2>/dev/null; then
                    _checkout_ok=true
                fi

                if ! $_checkout_ok; then
                    echo "SKIP|$proj_name|could not checkout $target_branch" > "$_result_file"
                    exit 0
                fi

                if ! git -C "$proj_path" merge --no-commit --no-ff "$session_name" 2>/dev/null; then
                    # Conflicts detected — abort and skip
                    git -C "$proj_path" merge --abort 2>/dev/null || true
                    if [[ "$current_branch" != "$target_branch" ]]; then
                        git -C "$proj_path" checkout "$current_branch" 2>/dev/null || true
                    fi
                    echo "CONFLICT|$proj_name|would conflict" > "$_result_file"
                    exit 0
                fi

                # Clean merge — abort the dry-run, we'll do it for real
                git -C "$proj_path" merge --abort 2>/dev/null || true
                if [[ "$current_branch" != "$target_branch" ]]; then
                    git -C "$proj_path" checkout "$current_branch" 2>/dev/null || true
                fi
            fi

            # Safe to merge — either fast-forward or verified clean
            if [ '$dry_run' = 'true' ]; then
                if $is_ff; then
                    echo "OK|$proj_name|would fast-forward into $target_branch" > "$_result_file"
                else
                    echo "OK|$proj_name|would merge cleanly into $target_branch" > "$_result_file"
                fi
            else
                local current_branch
                current_branch=$(git -C "$proj_path" symbolic-ref --short HEAD 2>/dev/null || echo "")

                if [[ "$current_branch" == "$target_branch" ]]; then
                    git -C "$proj_path" merge "$session_name" --no-edit 2>/dev/null
                    echo "OK|$proj_name|merged $session_name into $target_branch" > "$_result_file"
                else
                    if git -C "$proj_path" checkout "$target_branch" 2>/dev/null; then
                        git -C "$proj_path" merge "$session_name" --no-edit 2>/dev/null
                        echo "OK|$proj_name|merged $session_name into $target_branch" > "$_result_file"
                        git -C "$proj_path" checkout "$current_branch" 2>/dev/null || true
                    else
                        echo "SKIP|$proj_name|could not checkout $target_branch" > "$_result_file"
                    fi
                fi
            fi
        ) &
        _pids+=($!)
    done <<< "$projects"

    # Wait for all merges to complete
    for _pid in "${_pids[@]}"; do
        wait "$_pid" 2>/dev/null || true
    done

    # Collect and display results
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
                success "  $_name: $_msg"
                merge_ok=$((merge_ok + 1))
                ;;
            SKIP)
                warn "  $_name: $_msg (skipped)"
                merge_skip=$((merge_skip + 1))
                ;;
            CONFLICT)
                warn "  $_name: $_msg (skipped)"
                merge_conflict=$((merge_conflict + 1))
                ;;
        esac
    done

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
        echo "    claude-container push -s $session_name $target_branch --merge"
        echo "    claude-container pull -s $session_name $target_branch"
        return 2
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
