# forward-to-matrix.ps1 — Posts Copilot CLI hook events to a Matrix room.
#
# Each working directory gets its own Matrix room (auto-created on first use).
# Room mapping is cached in ~/.copilot-hooks/rooms.json
#
# Required env vars (loaded from ~/.copilot-hooks/.env.ps1):
#   MATRIX_HOMESERVER   — e.g., http://localhost:8008
#   MATRIX_ACCESS_TOKEN — admin user's access token

$ErrorActionPreference = "SilentlyContinue"

# Auto-load credentials
$envFile = Join-Path $HOME ".copilot-hooks" ".env.ps1"
if (Test-Path $envFile) { . $envFile }

$HookType = $env:HOOK_TYPE
if (-not $HookType) { $HookType = "unknown" }

$Homeserver = if ($env:MATRIX_HOMESERVER) { $env:MATRIX_HOMESERVER } else { "http://localhost:8008" }
$Token = $env:MATRIX_ACCESS_TOKEN
$RoomsFile = Join-Path $HOME ".copilot-hooks" "rooms.json"

# Skip if not configured
if (-not $Token) { exit 0 }

# Read JSON from stdin
$InputText = @($input) -join "`n"
if (-not $InputText) {
    try { $InputText = [Console]::In.ReadToEnd() } catch { $InputText = "" }
}
if (-not $InputText) { exit 0 }
$Event = $InputText | ConvertFrom-Json

# Get working directory from hook event
$EventCwd = if ($Event.cwd) { $Event.cwd } else { (Get-Location).Path }
$DirName = Split-Path $EventCwd -Leaf

# --- Room-per-directory logic ---
if (-not (Test-Path $RoomsFile)) {
    '{}' | Out-File $RoomsFile -Encoding utf8
}
$Rooms = Get-Content $RoomsFile -Raw | ConvertFrom-Json
$RoomId = $Rooms.$EventCwd

if (-not $RoomId) {
    # Create a new room for this directory
    $RoomName = "CLI: $DirName"
    $createBody = @{
        name = $RoomName
        topic = "Copilot CLI monitor for $EventCwd"
        visibility = "private"
    } | ConvertTo-Json -Compress

    try {
        $resp = Invoke-RestMethod -Uri "${Homeserver}/_matrix/client/v3/createRoom" `
            -Method Post -Headers @{ Authorization = "Bearer $Token" } `
            -ContentType "application/json" -Body $createBody
        $RoomId = $resp.room_id
    } catch {
        exit 0
    }

    if ($RoomId) {
        $Rooms | Add-Member -NotePropertyName $EventCwd -NotePropertyValue $RoomId -Force
        $Rooms | ConvertTo-Json -Compress | Out-File $RoomsFile -Encoding utf8
    } else {
        exit 0
    }
}

# Format message based on hook type
$Msg = switch ($HookType) {
    "sessionStart" {
        $source = if ($Event.source) { $Event.source } else { "unknown" }
        $prompt = if ($Event.initialPrompt) { $Event.initialPrompt } else { "(none)" }
        "🟢 **Session started** ($source)`n📁 ``$EventCwd```n💬 $prompt"
    }
    "sessionEnd" {
        $reason = if ($Event.reason) { $Event.reason } else { "unknown" }
        "🔴 **Session ended**: $reason"
    }
    "userPromptSubmitted" {
        $prompt = if ($Event.prompt) { $Event.prompt } else { "" }
        "👤 **Prompt**: $prompt"
    }
    "preToolUse" {
        $tool = if ($Event.toolName) { $Event.toolName } else { "?" }
        $args = if ($Event.toolArgs) { $Event.toolArgs.Substring(0, [Math]::Min(500, $Event.toolArgs.Length)) } else { "{}" }
        "🔧 **Tool call**: ``$tool```n``````n$args`n``````"
    }
    "postToolUse" {
        $tool = if ($Event.toolName) { $Event.toolName } else { "?" }
        $resultType = if ($Event.toolResult.resultType) { $Event.toolResult.resultType } else { "?" }
        $resultText = if ($Event.toolResult.textResultForLlm) {
            $Event.toolResult.textResultForLlm.Substring(0, [Math]::Min(1000, $Event.toolResult.textResultForLlm.Length))
        } else { "" }
        $icon = if ($resultType -eq "success") { "✅" } else { "❌" }
        "$icon **$tool** ($resultType)`n``````n$resultText`n``````"
    }
    "errorOccurred" {
        $errName = if ($Event.error.name) { $Event.error.name } else { "Error" }
        $errMsg = if ($Event.error.message) { $Event.error.message } else { "Unknown error" }
        "🚨 **Error** [$errName]: $errMsg"
    }
    default {
        "📋 **$HookType**: $($InputText.Substring(0, [Math]::Min(500, $InputText.Length)))"
    }
}

# Send to Matrix room
$TxnId = "hook-$(Get-Date -Format 'yyyyMMddHHmmssfff')-$$"
$sendBody = @{
    msgtype = "m.text"
    body = $Msg
    format = "org.matrix.custom.html"
    formatted_body = $Msg
} | ConvertTo-Json -Compress

try {
    Invoke-RestMethod -Uri "${Homeserver}/_matrix/client/v3/rooms/${RoomId}/send/m.room.message/${TxnId}" `
        -Method Put -Headers @{ Authorization = "Bearer $Token" } `
        -ContentType "application/json" -Body $sendBody | Out-Null
} catch {}
