#!/usr/bin/env bash
# Executable contracts — each function validates one boundary.
# Returns 0 = pass, 1 = fail. Reasons on stdout, logging on stderr.
# Requires: contract.sh and constants.sh sourced first.

# ============================================================================
# Contract: Image meets the container protocol
# ============================================================================
# Checks critical + optional binaries in one docker run.
# Caches result by image ID — only re-checks when image changes.
#
# READS: Docker image (one container run on cache miss, inspect on hit)
# WRITES: cache file at $CC_CACHE_DIR/image-validated/<image_id>
# DESTROYS: nothing
contract_image() {
    local image="$1"

    # Get image ID (free — inspect only)
    local image_id
    image_id=$(docker inspect --format '{{.Id}}' "$image" 2>/dev/null) || {
        echo "fail:image not found: $image"
        return 1
    }

    # Check image USER directive (free — inspect only)
    local image_user
    image_user=$(docker inspect --format '{{.Config.User}}' "$image" 2>/dev/null || echo "")
    if [[ -n "$image_user" && "$image_user" != "root" && "$image_user" != "0" && "$image_user" != "" ]]; then
        echo "fail:image sets USER '$image_user' (entrypoint needs root entry)"
        # Don't cache failures — user might fix and retry
        return 1
    fi

    # Cache check
    local cache_dir="$CC_CACHE_DIR/image-validated"
    local cache_key="${image_id//[^a-zA-Z0-9]/_}"
    local cache_file="$cache_dir/$cache_key"

    if [[ -f "$cache_file" ]]; then
        # Cache hit — image ID unchanged
        cat "$cache_file"
        # Check if cached result was a failure
        grep -q "^fail:" "$cache_file" && return 1
        return 0
    fi

    # Cache miss — one docker run checks all binaries
    cc_note "Validating image (first launch)..." >&2
    local result
    result=$(docker run --rm --entrypoint sh "$image" -c '
        for cmd in gosu git claude bash python3 sudo docker; do
            if command -v "$cmd" >/dev/null 2>&1; then
                echo "$cmd:ok"
            else
                echo "$cmd:missing"
            fi
        done
        # Functional test: gosu can actually drop privileges
        if command -v gosu >/dev/null 2>&1; then
            gosu nobody true 2>/dev/null && echo "gosu_test:ok" || echo "gosu_test:fail"
        fi
    ' 2>/dev/null) || {
        echo "fail:cannot run image: $image"
        return 1
    }

    # Parse results
    local has_failure=false
    local output=""
    while IFS=: read -r _cmd _st; do
        [[ -z "$_cmd" ]] && continue
        case "$_cmd" in
            gosu|git|claude|bash|gosu_test)
                if [[ "$_st" != "ok" ]]; then
                    output+="fail:$_cmd"$'\n'
                    has_failure=true
                else
                    output+="ok:$_cmd"$'\n'
                fi
                ;;
            python3|sudo|docker)
                if [[ "$_st" != "ok" ]]; then
                    output+="warn:$_cmd"$'\n'
                else
                    output+="ok:$_cmd"$'\n'
                fi
                ;;
        esac
    done <<< "$result" || true

    # Cache the result (only cache successes — failures might be fixed)
    if ! $has_failure; then
        mkdir -p "$cache_dir"
        echo "$output" > "$cache_file"
    fi

    echo -n "$output"
    $has_failure && return 1
    return 0
}

# ============================================================================
# Contract: Container is safe to resume
# ============================================================================
# Pure inspect — zero container runs. Checks 5 conditions.
#
# READS: Docker container metadata (inspect)
# WRITES: nothing
# DESTROYS: nothing
contract_container() {
    local container="$1"
    local expected_image="$2"
    local expected_script_dir="$3"
    local continue_session="${4:-false}"

    local failures=()

    # Check 1: image ID matches (catches rebuilds with same name)
    local ctr_image_id cur_image_id
    ctr_image_id=$(docker inspect --format '{{.Image}}' "$container" 2>/dev/null || echo "")
    cur_image_id=$(docker inspect --format '{{.Id}}' "$expected_image" 2>/dev/null || echo "")
    if [[ -n "$ctr_image_id" && -n "$cur_image_id" && "$ctr_image_id" != "$cur_image_id" ]]; then
        failures+=("image rebuilt (container: ${ctr_image_id:7:12}, current: ${cur_image_id:7:12})")
    fi

    # Check 2: image name matches
    local ctr_image_name
    ctr_image_name=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || echo "")
    if [[ -n "$ctr_image_name" && "$ctr_image_name" != "$expected_image" ]]; then
        failures+=("image name: $ctr_image_name → $expected_image")
    fi

    # Check 3: entrypoint mount path matches
    local ctr_ep
    ctr_ep=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/usr/local/bin/cc-entrypoint"}}{{.Source}}{{end}}{{end}}' "$container" 2>/dev/null || echo "")
    local expected_ep="$expected_script_dir/lib/container/entrypoint.sh"
    if [[ -n "$ctr_ep" && "$ctr_ep" != "$expected_ep" ]]; then
        failures+=("entrypoint: $ctr_ep → $expected_ep")
    fi

    # Check 4: container user is root
    local ctr_user
    ctr_user=$(docker inspect --format '{{.Config.User}}' "$container" 2>/dev/null || echo "")
    if [[ "$ctr_user" != "0:0" && "$ctr_user" != "0" && "$ctr_user" != "root" && -z "$ctr_user" ]]; then
        failures+=("user: '$ctr_user' (needs root for entrypoint)")
    fi

    # Check 5: stale CONTINUE_SESSION env
    local ctr_env
    ctr_env=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null || true)
    if echo "$ctr_env" | grep -q "^CONTINUE_SESSION=1$" && [[ "$continue_session" != "true" ]]; then
        failures+=("stale env: CONTINUE_SESSION=1 baked in")
    fi

    if [[ ${#failures[@]} -gt 0 ]]; then
        printf 'fail:%s\n' "${failures[@]}"
        return 1
    fi

    echo "ok"
    return 0
}

# ============================================================================
# Contract: Token mount is valid
# ============================================================================
# Host-side only — no container runs. Checks for directory-instead-of-file corruption.
#
# READS: host filesystem (cache dir), container mounts (inspect)
# WRITES: nothing
# DESTROYS: nothing
contract_token_mount() {
    local container="$1"

    local mounts
    mounts=$(docker inspect --format '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$container" 2>/dev/null || true)

    while IFS='|' read -r src dst; do
        [[ -z "$src" ]] && continue
        if [[ "$src" == *"/token-"* && -d "$src" ]]; then
            echo "fail:corrupted mount: $src is a directory (expected file)"
            return 1
        fi
        if [[ "$src" == *"/token-"* && ! -f "$src" ]]; then
            echo "fail:token file missing: $src"
            return 1
        fi
    done <<< "$mounts" || true

    echo "ok"
    return 0
}

# ============================================================================
# Contract: Session volume has required structure
# ============================================================================
# One docker run to check volume contents.
#
# READS: Docker volume
# WRITES: nothing
# DESTROYS: nothing
contract_session_volume() {
    local volume="$1"

    docker volume inspect "$volume" &>/dev/null || {
        echo "fail:volume does not exist: $volume"
        return 1
    }

    local result
    result=$(docker run --rm --entrypoint sh -v "$volume:/session:ro" "${CC_GIT_IMAGE}" -c '
        [ -f /session/.claude-projects.yml ] && echo "config:ok" || echo "config:missing"
        repos=0
        for d in /session/*/ /session/*/*/; do
            [ -d "$d/.git" ] && repos=$((repos+1))
        done
        echo "repos:$repos"
        [ -f /session/.main-project ] && echo "main_project:$(cat /session/.main-project)" || echo "main_project:unset"
    ' 2>/dev/null) || {
        echo "fail:cannot read volume: $volume"
        return 1
    }

    local failures=()
    echo "$result" | grep -q "config:missing" && failures+=("missing .claude-projects.yml")

    local repo_count
    repo_count=$(echo "$result" | grep "repos:" | cut -d: -f2)
    [[ "${repo_count:-0}" -eq 0 ]] && failures+=("no git repos in volume")

    if [[ ${#failures[@]} -gt 0 ]]; then
        printf 'fail:%s\n' "${failures[@]}"
        # Also output the raw data for callers that need it
        echo "$result"
        return 1
    fi

    echo "$result"
    return 0
}

# ============================================================================
# Contract: Destructive operation
# ============================================================================
# Wraps any operation that destroys data. Requires confirmation or --force.
# Usage: contract_destructive "description" "detail1" "detail2" ... || return 1
#        <destructive operation here>
contract_destructive() {
    cc_confirm_destructive "$@"
}
