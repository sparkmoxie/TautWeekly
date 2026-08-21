[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$PythonPath = 'python',
    [switch]$KeepFailedArtifacts
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
$directImdbRatingScenarios = @($directOptionalRatingScenario, $directXmlRatingScenario)
$directRatingScenarios = @($directImdbRatingScenarios) + @($directEpisodeRtScenario)
$deletedHistoryScenarios = @($providerRecoveryScenarios) + @($cacheScenario)
$sendTestScenarios = @('optional-hero-metadata', 'rating-export-fallback') + @($directRatingScenarios) + @($deletedHistoryScenarios)

$executed = 0
foreach ($engine in $engines) {
    if ([string]::IsNullOrWhiteSpace([string]$engine.Host)) {
        Write-Warning "Skipping $($engine.Name) locally because PowerShell 7 is unavailable; hosted CI runs it."
        continue
    }

    foreach ($scenario in @('active', 'quiet', 'tv-only', 'optional-hero-metadata', 'rating-export-fallback') + $directRatingScenarios + $deletedHistoryScenarios) {
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
        $smtpStdout = Join-Path $tempRoot 'smtp.stdout.txt'
        $smtpStderr = Join-Path $tempRoot 'smtp.stderr.txt'
        $sendStdout = Join-Path $tempRoot 'send.stdout.txt'
        $sendStderr = Join-Path $tempRoot 'send.stderr.txt'
        $sendAllStdout = Join-Path $tempRoot 'send-all.stdout.txt'
        $sendAllStderr = Join-Path $tempRoot 'send-all.stderr.txt'
        $managerResultPath = Join-Path $tempRoot 'manager-operation-result.json'
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
                    '--data-file', $smtpDataFile
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
                CustomTextCardTitleGif = 'celebrate'
                CustomTextCardSubheading = 'Assessment & notes'
                CustomTextCardBody = "Synthetic <notice> & safe`nSecond line"
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
                if ($engine.Name -eq 'nas-docker-linux-freebsd' -and $scenario -eq 'active') {
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

            $indexPath = Join-Path $outputRoot 'preview-all-00-INDEX.html'
            $normalPath = Join-Path $outputRoot 'preview-all-04-normal-newsletter.html'
            Assert-True (Test-Path $indexPath) "$($engine.Name)/$scenario did not generate the preview index."
            Assert-True ((Get-ChildItem $outputRoot -Filter 'preview-all-*.html').Count -eq 7) "$($engine.Name)/$scenario did not generate all six states plus the index."
            if ($engine.Name -eq 'nas-docker-linux-freebsd' -and $scenario -eq 'active') {
                Assert-True (Test-Path -LiteralPath $managerResultPath) 'NAS Manager operation did not produce its structured result.'
                $managerResultRaw = Get-Content -LiteralPath $managerResultPath -Raw -Encoding UTF8
                $managerResult = $managerResultRaw | ConvertFrom-Json
                Assert-True ($managerResult.schemaVersion -eq 2) 'NAS Manager result used the wrong schema version.'
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
            $normalHtml = Get-Content $normalPath -Raw -Encoding UTF8
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
                $releaseMetaIndex = if ($previewHtml.Contains('NO NEW RELEASES THIS WEEK')) {
                    $previewHtml.IndexOf('NO NEW RELEASES THIS WEEK', [StringComparison]::Ordinal)
                }
                else {
                    $previewHtml.IndexOf('NEW MOVIE', [StringComparison]::Ordinal)
                }
                Assert-True ($customCardIndex -ge 0 -and $releaseMetaIndex -gt $customCardIndex) "$($engine.Name)/$scenario $($previewPath.Name) did not place the custom text card before release metadata."
                Assert-True (-not $previewHtml.Contains('background:#0f0f0f')) "$($engine.Name)/$scenario $($previewPath.Name) retained the outer background shorthand."
                Assert-True (-not $previewHtml.Contains('background:#181818')) "$($engine.Name)/$scenario $($previewPath.Name) retained the card background shorthand."
                Assert-True (-not $previewHtml.Contains('color-scheme:dark only')) "$($engine.Name)/$scenario $($previewPath.Name) retained the incompatible dark-only declaration."
            }
            Assert-True ($normalHtml.Contains('class="email-card"')) "$($engine.Name)/$scenario lost explicit dark card classes."
            Assert-True ($normalHtml.Contains('bgcolor="#181818"')) "$($engine.Name)/$scenario lost the legacy dark card fallback."
            Assert-True ($normalHtml.Contains('background-color:#181818')) "$($engine.Name)/$scenario lost the longhand dark card fallback."
            Assert-True (-not $normalHtml.Contains('Ratings unavailable') -and -not $normalHtml.Contains('IMDb unavailable')) "$($engine.Name)/$scenario rendered an unavailable-rating placeholder."
            $expectedMode = if ($scenario -eq 'quiet' -or $scenario -in $deletedHistoryScenarios) { 'QUIET / LATEST RELEASES' } else { 'NORMAL / NEW RELEASES' }
            Assert-True ($indexHtml.Contains($expectedMode)) "$($engine.Name)/$scenario reported the wrong release mode."
            Assert-True ($normalHtml.Contains('Selected Movie')) "$($engine.Name)/$scenario lost the selected movie."
            Assert-True ($normalHtml.Contains('Selected Show')) "$($engine.Name)/$scenario lost the selected TV show."
            Assert-True (-not $normalHtml.Contains('Private Movie')) "$($engine.Name)/$scenario leaked a private-library title."
            Assert-True (-not $normalHtml.Contains('Simulated Champion')) "$($engine.Name)/$scenario leaked the Binge Champion identity."
            Assert-True ($normalHtml.Contains('3h 0m watched')) "$($engine.Name)/$scenario lost the shared champion duration line."
            Assert-True ($normalHtml.Contains('1 TV show')) "$($engine.Name)/$scenario lost the unique TV-show breakdown."
            Assert-True (-not $normalHtml.Contains('0 movies')) "$($engine.Name)/$scenario rendered an empty Binge Champion movie category."
            Assert-True (-not $normalHtml.Contains('qualifying plays')) "$($engine.Name)/$scenario retained qualifying-play copy in Total Watched."
            if ($scenario -notin $deletedHistoryScenarios) {
                Assert-True (-not $normalHtml.Contains('TV SHOWS WATCHED')) "$($engine.Name)/$scenario rendered an empty TV stats card."
            }

            if ($scenario -eq 'tv-only') {
                Assert-True ($normalHtml.Contains('0 NEW MOVIES') -and $normalHtml.Contains('1 TV TITLE')) "$($engine.Name)/$scenario reported the wrong release-title counts."
                Assert-True ($normalHtml.Contains('TRENDING THIS WEEK')) "$($engine.Name)/$scenario did not promote Trending into the hero."
                Assert-True (-not $normalHtml.Contains('HOT NEW RELEASE')) "$($engine.Name)/$scenario promoted a TV release as HOT NEW RELEASE."
                Assert-True (([regex]::Matches($normalHtml, 'Selected Show')).Count -ge 2) "$($engine.Name)/$scenario removed the TV release after using Trending as the hero."
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
                Assert-True ($normalHtml.Contains('Hosted history show summary.')) "$($engine.Name)/$scenario did not restore the deleted TV summary."
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
            Assert-True (@($mediaCalls | Where-Object {
                $null -eq $_.query.PSObject.Properties['section_id'] -or
                [string]$_.query.section_id -notin @('10', '20')
            }).Count -eq 0) "$($engine.Name)/$scenario issued an unscoped/private media query."

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
                if ($scenario -notin $directRatingScenarios) {
                    Assert-True ($previewLog -match 'direct Plex .*404.*Not Found') "$($engine.Name)/$scenario did not exercise the recoverable direct Plex 404 fallback."
                }
                Assert-True ($normalHtml.Contains('Selected Show')) "$($engine.Name)/$scenario lost the global-history title fallback for sparse hero metadata."

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
                Assert-True ($sendLog.Contains('Test email sent successfully.')) "$($engine.Name)/$scenario SendTest did not complete delivery."
                if ($scenario -notin $directRatingScenarios) {
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
                    '--require-cid-sha256', 'custom_title_celebrate=86879C45175F3901A8676D9B0BB5132C7A98B20A9F40487C21E4C896CE196616'
                )
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
            if ($casePassed -or -not $KeepFailedArtifacts) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-Warning "Retained failed integration artifacts: $tempRoot"
            }
        }
    }
}

Assert-True ($executed -gt 0) 'No renderer integration scenario executed.'
Write-Host "Newsletter integration tests passed: $executed scenario(s)." -ForegroundColor Green
