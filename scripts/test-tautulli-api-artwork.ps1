[CmdletBinding()]
param(
    [string]$Root = '',
    [string[]]$RendererPaths = @('platforms/windows/TautWeekly.ps1', 'platforms/nas-docker/app/TautWeekly.ps1', 'platforms/mac-docker/app/TautWeekly.ps1')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Read-Function($Ast, [string]$Name) {
    $node = $Ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name}, $true)
    Assert-True ($null -ne $node) "Missing $Name"
    return $node.Extent.Text
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-api-artwork-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
try {
    foreach ($relative in $RendererPaths) {
        & {
            param($relative)
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $relative), [ref]$tokens, [ref]$errors)
            Assert-True ($errors.Count -eq 0) "Parse errors: $relative"
            foreach ($name in @('Build-TautulliUri', 'Invoke-TautulliApi', 'Get-DesignPmsImage')) {
                Invoke-Expression (Read-Function $ast $name)
            }
            # Every binary API path uses the same header and refuses redirects.
            foreach ($name in @('Get-DesignLogoExportSimple', 'Get-DesignRichExport', 'Get-DesignLogoFromExporter', 'Get-TautulliDefaultPosterHash', 'Get-PosterPath', 'Get-DesignPmsImage')) {
                $definition = Read-Function $ast $name
                $requestAst = [Management.Automation.Language.Parser]::ParseInput($definition, [ref]$null, [ref]$null)
                $requests = @($requestAst.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WebRequest'}, $true))
                Assert-True ($requests.Count -gt 0) "$relative/$name has no binary request"
                foreach ($request in $requests) {
                    Assert-True ($request.Extent.Text -match "X-Api-Key" -and $request.Extent.Text -match '-MaximumRedirection 0') "$relative/$name omitted binary header or redirect refusal"
                }
            }
            $script:Config = [PSCustomObject]@{ ApiKey = 'synthetic-secret-for-header-only' }
            $script:TautulliBase = 'https://tautulli.invalid/root'
            $script:DesignMediaDir = $tempRoot
            $script:RequestMode = 'ok'; $script:Version = 'v2.18.0'
            $script:Calls = New-Object System.Collections.Generic.List[object]
            $script:Warnings = New-Object System.Collections.Generic.List[string]
            function Write-Log { param($Message, $Level) $script:Warnings.Add([string]$Message) }
            function Invoke-RestMethod {
                param($Uri, $Headers, $MaximumRedirection, $Method, $TimeoutSec, $Body, $ContentType)
                Assert-True ($Uri -notmatch 'apikey=' -and -not $Uri.Contains($Config.ApiKey)) 'API key leaked into JSON URL'
                Assert-True ($Headers['X-Api-Key'] -ceq $Config.ApiKey -and $Headers.Count -eq 1) 'JSON header missing or too broadly scoped'
                Assert-True ($MaximumRedirection -eq 0) 'JSON request followed redirects'
                if ($script:RequestMode -eq 'throw') { throw ('Untrusted error echoes ' + $Config.ApiKey) }
                if ($script:RequestMode -eq 'reject') { return [PSCustomObject]@{ response = [PSCustomObject]@{ result = 'error'; message = $Config.ApiKey } } }
                return [PSCustomObject]@{ response = [PSCustomObject]@{ result = 'success'; data = [PSCustomObject]@{ tautulli_version = $script:Version } } }
            }
            foreach ($version in @('v2.18.0', 'v2.19.1')) {
                $script:Version = $version
                Assert-True ((Invoke-TautulliApi -Command 'get_tautulli_info').tautulli_version -ceq $version) "Header compatibility failed for $version"
            }
            foreach ($mode in @('throw', 'reject')) {
                $script:RequestMode = $mode; $message = ''
                try { Invoke-TautulliApi -Command 'get_tautulli_info' | Out-Null } catch { $message = $_.Exception.Message }
                Assert-True ($message -and -not $message.Contains($Config.ApiKey)) 'Untrusted JSON error exposed the secret'
            }
            $script:RequestMode = 'ok'
            foreach ($badBase in @('file:///tmp/tautulli', 'https://user:secret@example.com', 'https://tautulli.invalid/?apikey=secret', 'https://tautulli.invalid/#fragment')) {
                $script:TautulliBase = $badBase; $rejected = $false
                try { Build-TautulliUri -Command 'get_users' | Out-Null } catch { $rejected = $true }
                Assert-True $rejected "Invalid API base accepted: $badBase"
            }
            $script:TautulliBase = 'https://tautulli.invalid/root'
            $rejected = $false
            try { Build-TautulliUri -Command 'get_users' -Parameters @{ apikey = 'unwanted' } | Out-Null } catch { $rejected = $true }
            Assert-True $rejected 'Caller could add an API-key query parameter'
            $rejected = $false
            try { Invoke-TautulliApi -Command 'get_history' -Parameters @{ ApiKey = 'unwanted' } -Post | Out-Null } catch { $rejected = $true }
            Assert-True $rejected 'Caller could add an API-key form parameter'
            function Invoke-WebRequest {
                param($Uri, $Headers, $MaximumRedirection, $OutFile, $TimeoutSec)
                Assert-True ($Uri.StartsWith($TautulliBase + '/api/v2?')) 'Artwork fetched outside configured Tautulli API'
                Assert-True (-not $Uri.Contains($Config.ApiKey) -and $Uri -notmatch 'apikey=') 'API key leaked into binary URL'
                Assert-True ($Headers['X-Api-Key'] -ceq $Config.ApiKey -and $Headers.Count -eq 1 -and $MaximumRedirection -eq 0) 'Binary request lost header scope or redirect refusal'
                $query = @{}
                foreach ($part in ([Uri]$Uri).Query.TrimStart('?').Split('&')) {
                    $pair = $part.Split('=', 2)
                    $query[[Uri]::UnescapeDataString($pair[0])] = [Uri]::UnescapeDataString($pair[1])
                }
                $script:Calls.Add($query)
                if ($script:RequestMode -eq 'deny-all' -or ($script:RequestMode -eq 'deny-remote' -and $query.ContainsKey('img'))) {
                    throw ('Untrusted download error echoes ' + $Config.ApiKey)
                }
                [IO.File]::WriteAllBytes($OutFile, [byte[]](1..255) * 4)
            }
            $remote = 'https://images.invalid/stored-art.jpg'
            $result = Get-DesignPmsImage -ImagePath $remote -RatingKey '123' -OutputName 'stored.jpg'
            Assert-True ($result -ceq 'media/stored.jpg' -and $Calls.Count -eq 1 -and $Calls[0].rating_key -ceq '123' -and $Calls[0].img -ceq $remote) 'Stored artwork lost its item identity'
            Assert-True (-not $Calls[0].ContainsKey('fallback')) 'Remote denial could be mistaken for a successful generic image'
            $Calls.Clear(); $script:RequestMode = 'deny-remote'
            $result = Get-DesignPmsImage -ImagePath $remote -RatingKey '123' -OutputName 'fallback.jpg'
            Assert-True ($result -ceq 'media/fallback.jpg' -and $Calls.Count -eq 2 -and $Calls[1].rating_key -ceq '123' -and -not $Calls[1].ContainsKey('img') -and $Calls[1].fallback -ceq 'art') 'Denied remote artwork did not use the same item Plex fallback'
            $Calls.Clear(); $script:RequestMode = 'deny-all'
            $result = Get-DesignPmsImage -ImagePath $remote -RatingKey '123' -OutputName 'denied.jpg'
            Assert-True (-not $result -and $Calls.Count -eq 2 -and -not (Test-Path (Join-Path $tempRoot 'denied.jpg'))) 'Denied image retained stale bytes or fetched directly'
            $Calls.Clear()
            [void](Get-DesignPmsImage -ImagePath $remote -RatingKey '../other' -OutputName 'invalid-key.jpg')
            Assert-True ($Calls.Count -eq 1) 'Invalid key was used to synthesize a Plex fallback'
            Assert-True (-not ($Warnings -join ' ').Contains($Config.ApiKey)) 'Binary error logging exposed the secret'
            $Calls.Clear(); $script:RequestMode = 'ok'
            [void](Get-DesignPmsImage -ImagePath '/library/metadata/123/art/456' -RatingKey '123' -OutputName 'relative.jpg')
            Assert-True ($Calls.Count -eq 1 -and $Calls[0].img -ceq '/library/metadata/123/art/456' -and $Calls[0].rating_key -ceq '123') 'Plex-relative artwork regressed'
            Write-Host "[PASS] $relative JSON/binary headers, safe errors, artwork identity, remote denial, and Plex fallback."
        } $relative
    }
    # Exercise real HTTP redirects too: neither JSON nor binary requests may
    # deliver a custom API credential header to the redirected origin.
    $readyPath = Join-Path $tempRoot 'redirect-fixture.json'
    $redirectJob = Start-Job -ArgumentList $readyPath -ScriptBlock {
        param($readyPath)
        $source = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $target = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $source.Start(); $target.Start()
        $sourceCount = 0; $targetCount = 0; $sourceHeaderCount = 0; $queryKeyCount = 0
        $postCount = 0; $bodySecretCount = 0
        try {
            # Publish readiness only after the full JSON is closed. A reader
            # can otherwise observe Set-Content's newly created empty file.
            $readyJson = @{ sourcePort = $source.LocalEndpoint.Port; targetPort = $target.LocalEndpoint.Port } | ConvertTo-Json -Compress
            $readyTemporary = $readyPath + '.tmp'
            [IO.File]::WriteAllText($readyTemporary, $readyJson, (New-Object Text.UTF8Encoding($false)))
            [IO.File]::Move($readyTemporary, $readyPath)
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $doneAt = -1L
            while ($watch.ElapsedMilliseconds -lt 10000) {
                foreach ($entry in @(@{listener=$source;source=$true}, @{listener=$target;source=$false})) {
                    if (-not $entry.listener.Pending()) { continue }
                    $client = $entry.listener.AcceptTcpClient()
                    try {
                        $stream = $client.GetStream(); $stream.ReadTimeout = 2000
                        $reader = New-Object IO.StreamReader($stream)
                        $line = $reader.ReadLine(); $hasKey = $false; $contentLength = 0
                        $isPost = $line.StartsWith('POST ')
                        if ($line -match '(?i)apikey=') { $queryKeyCount++ }
                        while ($null -ne ($line = $reader.ReadLine()) -and $line.Length -gt 0) {
                            if ($line -match '(?i)^X-Api-Key:') { $hasKey = $true }
                            if ($line -match '(?i)^Content-Length: (\d+)') { $contentLength = [int]$Matches[1] }
                        }
                        if ($isPost) {
                            $postCount++
                            $buffer = New-Object char[] $contentLength
                            $read = 0
                            while ($read -lt $contentLength) {
                                $count = $reader.Read($buffer, $read, $contentLength - $read)
                                if ($count -le 0) { break }
                                $read += $count
                            }
                            $bodyText = -join $buffer
                            if ($bodyText -match '(?i)apikey=' -or $bodyText.Contains('synthetic-real-redirect-header')) { $bodySecretCount++ }
                        }
                        if ($entry.source) {
                            $sourceCount++
                            if ($hasKey) { $sourceHeaderCount++ }
                            $status = if ($sourceCount -eq 4) { '307 Temporary Redirect' } else { '302 Found' }
                            $reply = "HTTP/1.1 $status`r`nLocation: http://127.0.0.1:$($target.LocalEndpoint.Port)/api/v2?cmd=get_users`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
                        }
                        else {
                            $targetCount++
                            $body = '{"response":{"result":"success","data":[]}}'
                            $reply = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body"
                        }
                        $bytes = [Text.Encoding]::ASCII.GetBytes($reply)
                        $stream.Write($bytes, 0, $bytes.Length)
                    }
                    finally { $client.Close() }
                }
                if ($sourceCount -ge 4 -and $doneAt -lt 0) { $doneAt = $watch.ElapsedMilliseconds + 300 }
                if ($doneAt -ge 0 -and $watch.ElapsedMilliseconds -ge $doneAt) { break }
                Start-Sleep -Milliseconds 10
            }
            [PSCustomObject]@{sourceCount=$sourceCount;targetCount=$targetCount;sourceHeaderCount=$sourceHeaderCount;queryKeyCount=$queryKeyCount;postCount=$postCount;bodySecretCount=$bodySecretCount}
        }
        finally { $source.Stop(); $target.Stop() }
    }
    try {
        $readyWatch = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $readyPath) -and $readyWatch.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 50 }
        Assert-True (Test-Path -LiteralPath $readyPath) 'Redirect fixture did not start'
        $ports = [IO.File]::ReadAllText($readyPath) | ConvertFrom-Json
        $script:TautulliBase = 'http://127.0.0.1:' + $ports.sourcePort
        $script:Config = [PSCustomObject]@{ ApiKey = 'synthetic-real-redirect-header' }
        $script:DesignMediaDir = $tempRoot
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $RendererPaths[0]), [ref]$tokens, [ref]$errors)
        foreach ($name in @('Build-TautulliUri', 'Invoke-TautulliApi', 'Get-DesignPmsImage')) { Invoke-Expression (Read-Function $ast $name) }
        function Write-Log { param($Message, $Level) }
        $refused = $false
        try { Invoke-TautulliApi -Command 'get_users' | Out-Null } catch { $refused = $true }
        Assert-True $refused 'JSON request accepted an HTTP redirect'
        Assert-True (-not (Get-DesignPmsImage -RatingKey '123' -OutputName 'redirect.jpg')) 'Binary request accepted an HTTP redirect'
        foreach ($code in @(302, 307)) {
            $refused = $false
            try { Invoke-TautulliApi -Command 'get_history' -Parameters @{ start_date='2026-11-11'; section_id='10' } -Post | Out-Null } catch { $refused = $true }
            Assert-True $refused "History POST accepted an HTTP $code redirect"
        }
        [void](Wait-Job -Job $redirectJob -Timeout 15)
        Assert-True ($redirectJob.State -eq 'Completed') 'Redirect fixture did not finish'
        $observed = Receive-Job -Job $redirectJob
        Assert-True ($observed.sourceCount -eq 4 -and $observed.sourceHeaderCount -eq 4 -and $observed.targetCount -eq 0 -and $observed.queryKeyCount -eq 0 -and $observed.postCount -eq 2 -and $observed.bodySecretCount -eq 0) ("Redirect scope failed: requests={0}, headers={1}, redirected={2}, query-keys={3}, posts={4}, body-secrets={5}" -f $observed.sourceCount, $observed.sourceHeaderCount, $observed.targetCount, $observed.queryKeyCount, $observed.postCount, $observed.bodySecretCount)
        Write-Host '[PASS] Real JSON/binary and history POST 302/307 redirects refuse credential/body forwarding.'
    }
    finally {
        Stop-Job -Job $redirectJob -ErrorAction SilentlyContinue
        Remove-Job -Job $redirectJob -Force -ErrorAction SilentlyContinue
    }
    foreach ($payload in @('platforms/windows', 'platforms/nas-docker/app', 'platforms/mac-docker/app')) {
        & {
            param($payload)
            $script:ExpectedKey = 'synthetic-discovery-header-key'
            function Invoke-RestMethod {
                param($Uri, $Headers, $MaximumRedirection, $Method, $TimeoutSec)
                Assert-True ($Uri -notmatch 'apikey=' -and $Headers['X-Api-Key'] -ceq $script:ExpectedKey -and $MaximumRedirection -eq 0) 'Discovery request exposed key or followed redirect'
                return [PSCustomObject]@{ response = [PSCustomObject]@{ result = 'success'; data = 'header-ok' } }
            }
            . (Join-Path $Root ($payload + '/Library-Selection.ps1'))
            . (Join-Path $Root ($payload + '/User-Exclusions.ps1'))
            Assert-True ((Invoke-TautWeeklyLibraryApi -TautulliUrl 'http://tautulli.invalid' -ApiKey $script:ExpectedKey -Command 'get_libraries') -eq 'header-ok') 'Library discovery header failed'
            Assert-True ((Invoke-TautWeeklyUserApi -TautulliUrl 'http://tautulli.invalid' -ApiKey $script:ExpectedKey -Command 'get_users') -eq 'header-ok') 'User discovery header failed'
            $verify = Get-ChildItem (Join-Path $Root $payload) -File | Where-Object { $_.Name -ieq 'Verify-Setup.ps1' } | Select-Object -First 1
            $source = [IO.File]::ReadAllText($verify.FullName)
            Assert-True ($source -notmatch 'apikey=' -and $source.Contains('Invoke-TautWeeklyLibraryApi')) 'Setup verification bypasses safe header helper'
            Write-Host "[PASS] $payload discovery and verification use scoped header requests."
        } $payload
    }
}
finally {
    # This test-created path is resolved under the OS temp directory.
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    Assert-True ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) 'Test cleanup escaped temp directory'
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
