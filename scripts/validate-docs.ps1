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
    'mac/index.html',
    'linux/index.html',
    'freebsd/index.html'
)
$terminalPages = 0
$renderedUrls = @{
    'index.html'                  = 'https://sparkmoxie.github.io/TautWeekly/'
    'windows/index.html'          = 'https://sparkmoxie.github.io/TautWeekly/windows/'
    'nas-docker/index.html'       = 'https://sparkmoxie.github.io/TautWeekly/nas-docker/'
    'nas-docker/quickstart.html'  = 'https://sparkmoxie.github.io/TautWeekly/nas-docker/quickstart.html'
    'mac/index.html'              = 'https://sparkmoxie.github.io/TautWeekly/mac/'
    'linux/index.html'            = 'https://sparkmoxie.github.io/TautWeekly/linux/'
    'freebsd/index.html'          = 'https://sparkmoxie.github.io/TautWeekly/freebsd/'
}

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

    if ($relative -in @('windows/index.html', 'nas-docker/index.html', 'mac/index.html', 'linux/index.html', 'freebsd/index.html')) {
        foreach ($section in [regex]::Matches($html, '(?is)<section\b(?<attrs>[^>]*)>')) {
            $attributes = $section.Groups['attrs'].Value
            if ($attributes -notmatch '(?i)\bdata-search\s*=') { continue }
            if ($attributes -notmatch '(?i)\bclass\s*=\s*["''](?<classes>[^"'']+)["'']') {
                throw "Searchable section without a class in $relative"
            }
            $classes = @($Matches['classes'] -split '\s+')
            if ('section' -notin $classes -and 'hero' -notin $classes -and 'metrics' -notin $classes) {
                throw "Searchable section is outside the styled/search-filtered section sets in ${relative}: $($attributes.Trim())"
            }
        }
    }

    if ($combined -match '(?i)terminal') { $terminalPages++ }
    Write-Host "[PASS] Documentation features: $relative"
}

if ($terminalPages -lt 3) {
    throw "Expected terminal demonstrations on at least three documentation pages; found $terminalPages."
}

Write-Host "[PASS] Terminal demonstrations are present on $terminalPages page(s)."

$publishedHtml = @(Get-ChildItem -LiteralPath $docs -Recurse -File -Filter '*.html' | ForEach-Object {
    $_.FullName.Substring($docs.Length).TrimStart('\', '/') -replace '\\', '/'
})
$unexpectedHtml = @($publishedHtml | Where-Object { $_ -notin $pages })
$missingHtml = @($pages | Where-Object { $_ -notin $publishedHtml })
if ($unexpectedHtml -or $missingHtml) {
    throw "Rendered Pages inventory mismatch. Missing: $($missingHtml -join ', '); unexpected: $($unexpectedHtml -join ', ')"
}

$entryMarkdown = [IO.File]::ReadAllText((Join-Path $Root 'README.md')) +
    [Environment]::NewLine + [IO.File]::ReadAllText((Join-Path $docs 'README.md'))
foreach ($relative in $pages) {
    $url = $renderedUrls[$relative]
    if (-not $entryMarkdown.Contains($url)) {
        throw "Rendered Pages URL is not linked from README entry points: $url"
    }
}

$markdownFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.md' | Where-Object {
    $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)'
}
foreach ($markdown in $markdownFiles) {
    $content = [IO.File]::ReadAllText($markdown.FullName)
    foreach ($link in [regex]::Matches($content, '!?(?:\[[^\]]*\])\((?<target>[^)\s]+\.html(?:#[^)\s]+)?)\)')) {
        $target = $link.Groups['target'].Value
        $absolute = $null
        if ([Uri]::TryCreate($target, [UriKind]::Absolute, [ref]$absolute) -and
            $absolute.Host -notin @('github.com', 'raw.githubusercontent.com')) {
            continue
        }
        if (-not $target.StartsWith('https://sparkmoxie.github.io/TautWeekly/', [StringComparison]::OrdinalIgnoreCase)) {
            throw "HTML documentation must link to rendered Pages, not source: $($markdown.FullName) -> $target"
        }
    }
}

Write-Host "[PASS] All $($pages.Count) HTML documentation files have rendered Pages links."
