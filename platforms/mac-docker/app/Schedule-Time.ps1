function Get-TautWeeklyScheduleTimeZone {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$TimeZoneId = [string]$env:TZ
    )

    if ([string]::IsNullOrWhiteSpace($TimeZoneId)) {
        $TimeZoneId = 'Etc/UTC'
    }

    try {
        return [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    }
    catch {
        throw "TZ '$TimeZoneId' is not a valid IANA time zone in this runtime. Automatic delivery is refusing to fall back to UTC. Correct the platform timezone and restart or recreate the service."
    }
}

function Get-TautWeeklyScheduleNow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [TimeZoneInfo]$TimeZone,
        [DateTimeOffset]$UtcNow = [DateTimeOffset]::UtcNow
    )

    return [TimeZoneInfo]::ConvertTime($UtcNow, $TimeZone)
}

function ConvertTo-TautWeeklyScheduleUtc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [TimeZoneInfo]$TimeZone,
        [Parameter(Mandatory)]
        [DateTime]$LocalTime
    )

    $unspecifiedLocalTime = [DateTime]::SpecifyKind($LocalTime, [DateTimeKind]::Unspecified)
    return [TimeZoneInfo]::ConvertTimeToUtc($unspecifiedLocalTime, $TimeZone)
}
