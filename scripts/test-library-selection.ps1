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
    $content = [IO.File]::ReadAllText((Join-Path $root $relative))
    Assert-Equal -Name "$relative reads IncludedLibraryIds" -Actual ($content -match 'IncludedLibraryIds') -Expected $true
    $filterCalls = [regex]::Matches($content, 'Test-IncludedLibraryRow -Row \$row').Count
    Assert-Equal -Name "$relative filters history and both release feeds" -Actual $filterCalls -Expected 3
}

foreach ($name in @('Library-Selection.ps1', 'Manage-Library-Selection.ps1')) {
    $windowsContent = [IO.File]::ReadAllText((Join-Path $root "platforms/windows/$name"))
    foreach ($containerPath in @("platforms/nas-docker/app/$name", "platforms/mac-docker/app/$name")) {
        $containerContent = [IO.File]::ReadAllText((Join-Path $root $containerPath))
        Assert-Equal -Name "$containerPath matches the Windows shared source" -Actual ($containerContent -ceq $windowsContent) -Expected $true
    }
}

Write-Host 'Library-selection tests passed.' -ForegroundColor Green
