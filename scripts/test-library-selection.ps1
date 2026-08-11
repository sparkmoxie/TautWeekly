[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'platforms/windows/Library-Selection.ps1')

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected
    )

    if ([string]$Actual -ne [string]$Expected) {
        throw "$Name expected '$Expected' but received '$Actual'."
    }
    Write-Host "[PASS] $Name"
}

$libraries = @(
    [PSCustomObject]@{ SectionId = '10'; Name = 'Movies'; Type = 'movie'; ItemCount = '100'; IsActive = $true; Selectable = $true },
    [PSCustomObject]@{ SectionId = '20'; Name = 'Family Movies'; Type = 'movie'; ItemCount = '40'; IsActive = $true; Selectable = $true },
    [PSCustomObject]@{ SectionId = '30'; Name = 'Television'; Type = 'show'; ItemCount = '70'; IsActive = $true; Selectable = $true },
    [PSCustomObject]@{ SectionId = '40'; Name = 'Music'; Type = 'artist'; ItemCount = '50'; IsActive = $true; Selectable = $false },
    [PSCustomObject]@{ SectionId = '50'; Name = 'Archived'; Type = 'movie'; ItemCount = '5'; IsActive = $false; Selectable = $false }
)

$defaultIds = @(Get-TautWeeklyEffectiveLibraryIds -Libraries $libraries)
Assert-Equal -Name 'Empty configuration preserves legacy all-video scope' -Actual ($defaultIds -join ',') -Expected '10,20,30'

$explicitIds = @(Get-TautWeeklyEffectiveLibraryIds -Libraries $libraries -ConfiguredLibraryIds @('20', '30', '20'))
Assert-Equal -Name 'Explicit IDs are normalized and retained' -Actual ($explicitIds -join ',') -Expected '20,30'

$rows = ConvertFrom-TautWeeklyLibrarySelection -Selection '1,3' -Libraries $libraries
Assert-Equal -Name 'Rows replace the global scope' -Actual (@($rows.LibraryIds) -join ',') -Expected '10,30'

$range = ConvertFrom-TautWeeklyLibrarySelection -Selection '2-3,3' -Libraries $libraries
Assert-Equal -Name 'Ranges and duplicate rows are normalized' -Actual (@($range.LibraryIds) -join ',') -Expected '20,30'

$all = ConvertFrom-TautWeeklyLibrarySelection -Selection 'all' -Libraries $libraries -CurrentIncludedLibraryIds @('20')
Assert-Equal -Name 'all selects every active movie and TV library' -Actual (@($all.LibraryIds) -join ',') -Expected '10,20,30'

$keep = ConvertFrom-TautWeeklyLibrarySelection -Selection '' -Libraries $libraries -CurrentIncludedLibraryIds @('20')
Assert-Equal -Name 'Blank selection keeps the current scope' -Actual (@($keep.LibraryIds) -join ',') -Expected '20'

$staleOnly = ConvertFrom-TautWeeklyLibrarySelection -Selection 'keep' -Libraries $libraries -CurrentIncludedLibraryIds @('999')
Assert-Equal -Name 'A stale-only current scope cannot be kept' -Actual ([bool]$staleOnly.Valid) -Expected $false

$none = ConvertFrom-TautWeeklyLibrarySelection -Selection 'none' -Libraries $libraries
Assert-Equal -Name 'An empty global scope is rejected' -Actual ([bool]$none.Valid) -Expected $false

$outside = ConvertFrom-TautWeeklyLibrarySelection -Selection '4' -Libraries $libraries
Assert-Equal -Name 'Unsupported libraries are not selectable rows' -Actual ([bool]$outside.Valid) -Expected $false

$script:libraryApiCalls = New-Object System.Collections.Generic.List[string]
function Invoke-TautWeeklyLibraryApi {
    param([string]$TautulliUrl, [string]$ApiKey, [string]$Command, [hashtable]$Parameters = @{})
    $script:libraryApiCalls.Add($Command)
    return @(
        [PSCustomObject]@{ section_id = '7'; section_name = 'Films'; section_type = 'movie'; count = 12; is_active = 1 },
        [PSCustomObject]@{ section_id = '8'; section_name = 'Music'; section_type = 'artist'; count = 9; is_active = 1 },
        [PSCustomObject]@{ section_id = '9'; section_name = 'Old TV'; section_type = 'show'; count = 3; is_active = 0 }
    )
}
$discovered = @(Get-TautWeeklySelectableLibraries -TautulliUrl 'http://tautulli.example.test:8181' -ApiKey 'test-key')
Assert-Equal -Name 'Discovery uses the documented libraries endpoint' -Actual ($script:libraryApiCalls -join ',') -Expected 'get_libraries'
Assert-Equal -Name 'Discovery marks only active movie/show libraries selectable' -Actual (@($discovered | Where-Object Selectable).Count) -Expected 1

foreach ($relative in @(
    'platforms/windows/TautWeekly.ps1',
    'platforms/nas-docker/app/TautWeekly.ps1',
    'platforms/mac-docker/app/TautWeekly.ps1'
)) {
    $rendererPath = Join-Path $root $relative
    $content = [IO.File]::ReadAllText($rendererPath)
    Assert-Equal -Name "$relative reads IncludedLibraryIds" -Actual ($content -match 'IncludedLibraryIds') -Expected $true
    $filterCalls = [regex]::Matches($content, 'Test-IncludedLibraryRow -Row \$row').Count
    Assert-Equal -Name "$relative filters history and both release feeds" -Actual $filterCalls -Expected 3

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $rendererPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "Cannot execute the library predicate with parser errors: $relative"
    }

    foreach ($functionName in @(
        'Safe-Int',
        'Safe-Int64',
        'Get-OptionalStringProperty',
        'Get-DesignProviderRating',
        'Test-IncludedLibraryRow',
        'Get-IncludedLibraryQueryScopes',
        'Get-History',
        'Get-RecentItems',
        'New-ReleaseData',
        'Get-LatestReleaseData'
    )) {
        $definition = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        }, $true) | Select-Object -First 1
        if ($null -eq $definition) {
            throw "Missing $functionName in $relative"
        }
        Invoke-Expression $definition.Extent.Text
    }

    $script:LibraryFilterEnabled = $true
    $script:IncludedLibraryIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$script:IncludedLibraryIdSet.Add('10')
    Assert-Equal -Name "$relative includes a selected-library row at runtime" `
        -Actual (Test-IncludedLibraryRow -Row ([PSCustomObject]@{ section_id = '10' })) -Expected $true
    Assert-Equal -Name "$relative excludes an unselected-library row at runtime" `
        -Actual (Test-IncludedLibraryRow -Row ([PSCustomObject]@{ section_id = '99' })) -Expected $false
    Assert-Equal -Name "$relative excludes an unscoped row at runtime" `
        -Actual (Test-IncludedLibraryRow -Row ([PSCustomObject]@{ title = 'No section metadata' })) -Expected $false
    Assert-Equal -Name "$relative trusts missing row metadata from a selected scoped query" `
        -Actual (Test-IncludedLibraryRow `
            -Row ([PSCustomObject]@{ title = 'Scoped without section metadata' }) `
            -ExpectedSectionId '10') -Expected $true
    Assert-Equal -Name "$relative rejects an explicit mismatch from a selected scoped query" `
        -Actual (Test-IncludedLibraryRow `
            -Row ([PSCustomObject]@{ section_id = '20' }) `
            -ExpectedSectionId '10') -Expected $false
    Assert-Equal -Name "$relative rejects a missing row section for an unselected scoped query" `
        -Actual (Test-IncludedLibraryRow `
            -Row ([PSCustomObject]@{ title = 'Unselected scope' }) `
            -ExpectedSectionId '99') -Expected $false

    $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $selectedMovie = [PSCustomObject]@{
        section_id = '10'; media_type = 'movie'; rating_key = 'selected-movie'
        title = 'Selected Movie'; year = '2026'; added_at = $nowEpoch
        audience_rating = '91'; rating = '8.2'; summary = 'A selected-library release.'
        play_duration = 7200; watched_status = 1; percent_complete = 100
    }
    $selectedEpisode = [PSCustomObject]@{
        section_id = '20'; media_type = 'episode'; rating_key = 'selected-episode'
        grandparent_rating_key = 'selected-show'; grandparent_title = 'Selected Show'
        title = 'Selected Episode'; year = '2026'; added_at = $nowEpoch
        parent_media_index = 1; media_index = 1; play_duration = 1800
    }
    $privateMovie = [PSCustomObject]@{
        section_id = '99'; media_type = 'movie'; rating_key = 'private-movie'
        title = 'Private Movie'; year = '2026'; added_at = $nowEpoch + 60
        audience_rating = '99'; rating = '9.9'; summary = 'Must never influence selected output.'
        play_duration = 10800; watched_status = 1; percent_complete = 100
    }
    [void]$script:IncludedLibraryIdSet.Add('20')

    $script:scopeCalls = New-Object System.Collections.Generic.List[string]
    $script:simulationPhase = 'normal'
    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters = @{})

        $scope = if ($Parameters.ContainsKey('section_id')) { [string]$Parameters.section_id } else { '' }
        $script:scopeCalls.Add("$Command`:$scope")

        if ([string]::IsNullOrWhiteSpace($scope)) {
            # This emulates a busy private library occupying every globally
            # paged result. A correctly scoped renderer never consumes it.
            $privatePage = @()
            for ($index = 0; $index -lt 100; $index++) { $privatePage += $privateMovie }
            if ($Command -eq 'get_history') {
                return [PSCustomObject]@{ data = @($privateMovie); recordsFiltered = 1 }
            }
            return [PSCustomObject]@{ recently_added = $privatePage }
        }

        if ($script:simulationPhase -eq 'latest' -and
            $Command -eq 'get_recently_added' -and
            $scope -eq '20') {
            $start = Safe-Int $Parameters.start
            if ($start -eq 0) {
                $firstPage = New-Object System.Collections.Generic.List[object]
                for ($index = 1; $index -le 99; $index++) {
                    $firstPage.Add([PSCustomObject]@{
                        media_type = 'episode'; rating_key = "selected-episode-$index"
                        grandparent_rating_key = 'selected-show'; grandparent_title = 'Selected Show'
                        title = "Selected Episode $index"; year = '2026'; added_at = $nowEpoch - $index
                        parent_media_index = 1; media_index = $index; play_duration = 1800
                    })
                }
                $firstPage.Add($privateMovie)
                return [PSCustomObject]@{ recently_added = $firstPage.ToArray() }
            }
            if ($start -eq 100) {
                $secondPage = @()
                foreach ($showNumber in 2..4) {
                    $secondPage += [PSCustomObject]@{
                        media_type = 'episode'; rating_key = "selected-show-$showNumber-episode"
                        grandparent_rating_key = "selected-show-$showNumber"; grandparent_title = "Selected Show $showNumber"
                        title = 'Premiere'; year = '2026'; added_at = $nowEpoch - (100 + $showNumber)
                        parent_media_index = 1; media_index = 1; play_duration = 1800
                    }
                }
                $secondPage += $privateMovie
                return [PSCustomObject]@{ recently_added = $secondPage }
            }
        }

        if ((Safe-Int $Parameters.start) -gt 0) {
            if ($Command -eq 'get_history') {
                return [PSCustomObject]@{ data = @(); recordsFiltered = 0 }
            }
            return [PSCustomObject]@{ recently_added = @() }
        }

        $selected = if ($scope -eq '10') { $selectedMovie } else { $selectedEpisode }
        $selectedRecent = if ($scope -eq '10') {
            [PSCustomObject]@{
                media_type = 'movie'; rating_key = 'selected-movie'
                title = 'Selected Movie'; year = '2026'; added_at = $nowEpoch
                audience_rating = '91'; rating = '8.2'; summary = 'A selected-library release.'
            }
        } else {
            [PSCustomObject]@{
                media_type = 'episode'; rating_key = 'selected-episode'
                grandparent_rating_key = 'selected-show'; grandparent_title = 'Selected Show'
                title = 'Selected Episode'; year = '2026'; added_at = $nowEpoch
                parent_media_index = 1; media_index = 1
            }
        }
        # Include a leaked private row to prove the client still fails closed
        # if a Tautulli version ignores or mishandles section_id.
        if ($Command -eq 'get_history') {
            return [PSCustomObject]@{ data = @($selected, $privateMovie); recordsFiltered = 2 }
        }
        if ($Command -eq 'get_recently_added') {
            # Tautulli's section-scoped recentlyAdded response can omit the
            # redundant librarySectionID/section_id field on valid rows.
            return [PSCustomObject]@{ recently_added = @($selectedRecent, $privateMovie) }
        }
        throw "Unexpected simulated command: $Command"
    }

    $history = @(Get-History -AfterDate '2026-08-01' -BeforeDate '2026-08-07')
    Assert-Equal -Name "$relative scopes history queries and rejects leaked private rows" `
        -Actual (($history | ForEach-Object rating_key) -join ',') -Expected 'selected-movie,selected-episode'

    $weekly = @(Get-RecentItems -StartEpoch ($nowEpoch - 3600) -EndEpochExclusive ($nowEpoch + 3600))
    Assert-Equal -Name "$relative prevents private-library crowd-out in weekly releases" `
        -Actual (($weekly | ForEach-Object rating_key) -join ',') -Expected 'selected-movie,selected-episode'

    $script:simulationPhase = 'latest'
    $latest = Get-LatestReleaseData -MovieLimit 4 -TvLimit 4
    Assert-Equal -Name "$relative prevents private-library crowd-out in quiet-week fallback" `
        -Actual ((@($latest.Movies.Title) + @($latest.TV.Title)) -join ',') `
        -Expected 'Selected Movie,Selected Show,Selected Show 2,Selected Show 3,Selected Show 4'

    $unscopedCalls = @($script:scopeCalls | Where-Object { $_ -match ':$' })
    Assert-Equal -Name "$relative sends no global media query when a library scope is configured" `
        -Actual $unscopedCalls.Count -Expected 0

    $scopes = @(
        $script:scopeCalls |
            ForEach-Object { ($_ -split ':', 2)[1] } |
            Sort-Object -Unique
    )
    Assert-Equal -Name "$relative queries every configured library" -Actual ($scopes -join ',') -Expected '10,20'

    $script:LibraryFilterEnabled = $false
    $script:scopeCalls.Clear()
    $legacyHistory = @(Get-History -AfterDate '2026-08-01' -BeforeDate '2026-08-07')
    Assert-Equal -Name "$relative preserves one global query for legacy empty scopes" `
        -Actual ($script:scopeCalls -join ',') -Expected 'get_history:'
    Assert-Equal -Name "$relative preserves legacy all-library history" `
        -Actual (($legacyHistory | ForEach-Object rating_key) -join ',') -Expected 'private-movie'
}

foreach ($name in @('Library-Selection.ps1', 'Manage-Library-Selection.ps1')) {
    $windowsContent = [IO.File]::ReadAllText((Join-Path $root "platforms/windows/$name"))
    foreach ($containerPath in @("platforms/nas-docker/app/$name", "platforms/mac-docker/app/$name")) {
        $containerContent = [IO.File]::ReadAllText((Join-Path $root $containerPath))
        Assert-Equal -Name "$containerPath matches the Windows shared source" -Actual ($containerContent -ceq $windowsContent) -Expected $true
    }
}

Write-Host 'Library-selection tests passed.' -ForegroundColor Green
