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
    'Safe-Int',
    'Format-WatchTime',
    'Get-HistoryRowPlayCount',
    'Get-BingeChampion',
    'Get-BingeChampionDisplay',
    'Get-BingeChampionTitleBreakdown'
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
        throw "Cannot test Binge Champion with parser errors: $relativePath"
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
        WatchedPercent         = 85
        MinimumEpisodeSeconds = 120
    }

    $history = @(
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 14400; watched_status = 1
            percent_complete = 100; group_count = 2; rating_key = 'movie-1'
            title = 'Private Movie'; user_id = '10'; friendly_name = 'Private Winner'
        },
        [PSCustomObject]@{
            media_type = 'episode'; play_duration = 7200; watched_status = 0
            percent_complete = 50; group_count = 1; grandparent_rating_key = 'show-1'
            grandparent_title = 'Private Show'; title = 'Episode'
            user_id = '10'; friendly_name = 'Private Winner'
        },
        [PSCustomObject]@{
            media_type = 'episode'; play_duration = 18000; watched_status = 0
            percent_complete = 50; group_count = 10; grandparent_rating_key = 'show-2'
            grandparent_title = 'Runner Show'; title = 'Episode'
            user_id = '20'; friendly_name = 'Runner With More Plays'
        },
        [PSCustomObject]@{
            media_type = 'movie'; play_duration = 21600; watched_status = 1
            percent_complete = 100; group_count = 2; rating_key = 'movie-3'
            title = 'Tie Movie'; user_id = '30'; friendly_name = 'Runner With Equal Time'
        }
    )

    $champion = Get-BingeChampion -GlobalHistory $history
    Assert-True ($null -ne $champion) "$relativePath did not select a Binge Champion"
    Assert-True ($champion.UserId -eq '10') "$relativePath did not rank watch time first and plays second"
    Assert-True ($champion.Seconds -eq 21600) "$relativePath returned the wrong aggregate watch time"
    Assert-True ($champion.MoviePlays -eq 2) "$relativePath returned the wrong movie-play count"
    Assert-True ($champion.TvPlays -eq 1) "$relativePath returned the wrong TV-play count"
    Assert-True ($champion.QualifyingTitles -eq 2) "$relativePath did not count one movie and one TV show as two qualifying titles"
    Assert-True ($champion.QualifyingMovies -eq 1) "$relativePath returned the wrong unique movie count"
    Assert-True ($champion.QualifyingTvShows -eq 1) "$relativePath returned the wrong unique TV-show count"
    Assert-True ($champion.TotalTimeText -eq '6h 0m') "$relativePath returned the wrong watch-time label"

    $winnerView = Get-BingeChampionDisplay -BingeChampion $champion -User ([PSCustomObject]@{
        UserId = '10'; FriendlyName = 'Private Winner'
    })
    $otherView = Get-BingeChampionDisplay -BingeChampion $champion -User ([PSCustomObject]@{
        UserId = '20'; FriendlyName = 'Runner With More Plays'
    })

    Assert-True $winnerView.IsWinner "$relativePath did not mark the winning recipient"
    Assert-True (-not $otherView.IsWinner) "$relativePath marked a non-winner as the champion"
    Assert-True ($winnerView.MoviePlays -eq 2 -and $otherView.MoviePlays -eq 2) "$relativePath did not share the movie aggregate"
    Assert-True ($winnerView.TvPlays -eq 1 -and $otherView.TvPlays -eq 1) "$relativePath did not share the TV aggregate"
    Assert-True ($winnerView.QualifyingTitles -eq 2 -and $otherView.QualifyingTitles -eq 2) "$relativePath did not share the qualifying-title aggregate"
    Assert-True ($winnerView.QualifyingMovies -eq 1 -and $otherView.QualifyingMovies -eq 1) "$relativePath did not share the unique movie aggregate"
    Assert-True ($winnerView.QualifyingTvShows -eq 1 -and $otherView.QualifyingTvShows -eq 1) "$relativePath did not share the unique TV-show aggregate"
    Assert-True ($winnerView.TotalTimeText -eq '6h 0m' -and $otherView.TotalTimeText -eq '6h 0m') "$relativePath did not share the watch-time aggregate"

    $bullet = [char]0x2022
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ QualifyingMovies = 1; QualifyingTvShows = 0 })) -eq '1 movie') "$relativePath lost singular movie copy"
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ QualifyingMovies = 2; QualifyingTvShows = 0 })) -eq '2 movies') "$relativePath lost plural movie copy"
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ QualifyingMovies = 0; QualifyingTvShows = 1 })) -eq '1 TV show') "$relativePath lost singular TV-show copy"
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ QualifyingMovies = 0; QualifyingTvShows = 3 })) -eq '3 TV shows') "$relativePath lost plural TV-show copy"
    Assert-True ((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ QualifyingMovies = 5; QualifyingTvShows = 2 })) -eq "5 movies $bullet 2 TV shows") "$relativePath lost the mixed title breakdown"
    Assert-True ([string]::IsNullOrWhiteSpace((Get-BingeChampionTitleBreakdown -BingeDisplay ([PSCustomObject]@{ QualifyingMovies = 0; QualifyingTvShows = 0 })))) "$relativePath rendered zero-count categories"

    $legacyDisplay = Get-BingeChampionDisplay -BingeChampion ([PSCustomObject]@{
        UserId = '10'; FriendlyName = 'Private Winner'; Seconds = 21600
        TotalTimeText = '6h 0m'; MoviePlays = 20; TvPlays = 30
    }) -User ([PSCustomObject]@{ UserId = '20'; FriendlyName = 'Observer' })
    Assert-True ($legacyDisplay.QualifyingTitles -eq 0) "$relativePath substituted play counts for a missing title count"
    Assert-True ($legacyDisplay.QualifyingMovies -eq 0 -and $legacyDisplay.QualifyingTvShows -eq 0) "$relativePath substituted play counts for missing media-title counts"

    foreach ($privateProperty in @('UserId', 'FriendlyName', 'Title', 'Titles', 'TopTitles')) {
        Assert-True (
            $otherView.PSObject.Properties.Name -notcontains $privateProperty
        ) "$relativePath leaked $privateProperty through the non-winner display model"
    }

    $source = Get-Content -LiteralPath $path -Raw
    Assert-True ($source -notmatch 'WinningTitle|TopTitles|YOUR TOP TITLES') "$relativePath retains title-based Binge Champion output"
    Assert-True ($source -notmatch '\$bingeHeadline|\$bingeTitleCount|\$bingeTitleWord') "$relativePath retains the retired one-line Binge Champion metric"
    Assert-True ($source -match 'font-size:10px;line-height:1\.35;font-weight:400;color:#b0b0b0') "$relativePath does not render the media breakdown in the compact secondary style"
    Assert-True ($source.Contains('$footerFeature += "`r`n${winnerLine}`r`n$($bingeDisplay.TotalTimeText) watched"')) "$relativePath does not use the two-line Binge Champion plain-text format"
    Assert-True ($source -notmatch 'movie/TV play split') "$relativePath retains the retired Binge Champion play-split copy"
    $winnerEyebrow = 'YOU WON ' + [char]0x2022 + ' BINGE CHAMPION'
    Assert-True ($source.Contains($winnerEyebrow)) "$relativePath lost the winner presentation"
    Assert-True ($source -match "THIS WEEK'S BINGE CHAMPION") "$relativePath lost the non-winner presentation"
    Assert-True ($source -match 'if \(\$isBingeWinner\) \{ 54 \} else \{ 42 \}') "$relativePath does not preserve winner/non-winner trophy sizing"

    Write-Host "[PASS] Binge Champion privacy and ranking: $relativePath"
}
