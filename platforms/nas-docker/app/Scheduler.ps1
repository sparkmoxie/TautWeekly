param(
    [string]$DataRoot = $(if ($env:TAUTWEEKLY_DATA_DIR) { $env:TAUTWEEKLY_DATA_DIR } else { "/data" })
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$configPath = Join-Path $DataRoot "config.json"
$appRoot = if ($env:TAUTWEEKLY_APP_DIR) { [string]$env:TAUTWEEKLY_APP_DIR } else { $PSScriptRoot }
. (Join-Path $appRoot "Schedule-Time.ps1")
$scheduleTimeZone = Get-TautWeeklyScheduleTimeZone
$initialScheduleNow = Get-TautWeeklyScheduleNow -TimeZone $scheduleTimeZone
$runModePath = Join-Path (Join-Path $appRoot "bin") "run-mode.sh"
$statePath = Join-Path $DataRoot "scheduler-state.json"
$heartbeatPath = Join-Path $DataRoot "scheduler-heartbeat.json"
$logDir = Join-Path $DataRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logPath = Join-Path $logDir ("scheduler_{0}.log" -f $initialScheduleNow.ToString("yyyyMMdd"))

function Log([string]$Message, [string]$Level = "INFO") {
    $localNow = Get-TautWeeklyScheduleNow -TimeZone $scheduleTimeZone
    $line = "{0} [{1}] {2}" -f $localNow.ToString("yyyy-MM-dd HH:mm:ss zzz"), $Level, $Message
    Add-Content -Path $logPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Save-Json([object]$Value, [string]$Path) {
    $temp = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 8 | Set-Content -Path $temp -Encoding UTF8
    Move-Item -Path $temp -Destination $Path -Force
}

function Get-ConfigValue {
    param([object]$Config, [string]$Name, [object]$Default)
    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    if ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $Default }
    return $property.Value
}

function Add-MissingStateProperties([object]$State) {
    $defaults = [ordered]@{
        LastAttemptLocalDate = ""
        LastAttemptUtc = ""
        LastSuccessUtc = ""
        LastResult = "never"
        LastExitCode = $null
    }
    foreach ($name in $defaults.Keys) {
        if ($null -eq $State.PSObject.Properties[$name]) {
            $State | Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name]
        }
    }
    return $State
}

function Load-State {
    if (Test-Path $statePath) {
        try {
            $loaded = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            return (Add-MissingStateProperties $loaded)
        }
        catch { Log "scheduler-state.json was unreadable; recreating it." "WARN" }
    }
    return (Add-MissingStateProperties ([PSCustomObject]@{}))
}

Log "TautWeekly for Plex scheduler started. Configured TZ=$([string]$env:TZ); active time zone=$($scheduleTimeZone.Id); local time=$($initialScheduleNow.ToString('o'))."
$lastMissingConfigWarningUtc = [DateTimeOffset]::MinValue

while ($true) {
    try {
        $scheduleNow = Get-TautWeeklyScheduleNow -TimeZone $scheduleTimeZone
        Save-Json ([ordered]@{
            Utc = [DateTimeOffset]::UtcNow.ToString("o")
            Local = $scheduleNow.ToString("o")
            TimeZoneId = $scheduleTimeZone.Id
            UtcOffset = $scheduleNow.Offset.ToString()
            ProcessId = $PID
        }) $heartbeatPath

        if (-not (Test-Path $configPath)) {
            if (([DateTimeOffset]::UtcNow - $lastMissingConfigWarningUtc).TotalMinutes -ge 5) {
                $misplacedConfig = Join-Path $appRoot "config.json"
                if (Test-Path $misplacedConfig) {
                    Log "Found a non-persistent config at $misplacedConfig, but the scheduler only reads $configPath. Run ./tautweekly.sh setup from the Compose directory or Setup-First.ps1 from the container Console." "WARN"
                }
                else {
                    Log "Waiting for $configPath. From the Compose directory run ./tautweekly.sh setup; from an Unraid container Console run pwsh -NoLogo -NoProfile -File /opt/tautweekly/Setup-First.ps1." "WARN"
                }
                $lastMissingConfigWarningUtc = [DateTimeOffset]::UtcNow
            }
            Start-Sleep -Seconds 30
            continue
        }

        $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $pollSeconds = [int](Get-ConfigValue $config "SchedulerPollSeconds" 30)
        if ($pollSeconds -lt 10 -or $pollSeconds -gt 300) { $pollSeconds = 30 }

        $enabled = [bool](Get-ConfigValue $config "ScheduleEnabled" $false)
        if (-not $enabled) {
            Start-Sleep -Seconds $pollSeconds
            continue
        }

        $day = [string](Get-ConfigValue $config "ScheduleDay" "Friday")
        $timeText = [string](Get-ConfigValue $config "ScheduleTime" "09:30")
        $graceMinutes = [int](Get-ConfigValue $config "ScheduleGraceMinutes" 60)
        if ($graceMinutes -lt 1 -or $graceMinutes -gt 720) { $graceMinutes = 60 }

        $now = (Get-TautWeeklyScheduleNow -TimeZone $scheduleTimeZone).DateTime
        if ([string]$now.DayOfWeek -ine $day) {
            Start-Sleep -Seconds $pollSeconds
            continue
        }

        $parsedTime = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact($timeText, "HH:mm", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedTime)) {
            Log "Invalid ScheduleTime '$timeText'; scheduler is paused until config is corrected." "ERROR"
            Start-Sleep -Seconds 300
            continue
        }

        $scheduled = $now.Date.AddHours($parsedTime.Hour).AddMinutes($parsedTime.Minute)
        $windowEnds = $scheduled.AddMinutes($graceMinutes)
        if ($now -lt $scheduled -or $now -ge $windowEnds) {
            Start-Sleep -Seconds $pollSeconds
            continue
        }

        $todayKey = $now.ToString("yyyy-MM-dd")
        $state = Load-State
        if ([string]$state.LastAttemptLocalDate -eq $todayKey) {
            Start-Sleep -Seconds $pollSeconds
            continue
        }

        # Mark the attempt BEFORE sending. A partial SMTP failure will therefore
        # never cause an automatic same-day retry and duplicate earlier recipients.
        $state.LastAttemptLocalDate = $todayKey
        $state.LastAttemptUtc = [DateTime]::UtcNow.ToString("o")
        $state.LastResult = "running"
        $state.LastExitCode = $null
        Save-Json $state $statePath

        Log "Scheduled send window reached. Beginning one guarded SendAll attempt."
        & $runModePath SendAll --confirm-send-all
        $exitCode = $LASTEXITCODE

        $state = Load-State
        $state.LastExitCode = $exitCode
        if ($exitCode -eq 0) {
            $state.LastResult = "success"
            $state.LastSuccessUtc = [DateTime]::UtcNow.ToString("o")
            Log "Scheduled SendAll completed successfully."
        }
        elseif ($exitCode -eq 75) {
            $state.LastResult = "blocked-by-active-lock"
            Log "Scheduled SendAll did not start because another TautWeekly for Plex operation held the lock." "ERROR"
        }
        else {
            $state.LastResult = "failed"
            Log "Scheduled SendAll exited with code $exitCode. Automatic retry is suppressed for safety; inspect logs and reset explicitly if needed." "ERROR"
        }
        Save-Json $state $statePath
    }
    catch {
        Log "Scheduler loop error: $($_.Exception.Message)" "ERROR"
    }

    Start-Sleep -Seconds 30
}
