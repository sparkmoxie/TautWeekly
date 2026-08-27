[CmdletBinding()]
param(
    [string]$DataRoot = "",
    [ValidateSet("Status","SetPersistenceProbe","VerifyPersistenceProbe","ClearPersistenceProbe")]
    [string]$Action = "Status",
    [switch]$VerifyArtworkHashes,
    [ValidateSet("","movie","show")]
    [string]$ProbeMediaType = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:CacheDiagnosticLogs = New-Object System.Collections.Generic.List[string]

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $script:CacheDiagnosticLogs.Add("[$Level] cache-event")
}

function Get-OptionalStringProperty {
    param([AllowNull()][object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return "" }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return "" }
    return [string]$property.Value
}

function Safe-Int64 {
    param([AllowNull()][object]$Value)
    [int64]$parsed = 0
    if ($null -ne $Value) { [void][int64]::TryParse([string]$Value, [ref]$parsed) }
    return $parsed
}

function Write-CacheDiagnosticLine {
    param([string]$Name, [AllowNull()][object]$Value)
    $safeValue = if ($null -eq $Value) { "unavailable" } else { ([string]$Value).ToLowerInvariant() }
    Write-Output ("{0}: {1}" -f $Name, $safeValue)
}

function Get-PersistenceProbeState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "absent" }
    try {
        if ((Get-Item -LiteralPath $Path).Length -gt 4KB) { return "invalid-size" }
        $probe = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()
        if (-not [string]::Equals($probe, "tautweekly-cache-persistence-v1", [StringComparison]::Ordinal)) {
            return "invalid-content"
        }
        return "preserved"
    }
    catch { return "invalid-read" }
}

if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = $PSScriptRoot }
$resolvedRoot = [IO.Path]::GetFullPath($DataRoot)
$configPath = Join-Path $resolvedRoot "config.json"

Write-CacheDiagnosticLine "CacheDiagnosticSchema" 1
Write-CacheDiagnosticLine "ShareSafe" $true
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-CacheDiagnosticLine "Configuration" "missing"
    Write-CacheDiagnosticLine "Enabled" "unknown"
    Write-CacheDiagnosticLine "Available" $false
    Write-CacheDiagnosticLine "Manifest" "unavailable"
    Write-CacheDiagnosticLine "Backup" "unavailable"
    Write-CacheDiagnosticLine "Writability" "not-checked"
    Write-CacheDiagnosticLine "PersistenceProbe" "not-checked"
    return
}

try {
    if ((Get-Item -LiteralPath $configPath).Length -gt 1MB) { throw "bounded configuration check failed" }
    $configuration = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-CacheDiagnosticLine "Configuration" "invalid-or-unreadable"
    Write-CacheDiagnosticLine "Enabled" "unknown"
    Write-CacheDiagnosticLine "Available" $false
    Write-CacheDiagnosticLine "Manifest" "unavailable"
    Write-CacheDiagnosticLine "Backup" "unavailable"
    Write-CacheDiagnosticLine "Writability" "not-checked"
    Write-CacheDiagnosticLine "PersistenceProbe" "not-checked"
    return
}

. (Join-Path $PSScriptRoot "DeletedItemCache.ps1")
$cacheRoot = Join-Path $resolvedRoot "cache/deleted-items"
Initialize-TautWeeklyDeletedItemCache -CacheRoot $cacheRoot -Configuration $configuration
$probePath = Join-Path $cacheRoot ".persistence-probe"
$persistenceState = Get-PersistenceProbeState -Path $probePath

switch ($Action) {
    "SetPersistenceProbe" {
        if ($script:TwDeletedCacheEnabled -and $script:TwDeletedCacheAvailable) {
            $temporaryPath = Join-Path $cacheRoot (".persistence-probe." + [Guid]::NewGuid().ToString("N") + ".tmp")
            try {
                [IO.File]::WriteAllText($temporaryPath, ("tautweekly-cache-persistence-v1" + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
                Move-Item -LiteralPath $temporaryPath -Destination $probePath -Force
                $persistenceState = "created"
            }
            catch { $persistenceState = "failed" }
            finally { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
        else { $persistenceState = "unavailable" }
    }
    "VerifyPersistenceProbe" {
        $persistenceState = Get-PersistenceProbeState -Path $probePath
    }
    "ClearPersistenceProbe" {
        try {
            Remove-Item -LiteralPath $probePath -Force -ErrorAction Stop
            $persistenceState = "cleared"
        }
        catch {
            $persistenceState = if (Test-Path -LiteralPath $probePath) { "failed" } else { "cleared" }
        }
    }
}

$diagnostics = Get-TautWeeklyDeletedItemCacheDiagnostics -VerifyArtworkHashes:$VerifyArtworkHashes
$exactProbe = "not-requested"
if (-not [string]::IsNullOrWhiteSpace($ProbeMediaType)) {
    if (-not $diagnostics.Enabled -or -not $diagnostics.Available) {
        $exactProbe = "unavailable"
    }
    else {
        $secureGuid = Read-Host "Enter the exact Plex metadata GUID (input is hidden and never printed)" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureGuid)
        try {
            $guid = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            if ([string]::IsNullOrWhiteSpace((Get-TwDeletedCacheStableGuid $guid))) { $exactProbe = "invalid" }
            elseif ($null -ne (Get-TautWeeklyDeletedItemCacheEntry -MediaType $ProbeMediaType -MetadataGuid $guid)) { $exactProbe = "hit" }
            else { $exactProbe = "miss" }
        }
        finally {
            if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            $guid = $null
            $secureGuid.Dispose()
        }
    }
}

Write-CacheDiagnosticLine "Configuration" "valid"
Write-CacheDiagnosticLine "Enabled" $diagnostics.Enabled
Write-CacheDiagnosticLine "Available" $diagnostics.Available
Write-CacheDiagnosticLine "Manifest" $diagnostics.ManifestState
Write-CacheDiagnosticLine "Backup" $diagnostics.BackupState
Write-CacheDiagnosticLine "Writability" $diagnostics.Writability
Write-CacheDiagnosticLine "Integrity" $diagnostics.Integrity
Write-CacheDiagnosticLine "Entries" $diagnostics.ItemCount
Write-CacheDiagnosticLine "ArtworkFiles" $diagnostics.ArtworkCount
Write-CacheDiagnosticLine "ArtworkBytes" $diagnostics.ArtworkBytes
Write-CacheDiagnosticLine "MissingArtwork" $diagnostics.MissingArtworkCount
Write-CacheDiagnosticLine "OrphanArtwork" $diagnostics.OrphanArtworkCount
Write-CacheDiagnosticLine "ArtworkSizeMismatches" $diagnostics.ArtworkSizeMismatchCount
Write-CacheDiagnosticLine "HashMismatches" $diagnostics.HashMismatchCount
Write-CacheDiagnosticLine "ExpiredEntries" $diagnostics.ExpiredEntryCount
Write-CacheDiagnosticLine "RetentionDays" $diagnostics.RetentionDays
Write-CacheDiagnosticLine "MaxItems" $diagnostics.MaxItems
Write-CacheDiagnosticLine "MaxBytes" $diagnostics.MaxBytes
Write-CacheDiagnosticLine "ExactGuidProbe" $exactProbe
Write-CacheDiagnosticLine "PersistenceProbe" $persistenceState
