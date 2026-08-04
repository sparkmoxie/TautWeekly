Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$configPath = Join-Path $root "config.json"
if (-not (Test-Path $configPath)) { throw "config.json is missing." }
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$taskName = if ($null -ne $config.PSObject.Properties["ScheduledTaskName"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ScheduledTaskName)) { [string]$config.ScheduledTaskName } else { "PlexWeekly Newsletter" }
$day = if ($null -ne $config.PSObject.Properties["ScheduleDay"]) { [string]$config.ScheduleDay } else { "Friday" }
$time = if ($null -ne $config.PSObject.Properties["ScheduleTime"]) { [string]$config.ScheduleTime } else { "09:30" }

Write-Host ""
try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $info = $task | Get-ScheduledTaskInfo
    Write-Host "PlexWeekly task is installed." -ForegroundColor Green
    Write-Host "Task:        $taskName"
    Write-Host "Expected:    Every $day at $time local Windows time"
    Write-Host "State:       $($task.State)"
    Write-Host "Next run:    $($info.NextRunTime)"
    Write-Host "Last run:    $($info.LastRunTime)"
    Write-Host "Last result: $($info.LastTaskResult)"
    Write-Host "Action:      $($task.Actions.Execute) $($task.Actions.Arguments)"
    Write-Host "Working dir: $($task.Actions.WorkingDirectory)"
    exit 0
}
catch {
    Write-Host "Scheduled task '$taskName' was not found." -ForegroundColor Red
    exit 1
}
