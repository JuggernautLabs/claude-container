# Git-Ops Workflow Consolidation Audit

## Executive Summary

The git-ops module shows **excellent workflow architecture** but has **7 major workflow patterns** that are duplicated across functions. The core issue is that **diff** and **merge** operations follow nearly identical workflows but duplicate the orchestration code.

**Key Finding:** The single vs multi-project dispatch pattern is repeated, and the multi-project operations share 80% of their workflow structure. This represents ~200-300 lines that could be consolidated.

---

## 1. SESSION TYPE DISPATCH PATTERN

### Current State: Duplicated Dispatcher (2 occurrences)

**Location:**
- `diff_git_session()` lines 470-478
- `merge_git_session()` lines 742-750

**Pattern:**
```bash
# Check if session exists
if ! docker volume inspect "$volume" &>/dev/null; then
    error "Session not found: $name"
    exit 1
fi

# Check if this is a multi-project session
if has_multi_project_config "$volume"; then
    [operation]_multi_project_session "$name" "$target_dir" "$@"
    return $?
fi

# ... single-project implementation ...
```

**Consolidation Strategy:**

```bash
# Generic session operation dispatcher
dispatch_session_operation() {
    local operation="$1"     # "diff" or "merge"
    local session_name="$2"
    shift 2
    local remaining_args=("$@")

    local volume="claude-session-${session_name}"

    # Check if session exists
    if ! docker volume inspect "$volume" &>/dev/null; then
        error "Session not found: $session_name"
        exit 1
    fi

    # Dispatch to multi or single-project handler
    if has_multi_project_config "$volume"; then
        "${operation}_multi_project_session" "$session_name" "${remaining_args[@]}"
    else
        "${operation}_single_project_session" "$session_name" "${remaining_args[@]}"
    fi
}

# Refactored public interface
diff_git_session() {
    dispatch_session_operation "diff" "$@"
}

merge_git_session() {
    dispatch_session_operation "merge" "$@"
}
```

**Impact:** Eliminates 20+ lines of duplicate validation, centralizes session type detection.

**Benefits:**
- Single place to add new session validation
- Easy to add new operations (export, backup, etc.)
- Consistent error messages
- Testable dispatch logic

---

## 2. CONFIG LOADING WORKFLOW

### Current State: Duplicated Config Extraction (2 identical occurrences)

**Location:**
- `diff_multi_project_session()` lines 121-140
- `merge_multi_project_session()` lines 535-564

**Pattern:**
```bash
# Extract config from volume (single docker call)
local config_data
config_data=$(docker run --rm \
    -v "$volume:/session:ro" \
    --entrypoint sh \
    "$git_image" \
    -c 'cat /session/.claude-projects.yml' 2>/dev/null) || {
    error "Failed to read config from session volume"
    exit 1
}

# Parse config from session volume
local temp_config="$CACHE_DIR/temp-config-$$.yml"
mkdir -p "$CACHE_DIR"
echo "$config_data" > "$temp_config"

local projects
projects=$(parse_config_file "$temp_config")
rm -f "$temp_config"

# Also check host config dir for discovered repos
local host_config="$SESSIONS_CONFIG_DIR/${name}.yml"
if [[ -f "$host_config" ]]; then
    local host_projects
    host_projects=$(parse_config_file "$host_config" 2>/dev/null) || true
    if [[ -n "$host_projects" ]]; then
        projects="${projects}
${host_projects}"
    fi
fi
```

**Red Flag:** This is a **complete workflow** (15+ lines) duplicated exactly twice.

**Consolidation Strategy:**

```bash
# Load and merge config from volume and host
# Returns: project list in pipe-delimited format
load_session_config() {
    local session_name="$1"
    local volume="claude-session-${session_name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    # Extract config from volume
    local config_data
    config_data=$(docker run --rm \
        -v "$volume:/session:ro" \
        --entrypoint sh \
        "$git_image" \
        -c 'cat /session/.claude-projects.yml' 2>/dev/null) || {
        error "Failed to read config from session volume"
        return 1
    }

    # Parse volume config
    local temp_config="$CACHE_DIR/temp-config-$$.yml"
    mkdir -p "$CACHE_DIR"
    echo "$config_data" > "$temp_config"
    trap "rm -f '$temp_config'" RETURN

    local projects
    projects=$(parse_config_file "$temp_config")

    # Merge with host config if present
    local host_config="$SESSIONS_CONFIG_DIR/${session_name}.yml"
    if [[ -f "$host_config" ]]; then
        local host_projects
        host_projects=$(parse_config_file "$host_config" 2>/dev/null) || true
        if [[ -n "$host_projects" ]]; then
            projects="${projects}
${host_projects}"
        fi
    fi

    echo "$projects"
}

# Usage (before):
config_data=$(docker run ...)
echo "$config_data" > "$temp_config"
projects=$(parse_config_file "$temp_config")
# ... 15 more lines ...

# Usage (after):
projects=$(load_session_config "$session_name")
```

**Impact:** Eliminates 30+ lines (2 × 15), makes config loading a first-class operation.

**Benefits:**
- Single place to modify config loading strategy
- Can add caching easily
- Can add config validation
- Can add config version migration
- Testable in isolation

---

## 3. SHOW SESSION COMMITS WORKFLOW

### Current State: Duplicated Git Log Operations (4 variations)

**Locations:**
1. `diff_multi_project_session()` filtered - lines 152-161
2. `diff_multi_project_session()` summary - lines 245-256
3. `diff_git_session()` - lines 486-497
4. `merge_git_session()` - lines 778-793

**Pattern Variations:**

**Variation 1: Detailed log (diff filtered)**
```bash
docker run --rm \
    -v "$volume:/session:ro" \
    "$git_image" \
    sh -c "
        git config --global --add safe.directory '*'
        cd /session/$project_name
        initial=\$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
        git log --oneline \"\$initial\"..HEAD 2>/dev/null || git log --oneline -10
    "
```

**Variation 2: Summary log with indent (diff summary)**
```bash
docker run --rm \
    -v "$volume:/session:ro" \
    "$git_image" \
    sh -c '
        git config --global --add safe.directory "*"
        cd /session/'"$project_name"'
        initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
        git log --oneline "$initial..HEAD" 2>/dev/null | sed "s/^/  /"
    ' < /dev/null
```

**Variation 3: Single-project log (diff single)**
```bash
docker run --rm \
    -v "$volume:/session:ro" \
    "$git_image" \
    sh -c '
        git config --global --add safe.directory "*"
        cd /session
        initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
        git log --oneline "$initial"..HEAD 2>/dev/null || git log --oneline -10
    '
```

**Variation 4: With count check (merge single)**
```bash
docker run --rm \
    -v "$volume:/session:ro" \
    "$git_image" \
    sh -c '
        git config --global --add safe.directory "*"
        cd /session
        INITIAL=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
        COUNT=$(git rev-list --count "$INITIAL..HEAD" 2>/dev/null || echo "0")
        if [ "$COUNT" = "0" ]; then
            echo "(no commits)"
        else
            git log --oneline "$INITIAL..HEAD" 2>/dev/null
        fi
    '
```

**Consolidation Strategy:**

```bash
# Show commits in a session project
# Arguments:
#   $1 - volume name
#   $2 - project path (empty for single-project)
#   $3 - format: "oneline" (default), "count", "full"
#   $4 - indent: "" (default), "  ", etc.
#   $5 - limit: number of commits or "all" (default)
show_session_commits() {
    local volume="$1"
    local project_path="$2"
    local format="${3:-oneline}"
    local indent="${4:-}"
    local limit="${5:-all}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    local cd_path="/session${project_path:+/$project_path}"
    local sed_cmd=""
    [[ -n "$indent" ]] && sed_cmd=" | sed 's/^/$indent/'"

    local git_cmd=""
    case "$format" in
        count)
            git_cmd='
                INITIAL=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                git rev-list --count "$INITIAL..HEAD" 2>/dev/null || echo "0"
            '
            ;;
        full)
            git_cmd='
                INITIAL=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                git log --pretty=fuller "$INITIAL..HEAD" 2>/dev/null
            '
            ;;
        oneline|*)
            local fallback=""
            [[ "$limit" != "all" ]] && fallback="|| git log --oneline -$limit"
            git_cmd='
                INITIAL=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
                git log --oneline "$INITIAL..HEAD" 2>/dev/null '"$fallback"'
            '
            ;;
    esac

    docker run --rm \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c "
            git config --global --add safe.directory '*'
            cd $cd_path
            $git_cmd $sed_cmd
        " 2>/dev/null
}

# Usage examples:
# Before: 8 lines of boilerplate × 4 = 32 lines
# After:
show_session_commits "$volume" "$project_name" "oneline" ""
show_session_commits "$volume" "$project_name" "oneline" "  "
show_session_commits "$volume" "" "oneline" "" "10"
show_session_commits "$volume" "" "count" ""
```

**Impact:** Eliminates 50+ lines across 4 locations.

**Benefits:**
- Consistent output formatting
- Easy to add new formats (json, summary, etc.)
- Single place to optimize performance
- Reusable for new features (export, backup, etc.)

---

## 4. SHOW DIFF VS SOURCE WORKFLOW

### Current State: Duplicated Diff Comparison (2 identical occurrences)

**Location:**
- `diff_multi_project_session()` filtered - lines 164-176
- `diff_git_session()` - lines 500-514

**Pattern:**
```bash
docker run --rm \
    -v "$source_path:/source:ro" \
    -v "$volume:/session:ro" \
    "$git_image" \
    sh -c "
        git config --global --add safe.directory '*'
        cd /session/$project_name
        git remote add source /source 2>/dev/null || true
        git fetch source --quiet 2>/dev/null || true
        git diff --stat source/HEAD HEAD 2>/dev/null || \
            echo '  (unable to compare - source may not be a git repo)'
    "
```

**Consolidation Strategy:**

```bash
# Compare session project with source repository
# Arguments:
#   $1 - volume name
#   $2 - project path in session (empty for single-project)
#   $3 - source path on host
#   $4 - diff format: "stat" (default), "summary", "files", "full"
show_diff_vs_source() {
    local volume="$1"
    local project_path="$2"
    local source_path="$3"
    local format="${4:-stat}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    local cd_path="/session${project_path:+/$project_path}"

    local diff_cmd="git diff --stat source/HEAD HEAD"
    case "$format" in
        summary) diff_cmd="git diff --shortstat source/HEAD HEAD" ;;
        files) diff_cmd="git diff --name-status source/HEAD HEAD" ;;
        full) diff_cmd="git diff source/HEAD HEAD" ;;
    esac

    docker run --rm \
        -v "$source_path:/source:ro" \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c "
            git config --global --add safe.directory '*'
            cd $cd_path
            git remote add source /source 2>/dev/null || true
            git fetch source --quiet 2>/dev/null || true
            $diff_cmd 2>/dev/null || \
                echo '  (unable to compare - source may not be a git repo)'
        " 2>/dev/null
}

# Usage:
# Before: 12 lines × 2 = 24 lines
# After:
show_diff_vs_source "$volume" "$project_name" "$source_path" "stat"
show_diff_vs_source "$volume" "" "$source_dir" "stat"
```

**Impact:** Eliminates 24 lines, adds flexibility for different diff formats.

---

## 5. GET INITIAL COMMIT PATTERN

### Current State: Inline Git Command (7 occurrences)

**Locations:** Lines 28, 159, 237, 251, 363, 494, 786

**Pattern:**
```bash
initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
INITIAL=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
```

**Note:** This is used inside docker containers, so can't be extracted to bash function directly. But it's part of the show_session_commits consolidation above.

**Consolidation:** Already handled by `show_session_commits()` abstraction.

---

## 6. COUNT COMMITS WORKFLOW

### Current State: Duplicated Commit Counting (5 variations)

**Locations:**
1. `get_session_status()` - lines 27-30 (function exists!)
2. `diff_multi_project_session()` discovered - lines 208-214
3. `diff_multi_project_session()` summary - lines 231-239
4. `merge_multi_project_session()` discovered - lines 469-475
5. `merge_multi_project_session()` arrays - line 483 (uses get_session_status!)

**Observation:** `get_session_status()` already exists but is only used in merge! Diff operations duplicate the logic.

**Current get_session_status:**
```bash
get_session_status() {
    local volume="$1"
    local project_name="$2"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    docker run --rm \
        -v "$volume:/session:ro" \
        --entrypoint sh \
        "$git_image" \
        -c '
            git config --global --add safe.directory "*"
            cd /session/'"$project_name"' 2>/dev/null || exit 1

            # Count all commits from initial commit to HEAD
            INITIAL=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
            git rev-list --count "$INITIAL..HEAD" 2>/dev/null || echo "0"
        ' 2>/dev/null || echo "0"
}
```

**Consolidation Strategy:**

**REUSE EXISTING FUNCTION!** Just use `get_session_status()` everywhere instead of inline commands.

**Replace inline count in diff_multi_project_session (line 231):**
```bash
# Before:
commit_count=$(docker run --rm \
    -v "$volume:/session:ro" \
    "$git_image" \
    sh -c '
        git config --global --add safe.directory "*"
        cd /session/'"$project_name"' 2>/dev/null || exit 0
        initial=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
        git rev-list --count "$initial..HEAD" 2>/dev/null || echo 0
    ' < /dev/null) || echo "0"

# After:
commit_count=$(get_session_status "$volume" "$project_name")
```

**For discovered repos (special case):**
```bash
# Enhance get_session_status or create variant
get_total_commits() {
    local volume="$1"
    local project_name="$2"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    docker run --rm \
        -v "$volume:/session:ro" \
        "$git_image" \
        sh -c "
            git config --global --add safe.directory '*'
            cd /session/$project_name 2>/dev/null && git rev-list --count HEAD 2>/dev/null || echo 0
        " 2>/dev/null || echo "0"
}
```

**Impact:** Reusing existing function eliminates 30+ lines of duplicate docker commands.

**Benefits:**
- Already exists, just needs wider adoption
- Consistent status checking
- Single place to optimize
- Could add caching

---

## 7. MULTI-PROJECT OPERATION WORKFLOW STRUCTURE

### Current State: Diff and Merge Share 80% Structure

Both `diff_multi_project_session()` and `merge_multi_project_session()` follow this structure:

```
1. Load config (identical)
2. Parse projects to arrays (identical)
3. Display header
4. For each project:
   a. Skip untracked (identical logic)
   b. Handle discovered repos (similar logic)
   c. Get commit count (identical)
   d. Display/process project (operation-specific)
5. Show summary/perform action
```

**The only difference** between diff and merge is step 4d and 5 (the actual operation).

**Consolidation Strategy:**

```bash
# Generic multi-project iterator with operation callback
for_each_multi_project() {
    local session_name="$1"
    local operation_callback="$2"  # Function to call for each project
    shift 2
    local callback_args=("$@")

    local volume="claude-session-${session_name}"

    # 1. Load config (centralized)
    local projects
    projects=$(load_session_config "$session_name") || return 1

    # 2. Parse to arrays (could be extracted further)
    local -a project_names=()
    local -a project_paths=()
    local -a project_branches=()
    local -a project_track=()
    local -a project_source=()

    while IFS='|' read -r pname ppath pbranch ptrack psource; do
        project_names+=("$pname")
        project_paths+=("$ppath")
        project_branches+=("$pbranch")
        project_track+=("${ptrack:-true}")
        project_source+=("${psource:-}")
    done <<< "$projects"

    # 3. Iterate and callback
    for i in "${!project_names[@]}"; do
        local pname="${project_names[$i]}"
        local ppath="${project_paths[$i]}"
        local pbranch="${project_branches[$i]}"
        local ptrack="${project_track[$i]}"
        local psource="${project_source[$i]}"

        # Skip untracked
        [[ "$ptrack" != "true" ]] && continue

        # Call operation-specific handler
        "$operation_callback" "$i" "$pname" "$ppath" "$pbranch" "$psource" "${callback_args[@]}"
    done
}

# Diff handler
diff_project_callback() {
    local index="$1"
    local name="$2"
    local path="$3"
    local branch="$4"
    local source="$5"
    local volume="$6"

    if [[ "$source" == "discovered" ]]; then
        local count=$(get_total_commits "$volume" "$name")
        echo "Project: $name (NEW - $count commits)"
        show_session_commits "$volume" "$name" "oneline" "  " 5
    else
        local count=$(get_session_status "$volume" "$name")
        echo "Project: $name ($count commits)"
        [[ $count -gt 0 ]] && show_session_commits "$volume" "$name" "oneline" "  "
    fi
    echo ""
}

# Merge handler
merge_project_callback() {
    local index="$1"
    local name="$2"
    local path="$3"
    local branch="$4"
    local source="$5"
    local volume="$6"
    local target_branch="$7"
    local from_branch="$8"
    local git_image="$9"

    if [[ "$source" == "discovered" ]]; then
        extract_repo_from_session "$volume" "$name" "$path" "$git_image"
    else
        local worktree
        worktree=$(create_or_find_worktree "$path" "$target_branch" "$from_branch" "$name")
        merge_session_project "$volume" "$name" "$worktree" "$git_image"
        cleanup_worktree "$path" "$worktree" "$created_worktree" "$name"
    fi
}

# Public interface
diff_multi_project_session() {
    local name="$1"
    local volume="claude-session-${name}"

    info "Multi-project session: $name"
    echo ""

    for_each_multi_project "$name" diff_project_callback "$volume"
}

merge_multi_project_session() {
    local name="$1"
    local target_dir="$2"
    local target_branch="${3:-$name}"
    local auto_mode="${4:-false}"
    local no_run="${5:-false}"
    local from_branch="${6:-HEAD}"
    local volume="claude-session-${name}"
    local git_image="${IMAGE_NAME:-$DEFAULT_IMAGE}"

    info "Merging multi-project session: $name"

    # Preview phase
    for_each_multi_project "$name" merge_preview_callback "$volume"

    # Confirm and execute
    read -p "Merge all? [y/n] " choice
    [[ "$choice" != "y" ]] && return 0

    for_each_multi_project "$name" merge_project_callback "$volume" "$target_branch" "$from_branch" "$git_image"
}
```

**Impact:** This is a bigger refactor, but would eliminate 100+ lines and make the code much more maintainable.

**Benefits:**
- New operations (export, backup) trivial to add
- Consistent project iteration logic
- Easier testing (mock callbacks)
- Clearer separation of concerns

---

## Summary: Consolidation Opportunities

| Workflow Pattern | Occurrences | Current LOC | Target LOC | Savings | Priority |
|-----------------|-------------|-------------|------------|---------|----------|
| Config Loading | 2 | 30 | 5 (call) | 25 | HIGH |
| Session Dispatch | 2 | 20 | 10 (func) | 10 | HIGH |
| Show Commits | 4 | 50 | 10 (func) | 40 | HIGH |
| Show Diff vs Source | 2 | 24 | 5 (call) | 19 | MEDIUM |
| Count Commits | 5 | 30 | 5 (reuse existing) | 25 | HIGH |
| Multi-Project Iterator | 2 | 150 | 50 (callbacks) | 100 | MEDIUM |
| **TOTAL** | **17** | **~304** | **~85** | **~219** | |

---

## Recommended Action Plan

### Phase 1: Quick Wins (Day 1)
1. **Reuse `get_session_status()`** everywhere instead of inline commit counting
2. **Extract `load_session_config()`** - affects both diff and merge
3. **Extract `show_session_commits()`** - affects 4 locations

**Expected savings:** ~90 lines, ~3 hours work

### Phase 2: Structural Improvements (Day 2-3)
4. **Extract `show_diff_vs_source()`**
5. **Extract `dispatch_session_operation()`**
6. **Add `get_total_commits()`** for discovered repos

**Expected savings:** ~50 lines, ~4 hours work

### Phase 3: Advanced (Week 2 - Optional)
7. **Extract `for_each_multi_project()`** with callbacks
8. **Refactor diff/merge to use iterator**

**Expected savings:** ~100 lines, but requires careful refactoring

---

## Testing Strategy

For each extraction:

### 1. Unit Test the New Function
```bash
# Test load_session_config
test_load_config() {
    local result=$(load_session_config "test-session")
    assert_contains "$result" "project1|"
}
```

### 2. Integration Test
- Create test session with known commits
- Run diff before/after refactor
- Compare outputs (should be identical)

### 3. Regression Test Matrix

| Operation | Single Project | Multi Project | With Filter | Discovered Repos |
|-----------|---------------|---------------|-------------|------------------|
| Diff | ✓ | ✓ | ✓ | ✓ |
| Merge | ✓ | ✓ | N/A | ✓ |

---

## Additional Observations

### 1. The Refactoring We Just Did Was Perfect

The extraction of `merge_session_project()` and related functions (worktree, patches) was **exactly the right approach**. It:
- Removed duplication between single and multi-project merge
- Created reusable, testable functions
- Preserved all behavior
- Made the code self-documenting

**We should apply the same pattern** to diff operations and config loading.

### 2. Diff Operations Need Similar Treatment

Currently:
- `diff_git_session()` has inline docker commands
- `diff_multi_project_session()` duplicates the same commands
- No shared diff logic between them

Should create:
- `show_session_diff()` - shows diff for one project
- Reuse in both single and multi-project diff

### 3. Config Loading is a First-Class Operation

Config loading appears in:
- Diff operations (read-only)
- Merge operations (read + merge with host)
- Session scanning (discovery)

It deserves its own utility function, not inline code.

### 4. The Multi-Project Iterator Pattern

Both diff and merge iterate over projects with:
- Same parsing logic
- Same filtering (tracked/untracked)
- Same discovered repo detection
- Different operations per project

This is a perfect candidate for the **strategy pattern** with callbacks.

---

## Anti-Patterns to Avoid

1. **Don't extract too early** - The multi-project iterator is complex, do simpler extractions first
2. **Don't break error handling** - Config loading errors must still exit properly
3. **Don't change behavior** - Output format must stay identical for scripts that parse it
4. **Don't over-parameterize** - If a function needs 8 parameters, it's probably wrong

---

## Conclusion

The git-ops module is **well-structured** but has **natural duplication** from the single→multi-project evolution. The refactoring of merge operations shows the right path forward.

**Highest ROI:**
1. Config loading extraction (2 occurrences, clear interface)
2. Reuse get_session_status (5 occurrences, function exists!)
3. Show commits extraction (4 occurrences, common operation)

These three changes alone would eliminate **~90 lines** and significantly improve maintainability, taking ~1 day of focused work.

The multi-project iterator is a bigger win (~100 lines) but requires more careful design. Consider it for Phase 3 after the quick wins are proven.
