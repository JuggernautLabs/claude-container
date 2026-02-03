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
        rm -rf "$HOME/.config/claude-container/worktrees/$session" 2>/dev/null || true
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

    # Add a commit inside the session
    docker run --rm \
        -v "claude-session-$session:/session" \
        alpine sh -c "
            apk add --quiet git
            cd /session
            git config --global safe.directory '*'
            echo 'new file' > newfile.txt
            git add newfile.txt
            git commit -q -m 'Add newfile'
        " >/dev/null 2>&1 || {
        echo "Failed to add commit in session"
        return 1
    }

    # Extract session
    local output
    output=$($CC --extract-session "$session" --force 2>&1)
    if ! echo "$output" | grep -qi "extracted"; then
        echo "Extract output missing 'extracted'"
        echo "Output was: $output"
        return 1
    fi

    # Verify worktree exists with new file
    local worktree="$HOME/.config/claude-container/worktrees/$session"
    if [[ ! -f "$worktree/newfile.txt" ]]; then
        echo "Extracted file not found at $worktree/newfile.txt"
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

    # Extract once
    $CC --extract-session "$session" >/dev/null 2>&1

    # Create a marker file in worktree
    local worktree="$HOME/.config/claude-container/worktrees/$session"
    echo "marker" > "$worktree/marker.txt"

    # Extract again with --force
    $CC --extract-session "$session" --force >/dev/null 2>&1

    # Marker should be gone (worktree was replaced)
    if [[ -f "$worktree/marker.txt" ]]; then
        echo "Worktree was not replaced"
        return 1
    fi

    return 0
}

test_worktree_cleanup() {
    local repo=$(create_test_repo "cleanup")
    local session="test-cleanup-$$"
    TEST_SESSIONS+=("$session")

    cd "$repo"

    # Create and extract session
    $CC -s "$session" --no-run >/dev/null 2>&1
    $CC --extract-session "$session" >/dev/null 2>&1

    local worktree="$HOME/.config/claude-container/worktrees/$session"

    # Verify worktree exists
    if [[ ! -d "$worktree" ]]; then
        echo "Worktree not created"
        return 1
    fi

    # Cleanup worktree
    $CC --cleanup-worktree "$session" --yes >/dev/null 2>&1

    # Verify worktree removed
    if [[ -d "$worktree" ]]; then
        echo "Worktree not removed"
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
    $CC --delete-session "$session" --yes >/dev/null 2>&1

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

test_diff_session() {
    local repo=$(create_test_repo "diff")
    local session="test-diff-$$"
    TEST_SESSIONS+=("$session")

    cd "$repo"

    # Create session
    $CC -s "$session" --no-run >/dev/null 2>&1

    # Add a commit inside the session
    docker run --rm \
        -v "claude-session-$session:/session" \
        alpine sh -c "
            apk add --quiet git
            cd /session
            git config --global safe.directory '*'
            echo 'diff test' > difffile.txt
            git add difffile.txt
            git commit -q -m 'Add difffile for testing'
        " >/dev/null 2>&1

    # Diff should show the commit message or file
    local output
    output=$($CC --diff-session "$session" 2>&1)
    if ! echo "$output" | grep -qi "difffile\|commits"; then
        echo "Diff didn't show changes"
        echo "Output: $output"
        return 1
    fi

    return 0
}

test_merge_deprecated_redirects() {
    local repo=$(create_test_repo "merge-deprecated")
    local session="test-merge-deprecated-$$"
    TEST_SESSIONS+=("$session")

    cd "$repo"

    # Create session
    $CC -s "$session" --no-run >/dev/null 2>&1

    # --merge-session should show deprecation warning and extract
    local output
    output=$($CC --merge-session "$session" --force 2>&1)

    if ! echo "$output" | grep -q "deprecated"; then
        echo "No deprecation warning"
        return 1
    fi

    if ! echo "$output" | grep -q "Session extracted"; then
        echo "Didn't redirect to extract"
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

    # Verify session has feature.txt
    if ! docker run --rm -v "claude-session-$session:/session:ro" alpine test -f /session/feature.txt; then
        echo "Branch content not found"
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

test_dind_session() {
    # Test that we can create a session from inside a container (Docker-in-Docker)
    # Skip if no token available
    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        # Try to get token from config
        local token_file="$HOME/.config/claude-container/oauth_token"
        if [[ -f "$token_file" ]]; then
            CLAUDE_CODE_OAUTH_TOKEN=$(cat "$token_file")
        else
            echo "Skipping DinD test - no CLAUDE_CODE_OAUTH_TOKEN"
            return 0
        fi
    fi

    local repo=$(create_test_repo "dind")
    local session="test-dind-$$"
    TEST_SESSIONS+=("$session")

    # Run claude-container from inside a container with Docker socket mounted
    # Pass the oauth token via environment variable
    local output
    output=$(docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$REPO_ROOT:/cc:ro" \
        -v "$repo:/testrepo:ro" \
        -e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" \
        -w /testrepo \
        docker:cli sh -c "
            apk add --quiet bash git
            git config --global safe.directory '*'
            /cc/claude-container -s $session --no-run 2>&1
        " 2>&1)

    # Check if session was created (look for success messages)
    if ! echo "$output" | grep -qi "session created\|session ready\|Git session"; then
        echo "DinD session creation failed"
        echo "Output: $output"
        return 1
    fi

    # Verify volume exists
    if ! docker volume inspect "claude-session-$session" &>/dev/null; then
        echo "DinD session volume not found"
        return 1
    fi

    return 0
}

# ============================================================================
# Run tests
# ============================================================================

echo "=== claude-container Workflow Tests ==="
echo "Repository: $REPO_ROOT"
echo ""

# Basic tests
run_test "Session creation" test_session_create
run_test "Session extraction" test_session_extract
run_test "Extract --force overwrites" test_session_extract_force_overwrites
run_test "Worktree cleanup" test_worktree_cleanup
run_test "Session deletion" test_session_delete
run_test "Session listing" test_session_list
run_test "Diff session" test_diff_session

# Deprecated command handling
run_test "--merge-session redirects to --extract" test_merge_deprecated_redirects

# Multi-project
run_test "Multi-project session creation" test_multi_project_create
run_test "Discover repos" test_discover_repos

# Branch handling
run_test "Branch name matching" test_branch_matching

# Help
run_test "Help command" test_help_command

# Docker-in-Docker
run_test "Docker-in-Docker session creation" test_dind_session
