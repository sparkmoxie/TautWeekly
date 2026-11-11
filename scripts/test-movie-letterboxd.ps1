[CmdletBinding()]
param([string]$Root = '', [string[]]$Renderers = @('platforms/windows/TautWeekly.ps1', 'platforms/nas-docker/app/TautWeekly.ps1', 'platforms/mac-docker/app/TautWeekly.ps1'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
foreach ($relative in $Renderers) {
    & {
        param($relative)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $relative), [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "Parse failed: $relative"
        foreach ($name in @('Get-OptionalStringProperty', 'HtmlEncode', 'Safe-Int', 'Get-MovieExternalGuids', 'Get-MovieLetterboxdUrl', 'Get-MovieLetterboxdHtml', 'Get-DesignRatingLine', 'Get-StatsMovieRatingHtml', 'Build-PlainText')) {
            $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
            Assert-True ($null -ne $definition) "Missing $name"
            Invoke-Expression $definition.Extent.Text
        }
        $Config = [PSCustomObject]@{}
        $movie = [PSCustomObject]@{ Type='movie'; Title='Synthetic Movie'; Year='2026'; MetadataGuid='plex://movie/exact'; ExternalGuids=@('imdb://tt1234567', 'tmdb://7654321') }
        Assert-True ((Get-MovieLetterboxdUrl $movie) -eq '') 'Missing setting enabled links'
        $Config | Add-Member ShowLetterboxdLinks $false
        Assert-True ((Get-MovieLetterboxdUrl $movie) -eq '') 'False setting enabled links'
        $Config.ShowLetterboxdLinks = $true
        $movie | Add-Member RatingKey '123'
        $metadata = [PSCustomObject]@{rating_key='123'; guid='plex://movie/reused'; media_type='movie'; title='Synthetic Movie'; year='2026'; guids=@('tmdb://99')}
        Assert-True (@(Get-MovieExternalGuids -Item $movie -Metadata $metadata).Count -eq 0) 'Reused rating key attached another movie identity'
        $metadata.guid = $movie.MetadataGuid
        Assert-True ((@(Get-MovieExternalGuids -Item $movie -Metadata $metadata) -join ',') -eq 'tmdb://99') 'Exact retained movie GUID rejected'
        $movie.MetadataGuid = ''
        Assert-True (@(Get-MovieExternalGuids -Item $movie -Metadata $metadata).Count -eq 1) 'Missing GUID exact title/year fallback rejected'
        $metadata.year = '2025'
        Assert-True (@(Get-MovieExternalGuids -Item $movie -Metadata $metadata).Count -eq 0) 'Unidentified remake attached another movie identity'
        $movie.MetadataGuid = 'plex://movie/exact'
        Assert-True ((Get-MovieLetterboxdUrl $movie) -ceq 'https://letterboxd.com/tmdb/7654321/') 'TMDB identity was not used'
        $movie.ExternalGuids = @('imdb://tt1234567')
        Assert-True ((Get-MovieLetterboxdUrl $movie) -ceq 'https://letterboxd.com/imdb/tt1234567/') 'IMDb identity fallback failed'
        foreach ($type in @('show','episode','season','')) {
            $movie.Type = $type
            Assert-True ((Get-MovieLetterboxdUrl $movie) -eq '') "Non-movie $type got a link"
        }
        $movie.Type = 'movie'
        foreach ($identity in @('https://evil.invalid/?tmdb://12','tmdb://12/path','tmdb://0','imdb://tt123" onclick="x','plex://movie/id','tmdb://12%0a')) {
            $movie.ExternalGuids = @($identity)
            Assert-True ((Get-MovieLetterboxdUrl $movie) -eq '') "Unsafe identity accepted: $identity"
        }
        $movie.MetadataGuid = 'com.plexapp.agents.imdb://tt1234567?lang=en'
        $movie.ExternalGuids = @()
        Assert-True ((Get-MovieLetterboxdUrl $movie) -ceq 'https://letterboxd.com/imdb/tt1234567/') 'Legacy movie identity failed'
        foreach ($mode in @('Preview','Email')) {
            Assert-True ((Get-DesignRatingLine -Item $movie -ImageMode $mode) -match 'href="https://letterboxd.com/imdb/tt1234567/"') "$mode hero/card link missing"
            Assert-True ((Get-StatsMovieRatingHtml -Item $movie -ImageMode $mode) -match '>Letterboxd</a>') "$mode personal movie link missing"
        }
        function Get-ConfiguredServerName { 'Synthetic Server' }
        function Get-ConfiguredDeliveryDay { 'Friday' }
        function Get-ConfiguredPlexWebUrl { 'https://app.plex.tv/desktop/' }
        function Get-ConfiguredPlexButtonLabel { 'Open Plex' }
        function Get-CustomTextCardPlainText { '' }
        function Get-NewsletterReleaseDisplayData { [PSCustomObject]@{ CountLine='1 NEW MOVIE' } }
        function Get-DynamicPreheader { '1 NEW MOVIE' }
        function Get-RecipientWatchedPlainTextSuffix { '' }
        $script:GlobalTrendingStat = $null
        $stats = [PSCustomObject]@{TotalSeconds=0; MovieItems=@(); TvShowItems=@()}
        $plain = Build-PlainText -User ([PSCustomObject]@{FriendlyName='Synthetic Viewer'}) -Stats $stats -ReleaseData ([PSCustomObject]@{Movies=@($movie)}) -HotRelease ([PSCustomObject]@{Item=$movie; IsTrending=$false}) -TrendingTitle '' -SystemWarmingUp $false -RecentAccess $false -StartLabel 'Start' -EndLabel 'End'
        Assert-True (([regex]::Matches($plain, 'https://letterboxd.com/imdb/tt1234567/')).Count -eq 1) 'Plain text omitted or duplicated movie link'
        $Config.ShowLetterboxdLinks = $false
        Assert-True ((Get-DesignRatingLine -Item $movie -ImageMode Email) -notmatch 'Letterboxd') 'Disabled links changed HTML'
        Write-Host "[PASS] $relative optional Letterboxd identities, movie-only policy, HTML/plain-text parity and deduplication."
    } $relative
}
