$path = Join-Path $PSScriptRoot "access-state.json"

if (-not (Test-Path $path)) {
    Write-Host "No access roster exists yet. Run 02-LIST-USERS.bat or 03-PREVIEW-NEWSLETTER.bat first."
    exit 0
}

$state = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host ""
Write-Host "PlexWeekly access roster"
Write-Host "Baseline: $($state.BaselineUtc)"
Write-Host ""

$rows = @()
foreach ($prop in $state.Users.PSObject.Properties) {
    $u = $prop.Value
    $rows += [PSCustomObject]@{
        UserId         = $u.UserId
        Username       = $u.Username
        Email          = $u.Email
        FirstSeenUtc   = $u.FirstSeenUtc
        Baseline       = $u.IsBaseline
        WelcomeSentUtc = $u.WelcomeSentUtc
    }
}
$rows | Sort-Object FirstSeenUtc | Format-Table -AutoSize
