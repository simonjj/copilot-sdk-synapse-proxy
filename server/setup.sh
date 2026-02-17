#!/usr/bin/env bash
# setup.sh — Deploy Matrix Synapse with Caddy TLS.
#
# Usage:
#   export MATRIX_DOMAIN="matrix.example.com"
#   bash setup.sh
#
# Prerequisites: Docker + Docker Compose, ports 80 + 443 open, DNS pointed.
set -euo pipefail

DOMAIN="${MATRIX_DOMAIN:?Set MATRIX_DOMAIN (e.g. matrix.example.com)}"
PROJECT_DIR="${MATRIX_PROJECT_DIR:-/opt/matrix}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Matrix Synapse Setup ==="
echo "Domain:     $DOMAIN"
echo "Deploy to:  $PROJECT_DIR"
echo ""

# --- Copy server files to project dir ---
mkdir -p "$PROJECT_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$PROJECT_DIR/"
cp "$SCRIPT_DIR/Caddyfile" "$PROJECT_DIR/"
cp "$SCRIPT_DIR/register-bot.sh" "$PROJECT_DIR/"
chmod +x "$PROJECT_DIR/register-bot.sh"

cd "$PROJECT_DIR"

# Write MATRIX_DOMAIN into .env so Caddy can read it
if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo ">> Generating secrets..."
    PG_PASS=$(openssl rand -hex 16)
    REG_SECRET=$(openssl rand -hex 32)
    cat > "$PROJECT_DIR/.env" << EOF
MATRIX_DOMAIN=$DOMAIN
PG_PASSWORD=$PG_PASS
REGISTRATION_SECRET=$REG_SECRET
EOF
    echo "   Saved to .env"
    echo ""
    echo "   >>> SAVE THESE SECRETS SOMEWHERE SAFE <<<"
    echo ""
else
    echo ">> .env already exists, loading..."
    # Ensure domain is set
    if ! grep -q "MATRIX_DOMAIN" "$PROJECT_DIR/.env"; then
        echo "MATRIX_DOMAIN=$DOMAIN" >> "$PROJECT_DIR/.env"
    fi
fi

source "$PROJECT_DIR/.env"

# --- Step 2: Generate Synapse config if signing key doesn't exist ---
if [ ! -f "$PROJECT_DIR/synapse-data/$DOMAIN.signing.key" ]; then
    echo ">> Generating Synapse config and signing key..."
    mkdir -p "$PROJECT_DIR/synapse-data"
    docker run --rm \
        -v "$PROJECT_DIR/synapse-data:/data" \
        -e SYNAPSE_SERVER_NAME="$DOMAIN" \
        -e SYNAPSE_REPORT_STATS=no \
        matrixdotorg/synapse:latest generate
    echo "   Signing key generated."
else
    echo ">> Signing key already exists, skipping generate."
fi

# --- Step 3: Write hardened homeserver.yaml ---
echo ">> Writing hardened homeserver.yaml..."
cat > "$PROJECT_DIR/synapse-data/homeserver.yaml" << YAML
server_name: "$DOMAIN"
pid_file: /data/homeserver.pid
public_baseurl: "https://$DOMAIN/"

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client]
        compress: false

database:
  name: psycopg2
  args:
    user: synapse
    password: "$PG_PASSWORD"
    database: synapse
    host: postgres
    cp_min: 5
    cp_max: 10

log_config: "/data/$DOMAIN.log.config"
media_store_path: /data/media_store
signing_key_path: "/data/$DOMAIN.signing.key"

federation_domain_whitelist: []

enable_registration: false
enable_registration_without_verification: false
registration_shared_secret: "$REGISTRATION_SECRET"

trusted_key_servers: []
suppress_key_server_warning: true

max_upload_size: 20M
url_preview_enabled: false

rc_message:
  per_second: 10
  burst_count: 30

rc_login:
  address:
    per_second: 1
    burst_count: 5
  account:
    per_second: 1
    burst_count: 3

report_stats: false
YAML
echo "   homeserver.yaml written."

# --- Step 4: Start services ---
echo ">> Starting services..."
docker compose up -d
echo ">> Waiting for Synapse to become healthy..."
for i in $(seq 1 30); do
    if docker compose exec -T synapse curl -fsSo /dev/null http://localhost:8008/health 2>/dev/null; then
        echo "   Synapse is healthy!"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "   ERROR: Synapse didn't start. Check: docker compose logs synapse"
        exit 1
    fi
    sleep 3
done

# --- Step 5: Register admin user ---
echo ""
echo ">> Registering admin user..."
ADMIN_USER="admin"
read -s -p "Choose admin password: " ADMIN_PASS
echo ""

# Use docker exec to reach Synapse admin API (not exposed externally)
NONCE=$(docker compose exec -T synapse curl -s http://localhost:8008/_synapse/admin/v1/register | python3 -c "import sys,json; print(json.load(sys.stdin)['nonce'])")
MAC=$(printf '%s\0%s\0%s\0admin' "$NONCE" "$ADMIN_USER" "$ADMIN_PASS" | openssl dgst -sha1 -hmac "$REGISTRATION_SECRET" | awk '{print $NF}')

RESULT=$(docker compose exec -T synapse curl -s -X POST http://localhost:8008/_synapse/admin/v1/register \
    -H "Content-Type: application/json" \
    -d "{\"nonce\":\"$NONCE\",\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\",\"admin\":true,\"mac\":\"$MAC\"}")

if echo "$RESULT" | grep -q "user_id\|already taken"; then
    echo "   Admin user ready: @${ADMIN_USER}:${DOMAIN}"
else
    echo "   WARNING: $RESULT"
fi

echo ""
echo "=== Setup Complete ==="
echo "Public URL:     https://$DOMAIN"
echo "Admin user:     @${ADMIN_USER}:${DOMAIN}"
echo "Secrets in:     $PROJECT_DIR/.env"
echo ""
echo "Test: curl https://$DOMAIN/_matrix/client/versions"
