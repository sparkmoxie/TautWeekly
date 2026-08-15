[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot,

    [Parameter(Mandatory = $true)]
    [string]$CandidateRoot,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Za-z][0-9A-Za-z._-]*$')]
    [string]$TargetVersion,

    [string]$ResultPath = '',

    [string]$ManagerDataRoot = '',

    [switch]$SimulatePostInstallFailure,

    [switch]$InstallerTestMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$CandidateRoot = [IO.Path]::GetFullPath($CandidateRoot)
$lockHelper = Join-Path $PSScriptRoot 'Operation-Lock.ps1'
if (-not (Test-Path -LiteralPath $lockHelper -PathType Leaf)) {
    throw "Operation lock helper is missing: $lockHelper"
}
. $lockHelper

$script:Result = [ordered]@{
    Status = 'failed'
    Version = $TargetVersion
    Backup = ''
    Message = ''
}

function Write-UpdateResult {
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
    $resolvedResultPath = [IO.Path]::GetFullPath($ResultPath)
    $resultParent = Split-Path -Parent $resolvedResultPath
    if (-not (Test-Path -LiteralPath $resultParent -PathType Container)) {
        New-Item -ItemType Directory -Path $resultParent -Force | Out-Null
    }
    $json = $script:Result | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($resolvedResultPath, $json, [Text.UTF8Encoding]::new($false))
}

function Get-SafeRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains(':')) {
        throw "Unsafe release path: $RelativePath"
    }
    $segments = @($RelativePath.Replace('\', '/') -split '/')
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw "Release path contains an unsafe segment: $RelativePath"
    }
    $normalized = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path $Root $normalized))
    $prefix = $Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release path escapes the installation directory: $RelativePath"
    }
    return $full
}

function Assert-PackageOwnedPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $normalized = $RelativePath.Replace('\', '/').TrimStart('/')
    $segments = @($normalized -split '/')
    $leaf = $segments[-1]
    $privateNames = @(
        'config.json', '.env', 'state.json', 'access-state.json',
        'scheduler-state.json', 'scheduler-heartbeat.json', 'service-heartbeat.json',
        'configuration-status.json', 'last-run.json', 'deleted-item-cache.json',
        '.tautweekly-operation.lock'
    )
    if ($leaf -in $privateNames -or $leaf -like 'config.backup.*.json' -or
        $leaf -like '*.log' -or $leaf -like '*.log.*' -or
        $segments -contains 'logs' -or $segments -contains 'output' -or
        $segments -contains 'cache' -or $segments -contains '.manager-data') {
        throw "Release manifest attempts to own private runtime material: $RelativePath"
    }
}

function Read-ReleaseManifest {
    param([Parameter(Mandatory = $true)][string]$Root)

    $manifestPath = Join-Path $Root 'RELEASE-FILES.txt'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Release file manifest is missing: $manifestPath"
    }

    $entries = [ordered]@{}
    foreach ($line in (Get-Content -LiteralPath $manifestPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64})\s{2}(?<path>.+)$') {
            throw "Invalid release file manifest line: $line"
        }
        $relative = $Matches['path'].Replace('\', '/').Trim()
        Assert-PackageOwnedPath -RelativePath $relative
        [void](Get-SafeRelativePath -Root $Root -RelativePath $relative)
        $key = $relative.ToLowerInvariant()
        if ($entries.Contains($key)) {
            throw "Duplicate release manifest path: $relative"
        }
        $entries[$key] = [PSCustomObject]@{
            RelativePath = $relative
            Hash = $Matches['hash'].ToLowerInvariant()
        }
    }
    if ($entries.Count -eq 0) { throw 'Release file manifest is empty.' }
    return $entries
}

function Get-RepositoryVersion {
    param([Parameter(Mandatory = $true)][string]$Root)
    $metadataPath = Join-Path $Root 'RELEASE-METADATA.txt'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return '' }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8
    if ($metadata -match '(?m)^Repository version:\s*v?(?<version>[0-9A-Za-z][0-9A-Za-z._-]*)\s*$') {
        return $Matches['version']
    }
    return ''
}

function Assert-ManifestFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Manifest
    )

    foreach ($entry in $Manifest.Values) {
        $path = Get-SafeRelativePath -Root $Root -RelativePath $entry.RelativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Release file is missing: $($entry.RelativePath)"
        }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $entry.Hash) {
            throw "Release file hash mismatch: $($entry.RelativePath)"
        }
    }
}

function Assert-PowerShellSyntax {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Manifest
    )
    foreach ($entry in ($Manifest.Values | Where-Object { $_.RelativePath -match '(?i)\.ps1$' })) {
        $scriptFile = Get-Item -LiteralPath (Get-SafeRelativePath -Root $Root -RelativePath $entry.RelativePath)
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) {
            throw "PowerShell syntax validation failed for $($scriptFile.Name): $($errors[0].Message)"
        }
    }
}

function Copy-DirectorySnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in (Get-ChildItem -LiteralPath $Source -Force -Recurse)) {
        $relative = $item.FullName.Substring($Source.Length).TrimStart('\', '/')
        if ($relative -eq '.tautweekly-operation.lock') { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to update an installation containing a reparse point: $relative"
        }
        $target = Get-SafeRelativePath -Root $Destination -RelativePath $relative
        if ($item.PSIsContainer) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
        else {
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

function Get-ExpectedTaskArguments {
    param([string]$EnginePath, [string]$ResultPath)
    return ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode SendAll -ResultPath "{1}" -ConfirmSendAll' -f $EnginePath, $ResultPath)
}

function Test-OwnedNewsletterTask {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { return $false }
    $taskAction = $actions[0]
    $enginePath = Join-Path $Root 'TautWeekly.ps1'
    $resultPath = Join-Path $Root 'last-run.json'
    $expectedArguments = Get-ExpectedTaskArguments -EnginePath $enginePath -ResultPath $resultPath
    if ([IO.Path]::GetFileName([string]$taskAction.Execute) -ine 'powershell.exe') { return $false }
    if ([string]$taskAction.Arguments -ine $expectedArguments) { return $false }
    try {
        $workingDirectory = [IO.Path]::GetFullPath([string]$taskAction.WorkingDirectory).TrimEnd('\')
        $expectedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        if ($workingDirectory -ine $expectedRoot) { return $false }
    }
    catch { return $false }
    return [string]$Task.Principal.UserId -ieq 'SYSTEM'
}

function Get-ScheduledNewsletterTask {
    if ($null -eq (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $null }
    $configPath = Join-Path $InstallRoot 'config.json'
    $taskName = 'TautWeekly for Plex Newsletter'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $config.PSObject.Properties['ScheduledTaskName'] -and
                -not [string]::IsNullOrWhiteSpace([string]$config.ScheduledTaskName)) {
                $taskName = [string]$config.ScheduledTaskName
            }
        }
        catch { throw "Cannot read config.json while checking the scheduled task: $($_.Exception.Message)" }
    }
    $tasks = @(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
    if ($tasks.Count -gt 1) {
        throw "More than one scheduled task is named '$taskName'; resolve the duplicate before updating."
    }
    if ($tasks.Count -eq 1) {
        if (-not (Test-OwnedNewsletterTask -Task $tasks[0] -Root $InstallRoot)) {
            throw "A scheduled task named '$taskName' exists but is not owned by this TautWeekly installation. It was left untouched."
        }
        return $tasks[0]
    }
    return $null
}

function Set-NewsletterTaskEnabled {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )
    if ($Enabled) {
        Enable-ScheduledTask -InputObject $Task | Out-Null
    }
    else {
        Disable-ScheduledTask -InputObject $Task | Out-Null
    }
}

function Get-InstalledManagerProcesses {
    $managerPath = Join-Path $InstallRoot 'tautweekly-manager.exe'
    if (-not (Test-Path -LiteralPath $managerPath -PathType Leaf)) { return @() }
    $expected = [IO.Path]::GetFullPath($managerPath)
    return @(Get-Process -Name 'tautweekly-manager' -ErrorAction SilentlyContinue | Where-Object {
        try { [IO.Path]::GetFullPath([string]$_.Path) -ieq $expected }
        catch { $false }
    })
}

function Stop-InstalledManager {
    $managerProcesses = @(Get-InstalledManagerProcesses)
    if ($managerProcesses.Count -eq 0) { return $false }
    $managerPath = Join-Path $InstallRoot 'tautweekly-manager.exe'
    try {
        & $managerPath shutdown --listen=127.0.0.1:8788 "--tautweekly-root=$InstallRoot" 2>$null
    }
    catch { }
    $deadline = (Get-Date).AddSeconds(10)
    foreach ($managerProcess in $managerProcesses) {
        $remaining = [Math]::Max(0, [int]($deadline - (Get-Date)).TotalMilliseconds)
        if (-not $managerProcess.HasExited -and $remaining -gt 0) {
            [void]$managerProcess.WaitForExit($remaining)
        }
    }
    $remainingProcesses = @(Get-InstalledManagerProcesses)
    foreach ($managerProcess in $remainingProcesses) {
        Stop-Process -Id $managerProcess.Id -Force -ErrorAction Stop
    }
    foreach ($managerProcess in $remainingProcesses) {
        if (-not $managerProcess.WaitForExit(10000)) {
            throw 'The exact packaged Manager process did not stop for the update.'
        }
    }
    return $true
}

function Start-InstalledManager {
    $managerPath = Join-Path $InstallRoot 'tautweekly-manager.exe'
    if (-not (Test-Path -LiteralPath $managerPath -PathType Leaf)) {
        throw 'The packaged Manager executable is unavailable after the update.'
    }
    $dataRoot = if ([string]::IsNullOrWhiteSpace($ManagerDataRoot)) { Join-Path $InstallRoot '.manager-data' } else { [IO.Path]::GetFullPath($ManagerDataRoot) }
    if ([string]::IsNullOrWhiteSpace($ManagerDataRoot)) {
        $installMetadata = Join-Path $InstallRoot 'INSTALL-METADATA.txt'
        if (Test-Path -LiteralPath $installMetadata -PathType Leaf) {
            $dataLine = Get-Content -LiteralPath $installMetadata | Where-Object { $_ -match '^DataDirectory=(?<path>.+)$' } | Select-Object -First 1
            if ($null -ne $dataLine -and $dataLine -match '^DataDirectory=(?<path>.+)$') {
                $candidateDataRoot = [IO.Path]::GetFullPath([string]$Matches['path'])
                if ($candidateDataRoot -eq [IO.Path]::GetFullPath($InstallRoot)) {
                    throw 'Installer metadata contains an unsafe Manager data directory.'
                }
                $dataRoot = $candidateDataRoot
            }
        }
    }
    if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $dataRoot | Out-Null
    }
    $arguments = 'serve --listen=127.0.0.1:8788 --tautweekly-root="{0}" --data-dir="{1}" --open-browser' -f $InstallRoot, $dataRoot
    $process = Start-Process -FilePath $managerPath -ArgumentList $arguments -WorkingDirectory $InstallRoot -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 200
        if ($process.HasExited) {
            throw "The packaged Manager stopped during restart with exit code $($process.ExitCode)."
        }
        try {
            $health = Invoke-RestMethod -UseBasicParsing -Uri 'http://127.0.0.1:8788/health/live' -TimeoutSec 2
            $setup = Invoke-RestMethod -UseBasicParsing -Uri 'http://127.0.0.1:8788/api/v1/setup' -TimeoutSec 2
            if ([string]$health.status -eq 'alive' -and $null -ne $setup.PSObject.Properties['paired']) { return }
        }
        catch { }
    } while ((Get-Date) -lt $deadline)
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw 'The packaged Manager did not become ready after the update.'
}

function Remove-OwnedFiles {
    param(
        [Parameter(Mandatory = $true)][Collections.IEnumerable]$RelativePaths,
        [Parameter(Mandatory = $true)][string]$Root
    )
    foreach ($relative in $RelativePaths) {
        Assert-PackageOwnedPath -RelativePath $relative
        $target = Get-SafeRelativePath -Root $Root -RelativePath $relative
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
        }
    }
}

function Copy-OwnedFiles {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Manifest,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    foreach ($entry in $Manifest.Values) {
        $sourcePath = Get-SafeRelativePath -Root $Source -RelativePath $entry.RelativePath
        $destinationPath = Get-SafeRelativePath -Root $Destination -RelativePath $entry.RelativePath
        $parent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }
    Copy-Item -LiteralPath (Join-Path $Source 'RELEASE-FILES.txt') -Destination (Join-Path $Destination 'RELEASE-FILES.txt') -Force
}

if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    throw "Installation directory was not found: $InstallRoot"
}
if (-not (Test-Path -LiteralPath $CandidateRoot -PathType Container)) {
    throw "Staged update directory was not found: $CandidateRoot"
}
if ($CandidateRoot.StartsWith($InstallRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The staged update must be outside the live installation directory.'
}
if ($InstallerTestMode) {
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $installUnderTemporaryRoot = $InstallRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)
    $candidateUnderTemporaryRoot = $CandidateRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)
    $testSegment = [IO.Path]::DirectorySeparatorChar + 'tautweekly-installer-test-'
    if (-not $installUnderTemporaryRoot -or -not $candidateUnderTemporaryRoot -or
        $InstallRoot.IndexOf($testSegment, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $CandidateRoot.IndexOf($testSegment, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw 'Installer test mode is restricted to an isolated TautWeekly installer test directory.'
    }
}

$candidateManifest = Read-ReleaseManifest -Root $CandidateRoot
$requiredFiles = @(
    'TautWeekly.ps1', 'Check-Update.ps1', 'Windows-Update.ps1',
    'Operation-Lock.ps1', 'SCHEDULE-HELPER.ps1',
    '00-OPEN-MANAGER.bat', 'START-MANAGER.ps1', '18-RESET-MANAGER-ACCESS.bat', 'RESET-MANAGER-ACCESS.ps1',
    'tautweekly-manager.exe', 'RELEASE-METADATA.txt'
)
foreach ($required in $requiredFiles) {
    if (-not $candidateManifest.Contains($required.ToLowerInvariant())) {
        throw "Staged update manifest is missing required file: $required"
    }
}
if ((Get-RepositoryVersion -Root $CandidateRoot) -ne $TargetVersion) {
    throw "Staged package metadata does not match target version $TargetVersion."
}
Assert-ManifestFiles -Root $CandidateRoot -Manifest $candidateManifest
Assert-PowerShellSyntax -Root $CandidateRoot -Manifest $candidateManifest

$operationLock = $null
$task = $null
$taskWasEnabled = $false
$taskDisabledByUpdater = $false
$backupRoot = ''
$oldManifest = $null
$mutationStarted = $false
$rollbackSucceeded = $false
$managerWasRunning = $false
$managerRestarted = $false

try {
    $operationLock = Enter-TautWeeklyOperationLock -Root $InstallRoot -Purpose "update to $TargetVersion"

    $managerWasRunning = Stop-InstalledManager

    $task = if ($InstallerTestMode) { $null } else { Get-ScheduledNewsletterTask }
    if ($null -ne $task) {
        if ([string]$task.State -eq 'Running') {
            throw 'The TautWeekly scheduled task is running. Wait for the send to finish before updating.'
        }
        $taskWasEnabled = ([string]$task.State -ne 'Disabled')
        if ($taskWasEnabled) {
            Set-NewsletterTaskEnabled -Task $task -Enabled $false
            $taskDisabledByUpdater = $true
        }
    }

    $currentVersion = Get-RepositoryVersion -Root $InstallRoot
    if ([string]::IsNullOrWhiteSpace($currentVersion)) { $currentVersion = 'unknown' }
    $backupParent = Split-Path -Parent $InstallRoot
    $backupLeaf = '{0}.backup-v{1}-{2}' -f (Split-Path -Leaf $InstallRoot), $currentVersion, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $backupRoot = Join-Path $backupParent $backupLeaf
    if (Test-Path -LiteralPath $backupRoot) {
        $backupRoot += '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    }
    Copy-DirectorySnapshot -Source $InstallRoot -Destination $backupRoot
    $script:Result.Backup = $backupRoot

    $oldManifestPath = Join-Path $InstallRoot 'RELEASE-FILES.txt'
    if (Test-Path -LiteralPath $oldManifestPath -PathType Leaf) {
        $oldManifest = Read-ReleaseManifest -Root $InstallRoot
    }

    $mutationStarted = $true
    if ($null -ne $oldManifest) {
        $deprecated = @($oldManifest.Values | Where-Object {
            $entry = $_
            if ($candidateManifest.Contains($entry.RelativePath.ToLowerInvariant())) { return $false }
            $existingPath = Get-SafeRelativePath -Root $InstallRoot -RelativePath $entry.RelativePath
            if (-not (Test-Path -LiteralPath $existingPath -PathType Leaf)) { return $false }
            $existingHash = (Get-FileHash -LiteralPath $existingPath -Algorithm SHA256).Hash.ToLowerInvariant()
            return $existingHash -eq $entry.Hash
        } | ForEach-Object { $_.RelativePath })
        Remove-OwnedFiles -RelativePaths $deprecated -Root $InstallRoot
    }

    Copy-OwnedFiles -Manifest $candidateManifest -Source $CandidateRoot -Destination $InstallRoot
    if ($SimulatePostInstallFailure) {
        throw 'Simulated post-install failure for rollback validation.'
    }
    Assert-ManifestFiles -Root $InstallRoot -Manifest $candidateManifest
    Assert-PowerShellSyntax -Root $InstallRoot -Manifest $candidateManifest
    if ((Get-RepositoryVersion -Root $InstallRoot) -ne $TargetVersion) {
        throw "Installed package did not report repository version $TargetVersion."
    }

    if ($taskDisabledByUpdater) {
        Set-NewsletterTaskEnabled -Task $task -Enabled $true
        $taskDisabledByUpdater = $false
    }

    if ($managerWasRunning) {
        Start-InstalledManager
        $managerRestarted = $true
    }

    $script:Result.Status = 'success'
    $script:Result.Message = "Updated safely to $TargetVersion."
    Write-UpdateResult
    Write-Host "TautWeekly updated safely to $TargetVersion." -ForegroundColor Green
    Write-Host "Private rollback backup: $backupRoot"
    Write-Host 'If this update addresses missing ratings/artwork or results still appear stale, complete metadata readiness before testing: confirm the Plex Movie Ratings Source; run Plex Refresh All Metadata for each included movie/TV library; then run Tautulli Library > Media Info > Refresh media info for each same library.'
    Write-Host 'Open TautWeekly Manager, run Validate, save, and verify, inspect the generated previews, and complete a controlled TestEmail check before the next production send.'
}
catch {
    $failure = $_
    $managerRestartFailure = ''
    if ($mutationStarted -and -not [string]::IsNullOrWhiteSpace($backupRoot) -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        try {
            $pathsToRemove = @($candidateManifest.Values | ForEach-Object { $_.RelativePath })
            if ($null -ne $oldManifest) {
                $pathsToRemove += @($oldManifest.Values | ForEach-Object { $_.RelativePath })
            }
            Remove-OwnedFiles -RelativePaths ($pathsToRemove | Sort-Object -Unique) -Root $InstallRoot
            if (Test-Path -LiteralPath (Join-Path $InstallRoot 'RELEASE-FILES.txt')) {
                Remove-Item -LiteralPath (Join-Path $InstallRoot 'RELEASE-FILES.txt') -Force
            }
            Copy-DirectorySnapshot -Source $backupRoot -Destination $InstallRoot
            $rollbackSucceeded = $true
        }
        catch {
            $script:Result.Message = "Update failed and automatic rollback also failed: $($failure.Exception.Message) Rollback error: $($_.Exception.Message)"
        }
    }

    if ((-not $mutationStarted -or $rollbackSucceeded) -and $taskDisabledByUpdater) {
        try {
            Set-NewsletterTaskEnabled -Task $task -Enabled $true
            $taskDisabledByUpdater = $false
        }
        catch {
            $script:Result.Message = "Update failed and files were rolled back, but the scheduled task could not be restored: $($_.Exception.Message)"
        }
    }

    if ($managerWasRunning -and -not $managerRestarted) {
        try {
            Start-InstalledManager
            $managerRestarted = $true
        }
        catch {
            $managerRestartFailure = " The packaged Manager could not be restarted: $($_.Exception.Message)"
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:Result.Message)) {
        if ($rollbackSucceeded) {
            $script:Result.Message = "Update failed; the previous installation was restored automatically: $($failure.Exception.Message)"
        }
        else {
            $script:Result.Message = "Update stopped before completion: $($failure.Exception.Message)"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($managerRestartFailure)) {
        $script:Result.Message += $managerRestartFailure
    }
    Write-UpdateResult
    throw $script:Result.Message
}
finally {
    Exit-TautWeeklyOperationLock -Lock $operationLock
}
