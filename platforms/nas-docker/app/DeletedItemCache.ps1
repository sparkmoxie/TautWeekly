Set-StrictMode -Version Latest

# Private, bounded pre-deletion media cache. This module intentionally accepts
# only presentation items and poster paths; configuration secrets, recipients,
# and viewing metrics never cross this boundary.
$script:TwDeletedCacheSchemaVersion = 1
$script:TwDeletedCacheEnabled = $false
$script:TwDeletedCacheAvailable = $false
$script:TwDeletedCacheRoot = ""
$script:TwDeletedCacheAssetRoot = ""
$script:TwDeletedCacheIndexPath = ""
$script:TwDeletedCacheBackupPath = ""
$script:TwDeletedCacheIndex = $null
$script:TwDeletedCacheRetentionDays = 365
$script:TwDeletedCacheMaxItems = 1000
$script:TwDeletedCacheMaxBytes = [int64](256MB)
$script:TwDeletedCacheHitIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:TwDeletedCacheSeenHitIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:TwDeletedCacheSeenMissIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:TwDeletedCacheManifestState = "not-initialized"
$script:TwDeletedCacheWritability = "not-checked"
$script:TwDeletedCacheCaptureAccepted = 0
$script:TwDeletedCacheCaptureSkippedMetadata = 0
$script:TwDeletedCacheCaptureSkippedPoster = 0
$script:TwDeletedCacheCaptureRejectedGuid = 0
$script:TwDeletedCacheCaptureRejectedArtwork = 0
$script:TwDeletedCacheCaptureWriteFailed = 0
$script:TwDeletedCacheInvalidLookups = 0
$script:TwDeletedCacheActivityWritten = $false

function Write-TwDeletedCacheLog {
    param([string]$Message, [string]$Level = "INFO")
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message $Message -Level $Level
    }
    else {
        Write-Warning $Message
    }
}

function Test-TwDeletedCacheWritable {
    $probePath = Join-Path $script:TwDeletedCacheRoot (".cache-write-probe." + [Guid]::NewGuid().ToString("N") + ".tmp")
    $stream = $null
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes("tautweekly-cache-write-probe`n")
        $stream = New-Object IO.FileStream($probePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        try { $stream.Flush($true) } catch { $stream.Flush() }
        $stream.Dispose()
        $stream = $null
        Remove-Item -LiteralPath $probePath -Force
        return $true
    }
    catch { return $false }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
    }
}

function Register-TautWeeklyDeletedItemCacheCaptureSkip {
    param([ValidateSet("metadata","poster")][string]$Reason)
    if ($Reason -eq "metadata") { $script:TwDeletedCacheCaptureSkippedMetadata++ }
    else { $script:TwDeletedCacheCaptureSkippedPoster++ }
}

function Write-TautWeeklyDeletedItemCacheActivitySummary {
    if ($script:TwDeletedCacheActivityWritten) { return }
    $script:TwDeletedCacheActivityWritten = $true
    $itemCount = if ($script:TwDeletedCacheEnabled -and $script:TwDeletedCacheAvailable) { @((Get-TwDeletedCacheIndex).Entries).Count } else { 0 }
    Write-TwDeletedCacheLog ("Deleted-item cache activity: enabled={0}; available={1}; manifest={2}; entries={3}; captures={4}; skipped-metadata={5}; skipped-poster={6}; rejected-guid={7}; rejected-artwork={8}; write-failures={9}; exact-hits={10}; exact-misses={11}; invalid-lookups={12}." -f `
        $script:TwDeletedCacheEnabled.ToString().ToLowerInvariant(),
        $script:TwDeletedCacheAvailable.ToString().ToLowerInvariant(),
        $script:TwDeletedCacheManifestState,
        $itemCount,
        $script:TwDeletedCacheCaptureAccepted,
        $script:TwDeletedCacheCaptureSkippedMetadata,
        $script:TwDeletedCacheCaptureSkippedPoster,
        $script:TwDeletedCacheCaptureRejectedGuid,
        $script:TwDeletedCacheCaptureRejectedArtwork,
        $script:TwDeletedCacheCaptureWriteFailed,
        $script:TwDeletedCacheSeenHitIds.Count,
        $script:TwDeletedCacheSeenMissIds.Count,
        $script:TwDeletedCacheInvalidLookups)
}

function Get-TwDeletedCacheFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $algorithm = $null
    try {
        $stream = [IO.File]::OpenRead((Get-Item -LiteralPath $Path).FullName)
        $algorithm = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $algorithm) { $algorithm.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-TwDeletedCacheConfigInt {
    param(
        [object]$Configuration,
        [string]$Name,
        [int]$Default,
        [int]$Minimum,
        [int]$Maximum
    )

    $value = $Default
    $property = if ($null -ne $Configuration) { $Configuration.PSObject.Properties[$Name] } else { $null }
    if ($null -ne $property) {
        [int]$parsed = 0
        if ([int]::TryParse([string]$property.Value, [ref]$parsed) -and
            $parsed -ge $Minimum -and $parsed -le $Maximum) {
            $value = $parsed
        }
        else {
            Write-TwDeletedCacheLog "Ignored invalid $Name; using the bounded default $Default." "WARN"
        }
    }
    return $value
}

function Get-TwDeletedCacheConfigBool {
    param([object]$Configuration, [string]$Name, [bool]$Default)
    $property = if ($null -ne $Configuration) { $Configuration.PSObject.Properties[$Name] } else { $null }
    if ($null -eq $property) { return $Default }
    try { return [Convert]::ToBoolean($property.Value, [Globalization.CultureInfo]::InvariantCulture) }
    catch {
        Write-TwDeletedCacheLog "Ignored invalid $Name; using the default $Default." "WARN"
        return $Default
    }
}

function New-TwDeletedCacheIndex {
    return [PSCustomObject]@{
        SchemaVersion = $script:TwDeletedCacheSchemaVersion
        UpdatedUtc     = [DateTime]::UtcNow.ToString("o")
        Entries        = @()
    }
}

function Get-TwDeletedCacheStableGuid {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "" }
    $guid = ([string]$Value).Trim()
    if ($guid.Length -gt 512 -or $guid -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://[^\s]+$') { return "" }
    return $guid.ToLowerInvariant()
}

function Get-TwDeletedCacheId {
    param([string]$MediaType, [string]$MetadataGuid)
    $type = ([string]$MediaType).Trim().ToLowerInvariant()
    if ($type -notin @("movie", "show")) { return "" }
    $guid = Get-TwDeletedCacheStableGuid $MetadataGuid
    if ([string]::IsNullOrWhiteSpace($guid)) { return "" }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($type + "|" + $guid)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Read-TwDeletedCacheIndexFile {
    param([string]$Path)
    if ((Get-Item -LiteralPath $Path).Length -gt $script:TwDeletedCacheMaxBytes) {
        throw "Deleted-item cache manifest exceeds the configured whole-cache bound."
    }
    $index = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $index -or
        $null -eq $index.PSObject.Properties["SchemaVersion"] -or
        [int]$index.SchemaVersion -ne $script:TwDeletedCacheSchemaVersion -or
        $null -eq $index.PSObject.Properties["Entries"]) {
        throw "Unsupported or incomplete deleted-item cache schema."
    }
    $entries = @($index.Entries | Where-Object { $null -ne $_ })
    $validEntries = @($entries | Where-Object { Test-TwDeletedCacheEntry $_ })
    if ($validEntries.Count -ne $entries.Count) {
        throw "Deleted-item cache manifest contains an invalid or unsafe entry."
    }
    $index.Entries = $validEntries
    return $index
}

function Test-TwDeletedCacheEntry {
    param([AllowNull()][object]$Entry)
    if ($null -eq $Entry) { return $false }
    $id = Get-OptionalStringProperty $Entry "Id"
    $mediaType = Get-OptionalStringProperty $Entry "MediaType"
    $guid = Get-OptionalStringProperty $Entry "Guid"
    $poster = if ($null -ne $Entry.PSObject.Properties["Poster"]) { $Entry.Poster } else { $null }
    $fileName = Get-OptionalStringProperty $poster "FileName"
    $hash = Get-OptionalStringProperty $poster "Sha256"
    return (
        $id -match '^[0-9a-f]{64}$' -and
        $mediaType -in @("movie", "show") -and
        -not [string]::IsNullOrWhiteSpace((Get-TwDeletedCacheStableGuid $guid)) -and
        $id -eq (Get-TwDeletedCacheId $mediaType $guid) -and
        $fileName -eq ($id + ".jpg") -and
        $hash -match '^[0-9a-f]{64}$'
    )
}

function Move-TwDeletedCacheCorruptManifest {
    if (-not (Test-Path -LiteralPath $script:TwDeletedCacheIndexPath -PathType Leaf)) { return }
    $corruptPath = Join-Path $script:TwDeletedCacheRoot "index.corrupt.json"
    Remove-Item -LiteralPath $corruptPath -Force -ErrorAction SilentlyContinue
    if ((Get-Item -LiteralPath $script:TwDeletedCacheIndexPath).Length -le 1MB) {
        Move-Item -LiteralPath $script:TwDeletedCacheIndexPath -Destination $corruptPath -Force
    }
    else {
        Remove-Item -LiteralPath $script:TwDeletedCacheIndexPath -Force
        Write-TwDeletedCacheLog "Discarded an oversized corrupt cache manifest instead of retaining unbounded data." "WARN"
    }
}

function Restore-TwDeletedCacheBackup {
    param([object]$BackupIndex)
    $corruptPath = Join-Path $script:TwDeletedCacheRoot "index.corrupt.json"
    if (Test-Path -LiteralPath $corruptPath) {
        Remove-Item -LiteralPath $corruptPath -Force -ErrorAction SilentlyContinue
    }
    Move-TwDeletedCacheCorruptManifest
    $restoreTemp = Join-Path $script:TwDeletedCacheRoot ("index.restore." + [Guid]::NewGuid().ToString("N") + ".tmp")
    Copy-Item -LiteralPath $script:TwDeletedCacheBackupPath -Destination $restoreTemp -Force
    [IO.File]::Move($restoreTemp, $script:TwDeletedCacheIndexPath)
    Write-TwDeletedCacheLog "Recovered the deleted-item cache manifest from its last atomic backup." "WARN"
    return $BackupIndex
}

function Get-TwDeletedCacheIndex {
    if ($null -ne $script:TwDeletedCacheIndex) { return $script:TwDeletedCacheIndex }
    if (-not $script:TwDeletedCacheEnabled -or -not $script:TwDeletedCacheAvailable) {
        return (New-TwDeletedCacheIndex)
    }

    try {
        if (Test-Path -LiteralPath $script:TwDeletedCacheIndexPath) {
            try {
                $script:TwDeletedCacheIndex = Read-TwDeletedCacheIndexFile $script:TwDeletedCacheIndexPath
                $script:TwDeletedCacheManifestState = "primary-valid"
                return $script:TwDeletedCacheIndex
            }
            catch {
                if (Test-Path -LiteralPath $script:TwDeletedCacheBackupPath) {
                    try {
                        $backupIndex = Read-TwDeletedCacheIndexFile $script:TwDeletedCacheBackupPath
                        $script:TwDeletedCacheIndex = Restore-TwDeletedCacheBackup $backupIndex
                        $script:TwDeletedCacheManifestState = "backup-recovered"
                        return $script:TwDeletedCacheIndex
                    }
                    catch { }
                }

                Move-TwDeletedCacheCorruptManifest
                Remove-Item -LiteralPath $script:TwDeletedCacheBackupPath -Force -ErrorAction SilentlyContinue
                Write-TwDeletedCacheLog "The deleted-item cache manifest and backup were unreadable; retained one bounded corrupt copy when small enough and started an empty cache." "WARN"
                $script:TwDeletedCacheManifestState = "reset-after-corruption"
            }
        }
        $script:TwDeletedCacheIndex = New-TwDeletedCacheIndex
        if ($script:TwDeletedCacheManifestState -eq "not-initialized") {
            $script:TwDeletedCacheManifestState = "unseeded"
        }
        return $script:TwDeletedCacheIndex
    }
    catch {
        $script:TwDeletedCacheAvailable = $false
        $script:TwDeletedCacheManifestState = "unavailable"
        $script:TwDeletedCacheWritability = "failed"
        Write-TwDeletedCacheLog "Deleted-item cache reads are unavailable for this run: $($_.Exception.Message)" "WARN"
        $script:TwDeletedCacheIndex = New-TwDeletedCacheIndex
        return $script:TwDeletedCacheIndex
    }
}

function Save-TwDeletedCacheIndex {
    if (-not $script:TwDeletedCacheEnabled -or -not $script:TwDeletedCacheAvailable -or
        $null -eq $script:TwDeletedCacheIndex) { return $false }

    $tempPath = Join-Path $script:TwDeletedCacheRoot ("index." + [Guid]::NewGuid().ToString("N") + ".tmp")
    try {
        $script:TwDeletedCacheIndex.SchemaVersion = $script:TwDeletedCacheSchemaVersion
        $script:TwDeletedCacheIndex.UpdatedUtc = [DateTime]::UtcNow.ToString("o")
        $json = $script:TwDeletedCacheIndex | ConvertTo-Json -Depth 12
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json + [Environment]::NewLine)
        $stream = New-Object IO.FileStream($tempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            try { $stream.Flush($true) } catch { $stream.Flush() }
        }
        finally { $stream.Dispose() }

        if (Test-Path -LiteralPath $script:TwDeletedCacheIndexPath) {
            [IO.File]::Replace($tempPath, $script:TwDeletedCacheIndexPath, $script:TwDeletedCacheBackupPath)
        }
        else {
            [IO.File]::Move($tempPath, $script:TwDeletedCacheIndexPath)
        }
        return $true
    }
    catch {
        $script:TwDeletedCacheAvailable = $false
        Write-TwDeletedCacheLog "Deleted-item cache writes are unavailable for this run; newsletter rendering will continue: $($_.Exception.Message)" "WARN"
        return $false
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-TwDeletedCacheEntryDate {
    param([object]$Entry)
    foreach ($name in @("LastSeenUtc", "CreatedUtc")) {
        $value = Get-OptionalStringProperty -InputObject $Entry -Name $name
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            try { return [DateTime]::Parse($value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
            catch { }
        }
    }
    return [DateTime]::MinValue
}

function Invoke-TwDeletedCacheCleanup {
    if (-not $script:TwDeletedCacheEnabled -or -not $script:TwDeletedCacheAvailable) { return }
    $index = Get-TwDeletedCacheIndex
    $entries = @($index.Entries)
    $changed = $false
    $cutoff = [DateTime]::UtcNow.AddDays(-$script:TwDeletedCacheRetentionDays)
    $kept = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $entries) {
        $id = Get-OptionalStringProperty -InputObject $entry -Name "Id"
        $poster = if ($null -ne $entry.PSObject.Properties["Poster"]) { $entry.Poster } else { $null }
        $fileName = Get-OptionalStringProperty -InputObject $poster -Name "FileName"
        $assetPath = if (-not [string]::IsNullOrWhiteSpace($fileName)) { Join-Path $script:TwDeletedCacheAssetRoot $fileName } else { "" }
        if ([string]::IsNullOrWhiteSpace($id) -or
            (Get-TwDeletedCacheEntryDate $entry) -lt $cutoff -or
            [string]::IsNullOrWhiteSpace($assetPath) -or
            -not (Test-Path -LiteralPath $assetPath)) {
            if (-not [string]::IsNullOrWhiteSpace($assetPath)) {
                Remove-Item -LiteralPath $assetPath -Force -ErrorAction SilentlyContinue
            }
            $changed = $true
            continue
        }
        $kept.Add($entry)
    }

    $ordered = @($kept | Sort-Object @{Expression={ Get-TwDeletedCacheEntryDate $_ };Descending=$true}, @{Expression={ Get-OptionalStringProperty $_ "Id" };Descending=$false})
    $contentBudget = [int64][Math]::Max(1MB, ($script:TwDeletedCacheMaxBytes - 1MB))
    [int64]$assetBytes = 0
    [int64]$estimatedManifestBytes = 0
    $bounded = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $ordered) {
        $posterBytes = [int64]0
        if ($null -ne $entry.PSObject.Properties["Poster"]) {
            $posterBytes = [int64](Safe-Int64 (Get-OptionalStringProperty $entry.Poster "Bytes"))
        }
        $entryJson = $entry | ConvertTo-Json -Depth 10 -Compress
        $entryManifestBytes = [int64]([Text.Encoding]::UTF8.GetByteCount($entryJson) * 2)
        if ($bounded.Count -ge $script:TwDeletedCacheMaxItems -or
            ($assetBytes + $posterBytes + $estimatedManifestBytes + $entryManifestBytes) -gt $contentBudget) {
            $fileName = if ($null -ne $entry.PSObject.Properties["Poster"]) { Get-OptionalStringProperty $entry.Poster "FileName" } else { "" }
            if (-not [string]::IsNullOrWhiteSpace($fileName)) {
                Remove-Item -LiteralPath (Join-Path $script:TwDeletedCacheAssetRoot $fileName) -Force -ErrorAction SilentlyContinue
            }
            $changed = $true
            continue
        }
        $assetBytes += $posterBytes
        $estimatedManifestBytes += $entryManifestBytes
        $bounded.Add($entry)
    }

    $referenced = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $bounded) {
        if ($null -ne $entry.PSObject.Properties["Poster"]) {
            [void]$referenced.Add((Get-OptionalStringProperty $entry.Poster "FileName"))
        }
    }
    foreach ($asset in @(Get-ChildItem -LiteralPath $script:TwDeletedCacheAssetRoot -File -ErrorAction SilentlyContinue)) {
        if (-not $referenced.Contains($asset.Name)) {
            Remove-Item -LiteralPath $asset.FullName -Force -ErrorAction SilentlyContinue
            $changed = $true
        }
    }
    foreach ($temp in @(Get-ChildItem -LiteralPath $script:TwDeletedCacheRoot -File -Filter "*.tmp" -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $temp.FullName -Force -ErrorAction SilentlyContinue
    }

    $index.Entries = $bounded.ToArray()
    if ($changed) {
        [void](Save-TwDeletedCacheIndex)
        Write-TwDeletedCacheLog ("Deleted-item cache cleanup retained {0} item(s) and {1} artwork byte(s)." -f $bounded.Count, $assetBytes)
    }
}

function Initialize-TautWeeklyDeletedItemCache {
    param([string]$CacheRoot, [object]$Configuration)

    $script:TwDeletedCacheEnabled = Get-TwDeletedCacheConfigBool $Configuration "DeletedItemCacheEnabled" $true
    $script:TwDeletedCacheRetentionDays = Get-TwDeletedCacheConfigInt $Configuration "DeletedItemCacheRetentionDays" 365 1 3650
    $script:TwDeletedCacheMaxItems = Get-TwDeletedCacheConfigInt $Configuration "DeletedItemCacheMaxItems" 1000 1 10000
    $maxMb = Get-TwDeletedCacheConfigInt $Configuration "DeletedItemCacheMaxBytesMB" 256 16 2048
    $script:TwDeletedCacheMaxBytes = [int64]$maxMb * 1MB
    $script:TwDeletedCacheRoot = [IO.Path]::GetFullPath($CacheRoot)
    $script:TwDeletedCacheAssetRoot = Join-Path $script:TwDeletedCacheRoot "artwork"
    $script:TwDeletedCacheIndexPath = Join-Path $script:TwDeletedCacheRoot "index.json"
    $script:TwDeletedCacheBackupPath = Join-Path $script:TwDeletedCacheRoot "index.backup.json"
    $script:TwDeletedCacheIndex = $null
    $script:TwDeletedCacheHitIds.Clear()
    $script:TwDeletedCacheSeenHitIds.Clear()
    $script:TwDeletedCacheSeenMissIds.Clear()
    $script:TwDeletedCacheManifestState = "not-initialized"
    $script:TwDeletedCacheWritability = "not-checked"
    $script:TwDeletedCacheCaptureAccepted = 0
    $script:TwDeletedCacheCaptureSkippedMetadata = 0
    $script:TwDeletedCacheCaptureSkippedPoster = 0
    $script:TwDeletedCacheCaptureRejectedGuid = 0
    $script:TwDeletedCacheCaptureRejectedArtwork = 0
    $script:TwDeletedCacheCaptureWriteFailed = 0
    $script:TwDeletedCacheInvalidLookups = 0
    $script:TwDeletedCacheActivityWritten = $false
    $script:TwDeletedCacheAvailable = $script:TwDeletedCacheEnabled
    if (-not $script:TwDeletedCacheEnabled) {
        $script:TwDeletedCacheManifestState = "disabled"
        $script:TwDeletedCacheWritability = "not-applicable"
        return
    }

    try {
        New-Item -ItemType Directory -Force -Path $script:TwDeletedCacheAssetRoot | Out-Null
        if (-not (Test-Path -LiteralPath $script:TwDeletedCacheRoot -PathType Container) -or
            -not (Test-Path -LiteralPath $script:TwDeletedCacheAssetRoot -PathType Container)) {
            throw "The deleted-item cache path is not a writable directory."
        }
        if (-not (Test-TwDeletedCacheWritable)) {
            throw "The deleted-item cache directory did not pass its local write probe."
        }
        $script:TwDeletedCacheWritability = "passed"
        [void](Get-TwDeletedCacheIndex)
        Invoke-TwDeletedCacheCleanup
    }
    catch {
        $script:TwDeletedCacheAvailable = $false
        $script:TwDeletedCacheWritability = "failed"
        $script:TwDeletedCacheManifestState = "unavailable"
        Write-TwDeletedCacheLog "Deleted-item cache initialization failed; newsletter rendering will continue: $($_.Exception.Message)" "WARN"
    }
}

function Get-TautWeeklyDeletedItemCacheStatus {
    $index = Get-TwDeletedCacheIndex
    return [PSCustomObject]@{
        Enabled       = $script:TwDeletedCacheEnabled
        Available     = $script:TwDeletedCacheAvailable
        SchemaVersion = $script:TwDeletedCacheSchemaVersion
        Root          = $script:TwDeletedCacheRoot
        ManifestState = $script:TwDeletedCacheManifestState
        Writability   = $script:TwDeletedCacheWritability
        RetentionDays = $script:TwDeletedCacheRetentionDays
        MaxItems      = $script:TwDeletedCacheMaxItems
        MaxBytes      = $script:TwDeletedCacheMaxBytes
        ItemCount     = @($index.Entries).Count
    }
}

function Get-TautWeeklyDeletedItemCacheDiagnostics {
    param([switch]$VerifyArtworkHashes)

    $index = Get-TwDeletedCacheIndex
    $backupState = if (-not $script:TwDeletedCacheEnabled) { "not-applicable" } elseif (-not $script:TwDeletedCacheAvailable) { "unavailable" } else { "missing" }
    if ($script:TwDeletedCacheEnabled -and $script:TwDeletedCacheAvailable -and (Test-Path -LiteralPath $script:TwDeletedCacheBackupPath -PathType Leaf)) {
        try {
            [void](Read-TwDeletedCacheIndexFile -Path $script:TwDeletedCacheBackupPath)
            $backupState = "valid"
        }
        catch { $backupState = "invalid" }
    }
    if ($script:TwDeletedCacheManifestState -eq "unseeded" -and $backupState -eq "valid") {
        $backupState = "stale-ignored"
    }
    $integrityState = if (-not $script:TwDeletedCacheEnabled) { "not-applicable" } elseif (-not $script:TwDeletedCacheAvailable) { "unavailable" } elseif ($VerifyArtworkHashes) { "hash-verified" } else { "structural" }
    $referenced = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [int64]$artworkBytes = 0
    [int]$missing = 0
    [int]$orphaned = 0
    [int]$sizeMismatch = 0
    [int]$hashMismatch = 0
    [int]$expired = 0
    $cutoff = [DateTime]::UtcNow.AddDays(-$script:TwDeletedCacheRetentionDays)

    foreach ($entry in @($index.Entries)) {
        $fileName = if ($null -ne $entry.PSObject.Properties["Poster"]) { Get-OptionalStringProperty $entry.Poster "FileName" } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($fileName)) { [void]$referenced.Add($fileName) }
        $assetPath = if (-not [string]::IsNullOrWhiteSpace($fileName)) { Join-Path $script:TwDeletedCacheAssetRoot $fileName } else { "" }
        if ([string]::IsNullOrWhiteSpace($assetPath) -or -not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
            $missing++
        }
        else {
            $asset = Get-Item -LiteralPath $assetPath
            if ([int64](Safe-Int64 (Get-OptionalStringProperty $entry.Poster "Bytes")) -ne [int64]$asset.Length) { $sizeMismatch++ }
            if ($VerifyArtworkHashes) {
                try {
                    if ((Get-TwDeletedCacheFileSha256 -Path $assetPath) -ne (Get-OptionalStringProperty $entry.Poster "Sha256").ToLowerInvariant()) { $hashMismatch++ }
                }
                catch { $hashMismatch++ }
            }
        }
        if ((Get-TwDeletedCacheEntryDate $entry) -lt $cutoff) { $expired++ }
    }

    $assets = @(
        if (Test-Path -LiteralPath $script:TwDeletedCacheAssetRoot -PathType Container) {
            Get-ChildItem -LiteralPath $script:TwDeletedCacheAssetRoot -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^[0-9a-f]{64}\.jpg$' }
        }
    )
    foreach ($asset in $assets) {
        $artworkBytes += [int64]$asset.Length
        if (-not $referenced.Contains($asset.Name)) { $orphaned++ }
    }

    return [PSCustomObject]@{
        SchemaVersion            = 1
        Enabled                  = $script:TwDeletedCacheEnabled
        Available                = $script:TwDeletedCacheAvailable
        ManifestState            = $script:TwDeletedCacheManifestState
        BackupState              = $backupState
        Writability              = $script:TwDeletedCacheWritability
        Integrity                = $integrityState
        RetentionDays            = $script:TwDeletedCacheRetentionDays
        MaxItems                 = $script:TwDeletedCacheMaxItems
        MaxBytes                 = $script:TwDeletedCacheMaxBytes
        ItemCount                = @($index.Entries).Count
        ArtworkCount             = $assets.Count
        ArtworkBytes             = $artworkBytes
        MissingArtworkCount      = $missing
        OrphanArtworkCount       = $orphaned
        ArtworkSizeMismatchCount = $sizeMismatch
        HashMismatchCount        = $hashMismatch
        ExpiredEntryCount        = $expired
    }
}

function Get-TautWeeklyDeletedItemCacheEntry {
    param([string]$MediaType, [string]$MetadataGuid, [switch]$LogHit)
    if (-not $script:TwDeletedCacheEnabled -or -not $script:TwDeletedCacheAvailable) { return $null }
    $id = Get-TwDeletedCacheId $MediaType $MetadataGuid
    if ([string]::IsNullOrWhiteSpace($id)) {
        $script:TwDeletedCacheInvalidLookups++
        return $null
    }
    $entry = @((Get-TwDeletedCacheIndex).Entries | Where-Object {
        (Get-OptionalStringProperty $_ "Id") -eq $id -and
        (Get-OptionalStringProperty $_ "Guid") -eq (Get-TwDeletedCacheStableGuid $MetadataGuid) -and
        (Get-OptionalStringProperty $_ "MediaType") -eq $MediaType
    } | Select-Object -First 1)
    if ($entry.Count -eq 0) {
        [void]$script:TwDeletedCacheSeenMissIds.Add($id)
        return $null
    }
    [void]$script:TwDeletedCacheSeenHitIds.Add($id)
    if ($LogHit -and $script:TwDeletedCacheHitIds.Add($id)) {
        Write-TwDeletedCacheLog "Deleted-item cache hit for an exact $MediaType GUID; using stored presentation metadata or artwork."
    }
    return $entry[0]
}

function Restore-TautWeeklyDeletedItemCachePoster {
    param([string]$MediaType, [string]$MetadataGuid, [string]$DestinationPath)
    $entry = Get-TautWeeklyDeletedItemCacheEntry -MediaType $MediaType -MetadataGuid $MetadataGuid -LogHit
    if ($null -eq $entry -or $null -eq $entry.PSObject.Properties["Poster"]) { return "" }
    $source = Join-Path $script:TwDeletedCacheAssetRoot (Get-OptionalStringProperty $entry.Poster "FileName")
    if (-not (Test-Path -LiteralPath $source)) { return "" }
    $expectedHash = Get-OptionalStringProperty $entry.Poster "Sha256"
    try {
        $actualHash = Get-TwDeletedCacheFileSha256 -Path $source
        if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
            Write-TwDeletedCacheLog "Deleted-item cache artwork failed its SHA-256 check; ignoring the damaged entry." "WARN"
            Remove-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
            $index = Get-TwDeletedCacheIndex
            $id = Get-OptionalStringProperty $entry "Id"
            $index.Entries = @($index.Entries | Where-Object { (Get-OptionalStringProperty $_ "Id") -ne $id })
            [void](Save-TwDeletedCacheIndex)
            return ""
        }
        $temp = $DestinationPath + ".cache-" + [Guid]::NewGuid().ToString("N") + ".tmp"
        Copy-Item -LiteralPath $source -Destination $temp -Force
        if (Test-Path -LiteralPath $DestinationPath) {
            [IO.File]::Replace($temp, $DestinationPath, $null)
        }
        else { [IO.File]::Move($temp, $DestinationPath) }
        Write-TwDeletedCacheLog "Restored deleted $MediaType history artwork from the bounded pre-deletion cache."
        return $DestinationPath
    }
    catch {
        Write-TwDeletedCacheLog "Deleted-item cache artwork could not be restored: $($_.Exception.Message)" "WARN"
        return ""
    }
}

function ConvertTo-TwDeletedCacheText {
    param([AllowNull()][object]$Value, [int]$MaximumLength)
    if ($null -eq $Value) { return "" }
    $text = ([string]$Value).Trim() -replace '[\x00-\x1f]+', ' '
    if ($text.Length -gt $MaximumLength) { return $text.Substring(0, $MaximumLength).TrimEnd() }
    return $text
}

function Update-TautWeeklyDeletedItemCache {
    param([object]$Item, [string]$PosterPath)
    if (-not $script:TwDeletedCacheEnabled -or -not $script:TwDeletedCacheAvailable) { return $false }
    if ($null -eq $Item -or -not (Test-Path -LiteralPath $PosterPath)) {
        $script:TwDeletedCacheCaptureRejectedArtwork++
        return $false
    }

    $mediaType = if ((Get-OptionalStringProperty $Item "Type") -eq "show") { "show" } else { "movie" }
    $guid = Get-TwDeletedCacheStableGuid (Get-OptionalStringProperty $Item "MetadataGuid")
    $id = Get-TwDeletedCacheId $mediaType $guid
    if ([string]::IsNullOrWhiteSpace($id)) {
        $script:TwDeletedCacheCaptureRejectedGuid++
        return $false
    }

    $assetTemp = ""
    try {
        $posterInfo = Get-Item -LiteralPath $PosterPath
        if ($posterInfo.Length -le 512 -or $posterInfo.Length -gt $script:TwDeletedCacheMaxBytes) {
            $script:TwDeletedCacheCaptureRejectedArtwork++
            return $false
        }
        $assetName = $id + ".jpg"
        $assetPath = Join-Path $script:TwDeletedCacheAssetRoot $assetName
        $posterHash = Get-TwDeletedCacheFileSha256 -Path $PosterPath
        $copyNeeded = $true
        if (Test-Path -LiteralPath $assetPath) {
            $copyNeeded = ((Get-TwDeletedCacheFileSha256 -Path $assetPath) -ne $posterHash)
        }
        if ($copyNeeded) {
            $assetTemp = Join-Path $script:TwDeletedCacheAssetRoot ($id + "." + [Guid]::NewGuid().ToString("N") + ".tmp")
            Copy-Item -LiteralPath $PosterPath -Destination $assetTemp -Force
            if (Test-Path -LiteralPath $assetPath) { [IO.File]::Replace($assetTemp, $assetPath, $null) }
            else { [IO.File]::Move($assetTemp, $assetPath) }
        }

        $genres = New-Object System.Collections.Generic.List[string]
        if ($null -ne $Item.PSObject.Properties["DesignGenres"]) {
            foreach ($genre in @($Item.DesignGenres | Select-Object -First 8)) {
                $text = ConvertTo-TwDeletedCacheText $genre 80
                if (-not [string]::IsNullOrWhiteSpace($text)) { $genres.Add($text) }
            }
        }
        $now = [DateTime]::UtcNow.ToString("o")
        $index = Get-TwDeletedCacheIndex
        $existing = @($index.Entries | Where-Object { (Get-OptionalStringProperty $_ "Id") -eq $id } | Select-Object -First 1)
        $created = if ($existing.Count -gt 0) { Get-OptionalStringProperty $existing[0] "CreatedUtc" } else { $now }
        $entry = [PSCustomObject]@{
            Id          = $id
            MediaType   = $mediaType
            Guid        = $guid
            RatingKey   = ConvertTo-TwDeletedCacheText (Get-OptionalStringProperty $Item "PosterRatingKey") 128
            Title       = ConvertTo-TwDeletedCacheText (Get-OptionalStringProperty $Item "Title") 300
            Year        = ConvertTo-TwDeletedCacheText (Get-OptionalStringProperty $Item "Year") 16
            Summary     = ConvertTo-TwDeletedCacheText (Get-OptionalStringProperty $Item "Summary") 1600
            Genres      = $genres.ToArray()
            Ratings     = [PSCustomObject]@{
                RtCritic       = ConvertTo-TwDeletedCacheText (Get-OptionalStringProperty $Item "DesignRtCritic") 8
                RtAudience     = ConvertTo-TwDeletedCacheText (Get-OptionalStringProperty $Item "DesignRtAudience") 8
                Imdb           = ConvertTo-TwDeletedCacheText (Get-OptionalStringProperty $Item "DesignImdbRating") 8
                Provider       = ConvertTo-TwDeletedCacheText (Get-OptionalStringProperty $Item "DesignRatingProvider") 12
                ProviderValue  = ConvertTo-TwDeletedCacheText (Get-OptionalStringProperty $Item "DesignRatingValue") 8
                RtCriticImage  = ConvertTo-TwDeletedCacheText (Get-OptionalStringProperty $Item "DesignRtCriticImage") 100
                RtAudienceImage = ConvertTo-TwDeletedCacheText (Get-OptionalStringProperty $Item "DesignRtAudienceImage") 100
            }
            Poster      = [PSCustomObject]@{ FileName = $assetName; Sha256 = $posterHash; Bytes = [int64]$posterInfo.Length }
            CreatedUtc  = $created
            LastSeenUtc = $now
        }
        $index.Entries = @($index.Entries | Where-Object { (Get-OptionalStringProperty $_ "Id") -ne $id }) + @($entry)
        if (-not (Save-TwDeletedCacheIndex)) {
            $script:TwDeletedCacheCaptureWriteFailed++
            return $false
        }
        Invoke-TwDeletedCacheCleanup
        $script:TwDeletedCacheCaptureAccepted++
        return $true
    }
    catch {
        $script:TwDeletedCacheCaptureWriteFailed++
        Write-TwDeletedCacheLog "A live item could not be added to the deleted-item cache; rendering will continue: $($_.Exception.Message)" "WARN"
        return $false
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($assetTemp)) {
            Remove-Item -LiteralPath $assetTemp -Force -ErrorAction SilentlyContinue
        }
    }
}
