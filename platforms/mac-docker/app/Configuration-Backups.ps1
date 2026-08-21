Set-StrictMode -Version Latest

$script:TautWeeklyConfigurationBackupLimit = 10
$script:TautWeeklyConfigurationBackupPattern = '^config\.backup\.\d{8}-\d{6}(?:\.\d{9}Z)?\.json$'

function Invoke-TautWeeklyConfigurationBackupRetention {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return
    }
    $backups = @(
        Get-ChildItem -LiteralPath $Directory -File -ErrorAction Stop |
            Where-Object {
                $_.Name -match $script:TautWeeklyConfigurationBackupPattern -and
                -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
            } |
            Sort-Object Name -Descending
    )
    foreach ($backup in @($backups | Select-Object -Skip $script:TautWeeklyConfigurationBackupLimit)) {
        try { Remove-Item -LiteralPath $backup.FullName -Force -ErrorAction Stop }
        catch { if (Test-Path -LiteralPath $backup.FullName) { throw } }
    }
}

function New-TautWeeklyConfigurationBackup {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss.fffffff'00Z'", [Globalization.CultureInfo]::InvariantCulture)
    $backupPath = Join-Path $Directory ("config.backup.{0}.json" -f $stamp)
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -ErrorAction Stop
    if ($PSVersionTable.ContainsKey('Platform') -and [string]$PSVersionTable['Platform'] -eq 'Unix') {
        try { & /bin/chmod 600 $backupPath 2>$null } catch { }
    }
    Invoke-TautWeeklyConfigurationBackupRetention -Directory $Directory
    return $backupPath
}
