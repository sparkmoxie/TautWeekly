Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($PSScriptRoot)
$configPath = Join-Path $root 'config.json'
$helperPath = Join-Path $root 'SCHEDULE-HELPER.ps1'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'config.json is missing. Open Manager Config and save a valid configuration, or use 00-SETUP-FIRST.bat as the portable fallback.'
}
if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw 'The verified schedule helper is missing. Reinstall or re-extract the complete official Windows package.'
}

$revision = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
& $helperPath -Action Install -ExpectedRevision $revision
if ($LASTEXITCODE -ne 0) {
    throw "The verified schedule install/refresh did not complete (exit code $LASTEXITCODE). Open Manager Schedule for the current task state and support guidance."
}

Write-Host ''
Write-Host 'TautWeekly for Plex schedule installed or refreshed and ownership verified.' -ForegroundColor Green
Write-Host 'Open Manager Schedule to review the configured window, task state, and upcoming run.'
