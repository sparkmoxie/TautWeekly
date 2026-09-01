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
foreach ($field in @('Name','Repository','Registry','Network','Shell','Privileged','Icon','Overview','Support','Project','TemplateURL','ReadMe','Category','License')) {
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
$expectedIcon = 'https://raw.githubusercontent.com/sparkmoxie/TautWeekly/main/assets/branding/tautweekly-app-icon-512.png'
if ([string]$profile.CommunityApplications.Icon -cne $expectedIcon -or [string]$container.Icon -cne $expectedIcon) {
    Add-Failure 'Unraid profile and template must use the canonical global TautWeekly app icon.'
}

$configs = @($container.Config)
$requiredTargets = @('/data','/var/lib/tautweekly-tailscale','TZ','PUID','PGID','UMASK','TAUTWEEKLY_RUNTIME_PROFILE','TAUTWEEKLY_FUNNEL_ADAPTER','TAUTWEEKLY_PREVIEW_BASE_URL','TAUTWEEKLY_MANAGER_ALLOWED_HOSTS','TAUTWEEKLY_MANAGER_SECURE_COOKIES','TAUTWEEKLY_PACKAGE_KIND','TAUTWEEKLY_HOST_ADAPTER_API')
foreach ($target in $requiredTargets) {
    if (-not ($configs | Where-Object { [string]$_.Target -ceq $target })) {
        Add-Failure "Missing Unraid Config target: $target"
    }
}

$appdata = $configs | Where-Object { [string]$_.Target -ceq '/data' } | Select-Object -First 1
if ($null -ne $appdata -and [string]$appdata.Default -cne '/mnt/user/appdata/tautweekly') {
    Add-Failure 'Unraid appdata default must be /mnt/user/appdata/tautweekly.'
}
if ($configs | Where-Object { [string]$_.Type -ceq 'Port' -or [string]$_.Target -ceq '8080' }) {
    Add-Failure 'Unraid must not generate a broad host port mapping through a Port Config entry.'
}
if ([string]$container.ExtraParams -notmatch '(?:^| )--publish 127[.]0[.]0[.]1:8787:8080/tcp(?: |$)') {
    Add-Failure 'Unraid Manager recovery must use the fixed loopback-only port mapping.'
}
if ($null -ne $container.SelectSingleNode('WebUI')) {
    Add-Failure 'Unraid must omit optional WebUI launch metadata because Community Apps rejects literal loopback hosts.'
}
$packageKind = $configs | Where-Object { [string]$_.Target -ceq 'TAUTWEEKLY_PACKAGE_KIND' } | Select-Object -First 1
if ($null -ne $packageKind -and [string]$packageKind.Default -cne 'unraid') {
    Add-Failure 'Unraid package identity must remain unraid.'
}
$runtimeProfile = $configs | Where-Object { [string]$_.Target -ceq 'TAUTWEEKLY_RUNTIME_PROFILE' } | Select-Object -First 1
if ($null -ne $runtimeProfile -and [string]$runtimeProfile.Default -cne 'unraid') {
    Add-Failure 'Unraid runtime profile must remain unraid.'
}
$hostAdapter = $configs | Where-Object { [string]$_.Target -ceq 'TAUTWEEKLY_HOST_ADAPTER_API' } | Select-Object -First 1
if ($null -ne $hostAdapter -and [string]$hostAdapter.Default -cne '4') {
    Add-Failure 'Unraid host-adapter API must match the current Manager contract.'
}
$funnelAdapter = $configs | Where-Object { [string]$_.Target -ceq 'TAUTWEEKLY_FUNNEL_ADAPTER' } | Select-Object -First 1
if ($null -ne $funnelAdapter -and [string]$funnelAdapter.Default -cne 'disabled') {
    Add-Failure 'Unraid public Funnel must remain explicit opt-in.'
}
$tailscaleState = $configs | Where-Object { [string]$_.Target -ceq '/var/lib/tautweekly-tailscale' } | Select-Object -First 1
if ($null -ne $tailscaleState -and [string]$tailscaleState.Default -cne '/mnt/user/appdata/tautweekly-tailscale') {
    Add-Failure 'Unraid Tailscale state must remain separate from Manager appdata.'
}
if ([string]$container.Overview -notmatch 'authenticated TautWeekly Manager' -or
    [string]$container.Overview -notmatch 'use an SSH local forward' -or
    [string]$container.Overview -notmatch 'access-bootstrap') {
    Add-Failure 'Unraid overview must describe authenticated Manager bootstrap from the container Console.'
}
if ([string]$container.Overview -notmatch 'Unraid owns container lifecycle and stable image updates' -or
    [string]$container.Description -notmatch 'no auth key, Docker socket, privileged mode, host executable, router port, or firewall change') {
    Add-Failure 'Unraid update policy must remain host-managed, stable-only, and socket-free.'
}
if ([string]$container.ExtraParams -notmatch '(?:^| )--tmpfs /run:rw,noexec,nosuid,size=16m,mode=0755(?: |$)' -or
    [string]$container.Description -notmatch 'Tailscale Funnel') {
    Add-Failure 'Unraid Funnel must use only the private runtime tmpfs and fixed userspace adapter.'
}
if ([string]$container.ExtraParams -match '(?i)(?:--publish|-p)\s+(?:0[.]0[.]0[.]0:|[^ ]*::)' ) {
    Add-Failure 'Unraid template contains a broad Manager publish mapping.'
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
