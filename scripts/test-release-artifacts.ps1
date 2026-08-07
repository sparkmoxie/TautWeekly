[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$DistPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
if ([string]::IsNullOrWhiteSpace($DistPath)) { $DistPath = Join-Path $Root 'dist' }
$DistPath = [IO.Path]::GetFullPath($DistPath)

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$expected = [ordered]@{
    'TautWeekly-windows.zip' = @(
        'TautWeekly-windows/TautWeekly.ps1',
        'TautWeekly-windows/Smtp-Transport.ps1',
        'TautWeekly-windows/config.example.json',
        'TautWeekly-windows/15-MANAGE-LIBRARIES.bat',
        'TautWeekly-windows/16-LIST-LIBRARIES.bat',
        'TautWeekly-windows/README.md'
    )
    'TautWeekly-nas-docker.zip' = @(
        'TautWeekly-nas-docker/app/TautWeekly.ps1',
        'TautWeekly-nas-docker/app/Smtp-Transport.ps1',
        'TautWeekly-nas-docker/app/Schedule-Time.ps1',
        'TautWeekly-nas-docker/app/healthcheck.sh',
        'TautWeekly-nas-docker/tautweekly.sh',
        'TautWeekly-nas-docker/compose.yaml',
        'TautWeekly-nas-docker/README.md'
    )
    'TautWeekly-mac-docker.zip' = @(
        'TautWeekly-mac-docker/app/TautWeekly.ps1',
        'TautWeekly-mac-docker/app/Smtp-Transport.ps1',
        'TautWeekly-mac-docker/app/Schedule-Time.ps1',
        'TautWeekly-mac-docker/tautweekly.sh',
        'TautWeekly-mac-docker/INSTALL-MAC.command',
        'TautWeekly-mac-docker/README.md'
    )
    'TautWeekly-linux.zip' = @(
        'TautWeekly-linux/app/TautWeekly.ps1',
        'TautWeekly-linux/app/Smtp-Transport.ps1',
        'TautWeekly-linux/app/Schedule-Time.ps1',
        'TautWeekly-linux/install-linux.sh',
        'TautWeekly-linux/systemd/tautweekly.service',
        'TautWeekly-linux/tautweekly',
        'TautWeekly-linux/README.md'
    )
    'TautWeekly-freebsd-podman.zip' = @(
        'TautWeekly-freebsd-podman/app/TautWeekly.ps1',
        'TautWeekly-freebsd-podman/app/Smtp-Transport.ps1',
        'TautWeekly-freebsd-podman/app/Schedule-Time.ps1',
        'TautWeekly-freebsd-podman/install-freebsd.sh',
        'TautWeekly-freebsd-podman/rc.d/tautweekly',
        'TautWeekly-freebsd-podman/tautweekly',
        'TautWeekly-freebsd-podman/README.md'
    )
}

$forbiddenNames = @(
    'config.json', '.env', 'state.json', 'access-state.json',
    'scheduler-state.json', 'scheduler-heartbeat.json', 'service-heartbeat.json'
)

foreach ($archiveName in $expected.Keys) {
    $archivePath = Join-Path $DistPath $archiveName
    Assert-True (Test-Path -LiteralPath $archivePath) "Missing release artifact: $archiveName"
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        foreach ($requiredEntry in $expected[$archiveName]) {
            Assert-True ($entryNames -ccontains $requiredEntry) "$archiveName is missing $requiredEntry"
        }

        $forbidden = @($entryNames | Where-Object {
            $name = ($_ -split '/')[-1]
            $name -in $forbiddenNames -or $_ -match '/(logs|output)/'
        })
        Assert-True ($forbidden.Count -eq 0) "$archiveName contains runtime/private paths: $($forbidden -join ', ')"

        $rendererEntry = @($archive.Entries | Where-Object { $_.FullName -match '/(?:app/)?TautWeekly\.ps1$' } | Select-Object -First 1)
        Assert-True ($rendererEntry.Count -eq 1) "$archiveName has no production renderer."
        $reader = New-Object IO.StreamReader($rendererEntry[0].Open())
        try { $renderer = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
        Assert-True ($renderer.Contains('Get-OptionalStringProperty -InputObject $Row -Name "section_id"')) "$archiveName lacks the executable library predicate fix."
        Assert-True ($renderer.Contains('$params.section_id = $sectionId')) "$archiveName lacks server-side selected-library scoping."
        Assert-True ($renderer.Contains('Smtp-Transport.ps1')) "$archiveName does not load the explicit SMTP authentication transport."
        Assert-True ($renderer.Contains('Send-TautWeeklySmtpMessage')) "$archiveName does not route mail through the explicit SMTP transport."

        Write-Host "[PASS] Release payload contract: $archiveName ($($archive.Entries.Count) entries)"
    }
    finally {
        $archive.Dispose()
    }
}

$checksumPath = Join-Path $DistPath 'SHA256SUMS.txt'
Assert-True (Test-Path -LiteralPath $checksumPath) 'SHA256SUMS.txt is missing.'
$checksumLines = @(Get-Content -LiteralPath $checksumPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$artifacts = @(Get-ChildItem -LiteralPath $DistPath -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' })
Assert-True ($checksumLines.Count -eq $artifacts.Count) 'Checksum manifest does not cover every artifact exactly once.'
foreach ($artifact in $artifacts) {
    $line = @($checksumLines | Where-Object { $_ -match ('\s\s' + [regex]::Escape($artifact.Name) + '$') })
    Assert-True ($line.Count -eq 1) "Checksum entry is missing or duplicated for $($artifact.Name)."
    $expectedHash = ($line[0] -split '\s+', 2)[0].ToUpperInvariant()
    $actualHash = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    Assert-True ($expectedHash -eq $actualHash) "SHA-256 mismatch for $($artifact.Name)."
}

Write-Host 'Release artifact functional contracts and SHA-256 checks passed.' -ForegroundColor Green
