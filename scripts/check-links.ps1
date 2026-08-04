[CmdletBinding()]
param(
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$failures = [System.Collections.Generic.List[string]]::new()
$files = Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' -and
    $_.Extension -in @('.md','.html')
}

function Test-Target {
    param([IO.FileInfo]$Source, [string]$Target)
    $clean = [Net.WebUtility]::HtmlDecode($Target.Trim())
    if ([string]::IsNullOrWhiteSpace($clean) -or
        $clean.StartsWith('#') -or
        $clean -match '\$\{[^}]+\}' -or
        $clean -match '^(?i)(?:https?:|mailto:|data:|javascript:)') {
        return
    }

    $pathPart = ($clean -split '#',2)[0] -split '\?',2 | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($pathPart)) { return }
    $pathPart = [Uri]::UnescapeDataString($pathPart)
    $candidate = [IO.Path]::GetFullPath((Join-Path $Source.DirectoryName $pathPart))
    if (-not $candidate.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add("$($Source.FullName.Substring($Root.Length).TrimStart('\','/')): link escapes repository: $Target")
        return
    }
    if (-not (Test-Path -LiteralPath $candidate)) {
        $failures.Add("$($Source.FullName.Substring($Root.Length).TrimStart('\','/')): missing target: $Target")
    }
}

foreach ($file in $files) {
    $content = [IO.File]::ReadAllText($file.FullName)
    if ($file.Extension -eq '.md') {
        foreach ($match in [regex]::Matches($content, '!?(?:\[[^\]]*\])\((?<target>[^)\s]+)(?:\s+"[^"]*")?\)')) {
            Test-Target -Source $file -Target $match.Groups['target'].Value
        }
    }
    else {
        foreach ($match in [regex]::Matches($content, '(?i)\b(?:href|src)\s*=\s*["''](?<target>[^"'']+)["'']')) {
            Test-Target -Source $file -Target $match.Groups['target'].Value
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "Relative-link validation failed with $($failures.Count) finding(s)."
}

Write-Host "[PASS] Checked relative links in $($files.Count) Markdown/HTML file(s)."
