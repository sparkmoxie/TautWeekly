[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = if ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME -replace '^v','' } else { 'dev' }
}
$Root = [IO.Path]::GetFullPath($Root)

if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]*$') {
    throw "Version contains unsupported characters: $Version"
}

$dist = Join-Path $Root 'dist'
$staging = Join-Path $Root 'release-staging'
foreach ($path in @($dist,$staging)) {
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean a path outside the repository: $full"
    }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
    New-Item -ItemType Directory -Path $full | Out-Null
}

function Copy-Platform {
    param(
        [string]$SourceName,
        [string]$FolderName,
        [string]$GuidePath
    )
    $source = Join-Path (Join-Path $Root 'platforms') $SourceName
    $versionLine = [IO.File]::ReadLines((Join-Path $source 'VERSION.txt')) | Select-Object -First 1
    if ($versionLine -notmatch '\bv(?<baseline>[0-9]+(?:\.[0-9]+)+)\b') {
        throw "Unable to derive the $SourceName source baseline from VERSION.txt: $versionLine"
    }
    $baseline = $Matches['baseline']
    $destination = Join-Path $staging $FolderName
    New-Item -ItemType Directory -Path $destination | Out-Null
    Get-ChildItem -LiteralPath $source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $Root $GuidePath) -Destination (Join-Path $destination 'README.md') -Force
    Copy-Item -LiteralPath (Join-Path $Root 'LICENSE') -Destination $destination -Force
    Copy-Item -LiteralPath (Join-Path $Root 'THIRD_PARTY_NOTICES.md') -Destination $destination -Force
    $metadata = @(
        'TautWeekly for Plex public release'
        "Repository version: $Version"
        "Platform source baseline: $Baseline"
        'Source: https://github.com/sparkmoxie/TautWeekly'
        'Credentials and runtime state are intentionally excluded.'
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $destination 'RELEASE-METADATA.txt'), $metadata + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

    return $destination
}

function Write-ReleaseManifest {
    param([Parameter(Mandatory = $true)][string]$Destination)
    $releaseFiles = @(
        Get-ChildItem -LiteralPath $Destination -Force -Recurse -File | Where-Object {
            $_.Name -ne 'RELEASE-FILES.txt'
        } | ForEach-Object {
            $relative = $_.FullName.Substring($Destination.Length).TrimStart('\','/').Replace('\','/')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$hash  $relative"
        }
    ) | Sort-Object
    [IO.File]::WriteAllLines((Join-Path $Destination 'RELEASE-FILES.txt'), $releaseFiles, [Text.UTF8Encoding]::new($false))
}

function New-Zip {
    param([string]$FolderName, [string]$ArchiveName)
    $archive = Join-Path $dist $ArchiveName
    $source = Join-Path $staging $FolderName
    $expected = @(
        Get-ChildItem -LiteralPath $source -Force -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($source.Length).TrimStart('\','/').Replace('\','/')
            "$FolderName/$relative"
        }
    ) | Sort-Object -Unique

    $stream = [IO.File]::Open($archive, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($file in (Get-ChildItem -LiteralPath $source -Force -Recurse -File)) {
            $relative = $file.FullName.Substring($source.Length).TrimStart('\','/').Replace('\','/')
            $entryName = "$FolderName/$relative"
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip,
                $file.FullName,
                $entryName,
                [IO.Compression.CompressionLevel]::Optimal
            )
        }
    }
    finally {
        $zip.Dispose()
        $stream.Dispose()
    }

    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $actual = @(
            $zip.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) } |
                ForEach-Object { $_.FullName.Replace('\','/') }
        ) | Sort-Object -Unique
    }
    finally {
        $zip.Dispose()
    }
    $difference = @(Compare-Object -ReferenceObject $expected -DifferenceObject $actual)
    if ($difference.Count -gt 0) {
        throw "ZIP payload differs from release staging for ${ArchiveName}: $($difference.InputObject -join ', ')"
    }
    return $archive
}

function New-TarGz {
    param([string]$FolderName, [string]$ArchiveName)
    $archive = Join-Path $dist $ArchiveName
    & tar -czf $archive -C $staging $FolderName
    if ($LASTEXITCODE -ne 0) { throw "tar failed while creating $ArchiveName" }
    return $archive
}

try {
    [void](Copy-Platform -SourceName 'windows' -FolderName 'TautWeekly-windows' -GuidePath 'docs/windows/README.md')
    [void](Copy-Platform -SourceName 'nas-docker' -FolderName 'TautWeekly-nas-docker' -GuidePath 'docs/nas-docker/README.md')
    [void](Copy-Platform -SourceName 'mac-docker' -FolderName 'TautWeekly-mac-docker' -GuidePath 'docs/mac/README.md')

    $linuxDestination = Copy-Platform -SourceName 'linux' -FolderName 'TautWeekly-linux' -GuidePath 'docs/linux/README.md'
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/nas-docker/app') -Destination (Join-Path $linuxDestination 'app') -Recurse -Force

    $freeBsdDestination = Copy-Platform -SourceName 'freebsd-podman' -FolderName 'TautWeekly-freebsd-podman' -GuidePath 'docs/freebsd/README.md'
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/nas-docker/app') -Destination (Join-Path $freeBsdDestination 'app') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/nas-docker/Dockerfile') -Destination $freeBsdDestination -Force
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/nas-docker/.dockerignore') -Destination $freeBsdDestination -Force

    foreach ($destination in (Get-ChildItem -LiteralPath $staging -Directory)) {
        Write-ReleaseManifest -Destination $destination.FullName
    }

    $forbidden = Get-ChildItem -LiteralPath $staging -Force -Recurse | Where-Object {
        ($_.PSIsContainer -and $_.Name -in @('logs','output')) -or
        (-not $_.PSIsContainer -and $_.Name -in @('config.json','.env','state.json','access-state.json','scheduler-state.json')) -or
        (-not $_.PSIsContainer -and $_.Extension -eq '.log')
    }
    if ($forbidden) {
        throw "Forbidden runtime material entered release staging: $($forbidden.FullName -join ', ')"
    }

    $archives = @(
        (New-Zip -FolderName 'TautWeekly-windows' -ArchiveName 'TautWeekly-windows.zip')
        (New-Zip -FolderName 'TautWeekly-nas-docker' -ArchiveName 'TautWeekly-nas-docker.zip')
        (New-TarGz -FolderName 'TautWeekly-nas-docker' -ArchiveName 'TautWeekly-nas-docker.tar.gz')
        (New-Zip -FolderName 'TautWeekly-mac-docker' -ArchiveName 'TautWeekly-mac-docker.zip')
        (New-TarGz -FolderName 'TautWeekly-mac-docker' -ArchiveName 'TautWeekly-mac-docker.tar.gz')
        (New-Zip -FolderName 'TautWeekly-linux' -ArchiveName 'TautWeekly-linux.zip')
        (New-TarGz -FolderName 'TautWeekly-linux' -ArchiveName 'TautWeekly-linux.tar.gz')
        (New-Zip -FolderName 'TautWeekly-freebsd-podman' -ArchiveName 'TautWeekly-freebsd-podman.zip')
        (New-TarGz -FolderName 'TautWeekly-freebsd-podman' -ArchiveName 'TautWeekly-freebsd-podman.tar.gz')
    )

    $checksumLines = foreach ($archive in ($archives | Sort-Object)) {
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($archive))"
    }
    [IO.File]::WriteAllLines((Join-Path $dist 'SHA256SUMS.txt'), $checksumLines, [Text.UTF8Encoding]::new($false))

    Write-Host "Built TautWeekly for Plex $Version release artifacts:"
    Get-ChildItem -LiteralPath $dist -File | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0} ({1:N0} bytes)" -f $_.Name,$_.Length)
    }
}
finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
