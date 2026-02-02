# Architectural Audit: Collection Operations & Code Deduplication

## Executive Summary

This audit identified **9 major pattern categories** with **significant duplication** across the codebase:
- **35+ docker run invocations** with repeated structure
- **15+ array iteration loops** processing project configurations
- **Multiple while-read loops** parsing the same pipe-delimited format
- **Repeated volume-to-collection transformations**
- **Duplicated filtering and partitioning logic**

**Estimated duplication:** ~400-500 lines that could be reduced to ~150 lines through systematic extraction.

---

## 1. MAP PATTERNS: Transform Each Element

### Pattern: Docker Volume Name Extraction

**Found in:** `lib/session-mgmt.sh`

**Current Implementation (Repeated 3x):**
```bash
# Line 175-186: Extract session names from volumes
while read -r vol; do
    [[ -z "$vol" ]] && continue
    local session_name=""
    case "$vol" in
        claude-session-*) session_name="${vol#claude-session-}" ;;
        claude-state-*)   session_name="${vol#claude-state-}" ;;
        claude-cargo-*)   session_name="${vol#claude-cargo-}" ;;
        claude-npm-*)     session_name="${vol#claude-npm-}" ;;
        claude-pip-*)     session_name="${vol#claude-pip-}" ;;
    esac
    [[ -n "$session_name" ]] && sessions[$session_name]=1
done <<< "$all_volumes"
```

**Consolidation Strategy:**
```bash
# Utility function in utils.sh
extract_session_name() {
    local volume="$1"
    case "$volume" in
        claude-session-*) echo "${volume#claude-session-}" ;;
        claude-state-*)   echo "${volume#claude-state-}" ;;
        claude-cargo-*)   echo "${volume#claude-cargo-}" ;;
        claude-npm-*)     echo "${volume#claude-npm-}" ;;
        claude-pip-*)     echo "${volume#claude-pip-}" ;;
    esac
}

# Map volumes to session names (single pipeline)
map_volumes_to_sessions() {
    local volumes="$1"
    echo "$volumes" | while read -r vol; do
        [[ -z "$vol" ]] && continue
        local name=$(extract_session_name "$vol")
        [[ -n "$name" ]] && echo "$name"
    done | sort -u
}
```

**Impact:** Used in `session_list()`, `session_delete()`, pattern appears 3 times.

---

### Pattern: Project Config Parsing

**Found in:** `lib/git-ops.sh` (lines 145, 184, 196, 441), `lib/config.sh` (lines 177, 254, 336)

**Current Implementation (Repeated 7x):**
```bash
while IFS='|' read -r project_name source_path _branch project_track project_source; do
    # Process each project...
done <<< "$projects"
```

**Red Flag:** Same IFS pattern, same pipe-delimited format, scattered across 2 files. This is a **hidden map operation**.

**Consolidation Strategy:**
```bash
# In config.sh - create project iterator utilities
for_each_project() {
    local projects="$1"
    local callback="$2"  # Function name to call for each project

    while IFS='|' read -r proj_name proj_path proj_branch proj_track proj_source; do
        [[ -z "$proj_name" ]] && continue
        "$callback" "$proj_name" "$proj_path" "$proj_branch" "$proj_track" "$proj_source"
    done <<< "$projects"
}

# Usage
process_project() {
    local name="$1" path="$2" branch="$3" track="$4" source="$5"
    info "Processing: $name at $path"
}

for_each_project "$projects" process_project
```

**Alternative - Array-based:**
```bash
# Parse once into arrays (current pattern in merge_multi_project_session)
parse_projects_to_arrays() {
    local projects="$1"
    # Declare arrays in caller's scope (use eval or return serialized)
    while IFS='|' read -r pname ppath pbranch ptrack psource; do
        project_names+=("$pname")
        project_paths+=("$ppath")
        # ...
    done <<< "$projects"
}
```

**Impact:** 7+ occurrences, ~70-100 lines could be centralized.

---

## 2. FILTER PATTERNS: Select Subset

### Pattern: Volume Filtering by Usage

**Found in:** `lib/session-mgmt.sh:69-76`

**Current Implementation:**
```bash
# Filter unused volumes (manual loop with conditional add)
local unused_volumes=()
while read -r vol; do
    [[ -z "$vol" ]] && continue
    if echo "$used_volumes" | grep -q "^${vol}$"; then
        : # Volume is in use, skip
    else
        unused_volumes+=("$vol")
    fi
done <<< "$all_volumes"
```

**Red Flag:** This is `filter(vol => !isUsed(vol))` written as a 9-line loop.

**Consolidation Strategy:**
```bash
# Utility for set operations
filter_not_in_set() {
    local items="$1"
    local exclude_set="$2"

    echo "$items" | while read -r item; do
        [[ -z "$item" ]] && continue
        echo "$exclude_set" | grep -q "^${item}$" || echo "$item"
    done
}

# Usage
unused_volumes=$(filter_not_in_set "$all_volumes" "$used_volumes")
```

**Impact:** Pattern could be reused for filtering repos, branches, etc.

---

### Pattern: Tracked vs Untracked Projects

**Found in:** `lib/git-ops.sh:197-202, 459-464, 532-535`

**Current Implementation (Repeated 3x):**
```bash
# Skip untracked projects
if [[ "${project_track:-true}" != "true" ]]; then
    echo "  [-] $pname (untracked)"
    # Skip or handle differently
    continue
fi
```

**Consolidation Strategy:**
```bash
# In config.sh
is_project_tracked() {
    local track_flag="$1"
    [[ "${track_flag:-true}" == "true" ]]
}

filter_tracked_projects() {
    local projects="$1"
    while IFS='|' read -r pname ppath pbranch ptrack psource; do
        is_project_tracked "$ptrack" && echo "$pname|$ppath|$pbranch|$ptrack|$psource"
    done <<< "$projects"
}
```

**Impact:** 3 occurrences, consistent predicate extraction.

---

## 3. PARTITION PATTERNS: Split into Groups

### Pattern: Known vs New Repos

**Found in:** `lib/session-mgmt.sh:736-746`

**Current Implementation:**
```bash
local known_repos=()
local new_repos=()

while read -r repo; do
    [[ -z "$repo" ]] && continue
    if echo "$config_repos" | grep -q "^${repo}$"; then
        known_repos+=("$repo")
    else
        new_repos+=("$repo")
    fi
done <<< "$repos_in_session"
```

**Red Flag:** Classic partition operation written as manual if/else.

**Consolidation Strategy:**
```bash
# Generic partition utility
partition() {
    local items="$1"
    local predicate_func="$2"

    local passing=()
    local failing=()

    while read -r item; do
        [[ -z "$item" ]] && continue
        if "$predicate_func" "$item"; then
            passing+=("$item")
        else
            failing+=("$item")
        fi
    done <<< "$items"

    # Return both arrays (caller must use array name references)
    echo "PASSING:${passing[*]}"
    echo "FAILING:${failing[*]}"
}
```

**Impact:** Single occurrence but pattern could be reused for success/failure tracking, committed/uncommitted files, etc.

---

## 4. DOCKER RUN PATTERN CONSOLIDATION

### Pattern: Repeated Docker Container Structure

**Found:** 35+ invocations across all lib files

**Common Structure:**
```bash
docker run --rm \
    -v "$volume:/session:ro" \
    "$git_image" \
    sh -c '
        git config --global --add safe.directory "*"
        cd /session'"$project_path"'
        # ... command ...
    ' 2>/dev/null
```

**Repeated Elements:**
1. `--rm` flag (cleanup)
2. Volume mount patterns (`$volume:/session:ro`)
3. Git safe.directory configuration
4. Error redirection (`2>/dev/null`)
5. Image variable (`$git_image` or `alpine`)

**Consolidation Strategy:**

```bash
# In docker.sh or new lib/docker-utils.sh

# Generic docker run wrapper
docker_run_in_volume() {
    local volume="$1"
    local mount_point="${2:-/session}"
    local image="${3:-${IMAGE_NAME:-$DEFAULT_IMAGE}}"
    local command="$4"
    local readonly="${5:-true}"

    local mount_flag="-v $volume:$mount_point"
    [[ "$readonly" == "true" ]] && mount_flag="$mount_flag:ro"

    docker run --rm $mount_flag "$image" sh -c "$command" 2>/dev/null
}

# Git-specific wrapper
docker_run_git() {
    local volume="$1"
    local project_path="${2:-}"
    local git_command="$3"

    local full_command="
        git config --global --add safe.directory '*'
        cd /session${project_path:+/$project_path}
        $git_command
    "

    docker_run_in_volume "$volume" "/session" "${IMAGE_NAME:-$DEFAULT_IMAGE}" "$full_command"
}

# Usage examples:
# Old: 8 lines of boilerplate
commit_count=$(docker run --rm \
    -v "$volume:/session:ro" \
    "$git_image" \
    sh -c '
        git config --global --add safe.directory "*"
        cd /session/'"$project_name"'
        git rev-list --count "$INITIAL..HEAD"
    ' 2>/dev/null)

# New: 1 line
commit_count=$(docker_run_git "$volume" "$project_name" \
    'INITIAL=$(git rev-list --max-parents=0 HEAD | tail -1); git rev-list --count "$INITIAL..HEAD"')
```

**Impact:** Could reduce ~280 lines (35 invocations × ~8 lines each) to ~35 lines (35 calls × ~1 line).

---

## 5. SIDE-EFFECT ITERATION: Batch Operations

### Pattern: Volume Size Calculation

**Found in:** `lib/session-mgmt.sh:94-124, 188-214`

**Current Implementation (Repeated 2x):**
```bash
# Build mount arguments for all volumes
local mount_args=""
for vol in "${volumes[@]}"; do
    mount_args="$mount_args -v $vol:/$vol"
done

# Single docker run to get all sizes
sizes=$(docker run --rm $mount_args alpine sh -c '
    for dir in /claude-*/; do
        name=$(basename "$dir")
        size=$(du -sh "$dir" | cut -f1)
        echo "$name $size"
    done
')
```

**Observation:** This is already partially optimized (batch operation instead of per-volume), but pattern is duplicated.

**Consolidation Strategy:**
```bash
# In docker-utils.sh
mount_all_volumes() {
    local volumes=("$@")
    local mount_args=""
    for vol in "${volumes[@]}"; do
        mount_args="$mount_args -v $vol:/$vol:ro"
    done
    echo "$mount_args"
}

get_volume_sizes() {
    local volumes="$1"  # newline-separated
    local mount_args=$(mount_all_volumes $volumes)

    docker run --rm $mount_args alpine sh -c '
        for dir in /claude-*/ /session-data-*/; do
            [ -d "$dir" ] || continue
            echo "$(basename "$dir")|$(du -sh "$dir" | cut -f1)"
        done
    '
}
```

**Impact:** 2 occurrences, ~40 lines → ~10 lines.

---

## 6. REDUCE/FOLD PATTERN: Build Lookup Tables

### Pattern: Volume to Size Mapping

**Found in:** `lib/session-mgmt.sh:210-214`

**Current Implementation:**
```bash
# Parse sizes into associative array (manual reduce)
declare -A vol_sizes
while read -r vol size; do
    [[ -z "$vol" ]] && continue
    vol_sizes[$vol]="$size"
done <<< "$sizes"
```

**Red Flag:** This is `reduce(acc, item => acc[item.key] = item.value)`.

**Consolidation Strategy:**
```bash
# Generic key-value builder
build_lookup_table() {
    local input="$1"
    local delimiter="${2:-|}"

    declare -gA LOOKUP_TABLE  # Global associative array
    while IFS="$delimiter" read -r key value rest; do
        [[ -z "$key" ]] && continue
        LOOKUP_TABLE[$key]="$value"
    done <<< "$input"
}

# Usage:
build_lookup_table "$sizes" " "
echo "${LOOKUP_TABLE[claude-session-foo]}"
```

**Impact:** Could standardize all key-value parsing (volumes→sizes, projects→paths, etc.).

---

## 7. REPEATED CONDITIONAL LOGIC

### Pattern: Project Source Type Handling

**Found in:** `lib/git-ops.sh:271-293, 467-480, 543-550`

**Current Implementation (Repeated 3x):**
```bash
# Handle discovered repos (new repos created in session)
if [[ "$project_source" == "discovered" ]]; then
    # Get commit count
    commit_count=$(docker run ...)
    echo "  [+] $pname (NEW - $commit_count commits, will extract)"
    # Different handling...
    continue
fi
```

**Consolidation Strategy:**
```bash
# In config.sh or git-ops.sh
is_discovered_repo() {
    local source="$1"
    [[ "$source" == "discovered" ]]
}

handle_discovered_repo() {
    local volume="$1"
    local project_name="$2"
    local git_image="$3"

    local commit_count
    commit_count=$(docker_run_git "$volume" "$project_name" \
        'git rev-list --count HEAD 2>/dev/null || echo 0')

    echo "$commit_count"
}

# Usage in loops:
if is_discovered_repo "$psource"; then
    commit_count=$(handle_discovered_repo "$volume" "$pname" "$git_image")
    info "  [+] $pname (NEW - $commit_count commits)"
    continue
fi
```

**Impact:** 3 occurrences, consistent handling + testability.

---

## 8. FIND/SEARCH PATTERNS

### Pattern: Find Project in Config

**Found in:** `lib/git-ops.sh:145-177`

**Current Implementation:**
```bash
if [[ -n "$project_filter" ]]; then
    local found=false
    while IFS='|' read -r project_name source_path _branch; do
        if [[ "$project_name" == "$project_filter" ]]; then
            found=true
            # ... process ...
            break
        fi
    done <<< "$projects"

    if ! $found; then
        error "Project not found: $project_filter"
        # Show available...
    fi
fi
```

**Red Flag:** This is `items.find(item => item.name === filter)`.

**Consolidation Strategy:**
```bash
# Generic find utility
find_project() {
    local projects="$1"
    local target_name="$2"

    while IFS='|' read -r pname ppath pbranch ptrack psource; do
        if [[ "$pname" == "$target_name" ]]; then
            echo "$pname|$ppath|$pbranch|$ptrack|$psource"
            return 0
        fi
    done <<< "$projects"

    return 1
}

# Usage:
if [[ -n "$project_filter" ]]; then
    if project=$(find_project "$projects" "$project_filter"); then
        IFS='|' read -r pname ppath pbranch _ _ <<< "$project"
        # ... process ...
    else
        error "Project not found: $project_filter"
    fi
fi
```

**Impact:** Eliminates `found` flag pattern, clearer intent.

---

## 9. STRING TRANSFORMATION PATTERNS

### Pattern: Path Sanitization

**Found in:** `lib/git-ops.sh:562, 668` (referenced in requirements)

**Current Implementation (Inline):**
```bash
local worktree_dir="$CACHE_DIR/worktree-$$-${project_name//\//-}"
```

**Consolidation Strategy:**
```bash
# In utils.sh
sanitize_path_for_filename() {
    local path="$1"
    echo "${path//\//_}"  # Could add more: spaces, special chars, etc.
}

# Usage:
local safe_name=$(sanitize_path_for_filename "$project_name")
local worktree_dir="$CACHE_DIR/worktree-$$-$safe_name"
```

**Impact:** Documents intent, allows future enhancement (handle spaces, unicode, etc.).

---

## Summary Table: Duplication Analysis

| Pattern Category | Occurrences | Current LOC | Potential LOC | Savings |
|-----------------|-------------|-------------|---------------|---------|
| Docker run boilerplate | 35 | ~280 | ~35 | 245 |
| Project parsing loops | 7 | ~70 | ~20 | 50 |
| Volume name extraction | 3 | ~40 | ~10 | 30 |
| Discovered repo handling | 3 | ~45 | ~15 | 30 |
| Volume filtering | 2 | ~30 | ~10 | 20 |
| Size calculation | 2 | ~40 | ~10 | 30 |
| Project find | 2 | ~30 | ~10 | 20 |
| **TOTAL** | **54** | **~535** | **~110** | **~425** |

---

## Recommended Action Plan

### Phase 1: High-Impact, Low-Risk (Week 1)
1. **Extract `docker_run_git()` wrapper** - Affects 20+ call sites, ~200 LOC saved
2. **Extract `for_each_project()` iterator** - Affects 7 call sites, ~50 LOC saved
3. **Extract `is_discovered_repo()` + handler** - Affects 3 call sites, consistency gain

### Phase 2: Medium-Impact Utilities (Week 2)
4. **Extract volume utilities** (`extract_session_name`, `map_volumes_to_sessions`)
5. **Extract `find_project()` search utility**
6. **Extract filtering utilities** (`filter_tracked_projects`, `filter_not_in_set`)

### Phase 3: Advanced Patterns (Week 3)
7. **Extract partition utility** (for future use)
8. **Extract lookup table builder** (`build_lookup_table`)
9. **Create comprehensive docker-utils.sh** module

### Phase 4: Documentation & Testing
10. Add examples to each utility function
11. Create integration tests for critical paths
12. Document patterns in ARCHITECTURE.md

---

## Testing Strategy

For each extraction:

1. **Identify all call sites** (grep for pattern)
2. **Create utility with same behavior** (copy-paste-parameterize)
3. **Replace ONE call site** as proof of concept
4. **Test that call site** (manual or automated)
5. **Replace remaining call sites** in batches
6. **Verify no behavior change** (diff outputs, check error handling)

---

## Questions to Ask Before Each Extraction

1. **Is this truly duplicated?** (Same logic, not just similar structure)
2. **Will this be reused?** (3+ occurrences, or likely future use)
3. **Does extraction clarify intent?** (Name reveals what code does)
4. **Is the abstraction stable?** (Won't need frequent changes)
5. **Can it be tested independently?** (Improves testability)

---

## Anti-Patterns to Avoid

1. **Don't extract for 2 occurrences** unless you're certain of future reuse
2. **Don't over-parameterize** - if every call site passes different args, might not be same operation
3. **Don't abstract too early** - wait until pattern is clear
4. **Don't break error handling** - ensure utilities propagate errors correctly
5. **Don't hide domain logic** - utilities should be generic, not business-logic-heavy

---

## Conclusion

The codebase shows **mature shell scripting practices** but has **natural duplication** from incremental feature addition. The refactoring we just completed (extract merge functions) is **exactly the right pattern** to follow:

1. Identify duplicated logic (single vs multi-project merge)
2. Extract shared functions with clear responsibilities
3. Refactor callers to use shared functions
4. Preserve all existing behavior

**Recommended priority:** Docker wrapper utilities first (highest ROI), then project iteration utilities. These two changes alone would eliminate **~250-300 lines** and significantly improve maintainability.
