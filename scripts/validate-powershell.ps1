[CmdletBinding()]
param(
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }

$failures = [System.Collections.Generic.List[string]]::new()
$files = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.ps1' |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    )

    foreach ($parseError in @($errors)) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
        $failures.Add("${relative}:$($parseError.Extent.StartLineNumber): $($parseError.Message)")
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "PowerShell syntax validation failed for $($failures.Count) error(s)."
}

Write-Host "[PASS] Parsed $($files.Count) PowerShell file(s)."
