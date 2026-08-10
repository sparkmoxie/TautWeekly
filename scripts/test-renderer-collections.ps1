[CmdletBinding()]
param(
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
$Root = [IO.Path]::GetFullPath($Root)

$rendererPaths = @(
    'platforms/windows/TautWeekly.ps1',
    'platforms/nas-docker/app/TautWeekly.ps1',
    'platforms/mac-docker/app/TautWeekly.ps1'
)

$requiredFunctions = @(
    'Get-OptionalStringProperty',
    'Convert-DesignRatingPercent',
    'ConvertTo-DesignGenreList',
    'Add-DesignRatingMetadata',
    'Get-PlexHostedMetadataLookupPath',
    'Get-TautulliDefaultPosterHash',
    'Get-TautulliUser',
    'Get-TautulliUsers',
    'Safe-Int',
    'Safe-Int64',
    'New-ReleaseData',
    'Get-HistoryRowPlayCount',
    'Format-WatchTime',
    'Get-ConfiguredServerName',
    'Get-ConfiguredPlexWebUrl',
    'Get-ConfiguredDeliveryDay',
    'Get-UserStats',
    'Get-HotNewRelease',
    'Get-DynamicPreheader',
    'Build-PlainText'
)

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

foreach ($relativePath in $rendererPaths) {
    $path = Join-Path $Root $relativePath
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        throw "Cannot test renderer with parser errors: $relativePath"
    }

    foreach ($functionName in $requiredFunctions) {
        $definition = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        }, $true) | Select-Object -First 1

        if ($null -eq $definition) {
            throw "Missing $functionName in $relativePath"
        }

        Invoke-Expression $definition.Extent.Text
    }

    $posterProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-poster-probe-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $posterProbeRoot | Out-Null
        $script:PosterDir = $posterProbeRoot
        $script:TautulliDefaultPosterHash = ''
        $script:posterProbeOutFile = ''
        $script:posterProbeWarnings = New-Object System.Collections.Generic.List[string]

        function Write-Log {
            param([string]$Message, [string]$Level = 'INFO')
            if ($Level -eq 'WARN') { $script:posterProbeWarnings.Add($Message) }
        }

        function Build-TautulliUri {
            param([string]$Command, [hashtable]$Parameters = @{})
            Assert-True ($Command -eq 'pms_image_proxy') "$relativePath used the wrong command for the generic-poster probe"
            Assert-True ([string]$Parameters.fallback -eq 'poster') "$relativePath did not request Tautulli's poster fallback"
            return 'https://tautulli.invalid/api/v2'
        }

        function Invoke-WebRequest {
            param(
                [string]$Uri,
                [string]$OutFile,
                [int]$TimeoutSec
            )

            $script:posterProbeOutFile = $OutFile
            [IO.File]::WriteAllBytes($OutFile, [Text.Encoding]::UTF8.GetBytes(('GENERIC-POSTER' * 64)))
        }

        $posterHash = Get-TautulliDefaultPosterHash
        $probeWarningText = $script:posterProbeWarnings -join '; '
        Assert-True (-not [string]::IsNullOrWhiteSpace($posterHash)) "$relativePath could not fingerprint Tautulli's generic poster on this platform: $probeWarningText"
        Assert-True (-not (Test-Path -LiteralPath $script:posterProbeOutFile)) "$relativePath did not clean up the generic-poster probe"
    }
    finally {
        Remove-Item -LiteralPath $posterProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $script:Config = [PSCustomObject]@{
        WatchedPercent       = 85
        MinimumEpisodeSeconds = 120
        FooterServerName     = 'Test Plex'
        PlexWebUrl           = 'https://app.plex.tv/'
        ScheduleDay          = 'Friday'
    }

    $script:tautulliUserCalls = New-Object System.Collections.Generic.List[string]
    function Invoke-TautulliApi {
        param(
            [string]$Command,
            [hashtable]$Parameters = @{}
        )

        $script:tautulliUserCalls.Add($Command)
        if ($Command -eq 'get_user') {
            throw 'Simulated per-user lookup rejection'
        }
        if ($Command -eq 'get_users') {
            return @(
                [PSCustomObject]@{
                    user_id = '145330906'
                    username = 'viewer'
                    email = 'viewer@example.com'
                    is_active = 1
                    do_notify = 1
                }
            )
        }

        throw "Unexpected Tautulli command: $Command"
    }

    $fallbackUser = Get-TautulliUser -Id '145330906'
    Assert-True ([string]$fallbackUser.user_id -eq '145330906') "$relativePath did not recover the requested user from get_users"
    Assert-True (($script:tautulliUserCalls -join ',') -eq 'get_user,get_users') "$relativePath did not use the bulk-user fallback after get_user failed"

    $movie = [PSCustomObject]@{
        media_type      = 'movie'
        play_duration   = 7200
        watched_status  = 1
        percent_complete = 100
        rating_key      = 'movie-1'
        guid            = 'plex://movie/movie-guid-1'
        title           = 'Movie One'
        year            = '2026'
    }
    $episode = [PSCustomObject]@{
        media_type             = 'episode'
        play_duration          = 1800
        watched_status         = 0
        percent_complete       = 50
        rating_key             = 'episode-1'
        guid                   = 'plex://episode/episode-guid-1'
        grandparent_rating_key = 'show-1'
        grandparent_title      = 'Show One'
        parent_title           = 'Season 1'
        title                  = 'Pilot'
        parent_media_index     = 1
        media_index            = 1
        rating_image           = 'imdb://image.rating'
        rating                 = '8.5'
    }

    $oneMovie = Get-UserStats -History @($movie)
    Assert-True ($oneMovie.MovieItems -is [object[]]) "$relativePath collapsed one movie into a scalar"
    Assert-True ($oneMovie.MovieItems.Count -eq 1) "$relativePath lost the one-movie item"
    Assert-True ($oneMovie.MovieItems[0].MetadataGuid -eq 'plex://movie/movie-guid-1') "$relativePath lost the retained movie metadata GUID"
    Assert-True ($oneMovie.EpisodeItems.Count -eq 0) "$relativePath created an unexpected episode"
    Assert-True ($oneMovie.TvShowItems.Count -eq 0) "$relativePath created an unexpected TV show"

    $oneEpisode = Get-UserStats -History @($episode)
    Assert-True ($oneEpisode.EpisodeItems -is [object[]]) "$relativePath collapsed one episode into a scalar"
    Assert-True ($oneEpisode.EpisodeItems.Count -eq 1) "$relativePath lost the one-episode item"
    Assert-True ($oneEpisode.MovieItems.Count -eq 0) "$relativePath created an unexpected movie"
    Assert-True ($oneEpisode.TvShowItems.Count -eq 1) "$relativePath did not group the episode into one TV show"
    Assert-True ($oneEpisode.TvShowItems[0].MetadataGuid -eq 'plex://episode/episode-guid-1') "$relativePath lost the representative episode GUID for TV artwork"
    Assert-True ($oneEpisode.TvShowItems[0].ShowTitle -eq 'Show One') "$relativePath lost the grouped TV show title"
    Assert-True ($oneEpisode.EpisodeItems[0].ImdbRating -eq '8.5') "$relativePath lost an available episode IMDb rating"

    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'plex://movie/5d123abc?lang=en' -MediaType 'movie') -eq '/library/metadata/5d123abc') "$relativePath did not normalize a retained Plex GUID"
    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'com.plexapp.agents.themoviedb://12345?lang=en' -MediaType 'movie') -eq '/library/metadata/matches?guid=tmdb%3A%2F%2F12345&type=1') "$relativePath did not normalize a legacy TMDB movie GUID"
    Assert-True ([string]::IsNullOrWhiteSpace((Get-PlexHostedMetadataLookupPath -MetadataGuid 'com.plexapp.agents.thetvdb://999/1/2' -MediaType 'show'))) "$relativePath guessed from an unsupported legacy TVDB GUID"

    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }
    function Get-DesignPlexMetadata { param([string]$RatingKey) return $null }
    function Get-DesignRichExport {
        param([string]$RatingKey, [string]$MediaType, [switch]$NeedLogo)
        return [PSCustomObject]@{ RtCritic = ''; RtAudience = '' }
    }
    function Get-PlexHostedMetadata {
        param([string]$MetadataGuid, [string]$MediaType)
        Assert-True ($MetadataGuid -eq 'plex://movie/deleted-movie-guid') "$relativePath changed the retained GUID during hosted enrichment"
        Assert-True ($MediaType -eq 'movie') "$relativePath used the wrong hosted metadata type"
        return [PSCustomObject]@{
            type = 'movie'
            summary = 'Retained exact-GUID summary.'
            year = '2024'
            Genre = @([PSCustomObject]@{ tag = 'Mystery' }, [PSCustomObject]@{ tag = 'Drama' })
            rating = '8.7'
            ratingImage = 'rottentomatoes://image.rating.ripe'
            audienceRating = '9.3'
            audienceRatingImage = 'rottentomatoes://image.rating.upright'
        }
    }
    $deletedMovieItem = [PSCustomObject]@{
        RatingKey = 'deleted-movie'
        MetadataGuid = 'plex://movie/deleted-movie-guid'
        Type = 'movie'
        Title = 'Deleted Movie'
    }
    Add-DesignRatingMetadata -ReleaseData ([PSCustomObject]@{ Movies = @($deletedMovieItem); TV = @() })
    Assert-True ($deletedMovieItem.Summary -eq 'Retained exact-GUID summary.') "$relativePath did not restore a deleted movie summary"
    Assert-True ($deletedMovieItem.Year -eq '2024') "$relativePath did not restore a deleted movie year"
    Assert-True (($deletedMovieItem.DesignGenres -join ',') -eq 'Mystery,Drama') "$relativePath did not restore deleted movie genres"
    Assert-True ($deletedMovieItem.DesignRtCritic -eq '87') "$relativePath did not restore the deleted movie critic rating"
    Assert-True ($deletedMovieItem.DesignRtAudience -eq '93') "$relativePath did not restore the deleted movie audience rating"

    function Get-PlexHostedMetadata {
        param([string]$MetadataGuid, [string]$MediaType)
        Assert-True ($MetadataGuid -eq 'plex://episode/deleted-episode-guid') "$relativePath changed the retained episode GUID during hosted enrichment"
        Assert-True ($MediaType -eq 'show') "$relativePath used the wrong hosted TV metadata type"
        return [PSCustomObject]@{
            type = 'show'
            summary = 'Retained TV summary.'
            year = '2024'
            rating = '8.4'
            ratingImage = 'imdb://image.rating'
        }
    }
    $deletedShowItem = [PSCustomObject]@{
        RatingKey = 'deleted-show'
        MetadataGuid = 'plex://episode/deleted-episode-guid'
        Type = 'show'
        Title = 'Deleted Show'
    }
    Add-DesignRatingMetadata -ReleaseData ([PSCustomObject]@{ Movies = @(); TV = @($deletedShowItem) })
    Assert-True ($deletedShowItem.DesignImdbRating -eq '8.4') "$relativePath did not restore the deleted TV IMDb rating"
    Assert-True ([string]::IsNullOrWhiteSpace($deletedShowItem.DesignRtCritic)) "$relativePath mislabeled a TV IMDb rating as Rotten Tomatoes"
    Assert-True ([string]::IsNullOrWhiteSpace($deletedShowItem.DesignRtAudience)) "$relativePath invented a TV Rotten Tomatoes audience rating"

    $secondEpisode = [PSCustomObject]@{
        media_type             = 'episode'
        play_duration          = 3600
        watched_status         = 0
        percent_complete       = 50
        rating_key             = 'episode-2'
        grandparent_rating_key = 'show-1'
        grandparent_title      = 'Show One'
        parent_title           = 'Season 1'
        title                  = 'Second Episode'
        parent_media_index     = 1
        media_index            = 2
    }
    $sameShow = Get-UserStats -History @($episode, $secondEpisode)
    Assert-True ($sameShow.EpisodeItems.Count -eq 2) "$relativePath lost qualifying episode detail"
    Assert-True ($sameShow.TvShowItems.Count -eq 1) "$relativePath counted episodes as separate TV shows"
    Assert-True ($sameShow.TvShowItems[0].Seconds -eq 5400) "$relativePath did not aggregate watch time by TV show"

    $episodeWithoutRatingMetadata = [PSCustomObject]@{
        media_type             = 'episode'
        play_duration          = 1800
        watched_status         = 0
        percent_complete       = 50
        rating_key             = 'episode-without-rating'
        grandparent_rating_key = 'show-without-rating'
        grandparent_title      = 'Show Without Rating'
        parent_title           = 'Season 1'
        title                  = 'Unrated Episode'
        year                   = '2026'
        added_at               = 1785800000
        parent_media_index     = 1
        media_index            = 2
    }
    $missingRating = Get-UserStats -History @($episodeWithoutRatingMetadata)
    Assert-True ($missingRating.EpisodeItems.Count -eq 1) "$relativePath rejected an episode without rating metadata"
    Assert-True ([string]::IsNullOrWhiteSpace([string]$missingRating.EpisodeItems[0].ImdbRating)) "$relativePath invented an IMDb rating for missing metadata"

    $missingReleaseRating = New-ReleaseData -RecentItems @($episodeWithoutRatingMetadata)
    Assert-True ($missingReleaseRating.TV.Count -eq 1) "$relativePath rejected a TV release without rating metadata"
    Assert-True ($missingReleaseRating.TV[0].Episodes.Count -eq 1) "$relativePath lost an unrated TV release episode"
    Assert-True ([string]::IsNullOrWhiteSpace([string]$missingReleaseRating.TV[0].Episodes[0].ImdbRating)) "$relativePath invented a release IMDb rating for missing metadata"

    $empty = Get-UserStats -History @()
    Assert-True ($empty.MovieItems -is [object[]]) "$relativePath lost the empty movie array"
    Assert-True ($empty.EpisodeItems -is [object[]]) "$relativePath lost the empty episode array"
    Assert-True ($empty.TvShowItems -is [object[]]) "$relativePath lost the empty TV-show array"
    Assert-True ($empty.MovieItems.Count -eq 0) "$relativePath has unexpected empty-state movies"
    Assert-True ($empty.EpisodeItems.Count -eq 0) "$relativePath has unexpected empty-state episodes"
    Assert-True ($empty.TvShowItems.Count -eq 0) "$relativePath has unexpected empty-state TV shows"

    $threeMovies = Get-UserStats -History @(
        $movie,
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 5400; watched_status = 1
            percent_complete = 100; rating_key = 'movie-2'; title = 'Movie Two'; year = '2026'
        },
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 3600; watched_status = 1
            percent_complete = 100; rating_key = 'movie-3'; title = 'Movie Three'; year = '2026'
        }
    )
    Assert-True ($threeMovies.MovieItems.Count -eq 3) "$relativePath failed the three-movie adaptive branch"

    $heroMovie = [PSCustomObject]@{
        ReleaseKey = 'movie:hero-movie'; RatingKey = 'hero-movie'
        Title = 'Movie Hero'; Type = 'movie'; AddedAt = 100
    }
    $tvRelease = [PSCustomObject]@{
        ReleaseKey = 'show:tv-release'; RatingKey = 'tv-release'
        Title = 'TV Release'; Type = 'show'; AddedAt = 200
    }
    $releaseFixture = [PSCustomObject]@{ Movies = @($heroMovie); TV = @($tvRelease) }
    $movieOnlyHero = Get-HotNewRelease -ReleaseData $releaseFixture -GlobalHistory @(
        [PSCustomObject]@{ media_type = 'episode'; grandparent_rating_key = 'tv-release'; play_duration = 7200 },
        [PSCustomObject]@{ media_type = 'movie'; rating_key = 'hero-movie'; play_duration = 600 }
    )
    Assert-True ($movieOnlyHero.Item.Type -eq 'movie') "$relativePath allowed a TV release to become HOT NEW RELEASE"
    Assert-True (-not $movieOnlyHero.IsTrending) "$relativePath mislabeled a movie release hero as Trending"

    $tvOnlyHero = Get-HotNewRelease -ReleaseData ([PSCustomObject]@{
        Movies = @(); TV = @($tvRelease)
    }) -GlobalHistory @()
    Assert-True ($null -eq $tvOnlyHero) "$relativePath promoted a TV-only release as HOT NEW RELEASE"

    Assert-True ((Get-DynamicPreheader -ReleaseData ([PSCustomObject]@{
        Movies = @(); TV = @($tvRelease, $tvRelease)
    })) -eq '2 new TV titles!') "$relativePath inbox preview counted TV episodes instead of titles"
    $mixedPreheader = '1 new movie ' + [char]0x2022 + ' 1 new TV title!'
    Assert-True ((Get-DynamicPreheader -ReleaseData $releaseFixture) -eq $mixedPreheader) "$relativePath inbox preview lost mixed release counts"

    $twoTitleReleaseFixture = [PSCustomObject]@{
        Movies = @()
        TV = @([PSCustomObject]@{ Title = 'Show One' }, [PSCustomObject]@{ Title = 'Show Two' })
    }
    $plainText = Build-PlainText `
        -User ([PSCustomObject]@{ FriendlyName = 'Viewer' }) `
        -Stats ([PSCustomObject]@{ TotalSeconds = 0; TotalTimeText = '0m'; MovieItems = @(); TvShowItems = @() }) `
        -ReleaseData $twoTitleReleaseFixture `
        -HotRelease $null `
        -TrendingTitle '' `
        -SystemWarmingUp $false `
        -RecentAccess $false `
        -StartLabel 'August 1' `
        -EndLabel 'August 7'
    Assert-True ($plainText.Contains('2 new TV titles!')) "$relativePath plain-text inbox preview lost TV title semantics"
    Assert-True ($plainText.Contains('0 new movies') -and $plainText.Contains('2 TV titles')) "$relativePath plain-text body counted TV episodes instead of shows"

    $source = Get-Content -LiteralPath $path -Raw
    Assert-True ($source -match '\$hotRelease = if \(@\(\$releaseData\.Movies\)\.Count -gt 0\)') "$relativePath does not fall back from a movie-empty release hero"
    Assert-True ($source -match 'Select-Object -First 4') "$relativePath does not cap personal title lists at four"
    Assert-True ($source -match 'width="42" height="42" alt="Movies watched"') "$relativePath does not render the movie GIF at the standard stat-icon size"
    Assert-True ($source -match 'width="42" height="42" alt="TV shows watched"') "$relativePath does not render the TV GIF at the standard stat-icon size"
    Assert-True ($source -notmatch '\$qualifyingPlayCount qualifying') "$relativePath retains qualifying-play copy in Total Watched"
    Assert-True ($source -match '\$assetUri\.Scheme -ieq \$providerUri\.Scheme') "$relativePath can forward a Plex token across an artwork scheme change"
    Assert-True ($source.Contains('The real email layout, across every state.')) "$relativePath lost the Preview All headline"
    Assert-True ($source.Contains('Go ahead, shrink my window.')) "$relativePath lost the responsive Preview All subtitle"

    Write-Host "[PASS] Renderer collection edges: $relativePath"
}

$expectedAssetHashes = @{
    'movies.gif' = '9BCD489463C963C38469771518700308CCADE3965A32EDA18E12DC718950C971'
    'tv.gif'     = '35FFCB45F313953AD0EEF2C7EC852B4B68B0E033E5055BC0926B87EB2EDEF117'
}
$assetRoots = @(
    'docs/assets',
    'platforms/windows/assets',
    'platforms/nas-docker/app/assets-default',
    'platforms/mac-docker/app/assets-default'
)
foreach ($assetRoot in $assetRoots) {
    foreach ($assetName in $expectedAssetHashes.Keys) {
        $assetPath = Join-Path (Join-Path $Root $assetRoot) $assetName
        Assert-True (Test-Path -LiteralPath $assetPath -PathType Leaf) "Missing packaged asset: $assetRoot/$assetName"
        $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash
        Assert-True ($actualHash -eq $expectedAssetHashes[$assetName]) "Packaged $assetName diverges in $assetRoot"
    }
}

Write-Host '[PASS] Supplied movie/TV GIFs are byte-identical across packages'
