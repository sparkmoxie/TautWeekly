param(
    [Parameter(Position=0)]
    [ValidateSet(
        "help","build","up","down","restart","status","logs","shell",
        "setup","verify","list-users","preview","preview-all",
        "send-test","send-test-all","welcome","send-all","roster",
        "repair-assets","schedule-status","schedule-enable",
        "schedule-disable","schedule-reset"
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
    "shell" { Invoke-Compose @("exec","tautweekly","bash") }
    "setup" { Invoke-Compose @("exec","tautweekly","pwsh","-NoLogo","-NoProfile","-File","/opt/tautweekly/Setup-First.ps1") }
    "verify" { Invoke-Compose @("exec","tautweekly","pwsh","-NoLogo","-NoProfile","-File","/opt/tautweekly/Verify-Setup.ps1") }
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
    "roster" { Invoke-Compose @("exec","tautweekly","pwsh","-NoLogo","-NoProfile","-File","/opt/tautweekly/View-Access-Roster.ps1") }
    "repair-assets" { Invoke-Compose @("exec","tautweekly","pwsh","-NoLogo","-NoProfile","-File","/opt/tautweekly/Repair-Assets.ps1") }
    "schedule-status" { Invoke-Compose @("exec","tautweekly","pwsh","-NoLogo","-NoProfile","-File","/opt/tautweekly/Schedule-Control.ps1","-Action","Status") }
    "schedule-enable" {
        if (Confirm-Action "Enable the configured automatic weekly send?") {
            Invoke-Compose @("exec","tautweekly","pwsh","-NoLogo","-NoProfile","-File","/opt/tautweekly/Schedule-Control.ps1","-Action","Enable")
        }
    }
    "schedule-disable" { Invoke-Compose @("exec","tautweekly","pwsh","-NoLogo","-NoProfile","-File","/opt/tautweekly/Schedule-Control.ps1","-Action","Disable") }
    "schedule-reset" {
        Write-Warning "This clears today's automatic-attempt guard and can permit another real send today."
        if (Confirm-Action "Clear the guard?") {
            Invoke-Compose @("exec","tautweekly","pwsh","-NoLogo","-NoProfile","-File","/opt/tautweekly/Schedule-Control.ps1","-Action","ResetToday")
        }
    }
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
  .\tautweekly-docker.ps1 logs
  .\tautweekly-docker.ps1 status

The wrapper requires Docker Desktop in Linux-container mode.
USER_ID is the numeric value shown by list-users. Omit it only in an
interactive terminal when you want the wrapper to prompt for it.
"@ | Write-Host
    }
}
