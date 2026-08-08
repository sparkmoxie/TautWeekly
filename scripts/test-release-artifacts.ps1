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

$forbiddenNames = @(
    'config.json', '.env', 'state.json', 'access-state.json',
    'scheduler-state.json', 'scheduler-heartbeat.json', 'service-heartbeat.json'
)

foreach ($archiveName in $expected.Keys) {
    $archivePath = Join-Path $DistPath $archiveName
    Assert-True (Test-Path -LiteralPath $archivePath) "Missing release artifact: $archiveName"
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
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

        $rendererEntry = @($archive.Entries | Where-Object { $_.FullName -match '/(?:app/)?TautWeekly\.ps1$' } | Select-Object -First 1)
        Assert-True ($rendererEntry.Count -eq 1) "$archiveName has no production renderer."
        $reader = New-Object IO.StreamReader($rendererEntry[0].Open())
        try { $renderer = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
        Assert-True ($renderer.Contains('Get-OptionalStringProperty -InputObject $Row -Name "section_id"')) "$archiveName lacks the executable library predicate fix."
        Assert-True ($renderer.Contains('$params.section_id = $sectionId')) "$archiveName lacks server-side selected-library scoping."
        Assert-True ($renderer.Contains('Smtp-Transport.ps1')) "$archiveName does not load the explicit SMTP authentication transport."
        Assert-True ($renderer.Contains('Send-TautWeeklySmtpMessage')) "$archiveName does not route mail through the explicit SMTP transport."
        Assert-True ($renderer.Contains('function Get-StatsTvShowRowsHtml')) "$archiveName lacks grouped TV-show personal statistics."
        Assert-True ($renderer.Contains('function Get-BingeChampionTitleBreakdown')) "$archiveName lacks the media-specific Binge Champion title breakdown."
        Assert-True ($renderer.Contains('$bingeTimeLine = "$([string]$bingeDisplay.TotalTimeText) watched"')) "$archiveName has stale Binge Champion duration copy."
        Assert-True (-not $renderer.Contains('$bingeHeadline')) "$archiveName retains the retired one-line Binge Champion metric."
        Assert-True ($renderer.Contains('$heroLabel = if ($trendingHeroMode) { "TRENDING THIS WEEK" } else { "HOT NEW RELEASE" }')) "$archiveName lacks the movie-empty Trending hero fallback."

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

$checksumPath = Join-Path $DistPath 'SHA256SUMS.txt'
Assert-True (Test-Path -LiteralPath $checksumPath) 'SHA256SUMS.txt is missing.'
$checksumLines = @(Get-Content -LiteralPath $checksumPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$artifacts = @(Get-ChildItem -LiteralPath $DistPath -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' })
Assert-True ($checksumLines.Count -eq $artifacts.Count) 'Checksum manifest does not cover every artifact exactly once.'
foreach ($artifact in $artifacts) {
    $line = @($checksumLines | Where-Object { $_ -match ('\s\s' + [regex]::Escape($artifact.Name) + '$') })
    Assert-True ($line.Count -eq 1) "Checksum entry is missing or duplicated for $($artifact.Name)."
    $expectedHash = ($line[0] -split '\s+', 2)[0].ToUpperInvariant()
    $actualHash = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    Assert-True ($expectedHash -eq $actualHash) "SHA-256 mismatch for $($artifact.Name)."
}

Write-Host 'Release artifact functional contracts and SHA-256 checks passed.' -ForegroundColor Green
