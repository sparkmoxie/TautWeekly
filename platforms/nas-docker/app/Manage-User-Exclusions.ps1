param(
    [string]$ConfigPath = $(if (-not [string]::IsNullOrWhiteSpace([string]$env:TAUTWEEKLY_CONFIG)) { [string]$env:TAUTWEEKLY_CONFIG } else { Join-Path $PSScriptRoot 'config.json' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'User-Exclusions.ps1')

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath. Run the primary setup first."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$tautulliUrl = [string](Get-TautWeeklyObjectValue -InputObject $config -Name 'TautulliUrl' -Default '')
$apiKey = [string](Get-TautWeeklyObjectValue -InputObject $config -Name 'ApiKey' -Default '')
if ([string]::IsNullOrWhiteSpace($tautulliUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
    throw 'TautulliUrl and ApiKey must be configured before user exclusions can be managed.'
}

$current = @()
$excludedProperty = $config.PSObject.Properties['ExcludedUserIds']
if ($null -ne $excludedProperty) { $current = @($excludedProperty.Value) }

$users = @(Get-TautWeeklySelectableUsers -TautulliUrl $tautulliUrl -ApiKey $apiKey)
if ($users.Count -eq 0) {
    throw 'Tautulli returned no selectable users. No configuration changes were made.'
}

$updated = @(Read-TautWeeklyExcludedUserIds -Users $users -CurrentExcludedUserIds $current)
$before = @($current | ForEach-Object { [string]$_ } | Sort-Object -Unique)
$after = @($updated | ForEach-Object { [string]$_ } | Sort-Object -Unique)
$changed = $null -ne (Compare-Object -ReferenceObject $before -DifferenceObject $after)

if (-not $changed) {
    Write-Host ''
    Write-Host 'User exclusions are unchanged.' -ForegroundColor Green
    exit 0
}

if ($null -eq $excludedProperty) {
    $config | Add-Member -MemberType NoteProperty -Name 'ExcludedUserIds' -Value @($updated)
}
else {
    $config.ExcludedUserIds = @($updated)
}

$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
if ($PSVersionTable.ContainsKey('Platform') -and [string]$PSVersionTable['Platform'] -eq 'Unix') {
    try { & /bin/chmod 600 $ConfigPath 2>$null } catch { }
}

Write-Host ''
Write-Host ('Saved {0} excluded user ID(s) to {1}.' -f $updated.Count, $ConfigPath) -ForegroundColor Green
Write-Host 'ExcludedEmails was left unchanged.' -ForegroundColor DarkGray
