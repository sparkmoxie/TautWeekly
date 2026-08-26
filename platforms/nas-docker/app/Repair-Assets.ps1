param([string]$DataRoot = $(if ($env:TAUTWEEKLY_DATA_DIR) { $env:TAUTWEEKLY_DATA_DIR } else { "/data" }))
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Explicit repair restores every shipped filename, including customized files.
# Custom-only filenames and all other runtime data remain untouched.
& python3 (Join-Path $PSScriptRoot "refresh-assets.py") --data-root $DataRoot --force
if ($LASTEXITCODE -ne 0) {
    throw "Packaged asset repair failed; the bundle marker was not advanced."
}
