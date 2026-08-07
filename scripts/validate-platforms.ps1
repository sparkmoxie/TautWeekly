[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)

function Read-RepoFile([string]$Relative) {
    return [IO.File]::ReadAllText((Join-Path $Root $Relative))
}

function Require-Text([string]$Relative, [string[]]$Patterns) {
    $content = Read-RepoFile $Relative
    foreach ($pattern in $Patterns) {
        if ($content -notmatch $pattern) {
            throw "Required platform contract '$pattern' is missing from $Relative"
        }
    }
    Write-Host "[PASS] Platform contract: $Relative"
}

Require-Text 'platforms/linux/systemd/tautweekly.service' @(
    'User=tautweekly',
    'ProtectSystem=strict',
    'ReadWritePaths=/var/lib/tautweekly',
    'NoNewPrivileges=true'
)
Require-Text 'platforms/linux/tautweekly.env.example' @(
    'TAUTWEEKLY_PREVIEW_BIND=127\.0\.0\.1',
    'TAUTWEEKLY_DATA_DIR=/var/lib/tautweekly'
)
Require-Text 'platforms/linux/install-linux.sh' @(
    'PowerShell 7\.2 or newer',
    'program-\$stamp\.tar\.gz',
    'Preserved existing /etc/tautweekly/tautweekly\.env'
)
Require-Text 'platforms/freebsd-podman/rc.d/tautweekly' @(
    'REQUIRE: NETWORKING linux podman',
    '--os=linux',
    'TAUTWEEKLY_PREVIEW_BIND:=127\.0\.0\.1',
    'TAUTWEEKLY_PODMAN_BIN:=/usr/local/bin/podman',
    '/var/db/tautweekly'
)
Require-Text 'platforms/freebsd-podman/install-freebsd.sh' @(
    'sysrc linux_enable=YES',
    'podman pull --os=linux',
    'Preserved existing /usr/local/etc/tautweekly/tautweekly\.env'
)
Require-Text 'platforms/nas-docker/app/run-service.sh' @(
    'Preview server listening',
    'curl --fail --silent --max-time 2',
    'service-heartbeat\.json',
    'write_service_heartbeat',
    'Preview server exited unexpectedly',
    'Scheduler exited unexpectedly'
)
Require-Text 'platforms/nas-docker/app/healthcheck.sh' @(
    'service-heartbeat\.json',
    'TAUTWEEKLY_HEALTH_HEARTBEAT_MAX_SECONDS',
    'Service supervisor heartbeat is stale',
    '\[WARN\] Preview asset movies\.gif is unavailable'
)
Require-Text 'platforms/nas-docker/app/Scheduler.ps1' @(
    'only reads \$configPath',
    'run \.\/tautweekly\.sh setup',
    'Setup-First\.ps1',
    'Get-TautWeeklyScheduleNow',
    'TimeZoneId = \$scheduleTimeZone\.Id'
)
Require-Text 'platforms/nas-docker/app/Schedule-Time.ps1' @(
    'FindSystemTimeZoneById',
    'ConvertTime',
    'ConvertTimeToUtc',
    'refusing to fall back to UTC'
)
Require-Text 'platforms/nas-docker/app/preview-home.html' @(
    'Preview server online',
    'not an admin Web UI',
    '\/data\/config\.json',
    'preview-all-00-INDEX\.html',
    'run-mode\.sh PreviewAll USER_ID',
    'does not select or save a default user',
    'host-side Compose wrapper',
    'not installed inside the container'
)
Require-Text 'platforms/nas-docker/app/Setup-First.ps1' @(
    'NEXT \(Unraid Console\): pwsh .*\/opt\/tautweekly\/Verify-Setup\.ps1',
    'NEXT \(Compose host project directory\): \.\/tautweekly\.sh verify'
)
Require-Text 'platforms/nas-docker/app/Verify-Setup.ps1' @(
    'Unraid Console:',
    '\/opt\/tautweekly\/bin\/run-mode\.sh ListUsers',
    'Compose host project directory:',
    '\.\/tautweekly\.sh list-users'
)
Require-Text 'docs/nas-docker/README.md' @(
    'host-side Compose wrapper',
    'does not exist inside the Unraid Apps container',
    "Unraid's Docker controls"
)
Require-Text 'docs/nas-docker/index.html' @(
    'wrapper does not exist inside the container',
    'host-side <code>\.\/tautweekly\.sh</code> Compose wrapper is not installed inside the Unraid Apps container',
    "Unraid's Docker controls"
)
Require-Text 'platforms/nas-docker/app/Smtp-Transport.ps1' @(
    "Command 'AUTH LOGIN'",
    "Command 'AUTH PLAIN'",
    "ExpectedCodes 235",
    'Authentication must complete with 235 before any envelope command',
    'MAIL FROM'
)
Require-Text 'platforms/nas-docker/app/TautWeekly.ps1' @(
    'Smtp-Transport\.ps1',
    'Send-TautWeeklySmtpMessage',
    'ListUsers only displays the roster',
    'Get-TautWeeklyScheduleNow -TimeZone \$deliveryTimeZone',
    'ConvertTo-TautWeeklyScheduleUtc -TimeZone \$deliveryTimeZone'
)
Require-Text 'platforms/windows/TautWeekly.ps1' @(
    'Smtp-Transport\.ps1',
    'Send-TautWeeklySmtpMessage',
    'ListUsers only displays the roster'
)
foreach ($relative in @(
    'platforms/nas-docker/app/Verify-Setup.ps1',
    'platforms/mac-docker/app/Verify-Setup.ps1',
    'platforms/windows/VERIFY-SETUP.ps1'
)) {
    Require-Text $relative @('SMTP authentication and sender authorization are not tested by verify')
}
Require-Text 'platforms/nas-docker/app/User-Exclusions.ps1' @(
    'get_user_names',
    'get_users',
    'ConvertTo-TautWeeklySelectableUsers',
    'DetailsAvailable'
)
Require-Text 'platforms/nas-docker/tautweekly.sh' @(
    '\.\/tautweekly\.sh setup',
    'list-libraries',
    'manage-libraries',
    '\.\/tautweekly\.sh start',
    '\.\/tautweekly\.sh stop',
    'preview-all USER_ID',
    'numeric value shown by list-users'
)

Require-Text 'platforms/linux/tautweekly' @('list-libraries', 'manage-libraries', 'Manage-Library-Selection\.ps1')
Require-Text 'platforms/freebsd-podman/tautweekly' @('list-libraries', 'manage-libraries', 'Manage-Library-Selection\.ps1')

foreach ($relative in @(
    'platforms/windows/Library-Selection.ps1',
    'platforms/windows/Manage-Library-Selection.ps1',
    'platforms/nas-docker/app/Library-Selection.ps1',
    'platforms/nas-docker/app/Manage-Library-Selection.ps1',
    'platforms/mac-docker/app/Library-Selection.ps1',
    'platforms/mac-docker/app/Manage-Library-Selection.ps1'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $relative))) {
        throw "Required library-selection source is missing: $relative"
    }
}
Write-Host '[PASS] Every directly shipped runtime contains library-selection management source.'

foreach ($relative in @(
    'app/entrypoint.sh',
    'app/healthcheck.sh',
    'app/preview-home.html',
    'app/run-service.sh',
    'app/bin/run-mode.sh',
    'app/Schedule-Time.ps1',
    'app/Schedule-Control.ps1',
    'app/Scheduler.ps1',
    'app/Smtp-Transport.ps1'
)) {
    $nas = Read-RepoFile ("platforms/nas-docker/$relative")
    $mac = Read-RepoFile ("platforms/mac-docker/$relative")
    if ($nas -cne $mac) {
        throw "Shared runtime wrapper drifted between NAS and macOS: $relative"
    }
}
Write-Host '[PASS] Shared runtime wrappers remain identical across container editions.'

$forbiddenRuntimeNames = @('config.json', '.env', 'state.json', 'access-state.json', 'scheduler-state.json', 'scheduler-heartbeat.json', 'service-heartbeat.json')
foreach ($platform in @('linux', 'freebsd-podman')) {
    $path = Join-Path (Join-Path $Root 'platforms') $platform
    $forbidden = @(Get-ChildItem -LiteralPath $path -Recurse -Force | Where-Object {
        (-not $_.PSIsContainer -and $_.Name -in $forbiddenRuntimeNames) -or
        ($_.PSIsContainer -and $_.Name -in @('logs', 'output'))
    })
    if ($forbidden) {
        throw "Forbidden runtime material is present in ${platform}: $($forbidden.FullName -join ', ')"
    }
}
Write-Host '[PASS] Linux and FreeBSD source packages contain no runtime data.'
