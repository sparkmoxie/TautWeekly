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
$deletedHistoryScenarios = @('deleted-history-metadata', 'deleted-history-legacy-guid')

$executed = 0
foreach ($engine in $engines) {
    if ([string]::IsNullOrWhiteSpace([string]$engine.Host)) {
        Write-Warning "Skipping $($engine.Name) locally because PowerShell 7 is unavailable; hosted CI runs it."
        continue
    }

    foreach ($scenario in @('active', 'quiet', 'tv-only', 'optional-hero-metadata') + $deletedHistoryScenarios) {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-integration-' + [Guid]::NewGuid().ToString('N'))
        $appRoot = Join-Path $tempRoot 'app'
        $dataRoot = Join-Path $tempRoot 'data'
        $callLog = Join-Path $tempRoot 'calls.jsonl'
        $readyFile = Join-Path $tempRoot 'ready.txt'
        $stdout = Join-Path $tempRoot 'renderer.stdout.txt'
        $stderr = Join-Path $tempRoot 'renderer.stderr.txt'
        $serverStdout = Join-Path $tempRoot 'server.stdout.txt'
        $serverStderr = Join-Path $tempRoot 'server.stderr.txt'
        $smtpCallLog = Join-Path $tempRoot 'smtp-calls.jsonl'
        $smtpReadyFile = Join-Path $tempRoot 'smtp-ready.txt'
        $smtpStdout = Join-Path $tempRoot 'smtp.stdout.txt'
        $smtpStderr = Join-Path $tempRoot 'smtp.stderr.txt'
        $sendStdout = Join-Path $tempRoot 'send.stdout.txt'
        $sendStderr = Join-Path $tempRoot 'send.stderr.txt'
        $server = $null
        $smtpServer = $null
        $casePassed = $false

        New-Item -ItemType Directory -Force -Path $appRoot, $dataRoot | Out-Null
        $sourceContents = Join-Path (Join-Path $Root ([string]$engine.Source)) '*'
        Copy-Item -Path $sourceContents -Destination $appRoot -Recurse -Force

        try {
            $port = Get-FreeTcpPort
            $server = Start-Process -FilePath $PythonPath -ArgumentList @(
                '-u', $fakeServer, '--port', [string]$port, '--scenario', $scenario,
                '--call-log', $callLog, '--ready-file', $readyFile
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
            if ($scenario -eq 'optional-hero-metadata' -or $scenario -in $deletedHistoryScenarios) {
                $smtpPort = Get-FreeTcpPort
                $smtpServer = Start-Process -FilePath $PythonPath -ArgumentList @(
                    '-u', $fakeSmtp, '--port', [string]$smtpPort,
                    '--call-log', $smtpCallLog, '--ready-file', $smtpReadyFile
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
                IncludedLibraryIds = @('10', '20')
                ExcludedUserIds = @()
                ExcludedEmails = @()
                DaysBack = 7
                MaxMovies = 4
                MaxTv = 4
            }
            if ($scenario -eq 'optional-hero-metadata' -or $scenario -in $deletedHistoryScenarios) {
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
                $process = Start-Process -FilePath $engine.Host -ArgumentList @(
                    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $headlessRunner,
                    '-RendererPath', (Join-Path $appRoot $engine.Renderer), '-ConfigPath', $configPath,
                    '-UserId', '1', '-Mode', 'PreviewAll'
                ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
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
            $indexHtml = Get-Content $indexPath -Raw -Encoding UTF8
            $normalHtml = Get-Content $normalPath -Raw -Encoding UTF8
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

            if ($scenario -in $deletedHistoryScenarios) {
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
            }

            $calls = @(Get-Content $callLog | ForEach-Object { $_ | ConvertFrom-Json })
            $mediaCalls = @($calls | Where-Object {
                $null -ne $_.query.PSObject.Properties['cmd'] -and
                [string]$_.query.cmd -in @('get_history', 'get_recently_added')
            })
            Assert-True ($mediaCalls.Count -gt 0) "$($engine.Name)/$scenario made no media calls."
            Assert-True (@($mediaCalls | Where-Object {
                $null -eq $_.query.PSObject.Properties['section_id'] -or
                [string]$_.query.section_id -notin @('10', '20')
            }).Count -eq 0) "$($engine.Name)/$scenario issued an unscoped/private media query."

            if ($scenario -in $deletedHistoryScenarios) {
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

            if ($scenario -eq 'optional-hero-metadata' -or $scenario -in $deletedHistoryScenarios) {
                $previewLog = Get-Content $stdout -Raw
                Assert-True ($previewLog -match 'direct Plex .*404.*Not Found') "$($engine.Name)/$scenario did not exercise the recoverable direct Plex 404 fallback."
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
                Assert-True ($sendLog -match 'direct Plex .*404.*Not Found') "$($engine.Name)/$scenario SendTest did not preserve the direct Plex 404 warning."
                if ($scenario -in $deletedHistoryScenarios) {
                    Assert-True ($sendLog.Contains('recovered an exact movie match through the provider POST contract')) "$($engine.Name)/$scenario SendTest did not report the provider-contract recovery."
                    Assert-True ($sendLog.Contains('recovered an exact show match through the provider POST contract')) "$($engine.Name)/$scenario SendTest did not report the TV provider-contract recovery."
                    Assert-True ($sendLog.Contains('Recovered deleted Plex movie history artwork')) "$($engine.Name)/$scenario SendTest did not recover deleted movie artwork."
                    Assert-True ($sendLog.Contains('Recovered deleted Plex show history artwork')) "$($engine.Name)/$scenario SendTest did not recover deleted TV artwork."
                }
                $smtpCommands = @(Get-Content $smtpCallLog | ForEach-Object { ($_ | ConvertFrom-Json).command })
                Assert-True ('DATA' -in $smtpCommands) "$($engine.Name)/$scenario SendTest did not submit an SMTP message."
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
