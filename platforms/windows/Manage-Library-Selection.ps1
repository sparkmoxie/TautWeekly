param(
    [string]$ConfigPath = $(if (-not [string]::IsNullOrWhiteSpace([string]$env:TAUTWEEKLY_CONFIG)) { [string]$env:TAUTWEEKLY_CONFIG } else { Join-Path $PSScriptRoot 'config.json' }),
    [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Library-Selection.ps1')
. (Join-Path $PSScriptRoot 'Configuration-Backups.ps1')

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath. Run the primary setup first."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$tautulliUrl = [string](Get-TautWeeklyLibraryObjectValue -InputObject $config -Name 'TautulliUrl' -Default '')
$apiKey = [string](Get-TautWeeklyLibraryObjectValue -InputObject $config -Name 'ApiKey' -Default '')
if ([string]::IsNullOrWhiteSpace($tautulliUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
    throw 'TautulliUrl and ApiKey must be configured before newsletter libraries can be managed.'
}

$configuredProperty = $config.PSObject.Properties['IncludedLibraryIds']
$current = @()
if ($null -ne $configuredProperty) { $current = @($configuredProperty.Value) }

$libraries = @(Get-TautWeeklySelectableLibraries -TautulliUrl $tautulliUrl -ApiKey $apiKey)
if (@($libraries | Where-Object { $_.Selectable }).Count -eq 0) {
    throw 'Tautulli returned no active movie or TV libraries. No configuration changes were made.'
}

if ($ListOnly) {
    [void](Show-TautWeeklyLibrarySelection -Libraries $libraries -CurrentIncludedLibraryIds $current)
    Write-Host ''
    Write-Host 'No configuration changes were made.' -ForegroundColor Green
    exit 0
}

$updated = @(Read-TautWeeklyIncludedLibraryIds -Libraries $libraries -CurrentIncludedLibraryIds $current)
$before = @((Get-TautWeeklyUniqueLibraryIds -Values $current) | Sort-Object)
$after = @((Get-TautWeeklyUniqueLibraryIds -Values $updated) | Sort-Object)
$hasExplicitSelection = ($null -ne $configuredProperty -and $before.Count -gt 0)
$changed = (-not $hasExplicitSelection) -or ($null -ne (Compare-Object -ReferenceObject $before -DifferenceObject $after))

if (-not $changed) {
    Write-Host ''
    Write-Host 'Newsletter library selection is unchanged.' -ForegroundColor Green
    exit 0
}

$backupPath = New-TautWeeklyConfigurationBackup -ConfigPath $ConfigPath -Directory (Split-Path -Parent $ConfigPath)

if ($null -eq $configuredProperty) {
    $config | Add-Member -MemberType NoteProperty -Name 'IncludedLibraryIds' -Value @($updated)
}
else {
    $config.IncludedLibraryIds = @($updated)
}

$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
if ($PSVersionTable.ContainsKey('Platform') -and [string]$PSVersionTable['Platform'] -eq 'Unix') {
    try { & /bin/chmod 600 $ConfigPath 2>$null } catch { }
}

Write-Host ''
Write-Host ('Saved {0} included library ID(s) to {1}.' -f $updated.Count, $ConfigPath) -ForegroundColor Green
Write-Host "Private configuration backup created: $backupPath" -ForegroundColor DarkGray
Write-Host 'The selection applies to the next preview, test, or newsletter run.' -ForegroundColor DarkGray
