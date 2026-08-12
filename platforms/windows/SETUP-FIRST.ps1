Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "TautWeekly for Plex Portable setup is supported on Windows only."
}
if ($PSVersionTable.PSVersion -lt [Version]"5.1") {
    throw "TautWeekly for Plex Portable requires Windows PowerShell 5.1 or newer. Found $($PSVersionTable.PSVersion)."
}

$root = $PSScriptRoot
$configPath = Join-Path $root "config.json"
$examplePath = Join-Path $root "config.example.json"
. (Join-Path $root "User-Exclusions.ps1")
. (Join-Path $root "Library-Selection.ps1")

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
        # without relying on ConvertFrom-SecureString -AsPlainText.
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
Write-Host "TAUTWEEKLY FOR PLEX PORTABLE SETUP" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor DarkYellow
Write-Host ""
Write-Host "This wizard writes config.json in this folder."
Write-Host "It does not send email and does not change Task Scheduler."
Write-Host ""

$existingExcludedUserIds = @()
$existingExcludedEmails = @()
$existingIncludedLibraryIds = @()
$existingDeletedItemCacheEnabled = $true
$existingDeletedItemCacheRetentionDays = 365
$existingDeletedItemCacheMaxItems = 1000
$existingDeletedItemCacheMaxBytesMB = 256
if (Test-Path $configPath) {
    Write-Host "An existing config.json was found:" -ForegroundColor Yellow
    Write-Host "  $configPath"
    if (-not (Read-YesNo "Replace it with a new configuration?" $false)) {
        Write-Host "Existing config preserved. Run 01-VERIFY-SETUP.bat next." -ForegroundColor Green
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
    }
    catch {
        Write-Host "WARNING: Existing user exclusions and library selection could not be read and will not be carried forward." -ForegroundColor Yellow
    }
    $backup = Join-Path $root ("config.backup.{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Copy-Item $configPath $backup -Force
    Write-Host "Backup created: $backup"
}

$tautulliUrl = Read-Default "Tautulli URL" "http://127.0.0.1:8181"
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
        Write-Host "Existing newsletter library selection will be preserved. Run 15-MANAGE-LIBRARIES.bat after verification." -ForegroundColor Yellow
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
    Write-Host "Setup will continue. Run 14-MANAGE-USER-EXCLUSIONS.bat after verification." -ForegroundColor Yellow
}

$serverName = Read-Default "Plex server/newsletter display name" "My Plex"
$serverLabel = Read-Default "Small header label" "PLEX"
$plexWebUrl = Read-Default "Open Plex button URL" "https://app.plex.tv/desktop/"

Write-Host ""
Write-Host "Recommended direct Plex settings" -ForegroundColor Cyan
Write-Host "Tautulli supplies core activity and fallback metadata. Direct Plex can expose provider-"
Write-Host "labelled movie ratings retained by Plex, exact-episode IMDb, backgrounds, and selected"
Write-Host "logos. For movie RT output, set each Plex Movie library's Advanced > Ratings Source to"
Write-Host "Rotten Tomatoes, then refresh affected metadata. This is library-wide."
Write-Host "Enter both direct values for predictable results,"
Write-Host "especially when Plex is remote or the scheduled task runs as SYSTEM. Leaving them blank"
Write-Host "uses best-effort Windows/Tautulli discovery and may limit the newsletter to flattened"
Write-Host "Tautulli ratings. Verification tests the resolved connection without printing the token."
$plexServerUrl = Read-Default "Direct Plex server URL, e.g. http://plex.example.test:32400"
$plexToken = Read-SecretPlainText "Plex token (optional; press Enter for auto-discovery)" $true

Write-Host ""
Write-Host "SMTP / sender settings" -ForegroundColor Cyan
$fromName = Read-Default "From display name" "$serverName Newsletter"
$fromEmail = Read-Default "From email address"
if ([string]::IsNullOrWhiteSpace($fromEmail)) { throw "From email is required." }
$replyTo = Read-Default "Reply-To address" $fromEmail
$smtpHost = Read-Default "SMTP host"
if ([string]::IsNullOrWhiteSpace($smtpHost)) { throw "SMTP host is required." }
$smtpPortText = Read-Default "SMTP port" "587"
[int]$smtpPort = 0
if (-not [int]::TryParse($smtpPortText, [ref]$smtpPort) -or $smtpPort -lt 1 -or $smtpPort -gt 65535) {
    throw "SMTP port must be between 1 and 65535."
}
$smtpSsl = Read-YesNo "Use SMTP TLS/SSL (STARTTLS for port 587)?" $true
if ($smtpPort -eq 465) {
    throw "Port 465 uses implicit SMTPS, which System.Net.Mail.SmtpClient does not support. Use your provider's STARTTLS port (commonly 587) or a compatible relay."
}
$smtpAuth = Read-YesNo "Does this SMTP server require username/password authentication?" $true
$smtpUsername = ""
$smtpPassword = ""
$stripPasswordSpaces = $false
if ($smtpAuth) {
    $smtpUsername = Read-Default "SMTP username" $fromEmail
    $smtpPassword = Read-SecretPlainText "SMTP password / app password"
    $stripPasswordSpaces = Read-YesNo "Strip whitespace from the SMTP password? (Useful for spaced Google app passwords)" $false
}
$testEmail = Read-Default "Test-email recipient" $fromEmail

Write-Host ""
Write-Host "Schedule" -ForegroundColor Cyan
$scheduleDay = Read-Default "Weekly send day" "Friday"
$validDays = @("Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday")
$canonicalDay = $validDays | Where-Object { $_ -ieq $scheduleDay } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($canonicalDay)) {
    throw "ScheduleDay must be Sunday, Monday, Tuesday, Wednesday, Thursday, Friday, or Saturday."
}
$scheduleTime = Read-Default "Weekly local send time (24-hour HH:mm)" "09:30"
$tempTime = [DateTime]::MinValue
if (-not [DateTime]::TryParseExact($scheduleTime, "HH:mm", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$tempTime)) {
    throw "ScheduleTime must use 24-hour HH:mm format, for example 09:30 or 18:45."
}
$taskName = Read-Default "Windows scheduled-task name" "TautWeekly for Plex Newsletter"

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
    SmtpAuthenticationMethod = "Auto"
    SmtpTimeoutSeconds = 30
    TestEmail = $testEmail
    TestSendDelaySeconds = 2
    SendDelaySeconds = 10
    ScheduleDay = $canonicalDay
    ScheduleTime = $scheduleTime
    ScheduledTaskName = $taskName
    DaysBack = 7
    WatchedPercent = 85
    MinimumEpisodeSeconds = 120
    MaxMovies = 8
    MaxTv = 8
    DeletedItemCacheEnabled = $existingDeletedItemCacheEnabled
    DeletedItemCacheRetentionDays = $existingDeletedItemCacheRetentionDays
    DeletedItemCacheMaxItems = $existingDeletedItemCacheMaxItems
    DeletedItemCacheMaxBytesMB = $existingDeletedItemCacheMaxBytesMB
    IncludedLibraryIds = @($includedLibraryIds)
    ExcludedUserIds = @($excludedUserIds)
    ExcludedEmails = @($existingExcludedEmails)
    RecentAccessDays = 7
}

$config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8

# Best-effort credential-file hardening for NTFS. The scheduled task runs as
# SYSTEM, so retain access for the current user, SYSTEM, and local Administrators.
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = $identity.User
    $systemSid = New-Object -TypeName Security.Principal.SecurityIdentifier -ArgumentList "S-1-5-18"
    $adminsSid = New-Object -TypeName Security.Principal.SecurityIdentifier -ArgumentList "S-1-5-32-544"

    $acl = Get-Acl -Path $configPath
    # Stop inheriting broad folder permissions. Existing inherited rules are
    # removed; explicit rules are retained, then the three required principals
    # are granted FullControl.
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($currentSid, $systemSid, $adminsSid)) {
        $rule = New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.SetAccessRule($rule)
    }
    Set-Acl -Path $configPath -AclObject $acl
    Write-Host "Credential-file permissions restricted to your account, SYSTEM, and local Administrators." -ForegroundColor DarkGreen
}
catch {
    Write-Host "WARNING: Could not tighten config.json file permissions automatically: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Protect config.json manually because it contains credentials." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Configuration created successfully:" -ForegroundColor Green
Write-Host "  $configPath"
Write-Host ""
Write-Host "IMPORTANT: config.json contains your SMTP credential and possibly Plex token."
Write-Host "Do not publish or share config.json."
Write-Host ""
Write-Host "NEXT: run 01-VERIFY-SETUP.bat"
