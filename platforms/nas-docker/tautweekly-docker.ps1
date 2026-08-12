param(
    [Parameter(Position=0)]
    [ValidateSet(
        "help","build","up","down","restart","status","logs","shell",
        "setup","verify","list-users","preview","preview-all",
        "send-test","send-test-all","welcome","send-all","roster",
        "repair-assets","schedule-status","schedule-enable",
        "schedule-disable","schedule-reset","check-update","update"
    )]
    [string]$Command = "help",

    [Parameter(Position=1)]
    [string]$User = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

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
    param([switch]$Apply)

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

        if (-not [string]::IsNullOrWhiteSpace($before) -and $before -eq $after) {
            if (-not (Wait-ContainerHealthy)) { throw 'The current container failed health verification.' }
            Write-Host "The running container is already on stable image version $afterVersion." -ForegroundColor Green
            return
        }

        try {
            Invoke-Compose @('up','-d','--no-build','tautweekly')
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
    "build" { Invoke-Compose @("build","--pull") }
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
    "check-update" { Invoke-ContainerUpdate }
    "update" { Invoke-ContainerUpdate -Apply }
    default {
        @"
TautWeekly for Plex Docker Desktop / PowerShell commands

  .\tautweekly-docker.ps1 build
  .\tautweekly-docker.ps1 up
  .\tautweekly-docker.ps1 setup
  .\tautweekly-docker.ps1 verify
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
