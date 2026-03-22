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

    if [[ "$_org_prefix" != "$_repo_basename" ]]; then
        # Has org prefix (e.g. "hypermemetic/plexus-core") — match by org
        while IFS='|' read -r _pname _ppath; do
            [[ -z "$_ppath" ]] && continue
            if [[ "$_pname" == "$_org_prefix"/* ]]; then
                echo "$(dirname "$_ppath")/$_repo_basename"
                return 0
            fi
        done <<< "$projects"
    fi

    # No org prefix or no org match — infer as sibling of any config project.
    # Check if repo exists as a sibling directory of any known project.
    while IFS='|' read -r _pname _ppath; do
        [[ -z "$_ppath" ]] && continue
        local _sibling_candidate="$(dirname "$_ppath")/$_repo_basename"
        if [[ -d "$_sibling_candidate" ]] && [[ -d "$_sibling_candidate/.git" || -f "$_sibling_candidate/.git" ]]; then
            echo "$_sibling_candidate"
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
# Snapshot ALL session state in one shot: one docker run + local git ops.
# Writes per-repo data to result dir via _pull_result_set.
# This is the single source of truth — no other function should docker-run to read container state.
#
# Arguments:
#   $1 - volume name (e.g. "claude-session-foo")
#   $2 - session_name (branch name used for extraction)
#   $3 - target_branch (branch to merge into, may be empty)
#   $4 - output_dir (result dir for _pull_result_set)
#   $5 - repo_filter (comma-separated partial names, may be empty)
# Reads config from volume to resolve host paths.
snapshot_session_state() {
    local volume="$1"
    local session_name="$2"
    local target_branch="$3"
    local output_dir="$4"
    local repo_filter="${5:-}"
    local git_image="${GIT_UTIL_IMAGE:-alpine/git}"

    # Read config for host path resolution + extract flags
    local _snap_cfg
    _snap_cfg=$(read_session_config "$volume")
    local _snap_projects=""
    if [[ -n "$_snap_cfg" ]]; then
        _snap_projects=$(parse_session_projects "$_snap_cfg")
    fi
    if [[ -n "$repo_filter" ]]; then
        _snap_projects=$(augment_projects_from_volume "$volume" "$_snap_projects" "$repo_filter")
    fi

    # Build extract flag lookup from full config
    declare -A _snap_extract_flags
    if [[ -n "$_snap_cfg" ]]; then
        local _snap_full
        _snap_full=$(parse_session_projects_full "$_snap_cfg")
        if [[ -n "$_snap_full" ]]; then
            while IFS='|' read -r _ef_name _ef_path _ef_extract; do
                [[ -z "$_ef_name" ]] && continue
                _snap_extract_flags[$_ef_name]="${_ef_extract:-true}"
            done <<< "$_snap_full"
        fi
    fi

    # Step A: One docker run reads ALL container state
    local _container_scan
    _container_scan=$(docker run --rm --entrypoint sh \
        -e HOME=/tmp \
        -v "$volume:/session:ro" "$git_image" \
        -c '
            git config --global --add safe.directory "*"
            for d in /session/*/ /session/*/*/; do
                [ -d "$d/.git" ] || continue
                name="${d#/session/}"; name="${name%/}"
                head=$(cd "$d" && git rev-parse HEAD 2>/dev/null | head -1)
                # Skip empty repos (no commits) where rev-parse returns literal "HEAD"
                case "$head" in
                    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
                    *) continue ;;
                esac
                dirty=$(cd "$d" && git status --porcelain 2>/dev/null | wc -l | tr -d " ")
                merging="no"; [ -f "$d/.git/MERGE_HEAD" ] && merging="yes"
                gitsize=$(du -sm "$d/.git" 2>/dev/null | cut -f1)
                echo "$name|$head|$dirty|$merging|${gitsize:-0}"
            done
        ' 2>/dev/null) || true

    [[ -z "$_container_scan" ]] && return 0

    # Step B+C: Per-repo local git ops + filter
    while IFS='|' read -r _name _head _dirty _merging _gitsize; do
        [[ -z "$_name" ]] && continue

        # Step C: Apply repo filter
        repo_matches_filter "$_name" "$repo_filter" || continue

        # Write container state
        _pull_result_set "$output_dir" "$_name" "repo_name" "$_name"
        _pull_result_set "$output_dir" "$_name" "container_head" "$_head"
        _pull_result_set "$output_dir" "$_name" "dirty_count" "$_dirty"
        _pull_result_set "$output_dir" "$_name" "merging" "$_merging"
        _pull_result_set "$output_dir" "$_name" "git_size_mb" "$_gitsize"

        # Extract flag from config (false = discovered repo, not yet promoted)
        local _extract_flag="${_snap_extract_flags[$_name]:-true}"
        _pull_result_set "$output_dir" "$_name" "extract_enabled" "$_extract_flag"

        # Resolve host path
        local _path=""
        if [[ -n "$_snap_projects" ]]; then
            _path=$(echo "$_snap_projects" | grep "^${_name}|" | head -1 | cut -d'|' -f2)
        fi
        if [[ -z "$_path" ]]; then
            _path=$(resolve_repo_host_path "$_name" "$_snap_projects")
        fi
        _pull_result_set "$output_dir" "$_name" "host_path" "$_path"

        # Skip local git ops if host path doesn't exist
        if [[ -z "$_path" || ! -d "$_path" ]]; then
            _pull_result_set "$output_dir" "$_name" "container_known" "false"
            continue
        fi

        # Host session branch HEAD (only if branch actually exists)
        local _session_head=""
        if git -C "$_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
            _session_head=$(git -C "$_path" rev-parse "refs/heads/$session_name" 2>/dev/null || echo "")
            # Validate looks like a SHA (rev-parse outputs the ref name on failure)
            [[ "$_session_head" =~ ^[0-9a-f]{7,} ]] || _session_head=""
        fi
        _pull_result_set "$output_dir" "$_name" "session_head" "${_session_head:-}"

        # Host target branch HEAD
        local _target_head=""
        if [[ -n "$target_branch" ]] && git -C "$_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
            _target_head=$(git -C "$_path" rev-parse "refs/heads/$target_branch" 2>/dev/null)
        fi
        [[ -n "$target_branch" ]] && _pull_result_set "$output_dir" "$_name" "target_head" "${_target_head:-}"

        # Squash-base ref
        if [[ -n "$session_name" ]]; then
            local _squash_base
            _squash_base=$(git -C "$_path" rev-parse --verify "refs/claude-container/squash-base/${session_name}" 2>/dev/null || echo "")
            _pull_result_set "$output_dir" "$_name" "squash_base" "${_squash_base:-}"
        fi

        # Host dirty state
        local _host_dirty
        _host_dirty=$(git -C "$_path" status --porcelain 2>/dev/null | head -1)
        _pull_result_set "$output_dir" "$_name" "host_dirty" "$([[ -n "$_host_dirty" ]] && echo true || echo false)"

        # Is container HEAD known on host?
        local _container_known=false
        git -C "$_path" cat-file -t "$_head" &>/dev/null && _container_known=true
        _pull_result_set "$output_dir" "$_name" "container_known" "$_container_known"

        # External commits ahead on target (non-squash)
        if [[ -n "$target_branch" && -n "$_target_head" && -n "$_session_head" ]]; then
            local _ext_ahead
            _ext_ahead=$(count_external_ahead "$_path" "$session_name" "$target_branch")
            _pull_result_set "$output_dir" "$_name" "external_ahead" "$_ext_ahead"
        else
            _pull_result_set "$output_dir" "$_name" "external_ahead" "0"
        fi

        # Is container's new work already in target?
        # True when container HEAD is ancestor of target or tree-identical.
        # Consumers use this to avoid "ready to merge" when there's nothing to do.
        local _container_in_target=false
        if [[ -n "$target_branch" && -n "$_target_head" ]] && $_container_known; then
            if git -C "$_path" merge-base --is-ancestor "$_head" "$_target_head" 2>/dev/null; then
                _container_in_target=true
            elif git -C "$_path" diff --quiet "$_head" "$_target_head" -- 2>/dev/null; then
                _container_in_target=true
            fi
        fi
        _pull_result_set "$output_dir" "$_name" "container_in_target" "$_container_in_target"

        # Pre-extraction status (replaces detect_pre_extract_status)
        if [[ -z "$_session_head" ]]; then
            _pull_result_set "$output_dir" "$_name" "pre_status" "not_extracted"
            _pull_result_set "$output_dir" "$_name" "pre_new_commits" "0"
        elif [[ "$_head" == "$_session_head" ]]; then
            _pull_result_set "$output_dir" "$_name" "pre_status" "up_to_date"
            _pull_result_set "$output_dir" "$_name" "pre_new_commits" "0"
        elif git -C "$_path" merge-base --is-ancestor "$_session_head" "$_head" 2>/dev/null; then
            local _nc
            _nc=$(git -C "$_path" rev-list --count "$_session_head".."$_head" 2>/dev/null || echo "0")
            _pull_result_set "$output_dir" "$_name" "pre_status" "ahead"
            _pull_result_set "$output_dir" "$_name" "pre_new_commits" "$_nc"
        elif $_container_known; then
            if git -C "$_path" diff --quiet "$_session_head" "$_head" -- 2>/dev/null; then
                _pull_result_set "$output_dir" "$_name" "pre_status" "rebased"
                _pull_result_set "$output_dir" "$_name" "pre_new_commits" "0"
            else
                _pull_result_set "$output_dir" "$_name" "pre_status" "ahead"
                _pull_result_set "$output_dir" "$_name" "pre_new_commits" "1"
            fi
        else
            _pull_result_set "$output_dir" "$_name" "pre_status" "ahead"
            _pull_result_set "$output_dir" "$_name" "pre_new_commits" "1"
        fi

        # Backward compat: write pre_session_head / pre_target_head aliases
        _pull_result_set "$output_dir" "$_name" "pre_session_head" "${_session_head:-}"
        [[ -n "$_target_head" ]] && _pull_result_set "$output_dir" "$_name" "pre_target_head" "$_target_head"
    done <<< "$_container_scan" || true
}

# Compute the diff between the session branch and a comparison branch for one repo,
# accounting for squash-base. All callers should use this instead of raw `git diff`.
#
# When a squash-base exists, the "new work" diff is squash_base..session (what the container
# added since last sync), not target..session (which double-counts already-squashed content).
# The "incoming" diff (what target has that session doesn't) uses the same base.
#
# Arguments:
#   $1 - result_dir (snapshot dir with per-repo state)
#   $2 - repo_name
#   $3 - direction: "outbound" (session→target) or "inbound" (target→session)
#   $4 - format: "stat" (--stat), "summary" (last line of --stat), "names" (--name-only),
#                "count" (file count only), "full" (full diff)
# Output: diff output on stdout, empty if nothing to diff
# Returns: always 0 (safe under set -e). Empty stdout means no diff.
snapshot_diff() {
    local result_dir="$1"
    local repo_name="$2"
    local direction="${3:-outbound}"
    local format="${4:-stat}"

    local _path _session_head _target_head _squash_base _container_known
    _path=$(_pull_result_get "$result_dir" "$repo_name" "host_path")
    _session_head=$(_pull_result_get "$result_dir" "$repo_name" "session_head")
    _target_head=$(_pull_result_get "$result_dir" "$repo_name" "target_head")
    _squash_base=$(_pull_result_get "$result_dir" "$repo_name" "squash_base")
    _container_known=$(_pull_result_get "$result_dir" "$repo_name" "container_known")

    [[ -z "$_path" || ! -d "$_path" ]] && return 0
    [[ -z "$_session_head" ]] && return 0

    # Determine the right base for comparison
    # With squash-base: compare from the last sync point (avoids double-counting squashed content)
    # Without: compare the trees directly (target..session or session..target)
    local _from _to

    if [[ "$direction" == "outbound" ]]; then
        # session → target: what would merging session into target change?
        if [[ -n "$_squash_base" ]] && \
           git -C "$_path" merge-base --is-ancestor "$_squash_base" "$_session_head" 2>/dev/null; then
            # squash-base is valid — diff shows new work since last squash
            _from="$_squash_base"
            _to="$_session_head"
        elif [[ -n "$_target_head" ]]; then
            _from="$_target_head"
            _to="$_session_head"
        else
            return 0
        fi
    else
        # target → session: what does target have that session doesn't?
        if [[ -n "$_target_head" && -n "$_session_head" ]]; then
            _from="$_session_head"
            _to="$_target_head"
        else
            return 0
        fi
    fi

    # Check refs exist
    git -C "$_path" cat-file -t "$_from" &>/dev/null || return 0
    git -C "$_path" cat-file -t "$_to" &>/dev/null || return 0

    # Trees identical → no diff
    git -C "$_path" diff --quiet "$_from" "$_to" -- 2>/dev/null && return 0

    case "$format" in
        stat)
            git -C "$_path" diff --stat "$_from".."$_to" 2>/dev/null
            ;;
        summary)
            git -C "$_path" diff --stat "$_from".."$_to" 2>/dev/null | tail -1
            ;;
        names)
            git -C "$_path" diff --name-only "$_from".."$_to" 2>/dev/null
            ;;
        count)
            git -C "$_path" diff --name-only "$_from".."$_to" 2>/dev/null | wc -l | tr -d ' '
            ;;
        full)
            git -C "$_path" diff "$_from".."$_to" 2>/dev/null
            ;;
    esac
}

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
