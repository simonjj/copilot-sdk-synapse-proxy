#!/usr/bin/env bash
# start-agent.sh — Launch the Matrix ↔ Copilot proxy for the CURRENT directory.
# Resumes the prior Copilot session if one exists for this path.
#
# Usage:  cd /path/to/project && start-agent
#         cd /path/to/project && start-agent --model gpt-5
set -euo pipefail

AGENT_HOME="$HOME/.agent-synapse-proxy"
ENV_FILE="$AGENT_HOME/.env"
VENV_DIR="$AGENT_HOME/venv"
BOT_DIR="$AGENT_HOME/bot"

# ── Preflight ─────────────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found. Run install.sh first." >&2
    exit 1
fi
if [ ! -d "$VENV_DIR" ]; then
    echo "ERROR: Python venv not found at $VENV_DIR. Run install.sh first." >&2
    exit 1
fi

# ── Load credentials ─────────────────────────────────────────────────
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ── Override work dir to CWD ──────────────────────────────────────────
export AGENT_WORK_DIR="${AGENT_WORK_DIR:-$(pwd)}"

# ── Parse optional flags ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)   export COPILOT_MODEL="$2"; shift 2 ;;
        --cli-url) export COPILOT_CLI_URL="$2"; shift 2 ;;
        *)         echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Activate venv and run ─────────────────────────────────────────────
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

DIR_NAME="$(basename "$AGENT_WORK_DIR")"
echo "=== Agent Proxy: $DIR_NAME ==="
echo "Directory:  $AGENT_WORK_DIR"
echo "Homeserver: $MATRIX_HOMESERVER"
echo "Model:      ${COPILOT_MODEL:-claude-sonnet-4}"
echo ""

exec python "$BOT_DIR/agent_proxy.py"
