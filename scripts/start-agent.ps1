# start-agent.ps1 - Launch the Matrix / Copilot proxy for the CURRENT directory.
# Resumes the prior Copilot session if one exists for this path.
#
# Usage:  cd C:\path\to\project; start-agent
#         cd C:\path\to\project; start-agent -Model gpt-5
param(
    [string]$Model,
    [string]$CliUrl
)

$ErrorActionPreference = "Stop"

$AgentHome = Join-Path $HOME ".agent-synapse-proxy"
$EnvFile   = Join-Path $AgentHome ".env.ps1"
$VenvDir   = Join-Path $AgentHome "venv"
$BotDir    = Join-Path $AgentHome "bot"

# Preflight
if (-not (Test-Path $EnvFile)) {
    Write-Error "$EnvFile not found. Run install.ps1 first."
    exit 1
}
if (-not (Test-Path $VenvDir)) {
    Write-Error "Python venv not found at $VenvDir. Run install.ps1 first."
    exit 1
}

# Load credentials
. $EnvFile

# Override work dir to CWD
$env:AGENT_WORK_DIR = (Get-Location).Path

# Apply optional flags
if ($Model)  { $env:COPILOT_MODEL   = $Model }
if ($CliUrl) { $env:COPILOT_CLI_URL = $CliUrl }

# Activate venv and run
$ActivateScript = Join-Path (Join-Path $VenvDir "Scripts") "Activate.ps1"
. $ActivateScript

$DirName = Split-Path (Get-Location).Path -Leaf
if ($env:COPILOT_MODEL) { $ModelDisplay = $env:COPILOT_MODEL } else { $ModelDisplay = "claude-sonnet-4" }

Write-Host ""
Write-Host "=== Agent Proxy: $DirName ==="
Write-Host "Directory:  $($env:AGENT_WORK_DIR)"
Write-Host "Homeserver: $($env:MATRIX_HOMESERVER)"
Write-Host "Model:      $ModelDisplay"
Write-Host ""

$BotScript = Join-Path $BotDir "agent_proxy.py"
python $BotScript
