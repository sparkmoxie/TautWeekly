[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$helper = Join-Path $Root 'platforms/windows/TAILSCALE-HELPER.ps1'
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'Tailscale helper is missing.' }

$nonceBytes = New-Object byte[] 32
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $random.GetBytes($nonceBytes) }
finally { $random.Dispose() }
$nonce = ([BitConverter]::ToString($nonceBytes)).Replace('-', '').ToLowerInvariant()
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
try {
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $systemRoot = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) { throw 'Windows system root is unavailable.' }
    $windowsPowerShell = Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper `
        -Action Inspect -Target 'http://127.0.0.1:8788' -CallbackPort $port -Nonce $nonce
    $helperExit = $LASTEXITCODE
    if ($helperExit -eq 10) { throw 'Windows administrator approval was cancelled.' }
    if (-not $listener.Pending()) { throw "Tailscale helper returned without a verified callback (exit $helperExit)." }
    $client = $listener.AcceptTcpClient()
    try {
        $client.ReceiveTimeout = 2000
        $reader = New-Object IO.StreamReader($client.GetStream(), [Text.UTF8Encoding]::new($false), $false, 4096, $true)
        try { $raw = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $client.Dispose() }
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Length -gt 262144) { throw 'Tailscale helper returned an invalid bounded result.' }
    $result = $raw | ConvertFrom-Json -ErrorAction Stop
    if ([int]$result.schemaVersion -ne 1 -or [string]$result.nonce -cne $nonce -or [string]$result.code -cne 'inspected' -or $helperExit -ne 0) {
        throw 'Tailscale helper callback verification failed.'
    }
    $configured = $false
    foreach ($name in @('TCP', 'Web', 'Services', 'AllowFunnel', 'Foreground')) {
        $property = $result.serveStatus.PSObject.Properties[$name]
        if ($null -ne $property -and @($property.Value.PSObject.Properties).Count -gt 0) { $configured = $true }
    }
    Write-Host '[PASS] Windows UAC Tailscale inspection completed with a bounded verified callback.' -ForegroundColor Green
    Write-Host ('Serve state is ' + $(if ($configured) { 'configured (details withheld).' } else { 'empty.' }))
}
finally {
    $listener.Stop()
}
