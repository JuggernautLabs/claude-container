#!/usr/bin/env bash
# Subcommand: serve
# Make host git branches available inside the container session volume.
# The agent in the container can fetch and merge at its own pace.
#
# Usage:
#   claude-container serve -s <session> [branch]
#   claude-container serve -s myproj main              # serve main branch
#   claude-container serve -s myproj --repo gamma main # one repo only

cmd_serve() {
    local session_name=""
    local branch=""
    local repo_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session|-s)
                session_name="$2"
                shift 2
                ;;
            --repo)
                repo_filter="$2"
                shift 2
                ;;
            --help|-h)
                _serve_help
                return 0
                ;;
            -*)
                error "Unknown option: $1"
                echo "Run 'claude-container serve --help' for usage"
                return 1
                ;;
            *)
                if [[ -z "$branch" ]]; then
                    branch="$1"
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
        return 1
    fi

    local branch="${branch:-main}"
    local volume="claude-session-${session_name}"

    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        return 1
    fi

    # Read session config for project list
    local config_content
    config_content=$(read_session_config "$volume")
    if [[ -z "$config_content" ]]; then
        error "No .claude-projects.yml in session"
        return 1
    fi

    local projects
    projects=$(parse_session_projects "$config_content")

    # Collect repos to serve
    local -a serve_repos=()  # "name|path" entries
    while IFS='|' read -r proj_name proj_path; do
        [[ -z "$proj_name" ]] && continue
        [[ -n "$repo_filter" && "$proj_name" != *"$repo_filter"* ]] && continue

        if [[ ! -d "$proj_path" ]]; then
            warn "  Skipping $proj_name (not found: $proj_path)"
            continue
        fi

        # Check branch exists
        if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
            warn "  Skipping $proj_name (no branch '$branch')"
            continue
        fi

        serve_repos+=("$proj_name|$proj_path")
    done <<< "$projects"

    if [[ ${#serve_repos[@]} -eq 0 ]]; then
        error "No repos to serve"
        return 1
    fi

    # Create bundles on host, then copy into session volume
    local bundle_dir
    bundle_dir=$(mktemp -d)
    trap "rm -rf '$bundle_dir'" RETURN

    local served=0
    local manifest=""

    for entry in "${serve_repos[@]}"; do
        local _name="${entry%%|*}"
        local _path="${entry#*|}"
        local _safe="${_name//\//_}"
        local _bundle="$bundle_dir/${_safe}.bundle"

        # Get branch HEAD for manifest
        local _head
        _head=$(git -C "$_path" rev-parse --short "$branch" 2>/dev/null)

        # Bundle the branch
        if git -C "$_path" bundle create "$_bundle" "$branch" >/dev/null 2>&1; then
            manifest+="${_name}|${branch}|${_head}"$'\n'
            served=$((served + 1))
        else
            warn "  Failed to bundle $proj_name"
        fi
    done

    if [[ $served -eq 0 ]]; then
        error "No bundles created"
        return 1
    fi

    # Write manifest
    printf '%s' "$manifest" > "$bundle_dir/.manifest"

    # Write a helper script the agent can source
    cat > "$bundle_dir/.fetch-host" << 'FETCHEOF'
#!/bin/sh
# Fetch host branches into session repos
# Usage: sh /session/.host/fetch-host [repo-filter]
# Drops bundles serve'd by: claude-container serve -s <session> <branch>
set -e
BUNDLE_DIR="/session/.host"
[ -f "$BUNDLE_DIR/.manifest" ] || { echo "No host bundles found"; exit 1; }
filter="${1:-}"
while IFS='|' read -r name branch head; do
    [ -z "$name" ] && continue
    [ -n "$filter" ] && case "$name" in *"$filter"*) ;; *) continue ;; esac
    safe=$(echo "$name" | tr "/" "_")
    bundle="$BUNDLE_DIR/${safe}.bundle"
    [ -f "$bundle" ] || continue
    cd "/session/$name" 2>/dev/null || continue
    echo "Fetching $branch ($head) into $name..."
    git fetch "$bundle" "$branch:refs/remotes/host/$branch" 2>/dev/null || {
        echo "  fetch failed for $name"
        continue
    }
    echo "  fetched → host/$branch"
    echo "  merge with: git merge host/$branch"
done < "$BUNDLE_DIR/.manifest"
FETCHEOF
    chmod +x "$bundle_dir/.fetch-host"

    # Copy bundles into session volume via docker
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"

    # Clear old bundles and copy new ones in
    local _copy_err
    _copy_err=$(docker run --rm \
        -v "$volume:/session" \
        -v "$bundle_dir:/host-bundles:ro" \
        --entrypoint sh "$git_image" \
        -c '
            rm -rf /session/.host
            cp -r /host-bundles /session/.host
            chmod -R a+r /session/.host
        ' 2>&1) || {
        error "Failed to copy bundles into session volume"
        [[ -n "$_copy_err" ]] && echo "  $_copy_err"
        return 1
    }

    # Report
    echo ""
    info "Served '$branch' into session '$session_name' ($served repo(s))"
    echo ""
    while IFS='|' read -r _mname _mbranch _mhead; do
        [[ -z "$_mname" ]] && continue
        echo -e "  ${BLUE}$_mname${NC}  ${_mbranch}:${_mhead}"
    done <<< "$manifest"
    echo ""
    info "Agent can run inside container:"
    echo "  sh /session/.host/.fetch-host          # fetch all"
    echo "  sh /session/.host/.fetch-host gamma    # fetch one repo"
    echo "  git merge host/$branch                 # merge into session"
}

_serve_help() {
    cat <<EOF
Usage: claude-container serve -s <session> [branch] [options]

Bundle host git branches and make them available inside the container
session volume. The agent in the container can then fetch and merge
at its own pace.

Arguments:
  branch                   Branch to serve (default: main)

Options:
  --session, -s <name>     Session name (required)
  --repo <name>            Only serve this repo (partial name OK)
  --help, -h               Show this help

How it works:
  Creates git bundles of the specified branch from each host repo and
  drops them into the session volume at /session/.host/. A helper script
  is included that the agent can run to fetch the bundles.

  Inside the container:
    sh /session/.host/.fetch-host          # fetch all repos
    sh /session/.host/.fetch-host gamma    # fetch one repo
    cd /session/myrepo && git merge host/main  # merge

  Combine with watch for live serving:
    claude-container watch -s X -- claude-container serve -s X main

Examples:
  # Serve main branch to container
  claude-container serve -s myproj main

  # Serve only one repo
  claude-container serve -s myproj main --repo gamma

  # Auto-serve whenever local main changes
  claude-container watch -s myproj -- claude-container serve -s myproj main
EOF
}
