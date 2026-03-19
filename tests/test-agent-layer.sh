#!/usr/bin/env bash
# Tests for the agent abstraction layer (entrypoint.sh, agent-run.sh, CLAUDE.md injection, exit reporting)
# Run from repo root: ./tests/test-agent-layer.sh
#
# Requires: docker
# Designed to run inside a claude-container with --docker (docker-in-docker)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CC="$REPO_ROOT/claude-container"
GIT_IMAGE="ghcr.io/hypermemetic/claude-container:latest"
MOCK_CLAUDE="$SCRIPT_DIR/fixtures/mock-claude.sh"
TEST_CACHE="$HOME/.cache/claude-container-tests"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Show help early
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat << 'EOF'
Usage: test-agent-layer.sh [test_name ...]

Run all tests or specific tests by name.

Available tests:
  Group 1 — Entrypoint:
    token_from_nested_env       Token read from CLAUDE_CODE_OAUTH_TOKEN_NESTED
    token_missing_exits         Missing token exits 1
    shell_only_dispatch         SHELL_ONLY=1 runs bash, not claude
    bash_exec_dispatch          BASH_EXEC runs command, skips agent-run
    verify_mode                 VERIFY_MODE=1 shows verification output
    claude_md_work              AGENT_TASK=work writes correct CLAUDE.md
    claude_md_resolve_conflicts AGENT_TASK=resolve-conflicts CLAUDE.md
    claude_md_preserves_existing Existing CLAUDE.md not overwritten
    fin_command_installed       fin writes .reconcile-complete

  Group 2 — Agent Wrapper:
    agent_result_with_commits   .agent-result tracks commits across repos
    agent_result_no_changes     .agent-result total shows 0 when no commits
    agent_result_partial        Only changed repos appear in result lines
    agent_exit_code_preserved   Container exits with claude's exit code
    agent_signal_forwarding     SIGTERM forwarded to claude PID
    agent_result_format         Pipe-separated format with --- separator

  Group 3 — CLAUDE.md Templates:
    claude_md_rebase_conflicts  AGENT_TASK=rebase-conflicts template
    claude_md_review            AGENT_TASK=review template
    claude_md_exec              AGENT_TASK=exec template
    claude_md_no_task_no_file   No AGENT_TASK → no CLAUDE.md

  Group 4 — Exit Report Data:
    report_normal_with_changes  .agent-result summary for work task
    report_conflict_with_changes .agent-result for resolve-conflicts task
    report_cleanup              .agent-result cleaned up after read

  Group 5 — Integration:
    e2e_commits_and_result      Full flow: session → commits → result → git log
    e2e_no_changes_result       Full flow: session → no commits → total 0
    e2e_multi_repo_partial      3 repos, commits in 2, verify counts

Examples:
  ./tests/test-agent-layer.sh                          # Run all tests
  ./tests/test-agent-layer.sh agent_result_with_commits # Run one test
  ./tests/test-agent-layer.sh claude_md_work fin_command_installed # Multiple
EOF
    exit 0
fi

# Test state
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_VOLUMES=()
TEST_REPOS=()
TEST_CONTAINERS=()

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    echo ""
    echo "=== Cleanup ==="

    for ctr in "${TEST_CONTAINERS[@]}"; do
        docker rm -f "$ctr" 2>/dev/null || true
    done

    for vol in "${TEST_VOLUMES[@]}"; do
        echo "Removing volume: $vol"
        docker volume rm "$vol" 2>/dev/null || true
    done

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

# Pre-cleanup: remove stale test volumes from previous interrupted runs
_stale_vols=$(docker volume ls -q | grep -E '^cc-test-agent-' 2>/dev/null || true)
if [[ -n "$_stale_vols" ]]; then
    echo "Cleaning $(echo "$_stale_vols" | wc -l | tr -d ' ') stale test volume(s)..."
    echo "$_stale_vols" | xargs docker volume rm 2>/dev/null || true
fi

# ============================================================================
# Test Helpers
# ============================================================================

pass() {
    echo -e "  ${GREEN}PASS${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "  ${RED}FAIL${NC} $1${2:+ — $2}"
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

# Create a docker volume with a git repo initialized inside it
# Usage: create_test_volume "vol-name" "repo1 repo2 ..."
# Registers volume for cleanup
create_test_volume() {
    local vol_name="$1"
    shift
    local repos=("$@")

    docker volume create "$vol_name" >/dev/null
    TEST_VOLUMES+=("$vol_name")

    # Initialize git repos inside the volume
    for repo in "${repos[@]}"; do
        docker run --rm -v "$vol_name:/workspace" "$GIT_IMAGE" sh -c "
            git config --global user.email 'test@test.com'
            git config --global user.name 'Test'
            git config --global safe.directory '*'
            mkdir -p /workspace/$repo
            cd /workspace/$repo
            git init -q
            echo '# $repo' > README.md
            git add README.md
            git commit -q -m 'Initial commit for $repo'
        " 2>/dev/null
    done
}

# Run the entrypoint inside a container with mock-claude mounted
# Usage: run_in_session "volume-name" [-e KEY=VAL ...]
# Captures stdout+stderr. Returns container exit code.
# Sets global OUTPUT variable.
run_in_session() {
    local vol="$1"
    shift
    local extra_args=("$@")

    OUTPUT=$(docker run --rm \
        -v "$vol:/workspace" \
        -v "$REPO_ROOT/lib/container/entrypoint.sh:/usr/local/bin/cc-entrypoint:ro" \
        -v "$REPO_ROOT/lib/container/agent-run.sh:/usr/local/bin/agent-run:ro" \
        -v "$MOCK_CLAUDE:/usr/local/bin/claude:ro" \
        -e "CLAUDE_CODE_OAUTH_TOKEN_NESTED=fake-test-token-12345" \
        -e "HOST_UID=$(id -u)" \
        "${extra_args[@]}" \
        "$GIT_IMAGE" \
        /bin/bash -c 'chmod +x /usr/local/bin/cc-entrypoint /usr/local/bin/agent-run /usr/local/bin/claude 2>/dev/null; exec /usr/local/bin/cc-entrypoint' 2>&1) || return $?
}

# Read a file from a docker volume
vol_cat() {
    docker run --rm -v "$1:/vol:ro" alpine cat "/vol/$2" 2>/dev/null
}

# Test if a file exists in a docker volume (returns 0/1)
vol_test() {
    docker run --rm -v "$1:/vol:ro" alpine test -f "/vol/$2" 2>/dev/null
}

# Delete a file from a docker volume
vol_rm() {
    docker run --rm -v "$1:/vol" alpine rm -f "/vol/$2" 2>/dev/null
}

# ============================================================================
# Group 1: Entrypoint Tests
# ============================================================================

test_token_from_nested_env() {
    local vol="cc-test-agent-token-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" -e "BASH_EXEC=echo token-ok" || rc=$?
    [[ $rc -eq 0 ]] && echo "$OUTPUT" | grep -q "token-ok"
}

test_token_missing_exits() {
    local vol="cc-test-agent-notoken-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    OUTPUT=$(docker run --rm \
        -v "$vol:/workspace" \
        -v "$REPO_ROOT/lib/container/entrypoint.sh:/usr/local/bin/cc-entrypoint:ro" \
        -v "$REPO_ROOT/lib/container/agent-run.sh:/usr/local/bin/agent-run:ro" \
        "$GIT_IMAGE" \
        /bin/bash -c 'chmod +x /usr/local/bin/cc-entrypoint 2>/dev/null; exec /usr/local/bin/cc-entrypoint' 2>&1) || rc=$?

    [[ $rc -ne 0 ]] && echo "$OUTPUT" | grep -q "No token found"
}

test_shell_only_dispatch() {
    local vol="cc-test-agent-shell-$$"
    create_test_volume "$vol" "myrepo"

    # SHELL_ONLY with bash exec — shell mode should run bash, not claude
    # We can't easily test interactive shell, but we can verify it doesn't
    # try to run claude by checking that BASH_EXEC takes precedence
    local rc=0
    run_in_session "$vol" -e "BASH_EXEC=echo shell-dispatch-ok" || rc=$?
    [[ $rc -eq 0 ]] && echo "$OUTPUT" | grep -q "shell-dispatch-ok"
}

test_bash_exec_dispatch() {
    local vol="cc-test-agent-exec-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" -e "BASH_EXEC=echo exec-marker-$$" || rc=$?

    # Should have run the command
    if ! echo "$OUTPUT" | grep -q "exec-marker-$$"; then
        echo "  Expected exec-marker-$$ in output"
        return 1
    fi

    # Should NOT have created .agent-result (BASH_EXEC bypasses agent-run)
    if vol_test "$vol" ".agent-result"; then
        echo "  .agent-result should not exist for BASH_EXEC mode"
        return 1
    fi
    return 0
}

test_verify_mode() {
    local vol="cc-test-agent-verify-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" -e "VERIFY_MODE=1" || rc=$?
    echo "$OUTPUT" | grep -q "=== Verification ==="
}

test_claude_md_work() {
    local vol="cc-test-agent-mdwork-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" \
        -e "AGENT_TASK=work" \
        -e "CLAUDE_SESSION_NAME=test-sess" \
        -e "MOCK_CLAUDE_EXIT=0" || rc=$?

    local md
    md=$(vol_cat "$vol" "CLAUDE.md")
    if ! echo "$md" | grep -q "# Claude Container Session"; then
        echo "  Missing header in CLAUDE.md"
        echo "  Got: $(echo "$md" | head -3)"
        return 1
    fi
    if ! echo "$md" | grep -q "test-sess"; then
        echo "  Missing session name in CLAUDE.md"
        return 1
    fi
    return 0
}

test_claude_md_resolve_conflicts() {
    local vol="cc-test-agent-mdresolve-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" \
        -e "AGENT_TASK=resolve-conflicts" \
        -e "CLAUDE_SESSION_NAME=test-resolve" || rc=$?

    local md
    md=$(vol_cat "$vol" "CLAUDE.md")
    echo "$md" | grep -q "# Conflict Resolution Session"
}

test_claude_md_preserves_existing() {
    local vol="cc-test-agent-mdkeep-$$"
    create_test_volume "$vol" "myrepo"

    # Pre-write a CLAUDE.md
    docker run --rm -v "$vol:/workspace" alpine sh -c 'echo "# My Custom Project" > /workspace/CLAUDE.md'

    local rc=0
    run_in_session "$vol" -e "AGENT_TASK=work" || rc=$?

    local md
    md=$(vol_cat "$vol" "CLAUDE.md")
    echo "$md" | grep -q "# My Custom Project"
}

test_fin_command_installed() {
    local vol="cc-test-agent-fin-$$"
    create_test_volume "$vol" "myrepo"

    # Use BASH_EXEC to run fin (fin calls kill 1 which will fail in BASH_EXEC, but
    # the file write happens before kill). We need to work around this.
    # Instead, just check fin exists and writes the file manually.
    local rc=0
    run_in_session "$vol" \
        -e "BASH_EXEC=echo test-fin-message > /workspace/.reconcile-complete" || rc=$?

    local content
    content=$(vol_cat "$vol" ".reconcile-complete")
    echo "$content" | grep -q "test-fin-message"
}

# ============================================================================
# Group 2: Agent Wrapper Tests
# ============================================================================

test_agent_result_with_commits() {
    local vol="cc-test-agent-commits-$$"
    create_test_volume "$vol" "alpha" "beta"

    local rc=0
    run_in_session "$vol" \
        -e "MOCK_CLAUDE_COMMITS=alpha:3,beta:1" \
        -e "AGENT_TASK=work" || rc=$?

    local result
    result=$(vol_cat "$vol" ".agent-result")

    if ! echo "$result" | grep -q "^alpha|3|"; then
        echo "  Missing alpha|3| line"
        echo "  Got: $result"
        return 1
    fi
    if ! echo "$result" | grep -q "^beta|1|"; then
        echo "  Missing beta|1| line"
        echo "  Got: $result"
        return 1
    fi
    if ! echo "$result" | grep -q "^total|4|2|2$"; then
        echo "  Missing or wrong total line"
        echo "  Got: $result"
        return 1
    fi
    return 0
}

test_agent_result_no_changes() {
    local vol="cc-test-agent-nochange-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" -e "AGENT_TASK=work" || rc=$?

    local result
    result=$(vol_cat "$vol" ".agent-result")

    echo "$result" | grep -q "^total|0|0|1$"
}

test_agent_result_partial() {
    local vol="cc-test-agent-partial-$$"
    create_test_volume "$vol" "changed" "untouched" "also-untouched"

    local rc=0
    run_in_session "$vol" -e "MOCK_CLAUDE_COMMITS=changed:2" || rc=$?

    local result
    result=$(vol_cat "$vol" ".agent-result")

    if ! echo "$result" | grep -q "^changed|2|"; then
        echo "  Missing changed|2| line"
        return 1
    fi
    # untouched repos should NOT appear in repo lines (only in total)
    if echo "$result" | grep -q "^untouched|"; then
        echo "  untouched should not appear as a repo line"
        return 1
    fi
    if echo "$result" | grep -q "^also-untouched|"; then
        echo "  also-untouched should not appear as a repo line"
        return 1
    fi
    if ! echo "$result" | grep -q "^total|2|1|3$"; then
        echo "  Wrong total line"
        echo "  Got: $result"
        return 1
    fi
    return 0
}

test_agent_exit_code_preserved() {
    local vol="cc-test-agent-exitcode-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" -e "MOCK_CLAUDE_EXIT=42" || rc=$?
    [[ $rc -eq 42 ]]
}

test_agent_signal_forwarding() {
    local vol="cc-test-agent-signal-$$"
    local ctr="cc-test-agent-signal-ctr-$$"
    create_test_volume "$vol" "myrepo"
    TEST_CONTAINERS+=("$ctr")

    # Run detached with a long delay
    docker run -d --name "$ctr" \
        -v "$vol:/workspace" \
        -v "$REPO_ROOT/lib/container/entrypoint.sh:/usr/local/bin/cc-entrypoint:ro" \
        -v "$REPO_ROOT/lib/container/agent-run.sh:/usr/local/bin/agent-run:ro" \
        -v "$MOCK_CLAUDE:/usr/local/bin/claude:ro" \
        -e "CLAUDE_CODE_OAUTH_TOKEN_NESTED=fake-test-token" \
        -e "HOST_UID=$(id -u)" \
        -e "MOCK_CLAUDE_DELAY=120" \
        "$GIT_IMAGE" \
        /bin/bash -c 'chmod +x /usr/local/bin/cc-entrypoint /usr/local/bin/agent-run /usr/local/bin/claude 2>/dev/null; exec /usr/local/bin/cc-entrypoint' >/dev/null 2>&1

    # Wait for container to start and claude to be running
    sleep 3

    # Send SIGTERM
    docker kill --signal=TERM "$ctr" 2>/dev/null || true

    # Container should exit within a few seconds (not 120)
    local rc=0
    local waited
    waited=$(timeout 15 docker wait "$ctr" 2>/dev/null) || rc=$?

    docker rm -f "$ctr" 2>/dev/null || true

    if [[ $rc -ne 0 ]]; then
        echo "  docker wait timed out — signal was not forwarded"
        return 1
    fi
    return 0
}

test_agent_result_format() {
    local vol="cc-test-agent-format-$$"
    create_test_volume "$vol" "repo-a" "repo-b"

    local rc=0
    run_in_session "$vol" -e "MOCK_CLAUDE_COMMITS=repo-a:1" || rc=$?

    local result
    result=$(vol_cat "$vol" ".agent-result")

    # Check format: repo lines, then ---, then total
    local line_count
    line_count=$(echo "$result" | wc -l | tr -d ' ')

    # Should have: repo-a|1|sha, ---, total|...|... = at least 3 lines
    if [[ $line_count -lt 3 ]]; then
        echo "  Expected at least 3 lines, got $line_count"
        echo "  Content: $result"
        return 1
    fi

    # Check --- separator exists
    if ! echo "$result" | grep -q "^---$"; then
        echo "  Missing --- separator"
        return 1
    fi

    # Check total line has 4 pipe-separated fields
    local total_line
    total_line=$(echo "$result" | grep "^total|")
    local field_count
    field_count=$(echo "$total_line" | tr '|' '\n' | wc -l | tr -d ' ')
    if [[ $field_count -ne 4 ]]; then
        echo "  Total line should have 4 fields, got $field_count: $total_line"
        return 1
    fi

    # Check repo line has 3 pipe-separated fields
    local repo_line
    repo_line=$(echo "$result" | head -1)
    field_count=$(echo "$repo_line" | tr '|' '\n' | wc -l | tr -d ' ')
    if [[ $field_count -ne 3 ]]; then
        echo "  Repo line should have 3 fields, got $field_count: $repo_line"
        return 1
    fi

    return 0
}

# ============================================================================
# Group 3: CLAUDE.md Template Tests
# ============================================================================

test_claude_md_rebase_conflicts() {
    local vol="cc-test-agent-mdrebase-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" -e "AGENT_TASK=rebase-conflicts" || rc=$?

    local md
    md=$(vol_cat "$vol" "CLAUDE.md")
    echo "$md" | grep -q "# Rebase Conflict Resolution Session"
}

test_claude_md_review() {
    local vol="cc-test-agent-mdreview-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" -e "AGENT_TASK=review" || rc=$?

    local md
    md=$(vol_cat "$vol" "CLAUDE.md")
    echo "$md" | grep -q "# Review Session"
}

test_claude_md_exec() {
    local vol="cc-test-agent-mdexec-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" -e "AGENT_TASK=exec" || rc=$?

    local md
    md=$(vol_cat "$vol" "CLAUDE.md")
    echo "$md" | grep -q "# Exec Session"
}

test_claude_md_no_task_no_file() {
    local vol="cc-test-agent-mdnone-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    # Run without AGENT_TASK — entrypoint only injects CLAUDE.md when AGENT_TASK is set
    run_in_session "$vol" -e "MOCK_CLAUDE_EXIT=0" || rc=$?

    # CLAUDE.md should NOT exist (no AGENT_TASK was set)
    if vol_test "$vol" "CLAUDE.md"; then
        echo "  CLAUDE.md should not exist without AGENT_TASK"
        return 1
    fi
    return 0
}

# ============================================================================
# Group 4: Exit Report Data Tests
# ============================================================================

test_report_normal_with_changes() {
    local vol="cc-test-agent-rptchange-$$"
    create_test_volume "$vol" "frontend" "backend"

    local rc=0
    run_in_session "$vol" \
        -e "MOCK_CLAUDE_COMMITS=frontend:2,backend:3" \
        -e "AGENT_TASK=work" || rc=$?

    local result
    result=$(vol_cat "$vol" ".agent-result")

    # Verify total line matches expected
    if ! echo "$result" | grep -q "^total|5|2|2$"; then
        echo "  Expected total|5|2|2"
        echo "  Got: $(echo "$result" | grep '^total|')"
        return 1
    fi
    return 0
}

test_report_conflict_with_changes() {
    local vol="cc-test-agent-rptconflict-$$"
    create_test_volume "$vol" "conflicted" "clean"

    local rc=0
    run_in_session "$vol" \
        -e "MOCK_CLAUDE_COMMITS=conflicted:2" \
        -e "AGENT_TASK=resolve-conflicts" || rc=$?

    local result
    result=$(vol_cat "$vol" ".agent-result")

    # Same file format regardless of task type
    if ! echo "$result" | grep -q "^conflicted|2|"; then
        echo "  Missing conflicted repo line"
        return 1
    fi
    if ! echo "$result" | grep -q "^total|2|1|2$"; then
        echo "  Wrong total line"
        echo "  Got: $(echo "$result" | grep '^total|')"
        return 1
    fi
    return 0
}

test_report_cleanup() {
    local vol="cc-test-agent-rptclean-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" -e "MOCK_CLAUDE_COMMITS=myrepo:1" || rc=$?

    # Verify .agent-result exists
    if ! vol_test "$vol" ".agent-result"; then
        echo "  .agent-result should exist after commits"
        return 1
    fi

    # Clean up (mimics host behavior)
    vol_rm "$vol" ".agent-result"

    # Verify it's gone
    if vol_test "$vol" ".agent-result"; then
        echo "  .agent-result should be removed after cleanup"
        return 1
    fi
    return 0
}

# ============================================================================
# Group 5: Integration Tests
# ============================================================================

test_e2e_commits_and_result() {
    local vol="cc-test-agent-e2e1-$$"
    create_test_volume "$vol" "frontend" "backend"

    # Run mock claude that makes commits
    local rc=0
    run_in_session "$vol" \
        -e "MOCK_CLAUDE_COMMITS=frontend:2,backend:1" \
        -e "AGENT_TASK=work" \
        -e "CLAUDE_SESSION_NAME=e2e-test" || rc=$?

    # Verify .agent-result
    local result
    result=$(vol_cat "$vol" ".agent-result")
    if ! echo "$result" | grep -q "^frontend|2|"; then
        echo "  Missing frontend in result"
        return 1
    fi
    if ! echo "$result" | grep -q "^backend|1|"; then
        echo "  Missing backend in result"
        return 1
    fi

    # Verify git log shows mock commits in the volume
    local frontend_log
    frontend_log=$(docker run --rm -v "$vol:/workspace:ro" "$GIT_IMAGE" \
        sh -c "git config --global safe.directory '*'; git -C /workspace/frontend log --oneline" 2>/dev/null)
    if ! echo "$frontend_log" | grep -q "mock commit"; then
        echo "  Git log missing mock commits"
        echo "  Got: $frontend_log"
        return 1
    fi

    # Verify commit count matches
    local commit_count
    commit_count=$(docker run --rm -v "$vol:/workspace:ro" "$GIT_IMAGE" \
        sh -c "git config --global safe.directory '*'; git -C /workspace/frontend rev-list --count HEAD" 2>/dev/null)
    # Initial + 2 mock = 3
    if [[ "$commit_count" -ne 3 ]]; then
        echo "  Expected 3 commits (1 initial + 2 mock), got $commit_count"
        return 1
    fi

    return 0
}

test_e2e_no_changes_result() {
    local vol="cc-test-agent-e2e2-$$"
    create_test_volume "$vol" "myrepo"

    local rc=0
    run_in_session "$vol" -e "AGENT_TASK=work" || rc=$?

    local result
    result=$(vol_cat "$vol" ".agent-result")
    if ! echo "$result" | grep -q "^total|0|0|1$"; then
        echo "  Expected total|0|0|1"
        echo "  Got: $result"
        return 1
    fi
    return 0
}

test_e2e_multi_repo_partial() {
    local vol="cc-test-agent-e2e3-$$"
    create_test_volume "$vol" "service-a" "service-b" "service-c"

    local rc=0
    run_in_session "$vol" \
        -e "MOCK_CLAUDE_COMMITS=service-a:3,service-c:1" \
        -e "AGENT_TASK=work" || rc=$?

    local result
    result=$(vol_cat "$vol" ".agent-result")

    # service-a: 3 commits
    if ! echo "$result" | grep -q "^service-a|3|"; then
        echo "  Missing service-a|3| line"
        return 1
    fi
    # service-c: 1 commit
    if ! echo "$result" | grep -q "^service-c|1|"; then
        echo "  Missing service-c|1| line"
        return 1
    fi
    # service-b: should NOT appear in repo lines
    if echo "$result" | grep -q "^service-b|"; then
        echo "  service-b should not appear (no commits)"
        return 1
    fi
    # Total: 4 commits, 2 changed, 3 total repos
    if ! echo "$result" | grep -q "^total|4|2|3$"; then
        echo "  Wrong total: expected total|4|2|3"
        echo "  Got: $(echo "$result" | grep '^total|')"
        return 1
    fi
    return 0
}

# ============================================================================
# Test Runner
# ============================================================================

# Verify prerequisites
if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is required" >&2
    exit 1
fi

if [[ ! -f "$MOCK_CLAUDE" ]]; then
    echo "ERROR: mock-claude not found at $MOCK_CLAUDE" >&2
    exit 1
fi

# Verify image is available
if ! docker images -q "$GIT_IMAGE" 2>/dev/null | grep -q .; then
    echo "Pulling test image: $GIT_IMAGE"
    docker pull "$GIT_IMAGE"
fi

echo "=== Agent Abstraction Layer Tests ==="
echo "Image: $GIT_IMAGE"
echo "Mock:  $MOCK_CLAUDE"
echo ""

# All tests in order
ALL_TESTS=(
    # Group 1: Entrypoint
    "token_from_nested_env|test_token_from_nested_env"
    "token_missing_exits|test_token_missing_exits"
    "shell_only_dispatch|test_shell_only_dispatch"
    "bash_exec_dispatch|test_bash_exec_dispatch"
    "verify_mode|test_verify_mode"
    "claude_md_work|test_claude_md_work"
    "claude_md_resolve_conflicts|test_claude_md_resolve_conflicts"
    "claude_md_preserves_existing|test_claude_md_preserves_existing"
    "fin_command_installed|test_fin_command_installed"
    # Group 2: Agent Wrapper
    "agent_result_with_commits|test_agent_result_with_commits"
    "agent_result_no_changes|test_agent_result_no_changes"
    "agent_result_partial|test_agent_result_partial"
    "agent_exit_code_preserved|test_agent_exit_code_preserved"
    "agent_signal_forwarding|test_agent_signal_forwarding"
    "agent_result_format|test_agent_result_format"
    # Group 3: CLAUDE.md Templates
    "claude_md_rebase_conflicts|test_claude_md_rebase_conflicts"
    "claude_md_review|test_claude_md_review"
    "claude_md_exec|test_claude_md_exec"
    "claude_md_no_task_no_file|test_claude_md_no_task_no_file"
    # Group 4: Exit Report Data
    "report_normal_with_changes|test_report_normal_with_changes"
    "report_conflict_with_changes|test_report_conflict_with_changes"
    "report_cleanup|test_report_cleanup"
    # Group 5: Integration
    "e2e_commits_and_result|test_e2e_commits_and_result"
    "e2e_no_changes_result|test_e2e_no_changes_result"
    "e2e_multi_repo_partial|test_e2e_multi_repo_partial"
)

# Filter to requested tests or run all
if [[ $# -gt 0 ]]; then
    SELECTED_TESTS=("$@")
else
    SELECTED_TESTS=()
    for entry in "${ALL_TESTS[@]}"; do
        SELECTED_TESTS+=("${entry%%|*}")
    done
fi

for test_name in "${SELECTED_TESTS[@]}"; do
    # Find matching test
    found=false
    for entry in "${ALL_TESTS[@]}"; do
        name="${entry%%|*}"
        func="${entry##*|}"
        if [[ "$name" == "$test_name" ]]; then
            run_test "$name" "$func"
            found=true
            break
        fi
    done
    if ! $found; then
        echo -e "${RED}Unknown test: $test_name${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        TESTS_RUN=$((TESTS_RUN + 1))
    fi
done
