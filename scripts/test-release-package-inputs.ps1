[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# Load only assembly helpers; executing the builder itself would clean staging
# and build every binary, which is unnecessary for these packaging regressions.
$builderPath = Join-Path $Root 'scripts/build-releases.ps1'
$parseErrors = $null
$parseTokens = $null
$builder = [Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$parseTokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'Release builder must parse before its token helpers can be tested.'
foreach ($functionName in @('Copy-Platform', 'Test-UnixTextReleaseFile', 'Set-ReleaseVersionTokens')) {
    $function = $builder.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    Assert-True ($null -ne $function) "Release builder helper is missing: $functionName"
    . ([scriptblock]::Create($function.Extent.Text))
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-package-tokens-' + [Guid]::NewGuid().ToString('N'))
$staging = Join-Path $testRoot 'staging'
$Version = '9.8.7'
$token = '__TAUTWEEKLY_RELEASE_VERSION__'
$utf8 = [Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Path $staging -Force | Out-Null

function Assert-TokenRefused([string]$Name, [byte[]]$Bytes) {
    $destination = Join-Path $testRoot ([IO.Path]::GetFileNameWithoutExtension($Name) + '-refusal')
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $path = Join-Path $destination $Name
    [IO.File]::WriteAllBytes($path, $Bytes)
    $before = [Convert]::ToBase64String($Bytes)
    $refused = $false
    try { Set-ReleaseVersionTokens -Destination $destination }
    catch { $refused = $_.Exception.Message -match 'refusing to alter|was not replaced' }
    Assert-True $refused "Token-bearing unsupported/binary file was accepted: $Name"
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq $before) "Refused file was altered: $Name"
}

try {
    $destination = Copy-Platform -SourceName 'freebsd-podman' -FolderName 'TautWeekly-freebsd-podman' -GuidePath 'docs/freebsd/README.md'
    foreach ($name in @('compose.yaml', 'fixture.json', 'fixture.sh', 'fixture.example', 'fixture.md')) {
        [IO.File]::WriteAllText((Join-Path $destination $name), "before $token after`n", $utf8)
    }
    $binaryPath = Join-Path $destination 'fixture.bin'
    $binaryBytes = [byte[]]@(0, 255, 19, 128, 0, 42)
    [IO.File]::WriteAllBytes($binaryPath, $binaryBytes)
    Set-ReleaseVersionTokens -Destination $destination
    foreach ($relative in @('tautweekly.env.example', 'tautweekly', 'rc.d/tautweekly')) {
        $text = [IO.File]::ReadAllText((Join-Path $destination $relative))
        Assert-True ($text.Contains("ghcr.io/sparkmoxie/tautweekly:$Version")) "FreeBSD default image was not expanded in $relative."
        Assert-True (-not $text.Contains($token)) "FreeBSD $relative retains the version token."
    }
    foreach ($name in @('compose.yaml', 'fixture.json', 'fixture.sh', 'fixture.example', 'fixture.md')) {
        Assert-True ([IO.File]::ReadAllText((Join-Path $destination $name)) -ceq "before $Version after`n") "Version replacement damaged $name."
    }
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($binaryPath)) -ceq [Convert]::ToBase64String($binaryBytes)) 'Token-free binary bytes changed.'
    Assert-TokenRefused 'unknown.dat' ($utf8.GetBytes($token))
    Assert-TokenRefused 'binary.txt' ([byte[]](@(0) + @($utf8.GetBytes($token))))
    Assert-TokenRefused 'invalid-utf8.txt' ([byte[]](@(255) + @($utf8.GetBytes($token))))
    Write-Host '[PASS] FreeBSD image defaults and all supported text tokens expand; unsupported/binary tokens fail without altering their bytes.'

    $guide = [IO.File]::ReadAllText((Join-Path $destination 'README.md'))
    Assert-True ($guide.Contains('git clone --depth 1 --branch "v$release"') -and
        $guide.Contains('cd TautWeekly-source') -and
        $guide.Contains('BUILD_VERSION="$release" -f platforms/nas-docker/Dockerfile')) 'FreeBSD image build must check out the installed release and use repository-root context.'
    Assert-True (-not $guide.Contains('sudo podman build --os=linux -t localhost/tautweekly:local .')) 'FreeBSD guide still claims its release archive is a standalone build context.'
    $dockerfile = [IO.File]::ReadAllText((Join-Path $Root 'platforms/nas-docker/Dockerfile'))
    $copySources = [regex]::Matches($dockerfile, '(?m)^COPY (?<source>(?!--)\S+)\s+')
    Assert-True ($copySources.Count -ge 3) 'Canonical Dockerfile must expose its local COPY inputs for context validation.'
    foreach ($copySource in $copySources) {
        $relative = $copySource.Groups['source'].Value
        Assert-True (Test-Path -LiteralPath (Join-Path $Root $relative)) "Documented repository-root build lacks COPY source: $relative"
    }
    Write-Host '[PASS] FreeBSD source-build instructions use a complete versioned checkout with every local Docker COPY input present.'

    $installer = [IO.File]::ReadAllText((Join-Path $destination 'install-freebsd.sh'))
    $repair = [regex]::Match($installer, '(?ms)^repair_legacy_image_default\(\) \(\r?\n.*?^\)\r?\n')
    Assert-True $repair.Success 'FreeBSD installer is missing its bounded legacy-default repair function.'
    Assert-True ($repair.Value.Contains("'__TAUTWEEKLY_RELEASE_''VERSION__'")) 'Release expansion must preserve the split legacy repair token.'
    $gitBash = if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) { Join-Path $env:ProgramFiles 'Git/bin/bash.exe' } else { '' }
    $bashCommand = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $bash = if ($gitBash -and (Test-Path -LiteralPath $gitBash -PathType Leaf)) { $gitBash } elseif ($null -ne $bashCommand) { $bashCommand.Source } else { '' }
    Assert-True (Test-Path -LiteralPath $bash -PathType Leaf) 'Bash is required for isolated FreeBSD repair fixtures.'
    $script:fixtureNumber = 0
    function Invoke-LegacyRepairFixture([string]$Image, [string]$Metadata, [bool]$Success, [bool]$Repaired, [bool]$MissingMetadata = $false) {
        $script:fixtureNumber++
        $fixture = Join-Path $testRoot ('freebsd-repair-' + $script:fixtureNumber)
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        $envPath = Join-Path $fixture 'tautweekly.env'
        $metadataPath = Join-Path $fixture 'metadata.txt'
        $ownershipLog = Join-Path $fixture 'ownership.txt'
        $original = "# private settings`nTAUTWEEKLY_IMAGE=$Image`nTAUTWEEKLY_TIMEZONE=Etc/UTC`nPRIVATE_SENTINEL='a & b / c | secret'`n"
        [IO.File]::WriteAllText($envPath, $original, $utf8)
        if (-not $MissingMetadata) { [IO.File]::WriteAllText($metadataPath, $Metadata, $utf8) }
        $mock = @(
            'ownership_log="$3"',
            'chmod() { printf ''%s\n'' "$1" >>"$ownership_log"; command chmod "$@"; }',
            'chown() { [ "$#" -eq 2 ] && [ "$1" = root:wheel ] && [ -f "$2" ]; printf ''%s\n'' "$1" >>"$ownership_log"; }',
            'repair_legacy_image_default "$1" "$2"'
        ) -join "`n"
        $shell = "set -eu`n" + $repair.Value + "`n" + $mock + "`n"
        # Windows PowerShell wraps redirected native stderr in error records.
        # Capture expected refusal messages and judge the native exit code.
        $previousErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $result = $shell | & $bash -s -- ($envPath.Replace('\','/')) ($metadataPath.Replace('\','/')) ($ownershipLog.Replace('\','/')) 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousErrorPreference }
        Assert-True (($exitCode -eq 0) -eq $Success) "FreeBSD repair fixture exited $exitCode unexpectedly: $($result -join ' ')"
        $expected = if ($Repaired) { $original.Replace("TAUTWEEKLY_IMAGE=$Image", "TAUTWEEKLY_IMAGE=ghcr.io/sparkmoxie/tautweekly:$Version") } else { $original }
        Assert-True ([IO.File]::ReadAllText($envPath) -ceq $expected) 'FreeBSD repair changed custom/private content or failed to repair the exact legacy default.'
        if ($Repaired) {
            Assert-True (Test-Path -LiteralPath $ownershipLog) 'Repaired environment ownership was not set.'
            Assert-True ([IO.File]::ReadAllText($ownershipLog).Replace("`r`n","`n") -ceq "0600`nroot:wheel`n") 'Repaired environment must be private and root-owned before atomic replacement.'
        } else {
            Assert-True (-not (Test-Path -LiteralPath $ownershipLog)) 'Unchanged environment unexpectedly had its mode or owner altered.'
        }
        Assert-True (@(Get-ChildItem -LiteralPath $fixture -Filter '*.repair.*' -File).Count -eq 0) 'FreeBSD repair left a temporary environment file.'
    }
    $legacyImage = 'ghcr.io/sparkmoxie/tautweekly:' + $token
    Invoke-LegacyRepairFixture $legacyImage "Repository version: $Version`n" $true $true
    Invoke-LegacyRepairFixture $legacyImage '' $false $false $true
    foreach ($malformed in @('dev', '09.8.7', '9.8', '9.8.7;bad', "9.8.7`nRepository version: 9.8.6")) {
        Invoke-LegacyRepairFixture $legacyImage "Repository version: $malformed`n" $false $false
    }
    foreach ($customImage in @('ghcr.io/sparkmoxie/tautweekly:0.27.2', ('ghcr.io/sparkmoxie/tautweekly:0.27.2@sha256:' + ('a' * 64)), 'localhost/tautweekly:custom', ("'" + $legacyImage + "'"))) {
        Invoke-LegacyRepairFixture $customImage '' $true $false $true
    }
    Write-Host '[PASS] Only the literal legacy FreeBSD default is repaired; custom references/private fields remain unchanged, malformed metadata fails, and replacements are private/root-owned.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
