[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$script:PowerShellExecutable = (Get-Process -Id $PID).Path

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-CacheDiagnostic {
    param([string]$Script, [string]$DataRoot, [string[]]$Arguments = @())
    return @(& $script:PowerShellExecutable -NoLogo -NoProfile -File $Script -DataRoot $DataRoot @Arguments 2>&1 | ForEach-Object { [string]$_ })
}

$scripts = @(
    Join-Path $Root 'platforms/windows/Cache-Diagnostics.ps1'
    Join-Path $Root 'platforms/nas-docker/app/Cache-Diagnostics.ps1'
    Join-Path $Root 'platforms/mac-docker/app/Cache-Diagnostics.ps1'
)
foreach ($script in $scripts) { Assert-True (Test-Path -LiteralPath $script) "Missing cache diagnostic: $script" }
$canonical = ((Get-Content -LiteralPath $scripts[0] -Raw) -replace "`r`n", "`n").TrimEnd()
foreach ($script in $scripts[1..2]) {
    $candidate = ((Get-Content -LiteralPath $script -Raw) -replace "`r`n", "`n").TrimEnd()
    Assert-True ($candidate -eq $canonical) "Cache diagnostic implementations diverged: $script"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-cache-diagnostic-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $privateToken = 'private-token-must-not-appear'
    $configuration = [ordered]@{
        DeletedItemCacheEnabled       = $true
        DeletedItemCacheRetentionDays = 90
        DeletedItemCacheMaxItems      = 1000
        DeletedItemCacheMaxBytesMB    = 16
        ApiKey                        = $privateToken
    }
    $configuration | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot 'config.json') -Encoding UTF8

    $status = Invoke-CacheDiagnostic -Script $scripts[0] -DataRoot $testRoot
    $joined = $status -join "`n"
    foreach ($expected in @('CacheDiagnosticSchema: 1','ShareSafe: true','Configuration: valid','Enabled: true','Available: true','Manifest: unseeded','Backup: missing','Writability: passed','Entries: 0','ExactGuidProbe: not-requested','PersistenceProbe: absent')) {
        Assert-True $joined.Contains($expected) "Cache diagnostic omitted '$expected'. Output: $joined"
    }
    foreach ($forbidden in @($testRoot, $privateToken, 'config.json', 'index.json', 'deleted-items')) {
        Assert-True (-not $joined.Contains($forbidden)) "Cache diagnostic exposed private value '$forbidden'."
    }

    $set = (Invoke-CacheDiagnostic -Script $scripts[0] -DataRoot $testRoot -Arguments @('-Action','SetPersistenceProbe')) -join "`n"
    Assert-True $set.Contains('PersistenceProbe: created') 'Persistence probe was not created.'
    $verify = (Invoke-CacheDiagnostic -Script $scripts[0] -DataRoot $testRoot -Arguments @('-Action','VerifyPersistenceProbe','-VerifyArtworkHashes')) -join "`n"
    Assert-True $verify.Contains('PersistenceProbe: preserved') "Persistence verification did not report its safe state. Share-safe output: $verify"
    Assert-True $verify.Contains('Integrity: hash-verified') "Artwork hash verification did not report its safe state. Share-safe output: $verify"
    $clear = (Invoke-CacheDiagnostic -Script $scripts[0] -DataRoot $testRoot -Arguments @('-Action','ClearPersistenceProbe')) -join "`n"
    Assert-True $clear.Contains('PersistenceProbe: cleared') 'Persistence probe was not cleared.'

    $invalidRoot = Join-Path $testRoot 'invalid'
    New-Item -ItemType Directory -Path $invalidRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $invalidRoot 'config.json') -Value '{invalid' -Encoding UTF8
    $invalid = (Invoke-CacheDiagnostic -Script $scripts[0] -DataRoot $invalidRoot) -join "`n"
    Assert-True ($invalid.Contains('Configuration: invalid-or-unreadable') -and $invalid.Contains('Available: false')) 'Invalid configuration was not reported safely.'
    Assert-True (-not $invalid.Contains($invalidRoot)) 'Invalid configuration output exposed its local path.'

    $disabledRoot = Join-Path $testRoot 'disabled'
    New-Item -ItemType Directory -Path $disabledRoot | Out-Null
    @{ DeletedItemCacheEnabled = $false } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $disabledRoot 'config.json') -Encoding UTF8
    $disabled = (Invoke-CacheDiagnostic -Script $scripts[0] -DataRoot $disabledRoot -Arguments @('-VerifyArtworkHashes')) -join "`n"
    Assert-True ($disabled.Contains('Enabled: false') -and $disabled.Contains('Backup: not-applicable') -and $disabled.Contains('Integrity: not-applicable')) 'Disabled cache diagnostic did not remain non-applicable.'

    Write-Host '[PASS] Share-safe cache diagnostics, script parity, hash mode, and restart persistence probe.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
