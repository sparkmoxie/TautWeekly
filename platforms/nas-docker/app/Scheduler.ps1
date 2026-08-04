param(
    [string]$DataRoot = $(if ($env:PLEXWEEKLY_DATA_DIR) { $env:PLEXWEEKLY_DATA_DIR } else { "/data" })
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$configPath = Join-Path $DataRoot "config.json"
$statePath = Join-Path $DataRoot "scheduler-state.json"
$heartbeatPath = Join-Path $DataRoot "scheduler-heartbeat.json"
$logDir = Join-Path $DataRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logPath = Join-Path $logDir ("scheduler_{0}.log" -f (Get-Date -Format "yyyyMMdd"))

function Log([string]$Message, [string]$Level = "INFO") {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
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

Log "PlexWeekly scheduler started. TZ=$([string]$env:TZ); local time=$(Get-Date -Format o)."
$lastMissingConfigWarning = [DateTime]::MinValue

while ($true) {
    try {
        Save-Json ([ordered]@{
            Utc = [DateTime]::UtcNow.ToString("o")
            Local = (Get-Date).ToString("o")
            ProcessId = $PID
        }) $heartbeatPath

        if (-not (Test-Path $configPath)) {
            if (((Get-Date) - $lastMissingConfigWarning).TotalMinutes -ge 5) {
                Log "Waiting for /data/config.json. Run ./plexweekly.sh setup." "WARN"
                $lastMissingConfigWarning = Get-Date
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

        $now = Get-Date
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
        & /opt/plexweekly/bin/run-mode.sh SendAll --confirm-send-all
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
            Log "Scheduled SendAll did not start because another PlexWeekly operation held the lock." "ERROR"
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
