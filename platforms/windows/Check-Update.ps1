[CmdletBinding()]
param(
    [string]$LatestVersion = '',
    [string]$MetadataPath = '',
    [string]$InstallRoot = '',
    [string]$ArchivePath = '',
    [string]$ChecksumsPath = '',
    [switch]$PromptForUpdate,
    [switch]$Apply,
    [switch]$NoElevation,
    [switch]$SimulatePostInstallFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repository = 'sparkmoxie/TautWeekly'
$archiveName = 'TautWeekly-windows.zip'
$checksumsName = 'SHA256SUMS.txt'
$release = $null
$currentVersion = ''
if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = $PSScriptRoot }
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
if ([string]::IsNullOrWhiteSpace($MetadataPath)) { $MetadataPath = Join-Path $InstallRoot 'RELEASE-METADATA.txt' }

function Invoke-GitHubReleaseRequest {
    param([Parameter(Mandatory = $true)][string]$Uri)
    $headers = @{
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'TautWeekly-windows-updater'
    }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

function Assert-StableRelease {
    param([Parameter(Mandatory = $true)]$Release)
    $version = ([string]$Release.tag_name).TrimStart('v')
    if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "GitHub did not return a valid stable release version: $version"
    }
    if ([bool]$Release.draft -or [bool]$Release.prerelease) {
        throw "Refusing non-stable GitHub release v$version."
    }
    return $version
}

function Get-ReleaseAssetUrl {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $asset = @($Release.assets | Where-Object { [string]$_.name -ceq $Name })
    if ($asset.Count -ne 1) {
        throw "Stable release v$LatestVersion must contain exactly one $Name asset."
    }
    $uri = [Uri]([string]$asset[0].browser_download_url)
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com') {
        throw "Refusing unexpected release asset URL for ${Name}: $uri"
    }
    return $uri.AbsoluteUri
}

function Copy-OrDownloadFile {
    param(
        [string]$SourcePath,
        [string]$SourceUri,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        Copy-Item -LiteralPath ([IO.Path]::GetFullPath($SourcePath)) -Destination $Destination -Force
    }
    else {
        Invoke-WebRequest -Uri $SourceUri -OutFile $Destination -UseBasicParsing
    }
}

function Assert-ArchiveChecksum {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Checksums
    )
    $matches = @(Get-Content -LiteralPath $Checksums -Encoding UTF8 | Where-Object {
        $_ -match ('^(?<hash>[0-9a-fA-F]{64})\s{2}' + [regex]::Escape($archiveName) + '$')
    })
    if ($matches.Count -ne 1) {
        throw "$checksumsName does not contain exactly one checksum for $archiveName."
    }
    [void]($matches[0] -match '^(?<hash>[0-9a-fA-F]{64})')
    $expected = $Matches['hash'].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "SHA-256 verification failed for $archiveName."
    }
}

function Expand-VerifiedWindowsArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if (-not $name.StartsWith('TautWeekly-windows/', [StringComparison]::Ordinal) -or
                $name.Contains(':')) {
                throw "Windows release contains an unsafe or unexpected path: $name"
            }
            $relative = $name.Substring('TautWeekly-windows/'.Length)
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            $segments = @($relative -split '/')
            if (@($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
                throw "Windows release contains an unsafe path segment: $name"
            }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $name.Replace('/', [IO.Path]::DirectorySeparatorChar)))
            $prefix = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Windows release path escapes the staging directory: $name"
            }
        }
    }
    finally {
        $zip.Dispose()
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
    return Join-Path $Destination 'TautWeekly-windows'
}

function Read-UpdateResult {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Invoke-SafeUpdate {
    $workRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-windows-update-' + [Guid]::NewGuid().ToString('N'))
    $downloadRoot = Join-Path $workRoot 'download'
    $extractRoot = Join-Path $workRoot 'extract'
    $resultPath = Join-Path $workRoot 'result.json'
    try {
        New-Item -ItemType Directory -Path $downloadRoot, $extractRoot -Force | Out-Null
        $localArchive = Join-Path $downloadRoot $archiveName
        $localChecksums = Join-Path $downloadRoot $checksumsName

        if ([string]::IsNullOrWhiteSpace($ArchivePath) -xor [string]::IsNullOrWhiteSpace($ChecksumsPath)) {
            throw 'ArchivePath and ChecksumsPath must be supplied together.'
        }

        if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
            if ($null -eq $script:release) {
                $script:release = Invoke-GitHubReleaseRequest -Uri "https://api.github.com/repos/$repository/releases/tags/v$LatestVersion"
                $resolved = Assert-StableRelease -Release $script:release
                if ($resolved -ne $LatestVersion) {
                    throw "GitHub release tag changed during update discovery: v$resolved"
                }
            }
            $archiveUri = Get-ReleaseAssetUrl -Release $script:release -Name $archiveName
            $checksumsUri = Get-ReleaseAssetUrl -Release $script:release -Name $checksumsName
            Write-Host "Downloading stable Windows release v$LatestVersion..." -ForegroundColor Cyan
            Copy-OrDownloadFile -SourceUri $archiveUri -Destination $localArchive
            Copy-OrDownloadFile -SourceUri $checksumsUri -Destination $localChecksums
        }
        else {
            Copy-OrDownloadFile -SourcePath $ArchivePath -Destination $localArchive
            Copy-OrDownloadFile -SourcePath $ChecksumsPath -Destination $localChecksums
        }

        Assert-ArchiveChecksum -Archive $localArchive -Checksums $localChecksums
        Write-Host 'SHA-256 checksum verified.' -ForegroundColor Green
        $candidateRoot = Expand-VerifiedWindowsArchive -Archive $localArchive -Destination $extractRoot
        $updater = Join-Path $candidateRoot 'Windows-Update.ps1'
        if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
            throw 'The verified Windows archive does not contain Windows-Update.ps1.'
        }

        $updaterArgs = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $updater),
            '-InstallRoot', ('"{0}"' -f $InstallRoot),
            '-CandidateRoot', ('"{0}"' -f $candidateRoot),
            '-TargetVersion', $LatestVersion,
            '-ResultPath', ('"{0}"' -f $resultPath)
        )
        if ($SimulatePostInstallFailure) { $updaterArgs += '-SimulatePostInstallFailure' }

        if ($NoElevation -or $env:OS -ne 'Windows_NT') {
            $directArgs = @{
                InstallRoot = $InstallRoot
                CandidateRoot = $candidateRoot
                TargetVersion = $LatestVersion
                ResultPath = $resultPath
                SimulatePostInstallFailure = [bool]$SimulatePostInstallFailure
            }
            & $updater @directArgs
        }
        else {
            Write-Host 'Windows will request administrator approval to pause and restore Task Scheduler safely.' -ForegroundColor Yellow
            $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $updaterArgs -Wait -PassThru
            if ($process.ExitCode -ne 0) {
                $failedResult = Read-UpdateResult -Path $resultPath
                if ($null -ne $failedResult -and -not [string]::IsNullOrWhiteSpace([string]$failedResult.Message)) {
                    throw [string]$failedResult.Message
                }
                throw "The elevated updater exited with code $($process.ExitCode)."
            }
        }

        $result = Read-UpdateResult -Path $resultPath
        if ($null -eq $result -or [string]$result.Status -ne 'success') {
            throw 'The updater did not report a successful verified installation.'
        }
        Write-Host "Update complete: v$($result.Version)" -ForegroundColor Green
        Write-Host "Private rollback backup: $($result.Backup)"
    }
    finally {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (Test-Path -LiteralPath $MetadataPath -PathType Leaf) {
    $metadata = Get-Content -LiteralPath $MetadataPath -Raw -Encoding UTF8
    if ($metadata -match '(?m)^Repository version:\s*v?(?<version>[0-9]+\.[0-9]+\.[0-9]+)\s*$') {
        $currentVersion = $Matches['version']
    }
}

$previousProtocol = $null
if (-not ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12)) {
    $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
}
try {
    if ([string]::IsNullOrWhiteSpace($LatestVersion)) {
        $release = Invoke-GitHubReleaseRequest -Uri "https://api.github.com/repos/$repository/releases/latest"
        $LatestVersion = Assert-StableRelease -Release $release
    }
    else {
        $LatestVersion = $LatestVersion.TrimStart('v')
    }

    if ($LatestVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "GitHub did not return a valid stable release version: $LatestVersion"
    }

    if ([string]::IsNullOrWhiteSpace($currentVersion)) {
        Write-Output 'Installed package: unknown (release metadata is unavailable)'
        Write-Output "Latest stable release: $LatestVersion"
        Write-Output 'Use an official release ZIP before applying an update.'
        exit 0
    }

    Write-Output "Installed package: $currentVersion"
    Write-Output "Latest stable release: $LatestVersion"
    if ($currentVersion -eq $LatestVersion) {
        Write-Output 'This package is up to date.'
        exit 0
    }
    if ([version]$currentVersion -gt [version]$LatestVersion) {
        Write-Output "This package is newer than GitHub's latest stable release; no update is offered."
        exit 0
    }

    Write-Output "A stable update is available: $currentVersion -> $LatestVersion"
    $releaseUrl = "https://github.com/$repository/releases/tag/v$LatestVersion"
    Write-Output "Release: $releaseUrl"

    if ($Apply) {
        Invoke-SafeUpdate
        exit 0
    }
    if (-not $PromptForUpdate) {
        Write-Output 'No files were downloaded or changed. Run the BAT launcher to choose whether to apply it.'
        exit 0
    }

    Write-Host ''
    Write-Host '[U] Apply this stable update safely' -ForegroundColor Cyan
    Write-Host '[O] Open the stable release page'
    Write-Host '[Enter] Exit without changing anything'
    $choice = (Read-Host 'Choose an action').Trim()
    if ($choice -ieq 'U') {
        Invoke-SafeUpdate
    }
    elseif ($choice -ieq 'O') {
        Start-Process $releaseUrl
    }
    else {
        Write-Host 'No update was applied.'
    }
}
finally {
    if ($null -ne $previousProtocol) {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
    }
}
