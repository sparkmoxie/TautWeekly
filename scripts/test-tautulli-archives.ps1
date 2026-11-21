[CmdletBinding()]
param([string]$RendererPattern = '*')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}

foreach ($relative in @('platforms/windows', 'platforms/nas-docker/app', 'platforms/mac-docker/app') | Where-Object { $_ -like $RendererPattern }) {
    . (Join-Path $root "$relative/Library-Selection.ps1")
    . (Join-Path $root "$relative/User-Exclusions.ps1")
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root "$relative/TautWeekly.ps1"), [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "$relative renderer failed to parse"
    foreach ($name in @('Safe-Int','Safe-Int64','Get-OptionalStringProperty','Test-TautulliLocalUserId','Get-NewsletterUser','Get-UserExclusionReason','Get-UserSkipReason','Assert-TautWeeklyRecipientCurrent','Test-IncludedLibraryRow','Get-IncludedLibraryQueryScopes','Get-LatestReleaseQueryScopes','Initialize-TautWeeklyLibraryPolicy','Get-History','Get-RecentItems','Get-RecipientWatchedMovies')) {
        $definition = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true) | Select-Object -First 1
        Assert-True ($null -ne $definition) "$relative is missing $name"
        Invoke-Expression $definition.Extent.Text
    }
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }
    $ScriptRoot = Join-Path $root $relative
    $Config = [PSCustomObject]@{ ExcludedUserIds = @(); ExcludedEmails = @(); WatchedPercent = 85; UserEmailOverrides = [PSCustomObject]@{ '2' = 'fallback@example.com' } }
    $script:FixtureUser = [PSCustomObject]@{ user_id='2'; username='viewer'; friendly_name='Viewer'; email=''; is_active=1; deleted_user=0; is_archived=0; do_notify=1 }
    function Get-TautulliUser { param([string]$Id) $script:FixtureUser }
    $user = Get-NewsletterUser -Id '2'
    Assert-True ($user.IsArchived -eq 0 -and $user.DeliveryEmail -eq 'fallback@example.com' -and (Get-UserSkipReason -User $user) -eq '') "$relative active managed user lost compatibility"
    $script:FixtureUser.is_archived = 1
    $archived = Get-NewsletterUser -Id '2'
    Assert-True ($archived.IsArchived -eq 1 -and (Get-UserSkipReason -User $archived) -eq 'inactiveOrDeleted') "$relative archived production account remained eligible"
    Assert-True ((Get-UserExclusionReason -User $archived) -eq 'archivedUser') "$relative archived preview/test account remained eligible"
    $Config.ExcludedUserIds = @('2')
    Assert-True ((Get-UserExclusionReason -User $archived) -eq 'excludedUserId') "$relative archive status displaced saved exclusion precedence"
    $Config.ExcludedUserIds = @()
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user } "$relative stale preview eligibility bypassed a backend archive"
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user -Production } "$relative stale production eligibility bypassed a backend archive"
    $script:FixtureUser.is_archived = 0
    Assert-True ((Assert-TautWeeklyRecipientCurrent -User $archived -Production).IsArchived -eq 0) "$relative unarchive did not restore eligibility"
    $script:FixtureUser.PSObject.Properties.Remove('is_archived')
    Assert-True ((Get-UserSkipReason -User (Get-NewsletterUser -Id '2')) -eq '') "$relative v2.18 missing archive field became ineligible"
    $script:FixtureUser.is_active = 0
    Assert-True ((Get-UserExclusionReason -User (Get-NewsletterUser -Id '2')) -eq 'inactiveOrDeleted') "$relative inactive account remained eligible for personalized modes"
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user } "$relative stale preview eligibility bypassed inactive backend state"
    $script:FixtureUser.is_active = 1
    $script:FixtureUser.deleted_user = 1
    Assert-True ((Get-UserExclusionReason -User (Get-NewsletterUser -Id '2')) -eq 'inactiveOrDeleted') "$relative deleted account remained eligible for personalized modes"
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user } "$relative stale preview eligibility bypassed deleted backend state"
    $script:FixtureUser.deleted_user = 0
    $Config.UserEmailOverrides = [PSCustomObject]@{}
    Assert-True ((Assert-TautWeeklyRecipientCurrent -User $user).DeliveryEmail -eq '') "$relative active addressless previews became unavailable"
    $Config.UserEmailOverrides = [PSCustomObject]@{ '2' = 'fallback@example.com' }
    $selectableUsers = @(ConvertTo-TautWeeklySelectableUsers -DetailedUsers @(
        [PSCustomObject]@{user_id='2'; email='archived@example.com'; is_active=1; is_archived=1},
        [PSCustomObject]@{user_id='18446744073709551615'; email='active@example.com'; is_active=1},
        [PSCustomObject]@{user_id='0'; email='local@example.com'; is_active=1}
    ))
    Assert-True ($selectableUsers.Count -eq 2 -and @($selectableUsers | Where-Object Eligible).Count -eq 1 -and ($selectableUsers | Where-Object UserId -eq '2').IsArchived) "$relative CLI archive/numeric-ID eligibility drifted"

    $script:LiveLibraries = @(
        [PSCustomObject]@{ section_id='10'; section_name='Movies'; section_type='movie'; is_active=1 },
        [PSCustomObject]@{ section_id='20'; section_name='Same name'; section_type='show'; is_active=1 },
        [PSCustomObject]@{ section_id='30'; section_name='Same name'; section_type='movie'; is_active=1 },
        [PSCustomObject]@{ section_id='40'; section_name='Deleted'; section_type='movie'; is_active=1 }
    )
    $script:KnownLibraries = @(
        [PSCustomObject]@{ section_id='10'; section_name='Movies'; section_type='movie'; is_archived=0 },
        [PSCustomObject]@{ section_id='20'; section_name='Same name'; section_type='show'; is_archived=1 },
        [PSCustomObject]@{ section_id='30'; section_name='Same name'; section_type='movie'; is_archived=0 }
    )
    $script:TableOverride = $null
    $script:MachineId = 'current-fixture'
    function Read-FixtureLibraryEvidence {
        param($Command, $Parameters)
        if ($Command -eq 'get_server_identity') { return [PSCustomObject]@{ machine_identifier=$script:MachineId } }
        Assert-True ($Command -eq 'get_libraries_table' -and $Parameters.include_archived -eq 1 -and $Parameters.include_deleted -eq 1 -and $Parameters.start -eq 0 -and $Parameters.length -eq -1) 'Table lookup omitted flags or requested a partial page'
        if ($null -ne $script:TableOverride) { return $script:TableOverride }
        $data = @(foreach ($name in $script:KnownLibraries) {
            [PSCustomObject]@{
                section_id=[int]$name.section_id; section_type=$name.section_type; section_name=$name.section_name
                server_id='current-fixture'; is_active=1; is_archived=$name.is_archived
                deleted_section=Get-TautWeeklyLibraryObjectValue $name 'deleted_section' 0
            }
        })
        return [PSCustomObject]@{ recordsFiltered=$data.Count; recordsTotal=$data.Count; data=$data }
    }
    $libraries = @(ConvertTo-TautWeeklySelectableLibraries -LiveLibraries $script:LiveLibraries -KnownLibraries $script:KnownLibraries -Query ${function:Read-FixtureLibraryEvidence})
    Assert-True ((@($libraries | Where-Object Selectable | ForEach-Object SectionId) | Sort-Object) -join ',' -eq '10,30') "$relative live libraries bypassed the DB archive join"
    Assert-True (($libraries | Where-Object SectionId -eq '20').IsArchived -and -not ($libraries | Where-Object SectionId -eq '40').Selectable) "$relative archived/deleted library state was lost"
    $script:IncludedLibraryIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$script:IncludedLibraryIdSet.Add('10')
    [void]$script:IncludedLibraryIdSet.Add('20')
    $script:LibraryFilterEnabled = $true
    $script:Calls = New-Object 'System.Collections.Generic.List[object]'
    $script:FailLibraryNames = $false
    $script:UpstreamHistoryShape = $false
    $script:HistoryRows = @(
        [PSCustomObject]@{section_id='10'; user_id='2'; rating_key='active'; media_type='movie'; user_is_archived=0; library_is_archived=0; watched_status=1; percent_complete=100; guid=''; added_at=100},
        [PSCustomObject]@{section_id='10'; user_id='3'; rating_key='archived-user'; media_type='movie'; user_is_archived=1; library_is_archived=0; watched_status=1; percent_complete=100; guid=''; added_at=100},
        [PSCustomObject]@{section_id='20'; user_id='2'; rating_key='archived-library'; media_type='movie'; user_is_archived=0; library_is_archived=1; watched_status=1; percent_complete=100; guid=''; added_at=100},
        [PSCustomObject]@{section_id='30'; user_id='2'; rating_key='unselected'; media_type='movie'; user_is_archived=0; library_is_archived=0; watched_status=1; percent_complete=100; guid=''; added_at=100}
    )
    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters = @{})
        $script:Calls.Add([PSCustomObject]@{ Command=$Command; Parameters=$Parameters.Clone() })
        switch ($Command) {
            'get_libraries' { return $script:LiveLibraries }
            'get_library_names' { if ($script:FailLibraryNames) { throw 'DB discovery failed' }; return $script:KnownLibraries }
            'get_libraries_table' { return Read-FixtureLibraryEvidence $Command $Parameters }
            'get_server_identity' { return Read-FixtureLibraryEvidence $Command $Parameters }
            'get_history' {
                $rows = @($script:HistoryRows)
                if ($script:UpstreamHistoryShape) {
                    # Tautulli v2.18/v2.19 filters by the requested section in
                    # SQL, but does not project section_id into history rows.
                    # https://github.com/Tautulli/Tautulli/blob/v2.18.0/plexpy/datafactory.py#L328-L372
                    # https://github.com/Tautulli/Tautulli/blob/v2.19.0/plexpy/datafactory.py#L575-L620
                    if ($Parameters.ContainsKey('section_id')) {
                        $rows = @($rows | Where-Object { [string]$_.section_id -eq [string]$Parameters.section_id })
                    }
                    if ($Parameters.ContainsKey('user_id')) {
                        $rows = @($rows | Where-Object { [string]$_.user_id -eq [string]$Parameters.user_id })
                    }
                    $rows = @($rows | Select-Object -Property * -ExcludeProperty section_id)
                }
                $page = @($rows | Select-Object -Skip ([int]$Parameters.start) -First ([int]$Parameters.length))
                return [PSCustomObject]@{ data=$page; recordsFiltered=$rows.Count }
            }
            'get_recently_added' { return [PSCustomObject]@{ recently_added=$script:HistoryRows } }
            default { throw "Unexpected fixture command $Command" }
        }
    }
    # get_library_names has no server or activity fields. Its projection can
    # repeat a section ID, or hide the current row entirely if it was deleted.
    $originalKnown = $script:KnownLibraries
    $baseTable = Read-FixtureLibraryEvidence 'get_libraries_table' @{include_archived=1; include_deleted=1; start=0; length=-1}
    $stale = [PSCustomObject]@{ section_id=10; section_type='movie'; section_name='Old movies'; server_id='other-fixture'; is_active=0; is_archived=0; deleted_section=0 }
    $older = [PSCustomObject]@{ section_id=10; section_type='artist'; section_name='Old music'; server_id='older-fixture'; is_active=0; is_archived=1; deleted_section=0 }
    $outside = [PSCustomObject]@{ section_id=30; section_type='movie'; section_name='Conflicting'; server_id='other-fixture'; is_active=1; is_archived=0; deleted_section=0 }
    $retired = [PSCustomObject]@{ section_id=60; section_type='movie'; section_name='Retired'; server_id='other-fixture'; is_active=0; is_archived=1; deleted_section=0 }
    $data = @($stale, $older, $outside, $retired) + $baseTable.data
    $script:TableOverride = [PSCustomObject]@{ recordsFiltered=$data.Count; recordsTotal=$data.Count; data=$data }
    $script:KnownLibraries = @($data | Select-Object section_id,section_name,section_type,is_archived)
    $retiredChoice = Get-TautWeeklyLibraryRoster -Query ${function:Invoke-TautulliApi} | Where-Object SectionId -eq '60'
    Assert-True ($retiredChoice.IsArchived -and -not $retiredChoice.Selectable) "$relative a DB-only archive lost its label or became eligible"
    Initialize-TautWeeklyLibraryPolicy
    Assert-True ((@(Get-IncludedLibraryQueryScopes) -join ',') -eq '10') "$relative did not resolve the live movie row among stale rows"
    [void](Assert-TautWeeklyRecipientCurrent -User $user)
    $stale.is_active = 1
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user -Production } "$relative accepted two active server rows for a frozen section"
    Assert-Throws { Initialize-TautWeeklyLibraryPolicy } "$relative conflicting selection broadened to another library"
    $stale.is_active = 0
    Initialize-TautWeeklyLibraryPolicy
    $liveMovie = $baseTable.data[0]
    $script:KnownLibraries = @($script:KnownLibraries | Where-Object section_name -ne 'Movies')
    $liveMovie.deleted_section = 1
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user } "$relative a stale name masked deletion of the frozen current library"
    $script:KnownLibraries = @($script:KnownLibraries | Where-Object section_name -ne 'Old music')
    $older.deleted_section = 1
    Assert-Throws { Initialize-TautWeeklyLibraryPolicy } "$relative a solitary surviving inactive name masked a deleted current row"
    $older.deleted_section = 0
    $liveMovie.deleted_section = 0
    $script:KnownLibraries = @($data | Select-Object section_id,section_name,section_type,is_archived)
    Initialize-TautWeeklyLibraryPolicy
    $script:MachineId = $stale.server_id
    Assert-Throws { Initialize-TautWeeklyLibraryPolicy } "$relative an active row on the former server was trusted before Tautulli refreshed"
    $liveMovie.is_active = 0
    $stale.is_active = 1
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user } "$relative a server switch preserved eligibility for already rendered content"
    $script:MachineId = $liveMovie.server_id
    $liveMovie.is_active = 1
    $stale.is_active = 0
    $older.is_active = $null
    Assert-Throws { Initialize-TautWeeklyLibraryPolicy } "$relative a missing activity flag was treated as inactive"
    $older.is_active = 0
    $script:TableOverride.recordsFiltered++
    Assert-Throws { Initialize-TautWeeklyLibraryPolicy } "$relative an incomplete table was used as unique evidence"
    $script:TautWeeklyResultErrorCategory = 'render-failed'
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user } "$relative an incomplete table was accepted at delivery"
    Assert-True ($script:TautWeeklyResultErrorCategory -eq 'tautulli-unavailable') "$relative final table failure lost its Tautulli error category"
    $script:TableOverride.recordsFiltered--
    # Tautulli 2.18 omits archive/deletion flags and always filters deleted
    # table rows, so recordsTotal may exceed recordsFiltered.
    $script:TableOverride.data = @($data | Select-Object -Property * -ExcludeProperty is_archived,deleted_section)
    $script:TableOverride.recordsTotal++
    $script:KnownLibraries = @($data | Select-Object section_id,section_name,section_type)
    $legacyCollision = @(ConvertTo-TautWeeklySelectableLibraries -LiveLibraries $script:LiveLibraries -KnownLibraries $script:KnownLibraries -Query ${function:Read-FixtureLibraryEvidence})
    Assert-True (($legacyCollision | Where-Object SectionId -eq '10').Selectable -and -not ($legacyCollision | Where-Object SectionId -eq '30').Selectable) "$relative legacy collisions did not use current-server evidence"
    $script:TableOverride = $null
    $script:KnownLibraries = $originalKnown
    Initialize-TautWeeklyLibraryPolicy
    Assert-True ((@(Get-IncludedLibraryQueryScopes) -join ',') -eq '10' -and $script:IncludedLibraryIdSet.Contains('20')) "$relative unavailable saved library scope broadened or was rewritten"
    Assert-True ((@(Get-LatestReleaseQueryScopes) -join ',') -eq '10') "$relative quiet-week fallback included an archived library"
    $script:Calls.Clear()
    [void](Assert-TautWeeklyRecipientCurrent -User $user)
    Assert-True (($script:Calls.Command -join ',') -eq 'get_library_names,get_libraries_table,get_server_identity') "$relative final scope recheck repeated live library enumeration or omitted current server evidence"
    $script:KnownLibraries[0].is_archived = 1
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user -Production } "$relative a library archived during rendering remained deliverable"
    $script:KnownLibraries[0].is_archived = 0
    $script:KnownLibraries[0].section_type = 'show'
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user } "$relative a library type change during rendering was accepted"
    $script:KnownLibraries[0].section_type = 'movie'
    $script:KnownLibraries[0] | Add-Member -NotePropertyName deleted_section -NotePropertyValue 1
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user } "$relative a deleted library remained deliverable"
    $script:KnownLibraries[0].PSObject.Properties.Remove('deleted_section')
    $originalKnown = $script:KnownLibraries
    $script:KnownLibraries = @($script:KnownLibraries | Where-Object section_id -ne '10')
    Assert-Throws { Assert-TautWeeklyRecipientCurrent -User $user } "$relative a library missing from the current DB roster remained deliverable"
    $script:KnownLibraries = $originalKnown
    $script:KnownLibraries[1].is_archived = 0
    [void](Assert-TautWeeklyRecipientCurrent -User $user)
    Assert-True ((@(Get-IncludedLibraryQueryScopes) -join ',') -eq '10') "$relative library unarchive broadened the scope during a render"
    $script:KnownLibraries[1].is_archived = 1
    $weekly = @(Get-History -AfterDate '2026-11-01' -BeforeDate '2026-11-07')
    Assert-True ($weekly.Count -eq 1 -and $weekly[0].rating_key -eq 'active') "$relative explicit section exception leaked archived weekly history"
    $personal = @(Get-History -AfterDate '2026-11-01' -BeforeDate '2026-11-07' -ForUserId '2')
    Assert-True ($personal.Count -eq 1 -and $personal[0].rating_key -eq 'active') "$relative explicit user exception leaked archived weekly history"
    $recent = @(Get-RecentItems -StartEpoch 90 -EndEpochExclusive 110)
    Assert-True ($recent.Count -eq 2 -and @($recent | Where-Object section_id -ne '10').Count -eq 0) "$relative current content queried or accepted archived/unselected libraries"
    $watched = Get-RecipientWatchedMovies -ExpectedUserId '2'
    Assert-True ($watched.RatingKeys.ContainsKey('archived-library') -and -not $watched.RatingKeys.ContainsKey('archived-user') -and -not $watched.RatingKeys.ContainsKey('unselected')) "$relative exact-recipient historical evidence lost library/identity boundaries"
    foreach ($call in @($script:Calls | Where-Object { $_.Command -eq 'get_history' -and $_.Parameters.include_archived -eq 1 })) {
        Assert-True ($call.Parameters.user_id -eq '2' -and $call.Parameters.section_id -in @('10','20')) "$relative enabled archive history outside exact recipient/saved library scope"
    }
    $script:IncludedLibraryIdSet.Clear()
    [void]$script:IncludedLibraryIdSet.Add('20')
    Assert-Throws { Initialize-TautWeeklyLibraryPolicy } "$relative all-archived saved scope silently broadened"
    $script:FailLibraryNames = $true
    Assert-Throws { Initialize-TautWeeklyLibraryPolicy } "$relative DB archive discovery failure was silently ignored"
    $script:FailLibraryNames = $false
    $legacyLibraries = @($script:KnownLibraries | ForEach-Object { [PSCustomObject]@{ section_id=$_.section_id; section_name=$_.section_name; section_type=$_.section_type } })
    $legacySelection = @(ConvertTo-TautWeeklySelectableLibraries -LiveLibraries $script:LiveLibraries -KnownLibraries $legacyLibraries)
    Assert-True (@($legacySelection | Where-Object Selectable).Count -eq 3) "$relative v2.18 library rows without archive fields lost eligibility"
    $script:KnownLibraries[1].is_archived = 0
    Initialize-TautWeeklyLibraryPolicy
    Assert-True ((@(Get-IncludedLibraryQueryScopes) -join ',') -eq '20') "$relative library unarchive did not restore the saved selection"

    # Exercise the actual upstream history shape with no saved library filter.
    # v0.28.0 queried globally, then discarded every row for missing section_id.
    $script:LibraryFilterEnabled = $false
    $script:KnownLibraries[1].is_archived = 1
    Initialize-TautWeeklyLibraryPolicy
    $script:UpstreamHistoryShape = $true
    $script:Calls.Clear()
    $weekly = @(Get-History -AfterDate '2026-11-05' -BeforeDate '2026-11-11')
    Assert-True (($weekly | ForEach-Object rating_key | Sort-Object) -join ',' -eq 'active,unselected') "$relative upstream-shaped unfiltered history lost current activity"
    Assert-True (@($weekly | Where-Object { $null -ne $_.PSObject.Properties['section_id'] }).Count -eq 0) "$relative fixture invented section_id in the upstream response"
    Assert-True (-not (Test-IncludedLibraryRow -Row $weekly[0])) "$relative missing unscoped library evidence was accepted"
    $weeklyCalls = @($script:Calls | Where-Object Command -eq 'get_history')
    Assert-True (($weeklyCalls.Parameters.section_id | Sort-Object) -join ',' -eq '10,30') "$relative weekly history did not use frozen available sections"
    foreach ($call in $weeklyCalls) {
        Assert-True ($call.Parameters.after -eq '2026-11-05' -and $call.Parameters.before -eq '2026-11-12' -and $call.Parameters.start_date -eq '2026-11-05,2026-11-06,2026-11-07,2026-11-08,2026-11-09,2026-11-10,2026-11-11' -and $call.Parameters.include_activity -eq 0 -and $call.Parameters.include_archived -eq 0) "$relative weekly query lost reporting or archive boundaries"
    }
    $personal = @(Get-History -AfterDate '2026-11-05' -BeforeDate '2026-11-11' -ForUserId '2')
    Assert-True ($personal.Count -eq 2) "$relative exact-recipient upstream-shaped history lost activity"
    $script:LibraryFilterEnabled = $true
    $script:IncludedLibraryIdSet.Clear()
    [void]$script:IncludedLibraryIdSet.Add('10')
    [void]$script:IncludedLibraryIdSet.Add('20')
    $selected = @(Get-History -AfterDate '2026-11-05' -BeforeDate '2026-11-11' -ForUserId '2')
    Assert-True ($selected.Count -eq 1 -and $selected[0].rating_key -eq 'active') "$relative missing row section metadata broadened saved selections"
    $modernRows = $script:HistoryRows
    $script:HistoryRows = @(
        [PSCustomObject]@{ section_id=10; user_id=2; rating_key='legacy-active' },
        [PSCustomObject]@{ section_id=10; user_id=3; rating_key='other-recipient' },
        [PSCustomObject]@{ section_id=20; user_id=2; rating_key='legacy-archived-library' },
        [PSCustomObject]@{ section_id=30; user_id=2; rating_key='legacy-unselected' }
    )
    $legacyHistory = @(Get-History -AfterDate '2026-11-05' -BeforeDate '2026-11-11' -ForUserId '2')
    Assert-True ($legacyHistory.Count -eq 1 -and $legacyHistory[0].rating_key -eq 'legacy-active') "$relative v2.18 history without archive fields lost numeric identity or library/recipient boundaries"
    $script:HistoryRows = $modernRows

    # Keep the established page size and prove pagination is complete. Timings
    # are synthetic evidence only, never a claim about a user's database.
    $script:LibraryFilterEnabled = $false
    $script:HistoryRows = @(1..2105 | ForEach-Object { [PSCustomObject]@{ section_id='10'; user_id='2'; rating_key="movie-$_" } })
    $script:Calls.Clear()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $paged = @(Get-History -AfterDate '2026-11-01' -BeforeDate '2026-11-07')
    $timer.Stop()
    Assert-True ($paged.Count -eq 2105 -and $script:Calls.Count -eq 4) "$relative changed page size, omitted a current section, or truncated history"
    Assert-True ((@($script:Calls | Where-Object { $_.Parameters.section_id -eq '10' } | ForEach-Object { $_.Parameters.start }) -join ',') -eq '0,1000,2000') "$relative pagination offsets changed"
    Write-Host ("[PASS] {0}: archive/unarchive, stale recipient, upstream history shape, exact scopes, saved IDs; synthetic history 2105 rows / 4 scoped requests / {1} ms." -f $relative, $timer.ElapsedMilliseconds)
    Remove-Variable -Name AvailableLibraryIdSet -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name TautWeeklyFrozenLibraries -Scope Script -ErrorAction SilentlyContinue
}
