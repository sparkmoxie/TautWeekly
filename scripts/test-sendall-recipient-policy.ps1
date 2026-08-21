[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$PythonPath = 'python'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$fakeTautulli = Join-Path $Root 'scripts/test-support/fake-tautulli.py'
$fakeSmtp = Join-Path $Root 'scripts/test-support/fake-smtp.py'
$headlessRunner = Join-Path $Root 'scripts/test-support/invoke-renderer-headless.ps1'
$powerShell7 = Get-Command pwsh -ErrorAction SilentlyContinue
$windowsHost = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe' } else { '' }

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-FreeTcpPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function New-VirtualUser([string]$Id, [string]$Email, [int]$Active = 1, [int]$Notify = 1) {
    return [PSCustomObject]@{
        user_id = $Id
        username = "viewer-$Id"
        friendly_name = "Virtual Viewer $Id"
        email = $Email
        is_active = $Active
        deleted_user = 0
        do_notify = $Notify
    }
}

$scenarios = @(
    [PSCustomObject]@{
        Name = 'all-legacy-notify-disabled'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com' -Notify 0),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com' -Notify 0)
        )
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = ''
        FreshAccessState = $true
        ExitCode = 0
        Outcome = 'succeeded'
        ErrorCategory = ''
        Accepted = 2
        Skipped = 0
        Failed = 0
        Reasons = @(0, 0, 0, 0)
    },
    [PSCustomObject]@{
        Name = 'stale-manager-discovery-new-user'
        DiscoveryUsers = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com')
        )
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com'),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com')
        )
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = ''
        FreshAccessState = $false
        ExitCode = 0
        Outcome = 'succeeded'
        ErrorCategory = ''
        Accepted = 2
        Skipped = 0
        Failed = 0
        Reasons = @(0, 0, 0, 0)
    },
    [PSCustomObject]@{
        Name = 'mixed-fixed-skip-reasons'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com' -Notify 0),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com' -Active 0),
            (New-VirtualUser -Id '3' -Email ''),
            (New-VirtualUser -Id '4' -Email 'viewer4@example.com'),
            (New-VirtualUser -Id '5' -Email 'viewer5@example.com')
        )
        ExcludedUserIds = @('4')
        ExcludedEmails = @('viewer5@example.com')
        RejectRecipient = ''
        FreshAccessState = $false
        ExitCode = 0
        Outcome = 'succeeded'
        ErrorCategory = ''
        Accepted = 1
        Skipped = 4
        Failed = 0
        Reasons = @(1, 1, 1, 1)
    },
    [PSCustomObject]@{
        Name = 'all-explicitly-excluded'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com'),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com')
        )
        ExcludedUserIds = @('1')
        ExcludedEmails = @('viewer2@example.com')
        RejectRecipient = ''
        FreshAccessState = $false
        ExitCode = 3
        Outcome = 'failed'
        ErrorCategory = 'no-eligible-recipients'
        Accepted = 0
        Skipped = 2
        Failed = 0
        Reasons = @(0, 0, 1, 1)
    },
    [PSCustomObject]@{
        Name = 'partial-smtp-failure'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com'),
            (New-VirtualUser -Id '2' -Email 'viewer2@example.com')
        )
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = 'viewer2@example.com'
        FreshAccessState = $false
        ExitCode = 2
        Outcome = 'partial'
        ErrorCategory = ''
        Accepted = 1
        Skipped = 0
        Failed = 1
        Reasons = @(0, 0, 0, 0)
    },
    [PSCustomObject]@{
        Name = 'required-roster-refresh-failure'
        Users = @(
            (New-VirtualUser -Id '1' -Email 'viewer1@example.com')
        )
        FailRefresh = $true
        ExcludedUserIds = @()
        ExcludedEmails = @()
        RejectRecipient = ''
        FreshAccessState = $false
        ExitCode = 1
        Outcome = 'failed'
        ErrorCategory = 'user-roster-refresh-failed'
        Accepted = 0
        Skipped = 0
        Failed = 0
        Reasons = @(0, 0, 0, 0)
    }
)

$engines = @(
    [PSCustomObject]@{ Name = 'windows'; Source = 'platforms/windows'; Host = $windowsHost; Container = $false },
    [PSCustomObject]@{ Name = 'nas-docker-linux-freebsd'; Source = 'platforms/nas-docker/app'; Host = $(if ($powerShell7) { $powerShell7.Source } else { '' }); Container = $true },
    [PSCustomObject]@{ Name = 'mac-docker'; Source = 'platforms/mac-docker/app'; Host = $(if ($powerShell7) { $powerShell7.Source } else { '' }); Container = $true }
)

$executed = 0
foreach ($engine in $engines) {
    if ([string]::IsNullOrWhiteSpace([string]$engine.Host) -or -not (Test-Path -LiteralPath $engine.Host)) {
        Write-Warning "Skipping $($engine.Name) because its PowerShell runtime is unavailable."
        continue
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-sendall-policy-' + [Guid]::NewGuid().ToString('N'))
    $appRoot = Join-Path $tempRoot 'app'
    $dataRoot = Join-Path $tempRoot 'data'
    $usersFile = Join-Path $tempRoot 'users.json'
    $refreshUsersFile = Join-Path $tempRoot 'refresh-users.json'
    $failRefreshFile = Join-Path $tempRoot 'fail-refresh.flag'
    $tautulliLog = Join-Path $tempRoot 'tautulli-calls.jsonl'
    $tautulliReady = Join-Path $tempRoot 'tautulli-ready.txt'
    $tautulliStdout = Join-Path $tempRoot 'tautulli.stdout.txt'
    $tautulliStderr = Join-Path $tempRoot 'tautulli.stderr.txt'
    New-Item -ItemType Directory -Force -Path $appRoot, $dataRoot | Out-Null
    Copy-Item -Path (Join-Path (Join-Path $Root ([string]$engine.Source)) '*') -Destination $appRoot -Recurse -Force

    $tautulli = $null
    try {
        ConvertTo-Json -InputObject @($scenarios[0].Users) -Depth 8 | Set-Content -LiteralPath $usersFile -Encoding UTF8
        $tautulliPort = Get-FreeTcpPort
        $tautulli = Start-Process -FilePath $PythonPath -ArgumentList @(
            '-u', $fakeTautulli, '--port', [string]$tautulliPort, '--scenario', 'quiet',
            '--users-file', $usersFile, '--refresh-users-file', $refreshUsersFile,
            '--fail-refresh-file', $failRefreshFile, '--call-log', $tautulliLog, '--ready-file', $tautulliReady
        ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $tautulliStdout -RedirectStandardError $tautulliStderr
        for ($attempt = 0; $attempt -lt 100 -and -not (Test-Path $tautulliReady); $attempt++) {
            if ($tautulli.HasExited) { throw "Virtual Tautulli exited early: $(Get-Content $tautulliStderr -Raw -ErrorAction SilentlyContinue)" }
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path $tautulliReady) "Virtual Tautulli did not become ready for $($engine.Name)."
        $baseUrl = (Get-Content $tautulliReady -Raw).Trim()

        if ($engine.Container) {
            New-Item -ItemType Directory -Force -Path (Join-Path $dataRoot 'assets') | Out-Null
            Copy-Item -Path (Join-Path $appRoot 'assets-default/*') -Destination (Join-Path $dataRoot 'assets') -Recurse -Force
            $configPath = Join-Path $dataRoot 'config.json'
        }
        else {
            $configPath = Join-Path $appRoot 'config.json'
        }

        foreach ($scenario in $scenarios) {
            $discoveryUsers = if ($null -ne $scenario.PSObject.Properties['DiscoveryUsers']) { @($scenario.DiscoveryUsers) } else { @($scenario.Users) }
            ConvertTo-Json -InputObject @($discoveryUsers) -Depth 8 | Set-Content -LiteralPath $usersFile -Encoding UTF8
            if ($null -ne $scenario.PSObject.Properties['DiscoveryUsers']) {
                ConvertTo-Json -InputObject @($scenario.Users) -Depth 8 | Set-Content -LiteralPath $refreshUsersFile -Encoding UTF8
            }
            else {
                [IO.File]::WriteAllText($refreshUsersFile, '')
            }
            if ($null -ne $scenario.PSObject.Properties['FailRefresh'] -and [bool]$scenario.FailRefresh) {
                New-Item -ItemType File -Force -Path $failRefreshFile | Out-Null
            }
            else {
                Remove-Item -LiteralPath $failRefreshFile -Force -ErrorAction SilentlyContinue
            }
            $userProbe = Invoke-RestMethod -Uri ($baseUrl + '/api/v2?apikey=virtual-api-key&cmd=get_users') -Method Get
            Assert-True (@($userProbe.response.data).Count -eq @($discoveryUsers).Count) "$($engine.Name)/$($scenario.Name) virtual discovery roster did not load deterministically."
            $callBaseline = @(Get-Content -LiteralPath $tautulliLog -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
            $smtpPort = Get-FreeTcpPort
            $smtpLog = Join-Path $tempRoot ("smtp-$($scenario.Name).jsonl")
            $smtpReady = Join-Path $tempRoot ("smtp-$($scenario.Name)-ready.txt")
            $smtpStdout = Join-Path $tempRoot ("smtp-$($scenario.Name).stdout.txt")
            $smtpStderr = Join-Path $tempRoot ("smtp-$($scenario.Name).stderr.txt")
            $smtpArguments = @('-u', $fakeSmtp, '--port', [string]$smtpPort, '--call-log', $smtpLog, '--ready-file', $smtpReady)
            if (-not [string]::IsNullOrWhiteSpace([string]$scenario.RejectRecipient)) {
                $smtpArguments += @('--reject-recipient', [string]$scenario.RejectRecipient)
            }
            $smtp = $null
            $smtp = Start-Process -FilePath $PythonPath -ArgumentList $smtpArguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $smtpStdout -RedirectStandardError $smtpStderr
            try {
                for ($attempt = 0; $attempt -lt 100 -and -not (Test-Path $smtpReady); $attempt++) {
                    if ($smtp.HasExited) { throw "Virtual SMTP exited early: $(Get-Content $smtpStderr -Raw -ErrorAction SilentlyContinue)" }
                    Start-Sleep -Milliseconds 50
                }
                Assert-True (Test-Path $smtpReady) "Virtual SMTP did not become ready for $($engine.Name)/$($scenario.Name)."

                $config = Get-Content (Join-Path $appRoot 'config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                $overrides = [ordered]@{
                    TautulliUrl = $baseUrl; ApiKey = 'virtual-api-key'; PlexServerUrl = $baseUrl; PlexToken = 'virtual-plex-token'
                    FooterServerName = 'Virtual Plex'; IncludedLibraryIds = @('10', '20')
                    ExcludedUserIds = @($scenario.ExcludedUserIds); ExcludedEmails = @($scenario.ExcludedEmails)
                    DaysBack = 7; MaxMovies = 2; MaxTv = 2; SendDelaySeconds = 0
                    SmtpHost = '127.0.0.1'; SmtpPort = $smtpPort; SmtpEnableSsl = $false; SmtpUseAuthentication = $false; SmtpTimeoutSeconds = 5
                    FromEmail = 'sender@example.com'; FromName = 'TautWeekly Policy Test'; TestEmail = 'test@example.com'
                }
                foreach ($entry in $overrides.GetEnumerator()) { $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force }
                $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8

                $accessUsers = [ordered]@{}
                foreach ($user in @($scenario.Users)) {
                    $accessUsers[[string]$user.user_id] = [ordered]@{
                        UserId = [string]$user.user_id; Username = [string]$user.username; Email = [string]$user.email
                        FirstSeenUtc = [DateTime]::UtcNow.AddDays(-30).ToString('o'); IsBaseline = $true; WelcomeSentUtc = ''
                    }
                }
                $accessStatePath = Join-Path $(if ($engine.Container) { $dataRoot } else { $appRoot }) 'access-state.json'
                if ($scenario.FreshAccessState) {
                    Remove-Item -LiteralPath $accessStatePath -Force -ErrorAction SilentlyContinue
                }
                else {
                    [ordered]@{ BaselineUtc = [DateTime]::UtcNow.AddDays(-30).ToString('o'); Users = $accessUsers } |
                        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $accessStatePath -Encoding UTF8
                }

                $resultPath = Join-Path $tempRoot ("result-$($scenario.Name).json")
                $stdout = Join-Path $tempRoot ("renderer-$($scenario.Name).stdout.txt")
                $stderr = Join-Path $tempRoot ("renderer-$($scenario.Name).stderr.txt")
                $oldDataRoot = $env:TAUTWEEKLY_DATA_DIR
                $oldConfig = $env:TAUTWEEKLY_CONFIG
                try {
                    if ($engine.Container) {
                        $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                        $env:TAUTWEEKLY_CONFIG = $configPath
                    }
                    if ($scenario.Name -eq 'all-legacy-notify-disabled') {
                        $unconfirmedResultPath = Join-Path $tempRoot ("result-unconfirmed-$($engine.Name).json")
                        $unconfirmedStdout = Join-Path $tempRoot ("renderer-unconfirmed-$($engine.Name).stdout.txt")
                        $unconfirmedStderr = Join-Path $tempRoot ("renderer-unconfirmed-$($engine.Name).stderr.txt")
                        $callsBeforeUnconfirmed = @(Get-Content -LiteralPath $tautulliLog -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
                        $unconfirmedProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                            '-RendererPath', (Join-Path $appRoot 'TautWeekly.ps1'), '-ConfigPath', $configPath,
                            '-UserId', '1', '-Mode', 'SendAll', '-ResultPath', $unconfirmedResultPath, '-NoConfirmSendAll'
                        ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $unconfirmedStdout -RedirectStandardError $unconfirmedStderr
                        Assert-True ($unconfirmedProcess.ExitCode -eq 1) "$($engine.Name) accepted an unconfirmed production SendAll."
                        $callsAfterUnconfirmed = @(Get-Content -LiteralPath $tautulliLog -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
                        Assert-True ($callsAfterUnconfirmed -eq $callsBeforeUnconfirmed) "$($engine.Name) contacted Tautulli before production confirmation."
                        $smtpCallsBeforeConfirmed = @(Get-Content -LiteralPath $smtpLog -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                        Assert-True ($smtpCallsBeforeConfirmed.Count -eq 0) "$($engine.Name) contacted SMTP before production confirmation."
                    }
                    $process = Start-Process -FilePath $engine.Host -ArgumentList @(
                        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                        '-RendererPath', (Join-Path $appRoot 'TautWeekly.ps1'), '-ConfigPath', $configPath,
                        '-UserId', '1', '-Mode', 'SendAll', '-ResultPath', $resultPath
                    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
                }
                finally {
                    $env:TAUTWEEKLY_DATA_DIR = $oldDataRoot
                    $env:TAUTWEEKLY_CONFIG = $oldConfig
                }

                if ($process.ExitCode -ne $scenario.ExitCode) {
                    throw "$($engine.Name)/$($scenario.Name) exited $($process.ExitCode), expected $($scenario.ExitCode).`nRESULT:`n$(Get-Content $resultPath -Raw -ErrorAction SilentlyContinue)`nUSERS:`n$(Get-Content $usersFile -Raw -ErrorAction SilentlyContinue)`nSTDOUT:`n$(Get-Content $stdout -Raw -ErrorAction SilentlyContinue)`nSTDERR:`n$(Get-Content $stderr -Raw -ErrorAction SilentlyContinue)`nTAUTULLI CALLS:`n$(Get-Content $tautulliLog -Raw -ErrorAction SilentlyContinue)`nTAUTULLI STDERR:`n$(Get-Content $tautulliStderr -Raw -ErrorAction SilentlyContinue)"
                }
                Assert-True (Test-Path -LiteralPath $resultPath) "$($engine.Name)/$($scenario.Name) omitted its structured result."
                $resultRaw = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8
                $result = $resultRaw | ConvertFrom-Json
                Assert-True ($result.schemaVersion -eq 2 -and $result.outcome -eq $scenario.Outcome) "$($engine.Name)/$($scenario.Name) reported schema $($result.schemaVersion) / outcome $($result.outcome) / category $($result.errorCategory), expected 2 / $($scenario.Outcome)."
                Assert-True ([string]$result.errorCategory -eq [string]$scenario.ErrorCategory) "$($engine.Name)/$($scenario.Name) reported the wrong fixed error category."
                Assert-True ($result.smtpAcceptedCount -eq $scenario.Accepted -and $result.skippedCount -eq $scenario.Skipped -and $result.failedCount -eq $scenario.Failed) "$($engine.Name)/$($scenario.Name) reported inconsistent delivery aggregates."
                $actualReasons = @($result.skipReasonCounts.inactiveOrDeleted, $result.skipReasonCounts.missingEmail, $result.skipReasonCounts.excludedUserId, $result.skipReasonCounts.excludedEmail)
                Assert-True (($actualReasons -join ',') -eq (@($scenario.Reasons) -join ',')) "$($engine.Name)/$($scenario.Name) reported inconsistent fixed skip reasons."
                $tautulliCalls = @(
                    Get-Content -LiteralPath $tautulliLog -ErrorAction SilentlyContinue |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Skip $callBaseline |
                        ForEach-Object { $_ | ConvertFrom-Json }
                )
                $apiCommands = @(
                    $tautulliCalls |
                        Where-Object { [string]$_.path -eq '/api/v2' } |
                        ForEach-Object { [string]$_.query.cmd }
                )
                Assert-True (@($apiCommands | Where-Object { $_ -eq 'refresh_users_list' }).Count -eq 1) "$($engine.Name)/$($scenario.Name) did not refresh the Tautulli roster exactly once."
                Assert-True ($apiCommands.Count -gt 0 -and $apiCommands[0] -eq 'refresh_users_list') "$($engine.Name)/$($scenario.Name) did not refresh before reading production data."
                if ($scenario.Name -eq 'stale-manager-discovery-new-user') {
                    $refreshIndex = [Array]::IndexOf([object[]]$apiCommands, 'refresh_users_list')
                    $rosterIndex = [Array]::IndexOf([object[]]$apiCommands, 'get_users')
                    Assert-True ($refreshIndex -ge 0 -and $rosterIndex -gt $refreshIndex) "$($engine.Name) did not fetch the live roster after the required refresh."
                    Assert-True ($result.smtpAcceptedCount -eq 2) "$($engine.Name) did not include the synthetic user added after stale Manager discovery."
                }
                if ($scenario.Name -eq 'required-roster-refresh-failure') {
                    # A failed required refresh must stop before roster discovery,
                    # integration/media work, preview work, or SMTP preflight.
                    Assert-True ($apiCommands.Count -eq 1) "$($engine.Name) continued into production data calls after a failed roster refresh."
                    $smtpCalls = @(Get-Content -LiteralPath $smtpLog -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    Assert-True ($smtpCalls.Count -eq 0) "$($engine.Name) contacted SMTP after the required roster refresh failed."
                    Assert-True (-not $resultRaw.Contains('virtual roster refresh rejected')) "$($engine.Name) exposed the raw upstream refresh failure."
                }
                foreach ($user in @($scenario.Users)) {
                    $privateValues = @([string]$user.email, [string]$user.friendly_name) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    foreach ($privateValue in $privateValues) {
                        Assert-True (-not $resultRaw.Contains($privateValue)) "$($engine.Name)/$($scenario.Name) exposed a recipient identity in its structured result."
                    }
                }
                $executed++
                Write-Host "[PASS] SendAll recipient policy: $($engine.Name) / $($scenario.Name)"
            }
            finally {
                if ($null -ne $smtp -and -not $smtp.HasExited) {
                    Stop-Process -Id $smtp.Id -Force -ErrorAction SilentlyContinue
                    $smtp.WaitForExit()
                }
            }
        }
    }
    finally {
        if ($null -ne $tautulli -and -not $tautulli.HasExited) {
            Stop-Process -Id $tautulli.Id -Force -ErrorAction SilentlyContinue
            $tautulli.WaitForExit()
        }
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

foreach ($path in @('platforms/nas-docker/app/Scheduler.ps1', 'platforms/mac-docker/app/Scheduler.ps1')) {
    $scheduler = Get-Content -LiteralPath (Join-Path $Root $path) -Raw -Encoding UTF8
    Assert-True ($scheduler.Contains('& $runModePath SendAll --confirm-send-all')) "$path does not route scheduled delivery through the shared guarded SendAll mode."
}
$windowsSchedule = Get-Content -LiteralPath (Join-Path $Root 'platforms/windows/SCHEDULE-HELPER.ps1') -Raw -Encoding UTF8
Assert-True ($windowsSchedule.Contains('-Mode SendAll -ResultPath') -and $windowsSchedule.Contains('-ConfirmSendAll')) 'Windows scheduled delivery does not route through the shared guarded SendAll mode.'

foreach ($path in @('platforms/windows/TautWeekly.ps1', 'platforms/nas-docker/app/TautWeekly.ps1', 'platforms/mac-docker/app/TautWeekly.ps1')) {
    $renderer = Get-Content -LiteralPath (Join-Path $Root $path) -Raw -Encoding UTF8
    Assert-True ($renderer.Contains('Sync-AccessRoster -RequireFreshUsers:($Mode -eq "SendAll")')) "$path does not require the shared refresh-on-SendAll path."
}

Assert-True ($executed -gt 0) 'No SendAll recipient-policy scenarios executed.'
Write-Host "[PASS] SendAll recipient policy, privacy, platform synchronization, and schedule/manual parity validated ($executed scenarios)."
