[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$DistPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
if ([string]::IsNullOrWhiteSpace($DistPath)) { $DistPath = Join-Path $Root 'dist' }
$DistPath = [IO.Path]::GetFullPath($DistPath)

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-ZipEntrySha256([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Assert-RendererContract([string]$PackageName, [string]$Renderer) {
    Assert-True ($Renderer.Contains('Get-OptionalStringProperty -InputObject $Row -Name "section_id"')) "$PackageName lacks the executable library predicate fix."
    Assert-True ($Renderer.Contains('$params.section_id = $sectionId')) "$PackageName lacks server-side selected-library scoping."
    Assert-True ($Renderer.Contains('$expectedSectionId = ([string]$ExpectedSectionId).Trim()')) "$PackageName lacks scoped recently-added row handling."
    Assert-True ($Renderer.Contains('if ([string]::IsNullOrWhiteSpace($sectionId)) { return $true }')) "$PackageName rejects selected-library rows that omit redundant section metadata."
    Assert-True ($Renderer.Contains('Get-OptionalStringProperty -InputObject $meta -Name "title"')) "$PackageName does not treat sparse hero metadata as optional."
    Assert-True (-not $Renderer.Contains('[string]$meta.title')) "$PackageName retains strict direct access to optional hero title metadata."
    Assert-True ($Renderer.Contains('Smtp-Transport.ps1')) "$PackageName does not load the explicit SMTP authentication transport."
    Assert-True ($Renderer.Contains('Send-TautWeeklySmtpMessage')) "$PackageName does not route mail through the explicit SMTP transport."
    Assert-True ($Renderer.Contains('function Get-StatsTvShowRowsHtml')) "$PackageName lacks grouped TV-show personal statistics."
    Assert-True ($Renderer.Contains('$tvShows = @($Stats.TvShowItems | Select-Object -First 4)')) "$PackageName does not enrich watched TV shows for IMDb ratings."
    Assert-True ($Renderer.Contains('Get-OptionalStringProperty -InputObject $item -Name "DesignImdbRating"')) "$PackageName does not render IMDb ratings in watched-TV statistics."
    Assert-True ($Renderer.Contains('function Get-PlexWatchRatings')) "$PackageName lacks the exact-slug public Plex rating fallback."
    Assert-True ($Renderer.Contains('function Get-PlexHostedMetadataMatchPayload')) "$PackageName lacks exact modern/legacy provider payload construction."
    Assert-True ($Renderer.Contains('function Get-PlexHostedMetadataItemFromResponse')) "$PackageName lacks shared hosted metadata response parsing."
    Assert-True ($Renderer.Contains('function Test-PlexHostedMetadataExactMatch')) "$PackageName lacks fail-closed hosted match validation."
    Assert-True ($Renderer.Contains('-Method Post')) "$PackageName lacks the provider-contract POST retry for empty exact-ID matches."
    Assert-True ($Renderer.Contains('matching hints only: require an exact modern GUID')) "$PackageName does not document the exact-identifier hosted POST boundary."
    Assert-True ($Renderer.Contains('"User-Agent"      = "TautWeekly-for-Plex/0.8.3"')) "$PackageName does not identify the tokenless public Plex rating fallback."
    Assert-True ($Renderer.Contains('"X-Plex-Version"           = "0.8.3"')) "$PackageName does not identify the authenticated hosted metadata fallback."
    Assert-True ($Renderer.Contains('"Accept-Language" = "en-US,en;q=0.9"')) "$PackageName does not request stable provider-labelled rating text."
    Assert-True ($Renderer.Contains('function Get-BingeChampionTitleBreakdown')) "$PackageName lacks the media-specific Binge Champion title breakdown."
    Assert-True ($Renderer.Contains('$bingeTimeLine = "$([string]$bingeDisplay.TotalTimeText) watched"')) "$PackageName has stale Binge Champion duration copy."
    Assert-True (-not $Renderer.Contains('$bingeHeadline')) "$PackageName retains the retired one-line Binge Champion metric."
    Assert-True ($Renderer.Contains('$heroLabel = if ($trendingHeroMode) { "TRENDING THIS WEEK" } else { "HOT NEW RELEASE" }')) "$PackageName lacks the movie-empty Trending hero fallback."
    Assert-True ($Renderer.Contains('"tautulli-default-poster-" + [Guid]::NewGuid().ToString("N") + ".png"')) "$PackageName lacks the portable generic-poster probe."
    Assert-True ($Renderer.Contains('Get-FileHash -LiteralPath $probePath -Algorithm SHA256')) "$PackageName lacks literal-path poster fingerprinting."
}

$expected = [ordered]@{
    'TautWeekly-windows.zip' = @(
        'TautWeekly-windows/TautWeekly.ps1',
        'TautWeekly-windows/Smtp-Transport.ps1',
        'TautWeekly-windows/config.example.json',
        'TautWeekly-windows/15-MANAGE-LIBRARIES.bat',
        'TautWeekly-windows/16-LIST-LIBRARIES.bat',
        'TautWeekly-windows/17-CHECK-FOR-UPDATE.bat',
        'TautWeekly-windows/Check-Update.ps1',
        'TautWeekly-windows/Windows-Update.ps1',
        'TautWeekly-windows/Operation-Lock.ps1',
        'TautWeekly-windows/RELEASE-FILES.txt',
        'TautWeekly-windows/RELEASE-METADATA.txt',
        'TautWeekly-windows/README.md'
    )
    'TautWeekly-nas-docker.zip' = @(
        'TautWeekly-nas-docker/app/TautWeekly.ps1',
        'TautWeekly-nas-docker/app/Smtp-Transport.ps1',
        'TautWeekly-nas-docker/app/Schedule-Time.ps1',
        'TautWeekly-nas-docker/app/healthcheck.sh',
        'TautWeekly-nas-docker/tautweekly.sh',
        'TautWeekly-nas-docker/container-update.sh',
        'TautWeekly-nas-docker/compose.yaml',
        'TautWeekly-nas-docker/RELEASE-FILES.txt',
        'TautWeekly-nas-docker/README.md'
    )
    'TautWeekly-mac-docker.zip' = @(
        'TautWeekly-mac-docker/app/TautWeekly.ps1',
        'TautWeekly-mac-docker/app/Smtp-Transport.ps1',
        'TautWeekly-mac-docker/app/Schedule-Time.ps1',
        'TautWeekly-mac-docker/tautweekly.sh',
        'TautWeekly-mac-docker/check-release.sh',
        'TautWeekly-mac-docker/mac-update.sh',
        'TautWeekly-mac-docker/INSTALL-MAC.command',
        'TautWeekly-mac-docker/RELEASE-FILES.txt',
        'TautWeekly-mac-docker/README.md'
    )
    'TautWeekly-linux.zip' = @(
        'TautWeekly-linux/app/TautWeekly.ps1',
        'TautWeekly-linux/app/Smtp-Transport.ps1',
        'TautWeekly-linux/app/Schedule-Time.ps1',
        'TautWeekly-linux/install-linux.sh',
        'TautWeekly-linux/systemd/tautweekly.service',
        'TautWeekly-linux/tautweekly',
        'TautWeekly-linux/check-release.sh',
        'TautWeekly-linux/RELEASE-METADATA.txt',
        'TautWeekly-linux/RELEASE-FILES.txt',
        'TautWeekly-linux/README.md'
    )
    'TautWeekly-freebsd-podman.zip' = @(
        'TautWeekly-freebsd-podman/app/TautWeekly.ps1',
        'TautWeekly-freebsd-podman/app/Smtp-Transport.ps1',
        'TautWeekly-freebsd-podman/app/Schedule-Time.ps1',
        'TautWeekly-freebsd-podman/install-freebsd.sh',
        'TautWeekly-freebsd-podman/rc.d/tautweekly',
        'TautWeekly-freebsd-podman/tautweekly',
        'TautWeekly-freebsd-podman/RELEASE-FILES.txt',
        'TautWeekly-freebsd-podman/README.md'
    )
}

$assetRoots = [ordered]@{
    'TautWeekly-windows.zip'         = 'TautWeekly-windows/assets'
    'TautWeekly-nas-docker.zip'      = 'TautWeekly-nas-docker/app/assets-default'
    'TautWeekly-mac-docker.zip'      = 'TautWeekly-mac-docker/app/assets-default'
    'TautWeekly-linux.zip'           = 'TautWeekly-linux/app/assets-default'
    'TautWeekly-freebsd-podman.zip'  = 'TautWeekly-freebsd-podman/app/assets-default'
}
$expectedGifHashes = [ordered]@{
    'movies.gif' = '9BCD489463C963C38469771518700308CCADE3965A32EDA18E12DC718950C971'
    'tv.gif'     = '35FFCB45F313953AD0EEF2C7EC852B4B68B0E033E5055BC0926B87EB2EDEF117'
}
$zipReleaseManifests = @{}
$releaseVersions = New-Object System.Collections.Generic.List[string]

$forbiddenNames = @(
    'config.json', '.env', 'state.json', 'access-state.json',
    'scheduler-state.json', 'scheduler-heartbeat.json', 'service-heartbeat.json'
)

$zipArchives = @(Get-ChildItem -LiteralPath $DistPath -File -Filter '*.zip')
Assert-True ($zipArchives.Count -eq 5) "Expected five ZIP release artifacts, found $($zipArchives.Count)."

foreach ($archiveName in $expected.Keys) {
    $archivePath = Join-Path $DistPath $archiveName
    Assert-True (Test-Path -LiteralPath $archivePath) "Missing release artifact: $archiveName"
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        $unsafeEntries = @($entryNames | Where-Object {
            $_ -match '^(?:/|[A-Za-z]:)' -or @($_ -split '/' | Where-Object { $_ -eq '..' }).Count -gt 0
        })
        Assert-True ($unsafeEntries.Count -eq 0) "$archiveName contains unsafe archive paths: $($unsafeEntries -join ', ')"
        foreach ($requiredEntry in $expected[$archiveName]) {
            Assert-True ($entryNames -ccontains $requiredEntry) "$archiveName is missing $requiredEntry"
        }

        $forbidden = @($entryNames | Where-Object {
            $name = ($_ -split '/')[-1]
            $name -in $forbiddenNames -or $_ -match '/(logs|output)/'
        })
        Assert-True ($forbidden.Count -eq 0) "$archiveName contains runtime/private paths: $($forbidden -join ', ')"

        $manifestEntry = @($archive.Entries | Where-Object { $_.FullName -match '/RELEASE-FILES\.txt$' })
        Assert-True ($manifestEntry.Count -eq 1) "$archiveName has no unique release-owned file manifest."
        $manifestReader = New-Object IO.StreamReader($manifestEntry[0].Open())
        try { $releaseManifest = $manifestReader.ReadToEnd() }
        finally { $manifestReader.Dispose() }
        $packageName = $archiveName.Substring(0, $archiveName.Length - '.zip'.Length)
        $zipReleaseManifests[$packageName] = ($releaseManifest -replace "`r`n", "`n").Trim()
        Assert-True ($releaseManifest -match '(?m)^[0-9a-f]{64}\s{2}RELEASE-METADATA\.txt\r?$') "$archiveName release manifest does not hash release metadata."
        Assert-True ($releaseManifest -notmatch '(?im)(?:^|/)(?:config\.json|state\.json|access-state\.json|scheduler-state\.json|\.tautweekly-operation\.lock)$') "$archiveName release manifest owns private runtime files."
        $manifestLines = @($releaseManifest -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-True ($manifestLines.Count -eq ($entryNames.Count - 1)) "$archiveName release manifest does not cover every packaged file except itself."
        $seenManifestPaths = @{}
        foreach ($manifestLine in $manifestLines) {
            Assert-True ($manifestLine -match '^(?<hash>[0-9a-f]{64})\s{2}(?<path>.+)$') "$archiveName has an invalid release manifest line: $manifestLine"
            $expectedFileHash = $Matches['hash']
            $relativePath = $Matches['path'].Replace('\', '/')
            Assert-True (-not $seenManifestPaths.ContainsKey($relativePath.ToLowerInvariant())) "$archiveName release manifest duplicates $relativePath."
            $seenManifestPaths[$relativePath.ToLowerInvariant()] = $true
            $packagedPath = ($manifestEntry[0].FullName -replace 'RELEASE-FILES\.txt$', '') + $relativePath
            $packagedEntry = @($archive.Entries | Where-Object { $_.FullName -ceq $packagedPath })
            Assert-True ($packagedEntry.Count -eq 1) "$archiveName release manifest references a missing or duplicate file: $relativePath"
            $sha256 = [Security.Cryptography.SHA256]::Create()
            $entryStream = $packagedEntry[0].Open()
            try {
                $actualHash = ([BitConverter]::ToString($sha256.ComputeHash($entryStream))).Replace('-', '').ToLowerInvariant()
            }
            finally {
                $entryStream.Dispose()
                $sha256.Dispose()
            }
            Assert-True ($actualHash -eq $expectedFileHash) "$archiveName release manifest hash failed for $relativePath."
        }

        $metadataEntry = @($archive.Entries | Where-Object { $_.FullName -match '/RELEASE-METADATA\.txt$' })
        Assert-True ($metadataEntry.Count -eq 1) "$archiveName has no unique release metadata file."
        $metadataReader = New-Object IO.StreamReader($metadataEntry[0].Open())
        try { $metadata = $metadataReader.ReadToEnd() }
        finally { $metadataReader.Dispose() }
        Assert-True ($metadata -match '(?m)^Repository version:\s*(?<version>\S+)\s*$') "$archiveName does not identify its repository version."
        $releaseVersions.Add($Matches['version'])

        $rendererEntry = @($archive.Entries | Where-Object { $_.FullName -match '/(?:app/)?TautWeekly\.ps1$' } | Select-Object -First 1)
        Assert-True ($rendererEntry.Count -eq 1) "$archiveName has no production renderer."
        $reader = New-Object IO.StreamReader($rendererEntry[0].Open())
        try { $renderer = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
        Assert-RendererContract -PackageName $archiveName -Renderer $renderer

        foreach ($gifName in $expectedGifHashes.Keys) {
            $gifEntryName = "$($assetRoots[$archiveName])/$gifName"
            $gifEntry = @($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -ceq $gifEntryName })
            Assert-True ($gifEntry.Count -eq 1) "$archiveName is missing $gifEntryName"
            $actualGifHash = Get-ZipEntrySha256 -Entry $gifEntry[0]
            Assert-True ($actualGifHash -ceq $expectedGifHashes[$gifName]) "$archiveName contains stale $gifName bytes."
        }

        Write-Host "[PASS] Release payload contract: $archiveName ($($archive.Entries.Count) entries)"
    }
    finally {
        $archive.Dispose()
    }
}

$tarArchives = @(Get-ChildItem -LiteralPath $DistPath -File -Filter '*.tar.gz')
Assert-True ($tarArchives.Count -eq 4) "Expected four TAR.GZ release artifacts, found $($tarArchives.Count)."
foreach ($tarArchive in $tarArchives) {
    $packageName = $tarArchive.Name.Substring(0, $tarArchive.Name.Length - '.tar.gz'.Length)
    $zipName = "$packageName.zip"
    Assert-True ($expected.Contains($zipName)) "$($tarArchive.Name) has no corresponding ZIP package contract."

    $rawTarEntries = @(& tar -tzf $tarArchive.FullName)
    Assert-True ($LASTEXITCODE -eq 0) "Could not list $($tarArchive.Name)."
    $unsafeEntries = @($rawTarEntries | Where-Object {
        $entry = ([string]$_).Replace('\', '/')
        $entry -match '^(?:/|[A-Za-z]:)' -or @($entry -split '/' | Where-Object { $_ -eq '..' }).Count -gt 0
    })
    Assert-True ($unsafeEntries.Count -eq 0) "$($tarArchive.Name) contains unsafe archive paths: $($unsafeEntries -join ', ')"
    $tarEntries = @($rawTarEntries | ForEach-Object {
        $entry = ([string]$_).Replace('\', '/')
        if ($entry.StartsWith('./', [StringComparison]::Ordinal)) { $entry.Substring(2) } else { $entry }
    })
    foreach ($requiredEntry in $expected[$zipName]) {
        Assert-True ($tarEntries -ccontains $requiredEntry) "$($tarArchive.Name) is missing $requiredEntry"
    }

    $extractRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-release-test-' + [Guid]::NewGuid().ToString('N'))
    $extractRoot = [IO.Path]::GetFullPath($extractRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    Assert-True ($extractRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) "Unsafe release test extraction root: $extractRoot"
    try {
        New-Item -ItemType Directory -Path $extractRoot | Out-Null
        & tar -xzf $tarArchive.FullName -C $extractRoot
        Assert-True ($LASTEXITCODE -eq 0) "Could not extract $($tarArchive.Name)."

        $packageRoot = Join-Path $extractRoot $packageName
        Assert-True (Test-Path -LiteralPath $packageRoot -PathType Container) "$($tarArchive.Name) has the wrong top-level directory."
        $files = @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse -Force)
        $relativeFiles = @($files | ForEach-Object {
            $_.FullName.Substring($packageRoot.Length).TrimStart('\', '/').Replace('\', '/')
        })
        $forbidden = @($relativeFiles | Where-Object {
            $name = ($_ -split '/')[-1]
            $name -in $forbiddenNames -or $_ -match '(^|/)(logs|output)/'
        })
        Assert-True ($forbidden.Count -eq 0) "$($tarArchive.Name) contains runtime/private paths: $($forbidden -join ', ')"

        $manifestFiles = @($files | Where-Object { $_.Name -ceq 'RELEASE-FILES.txt' })
        Assert-True ($manifestFiles.Count -eq 1) "$($tarArchive.Name) has no unique release-owned file manifest."
        $releaseManifest = Get-Content -LiteralPath $manifestFiles[0].FullName -Raw
        $normalizedManifest = ($releaseManifest -replace "`r`n", "`n").Trim()
        Assert-True ($normalizedManifest -ceq $zipReleaseManifests[$packageName]) "$($tarArchive.Name) does not match its corresponding ZIP file manifest."
        Assert-True ($releaseManifest -notmatch '(?im)(?:^|/)(?:config\.json|state\.json|access-state\.json|scheduler-state\.json|\.tautweekly-operation\.lock)$') "$($tarArchive.Name) release manifest owns private runtime files."

        $manifestLines = @($releaseManifest -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-True ($manifestLines.Count -eq ($files.Count - 1)) "$($tarArchive.Name) release manifest does not cover every packaged file except itself."
        $seenManifestPaths = @{}
        foreach ($manifestLine in $manifestLines) {
            Assert-True ($manifestLine -match '^(?<hash>[0-9a-f]{64})\s{2}(?<path>.+)$') "$($tarArchive.Name) has an invalid release manifest line: $manifestLine"
            $relativePath = $Matches['path'].Replace('\', '/')
            Assert-True (@($relativePath -split '/' | Where-Object { $_ -eq '..' }).Count -eq 0) "$($tarArchive.Name) release manifest contains an unsafe path: $relativePath"
            Assert-True (-not $seenManifestPaths.ContainsKey($relativePath.ToLowerInvariant())) "$($tarArchive.Name) release manifest duplicates $relativePath."
            $seenManifestPaths[$relativePath.ToLowerInvariant()] = $true
            $packagedPath = [IO.Path]::GetFullPath((Join-Path $packageRoot $relativePath))
            Assert-True ($packagedPath.StartsWith($packageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) "$($tarArchive.Name) release manifest escapes its package root: $relativePath"
            Assert-True (Test-Path -LiteralPath $packagedPath -PathType Leaf) "$($tarArchive.Name) release manifest references a missing file: $relativePath"
            $actualHash = (Get-FileHash -LiteralPath $packagedPath -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-True ($actualHash -eq $Matches['hash']) "$($tarArchive.Name) release manifest hash failed for $relativePath."
        }

        $metadataFiles = @($files | Where-Object { $_.Name -ceq 'RELEASE-METADATA.txt' })
        Assert-True ($metadataFiles.Count -eq 1) "$($tarArchive.Name) has no unique release metadata file."
        $metadata = Get-Content -LiteralPath $metadataFiles[0].FullName -Raw
        Assert-True ($metadata -match '(?m)^Repository version:\s*(?<version>\S+)\s*$') "$($tarArchive.Name) does not identify its repository version."
        $releaseVersions.Add($Matches['version'])

        $rendererFiles = @($files | Where-Object { $_.Name -ceq 'TautWeekly.ps1' })
        Assert-True ($rendererFiles.Count -eq 1) "$($tarArchive.Name) has no unique production renderer."
        $renderer = Get-Content -LiteralPath $rendererFiles[0].FullName -Raw
        Assert-RendererContract -PackageName $tarArchive.Name -Renderer $renderer

        foreach ($gifName in $expectedGifHashes.Keys) {
            $assetRoot = $assetRoots[$zipName].Substring($packageName.Length + 1)
            $gifPath = Join-Path $packageRoot (Join-Path $assetRoot $gifName)
            Assert-True (Test-Path -LiteralPath $gifPath -PathType Leaf) "$($tarArchive.Name) is missing $assetRoot/$gifName"
            $actualGifHash = (Get-FileHash -LiteralPath $gifPath -Algorithm SHA256).Hash
            Assert-True ($actualGifHash -ceq $expectedGifHashes[$gifName]) "$($tarArchive.Name) contains stale $gifName bytes."
        }

        Write-Host "[PASS] Release payload contract: $($tarArchive.Name) ($($files.Count) files)"
    }
    finally {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Assert-True ($releaseVersions.Count -eq 9) "Expected repository version metadata from all nine packages, found $($releaseVersions.Count)."
Assert-True (@($releaseVersions | Select-Object -Unique).Count -eq 1) 'Release packages do not identify one consistent repository version.'

$checksumPath = Join-Path $DistPath 'SHA256SUMS.txt'
Assert-True (Test-Path -LiteralPath $checksumPath) 'SHA256SUMS.txt is missing.'
$checksumLines = @(Get-Content -LiteralPath $checksumPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$artifacts = @(Get-ChildItem -LiteralPath $DistPath -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' })
Assert-True ($artifacts.Count -eq 9) "Expected nine release artifacts, found $($artifacts.Count)."
Assert-True ($checksumLines.Count -eq $artifacts.Count) 'Checksum manifest does not cover every artifact exactly once.'
foreach ($artifact in $artifacts) {
    $line = @($checksumLines | Where-Object { $_ -match ('\s\s' + [regex]::Escape($artifact.Name) + '$') })
    Assert-True ($line.Count -eq 1) "Checksum entry is missing or duplicated for $($artifact.Name)."
    $expectedHash = ($line[0] -split '\s+', 2)[0].ToUpperInvariant()
    $actualHash = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    Assert-True ($expectedHash -eq $actualHash) "SHA-256 mismatch for $($artifact.Name)."
}

Write-Host 'Release artifact functional contracts and SHA-256 checks passed.' -ForegroundColor Green
