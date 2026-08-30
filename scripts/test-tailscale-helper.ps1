[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$helper = Join-Path $Root 'platforms/windows/TAILSCALE-HELPER.ps1'
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'Tailscale helper is missing.' }

$tokens = $null
$parseErrors = $null
$scriptAst = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
    throw ('Tailscale helper has PowerShell syntax errors: ' + (($parseErrors | ForEach-Object Message) -join '; '))
}
$source = Get-Content -LiteralPath $helper -Raw

function Require-Pattern([string]$Pattern, [string]$Message) {
    if ($source -notmatch $Pattern) { throw $Message }
}
function Forbid-Pattern([string]$Pattern, [string]$Message) {
    if ($source -match $Pattern) { throw $Message }
}

Require-Pattern '\[ValidateSet\("Enable", "Disable", "Inspect"\)\]' 'Helper actions are not limited to Enable, Disable, and Inspect.'
Require-Pattern '\[ValidatePattern\("\^http://127\\\.0\\\.0\\\.1:' 'Helper target is not pinned to loopback HTTP.'
Require-Pattern 'funnel status --json' 'Helper does not inspect Funnel through the official JSON status command.'
Require-Pattern 'funnel --bg --yes --https=443 \$ExpectedTarget' 'Helper does not enable the fixed persistent HTTPS Funnel.'
Require-Pattern '& \$tailscalePath funnel --yes --https=443 off' 'Helper does not remove the exact Funnel route.'
Require-Pattern '& \$tailscalePath serve --yes --https=443 off' 'Helper cannot retire the exact legacy private Serve route.'
Require-Pattern 'Test-OwnedFunnelStatus' 'Helper does not validate exact Funnel ownership.'
Require-Pattern 'Test-OwnedLegacyServeStatus' 'Helper does not isolate legacy Serve migration.'
Require-Pattern 'AllowFunnel' 'Helper does not require explicit Funnel metadata.'
Require-Pattern 'provider-approval-required' 'Helper does not sanitize first-use provider approval.'
Require-Pattern 'not-running' 'Helper does not sanitize the stopped-service state.'
Require-Pattern 'unsupported' 'Helper does not sanitize unsupported clients.'
Require-Pattern 'Send-Result' 'Helper does not use the bounded nonce callback.'
Require-Pattern 'Resolve-DnsName -Name \$hostname -Type A -Server ''1\.1\.1\.1''' 'Helper does not bypass private MagicDNS with the fixed public resolver.'
Require-Pattern 'Test-PublicIPv4Address' 'Helper does not reject private and non-routable DNS answers.'
Require-Pattern 'BeginAuthenticateAsClient\(\$hostname' 'Helper does not perform a certificate-validated public TLS handshake.'
Require-Pattern 'if \(-not \$authentication\.AsyncWaitHandle\.WaitOne\(5000\)\) \{ continue \}' 'Helper could treat a public-edge TLS stall as published.'
Require-Pattern 'publiclyPublished = \$PubliclyPublished' 'Helper does not return the sanitized public-publication postcondition.'

Forbid-Pattern 'serve --bg' 'Helper still enables the obsolete private Serve workflow.'
Forbid-Pattern '(?i)tailscale(?:\.exe)?\s+(?:serve|funnel)\s+reset' 'Helper contains a destructive Tailscale reset.'
Forbid-Pattern '(?i)authkey|oauth|control-plane|device list|tailscale status(?:\s|$)' 'Helper contains a credential or inventory surface.'
Forbid-Pattern '(?i)New-NetFirewallRule|Set-NetFirewallRule|netsh\s+advfirewall|portproxy' 'Helper changes Windows firewall or ingress rules.'
Forbid-Pattern '(?i)Restart-Service|Stop-Service|Start-Service|sc(?:\.exe)?\s+(?:stop|start)' 'Helper silently restarts the Tailscale Windows service.'

$publicAddressFunction = $scriptAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-PublicIPv4Address'
}, $true)
if ($null -eq $publicAddressFunction) { throw 'Public IPv4 validator function is missing.' }
Invoke-Expression $publicAddressFunction.Extent.Text
foreach ($value in @('8.8.8.8', '185.40.234.37')) {
    if (-not (Test-PublicIPv4Address $value)) { throw "Public DNS/TLS fixture was rejected: $value" }
}
foreach ($value in @('invalid', '::1')) {
    if (Test-PublicIPv4Address $value) { throw "Non-public DNS/TLS fixture was accepted: $value" }
}
foreach ($octets in @(
    ,@(0, 0, 0, 0)
    ,@(10, 0, 0, 1)
    ,@(100, 64, 0, 1)
    ,@(127, 0, 0, 1)
    ,@(169, 254, 1, 1)
    ,@(172, 16, 0, 1)
    ,@(192, 0, 2, 1)
    ,@(192, 168, 1, 1)
    ,@(198, 18, 0, 1)
    ,@(198, 51, 100, 1)
    ,@(203, 0, 113, 1)
    ,@(224, 0, 0, 1)
)) {
    $value = $octets -join '.'
    if (Test-PublicIPv4Address $value) { throw "Non-public DNS/TLS fixture was accepted: $value" }
}

Write-Host '[PASS] Windows Funnel helper syntax, typed operations, fixed target, exact postconditions, legacy cleanup, and privacy boundaries are virtual-test safe.' -ForegroundColor Green
