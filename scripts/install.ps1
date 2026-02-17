# install.ps1 - One-time setup for the Matrix / Copilot agent proxy (Windows).
# Creates ~\.agent-synapse-proxy\ with venv, bot sources, credentials, launcher.
# Also creates a start-agent.cmd shim so it works from cmd.exe.

$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$AgentHome  = Join-Path $HOME ".agent-synapse-proxy"

# Defaults
if (-not $env:MATRIX_HOMESERVER)   { $MatrixHS = Read-Host "Matrix homeserver URL (e.g. https://matrix.example.com)" } else { $MatrixHS = $env:MATRIX_HOMESERVER }
if (-not $env:MATRIX_ADMIN_USER)   { $MatrixAU = Read-Host "Matrix admin user ID (e.g. @admin:matrix.example.com)" } else { $MatrixAU = $env:MATRIX_ADMIN_USER }
if (-not $env:MATRIX_BOT_USERNAME) { $BotUser  = Read-Host "Bot username (pre-registered, e.g. bot-laptop)" } else { $BotUser = $env:MATRIX_BOT_USERNAME }
if (-not $env:MATRIX_BOT_PASSWORD) { $BotPass  = Read-Host "Bot password" } else { $BotPass = $env:MATRIX_BOT_PASSWORD }
if ($env:COPILOT_MODEL) { $CopModel = $env:COPILOT_MODEL } else { $CopModel = "claude-sonnet-4" }

Write-Host ""
Write-Host "=== Agent Proxy - Windows Install ==="
Write-Host "Installing to: $AgentHome"
Write-Host ""

# Create directory structure
$BotDir = Join-Path $AgentHome "bot"
New-Item -ItemType Directory -Force -Path $BotDir | Out-Null

# Copy bot sources
Write-Host ">> Copying bot sources..."
$SrcBot = Join-Path $ProjectDir "bot"
Copy-Item (Join-Path $SrcBot "agent_proxy.py")   -Destination $BotDir -Force
Copy-Item (Join-Path $SrcBot "config.py")        -Destination $BotDir -Force
Copy-Item (Join-Path $SrcBot "requirements.txt") -Destination $BotDir -Force

# Create Python venv & install deps
$VenvDir = Join-Path $AgentHome "venv"
if (-not (Test-Path $VenvDir)) {
    Write-Host ">> Creating Python venv (using Python 3.12)..."
    py -3.12 -m venv $VenvDir
    if (-not $?) {
        Write-Host ">> Python 3.12 not found via py launcher, trying system python..."
        python -m venv $VenvDir
    }
}
Write-Host ">> Installing Python dependencies..."
$env:AIOHTTP_NO_EXTENSIONS = "1"
$VenvPython = Join-Path (Join-Path $VenvDir "Scripts") "python.exe"
& $VenvPython -m pip install --quiet --upgrade pip 2>$null
$ReqFile = Join-Path $BotDir "requirements.txt"
& $VenvPython -m pip install --quiet -r $ReqFile

# Write .env.ps1 (PowerShell format)
$EnvFile = Join-Path $AgentHome ".env.ps1"
$EnvLines = @(
    "`$env:MATRIX_HOMESERVER    = `"$MatrixHS`"",
    "`$env:MATRIX_ADMIN_USER    = `"$MatrixAU`"",
    "`$env:MATRIX_BOT_USERNAME  = `"$BotUser`"",
    "`$env:MATRIX_BOT_PASSWORD  = `"$BotPass`"",
    "`$env:COPILOT_MODEL        = `"$CopModel`""
)
$EnvLines | Set-Content -Path $EnvFile -Encoding UTF8
Write-Host ">> Wrote credentials to $EnvFile"

# Install launcher
$LauncherSrc = Join-Path $ScriptDir "start-agent.ps1"
Copy-Item $LauncherSrc -Destination $AgentHome -Force

# Create a .cmd shim so it works from cmd.exe too
$CmdShim = Join-Path $AgentHome "start-agent.cmd"
@"
@echo off
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.agent-synapse-proxy\start-agent.ps1" %*
"@ | Set-Content -Path $CmdShim -Encoding ASCII
Write-Host ">> Created cmd.exe shim: $CmdShim"

# Add to PATH if not present
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$AgentHome*") {
    [Environment]::SetEnvironmentVariable("Path", "$AgentHome;$UserPath", "User")
    Write-Host ">> Added $AgentHome to user PATH (restart terminal to pick up)"
}

Write-Host ""
Write-Host "=== Install Complete ==="
Write-Host ""
Write-Host "Usage (from any directory):"
Write-Host "  cd C:\path\to\project"
Write-Host "  start-agent                                # uses default model"
Write-Host "  start-agent -Model gpt-5                   # override model"
Write-Host "  start-agent -CliUrl localhost:4321          # external headless CLI"
Write-Host ""
Write-Host "From cmd.exe:"
Write-Host "  cd C:\path\to\project"
Write-Host "  start-agent                                # uses the .cmd shim"
Write-Host ""
Write-Host "Each directory gets its own Matrix room and persisted Copilot session."
