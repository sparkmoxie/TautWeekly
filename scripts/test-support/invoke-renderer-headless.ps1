[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RendererPath,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$UserId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows normally opens a generated preview automatically. The integration
# runner verifies the files directly and must remain non-interactive.
function global:Start-Process {
    param([Parameter(Position = 0)][string]$FilePath)
    Write-Host "[TEST] Suppressed preview open: $FilePath"
}

& $RendererPath -Mode PreviewAll -ConfigPath $ConfigPath -UserId $UserId
