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
$sharedQuickstartPages = @(
    'windows/index.html',
    'nas-docker/manager.html',
    'mac/index.html',
    'linux/index.html',
    'freebsd/index.html'
)
$expandedPlatformPages = @(
    'nas-docker/manager.html',
    'mac/index.html',
    'linux/index.html',
    'freebsd/index.html'
)
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
    if ($relative -in $sharedQuickstartPages) {
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'assets/quickstart.css'))
        $combined += [IO.File]::ReadAllText((Join-Path $docs 'assets/quickstart.js'))
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
    if ($relative -notin @('examples/preview-all-00-INDEX.html', 'gui-preview/index.html', 'nas-docker/index.html')) {
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

$homeQuickstart = [IO.File]::ReadAllText((Join-Path $docs 'index.html'))
$changelog = [IO.File]::ReadAllText((Join-Path $Root 'CHANGELOG.md'))
$releaseBlocks = [regex]::Matches(
    $changelog,
    '(?ms)^## \[(?<version>\d+\.\d+\.\d+)\][^\r\n]*\r?\n(?<body>.*?)(?=^## \[|\z)'
)
$latestFeatureBlock = @($releaseBlocks | Where-Object {
    $_.Groups['body'].Value -match '(?m)^### Added\s*$'
} | Select-Object -First 1)
if ($latestFeatureBlock.Count -ne 1) {
    throw 'CHANGELOG.md does not contain a published feature release with an Added section'
}
$latestFeatureRelease = 'v' + $latestFeatureBlock[0].Groups['version'].Value
$spotlightSection = [regex]::Match(
    $homeQuickstart,
    '(?is)<section\b(?=[^>]*\bid=["'']feature-spotlight["''])[^>]*>(?<content>.*?)</section>'
)
if (-not $spotlightSection.Success) {
    throw 'Primary Quickstart feature spotlight section is missing'
}
$spotlightOpeningTag = $spotlightSection.Value.Substring(0, $spotlightSection.Value.IndexOf('>') + 1)
$featureReleaseMatch = [regex]::Match(
    $spotlightOpeningTag,
    '(?i)\bdata-feature-release=["''](?<version>v\d+\.\d+\.\d+)["'']'
)
if (-not $featureReleaseMatch.Success) {
    throw 'Primary Quickstart feature spotlight is missing data-feature-release'
}
$spotlightRelease = $featureReleaseMatch.Groups['version'].Value
if ($spotlightRelease -ne $latestFeatureRelease) {
    throw "Primary Quickstart spotlights $spotlightRelease; latest feature release is $latestFeatureRelease"
}
$releaseNotesRelative = "releases/$latestFeatureRelease.md"
if (-not [IO.File]::Exists((Join-Path $docs $releaseNotesRelative))) {
    throw "Feature spotlight release notes are missing: $releaseNotesRelative"
}
$escapedReleaseLink = [regex]::Escape('href="' + $releaseNotesRelative + '"')
if ($spotlightSection.Groups['content'].Value -notmatch $escapedReleaseLink) {
    throw "Primary Quickstart feature spotlight does not link to $releaseNotesRelative"
}
Write-Host "[PASS] Primary Quickstart spotlights latest feature release: $latestFeatureRelease"

$quickstartCss = [IO.File]::ReadAllText((Join-Path $docs 'assets/quickstart.css'))
$quickstartJs = [IO.File]::ReadAllText((Join-Path $docs 'assets/quickstart.js'))
foreach ($pattern in @(
    '@media\s*\(max-width:\s*1100px\)',
    '@media\s*\(max-width:\s*760px\)',
    '@media\s*\(prefers-reduced-motion:\s*reduce\)',
    '\.console-pulse',
    'animation:\s*none',
    '\.menu-open',
    '\.nav-scrim'
)) {
    if ($quickstartCss -notmatch $pattern) {
        throw "Shared Quickstart responsive/motion style is missing: $pattern"
    }
}
foreach ($pattern in @(
    'matchMedia\(''\(max-width: 1100px\)''\)',
    'aria-expanded',
    'aria-hidden',
    '\.inert',
    'aria-current',
    "event\.key === 'Escape'",
    "event\.key === 'Tab'",
    'navigator\.clipboard\.writeText'
)) {
    if ($quickstartJs -notmatch $pattern) {
        throw "Shared Quickstart interaction/accessibility contract is missing: $pattern"
    }
}

foreach ($relative in $sharedQuickstartPages) {
    $html = [IO.File]::ReadAllText((Join-Path $docs $relative))
    foreach ($pattern in @(
        '<body\s+class="[^"]*quickstart',
        'href="\.\./assets/quickstart\.css"',
        'src="\.\./assets/quickstart\.js"',
        'id="menu-toggle"[^>]+aria-controls="guide-nav"[^>]+aria-expanded="false"',
        'id="guide-nav"[^>]+data-quickstart-nav[^>]+aria-label=',
        'id="menu-close"[^>]+aria-label="Close guide menu"',
        'id="nav-scrim"[^>]+aria-label="Close guide menu"',
        'for="quickstart-search"',
        'id="quickstart-search"[^>]+type="search"',
        'class="console-pulse"\s+aria-hidden="true"',
        'id="scroll-percent"'
    )) {
        if ($html -notmatch $pattern) {
            throw "Shared Quickstart UI/accessibility contract '$pattern' is missing from $relative"
        }
    }

    $ids = @([regex]::Matches($html, '(?i)\bid=["''](?<id>[^"'']+)["'']') | ForEach-Object { $_.Groups['id'].Value })
    foreach ($link in [regex]::Matches($html, '(?i)<a[^>]+href=["'']#(?<target>[^"'']+)["'']')) {
        $target = $link.Groups['target'].Value
        if ($target -notin $ids) {
            throw "Shared Quickstart navigation target is missing from ${relative}: #$target"
        }
    }
    Write-Host "[PASS] Shared Quickstart UI/accessibility: $relative"
}

foreach ($relative in $expandedPlatformPages) {
    $html = [IO.File]::ReadAllText((Join-Path $docs $relative))
    foreach ($pattern in @(
        'Main features',
        'Library selection',
        'User exclusions',
        'Newsletter and custom text',
        'Basic troubleshooting',
        'id="troubleshooting"',
        'TestEmail',
        'Schedule'
    )) {
        if ($html -notmatch $pattern) {
            throw "Quickstart feature/troubleshooting coverage '$pattern' is missing from $relative"
        }
    }
    Write-Host "[PASS] Quickstart feature/troubleshooting coverage: $relative"
}

foreach ($relative in $sharedQuickstartPages) {
    $html = [IO.File]::ReadAllText((Join-Path $docs $relative))
    foreach ($pattern in @(
        'Deleted-item cache',
        'does not crawl the whole library',
        'Unseeded',
        'Disabling the cache stops reads and writes but does not erase retained entries'
    )) {
        if ($html -notmatch $pattern) {
            throw "Quickstart cache lifecycle coverage '$pattern' is missing from $relative"
        }
    }
    Write-Host "[PASS] Quickstart cache lifecycle coverage: $relative"
}

$cacheDiagnosticPatterns = [ordered]@{
    'windows/index.html'      = '19-CACHE-DIAGNOSTICS\.bat'
    'nas-docker/manager.html' = '\.\/tautweekly\.sh cache-status'
    'mac/index.html'          = 'Cache-Diagnostics\.ps1 -DataRoot /data'
    'linux/index.html'        = 'sudo tautweekly cache-status'
    'freebsd/index.html'      = 'sudo tautweekly cache-status'
}
foreach ($entry in $cacheDiagnosticPatterns.GetEnumerator()) {
    $html = [IO.File]::ReadAllText((Join-Path $docs $entry.Key))
    if ($html -notmatch $entry.Value) {
        throw "Share-safe cache diagnostic command is missing from $($entry.Key)"
    }
}
Write-Host '[PASS] Quickstarts publish platform-specific share-safe cache diagnostics'

& node (Join-Path $Root 'scripts/sync-gui-preview.mjs') --check
if ($LASTEXITCODE -ne 0) { throw 'GUI preview differs from the current Manager/release. Regenerate it before deployment.' }

$guiPreview = [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/index.html'))
$guiPreviewApp = [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/app.js'))
$guiPreviewAPI = [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/mock-api.js'))
$guiPreviewRich = [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/rich-preview.js'))
$guiPreviewCSS = [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/app.css'))
$guiPreviewManifest = [IO.File]::ReadAllText((Join-Path $docs 'gui-preview/manifest.webmanifest'))
$guiPreviewCombined = $guiPreview + $guiPreviewApp + $guiPreviewAPI + $guiPreviewRich + $guiPreviewCSS + $guiPreviewManifest

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

foreach ($pattern in @('id="demo-profile"', 'id="demo-update-scenario"', 'id="demo-release-scenario"',
    'supportsStartup', 'remote-access/tailscale', 'const DEMO_VERSION', 'TautWeeklyDemoControls',
    'No services, email, files, credentials, or schedulers are contacted')) {
    if ($guiPreviewCombined -notmatch [regex]::Escape($pattern)) { throw "Current GUI preview capability is missing: $pattern" }
}

foreach ($forbiddenPattern in @(
    '(?i)\blocalStorage\b',
    '(?i)\bsessionStorage\b',
    '(?i)\bindexedDB\b',
    '(?i)\bXMLHttpRequest\b',
    '(?i)\bWebSocket\b',
    '(?i)\bEventSource\b',
    '(?i)sendBeacon'
)) {
    if ($guiPreviewCombined -match $forbiddenPattern) {
        throw "GUI Preview contains a forbidden persistence or network pattern: $forbiddenPattern"
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

foreach ($pattern in @(
    'statMovieCount:\s*12',
    'statShowCount:\s*11',
    'statMovieCount:\s*5,\s*statShowCount:\s*1',
    'function personalRating\(',
    'class="personal-ratings"',
    'class="stats-media-stack"',
    'class="stats-summary-grid"',
    'stats-media-card \.watched-list\{display:grid;grid-template-columns:repeat\(2',
    'stats-media-card \.watched-list,\.stats-summary-grid\{grid-template-columns:1fr\}',
    'stats-tv-media-card \.watched-list\{grid-template-columns:repeat\(2',
    'watched-row>img\{width:38px;height:56px;object-fit:cover',
    'imdb img\{width:28px;height:14px;object-fit:contain\}',
    'YOU CLOCKED',
    'total watch time',
    'function complementaryFooter\(',
    'TOP GENRE THIS WEEK',
    'genre-scifi[.]gif',
    '6h 56m watched across 2 movies',
    '0 NEW MOVIES &middot;',
    'RECENT MOVIE RELEASE',
    'state[.]latest \? "RECENT RELEASES" : "NEW RELEASES"',
    'display:none;max-height:0;overflow:hidden;opacity:0">\$\{headerLine\}'
)) {
    if ($guiPreviewRich -notmatch $pattern) {
        throw "GUI Preview personal-stat parity is missing: $pattern"
    }
}
if ($guiPreviewRich -match 'items\.slice\(0,\s*2\)' -or $guiPreviewRich -match 'total watched') {
    throw 'GUI Preview retains a capped personal-stat row list or stale total-watch-time label.'
}

$guiPreviewMedia = Join-Path $docs 'gui-preview/media'
$mediaReferences = [regex]::Matches($guiPreviewRich, '(?i)"(?<name>[^"/]+\.(?:gif|png|jpe?g))"')
foreach ($reference in $mediaReferences) {
    $assetPath = Join-Path $guiPreviewMedia $reference.Groups['name'].Value
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "GUI Preview local media asset is missing: $assetPath"
    }
}

$titleGifHashes = [ordered]@{
    'alert.gif'        = '5519D94DEAAA5F0CEE21F5F2F2CBB589145820C86E47FCAA423C5A1A58561B37'
    'celebrate.gif'    = 'A142E1EB25D6277BF95A3086221BA141700E1EF96FC47C3B6A3E1919A4D18FB1'
    'construction.gif' = '08B3B20C4240E4EEA16F3E72645B0D49A705314B8396BF2D7B8D853926855638'
    'rocket.gif'       = '38FC98792F107C94ECCB9DE2B4561AF9837644978E8FD35AA9950B4598D4522A'
    'tickets.gif'      = '332193167C44D5B73DE43DB86B8AD11064EEF61744DF043A26A768E020EAF669'
    'warning.gif'      = 'AE9913885C0B0579A9548F30C0D06629A007175628F24D715E63E572FEB749B8'
}
foreach ($entry in $titleGifHashes.GetEnumerator()) {
    $assetPath = Join-Path $guiPreviewMedia $entry.Key
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "GUI Preview title GIF is missing: $assetPath"
    }
    $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash
    if ($actualHash -ne $entry.Value) {
        throw "GUI Preview title GIF was visually or bytewise modified: $($entry.Key)"
    }
    $assetID = [IO.Path]::GetFileNameWithoutExtension($entry.Key)
    if ($guiPreviewRich -notmatch [regex]::Escape("${assetID}: `"$($entry.Key)`"")) {
        throw "GUI Preview safe title-GIF mapping is missing: $assetID"
    }
}

$guiGenreAsset = Join-Path $guiPreviewMedia 'genre-scifi.gif'
if (-not (Test-Path -LiteralPath $guiGenreAsset -PathType Leaf)) {
    throw 'GUI Preview Top Genre asset is missing.'
}
if ((Get-FileHash -LiteralPath $guiGenreAsset -Algorithm SHA256).Hash -ne '0C4063723C707AE71D41AE9121A5329A91C59532DABE707F406A272138C4DD94') {
    throw 'GUI Preview Top Genre asset differs from the validated Science Fiction GIF.'
}

foreach ($pattern in @(
    'CustomTextCardTitleGif.+asset-id.+none',
    'TITLE_GIF_IDS = new Set\(\["none", "celebrate", "construction", "rocket", "tickets", "warning", "alert"\]\)',
    'const titleGifAssets = Object\.freeze',
    'Object\.hasOwn\(titleGifAssets, requestedTitleGifID\)',
    'assetInput\.type = "hidden"',
    'role", "listbox"',
    'role", "option"',
    'aria-selected',
    'aria-expanded',
    'ArrowRight',
    'ArrowDown',
    '\["Enter", " "\]',
    'Escape',
    'noTitleGifChoice',
    'assetInput\.value === choice\.id \? noTitleGifChoice : choice',
    'id: "alert", label: "Alert", file: "alert\.gif"',
    'activate again to remove',
    '\["Delete", "Backspace"\]\.includes\(event\.key\)',
    'data-material-symbol="add_reaction"|dataset\.materialSymbol = "add_reaction"',
    'data-fill="0"',
    'data-weight="400"',
    'data-grade="0"',
    'data-optical-size="24"',
    'title-gif-field\{position:relative',
    'title-gif-field>input\{min-width:0;padding-right:3\.25rem\}',
    'title-gif-trigger\{position:absolute;z-index:1;top:4px;right:4px',
    'trigger\.replaceChildren\(\)',
    'selectedImage\.className = "title-gif-trigger-image"',
    'selectedImage\.width = 24',
    'selectedImage\.height = 24',
    'title-gif-trigger \.ui-icon,\.title-gif-trigger-image\{width:24px;height:24px\}',
    'custom-title-gif.+width="18" height="18" alt="" style="vertical-align:-4px;margin-left:6px"',
    'esc\(card\.title\.toUpperCase\(\)\)\}\$\{titleGif\}',
    'titleGifID',
    'titleGifFile'
)) {
    if ($guiPreviewCombined -notmatch $pattern) {
        throw "GUI Preview title-GIF selector contract is missing: $pattern"
    }
}
if ($guiPreviewApp -match '\{ id: "none", label: "None"[^\r\n]+titleGifChoices') {
    throw 'GUI Preview title-GIF picker must not render a redundant None choice.'
}
if ($guiPreviewApp -match 'titleGifChoices = Object\.freeze\(\[[\s\S]*?\{ id: "none", label: "None"') {
    throw 'GUI Preview title-GIF picker must expose only real GIF choices.'
}

foreach ($stateID in @('demo-welcome', 'demo-new', 'demo-history', 'demo-normal', 'demo-quiet', 'demo-warnings')) {
    if ($guiPreviewRich -notmatch [regex]::Escape("`"$stateID`": {")) {
        throw "GUI Preview title-GIF coverage is missing newsletter state: $stateID"
    }
}
if ($guiPreviewRich -notmatch '\$\{welcomeBlock\(state\)\}\$\{customTextCard\(\)\}<div class="release-meta">') {
    throw 'GUI Preview custom title GIF is not routed through every newsletter state before release metadata.'
}

foreach ($pattern in @(
    'const BACKUP_LIMIT = 10',
    'const OPERATION_HISTORY_LIMIT = 20',
    'const DIAGNOSTIC_LIMIT = 20',
    'retainNewest\(Array\.from\(\{ length: 12 \}',
    'retainNewest\(\[completedPreview, \.\.\.archivedOperations\], OPERATION_HISTORY_LIMIT\)',
    'recordBackup\(revision\)',
    'recordDiagnostic\("manager-operation"',
    'maximumEntries: BACKUP_LIMIT',
    'maximumEntries: OPERATION_HISTORY_LIMIT.+retentionPolicy: "count-only-fifo"',
    'maximumEntries: DIAGNOSTIC_LIMIT.+retentionPolicy: "count-only-fifo"',
    'slice\(0, state\.backupMaximum\)',
    'slice\(0, state\.historyMaximum\)',
    'slice\(0, diagnosticMaximum\)',
    'Rolling retention keeps the newest 10',
    'Count-only FIFO keeps the newest 20 completed items',
    'Count-only FIFO keeps the newest 20 events'
)) {
    if ($guiPreviewCombined -notmatch $pattern) {
        throw "GUI Preview rolling-retention contract is missing: $pattern"
    }
}

if ($guiPreviewRich -match 'CustomTextCardTitle[^\r\n]+(?:celebrate|construction|rocket|tickets|warning)\.gif') {
    throw 'GUI Preview title text contains a literal GIF filename or marker.'
}

Write-Host '[PASS] GUI Preview title-GIF selector, safe mapping, six-state output, accessibility, and rolling FIFO caps are covered.'

Write-Host '[PASS] GUI Preview is static, relative, package-aware, locally enriched, non-persistent, and network-blocked.'

$previewGallery = [IO.File]::ReadAllText((Join-Path $docs 'examples/preview-all-00-INDEX.html'))
foreach ($previewCopy in @(
    'The real email layout, across every state.',
    'Go ahead, shrink my window.'
)) {
    if (-not $previewGallery.Contains($previewCopy)) {
        throw "Email States Preview is missing requested copy: $previewCopy"
    }
}
foreach ($pattern in @(
    'stats-title-cell',
    'stats-title-spacer',
    'stats-tv-title-cell',
    'stats-tv-title-spacer',
    'class="stats-summary-cell"',
    'summaryHeight=178',
    'winner||high?movies.length:5',
    'winner||high?shows.length:1',
    'YOU CLOCKED',
    'total watch time',
    'alt="IMDb"',
    'releaseMovies=trendingHero\?moviePool\.slice\(1,5\):',
    'releaseLine=tvOnly\?`0 NEW MOVIES •',
    'quiet\?`1 TRENDING MOVIE •',
    'plural\(movieCount,"RECENT MOVIE RELEASE","RECENT MOVIE RELEASES"\)',
    'display:none;max-height:0;overflow:hidden;opacity:0">\$\{releaseLine\}',
    'function complementaryFooterBlock',
    'const item=rotate\(movies\)\[1\]',
    'TOP GENRE THIS WEEK',
    'genre-scifi\.gif',
    '6h 56m watched across 2 movies',
    'padding-top:3px;font-size:12px;line-height:1\.35;font-weight:400;color:#8e8e8e'
)) {
    if ($previewGallery -notmatch $pattern) {
        throw "Email States Preview personal-stat parity is missing: $pattern"
    }
}
if ($previewGallery -match 'rowCount=Math\.max' -or $previewGallery -match 'total watched') {
    throw 'Email States Preview retains media-coupled summary height or stale total-watch-time copy.'
}
if ($previewGallery -match 'const item=rotate\(shows\)\[0\]') {
    throw 'Email States Preview incorrectly uses a TV show for the server-wide Trending movie feature.'
}
$previewGenreAsset = Join-Path $docs 'assets/genre-scifi.gif'
if (-not (Test-Path -LiteralPath $previewGenreAsset -PathType Leaf)) {
    throw 'Email States Preview is missing its local sanitized Top Genre asset.'
}
if ((Get-FileHash -LiteralPath $previewGenreAsset -Algorithm SHA256).Hash -ne '0C4063723C707AE71D41AE9121A5329A91C59532DABE707F406A272138C4DD94') {
    throw 'Email States Preview Top Genre asset differs from the validated Science Fiction GIF.'
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
    'docs/nas-docker/manager.html',
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

foreach ($relative in @('mac/index.html', 'freebsd/index.html')) {
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
    'sudo tautweekly update',
    'SHA256SUMS\.txt',
    'manager-reset-access'
)) {
    if ($linuxQuickstart -notmatch $pattern) {
        throw "Native Linux GUI/update guidance is missing: $pattern"
    }
}

$macQuickstart = [IO.File]::ReadAllText((Join-Path $docs 'mac/index.html'))
$macReadme = [IO.File]::ReadAllText((Join-Path $docs 'mac/README.md'))
foreach ($source in @($macQuickstart, $macReadme)) {
    foreach ($pattern in @(
        'registry-first|Manager.*source of truth|Manager is the setup source',
        'manager-bootstrap',
        'manager-reset-access|access-recover',
        'http://localhost:8787/',
        'Validate, save, and verify',
        'all six',
        'TestEmail',
        'SHA256SUMS\.txt',
        'ghcr\.io/sparkmoxie/tautweekly(?!-mac)',
        'ghcr\.io/sparkmoxie/tautweekly-mac',
        'TAUTWEEKLY_RUNTIME_PROFILE|desktop.*profile',
        'TautWeekly-mac-compose\.yaml',
        'semver|semantic version',
        'digest',
        'named volume',
        'host\.docker\.internal',
        'archive.*fallback|fallback archive',
        '\.env',
        'data/',
        'docker compose down -v',
        'v0\.24\.x',
        '30 minutes'
    )) {
        if ($source -notmatch $pattern) {
            throw "macOS Manager/update guidance is missing: $pattern"
        }
    }
    if ($source -match 'read-only preview landing page|not an administration Web UI|terminal-based') {
        throw 'macOS documentation retained pre-Manager setup language.'
    }
}

$containerMigration = [IO.File]::ReadAllText((Join-Path $docs 'CONTAINER-MIGRATION.md'))
foreach ($pattern in @(
    'desktop[\s\S]+server[\s\S]+unraid',
    'ghcr\.io/sparkmoxie/tautweekly:0\.23\.0',
    'ghcr\.io/sparkmoxie/tautweekly-mac:0\.22\.0',
    'named volume',
    'bind mount',
    'PUID.*PGID.*UMASK',
    'host\.docker\.internal',
    'interrupted pull',
    'pairing',
    'docker compose down -v',
    'v0\.24\.x',
    'v0\.25\.0',
    'not transactional|not transactional'
)) {
    if ($containerMigration -notmatch $pattern) {
        throw "Unified container migration guidance is missing: $pattern"
    }
}

$nasRedirect = [IO.File]::ReadAllText((Join-Path $docs 'nas-docker/index.html'))
foreach ($pattern in @(
    'url=manager\.html',
    'location\.replace\("manager\.html"',
    'authenticated Manager is the setup source',
    'Config, verification, six previews, controlled TestEmail delivery, scheduling, unified-image profile/status, v0\.22\.0 migration, rollback, recovery'
)) {
    if ($nasRedirect -notmatch $pattern) {
        throw "NAS canonical redirect is missing Manager source-of-truth guidance: $pattern"
    }
}
foreach ($pattern in @(
    'Setup-First\.ps1',
    '\.\/tautweekly\.sh setup',
    'read-only preview viewer',
    'not an administration Web UI'
)) {
    if ($nasRedirect -match $pattern) {
        throw "NAS canonical redirect retained stale console-first guidance: $pattern"
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
foreach ($pattern in @(
    'Manager \*\*Config\*\* is the setup source on Windows, NAS/Docker, macOS Docker\s+Desktop, native Linux, and FreeBSD Podman',
    'Terminal setup scripts remain\s+expert/recovery fallbacks',
    'Normally revise this scope in Manager Config',
    'Normally revise exclusions in Manager Config'
)) {
    if ($configuration -notmatch $pattern) {
        throw "Configuration reference is missing a GUI capability boundary: $pattern"
    }
}
foreach ($pattern in @(
    'Windows, NAS/Docker, macOS Docker Desktop, native Linux, and FreeBSD serve previews through the\s+authenticated Manager',
    'manager-bootstrap',
    'Complete Config to create the\s+persistent `config\.json`',
    'http://localhost:8787/'
)) {
    if ($troubleshooting -notmatch $pattern) {
        throw "Troubleshooting is missing Manager source-of-truth guidance: $pattern"
    }
}
foreach ($pattern in @(
    'read-only preview viewer',
    'run `\.\/tautweekly\.sh setup` or run `Setup-First\.ps1`'
)) {
    if ($troubleshooting -match $pattern) {
        throw "Troubleshooting retained stale NAS setup guidance: $pattern"
    }
}

$freeBsdQuickstart = [IO.File]::ReadAllText((Join-Path $docs 'freebsd/index.html'))
$freeBsdReadme = [IO.File]::ReadAllText((Join-Path $docs 'freebsd/README.md'))
foreach ($source in @($freeBsdQuickstart, $freeBsdReadme)) {
    foreach ($pattern in @(
        'manager-bootstrap',
        'manager-reset-access',
        'http://127\.0\.0\.1:8787',
        'Manager Config',
        'Verify',
        'PreviewAll',
        'TestEmail',
        '30 minutes'
    )) {
        if ($source -notmatch $pattern) {
            throw "FreeBSD Manager/update guidance is missing: $pattern"
        }
    }
    if ($source -match 'unauthenticated\s+preview server|preview service has no built-in authentication') {
        throw 'FreeBSD documentation retained pre-Manager authentication language.'
    }
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
