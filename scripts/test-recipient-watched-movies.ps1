[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-RendererFunctionDefinition {
    param([Management.Automation.Language.ScriptBlockAst]$Ast, [string]$Name, [string]$Renderer)
    $definition = $Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true) | Select-Object -First 1
    Assert-True ($null -ne $definition) "Missing $Name in $Renderer"
    return $definition.Extent.Text
}

$renderers = @(
    [PSCustomObject]@{ Path='platforms/windows/TautWeekly.ps1'; PreviewBase='../assets' },
    [PSCustomObject]@{ Path='platforms/nas-docker/app/TautWeekly.ps1'; PreviewBase='assets' },
    [PSCustomObject]@{ Path='platforms/mac-docker/app/TautWeekly.ps1'; PreviewBase='assets' }
)
$requiredFunctions = @(
    'Get-OptionalStringProperty', 'Safe-Int', 'Get-RecipientWatchedMovies',
    'Test-IncludedLibraryRow', 'Get-IncludedLibraryQueryScopes',
    'Test-RecipientHasWatchedMovie', 'Get-RecipientWatchedAssetSource',
    'Get-RecipientWatchedTitleIconHtml', 'Get-RecipientWatchedTitleHtml', 'Get-RecipientWatchedDesktopHeroPosterHtml',
    'Get-RecipientWatchedPlainTextSuffix', 'Get-ReleaseCardsHtml', 'Get-StatsMovieRowsHtml'
)

$sharedDefinitions = @{}
foreach ($renderer in $renderers) {
    $path = Join-Path $Root $renderer.Path
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "Parser errors prevent watched-state testing: $($renderer.Path)"
    foreach ($name in $requiredFunctions) {
        $definition = Get-RendererFunctionDefinition -Ast $ast -Name $name -Renderer $renderer.Path
        if ($name -like '*Recipient*Watched*') {
            if ($sharedDefinitions.ContainsKey($name)) {
                Assert-True ($definition -ceq $sharedDefinitions[$name]) "Renderer drift in shared $name"
            } else { $sharedDefinitions[$name] = $definition }
        }
        Invoke-Expression $definition
    }

    function HtmlEncode([AllowNull()][object]$Value) { [Net.WebUtility]::HtmlEncode([string]$Value) }
    function Get-ImageSource { param($RatingKey, $PosterAssets, $ImageMode) 'posters/synthetic.jpg' }
    function Get-DesignGenreLine { param($Item) 'Drama' }
    function Get-DesignRatingLine { param($Item, $ImageMode) '2026' }
    function Get-StatsMovieRatingHtml { param($Item, $ImageMode) '2026' }
    function Truncate-Text { param($Text, $MaxChars) [string]$Text }
    function Get-TvEpisodeLinesHtml { param($Item, $ImageMode) '' }
    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        $script:WatchedLog.Add("$Level|$Message")
    }

    $script:Config = [PSCustomObject]@{ WatchedPercent = 85 }
    $script:LibraryFilterEnabled = $true
    $script:IncludedLibraryIdSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$script:IncludedLibraryIdSet.Add('10')
    $script:WatchedLog = [Collections.Generic.List[string]]::new()
    $script:HistoryCalls = [Collections.Generic.List[hashtable]]::new()
    $script:HistoryFailure = $false
    $script:HistoryPagination = $false
    function Invoke-TautulliApi {
        param([string]$Command, [hashtable]$Parameters)
        if ($Command -ne 'get_history') { throw "Unexpected command: $Command" }
        $script:HistoryCalls.Add($Parameters.Clone())
        if ($script:HistoryFailure) { throw 'Synthetic historical lookup failure' }
        if ($script:HistoryPagination) {
            # v2.18.0 SQL pagination preserves the same API shape; history rows
            # omit redundant section_id while the query remains scoped.
            $pageRows = if ($Parameters.start -eq 0) {
                @(1..1000 | ForEach-Object {
                    [PSCustomObject]@{ user_id='1'; media_type='movie'; rating_key="partial-page-$_"; guid=''; watched_status=0.75; percent_complete=64; started=1 }
                })
            } elseif ($Parameters.start -eq 1000) {
                @([PSCustomObject]@{ user_id='1'; media_type='movie'; rating_key='historical-page-two'; guid='plex://movie/historical-page-two'; watched_status=1; percent_complete=100; started=1 })
            } else { throw 'Unexpected history offset' }
            return [PSCustomObject]@{ recordsFiltered=1001; recordsTotal=1001; data=$pageRows }
        }
        [PSCustomObject]@{
            recordsFiltered = 11
            data = @(
                [PSCustomObject]@{ user_id='1'; media_type='movie'; rating_key='watched-key'; guid='plex://movie/watched'; watched_status=1; percent_complete=5; started=1 },
                [PSCustomObject]@{ section_id='10'; user_id='1'; media_type='movie'; rating_key='percent-key'; guid='plex://movie/percent'; watched_status=0; percent_complete=85 },
                [PSCustomObject]@{ section_id='10'; user_id='1'; media_type='movie'; rating_key='old-key'; guid='plex://movie/guid-match'; watched_status=1; percent_complete=100 },
                [PSCustomObject]@{ section_id='10'; user_id='1'; media_type='movie'; rating_key='unwatched-key'; guid='plex://movie/unwatched'; watched_status=0; percent_complete=84 },
                [PSCustomObject]@{ section_id='10'; user_id='1'; media_type='movie'; rating_key='partial-key'; guid='plex://movie/partial'; watched_status=0.75; percent_complete=64 },
                [PSCustomObject]@{ section_id='10'; user_id='1'; media_type='movie'; rating_key='quarter-key'; guid='plex://movie/quarter'; watched_status=0.25; percent_complete=21 },
                [PSCustomObject]@{ section_id='10'; user_id='1'; media_type='movie'; rating_key='half-key'; guid='plex://movie/half'; watched_status=0.50; percent_complete=43 },
                [PSCustomObject]@{ section_id='10'; user_id='2'; media_type='movie'; rating_key='other-user-key'; guid='plex://movie/other-user'; watched_status=1; percent_complete=100 },
                [PSCustomObject]@{ section_id='10'; media_type='movie'; rating_key='missing-user-key'; guid='plex://movie/missing-user'; watched_status=1; percent_complete=100 },
                [PSCustomObject]@{ section_id='10'; user_id='1'; media_type='episode'; rating_key='tv-key'; guid='plex://episode/tv'; watched_status=1; percent_complete=100 },
                [PSCustomObject]@{ section_id='99'; user_id='1'; media_type='movie'; rating_key='other-library-key'; guid='plex://movie/other-library'; watched_status=1; percent_complete=100 }
            )
        }
    }

    $state = Get-RecipientWatchedMovies -ExpectedUserId '1'
    Assert-True ($script:HistoryCalls.Count -eq 1) "$($renderer.Path) made the wrong history-query count"
    $query = $script:HistoryCalls[0]
    Assert-True ([string]$query.user_id -eq '1') "$($renderer.Path) did not scope history to the recipient"
    Assert-True ([string]$query.media_type -eq 'movie') "$($renderer.Path) did not scope history to movies"
    Assert-True ($query.ContainsKey('include_activity') -and $query.include_activity -eq 0) "$($renderer.Path) let Tautulli's active-session default affect historical watched state"
    Assert-True ([string]$query.section_id -eq '10') "$($renderer.Path) did not retain library scope"
    Assert-True (-not $query.ContainsKey('after') -and -not $query.ContainsKey('before')) "$($renderer.Path) limited watched state to the newsletter window"
    Assert-True ($state.RatingKeys.ContainsKey('watched-key')) "$($renderer.Path) ignored watched_status"
    Assert-True ($state.RatingKeys.ContainsKey('percent-key')) "$($renderer.Path) ignored WatchedPercent"
    Assert-True ($state.MetadataGuids.ContainsKey('plex://movie/guid-match')) "$($renderer.Path) lost GUID identity"
    foreach ($rejectedKey in @('unwatched-key','partial-key','quarter-key','half-key','other-user-key','missing-user-key','tv-key','other-library-key')) {
        Assert-True (-not $state.RatingKeys.ContainsKey($rejectedKey)) "$($renderer.Path) accepted forbidden history row $rejectedKey"
    }

    $otherState = Get-RecipientWatchedMovies -ExpectedUserId '2'
    Assert-True ($otherState.RatingKeys.Count -eq 1 -and $otherState.RatingKeys.ContainsKey('other-user-key')) "$($renderer.Path) did not isolate a second recipient's state"
    Assert-True (-not $otherState.RatingKeys.ContainsKey('watched-key') -and $state.RatingKeys.ContainsKey('watched-key')) "$($renderer.Path) reused or mutated another recipient's state"
    $callsBeforeMissingId = $script:HistoryCalls.Count
    $missingIdState = Get-RecipientWatchedMovies -ExpectedUserId ''
    Assert-True ($missingIdState.RatingKeys.Count -eq 0 -and $script:HistoryCalls.Count -eq $callsBeforeMissingId) "$($renderer.Path) queried unscoped history for a missing recipient"
    $script:Config.WatchedPercent = 90
    $higherThresholdState = Get-RecipientWatchedMovies -ExpectedUserId '1'
    Assert-True (-not $higherThresholdState.RatingKeys.ContainsKey('percent-key') -and $higherThresholdState.RatingKeys.ContainsKey('watched-key')) "$($renderer.Path) ignored the configured percentage or definitive watched status"
    $script:Config.WatchedPercent = 85

    $script:HistoryCalls.Clear()
    $script:HistoryPagination = $true
    $pagedState = Get-RecipientWatchedMovies -ExpectedUserId '1'
    Assert-True ($script:HistoryCalls.Count -eq 2) "$($renderer.Path) did not paginate historical recipient state"
    Assert-True ($script:HistoryCalls[0].start -eq 0 -and $script:HistoryCalls[1].start -eq 1000) "$($renderer.Path) used incorrect history page offsets"
    Assert-True ($pagedState.RatingKeys.Count -eq 1 -and $pagedState.RatingKeys.ContainsKey('historical-page-two')) "$($renderer.Path) lost the all-time watched movie beyond the first page"
    foreach ($pageQuery in $script:HistoryCalls) {
        Assert-True ($pageQuery.length -eq 1000 -and $pageQuery.include_activity -eq 0 -and $pageQuery.user_id -eq '1' -and $pageQuery.section_id -eq '10') "$($renderer.Path) changed query scope while paging"
        Assert-True (-not $pageQuery.ContainsKey('after') -and -not $pageQuery.ContainsKey('before')) "$($renderer.Path) applied a weekly window while paging"
    }
    $script:HistoryPagination = $false

    $watched = [PSCustomObject]@{ Type='movie'; RatingKey='watched-key'; MetadataGuid=''; Title='Watched Movie'; PosterRatingKey='watched-key'; Summary='Synthetic summary' }
    $guid = [PSCustomObject]@{ Type='movie'; RatingKey='new-key'; MetadataGuid='plex://movie/guid-match'; Title='GUID Movie'; PosterRatingKey='new-key'; Summary='Synthetic summary' }
    $unwatched = [PSCustomObject]@{ Type='movie'; RatingKey='unwatched-key'; MetadataGuid='plex://movie/unwatched'; Title='Unwatched Movie'; PosterRatingKey='unwatched-key'; Summary='Synthetic summary' }
    $tv = [PSCustomObject]@{ Type='show'; RatingKey='watched-key'; MetadataGuid='plex://movie/watched'; Title='TV Title'; PosterRatingKey='tv-key'; Summary='Synthetic summary'; SeasonCount=1; EpisodeCount=1; IsNewSeries=$true }

    Assert-True (Test-RecipientHasWatchedMovie $watched $state) "$($renderer.Path) did not match rating_key"
    Assert-True (Test-RecipientHasWatchedMovie $guid $state) "$($renderer.Path) did not match GUID"
    Assert-True (-not (Test-RecipientHasWatchedMovie $unwatched $state)) "$($renderer.Path) marked an unwatched movie"
    Assert-True (-not (Test-RecipientHasWatchedMovie $tv $state)) "$($renderer.Path) marked TV through a colliding key"

    $previewIcon = Get-RecipientWatchedTitleIconHtml $watched $state Preview $renderer.PreviewBase
    Assert-True ($previewIcon.Contains("src=`"$($renderer.PreviewBase)/watched.png`"")) "$($renderer.Path) used the wrong preview path"
    Assert-True ($previewIcon.Contains('width="20" height="20" alt="Watched" title="Watched"')) "$($renderer.Path) lost circular icon dimensions/accessibility"
    Assert-True ($previewIcon.Contains('vertical-align:middle;margin-left:6px;')) "$($renderer.Path) lost consistent icon centering/spacing"
    $emailIcon = Get-RecipientWatchedTitleIconHtml $watched $state Email $renderer.PreviewBase
    Assert-True ($emailIcon.Contains('src="cid:recipient_watched"')) "$($renderer.Path) lost the circular CID"
    Assert-True ((Get-RecipientWatchedTitleIconHtml $unwatched $state Preview $renderer.PreviewBase) -eq '') "$($renderer.Path) left an unwatched title gap"
    Assert-True ((Get-RecipientWatchedTitleIconHtml $tv $state Preview $renderer.PreviewBase) -eq '') "$($renderer.Path) changed TV title markup"

    $badge = Get-RecipientWatchedDesktopHeroPosterHtml $watched $state Email $renderer.PreviewBase 'cid:poster_synthetic' 'Watched Movie poster'
    Assert-True ($badge.Contains('src="cid:recipient_watched_desktop"')) "$($renderer.Path) lost the desktop CID"
    Assert-True ($badge.Contains('width="26" height="26" alt="Watched" title="Watched"')) "$($renderer.Path) lost desktop dimensions/accessibility"
    Assert-True ($badge.Contains('width="147" height="26"') -and $badge.Contains('width="7" height="26"') -and $badge.Contains('padding:5px 0 0;')) "$($renderer.Path) drifted from desktop table placement"
    Assert-True ($badge.Contains('<v:group') -and $badge.Contains('coordsize="180,275"') -and $badge.Contains('left:147;top:0;width:26;height:26;') -and $badge.Contains('left:0;top:5;width:180;height:270;')) "$($renderer.Path) lost fixed Outlook VML placement"
    $standardPoster = ($badge -split '<!--\[if !mso\]><!-- -->')[1]
    Assert-True (-not $standardPoster.Contains('position:') -and -not $standardPoster.Contains('z-index')) "$($renderer.Path) relies on unsupported webmail CSS positioning"
    $unwatchedPoster = Get-RecipientWatchedDesktopHeroPosterHtml $unwatched $state Preview $renderer.PreviewBase 'posters/synthetic.jpg' 'Unwatched Movie poster'
    Assert-True ($unwatchedPoster.StartsWith('<img src="posters/synthetic.jpg"') -and -not $unwatchedPoster.Contains('recipient-watched') -and -not $unwatchedPoster.Contains('<table')) "$($renderer.Path) left an unwatched poster gap"
    Assert-True ((Get-RecipientWatchedDesktopHeroPosterHtml $watched $state Preview $renderer.PreviewBase '' 'Missing poster') -eq '') "$($renderer.Path) rendered a floating badge without a poster"
    Assert-True ((Get-RecipientWatchedPlainTextSuffix $watched $state) -eq ' - Watched') "$($renderer.Path) lost plain-text semantics"
    Assert-True ((Get-RecipientWatchedPlainTextSuffix $tv $state) -eq '') "$($renderer.Path) changed plain-text TV"

    $previewTitle = Get-RecipientWatchedTitleHtml 'Watched Movie' $watched $state Preview $renderer.PreviewBase
    Assert-True ($previewTitle.Contains('<span style="vertical-align:middle;">Watched </span>') -and $previewTitle.Contains('<span class="recipient-watched-title-tail" style="white-space:nowrap;"><span style="vertical-align:middle;">Movie</span>' + $previewIcon)) "$($renderer.Path) lost centered text or orphan-free wrapping"
    Assert-True ((Get-RecipientWatchedTitleHtml 'Unwatched Movie' $unwatched $state Preview $renderer.PreviewBase) -ceq 'Unwatched Movie') "$($renderer.Path) changed unwatched title markup or spacing"
    Assert-True ((Get-RecipientWatchedTitleHtml 'TV Title' $tv $state Preview $renderer.PreviewBase) -ceq 'TV Title') "$($renderer.Path) changed TV title markup"
    $watchedCard = Get-ReleaseCardsHtml @($watched) @() Preview $state $renderer.PreviewBase Movie
    Assert-True ($watchedCard.Contains($previewTitle)) "$($renderer.Path) did not place the icon immediately after the card title"
    Assert-True ($watchedCard.Contains('vertical-align:middle;margin-left:6px;')) "$($renderer.Path) card spacing differs from hero spacing"
    $unwatchedCard = Get-ReleaseCardsHtml @($unwatched) @() Preview $state $renderer.PreviewBase Movie
    Assert-True (-not $unwatchedCard.Contains('recipient-watched-title-icon')) "$($renderer.Path) left watched markup in an unwatched card"
    $tvCard = Get-ReleaseCardsHtml @($tv) @() Preview $state $renderer.PreviewBase TV
    Assert-True (-not $tvCard.Contains('recipient-watched-title-icon')) "$($renderer.Path) changed TV card rendering"

    $statsRow = Get-StatsMovieRowsHtml @($watched) @() Preview $state $renderer.PreviewBase
    Assert-True ($statsRow.Contains($previewTitle)) "$($renderer.Path) omitted the identical marker from the personal movie recap"
    $unwatchedStats = Get-StatsMovieRowsHtml @($unwatched) @() Preview $state $renderer.PreviewBase
    Assert-True (-not $unwatchedStats.Contains('recipient-watched-title-icon')) "$($renderer.Path) marked an unwatched recap item"

    $source = [IO.File]::ReadAllText($path)
    Assert-True ($source.Contains('$hotTitleWithStatus = Get-RecipientWatchedTitleHtml -EncodedTitle $hotTitle')) "$($renderer.Path) lost mobile hero placement"
    Assert-True ($source.Contains('$hotPosterHtml = Get-RecipientWatchedDesktopHeroPosterHtml')) "$($renderer.Path) lost desktop hero placement"
    Assert-True ($source.Contains('$trendingTitleWithStatus = Get-RecipientWatchedTitleHtml -EncodedTitle $trendingDisplay -Item $script:GlobalTrendingStat')) "$($renderer.Path) omitted the compact Trending movie marker"
    Assert-True ($source.Contains('$trendWatchedSuffix = Get-RecipientWatchedPlainTextSuffix -Item $script:GlobalTrendingStat')) "$($renderer.Path) omitted compact Trending plain-text status"
    Assert-True ($source.Contains('$watchedSuffix = Get-RecipientWatchedPlainTextSuffix -Item $_')) "$($renderer.Path) omitted personal movie plain-text status"
    Assert-True ($source.Contains('Cid = "recipient_watched"; MediaType = "image/png"')) "$($renderer.Path) omitted circular MIME registration"
    Assert-True ($source.Contains('Cid = "recipient_watched_desktop"; MediaType = "image/png"')) "$($renderer.Path) omitted desktop MIME registration"
    Assert-True (([regex]::Matches($source, [regex]::Escape('Get-RecipientWatchedMovies -ExpectedUserId $user.UserId'))).Count -eq 3) "$($renderer.Path) omitted a recipient-state lifecycle"
    Assert-True (([regex]::Matches($source, [regex]::Escape('-RecipientWatchedMovies $recipientWatchedMovies'))).Count -eq 16) "$($renderer.Path) omitted an HTML/plain lifecycle propagation"

    $script:HistoryFailure = $true
    $failedState = Get-RecipientWatchedMovies -ExpectedUserId '1'
    Assert-True ($failedState.RatingKeys.Count -eq 0 -and $failedState.MetadataGuids.Count -eq 0) "$($renderer.Path) retained state after lookup failure"
    Assert-True ($script:WatchedLog.Count -eq 1 -and $script:WatchedLog[0] -like 'WARN|Historical recipient movie state was unavailable*') "$($renderer.Path) did not fail closed generically"
    Write-Host "[PASS] Recipient movie watched-state algorithm, privacy, markup, lifecycle: $($renderer.Path)"
}

$expectedAssets = [ordered]@{
    'watched.png' = @{ Hash='26744be4a08445006673cee9757e88937ff6a98406eca4acf6c4da4fc2b20498'; Width=20; Height=20 }
    'watched-desktop.png' = @{ Hash='714bbb0d84c41a22ad38717a52bf177029f8854ec3ace48e753c162d7e97a52e'; Width=26; Height=26 }
}
$assetRoots = @('platforms/windows/assets','platforms/nas-docker/app/assets-default','platforms/mac-docker/app/assets-default')
foreach ($assetRoot in $assetRoots) {
    foreach ($assetName in $expectedAssets.Keys) {
        $expected = $expectedAssets[$assetName]
        $assetPath = Join-Path (Join-Path $Root $assetRoot) $assetName
        Assert-True (Test-Path -LiteralPath $assetPath -PathType Leaf) "Missing watched asset: $assetRoot/$assetName"
        $bytes = [IO.File]::ReadAllBytes($assetPath)
        Assert-True ($bytes.Length -ge 8 -and [BitConverter]::ToString($bytes,0,8) -eq '89-50-4E-47-0D-0A-1A-0A') "$assetRoot/$assetName is not PNG"
        Assert-True ((Get-FileHash $assetPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expected.Hash) "$assetRoot/$assetName changed from validated source"
        $width = ($bytes[16] -shl 24) -bor ($bytes[17] -shl 16) -bor ($bytes[18] -shl 8) -bor $bytes[19]
        $height = ($bytes[20] -shl 24) -bor ($bytes[21] -shl 16) -bor ($bytes[22] -shl 8) -bor $bytes[23]
        Assert-True ($width -eq $expected.Width -and $height -eq $expected.Height) "$assetRoot/$assetName has wrong dimensions"
        Assert-True ($bytes[24] -eq 8 -and $bytes[25] -eq 6) "$assetRoot/$assetName is not 8-bit RGBA with transparency"
    }
}
Write-Host '[PASS] Watched PNG type, dimensions, RGBA transparency, hashes, and package parity.'
