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
[Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$parseErrors) | Out-Null
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

Forbid-Pattern 'serve --bg' 'Helper still enables the obsolete private Serve workflow.'
Forbid-Pattern '(?i)tailscale(?:\.exe)?\s+(?:serve|funnel)\s+reset' 'Helper contains a destructive Tailscale reset.'
Forbid-Pattern '(?i)authkey|oauth|control-plane|device list|tailscale status(?:\s|$)' 'Helper contains a credential or inventory surface.'
Forbid-Pattern '(?i)New-NetFirewallRule|Set-NetFirewallRule|netsh\s+advfirewall|portproxy' 'Helper changes Windows firewall or ingress rules.'

Write-Host '[PASS] Windows Funnel helper syntax, typed operations, fixed target, exact postconditions, legacy cleanup, and privacy boundaries are virtual-test safe.' -ForegroundColor Green
