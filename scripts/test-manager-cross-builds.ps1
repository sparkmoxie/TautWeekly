[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$GoPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
if ([string]::IsNullOrWhiteSpace($GoPath)) {
    $GoPath = Get-Command go -CommandType Application -ErrorAction Stop |
        Select-Object -First 1 -ExpandProperty Source
}
$GoPath = [IO.Path]::GetFullPath($GoPath)
if (-not (Test-Path -LiteralPath $GoPath -PathType Leaf)) {
    throw "Go executable was not found: $GoPath"
}

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$buildRoot = Join-Path $tempParent ('tautweekly-manager-cross-build-' + [Guid]::NewGuid().ToString('N'))
$buildRoot = [IO.Path]::GetFullPath($buildRoot)
if (-not $buildRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe Manager cross-build root: $buildRoot"
}
New-Item -ItemType Directory -Path $buildRoot | Out-Null

$targets = @(
    @('windows', 'amd64'),
    @('windows', 'arm64'),
    @('linux', 'amd64'),
    @('linux', 'arm64'),
    @('darwin', 'amd64'),
    @('darwin', 'arm64'),
    @('freebsd', 'amd64'),
    @('freebsd', 'arm64')
)
$previousGoOS = $env:GOOS
$previousGoArch = $env:GOARCH
$previousCGO = $env:CGO_ENABLED
try {
    $env:CGO_ENABLED = '0'
    Push-Location (Join-Path $Root 'manager')
    try {
        foreach ($target in $targets) {
            $env:GOOS = $target[0]
            $env:GOARCH = $target[1]
            $suffix = if ($env:GOOS -eq 'windows') { '.exe' } else { '' }
            $output = Join-Path $buildRoot ("tautweekly-manager-{0}-{1}{2}" -f $env:GOOS, $env:GOARCH, $suffix)
            & $GoPath build -trimpath -buildvcs=false -o $output ./cmd/tautweekly-manager
            if ($LASTEXITCODE -ne 0) {
                throw "Manager cross-build failed for $($env:GOOS)/$($env:GOARCH)."
            }
            if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
                throw "Manager cross-build did not produce $output."
            }
            Write-Host "[PASS] Manager cross-build $($env:GOOS)/$($env:GOARCH)"
        }
    }
    finally { Pop-Location }
}
finally {
    if ($null -eq $previousGoOS) { Remove-Item Env:GOOS -ErrorAction SilentlyContinue } else { $env:GOOS = $previousGoOS }
    if ($null -eq $previousGoArch) { Remove-Item Env:GOARCH -ErrorAction SilentlyContinue } else { $env:GOARCH = $previousGoArch }
    if ($null -eq $previousCGO) { Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue } else { $env:CGO_ENABLED = $previousCGO }
    if (Test-Path -LiteralPath $buildRoot) {
        $resolved = [IO.Path]::GetFullPath($buildRoot)
        if ($resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved).StartsWith('tautweekly-manager-cross-build-', [StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
