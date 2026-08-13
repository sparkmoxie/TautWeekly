[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$brandRoot = Join-Path $Root 'assets/branding'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PngDimensions([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-True ($bytes.Length -ge 24) "PNG is truncated: $Path"
    $signature = @(137,80,78,71,13,10,26,10)
    for ($index = 0; $index -lt $signature.Count; $index++) {
        Assert-True ($bytes[$index] -eq $signature[$index]) "Invalid PNG signature: $Path"
    }
    Assert-True ([Text.Encoding]::ASCII.GetString($bytes, 12, 4) -ceq 'IHDR') "PNG has no leading IHDR: $Path"
    $width = ([int64]$bytes[16] * 16777216) + ([int64]$bytes[17] * 65536) + ([int64]$bytes[18] * 256) + $bytes[19]
    $height = ([int64]$bytes[20] * 16777216) + ([int64]$bytes[21] * 65536) + ([int64]$bytes[22] * 256) + $bytes[23]
    return "$($width)x$($height)"
}

function Get-IcoSizes([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-True ($bytes.Length -ge 6) "ICO is truncated: $Path"
    $reserved = [BitConverter]::ToUInt16($bytes, 0)
    $type = [BitConverter]::ToUInt16($bytes, 2)
    $count = [BitConverter]::ToUInt16($bytes, 4)
    Assert-True ($reserved -eq 0 -and $type -eq 1 -and $count -gt 0) "Invalid ICO header: $Path"
    Assert-True ($bytes.Length -ge (6 + (16 * $count))) "ICO directory is truncated: $Path"
    $sizes = @()
    for ($index = 0; $index -lt $count; $index++) {
        $offset = 6 + (16 * $index)
        $width = if ($bytes[$offset] -eq 0) { 256 } else { [int]$bytes[$offset] }
        $height = if ($bytes[$offset + 1] -eq 0) { 256 } else { [int]$bytes[$offset + 1] }
        $sizes += "$($width)x$($height)"
    }
    return @($sizes)
}

$expectedHashes = [ordered]@{
    'tautweekly.ico'               = '22ebb62553593c12350f800769e6342165d9d1fc38a7f7cf25c14b5a2da7199e'
    'tautweekly-app-icon-16.png'   = '47b651982d5ac89fc6a38f030a6fd8940d0cbe298760f1d38402fe452952c6cb'
    'tautweekly-app-icon-32.png'   = '4ff84d1c57681a390703acea7b352c48ceed139978b41ad7dce14e2224265d47'
    'tautweekly-app-icon.svg'      = '598423a2d8691f746275e9f8edf8caa51d66b677ac08a9ec28daf12e878dc021'
    'build-assets.py'              = '63115440c39185855acf72dc3ae350420c85b0809db06b28a153acca9eccabf1'
    'tautweekly-app-icon-256.png'  = '7ddd1a0f160c29e02fddf12358dad4a9972a1bda428c25add9ddb79bc3847cf3'
    'tautweekly-app-icon-64.png'   = '826ed7fe048ae6f4c4732ea093ba47df51392c96ced09fea0c8d129a902fa1eb'
    'tautweekly-logo-128.png'      = '84f23e8d60ce448a045ce92d4a4090253ed9263428780e12e6ea61a5f633189e'
    'tautweekly-app-icon-128.png'  = '896ac8a1c33b8aec75c1f2635c87e41142613e9d4311d3b140f1b86b665ffc52'
    'favicon.ico'                  = '8b7488e80ea2a27d02012f6d280ed154de253ac6661aa66841ae418e54add495'
    'tautweekly-logo-512.png'      = '8b7e2bea34d8b7f6fbbee5dcc51c67c508727320aa4b20cbba0eb8395364a162'
    'tautweekly-app-icon-512.png'  = '94f8ebcfc43a4336db360af85ff454ca24a0e419b12d57191bdecad208615a15'
    'tautweekly-app-icon-180.png'  = 'a27f0e77f5a9497b9f7a5430ef605543e5c5370655c64f3177e2d90823da465a'
    'tautweekly-app-icon-192.png'  = 'b58ad43cbadf3328b0aafe9ac2586f60f97d533f29a072b98139fe90645c181d'
    'tautweekly-logo-256.png'      = 'd38e68e28e750c8dceebd8c695d361018280001f3a4a43200fdb1f8756b38a75'
    'tautweekly-logo.svg'          = 'e08f49bff853a504360184006a24fb9273331fd84a0c84ecf8661f05a3770b77'
    'tautweekly-app-icon-1024.png' = 'ee29569539c627c5df78e55c70eaf3b11667f41f2981bc1ee5bb6eaa3c1c6ceb'
    'tautweekly-logo-source.png'   = 'fa6c43f81768ea28ba3cae604a7e93d43cbdb783809e9c16fe68ef9016530ed4'
    'tautweekly-logo-1024.png'     = 'fada7196c5f6fa9283bf3e5fe0a928a22360e152320e9139e1f3c6cd4b27688d'
    'tautweekly-logo-master.png'   = 'fada7196c5f6fa9283bf3e5fe0a928a22360e152320e9139e1f3c6cd4b27688d'
    'tautweekly-app-icon-48.png'   = 'fd11b807a2afec27de103e79ab9a5608cfa7590a6acd35138859ab3f5bbbcea3'
}

$checksumLines = @(Get-Content -LiteralPath (Join-Path $brandRoot 'SHA256SUMS.txt') | Where-Object { $_.Trim() })
Assert-True ($checksumLines.Count -eq $expectedHashes.Count) 'Brand SHA256SUMS.txt does not cover the exact canonical source/build/generated set.'
foreach ($entry in $expectedHashes.GetEnumerator()) {
    $path = Join-Path $brandRoot $entry.Key
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Canonical brand file is missing: $($entry.Key)"
    Assert-True ((Get-Sha256 $path) -ceq $entry.Value) "Canonical brand hash changed: $($entry.Key)"
    $escapedName = [regex]::Escape($entry.Key)
    Assert-True (@($checksumLines | Where-Object { $_ -cmatch "^$($entry.Value)  $escapedName$" }).Count -eq 1) "Brand checksum evidence is missing or duplicated: $($entry.Key)"
}
Write-Host '[PASS] Canonical source, build script, and 19 generated asset hashes match the approved handoff.'

$pngDimensions = [ordered]@{
    'tautweekly-logo-source.png'   = '1254x1254'
    'tautweekly-logo-master.png'   = '1024x1024'
    'tautweekly-logo-128.png'      = '128x128'
    'tautweekly-logo-256.png'      = '256x256'
    'tautweekly-logo-512.png'      = '512x512'
    'tautweekly-logo-1024.png'     = '1024x1024'
    'tautweekly-app-icon-16.png'   = '16x16'
    'tautweekly-app-icon-32.png'   = '32x32'
    'tautweekly-app-icon-48.png'   = '48x48'
    'tautweekly-app-icon-64.png'   = '64x64'
    'tautweekly-app-icon-128.png'  = '128x128'
    'tautweekly-app-icon-180.png'  = '180x180'
    'tautweekly-app-icon-192.png'  = '192x192'
    'tautweekly-app-icon-256.png'  = '256x256'
    'tautweekly-app-icon-512.png'  = '512x512'
    'tautweekly-app-icon-1024.png' = '1024x1024'
}
foreach ($entry in $pngDimensions.GetEnumerator()) {
    Assert-True ((Get-PngDimensions (Join-Path $brandRoot $entry.Key)) -ceq $entry.Value) "Unexpected PNG dimensions: $($entry.Key)"
}
Assert-True ((Get-IcoSizes (Join-Path $brandRoot 'tautweekly.ico')) -join ',' -ceq '16x16,24x24,32x32,48x48,64x64,128x128,256x256') 'Windows ICO size directory changed.'
Assert-True ((Get-IcoSizes (Join-Path $brandRoot 'favicon.ico')) -join ',' -ceq '16x16,24x24,32x32') 'Favicon ICO size directory changed.'
Write-Host '[PASS] Canonical PNG and ICO dimensions match every platform size contract.'

foreach ($svgContract in @(
    @{ Svg = 'tautweekly-logo.svg'; Png = 'tautweekly-logo-master.png' },
    @{ Svg = 'tautweekly-app-icon.svg'; Png = 'tautweekly-app-icon-1024.png' }
)) {
    $svg = [IO.File]::ReadAllText((Join-Path $brandRoot $svgContract.Svg))
    Assert-True ($svg -match '<title\s+id="title">[^<]+</title>' -and $svg -match '<desc\s+id="desc">[^<]+</desc>') "$($svgContract.Svg) lacks an accessible title/description."
    Assert-True ($svg -match 'href="data:image/png;base64,(?<payload>[A-Za-z0-9+/=]+)"') "$($svgContract.Svg) does not embed the canonical raster."
    $embeddedPath = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-brand-svg-' + [Guid]::NewGuid().ToString('N') + '.png')
    try {
        [IO.File]::WriteAllBytes($embeddedPath, [Convert]::FromBase64String($Matches['payload']))
        Assert-True ((Get-Sha256 $embeddedPath) -ceq (Get-Sha256 (Join-Path $brandRoot $svgContract.Png))) "$($svgContract.Svg) changed the embedded raster bytes."
    }
    finally { Remove-Item -LiteralPath $embeddedPath -Force -ErrorAction SilentlyContinue }
}
Write-Host '[PASS] Raster-preserving SVG wrappers embed the exact masters and remain accessible.'

$copies = [ordered]@{
    'docs/favicon.ico' = 'favicon.ico'
    'docs/assets/branding/tautweekly-app-icon-64.png' = 'tautweekly-app-icon-64.png'
    'docs/assets/branding/tautweekly-app-icon-180.png' = 'tautweekly-app-icon-180.png'
    'docs/assets/branding/tautweekly-app-icon-192.png' = 'tautweekly-app-icon-192.png'
    'docs/assets/branding/tautweekly-app-icon-512.png' = 'tautweekly-app-icon-512.png'
    'docs/assets/branding/tautweekly-app-icon-1024.png' = 'tautweekly-app-icon-1024.png'
    'platforms/windows/TautWeekly.ico' = 'tautweekly.ico'
    'platforms/nas-docker/app/product-branding/favicon.ico' = 'favicon.ico'
    'platforms/nas-docker/app/product-branding/tautweekly-app-icon-128.png' = 'tautweekly-app-icon-128.png'
    'platforms/mac-docker/app/product-branding/favicon.ico' = 'favicon.ico'
    'platforms/mac-docker/app/product-branding/tautweekly-app-icon-128.png' = 'tautweekly-app-icon-128.png'
}
foreach ($copy in $copies.GetEnumerator()) {
    $copyPath = Join-Path $Root $copy.Key
    Assert-True (Test-Path -LiteralPath $copyPath -PathType Leaf) "Integrated brand copy is missing: $($copy.Key)"
    Assert-True ((Get-Sha256 $copyPath) -ceq $expectedHashes[$copy.Value]) "Integrated brand copy changed bytes: $($copy.Key)"
}
Write-Host '[PASS] Documentation, Windows, NAS/container, and macOS package copies preserve the exact raster bytes.'

$manifest = Get-Content -LiteralPath (Join-Path $Root 'docs/site.webmanifest') -Raw | ConvertFrom-Json
Assert-True ([string]$manifest.name -ceq 'TautWeekly for Plex') 'Web manifest has the wrong product name.'
$manifestSizes = @($manifest.icons | ForEach-Object { [string]$_.sizes })
Assert-True ($manifestSizes -ccontains '192x192' -and $manifestSizes -ccontains '512x512') 'Web manifest lacks required 192/512 PNG icons.'

$pageContracts = [ordered]@{
    'docs/index.html' = 'assets/branding/tautweekly-app-icon-64.png'
    'docs/windows/index.html' = '../assets/branding/tautweekly-app-icon-64.png'
    'docs/nas-docker/index.html' = '../assets/branding/tautweekly-app-icon-64.png'
    'docs/mac/index.html' = '../assets/branding/tautweekly-app-icon-64.png'
}
foreach ($page in $pageContracts.GetEnumerator()) {
    $html = [IO.File]::ReadAllText((Join-Path $Root $page.Key))
    Assert-True ($html.Contains($page.Value)) "$($page.Key) does not use the canonical global product header mark."
    Assert-True ($html -match '<img[^>]+alt=""[^>]+(?:width="(?:36|38)"|height="(?:36|38)")') "$($page.Key) product header mark is not decoratively accessible with explicit dimensions."
}
foreach ($relative in @('docs/index.html','docs/windows/index.html','docs/nas-docker/index.html','docs/mac/index.html','docs/linux/index.html','docs/freebsd/index.html')) {
    $html = [IO.File]::ReadAllText((Join-Path $Root $relative))
    Assert-True ($html -match 'rel="icon"' -and $html -match 'rel="apple-touch-icon"' -and $html -match 'rel="manifest"') "$relative lacks the global favicon/touch/manifest contract."
    Assert-True ($html -match 'property="og:image"' -and $html -match 'property="og:image:alt"') "$relative lacks accessible social-image metadata."
}
$linuxHtml = [IO.File]::ReadAllText((Join-Path $Root 'docs/linux/index.html'))
$freeBsdHtml = [IO.File]::ReadAllText((Join-Path $Root 'docs/freebsd/index.html'))
Assert-True ($linuxHtml.Contains('<span class="mark">LIN</span>')) 'Native Linux platform mark was replaced.'
Assert-True ($freeBsdHtml.Contains('<span class="brand-mark freebsd-mark">BSD</span>')) 'FreeBSD platform mark was replaced.'

$readme = [IO.File]::ReadAllText((Join-Path $Root 'README.md'))
foreach ($badge in @('Windows-PowerShell','NAS-Docker','Unraid-Community','GHCR-amd64','macOS-Docker','Linux-native','FreeBSD-Podman')) {
    Assert-True ($readme.Contains($badge)) "Platform/package badge was removed: $badge"
}
Assert-True ($readme.Contains('assets/branding/tautweekly-logo-256.png')) 'Repository README lacks the canonical global product logo.'

$unraidIcon = 'https://raw.githubusercontent.com/sparkmoxie/TautWeekly/main/assets/branding/tautweekly-app-icon-512.png'
foreach ($relative in @('ca_profile.xml','templates/tautweekly.xml')) {
    $metadata = [IO.File]::ReadAllText((Join-Path $Root $relative))
    Assert-True ($metadata.Contains("<Icon>$unraidIcon</Icon>")) "$relative does not use the canonical global app icon."
}
foreach ($relative in @('platforms/nas-docker/app/preview-home.html','platforms/mac-docker/app/preview-home.html')) {
    $landing = [IO.File]::ReadAllText((Join-Path $Root $relative))
    Assert-True ($landing.Contains('product-branding/tautweekly-app-icon-128.png') -and $landing.Contains('product-branding/favicon.ico')) "$relative lacks the packaged product identity."
}
$architecture = [IO.File]::ReadAllText((Join-Path $Root 'docs/assets/architecture.svg'))
Assert-True ($architecture.Contains('branding/tautweekly-app-icon-64.png') -and -not $architecture.Contains('>TW</text>')) 'Architecture diagram retains the generic TW placeholder.'

foreach ($newsletterRoot in @('platforms/windows/assets','platforms/nas-docker/app/assets-default','platforms/mac-docker/app/assets-default')) {
    $unexpected = @(Get-ChildItem -LiteralPath (Join-Path $Root $newsletterRoot) -File | Where-Object { $_.Name -match '^tautweekly-(?:logo|app-icon)' })
    Assert-True ($unexpected.Count -eq 0) "Product logo leaked into generated-newsletter assets: $newsletterRoot"
}
Write-Host '[PASS] Global product identity is applied only to approved surfaces; platform badges and newsletter assets remain separate.'
Write-Host 'Canonical branding validation passed.' -ForegroundColor Green
