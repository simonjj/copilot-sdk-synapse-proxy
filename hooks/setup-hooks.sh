#!/bin/bash
# setup-hooks.sh — Install global Copilot CLI hooks for Matrix forwarding.
#
# Installs hooks globally at ~/.github/hooks/ so every `copilot` session
# posts events to Matrix. Each working directory auto-creates its own room.
#
# Usage:
#   bash setup-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOMESERVER="${MATRIX_HOMESERVER:-http://localhost:8008}"
ADMIN_USER="${MATRIX_ADMIN_USER:-admin}"
ADMIN_PASS="${MATRIX_ADMIN_PASS:-admin-secure-password-change-me}"
HOOKS_DIR="$HOME/.copilot-hooks"
ENV_FILE="$HOOKS_DIR/.env"
GLOBAL_HOOKS_DIR="$HOME/.github/hooks"

echo "=== Global Copilot CLI Hooks → Matrix Setup ==="
echo "Homeserver: $HOMESERVER"

# 1. Install forwarding script
echo ">> Installing forward-to-matrix.sh to $HOOKS_DIR..."
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/forward-to-matrix.sh" "$HOOKS_DIR/forward-to-matrix.sh"
chmod +x "$HOOKS_DIR/forward-to-matrix.sh"

# Init rooms cache
if [ ! -f "$HOOKS_DIR/rooms.json" ]; then
    echo '{}' > "$HOOKS_DIR/rooms.json"
fi

# 2. Get access token
echo ">> Getting access token for @${ADMIN_USER}:localhost..."
TOKEN=$(curl -s -X POST "${HOMESERVER}/_matrix/client/v3/login" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"m.login.password\",\"user\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" \
    | jq -r '.access_token')

if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to get access token. Check credentials."
    exit 1
fi
echo "   Token obtained."

# 3. Write env file
echo ">> Writing credentials to $ENV_FILE..."
cat > "$ENV_FILE" <<EOF
export MATRIX_HOMESERVER="$HOMESERVER"
export MATRIX_ACCESS_TOKEN="$TOKEN"
export HOOKS_SCRIPT_DIR="$HOOKS_DIR"
EOF
chmod 600 "$ENV_FILE"

# 4. Install hooks.json globally
echo ">> Installing hooks.json to ${GLOBAL_HOOKS_DIR}..."
mkdir -p "$GLOBAL_HOOKS_DIR"
cp "$SCRIPT_DIR/hooks.json" "$GLOBAL_HOOKS_DIR/hooks.json"

echo ""
echo "=== Setup Complete ==="
echo "Global hooks:       ${GLOBAL_HOOKS_DIR}/hooks.json"
echo "Forwarding script:  ${HOOKS_DIR}/forward-to-matrix.sh"
echo "Credentials:        ${ENV_FILE}"
echo "Room cache:         ${HOOKS_DIR}/rooms.json"
echo ""
echo "Every 'copilot' session now posts events to Matrix."
echo "Each directory auto-creates its own 'CLI: <dirname>' room."
echo ""
echo "To test:"
echo "  cd /any/project && copilot"
echo "  → Check FluffyChat for a new 'CLI: <dirname>' room"
