Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$configPath = Join-Path $root "config.json"
if (-not (Test-Path $configPath)) { throw "config.json is missing." }
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$taskName = if ($null -ne $config.PSObject.Properties["ScheduledTaskName"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ScheduledTaskName)) { [string]$config.ScheduledTaskName } else { "TautWeekly for Plex Newsletter" }
$day = if ($null -ne $config.PSObject.Properties["ScheduleDay"]) { [string]$config.ScheduleDay } else { "Friday" }
$time = if ($null -ne $config.PSObject.Properties["ScheduleTime"]) { [string]$config.ScheduleTime } else { "09:30" }
$engine = Join-Path $root 'TautWeekly.ps1'
$resultPath = Join-Path $root 'last-run.json'
$expectedArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode SendAll -ResultPath "{1}" -ConfirmSendAll' -f $engine, $resultPath

Write-Host ""
try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $info = $task | Get-ScheduledTaskInfo
    $actions = @($task.Actions)
    $owned = $false
    if ($actions.Count -eq 1) {
        $action = $actions[0]
        try {
            $workingDirectory = [IO.Path]::GetFullPath([string]$action.WorkingDirectory).TrimEnd('\')
            $expectedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
            $owned = ([IO.Path]::GetFileName([string]$action.Execute) -ieq 'powershell.exe') -and
                ([string]$action.Arguments -ieq $expectedArguments) -and
                ($workingDirectory -ieq $expectedRoot) -and
                ([string]$task.Principal.UserId -ieq 'SYSTEM')
        }
        catch { $owned = $false }
    }
    if (-not $owned) {
        Write-Host "Scheduled task '$taskName' exists but is not owned by this TautWeekly installation." -ForegroundColor Red
        Write-Host 'It was not changed. Choose a different ScheduledTaskName or resolve the collision manually.'
        exit 1
    }
    Write-Host "TautWeekly for Plex task is installed." -ForegroundColor Green
    Write-Host "Task:        $taskName"
    Write-Host "Expected:    Every $day at $time local Windows time"
    Write-Host "State:       $($task.State)"
    Write-Host "Next run:    $($info.NextRunTime)"
    Write-Host "Last run:    $($info.LastRunTime)"
    Write-Host "Last result: $($info.LastTaskResult)"
    Write-Host "Action:      $($task.Actions.Execute) $($task.Actions.Arguments)"
    Write-Host "Working dir: $($task.Actions.WorkingDirectory)"
    Write-Host 'Ownership:   Verified'
    exit 0
}
catch {
    Write-Host "Scheduled task '$taskName' was not found." -ForegroundColor Red
    exit 1
}
