#!/usr/bin/env bash
# install.sh — One-time setup for the Matrix ↔ Copilot agent proxy (WSL/Linux).
#
# Creates:
#   ~/.agent-synapse-proxy/
#     venv/           Python virtual environment
#     bot/            Copy of bot sources
#     .env            Credentials
#     start-agent.sh  Launcher (also symlinked to ~/.local/bin/start-agent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_HOME="$HOME/.agent-synapse-proxy"

# ── Defaults (override via env or prompts) ────────────────────────────
if [ -z "$MATRIX_HOMESERVER" ]; then
    read -p "Matrix homeserver URL (e.g. https://matrix.example.com): " MATRIX_HOMESERVER
fi
if [ -z "$MATRIX_ADMIN_USER" ]; then
    read -p "Matrix admin user ID (e.g. @admin:matrix.example.com): " MATRIX_ADMIN_USER
fi
if [ -z "$MATRIX_BOT_USERNAME" ]; then
    read -p "Bot username (pre-registered, e.g. bot-laptop): " MATRIX_BOT_USERNAME
fi
if [ -z "$MATRIX_BOT_PASSWORD" ]; then
    read -s -p "Bot password: " MATRIX_BOT_PASSWORD; echo
fi
COPILOT_MODEL="${COPILOT_MODEL:-claude-sonnet-4}"

echo "=== Agent Proxy — WSL/Linux Install ==="
echo "Installing to: $AGENT_HOME"
echo ""

# ── Create directory structure ────────────────────────────────────────
mkdir -p "$AGENT_HOME/bot"

# ── Copy bot sources ──────────────────────────────────────────────────
echo ">> Copying bot sources..."
cp "$PROJECT_DIR/bot/agent_proxy.py"    "$AGENT_HOME/bot/"
cp "$PROJECT_DIR/bot/config.py"         "$AGENT_HOME/bot/"
cp "$PROJECT_DIR/bot/requirements.txt"  "$AGENT_HOME/bot/"

# ── Create Python venv & install deps ─────────────────────────────────
VENV_DIR="$AGENT_HOME/venv"
if [ ! -d "$VENV_DIR" ]; then
    echo ">> Creating Python venv..."
    python3 -m venv "$VENV_DIR"
fi
echo ">> Installing Python dependencies..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet -r "$AGENT_HOME/bot/requirements.txt"

# ── Write .env ────────────────────────────────────────────────────────
cat > "$AGENT_HOME/.env" <<EOF
MATRIX_HOMESERVER=$MATRIX_HOMESERVER
MATRIX_ADMIN_USER=$MATRIX_ADMIN_USER
MATRIX_BOT_USERNAME=$MATRIX_BOT_USERNAME
MATRIX_BOT_PASSWORD=$MATRIX_BOT_PASSWORD
COPILOT_MODEL=$COPILOT_MODEL
EOF
echo ">> Wrote credentials to $AGENT_HOME/.env"

# ── Install launcher ─────────────────────────────────────────────────
cp "$SCRIPT_DIR/start-agent.sh" "$AGENT_HOME/start-agent.sh"
chmod +x "$AGENT_HOME/start-agent.sh"

# Symlink into ~/.local/bin if it exists (common on Ubuntu/Debian)
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "$AGENT_HOME/start-agent.sh" "$BIN_DIR/start-agent"
echo ">> Symlinked start-agent → $BIN_DIR/start-agent"

echo ""
echo "=== Install Complete ==="
echo ""
echo "Usage (from any directory):"
echo "  cd /path/to/project"
echo "  start-agent                          # uses default model"
echo "  start-agent --model gpt-5            # override model"
echo "  start-agent --cli-url localhost:4321  # connect to external headless CLI"
echo ""
echo "Each directory auto-creates its own Matrix room and persists the"
echo "Copilot session ID so the next 'start-agent' in the same dir resumes."
echo ""
if ! echo "$PATH" | grep -q "$BIN_DIR"; then
    echo "NOTE: Add $BIN_DIR to your PATH if it isn't already:"
    echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
fi
