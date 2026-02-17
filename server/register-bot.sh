#!/usr/bin/env bash
# Register a new bot user on Synapse (run from the server).
# Usage: ./register-bot.sh <username> <password>
# Example: ./register-bot.sh bot-laptop my-secret-password

set -euo pipefail
cd "${MATRIX_PROJECT_DIR:-/opt/matrix}"

BOT_USER="${1:?Usage: $0 <username> <password>}"
BOT_PASS="${2:?Usage: $0 <username> <password>}"

source .env

NONCE=$(docker compose exec -T synapse curl -s http://localhost:8008/_synapse/admin/v1/register \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['nonce'])")

MAC=$(printf '%s\0%s\0%s\0notadmin' "$NONCE" "$BOT_USER" "$BOT_PASS" \
  | openssl dgst -sha1 -hmac "$REGISTRATION_SECRET" | awk '{print $NF}')

RESULT=$(docker compose exec -T synapse curl -s -X POST http://localhost:8008/_synapse/admin/v1/register \
  -H "Content-Type: application/json" \
  -d "{\"nonce\":\"$NONCE\",\"username\":\"$BOT_USER\",\"password\":\"$BOT_PASS\",\"admin\":false,\"mac\":\"$MAC\"}")

echo "$RESULT" | python3 -c "
import sys, json
r = json.load(sys.stdin)
if 'user_id' in r:
    print(f'Registered: {r[\"user_id\"]}')
elif 'error' in r:
    print(f'Error: {r[\"error\"]}')
else:
    print(r)
"
