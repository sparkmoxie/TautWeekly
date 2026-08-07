[CmdletBinding()]
param(
    [string]$LatestVersion = '',
    [string]$MetadataPath = (Join-Path $PSScriptRoot 'RELEASE-METADATA.txt')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$currentVersion = ''
if (Test-Path -LiteralPath $MetadataPath) {
    $metadata = Get-Content -LiteralPath $MetadataPath -Raw -Encoding UTF8
    if ($metadata -match '(?m)^Repository version:\s*v?(?<version>[0-9]+\.[0-9]+\.[0-9]+)\s*$') {
        $currentVersion = $Matches['version']
    }
}

if ([string]::IsNullOrWhiteSpace($LatestVersion)) {
    if ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) {
        $previousProtocol = $null
    }
    else {
        $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    try {
        $headers = @{
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent' = 'TautWeekly-update-check'
        }
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/sparkmoxie/TautWeekly/releases/latest' -Headers $headers
        $LatestVersion = ([string]$release.tag_name).TrimStart('v')
    }
    finally {
        if ($null -ne $previousProtocol) {
            [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
        }
    }
}
else {
    $LatestVersion = $LatestVersion.TrimStart('v')
}

if ($LatestVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "GitHub did not return a valid stable release version: $LatestVersion"
}

if ([string]::IsNullOrWhiteSpace($currentVersion)) {
    Write-Output 'Installed package: unknown (release metadata is unavailable)'
    Write-Output "Latest stable release: $LatestVersion"
    Write-Output 'Use an official release ZIP before applying an update.'
    exit 0
}

Write-Output "Installed package: $currentVersion"
Write-Output "Latest stable release: $LatestVersion"
if ($currentVersion -eq $LatestVersion) {
    Write-Output 'This package is up to date.'
}
elseif ([version]$currentVersion -gt [version]$LatestVersion) {
    Write-Output "This package is newer than GitHub's latest stable release; no update is offered."
}
else {
    Write-Output "A stable update is available: $currentVersion -> $LatestVersion"
    Write-Output "Release: https://github.com/sparkmoxie/TautWeekly/releases/tag/v$LatestVersion"
}
