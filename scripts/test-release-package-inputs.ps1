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
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
