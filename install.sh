#!/usr/bin/env bash
# Install claude-container to a stable location.
# Copies the current version so the dev repo can change freely.
#
# Usage:
#   ./install.sh              # install to ~/.local/share/claude-container
#   ./install.sh /opt/cc      # install to custom prefix
#
# Creates/updates:
#   $PREFIX/                   ← full copy of lib/, docs/, etc.
#   $PREFIX/claude-container   ← the main script
#   ~/.hypermemetic-infra/scripts/claude-container → $PREFIX/claude-container  (symlink)
#
# Safe to re-run: overwrites the installed copy with the current repo state.

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${1:-$HOME/.local/share/claude-container}"
LINK_DIR="$HOME/.hypermemetic-infra/scripts"
LINK_PATH="$LINK_DIR/claude-container"

echo "Installing claude-container"
echo "  from: $REPO_DIR"
echo "  to:   $PREFIX"
echo ""

# Create prefix
mkdir -p "$PREFIX"

# Copy everything except .git, plans, tests, docs/architecture (dev-only)
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
    local_target=$(readlink "$LINK_PATH" 2>/dev/null || true)
    if [[ "$local_target" != "$PREFIX/claude-container" ]]; then
        echo "  Updating symlink (was → $local_target)"
        rm -f "$LINK_PATH"
        ln -s "$PREFIX/claude-container" "$LINK_PATH"
    else
        echo "  Symlink already correct"
    fi
elif [[ -e "$LINK_PATH" ]]; then
    echo "  Warning: $LINK_PATH exists and is not a symlink — not touching it"
    echo "  You may need to manually update your PATH"
else
    ln -s "$PREFIX/claude-container" "$LINK_PATH"
    echo "  Created symlink"
fi

echo ""
echo "Installed: $(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo 'unknown commit')"
echo "Run 'claude-container --help' to verify"
