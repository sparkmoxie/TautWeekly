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
    $Version = if ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME -replace '^v','' } else { 'local' }
}
$Root = [IO.Path]::GetFullPath($Root)

$sourceDateEpoch = 0L
if (-not [string]::IsNullOrWhiteSpace([string]$env:SOURCE_DATE_EPOCH)) {
    [void][int64]::TryParse([string]$env:SOURCE_DATE_EPOCH, [ref]$sourceDateEpoch)
}
if ($sourceDateEpoch -le 0) {
    $gitEpoch = & git -C $Root log -1 --format=%ct 2>$null
    if ($LASTEXITCODE -eq 0) { [void][int64]::TryParse(([string]$gitEpoch).Trim(), [ref]$sourceDateEpoch) }
}
if ($sourceDateEpoch -le 0) { $sourceDateEpoch = 315532800L }
$sourceTimestamp = [DateTimeOffset]::FromUnixTimeSeconds($sourceDateEpoch).UtcDateTime
# ZIP timestamps cannot represent dates before 1980.
if ($sourceTimestamp -lt [DateTime]'1980-01-01T00:00:00Z') {
    $sourceTimestamp = [DateTime]'1980-01-01T00:00:00Z'
}

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

function Build-WindowsManager {
    param([Parameter(Mandatory = $true)][string]$Destination)

    $goPath = if (-not [string]::IsNullOrWhiteSpace([string]$env:TAUTWEEKLY_GO)) {
        [IO.Path]::GetFullPath([string]$env:TAUTWEEKLY_GO)
    }
    else {
        Get-Command go -CommandType Application -ErrorAction Stop |
            Select-Object -First 1 -ExpandProperty Source
    }
    if (-not (Test-Path -LiteralPath $goPath -PathType Leaf)) {
        throw "Go executable was not found: $goPath"
    }
    $managerRoot = Join-Path $Root 'manager'
    $output = Join-Path $Destination 'tautweekly-manager.exe'
    $previousGoOS = $env:GOOS
    $previousGoArch = $env:GOARCH
    $previousCGO = $env:CGO_ENABLED
    try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        Push-Location $managerRoot
        try {
            & $goPath build -trimpath -buildvcs=false -ldflags "-s -w -X main.version=$Version" -o $output ./cmd/tautweekly-manager
            if ($LASTEXITCODE -ne 0) { throw 'Go failed to build the Windows Manager.' }
        }
        finally { Pop-Location }
    }
    finally {
        if ($null -eq $previousGoOS) { Remove-Item Env:GOOS -ErrorAction SilentlyContinue } else { $env:GOOS = $previousGoOS }
        if ($null -eq $previousGoArch) { Remove-Item Env:GOARCH -ErrorAction SilentlyContinue } else { $env:GOARCH = $previousGoArch }
        if ($null -eq $previousCGO) { Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue } else { $env:CGO_ENABLED = $previousCGO }
    }

    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw 'The Windows Manager build did not produce tautweekly-manager.exe.'
    }
    $header = [IO.File]::ReadAllBytes($output)
    if ($header.Length -lt 2 -or $header[0] -ne 0x4d -or $header[1] -ne 0x5a) {
        throw 'The Windows Manager output is not a Windows PE executable.'
    }
}

function Build-WindowsInstaller {
    param([Parameter(Mandatory = $true)][string]$WindowsArchive)

    $goPath = if (-not [string]::IsNullOrWhiteSpace([string]$env:TAUTWEEKLY_GO)) {
        [IO.Path]::GetFullPath([string]$env:TAUTWEEKLY_GO)
    }
    else {
        Get-Command go -CommandType Application -ErrorAction Stop |
            Select-Object -First 1 -ExpandProperty Source
    }
    if (-not (Test-Path -LiteralPath $goPath -PathType Leaf)) {
        throw "Go executable was not found: $goPath"
    }

    $installerRoot = Join-Path $Root 'installer'
    $commandRoot = Join-Path $installerRoot 'cmd/tautweekly-setup'
    $payloadRoot = Join-Path $commandRoot 'payload'
    $iconSource = Join-Path $installerRoot 'assets/tautweekly.ico'
    $resourceObject = Join-Path $commandRoot 'rsrc_windows_amd64.syso'
    foreach ($required in @($iconSource, $resourceObject)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Windows installer build input was not found: $required"
        }
    }
    New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
    $payloadArchive = Join-Path $payloadRoot 'TautWeekly-windows.zip'
    $payloadHash = Join-Path $payloadRoot 'TautWeekly-windows.zip.sha256'
    $payloadIcon = Join-Path $payloadRoot 'tautweekly.ico'
    Copy-Item -LiteralPath $WindowsArchive -Destination $payloadArchive -Force
    Copy-Item -LiteralPath $iconSource -Destination $payloadIcon -Force
    $hash = (Get-FileHash -LiteralPath $WindowsArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($payloadHash, $hash, [Text.Encoding]::ASCII)

    $output = Join-Path $dist 'TautWeekly-Setup.exe'
    $previousGoOS = $env:GOOS
    $previousGoArch = $env:GOARCH
    $previousCGO = $env:CGO_ENABLED
    try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        Push-Location $installerRoot
        try {
            & $goPath build -trimpath -buildvcs=false -ldflags "-s -w -H windowsgui -X main.version=$Version" -o $output ./cmd/tautweekly-setup
            if ($LASTEXITCODE -ne 0) { throw 'Go failed to build the Windows installer.' }
        }
        finally { Pop-Location }
    }
    finally {
        if ($null -eq $previousGoOS) { Remove-Item Env:GOOS -ErrorAction SilentlyContinue } else { $env:GOOS = $previousGoOS }
        if ($null -eq $previousGoArch) { Remove-Item Env:GOARCH -ErrorAction SilentlyContinue } else { $env:GOARCH = $previousGoArch }
        if ($null -eq $previousCGO) { Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue } else { $env:CGO_ENABLED = $previousCGO }
    }

    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw 'The Windows installer build did not produce TautWeekly-Setup.exe.'
    }
    $header = [IO.File]::ReadAllBytes($output)
    if ($header.Length -lt 2 -or $header[0] -ne 0x4d -or $header[1] -ne 0x5a) {
        throw 'The Windows installer output is not a Windows PE executable.'
    }
    return $output
}

function Build-WindowsUninstaller {
    param([Parameter(Mandatory = $true)][string]$Destination)

    $goPath = if (-not [string]::IsNullOrWhiteSpace([string]$env:TAUTWEEKLY_GO)) {
        [IO.Path]::GetFullPath([string]$env:TAUTWEEKLY_GO)
    }
    else {
        Get-Command go -CommandType Application -ErrorAction Stop |
            Select-Object -First 1 -ExpandProperty Source
    }
    $installerRoot = Join-Path $Root 'installer'
    $output = Join-Path $Destination 'TautWeekly-Uninstall.exe'
    $previousGoOS = $env:GOOS
    $previousGoArch = $env:GOARCH
    $previousCGO = $env:CGO_ENABLED
    try {
        $env:GOOS = 'windows'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        Push-Location $installerRoot
        try {
            & $goPath build -tags uninstaller -trimpath -buildvcs=false -ldflags "-s -w -H windowsgui -X main.version=$Version" -o $output ./cmd/tautweekly-setup
            if ($LASTEXITCODE -ne 0) { throw 'Go failed to build the Windows uninstaller.' }
        }
        finally { Pop-Location }
    }
    finally {
        if ($null -eq $previousGoOS) { Remove-Item Env:GOOS -ErrorAction SilentlyContinue } else { $env:GOOS = $previousGoOS }
        if ($null -eq $previousGoArch) { Remove-Item Env:GOARCH -ErrorAction SilentlyContinue } else { $env:GOARCH = $previousGoArch }
        if ($null -eq $previousCGO) { Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue } else { $env:CGO_ENABLED = $previousCGO }
    }
    $header = [IO.File]::ReadAllBytes($output)
    if ($header.Length -lt 2 -or $header[0] -ne 0x4d -or $header[1] -ne 0x5a) {
        throw 'The Windows uninstaller output is not a Windows PE executable.'
    }
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
    # gzip bytes 4-7 encode the compressor's wall-clock timestamp. It is not
    # covered by the compressed payload CRC, so normalize it to the standard
    # reproducible-build value of zero after tar succeeds.
    $gzip = [IO.File]::Open($archive, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if ($gzip.Length -lt 10) { throw "Invalid gzip output for $ArchiveName" }
        [void]$gzip.Seek(4, [IO.SeekOrigin]::Begin)
        $gzip.Write((New-Object byte[] 4), 0, 4)
        $gzip.Flush()
    }
    finally { $gzip.Dispose() }
    return $archive
}

try {
    $windowsDestination = Copy-Platform -SourceName 'windows' -FolderName 'TautWeekly-windows' -GuidePath 'docs/windows/README.md'
    Build-WindowsManager -Destination $windowsDestination
    Build-WindowsUninstaller -Destination $windowsDestination
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

    # Source checkout mtimes and generated-manifest mtimes vary across runners.
    # Normalize the complete staging tree so identical source produces
    # byte-identical ZIP/TAR.GZ artifacts on repeated builds.
    foreach ($item in @(Get-ChildItem -LiteralPath $staging -Force -Recurse) + @(Get-ChildItem -LiteralPath $staging -Force -Directory)) {
        $item.LastWriteTimeUtc = $sourceTimestamp
    }

    $forbiddenPrivateNames = @(
        'config.json', '.env', 'state.json', 'access-state.json',
        'scheduler-state.json', 'scheduler-heartbeat.json', 'service-heartbeat.json',
        'configuration-status.json', 'last-run.json', 'deleted-item-cache.json',
        '.tautweekly-operation.lock'
    )
    $forbidden = Get-ChildItem -LiteralPath $staging -Force -Recurse | Where-Object {
        ($_.PSIsContainer -and $_.Name -in @('logs','output','cache','.manager-data')) -or
        (-not $_.PSIsContainer -and $_.Name -in $forbiddenPrivateNames) -or
        (-not $_.PSIsContainer -and $_.Name -like 'config.backup.*.json') -or
        (-not $_.PSIsContainer -and ($_.Name -like '*.log' -or $_.Name -like '*.log.*'))
    }
    if ($forbidden) {
        throw "Forbidden runtime material entered release staging: $($forbidden.FullName -join ', ')"
    }

    $windowsArchive = New-Zip -FolderName 'TautWeekly-windows' -ArchiveName 'TautWeekly-windows.zip'
    $installer = Build-WindowsInstaller -WindowsArchive $windowsArchive
    $archives = @(
        $windowsArchive
        $installer
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
