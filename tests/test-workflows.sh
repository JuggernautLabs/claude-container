#!/usr/bin/env bash
# High-level workflow tests for claude-container
# Run from repo root: ./tests/test-workflows.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CC="$REPO_ROOT/claude-container"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Show help early (before trap setup)
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat << 'EOF'
Usage: test-workflows.sh [test_name ...]

Run all tests or specific tests by name.

Available tests:
  branch_matching      - Session clones branch matching session name
  discover_extract     - Discover repos and extract as branches
  discover_repos       - Auto-discover git repos in directory
  extract_force        - Extract with --force updates existing branch
  from_branch          - --from flag creates session from specific branch
  help                 - --help shows usage
  multi_project        - Multi-project session creation
  session_create       - Basic session creation
  session_delete       - Session deletion with --delete
  session_extract      - Extract session as branch
  session_list         - List sessions with --sessions
  sync_branch_not_found - Sync warns when branch doesn't exist
  sync_clean           - Sync rebases cleanly without conflicts
  sync_conflicts       - Sync detects and reports conflicts
  sync_multi           - Sync works with multiple projects
  sync_uncommitted     - Sync warns about uncommitted changes

Examples:
  ./test-workflows.sh                    # Run all tests
  ./test-workflows.sh sync_clean         # Run only sync_clean test
  ./test-workflows.sh extract_force sync_clean  # Run multiple tests
EOF
    exit 0
fi

# Test state
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_REPOS=()
TEST_SESSIONS=()

# Cleanup on exit
cleanup() {
    echo ""
    echo "=== Cleanup ==="

    # Remove test sessions
    for session in "${TEST_SESSIONS[@]}"; do
        echo "Removing session: $session"
        docker volume rm "claude-session-$session" 2>/dev/null || true
        docker volume rm "claude-state-$session" 2>/dev/null || true
        docker volume rm "claude-cargo-$session" 2>/dev/null || true
        docker volume rm "claude-npm-$session" 2>/dev/null || true
        docker volume rm "claude-pip-$session" 2>/dev/null || true
    done

    # Remove test repos
    for repo in "${TEST_REPOS[@]}"; do
        echo "Removing test repo: $repo"
        rm -rf "$repo"
    done

    echo ""
    echo "=== Test Results ==="
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    echo "Total:  $TESTS_RUN"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}
trap cleanup EXIT

# Test helpers
pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "  ${RED}✗${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

run_test() {
    local name="$1"
    local func="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo -e "${YELLOW}[$TESTS_RUN] $name${NC}"

    if $func; then
        pass "$name"
    else
        fail "$name"
    fi
}

# Create a test git repo (in home dir, not /tmp - Docker on macOS can't mount /tmp)
create_test_repo() {
    local name="$1"
    local path="$HOME/.cache/claude-container-tests/test-cc-$name-$$"
    mkdir -p "$(dirname "$path")"

    mkdir -p "$path"
    cd "$path"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "# Test repo: $name" > README.md
    git add README.md
    git commit -q -m "Initial commit"

    TEST_REPOS+=("$path")
    echo "$path"
}

# ============================================================================
# Tests
# ============================================================================

test_session_create() {
    local repo=$(create_test_repo "create")
    local session="test-create-$$"
    TEST_SESSIONS+=("$session")

    cd "$repo"

    # Create session
    if ! $CC -s "$session" --no-run 2>&1; then
        echo "Failed to create session"
        return 1
    fi

    # Verify volume exists
    if ! docker volume inspect "claude-session-$session" &>/dev/null; then
        echo "Session volume not found"
        return 1
    fi

    return 0
}

test_session_extract() {
    local repo=$(create_test_repo "extract")
    local session="test-extract-$$"
    TEST_SESSIONS+=("$session")

    cd "$repo" || return 1

    # Create session
    $CC -s "$session" --no-run >/dev/null 2>&1 || {
        echo "Failed to create session"
        return 1
    }

    # Get project name (basename of repo)
    local proj_name=$(basename "$repo")

    # Add a commit inside the session (note: files are in /session/{project_name}/)
    docker run --rm \
        -v "claude-session-$session:/session" \
        alpine sh -c "
            apk add --quiet git
            cd /session/$proj_name
            git config --global safe.directory '*'
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'new file' > newfile.txt
            git add newfile.txt
            git commit -q -m 'Add newfile'
        " >/dev/null 2>&1 || {
        echo "Failed to add commit in session"
        return 1
    }

    # Extract session (creates branch in original repo)
    local output
    output=$($CC -s "$session" --extract --force 2>&1)
    if ! echo "$output" | grep -qi "branch\|created"; then
        echo "Extract output missing expected text"
        echo "Output was: $output"
        return 1
    fi

    # Verify branch exists in original repo
    if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$session" 2>/dev/null; then
        echo "Branch $session not found in original repo"
        return 1
    fi

    return 0
}

test_session_extract_force_overwrites() {
    local repo=$(create_test_repo "extract-force")
    local session="test-extract-force-$$"
    TEST_SESSIONS+=("$session")

    cd "$repo"

    # Create session
    $CC -s "$session" --no-run >/dev/null 2>&1

    # Get project name
    local proj_name=$(basename "$repo")
    local git_image="ghcr.io/hypermemetic/claude-container:latest"

    # Add a commit in session first (so extraction has something to create)
    docker run --rm \
        -v "claude-session-$session:/session" \
        "$git_image" \
        sh -c "
            set -e
            cd /session/$proj_name
            git config --global safe.directory '*'
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'first file' > first.txt
            git add first.txt
            git commit -q -m 'Add first file'
        " >/dev/null 2>&1

    # Verify first commit exists in session (check file exists)
    if ! docker run --rm -v "claude-session-$session:/session:ro" "$git_image" \
        test -f "/session/$proj_name/first.txt" 2>/dev/null; then
        echo "First file not created in session"
        return 1
    fi

    # Extract once (creates branch)
    $CC -s "$session" --extract >/dev/null 2>&1

    # Verify branch exists
    if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$session" 2>/dev/null; then
        echo "Branch not created on first extract"
        return 1
    fi

    # Add another commit in session
    docker run --rm \
        -v "claude-session-$session:/session" \
        "$git_image" \
        sh -c "
            set -e
            cd /session/$proj_name
            git config --global safe.directory '*'
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'second file' > second.txt
            git add second.txt
            git commit -q -m 'Add second file'
        " >/dev/null 2>&1

    # Verify second file exists in session before extracting
    if ! docker run --rm -v "claude-session-$session:/session:ro" "$git_image" \
        test -f "/session/$proj_name/second.txt" 2>/dev/null; then
        echo "Second file not created in session"
        return 1
    fi

    # Extract again with --force (should update branch)
    $CC -s "$session" --extract --force >/dev/null 2>&1

    # Verify branch has new commit
    local branch_log
    branch_log=$(git -C "$repo" log "$session" --oneline 2>&1)
    if ! echo "$branch_log" | grep -q "Add second file"; then
        echo "Branch was not updated with second commit"
        echo "Branch log:"
        echo "$branch_log"
        return 1
    fi

    return 0
}

test_session_delete() {
    local repo=$(create_test_repo "delete")
    local session="test-delete-$$"
    # Don't add to TEST_SESSIONS since we're deleting it ourselves

    cd "$repo"

    # Create session
    $CC -s "$session" --no-run >/dev/null 2>&1

    # Verify exists
    if ! docker volume inspect "claude-session-$session" &>/dev/null; then
        echo "Session not created"
        return 1
    fi

    # Delete session
    $CC -s "$session" --delete --yes >/dev/null 2>&1

    # Verify deleted
    if docker volume inspect "claude-session-$session" &>/dev/null; then
        echo "Session not deleted"
        return 1
    fi

    return 0
}

test_session_list() {
    local repo=$(create_test_repo "list")
    local session="test-list-$$"
    TEST_SESSIONS+=("$session")

    cd "$repo"

    # Create session
    $CC -s "$session" --no-run >/dev/null 2>&1

    # List sessions should include our session (session name appears in the table)
    local output
    output=$($CC --sessions 2>&1)
    if ! echo "$output" | grep -q "test-list"; then
        echo "Session not in list"
        echo "Output: $output"
        return 1
    fi

    return 0
}

test_multi_project_create() {
    local repo1=$(create_test_repo "multi1")
    local repo2=$(create_test_repo "multi2")
    local session="test-multi-$$"
    TEST_SESSIONS+=("$session")

    # Create config file
    local config_dir=$(dirname "$repo1")
    cat > "$config_dir/.claude-projects.yml" << EOF
version: "1"
projects:
  project1:
    path: $repo1
  project2:
    path: $repo2
EOF

    cd "$config_dir"

    # Create multi-project session (look for "Multi-project" or "2 projects")
    local output
    output=$($CC -s "$session" --no-run -C "$config_dir/.claude-projects.yml" 2>&1)
    if ! echo "$output" | grep -qi "multi-project\|2 projects\|session created"; then
        echo "Multi-project session not created"
        echo "Output: $output"
        rm -f "$config_dir/.claude-projects.yml"
        return 1
    fi

    rm -f "$config_dir/.claude-projects.yml"

    # Verify both projects in session
    local files
    files=$(docker run --rm -v "claude-session-$session:/session:ro" alpine ls /session 2>/dev/null)

    if ! echo "$files" | grep -q "project1"; then
        echo "project1 not in session"
        return 1
    fi

    if ! echo "$files" | grep -q "project2"; then
        echo "project2 not in session"
        return 1
    fi

    return 0
}

test_discover_repos() {
    local base_dir="$HOME/.cache/claude-container-tests/discover-$$"
    mkdir -p "$base_dir"
    TEST_REPOS+=("$base_dir")

    # Create multiple repos in directory
    for name in repo-a repo-b repo-c; do
        mkdir -p "$base_dir/$name"
        cd "$base_dir/$name"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "# $name" > README.md
        git add README.md
        git commit -q -m "Initial"
    done

    local session="test-discover-$$"
    TEST_SESSIONS+=("$session")

    # Discover repos (look for "3" or "Discovered" or repo names)
    local output
    output=$($CC -s "$session" --no-run --discover-repos "$base_dir" 2>&1)
    if ! echo "$output" | grep -qi "discovered\|3 repo\|repo-a\|repo-b\|repo-c"; then
        echo "Didn't discover repos"
        echo "Output: $output"
        return 1
    fi

    return 0
}

test_branch_matching() {
    local repo=$(create_test_repo "branch")
    local session="feature-branch-$$"
    TEST_SESSIONS+=("$session")

    cd "$repo"

    # Create a branch matching session name
    git checkout -b "$session"
    echo "feature content" > feature.txt
    git add feature.txt
    git commit -q -m "Feature commit"
    git checkout -q master

    # Create session - should clone the matching branch
    $CC -s "$session" --no-run >/dev/null 2>&1

    # Get project name
    local proj_name=$(basename "$repo")

    # Verify session has feature.txt (note: file is in /session/{project_name}/)
    if ! docker run --rm -v "claude-session-$session:/session:ro" alpine test -f "/session/$proj_name/feature.txt"; then
        echo "Branch content not found at /session/$proj_name/feature.txt"
        docker run --rm -v "claude-session-$session:/session:ro" alpine find /session -type f 2>/dev/null
        return 1
    fi

    return 0
}

test_help_command() {
    # --help should show usage information
    if ! $CC --help 2>&1 | grep -qi "usage\|options\|session"; then
        echo "Help not showing usage"
        return 1
    fi

    return 0
}

test_discover_repos_extract() {
    # Test that we can extract a discover-repos (multi-project) session
    local base_dir="$HOME/.cache/claude-container-tests/discover-extract-$$"
    mkdir -p "$base_dir"
    TEST_REPOS+=("$base_dir")

    # Create multiple repos in directory
    for name in proj-alpha proj-beta; do
        mkdir -p "$base_dir/$name"
        cd "$base_dir/$name"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "# $name" > README.md
        echo "content for $name" > content.txt
        git add README.md content.txt
        git commit -q -m "Initial commit for $name"
    done

    local session="test-discover-extract-$$"
    TEST_SESSIONS+=("$session")

    # Create discover-repos session
    $CC -s "$session" --no-run --discover-repos "$base_dir" >/dev/null 2>&1 || {
        echo "Failed to create discover-repos session"
        return 1
    }

    # Add a commit to proj-alpha in session
    local parent_name=$(basename "$base_dir")
    docker run --rm \
        -v "claude-session-$session:/session" \
        alpine sh -c "
            apk add --quiet git
            cd /session/$parent_name/proj-alpha
            git config --global safe.directory '*'
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'session change' > session.txt
            git add session.txt
            git commit -q -m 'Session commit to proj-alpha'
        " >/dev/null 2>&1 || {
        echo "Failed to add commit in session"
        return 1
    }

    # Extract the session (creates branches in original repos)
    local output
    output=$($CC -s "$session" --extract --force 2>&1)
    if ! echo "$output" | grep -qi "branch\|created"; then
        echo "Extract failed"
        echo "Output: $output"
        return 1
    fi

    # Verify branch was created in proj-alpha
    if ! git -C "$base_dir/proj-alpha" show-ref --verify --quiet "refs/heads/$session" 2>/dev/null; then
        echo "Branch not created in proj-alpha"
        return 1
    fi

    return 0
}

# ============================================================================
# Sync tests
# ============================================================================

test_sync_clean_rebase() {
    # Test that --sync rebases cleanly when there are no conflicts
    local base_dir="$HOME/.cache/claude-container-tests/sync-clean-$$"
    mkdir -p "$base_dir"
    TEST_REPOS+=("$base_dir")

    # Create a repo with main branch
    mkdir -p "$base_dir/myrepo"
    cd "$base_dir/myrepo"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "# Original" > README.md
    git add README.md
    git commit -q -m "Initial commit"

    local session="test-sync-clean-$$"
    TEST_SESSIONS+=("$session")

    # Create config file
    cat > "$base_dir/.claude-projects.yml" << EOF
version: "1"
projects:
  myrepo:
    path: $base_dir/myrepo
EOF

    cd "$base_dir"

    # Create session
    $CC -s "$session" --no-run -C "$base_dir/.claude-projects.yml" >/dev/null 2>&1 || {
        echo "Failed to create session"
        return 1
    }

    # Add a commit in the session (to different file)
    docker run --rm \
        -v "claude-session-$session:/session" \
        alpine sh -c "
            apk add --quiet git
            cd /session/myrepo
            git config --global safe.directory '*'
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'session work' > session-file.txt
            git add session-file.txt
            git commit -q -m 'Session commit'
        " >/dev/null 2>&1 || {
        echo "Failed to add session commit"
        return 1
    }

    # Add a commit to the original repo (different file, no conflict)
    cd "$base_dir/myrepo"
    echo "upstream change" > upstream-file.txt
    git add upstream-file.txt
    git commit -q -m "Upstream commit"

    # Run sync
    cd "$base_dir"
    local output
    output=$($CC -s "$session" --sync master --no-run 2>&1) || true

    # Check for success message
    if ! echo "$output" | grep -qi "rebased successfully\|up to date"; then
        echo "Sync didn't report success"
        echo "Output: $output"
        return 1
    fi

    # Verify session now has both commits
    local session_log
    session_log=$(docker run --rm \
        -v "claude-session-$session:/session:ro" \
        alpine sh -c "
            apk add --quiet git
            cd /session/myrepo
            git config --global safe.directory '*'
            git log --oneline
        " 2>/dev/null)

    if ! echo "$session_log" | grep -q "Upstream commit"; then
        echo "Upstream commit not in session"
        echo "Log: $session_log"
        return 1
    fi

    if ! echo "$session_log" | grep -q "Session commit"; then
        echo "Session commit lost after rebase"
        echo "Log: $session_log"
        return 1
    fi

    return 0
}

test_sync_with_conflicts() {
    # Test that --sync detects conflicts and reports them
    local base_dir="$HOME/.cache/claude-container-tests/sync-conflict-$$"
    mkdir -p "$base_dir"
    TEST_REPOS+=("$base_dir")

    # Create a repo
    mkdir -p "$base_dir/conflictrepo"
    cd "$base_dir/conflictrepo"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "original content" > conflict.txt
    git add conflict.txt
    git commit -q -m "Initial commit"

    local session="test-sync-conflict-$$"
    TEST_SESSIONS+=("$session")

    # Create config
    cat > "$base_dir/.claude-projects.yml" << EOF
version: "1"
projects:
  conflictrepo:
    path: $base_dir/conflictrepo
EOF

    cd "$base_dir"

    # Create session
    $CC -s "$session" --no-run -C "$base_dir/.claude-projects.yml" >/dev/null 2>&1

    # Modify same file in session
    docker run --rm \
        -v "claude-session-$session:/session" \
        alpine sh -c "
            apk add --quiet git
            cd /session/conflictrepo
            git config --global safe.directory '*'
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'session version' > conflict.txt
            git add conflict.txt
            git commit -q -m 'Session changes conflict.txt'
        " >/dev/null 2>&1

    # Modify same file in original (creates conflict)
    cd "$base_dir/conflictrepo"
    echo "upstream version" > conflict.txt
    git add conflict.txt
    git commit -q -m "Upstream changes conflict.txt"

    # Run sync
    cd "$base_dir"
    local output
    output=$($CC -s "$session" --sync master --no-run 2>&1) || true

    # Should report conflicts
    if ! echo "$output" | grep -qi "conflict"; then
        echo "Sync didn't detect conflicts"
        echo "Output: $output"
        return 1
    fi

    return 0
}

test_sync_multi_project() {
    # Test sync with multiple projects (some with changes, some without)
    local base_dir="$HOME/.cache/claude-container-tests/sync-multi-$$"
    mkdir -p "$base_dir"
    TEST_REPOS+=("$base_dir")

    # Create two repos
    for name in proj-a proj-b; do
        mkdir -p "$base_dir/$name"
        cd "$base_dir/$name"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "# $name" > README.md
        git add README.md
        git commit -q -m "Initial $name"
    done

    local session="test-sync-multi-$$"
    TEST_SESSIONS+=("$session")

    # Create config
    cat > "$base_dir/.claude-projects.yml" << EOF
version: "1"
projects:
  proj-a:
    path: $base_dir/proj-a
  proj-b:
    path: $base_dir/proj-b
EOF

    cd "$base_dir"

    # Create session
    $CC -s "$session" --no-run -C "$base_dir/.claude-projects.yml" >/dev/null 2>&1

    # Add commit to proj-a in session
    docker run --rm \
        -v "claude-session-$session:/session" \
        alpine sh -c "
            apk add --quiet git
            cd /session/proj-a
            git config --global safe.directory '*'
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'session a' > session-a.txt
            git add session-a.txt
            git commit -q -m 'Session commit to proj-a'
        " >/dev/null 2>&1

    # Add upstream commit to proj-a only
    cd "$base_dir/proj-a"
    echo "upstream a" > upstream-a.txt
    git add upstream-a.txt
    git commit -q -m "Upstream commit to proj-a"

    # Run sync
    cd "$base_dir"
    local output
    output=$($CC -s "$session" --sync master --no-run 2>&1) || true

    # Should mention both projects
    if ! echo "$output" | grep -q "proj-a"; then
        echo "proj-a not mentioned"
        echo "Output: $output"
        return 1
    fi

    if ! echo "$output" | grep -q "proj-b"; then
        echo "proj-b not mentioned"
        echo "Output: $output"
        return 1
    fi

    return 0
}

test_from_branch() {
    # Test --from flag creates session from specific branch
    local repo=$(create_test_repo "from-branch")
    local session="test-from-$$"
    TEST_SESSIONS+=("$session")

    cd "$repo"

    # Create a feature branch with unique content
    git checkout -b feature-xyz
    echo "feature xyz content" > feature-xyz.txt
    git add feature-xyz.txt
    git commit -q -m "Feature XYZ commit"
    git checkout -q master

    # Create session from feature branch (not matching session name)
    $CC -s "$session" --from feature-xyz --no-run >/dev/null 2>&1 || {
        echo "Failed to create session with --from"
        return 1
    }

    # Get project name
    local proj_name=$(basename "$repo")

    # Verify session has feature content
    if ! docker run --rm -v "claude-session-$session:/session:ro" alpine test -f "/session/$proj_name/feature-xyz.txt" 2>/dev/null; then
        echo "Feature branch content not found"
        docker run --rm -v "claude-session-$session:/session:ro" alpine find /session -type f 2>/dev/null
        return 1
    fi

    return 0
}

test_sync_uncommitted_changes() {
    # Test that --sync warns about uncommitted changes (not "up to date")
    local base_dir="$HOME/.cache/claude-container-tests/sync-uncommitted-$$"
    mkdir -p "$base_dir"
    TEST_REPOS+=("$base_dir")

    # Create a repo
    mkdir -p "$base_dir/dirtyrepo"
    cd "$base_dir/dirtyrepo"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "original" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"

    local session="test-sync-uncommitted-$$"
    TEST_SESSIONS+=("$session")

    # Create config
    cat > "$base_dir/.claude-projects.yml" << EOF
version: "1"
projects:
  dirtyrepo:
    path: $base_dir/dirtyrepo
EOF

    cd "$base_dir"

    # Create session
    $CC -s "$session" --no-run -C "$base_dir/.claude-projects.yml" >/dev/null 2>&1

    # Make UNCOMMITTED changes in the session (no commit!)
    docker run --rm \
        -v "claude-session-$session:/session" \
        alpine sh -c "
            echo 'uncommitted work' > /session/dirtyrepo/uncommitted.txt
        " >/dev/null 2>&1

    # Run sync - should NOT say "already up to date"
    # Should warn about uncommitted changes but still start session
    local output
    output=$($CC -s "$session" --sync master --no-run 2>&1) || true

    # The bug: currently reports "already up to date" which is misleading
    # Expected: should warn about uncommitted/unstaged changes
    if echo "$output" | grep -qi "up to date"; then
        echo "BUG: Reported 'up to date' despite uncommitted changes"
        echo "Output: $output"
        return 1
    fi

    if ! echo "$output" | grep -qi "uncommitted\|unstaged\|dirty\|local changes"; then
        echo "Should warn about uncommitted changes"
        echo "Output: $output"
        return 1
    fi

    # Should still proceed to start container (session continues despite dirty state)
    if ! echo "$output" | grep -qi "starting container\|review"; then
        echo "Should still start container for review"
        echo "Output: $output"
        return 1
    fi

    return 0
}

test_sync_branch_not_found() {
    # Test that sync reports error when branch doesn't exist
    local base_dir="$HOME/.cache/claude-container-tests/sync-nobranch-$$"
    mkdir -p "$base_dir"
    TEST_REPOS+=("$base_dir")

    mkdir -p "$base_dir/myrepo"
    cd "$base_dir/myrepo"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "content" > file.txt
    git add file.txt
    git commit -q -m "Initial"

    local session="test-sync-nobranch-$$"
    TEST_SESSIONS+=("$session")

    cat > "$base_dir/.claude-projects.yml" << EOF
version: "1"
projects:
  myrepo:
    path: $base_dir/myrepo
EOF

    cd "$base_dir"
    $CC -s "$session" --no-run -C "$base_dir/.claude-projects.yml" >/dev/null 2>&1

    # Try to sync to non-existent branch
    local output
    output=$($CC -s "$session" --sync nonexistent-branch --no-run 2>&1) || true

    # Should skip or warn about missing branch
    if ! echo "$output" | grep -qi "not found\|skipping"; then
        echo "Should warn about missing branch"
        echo "Output: $output"
        return 1
    fi

    return 0
}

# ============================================================================
# Run tests
# ============================================================================

# All available tests
declare -A ALL_TESTS=(
    ["session_create"]="test_session_create"
    ["session_extract"]="test_session_extract"
    ["extract_force"]="test_session_extract_force_overwrites"
    ["session_delete"]="test_session_delete"
    ["session_list"]="test_session_list"
    ["multi_project"]="test_multi_project_create"
    ["discover_repos"]="test_discover_repos"
    ["branch_matching"]="test_branch_matching"
    ["help"]="test_help_command"
    ["discover_extract"]="test_discover_repos_extract"
    ["sync_clean"]="test_sync_clean_rebase"
    ["sync_conflicts"]="test_sync_with_conflicts"
    ["sync_multi"]="test_sync_multi_project"
    ["from_branch"]="test_from_branch"
    ["sync_branch_not_found"]="test_sync_branch_not_found"
    ["sync_uncommitted"]="test_sync_uncommitted_changes"
)

echo "=== claude-container Workflow Tests ==="
echo "Repository: $REPO_ROOT"
echo ""

# If specific tests requested, run only those
if [[ $# -gt 0 ]]; then
    for test_name in "$@"; do
        if [[ -z "${ALL_TESTS[$test_name]:-}" ]]; then
            echo "Unknown test: $test_name"
            echo "Run '$0 --help' to see available tests"
            exit 1
        fi
        run_test "$test_name" "${ALL_TESTS[$test_name]}"
    done
else
    # Run all tests
    # Basic tests
    run_test "Session creation" test_session_create
    run_test "Session extraction" test_session_extract
    run_test "Extract --force overwrites" test_session_extract_force_overwrites
    run_test "Session deletion" test_session_delete
    run_test "Session listing" test_session_list

    # Multi-project
    run_test "Multi-project session creation" test_multi_project_create
    run_test "Discover repos" test_discover_repos

    # Branch handling
    run_test "Branch name matching" test_branch_matching

    # Help
    run_test "Help command" test_help_command

    # Discover repos extraction
    run_test "Discover repos extraction" test_discover_repos_extract

    # Sync tests
    run_test "Sync clean rebase" test_sync_clean_rebase
    run_test "Sync with conflicts" test_sync_with_conflicts
    run_test "Sync multi-project" test_sync_multi_project
    run_test "From branch flag" test_from_branch
    run_test "Sync branch not found" test_sync_branch_not_found
    run_test "Sync uncommitted changes" test_sync_uncommitted_changes
fi
