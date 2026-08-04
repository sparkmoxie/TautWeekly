[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$windowsLibrary = Join-Path $root 'platforms/windows/User-Exclusions.ps1'
. $windowsLibrary

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

$users = @(
    [PSCustomObject]@{ UserId = '10'; FriendlyName = 'Alpha'; Username = 'alpha'; Email = 'alpha@example.com'; Eligible = $true },
    [PSCustomObject]@{ UserId = '20'; FriendlyName = 'Beta'; Username = 'beta'; Email = 'beta@example.com'; Eligible = $true },
    [PSCustomObject]@{ UserId = '30'; FriendlyName = 'Gamma'; Username = 'gamma'; Email = ''; Eligible = $false }
)

$keep = ConvertFrom-TautWeeklyExcludedSelection -Selection '' -Users $users -CurrentExcludedUserIds @('20', 'legacy')
Assert-Equal -Name 'Blank selection keeps current IDs' -Actual (@($keep.UserIds) -join ',') -Expected '20,legacy'

$clear = ConvertFrom-TautWeeklyExcludedSelection -Selection 'none' -Users $users -CurrentExcludedUserIds @('20', 'legacy')
Assert-Equal -Name 'none clears all IDs' -Actual (@($clear.UserIds) -join ',') -Expected ''

$replace = ConvertFrom-TautWeeklyExcludedSelection -Selection '1,3' -Users $users -CurrentExcludedUserIds @('20', 'legacy')
Assert-Equal -Name 'Rows replace known IDs and preserve unavailable IDs' -Actual (@($replace.UserIds) -join ',') -Expected 'legacy,10,30'

$range = ConvertFrom-TautWeeklyExcludedSelection -Selection '1-2,2' -Users $users
Assert-Equal -Name 'Ranges and duplicate rows are normalized' -Actual (@($range.UserIds) -join ',') -Expected '10,20'

$invalid = ConvertFrom-TautWeeklyExcludedSelection -Selection '0' -Users $users
Assert-Equal -Name 'Out-of-range rows are rejected' -Actual ([bool]$invalid.Valid) -Expected $false

$libraryPaths = @(
    $windowsLibrary,
    (Join-Path $root 'platforms/nas-docker/app/User-Exclusions.ps1'),
    (Join-Path $root 'platforms/mac-docker/app/User-Exclusions.ps1')
)
$managerPaths = @(
    (Join-Path $root 'platforms/windows/Manage-User-Exclusions.ps1'),
    (Join-Path $root 'platforms/nas-docker/app/Manage-User-Exclusions.ps1'),
    (Join-Path $root 'platforms/mac-docker/app/Manage-User-Exclusions.ps1')
)

foreach ($group in @($libraryPaths, $managerPaths)) {
    $canonical = ((Get-Content -LiteralPath $group[0] -Raw -Encoding UTF8) -replace "`r`n", "`n").TrimEnd()
    foreach ($path in $group | Select-Object -Skip 1) {
        $candidate = ((Get-Content -LiteralPath $path -Raw -Encoding UTF8) -replace "`r`n", "`n").TrimEnd()
        Assert-Equal -Name "Cross-platform copy matches $([IO.Path]::GetFileName($group[0]))" -Actual $candidate -Expected $canonical
    }
}

Write-Host '[PASS] User-exclusion selection behavior is valid.'
