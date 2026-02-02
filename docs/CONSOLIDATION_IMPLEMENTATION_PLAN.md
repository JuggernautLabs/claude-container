# Code Consolidation Implementation Plan

## Overview

This document provides the implementation roadmap for consolidating duplicated code across the codebase, based on findings from:
- `ARCHITECTURAL_AUDIT.md` - Collection operations and docker patterns
- `GITOPS_WORKFLOW_AUDIT.md` - Git workflow consolidations

## Implementation Phases

### Phase 1: Git-Ops Quick Wins (Day 1)
**Priority: HIGH | Risk: LOW | Impact: ~90 LOC**

#### 1.1 Extract Config Loading Workflow
**Files:** `lib/git-ops.sh`
**Occurrences:** 2 (lines 121-140, 535-564)
**Savings:** ~25 lines

**New Function:**
```bash
load_session_config() {
    local session_name="$1"
    # Extract from volume + merge with host config
    # Returns: project list in pipe-delimited format
}
```

**Callers:**
- `diff_multi_project_session()` line 121
- `merge_multi_project_session()` line 535

**Testing:**
- Unit test: config extraction with mock volume
- Integration: diff/merge operations produce same output

---

#### 1.2 Reuse get_session_status() for Commit Counting
**Files:** `lib/git-ops.sh`
**Occurrences:** 5 (lines 208-214, 231-239, 469-475, plus 1 correct usage at 483)
**Savings:** ~25 lines

**Existing Function:** `get_session_status()` already exists at line 14

**New Function for Discovered Repos:**
```bash
get_total_commits() {
    local volume="$1"
    local project_name="$2"
    # Returns total commit count (for discovered repos)
}
```

**Changes:**
- Replace inline commit counting at lines 208, 231, 469
- Add `get_total_commits()` for discovered repo case

**Testing:**
- Verify commit counts match before/after
- Test with empty repos, single commit, multiple commits

---

#### 1.3 Extract Show Session Commits
**Files:** `lib/git-ops.sh`
**Occurrences:** 4 (lines 152-161, 245-256, 486-497, 778-793)
**Savings:** ~40 lines

**New Function:**
```bash
show_session_commits() {
    local volume="$1"
    local project_path="$2"      # empty for single-project
    local format="${3:-oneline}" # oneline, count, full
    local indent="${4:-}"        # "  " for indented
    local limit="${5:-all}"      # number or "all"
}
```

**Callers:** Replace 4 docker run blocks

**Testing:**
- Compare output format before/after
- Test with/without commits
- Test indent and limit variations

---

### Phase 2: Git-Ops Medium Priority (Day 2-3)
**Priority: MEDIUM | Risk: LOW | Impact: ~65 LOC**

#### 2.1 Extract Show Diff vs Source
**Files:** `lib/git-ops.sh`
**Occurrences:** 2 (lines 164-176, 500-514)
**Savings:** ~19 lines

**New Function:**
```bash
show_diff_vs_source() {
    local volume="$1"
    local project_path="$2"
    local source_path="$3"
    local format="${4:-stat}"  # stat, summary, files, full
}
```

---

#### 2.2 Extract Session Type Dispatcher
**Files:** `lib/git-ops.sh`
**Occurrences:** 2 (lines 470-478, 742-750)
**Savings:** ~10 lines

**New Function:**
```bash
dispatch_session_operation() {
    local operation="$1"  # "diff" or "merge"
    local session_name="$2"
    # Validates session, dispatches to single/multi handler
}
```

**Impact:** Makes adding new operations (export, backup) trivial

---

#### 2.3 Add Helper for Discovered Repos
**Files:** `lib/git-ops.sh`
**Occurrences:** 3 (lines 206-227, 467-480, 543-550)
**Savings:** ~20 lines + consistency

**New Functions:**
```bash
is_discovered_repo() {
    local source="$1"
    [[ "$source" == "discovered" ]]
}

handle_discovered_repo_info() {
    local volume="$1"
    local project_name="$2"
    # Returns formatted info for discovered repo
}
```

---

### Phase 3: Docker Wrapper Utilities (Week 2)
**Priority: HIGH | Risk: MEDIUM | Impact: ~200 LOC**

#### 3.1 Create docker-utils.sh Module
**New File:** `lib/docker-utils.sh`

**Functions:**
```bash
# Generic docker run wrapper
docker_run_in_volume() {
    local volume="$1"
    local mount_point="${2:-/session}"
    local image="${3:-${IMAGE_NAME:-$DEFAULT_IMAGE}}"
    local command="$4"
    local readonly="${5:-true}"
}

# Git-specific wrapper
docker_run_git() {
    local volume="$1"
    local project_path="${2:-}"
    local git_command="$3"
}

# Volume mounting helper
mount_all_volumes() {
    local volumes=("$@")
    # Returns mount args string
}

# Volume size calculation
get_volume_sizes() {
    local volumes="$1"  # newline-separated
    # Returns name|size pairs
}
```

**Impact:**
- 35 docker run invocations → concise calls
- ~245 lines saved across all files
- Consistent error handling
- Easy to add logging, metrics

**Files Affected:**
- `lib/git-ops.sh` (16 invocations)
- `lib/session-mgmt.sh` (15 invocations)
- `lib/config.sh` (4 invocations)

**Risk:** High touch count, needs careful testing

---

### Phase 4: Collection Operation Utilities (Week 2-3)
**Priority: MEDIUM | Risk: LOW | Impact: ~100 LOC**

#### 4.1 Project Iteration Utilities
**File:** `lib/config.sh`

**Functions:**
```bash
for_each_project() {
    local projects="$1"
    local callback="$2"  # Function name
    # Iterates with consistent parsing
}

find_project() {
    local projects="$1"
    local target_name="$2"
    # Returns project line or exits 1
}

filter_tracked_projects() {
    local projects="$1"
    # Returns only tracked projects
}

is_project_tracked() {
    local track_flag="$1"
    # Boolean check
}
```

**Occurrences:** 7+ project parsing loops

---

#### 4.2 Volume Utilities
**File:** `lib/docker-utils.sh`

**Functions:**
```bash
extract_session_name() {
    local volume="$1"
    # Returns session name from volume name
}

map_volumes_to_sessions() {
    local volumes="$1"
    # Maps volume names to unique session names
}

filter_not_in_set() {
    local items="$1"
    local exclude_set="$2"
    # Set difference operation
}
```

**Impact:** Affects session-mgmt.sh volume operations

---

### Phase 5: Advanced Patterns (Week 3-4 - Optional)
**Priority: LOW | Risk: HIGH | Impact: ~100 LOC**

#### 5.1 Multi-Project Iterator with Callbacks
**File:** `lib/git-ops.sh`

This is the most complex refactor - extracting the iteration pattern from diff/merge.

**Function:**
```bash
for_each_multi_project() {
    local session_name="$1"
    local operation_callback="$2"
    shift 2
    local callback_args=("$@")

    # 1. Load config
    # 2. Parse to arrays
    # 3. Iterate with callback
}
```

**Benefit:** Makes diff and merge share 80% of code

**Risk:** Complex refactor, needs extensive testing

---

## Implementation Order

### Sprint 1 (Day 1-3): Git-Ops Quick Wins
1. Extract `load_session_config()` [Agent 1]
2. Reuse `get_session_status()` [Agent 2]
3. Extract `show_session_commits()` [Agent 3]
4. Extract `show_diff_vs_source()` [Agent 4]
5. Extract session dispatcher [Agent 5]

**Parallel execution:** Agents 1-5 can work simultaneously

### Sprint 2 (Week 2): Docker Utilities
6. Create `docker-utils.sh` with core functions [Agent 6]
7. Refactor git-ops.sh to use docker-utils [Agent 7]
8. Refactor session-mgmt.sh to use docker-utils [Agent 8]

**Sequential execution:** Agent 6 must complete before 7-8

### Sprint 3 (Week 2-3): Collection Utilities
9. Add project iteration utilities [Agent 9]
10. Add volume utilities [Agent 10]
11. Refactor callers [Agent 11]

**Sequential execution:** 9-10 before 11

### Sprint 4 (Week 3-4 - Optional): Advanced
12. Extract multi-project iterator [Agent 12]
13. Refactor diff/merge to use iterator [Agent 13]

---

## Testing Strategy

### Pre-Implementation
- ✓ Identify all call sites (grep patterns)
- ✓ Document current behavior
- ✓ Create test data (sessions with commits)

### During Implementation
- Unit test each extracted function
- Integration test original operations
- Compare outputs before/after

### Post-Implementation
- Full regression test suite
- Manual verification of key workflows
- Performance comparison (should be same or better)

### Test Matrix

| Operation | Single-Project | Multi-Project | Filtered | Discovered | Empty |
|-----------|---------------|---------------|----------|------------|-------|
| diff | ✓ | ✓ | ✓ | ✓ | ✓ |
| merge | ✓ | ✓ | N/A | ✓ | ✓ |
| list | ✓ | N/A | N/A | N/A | ✓ |
| delete | ✓ | N/A | N/A | N/A | ✓ |

---

## Risk Mitigation

### High-Risk Changes
- Docker wrapper refactors (35 call sites)
- Multi-project iterator (complex logic)

**Mitigation:**
- Implement in separate branch
- Extensive testing before merge
- Phased rollout (one file at a time)

### Medium-Risk Changes
- Config loading extraction (2 call sites)
- Session dispatcher (2 call sites)

**Mitigation:**
- Create function first, replace one call site
- Test that call site thoroughly
- Replace second call site

### Low-Risk Changes
- Show commits extraction (isolated utility)
- Reusing existing functions (get_session_status)

**Mitigation:**
- Standard unit testing
- Output comparison

---

## Success Metrics

### Code Quality
- [ ] ~400-500 lines removed
- [ ] No increase in complexity metrics
- [ ] All functions have clear docstrings
- [ ] No duplication in new code

### Functionality
- [ ] All existing tests pass
- [ ] New unit tests for extracted functions
- [ ] Integration tests for workflows
- [ ] Manual testing of key operations

### Performance
- [ ] No regression in execution time
- [ ] Docker call count same or reduced
- [ ] Memory usage unchanged

### Maintainability
- [ ] New operations easier to add
- [ ] Clear separation of concerns
- [ ] Consistent error handling
- [ ] Better testability

---

## Rollback Plan

Each phase can be rolled back independently:

1. **Git-Ops Quick Wins:** Revert git-ops.sh to previous version
2. **Docker Utilities:** Remove docker-utils.sh, revert callers
3. **Collection Utilities:** Revert individual files
4. **Advanced Patterns:** Most isolated, easy to revert

**Rollback triggers:**
- Tests fail after implementation
- Performance regression > 10%
- New bugs introduced
- Complexity increases significantly

---

## Documentation Updates

After implementation:

### Code Documentation
- [ ] Add function docstrings for all new functions
- [ ] Update file headers with new dependencies
- [ ] Add usage examples in comments

### User Documentation
- [ ] No user-facing changes (internal refactor)
- [ ] Update CONTRIBUTING.md with new patterns
- [ ] Add ARCHITECTURE.md with module overview

### Developer Documentation
- [ ] Update this document with actual results
- [ ] Document any deviations from plan
- [ ] Create PATTERNS.md with reusable patterns

---

## Agent Task Assignments

### Sprint 1 Agents (Parallel)

**Agent 1: Config Loading**
- Extract `load_session_config()` in git-ops.sh
- Replace 2 call sites
- Add unit tests

**Agent 2: Commit Counting**
- Add `get_total_commits()` for discovered repos
- Replace 4 inline commit counting blocks with `get_session_status()`
- Verify commit counts match

**Agent 3: Show Commits**
- Extract `show_session_commits()` with format/indent options
- Replace 4 docker run blocks
- Test output formatting

**Agent 4: Show Diff**
- Extract `show_diff_vs_source()`
- Replace 2 call sites
- Test diff output

**Agent 5: Dispatcher**
- Extract `dispatch_session_operation()`
- Update diff_git_session and merge_git_session
- Test routing logic

### Sprint 2 Agents (Sequential)

**Agent 6: Docker Utils Module**
- Create lib/docker-utils.sh
- Implement docker_run_git, docker_run_in_volume
- Add tests

**Agent 7: Refactor Git-Ops Docker Calls**
- Replace 16 docker run calls in git-ops.sh
- Use docker-utils functions
- Verify behavior unchanged

**Agent 8: Refactor Session-Mgmt Docker Calls**
- Replace 15 docker run calls in session-mgmt.sh
- Use docker-utils functions
- Test session operations

---

## Current Status

- [x] Architectural audit completed
- [x] Git-ops workflow audit completed
- [x] Implementation plan created
- [ ] Sprint 1: Git-ops quick wins
- [ ] Sprint 2: Docker utilities
- [ ] Sprint 3: Collection utilities
- [ ] Sprint 4: Advanced patterns

---

## Notes

### Already Completed
- Merge function consolidation (merge_session_project, worktree utilities, patch utilities)
- This was the proof-of-concept that validates our approach

### Lessons Learned from Merge Refactor
1. Extract atomic operations first (patches, worktree)
2. Create shared orchestration function
3. Update callers incrementally
4. Preserve all existing behavior
5. Add clear documentation

**Apply same pattern** to remaining consolidations.

### Key Insight
The codebase follows good patterns but has natural duplication from:
- Single-project → multi-project evolution
- Feature additions over time
- Similar operations (diff vs merge)

Consolidation will make the architecture explicit and consistent.
