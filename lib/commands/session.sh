#!/usr/bin/env bash
# Subcommand: session
# View and manage session properties
#
# Usage:
#   claude-container session -s <session> show          # show all properties
#   claude-container session -s <session> set-dir <dir> # set startup directory
#   claude-container session -s <session> set <key> <value>
#   claude-container session -s <session> unset <key>
#   claude-container session -s <session> rebuild       # remove container, keep volume

cmd_session() {
    local session_name=""
    local action=""
    local -a action_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --help|-h)
                _session_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container session --help' for usage"
                return 1
                ;;
            *)
                if [[ -z "$action" ]]; then
                    action="$1"
                else
                    action_args+=("$1")
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

    case "${action:-show}" in
        show|info)
            _session_show "$session_name"
            ;;
        set-dir|startdir|dir)
            _session_set_dir "$session_name" "${action_args[0]:-}"
            ;;
        set)
            _session_set "$session_name" "${action_args[0]:-}" "${action_args[1]:-}"
            ;;
        unset)
            _session_unset "$session_name" "${action_args[0]:-}"
            ;;
        add-repo|add)
            _session_add_repos "$session_name" "${action_args[@]}"
            ;;
        diff)
            _session_diff "$session_name" "${action_args[0]:-main}"
            ;;
        cleanup|clean)
            _session_cleanup "$session_name"
            ;;
        rebuild)
            _session_rebuild "$session_name"
            ;;
        *)
            error "Unknown action: $action"
            echo "Run 'claude-container session --help' for usage"
            return 1
            ;;
    esac
}

_session_show() {
    local session_name="$1"
    local volume="claude-session-${session_name}"
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"
    local container_name="claude-session-ctr-${session_name}"
    local meta_file="$SESSIONS_CONFIG_DIR/${session_name}.env"

    _rule "session: ${session_name}"
    echo ""

    # Container status
    local _ctr_running _ctr_exists
    _ctr_running=$(docker ps -q --filter "name=^${container_name}$" 2>/dev/null || true)
    _ctr_exists=$(docker ps -aq --filter "name=^${container_name}$" 2>/dev/null || true)
    if [[ -n "$_ctr_running" ]]; then
        echo -e "  container: ${GREEN}running${NC}  ($container_name)"
    elif [[ -n "$_ctr_exists" ]]; then
        echo -e "  container: ${DIM}stopped${NC}  ($container_name)"
    else
        echo -e "  container: ${DIM}none${NC}"
    fi

    # Main project (startup dir)
    local _main_proj
    _main_proj=$(docker run --rm --entrypoint sh -v "$volume:/session:ro" "$git_image" \
        -c 'cat /session/.main-project 2>/dev/null || echo ""' 2>/dev/null || true)
    if [[ -n "$_main_proj" ]]; then
        echo -e "  start dir: ${BLUE}/workspace/${_main_proj}${NC}"
    else
        echo -e "  start dir: ${DIM}/workspace${NC}"
    fi

    # Volume
    echo -e "  volume:    $volume"

    # Session metadata
    if [[ -f "$meta_file" ]]; then
        echo ""
        echo "  properties:"
        while IFS='=' read -r _key _val; do
            [[ -z "$_key" || "$_key" =~ ^# ]] && continue
            case "$_val" in
                true)  echo -e "    ${_key}: ${GREEN}${_val}${NC}" ;;
                false) echo -e "    ${_key}: ${DIM}${_val}${NC}" ;;
                *)     echo -e "    ${_key}: ${_val}" ;;
            esac
        done < "$meta_file"
    fi

    # Repos with host paths
    local _session_cfg
    _session_cfg=$(docker run --rm --entrypoint sh -v "$volume:/session:ro" "$git_image" \
        -c 'cat /session/.claude-projects.yml' 2>/dev/null || true)

    local _repo_count=0
    if [[ -n "$_session_cfg" ]] && command -v yq &>/dev/null; then
        echo ""
        echo "  repos:"
        local _cwd
        _cwd=$(pwd)
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_pname" ]] && continue
            _repo_count=$((_repo_count + 1))
            local _rel_path
            _rel_path=$(python3 -c "import os; print(os.path.relpath('$_ppath', '$_cwd'))" 2>/dev/null || echo "${_ppath/#$HOME/~}")
            if [[ -d "$_ppath" ]]; then
                echo -e "    ${BLUE}$_pname${NC}  ${DIM}$_rel_path${NC}"
            else
                echo -e "    ${BLUE}$_pname${NC}  ${DIM}$_rel_path${NC}  ${YELLOW}(missing)${NC}"
            fi
        done <<< "$(echo "$_session_cfg" | yq eval '.projects | to_entries | .[] | .key + "|" + .value.path' - 2>/dev/null)" || true
    else
        echo ""
        echo -e "  repos:     ${DIM}(no config)${NC}"
    fi

    echo ""
    echo -e "  total:     $_repo_count"

    echo ""
    _rule
}

_session_set_dir() {
    local session_name="$1"
    local target_dir="$2"
    local volume="claude-session-${session_name}"
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"
    local container_name="claude-session-ctr-${session_name}"

    # Read session config
    local _session_cfg _match=""
    _session_cfg=$(docker run --rm --entrypoint sh \
        -v "$volume:/session:ro" "$git_image" \
        -c 'cat /session/.claude-projects.yml' 2>/dev/null || true)

    if [[ -z "$target_dir" ]]; then
        # No arg — use cwd
        target_dir=$(pwd)
    fi

    if [[ -n "$_session_cfg" ]] && command -v yq &>/dev/null; then
        local _projects
        _projects=$(echo "$_session_cfg" | yq eval '.projects | to_entries | .[] | .key + "|" + .value.path' - 2>/dev/null) || true

        # Try 1: match by project name (e.g. "synapse", "hypermemetic/synapse")
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_pname" ]] && continue
            if [[ "$_pname" == "$target_dir" || "$_pname" == *"/$target_dir" || "${_pname##*/}" == "$target_dir" ]]; then
                _match="$_pname"
                break
            fi
        done <<< "$_projects" || true

        # Try 2: match by host path (cwd or absolute path)
        if [[ -z "$_match" ]]; then
            local _abs_dir="$target_dir"
            if [[ "$_abs_dir" != /* ]]; then
                _abs_dir="$(cd "$_abs_dir" 2>/dev/null && pwd)" || _abs_dir=""
            fi
            if [[ -n "$_abs_dir" ]]; then
                while IFS='|' read -r _pname _ppath; do
                    [[ -z "$_ppath" ]] && continue
                    if [[ "$_abs_dir" == "$_ppath" || "$_abs_dir" == "$_ppath"/* ]]; then
                        _match="$_pname"
                        break
                    fi
                done <<< "$_projects" || true
            fi
        fi
    fi

    if [[ -z "$_match" ]]; then
        error "No project matching '$target_dir' in session '$session_name'"
        echo "  Available projects:"
        if [[ -n "$_session_cfg" ]] && command -v yq &>/dev/null; then
            echo "$_session_cfg" | yq eval '.projects | keys | .[]' - 2>/dev/null | while read -r _p; do
                echo "    $_p"
            done
        fi
        return 1
    fi

    # Write .main-project
    docker run --rm --entrypoint sh \
        --user "$(id -u):$(id -u)" \
        -v "$volume:/session" \
        "$git_image" \
        -c "echo '$_match' > /session/.main-project" 2>/dev/null || true

    # Remove stopped container so next launch uses the new dir
    docker rm -f "$container_name" >/dev/null 2>&1 || true

    success "Start directory set to: /workspace/$_match"
    echo -e "${DIM}Container removed — next launch will start in the new directory${NC}"
}

_session_set() {
    local session_name="$1"
    local key="$2"
    local val="$3"
    local meta_file="$SESSIONS_CONFIG_DIR/${session_name}.env"

    if [[ -z "$key" || -z "$val" ]]; then
        error "Usage: session set <key> <value>"
        echo "  Keys: ENABLE_DOCKER, RUN_AS_USER, RUN_AS_ROOTISH, DOCKERFILE, EPHEMERAL"
        return 1
    fi

    # Validate key
    case "$key" in
        ENABLE_DOCKER|RUN_AS_USER|RUN_AS_ROOTISH|DOCKERFILE|EPHEMERAL|NO_CONFIG) ;;
        *)
            error "Unknown property: $key"
            echo "  Valid keys: ENABLE_DOCKER, RUN_AS_USER, RUN_AS_ROOTISH, DOCKERFILE, EPHEMERAL"
            return 1
            ;;
    esac

    if [[ -f "$meta_file" ]]; then
        # Update existing key or append
        if grep -q "^${key}=" "$meta_file" 2>/dev/null; then
            sed -i.bak "s|^${key}=.*|${key}=${val}|" "$meta_file"
            rm -f "${meta_file}.bak"
        else
            echo "${key}=${val}" >> "$meta_file"
        fi
    else
        echo "# Session metadata for claude-container (auto-generated)" > "$meta_file"
        echo "${key}=${val}" >> "$meta_file"
    fi

    # Remove stopped container so new properties take effect
    local container_name="claude-session-ctr-${session_name}"
    docker rm -f "$container_name" >/dev/null 2>&1 || true

    success "$key=$val"
    echo -e "${DIM}Container removed — next launch will use the new setting${NC}"
}

_session_unset() {
    local session_name="$1"
    local key="$2"
    local meta_file="$SESSIONS_CONFIG_DIR/${session_name}.env"

    if [[ -z "$key" ]]; then
        error "Usage: session unset <key>"
        return 1
    fi

    if [[ -f "$meta_file" ]] && grep -q "^${key}=" "$meta_file" 2>/dev/null; then
        sed -i.bak "/^${key}=/d" "$meta_file"
        rm -f "${meta_file}.bak"
        success "Removed: $key"
    else
        info "$key was not set"
    fi
}

_session_rebuild() {
    local session_name="$1"
    local container_name="claude-session-ctr-${session_name}"

    local _running
    _running=$(docker ps -q --filter "name=^${container_name}$" 2>/dev/null || true)
    if [[ -n "$_running" ]]; then
        warn "Stopping running container..."
        docker stop -t 5 "$container_name" >/dev/null 2>&1 || true
    fi

    docker rm -f "$container_name" >/dev/null 2>&1 || true
    success "Container removed for session '$session_name'"
    echo -e "${DIM}Volume preserved — next launch will create a fresh container${NC}"
}

_session_add_repos() {
    local session_name="$1"
    shift
    local -a paths=("$@")

    if [[ ${#paths[@]} -eq 0 ]]; then
        # No args — add cwd if it's a git repo
        local _cwd
        _cwd=$(pwd)
        if is_git_repo "$_cwd"; then
            paths=("$_cwd")
        else
            error "No repo paths given and cwd is not a git repo"
            echo "Usage: session -s $session_name add-repo /path/to/repo [/path/to/another ...]"
            return 1
        fi
    fi

    local _added=0
    for _rpath in "${paths[@]}"; do
        # Resolve absolute
        local _abs
        if [[ "$_rpath" == /* ]]; then
            _abs="$_rpath"
        else
            _abs="$(cd "$_rpath" 2>/dev/null && pwd)" || { warn "Not found: $_rpath"; continue; }
        fi
        if ! is_git_repo "$_abs"; then
            warn "Not a git repo: $_abs"
            continue
        fi
        info "Adding $(basename "$_abs") to session '$session_name'..."
        session_add_repo "$session_name" "$_abs" || { warn "Failed to add $_abs"; continue; }
        _added=$((_added + 1))
    done

    if [[ $_added -gt 0 ]]; then
        success "Added $_added repo(s)"
        # Remove container so new repos are available on next launch
        docker rm -f "claude-session-ctr-${session_name}" >/dev/null 2>&1 || true
    fi
}

_session_diff() {
    local session_name="$1"
    local target_branch="${2:-main}"
    local volume="claude-session-${session_name}"

    # Use snapshot for all state
    local _diff_dir
    _diff_dir=$(mktemp -d)
    snapshot_session_state "$volume" "$session_name" "$target_branch" "$_diff_dir"

    _rule "diff: ${session_name} ↔ ${target_branch}"
    echo ""

    local _any_diff=false
    for _sf in "$_diff_dir"/*; do
        [[ -f "$_sf" ]] || continue
        local _name
        _name=$(grep "^repo_name=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
        [[ -z "$_name" ]] && continue

        local _c_head _s_head _t_head
        _c_head=$(grep "^container_head=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
        _t_head=$(grep "^target_head=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)
        _s_head=$(grep "^session_head=" "$_sf" 2>/dev/null | tail -1 | cut -d= -f2-)

        # Outbound diff (session → target)
        local _out
        _out=$(snapshot_diff "$_diff_dir" "$_name" "outbound" "stat")
        # Inbound diff (target → session)
        local _in
        _in=$(snapshot_diff "$_diff_dir" "$_name" "inbound" "stat")

        [[ -z "$_out" && -z "$_in" ]] && continue
        _any_diff=true

        echo -e "  ${BLUE}$_name${NC}"
        echo -e "    ${DIM}container:${_c_head:0:7}  ${target_branch}:${_t_head:0:7}${NC}"

        if [[ -n "$_out" ]]; then
            echo -e "    ${DIM}session → ${target_branch}:${NC}"
            echo "$_out" | sed 's/^/      /'
        fi
        if [[ -n "$_in" ]]; then
            echo -e "    ${DIM}${target_branch} → session:${NC}"
            echo "$_in" | sed 's/^/      /'
        fi
        echo ""
    done

    rm -rf "$_diff_dir"

    if ! $_any_diff; then
        success "No differences"
    fi

    _rule
}

_session_cleanup() {
    local session_name="$1"
    local volume="claude-session-${session_name}"
    local container_name="claude-session-ctr-${session_name}"

    _rule "cleanup: ${session_name}"
    echo ""

    # Check for running container
    local _running
    _running=$(docker ps -q --filter "name=^${container_name}$" 2>/dev/null || true)
    if [[ -n "$_running" ]]; then
        error "Container is running — stop it first or use 'session rebuild'"
        return 1
    fi

    # Remove stopped container
    local _stopped
    _stopped=$(docker ps -aq --filter "name=^${container_name}$" 2>/dev/null || true)
    if [[ -n "$_stopped" ]]; then
        docker rm -f "$container_name" >/dev/null 2>&1 || true
        success "Removed stopped container"
    else
        echo -e "  ${DIM}No container to remove${NC}"
    fi

    # Clean stale session branches on host
    local _session_cfg
    _session_cfg=$(docker run --rm --entrypoint sh -v "$volume:/session:ro" "${GIT_UTIL_IMAGE:-alpine/git}" \
        -c 'cat /session/.claude-projects.yml' 2>/dev/null || true)

    if [[ -n "$_session_cfg" ]] && command -v yq &>/dev/null; then
        local _cleaned=0
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_ppath" || ! -d "$_ppath" ]] && continue
            # Check for stale session branches
            if git -C "$_ppath" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
                # Check if session branch is merged into main
                local _main_head
                _main_head=$(git -C "$_ppath" rev-parse HEAD 2>/dev/null || echo "")
                local _session_head
                _session_head=$(git -C "$_ppath" rev-parse "refs/heads/$session_name" 2>/dev/null || echo "")
                if [[ -n "$_main_head" && "$_session_head" == "$_main_head" ]]; then
                    echo -e "  ${DIM}$_pname: session branch matches HEAD, removing${NC}"
                    git -C "$_ppath" branch -D "$session_name" >/dev/null 2>&1 || true
                    _cleaned=$((_cleaned + 1))
                elif git -C "$_ppath" merge-base --is-ancestor "$_session_head" "$_main_head" 2>/dev/null; then
                    echo -e "  ${DIM}$_pname: session branch merged, removing${NC}"
                    git -C "$_ppath" branch -D "$session_name" >/dev/null 2>&1 || true
                    _cleaned=$((_cleaned + 1))
                else
                    echo -e "  ${YELLOW}$_pname${NC}: session branch has unmerged work — keeping"
                fi
            fi
            # Clean squash-base refs
            if git -C "$_ppath" show-ref --verify --quiet "refs/claude-container/squash-base/$session_name" 2>/dev/null; then
                git -C "$_ppath" update-ref -d "refs/claude-container/squash-base/$session_name" 2>/dev/null || true
            fi
        done <<< "$(echo "$_session_cfg" | yq eval '.projects | to_entries | .[] | .key + "|" + .value.path' - 2>/dev/null)" || true
        if [[ $_cleaned -gt 0 ]]; then
            success "Cleaned $_cleaned session branch(es)"
        else
            echo -e "  ${DIM}No stale session branches${NC}"
        fi
    fi

    # Clean stale token files
    local _stale_tokens=0
    for _tf in "$CACHE_DIR"/token-*; do
        [[ -e "$_tf" ]] || continue
        _stale_tokens=$((_stale_tokens + 1))
    done
    if [[ $_stale_tokens -gt 0 ]]; then
        rm -f "$CACHE_DIR"/token-*
        success "Cleaned $_stale_tokens stale token file(s)"
    fi

    echo ""
    _rule
}

_session_help() {
    cat <<'EOF'
Usage: claude-container session -s <session> <action> [args]

View and manage session properties.

Actions:
  show                 Show session info, properties, and all repos with host paths
  add-repo [paths...]  Add git repos to session. No args = add cwd.
  diff [branch]        Show squash-aware diffs for all repos (default: main)
  set-dir [dir|name]   Set startup directory by name, path, or cwd
  set <key> <value>    Set a session property
  unset <key>          Remove a session property
  cleanup              Remove stopped container, clean stale session branches + tokens
  rebuild              Remove container (keep volume) — next launch starts fresh

Properties (set/unset):
  ENABLE_DOCKER        Mount Docker socket (true/false)
  RUN_AS_USER          Run as non-root user (true/false)
  RUN_AS_ROOTISH       Run as user with sudo (true/false, default: true)
  DOCKERFILE           Custom Dockerfile path
  EPHEMERAL            Delete session on exit (true/false)

Examples:
  # See session info with all repos
  claude-container session -s myproj show

  # Add current directory as a repo
  cd ~/dev/new-thing && claude-container session -s myproj add-repo

  # Add specific repos
  claude-container session -s myproj add-repo ~/dev/repo1 ~/dev/repo2

  # Show diffs between session and main
  claude-container session -s myproj diff
  claude-container session -s myproj diff develop

  # Set startup dir by project name
  claude-container session -s myproj set-dir synapse

  # Enable Docker-in-Docker
  claude-container session -s myproj set ENABLE_DOCKER true

  # Clean up stale state
  claude-container session -s myproj cleanup

  # Rebuild container (picks up all property changes)
  claude-container session -s myproj rebuild
EOF
}
