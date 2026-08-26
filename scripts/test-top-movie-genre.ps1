[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-MovieRow {
    param(
        [string]$Key,
        [int64]$Seconds,
        [int]$GroupCount = 1,
        [int]$WatchedStatus = 1,
        [int]$PercentComplete = 100
    )
    return [PSCustomObject]@{
        media_type = 'movie'; rating_key = $Key; title = "Movie $Key"
        play_duration = $Seconds; group_count = $GroupCount
        watched_status = $WatchedStatus; percent_complete = $PercentComplete
    }
}

$rendererPaths = @(
    'platforms/windows/TautWeekly.ps1',
    'platforms/nas-docker/app/TautWeekly.ps1',
    'platforms/mac-docker/app/TautWeekly.ps1'
)
$requiredFunctions = @(
    'Get-OptionalStringProperty', 'Safe-Int', 'Format-WatchTime',
    'Get-HistoryRowPlayCount', 'ConvertTo-DesignGenreList', 'Get-NewsletterReleaseDisplayData',
    'ConvertTo-TopMovieGenreLabel', 'Get-TopMovieGenreAsset',
    'Get-GlobalTopMovieGenre'
)

foreach ($relativePath in $rendererPaths) {
    $path = Join-Path $Root $relativePath
    $script:AssetsDir = if ($relativePath -like 'platforms/windows/*') {
        Join-Path (Split-Path -Parent $path) 'assets'
    } else {
        Join-Path (Split-Path -Parent $path) 'assets-default'
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "Cannot test Top Movie Genre with parser errors: $relativePath"
    foreach ($functionName in $requiredFunctions) {
        $definition = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true) | Select-Object -First 1
        Assert-True ($null -ne $definition) "Missing $functionName in $relativePath"
        Invoke-Expression $definition.Extent.Text
    }

    $script:Config = [PSCustomObject]@{ WatchedPercent = 85 }
    $script:Metadata = @{}
    $script:DirectMetadata = @{}
    $script:MetadataCalls = [Collections.Generic.List[string]]::new()
    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters)
        if ($Command -ne 'get_metadata') { throw "Unexpected test command: $Command" }
        $key = [string]$Parameters.rating_key
        $script:MetadataCalls.Add($key)
        if (-not $script:Metadata.ContainsKey($key) -or $script:Metadata[$key] -is [Exception]) {
            throw "Synthetic metadata failure: $key"
        }
        return $script:Metadata[$key]
    }
    function Get-DesignPlexMetadata {
        param([string]$RatingKey)
        if ($script:DirectMetadata.ContainsKey($RatingKey)) { return $script:DirectMetadata[$RatingKey] }
        return $null
    }
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

    foreach ($alias in @('Science Fiction', 'science fiction', 'SCI-FI', 'Sci Fi', 'scifi')) {
        Assert-True ((ConvertTo-TopMovieGenreLabel -Value $alias) -eq 'Science Fiction') "$relativePath lost the $alias alias"
    }
    Assert-True ((ConvertTo-TopMovieGenreLabel -Value 'dRaMa') -eq 'Drama') "$relativePath did not normalize genre case"

    $script:Metadata = @{
        a = [PSCustomObject]@{ genres = @('Science Fiction', 'Drama') }
        b = [PSCustomObject]@{ genres = @('sci-fi', 'Action') }
        c = [PSCustomObject]@{ genres = @('SCI FI', 'Comedy') }
    }
    $script:MetadataCalls.Clear()
    $aggregate = Get-GlobalTopMovieGenre -GlobalHistory @(
        (New-MovieRow -Key a -Seconds 1200),
        (New-MovieRow -Key a -Seconds 2400 -GroupCount 2),
        (New-MovieRow -Key b -Seconds 1800),
        (New-MovieRow -Key c -Seconds 600)
    )
    Assert-True $aggregate.Available "$relativePath did not produce a qualified genre"
    Assert-True ($aggregate.Genre -eq 'Science Fiction') "$relativePath did not use and normalize only Plex's first genre"
    Assert-True ($aggregate.Seconds -eq 6000 -and $aggregate.MovieCount -eq 3) "$relativePath returned the wrong aggregate seconds or unique movie count"
    Assert-True ($aggregate.SupportingText -eq '1h 40m watched across 3 movies') "$relativePath returned the wrong watch-time supporting copy"
    Assert-True (@($script:MetadataCalls | Where-Object { $_ -eq 'a' }).Count -eq 1) "$relativePath resolved duplicate movie metadata more than once"
    Assert-True ($aggregate.AssetFileName -eq 'genre-scifi.gif' -and -not $aggregate.AssetFallback) "$relativePath did not map Science Fiction safely"

    $script:Metadata = @{
        action = [PSCustomObject]@{ genres = @('Action') }
        drama1 = [PSCustomObject]@{ genres = @('Drama') }
        drama2 = [PSCustomObject]@{ genres = @('Drama') }
    }
    $uniqueTie = Get-GlobalTopMovieGenre -GlobalHistory @(
        (New-MovieRow -Key action -Seconds 3600),
        (New-MovieRow -Key drama1 -Seconds 1800),
        (New-MovieRow -Key drama2 -Seconds 1800)
    )
    Assert-True ($uniqueTie.Genre -eq 'Drama' -and $uniqueTie.MovieCount -eq 2) "$relativePath did not use unique movie count as the first tie-break"

    $script:Metadata = @{
        action = [PSCustomObject]@{ genres = @('Action') }
        comedy = [PSCustomObject]@{ genres = @('Comedy') }
    }
    $playTie = Get-GlobalTopMovieGenre -GlobalHistory @(
        (New-MovieRow -Key action -Seconds 3600 -GroupCount 2),
        (New-MovieRow -Key comedy -Seconds 3600 -GroupCount 1)
    )
    Assert-True ($playTie.Genre -eq 'Action') "$relativePath did not use grouped plays after the displayed tie metrics"
    $alphaTie = Get-GlobalTopMovieGenre -GlobalHistory @(
        (New-MovieRow -Key action -Seconds 3600),
        (New-MovieRow -Key comedy -Seconds 3600)
    )
    Assert-True ($alphaTie.Genre -eq 'Action') "$relativePath lost the deterministic alphabetic final tie-break"

    $script:Metadata = @{ fallback = [InvalidOperationException]::new('synthetic') }
    $script:DirectMetadata = @{ fallback = [PSCustomObject]@{ Genre = @([PSCustomObject]@{ tag = 'Horror' }, [PSCustomObject]@{ tag = 'Comedy' }) } }
    $directFallback = Get-GlobalTopMovieGenre -GlobalHistory @((New-MovieRow -Key fallback -Seconds 7200))
    Assert-True ($directFallback.Genre -eq 'Horror') "$relativePath did not use the first direct Plex fallback genre"

    $script:Metadata = @{ documentary = [PSCustomObject]@{ genres = @('DOCUMENTARY') } }
    $script:DirectMetadata = @{}
    $unmapped = Get-GlobalTopMovieGenre -GlobalHistory @((New-MovieRow -Key documentary -Seconds 3600))
    Assert-True ($unmapped.Available -and $unmapped.Genre -eq 'Documentary') "$relativePath discarded a valid unmapped Plex genre"
    Assert-True ($unmapped.AssetFileName -eq 'movies.gif' -and $unmapped.AssetCid -eq 'icon_movies' -and $unmapped.AssetFallback) "$relativePath did not use the neutral movie fallback asset"

    $script:Metadata = @{ missing = [PSCustomObject]@{ genres = @() } }
    $unavailable = Get-GlobalTopMovieGenre -GlobalHistory @(
        (New-MovieRow -Key missing -Seconds 3600),
        (New-MovieRow -Key incomplete -Seconds 900 -WatchedStatus 0 -PercentComplete 20)
    )
    Assert-True (-not $unavailable.Available -and $unavailable.MovieCount -eq 0) "$relativePath invented a genre for missing/unqualified activity"
    Assert-True ($unavailable.AssetFileName -eq 'movies.gif' -and $unavailable.SupportingText -match '^No qualifying movie activity') "$relativePath lost the no-activity fallback"

    $trendingHero = [PSCustomObject]@{
        IsTrending = $true
        Item = [PSCustomObject]@{ Type = 'movie'; ReleaseKey = 'hero' }
    }
    $recentMovies = @(
        [PSCustomObject]@{ ReleaseKey = 'hero'; Title = 'Trending Hero' },
        [PSCustomObject]@{ ReleaseKey = 'recent-1'; Title = 'Recent One' },
        [PSCustomObject]@{ ReleaseKey = 'recent-2'; Title = 'Recent Two' },
        [PSCustomObject]@{ ReleaseKey = 'recent-3'; Title = 'Recent Three' },
        [PSCustomObject]@{ ReleaseKey = 'recent-4'; Title = 'Recent Four' }
    )
    $mixedTrendingDisplay = Get-NewsletterReleaseDisplayData -ReleaseData ([PSCustomObject]@{
        Movies = $recentMovies
        TV = @([PSCustomObject]@{ ReleaseKey = 'new-tv'; Title = 'New TV' })
        MovieSectionLabel = 'RECENT RELEASES'
        TvSectionLabel = 'NEW RELEASES'
    }) -HotRelease $trendingHero -QuietReleaseMode $true
    Assert-True ($mixedTrendingDisplay.Movies.Count -eq 4 -and $mixedTrendingDisplay.TV.Count -eq 1) "$relativePath did not retain four recent movies plus new TV in a Trending state"
    Assert-True ($mixedTrendingDisplay.MovieSectionLabel -eq 'RECENT RELEASES' -and $mixedTrendingDisplay.TvSectionLabel -eq 'NEW RELEASES') "$relativePath did not keep separate Recent Movie and New TV labels"
    Assert-True ($mixedTrendingDisplay.CountLine -eq '0 NEW MOVIES • 1 TV TITLE') "$relativePath returned the wrong mixed-source Trending count line"

    $recentOnlyDisplay = Get-NewsletterReleaseDisplayData -ReleaseData ([PSCustomObject]@{
        Movies = $recentMovies
        TV = @(
            [PSCustomObject]@{ ReleaseKey = 'recent-tv-1'; Title = 'Recent TV One' },
            [PSCustomObject]@{ ReleaseKey = 'recent-tv-2'; Title = 'Recent TV Two' }
        )
        MovieSectionLabel = 'RECENT RELEASES'
        TvSectionLabel = 'RECENT RELEASES'
    }) -HotRelease $trendingHero -QuietReleaseMode $true
    Assert-True ($recentOnlyDisplay.CountLine -eq '1 TRENDING MOVIE • 4 RECENT MOVIE RELEASES') "$relativePath did not fall back to Recent TV when no new TV exists"
    $singleRecentDisplay = Get-NewsletterReleaseDisplayData -ReleaseData ([PSCustomObject]@{
        Movies = @($recentMovies[0], $recentMovies[1])
        TV = @()
        MovieSectionLabel = 'RECENT RELEASES'
        TvSectionLabel = 'RECENT RELEASES'
    }) -HotRelease $trendingHero -QuietReleaseMode $true
    Assert-True ($singleRecentDisplay.CountLine -eq '1 TRENDING MOVIE • 1 RECENT MOVIE RELEASE') "$relativePath lost the singular Recent Movie Release header"
    $source = [IO.File]::ReadAllText($path)
    $sharedSupportStyle = 'padding-top:3px;font-size:12px;line-height:1.35;font-weight:400;color:#8e8e8e;'
    Assert-True ($source.Contains("`$summarySupportingStyle = '$sharedSupportStyle'")) "$relativePath does not define the normalized support style"
    Assert-True ($source.Contains('<div style="$summarySupportingStyle">total watch time</div>')) "$relativePath total-watch support does not use the shared style"
    Assert-True ($source.Contains('$bingeBreakdownHtml = "<div style=`"$summarySupportingStyle`">')) "$relativePath Binge breakdown does not use the shared style"
    Assert-True ($source.Contains('<div style="$summarySupportingStyle">$(HtmlEncode $topGenreDescription)</div>')) "$relativePath Top Genre duration/count does not use the shared style"
    Assert-True ($source.Contains('if ($trendingHeroMode) { $topGenreBlock } else { $trendingBlock }')) "$relativePath lost the complementary footer matrix"
    Assert-True ($source -match '\$preheader = if \(\$QuietReleaseMode\) \{\r?\n\s+\$releaseCountLine') "$relativePath does not inherit the Trending count line into inbox preview text"
    Assert-True ($source -match '\$plainPreheader = if \(\$QuietReleaseMode\) \{\r?\n\s+\[string\]\$releaseDisplay\.CountLine') "$relativePath does not inherit the Trending count line into the plain-text preview"
    Assert-True ($source.Contains('width="42" height="42" alt="Top genre this week"')) "$relativePath Top Genre icon drifted from the standard Binge icon size"
    Assert-True ($source.Contains('elseif (-not $WelcomeOnly)')) "$relativePath plain-text Manual Welcome can disclose Binge Champion"
    foreach ($cid in @('genre_action','genre_comedy','genre_crime','genre_drama','genre_fantasy','genre_horror','genre_musical','genre_mystery','genre_romance','genre_scifi','genre_thriller','genre_western')) {
        Assert-True ($source.Contains("Cid = `"$cid`"; MediaType = `"image/gif`"")) "$relativePath does not register MIME resource $cid"
    }

    Write-Host "[PASS] Top Movie Genre algorithm, privacy model, rendering contract: $relativePath"
}

$gifManifest = Get-Content -LiteralPath (Join-Path $Root 'assets/email-gifs.json') -Raw | ConvertFrom-Json
$expectedAssets = [ordered]@{}
foreach ($asset in $gifManifest.assets) {
    if ($asset.name -like 'genre-*.gif') {
        $expectedAssets[$asset.name] = @{ Hash=$asset.sha256; Frames=$asset.gif.frames.Count; Width=$asset.gif.width; Height=$asset.gif.height }
    }
}
Assert-True ($expectedAssets.Count -eq 12) 'Expected all twelve optimized genre GIFs.'
$assetRoots = @('platforms/windows/assets','platforms/nas-docker/app/assets-default','platforms/mac-docker/app/assets-default')
Add-Type -AssemblyName System.Drawing
foreach ($assetRoot in $assetRoots) {
    foreach ($assetName in $expectedAssets.Keys) {
        $assetPath = Join-Path (Join-Path $Root $assetRoot) $assetName
        Assert-True (Test-Path -LiteralPath $assetPath -PathType Leaf) "Missing genre asset: $assetRoot/$assetName"
        $bytes = [IO.File]::ReadAllBytes($assetPath)
        Assert-True ([Text.Encoding]::ASCII.GetString($bytes,0,6) -eq 'GIF89a') "$assetRoot/$assetName is not GIF89a"
        Assert-True ([BitConverter]::ToUInt16($bytes,6) -eq $expectedAssets[$assetName].Width -and [BitConverter]::ToUInt16($bytes,8) -eq $expectedAssets[$assetName].Height) "$assetRoot/$assetName does not match the optimized dimensions"
        Assert-True ((Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedAssets[$assetName].Hash) "$assetRoot/$assetName changed from the validated optimized GIF"
        $image = [Drawing.Image]::FromFile($assetPath)
        try {
            $dimension = [Drawing.Imaging.FrameDimension]::new($image.FrameDimensionsList[0])
            Assert-True ($image.GetFrameCount($dimension) -eq $expectedAssets[$assetName].Frames) "$assetRoot/$assetName lost animation frames"
        } finally { $image.Dispose() }
    }
}
Write-Host '[PASS] Validated optimized GIF type, email-sized dimensions, animation, hashes, and package parity.'