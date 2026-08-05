function Invoke-TautWeeklyLibraryApi {
    param(
        [Parameter(Mandatory = $true)][string]$TautulliUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)][string]$Command,
        [hashtable]$Parameters = @{}
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("apikey={0}" -f [Uri]::EscapeDataString($ApiKey))
    $parts.Add("cmd={0}" -f [Uri]::EscapeDataString($Command))
    foreach ($entry in $Parameters.GetEnumerator()) {
        $parts.Add("{0}={1}" -f [Uri]::EscapeDataString([string]$entry.Key), [Uri]::EscapeDataString([string]$entry.Value))
    }

    $uri = "{0}/api/v2?{1}" -f $TautulliUrl.TrimEnd('/'), ($parts -join '&')
    try {
        $raw = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20
    }
    catch {
        throw 'Could not query Tautulli libraries. Check the Tautulli URL, API key, and network access.'
    }

    if ($null -eq $raw -or $null -eq $raw.PSObject.Properties['response']) {
        throw 'Tautulli returned an unexpected response while loading libraries.'
    }
    if ([string]$raw.response.result -ne 'success') {
        throw 'Tautulli rejected the library lookup request. Check the API key and Tautulli permissions.'
    }

    return $raw.response.data
}

function Get-TautWeeklyLibraryObjectValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-TautWeeklyUniqueLibraryIds {
    param([AllowNull()][object[]]$Values = @())

    $result = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @($Values)) {
        $id = [string]$value
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $id = $id.Trim()
        if ($seen.Add($id)) { $result.Add($id) }
    }
    return @($result)
}

function Get-TautWeeklySelectableLibraries {
    param(
        [Parameter(Mandatory = $true)][string]$TautulliUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey
    )

    $rawLibraries = @(Invoke-TautWeeklyLibraryApi -TautulliUrl $TautulliUrl -ApiKey $ApiKey -Command 'get_libraries')
    $libraries = New-Object System.Collections.Generic.List[object]

    foreach ($library in $rawLibraries) {
        $sectionId = [string](Get-TautWeeklyLibraryObjectValue -InputObject $library -Name 'section_id' -Default '')
        if ([string]::IsNullOrWhiteSpace($sectionId)) { continue }

        $sectionType = ([string](Get-TautWeeklyLibraryObjectValue -InputObject $library -Name 'section_type' -Default '')).ToLowerInvariant()
        $isActiveValue = Get-TautWeeklyLibraryObjectValue -InputObject $library -Name 'is_active' -Default 1
        [int]$isActive = 1
        [void][int]::TryParse([string]$isActiveValue, [ref]$isActive)
        $selectable = ($isActive -gt 0 -and $sectionType -in @('movie','show'))

        $libraries.Add([PSCustomObject]@{
            SectionId = $sectionId.Trim()
            Name = [string](Get-TautWeeklyLibraryObjectValue -InputObject $library -Name 'section_name' -Default "Library $sectionId")
            Type = $sectionType
            ItemCount = [string](Get-TautWeeklyLibraryObjectValue -InputObject $library -Name 'count' -Default '')
            IsActive = ($isActive -gt 0)
            Selectable = $selectable
        })
    }

    return @($libraries | Sort-Object @{ Expression = { -not $_.Selectable } }, Type, Name, SectionId)
}

function Get-TautWeeklyEffectiveLibraryIds {
    param(
        [Parameter(Mandatory = $true)][object[]]$Libraries,
        [AllowNull()][object[]]$ConfiguredLibraryIds = @()
    )

    $configured = @(Get-TautWeeklyUniqueLibraryIds -Values $ConfiguredLibraryIds)
    if ($configured.Count -gt 0) { return @($configured) }
    return @(Get-TautWeeklyUniqueLibraryIds -Values @($Libraries | Where-Object { $_.Selectable } | ForEach-Object { $_.SectionId }))
}

function Show-TautWeeklyLibrarySelection {
    param(
        [Parameter(Mandatory = $true)][object[]]$Libraries,
        [AllowNull()][object[]]$CurrentIncludedLibraryIds = @()
    )

    $effective = @(Get-TautWeeklyEffectiveLibraryIds -Libraries $Libraries -ConfiguredLibraryIds $CurrentIncludedLibraryIds)
    $includedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $effective) { [void]$includedSet.Add([string]$id) }

    Write-Host ''
    Write-Host 'Newsletter library selection' -ForegroundColor Cyan
    Write-Host 'Selected libraries feed releases, quiet mode, Trending, Binge Champion, and personal statistics.'
    Write-Host ''
    Write-Host ('{0,-4} {1,-10} {2,-8} {3,-32} {4,-12} {5}' -f '#', 'Status', 'Type', 'Library', 'Section ID', 'Items')
    Write-Host ('{0,-4} {1,-10} {2,-8} {3,-32} {4,-12} {5}' -f '--', '----------', '--------', '--------------------------------', '------------', '-----')

    $row = 0
    foreach ($library in $Libraries) {
        if ($library.Selectable) {
            $row++
            $number = [string]$row
            $status = if ($includedSet.Contains([string]$library.SectionId)) { 'INCLUDED' } else { 'excluded' }
        }
        else {
            $number = '-'
            $status = if (-not $library.IsActive) { 'inactive' } else { 'unsupported' }
        }
        $type = if ([string]::IsNullOrWhiteSpace([string]$library.Type)) { 'unknown' } else { [string]$library.Type }
        $count = if ([string]::IsNullOrWhiteSpace([string]$library.ItemCount)) { '-' } else { [string]$library.ItemCount }
        Write-Host ('{0,-4} {1,-10} {2,-8} {3,-32} {4,-12} {5}' -f $number, $status, $type, [string]$library.Name, [string]$library.SectionId, $count)
    }

    $configured = @(Get-TautWeeklyUniqueLibraryIds -Values $CurrentIncludedLibraryIds)
    $knownIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($library in $Libraries) { [void]$knownIds.Add([string]$library.SectionId) }
    $unknownIds = @($configured | Where-Object { -not $knownIds.Contains([string]$_) })
    if ($unknownIds.Count -gt 0) {
        Write-Host ''
        Write-Host ('Configured section IDs not returned by Tautulli: {0}' -f ($unknownIds -join ', ')) -ForegroundColor Yellow
    }

    return $row
}

function ConvertFrom-TautWeeklyLibrarySelection {
    param(
        [AllowNull()][string]$Selection,
        [Parameter(Mandatory = $true)][object[]]$Libraries,
        [AllowNull()][object[]]$CurrentIncludedLibraryIds = @()
    )

    $selectable = @($Libraries | Where-Object { $_.Selectable })
    if ($selectable.Count -eq 0) {
        return [PSCustomObject]@{ Valid = $false; Message = 'Tautulli returned no active movie or TV libraries.'; LibraryIds = @() }
    }

    $current = @(Get-TautWeeklyEffectiveLibraryIds -Libraries $Libraries -ConfiguredLibraryIds $CurrentIncludedLibraryIds)
    $raw = if ($null -eq $Selection) { '' } else { $Selection.Trim() }

    if ([string]::IsNullOrWhiteSpace($raw) -or $raw -ieq 'keep') {
        $selectableIds = @($selectable | ForEach-Object { [string]$_.SectionId })
        if (@($current | Where-Object { $selectableIds -contains $_ }).Count -eq 0) {
            return [PSCustomObject]@{ Valid = $false; Message = 'The current selection contains no active movie or TV library. Choose at least one row or type all.'; LibraryIds = @() }
        }
        return [PSCustomObject]@{ Valid = $true; Message = ''; LibraryIds = @($current) }
    }
    if ($raw -ieq 'all') {
        return [PSCustomObject]@{ Valid = $true; Message = ''; LibraryIds = @(Get-TautWeeklyUniqueLibraryIds -Values @($selectable | ForEach-Object { $_.SectionId })) }
    }
    if ($raw -ieq 'none') {
        return [PSCustomObject]@{ Valid = $false; Message = 'At least one active movie or TV library must be included.'; LibraryIds = @() }
    }

    $selectedRows = New-Object System.Collections.Generic.List[int]
    $selectedSet = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($tokenValue in @($raw -split ',')) {
        $token = ([string]$tokenValue).Trim()
        if ($token -match '^([0-9]+)-([0-9]+)$') {
            $first = [int]$Matches[1]
            $last = [int]$Matches[2]
            if ($first -lt 1 -or $last -gt $selectable.Count -or $first -gt $last) {
                return [PSCustomObject]@{ Valid = $false; Message = "Row range '$token' is outside 1-$($selectable.Count)."; LibraryIds = @() }
            }
            foreach ($row in $first..$last) {
                if ($selectedSet.Add($row)) { $selectedRows.Add($row) }
            }
            continue
        }
        if ($token -notmatch '^[0-9]+$') {
            return [PSCustomObject]@{ Valid = $false; Message = "'$token' is not a row number or range."; LibraryIds = @() }
        }
        $rowNumber = [int]$token
        if ($rowNumber -lt 1 -or $rowNumber -gt $selectable.Count) {
            return [PSCustomObject]@{ Valid = $false; Message = "Row '$token' is outside 1-$($selectable.Count)."; LibraryIds = @() }
        }
        if ($selectedSet.Add($rowNumber)) { $selectedRows.Add($rowNumber) }
    }

    if ($selectedRows.Count -eq 0) {
        return [PSCustomObject]@{ Valid = $false; Message = 'At least one active movie or TV library must be included.'; LibraryIds = @() }
    }

    $ids = @($selectedRows | ForEach-Object { [string]$selectable[$_ - 1].SectionId })
    return [PSCustomObject]@{ Valid = $true; Message = ''; LibraryIds = @(Get-TautWeeklyUniqueLibraryIds -Values $ids) }
}

function Read-TautWeeklyIncludedLibraryIds {
    param(
        [Parameter(Mandatory = $true)][object[]]$Libraries,
        [AllowNull()][object[]]$CurrentIncludedLibraryIds = @()
    )

    $selectableCount = Show-TautWeeklyLibrarySelection -Libraries $Libraries -CurrentIncludedLibraryIds $CurrentIncludedLibraryIds
    if ($selectableCount -eq 0) { throw 'Tautulli returned no active movie or TV libraries.' }

    Write-Host ''
    Write-Host 'Enter rows to include, for example 1,3-4. This replaces the current selection.'
    Write-Host "Type 'all' to include every active movie/TV library; press Enter (or type 'keep') to keep the displayed selection."

    while ($true) {
        $selection = Read-Host 'Rows to include'
        $parsed = ConvertFrom-TautWeeklyLibrarySelection -Selection $selection -Libraries $Libraries -CurrentIncludedLibraryIds $CurrentIncludedLibraryIds
        if ([bool]$parsed.Valid) { return @($parsed.LibraryIds) }
        Write-Host ([string]$parsed.Message) -ForegroundColor Yellow
    }
}
