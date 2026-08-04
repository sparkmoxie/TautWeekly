Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$configPath = Join-Path $PSScriptRoot "config.json"
$taskName = "TautWeekly for Plex Newsletter"
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $config.PSObject.Properties["ScheduledTaskName"] -and -not [string]::IsNullOrWhiteSpace([string]$config.ScheduledTaskName)) {
            $taskName = [string]$config.ScheduledTaskName
        }
    } catch { }
}
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed scheduled task: $taskName" -ForegroundColor Green
} else {
    Write-Host "Scheduled task was not installed: $taskName" -ForegroundColor Yellow
}
