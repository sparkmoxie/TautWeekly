[CmdletBinding()]
param(
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string]$Message)
    $script:failures.Add($Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Add-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

$required = @(
    'README.md', 'LICENSE', 'SECURITY.md', 'CONTRIBUTING.md', 'CHANGELOG.md',
    'CODE_OF_CONDUCT.md', 'THIRD_PARTY_NOTICES.md', '.gitignore', '.gitattributes',
    'ca_profile.xml', 'templates/tautweekly.xml',
    'platforms/windows/TautWeekly.ps1',
    'platforms/nas-docker/compose.yaml',
    'platforms/nas-docker/compose.qnap.yaml',
    'platforms/nas-docker/tautweekly.sh',
    'platforms/nas-docker/app/TautWeekly.ps1',
    'platforms/mac-docker/compose.yaml',
    'platforms/mac-docker/tautweekly.sh',
    'platforms/mac-docker/app/TautWeekly.ps1',
    'platforms/linux/install-linux.sh',
    'platforms/linux/tautweekly',
    'platforms/linux/systemd/tautweekly.service',
    'platforms/freebsd-podman/install-freebsd.sh',
    'platforms/freebsd-podman/tautweekly',
    'platforms/freebsd-podman/rc.d/tautweekly',
    'docs/index.html', 'docs/windows/README.md', 'docs/nas-docker/README.md',
    'docs/mac/README.md', 'docs/linux/README.md', 'docs/freebsd/README.md',
    'scripts/build-releases.ps1', 'scripts/validate-platforms.ps1',
    'scripts/validate-unraid-template.ps1',
    '.github/workflows/ci.yml', '.github/workflows/pages.yml',
    '.github/workflows/release.yml',
    '.github/workflows/container.yml'
)

foreach ($relative in $required) {
    $path = Join-Path $Root $relative
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Failure "Required path is missing: $relative"
    }
}
if ($failures.Count -eq 0) { Add-Pass "Required repository structure is present." }

$forbiddenNames = @(
    'config.json', '.env', 'state.json', 'access-state.json',
    'scheduler-state.json'
)
$forbiddenDirectories = @('logs', 'output')

$items = Get-ChildItem -LiteralPath $Root -Force -Recurse |
    Where-Object { $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' }

foreach ($item in $items) {
    $relative = $item.FullName.Substring($Root.Length).TrimStart('\','/')
    if (-not $item.PSIsContainer -and $item.Name -in $forbiddenNames) {
        Add-Failure "Forbidden runtime file is present: $relative"
    }
    if ($item.PSIsContainer -and $item.Name -in $forbiddenDirectories) {
        Add-Failure "Forbidden runtime directory is present: $relative"
    }
    if (-not $item.PSIsContainer -and $item.Extension -in @('.log', '.pfx', '.pem', '.key')) {
        Add-Failure "Forbidden credential/log file is present: $relative"
    }
}
if (-not ($items | Where-Object {
    (-not $_.PSIsContainer -and ($_.Name -in $forbiddenNames -or $_.Extension -in @('.log','.pfx','.pem','.key'))) -or
    ($_.PSIsContainer -and $_.Name -in $forbiddenDirectories)
})) { Add-Pass "No forbidden runtime or credential files are present." }

$textExtensions = @('.ps1','.psm1','.sh','.command','.bat','.json','.yaml','.yml','.md','.txt','.html','.css','.js','.xml','.env','.example')
$textNames = @('LICENSE','Dockerfile','.gitignore','.gitattributes','.dockerignore')
$textFiles = Get-ChildItem -LiteralPath $Root -Force -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' -and
    $_.FullName -notmatch '[\\/]dist(?:[\\/]|$)' -and
    ($_.Extension -in $textExtensions -or $_.Name -in $textNames)
}

$retiredBrandPattern = '(?i)Plex' + '[\s_.-]*' + 'Weekly'
$retiredBrandFindings = [System.Collections.Generic.List[string]]::new()
foreach ($item in $items) {
    if ($item.Name -match $retiredBrandPattern) {
        $relative = $item.FullName.Substring($Root.Length).TrimStart('\','/')
        $retiredBrandFindings.Add("path: $relative")
    }
}
foreach ($file in $textFiles) {
    $content = [IO.File]::ReadAllText($file.FullName)
    if ($content -match $retiredBrandPattern) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\','/')
        $retiredBrandFindings.Add("text: $relative")
    }
}
if ($retiredBrandFindings.Count -gt 0) {
    Add-Failure "Retired product branding is present: $($retiredBrandFindings -join ', ')"
}
else {
    Add-Pass 'No retired product branding is present in paths or text files.'
}

$checks = [ordered]@{
    'private IPv4 address' = '(?<!\d)(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})(?!\d)'
    'Windows user path' = '(?i)[A-Z]:\\Users\\[^\\\s"<>]+'
    'Unix user path' = '(?i)/(?:Users|home)/[^/\s"<>]+'
    'GitHub token' = '(?i)\bgh[pousr]_[A-Za-z0-9]{20,}\b'
    'private key block' = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
}

foreach ($file in $textFiles) {
    $content = [IO.File]::ReadAllText($file.FullName)
    $relative = $file.FullName.Substring($Root.Length).TrimStart('\','/')
    foreach ($check in $checks.GetEnumerator()) {
        if ($content -match $check.Value) {
            Add-Failure "$($check.Key) found in $relative"
        }
    }

    foreach ($emailMatch in [regex]::Matches($content, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b')) {
        $email = $emailMatch.Value.ToLowerInvariant()
        if ($email -notmatch '@(?:example\.com|example\.org|example\.net|users\.noreply\.github\.com)$') {
            Add-Failure "Non-example email address found in ${relative}: $email"
        }
    }
}
if ($failures.Count -eq 0) { Add-Pass "Privacy and high-confidence secret patterns are clean." }

$jsonFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.json' |
    Where-Object { $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' }
foreach ($json in $jsonFiles) {
    try {
        [void](Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json)
    }
    catch {
        Add-Failure "Invalid JSON: $($json.FullName.Substring($Root.Length).TrimStart('\','/')) - $($_.Exception.Message)"
    }
}
if ($jsonFiles.Count -gt 0 -and -not ($failures | Where-Object { $_ -like 'Invalid JSON:*' })) {
    Add-Pass "Parsed $($jsonFiles.Count) JSON file(s)."
}

$examples = Get-ChildItem -LiteralPath (Join-Path $Root 'platforms') -Recurse -File -Filter 'config.example.json'
foreach ($example in $examples) {
    $config = Get-Content -LiteralPath $example.FullName -Raw | ConvertFrom-Json
    if ([string]$config.ApiKey -notmatch '^PASTE_') {
        Add-Failure "ApiKey is not a placeholder in $($example.FullName.Substring($Root.Length).TrimStart('\','/'))"
    }
    if ([string]$config.SmtpPassword -notmatch '^PASTE_') {
        Add-Failure "SmtpPassword is not a placeholder in $($example.FullName.Substring($Root.Length).TrimStart('\','/'))"
    }
    if (-not [string]::IsNullOrEmpty([string]$config.PlexToken)) {
        Add-Failure "PlexToken must be blank in $($example.FullName.Substring($Root.Length).TrimStart('\','/'))"
    }
}
if (-not ($failures | Where-Object { $_ -like '*placeholder*' -or $_ -like 'PlexToken must*' })) {
    Add-Pass "Sanitized configuration examples use safe placeholders."
}

if ($failures.Count -gt 0) {
    throw "Repository validation failed with $($failures.Count) finding(s)."
}

Write-Host "Repository validation passed." -ForegroundColor Green
