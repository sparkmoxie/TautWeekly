[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$modules = @(
    'platforms/windows/Configuration-Backups.ps1',
    'platforms/nas-docker/app/Configuration-Backups.ps1',
    'platforms/mac-docker/app/Configuration-Backups.ps1'
)

foreach ($relativePath in $modules) {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-backups-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    try {
        . (Join-Path $Root $relativePath)
        $configPath = Join-Path $tempRoot 'config.json'
        [IO.File]::WriteAllText($configPath, '{"marker":"current"}', [Text.UTF8Encoding]::new($false))
        for ($index = 0; $index -lt 12; $index++) {
            $stamp = ([DateTime]'2001-04-18T16:00:00Z').AddMinutes($index).ToString('yyyyMMdd-HHmmss')
            $name = if (($index % 2) -eq 0) { "config.backup.$stamp.000000000Z.json" } else { "config.backup.$stamp.json" }
            [IO.File]::WriteAllText((Join-Path $tempRoot $name), "{`"marker`":$index}", [Text.UTF8Encoding]::new($false))
        }
        $unrecognizedPath = Join-Path $tempRoot 'config.backup.unsafe.json'
        [IO.File]::WriteAllText($unrecognizedPath, 'leave me', [Text.UTF8Encoding]::new($false))

        $created = New-TautWeeklyConfigurationBackup -ConfigPath $configPath -Directory $tempRoot
        $retained = @(Get-ChildItem -LiteralPath $tempRoot -File | Where-Object { $_.Name -match '^config\.backup\.\d{8}-\d{6}(?:\.\d{9}Z)?\.json$' })
        Assert-True ($retained.Count -eq 10) "$relativePath retained $($retained.Count) backups instead of 10."
        Assert-True (Test-Path -LiteralPath $created -PathType Leaf) "$relativePath removed the newly-created backup."
        Assert-True ((Get-Content -LiteralPath $created -Raw) -eq '{"marker":"current"}') "$relativePath changed backup bytes."
        Assert-True (Test-Path -LiteralPath $unrecognizedPath -PathType Leaf) "$relativePath removed an unrecognized file."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempRoot 'config.backup.20010418-160000.000000000Z.json'))) "$relativePath did not remove the oldest overflow backup."
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '[PASS] Configuration backup helpers keep the newest 10 canonical and legacy backups.'
