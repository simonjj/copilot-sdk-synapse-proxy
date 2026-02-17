# init-hooks.ps1 — Initialize Copilot CLI Matrix hooks in the current directory.
#
# Run this in any project dir to enable Matrix monitoring for that project.
# Copies hooks.json from the global config into .github/hooks/
#
# Usage:
#   pwsh /path/to/init-hooks.ps1
#   or from any dir: & "$HOME\.copilot-hooks\init-hooks.ps1"

param([string]$TargetDir = ".")

$HooksDir = Join-Path $HOME ".copilot-hooks"
$GithubHooksDir = Join-Path (Join-Path $TargetDir ".github") "hooks"

# Check if global setup has been done
if (-not (Test-Path (Join-Path $HooksDir ".env.ps1"))) {
    Write-Host "❌ Global hooks not set up yet. Run setup-hooks.ps1 first." -ForegroundColor Red
    exit 1
}

# Create .github/hooks/ in the project
New-Item -ItemType Directory -Force -Path $GithubHooksDir | Out-Null

$targetFile = Join-Path $GithubHooksDir "hooks.json"
$sourceFile = Join-Path $HooksDir "hooks.json"

if (Test-Path $targetFile) {
    Write-Host "⚠️  hooks.json already exists. Replacing..." -ForegroundColor Yellow
}

# Copy (Windows doesn't support symlinks well without admin)
Copy-Item $sourceFile $targetFile -Force
Write-Host "✅ Installed: $targetFile" -ForegroundColor Green

$DirName = Split-Path (Resolve-Path $TargetDir) -Leaf
Write-Host ""
Write-Host "Hooks initialized for: $DirName"
Write-Host "Run 'copilot' here and check FluffyChat for 'CLI: $DirName' room."
