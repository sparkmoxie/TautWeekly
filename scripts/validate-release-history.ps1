[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$Version = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)

$changelogPath = Join-Path $Root 'CHANGELOG.md'
$changelog = [IO.File]::ReadAllText($changelogPath)
$releaseMatches = [regex]::Matches(
    $changelog,
    '(?m)^## \[(?<version>\d+\.\d+\.\d+)\] - (?<date>\d{4}-\d{2}-\d{2})\s*$'
)
if ($releaseMatches.Count -eq 0) {
    throw 'CHANGELOG.md has no dated semantic-version release section.'
}

$latestVersion = $releaseMatches[0].Groups['version'].Value
$latestDate = $releaseMatches[0].Groups['date'].Value
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $latestVersion }
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Release version must use MAJOR.MINOR.PATCH: $Version"
}
if ($Version -ne $latestVersion) {
    throw "Latest CHANGELOG.md release is $latestVersion, not $Version."
}

$unreleasedIndex = $changelog.IndexOf('## [Unreleased]', [StringComparison]::Ordinal)
$releaseIndex = $changelog.IndexOf("## [$Version]", [StringComparison]::Ordinal)
if ($unreleasedIndex -lt 0 -or $releaseIndex -lt 0 -or $unreleasedIndex -gt $releaseIndex) {
    throw 'CHANGELOG.md must keep [Unreleased] before the latest dated release.'
}

$notesRelative = "docs/releases/v$Version.md"
$notesPath = Join-Path $Root $notesRelative
if (-not [IO.File]::Exists($notesPath)) {
    throw "Release notes are missing: $notesRelative"
}
$notes = [IO.File]::ReadAllText($notesPath)
if ($notes -notmatch "(?m)^# TautWeekly for Plex v$([regex]::Escape($Version))\s*$") {
    throw "$notesRelative does not identify TautWeekly for Plex v$Version."
}
$releasedMatch = [regex]::Match($notes, '(?m)^Released:\s*(?<date>\d{4}-\d{2}-\d{2})\s*$')
if (-not $releasedMatch.Success -or $releasedMatch.Groups['date'].Value -ne $latestDate) {
    throw "$notesRelative does not use the CHANGELOG.md release date $latestDate."
}

$versionFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'platforms') -Filter VERSION.txt -Recurse)
if ($versionFiles.Count -eq 0) {
    throw 'No platform VERSION.txt source-baseline files were found.'
}
foreach ($file in $versionFiles) {
    $firstLine = [IO.File]::ReadLines($file.FullName) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($firstLine) -or $firstLine -notmatch '\bv\d+\.\d+\.\d+\b') {
        throw "$($file.FullName) does not identify its independent platform source baseline."
    }
}

Write-Host "[PASS] Release history identifies v$Version on $latestDate with matching notes and $($versionFiles.Count) valid platform source baselines."
