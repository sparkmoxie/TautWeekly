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

function Find-ByteSequenceOffsets {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][byte[]]$Needle
    )
    if ($Needle.Length -eq 0) { throw 'Byte sequence cannot be empty.' }
    $matches = [Collections.Generic.List[int]]::new()
    for ($offset = 0; $offset -le $Bytes.Length - $Needle.Length; $offset++) {
        $matched = $true
        for ($index = 0; $index -lt $Needle.Length; $index++) {
            if ($Bytes[$offset + $index] -ne $Needle[$index]) { $matched = $false; break }
        }
        if ($matched) { $matches.Add($offset) }
    }
    return $matches.ToArray()
}

function Set-Utf16ResourceString {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$CurrentValue,
        [Parameter(Mandatory = $true)][string]$ReplacementValue
    )
    if ($ReplacementValue.Length -gt $CurrentValue.Length) {
        throw "Replacement resource string is longer than its fixed resource field: $ReplacementValue"
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $needle = [Text.Encoding]::Unicode.GetBytes($CurrentValue + [char]0)
    $replacement = [Text.Encoding]::Unicode.GetBytes($ReplacementValue + [char]0)
    $matches = @(Find-ByteSequenceOffsets -Bytes $bytes -Needle $needle)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one fixed resource string '$CurrentValue' in $Path; found $($matches.Count)."
    }
    $start = $matches[0]
    for ($index = 0; $index -lt $needle.Length; $index++) { $bytes[$start + $index] = 0 }
    [Buffer]::BlockCopy($replacement, 0, $bytes, $start, $replacement.Length)
    [IO.File]::WriteAllBytes($Path, $bytes)
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

function Set-ReleaseVersionTokens {
    param([Parameter(Mandatory = $true)][string]$Destination)

    $token = '__TAUTWEEKLY_RELEASE_VERSION__'
    foreach ($file in Get-ChildItem -LiteralPath $Destination -Recurse -File -Include '*.yaml','*.yml') {
        $text = [IO.File]::ReadAllText($file.FullName)
        if ($text.Contains($token)) {
            $text = $text.Replace($token, $Version)
            [IO.File]::WriteAllText($file.FullName, $text, [Text.UTF8Encoding]::new($false))
        }
    }
    $remaining = Get-ChildItem -LiteralPath $Destination -Recurse -File -Include '*.yaml','*.yml' | Where-Object {
        [IO.File]::ReadAllText($_.FullName).Contains($token)
    }
    if ($remaining) {
        throw "Release package version token was not replaced: $($remaining.FullName -join ', ')"
    }
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
    $managerCommandRoot = Join-Path $managerRoot 'cmd/tautweekly-manager'
    $managerResource = Join-Path $managerCommandRoot 'rsrc_windows_amd64.syso'
    $setupResource = Join-Path $Root 'installer/cmd/tautweekly-setup/rsrc_windows_amd64.syso'
    if (-not (Test-Path -LiteralPath $setupResource -PathType Leaf)) {
        throw "Windows Manager resource source was not found: $setupResource"
    }
    if (Test-Path -LiteralPath $managerResource) {
        throw "Refusing to replace an unexpected Windows Manager resource object: $managerResource"
    }
    $output = Join-Path $Destination 'tautweekly-manager.exe'
    $previousGoOS = $env:GOOS
    $previousGoArch = $env:GOARCH
    $previousCGO = $env:CGO_ENABLED
    try {
        Copy-Item -LiteralPath $setupResource -Destination $managerResource
        Set-Utf16ResourceString -Path $managerResource -CurrentValue 'TautWeekly for Plex Setup' -ReplacementValue 'TautWeekly for Plex'
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
        Remove-Item -LiteralPath $managerResource -Force -ErrorAction SilentlyContinue
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
    $identityNeedle = [Text.Encoding]::Unicode.GetBytes('TautWeekly for Plex' + [char]0)
    $identityMatches = @(Find-ByteSequenceOffsets -Bytes $header -Needle $identityNeedle)
    if ($identityMatches.Count -lt 2) {
        throw "The Windows Manager does not contain both expected TautWeekly for Plex identity resources."
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $fileInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($output)
        if ($fileInfo.FileDescription -ne 'TautWeekly for Plex' -or $fileInfo.ProductName -ne 'TautWeekly for Plex') {
            throw "Windows does not expose the expected TautWeekly for Plex file metadata."
        }
    }
}

function Build-LinuxManagers {
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
    $outputRoot = Join-Path $Destination 'manager'
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    $previousGoOS = $env:GOOS
    $previousGoArch = $env:GOARCH
    $previousCGO = $env:CGO_ENABLED
    try {
        $env:GOOS = 'linux'
        $env:CGO_ENABLED = '0'
        foreach ($architecture in @('amd64', 'arm64')) {
            $env:GOARCH = $architecture
            $output = Join-Path $outputRoot "tautweekly-manager-linux-$architecture"
            Push-Location $managerRoot
            try {
                & $goPath build -trimpath -buildvcs=false -ldflags "-s -w -X main.version=$Version" -o $output ./cmd/tautweekly-manager
                if ($LASTEXITCODE -ne 0) { throw "Go failed to build the Linux $architecture Manager." }
            }
            finally { Pop-Location }
            $header = [IO.File]::ReadAllBytes($output)
            if ($header.Length -lt 4 -or $header[0] -ne 0x7f -or $header[1] -ne 0x45 -or $header[2] -ne 0x4c -or $header[3] -ne 0x46) {
                throw "The Linux $architecture Manager output is not an ELF executable."
            }
        }
    }
    finally {
        if ($null -eq $previousGoOS) { Remove-Item Env:GOOS -ErrorAction SilentlyContinue } else { $env:GOOS = $previousGoOS }
        if ($null -eq $previousGoArch) { Remove-Item Env:GOARCH -ErrorAction SilentlyContinue } else { $env:GOARCH = $previousGoArch }
        if ($null -eq $previousCGO) { Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue } else { $env:CGO_ENABLED = $previousCGO }
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
    [IO.File]::WriteAllText(
        (Join-Path $Destination 'RELEASE-FILES.txt'),
        (($releaseFiles -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Test-ReleaseExecutable {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $normalized = $RelativePath.Replace('\','/')
    return $normalized.EndsWith('.sh', [StringComparison]::OrdinalIgnoreCase) -or
        $normalized -match '(?:^|/)manager/tautweekly-manager-linux-(?:amd64|arm64)$' -or
        $normalized -match '(?:^|/)(?:rc\.d/)?tautweekly$'
}

function Test-UnixTextReleaseFile {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $normalized = $RelativePath.Replace('\','/')
    $name = [IO.Path]::GetFileName($normalized)
    $extension = [IO.Path]::GetExtension($name).ToLowerInvariant()
    return $extension -in @('.sh','.command','.ps1','.psm1','.yml','.yaml','.json','.md','.html','.css','.js','.py','.txt','.xml','.service','.example') -or
        $name -in @('Dockerfile','.dockerignore','LICENSE','tautweekly')
}

function Convert-ToUnixLineEndings {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $normalized = [Collections.Generic.List[byte]]::new($bytes.Length)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -eq 0x0d) {
            if ($index + 1 -lt $bytes.Length -and $bytes[$index + 1] -eq 0x0a) { continue }
            $normalized.Add(0x0a)
            continue
        }
        $normalized.Add($bytes[$index])
    }
    [IO.File]::WriteAllBytes($Path, $normalized.ToArray())
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
            $entry = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip,
                $file.FullName,
                $entryName,
                [IO.Compression.CompressionLevel]::Optimal
            )
            if ($FolderName -ne 'TautWeekly-windows') {
                # ZIP permissions live in the high 16 bits of ExternalAttributes.
                # Set the regular-file type plus a deliberate 0755/0644 mode so a
                # Unix-aware extractor does not inherit Windows staging ACLs.
                $unixMode = if (Test-ReleaseExecutable -RelativePath $relative) { 0x81ed } else { 0x81a4 }
                $entry.ExternalAttributes = [BitConverter]::ToInt32(
                    [byte[]]@(0, 0, ($unixMode -band 0xff), (($unixMode -shr 8) -band 0xff)),
                    0
                )
            }
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
    $isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    if (-not $isWindowsHost) {
        & tar -czf $archive -C $staging $FolderName
        if ($LASTEXITCODE -ne 0) { throw "tar failed while creating $ArchiveName" }
    }
    else {
        # Windows bsdtar derives 0666 from NTFS ACLs, which makes native Linux
        # launchers and generated ELF Manager binaries unusable after extraction.
        # Git for Windows ships GNU tar; build the tar in mode-specific passes so
        # local/CI artifacts preserve the same Unix contract as an Ubuntu build.
        $gitPath = Get-Command git -CommandType Application -ErrorAction Stop |
            Select-Object -First 1 -ExpandProperty Source
        $gitRoot = Split-Path -Parent (Split-Path -Parent $gitPath)
        $tarPath = Join-Path $gitRoot 'usr/bin/tar.exe'
        $cygpathPath = Join-Path $gitRoot 'usr/bin/cygpath.exe'
        if (-not (Test-Path -LiteralPath $tarPath -PathType Leaf)) {
            throw "Git for Windows GNU tar was not found: $tarPath"
        }
        if (-not (Test-Path -LiteralPath $cygpathPath -PathType Leaf)) {
            throw "Git for Windows cygpath was not found: $cygpathPath"
        }

        $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $tempRoot = Join-Path $tempParent ('tautweekly-release-tar-' + [Guid]::NewGuid().ToString('N'))
        $tempRoot = [IO.Path]::GetFullPath($tempRoot)
        if (-not $tempRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe temporary tar root: $tempRoot"
        }
        New-Item -ItemType Directory -Path $tempRoot | Out-Null
        $rawTar = Join-Path $tempRoot 'payload.tar'
        $directoryList = Join-Path $tempRoot 'directories.txt'
        $regularList = Join-Path $tempRoot 'regular-files.txt'
        $executableList = Join-Path $tempRoot 'executable-files.txt'
        $source = Join-Path $staging $FolderName
        try {
            $directories = @($source) + @(Get-ChildItem -LiteralPath $source -Force -Recurse -Directory | ForEach-Object { $_.FullName })
            $directoryEntries = @($directories | ForEach-Object {
                $_.Substring($staging.Length).TrimStart('\','/').Replace('\','/')
            }) | Sort-Object -Unique
            $regularEntries = [Collections.Generic.List[string]]::new()
            $executableEntries = [Collections.Generic.List[string]]::new()
            foreach ($file in (Get-ChildItem -LiteralPath $source -Force -Recurse -File)) {
                $entry = $file.FullName.Substring($staging.Length).TrimStart('\','/').Replace('\','/')
                $relative = $file.FullName.Substring($source.Length).TrimStart('\','/').Replace('\','/')
                if (Test-ReleaseExecutable -RelativePath $relative) { $executableEntries.Add($entry) }
                else { $regularEntries.Add($entry) }
            }
            $utf8NoBom = [Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText($directoryList, (@($directoryEntries) -join "`n") + "`n", $utf8NoBom)
            [IO.File]::WriteAllText($regularList, (@($regularEntries | Sort-Object) -join "`n") + "`n", $utf8NoBom)
            [IO.File]::WriteAllText($executableList, (@($executableEntries | Sort-Object) -join "`n") + "`n", $utf8NoBom)

            $previousPath = $env:PATH
            try {
                $env:PATH = (Split-Path -Parent $tarPath) + [IO.Path]::PathSeparator + $env:PATH
                $rawTarForTar = ([string](& $cygpathPath -u $rawTar)).Trim()
                $stagingForTar = ([string](& $cygpathPath -u $staging)).Trim()
                $directoryListForTar = ([string](& $cygpathPath -u $directoryList)).Trim()
                $regularListForTar = ([string](& $cygpathPath -u $regularList)).Trim()
                $executableListForTar = ([string](& $cygpathPath -u $executableList)).Trim()
                if ($LASTEXITCODE -ne 0) { throw "cygpath failed while preparing $ArchiveName" }
                $common = @('--owner=0', '--group=0', '--numeric-owner', '--no-recursion')
                & $tarPath '--force-local' '-cf' $rawTarForTar @common '--mode=0755' '-C' $stagingForTar '-T' $directoryListForTar
                if ($LASTEXITCODE -ne 0) { throw "GNU tar failed while creating directories for $ArchiveName" }
                if ($regularEntries.Count -gt 0) {
                    & $tarPath '--force-local' '-rf' $rawTarForTar @common '--mode=0644' '-C' $stagingForTar '-T' $regularListForTar
                    if ($LASTEXITCODE -ne 0) { throw "GNU tar failed while adding regular files to $ArchiveName" }
                }
                if ($executableEntries.Count -gt 0) {
                    & $tarPath '--force-local' '-rf' $rawTarForTar @common '--mode=0755' '-C' $stagingForTar '-T' $executableListForTar
                    if ($LASTEXITCODE -ne 0) { throw "GNU tar failed while adding executable files to $ArchiveName" }
                }
            }
            finally { $env:PATH = $previousPath }

            $input = [IO.File]::OpenRead($rawTar)
            $output = [IO.File]::Open($archive, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $gzipStream = [IO.Compression.GZipStream]::new($output, [IO.Compression.CompressionLevel]::Optimal, $true)
            try { $input.CopyTo($gzipStream) }
            finally {
                $gzipStream.Dispose()
                $output.Dispose()
                $input.Dispose()
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot) {
                $resolved = [IO.Path]::GetFullPath($tempRoot)
                if ($resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and
                    (Split-Path -Leaf $resolved).StartsWith('tautweekly-release-tar-', [StringComparison]::Ordinal)) {
                    Remove-Item -LiteralPath $resolved -Recurse -Force
                }
            }
        }
    }
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
    $nasDestination = Copy-Platform -SourceName 'nas-docker' -FolderName 'TautWeekly-nas-docker' -GuidePath 'docs/nas-docker/README.md'
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/shared/package-update.sh') -Destination (Join-Path $nasDestination 'package-update.sh') -Force
    $macDestination = Copy-Platform -SourceName 'mac-docker' -FolderName 'TautWeekly-mac-docker' -GuidePath 'docs/mac/README.md'
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/shared/package-update.sh') -Destination (Join-Path $macDestination 'package-update.sh') -Force
    Build-LinuxManagers -Destination $macDestination

    $linuxDestination = Copy-Platform -SourceName 'linux' -FolderName 'TautWeekly-linux' -GuidePath 'docs/linux/README.md'
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/shared/package-update.sh') -Destination (Join-Path $linuxDestination 'package-update.sh') -Force
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/nas-docker/app') -Destination (Join-Path $linuxDestination 'app') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/linux/preview-home.html') -Destination (Join-Path $linuxDestination 'app/preview-home.html') -Force
    Remove-Item -LiteralPath (Join-Path $linuxDestination 'preview-home.html') -Force
    Build-LinuxManagers -Destination $linuxDestination

    $freeBsdDestination = Copy-Platform -SourceName 'freebsd-podman' -FolderName 'TautWeekly-freebsd-podman' -GuidePath 'docs/freebsd/README.md'
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/shared/package-update.sh') -Destination (Join-Path $freeBsdDestination 'package-update.sh') -Force
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/nas-docker/app') -Destination (Join-Path $freeBsdDestination 'app') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/nas-docker/Dockerfile') -Destination $freeBsdDestination -Force
    Copy-Item -LiteralPath (Join-Path $Root 'platforms/nas-docker/.dockerignore') -Destination $freeBsdDestination -Force

    foreach ($destination in (Get-ChildItem -LiteralPath $staging -Directory)) {
        Set-ReleaseVersionTokens -Destination $destination.FullName
        if ($destination.Name -ne 'TautWeekly-windows') {
            foreach ($file in Get-ChildItem -LiteralPath $destination.FullName -Force -Recurse -File) {
                $relative = $file.FullName.Substring($destination.FullName.Length).TrimStart('\','/').Replace('\','/')
                if (Test-UnixTextReleaseFile -RelativePath $relative) {
                    Convert-ToUnixLineEndings -Path $file.FullName
                }
            }
        }
        Write-ReleaseManifest -Destination $destination.FullName
    }

    # Source checkout mtimes and generated-manifest mtimes vary across runners.
    # Normalize the complete staging tree so identical source produces
    # byte-identical ZIP/TAR.GZ artifacts on repeated builds.
    foreach ($item in @(Get-ChildItem -LiteralPath $staging -Force -Recurse) + @(Get-ChildItem -LiteralPath $staging -Force -Directory)) {
        $item.LastWriteTimeUtc = $sourceTimestamp
    }

    $forbiddenPrivateNames = @(
        'config.json', '.env', 'state.json', 'access-state.json', 'remote-access.json',
        'scheduler-state.json', 'scheduler-heartbeat.json', 'service-heartbeat.json',
        'configuration-status.json', 'last-run.json', 'deleted-item-cache.json',
        '.tautweekly-operation.lock', 'authkey.local'
    )
    $forbidden = Get-ChildItem -LiteralPath $staging -Force -Recurse | Where-Object {
        ($_.PSIsContainer -and $_.Name -in @('logs','output','cache','.manager-data')) -or
        (-not $_.PSIsContainer -and $_.Name -in $forbiddenPrivateNames) -or
        (-not $_.PSIsContainer -and $_.FullName -match '[\\/]tailscale[\\/]state[\\/](?!\.keep$)') -or
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

    $macCompose = Join-Path $dist 'TautWeekly-mac-compose.yaml'
    $macComposeContent = [IO.File]::ReadAllText((Join-Path $Root 'platforms/mac-docker/compose.registry.yaml'))
    $macComposeContent = $macComposeContent.Replace('__TAUTWEEKLY_RELEASE_VERSION__', $Version)
    if ($macComposeContent.Contains('__TAUTWEEKLY_RELEASE_VERSION__')) {
        throw 'The standalone Mac Compose release asset contains an unresolved release-version token.'
    }
    [IO.File]::WriteAllText($macCompose, $macComposeContent, [Text.UTF8Encoding]::new($false))
    (Get-Item -LiteralPath $macCompose).LastWriteTimeUtc = $sourceTimestamp

    $releaseArtifacts = @($archives) + @($macCompose)

    $checksumLines = foreach ($artifact in ($releaseArtifacts | Sort-Object)) {
        $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($artifact))"
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
