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

    # Repo count
    local _repo_count
    _repo_count=$(docker run --rm --entrypoint sh -v "$volume:/session:ro" "$git_image" -c '
        count=0
        for d in /session/*/ /session/*/*/; do
            [ -d "$d/.git" ] && count=$((count + 1))
        done
        echo $count
    ' 2>/dev/null || echo "?")
    echo ""
    echo -e "  repos:     $_repo_count"

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

_session_help() {
    cat <<'EOF'
Usage: claude-container session -s <session> <action> [args]

View and manage session properties.

Actions:
  show                 Show session info (container status, start dir, properties)
  set-dir [dir|name]   Set the startup directory. Uses cwd if no arg given.
                       Accepts a path or project name (e.g. "synapse").
  set <key> <value>    Set a session property
  unset <key>          Remove a session property
  rebuild              Remove container (keep volume) — next launch starts fresh

Properties (set/unset):
  ENABLE_DOCKER        Mount Docker socket (true/false)
  RUN_AS_USER          Run as non-root user (true/false)
  RUN_AS_ROOTISH       Run as user with sudo (true/false, default: true)
  DOCKERFILE           Custom Dockerfile path
  EPHEMERAL            Delete session on exit (true/false)

Examples:
  # See session info
  claude-container session -s myproj show

  # Set startup dir to current directory
  cd ~/dev/myrepo && claude-container session -s myproj set-dir

  # Set startup dir by project name
  claude-container session -s myproj set-dir synapse

  # Enable Docker-in-Docker
  claude-container session -s myproj set ENABLE_DOCKER true

  # Rebuild container (picks up all property changes)
  claude-container session -s myproj rebuild
EOF
}
