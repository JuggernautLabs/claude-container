# Session History Tracking for claude-container

## Problem

When using `--git-session` in claude-container, the workspace is preserved between sessions but:
1. Fine-grained edit history is lost (only explicit commits are saved)
2. Resuming a session with `--continue` restores conversation but not intermediate file states
3. No way to "rewind" to see what Claude changed at a specific point

## Proposed Solution: Layered History

Combine two complementary approaches:

### Layer 1: NILFS2 Filesystem (Continuous History)

[NILFS2](https://nilfs.sourceforge.io/) is a log-structured filesystem that continuously records all changes as checkpoints (every few seconds by default).

**Benefits:**
- Zero-overhead versioning (no explicit saves needed)
- Can mount any point in time as read-only snapshot
- Efficient storage (only deltas stored)
- Works transparently with any tool

**Implementation:**
```bash
# Create NILFS2-backed volume for session
docker volume create --driver local \
  --opt type=nilfs2 \
  --opt device=/dev/loop0 \
  claude-session-$NAME

# Inside container: browse history
mount -t nilfs2 -o ro,cp=<checkpoint> /dev/nilfs /history
```

**Tradeoffs:**
- Linux-only (not available on macOS Docker Desktop without VM tricks)
- Requires periodic garbage collection (`nilfs-clean`)
- Checkpoints are time-based, not semantically meaningful

### Layer 2: LLM-Generated Semantic Commits (Periodic Snapshots)

Background process that periodically commits with auto-generated messages describing the changes.

**Implementation in claude-container:**
```bash
# New flag
claude-container --git-session feature --auto-commit 60  # commit every 60s

# Background process inside container
auto_commit() {
    while true; do
        sleep ${AUTO_COMMIT_INTERVAL:-60}
        if [[ -n "$(git status --porcelain)" ]]; then
            DIFF_STAT=$(git diff --stat | head -20)
            MSG=$(claude --print "One-line commit message for: $DIFF_STAT")
            git add -A && git commit -m "$MSG"
        fi
    done
}
auto_commit &
```

**Benefits:**
- Human-readable history with meaningful messages
- Works on any platform (just git)
- Easy to cherry-pick or revert specific changes
- Integrates with existing `--merge-session` workflow

**Tradeoffs:**
- Not continuous (interval-based)
- Uses Claude API calls (cost, though Haiku is cheap)
- May create noisy commit history

## Recommended Approach

Use **Layer 2 (git auto-commits)** as the primary mechanism:
- Cross-platform compatibility
- Integrates with existing git-session workflow
- Semantic history is more useful than raw filesystem checkpoints

Reserve **Layer 1 (NILFS2)** for:
- Self-hosted Linux environments where fine-grained history is critical
- Debugging/forensics use cases
- Future enhancement once Docker Desktop supports it better

## Implementation Plan

### Phase 1: Git Auto-Commits
1. Add `--auto-commit [interval]` flag to claude-container
2. Run background commit loop inside container
3. Use `claude --print` for message generation (already available)
4. Default interval: 120 seconds (2 minutes)

### Phase 2: Configurable Message Generation
1. Support `COMMIT_MESSAGE_MODEL` env var (default: use claude inside container)
2. Option to use `hyperforge commit --auto-message` if available
3. Fallback to timestamp-only messages if no LLM available

### Phase 3: NILFS2 Support (Optional)
1. Add `--nilfs` flag for Linux hosts
2. Create NILFS2-formatted loop device as session storage
3. Document checkpoint browsing workflow

## Related Files

- `scripts/claude-container` - Main container script
- `scripts/forge-commit` - Existing LLM commit message generation

## Example Workflow

```bash
# Start session with auto-commits every 2 minutes
claude-container --git-session feature --auto-commit 120

# ... Claude makes changes over 30 minutes ...
# Auto-commits created:
#   "Add user authentication middleware"
#   "Implement JWT token validation"
#   "Add login endpoint tests"

# Exit and check history
claude-container --diff-session feature
# Shows semantic commit log

# Resume later, continue conversation AND git history
claude-container -g feature --continue

# When done, merge meaningful commits back
claude-container --merge-session feature --into feature-branch
```
