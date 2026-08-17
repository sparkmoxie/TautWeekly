param(
    [ValidateSet("Status","Enable","Disable","ResetToday")]
    [string]$Action = "Status",
    [string]$DataRoot = $(if ($env:TAUTWEEKLY_DATA_DIR) { $env:TAUTWEEKLY_DATA_DIR } else { "/data" })
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$configPath = Join-Path $DataRoot "config.json"
$statePath = Join-Path $DataRoot "scheduler-state.json"
$heartbeatPath = Join-Path $DataRoot "scheduler-heartbeat.json"
$appRoot = if ($env:TAUTWEEKLY_APP_DIR) { [string]$env:TAUTWEEKLY_APP_DIR } else { $PSScriptRoot }
. (Join-Path $appRoot "Schedule-Time.ps1")

function Get-Value {
    param([object]$Object, [string]$Name, [object]$Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    if ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $Default }
    return $property.Value
}

function Ensure-Property {
    param([object]$Object, [string]$Name, [object]$Default)
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Default
    }
}

if (-not (Test-Path $configPath)) { throw "config.json is missing. Complete Config in the authenticated Manager; terminal setup is an expert recovery fallback." }
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$configuredTimeZoneId = if ([string]::IsNullOrWhiteSpace([string]$env:TZ)) { 'Etc/UTC' } else { [string]$env:TZ }
$scheduleTimeZone = $null
$controlNow = $null
$timeZoneError = ''
try {
    $scheduleTimeZone = Get-TautWeeklyScheduleTimeZone -TimeZoneId $configuredTimeZoneId
    $controlNow = Get-TautWeeklyScheduleNow -TimeZone $scheduleTimeZone
}
catch {
    $timeZoneError = $_.Exception.Message
    if ($Action -eq "Enable") { throw $timeZoneError }
}
$heartbeat = $null
if (Test-Path $heartbeatPath) {
    try { $heartbeat = Get-Content $heartbeatPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $heartbeat = $null }
}
if ($Action -eq "Enable" -and (Test-Path $heartbeatPath)) {
    if ($null -eq $heartbeat) {
        throw "The active scheduler heartbeat is unreadable. Restart or recreate the service before enabling delivery."
    }
    $activeTimeZoneId = [string](Get-Value $heartbeat 'TimeZoneId' '')
    if ([string]::IsNullOrWhiteSpace($activeTimeZoneId)) {
        throw "The active scheduler has not recorded its resolved time zone. Restart or recreate the service after upgrading before enabling delivery."
    }
    if ($activeTimeZoneId -cne $scheduleTimeZone.Id) {
        throw "The active scheduler is using '$activeTimeZoneId', but the control process resolved '$($scheduleTimeZone.Id)'. Restart or recreate the service before enabling delivery."
    }
}

if ($Action -in @("Enable","Disable")) {
    $enabled = ($Action -eq "Enable")
    if ($null -eq $config.PSObject.Properties["ScheduleEnabled"]) {
        $config | Add-Member -NotePropertyName ScheduleEnabled -NotePropertyValue $enabled
    } else { $config.ScheduleEnabled = $enabled }
    $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
    try { & /bin/chmod 600 $configPath 2>$null } catch { }
    Write-Host "Automatic schedule enabled: $enabled" -ForegroundColor Green
}
elseif ($Action -eq "ResetToday") {
    if (Test-Path $statePath) {
        $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Ensure-Property $state "LastAttemptLocalDate" ""
        Ensure-Property $state "LastResult" "never"
        $state.LastAttemptLocalDate = ""
        $state.LastResult = "manually reset"
        $state | ConvertTo-Json -Depth 8 | Set-Content $statePath -Encoding UTF8
    }
    Write-Host "Today's automatic-attempt guard was cleared." -ForegroundColor Yellow
}

$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$enabledValue = [bool](Get-Value $config "ScheduleEnabled" $false)
$dayValue = [string](Get-Value $config "ScheduleDay" "Friday")
$timeValue = [string](Get-Value $config "ScheduleTime" "09:30")
$graceValue = [int](Get-Value $config "ScheduleGraceMinutes" 60)

Write-Host ""
Write-Host "TAUTWEEKLY FOR PLEX SCHEDULE STATUS" -ForegroundColor Cyan
Write-Host "Enabled:       $enabledValue"
Write-Host "Day/time:      $dayValue $timeValue"
Write-Host "Grace minutes: $graceValue"
Write-Host "Configured TZ: $configuredTimeZoneId"
if ($null -ne $scheduleTimeZone) {
    Write-Host "Control zone:  $($scheduleTimeZone.Id)"
    Write-Host "Control now:   $($controlNow.ToString('o'))"
}
else {
    Write-Host "Control zone:  INVALID - $timeZoneError" -ForegroundColor Red
}

if (Test-Path $statePath) {
    try { $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $state = $null }
    Write-Host "Last attempt:  $([string](Get-Value $state 'LastAttemptUtc' 'not recorded'))"
    Write-Host "Last success:  $([string](Get-Value $state 'LastSuccessUtc' 'not recorded'))"
    Write-Host "Last result:   $([string](Get-Value $state 'LastResult' 'not recorded'))"
    Write-Host "Last exit:     $([string](Get-Value $state 'LastExitCode' 'not recorded'))"
} else { Write-Host "Scheduler state: no attempt recorded" }

if (Test-Path $heartbeatPath) {
    Write-Host "Heartbeat:     $([string](Get-Value $heartbeat 'Utc' 'unreadable')) UTC"
    $schedulerZoneId = [string](Get-Value $heartbeat 'TimeZoneId' '')
    $schedulerLocal = [string](Get-Value $heartbeat 'Local' '')
    $schedulerOffset = [string](Get-Value $heartbeat 'UtcOffset' '')
    if ([string]::IsNullOrWhiteSpace($schedulerZoneId)) {
        Write-Host "Scheduler TZ:  not recorded; restart the service after upgrading" -ForegroundColor Yellow
    }
    else {
        Write-Host "Scheduler TZ:  $schedulerZoneId"
        Write-Host "Scheduler now: $schedulerLocal (UTC offset $schedulerOffset)"
        if ($null -ne $scheduleTimeZone -and $schedulerZoneId -cne $scheduleTimeZone.Id) {
            Write-Host "WARNING: The active scheduler is using a different time zone. Restart or recreate the service before enabling delivery." -ForegroundColor Yellow
        }
    }
} else { Write-Host "Heartbeat:     missing" }

if ($Action -eq "Status" -and $null -eq $scheduleTimeZone) { exit 1 }
