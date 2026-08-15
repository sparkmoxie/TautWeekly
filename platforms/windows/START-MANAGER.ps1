[CmdletBinding()]
param(
    [string]$DataRoot = '',
    [switch]$Startup,
    [switch]$OpenDashboard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = [IO.Path]::GetFullPath($PSScriptRoot)
$manager = Join-Path $root 'tautweekly-manager.exe'
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $dataRoot = Join-Path $root '.manager-data'
}
else {
    $dataRoot = [IO.Path]::GetFullPath($DataRoot)
}
$baseUri = 'http://127.0.0.1:8788/'
$healthUri = $baseUri + 'health/live'
$setupUri = $baseUri + 'api/v1/setup'

if ($OpenDashboard -and -not $Startup) {
    throw '-OpenDashboard is valid only with -Startup.'
}

function Test-ExistingManager {
    try {
        $health = Invoke-RestMethod -UseBasicParsing -Uri $healthUri -TimeoutSec 2
        $setup = Invoke-RestMethod -UseBasicParsing -Uri $setupUri -TimeoutSec 2
        return ([string]$health.status -eq 'alive' -and $null -ne $setup.PSObject.Properties['paired'])
    }
    catch {
        return $false
    }
}

if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) {
    throw 'tautweekly-manager.exe is missing. Re-extract the complete official Windows ZIP.'
}

if (Test-ExistingManager) {
    if (-not $Startup -or $OpenDashboard) {
        & $manager open '--listen=127.0.0.1:8788'
        if ($LASTEXITCODE -ne 0) {
            throw "The existing TautWeekly Dashboard could not be activated (exit code $LASTEXITCODE)."
        }
    }
    exit 0
}

$occupied = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 8788 -State Listen -ErrorAction SilentlyContinue
if ($null -ne $occupied) {
    throw 'Port 8788 is already used by another local application. Stop that application before opening TautWeekly Manager.'
}

if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $dataRoot | Out-Null
}

$arguments = 'serve --listen=127.0.0.1:8788 --tautweekly-root="{0}" --data-dir="{1}"' -f $root, $dataRoot
if (-not $Startup -or $OpenDashboard) {
    $arguments += ' --open-browser'
}
$process = Start-Process -FilePath $manager -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Hidden -PassThru
$deadline = (Get-Date).AddSeconds(10)
do {
    Start-Sleep -Milliseconds 200
    if ($process.HasExited) {
        throw "TautWeekly Manager stopped during startup with exit code $($process.ExitCode)."
    }
    if (Test-ExistingManager) {
        exit 0
    }
} while ((Get-Date) -lt $deadline)

Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
throw 'TautWeekly Manager did not become ready within 10 seconds.'
