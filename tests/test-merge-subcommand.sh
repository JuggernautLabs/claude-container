#!/usr/bin/env bash
# Tests for the `merge` subcommand and subcommand dispatch system
# Run from repo root: ./tests/test-merge-subcommand.sh
#
# Requires: docker, yq, git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CC="$REPO_ROOT/claude-container"
GIT_IMAGE="ghcr.io/hypermemetic/claude-container:latest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Show help early
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat << 'EOF'
Usage: test-merge-subcommand.sh [test_name ...]

Run all tests or specific tests by name.

Available tests:
  dispatch_known          - Known subcommand dispatches to handler
  dispatch_flags          - Existing flags still work (not caught by dispatch)
  dispatch_unknown        - Unknown bare word falls through to error
  merge_help              - merge --help shows usage
  merge_missing_session   - merge without -s errors
  merge_unknown_option    - merge --bogus errors
  merge_extract_merge     - Extract + auto-merge into target branch
  merge_default_branch    - Without --branch, target defaults to session name
  merge_verify_not_extracted - Verify shows not-extracted before extraction
  merge_verify_synced     - Verify shows synced after extract + merge
  merge_verify_unchanged  - Verify shows unchanged for untouched repos
  merge_verify_new_repos  - Verify discovers repos created inside session
  merge_force             - --force flag passes through to extract

Examples:
  ./test-merge-subcommand.sh                          # Run all tests
  ./test-merge-subcommand.sh merge_extract_merge      # Run one test
  ./test-merge-subcommand.sh dispatch_known merge_help # Run multiple
EOF
    exit 0
fi

# Test state
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_REPOS=()
TEST_SESSIONS=()
TEST_CMD_FILES=()

# Cleanup on exit
cleanup() {
    echo ""
    echo "=== Cleanup ==="

    for session in "${TEST_SESSIONS[@]}"; do
        echo "Removing session: $session"
        docker volume rm "claude-session-$session" 2>/dev/null || true
        docker volume rm "claude-state-$session" 2>/dev/null || true
        docker volume rm "claude-cargo-$session" 2>/dev/null || true
        docker volume rm "claude-npm-$session" 2>/dev/null || true
        docker volume rm "claude-pip-$session" 2>/dev/null || true
        # Clean up session config files
        rm -f "$HOME/.config/claude-container/sessions/${session}.yml" 2>/dev/null || true
        rm -f "$HOME/.config/claude-container/sessions/${session}.env" 2>/dev/null || true
    done

    for repo in "${TEST_REPOS[@]}"; do
        echo "Removing test repo: $repo"
        rm -rf "$repo"
    done

    for f in "${TEST_CMD_FILES[@]}"; do
        echo "Removing test command: $f"
        rm -f "$f"
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

# Pre-cleanup: remove stale test volumes from previous interrupted runs
_stale_vols=$(docker volume ls -q | grep -E '^claude-(session|state|cargo|npm|pip)-test-merge-' 2>/dev/null || true)
if [[ -n "$_stale_vols" ]]; then
    echo "Cleaning $(echo "$_stale_vols" | wc -l | tr -d ' ') stale test volume(s)..."
    echo "$_stale_vols" | xargs docker volume rm 2>/dev/null || true
fi
_stale_repos=$(find "$HOME/.cache" -maxdepth 1 -name 'claude-container-tests' -type d 2>/dev/null || true)
if [[ -n "$_stale_repos" ]]; then
    rm -rf "$HOME/.cache/claude-container-tests"
fi

# Test helpers
pass() {
    echo -e "  ${GREEN}PASS${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "  ${RED}FAIL${NC} $1"
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

# Create a test git repo (in $HOME, not /tmp — Docker on macOS can't mount /tmp)
create_test_repo() {
    local name="$1"
    local path="$HOME/.cache/claude-container-tests/test-merge-$name-$$"
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

# Set up a multi-project session with two repos and commits inside the volume
# Outputs: base_dir session_name (space separated)
setup_merge_env() {
    local tag="$1"
    local base_dir="$HOME/.cache/claude-container-tests/merge-$tag-$$"
    mkdir -p "$base_dir"

    # Create two host repos
    for name in alpha beta; do
        mkdir -p "$base_dir/$name"
        cd "$base_dir/$name"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "# $name" > README.md
        echo "original $name content" > content.txt
        git add README.md content.txt
        git commit -q -m "Initial $name commit"
    done

    local session="test-merge-$tag-$$"

    # Write config
    cat > "$base_dir/.claude-projects.yml" << EOF
version: "1"
projects:
  alpha:
    path: $base_dir/alpha
  beta:
    path: $base_dir/beta
EOF

    cd "$base_dir"

    # Create session
    $CC -s "$session" --no-run -C "$base_dir/.claude-projects.yml" >/dev/null 2>&1

    # Add commits inside the session volume (simulating Claude's work)
    docker run --rm \
        -v "claude-session-$session:/session" \
        "$GIT_IMAGE" \
        sh -c "
            git config --global safe.directory '*'
            cd /session/alpha
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'alpha session work' > session-alpha.txt
            git add session-alpha.txt
            git commit -q -m 'Session commit to alpha'

            cd /session/beta
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'beta session work' > session-beta.txt
            git add session-beta.txt
            git commit -q -m 'Session commit to beta'
        " >/dev/null 2>&1

    echo "$base_dir $session"
}


# ============================================================================
# Dispatch tests
# ============================================================================

test_dispatch_known_subcommand() {
    # A known subcommand file in lib/commands/ should be dispatched
    local cmd_file="$REPO_ROOT/lib/commands/ping.sh"
    cat > "$cmd_file" << 'CMDEOF'
cmd_ping() { echo "pong $*"; }
CMDEOF
    TEST_CMD_FILES+=("$cmd_file")

    local output
    output=$($CC ping --foo bar 2>&1) || true

    if [[ "$output" == *"pong --foo bar"* ]]; then
        return 0
    else
        echo "Expected 'pong --foo bar' in output"
        echo "Got: $output"
        return 1
    fi
}

test_dispatch_existing_flags() {
    # Flags starting with - should NOT trigger dispatch, even if a subcommand exists
    local output
    output=$($CC --help 2>&1)

    if echo "$output" | grep -qi "Usage:"; then
        return 0
    else
        echo "--help didn't show usage"
        echo "Got: $output"
        return 1
    fi
}

test_dispatch_unknown_bare_word() {
    # A bare word that doesn't match a command file should fall through to "Unknown option"
    local output
    output=$($CC notacommand 2>&1) || true

    if echo "$output" | grep -qi "Unknown option.*notacommand"; then
        return 0
    else
        echo "Expected 'Unknown option: notacommand'"
        echo "Got: $output"
        return 1
    fi
}


# ============================================================================
# Merge arg parsing tests
# ============================================================================

test_merge_help() {
    local output
    output=$($CC merge --help 2>&1)

    if echo "$output" | grep -qi "Usage.*merge" && echo "$output" | grep -qi "\-\-session" && echo "$output" | grep -qi "\-\-verify"; then
        return 0
    else
        echo "Help output incomplete"
        echo "Got: $output"
        return 1
    fi
}

test_merge_missing_session() {
    local output
    output=$($CC merge 2>&1) || true
    local rc=$?

    if [[ $rc -ne 0 ]] || echo "$output" | grep -qi "session.*required"; then
        return 0
    else
        echo "Expected error about missing session"
        echo "Got (rc=$rc): $output"
        return 1
    fi
}

test_merge_unknown_option() {
    local output
    output=$($CC merge --bogus 2>&1) || true

    if echo "$output" | grep -qi "Unknown option.*bogus"; then
        return 0
    else
        echo "Expected unknown option error"
        echo "Got: $output"
        return 1
    fi
}


# ============================================================================
# Merge functional tests
# ============================================================================

test_merge_extract_merge() {
    # Extract + auto-merge into a named target branch
    local env_out
    env_out=$(setup_merge_env "exmerge")
    local base_dir="${env_out% *}"
    local session="${env_out#* }"
    TEST_REPOS+=("$base_dir")
    TEST_SESSIONS+=("$session")

    cd "$base_dir"

    # Run: merge into master
    local output
    output=$($CC merge -s "$session" --branch master 2>&1) || true

    # Should have extracted (branch created on host)
    if ! git -C "$base_dir/alpha" show-ref --verify --quiet "refs/heads/$session" 2>/dev/null; then
        echo "Session branch not created in alpha"
        echo "Output: $output"
        return 1
    fi

    if ! git -C "$base_dir/beta" show-ref --verify --quiet "refs/heads/$session" 2>/dev/null; then
        echo "Session branch not created in beta"
        echo "Output: $output"
        return 1
    fi

    # Should have merged into master
    if ! git -C "$base_dir/alpha" merge-base --is-ancestor "$session" master 2>/dev/null; then
        echo "alpha: session not merged into master"
        echo "Output: $output"
        return 1
    fi

    if ! git -C "$base_dir/beta" merge-base --is-ancestor "$session" master 2>/dev/null; then
        echo "beta: session not merged into master"
        echo "Output: $output"
        return 1
    fi

    return 0
}

test_merge_default_branch() {
    # Without --branch, target defaults to session name (merge into self = no-op merge,
    # but extract should still work)
    local env_out
    env_out=$(setup_merge_env "defbranch")
    local base_dir="${env_out% *}"
    local session="${env_out#* }"
    TEST_REPOS+=("$base_dir")
    TEST_SESSIONS+=("$session")

    cd "$base_dir"

    # Run merge without --branch (target = session name)
    local output
    output=$($CC merge -s "$session" 2>&1) || true

    # Session branch should exist on host (extract worked)
    if ! git -C "$base_dir/alpha" show-ref --verify --quiet "refs/heads/$session" 2>/dev/null; then
        echo "Session branch not created in alpha"
        echo "Output: $output"
        return 1
    fi

    # The auto-merge target is the session name itself, so it should be "already up to date"
    if ! echo "$output" | grep -qi "up to date\|merged"; then
        echo "Expected up-to-date or merged status"
        echo "Output: $output"
        return 1
    fi

    return 0
}

test_merge_verify_not_extracted() {
    # Before extraction, --verify should report not-extracted
    local env_out
    env_out=$(setup_merge_env "vernotex")
    local base_dir="${env_out% *}"
    local session="${env_out#* }"
    TEST_REPOS+=("$base_dir")
    TEST_SESSIONS+=("$session")

    cd "$base_dir"

    # Run verify before any extraction
    local output rc=0
    output=$($CC merge -s "$session" --verify 2>&1) || rc=$?

    # Should report not extracted and return non-zero
    if ! echo "$output" | grep -qi "not extracted"; then
        echo "Expected 'not extracted' status"
        echo "Output: $output"
        return 1
    fi

    if [[ $rc -eq 0 ]]; then
        echo "Verify should return non-zero when not synced"
        return 1
    fi

    return 0
}

test_merge_verify_synced() {
    # After extract + merge, --verify should show synced
    local env_out
    env_out=$(setup_merge_env "versynced")
    local base_dir="${env_out% *}"
    local session="${env_out#* }"
    TEST_REPOS+=("$base_dir")
    TEST_SESSIONS+=("$session")

    cd "$base_dir"

    # Do extract + merge first
    $CC merge -s "$session" --branch master >/dev/null 2>&1 || true

    # Now verify
    local output
    output=$($CC merge -s "$session" --branch master --verify 2>&1)
    local rc=$?

    if ! echo "$output" | grep -qi "synced"; then
        echo "Expected 'synced' status"
        echo "Output: $output"
        return 1
    fi

    if [[ $rc -ne 0 ]]; then
        echo "Verify should return 0 when fully synced"
        echo "Output: $output"
        return 1
    fi

    return 0
}

test_merge_force() {
    # --force should let re-extraction overwrite a diverged branch
    local env_out
    env_out=$(setup_merge_env "force")
    local base_dir="${env_out% *}"
    local session="${env_out#* }"
    TEST_REPOS+=("$base_dir")
    TEST_SESSIONS+=("$session")

    cd "$base_dir"

    # Extract once (creates branch)
    $CC merge -s "$session" --branch master >/dev/null 2>&1 || true

    # Add another commit inside the session
    docker run --rm \
        -v "claude-session-$session:/session" \
        "$GIT_IMAGE" \
        sh -c "
            git config --global safe.directory '*'
            cd /session/alpha
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'more work' > extra.txt
            git add extra.txt
            git commit -q -m 'Extra session commit'
        " >/dev/null 2>&1

    # Re-extract with --force
    local output
    output=$($CC merge -s "$session" --branch master --force 2>&1) || true

    # Verify the new commit landed on the host branch
    # (avoid grep -q in pipeline — pipefail + SIGPIPE causes false negatives)
    local master_log
    master_log=$(git -C "$base_dir/alpha" log master --oneline 2>/dev/null) || true
    if ! echo "$master_log" | grep -q "Extra session commit"; then
        echo "Force re-extract didn't land the new commit on master"
        echo "alpha master log: $master_log"
        echo "Output: $output"
        return 1
    fi

    return 0
}

test_merge_verify_unchanged() {
    # Repos where session didn't make changes should show "unchanged" (positive)
    local base_dir="$HOME/.cache/claude-container-tests/merge-unchanged-$$"
    mkdir -p "$base_dir"
    TEST_REPOS+=("$base_dir")

    # Create two host repos
    for name in changed untouched; do
        mkdir -p "$base_dir/$name"
        cd "$base_dir/$name"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "# $name" > README.md
        git add README.md
        git commit -q -m "Initial $name commit"
    done

    local session="test-merge-unchanged-$$"
    TEST_SESSIONS+=("$session")

    cat > "$base_dir/.claude-projects.yml" << EOF
version: "1"
projects:
  changed:
    path: $base_dir/changed
  untouched:
    path: $base_dir/untouched
EOF

    cd "$base_dir"
    $CC -s "$session" --no-run -C "$base_dir/.claude-projects.yml" >/dev/null 2>&1

    # Add a commit to only "changed" in the session — leave "untouched" alone
    docker run --rm \
        -v "claude-session-$session:/session" \
        "$GIT_IMAGE" \
        sh -c "
            git config --global safe.directory '*'
            cd /session/changed
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'new work' > work.txt
            git add work.txt
            git commit -q -m 'Session work'
        " >/dev/null 2>&1

    # Run verify — "untouched" should be "unchanged", "changed" should be "not extracted"
    local output rc=0
    output=$($CC merge -s "$session" --verify 2>&1) || rc=$?

    if ! echo "$output" | grep -q "untouched: unchanged"; then
        echo "Expected 'untouched: unchanged'"
        echo "Output: $output"
        return 1
    fi

    if ! echo "$output" | grep -q "changed: not extracted"; then
        echo "Expected 'changed: not extracted'"
        echo "Output: $output"
        return 1
    fi

    return 0
}

test_merge_verify_discovers_new_repos() {
    # Repos created inside the session (not in config) should appear in verify
    local base_dir="$HOME/.cache/claude-container-tests/merge-newrepo-$$"
    mkdir -p "$base_dir"
    TEST_REPOS+=("$base_dir")

    # Create one host repo
    mkdir -p "$base_dir/original"
    cd "$base_dir/original"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "# original" > README.md
    git add README.md
    git commit -q -m "Initial commit"

    local session="test-merge-newrepo-$$"
    TEST_SESSIONS+=("$session")

    cat > "$base_dir/.claude-projects.yml" << EOF
version: "1"
projects:
  original:
    path: $base_dir/original
EOF

    cd "$base_dir"
    $CC -s "$session" --no-run -C "$base_dir/.claude-projects.yml" >/dev/null 2>&1

    # Create a NEW repo inside the session that isn't in config
    docker run --rm \
        -v "claude-session-$session:/session" \
        "$GIT_IMAGE" \
        sh -c "
            git config --global safe.directory '*'
            mkdir -p /session/bonus-repo
            cd /session/bonus-repo
            git init -q
            git config user.email 'claude@container'
            git config user.name 'Claude'
            echo 'created in session' > README.md
            git add README.md
            git commit -q -m 'New repo created in session'
        " >/dev/null 2>&1

    # Run verify — should see "bonus-repo" in output
    local output rc=0
    output=$($CC merge -s "$session" --verify 2>&1) || rc=$?

    if ! echo "$output" | grep -q "bonus-repo"; then
        echo "Expected 'bonus-repo' to appear in verify output"
        echo "Output: $output"
        return 1
    fi

    return 0
}


# ============================================================================
# Run tests
# ============================================================================

declare -A ALL_TESTS=(
    ["dispatch_known"]="test_dispatch_known_subcommand"
    ["dispatch_flags"]="test_dispatch_existing_flags"
    ["dispatch_unknown"]="test_dispatch_unknown_bare_word"
    ["merge_help"]="test_merge_help"
    ["merge_missing_session"]="test_merge_missing_session"
    ["merge_unknown_option"]="test_merge_unknown_option"
    ["merge_extract_merge"]="test_merge_extract_merge"
    ["merge_default_branch"]="test_merge_default_branch"
    ["merge_verify_not_extracted"]="test_merge_verify_not_extracted"
    ["merge_verify_synced"]="test_merge_verify_synced"
    ["merge_verify_unchanged"]="test_merge_verify_unchanged"
    ["merge_verify_new_repos"]="test_merge_verify_discovers_new_repos"
    ["merge_force"]="test_merge_force"
)

echo "=== Merge Subcommand Tests ==="
echo "Repository: $REPO_ROOT"
echo ""

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
    # Dispatch tests (fast, no docker volumes needed)
    run_test "Dispatch: known subcommand" test_dispatch_known_subcommand
    run_test "Dispatch: existing flags still work" test_dispatch_existing_flags
    run_test "Dispatch: unknown bare word errors" test_dispatch_unknown_bare_word

    # Arg parsing (fast)
    run_test "Merge: --help" test_merge_help
    run_test "Merge: missing session errors" test_merge_missing_session
    run_test "Merge: unknown option errors" test_merge_unknown_option

    # Functional tests (create real sessions)
    run_test "Merge: extract + merge into branch" test_merge_extract_merge
    run_test "Merge: default branch = session name" test_merge_default_branch
    run_test "Merge: verify not-extracted" test_merge_verify_not_extracted
    run_test "Merge: verify synced" test_merge_verify_synced
    run_test "Merge: verify unchanged repos" test_merge_verify_unchanged
    run_test "Merge: verify discovers new repos" test_merge_verify_discovers_new_repos
    run_test "Merge: --force re-extract" test_merge_force
fi
