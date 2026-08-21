[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RendererPath,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$UserId,
    [ValidateSet('VerifyPlex', 'PreviewAll', 'SendTest', 'SendAll')][string]$Mode = 'PreviewAll',
    [string]$ResultPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows normally opens a generated preview automatically. The integration
# runner verifies the files directly and must remain non-interactive.
function global:Start-Process {
    param([Parameter(Position = 0)][string]$FilePath)
    Write-Host "[TEST] Suppressed preview open: $FilePath"
}

$resultArguments = @{}
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $resultArguments.ResultPath = $ResultPath
}

if ($Mode -eq 'VerifyPlex') {
    & $RendererPath -Mode $Mode -ConfigPath $ConfigPath @resultArguments
    exit $LASTEXITCODE
}
elseif ($Mode -eq 'SendAll') {
    & $RendererPath -Mode $Mode -ConfigPath $ConfigPath -ConfirmSendAll @resultArguments
}
else {
    & $RendererPath -Mode $Mode -ConfigPath $ConfigPath -UserId $UserId @resultArguments
}
exit $LASTEXITCODE
