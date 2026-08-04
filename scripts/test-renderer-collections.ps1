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
    'Safe-Int',
    'Safe-Int64',
    'New-ReleaseData',
    'Get-HistoryRowPlayCount',
    'Format-WatchTime',
    'Get-UserStats'
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

    $script:Config = [PSCustomObject]@{
        WatchedPercent       = 85
        MinimumEpisodeSeconds = 120
    }

    $movie = [PSCustomObject]@{
        media_type      = 'movie'
        play_duration   = 7200
        watched_status  = 1
        percent_complete = 100
        rating_key      = 'movie-1'
        title           = 'Movie One'
        year            = '2026'
    }
    $episode = [PSCustomObject]@{
        media_type             = 'episode'
        play_duration          = 1800
        watched_status         = 0
        percent_complete       = 50
        rating_key             = 'episode-1'
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
    Assert-True ($oneMovie.EpisodeItems.Count -eq 0) "$relativePath created an unexpected episode"

    $oneEpisode = Get-UserStats -History @($episode)
    Assert-True ($oneEpisode.EpisodeItems -is [object[]]) "$relativePath collapsed one episode into a scalar"
    Assert-True ($oneEpisode.EpisodeItems.Count -eq 1) "$relativePath lost the one-episode item"
    Assert-True ($oneEpisode.MovieItems.Count -eq 0) "$relativePath created an unexpected movie"
    Assert-True ($oneEpisode.EpisodeItems[0].ImdbRating -eq '8.5') "$relativePath lost an available episode IMDb rating"

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
    Assert-True ($empty.MovieItems.Count -eq 0) "$relativePath has unexpected empty-state movies"
    Assert-True ($empty.EpisodeItems.Count -eq 0) "$relativePath has unexpected empty-state episodes"

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

    Write-Host "[PASS] Renderer collection edges: $relativePath"
}
