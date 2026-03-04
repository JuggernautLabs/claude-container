#!/usr/bin/env bash
# claude-container session discovery module - shared config reading and repo discovery
# Source this file after utils.sh and docker-utils.sh
#
# Extracts duplicated patterns for:
#   - Reading .claude-projects.yml from session volumes
#   - Parsing project config into name|path pairs
#   - Scanning volumes for git repos and their HEADs
#   - Resolving host paths via config lookup or org-sibling inference
#   - Classifying repo sync status (synced, unchanged, extracted, etc.)
#
# All functions use stdin/stdout string passing (no namerefs).

# Read .claude-projects.yml from a session volume.
# Arguments:
#   $1 - volume name (e.g. "claude-session-foo")
# Returns: YAML content on stdout (empty string if not found)
read_session_config() {
    local volume="$1"
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"

    docker run --rm --entrypoint sh -v "$volume:/session:ro" "$git_image" \
        -c 'cat /session/.claude-projects.yml' 2>/dev/null || echo ""
}

# Parse config YAML into name|path pairs on stdout.
# Requires yq on the host.
# Arguments:
#   $1 - config content (YAML string)
# Returns: name|path lines on stdout
parse_session_projects() {
    local config_content="$1"

    [[ -z "$config_content" ]] && return 0

    echo "$config_content" | yq eval \
        '.projects | to_entries | .[] | .key + "|" + .value.path' - 2>/dev/null
}

# Scan volume for ALL git repos + their HEADs (single docker run).
# Scans both 1-level (repo/) and 2-level (org/repo/) paths.
# Arguments:
#   $1 - volume name
# Returns: name|head lines on stdout
get_session_heads() {
    local volume="$1"
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"

    docker run --rm --entrypoint sh -v "$volume:/session:ro" "$git_image" \
        -c '
            git config --global --add safe.directory "*"
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"
                name="${name%/}"
                head=$(cd "$d" && git rev-parse HEAD 2>/dev/null | head -1)
                # Skip empty repos (no commits) where rev-parse returns literal "HEAD"
                case "$head" in
                    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
                    *) continue ;;
                esac
                echo "${name}|${head}"
            done
        ' 2>/dev/null || true
}

# Resolve host path for a repo name.
# Looks up in config first, then infers from org-sibling paths, then falls back to cwd.
# Arguments:
#   $1 - repo_name (e.g. "org/repo" or "repo")
#   $2 - projects string (name|path lines from parse_session_projects)
# Returns: resolved path on stdout
resolve_repo_host_path() {
    local repo_name="$1"
    local projects="$2"

    # Try config lookup first
    while IFS='|' read -r _pname _ppath; do
        [[ -z "$_pname" ]] && continue
        if [[ "$_pname" == "$repo_name" ]]; then
            echo "$_ppath"
            return 0
        fi
    done <<< "$projects"

    # Infer from org-sibling: find any config project sharing the same org prefix
    local _repo_basename="${repo_name##*/}"
    local _org_prefix="${repo_name%%/*}"

    while IFS='|' read -r _pname _ppath; do
        [[ -z "$_ppath" ]] && continue
        if [[ "$_pname" == "$_org_prefix"/* ]]; then
            echo "$(dirname "$_ppath")/$_repo_basename"
            return 0
        fi
    done <<< "$projects"

    # Fallback: current directory
    echo "$(pwd)/$_repo_basename"
}

# Classify one repo's sync status.
# Arguments:
#   $1 - session_head (commit hash from volume)
#   $2 - host_path (resolved path to host repo)
#   $3 - session_name (branch name used for extraction)
#   $4 - target_branch (branch to merge into)
# Returns one of: synced, unchanged, extracted_only, not_extracted, missing
check_repo_sync_status() {
    local session_head="$1"
    local host_path="$2"
    local session_name="$3"
    local target_branch="$4"

    # Missing: host repo doesn't exist
    if [[ ! -d "$host_path" ]]; then
        echo "missing"
        return 0
    fi

    # Check if session branch exists on host
    local host_branch_head=""
    if git -C "$host_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
        host_branch_head=$(git -C "$host_path" rev-parse "refs/heads/$session_name" 2>/dev/null)
    fi

    if [[ -z "$host_branch_head" ]]; then
        # No session branch on host — check if session actually changed anything
        local host_head
        host_head=$(git -C "$host_path" rev-parse HEAD 2>/dev/null || echo "")
        if [[ "$session_head" == "$host_head" ]]; then
            echo "unchanged"
        elif git -C "$host_path" merge-base --is-ancestor "$session_head" "$host_head" 2>/dev/null; then
            echo "unchanged"
        else
            echo "not_extracted"
        fi
        return 0
    fi

    # Session branch exists — check extraction + merge status
    local is_extracted=false
    if [[ "$session_head" == "$host_branch_head" ]]; then
        is_extracted=true
    fi

    local is_merged=false
    if git -C "$host_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
        if git -C "$host_path" merge-base --is-ancestor "$session_name" "$target_branch" 2>/dev/null; then
            is_merged=true
        fi
    fi

    if $is_extracted && $is_merged; then
        echo "synced"
    elif $is_extracted; then
        echo "extracted_only"
    else
        echo "not_extracted"
    fi
}
