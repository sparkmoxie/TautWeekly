[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$nas = Join-Path $Root 'platforms/nas-docker/app/Runtime-Logs.ps1'
$mac = Join-Path $Root 'platforms/mac-docker/app/Runtime-Logs.ps1'
if ([IO.File]::ReadAllText($nas) -cne [IO.File]::ReadAllText($mac)) { throw 'Runtime log helpers drifted.' }
. $nas

function Assert-LogBound([string]$Directory, [int]$MaximumBytes = 64, [int]$MaximumFiles = 4) {
    $files = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object { $_.Name -match '^scheduler_\d{8}\.log(?:\.[1-9][0-9]*)?$' })
    if ($files.Count -gt $MaximumFiles) { throw "Retained $($files.Count) scheduler files; bound is $MaximumFiles." }
    $total = 0L
    foreach ($file in $files) {
        if ($file.Length -gt $MaximumBytes) { throw "Oversize scheduler file: $($file.Name)" }
        $total += $file.Length
    }
    if ($total -gt $MaximumBytes * $MaximumFiles) { throw 'Scheduler retained bytes exceeded their bound.' }
}

$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $temporaryParent ('tautweekly-runtime-logs-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $day = [DateTimeOffset]::Parse('2031-04-18T23:59:00-07:00')
    $logs = Join-Path $testRoot 'continuous'
    New-Item -ItemType Directory -Path $logs | Out-Null
    $unrelated = Join-Path $logs 'tautweekly_20200101.log'
    [IO.File]::WriteAllText($unrelated, 'private renderer install-age evidence')
    [IO.File]::WriteAllText((Join-Path $logs 'config.json'), 'unrelated private fixture')
    for ($index = 0; $index -lt 100; $index++) {
        Write-TautWeeklySchedulerLog -LogDirectory $logs -LocalNow $day -Line "fixture record $index" -MaximumBytes 64
        Assert-LogBound $logs
    }
    Write-Host '[PASS] Scheduler continuous session: 100 writes; <=4 files and <=256 retained bytes at a 64-byte test cap.'
    Write-TautWeeklySchedulerLog -LogDirectory $logs -LocalNow $day.AddMinutes(2) -Line 'new local day' -MaximumBytes 64
    if (-not (Test-Path -LiteralPath (Join-Path $logs 'scheduler_20310419.log'))) { throw 'Scheduler did not choose the current local date on a later write.' }
    Assert-LogBound $logs
    if ([IO.File]::ReadAllText($unrelated) -cne 'private renderer install-age evidence' -or
        [IO.File]::ReadAllText((Join-Path $logs 'config.json')) -cne 'unrelated private fixture') { throw 'Unrelated runtime files changed.' }

    $legacy = Join-Path $testRoot 'legacy'
    New-Item -ItemType Directory -Path $legacy | Out-Null
    $old = ('old fixture ' * 100)
    foreach ($name in @('scheduler_20200101.log', 'scheduler_20200101.log.1', 'scheduler_20200101.log.2')) {
        [IO.File]::WriteAllText((Join-Path $legacy $name), $old)
    }
    Write-TautWeeklySchedulerLog -LogDirectory $legacy -LocalNow $day -Line 'new fixture' -MaximumBytes 64
    Assert-LogBound $legacy
    $expectedTail = $old.Substring($old.Length - 64)
    if ([IO.File]::ReadAllText((Join-Path $legacy 'scheduler_20200101.log')) -cne $expectedTail) { throw 'Oversized legacy scheduler tail was lost.' }
    Write-TautWeeklySchedulerLog -LogDirectory $legacy -LocalNow $day -Line ('oversize fixture ' * 1000) -MaximumBytes 64
    Assert-LogBound $legacy

    $unsafe = Join-Path $testRoot 'unsafe'
    New-Item -ItemType Directory -Path $unsafe | Out-Null
    $target = Join-Path $testRoot 'private-fixture.json'
    [IO.File]::WriteAllText($target, 'must remain unchanged')
    $log = Join-Path $unsafe 'scheduler_20310418.log'
    New-Item -ItemType HardLink -Path $log -Target $target | Out-Null
    $refused = $false
    try { Write-TautWeeklySchedulerLog -LogDirectory $unsafe -LocalNow $day -Line 'not written' -MaximumBytes 64 }
    catch { $refused = $_.Exception.Message -match 'refuses links' }
    if (-not $refused -or [IO.File]::ReadAllText($target) -cne 'must remain unchanged') { throw 'Hard-linked scheduler log was not refused safely.' }
    Remove-Item -LiteralPath $log -Force
    New-Item -ItemType Directory -Path $log | Out-Null
    $refused = $false
    try { Write-TautWeeklySchedulerLog -LogDirectory $unsafe -LocalNow $day -Line 'not written' -MaximumBytes 64 }
    catch { $refused = $_.Exception.Message -match 'refuses links' }
    if (-not $refused) { throw 'Directory accepted as scheduler log.' }
    Remove-Item -LiteralPath $log -Force
    try { New-Item -ItemType SymbolicLink -Path $log -Target $target -ErrorAction Stop | Out-Null }
    catch { Write-Host '[SKIP] Scheduler symbolic-link creation is unavailable; hard-link and directory refusal were verified.' }
    if (Get-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue) {
        $refused = $false
        try { Write-TautWeeklySchedulerLog -LogDirectory $unsafe -LocalNow $day -Line 'not written' -MaximumBytes 64 }
        catch { $refused = $_.Exception.Message -match 'refuses links' }
        if (-not $refused) { throw 'Symbolic scheduler log was not refused safely.' }
    }

    # Execute each maintained Scheduler's actual Log function, without its loop.
    foreach ($relative in @('platforms/nas-docker/app/Scheduler.ps1', 'platforms/mac-docker/app/Scheduler.ps1')) {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $relative), [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw "Scheduler syntax failed: $relative" }
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Log' }, $true)
        . ([ScriptBlock]::Create($definition.Extent.Text))
        $script:TautWeeklySchedulerLogWarningShown = $false
        $script:fixtureNow = $day
        function Get-TautWeeklyScheduleNow { param($TimeZone) return $script:fixtureNow }
        $scheduleTimeZone = [TimeZoneInfo]::Utc
        $logDir = Join-Path $testRoot ('scheduler-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $logDir | Out-Null
        Log 'before midnight' *> $null
        $script:fixtureNow = $day.AddMinutes(2)
        Log 'after midnight' *> $null
        foreach ($date in @('20310418', '20310419')) {
            if (-not (Test-Path -LiteralPath (Join-Path $logDir "scheduler_$date.log"))) { throw "Scheduler $relative kept its startup date for later log writes." }
        }
        # A persistent-file failure must leave the scheduler's console path alive.
        $logDir = Join-Path $testRoot 'missing-directory'
        Log 'disk/file failure fixture' *> $null
        if (-not $script:TautWeeklySchedulerLogWarningShown) { throw 'Scheduler file failure did not use the console fallback.' }
    }
    Write-Host '[PASS] Runtime log rollover, legacy tails, oversize writes, unrelated files, link refusal, local midnight, and file-failure fallback.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\', '/') -ne $temporaryParent.TrimEnd('\', '/') -or
        -not [IO.Path]::GetFileName($resolved).StartsWith('tautweekly-runtime-logs-')) { throw 'Unsafe runtime-log test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
