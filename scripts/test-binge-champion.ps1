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
    'Get-BingeChampionDisplay'
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
    Assert-True ($winnerView.TotalTimeText -eq '6h 0m' -and $otherView.TotalTimeText -eq '6h 0m') "$relativePath did not share the watch-time aggregate"

    foreach ($privateProperty in @('UserId', 'FriendlyName', 'Title', 'Titles', 'TopTitles')) {
        Assert-True (
            $otherView.PSObject.Properties.Name -notcontains $privateProperty
        ) "$relativePath leaked $privateProperty through the non-winner display model"
    }

    $source = Get-Content -LiteralPath $path -Raw
    Assert-True ($source -notmatch 'WinningTitle|TopTitles|YOUR TOP TITLES') "$relativePath retains title-based Binge Champion output"

    Write-Host "[PASS] Binge Champion privacy and ranking: $relativePath"
}
