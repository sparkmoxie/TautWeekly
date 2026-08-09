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

$executed = 0
foreach ($engine in $engines) {
    if ([string]::IsNullOrWhiteSpace([string]$engine.Host)) {
        Write-Warning "Skipping $($engine.Name) locally because PowerShell 7 is unavailable; hosted CI runs it."
        continue
    }

    foreach ($scenario in @('active', 'quiet', 'tv-only', 'optional-hero-metadata')) {
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
            if ($scenario -eq 'optional-hero-metadata') {
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
            if ($scenario -eq 'optional-hero-metadata') {
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
            try {
                if ($engine.Container) {
                    $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                    $env:TAUTWEEKLY_CONFIG = $configPath
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
            }

            if ($process.ExitCode -ne 0) {
                throw "$($engine.Name)/$scenario renderer failed ($($process.ExitCode)).`nSTDOUT:`n$(Get-Content $stdout -Raw)`nSTDERR:`n$(Get-Content $stderr -Raw)"
            }

            $indexPath = Join-Path $outputRoot 'preview-all-00-INDEX.html'
            $normalPath = Join-Path $outputRoot 'preview-all-04-normal-newsletter.html'
            Assert-True (Test-Path $indexPath) "$($engine.Name)/$scenario did not generate the preview index."
            Assert-True ((Get-ChildItem $outputRoot -Filter 'preview-all-*.html').Count -eq 7) "$($engine.Name)/$scenario did not generate all six states plus the index."
            $indexHtml = Get-Content $indexPath -Raw -Encoding UTF8
            $normalHtml = Get-Content $normalPath -Raw -Encoding UTF8
            $expectedMode = if ($scenario -eq 'quiet') { 'QUIET / LATEST RELEASES' } else { 'NORMAL / NEW RELEASES' }
            Assert-True ($indexHtml.Contains($expectedMode)) "$($engine.Name)/$scenario reported the wrong release mode."
            Assert-True ($normalHtml.Contains('Selected Movie')) "$($engine.Name)/$scenario lost the selected movie."
            Assert-True ($normalHtml.Contains('Selected Show')) "$($engine.Name)/$scenario lost the selected TV show."
            Assert-True (-not $normalHtml.Contains('Private Movie')) "$($engine.Name)/$scenario leaked a private-library title."
            Assert-True (-not $normalHtml.Contains('Simulated Champion')) "$($engine.Name)/$scenario leaked the Binge Champion identity."
            Assert-True ($normalHtml.Contains('3h 0m watched')) "$($engine.Name)/$scenario lost the shared champion duration line."
            Assert-True ($normalHtml.Contains('1 TV show')) "$($engine.Name)/$scenario lost the unique TV-show breakdown."
            Assert-True (-not $normalHtml.Contains('0 movies')) "$($engine.Name)/$scenario rendered an empty Binge Champion movie category."
            Assert-True (-not $normalHtml.Contains('qualifying plays')) "$($engine.Name)/$scenario retained qualifying-play copy in Total Watched."
            Assert-True (-not $normalHtml.Contains('TV SHOWS WATCHED')) "$($engine.Name)/$scenario rendered an empty TV stats card."

            if ($scenario -eq 'tv-only') {
                Assert-True ($normalHtml.Contains('0 NEW MOVIES') -and $normalHtml.Contains('1 TV TITLE')) "$($engine.Name)/$scenario reported the wrong release-title counts."
                Assert-True ($normalHtml.Contains('TRENDING THIS WEEK')) "$($engine.Name)/$scenario did not promote Trending into the hero."
                Assert-True (-not $normalHtml.Contains('HOT NEW RELEASE')) "$($engine.Name)/$scenario promoted a TV release as HOT NEW RELEASE."
                Assert-True (([regex]::Matches($normalHtml, 'Selected Show')).Count -ge 2) "$($engine.Name)/$scenario removed the TV release after using Trending as the hero."
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

            if ($scenario -eq 'optional-hero-metadata') {
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
                try {
                    if ($engine.Container) {
                        $env:TAUTWEEKLY_DATA_DIR = $dataRoot
                        $env:TAUTWEEKLY_CONFIG = $configPath
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
                }
                if ($sendProcess.ExitCode -ne 0) {
                    throw "$($engine.Name)/$scenario SendTest failed ($($sendProcess.ExitCode)).`nSTDOUT:`n$(Get-Content $sendStdout -Raw)`nSTDERR:`n$(Get-Content $sendStderr -Raw)"
                }
                $sendLog = Get-Content $sendStdout -Raw
                Assert-True ($sendLog.Contains('Test email sent successfully.')) "$($engine.Name)/$scenario SendTest did not complete delivery."
                Assert-True ($sendLog -match 'direct Plex .*404.*Not Found') "$($engine.Name)/$scenario SendTest did not preserve the direct Plex 404 warning."
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
