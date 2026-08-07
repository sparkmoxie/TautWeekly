[CmdletBinding()]
param(
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)

$profilePath = Join-Path $Root 'ca_profile.xml'
$templatePath = Join-Path $Root 'templates/tautweekly.xml'
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    $script:failures.Add($Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Require-Value([object]$Value, [string]$Name) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        Add-Failure "Missing Unraid field: $Name"
    }
}

try { [xml]$profile = Get-Content -LiteralPath $profilePath -Raw }
catch { throw "Invalid ca_profile.xml: $($_.Exception.Message)" }
try { [xml]$template = Get-Content -LiteralPath $templatePath -Raw }
catch { throw "Invalid templates/tautweekly.xml: $($_.Exception.Message)" }

Require-Value $profile.CommunityApplications.Profile 'ca_profile.xml/Profile'
Require-Value $profile.CommunityApplications.Icon 'ca_profile.xml/Icon'
Require-Value $profile.CommunityApplications.WebPage 'ca_profile.xml/WebPage'

$container = $template.Container
if ([string]$container.version -ne '2') { Add-Failure 'Unraid Container version must be 2.' }
foreach ($field in @('Name','Repository','Registry','Network','Shell','Privileged','Icon','WebUI','Overview','Support','Project','TemplateURL','ReadMe','Category','License')) {
    Require-Value $container.$field "Container/$field"
}

$expected = [ordered]@{
    Name = 'TautWeekly for Plex'
    Repository = 'ghcr.io/sparkmoxie/tautweekly:latest'
    Network = 'bridge'
    Shell = 'bash'
    Privileged = 'false'
    TemplateURL = 'https://raw.githubusercontent.com/sparkmoxie/TautWeekly/main/templates/tautweekly.xml'
    License = 'MIT'
}
foreach ($entry in $expected.GetEnumerator()) {
    if ([string]$container.($entry.Key) -cne [string]$entry.Value) {
        Add-Failure "Unexpected $($entry.Key): $($container.($entry.Key))"
    }
}

$configs = @($container.Config)
$requiredTargets = @('8080','/data','TZ','PUID','PGID','UMASK','TAUTWEEKLY_PREVIEW_BASE_URL')
foreach ($target in $requiredTargets) {
    if (-not ($configs | Where-Object { [string]$_.Target -ceq $target })) {
        Add-Failure "Missing Unraid Config target: $target"
    }
}

$appdata = $configs | Where-Object { [string]$_.Target -ceq '/data' } | Select-Object -First 1
if ($null -ne $appdata -and [string]$appdata.Default -cne '/mnt/user/appdata/tautweekly') {
    Add-Failure 'Unraid appdata default must be /mnt/user/appdata/tautweekly.'
}
$webPort = $configs | Where-Object { [string]$_.Target -ceq '8080' } | Select-Object -First 1
if ($null -ne $webPort -and ([string]$webPort.Default -cne '8787' -or [string]$webPort.Type -cne 'Port')) {
    Add-Failure 'Unraid WebUI must map host port 8787 to container port 8080.'
}
if ($null -ne $webPort -and ([string]$webPort.Name -cne 'Preview Viewer' -or [string]$webPort.Description -notmatch 'not an admin UI')) {
    Add-Failure 'Unraid port metadata must identify the endpoint as a preview viewer rather than an admin UI.'
}
if ([string]$container.Overview -notmatch 'read-only preview viewer' -or [string]$container.Overview -notmatch 'Setup-First\.ps1') {
    Add-Failure 'Unraid overview must distinguish the preview viewer from Console-based setup.'
}
if ([string]$container.Overview -notmatch 'Unraid checks the configured stable latest image' -or
    [string]$container.Description -notmatch 'No in-container updater, Docker socket, or edge image is enabled') {
    Add-Failure 'Unraid update policy must remain host-managed, stable-only, and socket-free.'
}

$rawMetadata = (Get-Content -LiteralPath $profilePath -Raw) + "`n" + (Get-Content -LiteralPath $templatePath -Raw)
if ($rawMetadata -match '(?i)YOUR_|example-app|YOUR_PLUGIN_REPO|YOUR_REPO_NAME') {
    Add-Failure 'Unraid metadata still contains starter placeholder values.'
}
if ($rawMetadata -match '(?i)(?:gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN .*PRIVATE KEY-----)') {
    Add-Failure 'Unraid metadata contains a credential-like value.'
}

if ($failures.Count -gt 0) {
    throw "Unraid template validation failed with $($failures.Count) finding(s)."
}

Write-Host "[PASS] Unraid Community Apps profile and template are valid." -ForegroundColor Green
Write-Host "[PASS] Verified $($configs.Count) safe port, path, and environment entries." -ForegroundColor Green
