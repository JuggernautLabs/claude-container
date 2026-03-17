#!/usr/bin/env bash
# Merge detection and prompt generation
# Core detection logic used by pull, push --merge, reconcile, and all dry-runs.
# One source of truth for "would this merge work?"

# Detect whether a session branch can merge into a target branch for a single repo.
# Performs git operations to test (checkout, cherry-pick, merge), then cleans up.
# Writes result as key=value pairs to the given result file.
#
# Usage: detect_repo_merge_status <repo_path> <session_name> <target_branch> <squash> <result_file>
#
# Result keys written:
#   merge_status   = OK | CONFLICT | SKIP
#   merge_detail   = human-readable description
#   conflict_files = comma-separated list (only for CONFLICT)
#   target_head    = target branch HEAD hash
detect_repo_merge_status() {
    local proj_path="$1"
    local session_name="$2"
    local target_branch="$3"
    local squash="${4:-true}"
    local result_file="$5"

    _detect_write() {
        local status="$1" detail="$2" files="${3:-}"
        echo "merge_status=$status" > "$result_file"
        echo "merge_detail=$detail" >> "$result_file"
        [[ -n "$files" ]] && echo "conflict_files=$files" >> "$result_file"
        local _th
        _th=$(git -C "$proj_path" rev-parse "refs/heads/$target_branch" 2>/dev/null || echo "")
        [[ -n "$_th" ]] && echo "target_head=$_th" >> "$result_file"
    }

    # --- Pre-merge validations ---

    if [[ ! -d "$proj_path" ]]; then
        _detect_write "SKIP" "repo not found: $proj_path"
        return 0
    fi

    if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$session_name" 2>/dev/null; then
        _detect_write "SKIP" "no session branch"
        return 0
    fi

    local orig_dirty
    orig_dirty=$(git -C "$proj_path" status --porcelain 2>/dev/null)
    if [[ -n "$orig_dirty" ]]; then
        _detect_write "SKIP" "host has uncommitted changes"
        return 0
    fi

    # Target branch doesn't exist — would create it
    if ! git -C "$proj_path" show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
        _detect_write "OK" "would create '$target_branch' from $session_name"
        return 0
    fi

    # --- Squash-base tracking (authoritative when exists) ---

    if [[ "$squash" == "true" ]]; then
        local _squash_ref="refs/claude-container/squash-base/${session_name}"
        local _squash_base
        _squash_base=$(git -C "$proj_path" rev-parse --verify "$_squash_ref" 2>/dev/null || echo "")

        # Validate squash-base is ancestor of current session
        if [[ -n "$_squash_base" ]] && \
           ! git -C "$proj_path" merge-base --is-ancestor "$_squash_base" "$session_name" 2>/dev/null; then
            _squash_base=""  # Stale, ignore
        fi

        if [[ -n "$_squash_base" ]]; then
            local _new_count
            _new_count=$(git -C "$proj_path" rev-list --count "${_squash_base}..${session_name}" 2>/dev/null || echo "0")

            if [[ "$_new_count" == "0" ]]; then
                _detect_write "OK" "no new commits since last squash"
                return 0
            fi

            # Test cherry-pick
            local current_branch
            current_branch=$(git -C "$proj_path" symbolic-ref --short HEAD 2>/dev/null || echo "")
            local _need_checkout=false
            if [[ "$current_branch" != "$target_branch" ]]; then
                if ! git -C "$proj_path" checkout "$target_branch" 2>/dev/null; then
                    _detect_write "SKIP" "could not checkout $target_branch"
                    return 0
                fi
                _need_checkout=true
            fi

            local _cp_err
            _cp_err=$(git -C "$proj_path" cherry-pick --no-commit "${_squash_base}..${session_name}" 2>&1)
            local _cp_rc=$?

            if [[ $_cp_rc -eq 0 ]]; then
                git -C "$proj_path" reset --hard HEAD 2>/dev/null || true
                $_need_checkout && git -C "$proj_path" checkout "$current_branch" 2>/dev/null || true
                _detect_write "OK" "would squash-merge into $target_branch ($_new_count new)"
                return 0
            elif echo "$_cp_err" | grep -q "is a merge but no -m option"; then
                # Range contains merge commits — cherry-pick can't handle them.
                # Clean up and fall through to regular merge test.
                git -C "$proj_path" cherry-pick --abort 2>/dev/null || git -C "$proj_path" reset --hard HEAD 2>/dev/null || true
                $_need_checkout && git -C "$proj_path" checkout "$current_branch" 2>/dev/null || true
                # Don't return — fall through to generic checks below
            else
                # Real conflict
                local _cfiles
                _cfiles=$(git -C "$proj_path" diff --name-only --diff-filter=U 2>/dev/null | head -5 | tr '\n' ', ')
                _cfiles="${_cfiles%,}"
                git -C "$proj_path" cherry-pick --abort 2>/dev/null || git -C "$proj_path" reset --hard HEAD 2>/dev/null || true
                $_need_checkout && git -C "$proj_path" checkout "$current_branch" 2>/dev/null || true
                _detect_write "CONFLICT" "would conflict${_cfiles:+ ($_cfiles)}" "$_cfiles"
                return 0
            fi
        fi
    fi

    # --- Generic checks (no squash-base) ---

    # Session already ancestor of target
    if git -C "$proj_path" merge-base --is-ancestor "$session_name" "$target_branch" 2>/dev/null; then
        _detect_write "OK" "already up to date"
        return 0
    fi

    # Trees identical (prior manual squash)
    if git -C "$proj_path" diff --quiet "$session_name" "$target_branch" -- 2>/dev/null; then
        _detect_write "OK" "content identical to $target_branch"
        return 0
    fi

    # Fast-forward possible?
    if git -C "$proj_path" merge-base --is-ancestor "$target_branch" "$session_name" 2>/dev/null; then
        local _ahead
        _ahead=$(git -C "$proj_path" rev-list --count "$target_branch".."$session_name" 2>/dev/null || echo "?")
        if [[ "$squash" == "true" ]]; then
            _detect_write "OK" "would squash-merge into $target_branch ($_ahead commits)"
        else
            _detect_write "OK" "would fast-forward into $target_branch ($_ahead commits)"
        fi
        return 0
    fi

    # Non-FF: test merge
    local current_branch
    current_branch=$(git -C "$proj_path" symbolic-ref --short HEAD 2>/dev/null || echo "")
    local _checkout_ok=false
    if [[ "$current_branch" == "$target_branch" ]]; then
        _checkout_ok=true
    elif git -C "$proj_path" checkout "$target_branch" 2>/dev/null; then
        _checkout_ok=true
    fi

    if ! $_checkout_ok; then
        _detect_write "SKIP" "could not checkout $target_branch"
        return 0
    fi

    if ! git -C "$proj_path" merge --no-commit --no-ff "$session_name" >/dev/null 2>&1; then
        local _cfiles
        _cfiles=$(git -C "$proj_path" diff --name-only --diff-filter=U 2>/dev/null | head -5 | tr '\n' ', ')
        _cfiles="${_cfiles%,}"
        git -C "$proj_path" merge --abort 2>/dev/null || true
        [[ "$current_branch" != "$target_branch" ]] && git -C "$proj_path" checkout "$current_branch" 2>/dev/null || true
        _detect_write "CONFLICT" "would conflict" "$_cfiles"
        return 0
    fi

    # Clean merge
    git -C "$proj_path" merge --abort 2>/dev/null || true
    [[ "$current_branch" != "$target_branch" ]] && git -C "$proj_path" checkout "$current_branch" 2>/dev/null || true

    if [[ "$squash" == "true" ]]; then
        _detect_write "OK" "would squash-merge into $target_branch"
    else
        _detect_write "OK" "would merge cleanly into $target_branch"
    fi
}

# Read a key from a detect result file
# Usage: detect_result_get <result_file> <key>
detect_result_get() {
    grep "^${2}=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Build Claude's reconcile prompt from detection results and session state.
# Usage: build_reconcile_prompt <session_name> <target_branch> <summary_lines[]> <conflict_count> <dirty_count> <reverse_conflict_repos[]> <reverse_conflict_files[]>
# Output: prompt text to stdout
build_reconcile_prompt() {
    local session_name="$1"
    local target_branch="$2"
    shift 2

    # Read arrays from args: summary_lines, then counts, then reverse arrays
    # Caller passes serialized data via environment variables:
    #   _PROMPT_SUMMARY_LINES (newline-separated)
    #   _PROMPT_CONFLICT_COUNT
    #   _PROMPT_DIRTY_COUNT
    #   _PROMPT_REVERSE_REPOS (newline-separated)
    #   _PROMPT_REVERSE_FILES (newline-separated)

    local prompt="Branch '$target_branch' was merged into this session. Here is what happened:"
    prompt+=$'\n'

    local _ok_count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Only include lines that need attention — skip "OK: ... (up to date/merged)"
        case "$line" in
            "OK: "*)
                _ok_count=$((_ok_count + 1))
                # Only show OK lines for repos that were actually merged (not "up to date")
                case "$line" in
                    *"(merged)"*) prompt+=$'\n'"  $line" ;;
                esac
                ;;
            *)
                prompt+=$'\n'"  $line"
                ;;
        esac
    done <<< "${_PROMPT_SUMMARY_LINES:-}"
    [[ $_ok_count -gt 0 ]] && prompt+=$'\n'"  ($_ok_count repo(s) already up to date)"

    local conflict_count="${_PROMPT_CONFLICT_COUNT:-0}"
    local dirty_count="${_PROMPT_DIRTY_COUNT:-0}"

    if [[ $conflict_count -gt 0 ]]; then
        prompt+=$'\n\n'"$conflict_count project(s) have merge conflicts that need resolution."
        prompt+=$'\n\n'"Resolve all merge conflicts. The '$target_branch' branch is incoming work that should generally be accepted — prefer the incoming (theirs/'$target_branch') side unless it would remove or overwrite substantive session work."
        prompt+=$'\n\n'"IMPORTANT: If resolving a conflict would discard or significantly alter work from the session (HEAD/ours), do NOT silently drop it. Instead, raise this to the human with:"
        prompt+=$'\n'"  - What the session had (ours)"
        prompt+=$'\n'"  - What the incoming branch has (theirs)"
        prompt+=$'\n'"  - Why they conflict"
        prompt+=$'\n'"  - Your recommendation"
        prompt+=$'\n\n'"For each conflicted project:"
        prompt+=$'\n'"1. Find all files with <<<<<<< markers: grep -r '<<<<<<< HEAD' ."
        prompt+=$'\n'"2. Edit each file to resolve conflicts, preferring incoming changes unless they remove session work"
        prompt+=$'\n'"3. git add the resolved files"
        prompt+=$'\n'"4. git commit to complete the merge"
        prompt+=$'\n\n'"Resolve autonomously when the incoming side clearly wins (new additions, non-overlapping changes, formatting). Ask the human when both sides made substantive changes to the same logic or when accepting incoming would remove session work."
    fi

    if [[ $dirty_count -gt 0 ]]; then
        prompt+=$'\n\n'"$dirty_count project(s) had uncommitted changes in the session and could not be auto-merged. The host repos are mounted read-only at /host/{project_name} so you can complete the merge manually."
        prompt+=$'\n\n'"For each dirty project:"
        prompt+=$'\n'"1. cd /workspace/{project_name}"
        prompt+=$'\n'"2. Review uncommitted changes: git status && git diff"
        prompt+=$'\n'"3. Commit or stash the uncommitted work: git add -A && git commit -m 'WIP: uncommitted session work'"
        prompt+=$'\n'"4. Merge from host: git remote add upstream /host/{project_name} && git fetch upstream $target_branch && git merge upstream/$target_branch --no-edit"
        prompt+=$'\n'"5. Resolve any conflicts (prefer session/HEAD side), then git add and git commit"
        prompt+=$'\n'"6. Clean up: git remote remove upstream"
    fi

    # Reverse merge conflicts
    local -a _rev_repos=() _rev_files=()
    while IFS= read -r _line; do
        [[ -n "$_line" ]] && _rev_repos+=("$_line")
    done <<< "${_PROMPT_REVERSE_REPOS:-}"
    while IFS= read -r _line; do
        [[ -n "$_line" ]] && _rev_files+=("$_line")
    done <<< "${_PROMPT_REVERSE_FILES:-}"

    local _rev_count=${#_rev_repos[@]}

    if [[ $_rev_count -gt 0 ]]; then
        prompt+=$'\n\n'"=== REVERSE MERGE CONFLICTS ==="
        prompt+=$'\n'"$_rev_count project(s) will conflict when merging your session back into '$target_branch' on the host."
        prompt+=$'\n'"This is typically caused by prior squash-merges creating divergent git history."
        prompt+=$'\n'"The host '$target_branch' branch is mounted read-only at /host/{project_name} for reference."
        prompt+=$'\n'
        for _i in "${!_rev_repos[@]}"; do
            [[ -z "${_rev_repos[$_i]}" ]] && continue
            prompt+=$'\n'"  ${_rev_repos[$_i]}: ${_rev_files[$_i]:-?}"
        done
        prompt+=$'\n\n'"For each reverse-conflict project:"
        prompt+=$'\n'"1. cd /workspace/{project_name}"
        prompt+=$'\n'"2. Fetch the host's $target_branch: git remote add host /host/{project_name} && git fetch host $target_branch"
        prompt+=$'\n'"3. Merge host/$target_branch into your session: git merge host/$target_branch --no-edit"
        prompt+=$'\n'"4. If conflicts, resolve them — the goal is that your session now contains everything from $target_branch"
        prompt+=$'\n'"5. git add the resolved files && git commit"
        prompt+=$'\n'"6. git remote remove host"
        prompt+=$'\n\n'"After this, the host will be able to fast-forward $target_branch to your session — no more squash conflicts."
    fi

    prompt+=$'\n\n'"After resolving all conflicts, review the result:"
    prompt+=$'\n'"- Do the merged changes preserve the functionality of the committed session work? Are there any regressions?"
    prompt+=$'\n'"- Are there augmentations — new features or behavior introduced by '$target_branch' that extend or change what the session was doing?"
    prompt+=$'\n'"- If anything is uncertain — ambiguous conflict resolutions, code that may have changed semantics, or areas where both branches made overlapping changes — present those uncertainties to me with your answers to the above questions."
    prompt+=$'\n\n'"When you have finished resolving all conflicts and are satisfied with the result, run:"
    prompt+=$'\n'"  fin \"<brief description of what was resolved>\""
    prompt+=$'\n'"This will signal completion and terminate the session."

    printf '%s' "$prompt"
}
