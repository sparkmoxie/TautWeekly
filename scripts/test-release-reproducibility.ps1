[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$Version = 'ci'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$dist = Join-Path $Root 'dist'
$builder = Join-Path $Root 'scripts/build-releases.ps1'

if (-not (Test-Path -LiteralPath (Join-Path $dist 'SHA256SUMS.txt'))) {
    & $builder -Root $Root -Version $Version
}

$before = @{}
foreach ($file in Get-ChildItem -LiteralPath $dist -File) {
    $before[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}

& $builder -Root $Root -Version $Version

$afterFiles = @(Get-ChildItem -LiteralPath $dist -File)
if ($afterFiles.Count -ne $before.Count) {
    throw "Artifact count changed across identical builds: $($before.Count) to $($afterFiles.Count)."
}

$differences = New-Object System.Collections.Generic.List[string]
foreach ($file in $afterFiles) {
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if (-not $before.ContainsKey($file.Name) -or $before[$file.Name] -ne $hash) {
        $differences.Add($file.Name)
    }
}
if ($differences.Count -gt 0) {
    throw "Non-reproducible release artifacts: $($differences -join ', ')"
}

Write-Host "[PASS] Repeated $Version builds produced byte-identical archives and checksums."
