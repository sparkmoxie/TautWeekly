Set-StrictMode -Version Latest

class TautWeeklySmtpException : System.Exception {
    [string]$Category
    [string]$Stage
    [int]$ResponseCode
    [int]$ResponseClass
    [bool]$BatchFatal
    [string]$Acceptance

    TautWeeklySmtpException(
        [string]$category,
        [string]$stage,
        [int]$responseCode,
        [bool]$batchFatal,
        [string]$acceptance
    ) : base(("SMTP delivery stopped at the {0} stage." -f $stage)) {
        $this.Category = $category
        $this.Stage = $stage
        $this.ResponseCode = $responseCode
        $this.ResponseClass = $(if ($responseCode -ge 100) { [Math]::Floor($responseCode / 100) } else { 0 })
        $this.BatchFatal = $batchFatal
        $this.Acceptance = $acceptance
    }
}

function New-TautWeeklySmtpException {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [int]$ResponseCode = 0,
        [string]$EnhancedStatus = '',
        [ValidateSet('not-attempted', 'rejected', 'unknown')][string]$Acceptance = 'not-attempted'
    )

    $responseClass = $(if ($ResponseCode -ge 100) { [Math]::Floor($ResponseCode / 100) } else { 0 })
    $category = 'smtp-transport-failed'
    $batchFatal = $true
    if ($Acceptance -eq 'unknown') {
        $category = 'smtp-acceptance-unknown'
    }
    elseif ($Stage -eq 'auth') {
        $category = 'smtp-auth-failed'
    }
    elseif ($responseClass -eq 4) {
        $category = 'smtp-rate-limited'
    }
    elseif ($Stage -eq 'rcpt-to' -and $responseClass -eq 5 -and $EnhancedStatus -match '^5\.(?:1|2)\.') {
        $category = 'smtp-recipient-rejected'
        $batchFatal = $false
    }
    elseif ($ResponseCode -gt 0) {
        $category = 'smtp-provider-rejected'
    }

    return [TautWeeklySmtpException]::new($category, $Stage, $ResponseCode, $batchFatal, $Acceptance)
}

function Get-TautWeeklySmtpConfigValue {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function New-TautWeeklySmtpIo {
    param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)

    $reader = [System.IO.StreamReader]::new($Stream, [Text.Encoding]::ASCII, $false, 4096, $true)
    $writer = [System.IO.StreamWriter]::new($Stream, [Text.UTF8Encoding]::new($false), 4096, $true)
    $writer.NewLine = "`r`n"
    $writer.AutoFlush = $true
    return [pscustomobject]@{ Reader = $reader; Writer = $writer }
}

function Read-TautWeeklySmtpResponse {
    param([Parameter(Mandatory = $true)][System.IO.StreamReader]$Reader)

    $first = $Reader.ReadLine()
    if ($null -eq $first) { throw "SMTP server closed the connection without a response." }
    if ($first -notmatch '^(?<code>\d{3})(?<separator>[ -])(?<message>.*)$') {
        throw "SMTP server returned an invalid response: $first"
    }

    $code = [int]$Matches.code
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($first)
    if ($Matches.separator -eq '-') {
        while ($true) {
            $line = $Reader.ReadLine()
            if ($null -eq $line) { throw "SMTP server closed a multiline response unexpectedly." }
            $lines.Add($line)
            if ($line -match ("^{0} " -f $code)) { break }
        }
    }

    return [pscustomobject]@{ Code = $code; Lines = @($lines); Text = ($lines -join ' | ') }
}

function Invoke-TautWeeklySmtpCommand {
    param(
        [Parameter(Mandatory = $true)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory = $true)][System.IO.StreamReader]$Reader,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][int[]]$ExpectedCodes,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    $Writer.WriteLine($Command)
    $response = Read-TautWeeklySmtpResponse -Reader $Reader
    if ($response.Code -notin $ExpectedCodes) {
        $enhancedStatus = ''
        if ($response.Lines.Count -gt 0 -and [string]$response.Lines[0] -match '^\d{3}[ -](?<enhanced>[245]\.\d{1,3}\.\d{1,3})(?:\s|$)') {
            $enhancedStatus = [string]$Matches.enhanced
        }
        throw (New-TautWeeklySmtpException -Stage $Stage -ResponseCode $response.Code -EnhancedStatus $enhancedStatus)
    }
    return $response
}

function Get-TautWeeklySmtpAuthMechanisms {
    param([Parameter(Mandatory = $true)][object]$EhloResponse)

    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($EhloResponse.Lines)) {
        $capability = ([string]$line) -replace '^\d{3}[- ]', ''
        if ($capability -match '^(?i:AUTH)(?:=|\s+)(?<methods>.+)$') {
            foreach ($method in ($Matches.methods -split '\s+')) {
                $normalized = ([string]$method).Trim().ToUpperInvariant()
                if (-not [string]::IsNullOrWhiteSpace($normalized) -and $normalized -notin $mechanisms) {
                    $mechanisms.Add($normalized)
                }
            }
        }
    }
    return @($mechanisms)
}

function ConvertTo-TautWeeklyMimeText {
    param([Parameter(Mandatory = $true)][System.Net.Mail.MailMessage]$MailMessage)

    $pickupRoot = Join-Path ([IO.Path]::GetTempPath()) ("tautweekly-smtp-{0}" -f [Guid]::NewGuid().ToString('N'))
    $pickupClient = $null
    try {
        [void](New-Item -ItemType Directory -Path $pickupRoot -Force)
        $pickupClient = [System.Net.Mail.SmtpClient]::new()
        $pickupClient.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::SpecifiedPickupDirectory
        $pickupClient.PickupDirectoryLocation = $pickupRoot
        $pickupClient.UseDefaultCredentials = $false
        $pickupClient.Send($MailMessage)

        $files = @(Get-ChildItem -LiteralPath $pickupRoot -File)
        if ($files.Count -ne 1) { throw "MIME serialization produced $($files.Count) files instead of one." }
        return [IO.File]::ReadAllText($files[0].FullName, [Text.Encoding]::UTF8)
    }
    finally {
        if ($null -ne $pickupClient) { $pickupClient.Dispose() }
        if (Test-Path -LiteralPath $pickupRoot) { Remove-Item -LiteralPath $pickupRoot -Recurse -Force }
    }
}

function Write-TautWeeklySmtpData {
    param(
        [Parameter(Mandatory = $true)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory = $true)][string]$MimeText
    )

    $normalized = $MimeText.Replace("`r`n", "`n").Replace("`r", "`n")
    $stringReader = [IO.StringReader]::new($normalized)
    try {
        while ($null -ne ($line = $stringReader.ReadLine())) {
            if ($line.StartsWith('.')) { $line = ".$line" }
            $Writer.WriteLine($line)
        }
        $Writer.WriteLine('.')
        $Writer.Flush()
    }
    finally {
        $stringReader.Dispose()
    }
}

function Send-TautWeeklySmtpMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Net.Mail.MailMessage]$MailMessage,
        [Parameter(Mandatory = $true)][object]$Config
    )

    $hostName = ([string](Get-TautWeeklySmtpConfigValue -Config $Config -Name 'SmtpHost' -Default '')).Trim()
    $port = [int](Get-TautWeeklySmtpConfigValue -Config $Config -Name 'SmtpPort' -Default 587)
    $enableTls = [bool](Get-TautWeeklySmtpConfigValue -Config $Config -Name 'SmtpEnableSsl' -Default $true)
    $useAuthentication = [bool](Get-TautWeeklySmtpConfigValue -Config $Config -Name 'SmtpUseAuthentication' -Default $true)
    $timeoutSeconds = [int](Get-TautWeeklySmtpConfigValue -Config $Config -Name 'SmtpTimeoutSeconds' -Default 30)
    $authenticationMethod = ([string](Get-TautWeeklySmtpConfigValue -Config $Config -Name 'SmtpAuthenticationMethod' -Default 'Auto')).Trim()

    if ([string]::IsNullOrWhiteSpace($hostName)) { throw (New-TautWeeklySmtpException -Stage 'configuration') }
    if ($port -lt 1 -or $port -gt 65535) { throw (New-TautWeeklySmtpException -Stage 'configuration') }
    if ($port -eq 465) { throw (New-TautWeeklySmtpException -Stage 'configuration') }
    if ($timeoutSeconds -lt 5 -or $timeoutSeconds -gt 300) { throw (New-TautWeeklySmtpException -Stage 'configuration') }
    if ($authenticationMethod -notin @('Auto', 'Login', 'Plain')) {
        throw (New-TautWeeklySmtpException -Stage 'configuration')
    }

    $username = ([string](Get-TautWeeklySmtpConfigValue -Config $Config -Name 'SmtpUsername' -Default '')).Trim()
    $password = [string](Get-TautWeeklySmtpConfigValue -Config $Config -Name 'SmtpPassword' -Default '')
    if ([string]::IsNullOrWhiteSpace($password)) {
        $password = [string](Get-TautWeeklySmtpConfigValue -Config $Config -Name 'SmtpAppPassword' -Default '')
    }
    if ([bool](Get-TautWeeklySmtpConfigValue -Config $Config -Name 'SmtpStripPasswordSpaces' -Default $false)) {
        $password = $password -replace '\s', ''
    }
    if ($useAuthentication -and ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password))) {
        throw (New-TautWeeklySmtpException -Stage 'configuration')
    }

    $fromAddress = ([System.Net.Mail.MailAddress]$MailMessage.From).Address
    if ($MailMessage.To.Count -ne 1) { throw (New-TautWeeklySmtpException -Stage 'configuration') }
    $toAddress = $MailMessage.To[0].Address
    try {
        $mimeText = ConvertTo-TautWeeklyMimeText -MailMessage $MailMessage
    }
    catch {
        throw (New-TautWeeklySmtpException -Stage 'mime')
    }

    $tcpClient = $null
    $stream = $null
    $reader = $null
    $writer = $null
    $currentStage = 'connect'
    $dataTerminatorWritten = $false
    try {
        $tcpClient = [Net.Sockets.TcpClient]::new()
        $connect = $tcpClient.BeginConnect($hostName, $port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($timeoutSeconds * 1000, $false)) {
            throw (New-TautWeeklySmtpException -Stage 'connect')
        }
        $tcpClient.EndConnect($connect)
        $tcpClient.ReceiveTimeout = $timeoutSeconds * 1000
        $tcpClient.SendTimeout = $timeoutSeconds * 1000
        $stream = $tcpClient.GetStream()
        $stream.ReadTimeout = $timeoutSeconds * 1000
        $stream.WriteTimeout = $timeoutSeconds * 1000

        $io = New-TautWeeklySmtpIo -Stream $stream
        $reader = $io.Reader
        $writer = $io.Writer
        $currentStage = 'greeting'
        $greeting = Read-TautWeeklySmtpResponse -Reader $reader
        if ($greeting.Code -ne 220) { throw (New-TautWeeklySmtpException -Stage 'greeting' -ResponseCode $greeting.Code) }

        $clientDomain = ([Net.Dns]::GetHostName() -replace '[^A-Za-z0-9.-]', '-').Trim('.-')
        if ([string]::IsNullOrWhiteSpace($clientDomain)) { $clientDomain = 'tautweekly.local' }
        $currentStage = 'ehlo'
        $ehlo = Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command "EHLO $clientDomain" -ExpectedCodes 250 -Label 'SMTP EHLO' -Stage 'ehlo'

        if ($enableTls) {
            if (($ehlo.Lines -join "`n") -notmatch '(?im)^\d{3}[- ]STARTTLS(?:\s|$)') {
                throw (New-TautWeeklySmtpException -Stage 'starttls')
            }
            $currentStage = 'starttls'
            [void](Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command 'STARTTLS' -ExpectedCodes 220 -Label 'SMTP STARTTLS' -Stage 'starttls')
            $reader.Dispose()
            $writer.Dispose()
            $reader = $null
            $writer = $null

            $currentStage = 'tls'
            $stream = [Net.Security.SslStream]::new($stream, $false)
            $stream.AuthenticateAsClient($hostName)
            $stream.ReadTimeout = $timeoutSeconds * 1000
            $stream.WriteTimeout = $timeoutSeconds * 1000
            $io = New-TautWeeklySmtpIo -Stream $stream
            $reader = $io.Reader
            $writer = $io.Writer
            $currentStage = 'ehlo'
            $ehlo = Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command "EHLO $clientDomain" -ExpectedCodes 250 -Label 'SMTP EHLO after STARTTLS' -Stage 'ehlo'
        }

        if ($useAuthentication) {
            $currentStage = 'auth'
            $mechanisms = @(Get-TautWeeklySmtpAuthMechanisms -EhloResponse $ehlo)
            $selectedMethod = $authenticationMethod.ToUpperInvariant()
            if ($selectedMethod -eq 'AUTO') {
                if ('LOGIN' -in $mechanisms) { $selectedMethod = 'LOGIN' }
                elseif ('PLAIN' -in $mechanisms) { $selectedMethod = 'PLAIN' }
                else { throw (New-TautWeeklySmtpException -Stage 'auth') }
            }
            elseif ($selectedMethod -notin $mechanisms) {
                throw (New-TautWeeklySmtpException -Stage 'auth')
            }

            if ($selectedMethod -eq 'LOGIN') {
                [void](Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command 'AUTH LOGIN' -ExpectedCodes 334 -Label 'SMTP AUTH LOGIN' -Stage 'auth')
                $encodedUsername = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($username))
                [void](Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command $encodedUsername -ExpectedCodes 334 -Label 'SMTP username authentication' -Stage 'auth')
                $encodedPassword = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($password))
                [void](Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command $encodedPassword -ExpectedCodes 235 -Label 'SMTP password authentication' -Stage 'auth')
            }
            else {
                $plainChallenge = Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command 'AUTH PLAIN' -ExpectedCodes @(235, 334) -Label 'SMTP AUTH PLAIN' -Stage 'auth'
                if ($plainChallenge.Code -eq 334) {
                    $plainBytes = [Text.Encoding]::UTF8.GetBytes("`0$username`0$password")
                    $plainResponse = [Convert]::ToBase64String($plainBytes)
                    [void](Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command $plainResponse -ExpectedCodes 235 -Label 'SMTP PLAIN authentication' -Stage 'auth')
                }
            }
        }

        # Authentication must complete with 235 before any envelope command is sent.
        $currentStage = 'mail-from'
        [void](Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command "MAIL FROM:<$fromAddress>" -ExpectedCodes 250 -Label 'SMTP MAIL FROM' -Stage 'mail-from')
        $currentStage = 'rcpt-to'
        [void](Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command "RCPT TO:<$toAddress>" -ExpectedCodes @(250, 251) -Label 'SMTP RCPT TO' -Stage 'rcpt-to')
        $currentStage = 'data-command'
        [void](Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command 'DATA' -ExpectedCodes 354 -Label 'SMTP DATA' -Stage 'data-command')
        $currentStage = 'data-acceptance'
        Write-TautWeeklySmtpData -Writer $writer -MimeText $mimeText
        $dataTerminatorWritten = $true
        $accepted = Read-TautWeeklySmtpResponse -Reader $reader
        if ($accepted.Code -ne 250) { throw (New-TautWeeklySmtpException -Stage 'data-acceptance' -ResponseCode $accepted.Code -Acceptance 'rejected') }

        $currentStage = 'quit'
        try { [void](Invoke-TautWeeklySmtpCommand -Writer $writer -Reader $reader -Command 'QUIT' -ExpectedCodes 221 -Label 'SMTP QUIT' -Stage 'quit') }
        catch { }
    }
    catch {
        if ($_.Exception -is [TautWeeklySmtpException]) {
            throw $_.Exception
        }
        $acceptance = $(if ($dataTerminatorWritten -and $currentStage -eq 'data-acceptance') { 'unknown' } else { 'not-attempted' })
        throw (New-TautWeeklySmtpException -Stage $currentStage -Acceptance $acceptance)
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $tcpClient) { $tcpClient.Dispose() }
    }
}
