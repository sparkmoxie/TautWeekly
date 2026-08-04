Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$assets = Join-Path $PSScriptRoot "assets"
New-Item -ItemType Directory -Force -Path $assets | Out-Null

Add-Type -AssemblyName System.Drawing

function Get-FrameCount {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return 0 }

    $img = $null
    try {
        $img = [System.Drawing.Image]::FromFile($Path)
        if ($img.FrameDimensionsList.Count -eq 0) { return 1 }
        $dimension = New-Object System.Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0])
        return $img.GetFrameCount($dimension)
    }
    catch {
        return 0
    }
    finally {
        if ($null -ne $img) { $img.Dispose() }
    }
}

function Ensure-AnimatedGif {
    param(
        [string]$Name,
        [string]$Url
    )

    $path = Join-Path $assets $Name
    $frames = Get-FrameCount -Path $path

    if ($frames -gt 1) {
        Write-Host "$Name already animated ($frames frames). Keeping it." -ForegroundColor Green
        return
    }

    if ($frames -eq 1) {
        Write-Host "$Name is static. Replacing with the official animated GIF..." -ForegroundColor Yellow
    }
    else {
        Write-Host "$Name is missing. Downloading the official animated GIF..."
    }

    $temp = "$path.download"
    Invoke-WebRequest -Uri $Url -OutFile $temp -UseBasicParsing -TimeoutSec 60

    $newFrames = Get-FrameCount -Path $temp
    if ($newFrames -le 1) {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
        throw "Downloaded $Name did not contain multiple animation frames."
    }

    Move-Item -Path $temp -Destination $path -Force
    Write-Host "$Name installed successfully ($newFrames frames)." -ForegroundColor Green
}

Ensure-AnimatedGif `
    -Name "movies.gif" `
    -Url "https://fonts.gstatic.com/s/e/notoemoji/latest/1f39e_fe0f/512.gif"

Ensure-AnimatedGif `
    -Name "tv.gif" `
    -Url "https://fonts.gstatic.com/s/e/notoemoji/latest/1f4fa/512.gif"

Write-Host ""
Write-Host "Animated movie and TV assets are ready." -ForegroundColor Green
