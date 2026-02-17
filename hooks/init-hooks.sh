#!/bin/bash
# init-hooks.sh — Initialize Copilot CLI Matrix hooks in the current directory.
#
# Run this in any project dir to enable Matrix monitoring for that project.
# Creates .github/hooks/hooks.json symlinked to the global config.
#
# Usage:
#   bash /path/to/init-hooks.sh
#   or: source ~/.copilot-hooks/init-hooks.sh

set -euo pipefail

HOOKS_DIR="$HOME/.copilot-hooks"
TARGET_DIR="${1:-.}"
GITHUB_HOOKS_DIR="${TARGET_DIR}/.github/hooks"

# Check if global setup has been done
if [ ! -f "$HOOKS_DIR/.env" ]; then
    echo "❌ Global hooks not set up yet. Run setup-hooks.sh first."
    exit 1
fi

# Create .github/hooks/ in the project
mkdir -p "$GITHUB_HOOKS_DIR"

# Symlink to the global hooks.json
if [ -L "$GITHUB_HOOKS_DIR/hooks.json" ]; then
    echo "✅ Hooks already linked: $(readlink "$GITHUB_HOOKS_DIR/hooks.json")"
elif [ -f "$GITHUB_HOOKS_DIR/hooks.json" ]; then
    echo "⚠️  hooks.json already exists (not a symlink). Backing up and replacing..."
    mv "$GITHUB_HOOKS_DIR/hooks.json" "$GITHUB_HOOKS_DIR/hooks.json.bak"
    ln -s "$HOOKS_DIR/hooks.json" "$GITHUB_HOOKS_DIR/hooks.json"
    echo "✅ Linked: $GITHUB_HOOKS_DIR/hooks.json → $HOOKS_DIR/hooks.json"
else
    ln -s "$HOOKS_DIR/hooks.json" "$GITHUB_HOOKS_DIR/hooks.json"
    echo "✅ Linked: $GITHUB_HOOKS_DIR/hooks.json → $HOOKS_DIR/hooks.json"
fi

DIR_NAME=$(basename "$(cd "$TARGET_DIR" && pwd)")
echo ""
echo "Hooks initialized for: $DIR_NAME"
echo "Run 'copilot' here and check FluffyChat for 'CLI: $DIR_NAME' room."
