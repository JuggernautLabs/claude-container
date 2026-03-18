#!/usr/bin/env bash
# Subcommand: repos
# Manage repos in a session — list, add, remove
#
# Usage:
#   claude-container repos -s <session> list
#   claude-container repos -s <session> add --repo /path/a,/path/b
#   claude-container repos -s <session> remove --repo name1,name2

cmd_repos() {
    local session_name=""
    local action=""
    local repo_filter=""
    local dry_run=false
    local force=false

    # Parse leading flags, then action, then trailing flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --repo)
                if [[ -n "$repo_filter" ]]; then
                    repo_filter="${repo_filter},$2"
                else
                    repo_filter="$2"
                fi
                shift 2
                ;;
            --dry-run|-n)
                dry_run=true
                shift
                ;;
            --force|-f)
                force=true
                shift
                ;;
            --help|-h)
                _repos_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container repos --help' for usage"
                return 1
                ;;
            *)
                if [[ -z "$action" ]]; then
                    action="$1"
                else
                    error "Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$session_name" ]]; then
        error "Session name required: use --session <name>"
        echo "Run 'claude-container repos --help' for usage"
        return 1
    fi

    local volume="claude-session-${session_name}"
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    case "$action" in
        list|ls|"")
            _repos_list "$session_name" "$repo_filter"
            ;;
        add)
            _repos_add "$session_name" "$repo_filter" "$dry_run" "$force"
            ;;
        remove|rm)
            _repos_remove "$session_name" "$repo_filter" "$dry_run" "$force"
            ;;
        discover)
            _repos_discover "$session_name" "$repo_filter" "$dry_run" "$force"
            ;;
        *)
            error "Unknown action: $action (expected: list, add, remove, discover)"
            return 1
            ;;
    esac
}

_repos_list() {
    local session_name="$1"
    local repo_filter="$2"
    local volume="claude-session-${session_name}"

    local config_content
    config_content=$(read_session_config "$volume")
    if [[ -z "$config_content" ]]; then
        error "No .claude-projects.yml in session"
        return 1
    fi

    local projects_full
    projects_full=$(parse_session_projects_full "$config_content")

    local count=0 total=0 discovered=0
    while IFS='|' read -r proj_name proj_path proj_extract; do
        [[ -z "$proj_name" ]] && continue
        total=$((total + 1))
        repo_matches_filter "$proj_name" "$repo_filter" || continue
        if [[ "$proj_extract" == "false" ]]; then
            echo -e "  ${YELLOW}○${NC} ${BLUE}$proj_name${NC}  ${DIM}$proj_path${NC}  ${YELLOW}(discovered, not extracted)${NC}"
            discovered=$((discovered + 1))
        else
            echo -e "  ${BLUE}$proj_name${NC}  ${DIM}$proj_path${NC}"
        fi
        count=$((count + 1))
    done <<< "$projects_full"

    echo ""
    if [[ -n "$repo_filter" ]]; then
        info "$count matching, $total total in session '$session_name'"
    else
        info "$total repo(s) in session '$session_name'"
    fi
    if [[ $discovered -gt 0 ]]; then
        echo -e "${DIM}$discovered discovered repo(s) — use 'repos discover' or 'pull --extract' to extract${NC}"
    fi
}

_repos_add() {
    local session_name="$1"
    local repo_filter="$2"
    local dry_run="$3"
    local force="$4"
    local volume="claude-session-${session_name}"

    if [[ -z "$repo_filter" ]]; then
        error "No repos specified: use --repo /path/to/repo"
        return 1
    fi

    # Read existing config to check for duplicates
    local existing_config existing_names=""
    existing_config=$(read_session_config "$volume" 2>/dev/null || true)
    if [[ -n "$existing_config" ]]; then
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_pname" ]] && continue
            existing_names+="$_pname"$'\n'
        done <<< "$(parse_session_projects "$existing_config")"
    fi

    # Split comma-separated paths
    local IFS=','
    local -a repo_paths=($repo_filter)
    unset IFS

    # Validate paths and build preview
    local -a valid_paths=()
    local -a valid_labels=()
    for rpath in "${repo_paths[@]}"; do
        # Resolve to absolute path
        local abs_path
        if [[ "$rpath" = /* ]]; then
            abs_path="$rpath"
        else
            abs_path="$(cd "$rpath" 2>/dev/null && pwd)" || abs_path=""
        fi

        if [[ -z "$abs_path" || ! -d "$abs_path" ]]; then
            warn "  skip: $rpath (path not found)"
            continue
        fi

        if ! is_git_repo "$abs_path"; then
            warn "  skip: $rpath (not a git repo)"
            continue
        fi

        # Check for worktree
        local source_path="$abs_path"
        local label="$(basename "$abs_path")"
        local extra=""
        if is_git_worktree "$abs_path"; then
            source_path=$(get_main_repo_path "$abs_path")
            local wt_branch
            wt_branch=$(get_git_branch "$abs_path")
            extra=" (worktree → branch: $wt_branch)"
        fi

        # Check if already in session
        if echo "$existing_names" | grep -qx ".*$(basename "$abs_path")"; then
            warn "  skip: $label — already in session"
            continue
        fi

        valid_paths+=("$abs_path")
        valid_labels+=("$label$extra")
    done

    if [[ ${#valid_paths[@]} -eq 0 ]]; then
        error "No valid repos to add"
        return 1
    fi

    # Show preview
    echo ""
    info "Will add ${#valid_paths[@]} repo(s) to session '$session_name':"
    echo ""
    for i in "${!valid_paths[@]}"; do
        echo -e "  ${GREEN}+${NC} ${valid_labels[$i]}"
        echo -e "    ${DIM}source: ${valid_paths[$i]}${NC}"
        echo -e "    ${DIM}action: clone into session volume, update .claude-projects.yml${NC}"
    done
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        info "(dry run — no changes made)"
        return 0
    fi

    if [[ "$force" != "true" ]]; then
        printf "Proceed? [y/N] "
        local answer
        read -r answer
        case "$answer" in
            [yY]|[yY][eE][sS]) ;;
            *)
                echo "Aborted."
                return 0
                ;;
        esac
    fi

    # Add each repo
    local added=0
    for rpath in "${valid_paths[@]}"; do
        echo ""
        session_add_repo "$session_name" "$rpath" || continue
        added=$((added + 1))
    done

    echo ""
    success "Added $added repo(s) to session '$session_name'"
}

_repos_remove() {
    local session_name="$1"
    local repo_filter="$2"
    local dry_run="$3"
    local force="$4"
    local volume="claude-session-${session_name}"

    if [[ -z "$repo_filter" ]]; then
        error "No repos specified: use --repo name1,name2"
        return 1
    fi

    # Read current config
    local config_content
    config_content=$(read_session_config "$volume")
    if [[ -z "$config_content" ]]; then
        error "No .claude-projects.yml in session"
        return 1
    fi

    local projects
    projects=$(parse_session_projects "$config_content")

    # Build removal list using repo_matches_filter
    local -a remove_names=()
    local -a keep_names=()

    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        if repo_matches_filter "$proj_name" "$repo_filter"; then
            remove_names+=("$proj_name")
        else
            keep_names+=("$proj_name")
        fi
    done <<< "$projects"

    if [[ ${#remove_names[@]} -eq 0 ]]; then
        info "No repos matched '$repo_filter' — nothing to remove"
        return 0
    fi

    if [[ ${#keep_names[@]} -eq 0 ]] && [[ "$force" != "true" ]]; then
        error "This would remove ALL repos. Use --force to confirm."
        return 1
    fi

    # Show preview
    echo ""
    info "Session: $session_name"
    echo ""
    echo "  Removing (${#remove_names[@]}):"
    for name in "${remove_names[@]}"; do
        echo -e "    ${RED}✗${NC} $name"
    done
    if [[ ${#keep_names[@]} -gt 0 && ${#keep_names[@]} -le 10 ]]; then
        echo ""
        echo -e "  ${DIM}Keeping (${#keep_names[@]}):${NC}"
        for name in "${keep_names[@]}"; do
            echo -e "    ${DIM}$name${NC}"
        done
    elif [[ ${#keep_names[@]} -gt 10 ]]; then
        echo ""
        echo -e "  ${DIM}Keeping ${#keep_names[@]} other repo(s)${NC}"
    fi
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        info "(dry run — no changes made)"
        return 0
    fi

    if [[ "$force" != "true" ]]; then
        printf "Proceed? [y/N] "
        local answer
        read -r answer
        case "$answer" in
            [yY]|[yY][eE][sS]) ;;
            *)
                echo "Aborted."
                return 0
                ;;
        esac
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

_repos_discover() {
    local session_name="$1"
    local repo_filter="$2"
    local dry_run="$3"
    local force="$4"
    local volume="claude-session-${session_name}"

    local config_content
    config_content=$(read_session_config "$volume")
    local projects=""
    if [[ -n "$config_content" ]]; then
        projects=$(parse_session_projects "$config_content")
    fi

    # Run discovery — registers new repos with extract: false
    discover_and_register "$volume" "$config_content" "$projects"

    # Re-read config to show current state (including newly discovered)
    config_content=$(read_session_config "$volume")
    local full_projects
    full_projects=$(parse_session_projects_full "$config_content")

    [[ -z "$full_projects" ]] && return 0

    # List discovered (extract: false) repos
    local -a discovered=()
    while IFS='|' read -r _dn _dp _de; do
        [[ -z "$_dn" ]] && continue
        [[ "$_de" == "false" ]] || continue
        repo_matches_filter "$_dn" "$repo_filter" || continue
        discovered+=("$_dn|$_dp")
    done <<< "$full_projects"

    if [[ ${#discovered[@]} -eq 0 ]]; then
        info "No discovered repos pending extraction"
        return 0
    fi

    echo ""
    info "${#discovered[@]} discovered repo(s) in session '$session_name' (not yet extracted):"
    echo ""
    for _entry in "${discovered[@]}"; do
        local _dn="${_entry%%|*}"
        local _dp="${_entry#*|}"
        echo -e "  ${YELLOW}○${NC} ${BLUE}$_dn${NC}  ${DIM}→ $_dp${NC}"
    done
    echo ""

    if [[ "$dry_run" == "true" ]]; then
        info "(dry run — no changes made)"
        echo ""
        echo "To extract: claude-container pull -s $session_name --extract"
        return 0
    fi

    if [[ "$force" != "true" ]]; then
        printf "Promote for extraction? [y/N] "
        local answer
        read -r answer
        case "$answer" in
            [yY]|[yY][eE][sS]) ;;
            *)
                echo "Aborted."
                echo ""
                echo "To extract later: claude-container pull -s $session_name --extract"
                return 0
                ;;
        esac
    fi

    # Promote: remove extract: false
    promote_discovered_repos "$volume" "$config_content" "$repo_filter"
    echo ""
    echo "Next: claude-container pull -s $session_name"
}

_repos_help() {
    cat <<'EOF'
Usage: claude-container repos -s <session> <action> [options]

Manage repos in a session.

Actions:
  list              List repos in session (default)
  add               Add repos by path
  remove, rm        Remove repos by name
  discover          Find and promote repos created inside the session

Options:
  --session, -s <name>     Session name (required)
  --repo <names>           Repo names/paths (comma-separated, or repeat --repo)
  --dry-run, -n            Preview without changes
  --force, -f              Skip confirmation
  --help, -h               Show this help

Examples:
  # List repos
  claude-container repos -s myproj

  # Add repos by path
  claude-container repos -s myproj add --repo ~/dev/org/repo1,~/dev/org/repo2
  claude-container repos -s myproj add --repo ~/dev/org/repo1 --repo ~/dev/org/repo2

  # Remove repos by name (partial match)
  claude-container repos -s myproj remove --repo cllient,old-thing
  claude-container repos -s myproj rm --repo hyperforge

  # Find repos created by agent inside the session
  claude-container repos -s myproj discover
  claude-container repos -s myproj discover --repo new-thing

  # Dry run
  claude-container repos -s myproj rm --repo '*tui*' --dry-run
EOF
}
