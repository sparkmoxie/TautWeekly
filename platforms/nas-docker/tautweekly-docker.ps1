param(
    [Parameter(Position=0)]
    [ValidateSet(
        "help","build","up","down","restart","status","logs","shell",
        "setup","verify","list-users","preview","preview-all",
        "send-test","send-test-all","welcome","send-all","roster",
        "repair-assets","manager-bootstrap","manager-reset-access","schedule-status","schedule-enable",
        "schedule-disable","schedule-reset","check-update","update"
    )]
    [string]$Command = "help",

    [Parameter(Position=1)]
    [string]$User = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$script:PackageRoot = [IO.Path]::GetFullPath($PSScriptRoot)

$script:ComposeExe = ""
$script:ComposePrefix = @()

& docker compose version *> $null
if ($LASTEXITCODE -eq 0) {
    $script:ComposeExe = "docker"
    $script:ComposePrefix = @("compose")
}
elseif ($null -ne (Get-Command docker-compose -ErrorAction SilentlyContinue)) {
    $script:ComposeExe = "docker-compose"
}
else {
    throw "Docker Compose was not found. Start Docker Desktop and enable Docker Compose."
}

function Invoke-Compose {
    param([string[]]$Arguments)

    $all = @($script:ComposePrefix) + @($Arguments)
    & $script:ComposeExe @all
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose exited with code $LASTEXITCODE."
    }
}

function Invoke-ComposeCapture {
    param([string[]]$Arguments)

    $all = @($script:ComposePrefix) + @($Arguments)
    $output = & $script:ComposeExe @all 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose exited with code $LASTEXITCODE."
    }
    return (($output | Out-String).Trim())
}

function Invoke-DockerCapture {
    param([string[]]$Arguments)

    $output = & docker @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($output | Out-String).Trim())
}

function Get-ContainerId {
    return (Invoke-ComposeCapture @('ps','-q','tautweekly')).Split([Environment]::NewLine)[0].Trim()
}

function Get-ImageVersion {
    param([string]$Image)
    if ([string]::IsNullOrWhiteSpace($Image)) { return 'unknown' }
    $value = Invoke-DockerCapture @('image','inspect','--format','{{ index .Config.Labels "org.opencontainers.image.version" }}',$Image)
    if ([string]::IsNullOrWhiteSpace($value)) { return 'unknown' }
    return $value
}

function Get-PackageVersion {
    $metadata = Join-Path $script:PackageRoot 'RELEASE-METADATA.txt'
    if (-not (Test-Path -LiteralPath $metadata -PathType Leaf)) { return 'unknown' }
    $match = [regex]::Match((Get-Content -LiteralPath $metadata -Raw), '(?m)^Repository version:\s*v?(?<version>\d+\.\d+\.\d+)\s*$')
    if (-not $match.Success) { return 'unknown' }
    return $match.Groups['version'].Value
}

function Get-LatestPackageVersion {
    if (-not [string]::IsNullOrWhiteSpace([string]$env:TAUTWEEKLY_LATEST_RELEASE_VERSION)) {
        $version = ([string]$env:TAUTWEEKLY_LATEST_RELEASE_VERSION).TrimStart('v')
    }
    else {
        $api = if ([string]::IsNullOrWhiteSpace([string]$env:TAUTWEEKLY_RELEASE_API_URL)) {
            'https://api.github.com/repos/sparkmoxie/TautWeekly/releases/latest'
        } else { [string]$env:TAUTWEEKLY_RELEASE_API_URL }
        $response = Invoke-RestMethod -Uri $api -Headers @{
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        $version = ([string]$response.tag_name).TrimStart('v')
    }
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'GitHub did not return a valid stable release version.' }
    return $version
}

function Test-SafePackagePath {
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) { return $false }
    $parts = $RelativePath.Replace('\','/').Split('/')
    return (@($parts | Where-Object {
        [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.','..') -or $_ -match '[\x00-\x1f:]'
    }).Count -eq 0)
}

function Test-ProtectedPackagePath {
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    $value = $RelativePath.Replace('\','/')
    return ($value -eq '.env' -or $value -eq 'data' -or $value.StartsWith('data/', [StringComparison]::OrdinalIgnoreCase))
}

function Read-ReleaseManifest {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path = Join-Path $Root 'RELEASE-FILES.txt'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release file manifest not found: $path" }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^(?<hash>[0-9a-f]{64})\s{2}(?<path>.+)$') { throw "Invalid release manifest line: $line" }
        $relative = $Matches['path'].Replace('\','/')
        if (-not (Test-SafePackagePath $relative)) { throw "Unsafe release manifest path: $relative" }
        $entries.Add([pscustomobject]@{ Hash=$Matches['hash']; Path=$relative })
    }
    return $entries.ToArray()
}

function Test-InstalledPackageManifest {
    try {
        foreach ($entry in Read-ReleaseManifest $script:PackageRoot) {
            if (Test-ProtectedPackagePath $entry.Path) { continue }
            $path = Join-Path $script:PackageRoot $entry.Path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Hash) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-VerifiedPackageCandidate {
    param([Parameter(Mandatory=$true)][string]$Version)
    $work = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-package-update-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $archiveName = 'TautWeekly-nas-docker.zip'
        $sums = Join-Path $work 'SHA256SUMS.txt'
        $archive = Join-Path $work $archiveName
        if (-not [string]::IsNullOrWhiteSpace([string]$env:TAUTWEEKLY_RELEASE_ASSET_DIR)) {
            Copy-Item -LiteralPath (Join-Path $env:TAUTWEEKLY_RELEASE_ASSET_DIR 'SHA256SUMS.txt') -Destination $sums
            Copy-Item -LiteralPath (Join-Path $env:TAUTWEEKLY_RELEASE_ASSET_DIR $archiveName) -Destination $archive
        }
        else {
            $downloadRoot = if ([string]::IsNullOrWhiteSpace([string]$env:TAUTWEEKLY_RELEASE_DOWNLOAD_ROOT)) {
                'https://github.com/sparkmoxie/TautWeekly/releases/download'
            } else { [string]$env:TAUTWEEKLY_RELEASE_DOWNLOAD_ROOT }
            Invoke-WebRequest -UseBasicParsing -Uri "$downloadRoot/v$Version/SHA256SUMS.txt" -OutFile $sums
            Invoke-WebRequest -UseBasicParsing -Uri "$downloadRoot/v$Version/$archiveName" -OutFile $archive
        }
        $checksumMatches = @(Get-Content -LiteralPath $sums | Where-Object { $_ -match ('^(?<hash>[0-9a-fA-F]{64})\s{2}' + [regex]::Escape($archiveName) + '$') })
        if ($checksumMatches.Count -ne 1) { throw "SHA256SUMS.txt has no unique entry for $archiveName." }
        [void]($checksumMatches[0] -match '^(?<hash>[0-9a-fA-F]{64})')
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $Matches['hash']) { throw "SHA-256 verification failed for $archiveName." }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            foreach ($entry in $zip.Entries) {
                $path = $entry.FullName.TrimEnd('/').Replace('\','/')
                if (-not [string]::IsNullOrWhiteSpace($path) -and -not (Test-SafePackagePath $path)) {
                    throw "Unsafe ZIP entry: $path"
                }
            }
        }
        finally { $zip.Dispose() }
        Expand-Archive -LiteralPath $archive -DestinationPath $work
        $candidate = Join-Path $work 'TautWeekly-nas-docker'
        $candidateVersionMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $candidate 'RELEASE-METADATA.txt') -Raw), '(?m)^Repository version:\s*v?(?<version>\d+\.\d+\.\d+)\s*$')
        if (-not $candidateVersionMatch.Success -or $candidateVersionMatch.Groups['version'].Value -ne $Version) {
            throw 'The verified archive reports an unexpected package version.'
        }
        foreach ($entry in Read-ReleaseManifest $candidate) {
            $path = Join-Path $candidate $entry.Path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release manifest file is missing: $($entry.Path)" }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Hash) {
                throw "Release manifest hash failed: $($entry.Path)"
            }
        }
        return [pscustomobject]@{ Work=$work; Candidate=$candidate }
    }
    catch {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Install-PackageCandidate {
    param([Parameter(Mandatory=$true)]$Staged)
    $backup = Join-Path $Staged.Work 'package-backup'
    New-Item -ItemType Directory -Path $backup | Out-Null
    $records = [Collections.Generic.List[object]]::new()
    $candidateEntries = @(Read-ReleaseManifest $Staged.Candidate)
    $candidatePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $candidateEntries) { [void]$candidatePaths.Add($entry.Path) }
    $manifestPath = Join-Path $script:PackageRoot 'RELEASE-FILES.txt'
    $manifestBackup = Join-Path $backup 'RELEASE-FILES.txt'
    $manifestExisted = Test-Path -LiteralPath $manifestPath -PathType Leaf
    if ($manifestExisted) { Copy-Item -LiteralPath $manifestPath -Destination $manifestBackup -Force }
    $installed = [pscustomobject]@{
        Work=$Staged.Work
        Backup=$backup
        Records=$records
        ManifestExisted=$manifestExisted
    }
    try {
        $oldEntries = try { @(Read-ReleaseManifest $script:PackageRoot) } catch { @() }
        foreach ($entry in $oldEntries) {
            if (Test-ProtectedPackagePath $entry.Path) { continue }
            if ($candidatePaths.Contains($entry.Path)) { continue }
            $destination = Join-Path $script:PackageRoot $entry.Path
            if (-not (Test-Path -LiteralPath $destination)) { continue }
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                throw "Refusing to remove a non-file retired package path: $($entry.Path)"
            }
            $backupPath = Join-Path $backup $entry.Path
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backupPath -Force
            $records.Add([pscustomobject]@{ Path=$entry.Path; Existed=$true })
            Remove-Item -LiteralPath $destination -Force
        }
        foreach ($entry in $candidateEntries) {
            if (Test-ProtectedPackagePath $entry.Path) { continue }
            $source = Join-Path $Staged.Candidate $entry.Path
            $destination = Join-Path $script:PackageRoot $entry.Path
            $backupPath = Join-Path $backup $entry.Path
            $exists = Test-Path -LiteralPath $destination -PathType Leaf
            if ($exists) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
                Copy-Item -LiteralPath $destination -Destination $backupPath -Force
            }
            elseif (Test-Path -LiteralPath $destination) { throw "Refusing to replace a non-file package path: $($entry.Path)" }
            $records.Add([pscustomobject]@{ Path=$entry.Path; Existed=$exists })
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
        Copy-Item -LiteralPath (Join-Path $Staged.Candidate 'RELEASE-FILES.txt') -Destination $manifestPath -Force
        return $installed
    }
    catch {
        Restore-PackageCandidate $installed
        throw
    }
}

function Restore-PackageCandidate {
    param([Parameter(Mandatory=$true)]$Installed)
    foreach ($record in $Installed.Records) {
        $destination = Join-Path $script:PackageRoot $record.Path
        if ($record.Existed) { Copy-Item -LiteralPath (Join-Path $Installed.Backup $record.Path) -Destination $destination -Force }
        else { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
    }
    $manifest = Join-Path $script:PackageRoot 'RELEASE-FILES.txt'
    if ($Installed.ManifestExisted) { Copy-Item -LiteralPath (Join-Path $Installed.Backup 'RELEASE-FILES.txt') -Destination $manifest -Force }
    else { Remove-Item -LiteralPath $manifest -Force -ErrorAction SilentlyContinue }
}

function Remove-PackageWork {
    param([Parameter(Mandatory=$true)][string]$Path)
    if ((Split-Path -Leaf $Path) -notlike 'tautweekly-package-update-*') { throw "Refusing to remove unexpected package staging path: $Path" }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Wait-ContainerHealthy {
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $id = Get-ContainerId
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $state = Invoke-DockerCapture @('inspect','--format','{{.State.Status}}',$id)
            $health = Invoke-DockerCapture @('inspect','--format','{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}',$id)
            if ($state -eq 'running' -and $health -eq 'healthy') { return $true }
            if ($state -in @('exited','dead')) { break }
        }
        Start-Sleep -Seconds 2
    }
    Invoke-Compose @('ps')
    Invoke-Compose @('logs','--tail=100','tautweekly')
    return $false
}

function Test-Compose {
    param([string[]]$Arguments)

    $all = @($script:ComposePrefix) + @($Arguments)
    & $script:ComposeExe @all *> $null
    return ($LASTEXITCODE -eq 0)
}

function Start-ContainerOperationLock {
    $lockedContainer = Get-ContainerId
    Invoke-Compose @('exec','-T','tautweekly','rm','-f','/data/.tautweekly-update-holder')
    $holderScript = 'echo $$ > /data/.tautweekly-update-holder; trap "rm -f /data/.tautweekly-update-holder" EXIT HUP INT TERM; while :; do sleep 60; done'
    Invoke-Compose @('exec','-T','-d','tautweekly','flock','-n','/data/.tautweekly-operation.lock','sh','-c',$holderScript)
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (Test-Compose @('exec','-T','tautweekly','test','-s','/data/.tautweekly-update-holder')) {
            return
        }
        Start-Sleep -Seconds 1
    }
    Stop-ContainerOperationLock $lockedContainer
    throw 'Another TautWeekly operation is running; the update was not started.'
}

function Stop-ContainerOperationLock {
    param([string]$LockedContainer)

    $currentContainer = Get-ContainerId
    if (-not [string]::IsNullOrWhiteSpace($LockedContainer) -and $currentContainer -eq $LockedContainer) {
        $cleanup = 'if [ -s /data/.tautweekly-update-holder ]; then kill "$(cat /data/.tautweekly-update-holder)" 2>/dev/null || true; fi; rm -f /data/.tautweekly-update-holder'
        $all = @($script:ComposePrefix) + @('exec','-T','tautweekly','sh','-c',$cleanup)
    }
    else {
        $all = @($script:ComposePrefix) + @('exec','-T','tautweekly','rm','-f','/data/.tautweekly-update-holder')
    }
    & $script:ComposeExe @all *> $null
}

function Invoke-ContainerUpdate {
    param([switch]$Apply, [switch]$ForceRecreate)

    $imageRef = ((Invoke-ComposeCapture @('config','--images')) -split "`r?`n" | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($imageRef)) { throw 'The configured Compose image could not be resolved.' }
    $containerId = Get-ContainerId
    $before = if ([string]::IsNullOrWhiteSpace($containerId)) { '' } else {
        Invoke-DockerCapture @('inspect','--format','{{.Image}}',$containerId)
    }
    $beforeVersion = Get-ImageVersion $before

    $lockHeld = $false
    if ($Apply -and -not [string]::IsNullOrWhiteSpace($containerId)) {
        Start-ContainerOperationLock
        $lockHeld = $true
    }

    try {
        Invoke-Compose @('pull','tautweekly')
        $after = Invoke-DockerCapture @('image','inspect','--format','{{.Id}}',$imageRef)
        if ([string]::IsNullOrWhiteSpace($after)) { throw "Unable to inspect configured image after pull: $imageRef" }
        $afterVersion = Get-ImageVersion $after
        if ($afterVersion -eq 'unknown') { throw 'The staged image has no repository version label; refusing to treat it as a release update.' }

        if (-not $Apply) {
            Write-Host "Running image version: $beforeVersion"
            Write-Host "Latest configured image version: $afterVersion"
            if ([string]::IsNullOrWhiteSpace($before)) { Write-Host 'The stable image is staged; no container is running.' }
            elseif ($before -eq $after) { Write-Host 'The running container is up to date.' -ForegroundColor Green }
            else { Write-Host 'An update is staged. Run .\tautweekly-docker.ps1 update to apply it.' -ForegroundColor Yellow }
            return
        }

        if (-not $ForceRecreate -and -not [string]::IsNullOrWhiteSpace($before) -and $before -eq $after) {
            if (-not (Wait-ContainerHealthy)) { throw 'The current container failed health verification.' }
            Write-Host "The running container is already on stable image version $afterVersion." -ForegroundColor Green
            return
        }

        try {
            $upArguments = @('up','-d','--no-build')
            if ($ForceRecreate) { $upArguments += '--force-recreate' }
            $upArguments += 'tautweekly'
            Invoke-Compose $upArguments
            if (-not (Wait-ContainerHealthy)) { throw 'The updated container failed health verification.' }
            $runningContainer = Get-ContainerId
            $runningAfter = Invoke-DockerCapture @('inspect','--format','{{.Image}}',$runningContainer)
            $runningAfterVersion = Get-ImageVersion $runningAfter
            if ($runningAfter -ne $after -or $runningAfterVersion -ne $afterVersion) {
                throw "The recreated service reports $runningAfterVersion ($runningAfter), expected $afterVersion ($after)."
            }
            Write-Host "Updated TautWeekly from $beforeVersion to $runningAfterVersion; persistent data was preserved." -ForegroundColor Green
        }
        catch {
            if ([string]::IsNullOrWhiteSpace($before)) { throw }
            Write-Warning 'Update failed; restoring the previous image.'
            & docker image tag $before $imageRef
            if ($LASTEXITCODE -ne 0) { throw "Automatic rollback could not retag previous image $before." }
            Invoke-Compose @('up','-d','--no-build','--force-recreate','tautweekly')
            if (-not (Wait-ContainerHealthy)) { throw "Rollback also failed health verification. Previous image ID: $before" }
            $restoredContainer = Get-ContainerId
            $restoredImage = Invoke-DockerCapture @('inspect','--format','{{.Image}}',$restoredContainer)
            if ($restoredImage -ne $before) { throw "Rollback became healthy on unexpected image $restoredImage; expected $before." }
            throw "Update failed and was rolled back to image version $beforeVersion."
        }
    }
    finally {
        if ($lockHeld) { Stop-ContainerOperationLock $containerId }
    }
}

function Invoke-PackageAwareUpdate {
    param([switch]$Apply)

    $current = Get-PackageVersion
    if ($current -eq 'unknown') {
        Write-Warning 'Host-package release metadata is unavailable; only the container image can be checked from this development or legacy directory.'
        Invoke-ContainerUpdate -Apply:$Apply
        return
    }
    $latest = Get-LatestPackageVersion
    $verified = Test-InstalledPackageManifest
    Write-Host "Installed host package: $current ($(if ($verified) { 'verified' } else { 'repair-required' }))"
    Write-Host "Latest stable package: $latest"
    if (-not $Apply) {
        if (-not $verified) { Write-Warning 'The next update will repair release-owned package files without replacing .env or data.' }
        elseif ([version]$current -lt [version]$latest) { Write-Host "A host-package update is available: $current -> $latest" -ForegroundColor Yellow }
        elseif ([version]$current -gt [version]$latest) { Write-Warning "Installed package $current is newer than stable $latest; it will not be downgraded." }
        else { Write-Host 'The host package is up to date.' -ForegroundColor Green }
        Invoke-ContainerUpdate
        return
    }

    $needsPackage = (-not $verified -or [version]$current -lt [version]$latest)
    if (-not $needsPackage -or [version]$current -gt [version]$latest) {
        if ([version]$current -gt [version]$latest) { Write-Warning "Installed package $current is newer than stable $latest; it was not downgraded." }
        Invoke-ContainerUpdate -Apply
        return
    }

    $staged = Get-VerifiedPackageCandidate $latest
    $installed = $null
    try {
        $installed = Install-PackageCandidate $staged
        Write-Host "Verified and installed stable host package $latest; .env and data were preserved." -ForegroundColor Green
        Invoke-ContainerUpdate -Apply -ForceRecreate
        Write-Host 'Host package and runtime update committed.' -ForegroundColor Green
    }
    catch {
        if ($null -ne $installed) {
            Restore-PackageCandidate $installed
            Write-Warning 'The previous release-owned host package files were restored; .env and data were unchanged.'
        }
        throw
    }
    finally {
        Remove-PackageWork $staged.Work
    }
}

function Resolve-User {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = Read-Host "UserId, username, friendly name, or email"
    }
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "A user identifier is required."
    }
    return $Value.Trim()
}

function Confirm-Action {
    param([string]$Prompt)
    $answer = Read-Host "$Prompt [y/N]"
    return (-not [string]::IsNullOrWhiteSpace($answer) -and $answer -match '^(?i:y|yes)$')
}

switch ($Command) {
    "build" {
        throw "The release Compose file pulls a published image. Source builds use: docker build -f platforms/nas-docker/Dockerfile ."
    }
    "up" { Invoke-Compose @("up","-d") }
    "down" { Invoke-Compose @("down") }
    "restart" { Invoke-Compose @("restart","tautweekly") }
    "status" { Invoke-Compose @("ps") }
    "logs" { Invoke-Compose @("logs","-f","--tail=200","tautweekly") }
    "shell" { Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-as-user.sh","bash") }
    "setup" { Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-script.sh","Setup-First.ps1") }
    "verify" { Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-script.sh","Verify-Setup.ps1") }
    "list-users" { Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-mode.sh","ListUsers") }
    "preview" {
        $id = Resolve-User $User
        Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-mode.sh","Preview",$id)
    }
    "preview-all" {
        $id = Resolve-User $User
        Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-mode.sh","PreviewAll",$id)
    }
    "send-test" {
        $id = Resolve-User $User
        if (Confirm-Action "Send one message to TestEmail using $id?") {
            Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-mode.sh","SendTest",$id)
        }
    }
    "send-test-all" {
        $id = Resolve-User $User
        if (Confirm-Action "Send all six regression messages to TestEmail using $id?") {
            Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-mode.sh","SendTestAll",$id)
        }
    }
    "welcome" {
        $id = Resolve-User $User
        if (Confirm-Action "Send a real one-off welcome to the selected Plex user?") {
            Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-mode.sh","SendWelcome",$id,"--confirm-welcome")
        }
    }
    "send-all" {
        if (Confirm-Action "Send one real newsletter to every eligible Plex user?") {
            Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-mode.sh","SendAll","--confirm-send-all")
        }
    }
    "roster" { Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-script.sh","View-Access-Roster.ps1") }
    "repair-assets" { Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-script.sh","Repair-Assets.ps1") }
    "manager-bootstrap" {
        Invoke-Compose @("exec","-T","tautweekly","/opt/tautweekly/bin/run-as-user.sh","/opt/tautweekly/bin/tautweekly-manager","access-bootstrap","--data-dir","/data/manager")
    }
    "manager-reset-access" {
        Write-Warning "This resets only the Manager password and active browser sessions. Newsletter data is preserved."
        if (Confirm-Action "Reset Manager access and restart the container?") {
            Invoke-Compose @("exec","-T","tautweekly","/opt/tautweekly/bin/run-as-user.sh","/opt/tautweekly/bin/tautweekly-manager","access-recover","--data-dir","/data/manager","--confirm")
            Invoke-Compose @("restart","tautweekly")
            Write-Host "Run .\tautweekly-docker.ps1 manager-bootstrap to retrieve the new one-time pairing token."
        }
    }
    "schedule-status" { Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-script.sh","Schedule-Control.ps1","-Action","Status") }
    "schedule-enable" {
        if (Confirm-Action "Enable the configured automatic weekly send?") {
            Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-script.sh","Schedule-Control.ps1","-Action","Enable")
        }
    }
    "schedule-disable" { Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-script.sh","Schedule-Control.ps1","-Action","Disable") }
    "schedule-reset" {
        Write-Warning "This clears today's automatic-attempt guard and can permit another real send today."
        if (Confirm-Action "Clear the guard?") {
            Invoke-Compose @("exec","tautweekly","/opt/tautweekly/bin/run-script.sh","Schedule-Control.ps1","-Action","ResetToday")
        }
    }
    "check-update" { Invoke-PackageAwareUpdate }
    "update" { Invoke-PackageAwareUpdate -Apply }
    default {
        @"
TautWeekly for Plex Docker Desktop / PowerShell commands

  .\tautweekly-docker.ps1 build
  .\tautweekly-docker.ps1 up
  .\tautweekly-docker.ps1 setup
  .\tautweekly-docker.ps1 verify
  .\tautweekly-docker.ps1 manager-bootstrap
  .\tautweekly-docker.ps1 manager-reset-access
  .\tautweekly-docker.ps1 list-users
  .\tautweekly-docker.ps1 preview-all USER_ID
  .\tautweekly-docker.ps1 send-test-all USER_ID
  .\tautweekly-docker.ps1 schedule-status
  .\tautweekly-docker.ps1 schedule-enable
  .\tautweekly-docker.ps1 check-update
  .\tautweekly-docker.ps1 update
  .\tautweekly-docker.ps1 logs
  .\tautweekly-docker.ps1 status

The wrapper requires Docker Desktop in Linux-container mode.
USER_ID is the numeric value shown by list-users. Omit it only in an
interactive terminal when you want the wrapper to prompt for it.
"@ | Write-Host
    }
}
