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
    'mac/index.html',
    'linux/index.html',
    'freebsd/index.html',
    'examples/preview-all-00-INDEX.html'
)
$redirectPages = @('nas-docker/quickstart.html')
$terminalPages = 0
$renderedUrls = @{
    'index.html'                  = 'https://sparkmoxie.github.io/TautWeekly/'
    'windows/index.html'          = 'https://sparkmoxie.github.io/TautWeekly/windows/'
    'nas-docker/index.html'       = 'https://sparkmoxie.github.io/TautWeekly/nas-docker/'
    'mac/index.html'              = 'https://sparkmoxie.github.io/TautWeekly/mac/'
    'linux/index.html'            = 'https://sparkmoxie.github.io/TautWeekly/linux/'
    'freebsd/index.html'          = 'https://sparkmoxie.github.io/TautWeekly/freebsd/'
    'examples/preview-all-00-INDEX.html' = 'https://sparkmoxie.github.io/TautWeekly/examples/preview-all-00-INDEX.html'
}
$expectedTitles = @{
    'index.html'             = 'TautWeekly Quickstart | TautWeekly for Plex'
    'windows/index.html'     = 'Windows Quickstart | TautWeekly for Plex'
    'nas-docker/index.html'  = 'NAS/Docker/QNAP/Unraid Quickstart | TautWeekly for Plex'
    'mac/index.html'         = 'macOS Quickstart | TautWeekly for Plex'
    'linux/index.html'       = 'Native Linux Quickstart | TautWeekly for Plex'
    'freebsd/index.html'     = 'FreeBSD Podman Quickstart | TautWeekly for Plex'
}

foreach ($relative in $pages) {
    $path = Join-Path $docs $relative
    $html = [IO.File]::ReadAllText($path)
    $combined = $html
    if ($relative -eq 'index.html') {
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'assets/styles.css'))
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'assets/site.js'))
    }

    $requiredPatterns = @(
        '(?i)<!doctype\s+html',
        '(?i)<title>[^<]+</title>',
        '(?i)<meta[^>]+name=["'']viewport["'']',
        '(?i)@media'
    )
    if ($relative -ne 'examples/preview-all-00-INDEX.html') {
        $requiredPatterns += @(
            '(?i)search',
            '(?i)progress',
            '(?i)position\s*:\s*sticky'
        )
    }

    foreach ($pattern in $requiredPatterns) {
        if ($combined -notmatch $pattern) {
            throw "Documentation feature '$pattern' is missing from $relative"
        }
    }

    if ($expectedTitles.ContainsKey($relative)) {
        $escapedTitle = [regex]::Escape($expectedTitles[$relative])
        if ($html -notmatch "(?i)<title>$escapedTitle</title>") {
            throw "Canonical Quickstart title is missing from ${relative}: $($expectedTitles[$relative])"
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

$previewGallery = [IO.File]::ReadAllText((Join-Path $docs 'examples/preview-all-00-INDEX.html'))
foreach ($previewCopy in @(
    'The real email layout, across every state.',
    'Go ahead, shrink my window.'
)) {
    if (-not $previewGallery.Contains($previewCopy)) {
        throw "Email States Preview is missing requested copy: $previewCopy"
    }
}

if ($terminalPages -lt 3) {
    throw "Expected terminal demonstrations on at least three documentation pages; found $terminalPages."
}

Write-Host "[PASS] Terminal demonstrations are present on $terminalPages page(s)."

foreach ($relative in $redirectPages) {
    $path = Join-Path $docs $relative
    $html = [IO.File]::ReadAllText($path)
    foreach ($pattern in @(
        '(?i)<meta[^>]+http-equiv=["'']refresh["'']',
        '(?i)<link[^>]+rel=["'']canonical["''][^>]+/TautWeekly/nas-docker/',
        '(?i)location\.replace\(',
        '(?i)href=["'']\./["'']'
    )) {
        if ($html -notmatch $pattern) {
            throw "Compatibility redirect feature '$pattern' is missing from $relative"
        }
    }
    Write-Host "[PASS] Compatibility redirect: $relative"
}

$publishedHtml = @(Get-ChildItem -LiteralPath $docs -Recurse -File -Filter '*.html' | ForEach-Object {
    $_.FullName.Substring($docs.Length).TrimStart('\', '/') -replace '\\', '/'
})
$expectedHtml = @($pages) + @($redirectPages)
$unexpectedHtml = @($publishedHtml | Where-Object { $_ -notin $expectedHtml })
$missingHtml = @($expectedHtml | Where-Object { $_ -notin $publishedHtml })
if ($unexpectedHtml -or $missingHtml) {
    throw "Rendered Pages inventory mismatch. Missing: $($missingHtml -join ', '); unexpected: $($unexpectedHtml -join ', ')"
}

$rootReadme = [IO.File]::ReadAllText((Join-Path $Root 'README.md'))
$docsReadme = [IO.File]::ReadAllText((Join-Path $docs 'README.md'))
$entryMarkdown = $rootReadme + [Environment]::NewLine + $docsReadme

$metadataReadinessDocs = @(
    'docs/CONFIGURATION.md',
    'docs/TROUBLESHOOTING.md',
    'docs/windows/README.md',
    'docs/nas-docker/README.md',
    'docs/mac/README.md',
    'docs/linux/README.md',
    'docs/freebsd/README.md',
    'docs/index.html',
    'docs/windows/index.html',
    'docs/nas-docker/index.html',
    'docs/mac/index.html',
    'docs/linux/index.html',
    'docs/freebsd/index.html'
)
foreach ($relative in $metadataReadinessDocs) {
    $content = [IO.File]::ReadAllText((Join-Path $Root $relative))
    foreach ($pattern in @(
        'Ratings Source',
        'Refresh All Metadata',
        'Media Info',
        'Refresh media info',
        '(?i)per[- ]library',
        '(?i)routine TautWeekly updates do not require'
    )) {
        if ($content -notmatch $pattern) {
            throw "Metadata-readiness guidance '$pattern' is missing from $relative"
        }
    }
    Write-Host "[PASS] Metadata readiness: $relative"
}

$nasInstall = [IO.File]::ReadAllText((Join-Path $docs 'nas-docker/README.md'))
if ($nasInstall -match '(?m)^/opt/tautweekly/bin/run-mode\.sh PreviewAll\s*$') {
    throw 'Unraid Console documentation contains PreviewAll without the required USER_ID.'
}
foreach ($pattern in @(
    '/opt/tautweekly/bin/run-mode\.sh PreviewAll USER_ID',
    'does not select or save a default user'
)) {
    if ($nasInstall -notmatch $pattern) { throw "NAS user-selection guidance is missing: $pattern" }
}

foreach ($relative in @('nas-docker/index.html', 'mac/index.html', 'linux/index.html', 'freebsd/index.html')) {
    $html = [IO.File]::ReadAllText((Join-Path $docs $relative))
    if ($html -notmatch 'USER_ID') { throw "Numeric USER_ID guidance is missing from $relative" }
}

$windowsQuickstart = [IO.File]::ReadAllText((Join-Path $docs 'windows/index.html'))
$windowsBatFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'platforms/windows') -File -Filter '*.bat')
foreach ($batFile in $windowsBatFiles) {
    $escapedBatName = [regex]::Escape($batFile.Name)
    if ($windowsQuickstart -notmatch "(?i)<strong>$escapedBatName</strong>") {
        throw "Windows BAT command center is missing launcher: $($batFile.Name)"
    }
}
$numberedWindowsBatCount = @($windowsBatFiles | Where-Object Name -match '^\d{2}-').Count
$escapedWindowsBatMetric = [regex]::Escape("<b>$numberedWindowsBatCount</b><span>numbered BAT launchers</span>")
if ($windowsQuickstart -notmatch $escapedWindowsBatMetric) {
    throw "Windows Quickstart launcher metric does not match the $numberedWindowsBatCount numbered BAT files."
}
foreach ($pattern in @(
    'Apply this stable update safely',
    'SHA256SUMS',
    'automatic rollback',
    'No periodic update task'
)) {
    if ($windowsQuickstart -notmatch $pattern) {
        throw "Windows Quickstart is missing safe-update guidance: $pattern"
    }
}

$linuxInstall = [IO.File]::ReadAllText((Join-Path $docs 'linux/README.md'))
$linuxOperations = [regex]::Match($linuxInstall, '(?ms)^## Operations\s*(?<content>.*?)(?=^##\s)')
if (-not $linuxOperations.Success -or $linuxOperations.Groups['content'].Value -notmatch 'sudo tautweekly check-update') {
    throw 'Native Linux Operations list is missing the manual stable update check.'
}

$configuration = [IO.File]::ReadAllText((Join-Path $docs 'CONFIGURATION.md'))
$troubleshooting = [IO.File]::ReadAllText((Join-Path $docs 'TROUBLESHOOTING.md'))
if ($configuration -notmatch 'SmtpAuthenticationMethod' -or $configuration -notmatch 'successful `235` response') {
    throw 'SMTP authentication transport is not documented in CONFIGURATION.md.'
}
if ($troubleshooting -notmatch 'smtp\.protonmail\.ch' -or $troubleshooting -notmatch 'Sender address rejected: not logged in') {
    throw 'Proton SMTP troubleshooting guidance is missing.'
}
foreach ($relative in $pages) {
    $url = $renderedUrls[$relative]
    if (-not $entryMarkdown.Contains($url)) {
        throw "Rendered Pages URL is not linked from README entry points: $url"
    }
}

$quickstartLinks = [ordered]@{
    'TautWeekly Quickstart'              = 'https://sparkmoxie.github.io/TautWeekly/'
    'Windows Quickstart'                 = 'https://sparkmoxie.github.io/TautWeekly/windows/'
    'NAS/Docker/QNAP/Unraid Quickstart'  = 'https://sparkmoxie.github.io/TautWeekly/nas-docker/'
    'macOS Quickstart'                   = 'https://sparkmoxie.github.io/TautWeekly/mac/'
    'Native Linux Quickstart'            = 'https://sparkmoxie.github.io/TautWeekly/linux/'
    'FreeBSD Podman Quickstart'          = 'https://sparkmoxie.github.io/TautWeekly/freebsd/'
}
foreach ($entryPoint in @{
    'README.md'      = $rootReadme
    'docs/README.md' = $docsReadme
}.GetEnumerator()) {
    $linkContent = $entryPoint.Value
    if ($entryPoint.Key -eq 'docs/README.md') {
        $section = [regex]::Match(
            $entryPoint.Value,
            '(?ms)^## Interactive Quickstart Guides\s*(?<content>.*?)(?=^##\s)'
        )
        if (-not $section.Success) {
            throw "Interactive Quickstart Guides section is missing from $($entryPoint.Key)"
        }
        $linkContent = $section.Groups['content'].Value
    }
    foreach ($link in $quickstartLinks.GetEnumerator()) {
        $expectedLink = "[$($link.Key)]($($link.Value))"
        if (-not $linkContent.Contains($expectedLink)) {
            throw "Canonical Quickstart link is missing from $($entryPoint.Key): $expectedLink"
        }
    }
    if ($entryPoint.Key -eq 'docs/README.md' -and $linkContent -match '(?i)Unraid (?:Community )?Apps') {
        throw "Unraid Apps must not appear as a separate top-level Quickstart in $($entryPoint.Key)"
    }
}

$unraidCatalogUrl = 'https://ca.unraid.net/apps/tautweekly-for-plex-16l668j1jpt7jb'
$nasComparisonRow = @($rootReadme -split "`r?`n" | Where-Object { $_ -match '^\| NAS / Docker \|' })
if ($nasComparisonRow.Count -ne 1 -or -not $nasComparisonRow[0].Contains("[Unraid Apps]($unraidCatalogUrl)")) {
    throw 'The NAS platform comparison row must retain its direct Unraid Apps catalog link.'
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

Write-Host "[PASS] All $($pages.Count) canonical HTML documentation files have rendered Pages links; $($redirectPages.Count) retired URL redirects safely."
