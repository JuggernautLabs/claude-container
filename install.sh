#!/usr/bin/env bash
# Install claude-container to a stable location.
# Copies the current version so the dev repo can change freely.
#
# Usage:
#   ./install.sh                    # install + symlink in ~/.local/bin
#   ./install.sh --prefix /opt/cc   # custom install location
#   ./install.sh --link-dir ~/bin   # custom symlink location
#
# Creates/updates:
#   $PREFIX/                   ← full copy of lib/, docs/, etc.
#   $PREFIX/claude-container   ← the main script
#   $LINK_DIR/claude-container → $PREFIX/claude-container  (symlink)
#
# Safe to re-run: overwrites the installed copy with the current repo state.

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$HOME/.local/share/claude-container"
LINK_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --link-dir)
            LINK_DIR="$2"
            shift 2
            ;;
        --revert)
            # Revert: point symlink back at the repo (live development mode)
            _link=$(readlink "$(which claude-container 2>/dev/null)" 2>/dev/null || true)
            if [[ -n "$_link" ]]; then
                _link_dir=$(dirname "$_link")
                _link_dir=$(dirname "$_link_dir")  # go up from the binary
                # Actually just find the symlink and repoint it
                for _ld in "$HOME/.hypermemetic-infra/scripts" "$HOME/.local/bin" "$HOME/bin"; do
                    if [[ -L "$_ld/claude-container" ]]; then
                        rm -f "$_ld/claude-container"
                        ln -s "$REPO_DIR/claude-container" "$_ld/claude-container"
                        echo "Reverted: $_ld/claude-container → $REPO_DIR/claude-container"
                        exit 0
                    fi
                done
            fi
            echo "No symlink found to revert"
            exit 1
            ;;
        --help|-h)
            echo "Usage: ./install.sh [--prefix <dir>] [--link-dir <dir>] [--revert]"
            echo ""
            echo "Options:"
            echo "  --prefix <dir>    Install location (default: ~/.local/share/claude-container)"
            echo "  --link-dir <dir>  Symlink location (default: auto-detect from PATH)"
            echo "  --revert          Point symlink back at repo (live dev mode)"
            exit 0
            ;;
        *)
            # Positional arg = prefix (backward compat)
            PREFIX="$1"
            shift
            ;;
    esac
done

# Auto-detect link dir: prefer ~/.local/bin if on PATH, else first writable PATH dir
if [[ -z "$LINK_DIR" ]]; then
    if echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
        LINK_DIR="$HOME/.local/bin"
    elif echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.hypermemetic-infra/scripts"; then
        LINK_DIR="$HOME/.hypermemetic-infra/scripts"
    elif echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/bin"; then
        LINK_DIR="$HOME/bin"
    else
        LINK_DIR="$HOME/.local/bin"
    fi
fi

LINK_PATH="$LINK_DIR/claude-container"

echo "Installing claude-container"
echo "  from: $REPO_DIR"
echo "  to:   $PREFIX"
echo "  link: $LINK_PATH"
echo ""

# Create prefix
mkdir -p "$PREFIX"

# Copy everything except .git, plans, tests
rsync -a --delete \
    --exclude '.git' \
    --exclude '.gitignore' \
    --exclude 'plans/' \
    --exclude 'tests/' \
    --exclude 'install.sh' \
    "$REPO_DIR/" "$PREFIX/"

chmod +x "$PREFIX/claude-container"

# Record what was installed
echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PREFIX/.install-meta"
echo "source=$REPO_DIR" >> "$PREFIX/.install-meta"
echo "commit=$(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo unknown)" >> "$PREFIX/.install-meta"

# Update symlink
mkdir -p "$LINK_DIR"
if [[ -L "$LINK_PATH" ]]; then
    current_target=$(readlink "$LINK_PATH" 2>/dev/null || true)
    if [[ "$current_target" != "$PREFIX/claude-container" ]]; then
        echo "  Updating symlink (was → $current_target)"
        rm -f "$LINK_PATH"
        ln -s "$PREFIX/claude-container" "$LINK_PATH"
    else
        echo "  Symlink already correct"
    fi
elif [[ -e "$LINK_PATH" ]]; then
    echo "  Warning: $LINK_PATH exists and is not a symlink — not touching it"
else
    ln -s "$PREFIX/claude-container" "$LINK_PATH"
    echo "  Created symlink"
fi

# Check if link dir is on PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$LINK_DIR"; then
    echo ""
    echo "  Note: $LINK_DIR is not on your PATH."
    echo "  Add to your shell rc: export PATH=\"$LINK_DIR:\$PATH\""
fi

echo ""
echo "Installed: $(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo 'unknown commit')"
echo "Run 'claude-container --help' to verify"
