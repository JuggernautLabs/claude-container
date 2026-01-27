#!/usr/bin/env bash
# claude-container utilities - logging and UI helpers
# Source this file: source "$(dirname "$0")/lib/utils.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; }

# Check if a directory is a git repository (handles both regular repos and worktrees)
# Regular repo: .git is a directory
# Worktree: .git is a file containing "gitdir: /path/to/main/.git/worktrees/name"
is_git_repo() {
    local path="$1"
    [[ -d "$path/.git" ]] || [[ -f "$path/.git" ]]
}

# Check if a git repo is a worktree
# Returns 0 if worktree, 1 if regular repo
is_git_worktree() {
    local path="$1"
    [[ -f "$path/.git" ]]
}

# Get the main repo path for a worktree
# For worktrees, parses .git file to find main repo
# For regular repos, returns the path as-is
# Arguments:
#   $1 - path to repo or worktree
# Returns:
#   Main repo path (stdout)
get_main_repo_path() {
    local path="$1"

    if [[ -f "$path/.git" ]]; then
        # Worktree: parse gitdir line to find main repo
        # Format: gitdir: /path/to/main/.git/worktrees/name
        local gitdir
        gitdir=$(grep "^gitdir:" "$path/.git" | cut -d' ' -f2)
        # Remove /worktrees/name suffix to get main .git, then remove /.git
        echo "${gitdir%/.git/worktrees/*}"
    else
        # Regular repo
        echo "$path"
    fi
}

# Get the current branch of a git repo or worktree
# Arguments:
#   $1 - path to repo or worktree
# Returns:
#   Branch name (stdout)
get_git_branch() {
    local path="$1"
    git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Find worktree path for a given branch
# Arguments:
#   $1 - path to main repo
#   $2 - branch name
# Returns:
#   Worktree path (stdout) if found, empty otherwise
find_worktree_for_branch() {
    local repo_path="$1"
    local branch="$2"

    # Get the main repo path (in case we're given a worktree)
    local main_repo
    main_repo=$(get_main_repo_path "$repo_path")

    # List worktrees and find one on the target branch
    git -C "$main_repo" worktree list --porcelain 2>/dev/null | while read -r line; do
        if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
            local wt_path="${BASH_REMATCH[1]}"
            # Read next lines for branch info
            read -r head_line || true
            read -r branch_line || true
            if [[ "$branch_line" =~ ^branch\ refs/heads/(.+)$ ]]; then
                local wt_branch="${BASH_REMATCH[1]}"
                if [[ "$wt_branch" == "$branch" ]]; then
                    echo "$wt_path"
                    return 0
                fi
            fi
        fi
    done
}

# Spinner for long operations
spin() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid &>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}
