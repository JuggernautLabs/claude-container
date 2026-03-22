#!/bin/bash
# claude-container entrypoint — runs inside the container
# Mounted at /usr/local/bin/cc-entrypoint
#
# Responsibilities:
#   1. Token setup
#   2. User/permissions setup
#   3. CLAUDE.md injection (task-type specific)
#   4. Shell/exec/verify dispatch
#   5. Agent wrapper invocation (replaces exec claude)

set -e

# ============================================================================
# Token Setup
# ============================================================================

if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN_NESTED:-}" ]]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN_NESTED"
elif [[ -f /run/secrets/claude_token ]]; then
    export CLAUDE_CODE_OAUTH_TOKEN=$(cat /run/secrets/claude_token)
else
    echo "ERROR: No token found (neither file nor env var)" >&2
    exit 1
fi

# ============================================================================
# Overlay Setup (deprecated)
# ============================================================================

HOST_UID=${HOST_UID:-1000}
DEV_GID=61000

if [[ "${USE_OVERLAY:-}" == "1" ]]; then
    echo "Setting up overlay filesystem..."
    mkdir -p /session-data/upper /session-data/work
    rmdir /workspace 2>/dev/null || rm -f /workspace 2>/dev/null || true
    mkdir -p /workspace
    if fuse-overlayfs \
        -o lowerdir=/workspace-lower,upperdir=/session-data/upper,workdir=/session-data/work \
        /workspace 2>&1; then
        echo "  Overlay mounted at /workspace"
    else
        mount --bind /workspace-lower /workspace 2>/dev/null || ln -sf /workspace-lower /workspace
        echo "  Fallback: direct mount, read-only"
    fi
    cd /workspace
    echo ""
fi

# ============================================================================
# Home Directory & Config
# ============================================================================

# Create config dirs (entrypoint always runs as root, drops privileges later via gosu)
mkdir -p /home/developer/.claude /home/developer/.cargo /home/developer/.npm /home/developer/.cache/pip

# Pre-accept trust dialog for /workspace and all subdirectories
python3 << 'TRUSTPY' 2>/dev/null || echo '{"theme":"dark-ansi","hasCompletedOnboarding":true,"bypassPermissionsModeAccepted":true}' > "/home/developer/.claude.json"
import json, glob, os
projects = {"/workspace": {"hasTrustDialogAccepted": True}}
for pattern in ["/workspace/*/", "/workspace/*/*/"]:
    for d in glob.glob(pattern):
        if os.path.isdir(os.path.join(d, ".git")):
            projects[d.rstrip("/")] = {"hasTrustDialogAccepted": True}
config = {
    "theme": "dark-ansi",
    "hasCompletedOnboarding": True,
    "bypassPermissionsModeAccepted": True,
    "projects": projects
}
with open("/home/developer/.claude.json", "w") as f:
    json.dump(config, f)
TRUSTPY

# Statusline settings (base64-encoded to avoid quoting issues)
echo "eyJzdGF0dXNMaW5lIjp7InR5cGUiOiJjb21tYW5kIiwiY29tbWFuZCI6ImlucHV0PSQoY2F0KTsgbW9kZWw9JChlY2hvIFwiJGlucHV0XCIgfCBqcSAtciAnLm1vZGVsLmRpc3BsYXlfbmFtZSAvLyAubW9kZWwuaWQgLy8gXCI/XCInIHwgdHIgJ1s6dXBwZXI6XScgJ1s6bG93ZXI6XScgfCB0ciAnICcgJy0nKTsgY29zdD0kKGVjaG8gXCIkaW5wdXRcIiB8IGpxIC1yICcuY29zdC50b3RhbF9jb3N0X3VzZCAvLyAwJyB8IHhhcmdzIHByaW50ZiAnJCUuMmYnKTsgb3ZlcjIwMGs9JChlY2hvIFwiJGlucHV0XCIgfCBqcSAtciAnLmV4Y2VlZHNfMjAwa190b2tlbnMnKTsgaWYgWyBcIiRvdmVyMjAwa1wiID0gXCJ0cnVlXCIgXTsgdGhlbiBjdHg9J+KaoO+4jz4yMDBrJzsgZWxzZSBjdHg9JzwyMDBrJzsgZmk7IGN3ZD0kKGVjaG8gXCIkaW5wdXRcIiB8IGpxIC1yICcud29ya3NwYWNlLmN1cnJlbnRfZGlyJyk7IGRpcj0kKGJhc2VuYW1lIFwiJGN3ZFwiKTsgY2QgXCIkY3dkXCIgMj4vZGV2L251bGwgfHwgdHJ1ZTsgYnJhbmNoPSQoZ2l0IHN5bWJvbGljLXJlZiAtLXNob3J0IEhFQUQgMj4vZGV2L251bGwpOyBkaXJ0eT0kKGdpdCBzdGF0dXMgLS1wb3JjZWxhaW4gMj4vZGV2L251bGwgfCBoZWFkIC0xKTsgaWYgWyAtbiBcIiRkaXJ0eVwiIF07IHRoZW4gbWFyaz0nKic7IGVsc2UgbWFyaz0nJzsgZmk7IHNlc3M9XCIke0NMQVVERV9TRVNTSU9OX05BTUU6LX1cIjsgaWYgWyAtbiBcIiRzZXNzXCIgXSAmJiBbIC1uIFwiJGJyYW5jaFwiIF07IHRoZW4gZWNobyBcIlskc2Vzc10gJG1vZGVsQCRkaXI6KCRicmFuY2gkbWFyaykgJGNvc3QgJGN0eFwiOyBlbGlmIFsgLW4gXCIkc2Vzc1wiIF07IHRoZW4gZWNobyBcIlskc2Vzc10gJG1vZGVsQCRkaXIgJGNvc3QgJGN0eFwiOyBlbGlmIFsgLW4gXCIkYnJhbmNoXCIgXTsgdGhlbiBlY2hvIFwiJG1vZGVsQCRkaXI6KCRicmFuY2gkbWFyaykgJGNvc3QgJGN0eFwiOyBlbHNlIGVjaG8gXCIkbW9kZWxAJGRpciAkY29zdCAkY3R4XCI7IGZpIn19Cg==" | base64 -d > "/home/developer/.claude/settings.json" 2>/dev/null || true

# Copy git config
if [[ -f /root/.gitconfig ]]; then
    cp /root/.gitconfig /home/developer/.gitconfig 2>/dev/null || true
fi

# Check for docker CLI if socket is mounted
if [[ -S /var/run/docker.sock ]] && ! command -v docker &>/dev/null; then
    echo "WARNING: docker socket mounted but docker CLI not found"
    echo "         Use --dockerfile to build an image with docker"
fi

# ============================================================================
# User Setup
# ============================================================================

if [[ "${RUN_AS_USER:-}" == "1" ]] || [[ "${RUN_AS_ROOTISH:-}" == "1" ]]; then
    groupadd -g $DEV_GID developer 2>/dev/null || true
    useradd -u $HOST_UID -g $DEV_GID -m -s /bin/bash developer 2>/dev/null || true
    # Fix ownership of home dir and key config dirs (NOT recursive on all of home —
    # .claude/ and .npm/ can have thousands of cached files from previous runs)
    chown developer:developer /home/developer 2>/dev/null || true
    # Key config files (non-recursive, fast)
    chown developer:developer /home/developer/.claude.json /home/developer/.gitconfig 2>/dev/null || true
    chown developer:developer /home/developer/.claude /home/developer/.cargo /home/developer/.npm /home/developer/.cache 2>/dev/null || true
    # Claude config needs recursive fix (settings, session-env, etc.) but skip debug/statsig bloat
    chown -R developer:developer /home/developer/.claude/settings.json /home/developer/.claude/session-env 2>/dev/null || true
    chown developer:developer /workspace 2>/dev/null || true

    # Make docker socket accessible if mounted
    if [[ -S /var/run/docker.sock ]]; then
        chmod 666 /var/run/docker.sock 2>/dev/null || true
    fi

    if [[ "${RUN_AS_ROOTISH:-}" == "1" ]]; then
        if ! command -v sudo &>/dev/null; then
            echo "WARNING: sudo not found - rootish mode requires sudo in the image"
            echo "         Use --dockerfile to build an image with sudo, or use --as-root"
        else
            echo "developer ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/developer
            chmod 0440 /etc/sudoers.d/developer

            cat > /usr/local/bin/rootish << 'WRAPPER'
#!/bin/bash
exec sudo "$@"
WRAPPER
            chmod +x /usr/local/bin/rootish
        fi
    fi
fi

# ============================================================================
# Install fin command
# ============================================================================

cat > /usr/local/bin/fin << 'FINSCRIPT'
#!/bin/bash
if [[ $# -eq 0 ]]; then
    echo "Usage: fin <description>"
    echo "Signals completion of conflict resolution and terminates the session."
    exit 1
fi
echo "$*" > /workspace/.reconcile-complete
echo ""
echo "Session complete: $*"
kill 1
FINSCRIPT
chmod +x /usr/local/bin/fin

# ============================================================================
# Verify Mode
# ============================================================================

if [[ "${VERIFY_MODE:-}" == "1" ]]; then
    echo "=== Verification ==="
    echo "Run as: $(if [[ "${RUN_AS_ROOTISH:-}" == "1" ]]; then echo "developer (sudo)"; elif [[ "${RUN_AS_USER:-}" == "1" ]]; then echo "developer"; else echo "root"; fi)"
    echo "Claude: $(which claude 2>&1)"
    echo "Platform: ${PLATFORM:-unknown}"

    echo ""
    echo "=== Token Check ==="
    if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        if [[ -f /run/secrets/claude_token ]]; then
            echo "  Token source: file"
        elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN_NESTED:-}" ]]; then
            echo "  Token source: nested env var"
        else
            echo "  Token source: environment"
        fi
        echo "  Token: ${CLAUDE_CODE_OAUTH_TOKEN:0:20}..."
    else
        echo "  Token missing"
        exit 1
    fi

    echo ""
    echo "=== Claude Test ==="
    HOME=/home/developer claude --print "test" 2>&1 | head -5
    exit 0
fi

# ============================================================================
# CLAUDE.md Injection
# ============================================================================

_inject_claude_md() {
    local task="${AGENT_TASK:-work}"
    local session="${CLAUDE_SESSION_NAME:-}"
    local context_b64="${AGENT_CONTEXT:-}"
    local context=""

    if [[ -n "$context_b64" ]]; then
        context=$(echo "$context_b64" | base64 -d 2>/dev/null || echo "$context_b64" | base64 -D 2>/dev/null || echo "")
    fi

    # Build repo list from /workspace
    local repos=()
    for repo in /workspace/*/; do
        [[ -d "$repo/.git" ]] && repos+=("$(basename "$repo")")
    done

    local claude_md=""

    case "$task" in
        resolve-conflicts)
            claude_md="# Conflict Resolution Session"
            claude_md+=$'\n\n'"You are resolving merge conflicts in a claude-container session."
            claude_md+=$'\n\n'"## Session: ${session}"
            claude_md+=$'\n\n'"## Repos in workspace"
            for r in "${repos[@]}"; do
                claude_md+=$'\n'"- /workspace/$r"
            done
            if [[ -n "$context" ]]; then
                claude_md+=$'\n\n'"## Conflict Details"
                claude_md+=$'\n'"$context"
            fi
            claude_md+=$'\n\n'"## Instructions"
            claude_md+=$'\n'"- Host repos are mounted read-only at /host/<repo_name>"
            claude_md+=$'\n'"- Resolve all merge conflicts, preferring session work"
            claude_md+=$'\n'"- Commit resolved files"
            claude_md+=$'\n'"- When done, run: fin \"<brief description>\""
            ;;
        rebase-conflicts)
            claude_md="# Rebase Conflict Resolution Session"
            claude_md+=$'\n\n'"You are resolving rebase conflicts in a claude-container session."
            claude_md+=$'\n\n'"## Session: ${session}"
            claude_md+=$'\n\n'"## Repos in workspace"
            for r in "${repos[@]}"; do
                claude_md+=$'\n'"- /workspace/$r"
            done
            if [[ -n "$context" ]]; then
                claude_md+=$'\n\n'"## Conflict Details"
                claude_md+=$'\n'"$context"
            fi
            claude_md+=$'\n\n'"## Instructions"
            claude_md+=$'\n'"- For each conflicted project:"
            claude_md+=$'\n'"  1. Find files with <<<<<<< markers"
            claude_md+=$'\n'"  2. Resolve conflicts (prefer session/HEAD side)"
            claude_md+=$'\n'"  3. git add resolved files"
            claude_md+=$'\n'"  4. git rebase --continue"
            claude_md+=$'\n'"- When done, run: fin \"<brief description>\""
            ;;
        review)
            claude_md="# Review Session"
            claude_md+=$'\n\n'"You are reviewing pending changes in a claude-container session."
            claude_md+=$'\n\n'"## Session: ${session}"
            claude_md+=$'\n\n'"## Repos in workspace"
            for r in "${repos[@]}"; do
                claude_md+=$'\n'"- /workspace/$r"
            done
            claude_md+=$'\n\n'"## Instructions"
            claude_md+=$'\n'"- This is a read-only review session"
            claude_md+=$'\n'"- Discuss changes with the user"
            claude_md+=$'\n'"- Do not make modifications unless explicitly asked"
            ;;
        exec)
            claude_md="# Exec Session"
            claude_md+=$'\n\n'"## Session: ${session}"
            if [[ -n "$context" ]]; then
                claude_md+=$'\n\n'"## Task"
                claude_md+=$'\n'"$context"
            fi
            ;;
        work|*)
            claude_md="# Claude Container Session"
            claude_md+=$'\n\n'"## Session: ${session}"
            claude_md+=$'\n\n'"## Repos in workspace"
            for r in "${repos[@]}"; do
                claude_md+=$'\n'"- /workspace/$r"
            done
            claude_md+=$'\n\n'"## Session Commands"
            claude_md+=$'\n'"- \`fin \"<description>\"\` — Signal completion and terminate session"
            ;;
    esac

    # Write CLAUDE.md to workspace root (don't overwrite existing user CLAUDE.md)
    if [[ ! -f /workspace/CLAUDE.md ]]; then
        echo "$claude_md" > /workspace/CLAUDE.md
    fi
}

# Only inject CLAUDE.md when AGENT_TASK is set
if [[ -n "${AGENT_TASK:-}" ]]; then
    _inject_claude_md
fi

# ============================================================================
# Working Directory
# ============================================================================

WORK_DIR="/workspace"
if [[ -f /workspace/.main-project ]]; then
    MAIN_PROJ=$(cat /workspace/.main-project)
    if [[ -d "/workspace/$MAIN_PROJ" ]]; then
        WORK_DIR="/workspace/$MAIN_PROJ"
    fi
fi

# ============================================================================
# Shell-Only Mode
# ============================================================================

if [[ "${SHELL_ONLY:-}" == "1" ]]; then
    if [[ "${RUN_AS_USER:-}" == "1" ]] || [[ "${RUN_AS_ROOTISH:-}" == "1" ]]; then
        exec gosu developer bash -c "export CLAUDE_CODE_OAUTH_TOKEN='$CLAUDE_CODE_OAUTH_TOKEN' && cd $WORK_DIR && exec bash"
    else
        exec bash -c "cd $WORK_DIR && exec bash"
    fi
fi

# ============================================================================
# Bash Exec Mode
# ============================================================================

if [[ -n "${BASH_EXEC:-}" ]]; then
    cd $WORK_DIR
    if [[ "${RUN_AS_USER:-}" == "1" ]] || [[ "${RUN_AS_ROOTISH:-}" == "1" ]]; then
        exec gosu developer bash -c "$BASH_EXEC"
    else
        exec bash -c "$BASH_EXEC"
    fi
fi

# ============================================================================
# Build Claude Command
# ============================================================================

CLAUDE_CMD_ARGS=""

if [[ "${RUN_AS_USER:-}" == "1" ]] || [[ "${RUN_AS_ROOTISH:-}" == "1" ]]; then
    CLAUDE_CMD_ARGS="--dangerously-skip-permissions"
fi

if [[ "${CONTINUE_SESSION:-}" == "1" ]]; then
    CLAUDE_CMD_ARGS="--continue $CLAUDE_CMD_ARGS"
fi

# Decode passthrough args
if [[ -n "${CLAUDE_PASSTHROUGH_ARGS:-}" ]]; then
    PASSTHROUGH_DECODED=$(echo "$CLAUDE_PASSTHROUGH_ARGS" | base64 -d 2>/dev/null || echo "$CLAUDE_PASSTHROUGH_ARGS" | base64 -D 2>/dev/null)
    while IFS= read -r arg; do
        if [[ -n "$arg" ]]; then
            if [[ "$arg" =~ \  ]]; then
                CLAUDE_CMD_ARGS="$CLAUDE_CMD_ARGS \"$arg\""
            else
                CLAUDE_CMD_ARGS="$CLAUDE_CMD_ARGS $arg"
            fi
        fi
    done <<< "$PASSTHROUGH_DECODED"
fi

# Check for merge-into or sync summary to use as initial prompt
CLAUDE_INITIAL_PROMPT=""
if [[ -f /workspace/.merge-into-summary ]]; then
    CLAUDE_INITIAL_PROMPT=$(cat /workspace/.merge-into-summary)
    rm -f /workspace/.merge-into-summary
elif [[ -f /workspace/.sync-summary ]]; then
    CLAUDE_INITIAL_PROMPT=$(cat /workspace/.sync-summary)
    rm -f /workspace/.sync-summary
fi

# ============================================================================
# Launch via Agent Wrapper
# ============================================================================

cd $WORK_DIR

# agent-run handles pre/post hooks and signal forwarding
# It calls claude (NOT exec) so we get control back for post-agent reporting
if [[ -n "$CLAUDE_INITIAL_PROMPT" ]]; then
    echo "$CLAUDE_INITIAL_PROMPT" > /tmp/.claude-initial-prompt
    if [[ "${RUN_AS_USER:-}" == "1" ]] || [[ "${RUN_AS_ROOTISH:-}" == "1" ]]; then
        exec gosu developer /usr/local/bin/agent-run $CLAUDE_CMD_ARGS "$(cat /tmp/.claude-initial-prompt)"
    else
        HOME=/home/developer exec /usr/local/bin/agent-run $CLAUDE_CMD_ARGS "$(cat /tmp/.claude-initial-prompt)"
    fi
elif [[ "${RUN_AS_USER:-}" == "1" ]] || [[ "${RUN_AS_ROOTISH:-}" == "1" ]]; then
    exec gosu developer /usr/local/bin/agent-run $CLAUDE_CMD_ARGS
else
    HOME=/home/developer exec /usr/local/bin/agent-run $CLAUDE_CMD_ARGS
fi
