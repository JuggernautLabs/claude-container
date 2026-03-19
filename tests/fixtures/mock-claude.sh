#!/bin/bash
# Mock claude binary for testing
# Controlled via environment variables:
#
#   MOCK_CLAUDE_COMMITS="repo1:2,repo2:1"  — make N commits in /workspace/<repo>
#   MOCK_CLAUDE_EXIT=0                     — exit code (default 0)
#   MOCK_CLAUDE_DELAY=0                    — sleep N seconds before exit
#   MOCK_CLAUDE_TOUCH_FILES="repo/f.txt"   — create files without committing (comma-sep)

set -e

# Configure git globally
git config --global user.email "mock@test.com" 2>/dev/null || true
git config --global user.name "Mock Claude" 2>/dev/null || true
git config --global safe.directory '*' 2>/dev/null || true

# Make commits in specified repos
if [[ -n "${MOCK_CLAUDE_COMMITS:-}" ]]; then
    IFS=',' read -ra _pairs <<< "$MOCK_CLAUDE_COMMITS"
    for pair in "${_pairs[@]}"; do
        repo="${pair%%:*}"
        count="${pair##*:}"
        repo_path="/workspace/$repo"

        if [[ ! -d "$repo_path/.git" ]]; then
            echo "mock-claude: warning: $repo_path is not a git repo, skipping" >&2
            continue
        fi

        cd "$repo_path"
        for ((i=1; i<=count; i++)); do
            echo "mock commit $i in $repo" > "mock-${i}.txt"
            git add "mock-${i}.txt"
            git commit -q -m "mock commit $i to $repo"
        done
    done
fi

# Touch files without committing
if [[ -n "${MOCK_CLAUDE_TOUCH_FILES:-}" ]]; then
    IFS=',' read -ra _files <<< "$MOCK_CLAUDE_TOUCH_FILES"
    for f in "${_files[@]}"; do
        fpath="/workspace/$f"
        mkdir -p "$(dirname "$fpath")"
        echo "touched" > "$fpath"
    done
fi

# Delay (for signal forwarding tests)
if [[ "${MOCK_CLAUDE_DELAY:-0}" -gt 0 ]]; then
    sleep "$MOCK_CLAUDE_DELAY"
fi

exit "${MOCK_CLAUDE_EXIT:-0}"
