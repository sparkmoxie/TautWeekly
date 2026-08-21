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
. (Join-Path $PSScriptRoot "User-Exclusions.ps1")
. (Join-Path $PSScriptRoot "Library-Selection.ps1")
. (Join-Path $PSScriptRoot "Configuration-Backups.ps1")

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

function Get-ExistingBooleanValue {
    param([object]$Value, [bool]$Default)

    if ($Value -is [bool]) { return [bool]$Value }
    $parsed = $false
    if ($null -ne $Value -and [bool]::TryParse(([string]$Value).Trim(), [ref]$parsed)) { return $parsed }
    return $Default
}

function Get-ExistingBoundedInteger {
    param([object]$Value, [int]$Default, [int]$Minimum, [int]$Maximum)

    $parsed = 0
    if ($null -ne $Value -and [int]::TryParse(([string]$Value).Trim(), [ref]$parsed) -and $parsed -ge $Minimum -and $parsed -le $Maximum) {
        return $parsed
    }
    return $Default
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

function Write-MetadataReadinessChecklist {
    Write-Host ""
    Write-Host "Metadata readiness before Verify, Preview, or TestEmail" -ForegroundColor Cyan
    Write-Host "1. Plex Web: for each included Plex Movie library, confirm Edit > Advanced > Ratings Source."
    Write-Host "2. Plex Web: run Manage Library > Refresh All Metadata for every included movie/TV"
    Write-Host "   library and wait for completion. This can take a long time and can update metadata/artwork."
    Write-Host "3. Tautulli: open each same library > Media Info > Refresh media info and wait."
    Write-Host "   The current Tautulli control is per library, so repeat it for every included library."
    Write-Host "Use this sequence after first install, after changing a Plex agent/Ratings Source, or after"
    Write-Host "a ratings/artwork recovery update when metadata may be stale. Routine TautWeekly updates do"
    Write-Host "not require a full library refresh when current metadata already renders correctly."
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkYellow
Write-Host "TAUTWEEKLY FOR PLEX MAC PORTABLE SETUP" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor DarkYellow
Write-Host ""
Write-Host "This wizard writes /data/config.json in the persistent Docker Desktop volume."
Write-Host "It does not send email. Automatic scheduling defaults to disabled."
Write-Host "Manager Config is the normal Mac setup source; this terminal wizard is an expert recovery fallback."
Write-Host ""

New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null

$defaults = Get-Content -Path $examplePath -Raw -Encoding UTF8 | ConvertFrom-Json
$existingExcludedUserIds = @()
$existingExcludedEmails = @()
$existingIncludedLibraryIds = @()
$existingDeletedItemCacheEnabled = $true
$existingDeletedItemCacheRetentionDays = 365
$existingDeletedItemCacheMaxItems = 1000
$existingDeletedItemCacheMaxBytesMB = 256
$existingCustomTextCardEnabled = $false
$existingCustomTextCardBorderColor = '#72aef7'
$existingCustomTextCardBorderOpacity = 34
$existingCustomTextCardTitle = ''
$existingCustomTextCardTitleGif = 'none'
$existingCustomTextCardSubheading = ''
$existingCustomTextCardBody = ''
if (Test-Path $configPath) {
    Write-Host "An existing config.json was found:" -ForegroundColor Yellow
    Write-Host "  $configPath"
    if (-not (Read-YesNo "Replace it with a new configuration?" $false)) {
        Write-Host "Existing config preserved." -ForegroundColor Green
        Write-MetadataReadinessChecklist
        Write-Host ""
        Write-Host "NEXT: return to the authenticated Manager at http://localhost:8787/."
        Write-Host "Expert verification fallback: ./tautweekly.sh verify"
        exit 0
    }
    try {
        $existingConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $existingConfig.PSObject.Properties["ExcludedUserIds"]) {
            $existingExcludedUserIds = @($existingConfig.ExcludedUserIds)
        }
        if ($null -ne $existingConfig.PSObject.Properties["ExcludedEmails"]) {
            $existingExcludedEmails = @($existingConfig.ExcludedEmails)
        }
        if ($null -ne $existingConfig.PSObject.Properties["IncludedLibraryIds"]) {
            $existingIncludedLibraryIds = @($existingConfig.IncludedLibraryIds)
        }
        if ($null -ne $existingConfig.PSObject.Properties["DeletedItemCacheEnabled"]) { $existingDeletedItemCacheEnabled = Get-ExistingBooleanValue $existingConfig.DeletedItemCacheEnabled $existingDeletedItemCacheEnabled }
        if ($null -ne $existingConfig.PSObject.Properties["DeletedItemCacheRetentionDays"]) { $existingDeletedItemCacheRetentionDays = Get-ExistingBoundedInteger $existingConfig.DeletedItemCacheRetentionDays $existingDeletedItemCacheRetentionDays 1 3650 }
        if ($null -ne $existingConfig.PSObject.Properties["DeletedItemCacheMaxItems"]) { $existingDeletedItemCacheMaxItems = Get-ExistingBoundedInteger $existingConfig.DeletedItemCacheMaxItems $existingDeletedItemCacheMaxItems 1 10000 }
        if ($null -ne $existingConfig.PSObject.Properties["DeletedItemCacheMaxBytesMB"]) { $existingDeletedItemCacheMaxBytesMB = Get-ExistingBoundedInteger $existingConfig.DeletedItemCacheMaxBytesMB $existingDeletedItemCacheMaxBytesMB 16 2048 }
        if ($null -ne $existingConfig.PSObject.Properties["CustomTextCardEnabled"]) { $existingCustomTextCardEnabled = Get-ExistingBooleanValue $existingConfig.CustomTextCardEnabled $existingCustomTextCardEnabled }
        if ($null -ne $existingConfig.PSObject.Properties["CustomTextCardBorderColor"] -and [string]$existingConfig.CustomTextCardBorderColor -match '^#[0-9a-fA-F]{6}$') { $existingCustomTextCardBorderColor = ([string]$existingConfig.CustomTextCardBorderColor).ToLowerInvariant() }
        if ($null -ne $existingConfig.PSObject.Properties["CustomTextCardBorderOpacity"]) { $existingCustomTextCardBorderOpacity = Get-ExistingBoundedInteger $existingConfig.CustomTextCardBorderOpacity $existingCustomTextCardBorderOpacity 0 100 }
        if ($null -ne $existingConfig.PSObject.Properties["CustomTextCardTitle"]) { $existingCustomTextCardTitle = [string]$existingConfig.CustomTextCardTitle }
        if ($null -ne $existingConfig.PSObject.Properties["CustomTextCardTitleGif"] -and ([string]$existingConfig.CustomTextCardTitleGif).Trim().ToLowerInvariant() -in @('celebrate','construction','rocket','tickets','warning','alert')) { $existingCustomTextCardTitleGif = ([string]$existingConfig.CustomTextCardTitleGif).Trim().ToLowerInvariant() }
        if ($null -ne $existingConfig.PSObject.Properties["CustomTextCardSubheading"]) { $existingCustomTextCardSubheading = [string]$existingConfig.CustomTextCardSubheading }
        if ($null -ne $existingConfig.PSObject.Properties["CustomTextCardBody"]) { $existingCustomTextCardBody = [string]$existingConfig.CustomTextCardBody }
    }
    catch {
        Write-Host "WARNING: Existing user exclusions and library selection could not be read and will not be carried forward." -ForegroundColor Yellow
    }
    $backup = New-TautWeeklyConfigurationBackup -ConfigPath $configPath -Directory $DataRoot
    Write-Host "Backup created: $backup"
}

Write-Host ""
Write-Host "Tautulli connection" -ForegroundColor Cyan
Write-Host "For Tautulli running directly on this Mac, use http://host.docker.internal:8181."
Write-Host "For another container on a shared network, use http://tautulli:8181."
Write-Host "For a remote server or NAS, use its LAN address. Do not use 127.0.0.1."
$tautulliUrl = Read-Default "Tautulli URL" ([string]$defaults.TautulliUrl)
$apiKey = Read-Default "Tautulli API key"
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw "Tautulli API key is required." }

$includedLibraryIds = @($existingIncludedLibraryIds)
try {
    $selectableLibraries = @(Get-TautWeeklySelectableLibraries -TautulliUrl $tautulliUrl -ApiKey $apiKey)
    $includedLibraryIds = @(Read-TautWeeklyIncludedLibraryIds -Libraries $selectableLibraries -CurrentIncludedLibraryIds $includedLibraryIds)
}
catch {
    if ($existingIncludedLibraryIds.Count -gt 0) {
        Write-Host "WARNING: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Existing newsletter library selection will be preserved. Run ./tautweekly.sh manage-libraries after verification." -ForegroundColor Yellow
    }
    else {
        throw "Newsletter libraries could not be selected: $($_.Exception.Message)"
    }
}

$excludedUserIds = @($existingExcludedUserIds)
try {
    $selectableUsers = @(Get-TautWeeklySelectableUsers -TautulliUrl $tautulliUrl -ApiKey $apiKey)
    if ($selectableUsers.Count -gt 0) {
        $excludedUserIds = @(Read-TautWeeklyExcludedUserIds -Users $selectableUsers -CurrentExcludedUserIds $excludedUserIds)
    }
    else {
        Write-Host "WARNING: Tautulli returned no users. Existing exclusions will be preserved." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "WARNING: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Setup will continue. Run ./tautweekly.sh exclude-users after verification." -ForegroundColor Yellow
}

$serverName = Read-Default "Plex server/newsletter display name" "My Plex"
$serverLabel = Read-Default "Small header label" "PLEX"
$plexWebUrl = Read-Default "Open Plex button URL or custom link" "https://app.plex.tv/desktop/"
$plexButtonLabel = Read-Default "Button label" "Open Plex"

Write-Host ""
Write-Host "Recommended direct Plex connection" -ForegroundColor Cyan
Write-Host "Tautulli supplies core activity and fallback metadata. Direct Plex can expose provider-"
Write-Host "labelled movie ratings retained by Plex, exact-episode IMDb/RT, backgrounds, and selected"
Write-Host "logos. For movie RT output, set each Plex Movie library's Advanced > Ratings Source to"
Write-Host "Rotten Tomatoes, then refresh affected metadata. This is library-wide."
Write-Host "For Plex on this Mac, use"
Write-Host "http://host.docker.internal:32400; container localhost points to TautWeekly itself."
Write-Host "Leaving either value unresolved uses flattened Tautulli fallbacks and may omit richer"
Write-Host "metadata. Verification tests the resolved connection without printing the token."
$plexServerUrl = Read-Default "Direct Plex URL, e.g. http://host.docker.internal:32400"
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
    PlexButtonLabel = $plexButtonLabel
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
    SmtpAuthenticationMethod = "Auto"
    SmtpTimeoutSeconds = 30
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
    DeletedItemCacheEnabled = $existingDeletedItemCacheEnabled
    DeletedItemCacheRetentionDays = $existingDeletedItemCacheRetentionDays
    DeletedItemCacheMaxItems = $existingDeletedItemCacheMaxItems
    DeletedItemCacheMaxBytesMB = $existingDeletedItemCacheMaxBytesMB
    CustomTextCardEnabled = $existingCustomTextCardEnabled
    CustomTextCardBorderColor = $existingCustomTextCardBorderColor
    CustomTextCardBorderOpacity = $existingCustomTextCardBorderOpacity
    CustomTextCardTitle = $existingCustomTextCardTitle
    CustomTextCardTitleGif = $existingCustomTextCardTitleGif
    CustomTextCardSubheading = $existingCustomTextCardSubheading
    CustomTextCardBody = $existingCustomTextCardBody
    IncludedLibraryIds = @($includedLibraryIds)
    ExcludedUserIds = @($excludedUserIds)
    ExcludedEmails = @($existingExcludedEmails)
    RecentAccessDays = 7
}

$config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8
try { & /bin/chmod 600 $configPath 2>$null } catch { }

Write-Host ""
Write-Host "Configuration created successfully:" -ForegroundColor Green
Write-Host "  $configPath"
Write-Host ""
Write-Host "IMPORTANT: config.json contains credentials. Never publish or share it."
Write-MetadataReadinessChecklist
Write-Host ""
Write-Host "NEXT: return to the authenticated Manager at http://localhost:8787/."
Write-Host "Expert verification fallback: ./tautweekly.sh verify"
