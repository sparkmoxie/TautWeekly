param(
    [string]$DataRoot = $(if ($env:TAUTWEEKLY_DATA_DIR) { $env:TAUTWEEKLY_DATA_DIR } else { "/data" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion -lt [Version]"7.2") {
    throw "PowerShell 7.2 or newer is required. Found $($PSVersionTable.PSVersion)."
}

$configPath = Join-Path $DataRoot "config.json"
$examplePath = "/opt/tautweekly/config.example.json"

function Read-Default {
    param([string]$Prompt, [string]$Default = "")
    $label = if ([string]::IsNullOrWhiteSpace($Default)) { $Prompt } else { "$Prompt [$Default]" }
    $value = Read-Host $label
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $Default }
    return ([string]$value).Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $suffix = if ($Default) { "Y/n" } else { "y/N" }
    while ($true) {
        $value = Read-Host "$Prompt [$suffix]"
        $raw = if ($null -eq $value) { "" } else { ([string]$value).Trim().ToLowerInvariant() }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        if ($raw -in @("y","yes")) { return $true }
        if ($raw -in @("n","no")) { return $false }
        Write-Host "Please enter Y or N." -ForegroundColor Yellow
    }
}

function Read-SecretPlainText {
    param([string]$Prompt, [bool]$AllowBlank = $false)

    while ($true) {
        $secure = Read-Host $Prompt -AsSecureString

        # Read-Host may return an empty SecureString when Enter is pressed.
        # Marshal conversion handles both Windows PowerShell and PowerShell 7
        # without relying on the PowerShell 7-only plaintext conversion switch.
        if ($null -eq $secure) {
            if ($AllowBlank) { return "" }
            Write-Host "A value is required." -ForegroundColor Yellow
            continue
        }

        $ptr = [IntPtr]::Zero
        $plain = ""
        try {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
            if ($null -eq $plain) { $plain = "" }
        }
        finally {
            if ($ptr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
            }
        }

        if ($AllowBlank -or -not [string]::IsNullOrWhiteSpace($plain)) {
            return [string]$plain
        }

        Write-Host "A value is required." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkYellow
Write-Host "TAUTWEEKLY FOR PLEX NAS PORTABLE SETUP" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor DarkYellow
Write-Host ""
Write-Host "This wizard writes /data/config.json in the persistent NAS volume."
Write-Host "It does not send email. Automatic scheduling defaults to disabled."
Write-Host ""

New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null

$defaults = Get-Content -Path $examplePath -Raw -Encoding UTF8 | ConvertFrom-Json
if (Test-Path $configPath) {
    Write-Host "An existing config.json was found:" -ForegroundColor Yellow
    Write-Host "  $configPath"
    if (-not (Read-YesNo "Replace it with a new configuration?" $false)) {
        Write-Host "Existing config preserved. Run ./tautweekly.sh verify next." -ForegroundColor Green
        exit 0
    }
    $backup = Join-Path $DataRoot ("config.backup.{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Copy-Item $configPath $backup -Force
    Write-Host "Backup created: $backup"
}

Write-Host ""
Write-Host "Tautulli connection" -ForegroundColor Cyan
Write-Host "For a Tautulli container with port 8181 published, use the QNAP LAN IP,"
Write-Host "for example http://media.example.test:8181. Do not use 127.0.0.1."
$tautulliUrl = Read-Default "Tautulli URL" ([string]$defaults.TautulliUrl)
$apiKey = Read-Default "Tautulli API key"
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw "Tautulli API key is required." }

$serverName = Read-Default "Plex server/newsletter display name" "My Plex"
$serverLabel = Read-Default "Small header label" "PLEX"
$plexWebUrl = Read-Default "Open Plex button URL" "https://app.plex.tv/desktop/"

Write-Host ""
Write-Host "Optional direct Plex connection" -ForegroundColor Cyan
Write-Host "Supplying these improves clearLogo and direct metadata support."
$plexServerUrl = Read-Default "Direct Plex URL, e.g. http://media.example.test:32400"
$plexToken = Read-SecretPlainText "Plex token (optional; press Enter to use Tautulli fallbacks)" $true

Write-Host ""
Write-Host "SMTP / sender" -ForegroundColor Cyan
$fromName = Read-Default "From display name" "$serverName Newsletter"
$fromEmail = Read-Default "From email address"
if ([string]::IsNullOrWhiteSpace($fromEmail)) { throw "From email is required." }
$replyTo = Read-Default "Reply-To address" $fromEmail
$smtpHost = Read-Default "SMTP host"
if ([string]::IsNullOrWhiteSpace($smtpHost)) { throw "SMTP host is required." }
$smtpPortText = Read-Default "SMTP STARTTLS port" "587"
[int]$smtpPort = 0
if (-not [int]::TryParse($smtpPortText, [ref]$smtpPort) -or $smtpPort -lt 1 -or $smtpPort -gt 65535) {
    throw "SMTP port must be between 1 and 65535."
}
if ($smtpPort -eq 465) {
    throw "Port 465 uses implicit SMTPS. Use your provider's STARTTLS port, commonly 587."
}
$smtpSsl = Read-YesNo "Use STARTTLS/TLS?" $true
$smtpAuth = Read-YesNo "Does the SMTP server require username/password authentication?" $true
$smtpUsername = ""
$smtpPassword = ""
$stripPasswordSpaces = $false
if ($smtpAuth) {
    $smtpUsername = Read-Default "SMTP username" $fromEmail
    $smtpPassword = Read-SecretPlainText "SMTP password / app password"
    $stripPasswordSpaces = Read-YesNo "Strip whitespace from the SMTP password?" $false
}
$testEmail = Read-Default "Test-email recipient" $fromEmail

Write-Host ""
Write-Host "Weekly schedule" -ForegroundColor Cyan
$scheduleDay = Read-Default "Weekly send day" "Friday"
$validDays = @("Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday")
$canonicalDay = $validDays | Where-Object { $_ -ieq $scheduleDay } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($canonicalDay)) {
    throw "Schedule day is invalid."
}
$scheduleTime = Read-Default "Local container send time (24-hour HH:mm)" "09:30"
$tempTime = [DateTime]::MinValue
if (-not [DateTime]::TryParseExact($scheduleTime, "HH:mm", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$tempTime)) {
    throw "ScheduleTime must use HH:mm, for example 09:30."
}
$scheduleGrace = [int](Read-Default "Schedule grace window in minutes" "60")
if ($scheduleGrace -lt 1 -or $scheduleGrace -gt 720) { throw "Grace window must be 1-720 minutes." }
$scheduleEnabled = Read-YesNo "Enable automatic weekly sending now? Enable only after tests pass." $false

$config = [ordered]@{
    TautulliUrl = $tautulliUrl.TrimEnd('/')
    ApiKey = $apiKey
    ServerLabel = $serverLabel
    FooterServerName = $serverName
    PlexWebUrl = $plexWebUrl
    PlexServerUrl = $plexServerUrl
    PlexToken = $plexToken
    FromName = $fromName
    FromEmail = $fromEmail
    ReplyToEmail = $replyTo
    SmtpHost = $smtpHost
    SmtpPort = $smtpPort
    SmtpEnableSsl = $smtpSsl
    SmtpUseAuthentication = $smtpAuth
    SmtpUsername = $smtpUsername
    SmtpPassword = $smtpPassword
    SmtpStripPasswordSpaces = $stripPasswordSpaces
    TestEmail = $testEmail
    TestSendDelaySeconds = 2
    SendDelaySeconds = 10
    ScheduleEnabled = $scheduleEnabled
    ScheduleDay = $canonicalDay
    ScheduleTime = $scheduleTime
    ScheduleGraceMinutes = $scheduleGrace
    SchedulerPollSeconds = 30
    DaysBack = 7
    WatchedPercent = 85
    MinimumEpisodeSeconds = 120
    MaxMovies = 8
    MaxTv = 8
    ExcludedUserIds = @()
    ExcludedEmails = @()
    RecentAccessDays = 7
}

$config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8
try { & /bin/chmod 600 $configPath 2>$null } catch { }

Write-Host ""
Write-Host "Configuration created successfully:" -ForegroundColor Green
Write-Host "  $configPath"
Write-Host ""
Write-Host "IMPORTANT: config.json contains credentials. Never publish or share it."
Write-Host "NEXT: ./tautweekly.sh verify"
