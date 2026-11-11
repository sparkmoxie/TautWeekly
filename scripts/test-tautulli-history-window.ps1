[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$PythonPath = 'python',
    [string[]]$RendererPaths = @('platforms/windows/TautWeekly.ps1', 'platforms/nas-docker/app/TautWeekly.ps1', 'platforms/mac-docker/app/TautWeekly.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}
function Get-FixtureTimeZone([string[]]$Ids) {
    foreach ($id in $Ids) { try { return [TimeZoneInfo]::FindSystemTimeZoneById($id) } catch {} }
    throw 'The history-window fixture requires a maintained New York time-zone database.'
}
function ConvertFrom-FixtureForm([object]$Form) {
    $values = @{}
    if ($Form -is [Collections.IDictionary]) {
        foreach ($key in $Form.Keys) { $values[[string]$key] = [string]$Form[$key] }
    } elseif ($null -ne $Form) {
        foreach ($part in ([string]$Form).TrimStart('?').Split('&')) {
            if (-not $part) { continue }
            $pair = $part.Split([char[]]@('='), 2, [StringSplitOptions]::None)
            $name = [Uri]::UnescapeDataString($pair[0].Replace('+', ' '))
            $values[$name] = if ($pair.Count -eq 2) { [Uri]::UnescapeDataString($pair[1].Replace('+', ' ')) } else { '' }
        }
    }
    return $values
}
function New-FixtureSession([string]$Key, [string]$Started, [int]$Seconds = 60, [string]$Group = '') {
    $stamp = [DateTimeOffset]::Parse($Started, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds()
    if (-not $Group) { $Group = $Key }
    [PSCustomObject]@{ rating_key=$Key; title=$Key; reference_id=$Group; group_id=([string]$stamp); started=$stamp; stopped=($stamp + $Seconds); user_id='18446744073709551615'; section_id='18446744073709551614'; watched_status=1.0; percent_complete=100.0; paused_counter=0 }
}

foreach ($relative in $RendererPaths) {
    & {
        param($relative)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $relative), [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "Renderer parse failed: $relative"
        foreach ($name in @('Safe-Int', 'Get-OptionalStringProperty', 'Build-TautulliUri', 'Invoke-TautulliApi', 'Test-IncludedLibraryRow', 'Get-IncludedLibraryQueryScopes', 'Get-History')) {
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
            Assert-True ($null -ne $definition) "Missing $name in $relative"
            Invoke-Expression $definition.Extent.Text
        }
        $Config = [PSCustomObject]@{ ApiKey='synthetic-history-key' }
        $TautulliBase = 'http://tautulli.invalid'
        $script:LibraryFilterEnabled = $true
        $script:IncludedLibraryIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [void]$script:IncludedLibraryIdSet.Add('18446744073709551614')
        $script:AvailableLibraryIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [void]$script:AvailableLibraryIdSet.Add('18446744073709551614')
        $script:ServerZone = Get-FixtureTimeZone @('America/New_York', 'Eastern Standard Time')
        $script:HistoryRequests = New-Object 'System.Collections.Generic.List[object]'
        $script:RawSessions = @()

        # Model the owning source, not TautWeekly's intended date behavior:
        # v2.18/v2.19 webserve.get_history creates inclusive midnight after/
        # before predicates and a server-local start_date predicate. The SQL
        # WHERE runs before GROUP BY reference_id and pagination. See:
        # https://github.com/Tautulli/Tautulli/blob/v2.19.0/plexpy/webserve.py
        # https://github.com/Tautulli/Tautulli/blob/v2.19.0/plexpy/datatables.py
        function Invoke-RestMethod {
            param($Uri, $Headers, $MaximumRedirection, $Method, $TimeoutSec, $Body, $ContentType)
            $query = ConvertFrom-FixtureForm ([Uri]$Uri).Query
            $parameters = ConvertFrom-FixtureForm $Body
            foreach ($name in $query.Keys) { $parameters[$name] = $query[$name] }
            Assert-True ($parameters.cmd -eq 'get_history') 'Unexpected fixture API command'
            Assert-True ($Headers['X-Api-Key'] -eq 'synthetic-history-key' -and $MaximumRedirection -eq 0) 'History request lost scoped header security'
            Assert-True (-not $parameters.ContainsKey('apikey')) 'History request leaked a query/body credential'
            $script:HistoryRequests.Add([PSCustomObject]@{ Uri=[string]$Uri; Method=[string]$Method; Parameters=$parameters })
            $rows = @($script:RawSessions)
            foreach ($boundary in @('after', 'before')) {
                if (-not $parameters.ContainsKey($boundary)) { continue }
                $local = [DateTime]::ParseExact($parameters[$boundary], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                $utc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($local, [DateTimeKind]::Unspecified), $script:ServerZone)
                $epoch = ([DateTimeOffset]$utc).ToUnixTimeSeconds()
                if ($boundary -eq 'after') { $rows = @($rows | Where-Object { $_.started -ge $epoch }) }
                else { $rows = @($rows | Where-Object { $_.started -le $epoch }) }
            }
            if ($parameters.ContainsKey('start_date')) {
                $dates = $parameters.start_date.Split(',')
                $rows = @($rows | Where-Object {
                    $serverDate = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeSeconds($_.started), $script:ServerZone).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                    $dates -contains $serverDate
                })
            }
            if ($parameters.ContainsKey('user_id')) { $rows = @($rows | Where-Object { [string]$_.user_id -eq $parameters.user_id }) }
            if ($parameters.ContainsKey('section_id')) { $rows = @($rows | Where-Object { [string]$_.section_id -eq $parameters.section_id }) }
            $grouped = @($rows | Group-Object reference_id | ForEach-Object {
                $sessions = @($_.Group | Sort-Object started)
                $seconds = 0L
                foreach ($session in $sessions) { $seconds += $session.stopped - $session.started }
                # Upstream history has no section_id in its projected rows.
                [PSCustomObject]@{ rating_key=$sessions[0].rating_key; title=$sessions[-1].title; reference_id=$sessions[0].reference_id; group_ids=($sessions.group_id -join ','); user_id=$sessions[0].user_id; media_type='movie'; started=$sessions[0].started; date=$sessions[-1].started; stopped=($sessions.stopped | Measure-Object -Maximum).Maximum; group_count=$sessions.Count; duration=$seconds; play_duration=$seconds; paused_counter=0; watched_status=($sessions.watched_status | Measure-Object -Maximum).Maximum; percent_complete=($sessions.percent_complete | Measure-Object -Maximum).Maximum; user_is_archived=0; library_is_archived=0 }
            } | Sort-Object rating_key)
            $page = @($grouped | Select-Object -Skip ([int]$parameters.start) -First ([int]$parameters.length))
            return [PSCustomObject]@{ response=[PSCustomObject]@{ result='success'; data=[PSCustomObject]@{ data=$page; recordsFiltered=$grouped.Count } } }
        }

        $script:RawSessions = @(
            (New-FixtureSession 'outside-before' '2026-11-04T23:59:59-05:00'),
            (New-FixtureSession 'first-midnight' '2026-11-05T00:00:00-05:00'),
            (New-FixtureSession 'run-midnight' '2026-11-11T00:00:00-05:00'),
            (New-FixtureSession 'run-noon' '2026-11-11T12:00:00-05:00'),
            (New-FixtureSession 'run-final-second' '2026-11-11T23:59:59-05:00'),
            (New-FixtureSession 'outside-next-midnight' '2026-11-12T00:00:00-05:00'),
            (New-FixtureSession 'group-start' '2026-11-04T23:59:00-05:00' 61 'start-edge'),
            (New-FixtureSession 'group-start' '2026-11-05T00:00:00-05:00' 62 'start-edge'),
            (New-FixtureSession 'group-end' '2026-11-11T23:59:00-05:00' 70 'end-edge'),
            (New-FixtureSession 'group-end' '2026-11-12T00:00:00-05:00' 80 'end-edge')
        )
        $other = New-FixtureSession 'other-user' '2026-11-11T12:00:00-05:00'; $other.user_id = '2'
        $unselected = New-FixtureSession 'unselected' '2026-11-11T12:00:00-05:00'; $unselected.section_id = '20'
        $script:RawSessions += @($other, $unselected)
        $weekly = @(Get-History -AfterDate '2026-11-05' -BeforeDate '2026-11-11' -ForUserId '18446744073709551615')
        Assert-True (($weekly.rating_key -join ',') -eq 'first-midnight,group-end,group-start,run-final-second,run-midnight,run-noon') "$relative lost first/run-day activity or included an outside date/recipient/library"
        Assert-True (($weekly | Where-Object rating_key -eq 'group-start').play_duration -eq 62 -and ($weekly | Where-Object rating_key -eq 'group-end').play_duration -eq 70) "$relative filtered resumed sessions after grouping"
        $request = $script:HistoryRequests[0]
        Assert-True ($request.Method -eq 'Post' -and $request.Uri -eq 'http://tautulli.invalid/api/v2?cmd=get_history') "$relative put history dates in the URL instead of the POST body"
        Assert-True ($request.Parameters.include_activity -eq '0' -and $request.Parameters.include_archived -eq '0') "$relative changed live/archive boundaries"

        $oneDay = @(Get-History -AfterDate '2026-11-11' -BeforeDate '2026-11-11' -ForUserId '18446744073709551615')
        Assert-True (($oneDay.rating_key -join ',') -eq 'group-end,run-final-second,run-midnight,run-noon') "$relative single-day history omitted run-day activity"
        # DST repeats 01:30 with two different offsets. Both belong to the
        # server's Nov 1 even when the renderer host uses a different zone.
        $script:RawSessions = @(
            (New-FixtureSession 'dst-first' '2026-11-01T01:30:00-04:00'),
            (New-FixtureSession 'dst-repeat' '2026-11-01T01:30:00-05:00'),
            (New-FixtureSession 'server-day-end' '2026-11-01T23:59:59-05:00'),
            (New-FixtureSession 'server-next-day' '2026-11-02T00:00:00-05:00')
        )
        $dst = @(Get-History -AfterDate '2026-11-01' -BeforeDate '2026-11-01' -ForUserId '18446744073709551615')
        Assert-True (($dst.rating_key -join ',') -eq 'dst-first,dst-repeat,server-day-end') "$relative used fixed-hour or renderer-local boundaries across DST"
        $script:RawSessions = @(
            (New-FixtureSession 'spring-midnight' '2026-03-08T00:00:00-05:00'),
            (New-FixtureSession 'spring-before-gap' '2026-03-08T01:59:59-05:00'),
            (New-FixtureSession 'spring-after-gap' '2026-03-08T03:00:00-04:00'),
            (New-FixtureSession 'spring-final-second' '2026-03-08T23:59:59-04:00'),
            (New-FixtureSession 'spring-next-day' '2026-03-09T00:00:00-04:00')
        )
        $spring = @(Get-History -AfterDate '2026-03-08' -BeforeDate '2026-03-08' -ForUserId '18446744073709551615')
        Assert-True (($spring.rating_key -join ',') -eq 'spring-after-gap,spring-before-gap,spring-final-second,spring-midnight') "$relative lost or broadened the 23-hour spring-forward day"

        $script:RawSessions = @(1..1001 | ForEach-Object { New-FixtureSession ('paged-{0:D4}' -f $_) '2026-11-11T12:00:00-05:00' })
        $script:HistoryRequests.Clear()
        $paged = @(Get-History -AfterDate '2026-11-05' -BeforeDate '2026-11-11' -ForUserId '18446744073709551615')
        Assert-True ($paged.Count -eq 1001 -and (($script:HistoryRequests.Parameters.start -join ',') -eq '0,1000')) "$relative lost scoped history pagination"
        $script:RawSessions = @()
        $script:HistoryRequests.Clear()
        $last = [DateTime]::ParseExact('2026-11-11', 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $first = $last.AddDays(-3649).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        [void](Get-History -AfterDate $first -BeforeDate '2026-11-11')
        $longDates = New-Object 'System.Collections.Generic.List[string]'
        foreach ($long in $script:HistoryRequests) {
            $chunkDates = $long.Parameters.start_date.Split(',')
            Assert-True ($chunkDates.Count -le 365 -and $long.Uri.Length -lt 100) "$relative exceeded safe SQLite date chunks or grew the URI"
            foreach ($date in $chunkDates) { $longDates.Add($date) }
        }
        Assert-True ($script:HistoryRequests.Count -eq 10 -and $longDates.Count -eq 3650 -and @($longDates | Select-Object -Unique).Count -eq 3650 -and $longDates[0] -eq $first -and $longDates[-1] -eq '2026-11-11') "$relative maximum window overlapped or omitted dates"
        $sqlRequestPath = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-history-sql-' + [Guid]::NewGuid().ToString('N') + '.json')
        try {
            $sqlRequests = @($script:HistoryRequests | ForEach-Object { $_.Parameters })
            $sqlRequestJson = ConvertTo-Json -InputObject $sqlRequests -Depth 5 -Compress
            [IO.File]::WriteAllText($sqlRequestPath, $sqlRequestJson, [Text.UTF8Encoding]::new($false))
            & $PythonPath (Join-Path $PSScriptRoot 'test-support/assert-history-date-sql.py') $sqlRequestPath
            Assert-True ($LASTEXITCODE -eq 0) "$relative history dates failed the real SQLite expression/variable limits"
        }
        finally {
            [IO.File]::Delete($sqlRequestPath)
        }

        # One resumed play crosses the 365-date query boundary. Recombining
        # query fragments must preserve one grouped play and decimal maxima.
        $chunkStart = $last.AddDays(-365)
        $leftDate = $chunkStart.AddDays(364).ToString('yyyy-MM-dd')
        $rightDate = $chunkStart.AddDays(365).ToString('yyyy-MM-dd')
        $left = New-FixtureSession 'chunk-resume' ($leftDate + 'T23:50:00-05:00') 120 '50001'
        $left.watched_status = 0.5; $left.percent_complete = 50.0; $left.group_id = '601'; $left.title = 'Older metadata'
        $right = New-FixtureSession 'chunk-resume' ($rightDate + 'T00:10:00-05:00') 180 '50001'
        $right.watched_status = 0.75; $right.percent_complete = 75.0; $right.group_id = '602'; $right.title = 'Latest metadata'
        $script:RawSessions = @($left, $right)
        $resumed = @(Get-History -AfterDate $chunkStart.ToString('yyyy-MM-dd') -BeforeDate '2026-11-11' -ForUserId '18446744073709551615')
        Assert-True ($resumed.Count -eq 1 -and $resumed[0].group_count -eq 2 -and $resumed[0].play_duration -eq 300) "$relative split a resumed group or lost its duration across date chunks"
        Assert-True ($resumed[0].watched_status -eq 0.75 -and $resumed[0].percent_complete -eq 75.0) "$relative rounded partial watched evidence or lost its maximum"
        Assert-True ([string]$resumed[0].user_id -ceq '18446744073709551615' -and [string]$resumed[0].reference_id -ceq '50001') "$relative changed exact numeric group/user identity"
        Assert-True ($resumed[0].duration -eq 300 -and $resumed[0].group_ids -ceq '601,602' -and $resumed[0].started -eq $left.started -and $resumed[0].date -eq $right.started -and $resumed[0].stopped -eq $right.stopped -and $resumed[0].title -ceq 'Latest metadata') "$relative lost group-ID union, date bounds, or newest metadata when merging chunks"
        $left.user_id = '0'; $right.user_id = '0'
        $localGlobal = @(Get-History -AfterDate $chunkStart.ToString('yyyy-MM-dd') -BeforeDate '2026-11-11')
        Assert-True ($localGlobal.Count -eq 1 -and [string]$localGlobal[0].user_id -ceq '0' -and $localGlobal[0].group_count -eq 2 -and $localGlobal[0].play_duration -eq 300) "$relative lost scoped Local global-history compatibility in a long window"
        $right.group_id = '601'
        Assert-Throws { Get-History -AfterDate $chunkStart.ToString('yyyy-MM-dd') -BeforeDate '2026-11-11' } "$relative double-counted overlapping session IDs across disjoint date chunks"
        $right.group_id = '602'; $right.reference_id = ''
        Assert-Throws { Get-History -AfterDate $chunkStart.ToString('yyyy-MM-dd') -BeforeDate '2026-11-11' } "$relative merged a long-window row without stable group identity"
        foreach ($invalid in @(@('2026-11-12', '2026-11-11'), @('11/05/2026', '2026-11-11'), @($last.AddDays(-3650).ToString('yyyy-MM-dd'), '2026-11-11'))) {
            Assert-Throws { Get-History -AfterDate $invalid[0] -BeforeDate $invalid[1] } "$relative accepted an invalid or oversized reporting window"
        }
        Write-Host "[PASS] $relative inclusive dates/DST, pre-group filtering, exact scopes, pagination, SQLite-safe chunks, and resumed-group merging."
        Remove-Variable -Name AvailableLibraryIdSet -Scope Script -ErrorAction SilentlyContinue
    } $relative
}
