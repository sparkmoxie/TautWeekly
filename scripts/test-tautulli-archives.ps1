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
    $libraries = @(ConvertTo-TautWeeklySelectableLibraries -LiveLibraries $script:LiveLibraries -KnownLibraries $script:KnownLibraries)
    Assert-True ((@($libraries | Where-Object Selectable | ForEach-Object SectionId) | Sort-Object) -join ',' -eq '10,30') "$relative live libraries bypassed the DB archive join"
    Assert-True (($libraries | Where-Object SectionId -eq '20').IsArchived -and -not ($libraries | Where-Object SectionId -eq '40').Selectable) "$relative archived/deleted library state was lost"
    $script:IncludedLibraryIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$script:IncludedLibraryIdSet.Add('10')
    [void]$script:IncludedLibraryIdSet.Add('20')
    $script:LibraryFilterEnabled = $true
    $script:Calls = New-Object 'System.Collections.Generic.List[object]'
    $script:FailLibraryNames = $false
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
            'get_history' {
                $page = @($script:HistoryRows | Select-Object -Skip ([int]$Parameters.start) -First ([int]$Parameters.length))
                return [PSCustomObject]@{ data=$page; recordsFiltered=$script:HistoryRows.Count }
            }
            'get_recently_added' { return [PSCustomObject]@{ recently_added=$script:HistoryRows } }
            default { throw "Unexpected fixture command $Command" }
        }
    }
    Initialize-TautWeeklyLibraryPolicy
    Assert-True ((@(Get-IncludedLibraryQueryScopes) -join ',') -eq '10' -and $script:IncludedLibraryIdSet.Contains('20')) "$relative unavailable saved library scope broadened or was rewritten"
    Assert-True ((@(Get-LatestReleaseQueryScopes) -join ',') -eq '10') "$relative quiet-week fallback included an archived library"
    $script:Calls.Clear()
    [void](Assert-TautWeeklyRecipientCurrent -User $user)
    Assert-True ($script:Calls.Count -eq 1 -and $script:Calls[0].Command -eq 'get_library_names') "$relative final scope recheck repeated a live Plex enumeration"
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

    # Keep the established page size and prove pagination is complete. Timings
    # are synthetic evidence only, never a claim about a user's database.
    $script:LibraryFilterEnabled = $false
    $script:HistoryRows = @(1..2105 | ForEach-Object { [PSCustomObject]@{ section_id='10'; user_id='2'; rating_key="movie-$_" } })
    $script:Calls.Clear()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $paged = @(Get-History -AfterDate '2026-11-01' -BeforeDate '2026-11-07')
    $timer.Stop()
    Assert-True ($paged.Count -eq 2105 -and $script:Calls.Count -eq 3) "$relative changed page size or truncated history"
    Write-Host ("[PASS] {0}: archive/unarchive, stale recipient, explicit scope exceptions, saved IDs, old-server fields; synthetic history 2105 rows / 3 requests / {1} ms." -f $relative, $timer.ElapsedMilliseconds)
    Remove-Variable -Name AvailableLibraryIdSet -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name TautWeeklyCurrentLibraryTypes -Scope Script -ErrorAction SilentlyContinue
}
