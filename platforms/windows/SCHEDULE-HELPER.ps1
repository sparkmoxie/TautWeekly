param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Install", "Enable", "Disable", "Remove")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-fA-F]{64}$")]
    [string]$ExpectedRevision,

    [ValidatePattern("^S-\d-\d+(-\d+)+$")]
    [string]$RequestedBySid,

    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Exit-ScheduleHelper {
    param([int]$Code)
    exit $Code
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FileSha256 {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
        }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-ExpectedTaskArguments {
    param([string]$EnginePath, [string]$ResultPath)
    return ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode SendAll -ResultPath "{1}" -ConfirmSendAll' -f $EnginePath, $ResultPath)
}

function Test-OwnedTask {
    param(
        [object]$Task,
        [string]$Root,
        [string]$ExpectedArguments
    )

    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { return $false }
    $taskAction = $actions[0]
    if ([IO.Path]::GetFileName([string]$taskAction.Execute) -ine "powershell.exe") { return $false }
    if ([string]$taskAction.Arguments -ine $ExpectedArguments) { return $false }
    try {
        $workingDirectory = [IO.Path]::GetFullPath([string]$taskAction.WorkingDirectory).TrimEnd('\')
        $expectedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        if ($workingDirectory -ine $expectedRoot) { return $false }
    }
    catch { return $false }
    return [string]$Task.Principal.UserId -ieq "SYSTEM"
}

function Grant-TaskReadAccess {
    param(
        [string]$TaskName,
        [string]$ReaderSid
    )

    if ($ReaderSid -notmatch "^S-\d-\d+(-\d+)+$") { return $false }
    $service = New-Object -ComObject "Schedule.Service"
    $service.Connect()
    $folder = $service.GetFolder("\")
    $registeredTask = $folder.GetTask($TaskName)
    $securityDescriptor = "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GR;;;$ReaderSid)"
    $registeredTask.SetSecurityDescriptor($securityDescriptor, 0)
    return $true
}

if ([string]::IsNullOrWhiteSpace($RequestedBySid)) {
    if ($Elevated) { Exit-ScheduleHelper 26 }
    try { $RequestedBySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    catch { Exit-ScheduleHelper 26 }
}
if ($RequestedBySid -notmatch "^S-\d-\d+(-\d+)+$") { Exit-ScheduleHelper 26 }

if (-not (Test-IsAdministrator)) {
    if ($Elevated) { Exit-ScheduleHelper 26 }
    try {
        if ([IO.Path]::GetFileName($PSCommandPath) -cne "SCHEDULE-HELPER.ps1") { Exit-ScheduleHelper 26 }
        $powerShellPath = Join-Path $PSHOME "powershell.exe"
        if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) { Exit-ScheduleHelper 26 }
        $helperPathArgument = [char]34 + $PSCommandPath + [char]34
        $arguments = @(
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", $helperPathArgument,
            "-Action", $Action,
            "-ExpectedRevision", $ExpectedRevision,
            "-RequestedBySid", $RequestedBySid,
            "-Elevated"
        )
        $process = Start-Process `
            -FilePath $powerShellPath `
            -ArgumentList $arguments `
            -WorkingDirectory $PSScriptRoot `
            -Verb RunAs `
            -WindowStyle Hidden `
            -PassThru
        $process.WaitForExit()
        $process.Refresh()
        $childExitCode = [int]$process.ExitCode
        Exit-ScheduleHelper $childExitCode
    }
    catch { Exit-ScheduleHelper 10 }
}

$failureExitCode = 28
try {
    $root = $PSScriptRoot
    $configPath = Join-Path $root "config.json"
    $enginePath = Join-Path $root "TautWeekly.ps1"
    $resultPath = Join-Path $root "last-run.json"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { Exit-ScheduleHelper 20 }
    if ((Get-FileSha256 -Path $configPath) -cne $ExpectedRevision.ToLowerInvariant()) { Exit-ScheduleHelper 21 }
    if ($Action -in @("Install", "Enable") -and -not (Test-Path -LiteralPath $enginePath -PathType Leaf)) { Exit-ScheduleHelper 25 }

    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $taskName = if ($null -ne $config.PSObject.Properties["ScheduledTaskName"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ScheduledTaskName)) {
        [string]$config.ScheduledTaskName
    }
    else { "TautWeekly for Plex Newsletter" }
    $expectedArguments = Get-ExpectedTaskArguments -EnginePath $enginePath -ResultPath $resultPath
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($null -ne $existing -and -not (Test-OwnedTask -Task $existing -Root $root -ExpectedArguments $expectedArguments)) {
        Exit-ScheduleHelper 23
    }
    switch ($Action) {
        "Install" {
            $dayText = if ($null -ne $config.PSObject.Properties["ScheduleDay"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ScheduleDay)) {
                [string]$config.ScheduleDay
            }
            else { "Friday" }
            try { $day = [System.Enum]::Parse([System.DayOfWeek], $dayText, $true) }
            catch { Exit-ScheduleHelper 24 }

            $timeText = if ($null -ne $config.PSObject.Properties["ScheduleTime"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ScheduleTime)) {
                [string]$config.ScheduleTime
            }
            else { "09:30" }
            $parsed = [DateTime]::MinValue
            if (-not [DateTime]::TryParseExact($timeText, "HH:mm", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                Exit-ScheduleHelper 24
            }
            $at = [DateTime]::Today.AddHours($parsed.Hour).AddMinutes($parsed.Minute)
            $failureExitCode = 29
            $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $expectedArguments -WorkingDirectory $root
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $at
            $settings = New-ScheduledTaskSettingsSet `
                -StartWhenAvailable `
                -WakeToRun `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit (New-TimeSpan -Hours 6)
            $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            $failureExitCode = 30
            Register-ScheduledTask `
                -TaskName $taskName `
                -Action $taskAction `
                -Trigger $trigger `
                -Settings $settings `
                -Principal $principal `
                -Description "Runs the configured weekly TautWeekly for Plex newsletter using local Windows time." `
                -Force | Out-Null
            $failureExitCode = 32
            if (-not (Grant-TaskReadAccess -TaskName $taskName -ReaderSid $RequestedBySid)) {
                Exit-ScheduleHelper 32
            }
            $failureExitCode = 31
            $installed = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $installedOwned = $null -ne $installed -and (Test-OwnedTask -Task $installed -Root $root -ExpectedArguments $expectedArguments)
            if ($null -eq $installed -or -not $installedOwned -or [string]$installed.State -eq "Disabled") {
                Exit-ScheduleHelper 31
            }
        }
        "Enable" {
            if ($null -eq $existing) { Exit-ScheduleHelper 22 }
            $failureExitCode = 30
            Enable-ScheduledTask -TaskName $taskName | Out-Null
            $failureExitCode = 31
            $enabledTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($null -eq $enabledTask -or -not (Test-OwnedTask -Task $enabledTask -Root $root -ExpectedArguments $expectedArguments) -or [string]$enabledTask.State -eq "Disabled") {
                Exit-ScheduleHelper 31
            }
        }
        "Disable" {
            if ($null -eq $existing) { Exit-ScheduleHelper 22 }
            $failureExitCode = 30
            Disable-ScheduledTask -TaskName $taskName | Out-Null
            $failureExitCode = 31
            $disabledTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($null -eq $disabledTask -or -not (Test-OwnedTask -Task $disabledTask -Root $root -ExpectedArguments $expectedArguments) -or [string]$disabledTask.State -ne "Disabled") {
                Exit-ScheduleHelper 31
            }
        }
        "Remove" {
            if ($null -eq $existing) { Exit-ScheduleHelper 22 }
            $failureExitCode = 30
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            $failureExitCode = 31
            if ($null -ne (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
                Exit-ScheduleHelper 31
            }
        }
    }
    Exit-ScheduleHelper 0
}
catch {
    Exit-ScheduleHelper $failureExitCode
}
