param(
    [ValidateSet("Status","Enable","Disable","ResetToday")]
    [string]$Action = "Status",
    [string]$DataRoot = $(if ($env:PLEXWEEKLY_DATA_DIR) { $env:PLEXWEEKLY_DATA_DIR } else { "/data" })
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$configPath = Join-Path $DataRoot "config.json"
$statePath = Join-Path $DataRoot "scheduler-state.json"
$heartbeatPath = Join-Path $DataRoot "scheduler-heartbeat.json"

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

if (-not (Test-Path $configPath)) { throw "config.json is missing. Run setup first." }
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

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
Write-Host "PLEXWEEKLY SCHEDULE STATUS" -ForegroundColor Cyan
Write-Host "Enabled:       $enabledValue"
Write-Host "Day/time:      $dayValue $timeValue"
Write-Host "Grace minutes: $graceValue"
Write-Host "Time zone:     $([string]$env:TZ)"
Write-Host "Container now: $(Get-Date -Format o)"

if (Test-Path $statePath) {
    try { $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $state = $null }
    Write-Host "Last attempt:  $([string](Get-Value $state 'LastAttemptUtc' 'not recorded'))"
    Write-Host "Last success:  $([string](Get-Value $state 'LastSuccessUtc' 'not recorded'))"
    Write-Host "Last result:   $([string](Get-Value $state 'LastResult' 'not recorded'))"
    Write-Host "Last exit:     $([string](Get-Value $state 'LastExitCode' 'not recorded'))"
} else { Write-Host "Scheduler state: no attempt recorded" }

if (Test-Path $heartbeatPath) {
    try { $heartbeat = Get-Content $heartbeatPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $heartbeat = $null }
    Write-Host "Heartbeat:     $([string](Get-Value $heartbeat 'Utc' 'unreadable')) UTC"
} else { Write-Host "Heartbeat:     missing" }
