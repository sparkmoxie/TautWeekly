[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RendererPath,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$UserId,
    [ValidateSet('PreviewAll', 'SendTest', 'SendAll')][string]$Mode = 'PreviewAll'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows normally opens a generated preview automatically. The integration
# runner verifies the files directly and must remain non-interactive.
function global:Start-Process {
    param([Parameter(Position = 0)][string]$FilePath)
    Write-Host "[TEST] Suppressed preview open: $FilePath"
}

if ($Mode -eq 'SendAll') {
    & $RendererPath -Mode $Mode -ConfigPath $ConfigPath -ConfirmSendAll
}
else {
    & $RendererPath -Mode $Mode -ConfigPath $ConfigPath -UserId $UserId
}
