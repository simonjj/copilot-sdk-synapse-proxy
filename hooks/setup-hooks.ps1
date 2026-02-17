# setup-hooks.ps1 — Install global Copilot CLI hooks for Matrix forwarding (Windows).
#
# Installs hooks globally at ~/.github/hooks/ so every `copilot` session
# posts events to Matrix. Each working directory auto-creates its own room.
#
# Usage:
#   pwsh setup-hooks.ps1

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Homeserver = if ($env:MATRIX_HOMESERVER) { $env:MATRIX_HOMESERVER } else { "http://localhost:8008" }
$AdminUser = if ($env:MATRIX_ADMIN_USER) { $env:MATRIX_ADMIN_USER } else { "admin" }
$AdminPass = if ($env:MATRIX_ADMIN_PASS) { $env:MATRIX_ADMIN_PASS } else { "admin-secure-password-change-me" }
$HooksDir = Join-Path $HOME ".copilot-hooks"
$EnvFile = Join-Path $HooksDir ".env.ps1"
$GlobalHooksDir = Join-Path $HOME ".github" "hooks"

Write-Host "=== Global Copilot CLI Hooks -> Matrix Setup (Windows) ==="
Write-Host "Homeserver: $Homeserver"

# 1. Install forwarding scripts
Write-Host ">> Installing scripts to $HooksDir..."
New-Item -ItemType Directory -Force -Path $HooksDir | Out-Null
Copy-Item (Join-Path $ScriptDir "forward-to-matrix.ps1") (Join-Path $HooksDir "forward-to-matrix.ps1") -Force
Copy-Item (Join-Path $ScriptDir "forward-to-matrix.sh") (Join-Path $HooksDir "forward-to-matrix.sh") -Force

# Init rooms cache
$roomsFile = Join-Path $HooksDir "rooms.json"
if (-not (Test-Path $roomsFile)) {
    '{}' | Out-File $roomsFile -Encoding utf8
}

# 2. Get access token
Write-Host ">> Getting access token for @${AdminUser}:localhost..."
$loginBody = @{
    type = "m.login.password"
    user = $AdminUser
    password = $AdminPass
} | ConvertTo-Json -Compress

$loginResp = Invoke-RestMethod -Uri "${Homeserver}/_matrix/client/v3/login" `
    -Method Post -ContentType "application/json" -Body $loginBody
$Token = $loginResp.access_token

if (-not $Token) {
    Write-Error "Failed to get access token. Check credentials."
    exit 1
}
Write-Host "   Token obtained."

# 3. Write env file (PowerShell format)
Write-Host ">> Writing credentials to $EnvFile..."
@"
`$env:MATRIX_HOMESERVER = "$Homeserver"
`$env:MATRIX_ACCESS_TOKEN = "$Token"
`$env:HOOKS_SCRIPT_DIR = "$HooksDir"
"@ | Out-File $EnvFile -Encoding utf8

# 4. Install hooks.json globally
Write-Host ">> Installing hooks.json to ${GlobalHooksDir}..."
New-Item -ItemType Directory -Force -Path $GlobalHooksDir | Out-Null
Copy-Item (Join-Path $ScriptDir "hooks.json") (Join-Path $GlobalHooksDir "hooks.json") -Force

Write-Host ""
Write-Host "=== Setup Complete ==="
Write-Host "Global hooks:       ${GlobalHooksDir}\hooks.json"
Write-Host "Forwarding script:  ${HooksDir}\forward-to-matrix.ps1"
Write-Host "Credentials:        ${EnvFile}"
Write-Host "Room cache:         ${HooksDir}\rooms.json"
Write-Host ""
Write-Host "Every 'copilot' session now posts events to Matrix."
Write-Host "Each directory auto-creates its own 'CLI: <dirname>' room."
Write-Host ""
Write-Host "To test:"
Write-Host "  cd C:\any\project"
Write-Host "  copilot"
Write-Host "  -> Check FluffyChat for a new 'CLI: <dirname>' room"
