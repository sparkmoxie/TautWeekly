[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$checker = Join-Path $Root 'platforms/windows/Check-Update.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("tautweekly-update-check-" + [guid]::NewGuid().ToString('N'))
$metadata = Join-Path $testRoot 'RELEASE-METADATA.txt'

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    [IO.File]::WriteAllText($metadata, "Repository version: 0.5.4`n", [Text.UTF8Encoding]::new($false))

    $currentOutput = (& $checker -MetadataPath $metadata -LatestVersion 'v0.5.4' | Out-String)
    if ($currentOutput -notmatch 'This package is up to date\.') {
        throw 'Windows stable-release checker did not report an equal version as current.'
    }

    $updateOutput = (& $checker -MetadataPath $metadata -LatestVersion '0.5.5' | Out-String)
    if ($updateOutput -notmatch 'A stable update is available: 0\.5\.4 -> 0\.5\.5') {
        throw 'Windows stable-release checker did not report the expected update.'
    }
    if ($updateOutput -match '(?i)installing|downloading') {
        throw 'Windows check-only output implies that it applies the update.'
    }

    [IO.File]::WriteAllText($metadata, "Repository version: 0.5.6`n", [Text.UTF8Encoding]::new($false))
    $newerOutput = (& $checker -MetadataPath $metadata -LatestVersion '0.5.5' | Out-String)
    if ($newerOutput -notmatch 'newer than GitHub''s latest stable release; no update is offered') {
        throw 'Windows stable-release checker offered a downgrade for a newer installed package.'
    }

    Write-Host '[PASS] Windows stable-release check behavior validated.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
