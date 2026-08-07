[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$nasHelperPath = Join-Path $Root 'platforms/nas-docker/app/Schedule-Time.ps1'
$macHelperPath = Join-Path $Root 'platforms/mac-docker/app/Schedule-Time.ps1'
$nasHelper = [IO.File]::ReadAllText($nasHelperPath)
$macHelper = [IO.File]::ReadAllText($macHelperPath)
Assert-Equal $nasHelper $macHelper 'Container schedule-time helpers drifted.'

. $nasHelperPath
$isWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$berlinTimeZoneId = if ($isWindowsPlatform) { 'W. Europe Standard Time' } else { 'Europe/Berlin' }
$phoenixTimeZoneId = if ($isWindowsPlatform) { 'US Mountain Standard Time' } else { 'America/Phoenix' }
$summerUtc = [DateTimeOffset]::Parse(
    '2026-08-07T07:30:00Z',
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
)
$winterUtc = [DateTimeOffset]::Parse(
    '2026-01-09T08:30:00Z',
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal
)

$berlin = Get-TautWeeklyScheduleTimeZone -TimeZoneId $berlinTimeZoneId
$berlinSummer = Get-TautWeeklyScheduleNow -TimeZone $berlin -UtcNow $summerUtc
$berlinWinter = Get-TautWeeklyScheduleNow -TimeZone $berlin -UtcNow $winterUtc
Assert-Equal 'Friday' ([string]$berlinSummer.DayOfWeek) 'The converted schedule weekday is wrong.'
Assert-Equal '09:30' $berlinSummer.ToString('HH:mm') 'Summer schedule conversion fell back to UTC.'
Assert-Equal ([TimeSpan]::FromHours(2)) $berlinSummer.Offset 'Summer DST offset is wrong.'
Assert-Equal '09:30' $berlinWinter.ToString('HH:mm') 'Winter schedule conversion is wrong.'
Assert-Equal ([TimeSpan]::FromHours(1)) $berlinWinter.Offset 'Winter standard-time offset is wrong.'
$berlinSummerMidnightUtc = ConvertTo-TautWeeklyScheduleUtc -TimeZone $berlin -LocalTime ([DateTime]'2026-08-07T00:00:00')
$berlinWinterMidnightUtc = ConvertTo-TautWeeklyScheduleUtc -TimeZone $berlin -LocalTime ([DateTime]'2026-01-09T00:00:00')
Assert-Equal '2026-08-06T22:00:00Z' $berlinSummerMidnightUtc.ToString('yyyy-MM-ddTHH:mm:ssK') 'Summer newsletter boundary is wrong.'
Assert-Equal '2026-01-08T23:00:00Z' $berlinWinterMidnightUtc.ToString('yyyy-MM-ddTHH:mm:ssK') 'Winter newsletter boundary is wrong.'

$phoenix = Get-TautWeeklyScheduleTimeZone -TimeZoneId $phoenixTimeZoneId
$phoenixNow = Get-TautWeeklyScheduleNow -TimeZone $phoenix -UtcNow $summerUtc
Assert-Equal '00:30' $phoenixNow.ToString('HH:mm') 'Negative-offset schedule conversion is wrong.'
Assert-Equal ([TimeSpan]::FromHours(-7)) $phoenixNow.Offset 'Phoenix offset is wrong.'

$invalidFailedClosed = $false
try {
    [void](Get-TautWeeklyScheduleTimeZone -TimeZoneId 'Invalid/Not-A-Zone')
}
catch {
    $invalidFailedClosed = $_.Exception.Message -match 'refusing to fall back to UTC'
}
if (-not $invalidFailedClosed) {
    throw 'An invalid schedule timezone did not fail closed.'
}

$controlTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("tautweekly-schedule-test-" + [Guid]::NewGuid().ToString('N'))
$previousTimeZone = [string]$env:TZ
$previousAppRoot = [string]$env:TAUTWEEKLY_APP_DIR
try {
    New-Item -ItemType Directory -Path $controlTestRoot | Out-Null
    $configPath = Join-Path $controlTestRoot 'config.json'
    $heartbeatPath = Join-Path $controlTestRoot 'scheduler-heartbeat.json'
    [ordered]@{
        ScheduleEnabled = $false
        ScheduleDay = 'Friday'
        ScheduleTime = '09:30'
        ScheduleGraceMinutes = 60
    } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    [ordered]@{
        Utc = $summerUtc.ToString('o')
        Local = $phoenixNow.ToString('o')
        TimeZoneId = $phoenix.Id
        UtcOffset = $phoenixNow.Offset.ToString()
        ProcessId = 123
    } | ConvertTo-Json | Set-Content -LiteralPath $heartbeatPath -Encoding UTF8

    $env:TZ = $berlinTimeZoneId
    $env:TAUTWEEKLY_APP_DIR = Join-Path $Root 'platforms/nas-docker/app'
    $mismatchBlocked = $false
    try {
        & (Join-Path $env:TAUTWEEKLY_APP_DIR 'Schedule-Control.ps1') -Action Enable -DataRoot $controlTestRoot
    }
    catch {
        $mismatchBlocked = $_.Exception.Message -match 'active scheduler is using'
    }
    if (-not $mismatchBlocked) { throw 'Schedule enable accepted a control/scheduler timezone mismatch.' }
    $blockedConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $false ([bool]$blockedConfig.ScheduleEnabled) 'A rejected timezone mismatch still enabled delivery.'

    [ordered]@{
        Utc = $summerUtc.ToString('o')
        Local = $berlinSummer.ToString('o')
        TimeZoneId = $berlin.Id
        UtcOffset = $berlinSummer.Offset.ToString()
        ProcessId = 123
    } | ConvertTo-Json | Set-Content -LiteralPath $heartbeatPath -Encoding UTF8
    & (Join-Path $env:TAUTWEEKLY_APP_DIR 'Schedule-Control.ps1') -Action Enable -DataRoot $controlTestRoot
    $enabledConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $true ([bool]$enabledConfig.ScheduleEnabled) 'A matching active scheduler timezone was not enabled.'
}
finally {
    $env:TZ = $previousTimeZone
    $env:TAUTWEEKLY_APP_DIR = $previousAppRoot
    if (Test-Path -LiteralPath $controlTestRoot) {
        Remove-Item -LiteralPath $controlTestRoot -Recurse -Force
    }
}

foreach ($relative in @(
    'platforms/nas-docker/app/Scheduler.ps1',
    'platforms/mac-docker/app/Scheduler.ps1'
)) {
    $scheduler = [IO.File]::ReadAllText((Join-Path $Root $relative))
    if ($scheduler -notmatch 'Get-TautWeeklyScheduleNow -TimeZone \$scheduleTimeZone' -or
        $scheduler -notmatch 'TimeZoneId = \$scheduleTimeZone\.Id' -or
        $scheduler -match '\$now\s*=\s*Get-Date') {
        throw "Scheduler runtime does not use the explicit timezone contract: $relative"
    }
}

foreach ($relative in @(
    'platforms/nas-docker/app/TautWeekly.ps1',
    'platforms/mac-docker/app/TautWeekly.ps1'
)) {
    $renderer = [IO.File]::ReadAllText((Join-Path $Root $relative))
    if ($renderer -notmatch '\$Mode -eq ''SendAll''' -or
        $renderer -notmatch 'Get-TautWeeklyScheduleNow -TimeZone \$deliveryTimeZone' -or
        $renderer -notmatch 'ConvertTo-TautWeeklyScheduleUtc -TimeZone \$deliveryTimeZone' -or
        $renderer -match '\$windowEnd\s*=\s*\(Get-Date\)\.Date') {
        throw "SendAll does not share the scheduler timezone contract: $relative"
    }
}

foreach ($relative in @(
    'platforms/nas-docker/app/Schedule-Control.ps1',
    'platforms/mac-docker/app/Schedule-Control.ps1'
)) {
    $control = [IO.File]::ReadAllText((Join-Path $Root $relative))
    if ($control -notmatch '\$Action -eq "Enable"' -or
        $control -notmatch 'Get-Value \$heartbeat ''TimeZoneId''' -or
        $control -notmatch 'Restart or recreate the service before enabling delivery') {
        throw "Schedule enable does not verify the active scheduler timezone: $relative"
    }
}

Write-Host '[PASS] Scheduler and SendAll convert through the configured zone across DST, fail closed on invalid zones, and record the active scheduler zone.'
