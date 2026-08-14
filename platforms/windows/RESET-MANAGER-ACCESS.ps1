[CmdletBinding()]
param(
    [string]$DataRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = [IO.Path]::GetFullPath($PSScriptRoot)
$manager = Join-Path $root 'tautweekly-manager.exe'
if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) {
    throw 'tautweekly-manager.exe is missing. Reinstall or re-extract the complete official Windows package.'
}

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $metadataPath = Join-Path $root 'INSTALL-METADATA.txt'
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        $saved = Get-Content -LiteralPath $metadataPath | Where-Object { $_ -like 'DataDirectory=*' } | Select-Object -First 1
        if ($null -ne $saved) {
            $DataRoot = $saved.Substring('DataDirectory='.Length)
        }
    }
}
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Join-Path $root '.manager-data'
}
$DataRoot = [IO.Path]::GetFullPath($DataRoot)

$expectedManager = [IO.Path]::GetFullPath($manager)
$running = @(Get-Process -Name 'tautweekly-manager' -ErrorAction SilentlyContinue | Where-Object {
    try { [IO.Path]::GetFullPath([string]$_.Path) -ieq $expectedManager } catch { $false }
})
foreach ($process in $running) {
    Stop-Process -Id $process.Id -Force -ErrorAction Stop
}

& $manager 'access-reset' "--data-dir=$DataRoot"
if ($LASTEXITCODE -ne 0) {
    throw "Manager access reset failed with exit code $LASTEXITCODE."
}

Write-Host 'Opening TautWeekly Manager with trusted-local access...'
& (Join-Path $root 'START-MANAGER.ps1') -DataRoot $DataRoot
