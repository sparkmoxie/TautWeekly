param([string]$DataRoot = $(if ($env:TAUTWEEKLY_DATA_DIR) { $env:TAUTWEEKLY_DATA_DIR } else { "/data" }))
$path = Join-Path $DataRoot "access-state.json"
if (-not (Test-Path $path)) {
    Write-Host "No access roster exists yet. From an Unraid Console run /opt/tautweekly/bin/run-mode.sh ListUsers; from the Compose host project directory run ./tautweekly.sh list-users."
    exit 0
}
$state = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host ""
Write-Host "TautWeekly for Plex access roster"
Write-Host "Baseline: $($state.BaselineUtc)"
Write-Host ""
$rows = foreach ($prop in $state.Users.PSObject.Properties) {
    $u = $prop.Value
    [PSCustomObject]@{ UserId=$u.UserId; Username=$u.Username; Email=$u.Email; FirstSeenUtc=$u.FirstSeenUtc; Baseline=$u.IsBaseline; WelcomeSentUtc=$u.WelcomeSentUtc }
}
$rows | Sort-Object FirstSeenUtc | Format-Table -AutoSize
