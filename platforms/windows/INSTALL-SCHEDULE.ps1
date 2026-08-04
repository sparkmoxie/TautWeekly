Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$configPath = Join-Path $root "config.json"
$engine = Join-Path $root "TautWeekly.ps1"

if (-not (Test-Path $engine)) { throw "TautWeekly.ps1 not found at $engine" }
if (-not (Test-Path $configPath)) { throw "config.json is missing. Run 00-SETUP-FIRST.bat first." }
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

$taskName = if ($null -ne $config.PSObject.Properties["ScheduledTaskName"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ScheduledTaskName)) {
    [string]$config.ScheduledTaskName
} else { "TautWeekly for Plex Newsletter" }

$dayText = if ($null -ne $config.PSObject.Properties["ScheduleDay"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ScheduleDay)) {
    [string]$config.ScheduleDay
} else { "Friday" }
try { $day = [System.Enum]::Parse([System.DayOfWeek], $dayText, $true) }
catch { throw "Invalid ScheduleDay '$dayText'. Use Sunday through Saturday." }

$timeText = if ($null -ne $config.PSObject.Properties["ScheduleTime"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ScheduleTime)) {
    [string]$config.ScheduleTime
} else { "09:30" }
$parsed = [DateTime]::MinValue
if (-not [DateTime]::TryParseExact($timeText, "HH:mm", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
    throw "Invalid ScheduleTime '$timeText'. Use 24-hour HH:mm format."
}
$at = [DateTime]::Today.AddHours($parsed.Hour).AddMinutes($parsed.Minute)

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode SendAll -ConfirmSendAll' -f $engine) `
    -WorkingDirectory $root

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $at

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -WakeToRun `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6)

$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Sends the TautWeekly for Plex personalized newsletter on $dayText at $timeText using local Windows time." `
    -Force | Out-Null

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$info = $task | Get-ScheduledTaskInfo
Write-Host ""
Write-Host "TautWeekly for Plex schedule installed." -ForegroundColor Green
Write-Host "Task:       $taskName"
Write-Host "Folder:     $root"
Write-Host "Schedule:   Every $dayText at $timeText (local Windows time)"
Write-Host "Runs as:    SYSTEM"
Write-Host "State:      $($task.State)"
Write-Host "Next run:   $($info.NextRunTime)"
Write-Host ""
Write-Host "NOTE: If Plex is remote or logo discovery works only under your user account,"
Write-Host "set PlexServerUrl and PlexToken in config.json so the SYSTEM task can use them."
