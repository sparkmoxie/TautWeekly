[CmdletBinding()]
param([string]$Root = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Load-Function($Ast, [string]$Name) {
    $definition = $Ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name}, $true)
    Assert-True ($null -ne $definition) "Missing function $Name"
    return $definition.Extent.Text
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-email-optimization-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    foreach ($relative in @('platforms/windows/TautWeekly.ps1','platforms/nas-docker/app/TautWeekly.ps1','platforms/mac-docker/app/TautWeekly.ps1')) {
        & {
            param($relative)
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $relative), [ref]$tokens, [ref]$errors)
            Assert-True ($errors.Count -eq 0) "Parse failed: $relative"
            Invoke-Expression (Load-Function $ast 'Get-PosterPath')
            Invoke-Expression (Load-Function $ast 'Get-DesignHeroAssets')
            Invoke-Expression (Load-Function $ast 'Write-TautWeeklyStructuredResult')
            # Execute every writer rather than matching source whitespace: the
            # Windows writer uses aligned assignments and must share schema 5.
            $Mode = 'SendTestAll'
            $ResultPath = Join-Path $testRoot 'synthetic-result.json'
            $script:TautWeeklyResultStartedAtUtc = [DateTime]::UtcNow.AddSeconds(-1)
            $script:TautWeeklyResultWritten = $false
            $script:TautWeeklyResultWriting = $false
            $script:TautWeeklyResultSmtpAcceptedCount = 6
            $script:TautWeeklyResultBccAcceptedCount = 0
            $script:TautWeeklyResultBccRejectedCount = 0
            $script:TautWeeklyResultSkippedCount = 0
            $script:TautWeeklyResultFailedCount = 0
            $script:TautWeeklyResultSmtpFailure = $null
            $script:TautWeeklyResultErrorCategory = ''
            $script:TautWeeklyResultDeliveryScope = 'test'
            $script:TautWeeklyResultGeneratedPreviewFiles = [Collections.Generic.List[string]]::new()
            $script:TautWeeklyResultSkipReasons = [ordered]@{inactiveOrDeleted=0;missingEmail=0;excludedUserId=0;excludedEmail=0}
            $script:TautWeeklyResultEmailSizeMetrics = [ordered]@{messageCount=6;maxHtmlBytes=2048L;maxMimeBytes=16384L;maxInlineImageCount=2;maxInlineImageBytes=1024L}
            Write-TautWeeklyStructuredResult -Outcome succeeded
            $written = [IO.File]::ReadAllText($ResultPath) | ConvertFrom-Json
            Assert-True ($written.schemaVersion -eq 5 -and $written.smtpAcceptedCount -eq 6 -and $written.emailSizeMetrics.messageCount -eq 6 -and $written.emailSizeMetrics.maxHtmlBytes -eq 2048 -and $written.emailSizeMetrics.maxMimeBytes -eq 16384 -and $written.emailSizeMetrics.maxInlineImageCount -eq 2 -and $written.emailSizeMetrics.maxInlineImageBytes -eq 1024) "$relative did not serialize schema 5 email maxima"
            Assert-True (($written.emailSizeMetrics.PSObject.Properties.Name | Sort-Object) -join ',' -ceq 'maxHtmlBytes,maxInlineImageBytes,maxInlineImageCount,maxMimeBytes,messageCount') "$relative serialized unsupported email metric fields"
            $script:TautWeeklyResultEmailSizeMetrics.messageCount = 0
            $script:TautWeeklyResultSmtpAcceptedCount = 0
            $script:TautWeeklyResultDeliveryScope = 'none'
            $Mode = 'CacheWarm'
            $script:TautWeeklyResultWritten = $false
            Write-TautWeeklyStructuredResult -Outcome succeeded
            $written = [IO.File]::ReadAllText($ResultPath) | ConvertFrom-Json
            Assert-True ($written.schemaVersion -eq 5 -and $null -eq $written.emailSizeMetrics) "$relative did not preserve an explicit absent-metrics state"
            Write-Host "[PASS] $relative structured-result schema, numeric email metrics and absent-metrics parity."
            $script:TautWeeklyRunPosterCache = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
            $script:TautWeeklyRunPosterPathKeys = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            $script:PosterDir = Join-Path $testRoot 'posters'
            $script:DesignMediaDir = Join-Path $testRoot 'media'
            [void][IO.Directory]::CreateDirectory($PosterDir)
            [void][IO.Directory]::CreateDirectory($DesignMediaDir)
            $script:TautulliBase = 'http://synthetic.test:8181'
            $script:Fetches = 0; $script:Generic = $false; $script:Recovery = $false; $script:FetchFailure = $false
            function Get-SafeFilePart([string]$Value) { return $Value }
            function Build-TautulliUri { param($Command, $Parameters) return 'http://no-network.test/mock' }
            function Write-Log { param($Message, $Level) }
            function Invoke-WebRequest {
                param($Uri, $OutFile, $TimeoutSec)
                $script:Fetches++
                if ($script:FetchFailure) { throw 'synthetic fetch failure' }
                [IO.File]::WriteAllBytes($OutFile, [byte[]](1..255) * 4)
            }
            function Test-IsTautulliDefaultPoster { param($Path) return $script:Generic }
            function Restore-TautWeeklyDeletedItemCachePoster {
                param($MediaType, $MetadataGuid, $DestinationPath)
                if ($script:Recovery) {
                    [IO.File]::WriteAllBytes($DestinationPath, [byte[]](255..1) * 4)
                    return $DestinationPath
                }
                return ''
            }
            function Get-PlexHostedPosterPath { param($MetadataGuid,$MediaType,$DestinationPath,$MatchTitle,$MatchYear,$ParentIndex,$Index) return '' }
            $live = $false
            $first = Get-PosterPath -RatingKey '123' -MetadataGuid 'guid:one' -LivePlexPoster ([ref]$live)
            $second = Get-PosterPath -RatingKey '123' -MetadataGuid 'guid:one' -LivePlexPoster ([ref]$live)
            Assert-True ($first -ceq $second -and $live -and $script:Fetches -eq 1) "$relative failed same-run live reuse"
            [void](Get-PosterPath -RatingKey '123' -MetadataGuid 'guid:two' -LivePlexPoster ([ref]$live))
            [void](Get-PosterPath -RatingKey '123' -MetadataGuid 'guid:one' -LivePlexPoster ([ref]$live))
            Assert-True ($script:Fetches -eq 3) "$relative reused overwritten bytes from another GUID"
            $script:TautulliBase = 'http://other-synthetic.test:8181'
            [void](Get-PosterPath -RatingKey '123' -MetadataGuid 'guid:one' -LivePlexPoster ([ref]$live))
            Assert-True ($script:Fetches -eq 4) "$relative reused artwork from another server"
            [void](Get-PosterPath -RatingKey '123' -MetadataGuid 'guid:one' -MediaType show -LivePlexPoster ([ref]$live))
            Assert-True ($script:Fetches -eq 5) "$relative reused artwork from another media type"
            $script:TautWeeklyRunPosterCache.Clear(); $script:TautWeeklyRunPosterPathKeys.Clear()
            [void](Get-PosterPath -RatingKey '123' -MetadataGuid 'guid:one' -LivePlexPoster ([ref]$live))
            Assert-True ($script:Fetches -eq 6) "$relative adopted prior-run generated output"
            Remove-Item -LiteralPath $first -Force
            [void](Get-PosterPath -RatingKey '123' -MetadataGuid 'guid:one' -LivePlexPoster ([ref]$live))
            Assert-True ($script:Fetches -eq 7) "$relative retained a missing run cache file"
            $script:Generic = $true; $script:Recovery = $true
            [void](Get-PosterPath -RatingKey 'recovered' -MetadataGuid 'exact:recovery' -LivePlexPoster ([ref]$live))
            Assert-True (-not $live) "$relative promoted recovered artwork to live provenance"
            $before = $script:Fetches
            [void](Get-PosterPath -RatingKey 'recovered' -MetadataGuid 'exact:recovery' -LivePlexPoster ([ref]$live))
            Assert-True (-not $live -and $script:Fetches -eq $before) "$relative changed cached recovery provenance"
            $script:FetchFailure = $true; $script:Recovery = $false
            [void](Get-PosterPath -RatingKey 'failed' -MetadataGuid 'exact:missing' -LivePlexPoster ([ref]$live))
            [void](Get-PosterPath -RatingKey 'failed' -MetadataGuid 'exact:missing' -LivePlexPoster ([ref]$live))
            Assert-True ($script:Fetches -eq $before + 2) "$relative cached transient failure as success"

            $script:HeroRequests = [Collections.Generic.List[string]]::new()
            $script:BannerFailure = $false
            function Invoke-TautulliApi { param($Command, $Parameters) return [PSCustomObject]@{ banner='synthetic-banner'; art='synthetic-art' } }
            function Get-DesignPmsImage {
                param($ImagePath,$RatingKey,$OutputName,$Fallback,$Width,$Height,$Format)
                $script:HeroRequests.Add($ImagePath)
                if ($script:BannerFailure -and $ImagePath -eq 'synthetic-banner') { return '' }
                return 'media/' + $OutputName
            }
            function Get-DesignBestClearLogoAsset { param($RatingKey) return [PSCustomObject]@{ LogoSrc='media/synthetic-logo.png' } }
            function Get-DesignPlexMetadata { param($RatingKey) return $null }
            function Get-DesignPlexImages { param($RatingKey) return @() }
            function Save-DesignPlexDiagnostic { param($RatingKey,$Metadata,$Images) }
            $hero = [PSCustomObject]@{ Item=[PSCustomObject]@{RatingKey='123';PosterRatingKey='123';Type='movie'} }
            $result = Get-DesignHeroAssets -HotRelease $hero
            Assert-True ($script:HeroRequests.Count -eq 1 -and $result.BannerSrc -eq 'media/banner_123.jpg') "$relative downloaded unused fallback artwork"
            $script:HeroRequests.Clear(); $script:BannerFailure = $true
            $result = Get-DesignHeroAssets -HotRelease $hero
            Assert-True ($script:HeroRequests.Count -eq 2 -and $result.BannerSrc -eq 'media/art_123.jpg') "$relative lost lazy fallback artwork"
            Write-Host "[PASS] $relative run-only exact identity/provenance, missing/failing files, and lazy hero fallback."
        } $relative
    }
    $helper = Join-Path $Root 'platforms/nas-docker/app/Smtp-Transport.ps1'
    $canonical = [IO.File]::ReadAllText($helper)
    foreach ($relative in @('platforms/windows/Smtp-Transport.ps1','platforms/mac-docker/app/Smtp-Transport.ps1')) {
        Assert-True ([IO.File]::ReadAllText((Join-Path $Root $relative)) -ceq $canonical) "SMTP helper drift: $relative"
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
    Invoke-Expression (Load-Function $ast 'New-TautWeeklyMimeFile')
    Invoke-Expression (Load-Function $ast 'Get-TautWeeklyMimeSizeMetrics')
    $mail = [Net.Mail.MailMessage]::new('sender@example.org','recipient@example.org')
    try {
        $html = '<html><body><img src="cid:synthetic"><p>synthetic &amp; non-ascii: ' + [char]0x00E9 + '</p></body></html>'
        $view = [Net.Mail.AlternateView]::CreateAlternateViewFromString($html,[Text.Encoding]::UTF8,'text/html')
        $bytes = [byte[]](1..255) * 4
        $resource = [Net.Mail.LinkedResource]::new([IO.MemoryStream]::new($bytes),'image/png')
        $resource.ContentId = 'synthetic'
        $view.LinkedResources.Add($resource)
        $mail.AlternateViews.Add($view)
        $mimeFile = New-TautWeeklyMimeFile -MailMessage $mail
        $metrics = Get-TautWeeklyMimeSizeMetrics -MailMessage $mail -MimeBytes $mimeFile.Length
        Assert-True ($metrics.htmlBytes -eq [Text.Encoding]::UTF8.GetByteCount($html)) 'HTML metric must measure decoded UTF-8 bytes'
        Assert-True ($metrics.mimeBytes -eq (Get-Item -LiteralPath $mimeFile.Path).Length) 'MIME metric does not match serialization bytes'
        Assert-True ($metrics.inlineImageCount -eq 1 -and $metrics.largestInlineImageBytes -eq $bytes.Length) 'Inline resource metrics differ from exact bytes'
        Assert-True (($metrics.Keys | Sort-Object) -join ',' -ceq 'htmlBytes,inlineImageCount,largestInlineImageBytes,mimeBytes') 'Metrics expose an unsupported field'
        Assert-True ($metrics.htmlBytes -lt 256 -and $metrics.mimeBytes -lt 4096) 'Small synthetic MIME fixture exceeds its regression budget'
        Write-Host "[PASS] Numeric-only email metrics match UTF-8 HTML, serialized MIME and exact inline resource sizes."
    } finally {
        $mail.Dispose()
        if ($null -ne $mimeFile) { Remove-Item -LiteralPath $mimeFile.Directory -Recurse -Force }
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
