param([string]$DataRoot = $(if ($env:TAUTWEEKLY_DATA_DIR) { $env:TAUTWEEKLY_DATA_DIR } else { "/data" }))
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$source = "/opt/tautweekly/assets-default"
$target = Join-Path $DataRoot "assets"
New-Item -ItemType Directory -Force -Path $target | Out-Null
foreach ($item in Get-ChildItem $source -File) {
    $dest = Join-Path $target $item.Name
    if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 100) {
        Copy-Item $item.FullName $dest -Force
        Write-Host "Restored $($item.Name)"
    }
}
$previewTarget = Join-Path (Join-Path $DataRoot "output") "assets"

if (Test-Path -LiteralPath $previewTarget) {
    $existing = Get-Item -LiteralPath $previewTarget -Force
    if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Remove-Item -LiteralPath $previewTarget -Force
    }
}

New-Item -ItemType Directory -Force -Path $previewTarget | Out-Null
foreach ($item in Get-ChildItem $target -File) {
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $previewTarget $item.Name) -Force
}

Write-Host "Packaged assets are present in $target" -ForegroundColor Green
Write-Host "Browser-preview assets are mirrored in $previewTarget" -ForegroundColor Green
