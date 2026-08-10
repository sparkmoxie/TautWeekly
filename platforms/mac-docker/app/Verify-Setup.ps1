param(
    [string]$DataRoot = $(if ($env:TAUTWEEKLY_DATA_DIR) { $env:TAUTWEEKLY_DATA_DIR } else { "/data" })
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$configPath = Join-Path $DataRoot "config.json"
$assetsDir = Join-Path $DataRoot "assets"
$previewAssetsDir = Join-Path (Join-Path $DataRoot "output") "assets"
. (Join-Path $PSScriptRoot "Library-Selection.ps1")
. (Join-Path $PSScriptRoot "Schedule-Time.ps1")

function OK([string]$Text) { Write-Host "[OK]   $Text" -ForegroundColor Green }
function WARN([string]$Text) { Write-Host "[WARN] $Text" -ForegroundColor Yellow }
function FAIL([string]$Text) { Write-Host "[FAIL] $Text" -ForegroundColor Red }

Write-Host ""
Write-Host "TAUTWEEKLY FOR PLEX MAC SETUP VERIFICATION" -ForegroundColor Cyan
Write-Host "================================="

if ($PSVersionTable.PSVersion -lt [Version]"7.2") {
    FAIL "PowerShell 7.2 or newer is required. Found $($PSVersionTable.PSVersion)."
    exit 1
}
OK "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

if (-not $IsLinux) {
    FAIL "This package is designed for a Linux container."
    exit 1
}
OK "Linux container detected ($([Runtime.InteropServices.RuntimeInformation]::OSArchitecture))"

foreach ($cmd in @("identify","convert","python3","flock")) {
    if ($null -eq (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        FAIL "$cmd is missing from the container image."
        exit 1
    }
}
OK "ImageMagick, Python preview server, and file locking are available"

if (-not (Test-Path $configPath)) {
    FAIL "config.json is missing. Run ./tautweekly.sh setup."
    exit 1
}
OK "config.json exists"

try { $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { FAIL "config.json is invalid JSON: $($_.Exception.Message)"; exit 1 }
OK "config.json parses correctly"

try {
    $mode = [System.IO.File]::GetUnixFileMode($configPath)
    $groupOrOther = $mode -band (
        [System.IO.UnixFileMode]::GroupRead -bor [System.IO.UnixFileMode]::GroupWrite -bor [System.IO.UnixFileMode]::GroupExecute -bor
        [System.IO.UnixFileMode]::OtherRead -bor [System.IO.UnixFileMode]::OtherWrite -bor [System.IO.UnixFileMode]::OtherExecute
    )
    if ($groupOrOther -eq 0) { OK "config.json permissions are private" }
    else { WARN "config.json is accessible to group/other users. Run: chmod 600 data/config.json" }
}
catch { WARN "Could not inspect Unix permissions for config.json." }

function Get-Prop([string]$Name) {
    $p = $config.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

foreach ($prop in @("TautulliUrl","ApiKey","FromName","FromEmail","SmtpHost","SmtpPort","TestEmail")) {
    $value = Get-Prop $prop
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value) -or [string]$value -match '^PASTE_') {
        FAIL "$prop is missing or still contains a placeholder."
        exit 1
    }
}
OK "Required configuration values are populated"

if ([string]$config.SmtpHost -ieq "smtp.example.com" -or
    [string]$config.FromEmail -match '@example\.com$' -or
    [string]$config.TestEmail -match '@example\.com$') {
    FAIL "Example mail settings remain in config.json."
    exit 1
}
OK "Example email placeholders were replaced"

foreach ($emailProp in @("FromEmail","TestEmail","ReplyToEmail")) {
    $value = [string](Get-Prop $emailProp)
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    try { [void](New-Object System.Net.Mail.MailAddress($value)) }
    catch { FAIL "$emailProp is not a valid email address: $value"; exit 1 }
}
OK "Configured email addresses are syntactically valid"

$smtpAuth = $true
if ($null -ne $config.PSObject.Properties["SmtpUseAuthentication"]) { $smtpAuth = [bool]$config.SmtpUseAuthentication }
if ($smtpAuth) {
    if ([string]::IsNullOrWhiteSpace([string](Get-Prop "SmtpUsername"))) { FAIL "SMTP username is blank."; exit 1 }
    $password = [string](Get-Prop "SmtpPassword")
    if ([string]::IsNullOrWhiteSpace($password) -or $password -match '^PASTE_') { FAIL "SMTP password is missing."; exit 1 }
    OK "SMTP credentials are configured"
}
else { OK "SMTP authentication is disabled" }

try {
    $base = ([string]$config.TautulliUrl).TrimEnd('/')
    if ($base -match '127\.0\.0\.1|localhost') {
        WARN "TautulliUrl points to localhost inside the container. Use host.docker.internal for a Mac-host service, a shared-network container name, or another reachable LAN address."
    }
    $key = [Uri]::EscapeDataString([string]$config.ApiKey)
    $info = Invoke-RestMethod -Uri "$base/api/v2?apikey=$key&cmd=get_tautulli_info" -TimeoutSec 20
    if ([string]$info.response.result -ne "success") { throw $info.response.message }
    $version = [string]$info.response.data.tautulli_version
    if ([string]::IsNullOrWhiteSpace($version)) { $version = "version not reported" }
    OK "Tautulli API works ($version)"

    $users = Invoke-RestMethod -Uri "$base/api/v2?apikey=$key&cmd=get_user_names" -TimeoutSec 20
    if ([string]$users.response.result -ne "success") { throw $users.response.message }
    OK "Tautulli user lookup works ($(@($users.response.data).Count) users found)"

    $libraries = @(Get-TautWeeklySelectableLibraries -TautulliUrl $base -ApiKey ([string]$config.ApiKey))
    $selectableLibraries = @($libraries | Where-Object { $_.Selectable })
    if ($selectableLibraries.Count -eq 0) { throw "Tautulli did not report any active movie or TV libraries." }
    $configuredLibraryIds = @()
    if ($null -ne $config.PSObject.Properties["IncludedLibraryIds"]) {
        $configuredLibraryIds = @(Get-TautWeeklyUniqueLibraryIds -Values @($config.IncludedLibraryIds))
    }
    if ($configuredLibraryIds.Count -eq 0) {
        WARN "IncludedLibraryIds is empty or absent; legacy all-library scope is active ($($selectableLibraries.Count) libraries)."
    }
    else {
        $availableIds = @($selectableLibraries | ForEach-Object { $_.SectionId })
        $matchedIds = @($configuredLibraryIds | Where-Object { $availableIds -contains $_ })
        $staleIds = @($configuredLibraryIds | Where-Object { $availableIds -notcontains $_ })
        if ($matchedIds.Count -eq 0) { throw "None of the configured IncludedLibraryIds match an active movie or TV library. Run ./tautweekly.sh manage-libraries." }
        OK "Global library scope matches $($matchedIds.Count) active movie/TV libraries"
        if ($staleIds.Count -gt 0) { WARN ("Configured library IDs no longer available: " + ($staleIds -join ", ")) }
    }
}
catch { FAIL "Tautulli API verification failed: $($_.Exception.Message)"; exit 1 }

try {
    $smtpPort = [int]$config.SmtpPort
    if ($smtpPort -eq 465) { throw "Implicit SMTPS port 465 is not supported; use STARTTLS, commonly port 587." }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect([string]$config.SmtpHost, $smtpPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(5000, $false)) { throw "Connection timed out after 5 seconds." }
        $client.EndConnect($async)
    }
    finally { $client.Dispose() }
    OK "SMTP host is reachable at $($config.SmtpHost):$smtpPort"
    WARN "SMTP authentication and sender authorization are not tested by verify. Run SendTest with a numeric UserId before enabling the schedule."
}
catch { FAIL "SMTP reachability failed: $($_.Exception.Message)"; exit 1 }

$validDays = @("Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday")
$day = [string](Get-Prop "ScheduleDay"); if ([string]::IsNullOrWhiteSpace($day)) { $day = "Friday" }
if (-not ($validDays | Where-Object { $_ -ieq $day })) { FAIL "ScheduleDay '$day' is invalid."; exit 1 }
$time = [string](Get-Prop "ScheduleTime"); if ([string]::IsNullOrWhiteSpace($time)) { $time = "09:30" }
$parsed = [DateTime]::MinValue
if (-not [DateTime]::TryParseExact($time, "HH:mm", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
    FAIL "ScheduleTime '$time' must use HH:mm."
    exit 1
}
$enabled = $false
if ($null -ne $config.PSObject.Properties["ScheduleEnabled"]) { $enabled = [bool]$config.ScheduleEnabled }
try {
    $scheduleTimeZone = Get-TautWeeklyScheduleTimeZone
    $scheduleNow = Get-TautWeeklyScheduleNow -TimeZone $scheduleTimeZone
    OK "Schedule: enabled=$enabled; $day at $time; time zone=$($scheduleTimeZone.Id); scheduler-local now=$($scheduleNow.ToString('o'))"
}
catch {
    FAIL $_.Exception.Message
    exit 1
}

function Get-FrameCount([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }

    try {
        # ImageMagick evaluates the format once per GIF frame. The previous
        # "%n" call emitted values with no delimiter (for example 121212...),
        # which overflowed [int] and was incorrectly reported as unreadable.
        $rawLines = @(& identify -format "%n\n" $Path 2>$null)
        if ($LASTEXITCODE -ne 0) { return 0 }

        $values = New-Object System.Collections.Generic.List[int]
        foreach ($line in $rawLines) {
            foreach ($token in ([string]$line -split '\s+')) {
                [int]$parsed = 0
                if ([int]::TryParse($token, [ref]$parsed)) {
                    $values.Add($parsed)
                }
            }
        }

        if ($values.Count -eq 0) { return 0 }
        return ($values | Measure-Object -Maximum).Maximum
    }
    catch {
        return 0
    }
}

$animated = @("movies.gif","tv.gif","clock.gif","trophy.gif","hot.gif","trending.gif","pending.gif","quiet.gif","welcome.gif","action.gif","watched.gif","lockinfo.gif","watchlist.gif","popcorn.gif")
$assetFailure = $false
foreach ($name in $animated) {
    $frames = Get-FrameCount (Join-Path $assetsDir $name)
    if ($frames -gt 1) { OK "$name is animated ($frames frames)" }
    elseif ($frames -eq 1) { FAIL "$name is static; expected animated GIF"; $assetFailure = $true }
    else { FAIL "$name is missing/unreadable"; $assetFailure = $true }
}
foreach ($name in @("rt_ripe.png","rt_rotten.png","rt_upright.png","rt_spilled.png","imdb.png")) {
    $path = Join-Path $assetsDir $name
    if ((Test-Path $path) -and (Get-Item $path).Length -gt 100) { OK "$name is present" }
    else { FAIL "$name is missing/invalid"; $assetFailure = $true }
}
if ($assetFailure) { exit 1 }

$mirrorFailure = $false
foreach ($name in ($animated + @("rt_ripe.png","rt_rotten.png","rt_upright.png","rt_spilled.png","imdb.png"))) {
    $path = Join-Path $previewAssetsDir $name
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 100) {
        OK "preview asset mirror contains $name"
    }
    else {
        FAIL "preview asset mirror is missing $name"
        $mirrorFailure = $true
    }
}
if ($mirrorFailure) {
    WARN "Run ./tautweekly.sh repair-assets, then verify again."
    exit 1
}

try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:8080/assets/movies.gif" -Method Head -TimeoutSec 5
    if ([int]$response.StatusCode -ne 200) {
        throw "HTTP status $([int]$response.StatusCode)"
    }
    OK "preview web server serves /assets/movies.gif"
}
catch {
    FAIL "preview asset web check failed: $($_.Exception.Message)"
    WARN "Inspect ./tautweekly.sh logs and confirm the container was recreated from v1.1.0."
    exit 1
}

Write-Host ""
OK "TautWeekly for Plex Mac Portable is ready for preview and test email."
Write-Host "SAFE NEXT STEPS:" -ForegroundColor Cyan
Write-Host "  ./tautweekly.sh list-users"
Write-Host "  ./tautweekly.sh preview-all"
Write-Host "  ./tautweekly.sh send-test-all"
