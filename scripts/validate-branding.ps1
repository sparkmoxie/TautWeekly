[CmdletBinding()]
param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$brandRoot = Join-Path $Root 'assets/branding'
$platformRoot = Join-Path $Root 'assets/platforms'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-Sha256([string]$Path) {
    if ([IO.Path]::GetFileName($Path) -ceq 'build-assets.py') {
        $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path)).Replace("`r`n", "`n")
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))
            return (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
        }
        finally { $algorithm.Dispose() }
    }
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

function Get-PngColorType([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-True ($bytes.Length -ge 26) "PNG is truncated: $Path"
    return [int]$bytes[25]
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
    'build-assets.py'              = '7e1e0d92e2b76ac5778fd3a7ec1ffcb84d59280e7354f669882a59b8016c2871'
    'favicon.ico'                  = 'a55139823f3da079e270049ef232b7919979e94605734a7c0dc0864af4c0e83a'
    'tautweekly.ico'               = 'a77aa803dfe9d026db37744ff646a6197c0c3c402ca03da8eea76962212b892c'
    'tautweekly-app-icon.svg'      = '54e41431aa4d48dc0e5edf4866c21da36fb6e9e73e295d827f8c0aec5d73baed'
    'tautweekly-app-icon-1024.png' = '35b77794f4648c2aa2fe0cd8637171ee3df4c96cd109e600fee832a7cfb649b9'
    'tautweekly-app-icon-128.png'  = '7938faa3711fcf51bf53a6ed530b4d1d7dca73b6a8ef7f5ca9d1e674b461251e'
    'tautweekly-app-icon-16.png'   = '130a7dea5bb3f56b4f747944fe1244b2b1ed4a7911ad3f3b85fa8cde95f9013f'
    'tautweekly-app-icon-180.png'  = 'e6430053355b69afb04e714a05e33a911aa3215d846f6afb09d43935508b4631'
    'tautweekly-app-icon-192.png'  = '213be384357ffdf565df9a193c156cba21189cbdd4fca168cf9894767523a374'
    'tautweekly-app-icon-256.png'  = '226b979f443c2f2d4a12c5fdffdbefa47b042c550eac846ddc455ad3516b9c12'
    'tautweekly-app-icon-32.png'   = '1ce1e56487479502a729c9b1383c0e3310bf8bbca5567826199cba5b3f347917'
    'tautweekly-app-icon-48.png'   = '503ee4405d049f19110ba1339a0784987b059550670e5fb4fce8744818edd1e4'
    'tautweekly-app-icon-512.png'  = '6f3995da01d9cc8d9141db4a31278865ee74935aa7de5792b643d556caa71070'
    'tautweekly-app-icon-64.png'   = '90046d94448ccccdd210e7221377a3678387a1018d89f725ac086aa900c34285'
    'tautweekly-logo.svg'          = '26e1d7b847892ccc0dadd0ce9e4168ec05c6c727d750997aa610c24de0063e35'
    'tautweekly-logo-1024.png'     = 'aaba3471c907d776779038c1d9c4f5ab489aca53dc70aceba57de8f8d0dd2adc'
    'tautweekly-logo-128.png'      = '99a07cc1206971ce95373006841ddfd06cd6c4195c6ce8c8d269193226393f4f'
    'tautweekly-logo-256.png'      = '95a81b8955c11fc2ad5b4df33a114725045a6ce99fc682cf6f77ec50835ed81b'
    'tautweekly-logo-512.png'      = 'c95bdd4b2cf18393a054ffef34c3970889247c3a3afec58d59656b815709d58b'
    'tautweekly-logo-master.png'   = 'aaba3471c907d776779038c1d9c4f5ab489aca53dc70aceba57de8f8d0dd2adc'
    'tautweekly-logo-source.png'   = 'fa6c43f81768ea28ba3cae604a7e93d43cbdb783809e9c16fe68ef9016530ed4'
    'tautweekly-logo-transparent-source.png' = 'a224a283f643ceb72873aed286efed945758eb2a4288ef7c2c719cf4f51322ea'
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
Write-Host '[PASS] Opaque provenance, corrected transparent source, build script, and 19 generated asset hashes match the approved handoff.'

$pngDimensions = [ordered]@{
    'tautweekly-logo-source.png'   = '1254x1254'
    'tautweekly-logo-transparent-source.png' = '1254x1254'
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
Assert-True ((Get-PngColorType (Join-Path $brandRoot 'tautweekly-logo-source.png')) -eq 2) 'Opaque provenance unexpectedly contains an alpha channel.'
foreach ($name in @('tautweekly-logo-transparent-source.png','tautweekly-logo-master.png','tautweekly-app-icon-1024.png')) {
    Assert-True ((Get-PngColorType (Join-Path $brandRoot $name)) -eq 6) "Transparent production source/master lacks an RGBA color type: $name"
}
Assert-True ((Get-IcoSizes (Join-Path $brandRoot 'tautweekly.ico')) -join ',' -ceq '16x16,24x24,32x32,48x48,64x64,128x128,256x256') 'Windows ICO size directory changed.'
Assert-True ((Get-IcoSizes (Join-Path $brandRoot 'favicon.ico')) -join ',' -ceq '16x16,24x24,32x32') 'Favicon ICO size directory changed.'
Write-Host '[PASS] Canonical PNG alpha/color-type, PNG dimensions, and ICO dimensions match every platform contract.'

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
    'installer/assets/tautweekly.ico' = 'tautweekly.ico'
    'manager/internal/manager/web/favicon.ico' = 'favicon.ico'
    'manager/internal/manager/web/tautweekly-icon-180.png' = 'tautweekly-app-icon-180.png'
    'manager/internal/manager/web/tautweekly-icon-192.png' = 'tautweekly-app-icon-192.png'
    'manager/internal/manager/web/tautweekly-logo.png' = 'tautweekly-app-icon-256.png'
    'manager/internal/manager/web/tautweekly-icon-512.png' = 'tautweekly-app-icon-512.png'
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
Write-Host '[PASS] Documentation, Manager, installer, Windows, NAS/container, and macOS package copies preserve the exact raster bytes.'

$expectedPlatformHashes = [ordered]@{
    'apple.svg'              = '0c4c6587bb4abedf2a01fe715d626d0807d27527bcfe302cc5bab570dfeda4c6'
    'apple-black-source.svg' = '9d00ea77a3240f291356c36261c5f45d7fa456f29c97a2f060caf0ed4b9c3231'
    'docker.svg'             = '0fd7f9164de13672bb1708ac7cc401ed439eb938ffa7358d5cb278e107904687'
    'freebsd.png'            = '09ea16d050fc1eb23cdf948ce2d6ec4704e12db7a0bdb1dc69e64c8dea01f384'
    'linux-tux.png'          = '5a6004f465e6604c90470cb6ed4ffc91137f6ee24a40d37e8377581417d91150'
    'qnap.png'               = 'f3771f92bebc261f104d93e27a53d3d66ba581ff5db6915c769c548ea1115eca'
    'unraid.svg'             = 'b9fe98013b4af13bcaa04dc0c84d7f3f7d18a0d0bbab18e332a6dec27becd496'
    'windows.svg'            = 'e8a33c4612b2ade22550b61e4c426e9d10a5bdf325b7b17f220e7363bed89dd2'
}
$platformChecksumLines = @(Get-Content -LiteralPath (Join-Path $platformRoot 'ASSET-SHA256SUMS.txt') | Where-Object { $_.Trim() })
Assert-True ($platformChecksumLines.Count -eq $expectedPlatformHashes.Count) 'Platform asset checksum manifest is incomplete.'
foreach ($entry in $expectedPlatformHashes.GetEnumerator()) {
    $path = Join-Path $platformRoot $entry.Key
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Platform identity asset is missing: $($entry.Key)"
    Assert-True ((Get-Sha256 $path) -ceq $entry.Value) "Platform identity asset hash changed: $($entry.Key)"
    $escapedName = [regex]::Escape($entry.Key)
    Assert-True (@($platformChecksumLines | Where-Object { $_ -cmatch "^$($entry.Value)  $escapedName$" }).Count -eq 1) "Platform checksum evidence is missing or duplicated: $($entry.Key)"
}
Assert-True ((Get-PngDimensions (Join-Path $platformRoot 'linux-tux.png')) -ceq '104x120') 'Tux PNG dimensions changed.'
Assert-True ((Get-PngDimensions (Join-Path $platformRoot 'qnap.png')) -ceq '1460x313') 'QNAP PNG dimensions changed.'
Assert-True ((Get-PngDimensions (Join-Path $platformRoot 'freebsd.png')) -ceq '570x164') 'FreeBSD PNG dimensions changed.'

$appleSource = [IO.File]::ReadAllText((Join-Path $platformRoot 'apple-black-source.svg'))
$appleDisplay = [IO.File]::ReadAllText((Join-Path $platformRoot 'apple.svg'))
Assert-True ($appleSource -match '<path d="(?<sourcePath>[^"]+)"') 'Apple provenance lacks its source path.'
$appleSourcePath = $Matches['sourcePath']
Assert-True ($appleDisplay -match '<path fill="#e5a00d" d="(?<displayPath>[^"]+)"') 'Apple display derivative lacks the approved TautWeekly-gold fill.'
Assert-True ($appleSourcePath -ceq $Matches['displayPath']) 'Apple display derivative changed the approved source geometry.'

foreach ($name in @('apple.svg','docker.svg','freebsd.png','linux-tux.png','qnap.png','unraid.svg','windows.svg')) {
    $docsCopy = Join-Path $Root "docs/assets/platforms/$name"
    Assert-True (Test-Path -LiteralPath $docsCopy -PathType Leaf) "Documentation platform asset is missing: $name"
    Assert-True ((Get-Sha256 $docsCopy) -ceq $expectedPlatformHashes[$name]) "Documentation platform asset changed bytes: $name"
}
Write-Host '[PASS] Platform identity sources, native colors, approved Apple derivative, dimensions, and documentation copies are verified.'

$manifest = Get-Content -LiteralPath (Join-Path $Root 'docs/site.webmanifest') -Raw | ConvertFrom-Json
Assert-True ([string]$manifest.name -ceq 'TautWeekly for Plex') 'Web manifest has the wrong product name.'
$manifestSizes = @($manifest.icons | ForEach-Object { [string]$_.sizes })
Assert-True ($manifestSizes -ccontains '192x192' -and $manifestSizes -ccontains '512x512') 'Web manifest lacks required 192/512 PNG icons.'

$pageContracts = [ordered]@{
    'docs/index.html' = 'assets/branding/tautweekly-app-icon-64.png'
    'docs/windows/index.html' = '../assets/branding/tautweekly-app-icon-64.png'
    'docs/nas-docker/index.html' = '../assets/branding/tautweekly-app-icon-64.png'
    'docs/mac/index.html' = '../assets/branding/tautweekly-app-icon-64.png'
    'docs/linux/index.html' = '../assets/branding/tautweekly-app-icon-64.png'
    'docs/freebsd/index.html' = '../assets/branding/tautweekly-app-icon-64.png'
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
$platformPages = [ordered]@{
    'docs/index.html' = @('assets/platforms/windows.svg','assets/platforms/docker.svg','assets/platforms/apple.svg','assets/platforms/linux-tux.png','assets/platforms/freebsd.png')
    'docs/windows/index.html' = @('../assets/platforms/windows.svg')
    'docs/nas-docker/index.html' = @('../assets/platforms/docker.svg','../assets/platforms/qnap.png','../assets/platforms/unraid.svg')
    'docs/mac/index.html' = @('../assets/platforms/apple.svg')
    'docs/linux/index.html' = @('../assets/platforms/linux-tux.png')
    'docs/freebsd/index.html' = @('../assets/platforms/freebsd.png')
}
foreach ($page in $platformPages.GetEnumerator()) {
    $html = [IO.File]::ReadAllText((Join-Path $Root $page.Key))
    foreach ($asset in $page.Value) {
        Assert-True ($html.Contains("src=`"$asset`" alt=`"`"")) "$($page.Key) lacks decoratively accessible platform identity: $asset"
    }
}
$homeHtml = [IO.File]::ReadAllText((Join-Path $Root 'docs/index.html'))
foreach ($placeholder in @('>WIN</div>','>NAS</div>','>MAC</div>','>LIN</div>','>BSD</div>')) {
    Assert-True (-not $homeHtml.Contains($placeholder)) "Landing page retains generic platform placeholder: $placeholder"
}
$allQuickstartHtml = @('docs/index.html','docs/windows/index.html','docs/nas-docker/index.html','docs/mac/index.html','docs/linux/index.html','docs/freebsd/index.html') | ForEach-Object { [IO.File]::ReadAllText((Join-Path $Root $_)) }
Assert-True (-not (($allQuickstartHtml -join "`n") -match '<(?:span|div)[^>]*>(?:WIN|NAS|MAC|LIN|BSD)</(?:span|div)>')) 'A Quickstart retains a generic platform abbreviation mark.'

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
Write-Host '[PASS] Global product identity and platform/package identity are applied to their classified surfaces; badges and newsletter assets remain separate.'
Write-Host 'Canonical branding validation passed.' -ForegroundColor Green
