param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Enable", "Disable", "Inspect")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^http://127\.0\.0\.1:[1-9][0-9]{0,4}$")]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$CallbackPort,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$Nonce,

    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TailscalePath {
    $roots = @($env:ProgramW6432, $env:ProgramFiles) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique
    foreach ($root in $roots) {
        $candidate = Join-Path ([string]$root) "Tailscale\tailscale.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Get-PropertyCount {
    param([object]$Value)
    if ($null -eq $Value) { return 0 }
    return @($Value.PSObject.Properties).Count
}

function Get-PropertyValue {
    param([object]$Value, [string]$Name, [object]$Default)
    if ($null -eq $Value) { return $Default }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-FunnelStatus {
    param([string]$TailscalePath)
    $raw = (& $TailscalePath funnel status --json 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw) -or $raw.Length -gt 262144) {
        if ($raw -match "(?i)not logged|logged out|needs login|no current profile|sign in") {
            throw "tailscale-sign-in-required"
        }
        if ($raw -match "(?i)service is not running|failed to connect to local tailscaled|no backend|connection refused") {
            throw "tailscale-not-running"
        }
        if ($raw -match "(?i)unknown command|unknown subcommand|does not support funnel") {
            throw "tailscale-funnel-unsupported"
        }
        throw "tailscale-status-unavailable"
    }
    try {
        $status = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $status) { return [PSCustomObject]@{} }
        return $status
    }
    catch { throw "tailscale-status-invalid" }
}

function Get-TailscaleApprovalUrl {
    param([string]$CommandOutput)
    if ([string]::IsNullOrWhiteSpace($CommandOutput)) { return "" }
    $match = [regex]::Match($CommandOutput, 'https://login\.tailscale\.com/[^\s''"]+')
    if (-not $match.Success -or $match.Value.Length -gt 2048) { return "" }
    try {
        $uri = [Uri]$match.Value
        if ($uri.Scheme -cne "https" -or $uri.Host -ine "login.tailscale.com" -or
            -not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or -not $uri.IsDefaultPort -or
            -not [string]::IsNullOrWhiteSpace($uri.Fragment)) { return "" }
        return $uri.AbsoluteUri
    }
    catch { return "" }
}

function Invoke-TailscaleFunnelEnable {
    param([string]$TailscalePath, [string]$ExpectedTarget)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $TailscalePath
    $startInfo.Arguments = "funnel --bg --yes --https=443 $ExpectedTarget"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "tailscale-start-failed" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $completed = $process.WaitForExit(15000)
        if (-not $completed) {
            try { $process.Kill() } catch { }
            if (-not $process.WaitForExit(5000)) { throw "tailscale-stop-failed" }
        }
        $output = [string]($stdoutTask.GetAwaiter().GetResult()) + [string]($stderrTask.GetAwaiter().GetResult())
        if ($output.Length -gt 262144) { throw "tailscale-output-too-large" }
        return [PSCustomObject]@{
            ExitCode = if ($completed) { [int]$process.ExitCode } else { -1 }
            TimedOut = -not $completed
            Output = $output
        }
    }
    finally { $process.Dispose() }
}

function Test-ServeStatusEmpty {
    param([object]$Status)
    foreach ($name in @("TCP", "Web", "Services", "AllowFunnel", "Foreground")) {
        $property = $Status.PSObject.Properties[$name]
        if ($null -ne $property -and (Get-PropertyCount $property.Value) -ne 0) { return $false }
    }
    return $true
}

function Test-OwnedFunnelStatus {
    param([object]$Status, [string]$ExpectedTarget)
    $tcpProperty = $Status.PSObject.Properties["TCP"]
    $webProperty = $Status.PSObject.Properties["Web"]
    if ($null -eq $tcpProperty -or $null -eq $webProperty) { return $false }
    if ((Get-PropertyCount $tcpProperty.Value) -ne 1 -or (Get-PropertyCount $webProperty.Value) -ne 1) { return $false }
    foreach ($name in @("Services", "Foreground")) {
        $property = $Status.PSObject.Properties[$name]
        if ($null -ne $property -and (Get-PropertyCount $property.Value) -ne 0) { return $false }
    }
    $funnelProperty = $Status.PSObject.Properties["AllowFunnel"]
    $tcp443 = $tcpProperty.Value.PSObject.Properties["443"]
    if ($null -eq $tcp443 -or -not [bool](Get-PropertyValue $tcp443.Value "HTTPS" $false) -or [bool](Get-PropertyValue $tcp443.Value "HTTP" $false)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $tcp443.Value "TCPForward" "")) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $tcp443.Value "TerminateTLS" "")) -or
        [int](Get-PropertyValue $tcp443.Value "ProxyProtocol" 0) -ne 0) { return $false }
    $webEntry = @($webProperty.Value.PSObject.Properties)[0]
    if ([string]$webEntry.Name -notmatch "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.ts\.net:443$") { return $false }
    if ($null -eq $funnelProperty) { return $false }
    $funnelEntries = @($funnelProperty.Value.PSObject.Properties)
    if ($funnelEntries.Count -ne 1) { return $false }
    foreach ($entry in $funnelEntries) {
        if (-not [bool]$entry.Value -or [string]$entry.Name -ine [string]$webEntry.Name) { return $false }
    }
    $handlers = $webEntry.Value.PSObject.Properties["Handlers"]
    if ($null -eq $handlers -or (Get-PropertyCount $handlers.Value) -ne 1) { return $false }
    $rootHandler = $handlers.Value.PSObject.Properties["/"]
    if ($null -eq $rootHandler -or [string](Get-PropertyValue $rootHandler.Value "Proxy" "") -cne $ExpectedTarget) { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $rootHandler.Value "Path" "")) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $rootHandler.Value "Text" "")) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $rootHandler.Value "Redirect" ""))) { return $false }
    $caps = $rootHandler.Value.PSObject.Properties["AcceptAppCaps"]
    return $null -eq $caps -or @($caps.Value).Count -eq 0
}

function Test-PublicIPv4Address {
    param([string]$Value)
    try { $bytes = ([Net.IPAddress]::Parse($Value)).GetAddressBytes() }
    catch { return $false }
    if ($bytes.Count -ne 4) { return $false }
    if ($bytes[0] -in @(0, 10, 127) -or $bytes[0] -ge 224) { return $false }
    if ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) { return $false }
    if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $false }
    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $false }
    if ($bytes[0] -eq 192 -and ($bytes[1] -eq 0 -or $bytes[1] -eq 168)) { return $false }
    if ($bytes[0] -eq 198 -and $bytes[1] -in @(18, 19, 51)) { return $false }
    if ($bytes[0] -eq 203 -and $bytes[1] -eq 0 -and $bytes[2] -eq 113) { return $false }
    return $true
}

function Get-NslookupPublicIPv4Addresses {
    param([string]$Output)
    if ([string]::IsNullOrWhiteSpace($Output) -or $Output.Length -gt 65536) { return @() }
    $matches = [regex]::Matches($Output, '(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])')
    return @($matches |
        ForEach-Object { [string]$_.Value } |
        Where-Object { $_ -ne '1.1.1.1' -and (Test-PublicIPv4Address $_) } |
        Select-Object -Unique |
        Select-Object -First 4)
}

function Resolve-PublicFunnelIPv4Addresses {
    param([string]$Hostname)
    if ($Hostname -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.ts\.net$') { return @() }
    $systemRoot = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) { return @() }
    $nslookupPath = Join-Path $systemRoot 'System32\nslookup.exe'
    if (-not (Test-Path -LiteralPath $nslookupPath -PathType Leaf)) { return @() }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $nslookupPath
    $startInfo.Arguments = "-type=A -timeout=2 -retry=1 $Hostname 1.1.1.1"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { return @() }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(6000)) {
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(2000)
            return @()
        }
        $output = [string]($stdoutTask.GetAwaiter().GetResult()) + [string]($stderrTask.GetAwaiter().GetResult())
        if ($process.ExitCode -ne 0) { return @() }
        return @(Get-NslookupPublicIPv4Addresses $output)
    }
    catch { return @() }
    finally { $process.Dispose() }
}

function Test-PublicFunnelPublished {
    param([object]$Status, [string]$ExpectedTarget)
    if (-not (Test-OwnedFunnelStatus $Status $ExpectedTarget)) { return $false }
    $webEntry = @($Status.PSObject.Properties['Web'].Value.PSObject.Properties)[0]
    $hostname = ([string]$webEntry.Name).Substring(0, ([string]$webEntry.Name).Length - 4)
    if ($hostname -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.ts\.net$') { return $false }
    # Resolve-DnsName honors Windows NRPT even with -Server, so use the system
    # nslookup client against a fixed public resolver to bypass MagicDNS.
    $addresses = @(Resolve-PublicFunnelIPv4Addresses $hostname)
    foreach ($address in $addresses) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $connect = $client.BeginConnect($address, 443, $null, $null)
            if (-not $connect.AsyncWaitHandle.WaitOne(4000)) { continue }
            $client.EndConnect($connect)
            $stream = $client.GetStream()
            try {
                $stream.ReadTimeout = 5000
                $stream.WriteTimeout = 5000
                $tls = New-Object Net.Security.SslStream($stream, $false)
                try {
                    $authentication = $tls.BeginAuthenticateAsClient($hostname, $null, $null)
                    if (-not $authentication.AsyncWaitHandle.WaitOne(5000)) { continue }
                    $tls.EndAuthenticateAsClient($authentication)
                    if ($tls.IsAuthenticated -and $tls.IsEncrypted) { return $true }
                }
                finally { $tls.Dispose() }
            }
            finally { $stream.Dispose() }
        }
        catch { }
        finally { $client.Dispose() }
    }
    return $false
}

function Test-OwnedLegacyServeStatus {
    param([object]$Status, [string]$ExpectedTarget)
    if (-not (Test-OwnedFunnelStatusShape $Status $ExpectedTarget)) { return $false }
    $webEntry = @($Status.PSObject.Properties['Web'].Value.PSObject.Properties)[0]
    $funnelProperty = $Status.PSObject.Properties['AllowFunnel']
    if ($null -eq $funnelProperty) { return $true }
    $entries = @($funnelProperty.Value.PSObject.Properties)
    if ($entries.Count -eq 0) { return $true }
    return $entries.Count -eq 1 -and [string]$entries[0].Name -ieq [string]$webEntry.Name -and -not [bool]$entries[0].Value
}

function Test-OwnedFunnelStatusShape {
    param([object]$Status, [string]$ExpectedTarget)
    $tcpProperty = $Status.PSObject.Properties['TCP']
    $webProperty = $Status.PSObject.Properties['Web']
    if ($null -eq $tcpProperty -or $null -eq $webProperty) { return $false }
    if ((Get-PropertyCount $tcpProperty.Value) -ne 1 -or (Get-PropertyCount $webProperty.Value) -ne 1) { return $false }
    foreach ($name in @('Services', 'Foreground')) {
        $property = $Status.PSObject.Properties[$name]
        if ($null -ne $property -and (Get-PropertyCount $property.Value) -ne 0) { return $false }
    }
    $tcp443 = $tcpProperty.Value.PSObject.Properties['443']
    if ($null -eq $tcp443 -or -not [bool](Get-PropertyValue $tcp443.Value 'HTTPS' $false) -or [bool](Get-PropertyValue $tcp443.Value 'HTTP' $false)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $tcp443.Value 'TCPForward' '')) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $tcp443.Value 'TerminateTLS' '')) -or
        [int](Get-PropertyValue $tcp443.Value 'ProxyProtocol' 0) -ne 0) { return $false }
    $webEntry = @($webProperty.Value.PSObject.Properties)[0]
    if ([string]$webEntry.Name -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.ts\.net:443$') { return $false }
    $handlers = $webEntry.Value.PSObject.Properties['Handlers']
    if ($null -eq $handlers -or (Get-PropertyCount $handlers.Value) -ne 1) { return $false }
    $rootHandler = $handlers.Value.PSObject.Properties['/']
    if ($null -eq $rootHandler -or [string](Get-PropertyValue $rootHandler.Value 'Proxy' '') -cne $ExpectedTarget) { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $rootHandler.Value 'Path' '')) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $rootHandler.Value 'Text' '')) -or
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $rootHandler.Value 'Redirect' ''))) { return $false }
    $caps = $rootHandler.Value.PSObject.Properties['AcceptAppCaps']
    return $null -eq $caps -or @($caps.Value).Count -eq 0
}

function Send-Result {
    param([string]$Code, [object]$ServeStatus, [string]$SetupUrl = "", [bool]$PubliclyPublished = $false)
    if (-not [string]::IsNullOrWhiteSpace($SetupUrl) -and
        $SetupUrl -notmatch "^https://login\.tailscale\.com/[^\s]+$") {
        throw "invalid-provider-url"
    }
    $result = [ordered]@{
        schemaVersion = 1
        nonce = $Nonce
        code = $Code
        serveStatus = if ($null -eq $ServeStatus) { [PSCustomObject]@{} } else { $ServeStatus }
        publiclyPublished = $PubliclyPublished
    }
    if (-not [string]::IsNullOrWhiteSpace($SetupUrl)) { $result.setupUrl = $SetupUrl }
    $json = $result | ConvertTo-Json -Compress -Depth 32
    if ($json.Length -gt 262144) { throw "callback-result-too-large" }
    $client = New-Object Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect("127.0.0.1", $CallbackPort, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(5000)) { throw "callback-connect-timeout" }
        $client.EndConnect($pending)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = $client.GetStream()
        try { $stream.Write($bytes, 0, $bytes.Length) }
        finally { $stream.Dispose() }
    }
    finally { $client.Dispose() }
}

if (-not (Test-IsAdministrator)) {
    if ($Elevated) { exit 26 }
    try {
        if ([IO.Path]::GetFileName($PSCommandPath) -cne "TAILSCALE-HELPER.ps1") { exit 26 }
        $systemRoot = [string]$env:SystemRoot
        if ([string]::IsNullOrWhiteSpace($systemRoot)) { exit 26 }
        $powerShellPath = Join-Path $systemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) { exit 26 }
        $arguments = @(
            "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", ([char]34 + $PSCommandPath + [char]34),
            "-Action", $Action,
            "-Target", $Target,
            "-CallbackPort", [string]$CallbackPort,
            "-Nonce", $Nonce,
            "-Elevated"
        )
        $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -Verb RunAs -WindowStyle Hidden -PassThru
        if (-not $process.WaitForExit(270000)) {
            try { $process.Kill() } catch { }
            exit 10
        }
        $process.Refresh()
        exit [int]$process.ExitCode
    }
    catch { exit 10 }
}

try {
    $tailscalePath = Get-TailscalePath
    if ([string]::IsNullOrWhiteSpace([string]$tailscalePath)) {
        Send-Result "not-installed" $null
        exit 20
    }
    $before = Get-FunnelStatus $tailscalePath
    if ($Action -eq "Inspect") {
        $published = Test-PublicFunnelPublished $before $Target
        Send-Result "inspected" $before "" $published
        exit 0
    }
    $ownedFunnel = Test-OwnedFunnelStatus $before $Target
    $ownedLegacyServe = Test-OwnedLegacyServeStatus $before $Target
    if (-not (Test-ServeStatusEmpty $before) -and -not $ownedFunnel -and -not $ownedLegacyServe) {
        Send-Result "conflict" $before
        exit 21
    }
    if ($Action -eq "Enable") {
        if (-not $ownedFunnel) {
            $command = Invoke-TailscaleFunnelEnable $tailscalePath $Target
            $approvalUrl = Get-TailscaleApprovalUrl $command.Output
            if (-not [string]::IsNullOrWhiteSpace($approvalUrl)) {
                Send-Result "provider-approval-required" $null $approvalUrl
                exit 24
            }
            if ($command.ExitCode -ne 0) {
                if ($command.Output -match "(?i)not logged|logged out|needs login|no current profile|sign in") {
                    Send-Result "sign-in-required" $null
                    exit 25
                }
                if ($command.Output -match "(?i)service is not running|failed to connect to local tailscaled|no backend|connection refused") {
                    Send-Result "not-running" $null
                    exit 27
                }
                if ($command.Output -match "(?i)unknown command|unknown subcommand|does not support funnel") {
                    Send-Result "unsupported" $null
                    exit 28
                }
                if ($command.TimedOut) {
                    $afterTimeout = Get-FunnelStatus $tailscalePath
                    if (Test-OwnedFunnelStatus $afterTimeout $Target) {
                        $published = Test-PublicFunnelPublished $afterTimeout $Target
                        Send-Result "enabled" $afterTimeout "" $published
                        exit 0
                    }
                }
                Send-Result "unavailable" $null
                exit 22
            }
        }
        $after = Get-FunnelStatus $tailscalePath
        if (-not (Test-OwnedFunnelStatus $after $Target)) {
            Send-Result "verification-failed" $after
            exit 23
        }
        $published = Test-PublicFunnelPublished $after $Target
        Send-Result "enabled" $after "" $published
        exit 0
    }
    if ($ownedFunnel) {
        & $tailscalePath funnel --yes --https=443 off 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) {
            Send-Result "unavailable" $before
            exit 22
        }
    }
    elseif ($ownedLegacyServe) {
        & $tailscalePath serve --yes --https=443 off 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) {
            Send-Result "unavailable" $before
            exit 22
        }
    }
    $after = Get-FunnelStatus $tailscalePath
    if (-not (Test-ServeStatusEmpty $after)) {
        Send-Result "verification-failed" $after
        exit 23
    }
    Send-Result "disabled" $after
    exit 0
}
catch {
    if ($_.Exception.Message -eq "tailscale-sign-in-required") {
        Send-Result "sign-in-required" $null
        exit 25
    }
    if ($_.Exception.Message -eq "tailscale-not-running") {
        Send-Result "not-running" $null
        exit 27
    }
    if ($_.Exception.Message -eq "tailscale-funnel-unsupported") {
        Send-Result "unsupported" $null
        exit 28
    }
    Send-Result "unavailable" $null
    exit 22
}
