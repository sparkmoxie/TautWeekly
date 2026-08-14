[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$checker = Join-Path $Root 'platforms/windows/Check-Update.ps1'
$lockHelper = Join-Path $Root 'platforms/windows/Operation-Lock.ps1'
$updater = Join-Path $Root 'platforms/windows/Windows-Update.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-update-check-' + [guid]::NewGuid().ToString('N'))
$metadata = Join-Path $testRoot 'RELEASE-METADATA.txt'

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Write-ReleaseMetadata([string]$Path, [string]$Version) {
    [IO.File]::WriteAllText($Path, "Repository version: $Version`n", [Text.UTF8Encoding]::new($false))
}

function Write-ReleaseManifest([string]$PackageRoot) {
    $lines = @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force -File | Where-Object {
            $_.Name -ne 'RELEASE-FILES.txt'
        } | ForEach-Object {
            $relative = $_.FullName.Substring($PackageRoot.Length).TrimStart('\', '/').Replace('\', '/')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$hash  $relative"
        }
    ) | Sort-Object
    [IO.File]::WriteAllLines((Join-Path $PackageRoot 'RELEASE-FILES.txt'), $lines, [Text.UTF8Encoding]::new($false))
}

function New-TestRelease([string]$Version, [string]$Marker) {
    $releaseRoot = Join-Path $testRoot ("release-$Version-" + [Guid]::NewGuid().ToString('N'))
    $archiveSource = Join-Path $releaseRoot 'archive'
    $packageRoot = Join-Path $archiveSource 'TautWeekly-windows'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

    Copy-Item -LiteralPath $checker -Destination (Join-Path $packageRoot 'Check-Update.ps1')
    Copy-Item -LiteralPath $updater -Destination (Join-Path $packageRoot 'Windows-Update.ps1')
    Copy-Item -LiteralPath $lockHelper -Destination (Join-Path $packageRoot 'Operation-Lock.ps1')
    [IO.File]::WriteAllText((Join-Path $packageRoot 'TautWeekly.ps1'), "Set-StrictMode -Version Latest`n# $Marker`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $packageRoot 'SCHEDULE-HELPER.ps1'), "Set-StrictMode -Version Latest`n# fictional update fixture`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $packageRoot 'START-MANAGER.ps1'), "Set-StrictMode -Version Latest`n# fictional update fixture`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $packageRoot 'RESET-MANAGER-ACCESS.ps1'), "Set-StrictMode -Version Latest`n# fictional update fixture`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $packageRoot '00-OPEN-MANAGER.bat'), "@echo off`r`nrem fictional update fixture`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $packageRoot '18-RESET-MANAGER-ACCESS.bat'), "@echo off`r`nrem fictional update fixture`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes((Join-Path $packageRoot 'tautweekly-manager.exe'), [byte[]](0x4d, 0x5a, 0x00, 0x00))
    [IO.File]::WriteAllText((Join-Path $packageRoot 'README.md'), "Test release $Version`n", [Text.UTF8Encoding]::new($false))
    Write-ReleaseMetadata -Path (Join-Path $packageRoot 'RELEASE-METADATA.txt') -Version $Version
    Write-ReleaseManifest -PackageRoot $packageRoot

    $archive = Join-Path $releaseRoot 'TautWeekly-windows.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($archiveSource, $archive)
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksums = Join-Path $releaseRoot 'SHA256SUMS.txt'
    [IO.File]::WriteAllText($checksums, "$hash  TautWeekly-windows.zip`n", [Text.UTF8Encoding]::new($false))
    return [PSCustomObject]@{
        Root = $packageRoot
        Archive = $archive
        Checksums = $checksums
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $updaterSource = Get-Content -LiteralPath $updater -Raw -Encoding UTF8
    Assert-True ($updaterSource -match 'Test-OwnedNewsletterTask') 'Windows updater does not verify scheduled-task ownership.'
    Assert-True ($updaterSource -match 'It was left untouched') 'Windows updater does not fail closed for a same-named unowned task.'
    foreach ($privateName in @('last-run.json', 'scheduler-heartbeat.json', 'service-heartbeat.json', 'config.backup.*.json')) {
        Assert-True ($updaterSource.Contains($privateName)) "Windows updater private-path guard is missing $privateName."
    }
    Write-ReleaseMetadata -Path $metadata -Version '0.5.4'

    $currentOutput = (& $checker -MetadataPath $metadata -LatestVersion 'v0.5.4' | Out-String)
    Assert-True ($currentOutput -match 'This package is up to date\.') 'Windows stable-release checker did not report an equal version as current.'

    $updateOutput = (& $checker -MetadataPath $metadata -LatestVersion '0.5.5' | Out-String)
    Assert-True ($updateOutput -match 'A stable update is available: 0\.5\.4 -> 0\.5\.5') 'Windows stable-release checker did not report the expected update.'
    Assert-True ($updateOutput -match 'No files were downloaded or changed') 'Check-only mode did not state that the installation remains unchanged.'

    Write-ReleaseMetadata -Path $metadata -Version '0.5.6'
    $newerOutput = (& $checker -MetadataPath $metadata -LatestVersion '0.5.5' | Out-String)
    Assert-True ($newerOutput -match "newer than GitHub's latest stable release; no update is offered") 'Windows stable-release checker offered a downgrade for a newer installed package.'

    $installRoot = Join-Path $testRoot 'installed'
    New-Item -ItemType Directory -Path $installRoot, (Join-Path $installRoot 'logs'), (Join-Path $installRoot 'output'), (Join-Path $installRoot 'cache/deleted-items/artwork'), (Join-Path $installRoot 'assets'), (Join-Path $installRoot '.manager-data') | Out-Null
    $taskName = 'TautWeekly updater test ' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText((Join-Path $installRoot 'config.json'), ('{"ScheduledTaskName":"' + $taskName + '","secret":"preserve"}'), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot 'state.json'), '{"state":"preserve"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot 'last-run.json'), '{"delivery":"preserve"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot 'config.backup.20260814.json'), '{"backup":"preserve"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot 'logs/private.log'), 'private log', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot 'output/private.html'), 'private output', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot 'cache/deleted-items/artwork/private.jpg'), 'private cached poster', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot 'assets/custom.gif'), 'custom asset', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot '.manager-data/auth.json'), '{"private":"manager-pairing-state"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot 'TautWeekly.ps1'), "# old engine`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $installRoot 'deprecated-owned.txt'), "remove me`n", [Text.UTF8Encoding]::new($false))
    Write-ReleaseMetadata -Path (Join-Path $installRoot 'RELEASE-METADATA.txt') -Version '0.5.4'
    $ownedNames = @('TautWeekly.ps1', 'deprecated-owned.txt', 'RELEASE-METADATA.txt')
    $oldManifest = foreach ($name in $ownedNames) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $installRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    [IO.File]::WriteAllLines((Join-Path $installRoot 'RELEASE-FILES.txt'), $oldManifest, [Text.UTF8Encoding]::new($false))

    $release056 = New-TestRelease -Version '0.5.6' -Marker 'new engine 0.5.6'
    $windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($null -ne $windowsPowerShell) {
        $externalOutput = (& $windowsPowerShell.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $release056.Root 'Check-Update.ps1') -LatestVersion '0.5.6' | Out-String)
        Assert-True ($LASTEXITCODE -eq 0) 'Windows PowerShell -File launcher path failed.'
        Assert-True ($externalOutput -match 'Installed package: 0\.5\.6' -and $externalOutput -match 'This package is up to date\.') 'Windows PowerShell -File launcher did not resolve release metadata beside the checker.'
    }
    else {
        Write-Warning 'Skipping the Windows PowerShell -File child-process assertion on this non-Windows runner.'
    }
    & $checker -MetadataPath (Join-Path $installRoot 'RELEASE-METADATA.txt') -InstallRoot $installRoot -LatestVersion '0.5.6' -Apply -ArchivePath $release056.Archive -ChecksumsPath $release056.Checksums -NoElevation | Out-Null
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'RELEASE-METADATA.txt') -Raw) -match 'Repository version: 0\.5\.6') 'Verified update did not install the target version.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'TautWeekly.ps1') -Raw) -match 'new engine 0\.5\.6') 'Verified update did not replace a release-owned file.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot 'deprecated-owned.txt'))) 'Verified update did not remove an unchanged deprecated release-owned file.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'config.json') -Raw) -match 'preserve') 'Verified update changed private configuration.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'last-run.json') -Raw) -match 'preserve') 'Verified update changed private delivery history.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'config.backup.20260814.json') -Raw) -match 'preserve') 'Verified update changed a private configuration backup.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'logs/private.log')) 'Verified update removed private logs.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'output/private.html')) 'Verified update removed private output.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'cache/deleted-items/artwork/private.jpg')) 'Verified update removed the private deleted-item cache.'
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'assets/custom.gif')) 'Verified update removed a custom-named asset.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot '.manager-data/auth.json') -Raw) -match 'manager-pairing-state') 'Verified update changed private Manager pairing state.'
    $backups = @(Get-ChildItem -LiteralPath $testRoot -Directory -Filter 'installed.backup-v0.5.4-*')
    Assert-True ($backups.Count -eq 1) 'Verified update did not create one private sibling backup.'
    Assert-True (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'deprecated-owned.txt')) 'Rollback backup did not preserve the previous owned files.'

    $release057 = New-TestRelease -Version '0.5.7' -Marker 'candidate engine 0.5.7'
    $rollbackFailedAsExpected = $false
    try {
        & $checker -MetadataPath (Join-Path $installRoot 'RELEASE-METADATA.txt') -InstallRoot $installRoot -LatestVersion '0.5.7' -Apply -ArchivePath $release057.Archive -ChecksumsPath $release057.Checksums -NoElevation -SimulatePostInstallFailure | Out-Null
    }
    catch {
        $rollbackFailedAsExpected = $_.Exception.Message -match 'previous installation was restored automatically'
    }
    Assert-True $rollbackFailedAsExpected 'Simulated post-install failure did not report automatic rollback.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'RELEASE-METADATA.txt') -Raw) -match 'Repository version: 0\.5\.6') 'Automatic rollback did not restore the previous version.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'TautWeekly.ps1') -Raw) -match 'new engine 0\.5\.6') 'Automatic rollback did not restore the previous engine.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'config.json') -Raw) -match 'preserve') 'Automatic rollback changed private configuration.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'last-run.json') -Raw) -match 'preserve') 'Automatic rollback changed private delivery history.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'config.backup.20260814.json') -Raw) -match 'preserve') 'Automatic rollback changed a private configuration backup.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot '.manager-data/auth.json') -Raw) -match 'manager-pairing-state') 'Automatic rollback changed private Manager pairing state.'

    . $lockHelper
    $heldLock = Enter-TautWeeklyOperationLock -Root $installRoot -Purpose 'test lock holder'
    try {
        $lockRefused = $false
        try {
            & $checker -MetadataPath (Join-Path $installRoot 'RELEASE-METADATA.txt') -InstallRoot $installRoot -LatestVersion '0.5.7' -Apply -ArchivePath $release057.Archive -ChecksumsPath $release057.Checksums -NoElevation | Out-Null
        }
        catch {
            $lockRefused = $_.Exception.Message -match 'Another TautWeekly operation is already running'
        }
        Assert-True $lockRefused 'Windows updater did not refuse a concurrent TautWeekly operation.'
    }
    finally {
        Exit-TautWeeklyOperationLock -Lock $heldLock
    }

    $badChecksums = Join-Path $testRoot 'bad-SHA256SUMS.txt'
    [IO.File]::WriteAllText($badChecksums, (('0' * 64) + '  TautWeekly-windows.zip' + "`n"), [Text.UTF8Encoding]::new($false))
    $checksumRefused = $false
    try {
        & $checker -MetadataPath (Join-Path $installRoot 'RELEASE-METADATA.txt') -InstallRoot $installRoot -LatestVersion '0.5.7' -Apply -ArchivePath $release057.Archive -ChecksumsPath $badChecksums -NoElevation | Out-Null
    }
    catch {
        $checksumRefused = $_.Exception.Message -match 'SHA-256 verification failed'
    }
    Assert-True $checksumRefused 'Windows updater accepted an archive with the wrong SHA-256 checksum.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'RELEASE-METADATA.txt') -Raw) -match 'Repository version: 0\.5\.6') 'Checksum rejection changed the installation.'

    Write-Host '[PASS] Windows stable check, verified apply, operation lock, newsletter/Manager private-state preservation, deprecated-file cleanup, and rollback validated.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
