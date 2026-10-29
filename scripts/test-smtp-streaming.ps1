[CmdletBinding()]
param([string]$Root = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
. (Join-Path $Root 'platforms/nas-docker/app/Smtp-Transport.ps1')
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('tautweekly-smtp-stream-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $path = Join-Path $testRoot 'synthetic.eml'
    $text = "Header: synthetic`r`n`r`n.leading dot`n..two dots`rUTF8 " + [char]0x00E9 + "`n`r`nlast line"
    [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
    $output = [IO.MemoryStream]::new()
    $writer = [IO.StreamWriter]::new($output,[Text.UTF8Encoding]::new($false),4096,$true)
    $writer.NewLine = "`r`n"
    $reader = [IO.StreamReader]::new($path,[Text.Encoding]::UTF8)
    try { Write-TautWeeklySmtpData -Writer $writer -MimeReader $reader }
    finally { $reader.Dispose(); $writer.Dispose() }
    $actual = [Text.Encoding]::UTF8.GetString($output.ToArray())
    $output.Dispose()
    $expected = "Header: synthetic`r`n`r`n..leading dot`r`n...two dots`r`nUTF8 " + [char]0x00E9 + "`r`n`r`nlast line`r`n.`r`n"
    Assert-True ($actual -ceq $expected) 'Streaming changed UTF-8, mixed line endings, empty/unterminated lines, dot stuffing or terminator'

    & {
        # Cleanup errors happen after DATA acceptance. They must remain a
        # fixed warning rather than replacing the successful delivery result.
        function Remove-Item { param($LiteralPath,[switch]$Recurse,[switch]$Force,$ErrorAction) throw 'synthetic private path that must not escape' }
        $capturedError = [IO.StringWriter]::new()
        $previousError = [Console]::Error
        try {
            [Console]::SetError($capturedError)
            Remove-TautWeeklyMimeFile -MimeFile ([PSCustomObject]@{Directory=$testRoot})
        } finally { [Console]::SetError($previousError) }
        Assert-True ($capturedError.ToString().Trim() -ceq 'Temporary serialized email cleanup was incomplete.') 'Cleanup error changed acceptance or exposed a path'
        $capturedError.Dispose()
    }

    # Measure live retained message buffers at the first output line. Both
    # paths use the same writer/line loop; the reference keeps the old strings.
    if (-not ('TautWeeklyStreamingMemoryProbe' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
public sealed class TautWeeklyStreamingMemoryProbe : StreamWriter {
    public long Before;
    public long Retained;
    private bool measured;
    public TautWeeklyStreamingMemoryProbe() : base(Stream.Null, new UTF8Encoding(false), 4096) { NewLine = "\r\n"; }
    public override void WriteLine(string value) {
        if (!measured) { Retained = GC.GetTotalMemory(true) - Before; measured = true; }
        base.WriteLine(value);
    }
}
"@
    }
    function Invoke-LegacyMimeBuffers($Path,$Writer) {
        $mimeText = [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
        $normalized = $mimeText.Replace("`r`n","`n").Replace("`r","`n")
        $referenceReader = [IO.StringReader]::new($normalized)
        try { Write-TautWeeklySmtpData -Writer $Writer -MimeReader $referenceReader }
        finally { $referenceReader.Dispose() }
    }
    function Measure-MimeBuffers([string]$Path,[bool]$Legacy) {
        $probe = [TautWeeklyStreamingMemoryProbe]::new()
        $probe.Before = [GC]::GetTotalMemory($true)
        try {
            if ($Legacy) { Invoke-LegacyMimeBuffers $Path $probe }
            else {
                $streamReader = [IO.StreamReader]::new($Path,[Text.Encoding]::UTF8)
                try { Write-TautWeeklySmtpData -Writer $probe -MimeReader $streamReader }
                finally { $streamReader.Dispose() }
            }
            return [Math]::Max(0L,$probe.Retained)
        } finally { $probe.Dispose() }
    }
    # Warm the PowerShell/.NET binders before the bounded 3 MiB comparison.
    [void](Measure-MimeBuffers $path $true)
    [void](Measure-MimeBuffers $path $false)
    $file = [IO.File]::Create($path)
    try {
        $lineBytes = [Text.Encoding]::ASCII.GetBytes(('x' * 74) + "`r`n")
        for ($index=0; $index -lt 42000; $index++) { $file.Write($lineBytes,0,$lineBytes.Length) }
    } finally { $file.Dispose() }
    $legacyBytes = Measure-MimeBuffers $path $true
    $streamBytes = Measure-MimeBuffers $path $false
    $fileBytes = (Get-Item -LiteralPath $path).Length
    Assert-True ($legacyBytes -gt $fileBytes -and $streamBytes -lt $legacyBytes / 2) 'Streaming retained unexpectedly large whole-message buffers'
    Write-Host "[PASS] MIME streaming memory: fixtureBytes=$fileBytes; oldRetainedBytes=$legacyBytes; streamedRetainedBytes=$streamBytes."
    Write-Host '[PASS] SMTP DATA preserves UTF-8, CRLF, dot stuffing, blank lines and the final terminator.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
