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
    'nas-docker/manager.html',
    'mac/index.html',
    'linux/index.html',
    'freebsd/index.html',
    'gui-preview/index.html',
    'examples/preview-all-00-INDEX.html'
)
$redirectPages = @('nas-docker/quickstart.html')
$terminalPages = 0
$renderedUrls = @{
    'index.html'                  = 'https://sparkmoxie.github.io/TautWeekly/'
    'windows/index.html'          = 'https://sparkmoxie.github.io/TautWeekly/windows/'
    'nas-docker/index.html'       = 'https://sparkmoxie.github.io/TautWeekly/nas-docker/'
    'nas-docker/manager.html'     = 'https://sparkmoxie.github.io/TautWeekly/nas-docker/'
    'mac/index.html'              = 'https://sparkmoxie.github.io/TautWeekly/mac/'
    'linux/index.html'            = 'https://sparkmoxie.github.io/TautWeekly/linux/'
    'freebsd/index.html'          = 'https://sparkmoxie.github.io/TautWeekly/freebsd/'
    'gui-preview/index.html'      = 'https://sparkmoxie.github.io/TautWeekly/gui-preview/'
    'examples/preview-all-00-INDEX.html' = 'https://sparkmoxie.github.io/TautWeekly/examples/preview-all-00-INDEX.html'
}
$expectedTitles = @{
    'index.html'             = 'TautWeekly Quickstart | TautWeekly for Plex'
    'windows/index.html'     = 'Windows Quickstart | TautWeekly for Plex'
    'nas-docker/index.html'  = 'NAS/Docker/QNAP/Unraid Quickstart | TautWeekly for Plex'
    'nas-docker/manager.html' = 'NAS / Docker Manager Quickstart | TautWeekly for Plex'
    'mac/index.html'         = 'macOS Quickstart | TautWeekly for Plex'
    'linux/index.html'       = 'Native Linux Quickstart | TautWeekly for Plex'
    'freebsd/index.html'     = 'FreeBSD Podman Quickstart | TautWeekly for Plex'
    'gui-preview/index.html' = 'TautWeekly Manager GUI Preview'
}

foreach ($relative in $pages) {
    $path = Join-Path $docs $relative
    $html = [IO.File]::ReadAllText($path)
    $combined = $html
    if ($relative -in @('index.html', 'nas-docker/manager.html')) {
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'assets/styles.css'))
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'assets/site.js'))
    }
    if ($relative -eq 'gui-preview/index.html') {
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/app.css'))
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/demo.css'))
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/mock-api.js'))
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/app.js'))
    }

    $requiredPatterns = @(
        '(?i)<!doctype\s+html',
        '(?i)<title>[^<]+</title>',
        '(?i)<meta[^>]+name=["'']viewport["'']',
        '(?i)@media'
    )
    if ($relative -notin @('examples/preview-all-00-INDEX.html', 'gui-preview/index.html')) {
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

$guiPreview = [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/index.html'))
$guiPreviewApp = [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/app.js'))
$guiPreviewAPI = [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/mock-api.js'))
$guiPreviewRich = [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/rich-preview.js'))
$guiPreviewManifest = [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/manifest.webmanifest'))
$guiPreviewCombined = $guiPreview + $guiPreviewApp + $guiPreviewAPI + $guiPreviewRich + $guiPreviewManifest

foreach ($pattern in @(
    'connect-src ''none''',
    'Interactive GUI Preview',
    'Fictional data',
    'No services, email, files, credentials, or schedulers are contacted',
    'sandbox="allow-same-origin"',
    'window\.fetch\s*=',
    'window\.TautWeeklyPreviewDemo',
    'srcdoc',
    'synthetic-demo',
    'Rotten Tomatoes',
    'IMDb',
    'media/',
    'demo\.invalid',
    'start_url"\s*:\s*"\./"',
    'scope"\s*:\s*"\./"'
)) {
    if ($guiPreviewCombined -notmatch $pattern) {
        throw "GUI Preview boundary or behavior is missing: $pattern"
    }
}

foreach ($forbiddenPattern in @(
    '(?i)\blocalStorage\b',
    '(?i)\bsessionStorage\b',
    '(?i)\bindexedDB\b',
    '(?i)\bXMLHttpRequest\b',
    '(?i)\bWebSocket\b',
    '(?i)\bEventSource\b',
    '(?i)sendBeacon',
    '(?i)\bWindows\b',
    '(?i)\bUAC\b',
    '(?i)\bSYSTEM principal\b'
)) {
    if ($guiPreviewCombined -match $forbiddenPattern) {
        throw "GUI Preview contains a forbidden persistence, network, or platform-specific pattern: $forbiddenPattern"
    }
}

$previewResourceAttributes = [regex]::Matches($guiPreview, '(?i)\b(?:src|href)=["''](?<target>[^"'']+)["'']')
foreach ($attribute in $previewResourceAttributes) {
    $target = $attribute.Groups['target'].Value
    if ($target.StartsWith('#') -or $target -eq '../') { continue }
    if ($target -match '^https://sparkmoxie\.github\.io/TautWeekly/gui-preview/$') { continue }
    if ($target -match '^(?:https?:)?//' -or $target.StartsWith('/')) {
        throw "GUI Preview asset or navigation target must be relative and local: $target"
    }
}

if ($guiPreviewAPI -match '(?i)https?://(?![^"'']*\.invalid(?:[:/]|["'']))') {
    throw 'GUI Preview mock API contains a non-fictional HTTP endpoint.'
}

if ($guiPreviewRich -match '(?i)https?://') {
    throw 'GUI Preview rich newsletter renderer contains an external HTTP endpoint.'
}

$guiPreviewMedia = Join-Path $docs 'gui-preview/media'
$mediaReferences = [regex]::Matches($guiPreviewRich, '(?i)"(?<name>[^"/]+\.(?:gif|png|jpe?g))"')
foreach ($reference in $mediaReferences) {
    $assetPath = Join-Path $guiPreviewMedia $reference.Groups['name'].Value
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "GUI Preview local media asset is missing: $assetPath"
    }
}

Write-Host '[PASS] GUI Preview is static, relative, package-neutral, locally enriched, non-persistent, and network-blocked.'

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
if ($nasInstall -match '(?m)^\.\/tautweekly\.sh preview-all\s*$') {
    throw 'NAS wrapper documentation contains preview-all without the required USER_ID.'
}
foreach ($pattern in @(
    '\.\/tautweekly\.sh preview-all USER_ID',
    'does not persist a default'
)) {
    if ($nasInstall -notmatch $pattern) { throw "NAS user-selection guidance is missing: $pattern" }
}

foreach ($relative in @('nas-docker/index.html', 'mac/index.html', 'freebsd/index.html')) {
    $html = [IO.File]::ReadAllText((Join-Path $docs $relative))
    if ($html -notmatch 'USER_ID') { throw "Numeric USER_ID guidance is missing from $relative" }
}

$linuxQuickstart = [IO.File]::ReadAllText((Join-Path $docs 'linux/index.html'))
foreach ($pattern in @(
    'GUI-first installation',
    'manager-bootstrap',
    'http://127\.0\.0\.1:8788',
    'Config.*Validate, save, and verify',
    'Previews.*Generate six previews',
    'Operations.*Send TestEmail',
    'install-linux\.sh --upgrade',
    'SHA256SUMS\.txt',
    'manager-reset-access'
)) {
    if ($linuxQuickstart -notmatch $pattern) {
        throw "Native Linux GUI/update guidance is missing: $pattern"
    }
}

$windowsQuickstart = [IO.File]::ReadAllText((Join-Path $docs 'windows/index.html'))
$windowsReadme = [IO.File]::ReadAllText((Join-Path $docs 'windows/README.md'))
foreach ($pattern in @(
    'TautWeekly-Setup\.exe',
    'authoritative Setup EXE',
    'Windows Manager',
    'First time setup',
    'Validate, save, and verify',
    'Libraries and users',
    'Tautulli and Plex',
    'SMTP preflight',
    'Local previews',
    'persistent Config',
    'No pairing token',
    'at least 8 characters',
    'Reset TautWeekly Manager Access',
    'choose the exact old portable folder for <strong>Migrate</strong>',
    'SHA256SUMS',
    'automatic rollback',
    'No periodic update task',
    'Portable recovery and advanced tools'
)) {
    if ($windowsQuickstart -notmatch $pattern) {
        throw "Windows Quickstart is missing Manager/Setup source-of-truth guidance: $pattern"
    }
}

foreach ($pattern in @(
    'TautWeekly-Setup\.exe',
    '(?i)normal setup flow',
    '\*\*Install\*\*',
    '\*\*Update\*\*',
    '\*\*Migrate\*\*',
    'First time setup',
    'Validate, save, and verify',
    'Optional Manager password',
    'at least 8 characters',
    'Portable recovery and advanced tools'
)) {
    if ($windowsReadme -notmatch $pattern) {
        throw "Windows README is missing Setup/Manager primary-flow guidance: $pattern"
    }
}

foreach ($source in @{
    'Windows Quickstart' = $windowsQuickstart
    'Windows README'     = $windowsReadme
}.GetEnumerator()) {
    $setupPosition = $source.Value.IndexOf('TautWeekly-Setup.exe', [StringComparison]::OrdinalIgnoreCase)
    $batPosition = $source.Value.IndexOf('.bat', [StringComparison]::OrdinalIgnoreCase)
    if ($setupPosition -lt 0 -or ($batPosition -ge 0 -and $batPosition -lt $setupPosition)) {
        throw "$($source.Key) presents a BAT launcher before the supported Setup EXE flow."
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
