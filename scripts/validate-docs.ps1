[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$docs = Join-Path $Root 'docs'
$pages = @(
    'index.html',
    'windows/index.html',
    'nas-docker/index.html',
    'nas-docker/quickstart.html',
    'mac/index.html'
)
$terminalPages = 0

foreach ($relative in $pages) {
    $path = Join-Path $docs $relative
    $html = [IO.File]::ReadAllText($path)
    $combined = $html
    if ($relative -eq 'index.html') {
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'assets/styles.css'))
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'assets/site.js'))
    }

    foreach ($pattern in @(
        '(?i)<!doctype\s+html',
        '(?i)<title>[^<]+</title>',
        '(?i)<meta[^>]+name=["'']viewport["'']',
        '(?i)search',
        '(?i)progress',
        '(?i)position\s*:\s*sticky',
        '(?i)@media'
    )) {
        if ($combined -notmatch $pattern) {
            throw "Documentation feature '$pattern' is missing from $relative"
        }
    }

    $ids = @([regex]::Matches($html, '(?i)\bid=["''](?<id>[^"'']+)["'']') | ForEach-Object { $_.Groups['id'].Value })
    $duplicates = @($ids | Group-Object | Where-Object Count -gt 1)
    if ($duplicates) {
        throw "Duplicate HTML id(s) in ${relative}: $($duplicates.Name -join ', ')"
    }
    if ($combined -match '(?i)terminal') { $terminalPages++ }
    Write-Host "[PASS] Documentation features: $relative"
}

if ($terminalPages -lt 3) {
    throw "Expected terminal demonstrations on at least three documentation pages; found $terminalPages."
}

Write-Host "[PASS] Terminal demonstrations are present on $terminalPages page(s)."
