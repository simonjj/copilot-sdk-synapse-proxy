#!/bin/bash
# forward-to-matrix.sh — Posts Copilot CLI hook events to a Matrix room.
#
# Each working directory gets its own Matrix room (auto-created on first use).
# Room mapping is cached in ~/.copilot-hooks/rooms.json
#
# Required env vars (loaded from ~/.copilot-hooks/.env):
#   MATRIX_HOMESERVER   — e.g., http://localhost:8008
#   MATRIX_ACCESS_TOKEN — admin user's access token

set -e

# Auto-load credentials
if [ -f "$HOME/.copilot-hooks/.env" ]; then source "$HOME/.copilot-hooks/.env"; fi

INPUT=$(cat)
HOOK_TYPE="${HOOK_TYPE:-unknown}"
HOMESERVER="${MATRIX_HOMESERVER:-http://localhost:8008}"
ROOMS_FILE="$HOME/.copilot-hooks/rooms.json"

# Skip if not configured
if [ -z "$MATRIX_ACCESS_TOKEN" ]; then
    exit 0
fi

# Get working directory from the hook event
EVENT_CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
if [ -z "$EVENT_CWD" ]; then
    EVENT_CWD="$(pwd)"
fi
DIR_NAME=$(basename "$EVENT_CWD")

# --- Room-per-directory logic ---
# Load or init rooms cache
if [ ! -f "$ROOMS_FILE" ]; then
    echo '{}' > "$ROOMS_FILE"
fi

MATRIX_ROOM_ID=$(jq -r --arg dir "$EVENT_CWD" '.[$dir] // ""' "$ROOMS_FILE")

if [ -z "$MATRIX_ROOM_ID" ]; then
    # Create a new room for this directory
    ROOM_NAME="CLI: $DIR_NAME"
    MATRIX_ROOM_ID=$(curl -s -X POST "${HOMESERVER}/_matrix/client/v3/createRoom" \
        -H "Authorization: Bearer ${MATRIX_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg name "$ROOM_NAME" --arg topic "Copilot CLI monitor for $EVENT_CWD" \
            '{name: $name, topic: $topic, visibility: "private"}')" \
        | jq -r '.room_id // ""')

    if [ -n "$MATRIX_ROOM_ID" ] && [ "$MATRIX_ROOM_ID" != "null" ]; then
        # Cache the room mapping
        jq --arg dir "$EVENT_CWD" --arg room "$MATRIX_ROOM_ID" '.[$dir] = $room' "$ROOMS_FILE" > "${ROOMS_FILE}.tmp"
        mv "${ROOMS_FILE}.tmp" "$ROOMS_FILE"
    else
        exit 0
    fi
fi

# Format the message based on hook type
case "$HOOK_TYPE" in
    sessionStart)
        SOURCE=$(echo "$INPUT" | jq -r '.source // "unknown"')
        PROMPT=$(echo "$INPUT" | jq -r '.initialPrompt // "(none)"')
        CWD=$(echo "$INPUT" | jq -r '.cwd // "?"')
        MSG="🟢 **Session started** ($SOURCE)\n📁 \`$CWD\`\n💬 $PROMPT"
        ;;
    sessionEnd)
        REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"')
        MSG="🔴 **Session ended**: $REASON"
        ;;
    userPromptSubmitted)
        PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')
        MSG="👤 **Prompt**: $PROMPT"
        ;;
    preToolUse)
        TOOL=$(echo "$INPUT" | jq -r '.toolName // "?"')
        ARGS=$(echo "$INPUT" | jq -r '.toolArgs // "{}"' | head -c 500)
        MSG="🔧 **Tool call**: \`$TOOL\`\n\`\`\`\n$ARGS\n\`\`\`"
        ;;
    postToolUse)
        TOOL=$(echo "$INPUT" | jq -r '.toolName // "?"')
        RESULT_TYPE=$(echo "$INPUT" | jq -r '.toolResult.resultType // "?"')
        RESULT_TEXT=$(echo "$INPUT" | jq -r '.toolResult.textResultForLlm // ""' | head -c 1000)
        if [ "$RESULT_TYPE" = "success" ]; then
            ICON="✅"
        else
            ICON="❌"
        fi
        MSG="$ICON **$TOOL** ($RESULT_TYPE)\n\`\`\`\n$RESULT_TEXT\n\`\`\`"
        ;;
    errorOccurred)
        ERR_NAME=$(echo "$INPUT" | jq -r '.error.name // "Error"')
        ERR_MSG=$(echo "$INPUT" | jq -r '.error.message // "Unknown error"')
        MSG="🚨 **Error** [$ERR_NAME]: $ERR_MSG"
        ;;
    *)
        MSG="📋 **$HOOK_TYPE**: $(echo "$INPUT" | head -c 500)"
        ;;
esac

# Send to Matrix room
TXN_ID="hook-$(date +%s%N)-$$"
curl -s -o /dev/null -X PUT \
    "${HOMESERVER}/_matrix/client/v3/rooms/${MATRIX_ROOM_ID}/send/m.room.message/${TXN_ID}" \
    -H "Authorization: Bearer ${MATRIX_ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg body "$MSG" '{msgtype: "m.text", body: $body, format: "org.matrix.custom.html", formatted_body: $body}')"
