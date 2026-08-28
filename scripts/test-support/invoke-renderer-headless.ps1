[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RendererPath,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [string]$UserId = '',
    [ValidateSet('VerifyPlex', 'Preview', 'PreviewAll', 'CacheWarm', 'SendTest', 'SendTestAll', 'SendAll')][string]$Mode = 'PreviewAll',
    [string]$ResultPath = '',
    [switch]$NoConfirmSendAll
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

if ($Mode -in @('VerifyPlex', 'CacheWarm')) {
    & $RendererPath -Mode $Mode -ConfigPath $ConfigPath @resultArguments
    exit $LASTEXITCODE
}
elseif ($Mode -eq 'SendAll') {
    if ($NoConfirmSendAll) {
        & $RendererPath -Mode $Mode -ConfigPath $ConfigPath @resultArguments
    }
    else {
        & $RendererPath -Mode $Mode -ConfigPath $ConfigPath -ConfirmSendAll @resultArguments
    }
}
else {
    if ([string]::IsNullOrWhiteSpace($UserId)) {
        throw "$Mode requires a synthetic user identifier in the headless integration runner."
    }
    & $RendererPath -Mode $Mode -ConfigPath $ConfigPath -UserId $UserId @resultArguments
}
exit $LASTEXITCODE
