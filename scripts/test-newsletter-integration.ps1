[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$PythonPath = 'python',
    [switch]$KeepFailedArtifacts,
    [switch]$KeepArtifacts,
    [string[]]$EngineFilter = @(),
    [string[]]$ScenarioFilter = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$fakeServer = Join-Path $Root 'scripts/test-support/fake-tautulli.py'
$fakeSmtp = Join-Path $Root 'scripts/test-support/fake-smtp.py'
$emailThemeAssertion = Join-Path $Root 'scripts/test-support/assert-email-theme.py'
$headlessRunner = Join-Path $Root 'scripts/test-support/invoke-renderer-headless.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$powerShell7 = Get-Command pwsh -ErrorAction SilentlyContinue

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-HtmlSection {
    param(
        [string]$Html,
        [string]$StartMarker,
        [string[]]$EndMarkers
    )

    $startIndex = $Html.IndexOf($StartMarker, [StringComparison]::Ordinal)
    if ($startIndex -lt 0) { return '' }
    $endIndex = $Html.Length
    foreach ($endMarker in $EndMarkers) {
        $candidate = $Html.IndexOf($endMarker, $startIndex + $StartMarker.Length, [StringComparison]::Ordinal)
        if ($candidate -ge 0 -and $candidate -lt $endIndex) {
            $endIndex = $candidate
        }
    }
    if ($endIndex -le $startIndex) { return '' }
    return $Html.Substring($startIndex, $endIndex - $startIndex)
}

function Assert-FooterPresentation {
    param([string]$Html, [string]$Context)
    $start = $Html.IndexOf('YOUR WEEK ON PLEX', [StringComparison]::Ordinal)
    if ($start -lt 0) { return } # Manual Welcome omits the personal footer.
    $footer = $Html.Substring($start)
    Assert-True (-not $footer.Contains('recipient-watched')) "$Context contains a footer watched marker."
    $headingPattern = '<div style="([^"]+)">(YOU CLOCKED|[^<]*BINGE CHAMPION|TOP GENRE THIS WEEK|TRENDING THIS WEEK)</div>\s*(?:<img[^>]+>\s*)?<div style="([^"]+)">[^<]*</div>'
    $summaries = [regex]::Matches($footer, $headingPattern)
    foreach ($summary in $summaries) {
        $heading = $summary.Groups[1].Value
        $value = $summary.Groups[3].Value
        foreach ($style in @('font-size:12px;', 'font-weight:900;', 'letter-spacing:1.1px;')) {
            Assert-True ($heading.Contains($style)) "$Context footer heading lost $style"
        }
        foreach ($style in @('font-size:27px;', 'font-weight:800;', 'line-height:1.1;')) {
            Assert-True ($value.Contains($style)) "$Context footer primary value lost $style"
        }
    }
    foreach ($label in [regex]::Matches($footer, '<div style="([^"]+)">(MOVIES WATCHED|TV SHOWS WATCHED)</div>')) {
        Assert-True ($label.Groups[1].Value.Contains('font-size:12px;')) "$Context recap label is not 12px."
        if ($label.Groups[2].Value -eq 'TV SHOWS WATCHED') {
            Assert-True ($label.Groups[1].Value.Contains('margin-bottom:-7px;')) "$Context lost deliberate TV-label spacing."
        }
    }
    if ($footer.Contains('class="stats-summary-cell"')) {
        Assert-True ($footer.Contains('class="pad" style="padding:0px 20px 0px;"')) "$Context restored unwanted bottom stats padding."
        Assert-True ($summaries.Count -ge 2) "$Context did not validate both summary values."
    }
}

function Get-TautulliMetadataCallCount {
    param(
        [string]$CallLogPath,
        [string]$RatingKey
    )

    if (-not (Test-Path -LiteralPath $CallLogPath -PathType Leaf)) { return 0 }
    return @(
        Get-Content -LiteralPath $CallLogPath |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object {
                $null -ne $_.query.PSObject.Properties['cmd'] -and
                [string]$_.query.cmd -eq 'get_metadata' -and
                $null -ne $_.query.PSObject.Properties['rating_key'] -and
                [string]$_.query.rating_key -eq $RatingKey
            }
    ).Count
}

function Get-FreeTcpPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

$engines = @(
    [PSCustomObject]@{ Name = 'windows'; Source = 'platforms/windows'; Renderer = 'TautWeekly.ps1'; Host = $windowsPowerShell; Container = $false },
    [PSCustomObject]@{ Name = 'nas-docker-linux-freebsd'; Source = 'platforms/nas-docker/app'; Renderer = 'TautWeekly.ps1'; Host = $(if ($null -ne $powerShell7) { $powerShell7.Source } else { '' }); Container = $true },
    [PSCustomObject]@{ Name = 'mac-docker'; Source = 'platforms/mac-docker/app'; Renderer = 'TautWeekly.ps1'; Host = $(if ($null -ne $powerShell7) { $powerShell7.Source } else { '' }); Container = $true }
)
$providerRecoveryScenarios = @('deleted-history-metadata', 'deleted-history-legacy-guid')
$cacheScenario = 'cache-deleted'
$directOptionalRatingScenario = 'direct-rating-optional'
$directXmlRatingScenario = 'direct-rating-xml-fallback'
$directEpisodeRtScenario = 'direct-episode-rt-fallback'
$sparseEpisodeMetadataScenario = 'sparse-episode-metadata'
$directImdbRatingScenarios = @($directOptionalRatingScenario, $directXmlRatingScenario)
$directRatingScenarios = @($directImdbRatingScenarios) + @($directEpisodeRtScenario)
$deletedHistoryScenarios = @($providerRecoveryScenarios) + @($cacheScenario)
$platformScenario = 'platform-tie'
$lastPlatformScenario = 'last-platform'
$quietNoHistoryScenario = 'quiet-no-history'
$quietNoGlobalHistoryScenario = 'quiet-no-global-history'
$sendTestScenarios = @('active', 'quiet', 'tv-only', $quietNoHistoryScenario, $quietNoGlobalHistoryScenario, $platformScenario, $lastPlatformScenario, $sparseEpisodeMetadataScenario, 'optional-hero-metadata', 'rating-export-fallback') + @($directRatingScenarios) + @($deletedHistoryScenarios)

$executed = 0
foreach ($engine in $engines) {
    if ($EngineFilter.Count -gt 0 -and $engine.Name -notin $EngineFilter) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$engine.Host)) {
        Write-Warning "Skipping $($engine.Name) locally because PowerShell 7 is unavailable; hosted CI runs it."
        continue
    }

    foreach ($scenario in @('active', 'quiet', $quietNoHistoryScenario, $quietNoGlobalHistoryScenario, 'tv-only', 'personal-many', $platformScenario, $lastPlatformScenario, $sparseEpisodeMetadataScenario, 'optional-hero-metadata', 'rating-export-fallback') + $directRatingScenarios + $deletedHistoryScenarios) {
        if ($ScenarioFilter.Count -gt 0 -and $scenario -notin $ScenarioFilter) { continue }
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-integration-' + [Guid]::NewGuid().ToString('N'))
        $appRoot = Join-Path $tempRoot 'app'
        $dataRoot = Join-Path $tempRoot 'data'
        $callLog = Join-Path $tempRoot 'calls.jsonl'
        $readyFile = Join-Path $tempRoot 'ready.txt'
        $scenarioState = Join-Path $tempRoot 'scenario.txt'
        $stdout = Join-Path $tempRoot 'renderer.stdout.txt'
        $stderr = Join-Path $tempRoot 'renderer.stderr.txt'
        $plexVerifyStdout = Join-Path $tempRoot 'plex-verify.stdout.txt'
        $plexVerifyStderr = Join-Path $tempRoot 'plex-verify.stderr.txt'
        $plexRejectStdout = Join-Path $tempRoot 'plex-reject.stdout.txt'
        $plexRejectStderr = Join-Path $tempRoot 'plex-reject.stderr.txt'
        $primeStdout = Join-Path $tempRoot 'prime.stdout.txt'
        $primeStderr = Join-Path $tempRoot 'prime.stderr.txt'
        $serverStdout = Join-Path $tempRoot 'server.stdout.txt'
        $serverStderr = Join-Path $tempRoot 'server.stderr.txt'
        $smtpCallLog = Join-Path $tempRoot 'smtp-calls.jsonl'
        $smtpDataFile = Join-Path $tempRoot 'smtp-message.eml'
        $smtpReadyFile = Join-Path $tempRoot 'smtp-ready.txt'
        $smtpDataDirectory = Join-Path $tempRoot 'smtp-messages'
        $smtpStdout = Join-Path $tempRoot 'smtp.stdout.txt'
        $smtpStderr = Join-Path $tempRoot 'smtp.stderr.txt'
        $sendStdout = Join-Path $tempRoot 'send.stdout.txt'
        $sendStderr = Join-Path $tempRoot 'send.stderr.txt'
        $previewSingleStdout = Join-Path $tempRoot 'preview-single.stdout.txt'
        $previewSingleStderr = Join-Path $tempRoot 'preview-single.stderr.txt'
        $sendWelcomeStdout = Join-Path $tempRoot 'send-welcome.stdout.txt'
        $sendWelcomeStderr = Join-Path $tempRoot 'send-welcome.stderr.txt'
        $sendWelcomeResultPath = Join-Path $tempRoot 'send-welcome-result.json'
        $sendAllStdout = Join-Path $tempRoot 'send-all.stdout.txt'
        $sendAllStderr = Join-Path $tempRoot 'send-all.stderr.txt'
        $managerResultPath = Join-Path $tempRoot 'manager-operation-result.json'
        $sendTestAllStdout = Join-Path $tempRoot 'send-test-all.stdout.txt'
        $sendTestAllStderr = Join-Path $tempRoot 'send-test-all.stderr.txt'
        $sendTestAllResultPath = Join-Path $tempRoot 'send-test-all-result.json'
        $failureResultPath = Join-Path $tempRoot 'manager-operation-failure.json'
        $failureStdout = Join-Path $tempRoot 'failure.stdout.txt'
        $failureStderr = Join-Path $tempRoot 'failure.stderr.txt'
        $server = $null
        $smtpServer = $null
        $casePassed = $false

        New-Item -ItemType Directory -Force -Path $appRoot, $dataRoot | Out-Null
        $sourceContents = Join-Path (Join-Path $Root ([string]$engine.Source)) '*'
        Copy-Item -Path $sourceContents -Destination $appRoot -Recurse -Force

        try {
            if ($scenario -eq 'active') {
                $oldFailureDataRoot = $env:TAUTWEEKLY_DATA_DIR
                $oldFailureConfig = $env:TAUTWEEKLY_CONFIG
                try {
                    $missingConfigPath = Join-Path $tempRoot 'missing-config.json'
                    if ($engine.Container) {
                        $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                        $env:TAUTWEEKLY_CONFIG = $missingConfigPath
                    }
                    $failureProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                        '-File', (Join-Path $appRoot $engine.Renderer), '-ConfigPath', $missingConfigPath,
                        '-UserId', '1', '-Mode', 'PreviewAll', '-ResultPath', $failureResultPath, '-NoOpen'
                    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $failureStdout -RedirectStandardError $failureStderr
                }
                finally {
                    $env:TAUTWEEKLY_DATA_DIR = $oldFailureDataRoot
                    $env:TAUTWEEKLY_CONFIG = $oldFailureConfig
                }
                Assert-True ($failureProcess.ExitCode -eq 1) "$($engine.Name) missing-config renderer returned $($failureProcess.ExitCode) instead of 1."
                Assert-True (Test-Path -LiteralPath $failureResultPath) "$($engine.Name) missing-config renderer omitted its structured failure result."
                $failureResultRaw = Get-Content -LiteralPath $failureResultPath -Raw -Encoding UTF8
                $failureResult = $failureResultRaw | ConvertFrom-Json
                Assert-True ($failureResult.outcome -eq 'failed' -and $failureResult.errorCategory -eq 'configuration-invalid') "$($engine.Name) missing-config renderer reported the wrong sanitized failure category."
                Assert-True (-not $failureResultRaw.Contains($tempRoot)) "$($engine.Name) structured failure exposed its private temporary path."
                Remove-Item -LiteralPath $failureResultPath -Force
            }

            $port = Get-FreeTcpPort
            $initialScenario = if ($scenario -eq $cacheScenario) { 'cache-prime' } else { $scenario }
            Set-Content -LiteralPath $scenarioState -Value $initialScenario -Encoding ASCII
            $server = Start-Process -FilePath $PythonPath -ArgumentList @(
                '-u', $fakeServer, '--port', [string]$port, '--scenario', $initialScenario,
                '--state-file', $scenarioState, '--call-log', $callLog, '--ready-file', $readyFile
            ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr

            for ($attempt = 0; $attempt -lt 100 -and -not (Test-Path $readyFile); $attempt++) {
                if ($server.HasExited) {
                    throw "Virtual Tautulli exited early: $(Get-Content $serverStderr -Raw -ErrorAction SilentlyContinue)"
                }
                Start-Sleep -Milliseconds 50
            }
            Assert-True (Test-Path $readyFile) "Virtual Tautulli did not become ready for $($engine.Name)/$scenario."
            $baseUrl = (Get-Content $readyFile -Raw).Trim()

            $smtpPort = 0
            if ($scenario -in $sendTestScenarios) {
                $smtpPort = Get-FreeTcpPort
                $smtpServer = Start-Process -FilePath $PythonPath -ArgumentList @(
                    '-u', $fakeSmtp, '--port', [string]$smtpPort,
                    '--call-log', $smtpCallLog, '--ready-file', $smtpReadyFile,
                    '--data-file', $smtpDataFile,
                    '--data-directory', $smtpDataDirectory
                ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $smtpStdout -RedirectStandardError $smtpStderr
                for ($attempt = 0; $attempt -lt 100 -and -not (Test-Path $smtpReadyFile); $attempt++) {
                    if ($smtpServer.HasExited) {
                        throw "Virtual SMTP exited early: $(Get-Content $smtpStderr -Raw -ErrorAction SilentlyContinue)"
                    }
                    Start-Sleep -Milliseconds 50
                }
                Assert-True (Test-Path $smtpReadyFile) "Virtual SMTP did not become ready for $($engine.Name)/$scenario."
            }

            $examplePath = Join-Path $appRoot 'config.example.json'
            $config = Get-Content $examplePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $configOverrides = [ordered]@{
                TautulliUrl = $baseUrl
                ApiKey = 'virtual-api-key'
                PlexServerUrl = $baseUrl
                PlexToken = 'virtual-plex-token'
                FooterServerName = 'Virtual Plex'
                PlexWebUrl = 'https://requests.example.test/'
                PlexButtonLabel = 'View & Request <Now>'
                IncludedLibraryIds = @('10', '20')
                ExcludedUserIds = @()
                ExcludedEmails = @()
                DaysBack = 7
                MaxMovies = 4
                MaxTv = 4
                SendDelaySeconds = 0
                CustomTextCardEnabled = $true
                CustomTextCardBorderColor = '#72aef7'
                CustomTextCardBorderOpacity = 34
                CustomTextCardTitle = 'Custom <Title>'
                TestSendDelaySeconds = 0
                CustomTextCardTitleGif = 'celebrate'
                CustomTextCardSubheading = 'Assessment & notes'
                CustomTextCardBody = "Synthetic <notice> & safe`nSecond line"
            }
            if ($scenario -eq $quietNoHistoryScenario) {
                $configOverrides['IncludedLibraryIds'] = @()
            }
            if ($scenario -in $sendTestScenarios) {
                $configOverrides['SmtpHost'] = '127.0.0.1'
                $configOverrides['SmtpPort'] = $smtpPort
                $configOverrides['SmtpEnableSsl'] = $false
                $configOverrides['SmtpUseAuthentication'] = $false
                $configOverrides['SmtpTimeoutSeconds'] = 5
                $configOverrides['FromEmail'] = 'sender@example.com'
                $configOverrides['FromName'] = 'TautWeekly Integration'
                $configOverrides['TestEmail'] = 'recipient@example.com'
            }
            foreach ($entry in $configOverrides.GetEnumerator()) {
                $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
            }

            if ($engine.Container) {
                New-Item -ItemType Directory -Force -Path (Join-Path $dataRoot 'assets') | Out-Null
                Copy-Item -Path (Join-Path $appRoot 'assets-default/*') -Destination (Join-Path $dataRoot 'assets') -Recurse -Force
                $configPath = Join-Path $dataRoot 'config.json'
                $outputRoot = Join-Path $dataRoot 'output'
            }
            else {
                $configPath = Join-Path $appRoot 'config.json'
                $outputRoot = Join-Path $appRoot 'output'
            }
            $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8
            $invalidPlexToken = 'virtual-invalid-token-do-not-print'
            $invalidPlexConfigPath = Join-Path $tempRoot 'invalid-plex-config.json'
            if ($scenario -eq 'active') {
                $invalidPlexConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $invalidPlexConfig.PlexToken = $invalidPlexToken
                $invalidPlexConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $invalidPlexConfigPath -Encoding UTF8
            }

            $oldDataRoot = $env:TAUTWEEKLY_DATA_DIR
            $oldConfig = $env:TAUTWEEKLY_CONFIG
            $oldMetadataProvider = $env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL
            $oldPlexWatch = $env:TAUTWEEKLY_TEST_PLEX_WATCH_URL
            try {
                if ($engine.Container) {
                    $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                    $env:TAUTWEEKLY_CONFIG = $configPath
                }
                if ($scenario -in $deletedHistoryScenarios) {
                    $env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL = $baseUrl + '/hosted'
                    $env:TAUTWEEKLY_TEST_PLEX_WATCH_URL = $baseUrl + '/watch'
                }
                $plexVerifyProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                    '-RendererPath', (Join-Path $appRoot $engine.Renderer), '-ConfigPath', $configPath,
                    '-UserId', '1', '-Mode', 'VerifyPlex'
                ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $plexVerifyStdout -RedirectStandardError $plexVerifyStderr
                if ($plexVerifyProcess.ExitCode -ne 0) {
                    throw "$($engine.Name)/$scenario direct Plex verification failed ($($plexVerifyProcess.ExitCode)).`nSTDOUT:`n$(Get-Content $plexVerifyStdout -Raw)`nSTDERR:`n$(Get-Content $plexVerifyStderr -Raw)"
                }
                $plexVerifyLog = Get-Content $plexVerifyStdout -Raw
                Assert-True ($plexVerifyLog.Contains('Direct Plex verification passed: identity HTTP 200; authenticated library HTTP 200.')) "$($engine.Name)/$scenario did not verify direct Plex identity and authenticated library access."
                if ($scenario -eq 'active') {
                    $plexRejectProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                        '-RendererPath', (Join-Path $appRoot $engine.Renderer), '-ConfigPath', $invalidPlexConfigPath,
                        '-UserId', '1', '-Mode', 'VerifyPlex'
                    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $plexRejectStdout -RedirectStandardError $plexRejectStderr
                    Assert-True ($plexRejectProcess.ExitCode -eq 2) "$($engine.Name) accepted a rejected direct Plex token or returned the wrong failure code ($($plexRejectProcess.ExitCode))."
                    $plexRejectLog = (Get-Content $plexRejectStdout -Raw) + (Get-Content $plexRejectStderr -Raw)
                    Assert-True ($plexRejectLog.Contains('Direct Plex verification failed (HTTP 401).')) "$($engine.Name) did not report the sanitized direct Plex rejection status."
                    Assert-True (-not $plexRejectLog.Contains($invalidPlexToken)) "$($engine.Name) exposed the rejected Plex token in verification output."
                    Assert-True (-not $plexRejectLog.Contains($baseUrl)) "$($engine.Name) exposed the private Plex URL in verification output."
                }
                if ($scenario -eq $cacheScenario) {
                    $primeProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                        '-RendererPath', (Join-Path $appRoot $engine.Renderer), '-ConfigPath', $configPath,
                        '-UserId', '1', '-Mode', 'PreviewAll'
                    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $primeStdout -RedirectStandardError $primeStderr
                    if ($primeProcess.ExitCode -ne 0) {
                        throw "$($engine.Name)/cache-prime renderer failed ($($primeProcess.ExitCode)).`nSTDOUT:`n$(Get-Content $primeStdout -Raw)`nSTDERR:`n$(Get-Content $primeStderr -Raw)"
                    }
                    $cacheRoot = if ($engine.Container) { Join-Path $dataRoot 'cache/deleted-items' } else { Join-Path $appRoot 'cache/deleted-items' }
                    Assert-True (Test-Path -LiteralPath (Join-Path $cacheRoot 'index.json')) "$($engine.Name) did not create the persistent cache manifest while items were live."
                    Assert-True ((Get-ChildItem -LiteralPath (Join-Path $cacheRoot 'artwork') -File -Filter '*.jpg').Count -ge 2) "$($engine.Name) did not cache live movie and TV artwork."
                    Set-Content -LiteralPath $scenarioState -Value $cacheScenario -Encoding ASCII
                    Remove-Item -LiteralPath (Join-Path $outputRoot 'posters') -Recurse -Force -ErrorAction SilentlyContinue
                    Get-ChildItem -LiteralPath $outputRoot -File -Filter 'preview-all-*.html' -ErrorAction SilentlyContinue | Remove-Item -Force
                    New-Item -ItemType Directory -Force -Path (Join-Path $outputRoot 'posters') | Out-Null
                }
                $previewArguments = @(
                    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                    '-RendererPath', (Join-Path $appRoot $engine.Renderer), '-ConfigPath', $configPath,
                    '-UserId', '1', '-Mode', 'PreviewAll'
                )
                if ($engine.Name -eq 'nas-docker-linux-freebsd' -and $scenario -in @('active', $platformScenario)) {
                    $previewArguments += @('-ResultPath', $managerResultPath)
                }
                $process = Start-Process -FilePath $engine.Host -ArgumentList $previewArguments `
                    -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            }
            finally {
                $env:TAUTWEEKLY_DATA_DIR = $oldDataRoot
                $env:TAUTWEEKLY_CONFIG = $oldConfig
                $env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL = $oldMetadataProvider
                $env:TAUTWEEKLY_TEST_PLEX_WATCH_URL = $oldPlexWatch
            }

            if ($process.ExitCode -ne 0) {
                throw "$($engine.Name)/$scenario renderer failed ($($process.ExitCode)).`nSTDOUT:`n$(Get-Content $stdout -Raw)`nSTDERR:`n$(Get-Content $stderr -Raw)"
            }
            $previewLog = Get-Content $stdout -Raw
            $historicalMovieCalls = @(
                Get-Content -LiteralPath $callLog |
                    ForEach-Object { $_ | ConvertFrom-Json } |
                    Where-Object {
                        $null -ne $_.query.PSObject.Properties['cmd'] -and
                        [string]$_.query.cmd -eq 'get_history' -and
                        $null -ne $_.query.PSObject.Properties['media_type'] -and
                        [string]$_.query.media_type -eq 'movie'
                    }
            )
            Assert-True ($historicalMovieCalls.Count -ge 1) "$($engine.Name)/$scenario did not request historical movie state."
            foreach ($historyCall in $historicalMovieCalls) {
                Assert-True ([string]$historyCall.query.user_id -eq '1') "$($engine.Name)/$scenario did not scope watched state to the recipient."
                Assert-True ([string]$historyCall.query.include_activity -eq '0') "$($engine.Name)/$scenario included active sessions in historical watched state."
                Assert-True ($null -eq $historyCall.query.PSObject.Properties['after'] -and $null -eq $historyCall.query.PSObject.Properties['before']) "$($engine.Name)/$scenario limited watched state to the newsletter window."
            }

            $indexPath = Join-Path $outputRoot 'preview-all-00-INDEX.html'
            $normalPath = Join-Path $outputRoot 'preview-all-04-normal-newsletter.html'
            Assert-True (Test-Path $indexPath) "$($engine.Name)/$scenario did not generate the preview index."
            $expectedPreviewNames = @(
                'preview-all-00-INDEX.html',
                'preview-all-01-manual-welcome.html',
                'preview-all-02-new-user-no-history.html',
                'preview-all-03-new-user-with-history.html',
                'preview-all-04-normal-newsletter.html',
                'preview-all-05-established-quiet.html',
                'preview-all-06-established-warmup.html'
            )
            $actualPreviewNames = @(
                Get-ChildItem $outputRoot -Filter 'preview-all-*.html' |
                    Sort-Object Name |
                    Select-Object -ExpandProperty Name
            )
            Assert-True (($actualPreviewNames -join '|') -eq ($expectedPreviewNames -join '|')) "$($engine.Name)/$scenario generated the all-state previews in the wrong order or under unexpected names."
            $scenarioHashes = @(Get-ChildItem $outputRoot -Filter 'preview-all-*.html' | Where-Object { $_.Name -ne 'preview-all-00-INDEX.html' } | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Select-Object -Unique)
            if ($scenario -in @($quietNoHistoryScenario, $quietNoGlobalHistoryScenario)) {
                Assert-True ($scenarioHashes.Count -eq 4) "$($engine.Name)/$scenario fabricated differences between authentic zero-history lifecycle states."
            }
            else {
                Assert-True ($scenarioHashes.Count -eq 6) "$($engine.Name)/$scenario collapsed distinct lifecycle scenarios into duplicate HTML."
            }
            Assert-True ((Get-ChildItem $outputRoot -Filter 'preview-all-*.html').Count -eq 7) "$($engine.Name)/$scenario did not generate all six states plus the index."
            if ($engine.Name -eq 'nas-docker-linux-freebsd' -and $scenario -in @('active', $platformScenario)) {
                Assert-True (Test-Path -LiteralPath $managerResultPath) 'NAS Manager operation did not produce its structured result.'
                $managerResultRaw = Get-Content -LiteralPath $managerResultPath -Raw -Encoding UTF8
                $managerResult = $managerResultRaw | ConvertFrom-Json
                Assert-True ($managerResult.schemaVersion -eq 3) 'NAS Manager result used the wrong schema version.'
                Assert-True ($managerResult.mode -eq 'PreviewAll' -and $managerResult.outcome -eq 'succeeded') 'NAS Manager result reported the wrong operation outcome.'
                Assert-True ([string]::IsNullOrEmpty([string]$managerResult.errorCategory)) 'NAS Manager success retained a renderer failure category.'
                Assert-True ($managerResult.deliveryScope -eq 'none') 'NAS Manager preview result reported a delivery scope.'
                Assert-True (($managerResult.skipReasonCounts.inactiveOrDeleted + $managerResult.skipReasonCounts.missingEmail + $managerResult.skipReasonCounts.excludedUserId + $managerResult.skipReasonCounts.excludedEmail) -eq 0) 'NAS Manager preview result reported production skip reasons.'
                Assert-True ($managerResult.generatedPreviewFiles.Count -eq 7) 'NAS Manager result did not report all generated previews.'
                Assert-True (-not $managerResultRaw.Contains('virtual-api-key')) 'NAS Manager result exposed the synthetic Tautulli API key.'
                Assert-True (-not $managerResultRaw.Contains('virtual-plex-token')) 'NAS Manager result exposed the synthetic Plex token.'
                Assert-True (-not $managerResultRaw.Contains($baseUrl)) 'NAS Manager result exposed a private service URL.'
                Assert-True (-not $managerResultRaw.Contains($configPath)) 'NAS Manager result exposed its configuration path.'
            }
            $indexHtml = Get-Content $indexPath -Raw -Encoding UTF8
            $previousScenarioLinkIndex = -1
            foreach ($scenarioPreviewName in @($expectedPreviewNames[1..6])) {
                $scenarioLinkIndex = $indexHtml.IndexOf(('href="' + $scenarioPreviewName + '"'), [StringComparison]::Ordinal)
                Assert-True ($scenarioLinkIndex -gt $previousScenarioLinkIndex) "$($engine.Name)/$scenario preview index listed lifecycle scenarios out of order."
                $previousScenarioLinkIndex = $scenarioLinkIndex
            }
            $manualHtml = Get-Content (Join-Path $outputRoot 'preview-all-01-manual-welcome.html') -Raw -Encoding UTF8
            $newNoHistoryHtml = Get-Content (Join-Path $outputRoot 'preview-all-02-new-user-no-history.html') -Raw -Encoding UTF8
            $newWithHistoryHtml = Get-Content (Join-Path $outputRoot 'preview-all-03-new-user-with-history.html') -Raw -Encoding UTF8
            $warmupHtml = Get-Content (Join-Path $outputRoot 'preview-all-06-established-warmup.html') -Raw -Encoding UTF8
            $normalHtml = Get-Content $normalPath -Raw -Encoding UTF8
            $quietHtml = Get-Content (Join-Path $outputRoot 'preview-all-05-established-quiet.html') -Raw -Encoding UTF8
            $scenarioPreviewHtml = @($manualHtml, $newNoHistoryHtml, $newWithHistoryHtml, $normalHtml, $quietHtml, $warmupHtml)
            foreach ($stateHtml in $scenarioPreviewHtml) { Assert-FooterPresentation -Html $stateHtml -Context "$($engine.Name)/$scenario" }
            $previewThemeMarkers = @(
                '<meta name="color-scheme" content="light dark">',
                '<meta name="supported-color-schemes" content="light dark">',
                ':root { color-scheme:light dark; supported-color-schemes:light dark; }',
                '@media (prefers-color-scheme: dark)',
                'class="email-background"',
                'bgcolor="#0f0f0f"',
                'background-color:#0f0f0f'
            )
            $previewPaths = @(Get-ChildItem $outputRoot -Filter 'preview-all-*.html' | Where-Object { $_.Name -ne 'preview-all-00-INDEX.html' })
            foreach ($previewPath in $previewPaths) {
                $previewHtml = Get-Content $previewPath.FullName -Raw -Encoding UTF8
                foreach ($marker in $previewThemeMarkers) {
                    Assert-True ($previewHtml.Contains($marker)) "$($engine.Name)/$scenario $($previewPath.Name) lost dark-theme marker: $marker"
                }
                Assert-True ($previewHtml.Contains('href="https://requests.example.test/"')) "$($engine.Name)/$scenario $($previewPath.Name) lost the custom button URL."
                Assert-True ($previewHtml.Contains('>View &amp; Request &lt;Now&gt;</a>')) "$($engine.Name)/$scenario $($previewPath.Name) did not safely render the custom button label."
                Assert-True ($previewHtml.Contains('class="email-card custom-text-card"')) "$($engine.Name)/$scenario $($previewPath.Name) did not render the enabled custom text card."
                Assert-True ($previewHtml.Contains('CUSTOM &lt;TITLE&gt;') -and $previewHtml.Contains('Assessment &amp; notes')) "$($engine.Name)/$scenario $($previewPath.Name) did not safely render the custom text card headings."
                Assert-True ($previewHtml.Contains('<span>CUSTOM &lt;TITLE&gt;</span><img src="../assets/celebrate.gif"')) "$($engine.Name)/$scenario $($previewPath.Name) did not append the selected title GIF in every newsletter state."
                Assert-True ($previewHtml.Contains('width="18" height="18" style="display:inline-block;width:18px;height:18px;border:0;vertical-align:-4px;margin-left:6px;"')) "$($engine.Name)/$scenario $($previewPath.Name) changed the approved title GIF dimensions or alignment."
                Assert-True ($previewHtml.Contains('Synthetic &lt;notice&gt; &amp; safe<br>Second line')) "$($engine.Name)/$scenario $($previewPath.Name) did not safely preserve custom text body formatting."
                Assert-True ($previewHtml.Contains('border-color:rgba(114,174,247,0.34)')) "$($engine.Name)/$scenario $($previewPath.Name) lost the configured custom card border opacity."
                $customCardIndex = $previewHtml.IndexOf('class="email-card custom-text-card"', [StringComparison]::Ordinal)
                $releaseSearchStart = [Math]::Max(0, $customCardIndex + 1)
                $releaseMetaIndexes = @(
                    foreach ($releaseMarker in @('TRENDING MOVIE', 'NO NEW RELEASES THIS WEEK', 'RECENT MOVIE', 'NEW MOVIE')) {
                        $candidateIndex = $previewHtml.IndexOf($releaseMarker, $releaseSearchStart, [StringComparison]::Ordinal)
                        if ($candidateIndex -ge 0) { $candidateIndex }
                    }
                )
                $releaseMetaIndex = if ($releaseMetaIndexes.Count -gt 0) {
                    [int](($releaseMetaIndexes | Measure-Object -Minimum).Minimum)
                }
                else { -1 }
                Assert-True ($customCardIndex -ge 0 -and $releaseMetaIndex -gt $customCardIndex) "$($engine.Name)/$scenario $($previewPath.Name) did not place the custom text card before release metadata."
                Assert-True (-not $previewHtml.Contains('background:#0f0f0f')) "$($engine.Name)/$scenario $($previewPath.Name) retained the outer background shorthand."
                Assert-True (-not $previewHtml.Contains('background:#181818')) "$($engine.Name)/$scenario $($previewPath.Name) retained the card background shorthand."
                Assert-True (-not $previewHtml.Contains('color-scheme:dark only')) "$($engine.Name)/$scenario $($previewPath.Name) retained the incompatible dark-only declaration."
            }
            if ($scenario -eq $platformScenario) {
                $expectedPlatformPreviewSource = if ($engine.Container) { 'assets/platform-android.png' } else { '../assets/platform-android.png' }
                foreach ($previewPath in $previewPaths) {
                    $previewHtml = Get-Content $previewPath.FullName -Raw -Encoding UTF8
                    if ($previewHtml.Contains('YOUR WEEK ON PLEX')) {
                        Assert-True ($previewHtml.Contains($expectedPlatformPreviewSource)) "$($engine.Name)/$scenario $($previewPath.Name) did not render the tie-winning Android icon."
                        Assert-True ($previewHtml.Contains('alt="Platform: Android"')) "$($engine.Name)/$scenario $($previewPath.Name) lost the accessible platform label."
                        Assert-True ($previewHtml.Contains('width="21" height="21"') -and $previewHtml.Contains('max-height:21px')) "$($engine.Name)/$scenario $($previewPath.Name) did not enforce the 21px platform icon size."
                        Assert-True (-not $previewHtml.Contains('platform-roku.png') -and -not $previewHtml.Contains('unsafe-platform')) "$($engine.Name)/$scenario $($previewPath.Name) used another user's or an unknown platform."
                    }
                    else {
                        Assert-True (-not $previewHtml.Contains('platform-android.png')) "$($engine.Name)/$scenario $($previewPath.Name) rendered a platform gap where the weekly heading is suppressed."
                    }
                }
                Assert-True (-not $previewLog.Contains('Android-TV') -and -not $previewLog.Contains('Roku') -and -not $previewLog.Contains('unsafe-platform')) "$($engine.Name)/$scenario exposed platform details in renderer logs."
                if ($engine.Name -eq 'nas-docker-linux-freebsd') {
                    $platformManagerResult = Get-Content -LiteralPath $managerResultPath -Raw -Encoding UTF8
                    Assert-True (-not $platformManagerResult.Contains('Android') -and -not $platformManagerResult.Contains('Roku') -and -not $platformManagerResult.Contains('unsafe-platform')) "$($engine.Name)/$scenario exposed platform details in Manager history."
                }
            }
            if ($scenario -eq $lastPlatformScenario) {
                $expectedLastPlatformPreviewSource = if ($engine.Container) { 'assets/platform-apple-tv.png' } else { '../assets/platform-apple-tv.png' }
                foreach ($previewPath in $previewPaths) {
                    $previewHtml = Get-Content $previewPath.FullName -Raw -Encoding UTF8
                    if ($previewHtml.Contains('YOUR WEEK ON PLEX')) {
                        Assert-True ($previewHtml.Contains($expectedLastPlatformPreviewSource) -and $previewHtml.Contains('alt="Platform: Apple TV"')) "$($engine.Name)/$scenario $($previewPath.Name) did not render the selected recipient's Last Platform fallback."
                        Assert-True (-not $previewHtml.Contains('platform-roku.png') -and -not $previewHtml.Contains('Unrecognized Platform')) "$($engine.Name)/$scenario $($previewPath.Name) used another user's or an unknown platform."
                    }
                }
                Assert-True (-not $previewLog.Contains('tvOS') -and -not $previewLog.Contains('Roku') -and -not $previewLog.Contains('Unrecognized Platform')) "$($engine.Name)/$scenario exposed Last Platform details in renderer logs."
            }
            Assert-True ($normalHtml.Contains('class="email-card"')) "$($engine.Name)/$scenario lost explicit dark card classes."
            Assert-True ($normalHtml.Contains('bgcolor="#181818"')) "$($engine.Name)/$scenario lost the legacy dark card fallback."
            Assert-True ($normalHtml.Contains('background-color:#181818')) "$($engine.Name)/$scenario lost the longhand dark card fallback."
            if ($scenario -notin @($quietNoHistoryScenario, $quietNoGlobalHistoryScenario)) {
            Assert-True ($normalHtml.Contains('YOU CLOCKED') -and $normalHtml.Contains('total watch time')) "$($engine.Name)/$scenario lost the personal total-watch-time presentation."
            Assert-True (-not $normalHtml.Contains('>total watched<')) "$($engine.Name)/$scenario retained the old personal-time label."
            Assert-True (([regex]::Matches($normalHtml, 'class="stats-summary-cell"')).Count -eq 2) "$($engine.Name)/$scenario did not render exactly two compact desktop summary cells."
            Assert-True (([regex]::Matches($normalHtml, 'height="178"')).Count -ge 4) "$($engine.Name)/$scenario did not keep both compact summary cards at the same fixed height."
            Assert-True ($normalHtml.Contains('.stats-summary-cell { display:block !important; width:100% !important;')) "$($engine.Name)/$scenario lost responsive summary-card stacking."
            Assert-True (-not $normalHtml.Contains('height:356px')) "$($engine.Name)/$scenario still couples summary-card height to four personal media rows."
            Assert-True ($normalHtml.Contains('colspan="2" width="100%" valign="top"')) "$($engine.Name)/$scenario did not render the populated personal media card at full width."
            Assert-True ($normalHtml.Contains('class="stats-title-cell" width="50%"') -and $normalHtml.Contains('.stats-title-cell { display:block !important; width:100% !important;')) "$($engine.Name)/$scenario lost the two-column desktop and one-column mobile movie-title layout."
            Assert-True ($normalHtml.Contains('.stats-title-cell.stats-tv-title-cell { display:table-cell !important; width:50% !important;')) "$($engine.Name)/$scenario lost the two-column mobile TV-title rule."
            }
            Assert-True (-not $quietHtml.Contains('class="stats-summary-cell"') -and -not $quietHtml.Contains('YOU CLOCKED')) "$($engine.Name)/$scenario rendered personal summary cards in the zero-activity state."
            Assert-True (-not $normalHtml.Contains('Ratings unavailable') -and -not $normalHtml.Contains('IMDb unavailable')) "$($engine.Name)/$scenario rendered an unavailable-rating placeholder."
            $expectedMode = if ($scenario -in @('quiet', $quietNoHistoryScenario, $quietNoGlobalHistoryScenario, 'tv-only', $sparseEpisodeMetadataScenario, 'optional-hero-metadata') -or $scenario -in $deletedHistoryScenarios) { 'TRENDING / RECENT MOVIES' } else { 'NORMAL / NEW RELEASES' }
            Assert-True ($indexHtml.Contains($expectedMode)) "$($engine.Name)/$scenario reported the wrong release mode."
            Assert-True ($normalHtml.Contains('Selected Movie')) "$($engine.Name)/$scenario lost the selected movie."
            if ($scenario -eq $lastPlatformScenario) {
                Assert-True (-not $normalHtml.Contains('Selected Show')) "$($engine.Name)/$scenario reused a TV champion as the Trending hero or compact Trending footer."
                Assert-True ($normalHtml.Contains('HOT NEW RELEASE')) "$($engine.Name)/$scenario did not keep its in-window movie in the active hero path."
            }
            else {
                Assert-True ($normalHtml.Contains('Selected Show')) "$($engine.Name)/$scenario lost the selected TV show."
            }
            Assert-True (-not $normalHtml.Contains('Private Movie')) "$($engine.Name)/$scenario leaked a private-library title."
            Assert-True (-not $normalHtml.Contains('Simulated Champion')) "$($engine.Name)/$scenario leaked the Binge Champion identity."
            if ($scenario -ne $quietNoGlobalHistoryScenario) {
            $expectedChampionDuration = if ($scenario -eq 'quiet') { '10h 0m watched' } elseif ($scenario -eq $quietNoHistoryScenario) { '5h 0m watched' } elseif ($scenario -eq $sparseEpisodeMetadataScenario) { '3h 40m watched' } elseif ($scenario -eq 'optional-hero-metadata') { '4h 0m watched' } else { '3h 0m watched' }
            Assert-True ($normalHtml.Contains($expectedChampionDuration)) "$($engine.Name)/$scenario lost the shared champion duration line."
            $expectedChampionMedia = if ($scenario -eq 'optional-hero-metadata') { '1 movie' } else { '1 TV show' }
            Assert-True ($normalHtml.Contains($expectedChampionMedia)) "$($engine.Name)/$scenario lost the Binge Champion media breakdown."
            Assert-True (-not $normalHtml.Contains('0 movies') -and -not $normalHtml.Contains('0 TV shows')) "$($engine.Name)/$scenario rendered an empty Binge Champion media category."
            }
            Assert-True (-not $normalHtml.Contains('qualifying plays')) "$($engine.Name)/$scenario retained qualifying-play copy in Total Watched."
            if ($scenario -notin $deletedHistoryScenarios -and $scenario -notin @('personal-many', 'quiet', $sparseEpisodeMetadataScenario) -and $scenario -ne $platformScenario -and $scenario -ne $quietNoHistoryScenario) {
                Assert-True (-not $normalHtml.Contains('TV SHOWS WATCHED')) "$($engine.Name)/$scenario rendered an empty TV stats card."
            }

            if ($scenario -in @('active', 'quiet')) {
                $stateContracts = @(
                    [PSCustomObject]@{ Html = $manualHtml; Name = 'Manual Welcome'; Required = @('WELCOME ABOARD'); Forbidden = @('YOU CLOCKED') },
                    [PSCustomObject]@{ Html = $newNoHistoryHtml; Name = 'New User - No History'; Required = @('WELCOME ABOARD'); Forbidden = @('YOU CLOCKED') },
                    [PSCustomObject]@{ Html = $newWithHistoryHtml; Name = 'New User - With History'; Required = @('WELCOME ABOARD', 'YOU CLOCKED'); Forbidden = @() },
                    [PSCustomObject]@{ Html = $normalHtml; Name = 'Normal Newsletter'; Required = @('YOU CLOCKED'); Forbidden = @('WELCOME ABOARD') },
                    [PSCustomObject]@{ Html = $quietHtml; Name = 'Established Quiet'; Required = @('QUIET IN THIS SECTOR'); Forbidden = @('YOU CLOCKED') },
                    [PSCustomObject]@{ Html = $warmupHtml; Name = 'Established Warnings'; Required = @('STATS ARE WARMING UP'); Forbidden = @('YOU CLOCKED') }
                )
                foreach ($stateContract in $stateContracts) {
                    foreach ($requiredMarker in $stateContract.Required) {
                        Assert-True ($stateContract.Html.Contains($requiredMarker)) "$($engine.Name)/$scenario $($stateContract.Name) lost state marker: $requiredMarker"
                    }
                    foreach ($forbiddenMarker in $stateContract.Forbidden) {
                        Assert-True (-not $stateContract.Html.Contains($forbiddenMarker)) "$($engine.Name)/$scenario $($stateContract.Name) rendered forbidden state marker: $forbiddenMarker"
                    }
                    Assert-True (-not $stateContract.Html.Contains('Sample Movie') -and -not $stateContract.Html.Contains('Sample Series')) "$($engine.Name)/$scenario $($stateContract.Name) created synthetic viewing history."
                }
            }

            if ($scenario -eq 'active') {
                $watchedPreviewBase = if ($engine.Container) { 'assets' } else { '../assets' }
                foreach ($stateHtml in $scenarioPreviewHtml) {
                    Assert-True ($stateHtml.Contains('1 NEW MOVIE') -and $stateHtml.Contains('1 TV TITLE')) "$($engine.Name)/$scenario did not share the active release-count line across all six states."
                    Assert-True ($stateHtml.Contains('HOT NEW RELEASE') -and $stateHtml.Contains('NEW RELEASES')) "$($engine.Name)/$scenario did not preserve HOT/new-release behavior across all six states."
                    $heroStart = $stateHtml.IndexOf('<tr class="design-hot-desktop">', [StringComparison]::Ordinal)
                    $releaseStart = if ($heroStart -ge 0) { $stateHtml.IndexOf('NEW RELEASES', $heroStart + 1, [StringComparison]::Ordinal) } else { -1 }
                    Assert-True ($heroStart -ge 0 -and $releaseStart -gt $heroStart) "$($engine.Name)/$scenario could not isolate the active hero from its release shelves."
                    $heroHtml = $stateHtml.Substring($heroStart, $releaseStart - $heroStart)
                    Assert-True ($heroHtml.Contains('class="design-desktop-logo"') -and $heroHtml.Contains('media/logo_selected-movie.png')) "$($engine.Name)/$scenario lost the active desktop clearLogo."
                    Assert-True ($heroHtml.Contains('A release from the selected movie library.') -and $heroHtml.Contains('Drama, Mystery') -and $heroHtml.Contains('2026')) "$($engine.Name)/$scenario lost active hero summary, genres, or year."
                    Assert-True ($heroHtml.Contains('Rotten Tomatoes critic') -and $heroHtml.Contains('Rotten Tomatoes audience')) "$($engine.Name)/$scenario lost active hero ratings."
                    Assert-True ($heroHtml.Contains('81%</span>') -and $heroHtml.Contains('92%</span>')) "$($engine.Name)/$scenario swapped or lost exact active hero critic/audience values."
                    Assert-True (([regex]::Matches($heroHtml, 'class="recipient-watched-title-icon"')).Count -eq 1) "$($engine.Name)/$scenario did not render exactly one circular hero marker."
                    Assert-True (([regex]::Matches($stateHtml, 'class="recipient-watched-desktop-badge"')).Count -eq 1) "$($engine.Name)/$scenario did not render exactly one desktop hero badge."
                    Assert-True ($heroHtml.Contains('<span style="vertical-align:middle;">Selected </span><span class="recipient-watched-title-tail" style="white-space:nowrap;"><span style="vertical-align:middle;">Movie</span><img class="recipient-watched-title-icon"')) "$($engine.Name)/$scenario did not place the circular marker immediately after the mobile hero title."
                    Assert-True ($heroHtml.Contains('alt="Watched" title="Watched"') -and $heroHtml.Contains('vertical-align:middle;margin-left:8px;')) "$($engine.Name)/$scenario lost accessible, centered, consistently spaced hero markup."
                    Assert-True ($heroHtml.Contains("src=`"$watchedPreviewBase/watched.png`"") -and $heroHtml.Contains("src=`"$watchedPreviewBase/watched-desktop.png`"")) "$($engine.Name)/$scenario used broken watched preview asset paths."
                    Assert-True ($heroHtml.Contains('<v:group') -and $heroHtml.Contains('coordsize="180,275"') -and $heroHtml.Contains('left:147;top:0;width:26;height:26;') -and $heroHtml.Contains('width="7" height="26"') -and $heroHtml.Contains('padding:5px 0 0;')) "$($engine.Name)/$scenario lost Outlook or standard desktop overlay placement."
                    Assert-True ($heroHtml.Contains('4 plays')) "$($engine.Name)/$scenario collapsed the grouped HOT history row to one play."
                    $activeReleaseHtml = Get-HtmlSection -Html $stateHtml -StartMarker 'NEW RELEASES' -EndMarkers @('YOUR WEEK ON PLEX', 'FRIDAY DROPS')
                    Assert-True (-not [string]::IsNullOrWhiteSpace($activeReleaseHtml)) "$($engine.Name)/$scenario could not bound the active release shelf."
                    Assert-True (-not $activeReleaseHtml.Contains('Selected Movie') -and $activeReleaseHtml.Contains('Selected Show')) "$($engine.Name)/$scenario duplicated the HOT movie in New Releases or lost the TV shelf."
                    Assert-True (-not $activeReleaseHtml.Contains('recipient-watched-title-icon')) "$($engine.Name)/$scenario marked a TV release."
                    $afterActiveHeroHtml = $stateHtml.Substring($releaseStart)
                    Assert-True ($afterActiveHeroHtml.Contains('>Active Trending Movie</div>') -and $afterActiveHeroHtml.Contains('posters/poster_active-trending-movie.jpg') -and -not $afterActiveHeroHtml.Contains('recipient-watched')) "$($engine.Name)/$scenario marked footer Trending or lost its title/poster."
                }
                $activeLogoPath = Join-Path (Join-Path $outputRoot 'media') 'logo_selected-movie.png'
                Assert-True ((Test-Path -LiteralPath $activeLogoPath) -and (Get-Item -LiteralPath $activeLogoPath).Length -gt 256) "$($engine.Name)/$scenario did not persist the active clearLogo asset."
                $activeStatsStart = $normalHtml.IndexOf('YOUR WEEK ON PLEX', [StringComparison]::Ordinal)
                Assert-True ($activeStatsStart -ge 0) "$($engine.Name)/$scenario could not isolate active real-history stats."
                $activeStatsHtml = $normalHtml.Substring($activeStatsStart)
                $expectedChromePreviewSource = if ($engine.Container) { 'assets/platform-chrome.png' } else { '../assets/platform-chrome.png' }
                Assert-True ($activeStatsHtml.Contains('MOVIES WATCHED') -and $activeStatsHtml.Contains('>Selected Movie</div>') -and -not $activeStatsHtml.Contains('recipient-watched')) "$($engine.Name)/$scenario marked the footer or lost the personal movie recap."
                Assert-True ($activeStatsHtml.Contains('Drama, Mystery') -and $activeStatsHtml.Contains('Rotten Tomatoes critic') -and $activeStatsHtml.Contains('Rotten Tomatoes audience')) "$($engine.Name)/$scenario lost watched-movie genres or critic/audience ratings."
                Assert-True ($activeStatsHtml.Contains('81%</span>') -and $activeStatsHtml.Contains('92%</span>')) "$($engine.Name)/$scenario swapped or lost exact watched-movie critic/audience values."
                Assert-True ($activeStatsHtml.Contains('posters/poster_selected-movie.jpg')) "$($engine.Name)/$scenario lost the watched-movie stat poster."
                Assert-True ($activeStatsHtml.Contains($expectedChromePreviewSource) -and $activeStatsHtml.Contains('alt="Platform: Chrome"')) "$($engine.Name)/$scenario lost the real recipient platform icon from active stats."
            }

            if ($scenario -eq 'quiet') {
                $watchedPreviewBase = if ($engine.Container) { 'assets' } else { '../assets' }
                foreach ($stateHtml in $scenarioPreviewHtml) {
                    Assert-True ($stateHtml.Contains('1 TRENDING MOVIE') -and $stateHtml.Contains('4 RECENT MOVIE RELEASES')) "$($engine.Name)/$scenario did not share the exact quiet count line across all six states."
                    Assert-True ($stateHtml.Contains('mso-hide:all;">1 TRENDING MOVIE • 4 RECENT MOVIE RELEASES')) "$($engine.Name)/$scenario did not inherit the quiet count line into email preview text."
                    Assert-True ($stateHtml.Contains('TRENDING THIS WEEK') -and $stateHtml.Contains('RECENT RELEASES') -and -not $stateHtml.Contains('HOT NEW RELEASE')) "$($engine.Name)/$scenario did not share quiet Trending/latest behavior across all six states."
                    $heroStart = $stateHtml.IndexOf('<tr class="design-hot-desktop">', [StringComparison]::Ordinal)
                    $releaseStart = if ($heroStart -ge 0) { $stateHtml.IndexOf('RECENT RELEASES', $heroStart + 1, [StringComparison]::Ordinal) } else { -1 }
                    Assert-True ($heroStart -ge 0 -and $releaseStart -gt $heroStart) "$($engine.Name)/$scenario could not isolate the quiet hero from its release shelves."
                    $heroHtml = $stateHtml.Substring($heroStart, $releaseStart - $heroStart)
                    $releaseHtml = $stateHtml.Substring($releaseStart)
                    Assert-True ($heroHtml.Contains('class="design-desktop-logo"') -and $heroHtml.Contains('media/logo_quiet-trending-movie.png')) "$($engine.Name)/$scenario lost the quiet desktop clearLogo."
                    Assert-True ($heroHtml.Contains('A complete quiet-week hero with real metadata.') -and $heroHtml.Contains('Adventure, Comedy') -and $heroHtml.Contains('2026')) "$($engine.Name)/$scenario lost quiet hero summary, genres, or year."
                    Assert-True ($heroHtml.Contains('Rotten Tomatoes critic') -and $heroHtml.Contains('Rotten Tomatoes audience')) "$($engine.Name)/$scenario lost quiet hero ratings."
                    Assert-True ($heroHtml.Contains('88%</span>') -and $heroHtml.Contains('94%</span>')) "$($engine.Name)/$scenario swapped or lost exact quiet hero critic/audience values."
                    Assert-True ($heroHtml.Contains('Most watched across Virtual Plex this week') -and $heroHtml.Contains('4 plays')) "$($engine.Name)/$scenario lost authentic trending watch statistics."
                    $watchedShelfHtml = Get-HtmlSection -Html $stateHtml -StartMarker 'RECENT RELEASES' -EndMarkers @('YOUR WEEK ON PLEX', 'FRIDAY DROPS')
                    Assert-True (([regex]::Matches(($heroHtml + $watchedShelfHtml), 'class="recipient-watched-title-icon"')).Count -eq 2) "$($engine.Name)/$scenario did not render exactly one circular hero marker and one watched movie-card marker."
                    Assert-True (([regex]::Matches($stateHtml, 'class="recipient-watched-desktop-badge"')).Count -eq 1) "$($engine.Name)/$scenario did not render exactly one desktop hero badge."
                    Assert-True ($heroHtml.Contains('<span style="vertical-align:middle;">Quiet Trending </span><span class="recipient-watched-title-tail" style="white-space:nowrap;"><span style="vertical-align:middle;">Movie</span><img class="recipient-watched-title-icon"')) "$($engine.Name)/$scenario did not place the circular marker immediately after the mobile hero title."
                    Assert-True ($releaseHtml.Contains('<span style="vertical-align:middle;">Recent Movie </span><span class="recipient-watched-title-tail" style="white-space:nowrap;"><span style="vertical-align:middle;">One</span><img class="recipient-watched-title-icon"')) "$($engine.Name)/$scenario did not place the circular marker immediately after a watched card title."
                    Assert-True ($stateHtml.Contains('alt="Watched" title="Watched"') -and $stateHtml.Contains('vertical-align:middle;margin-left:8px;')) "$($engine.Name)/$scenario lost accessible, centered, consistently spaced marker markup."
                    Assert-True ($stateHtml.Contains("src=`"$watchedPreviewBase/watched.png`"") -and $heroHtml.Contains("src=`"$watchedPreviewBase/watched-desktop.png`"")) "$($engine.Name)/$scenario used broken watched preview asset paths."
                    Assert-True ($heroHtml.Contains('<v:group') -and $heroHtml.Contains('coordsize="180,275"') -and $heroHtml.Contains('left:147;top:0;width:26;height:26;') -and $heroHtml.Contains('width="7" height="26"') -and $heroHtml.Contains('padding:5px 0 0;')) "$($engine.Name)/$scenario lost Outlook or standard desktop overlay placement."
                    Assert-True ($releaseHtml.Contains('>Selected Movie</div>') -and -not $releaseHtml.Contains('<span style="vertical-align:middle;">Selected </span><span class="recipient-watched-title-tail" style="white-space:nowrap;"><span style="vertical-align:middle;">Movie</span><img class="recipient-watched-title-icon"')) "$($engine.Name)/$scenario left a gap or leaked another user's watched state into Selected Movie."
                    Assert-True (-not $releaseHtml.Contains('Selected Show<img class="recipient-watched-title-icon"')) "$($engine.Name)/$scenario changed TV card rendering."
                    foreach ($movieTitle in @('Recent Movie One', 'Selected Movie', 'Recent Movie Three', 'Recent Movie Four')) {
                        Assert-True ($releaseHtml.Contains($movieTitle)) "$($engine.Name)/$scenario lost capped quiet movie: $movieTitle"
                    }
                    foreach ($showTitle in @('Selected Show', 'Recent Show Two', 'Recent Show Three', 'Recent Show Four')) {
                        Assert-True ($releaseHtml.Contains($showTitle)) "$($engine.Name)/$scenario lost eligible under-one-month TV title: $showTitle"
                    }
                    Assert-True (-not $releaseHtml.Contains('Quiet Trending Movie') -and -not $releaseHtml.Contains('TRENDING THIS WEEK')) "$($engine.Name)/$scenario duplicated the Trending hero in Recent Releases or the lower stat section."
                    Assert-True (-not $stateHtml.Contains('Recent Movie Overflow')) "$($engine.Name)/$scenario exceeded the four-movie quiet cap."
                    Assert-True (-not $stateHtml.Contains('Stale Show Beyond One Month')) "$($engine.Name)/$scenario included a TV title older than one calendar month."
                    Assert-True (-not $stateHtml.Contains('Toy Story 5')) "$($engine.Name)/$scenario substituted the old fallback shell."
                }
                $quietLogoPath = Join-Path (Join-Path $outputRoot 'media') 'logo_quiet-trending-movie.png'
                Assert-True ((Test-Path -LiteralPath $quietLogoPath) -and (Get-Item -LiteralPath $quietLogoPath).Length -gt 256) "$($engine.Name)/$scenario did not persist the quiet clearLogo asset."
                Assert-True ($previewLog.Contains('Recent Releases candidates: 5 movies and 4 TV titles.')) "$($engine.Name)/$scenario did not report the bounded quiet candidates before hero exclusion."
                Assert-True ($normalHtml.Contains('1 movie') -and $normalHtml.Contains('1 TV show')) "$($engine.Name)/$scenario lost the real mixed-media Binge Champion breakdown."
                $expectedChromePreviewSource = if ($engine.Container) { 'assets/platform-chrome.png' } else { '../assets/platform-chrome.png' }
                foreach ($populatedStateHtml in @($newWithHistoryHtml, $normalHtml)) {
                    $statsStart = $populatedStateHtml.IndexOf('YOUR WEEK ON PLEX', [StringComparison]::Ordinal)
                    Assert-True ($statsStart -ge 0) "$($engine.Name)/$scenario could not isolate populated real-history stats."
                    $statsHtml = $populatedStateHtml.Substring($statsStart)
                    Assert-True ($statsHtml.Contains('MOVIES WATCHED') -and $statsHtml.Contains('Recent Movie One')) "$($engine.Name)/$scenario lost the selected viewer's real movie stat row."
                    Assert-True ($statsHtml.Contains('Drama, Mystery') -and $statsHtml.Contains('Rotten Tomatoes critic') -and $statsHtml.Contains('Rotten Tomatoes audience')) "$($engine.Name)/$scenario lost watched-movie genres or critic/audience ratings."
                    Assert-True ($statsHtml.Contains('84%</span>') -and $statsHtml.Contains('90%</span>')) "$($engine.Name)/$scenario swapped or lost exact quiet watched-movie critic/audience values."
                    Assert-True ($statsHtml.Contains('posters/poster_quiet-recent-movie-01.jpg')) "$($engine.Name)/$scenario lost the watched-movie poster."
                    Assert-True ($statsHtml.Contains('TV SHOWS WATCHED') -and $statsHtml.Contains('Recent Show Two')) "$($engine.Name)/$scenario lost the selected viewer's real TV stat row."
                    Assert-True ($statsHtml.Contains('alt="IMDb"') -and $statsHtml.Contains('8.5') -and -not $statsHtml.Contains('6.1') -and $statsHtml.Contains('1h 0m watched')) "$($engine.Name)/$scenario lost show-level IMDb/duration or reused the episode rating."
                    Assert-True ($statsHtml.Contains('posters/poster_selected-show-recent-02.jpg')) "$($engine.Name)/$scenario lost the watched-TV poster."
                    Assert-True ($statsHtml.Contains($expectedChromePreviewSource) -and $statsHtml.Contains('alt="Platform: Chrome"')) "$($engine.Name)/$scenario lost the real recipient platform icon from populated stats."
                }
            }

            if ($scenario -eq $quietNoHistoryScenario) {
                Assert-True ($indexHtml.Contains('render authentic no-history output without fictional viewing data')) "$($engine.Name)/$scenario did not disclose authentic zero-history behavior."
                Assert-True ($newNoHistoryHtml.Contains('WELCOME ABOARD') -and -not $newNoHistoryHtml.Contains('YOU CLOCKED')) "$($engine.Name)/$scenario lost the intentional new-user/no-history state."
                Assert-True ($newWithHistoryHtml.Contains('WELCOME ABOARD') -and -not $newWithHistoryHtml.Contains('YOU CLOCKED')) "$($engine.Name)/$scenario invented new-user activity."
                Assert-True (-not $normalHtml.Contains('YOU CLOCKED')) "$($engine.Name)/$scenario invented established-user activity."
                foreach ($previewPath in $previewPaths) {
                    $authenticHtml = Get-Content -LiteralPath $previewPath.FullName -Raw -Encoding UTF8
                    Assert-True (-not $authenticHtml.Contains('Sample Movie') -and -not $authenticHtml.Contains('Sample Series')) "$($engine.Name)/$scenario emitted fabricated watch rows in $($previewPath.Name)."
                }
                Assert-True ($quietHtml.Contains('QUIET IN THIS SECTOR') -and -not $quietHtml.Contains('YOU CLOCKED')) "$($engine.Name)/$scenario lost the intentional established quiet state."
                Assert-True ($warmupHtml.Contains('STATS ARE WARMING UP') -and -not $warmupHtml.Contains('YOU CLOCKED')) "$($engine.Name)/$scenario lost the intentional warm-up state."
                foreach ($contentRichHtml in @($newWithHistoryHtml, $normalHtml)) {
                    Assert-True ($contentRichHtml.Contains('Selected Movie') -and $contentRichHtml.Contains('Selected Show')) "$($engine.Name)/$scenario lost real latest-release titles from a populated lifecycle state."
                    Assert-True ($contentRichHtml.Contains('A release from the selected movie library.') -and $contentRichHtml.Contains('Drama, Mystery')) "$($engine.Name)/$scenario lost latest movie summary or genres."
                    Assert-True ($contentRichHtml.Contains('Rotten Tomatoes critic') -and $contentRichHtml.Contains('Rotten Tomatoes audience')) "$($engine.Name)/$scenario lost latest movie ratings."
                    Assert-True ($contentRichHtml.Contains('posters/poster_selected-movie.jpg') -and $contentRichHtml.Contains('posters/poster_selected-show.jpg')) "$($engine.Name)/$scenario lost latest release posters."
                }
                Assert-True ($quietHtml.Contains('TRENDING THIS WEEK') -and $quietHtml.Contains('RECENT RELEASES')) "$($engine.Name)/$scenario did not render Trending plus the latest-release fallback."
                $quietReleaseStart = $quietHtml.IndexOf('RECENT RELEASES', [StringComparison]::Ordinal)
                Assert-True ($quietReleaseStart -ge 0) "$($engine.Name)/$scenario could not isolate the real quiet release shelf."
                $quietReleaseHtml = $quietHtml.Substring($quietReleaseStart)
                Assert-True (-not $quietReleaseHtml.Contains('Selected Movie') -and $quietReleaseHtml.Contains('Selected Show')) "$($engine.Name)/$scenario duplicated the Trending movie or lost the real TV fallback."
                Assert-True (-not $quietHtml.Contains('Toy Story 5')) "$($engine.Name)/$scenario substituted an unrelated fallback shell."
                Assert-True ($previewLog.Contains('Recent Releases candidates: 1 movies and 1 TV titles.')) "$($engine.Name)/$scenario did not load the bounded quiet-week fallback."
                Assert-True ($previewLog.Contains('Recent Releases will query 2 active movie/TV library section(s).')) "$($engine.Name)/$scenario used the empty global hub instead of enumerated library sections."
            }
            if ($scenario -eq $quietNoGlobalHistoryScenario) {
                foreach ($stateHtml in $scenarioPreviewHtml) {
                    Assert-True ($stateHtml.Contains('4 RECENT MOVIE RELEASES')) "$($engine.Name)/$scenario did not retain the exact real Recent counts across all six states."
                    Assert-True ($stateHtml.Contains('RECENT RELEASES')) "$($engine.Name)/$scenario lost Recent Releases without global history."
                    Assert-True (-not $stateHtml.Contains('TRENDING MOVIE') -and -not $stateHtml.Contains('TRENDING THIS WEEK') -and -not $stateHtml.Contains('HOT NEW RELEASE')) "$($engine.Name)/$scenario invented a Trending/HOT hero or count without global history."
                    $latestHtml = Get-HtmlSection -Html $stateHtml -StartMarker 'RECENT RELEASES' -EndMarkers @('YOUR WEEK ON PLEX', 'FRIDAY DROPS')
                    Assert-True (-not [string]::IsNullOrWhiteSpace($latestHtml)) "$($engine.Name)/$scenario could not bound real Recent Releases."
                    foreach ($movieTitle in @('Quiet Trending Movie', 'Recent Movie One', 'Selected Movie', 'Recent Movie Three')) {
                        Assert-True ($latestHtml.Contains($movieTitle)) "$($engine.Name)/$scenario lost no-history recent movie: $movieTitle"
                    }
                    foreach ($showTitle in @('Selected Show', 'Recent Show Two', 'Recent Show Three', 'Recent Show Four')) {
                        Assert-True ($latestHtml.Contains($showTitle)) "$($engine.Name)/$scenario lost no-history recent TV title: $showTitle"
                    }
                    Assert-True (-not $stateHtml.Contains('Recent Movie Four') -and -not $stateHtml.Contains('Recent Movie Overflow')) "$($engine.Name)/$scenario exceeded the no-history four-movie cap."
                    Assert-True (-not $stateHtml.Contains('Stale Show Beyond One Month')) "$($engine.Name)/$scenario included a no-history TV title older than one calendar month."
                    Assert-True (-not $stateHtml.Contains('YOU CLOCKED') -and -not $stateHtml.Contains('MOVIES WATCHED') -and -not $stateHtml.Contains('TV SHOWS WATCHED')) "$($engine.Name)/$scenario invented personal viewing rows."
                    Assert-True (-not $stateHtml.Contains("THIS WEEK'S BINGE CHAMPION") -and -not $stateHtml.Contains('YOU WON • BINGE CHAMPION') -and -not $stateHtml.Contains('Most watched across')) "$($engine.Name)/$scenario invented server-wide watch footer data."
                    Assert-True (-not $stateHtml.Contains('Sample Movie') -and -not $stateHtml.Contains('Sample Series') -and -not $stateHtml.Contains('Toy Story 5')) "$($engine.Name)/$scenario substituted synthetic content."
                }
                Assert-True ($previewLog.Contains('Recent Releases candidates: 5 movies and 4 TV titles.')) "$($engine.Name)/$scenario did not load bounded real Recent candidates."
            }

            if ($scenario -eq $sparseEpisodeMetadataScenario) {
                Assert-True ($normalHtml.Contains('0 NEW MOVIES') -and $normalHtml.Contains('1 TV TITLE')) "$($engine.Name)/$scenario reported the wrong sparse release counts."
                $sparseHeroStart = $normalHtml.IndexOf('TRENDING THIS WEEK', [StringComparison]::Ordinal)
                $sparseReleaseStart = if ($sparseHeroStart -ge 0) { $normalHtml.IndexOf('NEW RELEASES', $sparseHeroStart + 1, [StringComparison]::Ordinal) } else { -1 }
                Assert-True ($sparseHeroStart -ge 0 -and $sparseReleaseStart -gt $sparseHeroStart -and -not $normalHtml.Contains('HOT NEW RELEASE')) "$($engine.Name)/$scenario did not keep a movie-only Trending hero beside the TV release shelf."
                $sparseHeroHtml = $normalHtml.Substring($sparseHeroStart, $sparseReleaseStart - $sparseHeroStart)
                Assert-True ($sparseHeroHtml.Contains('Selected-library viewing history.') -and $sparseHeroHtml.Contains('Drama, Mystery') -and $sparseHeroHtml.Contains('2026')) "$($engine.Name)/$scenario did not backfill sparse hero descriptive metadata from the later real row."
                Assert-True ($sparseHeroHtml.Contains('Rotten Tomatoes critic') -and $sparseHeroHtml.Contains('81%</span>') -and $sparseHeroHtml.Contains('Rotten Tomatoes audience') -and $sparseHeroHtml.Contains('92%</span>')) "$($engine.Name)/$scenario lost the complete sparse hero rating pairs."
                Assert-True (-not $sparseHeroHtml.Contains('76%</span>') -and -not $sparseHeroHtml.Contains('77%</span>')) "$($engine.Name)/$scenario combined rating values and providers from different sparse rows."

                $sparseReleaseHtml = Get-HtmlSection -Html $normalHtml -StartMarker 'NEW RELEASES' -EndMarkers @('YOUR WEEK ON PLEX')
                Assert-True ($sparseReleaseHtml.Contains('Selected Show') -and $sparseReleaseHtml.Contains('Selected Premiere')) "$($engine.Name)/$scenario lost the real TV release or exact episode."
                $sparseEpisodeStart = $sparseReleaseHtml.IndexOf('Selected Premiere', [StringComparison]::Ordinal)
                $sparseEpisodeHtml = if ($sparseEpisodeStart -ge 0) { $sparseReleaseHtml.Substring($sparseEpisodeStart, [Math]::Min(900, $sparseReleaseHtml.Length - $sparseEpisodeStart)) } else { '' }
                Assert-True ($sparseEpisodeHtml.Contains('alt="IMDb"') -and $sparseEpisodeHtml.Contains('8.7')) "$($engine.Name)/$scenario did not preserve exact-episode IMDb through sparse successful metadata."
                Assert-True (-not $sparseEpisodeHtml.Contains('62%')) "$($engine.Name)/$scenario contaminated exact episode IMDb with the separate RT fallback."

                $sparseStatsStart = $normalHtml.IndexOf('YOUR WEEK ON PLEX', [StringComparison]::Ordinal)
                Assert-True ($sparseStatsStart -ge 0) "$($engine.Name)/$scenario could not isolate sparse real-history stats."
                $sparseStatsHtml = $normalHtml.Substring($sparseStatsStart)
                Assert-True ($sparseStatsHtml.Contains('MOVIES WATCHED') -and $sparseStatsHtml.Contains('Drama, Mystery') -and $sparseStatsHtml.Contains('81%</span>') -and $sparseStatsHtml.Contains('92%</span>')) "$($engine.Name)/$scenario did not backfill exact movie metadata in sparse personal stats."
                Assert-True (-not $sparseStatsHtml.Contains('76%</span>') -and -not $sparseStatsHtml.Contains('77%</span>')) "$($engine.Name)/$scenario mixed partial movie rating pairs in personal stats."
                Assert-True ($sparseStatsHtml.Contains('TV SHOWS WATCHED') -and $sparseStatsHtml.Contains('Selected Show') -and $sparseStatsHtml.Contains('alt="IMDb"') -and $sparseStatsHtml.Contains('8.4') -and $sparseStatsHtml.Contains('1h 30m watched')) "$($engine.Name)/$scenario lost show-level IMDb or aggregated TV duration."
                Assert-True (-not $sparseStatsHtml.Contains('7.3') -and -not $sparseStatsHtml.Contains('8.7')) "$($engine.Name)/$scenario promoted an incomplete show pair or ordinary episode IMDb into show stats."
                Assert-True ($sparseStatsHtml.Contains('posters/poster_selected-movie.jpg') -and $sparseStatsHtml.Contains('posters/poster_selected-show.jpg')) "$($engine.Name)/$scenario lost sparse real-history posters."
                $expectedChromePreviewSource = if ($engine.Container) { 'assets/platform-chrome.png' } else { '../assets/platform-chrome.png' }
                Assert-True ($sparseStatsHtml.Contains($expectedChromePreviewSource) -and $sparseStatsHtml.Contains('alt="Platform: Chrome"')) "$($engine.Name)/$scenario lost the sparse real-history platform icon."
                Assert-True (-not $previewLog.Contains('TV RT fallback:')) "$($engine.Name)/$scenario invoked RT fallback despite exact episode IMDb."
            }

            if ($scenario -eq 'optional-hero-metadata') {
                $heroStart = $normalHtml.IndexOf('TRENDING THIS WEEK', [StringComparison]::Ordinal)
                $latestStart = if ($heroStart -ge 0) { $normalHtml.IndexOf('RECENT RELEASES', $heroStart, [StringComparison]::Ordinal) } else { -1 }
                Assert-True ($heroStart -ge 0 -and $latestStart -gt $heroStart) "$($engine.Name)/$scenario could not isolate the quiet Trending hero."
                $heroHtml = $normalHtml.Substring($heroStart, $latestStart - $heroStart)
                Assert-True ($heroHtml.Contains('Selected-library viewing history.') -and $heroHtml.Contains('Drama, Mystery')) "$($engine.Name)/$scenario projected away the Trending hero summary or genres."
                Assert-True ($heroHtml.Contains('Rotten Tomatoes critic') -and $heroHtml.Contains('Rotten Tomatoes audience') -and $heroHtml.Contains('2026')) "$($engine.Name)/$scenario projected away the Trending hero year or ratings."
                Assert-True ($heroHtml.Contains('81%</span>') -and $heroHtml.Contains('92%</span>')) "$($engine.Name)/$scenario swapped or lost exact sparse-hero critic/audience values."
            }
            if ($scenario -eq 'personal-many') {
                Assert-True ($normalHtml.Contains('Personal Movie 12') -and $normalHtml.Contains('Personal Show 11')) "$($engine.Name)/$scenario capped personal movie or TV rows before the final synthetic title."
                Assert-True (([regex]::Matches($normalHtml, 'class="stats-title-cell(?: stats-tv-title-cell stats-tv-title-(?:left|right))?"')).Count -eq 23) "$($engine.Name)/$scenario did not render all 12 movie and 11 TV title cells."

                Assert-True (([regex]::Matches($normalHtml, 'class="stats-title-cell stats-tv-title-cell stats-tv-title-(?:left|right)"')).Count -eq 11) "$($engine.Name)/$scenario did not identify every TV cell for two-column mobile rendering."
                Assert-True (([regex]::Matches($normalHtml, 'class="stats-title-spacer stats-tv-title-spacer"')).Count -eq 1) "$($engine.Name)/$scenario did not preserve the odd TV grid row without a visible empty mobile item."
                $movieStatsStart = $normalHtml.IndexOf('MOVIES WATCHED', [StringComparison]::Ordinal)
                $tvStatsStart = $normalHtml.IndexOf('TV SHOWS WATCHED', [StringComparison]::Ordinal)
                Assert-True ($movieStatsStart -ge 0 -and $tvStatsStart -gt $movieStatsStart) "$($engine.Name)/$scenario did not stack the full-width Movies and TV cards in order."
                Assert-True ($normalHtml.Substring($movieStatsStart, $tvStatsStart - $movieStatsStart).Contains('Personal Movie 12')) "$($engine.Name)/$scenario did not keep the twelfth movie inside the Movies card."
                Assert-True ($normalHtml.Substring($tvStatsStart).Contains('Personal Show 11')) "$($engine.Name)/$scenario did not keep the eleventh TV show inside the TV card."
                Assert-True ($normalHtml.Contains('posters/poster_personal-movie-12.jpg') -and $normalHtml.Contains('posters/poster_selected-show-personal-11.jpg')) "$($engine.Name)/$scenario lost beyond-four poster references."
                $moviePoster = Join-Path (Join-Path $outputRoot 'posters') 'poster_personal-movie-12.jpg'
                $showPoster = Join-Path (Join-Path $outputRoot 'posters') 'poster_selected-show-personal-11.jpg'
                Assert-True ((Test-Path $moviePoster) -and (Get-Item $moviePoster).Length -gt 512) "$($engine.Name)/$scenario did not persist the twelfth movie poster."
                Assert-True ((Test-Path $showPoster) -and (Get-Item $showPoster).Length -gt 512) "$($engine.Name)/$scenario did not persist the eleventh TV poster."
                $movieTwelveStart = $normalHtml.IndexOf('Personal Movie 12', [StringComparison]::Ordinal)
                $showElevenStart = $normalHtml.IndexOf('Personal Show 11', [StringComparison]::Ordinal)
                Assert-True ($movieTwelveStart -ge 0 -and $normalHtml.Substring($movieTwelveStart, [Math]::Min(1500, $normalHtml.Length - $movieTwelveStart)).Contains('alt="Rotten Tomatoes critic"')) "$($engine.Name)/$scenario lost the twelfth movie rating."
                Assert-True ($showElevenStart -ge 0 -and $normalHtml.Substring($showElevenStart, [Math]::Min(1500, $normalHtml.Length - $showElevenStart)).Contains('alt="IMDb"')) "$($engine.Name)/$scenario lost the eleventh TV rating."
                Assert-True ($normalHtml.Contains('2h 51m') -and $normalHtml.Contains('3h 0m watched')) "$($engine.Name)/$scenario did not preserve the intentionally distinct personal and Binge Champion time semantics."
            }

            if ($scenario -eq 'tv-only') {
                foreach ($stateHtml in $scenarioPreviewHtml) {
                    Assert-True ($stateHtml.Contains('0 NEW MOVIES') -and $stateHtml.Contains('1 TV TITLE')) "$($engine.Name)/$scenario did not share the weekly TV count across all six states."
                    Assert-True ($stateHtml.Contains('mso-hide:all;">0 NEW MOVIES • 1 TV TITLE')) "$($engine.Name)/$scenario did not inherit the weekly TV count into email preview text."
                }
                Assert-True ($normalHtml.Contains('TRENDING THIS WEEK') -and $normalHtml.Contains('RECENT RELEASES') -and $normalHtml.Contains('NEW RELEASES')) "$($engine.Name)/$scenario lost the Trending, Recent Movies, or New TV sections."
                Assert-True (-not $normalHtml.Contains('HOT NEW RELEASE')) "$($engine.Name)/$scenario promoted a TV release as HOT NEW RELEASE."
                $recentMovieHtml = Get-HtmlSection -Html $normalHtml -StartMarker 'RECENT RELEASES' -EndMarkers @('NEW RELEASES', 'YOUR WEEK ON PLEX')
                foreach ($movieTitle in @('Quiet Trending Movie', 'Recent Movie One', 'Recent Movie Three', 'Recent Movie Four')) {
                    Assert-True ($recentMovieHtml.Contains($movieTitle)) "$($engine.Name)/$scenario lost recent movie card: $movieTitle"
                }
                Assert-True (-not $recentMovieHtml.Contains('Selected Movie') -and -not $recentMovieHtml.Contains('Selected Show')) "$($engine.Name)/$scenario duplicated the Trending hero or mixed new TV into Recent Movies."
                $newTvHtml = Get-HtmlSection -Html $normalHtml -StartMarker 'NEW RELEASES' -EndMarkers @('YOUR WEEK ON PLEX')
                Assert-True ($newTvHtml.Contains('Selected Show') -and -not $newTvHtml.Contains('Quiet Trending Movie')) "$($engine.Name)/$scenario did not retain the new TV release in its own section."
            }

            if ($scenario -eq 'rating-export-fallback') {
                Assert-True ($normalHtml.Contains('53%') -and $normalHtml.Contains('40%')) "$($engine.Name)/$scenario did not render preferred movie RT ratings from Tautulli's item export."
                Assert-True ($normalHtml.Contains('alt="IMDb"') -and $normalHtml.Contains('8.7')) "$($engine.Name)/$scenario did not render the exact episode IMDb rating."
                Assert-True (-not $normalHtml.Contains('6.6') -and -not $normalHtml.Contains('TMDB') -and -not $normalHtml.Contains('7.4')) "$($engine.Name)/$scenario rendered a lower-priority movie or episode provider."
                Assert-True ($previewLog.Contains('Design rich export result: RT critic=53%, audience=40')) "$($engine.Name)/$scenario did not report the successful JSON rating fallback."
                Assert-True ($previewLog.Contains('Design rich export result: RT critic=n/a, audience=n/a, IMDb=n/a, selected=TMDB 7.4')) "$($engine.Name)/$scenario did not report the successful show selected-provider fallback."
                Assert-True (-not $previewLog.Contains('selected-logo level 9')) "$($engine.Name)/$scenario mislabeled a rating-only item export as a logo export."
                Assert-True (-not $previewLog.Contains('could not enumerate additional exporter fields')) "$($engine.Name)/$scenario did not use a compatible Tautulli field-discovery request."
            }

            if ($scenario -in $directRatingScenarios) {
                Assert-True ($normalHtml.Contains('87%') -and $normalHtml.Contains('83%')) "$($engine.Name)/$scenario did not render movie RT from Plex's optional Rating element."
                if ($scenario -eq $directEpisodeRtScenario) {
                    Assert-True ($normalHtml.Contains('Selected Premiere') -and $normalHtml.Contains('alt="Rotten Tomatoes critic"') -and $normalHtml.Contains('62%')) "$($engine.Name)/$scenario did not render exact-episode RT after IMDb was unavailable."
                    Assert-True ($previewLog.Contains("TV RT fallback: Selected Show S1E1 'Selected Premiere' -> critic 62%")) "$($engine.Name)/$scenario did not report the sanitized exact-episode RT fallback."
                }
                else {
                    Assert-True ($normalHtml.Contains('alt="IMDb"') -and $normalHtml.Contains('8.6')) "$($engine.Name)/$scenario did not render exact-episode IMDb from Plex's optional Rating element."
                }
                Assert-True (-not $normalHtml.Contains('6.6') -and -not $normalHtml.Contains('TMDB') -and -not $normalHtml.Contains('7.4')) "$($engine.Name)/$scenario rendered the flattened selected provider instead of the optional ratings."
                Assert-True (-not $previewLog.Contains('Design rich export result:')) "$($engine.Name)/$scenario unnecessarily used Tautulli's item export after direct optional ratings succeeded."
            }

            if ($scenario -in $providerRecoveryScenarios) {
                Assert-True ($previewLog.Contains('recovered an exact movie match through the provider POST contract')) "$($engine.Name)/$scenario PreviewAll did not report the provider-contract recovery."
                Assert-True ($previewLog.Contains('recovered an exact show match through the provider POST contract')) "$($engine.Name)/$scenario PreviewAll did not report the TV provider-contract recovery."
                Assert-True ($normalHtml.Contains('TV SHOWS WATCHED')) "$($engine.Name)/$scenario did not render the deleted-history TV stats card."
                Assert-True ($normalHtml.Contains('History Drama, Mystery, and more')) "$($engine.Name)/$scenario did not restore deleted movie genres."
                Assert-True ($normalHtml.Contains('87%') -and $normalHtml.Contains('93%')) "$($engine.Name)/$scenario did not restore deleted movie ratings."
                $tvStatsStart = $normalHtml.IndexOf('TV SHOWS WATCHED', [StringComparison]::Ordinal)
                Assert-True ($tvStatsStart -ge 0) "$($engine.Name)/$scenario could not locate the deleted-history TV stats card."
                $tvStatsLength = [Math]::Min(3000, $normalHtml.Length - $tvStatsStart)
                $tvStatsHtml = $normalHtml.Substring($tvStatsStart, $tvStatsLength)
                Assert-True ($tvStatsHtml -match 'alt="IMDb"[^>]*>8\.4') "$($engine.Name)/$scenario did not render the restored IMDb rating inside the deleted-history TV stats card."
                Assert-True ($normalHtml.Contains('posters/poster_selected-movie.jpg')) "$($engine.Name)/$scenario did not render the recovered movie poster."
                Assert-True ($normalHtml.Contains('posters/poster_selected-show.jpg')) "$($engine.Name)/$scenario did not render the recovered TV poster."

                $moviePoster = Join-Path (Join-Path $outputRoot 'posters') 'poster_selected-movie.jpg'
                $showPoster = Join-Path (Join-Path $outputRoot 'posters') 'poster_selected-show.jpg'
                Assert-True ((Test-Path $moviePoster) -and (Get-Item $moviePoster).Length -gt 512) "$($engine.Name)/$scenario did not persist the recovered movie poster."
                Assert-True ((Test-Path $showPoster) -and (Get-Item $showPoster).Length -gt 512) "$($engine.Name)/$scenario did not persist the recovered TV poster."
                $providerCacheRoot = if ($engine.Container) { Join-Path $dataRoot 'cache/deleted-items' } else { Join-Path $appRoot 'cache/deleted-items' }
                $providerCacheIndex = Join-Path $providerCacheRoot 'index.json'
                if (Test-Path -LiteralPath $providerCacheIndex) {
                    $providerEntries = @((Get-Content -LiteralPath $providerCacheIndex -Raw -Encoding UTF8 | ConvertFrom-Json).Entries)
                    Assert-True ($providerEntries.Count -eq 0) "$($engine.Name)/$scenario persisted best-effort provider recovery as though it were a live local capture."
                }
            }

            if ($scenario -eq $cacheScenario) {
                Assert-True ($previewLog.Contains('Deleted-item cache hit for an exact movie GUID')) "$($engine.Name)/$scenario did not report an exact movie cache hit."
                Assert-True ($previewLog.Contains('Deleted-item cache hit for an exact show GUID')) "$($engine.Name)/$scenario did not report an exact TV cache hit."
                Assert-True ($previewLog.Contains('Restored deleted movie history artwork from the bounded pre-deletion cache.')) "$($engine.Name)/$scenario did not restore cached movie artwork."
                Assert-True ($previewLog.Contains('Restored deleted show history artwork from the bounded pre-deletion cache.')) "$($engine.Name)/$scenario did not restore cached TV artwork."
                Assert-True (-not $previewLog.Contains('recovered an exact movie match through the provider POST contract')) "$($engine.Name)/$scenario unexpectedly depended on provider recovery."
                Assert-True ($normalHtml.Contains('A release from the selected movie library.')) "$($engine.Name)/$scenario did not restore cached movie presentation metadata."
                Assert-True ($normalHtml.Contains('Drama, Mystery')) "$($engine.Name)/$scenario did not restore cached genres."
                Assert-True ($normalHtml.Contains('posters/poster_selected-movie.jpg')) "$($engine.Name)/$scenario did not render the cached movie poster."
                Assert-True ($normalHtml.Contains('posters/poster_selected-show.jpg')) "$($engine.Name)/$scenario did not render the cached TV poster."
                $cacheRoot = if ($engine.Container) { Join-Path $dataRoot 'cache/deleted-items' } else { Join-Path $appRoot 'cache/deleted-items' }
                $cacheText = Get-Content -LiteralPath (Join-Path $cacheRoot 'index.json') -Raw -Encoding UTF8
                foreach ($privateMarker in @('virtual-api-key', 'virtual-plex-token', 'viewer@example.com', 'champion@example.com', 'play_duration', 'watched_status', 'percent_complete', 'friendly_name')) {
                    Assert-True (-not $cacheText.Contains($privateMarker)) "$($engine.Name)/$scenario cache leaked private marker: $privateMarker"
                }
            }

            $calls = @(Get-Content $callLog | ForEach-Object { $_ | ConvertFrom-Json })
            $lastPlatformCalls = @($calls | Where-Object {
                $null -ne $_.query.PSObject.Properties['cmd'] -and
                [string]$_.query.cmd -eq 'get_users_table'
            })
            if ($scenario -eq $lastPlatformScenario) {
                Assert-True ($lastPlatformCalls.Count -ge 1) "$($engine.Name)/$scenario did not use Last Platform for Preview."
                foreach ($lastPlatformCall in $lastPlatformCalls) {
                    Assert-True ([string]$lastPlatformCall.query.user_id -eq '1' -and [string]$lastPlatformCall.query.start -eq '0' -and [string]$lastPlatformCall.query.length -eq '1') "$($engine.Name)/$scenario issued an unbounded or cross-recipient Last Platform lookup."
                }
            }
            elseif ($scenario -eq $platformScenario) {
                Assert-True ($lastPlatformCalls.Count -eq 0) "$($engine.Name)/$scenario ignored the recognized report-window winner and queried Last Platform."
            }
            Assert-True (@($calls | Where-Object { [string]$_.path -eq '/identity' -and $_.has_plex_token }).Count -gt 0) "$($engine.Name)/$scenario did not authenticate the direct Plex identity verification request."
            Assert-True (@($calls | Where-Object { [string]$_.path -eq '/library/sections' -and $_.has_plex_token }).Count -gt 0) "$($engine.Name)/$scenario did not authenticate the direct Plex library verification request."
            if ($scenario -in $directRatingScenarios) {
                $directItemCalls = @($calls | Where-Object {
                    [string]$_.path -match '^/library/metadata/[^/]+$'
                })
                $directRatingCalls = @($directItemCalls | Where-Object {
                    $null -ne $_.query.PSObject.Properties['includeOptionalElements'] -and
                    $null -ne $_.query.PSObject.Properties['excludeFields'] -and
                    [string]$_.query.includeOptionalElements -eq 'Rating' -and
                    [string]$_.query.excludeFields -eq 'rating'
                })
                Assert-True (@($directRatingCalls | Where-Object { [string]$_.path -eq '/library/metadata/selected-movie' -and $_.has_plex_token }).Count -gt 0) "$($engine.Name)/$scenario did not request the movie optional Rating element privately."
                Assert-True (@($directRatingCalls | Where-Object { [string]$_.path -eq '/library/metadata/selected-show' -and $_.has_plex_token }).Count -gt 0) "$($engine.Name)/$scenario did not request the show optional Rating element privately."
                Assert-True (@($directRatingCalls | Where-Object { [string]$_.path -eq '/library/metadata/selected-episode' -and $_.has_plex_token }).Count -gt 0) "$($engine.Name)/$scenario did not request the exact episode optional Rating element privately."
                if ($scenario -eq $directOptionalRatingScenario) {
                    Assert-True ($directRatingCalls.Count -eq $directItemCalls.Count) "$($engine.Name)/$scenario issued direct item metadata without requesting optional Rating or suppressing the colliding scalar."
                }
                elseif ($scenario -eq $directXmlRatingScenario) {
                    $xmlRatingCalls = @($directItemCalls | Where-Object {
                        [string]$_.accept -like '*application/xml*' -and
                        $null -ne $_.query.PSObject.Properties['includeOptionalElements'] -and
                        [string]$_.query.includeOptionalElements -eq 'Rating' -and
                        $null -eq $_.query.PSObject.Properties['excludeFields']
                    })
                    Assert-True (@($xmlRatingCalls | Where-Object { [string]$_.path -eq '/library/metadata/selected-movie' -and $_.has_plex_token }).Count -gt 0) "$($engine.Name)/$scenario did not recover movie ratings from authenticated native XML."
                    Assert-True (@($xmlRatingCalls | Where-Object { [string]$_.path -eq '/library/metadata/selected-show' -and $_.has_plex_token }).Count -gt 0) "$($engine.Name)/$scenario did not recover show ratings from authenticated native XML."
                    Assert-True (@($xmlRatingCalls | Where-Object { [string]$_.path -eq '/library/metadata/selected-episode' -and $_.has_plex_token }).Count -gt 0) "$($engine.Name)/$scenario did not recover exact-episode ratings from authenticated native XML."
                }
                else {
                    $episodeXmlCalls = @($directItemCalls | Where-Object {
                        [string]$_.path -eq '/library/metadata/selected-episode' -and
                        [string]$_.accept -like '*application/xml*' -and
                        $null -ne $_.query.PSObject.Properties['includeOptionalElements'] -and
                        [string]$_.query.includeOptionalElements -eq 'Rating'
                    })
                    Assert-True (@($episodeXmlCalls | Where-Object { $_.has_plex_token }).Count -gt 0) "$($engine.Name)/$scenario did not exhaust authenticated exact-episode IMDb before using RT."
                }
            }
            if ($scenario -eq 'rating-export-fallback') {
                $ratingFieldCalls = @($calls | Where-Object {
                    $null -ne $_.query -and
                    $null -ne $_.query.PSObject.Properties['cmd'] -and
                    [string]$_.query.cmd -eq 'get_export_fields'
                })
                Assert-True ($ratingFieldCalls.Count -ge 1) "$($engine.Name)/$scenario did not issue an exporter field-discovery request."
                foreach ($ratingFieldCall in $ratingFieldCalls) {
                    $fieldMediaType = [string]$ratingFieldCall.query.media_type
                    Assert-True ($fieldMediaType -in @('movie', 'show')) "$($engine.Name)/$scenario requested fields for the wrong media type."
                    Assert-True ([string]$ratingFieldCall.query.sub_media_type -eq $fieldMediaType) "$($engine.Name)/$scenario omitted Tautulli's required compatibility subtype."
                }
                Assert-True ('movie' -in @($ratingFieldCalls | ForEach-Object { [string]$_.query.media_type })) "$($engine.Name)/$scenario did not discover movie rating fields."
                Assert-True ('show' -in @($ratingFieldCalls | ForEach-Object { [string]$_.query.media_type })) "$($engine.Name)/$scenario did not discover show rating fields."

                $ratingExportCalls = @($calls | Where-Object {
                    $null -ne $_.query -and
                    $null -ne $_.query.PSObject.Properties['cmd'] -and
                    [string]$_.query.cmd -eq 'export_metadata' -and
                    [string]$_.query.logo_level -eq '0'
                })
                Assert-True ($ratingExportCalls.Count -eq 2) "$($engine.Name)/$scenario did not issue exactly one movie and one show item export."
                Assert-True (@($ratingExportCalls | Where-Object { [string]$_.query.rating_key -eq 'selected-movie' }).Count -eq 1) "$($engine.Name)/$scenario omitted the movie item export."
                Assert-True (@($ratingExportCalls | Where-Object { [string]$_.query.rating_key -eq 'selected-show' }).Count -eq 1) "$($engine.Name)/$scenario omitted the show item export."
                foreach ($ratingExportCall in $ratingExportCalls) {
                    Assert-True ([string]$ratingExportCall.query.individual_files -eq 'false') "$($engine.Name)/$scenario requested invalid individual files for a rating-key export."
                    Assert-True ([string]$ratingExportCall.query.metadata_level -eq '1') "$($engine.Name)/$scenario requested more Tautulli metadata than the rating fallback needs."
                    Assert-True ([string]$ratingExportCall.query.media_info_level -eq '0') "$($engine.Name)/$scenario requested private media information."
                    $requestedRatingFields = @(([string]$ratingExportCall.query.custom_fields).Split(',') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    Assert-True ($requestedRatingFields.Count -eq 4) "$($engine.Name)/$scenario requested fields beyond the four provider-labelled rating fields."
                    foreach ($requiredRatingField in @('rating', 'ratingImage', 'audienceRating', 'audienceRatingImage')) {
                        Assert-True ($requiredRatingField -in $requestedRatingFields) "$($engine.Name)/$scenario omitted explicit exporter field '$requiredRatingField'."
                    }
                }
            }
            $mediaCalls = @($calls | Where-Object {
                $null -ne $_.query.PSObject.Properties['cmd'] -and
                [string]$_.query.cmd -in @('get_history', 'get_recently_added')
            })
            Assert-True ($mediaCalls.Count -gt 0) "$($engine.Name)/$scenario made no media calls."
            if ($scenario -eq $quietNoHistoryScenario) {
                $unscopedRecentCalls = @($mediaCalls | Where-Object {
                    [string]$_.query.cmd -eq 'get_recently_added' -and
                    $null -eq $_.query.PSObject.Properties['section_id']
                })
                Assert-True ($unscopedRecentCalls.Count -eq 1) "$($engine.Name)/$scenario did not limit the empty global recently-added hub to weekly quiet detection."
                $scopedRecentSections = @($mediaCalls | Where-Object {
                    [string]$_.query.cmd -eq 'get_recently_added' -and
                    $null -ne $_.query.PSObject.Properties['section_id']
                } | ForEach-Object { [string]$_.query.section_id } | Sort-Object -Unique)
                Assert-True (($scopedRecentSections -join ',') -eq '10,20') "$($engine.Name)/$scenario did not query every active movie/TV section for Recent Releases."
            }
            else {
                Assert-True (@($mediaCalls | Where-Object {
                    $null -eq $_.query.PSObject.Properties['section_id'] -or
                    [string]$_.query.section_id -notin @('10', '20')
                }).Count -eq 0) "$($engine.Name)/$scenario issued an unscoped/private media query."
            }

            if ($scenario -in $providerRecoveryScenarios) {
                $hostedCalls = @($calls | Where-Object { [string]$_.path -like '/hosted/library/metadata/*' })
                Assert-True (@($hostedCalls | Where-Object { -not $_.has_plex_token }).Count -eq 0) "$($engine.Name)/$scenario called hosted metadata without the administrator Plex token."
                if ($scenario -eq 'deleted-history-legacy-guid') {
                    $legacyMovieQueryCalls = @($hostedCalls | Where-Object {
                        [string]$_.method -eq 'GET' -and
                        [string]$_.path -eq '/hosted/library/metadata/matches' -and
                        [string]$_.query.guid -eq 'tmdb://12345' -and
                        [string]$_.query.type -eq '1'
                    })
                    $legacyShowQueryCalls = @($hostedCalls | Where-Object {
                        [string]$_.method -eq 'GET' -and
                        [string]$_.path -eq '/hosted/library/metadata/matches' -and
                        [string]$_.query.guid -eq 'tvdb://999' -and
                        [string]$_.query.type -eq '2'
                    })
                    $legacyMoviePostCalls = @($hostedCalls | Where-Object {
                        [string]$_.method -eq 'POST' -and
                        [string]$_.path -eq '/hosted/library/metadata/matches' -and
                        [string]$_.body.guid -eq 'tmdb://12345' -and
                        [int]$_.body.type -eq 1
                    })
                    $legacyShowPostCalls = @($hostedCalls | Where-Object {
                        [string]$_.method -eq 'POST' -and
                        [string]$_.path -eq '/hosted/library/metadata/matches' -and
                        [string]$_.body.guid -eq 'tvdb://999' -and
                        [int]$_.body.type -eq 2
                    })
                    Assert-True ($legacyMovieQueryCalls.Count -gt 0) "$($engine.Name)/$scenario did not preserve the compatible exact TMDB query attempt."
                    Assert-True ($legacyShowQueryCalls.Count -gt 0) "$($engine.Name)/$scenario did not preserve the compatible exact TVDB query attempt."
                    Assert-True ($legacyMoviePostCalls.Count -gt 0) "$($engine.Name)/$scenario did not recover the exact legacy TMDB movie GUID through the provider POST contract."
                    Assert-True ($legacyShowPostCalls.Count -gt 0) "$($engine.Name)/$scenario did not recover the exact legacy TVDB show GUID through the provider POST contract."
                    Assert-True (@($legacyMoviePostCalls | Where-Object { [string]$_.body.title -eq 'Selected Movie' }).Count -gt 0) "$($engine.Name)/$scenario omitted the required retained movie title hint."
                    Assert-True (@($legacyShowPostCalls | Where-Object { [string]$_.body.title -eq 'Selected Show' }).Count -gt 0) "$($engine.Name)/$scenario omitted the required retained show title hint."
                }
                else {
                    Assert-True (@($hostedCalls | Where-Object { [string]$_.method -eq 'GET' -and [string]$_.path -eq '/hosted/library/metadata/deletedmovieguid' }).Count -gt 0) "$($engine.Name)/$scenario did not preserve the direct retained movie GUID attempt."
                    Assert-True (@($hostedCalls | Where-Object { [string]$_.method -eq 'GET' -and [string]$_.path -eq '/hosted/library/metadata/deletedepisodeguid' }).Count -gt 0) "$($engine.Name)/$scenario did not preserve the direct retained episode GUID attempt."
                    Assert-True (@($hostedCalls | Where-Object { [string]$_.method -eq 'GET' -and [string]$_.path -eq '/hosted/library/metadata/deletedshowguid' }).Count -gt 0) "$($engine.Name)/$scenario did not preserve the direct retained show GUID attempt."
                    $modernPostCalls = @($hostedCalls | Where-Object {
                        [string]$_.method -eq 'POST' -and
                        [string]$_.path -eq '/hosted/library/metadata/matches'
                    })
                    Assert-True (@($modernPostCalls | Where-Object { [string]$_.body.guid -eq 'plex://movie/deletedmovieguid' -and [int]$_.body.type -eq 1 }).Count -gt 0) "$($engine.Name)/$scenario did not recover the modern movie GUID through the provider POST contract."
                    Assert-True (@($modernPostCalls | Where-Object { [string]$_.body.guid -eq 'plex://episode/deletedepisodeguid' -and [int]$_.body.type -eq 4 }).Count -gt 0) "$($engine.Name)/$scenario did not preserve the modern episode type through the provider POST contract."
                    Assert-True (@($modernPostCalls | Where-Object { [string]$_.body.guid -eq 'plex://show/deletedshowguid' -and [int]$_.body.type -eq 2 }).Count -gt 0) "$($engine.Name)/$scenario did not promote the modern episode GUID to exact show metadata."
                    Assert-True (@($modernPostCalls | Where-Object { [string]$_.body.guid -eq 'plex://movie/deletedmovieguid' -and [string]$_.body.title -eq 'Selected Movie' }).Count -gt 0) "$($engine.Name)/$scenario omitted the required modern movie title hint."
                    Assert-True (@($modernPostCalls | Where-Object { [string]$_.body.guid -eq 'plex://episode/deletedepisodeguid' -and [string]$_.body.grandparentTitle -eq 'Selected Show' -and [int]$_.body.parentIndex -eq 1 -and [int]$_.body.index -eq 1 }).Count -gt 0) "$($engine.Name)/$scenario omitted the required modern episode match hints."
                    Assert-True (@($modernPostCalls | Where-Object { [string]$_.body.guid -eq 'plex://show/deletedshowguid' -and [string]$_.body.title -eq 'Selected Show' }).Count -gt 0) "$($engine.Name)/$scenario omitted the required promoted show title hint."
                }
                $hostedPostBodies = @($hostedCalls | Where-Object { [string]$_.method -eq 'POST' } | ForEach-Object { $_.body })
                Assert-True (@($hostedPostBodies | Where-Object {
                    $names = @($_.PSObject.Properties.Name)
                    @($names | Where-Object { $_ -in @('user_id', 'friendly_name', 'email', 'play_duration', 'watched_status', 'percent_complete') }).Count -gt 0
                }).Count -eq 0) "$($engine.Name)/$scenario sent recipient or viewing-history fields to hosted metadata."
                Assert-True (@($calls | Where-Object { [string]$_.path -match 'private' }).Count -eq 0) "$($engine.Name)/$scenario leaked a private-library identifier to hosted metadata."
                $watchCalls = @($calls | Where-Object { [string]$_.path -like '/watch/*' })
                Assert-True (@($watchCalls | Where-Object { $_.has_plex_token }).Count -eq 0) "$($engine.Name)/$scenario forwarded the Plex token to the public rating fallback."
                Assert-True (@($watchCalls | Where-Object { [string]$_.path -eq '/watch/movie/selected-movie' }).Count -gt 0) "$($engine.Name)/$scenario did not resolve movie ratings from the exact hosted slug."
                Assert-True (@($watchCalls | Where-Object { [string]$_.path -eq '/watch/show/selected-show' }).Count -gt 0) "$($engine.Name)/$scenario did not resolve TV IMDb from the exact hosted slug."
                Assert-True (@($watchCalls | Where-Object { @($_.query.PSObject.Properties).Count -gt 0 }).Count -eq 0) "$($engine.Name)/$scenario searched the public rating fallback instead of using an exact slug."
                $externalPosterCalls = @($calls | Where-Object { [string]$_.path -eq '/hosted/deleted-movie.jpg' })
                Assert-True ($externalPosterCalls.Count -gt 0) "$($engine.Name)/$scenario did not fetch the external hosted movie poster."
                Assert-True (@($externalPosterCalls | Where-Object { $_.has_plex_token }).Count -eq 0) "$($engine.Name)/$scenario forwarded the Plex token to an external poster host."
            }

            if ($scenario -in $sendTestScenarios) {
                $previewLog = Get-Content $stdout -Raw
                if ($scenario -notin $directRatingScenarios -and $scenario -notin @('active', 'quiet', 'tv-only', $platformScenario, $lastPlatformScenario, $quietNoHistoryScenario, $quietNoGlobalHistoryScenario, $sparseEpisodeMetadataScenario)) {
                    Assert-True ($previewLog -match 'direct Plex .*404.*Not Found') "$($engine.Name)/$scenario did not exercise the recoverable direct Plex 404 fallback."
                }
                if ($scenario -ne $quietNoGlobalHistoryScenario) {
                    $expectedSparseHeroTitle = if ($scenario -eq 'quiet') { 'Quiet Trending Movie' } elseif ($scenario -in @('active', 'tv-only', 'optional-hero-metadata', $lastPlatformScenario, $sparseEpisodeMetadataScenario)) { 'Selected Movie' } else { 'Selected Show' }
                    Assert-True ($normalHtml.Contains($expectedSparseHeroTitle)) "$($engine.Name)/$scenario lost the global-history title fallback for sparse hero metadata."
                }

                $accessStatePath = if ($engine.Container) {
                    Join-Path $dataRoot 'access-state.json'
                }
                else {
                    Join-Path $appRoot 'access-state.json'
                }
                [PSCustomObject]@{
                    BaselineUtc = [DateTime]::UtcNow.AddDays(-30).ToString('o')
                    Users = [PSCustomObject]@{
                        '1' = [PSCustomObject]@{
                            UserId = '1'; Username = 'viewer'; Email = 'viewer@example.com'
                            FirstSeenUtc = [DateTime]::UtcNow.AddDays(-30).ToString('o')
                            IsBaseline = $true; WelcomeSentUtc = ''
                        }
                        '2' = [PSCustomObject]@{
                            UserId = '2'; Username = 'champion'; Email = 'champion@example.com'
                            FirstSeenUtc = [DateTime]::UtcNow.AddDays(-30).ToString('o')
                            IsBaseline = $true; WelcomeSentUtc = ''
                        }
                    }
                } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $accessStatePath -Encoding UTF8

                if ($scenario -in @('active', 'quiet', $quietNoGlobalHistoryScenario)) {
                    $oldSinglePreviewDataRoot = $env:TAUTWEEKLY_DATA_DIR
                    $oldSinglePreviewConfig = $env:TAUTWEEKLY_CONFIG
                    try {
                        if ($engine.Container) {
                            $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                            $env:TAUTWEEKLY_CONFIG = $configPath
                        }
                        $singlePreviewProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                            '-RendererPath', (Join-Path $appRoot $engine.Renderer), '-ConfigPath', $configPath,
                            '-UserId', '1', '-Mode', 'Preview'
                        ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $previewSingleStdout -RedirectStandardError $previewSingleStderr
                    }
                    finally {
                        $env:TAUTWEEKLY_DATA_DIR = $oldSinglePreviewDataRoot
                        $env:TAUTWEEKLY_CONFIG = $oldSinglePreviewConfig
                    }
                    if ($singlePreviewProcess.ExitCode -ne 0) {
                        throw "$($engine.Name)/$scenario Preview failed ($($singlePreviewProcess.ExitCode)).`nSTDOUT:`n$(Get-Content $previewSingleStdout -Raw)`nSTDERR:`n$(Get-Content $previewSingleStderr -Raw)"
                    }
                    $singlePreviewPaths = @(Get-ChildItem -LiteralPath $outputRoot -File -Filter 'preview_*.html')
                    Assert-True ($singlePreviewPaths.Count -eq 1) "$($engine.Name)/$scenario Preview did not generate exactly one recipient HTML file."
                    $singlePreviewHtml = Get-Content -LiteralPath $singlePreviewPaths[0].FullName -Raw -Encoding UTF8
                    $singleContractMarkers = if ($scenario -eq 'active') {
                        @(
                            '1 NEW MOVIE', '1 TV TITLE', 'HOT NEW RELEASE', 'NEW RELEASES',
                            'A release from the selected movie library.', 'Drama, Mystery',
                            'Rotten Tomatoes critic', 'Rotten Tomatoes audience',
                            '81%</span>', '92%</span>',
                            'Selected Movie', 'Selected Show', 'Active Trending Movie',
                            'posters/poster_active-trending-movie.jpg', 'MOVIES WATCHED',
                            'posters/poster_selected-movie.jpg', 'Platform: Chrome'
                        )
                    }
                    elseif ($scenario -eq 'quiet') {
                        @(
                            '1 TRENDING MOVIE', '4 RECENT MOVIE RELEASES',
                            'TRENDING THIS WEEK', 'RECENT RELEASES',
                            'A complete quiet-week hero with real metadata.', 'Adventure, Comedy',
                            'Rotten Tomatoes critic', 'Rotten Tomatoes audience',
                            '88%</span>', '94%</span>', '84%</span>', '90%</span>',
                            'Recent Movie One', 'Selected Movie', 'Recent Movie Three', 'Recent Movie Four',
                            'Selected Show', 'Recent Show Two', 'Recent Show Three', 'Recent Show Four',
                            'MOVIES WATCHED', 'TV SHOWS WATCHED', 'IMDb', '1h 0m watched', 'Platform: Chrome'
                        )
                    }
                    else {
                        @(
                            '4 RECENT MOVIE RELEASES', 'RECENT RELEASES',
                            'Quiet Trending Movie', 'Recent Movie One', 'Selected Movie', 'Recent Movie Three',
                            'Selected Show', 'Recent Show Two', 'Recent Show Three', 'Recent Show Four'
                        )
                    }
                    foreach ($contractMarker in $singleContractMarkers) {
                        Assert-True ($singlePreviewHtml.Contains($contractMarker) -and $normalHtml.Contains($contractMarker)) "$($engine.Name)/$scenario Preview and Normal PreviewAll diverged at: $contractMarker"
                    }
                    Assert-True (-not $singlePreviewHtml.Contains('Sample Movie') -and -not $singlePreviewHtml.Contains('Sample Series')) "$($engine.Name)/$scenario Preview created synthetic viewing history."
                    if ($scenario -eq 'active') {
                        $singleReleaseHtml = Get-HtmlSection -Html $singlePreviewHtml -StartMarker 'NEW RELEASES' -EndMarkers @('YOUR WEEK ON PLEX')
                        Assert-True (-not [string]::IsNullOrWhiteSpace($singleReleaseHtml) -and -not $singleReleaseHtml.Contains('Selected Movie') -and $singleReleaseHtml.Contains('Selected Show')) "$($engine.Name)/$scenario Preview duplicated the HOT movie in New Releases or lost TV."
                    }
                    elseif ($scenario -eq 'quiet') {
                        $singleLatestHtml = Get-HtmlSection -Html $singlePreviewHtml -StartMarker 'RECENT RELEASES' -EndMarkers @('YOUR WEEK ON PLEX')
                        Assert-True (-not [string]::IsNullOrWhiteSpace($singleLatestHtml)) "$($engine.Name)/$scenario Preview could not isolate Recent Releases."
                        Assert-True (-not $singleLatestHtml.Contains('Quiet Trending Movie') -and -not $singleLatestHtml.Contains('TRENDING THIS WEEK')) "$($engine.Name)/$scenario Preview duplicated its Trending hero below Recent Releases."
                        Assert-True (-not $singlePreviewHtml.Contains('Recent Movie Overflow') -and -not $singlePreviewHtml.Contains('Stale Show Beyond One Month')) "$($engine.Name)/$scenario Preview violated quiet caps or TV cutoff."
                    }
                    else {
                        Assert-True (-not $singlePreviewHtml.Contains('TRENDING MOVIE') -and -not $singlePreviewHtml.Contains('TRENDING THIS WEEK') -and -not $singlePreviewHtml.Contains('HOT NEW RELEASE')) "$($engine.Name)/$scenario Preview invented a no-history hero or count."
                        Assert-True (-not $singlePreviewHtml.Contains('YOU CLOCKED') -and -not $singlePreviewHtml.Contains('MOVIES WATCHED') -and -not $singlePreviewHtml.Contains('TV SHOWS WATCHED')) "$($engine.Name)/$scenario Preview invented no-history stats."
                        Assert-True (-not $singlePreviewHtml.Contains('Recent Movie Four') -and -not $singlePreviewHtml.Contains('Recent Movie Overflow') -and -not $singlePreviewHtml.Contains('Stale Show Beyond One Month')) "$($engine.Name)/$scenario Preview violated no-history caps or TV cutoff."
                    }
                }

                $oldDataRoot = $env:TAUTWEEKLY_DATA_DIR
                $sendTestTrendingMetadataBefore = if ($scenario -eq 'active') { Get-TautulliMetadataCallCount -CallLogPath $callLog -RatingKey 'active-trending-movie' } else { 0 }
                $oldConfig = $env:TAUTWEEKLY_CONFIG
                $oldMetadataProvider = $env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL
                $oldPlexWatch = $env:TAUTWEEKLY_TEST_PLEX_WATCH_URL
                try {
                    if ($engine.Container) {
                        $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                        $env:TAUTWEEKLY_CONFIG = $configPath
                    }
                    if ($scenario -in $deletedHistoryScenarios) {
                        Remove-Item -LiteralPath (Join-Path $outputRoot 'posters') -Recurse -Force -ErrorAction SilentlyContinue
                        New-Item -ItemType Directory -Force -Path (Join-Path $outputRoot 'posters') | Out-Null
                        $env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL = $baseUrl + '/hosted'
                        $env:TAUTWEEKLY_TEST_PLEX_WATCH_URL = $baseUrl + '/watch'
                    }
                    $sendProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                        '-RendererPath', (Join-Path $appRoot $engine.Renderer), '-ConfigPath', $configPath,
                        '-UserId', '1', '-Mode', 'SendTest'
                    ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $sendStdout -RedirectStandardError $sendStderr
                }
                finally {
                    $env:TAUTWEEKLY_DATA_DIR = $oldDataRoot
                    $env:TAUTWEEKLY_CONFIG = $oldConfig
                    $env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL = $oldMetadataProvider
                    $env:TAUTWEEKLY_TEST_PLEX_WATCH_URL = $oldPlexWatch
                }
                if ($sendProcess.ExitCode -ne 0) {
                    throw "$($engine.Name)/$scenario SendTest failed ($($sendProcess.ExitCode)).`nSTDOUT:`n$(Get-Content $sendStdout -Raw)`nSTDERR:`n$(Get-Content $sendStderr -Raw)"
                }
                $sendLog = Get-Content $sendStdout -Raw
                $sendTestTrendingMetadataDelta = if ($scenario -eq 'active') {
                    (Get-TautulliMetadataCallCount -CallLogPath $callLog -RatingKey 'active-trending-movie') - $sendTestTrendingMetadataBefore
                } else { 0 }
                Assert-True ($sendLog.Contains('Test email sent successfully.')) "$($engine.Name)/$scenario SendTest did not complete delivery."
                if ($scenario -notin $directRatingScenarios -and $scenario -notin @('active', 'quiet', 'tv-only', $platformScenario, $lastPlatformScenario, $quietNoHistoryScenario, $quietNoGlobalHistoryScenario, $sparseEpisodeMetadataScenario)) {
                    Assert-True ($sendLog -match 'direct Plex .*404.*Not Found') "$($engine.Name)/$scenario SendTest did not preserve the direct Plex 404 warning."
                }

                if ($scenario -eq 'rating-export-fallback') {
                    Assert-True ($sendLog.Contains('Design rich export result: RT critic=53%, audience=40')) "$($engine.Name)/$scenario SendTest did not recover both ratings through the explicit item export."
                    Assert-True ($sendLog.Contains('Design rich export result: RT critic=n/a, audience=n/a, IMDb=n/a, selected=TMDB 7.4')) "$($engine.Name)/$scenario SendTest did not recover the show selected-provider rating through the explicit item export."
                    Assert-True (-not $sendLog.Contains('could not enumerate additional exporter fields')) "$($engine.Name)/$scenario SendTest did not use the compatible field-discovery request."
                }
                if ($scenario -in $providerRecoveryScenarios) {
                    Assert-True ($sendLog.Contains('recovered an exact movie match through the provider POST contract')) "$($engine.Name)/$scenario SendTest did not report the provider-contract recovery."
                    Assert-True ($sendLog.Contains('recovered an exact show match through the provider POST contract')) "$($engine.Name)/$scenario SendTest did not report the TV provider-contract recovery."
                    Assert-True ($sendLog.Contains('Recovered deleted Plex movie history artwork')) "$($engine.Name)/$scenario SendTest did not recover deleted movie artwork."
                    Assert-True ($sendLog.Contains('Recovered deleted Plex show history artwork')) "$($engine.Name)/$scenario SendTest did not recover deleted TV artwork."
                }
                if ($scenario -eq $cacheScenario) {
                    Assert-True ($sendLog.Contains('Deleted-item cache hit for an exact movie GUID')) "$($engine.Name)/$scenario SendTest did not reuse cached movie metadata."
                    Assert-True ($sendLog.Contains('Restored deleted movie history artwork from the bounded pre-deletion cache.')) "$($engine.Name)/$scenario SendTest did not reuse cached movie artwork."
                }
                $smtpCommands = @(Get-Content $smtpCallLog | ForEach-Object { ($_ | ConvertFrom-Json).command })
                Assert-True ('DATA' -in $smtpCommands) "$($engine.Name)/$scenario SendTest did not submit an SMTP message."
                Assert-True (Test-Path $smtpDataFile) "$($engine.Name)/$scenario SendTest did not preserve the captured MIME message."
                $emailThemeArgs = @($smtpDataFile)
                $emailThemeArgs += @(
                    '--require-html', 'CUSTOM &lt;TITLE&gt;</span><img',
                    '--require-html', 'cid:custom_title_celebrate',
                    '--require-html', 'display:inline-block;width:18px;height:18px;border:0;vertical-align:-4px;margin-left:6px;',
                    '--require-cid-sha256', 'custom_title_celebrate=A142E1EB25D6277BF95A3086221BA141700E1EF96FC47C3B6A3E1919A4D18FB1',
                    '--forbid-plain', 'Selected Show - Watched',
                    '--forbid-html', 'Sample Movie',
                    '--forbid-html', 'Sample Series',
                    '--forbid-html', 'Toy Story 5'
                )
                if ($scenario -eq $platformScenario) {
                    $emailThemeArgs += @(
                        '--require-html', 'Platform: Android',
                        '--require-html', 'cid:platform_android',
                        '--require-html', 'max-height:21px',
                        '--forbid-html', 'platform_roku',
                        '--forbid-html', 'unsafe-platform',
                        '--require-cid-sha256', 'platform_android=4361DA479BB80C786E681E7CB050E0C61A576887C67D802DACD202A9721EA67E'
                    )
                    Assert-True (-not $sendLog.Contains('Android-TV') -and -not $sendLog.Contains('Roku') -and -not $sendLog.Contains('unsafe-platform')) "$($engine.Name)/$scenario exposed platform details in SendTest logs."
                }
                if ($scenario -eq $lastPlatformScenario) {
                    $emailThemeArgs += @(
                        '--require-html', 'Platform: Apple TV',
                        '--require-html', 'cid:platform_apple_tv',
                        '--require-html', 'max-height:21px',
                        '--forbid-html', 'platform_roku',
                        '--forbid-html', 'Unrecognized Platform',
                        '--require-cid-sha256', 'platform_apple_tv=2E675B179A45FCABE6FEBF535C689D46BAF541BFBD752ED4FC5AB4247E4C2CA2'
                    )
                    Assert-True (-not $sendLog.Contains('tvOS') -and -not $sendLog.Contains('Roku') -and -not $sendLog.Contains('Unrecognized Platform')) "$($engine.Name)/$scenario exposed Last Platform details in SendTest logs."
                }
                if ($scenario -eq 'active') {
                    $emailThemeArgs += @(
                        '--require-html', '1 NEW MOVIE',
                        '--require-html', '1 TV TITLE',
                        '--require-preheader', '1 new movie • 1 new TV title!',
                        '--require-html', 'HOT NEW RELEASE',
                        '--require-html', 'NEW RELEASES',
                        '--require-html', 'A release from the selected movie library.',
                        '--require-html', 'Drama, Mystery',
                        '--require-html', 'Rotten Tomatoes critic',
                        '--require-html', 'Rotten Tomatoes audience',
                        '--require-html', '81%</span>',
                        '--require-html', '92%</span>',
                        '--require-html', 'cid:hero_logo',
                        '--require-html', 'cid:recipient_watched',
                        '--require-html', 'cid:recipient_watched_desktop',
                        '--require-html', 'vertical-align:middle;margin-left:8px;',
                        '--require-plain', 'HOT NEW RELEASE: Selected Movie - Watched',
                        '--require-html', 'Selected Show',
                        '--require-html', 'Active Trending Movie',
                        '--require-html', 'cid:poster_active-trending-movie',
                        '--require-html-between', 'HOT NEW RELEASE=NEW RELEASES=4 plays',
                        '--require-html-between', 'NEW RELEASES=YOUR WEEK ON PLEX=Selected Show',
                        '--forbid-html-between', 'NEW RELEASES=YOUR WEEK ON PLEX=Selected Movie',
                        '--require-html-after', 'YOUR WEEK ON PLEX=MOVIES WATCHED',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Drama, Mystery',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Rotten Tomatoes critic',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Rotten Tomatoes audience',
                        '--require-html-after', 'YOUR WEEK ON PLEX=81%</span>',
                        '--require-html-after', 'YOUR WEEK ON PLEX=92%</span>',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Selected Movie poster',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Platform: Chrome',
                        '--forbid-html', 'Sample Movie',
                        '--forbid-html', 'Sample Series',
                        '--require-html', 'MOVIES WATCHED',
                        '--require-html', 'Selected Movie poster',
                        '--require-html', 'Platform: Chrome',
                        '--require-html', 'cid:platform_chrome',
                        '--require-cid-sha256', 'platform_chrome=AB21A3ABF3DDEDE0A74C2BD0605AB19E73FE4AB369EFD02FB936CED58565C71E',
                        '--require-cid-sha256', 'poster_active-trending-movie=31AC758909ADD2BB42FCE41C0973435FA6705D95A0F8981C4F421A1C6E404817',
                        '--require-cid-png-dimensions', 'hero_logo=320x96'
                    )
                }
                if ($scenario -eq 'quiet') {
                    $emailThemeArgs += @(
                        '--require-html', '1 TRENDING MOVIE',
                        '--require-html', '4 RECENT MOVIE RELEASES',
                        '--require-preheader', '1 TRENDING MOVIE • 4 RECENT MOVIE RELEASES',
                        '--require-html', 'TRENDING THIS WEEK',
                        '--require-html', 'RECENT RELEASES',
                        '--require-html', 'A complete quiet-week hero with real metadata.',
                        '--require-html', 'Adventure, Comedy',
                        '--require-html', 'Rotten Tomatoes critic',
                        '--require-html', 'Rotten Tomatoes audience',
                        '--require-html', '88%</span>',
                        '--require-html', '94%</span>',
                        '--require-html', 'Most watched across Virtual Plex this week',
                        '--require-html', '4 plays',
                        '--require-html', 'cid:hero_logo',
                        '--require-html', 'cid:recipient_watched',
                        '--require-html', 'cid:recipient_watched_desktop',
                        '--require-html', 'vertical-align:middle;margin-left:8px;',
                        '--require-plain', 'TRENDING THIS WEEK: Quiet Trending Movie - Watched',
                        '--require-html', 'Recent Movie One',
                        '--require-html', 'Selected Movie',
                        '--require-html', 'Recent Movie Three',
                        '--require-html', 'Recent Movie Four',
                        '--require-html', 'Selected Show',
                        '--require-html', 'Recent Show Two',
                        '--require-html', 'Recent Show Three',
                        '--require-html', 'Recent Show Four',
                        '--forbid-html', 'Recent Movie Overflow',
                        '--forbid-html', 'Stale Show Beyond One Month',
                        '--forbid-html', 'Sample Movie',
                        '--forbid-html', 'Sample Series',
                        '--forbid-html', 'Toy Story 5',
                        '--forbid-html', 'HOT NEW RELEASE',
                        '--forbid-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Quiet Trending Movie',
                        '--forbid-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=TRENDING THIS WEEK',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Recent Movie One',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Selected Movie',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Recent Movie Three',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Recent Movie Four',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Selected Show',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Recent Show Two',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Recent Show Three',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Recent Show Four',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Drama, Mystery',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Rotten Tomatoes critic',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Rotten Tomatoes audience',
                        '--require-html-after', 'YOUR WEEK ON PLEX=IMDb',
                        '--require-html-after', 'YOUR WEEK ON PLEX=8.5',
                        '--require-html-after', 'YOUR WEEK ON PLEX=84%</span>',
                        '--require-html-after', 'YOUR WEEK ON PLEX=90%</span>',
                        '--forbid-html-after', 'YOUR WEEK ON PLEX=6.1',
                        '--require-html', 'MOVIES WATCHED',
                        '--require-html', 'TV SHOWS WATCHED',
                        '--require-html', 'Recent Movie One poster',
                        '--require-html', 'Recent Show Two poster',
                        '--require-html', 'IMDb',
                        '--require-html', '1h 0m watched',
                        '--require-html', 'Platform: Chrome',
                        '--require-html', 'cid:platform_chrome',
                        '--require-cid-sha256', 'platform_chrome=AB21A3ABF3DDEDE0A74C2BD0605AB19E73FE4AB369EFD02FB936CED58565C71E',
                        '--require-cid-png-dimensions', 'hero_logo=320x96'
                    )
                }
                if ($scenario -eq 'tv-only') {
                    $emailThemeArgs += @(
                        '--require-html', '0 NEW MOVIES',
                        '--require-html', '1 TV TITLE',
                        '--require-preheader', '0 NEW MOVIES • 1 TV TITLE',
                        '--require-html', 'TRENDING THIS WEEK',
                        '--require-html', 'RECENT RELEASES',
                        '--require-html', 'NEW RELEASES',
                        '--require-html-between', 'RECENT RELEASES=NEW RELEASES=Quiet Trending Movie',
                        '--require-html-between', 'RECENT RELEASES=NEW RELEASES=Recent Movie One',
                        '--require-html-between', 'RECENT RELEASES=NEW RELEASES=Recent Movie Three',
                        '--require-html-between', 'RECENT RELEASES=NEW RELEASES=Recent Movie Four',
                        '--forbid-html-between', 'RECENT RELEASES=NEW RELEASES=Selected Movie',
                        '--require-html-between', 'NEW RELEASES=YOUR WEEK ON PLEX=Selected Show',
                        '--forbid-html', 'HOT NEW RELEASE'
                    )
                }
                if ($scenario -eq $quietNoHistoryScenario) {
                    $emailThemeArgs += @(
                        '--require-html', 'TRENDING THIS WEEK',
                        '--require-html', 'RECENT RELEASES',
                        '--require-html', 'Selected Movie',
                        '--require-html', 'Selected Show',
                        '--forbid-html', 'Toy Story 5'
                    )
                }
                if ($scenario -eq $quietNoGlobalHistoryScenario) {
                    $emailThemeArgs += @(
                        '--require-html', '4 RECENT MOVIE RELEASES',
                        '--require-html', 'RECENT RELEASES',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Quiet Trending Movie',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Recent Movie One',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Selected Movie',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Recent Movie Three',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Selected Show',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Recent Show Two',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Recent Show Three',
                        '--require-html-between', 'RECENT RELEASES=YOUR WEEK ON PLEX=Recent Show Four',
                        '--forbid-html', 'TRENDING MOVIE',
                        '--forbid-html', 'TRENDING THIS WEEK',
                        '--forbid-html', 'HOT NEW RELEASE',
                        '--forbid-html', 'Recent Movie Four',
                        '--forbid-html', 'Recent Movie Overflow',
                        '--forbid-html', 'Stale Show Beyond One Month',
                        '--forbid-html', 'YOU CLOCKED',
                        '--forbid-html', 'MOVIES WATCHED',
                        '--forbid-html', 'TV SHOWS WATCHED',
                        '--forbid-html', 'THIS WEEK''S BINGE CHAMPION',
                        '--forbid-html', 'YOU WON • BINGE CHAMPION',
                        '--forbid-html', 'Most watched across'
                    )
                }
                if ($scenario -eq $sparseEpisodeMetadataScenario) {
                    $emailThemeArgs += @(
                        '--require-html', '0 NEW MOVIES',
                        '--require-html', '1 TV TITLE',
                        '--require-html', 'TRENDING THIS WEEK',
                        '--require-html', 'NEW RELEASES',
                        '--require-html-between', 'TRENDING THIS WEEK=NEW RELEASES=Selected-library viewing history.',
                        '--require-html-between', 'TRENDING THIS WEEK=NEW RELEASES=Drama, Mystery',
                        '--require-html-between', 'TRENDING THIS WEEK=NEW RELEASES=81%</span>',
                        '--require-html-between', 'TRENDING THIS WEEK=NEW RELEASES=92%</span>',
                        '--forbid-html-between', 'TRENDING THIS WEEK=NEW RELEASES=76%</span>',
                        '--forbid-html-between', 'TRENDING THIS WEEK=NEW RELEASES=77%</span>',
                        '--require-html-between', 'NEW RELEASES=YOUR WEEK ON PLEX=Selected Show',
                        '--require-html-between', 'NEW RELEASES=YOUR WEEK ON PLEX=Selected Premiere',
                        '--require-html-between', 'NEW RELEASES=YOUR WEEK ON PLEX=8.7',
                        '--forbid-html-between', 'NEW RELEASES=YOUR WEEK ON PLEX=62%',
                        '--require-html-after', 'YOUR WEEK ON PLEX=MOVIES WATCHED',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Drama, Mystery',
                        '--require-html-after', 'YOUR WEEK ON PLEX=81%</span>',
                        '--require-html-after', 'YOUR WEEK ON PLEX=92%</span>',
                        '--forbid-html-after', 'YOUR WEEK ON PLEX=76%</span>',
                        '--forbid-html-after', 'YOUR WEEK ON PLEX=77%</span>',
                        '--require-html-after', 'YOUR WEEK ON PLEX=TV SHOWS WATCHED',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Selected Show',
                        '--require-html-after', 'YOUR WEEK ON PLEX=IMDb',
                        '--require-html-after', 'YOUR WEEK ON PLEX=8.4',
                        '--forbid-html-after', 'YOUR WEEK ON PLEX=8.7',
                        '--forbid-html-after', 'YOUR WEEK ON PLEX=7.3',
                        '--require-html-after', 'YOUR WEEK ON PLEX=1h 30m watched',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Selected Movie poster',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Selected Show poster',
                        '--require-html-after', 'YOUR WEEK ON PLEX=Platform: Chrome',
                        '--require-html', 'cid:hero_logo',
                        '--require-html', 'cid:poster_selected-movie',
                        '--require-html', 'cid:poster_selected-show',
                        '--require-html', 'cid:platform_chrome',
                        '--require-cid-sha256', 'platform_chrome=AB21A3ABF3DDEDE0A74C2BD0605AB19E73FE4AB369EFD02FB936CED58565C71E',
                        '--require-cid-png-dimensions', 'hero_logo=320x96'
                    )
                    Assert-True (-not $sendLog.Contains('TV RT fallback:')) "$($engine.Name)/$scenario SendTest invoked RT fallback despite exact episode IMDb."
                }
                if ($scenario -eq 'rating-export-fallback') {
                    $emailThemeArgs += @(
                        # Windows PowerShell 5.1 strips embedded quote
                        # characters when forwarding native-process
                        # arguments. Use the provider labels themselves so
                        # the decoded-MIME assertions work identically under
                        # Windows PowerShell and PowerShell 7.
                        '--require-html', 'Rotten Tomatoes critic',
                        '--require-html', 'Rotten Tomatoes audience',
                        '--require-html', 'IMDb',
                        '--require-html', '53%</span>',
                        '--require-html', '40%</span>',
                        '--require-html', '8.7</span>',
                        '--forbid-html', '6.6</span>',
                        '--forbid-html', 'TMDB</span>',
                        '--forbid-html', '7.4</span>'
                    )
                }
                elseif ($scenario -in $directImdbRatingScenarios) {
                    $emailThemeArgs += @(
                        '--require-html', 'Rotten Tomatoes critic',
                        '--require-html', 'Rotten Tomatoes audience',
                        '--require-html', 'IMDb',
                        '--require-html', '87%</span>',
                        '--require-html', '83%</span>',
                        '--require-html', '8.6</span>',
                        '--forbid-html', '6.6</span>',
                        '--forbid-html', 'TMDB</span>',
                        '--forbid-html', '7.4</span>'
                    )
                }
                elseif ($scenario -eq $directEpisodeRtScenario) {
                    $emailThemeArgs += @(
                        '--require-html', 'Rotten Tomatoes critic',
                        '--require-html', 'Rotten Tomatoes audience',
                        '--require-html', '87%</span>',
                        '--require-html', '83%</span>',
                        '--require-html', '62%</span>',
                        '--forbid-html', '6.6</span>',
                        '--forbid-html', 'TMDB</span>',
                        '--forbid-html', '7.4</span>'
                    )
                }
                & $PythonPath $emailThemeAssertion @emailThemeArgs
                Assert-True ($LASTEXITCODE -eq 0) "$($engine.Name)/$scenario delivered HTML lost the dark email contract."
                if ($scenario -in @('active', 'quiet', 'tv-only')) {
                    $capturesBeforeSendTestAll = @(Get-ChildItem -LiteralPath $smtpDataDirectory -Filter 'message-*.eml').Count
                    Assert-True ($capturesBeforeSendTestAll -eq 1) "$($engine.Name)/$scenario expected exactly one captured SendTest message before SendTestAll."
                    $oldDataRoot = $env:TAUTWEEKLY_DATA_DIR
                    $oldConfig = $env:TAUTWEEKLY_CONFIG
                    try {
                        if ($engine.Container) {
                            $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                            $env:TAUTWEEKLY_CONFIG = $configPath
                        }
                        $sendTestAllProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                            '-RendererPath', (Join-Path $appRoot $engine.Renderer), '-ConfigPath', $configPath,
                            '-UserId', '1', '-Mode', 'SendTestAll', '-ResultPath', $sendTestAllResultPath
                        ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $sendTestAllStdout -RedirectStandardError $sendTestAllStderr
                    }
                    finally {
                        $env:TAUTWEEKLY_DATA_DIR = $oldDataRoot
                        $env:TAUTWEEKLY_CONFIG = $oldConfig
                    }
                    if ($sendTestAllProcess.ExitCode -ne 0) {
                        throw "$($engine.Name)/$scenario SendTestAll failed ($($sendTestAllProcess.ExitCode))."
                    }
                    $sendTestAllLog = Get-Content -LiteralPath $sendTestAllStdout -Raw -Encoding UTF8
                    Assert-True ($sendTestAllLog.Contains('All six email-state tests were sent to TestEmail only.')) "$($engine.Name)/$scenario SendTestAll did not complete its test-only delivery."
                    Assert-True (Test-Path -LiteralPath $sendTestAllResultPath) "$($engine.Name)/$scenario SendTestAll omitted its structured result."
                    $sendTestAllResultRaw = Get-Content -LiteralPath $sendTestAllResultPath -Raw -Encoding UTF8
                    $sendTestAllResult = $sendTestAllResultRaw | ConvertFrom-Json
                    Assert-True ($sendTestAllResult.mode -eq 'SendTestAll' -and $sendTestAllResult.outcome -eq 'succeeded') "$($engine.Name)/$scenario SendTestAll reported the wrong outcome."
                    Assert-True ($sendTestAllResult.deliveryScope -eq 'test' -and $sendTestAllResult.smtpAcceptedCount -eq 6) "$($engine.Name)/$scenario SendTestAll did not report six test-only SMTP acceptances."
                    Assert-True (-not $sendTestAllResultRaw.Contains('viewer@example.com') -and -not $sendTestAllResultRaw.Contains('virtual-api-key')) "$($engine.Name)/$scenario SendTestAll structured result exposed private fixture data."

                    $allCaptures = @(Get-ChildItem -LiteralPath $smtpDataDirectory -Filter 'message-*.eml' | Sort-Object Name)
                    Assert-True ($allCaptures.Count -eq 7) "$($engine.Name)/$scenario SendTestAll did not add exactly six captured messages after SendTest."
                    $stateCaptures = @($allCaptures | Select-Object -Last 6)
                    $releaseSectionMarker = if ($scenario -eq 'active') { 'NEW RELEASES' } else { 'RECENT RELEASES' }
                    $stateExpectations = @(
                        [PSCustomObject]@{ Required = @('WELCOME ABOARD', $releaseSectionMarker); Forbidden = @('YOU CLOCKED') },
                        [PSCustomObject]@{ Required = @('WELCOME ABOARD', $releaseSectionMarker); Forbidden = @('YOU CLOCKED') },
                        [PSCustomObject]@{ Required = @('WELCOME ABOARD', $releaseSectionMarker, 'YOU CLOCKED'); Forbidden = @() },
                        [PSCustomObject]@{ Required = @($releaseSectionMarker, 'YOU CLOCKED'); Forbidden = @('WELCOME ABOARD') },
                        [PSCustomObject]@{ Required = @('QUIET IN THIS SECTOR', $releaseSectionMarker); Forbidden = @('YOU CLOCKED') },
                        [PSCustomObject]@{ Required = @('STATS ARE WARMING UP', $releaseSectionMarker); Forbidden = @('YOU CLOCKED') }
                    )
                    $sharedLifecycleArgs = if ($scenario -eq 'active') {
                        @(
                            '--require-html', '1 NEW MOVIE',
                            '--require-html', '1 TV TITLE',
                            '--require-preheader', '1 new movie • 1 new TV title!',
                            '--require-html', 'HOT NEW RELEASE',
                            '--require-html', 'NEW RELEASES',
                            '--require-html', 'A release from the selected movie library.',
                            '--require-html', 'Drama, Mystery',
                            '--require-html', 'Rotten Tomatoes critic',
                            '--require-html', 'Rotten Tomatoes audience',
                            '--require-html', '81%</span>',
                            '--require-html', '92%</span>',
                            '--require-html-between', 'HOT NEW RELEASE=NEW RELEASES=4 plays',
                            '--require-html', 'Active Trending Movie',
                            '--require-html', 'cid:poster_active-trending-movie',
                            '--forbid-html', 'Toy Story 5',
                            '--require-html', 'cid:hero_logo',
                            '--require-html', 'cid:recipient_watched',
                            '--require-html', 'cid:recipient_watched_desktop',
                            '--require-html', 'vertical-align:middle;margin-left:8px;',
                            '--require-plain', 'HOT NEW RELEASE: Selected Movie - Watched',
                            '--require-cid-sha256', 'poster_active-trending-movie=31AC758909ADD2BB42FCE41C0973435FA6705D95A0F8981C4F421A1C6E404817',
                            '--require-cid-png-dimensions', 'hero_logo=320x96'
                        )
                    }
                    elseif ($scenario -eq 'quiet') {
                        @(
                        '--require-html', '1 TRENDING MOVIE',
                        '--require-html', '4 RECENT MOVIE RELEASES',
                        '--require-preheader', '1 TRENDING MOVIE • 4 RECENT MOVIE RELEASES',
                        '--require-html', 'TRENDING THIS WEEK',
                        '--require-html', 'RECENT RELEASES',
                        '--require-html', 'A complete quiet-week hero with real metadata.',
                        '--require-html', 'Adventure, Comedy',
                        '--require-html', 'Rotten Tomatoes critic',
                        '--require-html', 'Rotten Tomatoes audience',
                        '--require-html', '88%</span>',
                        '--require-html', '94%</span>',
                        '--require-html', 'Most watched across Virtual Plex this week',
                        '--require-html', '4 plays',
                        '--require-html', 'cid:hero_logo',
                        '--require-html', 'cid:recipient_watched',
                        '--require-html', 'cid:recipient_watched_desktop',
                        '--require-html', 'vertical-align:middle;margin-left:8px;',
                        '--require-plain', 'TRENDING THIS WEEK: Quiet Trending Movie - Watched',
                        '--require-html', 'Recent Movie One',
                        '--require-html', 'Selected Movie',
                        '--require-html', 'Recent Movie Three',
                        '--require-html', 'Recent Movie Four',
                        '--require-html', 'Selected Show',
                        '--require-html', 'Recent Show Two',
                        '--require-html', 'Recent Show Three',
                        '--require-html', 'Recent Show Four',
                        '--forbid-html', 'Recent Movie Overflow',
                        '--forbid-html', 'Stale Show Beyond One Month',
                        '--forbid-html', 'Sample Movie',
                        '--forbid-html', 'Sample Series',
                        '--forbid-html', 'Toy Story 5',
                        '--forbid-html', 'HOT NEW RELEASE',
                        '--require-cid-png-dimensions', 'hero_logo=320x96'
                        )
                    }
                    else {
                        @(
                            '--require-html', '0 NEW MOVIES',
                            '--require-html', '1 TV TITLE',
                            '--require-preheader', '0 NEW MOVIES • 1 TV TITLE',
                            '--require-html', 'TRENDING THIS WEEK',
                            '--require-html', 'RECENT RELEASES',
                            '--require-html', 'NEW RELEASES',
                            '--require-html', 'Quiet Trending Movie',
                            '--require-html', 'Recent Movie One',
                            '--require-html', 'Recent Movie Three',
                            '--require-html', 'Recent Movie Four',
                            '--require-html', 'Selected Show',
                            '--forbid-html', 'HOT NEW RELEASE'
                        )
                    }
                    for ($stateIndex = 0; $stateIndex -lt 6; $stateIndex++) {
                        $stateArgs = @($stateCaptures[$stateIndex].FullName, '--forbid-html', 'Sample Movie', '--forbid-html', 'Sample Series')
                        $stateArgs += @(
                            '--forbid-plain', 'Selected Show - Watched'
                        )
                        foreach ($requiredMarker in $stateExpectations[$stateIndex].Required) {
                            $stateArgs += @('--require-html', $requiredMarker)
                        }
                        foreach ($forbiddenMarker in $stateExpectations[$stateIndex].Forbidden) {
                            $stateArgs += @('--forbid-html', $forbiddenMarker)
                        }
                        $stateArgs += $sharedLifecycleArgs
                        $releaseEndMarker = if ($stateIndex -in @(0, 1)) { 'FRIDAY DROPS' } else { 'YOUR WEEK ON PLEX' }
                        if ($scenario -eq 'active') {
                            $stateArgs += @(
                                '--require-html-between', "NEW RELEASES=$releaseEndMarker=Selected Show",
                                '--forbid-html-between', "NEW RELEASES=$releaseEndMarker=Selected Movie"
                            )
                        }
                        elseif ($scenario -eq 'quiet') {
                            $stateArgs += @(
                                '--forbid-html-between', "RECENT RELEASES=$releaseEndMarker=Quiet Trending Movie",
                                '--forbid-html-between', "RECENT RELEASES=$releaseEndMarker=TRENDING THIS WEEK",
                                '--require-html-between', "RECENT RELEASES=$releaseEndMarker=Recent Movie One",
                                '--require-html-between', "RECENT RELEASES=$releaseEndMarker=Selected Movie",
                                '--require-html-between', "RECENT RELEASES=$releaseEndMarker=Recent Movie Three",
                                '--require-html-between', "RECENT RELEASES=$releaseEndMarker=Recent Movie Four",
                                '--require-html-between', "RECENT RELEASES=$releaseEndMarker=Selected Show",
                                '--require-html-between', "RECENT RELEASES=$releaseEndMarker=Recent Show Two",
                                '--require-html-between', "RECENT RELEASES=$releaseEndMarker=Recent Show Three",
                                '--require-html-between', "RECENT RELEASES=$releaseEndMarker=Recent Show Four"
                            )
                        }
                        else {
                            $stateArgs += @(
                                '--require-html-between', 'RECENT RELEASES=NEW RELEASES=Quiet Trending Movie',
                                '--require-html-between', 'RECENT RELEASES=NEW RELEASES=Recent Movie One',
                                '--require-html-between', 'RECENT RELEASES=NEW RELEASES=Recent Movie Three',
                                '--require-html-between', 'RECENT RELEASES=NEW RELEASES=Recent Movie Four',
                                '--forbid-html-between', 'RECENT RELEASES=NEW RELEASES=Selected Movie',
                                '--require-html-between', "NEW RELEASES=$releaseEndMarker=Selected Show"
                            )
                        }
                        if ($stateIndex -in @(2, 3)) {
                            $stateArgs += @(
                                '--require-html', 'MOVIES WATCHED',
                                '--require-html', 'Platform: Chrome',
                                '--require-html', 'cid:platform_chrome',
                                '--require-html-after', 'YOUR WEEK ON PLEX=Drama, Mystery',
                                '--require-html-after', 'YOUR WEEK ON PLEX=Rotten Tomatoes critic',
                                '--require-html-after', 'YOUR WEEK ON PLEX=Rotten Tomatoes audience',
                                '--require-cid-sha256', 'platform_chrome=AB21A3ABF3DDEDE0A74C2BD0605AB19E73FE4AB369EFD02FB936CED58565C71E'
                            )
                            if ($scenario -eq 'quiet') {
                                $stateArgs += @(
                                    '--require-html', 'TV SHOWS WATCHED',
                                    '--require-html-after', 'YOUR WEEK ON PLEX=Recent Movie One poster',
                                    '--require-html-after', 'YOUR WEEK ON PLEX=Recent Show Two poster',
                                    '--require-html-after', 'YOUR WEEK ON PLEX=IMDb',
                                    '--require-html-after', 'YOUR WEEK ON PLEX=8.5',
                                    '--require-html-after', 'YOUR WEEK ON PLEX=84%</span>',
                                    '--require-html-after', 'YOUR WEEK ON PLEX=90%</span>',
                                    '--require-html-after', 'YOUR WEEK ON PLEX=1h 0m watched',
                                    '--forbid-html-after', 'YOUR WEEK ON PLEX=6.1'
                                )
                            }
                            else {
                                $stateArgs += @(
                                    '--require-html-after', 'YOUR WEEK ON PLEX=Selected Movie poster',
                                    '--require-html-after', 'YOUR WEEK ON PLEX=81%</span>',
                                    '--require-html-after', 'YOUR WEEK ON PLEX=92%</span>',
                                    '--forbid-html-after', 'YOUR WEEK ON PLEX=TV SHOWS WATCHED'
                                )
                            }
                        }
                        & $PythonPath $emailThemeAssertion @stateArgs
                        Assert-True ($LASTEXITCODE -eq 0) "$($engine.Name)/$scenario SendTestAll message $($stateIndex + 1) did not match its PreviewAll lifecycle counterpart."
                    }
                }


                if ($scenario -in @('active', 'quiet')) {
                    $welcomeCapturesBefore = @(Get-ChildItem -LiteralPath $smtpDataDirectory -Filter 'message-*.eml').Count
                    $welcomeAcceptancesBefore = @(
                        Get-Content -LiteralPath $smtpCallLog |
                            ForEach-Object { ($_ | ConvertFrom-Json).command } |
                            Where-Object { $_ -eq 'DATA' }
                    ).Count
                    Assert-True ($welcomeCapturesBefore -eq 7 -and $welcomeAcceptancesBefore -eq 7) "$($engine.Name)/$scenario had an unexpected SMTP baseline before SendWelcome."
                    $welcomeTrendingMetadataBefore = if ($scenario -eq 'active') { Get-TautulliMetadataCallCount -CallLogPath $callLog -RatingKey 'active-trending-movie' } else { 0 }

                    $oldWelcomeDataRoot = $env:TAUTWEEKLY_DATA_DIR
                    $oldWelcomeConfig = $env:TAUTWEEKLY_CONFIG
                    try {
                        if ($engine.Container) {
                            $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                            $env:TAUTWEEKLY_CONFIG = $configPath
                        }
                        $sendWelcomeProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                            '-File', (Join-Path $appRoot $engine.Renderer),
                            '-ConfigPath', $configPath, '-UserId', '1', '-Mode', 'SendWelcome',
                            '-ConfirmWelcome', '-ResultPath', $sendWelcomeResultPath
                        ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $sendWelcomeStdout -RedirectStandardError $sendWelcomeStderr
                    }
                    finally {
                        $env:TAUTWEEKLY_DATA_DIR = $oldWelcomeDataRoot
                        $env:TAUTWEEKLY_CONFIG = $oldWelcomeConfig
                    }
                    if ($sendWelcomeProcess.ExitCode -ne 0) {
                        throw "$($engine.Name)/$scenario SendWelcome failed ($($sendWelcomeProcess.ExitCode)).`nSTDOUT:`n$(Get-Content $sendWelcomeStdout -Raw)`nSTDERR:`n$(Get-Content $sendWelcomeStderr -Raw)"
                    }
                    $sendWelcomeLog = Get-Content -LiteralPath $sendWelcomeStdout -Raw -Encoding UTF8
                    Assert-True ($sendWelcomeLog.Contains('Welcome email sent successfully')) "$($engine.Name)/$scenario SendWelcome did not report successful delivery."
                    Assert-True (Test-Path -LiteralPath $sendWelcomeResultPath) "$($engine.Name)/$scenario SendWelcome omitted its structured result."
                    $sendWelcomeResultRaw = Get-Content -LiteralPath $sendWelcomeResultPath -Raw -Encoding UTF8
                    $sendWelcomeResult = $sendWelcomeResultRaw | ConvertFrom-Json
                    Assert-True ($sendWelcomeResult.mode -eq 'SendWelcome' -and $sendWelcomeResult.outcome -eq 'succeeded') "$($engine.Name)/$scenario SendWelcome reported the wrong outcome."
                    Assert-True ($sendWelcomeResult.deliveryScope -eq 'welcome' -and $sendWelcomeResult.smtpAcceptedCount -eq 1) "$($engine.Name)/$scenario SendWelcome did not report exactly one welcome acceptance."
                    Assert-True (-not $sendWelcomeResultRaw.Contains('viewer@example.com') -and -not $sendWelcomeResultRaw.Contains('virtual-api-key')) "$($engine.Name)/$scenario SendWelcome structured result exposed private fixture data."

                    $welcomeCapturesAfter = @(Get-ChildItem -LiteralPath $smtpDataDirectory -Filter 'message-*.eml' | Sort-Object Name)
                    $welcomeAcceptancesAfter = @(
                        Get-Content -LiteralPath $smtpCallLog |
                            ForEach-Object { ($_ | ConvertFrom-Json).command } |
                            Where-Object { $_ -eq 'DATA' }
                    ).Count
                    Assert-True ($welcomeCapturesAfter.Count -eq ($welcomeCapturesBefore + 1)) "$($engine.Name)/$scenario SendWelcome did not add exactly one captured message."
                    Assert-True ($welcomeAcceptancesAfter -eq ($welcomeAcceptancesBefore + 1)) "$($engine.Name)/$scenario SendWelcome did not produce exactly one SMTP DATA acceptance."
                    $welcomeCapture = $welcomeCapturesAfter[-1]
                    if ($scenario -eq 'active') {
                        $welcomeTrendingMetadataDelta = (Get-TautulliMetadataCallCount -CallLogPath $callLog -RatingKey 'active-trending-movie') - $welcomeTrendingMetadataBefore
                        Assert-True ($welcomeTrendingMetadataDelta -eq 1 -and $welcomeTrendingMetadataDelta -eq $sendTestTrendingMetadataDelta) "$($engine.Name)/$scenario SendWelcome did not match SendTest's single shared compact-Trending metadata lookup."
                    }
                    $welcomeArgs = @(
                        $welcomeCapture.FullName,
                        '--require-html', 'WELCOME ABOARD',
                        '--forbid-html', 'YOU CLOCKED',
                        '--forbid-html', 'MOVIES WATCHED',
                        '--forbid-html', 'TV SHOWS WATCHED',
                        '--forbid-html', 'Sample Movie',
                        '--forbid-html', 'Sample Series',
                        '--forbid-html', 'Toy Story 5'
                    )
                    $welcomeArgs += @(
                        '--forbid-plain', 'Selected Show - Watched'
                    )
                    if ($scenario -eq 'active') {
                        $welcomeArgs += @(
                            '--require-html', '1 NEW MOVIE',
                            '--require-html', '1 TV TITLE',
                            '--require-preheader', '1 new movie • 1 new TV title!',
                            '--require-html', 'HOT NEW RELEASE',
                            '--require-html', 'NEW RELEASES',
                            '--require-html', 'A release from the selected movie library.',
                            '--require-html', 'Drama, Mystery',
                            '--require-html', 'Rotten Tomatoes critic',
                            '--require-html', 'Rotten Tomatoes audience',
                            '--require-html', '81%</span>',
                            '--require-html', '92%</span>',
                            '--require-html-between', 'HOT NEW RELEASE=NEW RELEASES=4 plays',
                            '--require-html-between', 'NEW RELEASES=FRIDAY DROPS=Selected Show',
                            '--forbid-html-between', 'NEW RELEASES=FRIDAY DROPS=Selected Movie',
                            '--require-html', 'Active Trending Movie',
                            '--require-html', 'cid:poster_active-trending-movie',
                            '--require-html', 'cid:poster_selected-movie',
                            '--require-html', 'cid:hero_logo',
                            '--require-html', 'cid:recipient_watched',
                            '--require-html', 'cid:recipient_watched_desktop',
                            '--require-html', 'vertical-align:middle;margin-left:8px;',
                            '--require-plain', 'HOT NEW RELEASE: Selected Movie - Watched',
                            '--require-cid-sha256', 'poster_active-trending-movie=31AC758909ADD2BB42FCE41C0973435FA6705D95A0F8981C4F421A1C6E404817',
                            '--require-cid-sha256', 'poster_selected-movie=31AC758909ADD2BB42FCE41C0973435FA6705D95A0F8981C4F421A1C6E404817',
                            '--require-cid-png-dimensions', 'hero_logo=320x96'
                        )
                    }
                    else {
                        $welcomeArgs += @(
                            '--require-html', '1 TRENDING MOVIE',
                            '--require-html', '4 RECENT MOVIE RELEASES',
                            '--require-html', 'TRENDING THIS WEEK',
                            '--require-html', 'RECENT RELEASES',
                            '--require-html', 'A complete quiet-week hero with real metadata.',
                            '--require-html', 'Adventure, Comedy',
                            '--require-html', 'Rotten Tomatoes critic',
                            '--require-html', 'Rotten Tomatoes audience',
                            '--require-html', '88%</span>',
                            '--require-html', '94%</span>',
                            '--require-html', 'Most watched across Virtual Plex this week',
                            '--require-html', '4 plays',
                            '--require-html-between', 'RECENT RELEASES=FRIDAY DROPS=Recent Movie One',
                            '--require-html-between', 'RECENT RELEASES=FRIDAY DROPS=Selected Movie',
                            '--require-html-between', 'RECENT RELEASES=FRIDAY DROPS=Recent Movie Three',
                            '--require-html-between', 'RECENT RELEASES=FRIDAY DROPS=Recent Movie Four',
                            '--require-html-between', 'RECENT RELEASES=FRIDAY DROPS=Selected Show',
                            '--require-html-between', 'RECENT RELEASES=FRIDAY DROPS=Recent Show Two',
                            '--require-html-between', 'RECENT RELEASES=FRIDAY DROPS=Recent Show Three',
                            '--require-html-between', 'RECENT RELEASES=FRIDAY DROPS=Recent Show Four',
                            '--forbid-html-between', 'RECENT RELEASES=FRIDAY DROPS=Quiet Trending Movie',
                            '--forbid-html-between', 'RECENT RELEASES=FRIDAY DROPS=TRENDING THIS WEEK',
                            '--forbid-html', 'Recent Movie Overflow',
                            '--forbid-html', 'Stale Show Beyond One Month',
                            '--forbid-html', 'HOT NEW RELEASE',
                            '--require-html', 'cid:poster_quiet-trending-movie',
                            '--require-html', 'cid:poster_quiet-recent-movie-01',
                            '--require-html', 'cid:hero_logo',
                            '--require-html', 'cid:recipient_watched',
                            '--require-html', 'cid:recipient_watched_desktop',
                            '--require-html', 'vertical-align:middle;margin-left:8px;',
                            '--require-plain', 'TRENDING THIS WEEK: Quiet Trending Movie - Watched',
                            '--require-cid-sha256', 'poster_quiet-trending-movie=31AC758909ADD2BB42FCE41C0973435FA6705D95A0F8981C4F421A1C6E404817',
                            '--require-cid-sha256', 'poster_quiet-recent-movie-01=31AC758909ADD2BB42FCE41C0973435FA6705D95A0F8981C4F421A1C6E404817',
                            '--require-cid-png-dimensions', 'hero_logo=320x96'
                        )
                    }
                    & $PythonPath $emailThemeAssertion @welcomeArgs
                    Assert-True ($LASTEXITCODE -eq 0) "$($engine.Name)/$scenario SendWelcome MIME diverged from the shared Preview/SendTest release contract."
                }

                if ($scenario -eq $cacheScenario) {
                    Remove-Item -LiteralPath (Join-Path $outputRoot 'posters') -Recurse -Force -ErrorAction SilentlyContinue
                    New-Item -ItemType Directory -Force -Path (Join-Path $outputRoot 'posters') | Out-Null
                    $oldDataRoot = $env:TAUTWEEKLY_DATA_DIR
                    $oldConfig = $env:TAUTWEEKLY_CONFIG
                    $oldMetadataProvider = $env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL
                    $oldPlexWatch = $env:TAUTWEEKLY_TEST_PLEX_WATCH_URL
                    try {
                        if ($engine.Container) {
                            $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                            $env:TAUTWEEKLY_CONFIG = $configPath
                        }
                        $env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL = $baseUrl + '/hosted'
                        $env:TAUTWEEKLY_TEST_PLEX_WATCH_URL = $baseUrl + '/watch'
                        $sendAllProcess = Start-Process -FilePath $engine.Host -ArgumentList @(
                            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                            '-RendererPath', (Join-Path $appRoot $engine.Renderer), '-ConfigPath', $configPath,
                            '-UserId', '1', '-Mode', 'SendAll'
                        ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $sendAllStdout -RedirectStandardError $sendAllStderr
                    }
                    finally {
                        $env:TAUTWEEKLY_DATA_DIR = $oldDataRoot
                        $env:TAUTWEEKLY_CONFIG = $oldConfig
                        $env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL = $oldMetadataProvider
                        $env:TAUTWEEKLY_TEST_PLEX_WATCH_URL = $oldPlexWatch
                    }
                    if ($sendAllProcess.ExitCode -ne 0) {
                        throw "$($engine.Name)/$scenario SendAll failed ($($sendAllProcess.ExitCode)).`nSTDOUT:`n$(Get-Content $sendAllStdout -Raw)`nSTDERR:`n$(Get-Content $sendAllStderr -Raw)"
                    }
                    $sendAllLog = Get-Content $sendAllStdout -Raw
                    Assert-True ($sendAllLog.Contains('Deleted-item cache hit for an exact movie GUID')) "$($engine.Name)/$scenario SendAll did not reuse cached movie metadata."
                    Assert-True ($sendAllLog.Contains('Restored deleted movie history artwork from the bounded pre-deletion cache.')) "$($engine.Name)/$scenario SendAll did not reuse cached movie artwork."
                    Assert-True ($sendAllLog.Contains('Sent:    2') -and $sendAllLog.Contains('Failed:  0')) "$($engine.Name)/$scenario SendAll did not complete both normal deliveries."
                    $smtpCommands = @(Get-Content $smtpCallLog | ForEach-Object { ($_ | ConvertFrom-Json).command })
                    Assert-True (@($smtpCommands | Where-Object { $_ -eq 'DATA' }).Count -ge 3) "$($engine.Name)/$scenario did not submit SendTest plus both SendAll messages."
                    & $PythonPath $emailThemeAssertion $smtpDataFile --require-html 'Platform: Roku' --require-html 'cid:platform_roku' --require-html 'max-height:21px' --require-cid-sha256 'platform_roku=7E9EA9D59B16F92A5C80C72E1F8E92FB794FE57C4E97EC3A5B55E8943D0ED136' --forbid-html 'cid:recipient_watched' --forbid-plain ' - Watched'
                    # The last production recipient has no qualifying movie history
                    # in this fixture; the preceding recipient's state must not leak.
                    if ($LASTEXITCODE -ne 0) { throw "$($engine.Name)/$scenario production SendAll MIME platform assertion failed." }
                    Assert-True (-not $sendAllLog.Contains('Chrome') -and -not $sendAllLog.Contains('Roku')) "$($engine.Name)/$scenario exposed platform details in SendAll logs."
                }
            }

            $executed++
            $casePassed = $true
            Write-Host "[PASS] Full renderer: $($engine.Name) / $scenario"
        }
        finally {
            if ($null -ne $server -and -not $server.HasExited) {
                Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
                $server.WaitForExit()
            }
            if ($null -ne $smtpServer -and -not $smtpServer.HasExited) {
                Stop-Process -Id $smtpServer.Id -Force -ErrorAction SilentlyContinue
                $smtpServer.WaitForExit()
            }
            if (-not $KeepArtifacts -and ($casePassed -or -not $KeepFailedArtifacts)) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-Warning "Retained synthetic integration artifacts ($($engine.Name)/$scenario): $tempRoot"
            }
        }
    }
}

Assert-True ($executed -gt 0) 'No renderer integration scenario executed.'
Write-Host "Newsletter integration tests passed: $executed scenario(s)." -ForegroundColor Green
