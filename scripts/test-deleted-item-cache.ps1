[CmdletBinding()]
param(
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }

$script:TestLogs = New-Object System.Collections.Generic.List[string]

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $script:TestLogs.Add("[$Level] $Message")
}

function Get-OptionalStringProperty {
    param([AllowNull()][object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return '' }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Safe-Int64 {
    param([AllowNull()][object]$Value)
    [int64]$parsed = 0
    if ($null -ne $Value) { [void][int64]::TryParse([string]$Value, [ref]$parsed) }
    return $parsed
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected, [string]$Message)
    if ([string]$Actual -ne [string]$Expected) {
        throw "$Message Expected '$Expected', received '$Actual'."
    }
}

function New-TestPoster {
    param([string]$Path, [int]$Bytes = 4096, [byte]$Fill = 73)
    $content = New-Object byte[] $Bytes
    for ($index = 0; $index -lt $content.Length; $index++) { $content[$index] = $Fill }
    [IO.File]::WriteAllBytes($Path, $content)
}

function New-TestItem {
    param(
        [string]$Guid,
        [string]$Title,
        [string]$Type = 'movie',
        [string]$Secret = 'must-not-be-persisted'
    )
    return [PSCustomObject]@{
        Type                  = $Type
        MetadataGuid          = $Guid
        PosterRatingKey       = '42'
        Title                 = $Title
        Year                  = '2026'
        Summary               = 'A short presentation summary.'
        DesignGenres          = @('Drama', 'Mystery')
        DesignRtCritic        = '91'
        DesignRtAudience      = '87'
        DesignImdbRating      = '7.8'
        DesignRatingProvider  = 'TMDB'
        DesignRatingValue     = '7.4'
        DesignRtCriticImage   = 'certified_fresh'
        DesignRtAudienceImage = 'upright'
        PlexToken             = $Secret
        TautulliApiKey        = $Secret
        RecipientEmail        = "viewer-$Secret@example.com"
        ViewCount             = 99
        TotalDuration         = 123456
    }
}

$modules = @(
    Join-Path $Root 'platforms/windows/DeletedItemCache.ps1'
    Join-Path $Root 'platforms/nas-docker/app/DeletedItemCache.ps1'
    Join-Path $Root 'platforms/mac-docker/app/DeletedItemCache.ps1'
)
foreach ($module in $modules) { Assert-True (Test-Path -LiteralPath $module) "Missing cache module: $module" }
$canonical = (((Get-Content -LiteralPath $modules[0] -Raw) -replace "`r`n", "`n").TrimEnd())
foreach ($module in $modules[1..2]) {
    $candidate = (((Get-Content -LiteralPath $module -Raw) -replace "`r`n", "`n").TrimEnd())
    Assert-Equal $candidate $canonical "Cache module implementations diverged: $module"
}

. $modules[0]

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-cache-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $cacheRoot = Join-Path $testRoot 'defaults'
    Initialize-TautWeeklyDeletedItemCache -CacheRoot $cacheRoot -Configuration ([PSCustomObject]@{})
    $status = Get-TautWeeklyDeletedItemCacheStatus
    Assert-True $status.Enabled 'Missing cache settings must safely migrate to enabled defaults.'
    Assert-True $status.Available 'Default cache must be writable.'
    Assert-Equal $status.SchemaVersion 1 'Unexpected cache schema.'
    Assert-Equal $status.RetentionDays 365 'Unexpected default retention.'
    Assert-Equal $status.MaxItems 1000 'Unexpected default item bound.'
    Assert-Equal $status.MaxBytes (256MB) 'Unexpected default byte bound.'

    $poster = Join-Path $testRoot 'live-poster.jpg'
    New-TestPoster -Path $poster
    $secret = 'private-7c4e2a'
    $movieGuid = 'plex://movie/0123456789abcdef'
    $movie = New-TestItem -Guid $movieGuid -Title 'Future Deleted Movie' -Secret $secret
    Assert-True (Update-TautWeeklyDeletedItemCache -Item $movie -PosterPath $poster) 'Live exact-GUID item was not cached.'
    $entry = Get-TautWeeklyDeletedItemCacheEntry -MediaType movie -MetadataGuid $movieGuid
    Assert-True ($null -ne $entry) 'Exact cache lookup failed.'
    Assert-Equal $entry.Title 'Future Deleted Movie' 'Cached title was not retained.'
    Assert-Equal $entry.Summary 'A short presentation summary.' 'Cached summary was not retained.'
    Assert-Equal $entry.Ratings.Provider 'TMDB' 'Selected rating provider was not retained.'
    Assert-Equal $entry.Ratings.ProviderValue '7.4' 'Selected rating value was not retained.'
    Assert-True ($null -eq $entry.PSObject.Properties['PlexToken']) 'Unexpected private field reached cache entry.'

    $rawIndex = Get-Content -LiteralPath (Join-Path $cacheRoot 'index.json') -Raw
    foreach ($forbidden in @($secret, 'PlexToken', 'TautulliApiKey', 'RecipientEmail', 'ViewCount', 'TotalDuration', 'example.com')) {
        Assert-True (-not $rawIndex.Contains($forbidden)) "Cache serialized forbidden private data: $forbidden"
    }

    $restored = Join-Path $testRoot 'restored-poster.jpg'
    Assert-Equal (Restore-TautWeeklyDeletedItemCachePoster -MediaType movie -MetadataGuid $movieGuid -DestinationPath $restored) $restored 'Cached poster was not restored.'
    Assert-Equal (Get-FileHash $restored -Algorithm SHA256).Hash (Get-FileHash $poster -Algorithm SHA256).Hash 'Restored poster changed bytes.'
    Assert-True ($null -eq (Get-TautWeeklyDeletedItemCacheEntry -MediaType movie -MetadataGuid 'plex://movie/different-id')) 'Same-title data must not match a different GUID.'
    Assert-True ($null -eq (Get-TautWeeklyDeletedItemCacheEntry -MediaType movie -MetadataGuid '')) 'A missing GUID must fail closed.'
    Assert-True (-not (Update-TautWeeklyDeletedItemCache -Item (New-TestItem -Guid '' -Title 'Future Deleted Movie') -PosterPath $poster)) 'A missing GUID must not be cached by title or rating key.'

    $boundedRoot = Join-Path $testRoot 'bounded'
    $boundedConfig = [PSCustomObject]@{
        DeletedItemCacheEnabled       = $true
        DeletedItemCacheRetentionDays = 365
        DeletedItemCacheMaxItems      = 2
        DeletedItemCacheMaxBytesMB    = 16
    }
    Initialize-TautWeeklyDeletedItemCache -CacheRoot $boundedRoot -Configuration $boundedConfig
    foreach ($number in 1..3) {
        New-TestPoster -Path $poster -Fill ([byte](60 + $number))
        Assert-True (Update-TautWeeklyDeletedItemCache -Item (New-TestItem -Guid "plex://movie/bounded-$number" -Title "Bounded $number") -PosterPath $poster) "Bounded item $number was not written."
        Start-Sleep -Milliseconds 15
    }
    $boundedStatus = Get-TautWeeklyDeletedItemCacheStatus
    Assert-Equal $boundedStatus.ItemCount 2 'MaxItems cleanup did not deterministically evict the oldest entry.'
    Assert-True ($null -eq (Get-TautWeeklyDeletedItemCacheEntry movie 'plex://movie/bounded-1')) 'Oldest bounded item was not evicted.'
    Assert-True ($null -ne (Get-TautWeeklyDeletedItemCacheEntry movie 'plex://movie/bounded-3')) 'Newest bounded item was incorrectly evicted.'

    $largeRoot = Join-Path $testRoot 'large'
    Initialize-TautWeeklyDeletedItemCache -CacheRoot $largeRoot -Configuration $boundedConfig
    foreach ($number in 1..3) {
        New-TestPoster -Path $poster -Bytes (6MB) -Fill ([byte](70 + $number))
        Assert-True (Update-TautWeeklyDeletedItemCache -Item (New-TestItem -Guid "plex://movie/large-$number" -Title "Large $number") -PosterPath $poster) "Large item $number cache update failed."
        Start-Sleep -Milliseconds 15
    }
    $largeStatus = Get-TautWeeklyDeletedItemCacheStatus
    Assert-True ($largeStatus.ItemCount -le 2) 'Artwork byte budget did not evict entries.'
    $largeAssetBytes = [int64](Get-ChildItem -LiteralPath (Join-Path $largeRoot 'artwork') -File | Measure-Object Length -Sum).Sum
    Assert-True ($largeAssetBytes -le 12MB) 'Artwork eviction did not retain a bounded newest-first set.'
    $largeTotalBytes = [int64](Get-ChildItem -LiteralPath $largeRoot -Recurse -File | Measure-Object Length -Sum).Sum
    Assert-True ($largeTotalBytes -le 16MB) 'Cache artwork plus manifests exceeded the configured total-byte ceiling.'

    $untrustedRoot = Join-Path $testRoot 'untrusted-manifest'
    $untrustedArtwork = Join-Path $untrustedRoot 'artwork'
    New-Item -ItemType Directory -Force -Path $untrustedArtwork | Out-Null
    $outsideFile = Join-Path $testRoot 'outside.jpg'
    New-TestPoster -Path $outsideFile
    [PSCustomObject]@{
        SchemaVersion = 1
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Entries = @([PSCustomObject]@{
            Id = ('a' * 64); MediaType = 'movie'; Guid = 'plex://movie/traversal'
            Poster = [PSCustomObject]@{ FileName = '../outside.jpg'; Sha256 = ('b' * 64); Bytes = 4096 }
            CreatedUtc = [DateTime]::UtcNow.ToString('o'); LastSeenUtc = [DateTime]::UtcNow.ToString('o')
        })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $untrustedRoot 'index.json') -Encoding UTF8
    Initialize-TautWeeklyDeletedItemCache -CacheRoot $untrustedRoot -Configuration ([PSCustomObject]@{})
    Assert-True (Test-Path -LiteralPath $outsideFile) 'Untrusted manifest path escaped the cache artwork directory.'
    Assert-Equal (Get-TautWeeklyDeletedItemCacheStatus).ItemCount 0 'Invalid manifest entry was not rejected.'

    $schemaRoot = Join-Path $testRoot 'unknown-schema'
    New-Item -ItemType Directory -Force -Path (Join-Path $schemaRoot 'artwork') | Out-Null
    [PSCustomObject]@{ SchemaVersion = 99; UpdatedUtc = [DateTime]::UtcNow.ToString('o'); Entries = @() } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $schemaRoot 'index.json') -Encoding UTF8
    Initialize-TautWeeklyDeletedItemCache -CacheRoot $schemaRoot -Configuration ([PSCustomObject]@{})
    Assert-Equal (Get-TautWeeklyDeletedItemCacheStatus).ItemCount 0 'Unknown schema did not migrate safely to an empty v1 cache.'
    Assert-True (Test-Path -LiteralPath (Join-Path $schemaRoot 'index.corrupt.json')) 'Small unsupported manifest was not preserved for diagnosis.'

    $oversizedRoot = Join-Path $testRoot 'oversized-corruption'
    New-Item -ItemType Directory -Force -Path (Join-Path $oversizedRoot 'artwork') | Out-Null
    New-TestPoster -Path (Join-Path $oversizedRoot 'index.json') -Bytes (2MB)
    Initialize-TautWeeklyDeletedItemCache -CacheRoot $oversizedRoot -Configuration ([PSCustomObject]@{})
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $oversizedRoot 'index.corrupt.json'))) 'Oversized corrupt manifest was retained outside the storage bound.'

    $expiryRoot = Join-Path $testRoot 'expiry'
    Initialize-TautWeeklyDeletedItemCache -CacheRoot $expiryRoot -Configuration ([PSCustomObject]@{
        DeletedItemCacheRetentionDays = 1
        DeletedItemCacheMaxItems = 10
        DeletedItemCacheMaxBytesMB = 16
    })
    New-TestPoster -Path $poster
    Assert-True (Update-TautWeeklyDeletedItemCache -Item (New-TestItem 'plex://movie/expired' 'Expired') -PosterPath $poster) 'Expiry fixture was not cached.'
    $expiryIndex = Get-TwDeletedCacheIndex
    $expiryIndex.Entries[0].LastSeenUtc = [DateTime]::UtcNow.AddDays(-2).ToString('o')
    Invoke-TwDeletedCacheCleanup
    Assert-Equal (Get-TautWeeklyDeletedItemCacheStatus).ItemCount 0 'Expired item was not removed.'

    $recoveryRoot = Join-Path $testRoot 'recovery'
    Initialize-TautWeeklyDeletedItemCache -CacheRoot $recoveryRoot -Configuration ([PSCustomObject]@{})
    New-TestPoster -Path $poster
    Assert-True (Update-TautWeeklyDeletedItemCache -Item (New-TestItem 'plex://movie/recover-1' 'Recover One') -PosterPath $poster) 'First recovery fixture failed.'
    Assert-True (Update-TautWeeklyDeletedItemCache -Item (New-TestItem 'plex://movie/recover-2' 'Recover Two') -PosterPath $poster) 'Second recovery fixture failed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $recoveryRoot 'index.backup.json')) 'Atomic replacement did not retain a backup manifest.'
    [IO.File]::WriteAllText((Join-Path $recoveryRoot 'index.json'), '{broken')
    $script:TwDeletedCacheIndex = $null
    $recovered = Get-TwDeletedCacheIndex
    Assert-True (@($recovered.Entries).Count -ge 1) 'Readable backup was not recovered after primary corruption.'
    Assert-True (Test-Path -LiteralPath (Join-Path $recoveryRoot 'index.corrupt.json')) 'Corrupt primary manifest was not preserved once.'
    Assert-Equal @(Get-ChildItem -LiteralPath $recoveryRoot -File -Filter '*.tmp').Count 0 'Atomic manifest update left temporary files.'

    $assetPath = Join-Path (Join-Path $recoveryRoot 'artwork') ((Get-OptionalStringProperty $recovered.Entries[0].Poster 'FileName'))
    [IO.File]::WriteAllText($assetPath, 'damaged')
    $damagedDestination = Join-Path $testRoot 'damaged-output.jpg'
    Assert-Equal (Restore-TautWeeklyDeletedItemCachePoster -MediaType $recovered.Entries[0].MediaType -MetadataGuid $recovered.Entries[0].Guid -DestinationPath $damagedDestination) '' 'SHA-256 mismatch must fail closed.'
    Assert-True (-not (Test-Path -LiteralPath $damagedDestination)) 'Damaged cache artwork reached output.'

    $invalidRoot = Join-Path $testRoot 'not-a-directory'
    [IO.File]::WriteAllText($invalidRoot, 'occupied')
    Initialize-TautWeeklyDeletedItemCache -CacheRoot $invalidRoot -Configuration ([PSCustomObject]@{})
    $invalidStatus = Get-TautWeeklyDeletedItemCacheStatus
    Assert-True (-not $invalidStatus.Available) 'Cache path failure must disable cache without throwing.'

    Initialize-TautWeeklyDeletedItemCache -CacheRoot (Join-Path $testRoot 'disabled') -Configuration ([PSCustomObject]@{ DeletedItemCacheEnabled = $false })
    $disabled = Get-TautWeeklyDeletedItemCacheStatus
    Assert-True (-not $disabled.Enabled -and -not $disabled.Available) 'Explicit disable setting was ignored.'

    Write-Host '[PASS] Deleted-item cache schema, privacy, exact matching, bounds, recovery, and platform parity.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
