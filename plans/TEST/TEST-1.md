# TEST-1: Docker-in-Docker Integration Test Suite

## Goal

Build a test harness that exercises claude-container's full critical paths using real Docker operations. Two modes:

1. **Standard mode** — Run tests from host, mock-claude for deterministic agent work, assert on git state and output. Practical, fast, CI-friendly.

2. **Self-healing mode (experimental)** — claude-container runs the tests inside a session, and when tests fail, spawns a *nested* claude-container session where a real Claude agent fixes the code, exits, tests re-run, loops until green. The human reviews the accumulated work via `pull --verify`.

## Current State

### What exists

4 test scripts in `tests/`:
- `test-agent-layer.sh` — Tests entrypoint.sh/agent-run.sh directly. **Works.** Best existing pattern.
- `test-workflows.sh` — **13/20 fail** — uses removed CLI flags (`--extract`, `--sync`, `--merge-into`).
- `test-merge-subcommand.sh` — **10/13 fail** — uses removed `merge` subcommand.
- `test-multi-project.sh` — **Fails** — uses `--extract` flag.

### Reusable patterns from existing tests

1. `create_test_volume(vol_name, repo1, repo2, ...)` — volume with git repos
2. `run_in_session(vol, -e KEY=VAL ...)` — run entrypoint with mock-claude
3. Mock-claude (`tests/fixtures/mock-claude.sh`) — env-var driven: `MOCK_CLAUDE_COMMITS`, `MOCK_CLAUDE_EXIT`, `MOCK_CLAUDE_DELAY`, `MOCK_CLAUDE_TOUCH_FILES`
4. Volume helpers — `vol_cat`, `vol_test`
5. Trap-based cleanup

---

## Mode 1: Standard Test Harness

### Architecture

Tests run on the host (or in CI with Docker socket). claude-container spawns child containers as normal. Mock-claude provides deterministic agent work.

```
Host / CI Runner
  ├─ tests/run-all.sh
  │    ├─ tests/test-pull.sh     (extract, merge, dry-run, status)
  │    ├─ tests/test-push.sh     (ff, merge, preview)
  │    ├─ tests/test-snapshot.sh (keys, squash, diff)
  │    ├─ tests/test-lifecycle.sh (create, delete, repos list)
  │    └─ tests/test-edge.sh     (bundle fix, path resolve, report)
  │
  │  Each test:
  │    1. create_test_repo → /tmp or ~/.cache
  │    2. create_session → claude-container -s test-xxx --no-run -C config
  │    3. agent_work → docker run with mock-claude
  │    4. command under test → claude-container pull/push/status/...
  │    5. assert on git state, output, exit code
  │    6. cleanup volumes + repos
  │
  └─ Session Containers (spawned by claude-container)
       mock-claude makes controlled commits
```

### Critical Paths to Test

**Group 1: Session Lifecycle**
- `session_create_single` — single repo, verify volume + config
- `session_create_multi` — 3-repo config, verify all cloned
- `session_delete` — verify volumes removed
- `session_repos_list` — `repos list` shows container state

**Group 2: Agent Work**
- `agent_commits` — mock-claude commits in multiple repos, verify .agent-result
- `agent_no_changes` — 0 commits, verify result format
- `agent_dirty_state` — touched files, no commits
- `agent_exit_code` — non-zero exit propagation

**Group 3: Pull — Extract**
- `pull_extract_basic` — branches created on host
- `pull_extract_force` — `--force` overwrites
- `pull_extract_filter` — `--repo` filters
- `pull_status` — `--status` shows delta
- `pull_dry_run_no_side_effects` — no cloning, no branch writes

**Group 4: Pull — Merge**
- `pull_merge_ff` — fast-forward into target
- `pull_merge_squash` — squash-merge, verify squash-base ref
- `pull_merge_conflict` — CONFLICT status
- `pull_merge_host_dirty` — SKIP status
- `pull_merge_up_to_date` — "Nothing to merge", no false ready count
- `pull_merge_squash_base_reuse` — second squash uses base correctly

**Group 5: Push**
- `push_ff_basic` — host branch into session
- `push_merge_basic` — `--merge` host into session
- `push_preview` — `--dry-run` output

**Group 6: Snapshot Correctness**
- `snapshot_all_keys` — every key written per repo
- `snapshot_container_in_target` — true after squash-merge
- `snapshot_external_ahead` — non-squash commits counted
- `snapshot_extract_enabled` — `extract: false` detection
- `snapshot_diff_squash_aware` — uses squash-base, not target

**Group 7: Edge Cases**
- `bundle_head_ref` — `git bundle create HEAD` works (not bare SHA)
- `resolve_path_sibling` — no-org repos find sibling dirs
- `report_no_false_ready` — "up to date" repos don't inflate ready count
- `extract_false_in_report` — discovered bucket shows new-work indicator

---

## Mode 2: Self-Healing Test Harness (Experimental)

### Concept

claude-container tests itself. A test-runner session spawns a fixer session when tests fail. The fixer reads failures, edits code, exits. Tests re-run. Loop until green. Human reviews the accumulated diff.

### Architecture

```
Human runs:
  claude-container test --self-heal

  ┌─────────────────────────────────────────────────────┐
  │ Outer Session: "cc-test-runner"                     │
  │                                                     │
  │  /workspace/claude-container  (the repo under test) │
  │  /workspace/.test-state/     (persistent across     │
  │                                iterations)          │
  │                                                     │
  │  Loop:                                              │
  │    1. Run test suite                                │
  │    2. If all pass → write summary, exit             │
  │    3. If failures:                                  │
  │       a. Write failure report to .test-state/       │
  │       b. Spawn inner session (real Claude):         │
  │          ┌──────────────────────────────────┐       │
  │          │ Inner Session: "cc-test-fixer"   │       │
  │          │                                  │       │
  │          │ AGENT_TASK=fix-test-failures      │       │
  │          │ CLAUDE.md:                        │       │
  │          │   "Here are the test failures:    │       │
  │          │    <failures>                     │       │
  │          │    Fix the code. Run the tests    │       │
  │          │    to verify. When done: fin"     │       │
  │          │                                  │       │
  │          │ Claude edits code, runs tests,   │       │
  │          │ commits fixes, calls fin         │       │
  │          └──────────────────────────────────┘       │
  │       c. Pull fixer's changes into runner's repo    │
  │       d. Goto 1                                     │
  │                                                     │
  │  Max iterations: 3 (configurable)                   │
  │  On exit: write .agent-result with test summary     │
  └─────────────────────────────────────────────────────┘

Human reviews:
  claude-container pull -s cc-test-runner main --verify

  Shows:
    ✓ claude-container — squash-merge 12 commit(s) into main
      8 files changed, 145 insertions(+), 89 deletions(-)

  The human sees the full diff of everything the self-healing loop changed,
  decides whether to merge, can --discuss to ask Claude about the changes.
```

### Key Design Decisions

**Outer session is a shell-only test runner, not an agent.**
The outer session runs `tests/run-all.sh` via `--shell` or `BASH_EXEC`. It doesn't need Claude — it just runs tests and spawns the fixer when needed.

**Inner session is a real Claude agent.**
The fixer session gets a `CLAUDE.md` with the failure report and instructions. It uses real Claude (not mock) to understand failures, read the relevant code, and commit fixes. The `fin` command signals completion.

**Changes accumulate in the outer session's volume.**
The fixer works on the same code as the runner. After the fixer exits, the runner `git pull`s or the fixer's commits are already in the same volume. The runner re-runs tests against the modified code.

**The human gets one review gate.**
No intermediate prompts. The loop runs autonomously. When done (tests pass or max iterations), the human does `pull --verify` and sees the full accumulated diff with hashes, diffstat, and merge detail. They can `--discuss` to ask about specific changes.

### Flow Detail

```bash
# tests/self-heal.sh (runs inside outer session)

MAX_ITERATIONS=3
iteration=0

while [[ $iteration -lt $MAX_ITERATIONS ]]; do
    iteration=$((iteration + 1))
    echo "=== Iteration $iteration ==="

    # Run tests, capture output
    test_output=$(./tests/run-all.sh 2>&1) || true
    test_rc=$?

    # Parse results
    passed=$(echo "$test_output" | grep -c "PASS" || true)
    failed=$(echo "$test_output" | grep -c "FAIL" || true)

    if [[ $failed -eq 0 ]]; then
        echo "All $passed tests passed on iteration $iteration"
        git add -A && git commit -m "test: all $passed tests passing (iteration $iteration)"
        break
    fi

    echo "$failed failures, $passed passes"

    # Write failure report for fixer
    failures=$(echo "$test_output" | grep -A5 "FAIL")
    cat > .test-state/failure-report.md << EOF
# Test Failures (Iteration $iteration)
$failed tests failed, $passed passed.

## Failures
$failures

## Full Output
$test_output
EOF

    # Spawn fixer session (real Claude)
    # The fixer works on THIS repo (already in /workspace)
    # Using claude directly since we're already in a container
    claude "$(cat .test-state/failure-report.md)

Fix these test failures. The test scripts are in tests/.
The code under test is in lib/.
Run the failing tests to verify your fixes.
When done, commit your changes and call fin."

    # fixer exited — changes are in the working tree
    # re-loop to run tests again
done

if [[ $failed -gt 0 ]]; then
    echo "Still $failed failures after $MAX_ITERATIONS iterations"
    git add -A && git commit -m "test: $failed failures remaining after $MAX_ITERATIONS iterations"
fi
```

### Invocation

```bash
# Standard tests (mock-claude, fast, deterministic)
claude-container test -s cc-tests

# Self-healing mode (real Claude, autonomous fix loop)
claude-container test -s cc-tests --self-heal

# Or manually:
claude-container -s cc-test-runner --docker -- bash tests/self-heal.sh
```

### Human Review UX

After the self-healing loop completes:

```bash
# See what changed
claude-container pull -s cc-test-runner main --verify

# Output:
# ─────────── pull: cc-test-runner → main ───────────
# ✓ 1 ready
#
#   ✓ . — squash-merge 12 commit(s) into main
#     container:a3f8b21 session:a3f8b21 main:e5b3038
#     8 files changed, 145 insertions(+), 89 deletions(-)
#
# ──────────────────────────────────────────────────
#
# session → main diff:
#   claude-container
#     lib/commands/pull/report.sh    | 15 ++++----
#     lib/session-discovery.sh       | 23 ++++++++---
#     tests/test-pull.sh             | 45 ++++++++++++++++++++
#     tests/test-snapshot.sh         | 38 +++++++++++++++++
#     tests/lib/helpers.sh           | 12 +++--
#     ...
#
# Merge into 'main'? [y/N]

# Or discuss first:
claude-container pull -s cc-test-runner main --discuss
# → launches Claude to explain what the fixer changed and why
```

### Requirements for Self-Healing Mode

1. **Docker socket access** in the outer session (`--docker` flag)
2. **Real Claude token** for the fixer (not mock)
3. **The test suite itself** must be in the session volume
4. **`fin` command** available in the fixer session (already exists in entrypoint.sh)

### Limitations

- The fixer only sees test output, not the human's intent. It can fix code to make tests pass but might do so in undesirable ways. The human review gate catches this.
- Max 3 iterations by default — prevents infinite loops on fundamentally broken tests.
- The fixer can't modify tests that are themselves wrong. Garbage-in, garbage-out.
- Network access needed for the fixer to install deps if tests require new packages.

---

## Implementation Plan

### TEST-2: Test framework + helpers
- `tests/lib/helpers.sh` — create_test_repo, write_config, assert_*, cleanup
- `tests/lib/agent.sh` — agent_work (mock-claude in session)
- `tests/run-all.sh` — runner, outputs machine-parseable results

### TEST-3: Session lifecycle tests (Group 1)
### TEST-4: Pull tests (Groups 3-4)
### TEST-5: Push + snapshot tests (Groups 5-6)
### TEST-6: Edge case tests (Group 7)
### TEST-7: Watch + reconcile tests
### TEST-8: Fix existing test scripts to use current CLI
### TEST-9: Self-healing harness (`tests/self-heal.sh`)
### TEST-10: `claude-container test` subcommand (optional convenience wrapper)

## Dependency DAG

```
TEST-2 (framework)
  ↓
TEST-3 (lifecycle) ──→ TEST-8 (fix old tests)
  ↓
TEST-4 (pull) ──→ TEST-7 (watch/reconcile)
  ↓
TEST-5 (push/snapshot)
  ↓
TEST-6 (edge cases)
  ↓
TEST-9 (self-heal) ← requires TEST-2..6 complete
  ↓
TEST-10 (test subcommand) ← optional
```

## Open Questions

1. **CI environment**: GitHub Actions with Docker? Self-hosted? macOS tests use `$HOME/.cache` (Docker Desktop only mounts `$HOME`).

2. **Image availability**: Tests need `ghcr.io/hypermemetic/claude-container:latest`. Pull or build locally?

3. **Self-heal token**: The fixer needs a real Claude token. In CI, this would be a secret. Locally, it uses the user's token.

4. **Self-heal review**: Should the outer session commit after each iteration (so the human sees the progression), or only commit the final state?

5. **Test speed**: 40+ tests with Docker volume creation. Consider shared base volumes or parallel execution with `$$` suffixed names.
