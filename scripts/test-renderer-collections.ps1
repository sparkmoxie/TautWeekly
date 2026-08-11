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
    'Get-DesignProviderRating',
    'Get-DesignProviderRatingHtml',
    'Convert-DesignRatingPercent',
    'Find-DesignProviderRatingsRecursive',
    'ConvertTo-DesignGenreList',
    'Add-DesignRatingMetadata',
    'Get-DesignEpisodeImdbRating',
    'Enrich-TvEpisodeMetadata',
    'Get-DesignRatingLine',
    'Get-StatsMovieRatingHtml',
    'Get-TvEpisodeLinesHtml',
    'Get-DesignRtIconUrl',
    'HtmlEncode',
    'Truncate-Text',
    'Get-PlexMetadataProviderBaseUrl',
    'Get-PlexHostedMetadataLookupPath',
    'Get-PlexHostedMetadataMatchPayload',
    'Get-PlexHostedMetadataItemFromResponse',
    'Test-PlexHostedMetadataExactMatch',
    'Get-PlexHostedMetadata',
    'Get-PlexWatchBaseUrl',
    'Get-PlexWatchRatings',
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
    'Add-UserStatsMediaMetadata',
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

    $flatCritic = ''
    $flatAudience = ''
    $flatImdb = ''
    $flatProvider = ''
    $flatProviderValue = ''
    Find-DesignProviderRatingsRecursive `
        -Node ([PSCustomObject]@{
            rating = '5.3'
            ratingImage = 'rottentomatoes://image.rating.rotten'
            audienceRating = '4.0'
            audienceRatingImage = 'rottentomatoes://image.rating.spilled'
        }) `
        -Critic ([ref]$flatCritic) `
        -Audience ([ref]$flatAudience) `
        -Imdb ([ref]$flatImdb) `
        -Provider ([ref]$flatProvider) `
        -ProviderValue ([ref]$flatProviderValue)
    Assert-True ($flatCritic -eq '53' -and $flatAudience -eq '40' -and [string]::IsNullOrWhiteSpace($flatImdb) -and [string]::IsNullOrWhiteSpace($flatProvider)) "$relativePath did not parse Tautulli's flattened low-score RT export"

    $flatShowCritic = ''
    $flatShowAudience = ''
    $flatShowImdb = ''
    $flatShowProvider = ''
    $flatShowProviderValue = ''
    Find-DesignProviderRatingsRecursive `
        -Node ([PSCustomObject]@{
            rating = ''
            audienceRating = '7.4'
            audienceRatingImage = 'themoviedb://image.rating'
        }) `
        -Critic ([ref]$flatShowCritic) `
        -Audience ([ref]$flatShowAudience) `
        -Imdb ([ref]$flatShowImdb) `
        -Provider ([ref]$flatShowProvider) `
        -ProviderValue ([ref]$flatShowProviderValue)
    Assert-True ($flatShowProvider -eq 'TMDB' -and $flatShowProviderValue -eq '7.4' -and [string]::IsNullOrWhiteSpace($flatShowImdb) -and [string]::IsNullOrWhiteSpace($flatShowCritic) -and [string]::IsNullOrWhiteSpace($flatShowAudience)) "$relativePath did not parse Tautulli's official TV selected-provider export shape"

    $nestedCritic = ''
    $nestedAudience = ''
    $nestedImdb = ''
    $nestedProvider = ''
    $nestedProviderValue = ''
    Find-DesignProviderRatingsRecursive `
        -Node ([PSCustomObject]@{
            Rating = @(
                [PSCustomObject]@{
                    image = 'rottentomatoes://image.rating.rotten'
                    type = 'critic'
                    value = '5.3'
                },
                [PSCustomObject]@{
                    image = 'rottentomatoes://image.rating.spilled'
                    type = 'audience'
                    value = '4.0'
                },
                [PSCustomObject]@{
                    image = 'imdb://image.rating'
                    type = 'critic'
                    value = '7.4'
                }
            )
        }) `
        -Critic ([ref]$nestedCritic) `
        -Audience ([ref]$nestedAudience) `
        -Imdb ([ref]$nestedImdb) `
        -Provider ([ref]$nestedProvider) `
        -ProviderValue ([ref]$nestedProviderValue)
    Assert-True ($nestedCritic -eq '53' -and $nestedAudience -eq '40' -and $nestedImdb -eq '7.4' -and [string]::IsNullOrWhiteSpace($nestedProvider)) "$relativePath did not parse nested provider-labelled entries"

    $unlabelledCritic = ''
    $unlabelledAudience = ''
    $unlabelledImdb = ''
    $unlabelledProvider = ''
    $unlabelledProviderValue = ''
    Find-DesignProviderRatingsRecursive `
        -Node ([PSCustomObject]@{ rating = '9.9'; audienceRating = '9.8' }) `
        -Critic ([ref]$unlabelledCritic) `
        -Audience ([ref]$unlabelledAudience) `
        -Imdb ([ref]$unlabelledImdb) `
        -Provider ([ref]$unlabelledProvider) `
        -ProviderValue ([ref]$unlabelledProviderValue)
    Assert-True (
        [string]::IsNullOrWhiteSpace($unlabelledCritic) -and
        [string]::IsNullOrWhiteSpace($unlabelledAudience) -and
        [string]::IsNullOrWhiteSpace($unlabelledImdb) -and
        [string]::IsNullOrWhiteSpace($unlabelledProvider) -and
        [string]::IsNullOrWhiteSpace($unlabelledProviderValue)
    ) "$relativePath mislabeled provider-free numeric ratings"

    $tvdb = Get-DesignProviderRating -RatingImage 'thetvdb://image.rating' -RatingValue '8.2'
    Assert-True ($tvdb.Provider -eq 'TVDB' -and $tvdb.Value -eq '8.2') "$relativePath did not recognize a provider-labelled TVDB rating"
    $unknown = Get-DesignProviderRating -RatingImage 'unknown://image.rating' -RatingValue '9.9'
    Assert-True ([string]::IsNullOrWhiteSpace($unknown.Provider)) "$relativePath accepted an unknown rating provider"
    $invalid = Get-DesignProviderRating -RatingImage 'themoviedb://image.rating' -RatingValue '12.4'
    Assert-True ([string]::IsNullOrWhiteSpace($invalid.Provider)) "$relativePath accepted an out-of-range provider rating"

    # Provider-only collection tests isolate the legacy best-effort path. The
    # persistent cache has its own exact-ID, privacy, and lifecycle suite.
    function Get-TautWeeklyDeletedItemCacheEntry {
        param([string]$MediaType, [string]$MetadataGuid, [switch]$LogHit)
        return $null
    }

    $posterProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-poster-probe-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $posterProbeRoot | Out-Null
        $script:PosterDir = $posterProbeRoot
        $script:TautulliDefaultPosterHash = ''
        $script:posterProbeOutFile = ''
        $script:posterProbeRequestCount = 0
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
            $script:posterProbeRequestCount++
            [IO.File]::WriteAllBytes($OutFile, [Text.Encoding]::UTF8.GetBytes(('GENERIC-POSTER' * 64)))
        }

        $posterHash = Get-TautulliDefaultPosterHash
        $cachedPosterHash = Get-TautulliDefaultPosterHash
        $probeWarningText = $script:posterProbeWarnings -join '; '
        Assert-True (-not [string]::IsNullOrWhiteSpace($posterHash)) "$relativePath could not fingerprint Tautulli's generic poster on this platform: $probeWarningText"
        Assert-True ($cachedPosterHash -eq $posterHash -and $script:posterProbeRequestCount -eq 1) "$relativePath did not cache Tautulli's generic-poster fingerprint"
        Assert-True ($script:posterProbeWarnings.Count -eq 0) "$relativePath logged an unexpected generic-poster probe warning: $probeWarningText"
        Assert-True (-not ([IO.Path]::GetFileName($script:posterProbeOutFile)).StartsWith('.')) "$relativePath used a Unix-hidden generic-poster probe"
        Assert-True (-not (Test-Path -LiteralPath $script:posterProbeOutFile)) "$relativePath did not clean up the generic-poster probe"
    }
    finally {
        Remove-Item -LiteralPath $posterProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $script:PlexWatchRatingCache = @{}
    $script:plexWatchRequestCount = 0
    $env:TAUTWEEKLY_TEST_PLEX_WATCH_URL = 'http://127.0.0.1:32123/watch'
    function Invoke-WebRequest {
        param(
            [switch]$UseBasicParsing,
            [string]$Uri,
            [hashtable]$Headers,
            [int]$TimeoutSec
        )
        Assert-True ($Uri -eq 'http://127.0.0.1:32123/watch/movie/deleted-movie') "$relativePath did not use the exact validated Plex slug"
        Assert-True (-not $Headers.ContainsKey('X-Plex-Token')) "$relativePath forwarded a Plex token to the public rating page"
        Assert-True ([string]$Headers['Accept-Language'] -eq 'en-US,en;q=0.9') "$relativePath did not request stable English provider labels"
        $script:plexWatchRequestCount++
        return [PSCustomObject]@{
            Content = '<div data-testid="metadata-ratings"><span title="53% critic rating on Rotten Tomatoes">53%</span><span title="40% audience rating on Rotten Tomatoes">40%</span><span title="5.4 audience rating on IMDb">5.4</span></div>'
        }
    }
    try {
        $watchRatings = Get-PlexWatchRatings -Slug 'deleted-movie' -MediaType 'movie'
        $cachedWatchRatings = Get-PlexWatchRatings -Slug 'deleted-movie' -MediaType 'movie'
        Assert-True ($watchRatings.RtCritic -eq '53' -and $watchRatings.RtAudience -eq '40') "$relativePath did not parse provider-labelled RT ratings"
        Assert-True ($watchRatings.Imdb -eq '5.4') "$relativePath did not parse a provider-labelled IMDb rating"
        Assert-True ($cachedWatchRatings.RtCritic -eq '53' -and $script:plexWatchRequestCount -eq 1) "$relativePath did not cache public Plex ratings"
        $unsafeSlugRatings = Get-PlexWatchRatings -Slug '../private-title' -MediaType 'movie'
        Assert-True ([string]::IsNullOrWhiteSpace($unsafeSlugRatings.RtCritic) -and $script:plexWatchRequestCount -eq 1) "$relativePath accepted an unsafe public-rating slug"
    }
    finally {
        Remove-Item Env:TAUTWEEKLY_TEST_PLEX_WATCH_URL -ErrorAction SilentlyContinue
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
    Assert-True ($oneEpisode.TvShowItems[0].MetadataParentIndex -eq 1 -and $oneEpisode.TvShowItems[0].MetadataIndex -eq 1) "$relativePath detached the representative episode indexes from its GUID"
    Assert-True ($oneEpisode.TvShowItems[0].ShowTitle -eq 'Show One') "$relativePath lost the grouped TV show title"
    Assert-True ($oneEpisode.EpisodeItems[0].ImdbRating -eq '8.5') "$relativePath lost an available episode IMDb rating"

    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'plex://movie/5d123abc?lang=en' -MediaType 'movie') -eq '/library/metadata/5d123abc') "$relativePath did not normalize a retained Plex GUID"
    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'com.plexapp.agents.themoviedb://12345?lang=en' -MediaType 'movie') -eq '/library/metadata/matches?guid=tmdb%3A%2F%2F12345&type=1') "$relativePath did not normalize a legacy TMDB movie GUID"
    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'com.plexapp.agents.tmdb://54321?lang=en' -MediaType 'movie') -eq '/library/metadata/matches?guid=tmdb%3A%2F%2F54321&type=1') "$relativePath did not normalize the alternate legacy TMDB movie agent"
    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'com.plexapp.agents.themoviedb://24680/1/2?lang=en' -MediaType 'show') -eq '/library/metadata/matches?guid=tmdb%3A%2F%2F24680&type=2') "$relativePath did not reduce a legacy TMDB episode GUID to its exact show identifier"
    Assert-True ((Get-PlexHostedMetadataLookupPath -MetadataGuid 'com.plexapp.agents.thetvdb://999/1/2?lang=en' -MediaType 'show') -eq '/library/metadata/matches?guid=tvdb%3A%2F%2F999&type=2') "$relativePath did not reduce a legacy TVDB episode GUID to its exact show identifier"
    Assert-True ([string]::IsNullOrWhiteSpace((Get-PlexHostedMetadataLookupPath -MetadataGuid 'tmdb://private-title' -MediaType 'movie'))) "$relativePath accepted a non-numeric external metadata identifier"
    Assert-True ([string]::IsNullOrWhiteSpace((Get-PlexHostedMetadataLookupPath -MetadataGuid 'local://private-library-item' -MediaType 'movie'))) "$relativePath sent a private local-library GUID to hosted metadata"

    $modernMoviePayload = Get-PlexHostedMetadataMatchPayload -MetadataGuid 'plex://movie/5d123abc?lang=en' -MediaType 'movie' -LookupPath '/library/metadata/5d123abc' -MatchTitle 'Sanitized Movie' -MatchYear '2024'
    $modernEpisodePayload = Get-PlexHostedMetadataMatchPayload -MetadataGuid 'plex://episode/5d456def?lang=en' -MediaType 'show' -LookupPath '/library/metadata/5d456def' -MatchTitle 'Sanitized Show' -ParentIndex 2 -Index 3
    $legacyMoviePayload = Get-PlexHostedMetadataMatchPayload -MetadataGuid 'com.plexapp.agents.tmdb://12345?lang=en' -MediaType 'movie' -LookupPath '/library/metadata/matches?guid=tmdb%3A%2F%2F12345&type=1' -MatchTitle 'Sanitized Movie' -MatchYear '2024'
    Assert-True ([string]$modernMoviePayload.guid -eq 'plex://movie/5d123abc' -and [int]$modernMoviePayload.type -eq 1 -and [string]$modernMoviePayload.title -eq 'Sanitized Movie' -and [int]$modernMoviePayload.year -eq 2024) "$relativePath did not build a provider-valid modern movie payload"
    Assert-True ([string]$modernEpisodePayload.guid -eq 'plex://episode/5d456def' -and [int]$modernEpisodePayload.type -eq 4 -and [string]$modernEpisodePayload.grandparentTitle -eq 'Sanitized Show' -and [int]$modernEpisodePayload.parentIndex -eq 2 -and [int]$modernEpisodePayload.index -eq 3) "$relativePath did not preserve the required episode match context"
    Assert-True ([string]$legacyMoviePayload.guid -eq 'tmdb://12345' -and [int]$legacyMoviePayload.type -eq 1 -and [string]$legacyMoviePayload.title -eq 'Sanitized Movie') "$relativePath did not build a provider-valid legacy movie payload"
    Assert-True ($null -eq (Get-PlexHostedMetadataMatchPayload -MetadataGuid 'plex://episode/5d456def' -MediaType 'show' -LookupPath '/library/metadata/5d456def' -MatchTitle 'Sanitized Show')) "$relativePath sent an incomplete episode match payload"
    Assert-True (Test-PlexHostedMetadataExactMatch -Metadata ([PSCustomObject]@{ guid = 'plex://movie/5d123abc' }) -MatchPayload $modernMoviePayload) "$relativePath rejected an exact canonical Plex GUID"
    Assert-True (Test-PlexHostedMetadataExactMatch -Metadata ([PSCustomObject]@{ Guid = @([PSCustomObject]@{ id = 'tmdb://12345' }) }) -MatchPayload $legacyMoviePayload) "$relativePath rejected an exact external provider GUID"
    Assert-True (Test-PlexHostedMetadataExactMatch -Metadata ([PSCustomObject]@{ type = 'movie'; title = 'Sanitized Movie' }) -MatchPayload $legacyMoviePayload) "$relativePath rejected a compatible exact external lookup response without Guid[]"
    Assert-True (-not (Test-PlexHostedMetadataExactMatch -Metadata ([PSCustomObject]@{ Guid = @([PSCustomObject]@{ id = 'tmdb://99999' }); type = 'movie'; title = 'Sanitized Movie' }) -MatchPayload $legacyMoviePayload)) "$relativePath accepted a mismatched returned external GUID"
    Assert-True (-not (Test-PlexHostedMetadataExactMatch -Metadata ([PSCustomObject]@{ guid = 'plex://movie/different' }) -MatchPayload $modernMoviePayload)) "$relativePath accepted a title-hinted response with the wrong canonical GUID"

    $script:PlexHostedMetadataCache = @{}
    $script:hostedMetadataRequestCount = 0
    $script:hostedMetadataWarnings = New-Object System.Collections.Generic.List[string]
    $env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL = 'http://127.0.0.1:32123/hosted'
    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        if ($Level -eq 'WARN') { $script:hostedMetadataWarnings.Add($Message) }
    }
    function Get-DesignPlexContext {
        return [PSCustomObject]@{ Token = 'virtual-plex-token' }
    }
    function Invoke-RestMethod {
        param(
            [string]$Uri,
            [hashtable]$Headers,
            [string]$Method,
            [string]$Body,
            [string]$ContentType,
            [int]$TimeoutSec
        )
        Assert-True ([string]$Headers['X-Plex-Token'] -eq 'virtual-plex-token') "$relativePath omitted the administrator Plex token from hosted metadata"
        $script:hostedMetadataRequestCount++

        if ($Uri -eq 'http://127.0.0.1:32123/hosted/library/metadata/noexactmatch') {
            Assert-True ($Method -eq 'Get') "$relativePath changed the direct retained Plex GUID request method"
            Assert-True ([string]::IsNullOrWhiteSpace($Body)) "$relativePath sent a request body with a direct retained Plex GUID"
            return [PSCustomObject]@{ MediaContainer = [PSCustomObject]@{ Metadata = @() } }
        }

        if ($Uri -eq 'http://127.0.0.1:32123/hosted/library/metadata/matches?guid=tmdb%3A%2F%2F12345&type=1') {
            Assert-True ($Method -eq 'Get') "$relativePath did not preserve the compatible query-form exact match"
            return [PSCustomObject]@{ MediaContainer = [PSCustomObject]@{ Metadata = @() } }
        }

        Assert-True ($Uri -eq 'http://127.0.0.1:32123/hosted/library/metadata/matches') "$relativePath changed the provider-contract exact-match endpoint"
        Assert-True ($Method -eq 'Post') "$relativePath did not retry an empty query match with the provider POST contract"
        Assert-True ($ContentType -eq 'application/json') "$relativePath omitted the exact-match JSON content type"
        $payload = $Body | ConvertFrom-Json
        if ([string]$payload.guid -eq 'plex://movie/noexactmatch') {
            Assert-True ([int]$payload.type -eq 1) "$relativePath changed the retained modern movie type in the POST body"
            Assert-True ([string]$payload.title -eq 'Missing Movie') "$relativePath omitted the required retained movie title hint"
            return [PSCustomObject]@{ MediaContainer = [PSCustomObject]@{ Metadata = @() } }
        }
        Assert-True ([string]$payload.guid -eq 'tmdb://12345') "$relativePath changed the retained external identifier in the POST body"
        Assert-True ([int]$payload.type -eq 1) "$relativePath changed the retained legacy movie type in the POST body"
        Assert-True ([string]$payload.title -eq 'Sanitized Movie') "$relativePath omitted the required retained legacy movie title hint"
        return [PSCustomObject]@{
            MediaContainer = [PSCustomObject]@{
                Metadata = @([PSCustomObject]@{
                    type = 'movie'
                    title = 'Sanitized exact-ID match'
                    Guid = @([PSCustomObject]@{ id = 'tmdb://12345' })
                })
            }
        }
    }
    try {
        $emptyHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'plex://movie/noexactmatch' -MediaType 'movie' -MatchTitle 'Missing Movie'
        $cachedEmptyHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'plex://movie/noexactmatch' -MediaType 'movie' -MatchTitle 'Missing Movie'
        Assert-True ($null -eq $emptyHostedMetadata -and $null -eq $cachedEmptyHostedMetadata) "$relativePath accepted an empty hosted metadata response"
        Assert-True ($script:hostedMetadataRequestCount -eq 2) "$relativePath did not retry and cache an empty exact-match response"
        Assert-True (@($script:hostedMetadataWarnings | Where-Object { $_ -like '*returned no exact match*' }).Count -eq 1) "$relativePath did not report an empty exact-match response exactly once"

        $legacyHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'com.plexapp.agents.tmdb://12345?lang=en' -MediaType 'movie' -MatchTitle 'Sanitized Movie'
        $cachedLegacyHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'com.plexapp.agents.tmdb://12345?lang=en' -MediaType 'movie' -MatchTitle 'Sanitized Movie'
        Assert-True ($null -ne $legacyHostedMetadata -and $legacyHostedMetadata.title -eq 'Sanitized exact-ID match') "$relativePath did not recover an empty query match through the provider POST contract"
        Assert-True ($cachedLegacyHostedMetadata -eq $legacyHostedMetadata) "$relativePath did not cache the provider POST match"
        Assert-True ($script:hostedMetadataRequestCount -eq 4) "$relativePath did not perform exactly one GET compatibility attempt and one POST contract retry"
        Assert-True (@($script:hostedMetadataWarnings | Where-Object { $_ -like '*returned no exact match*' }).Count -eq 1) "$relativePath warned after a successful provider POST retry"

        $unsupportedHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'local://private-library-item' -MediaType 'movie'
        $cachedUnsupportedHostedMetadata = Get-PlexHostedMetadata -MetadataGuid 'local://private-library-item' -MediaType 'movie'
        Assert-True ($null -eq $unsupportedHostedMetadata -and $null -eq $cachedUnsupportedHostedMetadata) "$relativePath accepted an unsupported private-library GUID"
        Assert-True ($script:hostedMetadataRequestCount -eq 4) "$relativePath sent an unsupported private-library GUID to hosted metadata"
        Assert-True (@($script:hostedMetadataWarnings | Where-Object { $_ -like '*provider format is unsupported*' }).Count -eq 1) "$relativePath did not report an unsupported retained GUID exactly once"
        Assert-True (-not (($script:hostedMetadataWarnings -join '; ').Contains('private-library-item'))) "$relativePath leaked a retained private-library identifier into diagnostics"
    }
    finally {
        Remove-Item Env:TAUTWEEKLY_TEST_PLEX_METADATA_PROVIDER_URL -ErrorAction SilentlyContinue
    }

    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }
    $script:providerDirectCalls = 0
    $script:providerExportCalls = 0
    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters = @{})
        Assert-True ($Command -eq 'get_metadata') "$relativePath used an unexpected Tautulli request for selected-provider metadata"
        if ([string]$Parameters.rating_key -eq 'preferred-provider-movie') {
            return [PSCustomObject]@{
                rating = '8.1'
                rating_image = 'imdb://image.rating'
                audience_rating = ''
                audience_rating_image = ''
            }
        }
        if ([string]$Parameters.rating_key -eq 'fallback-provider-movie') {
            return [PSCustomObject]@{
                rating = '6.6'
                rating_image = 'imdb://image.rating'
                audience_rating = ''
                audience_rating_image = ''
            }
        }
        Assert-True ([string]$Parameters.rating_key -eq 'selected-provider-show') "$relativePath requested an unexpected selected-provider rating key"
        return [PSCustomObject]@{
            rating = ''
            rating_image = ''
            audience_rating = '7.4'
            audience_rating_image = 'themoviedb://image.rating'
        }
    }
    function Get-DesignPlexMetadata {
        param([string]$RatingKey)
        $script:providerDirectCalls++
        if ($RatingKey -eq 'preferred-provider-movie') {
            return [PSCustomObject]@{
                Rating = @(
                    [PSCustomObject]@{ image = 'rottentomatoes://image.rating.rotten'; type = 'critic'; value = '5.3' },
                    [PSCustomObject]@{ image = 'rottentomatoes://image.rating.spilled'; type = 'audience'; value = '4.0' }
                )
            }
        }
        if ($RatingKey -eq 'selected-provider-show') {
            return [PSCustomObject]@{
                Rating = @(
                    [PSCustomObject]@{ image = 'imdb://image.rating'; type = 'audience'; value = '8.4' }
                )
            }
        }
        return $null
    }
    function Get-DesignRichExport {
        param([string]$RatingKey, [string]$MediaType, [switch]$NeedLogo)
        $script:providerExportCalls++
        return [PSCustomObject]@{ RtCritic = ''; RtAudience = ''; Imdb = ''; Provider = ''; ProviderValue = '' }
    }
    $selectedProviderShow = [PSCustomObject]@{
        RatingKey = 'selected-provider-show'
        Type = 'show'
        Title = 'Selected Provider Show'
    }
    $selectedProviderMovie = [PSCustomObject]@{
        RatingKey = 'preferred-provider-movie'
        Type = 'movie'
        Title = 'Preferred Provider Movie'
        Year = '2026'
    }
    $fallbackProviderMovie = [PSCustomObject]@{
        RatingKey = 'fallback-provider-movie'
        Type = 'movie'
        Title = 'Fallback Provider Movie'
        Year = '2026'
    }
    Add-DesignRatingMetadata -ReleaseData ([PSCustomObject]@{ Movies = @($selectedProviderMovie, $fallbackProviderMovie); TV = @($selectedProviderShow) })
    Assert-True ($selectedProviderShow.DesignRatingProvider -eq 'TMDB' -and $selectedProviderShow.DesignRatingValue -eq '7.4') "$relativePath ignored Tautulli's selected TV audience-rating provider"
    Assert-True ($selectedProviderShow.DesignImdbRating -eq '8.4') "$relativePath let a selected TMDB score prevent an available show IMDb fallback"
    Assert-True ($selectedProviderMovie.DesignRtCritic -eq '53' -and $selectedProviderMovie.DesignRtAudience -eq '40') "$relativePath let a selected movie IMDb score prevent available Rotten Tomatoes ratings"
    Assert-True ($fallbackProviderMovie.DesignImdbRating -eq '6.6') "$relativePath did not retain labelled IMDb as the final movie fallback"
    Assert-True ($script:providerDirectCalls -eq 3 -and $script:providerExportCalls -eq 1) "$relativePath did not exhaust preferred rating sources before accepting selected-provider fallbacks"

    $preferredMovieLine = Get-DesignRatingLine -Item $selectedProviderMovie -ImageMode Preview
    Assert-True ($preferredMovieLine.Contains('53%') -and $preferredMovieLine.Contains('40%') -and -not $preferredMovieLine.Contains('8.1')) "$relativePath did not render RT exclusively when a movie also retained an IMDb fallback"
    $preferredMovieStats = Get-StatsMovieRatingHtml -Item $selectedProviderMovie -ImageMode Preview
    Assert-True ($preferredMovieStats.Contains('53%') -and $preferredMovieStats.Contains('40%') -and -not $preferredMovieStats.Contains('8.1')) "$relativePath personal stats did not prefer RT over a movie IMDb fallback"
    $fallbackMovieLine = Get-DesignRatingLine -Item $fallbackProviderMovie -ImageMode Preview
    Assert-True ($fallbackMovieLine.Contains('IMDb') -and $fallbackMovieLine.Contains('6.6')) "$relativePath did not render labelled IMDb when no movie RT rating exists"

    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters = @{})
        Assert-True ($Command -eq 'get_metadata' -and [string]$Parameters.rating_key -eq 'selected-provider-episode') "$relativePath requested unexpected episode metadata"
        return [PSCustomObject]@{
            media_index = 2
            parent_media_index = 1
            rating = ''
            rating_image = ''
            audience_rating = '7.4'
            audience_rating_image = 'themoviedb://image.rating'
        }
    }
    function Get-DesignPlexMetadata {
        param([string]$RatingKey)
        Assert-True ($RatingKey -eq 'selected-provider-episode') "$relativePath requested IMDb for the wrong episode"
        return [PSCustomObject]@{
            Rating = @(
                [PSCustomObject]@{ image = 'themoviedb://image.rating'; type = 'audience'; value = '7.4' },
                [PSCustomObject]@{ image = 'imdb://image.rating'; type = 'audience'; value = '8.6' }
            )
        }
    }
    function Invoke-DesignPlexLegacyXml { param([string]$Path) throw "$relativePath unnecessarily used legacy XML after finding episode IMDb" }
    $selectedProviderEpisode = [PSCustomObject]@{
        RatingKey = 'selected-provider-episode'
        Title = 'Sanitized Episode'
        Season = 1
        Episode = 2
        ImdbRating = ''
        RatingImage = ''
    }
    $episodeShow = [PSCustomObject]@{
        Title = 'Sanitized Show'
        Episodes = @($selectedProviderEpisode)
    }
    Enrich-TvEpisodeMetadata -ReleaseData ([PSCustomObject]@{ TV = @($episodeShow) })
    Assert-True ($selectedProviderEpisode.ImdbRating -eq '8.6') "$relativePath let a selected TMDB score prevent exact-episode IMDb recovery"
    $episodeHtml = Get-TvEpisodeLinesHtml -Item $episodeShow -ImageMode Preview
    Assert-True ($episodeHtml.Contains('IMDb') -and $episodeHtml.Contains('8.6') -and -not $episodeHtml.Contains('TMDB') -and -not $episodeHtml.Contains('7.4')) "$relativePath rendered a non-IMDb provider on an episode row"

    function Invoke-TautulliApi { param([string]$Command, [hashtable]$Parameters = @{}) throw 'Simulated deleted metadata' }
    function Get-DesignPlexMetadata { param([string]$RatingKey) return $null }
    function Get-DesignRichExport {
        param([string]$RatingKey, [string]$MediaType, [switch]$NeedLogo)
        return [PSCustomObject]@{ RtCritic = ''; RtAudience = ''; Imdb = ''; Provider = ''; ProviderValue = '' }
    }
    function Get-PlexHostedMetadata {
        param([string]$MetadataGuid, [string]$MediaType, [string]$MatchTitle, [string]$MatchYear, [int]$ParentIndex, [int]$Index)
        Assert-True ($MetadataGuid -eq 'plex://movie/deleted-movie-guid') "$relativePath changed the retained GUID during hosted enrichment"
        Assert-True ($MediaType -eq 'movie') "$relativePath used the wrong hosted metadata type"
        Assert-True ($MatchTitle -eq 'Deleted Movie') "$relativePath omitted the retained movie title match hint"
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
        param([string]$MetadataGuid, [string]$MediaType, [string]$MatchTitle, [string]$MatchYear, [int]$ParentIndex, [int]$Index)
        Assert-True ($MetadataGuid -eq 'plex://episode/deleted-episode-guid') "$relativePath changed the retained episode GUID during hosted enrichment"
        Assert-True ($MediaType -eq 'show') "$relativePath used the wrong hosted TV metadata type"
        Assert-True ($MatchTitle -eq 'Deleted Show' -and $ParentIndex -eq 1 -and $Index -eq 2) "$relativePath omitted the retained TV episode match hints"
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
        MetadataParentIndex = 1
        MetadataIndex = 2
    }
    Add-DesignRatingMetadata -ReleaseData ([PSCustomObject]@{ Movies = @(); TV = @($deletedShowItem) })
    Assert-True ($deletedShowItem.DesignImdbRating -eq '8.4') "$relativePath did not restore the deleted TV IMDb rating"
    Assert-True ([string]::IsNullOrWhiteSpace($deletedShowItem.DesignRtCritic)) "$relativePath mislabeled a TV IMDb rating as Rotten Tomatoes"
    Assert-True ([string]::IsNullOrWhiteSpace($deletedShowItem.DesignRtAudience)) "$relativePath invented a TV Rotten Tomatoes audience rating"

    $script:statsMetadataInput = $null
    function Add-DesignRatingMetadata {
        param([object]$ReleaseData)
        $script:statsMetadataInput = $ReleaseData
    }
    Add-UserStatsMediaMetadata -Stats ([PSCustomObject]@{
        MovieItems  = @($deletedMovieItem)
        TvShowItems = @($deletedShowItem)
    })
    Assert-True ($null -ne $script:statsMetadataInput) "$relativePath skipped personal-stat metadata enrichment"
    Assert-True (@($script:statsMetadataInput.Movies).Count -eq 1) "$relativePath lost watched movies during personal-stat enrichment"
    Assert-True (@($script:statsMetadataInput.TV).Count -eq 1) "$relativePath omitted watched TV shows from IMDb enrichment"

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
    Assert-True ($source -match 'Get-OptionalStringProperty -InputObject \$item -Name "DesignImdbRating"') "$relativePath does not render enriched TV IMDb ratings in personal stats"
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
