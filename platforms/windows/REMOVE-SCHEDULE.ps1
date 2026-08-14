Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($PSScriptRoot)
$configPath = Join-Path $root 'config.json'
$helperPath = Join-Path $root 'SCHEDULE-HELPER.ps1'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'config.json is missing. Restore it before removing the owned schedule so the exact task name and configuration revision can be verified.'
}
if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw 'The verified schedule helper is missing. Reinstall or re-extract the complete official Windows package.'
}

$revision = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
& $helperPath -Action Remove -ExpectedRevision $revision
if ($LASTEXITCODE -ne 0) {
    throw "The verified schedule removal did not complete (exit code $LASTEXITCODE). A missing or unowned same-named task is left untouched."
}

Write-Host 'Removed the verified TautWeekly scheduled task.' -ForegroundColor Green
