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

# Augment a projects list with volume-only repos that match unmatched --repo filter terms.
# When a filter term matches nothing in the config, scans the volume and adds any matching
# repos with resolved host paths. Returns the augmented projects string (name|path lines).
#
# Arguments:
#   $1 - volume name (e.g. "claude-session-foo")
#   $2 - projects string (name|path lines from parse_session_projects)
#   $3 - repo_filter (comma-separated filter terms, may be empty)
# Returns: augmented name|path lines on stdout (original + discovered)
augment_projects_from_volume() {
    local volume="$1"
    local projects="$2"
    local repo_filter="$3"

    # Start with existing projects
    [[ -n "$projects" ]] && echo "$projects"

    # Nothing to augment if no filter
    [[ -z "$repo_filter" ]] && return 0

    # Find which filter terms have no config match
    local -a _unmatched=()
    local IFS=','
    for _fterm in $repo_filter; do
        local _found=false
        if [[ -n "$projects" ]]; then
            while IFS='|' read -r _pname _ppath; do
                [[ -z "$_pname" ]] && continue
                if [[ "$_pname" == *"$_fterm"* ]]; then
                    _found=true
                    break
                fi
            done <<< "$projects"
        fi
        $_found || _unmatched+=("$_fterm")
    done

    [[ ${#_unmatched[@]} -eq 0 ]] && return 0

    # Scan volume for all repo names (single docker run, reuse get_session_heads pattern)
    local _vol_repos
    _vol_repos=$(docker run --rm --entrypoint sh \
        -v "$volume:/session:ro" "${GIT_UTIL_IMAGE:-alpine/git}" \
        -c '
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"
                name="${name%/}"
                echo "$name"
            done
        ' 2>/dev/null) || true

    [[ -z "$_vol_repos" ]] && return 0

    # Match unmatched filter terms against volume repos
    while IFS= read -r _vname; do
        [[ -z "$_vname" ]] && continue
        for _fterm in "${_unmatched[@]}"; do
            if [[ "$_vname" == *"$_fterm"* ]]; then
                # Resolve host path using existing projects for org-sibling inference
                local _host_path
                _host_path=$(resolve_repo_host_path "$_vname" "$projects")
                echo "${_vname}|${_host_path}"
                break
            fi
        done
    done <<< "$_vol_repos"
}

# Parse config YAML into name|path|extract triples on stdout.
# Like parse_session_projects but includes the extract field (defaults to "true" if absent).
# Arguments:
#   $1 - config content (YAML string)
# Returns: name|path|extract lines on stdout
parse_session_projects_full() {
    local config_content="$1"

    [[ -z "$config_content" ]] && return 0

    echo "$config_content" | yq eval \
        '.projects | to_entries | .[] | .key + "|" + .value.path + "|" + (.value.extract // "true" | tostring)' - 2>/dev/null
}

# Discover repos in the session volume that aren't in .claude-projects.yml,
# then register them with extract: false. Idempotent — second call finds nothing new.
# Arguments:
#   $1 - volume name (e.g. "claude-session-foo")
#   $2 - config content (YAML string, may be empty)
#   $3 - projects string (name|path lines from parse_session_projects)
# Returns: prints info line if new repos found; writes updated config to volume
discover_and_register() {
    local volume="$1"
    local config_content="$2"
    local projects="$3"
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"

    # Build set of known project names from config
    declare -A _known_names
    if [[ -n "$projects" ]]; then
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_pname" ]] && continue
            _known_names[$_pname]=1
        done <<< "$projects"
    fi

    # Single docker run: list all repos in volume
    local _vol_repos
    _vol_repos=$(docker run --rm --entrypoint sh \
        -v "$volume:/session:ro" "$git_image" \
        -c '
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"
                name="${name%/}"
                echo "$name"
            done
        ' 2>/dev/null) || true

    [[ -z "$_vol_repos" ]] && return 0

    # Find repos not in config
    local -a _new_repos=()
    while IFS= read -r _vname; do
        [[ -z "$_vname" ]] && continue
        [[ -n "${_known_names[$_vname]:-}" ]] && continue
        _new_repos+=("$_vname")
    done <<< "$_vol_repos"

    [[ ${#_new_repos[@]} -eq 0 ]] && return 0

    # Register each new repo with extract: false
    local _updated_cfg="$config_content"
    if [[ -z "$_updated_cfg" ]]; then
        _updated_cfg="projects: {}"
    fi

    local _count=0
    for _new_name in "${_new_repos[@]}"; do
        local _host_path
        _host_path=$(resolve_repo_host_path "$_new_name" "$projects")
        _updated_cfg=$(echo "$_updated_cfg" | yq eval \
            ".projects.\"$_new_name\".path = \"$_host_path\" | .projects.\"$_new_name\".extract = false" -)
        _count=$((_count + 1))
    done

    if [[ $_count -gt 0 ]]; then
        # Write updated config back to volume
        local _host_uid
        _host_uid=$(get_host_uid)
        echo "$_updated_cfg" | docker run --rm -i --entrypoint sh \
            --user "$_host_uid:$_host_uid" \
            -v "$volume:/session" \
            "$git_image" \
            -c 'cat > /session/.claude-projects.yml' 2>/dev/null
        info "Discovered $_count new repo(s) in session"
    fi
}

# Promote discovered repos (extract: false) to normal (remove extract field).
# Arguments:
#   $1 - volume name
#   $2 - config content (YAML string)
#   $3 - repo_filter (comma-separated, may be empty — empty means all)
# Returns: writes updated config to volume
promote_discovered_repos() {
    local volume="$1"
    local config_content="$2"
    local repo_filter="$3"
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"

    [[ -z "$config_content" ]] && return 0

    # Find extract: false entries
    local _full_projects
    _full_projects=$(parse_session_projects_full "$config_content")
    [[ -z "$_full_projects" ]] && return 0

    local _updated_cfg="$config_content"
    local _count=0

    while IFS='|' read -r _pname _ppath _pextract; do
        [[ -z "$_pname" ]] && continue
        [[ "$_pextract" == "false" ]] || continue
        # Apply repo filter if provided
        if [[ -n "$repo_filter" ]]; then
            repo_matches_filter "$_pname" "$repo_filter" || continue
        fi
        _updated_cfg=$(echo "$_updated_cfg" | yq eval "del(.projects.\"$_pname\".extract)" -)
        _count=$((_count + 1))
    done <<< "$_full_projects"

    if [[ $_count -gt 0 ]]; then
        local _host_uid
        _host_uid=$(get_host_uid)
        echo "$_updated_cfg" | docker run --rm -i --entrypoint sh \
            --user "$_host_uid:$_host_uid" \
            -v "$volume:/session" \
            "$git_image" \
            -c 'cat > /session/.claude-projects.yml' 2>/dev/null
        info "Promoted $_count discovered repo(s) for extraction"
    fi
}
