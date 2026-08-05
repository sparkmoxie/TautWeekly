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
    'Setup-First\.ps1'
)
Require-Text 'platforms/nas-docker/app/preview-home.html' @(
    'Preview server online',
    'not an admin Web UI',
    '\/data\/config\.json',
    'preview-all-00-INDEX\.html'
)
Require-Text 'platforms/nas-docker/app/User-Exclusions.ps1' @(
    'get_user_names',
    'get_users',
    'ConvertTo-TautWeeklySelectableUsers',
    'DetailsAvailable'
)
Require-Text 'platforms/nas-docker/tautweekly.sh' @(
    '\.\/tautweekly\.sh setup',
    '\.\/tautweekly\.sh start',
    '\.\/tautweekly\.sh stop'
)

foreach ($relative in @(
    'app/entrypoint.sh',
    'app/healthcheck.sh',
    'app/preview-home.html',
    'app/run-service.sh',
    'app/bin/run-mode.sh',
    'app/Scheduler.ps1'
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
