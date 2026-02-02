#!/usr/bin/env bash
# claude-container docker utilities - Docker wrapper functions
#
# DESCRIPTION:
#   This module provides wrapper utilities for docker run operations to consolidate
#   repeated patterns across the codebase. It handles:
#   - Volume mounting with readonly/readwrite modes
#   - Git safe.directory configuration
#   - Error redirection (2>/dev/null suppression)
#   - Image variable resolution (IMAGE_NAME with DEFAULT_IMAGE fallback)
#   - Batch operations for efficiency
#
# DEPENDENCIES:
#   - utils.sh: error/info/warn/success functions (optional, graceful degradation)
#   - Docker must be installed and accessible
#
# REQUIRED GLOBALS:
#   - IMAGE_NAME: Docker image to use for operations (optional)
#   - DEFAULT_IMAGE: Fallback image when IMAGE_NAME not set (optional)
#   Note: If both are unset, functions will fail with descriptive errors
#
# USAGE EXAMPLES:
#   # Source this file
#   source "$(dirname "$0")/lib/docker-utils.sh"
#
#   # Generic docker run
#   docker_run_in_volume "claude-session-myproject" "/session" "alpine" "ls -la" "ro"
#
#   # Git operations
#   docker_run_git "claude-session-myproject" "myrepo" "git log --oneline"
#   docker_run_git "claude-session-myproject" "" "git status"  # No project path
#
#   # Mount multiple volumes
#   volumes=("vol1" "vol2" "vol3")
#   mount_args=$(mount_all_volumes volumes[@])
#   docker run --rm $mount_args alpine ls
#
#   # Batch size retrieval
#   volume_list=$(docker volume ls -q | grep "^claude-")
#   get_volume_sizes_batch "$volume_list"
#
# AUTHOR:
#   claude-container team
#

# Source error functions if available (graceful degradation)
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/utils.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
else
    # Fallback implementations
    error() { echo "ERROR: $*" >&2; }
    warn() { echo "WARNING: $*" >&2; }
    info() { echo "INFO: $*"; }
fi

# ============================================================================
# CORE DOCKER RUN WRAPPER
# ============================================================================

# docker_run_in_volume - Generic docker run wrapper with volume mounting
#
# Provides a consistent interface for running commands inside docker containers
# with volume mounts. Handles --rm flag, volume mounting patterns, and error
# redirection.
#
# PARAMETERS:
#   $1 - volume: Docker volume name (required)
#   $2 - mount_point: Container mount point path (required, e.g., "/session")
#   $3 - image: Docker image name (required, or use ${IMAGE_NAME:-$DEFAULT_IMAGE})
#   $4 - command: Shell command to execute (required)
#   $5 - readonly: Mount mode - "ro" for readonly, "" for readwrite (optional, default "")
#
# RETURNS:
#   Command output on stdout
#   Exit code 0 on success, non-zero on failure
#
# EXAMPLE:
#   docker_run_in_volume "my-volume" "/data" "alpine" "ls -la" "ro"
#   docker_run_in_volume "my-volume" "/data" "${IMAGE_NAME:-$DEFAULT_IMAGE}" "cat file.txt"
#
docker_run_in_volume() {
    local volume="$1"
    local mount_point="$2"
    local image="$3"
    local command="$4"
    local readonly="${5:-}"

    # Validate required parameters
    if [[ -z "$volume" ]]; then
        error "docker_run_in_volume: volume parameter is required"
        return 1
    fi
    if [[ -z "$mount_point" ]]; then
        error "docker_run_in_volume: mount_point parameter is required"
        return 1
    fi
    if [[ -z "$image" ]]; then
        error "docker_run_in_volume: image parameter is required"
        return 1
    fi
    if [[ -z "$command" ]]; then
        error "docker_run_in_volume: command parameter is required"
        return 1
    fi

    # Build mount options
    local mount_opts=""
    if [[ "$readonly" == "ro" ]]; then
        mount_opts=":ro"
    fi

    # Execute docker run with error suppression
    docker run --rm \
        -v "$volume:$mount_point$mount_opts" \
        "$image" \
        sh -c "$command" 2>/dev/null
}

# ============================================================================
# GIT-SPECIFIC WRAPPER
# ============================================================================

# docker_run_git - Git-specific docker run wrapper
#
# Specialized wrapper for git operations that automatically:
# - Sets up git safe.directory configuration
# - Changes to the correct session path (with or without project subdirectory)
# - Uses IMAGE_NAME with DEFAULT_IMAGE fallback
# - Suppresses errors with 2>/dev/null
#
# PARAMETERS:
#   $1 - volume: Docker volume name (required)
#   $2 - project_path: Project subdirectory path within /session (optional, "" for root)
#   $3 - git_command: Git command to execute (required)
#   $4 - readonly: Mount mode - "ro" for readonly, "" for readwrite (optional, default "ro")
#
# RETURNS:
#   Git command output on stdout
#   Exit code 0 on success, non-zero on failure
#
# NOTES:
#   - Always configures git safe.directory as '*' for security
#   - If project_path is empty "", operates in /session root
#   - If project_path is set, operates in /session/$project_path
#   - Readonly mount is the default for safety (most git reads don't need write access)
#
# EXAMPLE:
#   # Single-project session (no subdirectory)
#   docker_run_git "claude-session-myproject" "" "git status"
#
#   # Multi-project session (with subdirectory)
#   docker_run_git "claude-session-myproject" "repo1" "git log --oneline -5"
#
#   # Write operation (commit, merge, etc)
#   docker_run_git "claude-session-myproject" "repo1" "git commit -m 'test'" ""
#
docker_run_git() {
    local volume="$1"
    local project_path="${2:-}"
    local git_command="$3"
    local readonly="${4:-ro}"

    # Validate required parameters
    if [[ -z "$volume" ]]; then
        error "docker_run_git: volume parameter is required"
        return 1
    fi
    if [[ -z "$git_command" ]]; then
        error "docker_run_git: git_command parameter is required"
        return 1
    fi

    # Resolve image with fallback
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"
    if [[ -z "$git_image" ]]; then
        error "docker_run_git: IMAGE_NAME or DEFAULT_IMAGE must be set"
        return 1
    fi

    # Build session path: /session or /session/project_path
    local session_path="/session"
    if [[ -n "$project_path" ]]; then
        session_path="/session/$project_path"
    fi

    # Build mount options
    local mount_opts=""
    if [[ "$readonly" == "ro" ]]; then
        mount_opts=":ro"
    fi

    # Execute git command with safe.directory config
    docker run --rm \
        -v "$volume:/session$mount_opts" \
        "$git_image" \
        sh -c "
            git config --global --add safe.directory '*'
            cd $session_path || exit 1
            $git_command
        " 2>/dev/null
}

# ============================================================================
# VOLUME MOUNTING UTILITIES
# ============================================================================

# mount_all_volumes - Build docker mount arguments for multiple volumes
#
# Generates mount argument strings for use in docker run commands. Useful for
# batch operations that need to access multiple volumes simultaneously.
#
# PARAMETERS:
#   $1 - volumes_array_ref: Array reference containing volume names (required)
#        Pass as: mount_all_volumes volumes[@]
#   $2 - mount_prefix: Mount point prefix (optional, default "")
#        If empty, mounts at /$volume_name
#        If set, mounts at $mount_prefix/$volume_name
#   $3 - readonly: Mount mode - "ro" for readonly, "" for readwrite (optional, default "ro")
#
# RETURNS:
#   Mount arguments string on stdout (e.g., "-v vol1:/vol1:ro -v vol2:/vol2:ro")
#   Empty string if volumes array is empty
#   Exit code 0 on success
#
# EXAMPLE:
#   volumes=("vol1" "vol2" "vol3")
#   mount_args=$(mount_all_volumes volumes[@])
#   docker run --rm $mount_args alpine sh -c 'du -sh /vol*'
#
#   # With custom mount prefix
#   mount_args=$(mount_all_volumes volumes[@] "/data" "")
#   # Produces: -v vol1:/data/vol1 -v vol2:/data/vol2 -v vol3:/data/vol3
#
mount_all_volumes() {
    local volumes_ref="$1"
    local mount_prefix="${2:-}"
    local readonly="${3}"

    # Default to "ro" only if parameter not provided at all
    if [[ $# -lt 3 ]]; then
        readonly="ro"
    fi

    if [[ -z "$volumes_ref" ]]; then
        error "mount_all_volumes: volumes_array_ref parameter is required"
        return 1
    fi

    # Strip [@] suffix if present (e.g., "volumes[@]" -> "volumes")
    volumes_ref="${volumes_ref%\[@\]}"

    # Dereference array
    local -n volumes_array="$volumes_ref"

    # Handle empty array
    if [[ ${#volumes_array[@]} -eq 0 ]]; then
        echo ""
        return 0
    fi

    # Build mount options
    local mount_opts=""
    if [[ "$readonly" == "ro" ]]; then
        mount_opts=":ro"
    fi

    # Build mount arguments
    local mount_args=""
    for vol in "${volumes_array[@]}"; do
        [[ -z "$vol" ]] && continue

        local mount_point
        if [[ -n "$mount_prefix" ]]; then
            mount_point="$mount_prefix/$vol"
        else
            mount_point="/$vol"
        fi

        mount_args="$mount_args -v $vol:$mount_point$mount_opts"
    done

    echo "$mount_args"
}

# ============================================================================
# BATCH OPERATIONS
# ============================================================================

# get_volume_sizes_batch - Get sizes for multiple volumes in one docker run
#
# Efficiently retrieves disk usage for multiple volumes by mounting them all
# in a single container and running du commands. Much faster than individual
# docker run calls per volume.
#
# PARAMETERS:
#   $1 - volume_list: Newline-separated list of volume names (required)
#        Can be piped or passed as string with embedded newlines
#
# OUTPUT FORMAT:
#   One line per volume: "volume_name|human_readable_size"
#   Example: "claude-session-test|1.2G"
#   Volumes that don't exist or are empty may show "0" or "?"
#
# RETURNS:
#   Volume size pairs on stdout (name|size per line)
#   Exit code 0 on success, non-zero on failure
#
# NOTES:
#   - Uses alpine image for minimal overhead
#   - Silently handles missing volumes (won't fail entire batch)
#   - Uses du -sh for human-readable sizes (K, M, G suffixes)
#
# EXAMPLE:
#   # Get sizes for all claude volumes
#   volume_list=$(docker volume ls -q | grep "^claude-")
#   get_volume_sizes_batch "$volume_list"
#
#   # Parse output
#   get_volume_sizes_batch "$volume_list" | while IFS='|' read -r name size; do
#       echo "Volume $name is $size"
#   done
#
get_volume_sizes_batch() {
    local volume_list="$1"

    if [[ -z "$volume_list" ]]; then
        # Empty input is not an error, just return empty
        return 0
    fi

    # Build mount arguments for all volumes
    local mount_args=""
    while read -r vol; do
        [[ -z "$vol" ]] && continue
        mount_args="$mount_args -v $vol:/$vol:ro"
    done <<< "$volume_list"

    # Handle case where all lines were empty
    if [[ -z "$mount_args" ]]; then
        return 0
    fi

    # Run single container to get all sizes
    docker run --rm $mount_args alpine sh -c '
        for dir in /claude-* /session-data-*; do
            [ -d "$dir" ] || continue
            name=$(basename "$dir")
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            size=${size:-0}
            echo "$name|$size"
        done
    ' 2>/dev/null || echo ""
}

# get_volume_sizes_batch_with_total - Get sizes for multiple volumes with total
#
# Extended version of get_volume_sizes_batch that also calculates a total size.
# Returns individual volume sizes plus a TOTAL line at the end.
#
# PARAMETERS:
#   $1 - volume_list: Newline-separated list of volume names (required)
#
# OUTPUT FORMAT:
#   One line per volume: "volume_name|human_readable_size"
#   Final line: "TOTAL|human_readable_total"
#   Example:
#     claude-session-test1|1.2G
#     claude-session-test2|500M
#     TOTAL|1.7G
#
# RETURNS:
#   Volume size pairs plus total on stdout
#   Exit code 0 on success
#
# EXAMPLE:
#   volume_list=$(docker volume ls -q | grep "^claude-")
#   get_volume_sizes_batch_with_total "$volume_list" | while IFS='|' read -r name size; do
#       if [[ "$name" == "TOTAL" ]]; then
#           echo "Total size: $size"
#       else
#           echo "  $name: $size"
#       fi
#   done
#
get_volume_sizes_batch_with_total() {
    local volume_list="$1"

    if [[ -z "$volume_list" ]]; then
        return 0
    fi

    # Build mount arguments
    local mount_args=""
    while read -r vol; do
        [[ -z "$vol" ]] && continue
        mount_args="$mount_args -v $vol:/$vol:ro"
    done <<< "$volume_list"

    if [[ -z "$mount_args" ]]; then
        return 0
    fi

    # Run container with total calculation
    docker run --rm $mount_args alpine sh -c '
        total=0
        for dir in /claude-* /session-data-*; do
            [ -d "$dir" ] || continue
            name=$(basename "$dir")
            bytes=$(du -sb "$dir" 2>/dev/null | cut -f1)
            bytes=${bytes:-0}
            human=$(du -sh "$dir" 2>/dev/null | cut -f1)
            human=${human:-0}
            total=$((total + bytes))
            echo "$name|$human"
        done
        # Output total in human readable format
        if [ $total -gt 1073741824 ]; then
            echo "TOTAL|$((total / 1073741824))G"
        elif [ $total -gt 1048576 ]; then
            echo "TOTAL|$((total / 1048576))M"
        elif [ $total -gt 1024 ]; then
            echo "TOTAL|$((total / 1024))K"
        else
            echo "TOTAL|${total}B"
        fi
    ' 2>/dev/null || echo ""
}

# ============================================================================
# VOLUME INSPECTION UTILITIES
# ============================================================================

# check_volume_exists - Check if a docker volume exists
#
# PARAMETERS:
#   $1 - volume: Volume name to check (required)
#
# RETURNS:
#   Exit code 0 if volume exists, 1 if not
#
# EXAMPLE:
#   if check_volume_exists "my-volume"; then
#       echo "Volume exists"
#   fi
#
check_volume_exists() {
    local volume="$1"

    if [[ -z "$volume" ]]; then
        error "check_volume_exists: volume parameter is required"
        return 1
    fi

    docker volume inspect "$volume" &>/dev/null
}

# get_volume_contents - List contents of a volume
#
# PARAMETERS:
#   $1 - volume: Volume name (required)
#   $2 - path: Path within volume to list (optional, default "/")
#   $3 - ls_flags: Flags to pass to ls (optional, default "-lah")
#
# RETURNS:
#   ls output on stdout
#   Exit code 0 on success
#
# EXAMPLE:
#   get_volume_contents "my-volume" "/" "-la"
#   get_volume_contents "my-volume" "/session/myproject"
#
get_volume_contents() {
    local volume="$1"
    local path="${2:-/}"
    local ls_flags="${3:--lah}"

    if [[ -z "$volume" ]]; then
        error "get_volume_contents: volume parameter is required"
        return 1
    fi

    docker run --rm \
        -v "$volume:/inspect:ro" \
        alpine \
        ls $ls_flags "/inspect$path" 2>/dev/null
}

# ============================================================================
# CONVENIENCE WRAPPERS FOR COMMON PATTERNS
# ============================================================================

# docker_run_git_readonly - Convenience wrapper for readonly git operations
#
# Simplified interface for the most common case: readonly git commands.
#
# PARAMETERS:
#   $1 - volume: Docker volume name (required)
#   $2 - project_path: Project subdirectory (optional, "" for root)
#   $3 - git_command: Git command to execute (required)
#
# EXAMPLE:
#   docker_run_git_readonly "claude-session-test" "myrepo" "git status"
#
docker_run_git_readonly() {
    docker_run_git "$1" "$2" "$3" "ro"
}

# docker_run_git_readwrite - Convenience wrapper for read-write git operations
#
# Simplified interface for git commands that modify the repository.
#
# PARAMETERS:
#   $1 - volume: Docker volume name (required)
#   $2 - project_path: Project subdirectory (optional, "" for root)
#   $3 - git_command: Git command to execute (required)
#
# EXAMPLE:
#   docker_run_git_readwrite "claude-session-test" "myrepo" "git commit -m 'update'"
#
docker_run_git_readwrite() {
    docker_run_git "$1" "$2" "$3" ""
}

# ============================================================================
# MODULE INITIALIZATION
# ============================================================================

# Validate that we're being sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    error "This file should be sourced, not executed directly."
    error "Usage: source \"$(dirname \"\$0\")/lib/docker-utils.sh\""
    exit 1
fi

# Export functions for use by callers
export -f docker_run_in_volume
export -f docker_run_git
export -f docker_run_git_readonly
export -f docker_run_git_readwrite
export -f mount_all_volumes
export -f get_volume_sizes_batch
export -f get_volume_sizes_batch_with_total
export -f check_volume_exists
export -f get_volume_contents
