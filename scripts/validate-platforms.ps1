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

function Forbid-Text([string]$Relative, [string[]]$Patterns) {
    $content = Read-RepoFile $Relative
    foreach ($pattern in $Patterns) {
        if ($content -match $pattern) {
            throw "Forbidden platform contract '$pattern' is present in $Relative"
        }
    }
    Write-Host "[PASS] Forbidden platform behavior absent: $Relative"
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
    'Preserved existing /etc/tautweekly/tautweekly\.env',
    '\.tautweekly-operation\.lock',
    'RELEASE-METADATA\.txt',
    'tautweekly-check-release',
    'systemctl is-active --quiet tautweekly\.service'
)
Require-Text 'platforms/linux/check-release.sh' @(
    'releases/latest',
    'TAUTWEEKLY_LATEST_RELEASE_VERSION',
    'Latest stable release',
    'A stable update is available'
)
Require-Text 'platforms/linux/tautweekly' @('check-update', 'tautweekly-check-release')
Require-Text 'platforms/freebsd-podman/rc.d/tautweekly' @(
    'REQUIRE: NETWORKING linux podman',
    '--os=linux',
    'TAUTWEEKLY_PREVIEW_BIND:=127\.0\.0\.1',
    'TAUTWEEKLY_PODMAN_BIN:=/usr/local/bin/podman',
    '/var/db/tautweekly'
)
Require-Text 'platforms/freebsd-podman/install-freebsd.sh' @(
    'sysrc linux_enable=YES',
    '/usr/local/sbin/tautweekly update',
    'Preserved existing /usr/local/etc/tautweekly/tautweekly\.env'
)
Forbid-Text 'platforms/freebsd-podman/rc.d/tautweekly' @('io\.containers\.autoupdate')
Require-Text 'platforms/freebsd-podman/tautweekly' @(
    'check-update',
    'flock -n /data/\.tautweekly-operation\.lock',
    '\.tautweekly-update-holder',
    'pull --os=linux',
    'Rollback to image version',
    'health verification',
    'run-script\.sh',
    'run-as-user\.sh /bin/bash'
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
    'NEXT \(Unraid Console\): \/opt\/tautweekly\/bin\/run-script\.sh Verify-Setup\.ps1',
    'NEXT \(Compose host project directory\): \.\/tautweekly\.sh verify',
    'Metadata readiness before Verify, Preview, or TestEmail',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info',
    'current Tautulli control is per library',
    'Routine TautWeekly updates do'
)
Require-Text 'platforms/nas-docker/app/Verify-Setup.ps1' @(
    'Unraid Console:',
    '\/opt\/tautweekly\/bin\/run-mode\.sh ListUsers',
    'Compose host project directory:',
    '\.\/tautweekly\.sh list-users',
    'prove metadata freshness',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info'
)
Require-Text 'platforms/windows/SETUP-FIRST.ps1' @(
    'Metadata readiness before Verify, Preview, or TestEmail',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info',
    'current Tautulli control is per library',
    'Routine TautWeekly updates do'
)
Require-Text 'platforms/windows/VERIFY-SETUP.ps1' @(
    'prove metadata freshness',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info'
)
Require-Text 'platforms/mac-docker/app/Setup-First.ps1' @(
    'Metadata readiness before Verify, Preview, or TestEmail',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info',
    'current Tautulli control is per library',
    'Routine TautWeekly updates do'
)
Require-Text 'platforms/mac-docker/app/Verify-Setup.ps1' @(
    'prove metadata freshness',
    'Refresh All Metadata',
    'Library > Media Info > Refresh media info'
)
foreach ($relative in @(
    'platforms/windows/Windows-Update.ps1',
    'platforms/nas-docker/container-update.sh',
    'platforms/mac-docker/mac-update.sh',
    'platforms/linux/install-linux.sh',
    'platforms/freebsd-podman/tautweekly'
)) {
    Require-Text $relative @(
        'missing ratings/artwork|ratings/artwork\s+recovery update',
        'Refresh All Metadata',
        'Library > Media Info > Refresh media info'
    )
}
foreach ($relative in @(
    'platforms/nas-docker/app/preview-home.html',
    'platforms/mac-docker/app/preview-home.html'
)) {
    Require-Text $relative @(
        'Prepare Plex and Tautulli metadata before testing',
        'Refresh All Metadata',
        'Refresh media\s+info',
        'current control is per library'
    )
}
foreach ($relative in @(
    'platforms/nas-docker/qnap-install.sh',
    'platforms/mac-docker/mac-install.sh'
)) {
    Require-Text $relative @(
        'Prepare Plex and Tautulli metadata before acceptance',
        'Refresh All Metadata',
        'Refresh media\s+info',
        'press Enter to run verification'
    )
}
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
    'Operation-Lock\.ps1',
    'Enter-TautWeeklyOperationLock',
    'Send-TautWeeklySmtpMessage',
    'ListUsers only displays the roster'
)
foreach ($relative in @(
    'platforms/windows/DeletedItemCache.ps1',
    'platforms/nas-docker/app/DeletedItemCache.ps1',
    'platforms/mac-docker/app/DeletedItemCache.ps1'
)) {
    Require-Text $relative @(
        'TwDeletedCacheSchemaVersion = 1',
        'DeletedItemCacheRetentionDays',
        'DeletedItemCacheMaxItems',
        'DeletedItemCacheMaxBytesMB',
        'Get-TwDeletedCacheId',
        'File\]::Replace',
        'index\.backup\.json',
        'Get-FileHash -LiteralPath \$source -Algorithm SHA256',
        '\$fileName -eq \(\$id \+ "\.jpg"\)'
    )
}
$cacheModuleReference = (Read-RepoFile 'platforms/windows/DeletedItemCache.ps1') -replace "`r`n", "`n"
foreach ($relative in @(
    'platforms/nas-docker/app/DeletedItemCache.ps1',
    'platforms/mac-docker/app/DeletedItemCache.ps1'
)) {
    $candidate = (Read-RepoFile $relative) -replace "`r`n", "`n"
    if ($candidate.TrimEnd() -cne $cacheModuleReference.TrimEnd()) {
        throw "Deleted-item cache implementation drifted across renderers: $relative"
    }
}
Write-Host '[PASS] Deleted-item cache schema and implementation remain identical across renderers.'
foreach ($relative in @(
    'platforms/windows/SETUP-FIRST.ps1',
    'platforms/nas-docker/app/Setup-First.ps1',
    'platforms/mac-docker/app/Setup-First.ps1'
)) {
    Require-Text $relative @(
        'Get-ExistingBooleanValue',
        'Get-ExistingBoundedInteger',
        'DeletedItemCacheEnabled',
        'DeletedItemCacheRetentionDays.*1 3650',
        'DeletedItemCacheMaxItems.*1 10000',
        'DeletedItemCacheMaxBytesMB.*16 2048',
        'Ratings Source to',
        'Rotten Tomatoes, then refresh affected metadata',
        'Verification tests the resolved connection without printing the token'
    )
}
foreach ($relative in @(
    'platforms/nas-docker/app/Verify-Setup.ps1',
    'platforms/mac-docker/app/Verify-Setup.ps1',
    'platforms/windows/VERIFY-SETUP.ps1'
)) {
    Require-Text $relative @(
        'SMTP authentication and sender authorization are not tested by verify',
        '-Mode VerifyPlex',
        'Direct Plex identity and authenticated library requests succeeded',
        'complete movie RT critic/audience ratings',
        'Reachability does not select a movie rating provider',
        'Ratings Source > Rotten Tomatoes'
    )
}
foreach ($relative in @(
    'platforms/nas-docker/app/TautWeekly.ps1',
    'platforms/mac-docker/app/TautWeekly.ps1',
    'platforms/windows/TautWeekly.ps1'
)) {
    Require-Text $relative @(
        '"VerifyPlex"',
        'function Test-TautWeeklyDirectPlexConnection',
        '"/identity"',
        '"/library/sections"',
        'X-Plex-Token',
        'Direct Plex verification passed'
    )
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
    'numeric value shown by list-users',
    'check-update',
    'container-update\.sh apply',
    'run-script\.sh Verify-Setup\.ps1',
    'run-as-user\.sh bash'
)
Require-Text 'platforms/nas-docker/app/bin/run-as-user.sh' @(
    'PUID/PGID 0 is refused',
    'find "\$data_root" -xdev',
    '-exec chown -h',
    'exec gosu'
)
Require-Text 'platforms/nas-docker/app/bin/run-script.sh' @(
    'Verify-Setup\.ps1',
    'Schedule-Control\.ps1',
    'Unsupported TautWeekly helper script',
    'run-as-user\.sh'
)
Require-Text 'platforms/nas-docker/container-update.sh' @(
    'config --images',
    '\.tautweekly-operation\.lock',
    '\.tautweekly-update-holder',
    'compose_cmd pull tautweekly',
    'up -d --no-build',
    'wait_for_health',
    'no repository version label',
    'Restoring the previous image'
)
Forbid-Text 'platforms/nas-docker/compose.yaml' @('image:\s*.*:edge')
Require-Text 'platforms/nas-docker/compose.yaml' @('ghcr\.io/sparkmoxie/tautweekly:latest')
Require-Text 'platforms/nas-docker/compose.qnap.yaml' @('ghcr\.io/sparkmoxie/tautweekly:latest')

Require-Text 'platforms/mac-docker/check-release.sh' @(
    'releases/latest',
    'TAUTWEEKLY_LATEST_RELEASE_VERSION',
    'Latest stable release'
)
Require-Text 'platforms/mac-docker/mac-update.sh' @(
    'BUILD_VERSION',
    '\.tautweekly-operation\.lock',
    '\.tautweekly-update-holder',
    'wait_for_health',
    'verified stable release package',
    'Rollback to macOS image version'
)
Require-Text 'platforms/mac-docker/Dockerfile' @('ARG BUILD_VERSION=dev', 'org\.opencontainers\.image\.version="\$BUILD_VERSION"')
Require-Text 'platforms/mac-docker/compose.yaml' @('image:\s*tautweekly-mac:stable')
Forbid-Text 'platforms/mac-docker/compose.yaml' @('(?m)^\s*build:')
Forbid-Text 'platforms/mac-docker/tautweekly.sh' @('docker compose build --pull', 'docker-compose build --pull')
Require-Text 'platforms/mac-docker/tautweekly.sh' @(
    'run-script\.sh Verify-Setup\.ps1',
    'run-as-user\.sh bash'
)

Require-Text 'platforms/windows/Check-Update.ps1' @(
    'releases/latest',
    'Latest stable release',
    'A stable update is available',
    'SHA-256 checksum verified',
    'Windows-Update\.ps1',
    'Apply this stable update safely',
    'Start-Process.*-Verb RunAs'
)
Require-Text 'platforms/windows/Windows-Update.ps1' @(
    'Enter-TautWeeklyOperationLock',
    'RELEASE-FILES\.txt',
    'Disable-ScheduledTask',
    'Enable-ScheduledTask',
    'backup-v',
    'restored automatically',
    'Assert-ManifestFiles',
    'Assert-PowerShellSyntax'
)
Require-Text 'platforms/windows/Operation-Lock.ps1' @(
    '\.tautweekly-operation\.lock',
    'FileShare\]::None',
    'Another TautWeekly operation is already running'
)
Require-Text 'platforms/windows/17-CHECK-FOR-UPDATE.bat' @('Check-Update\.ps1', '-PromptForUpdate', 'pause')

foreach ($relative in @(
    'docs/windows/README.md',
    'docs/nas-docker/README.md',
    'docs/mac/README.md',
    'docs/linux/README.md',
    'docs/freebsd/README.md'
)) {
    Require-Text $relative @('check', 'stable', 'rollback|restore')
}

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
    'app/bin/run-as-user.sh',
    'app/bin/run-script.sh',
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
