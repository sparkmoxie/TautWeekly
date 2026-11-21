function Invoke-TautWeeklyLibraryApi {
    param(
        [Parameter(Mandatory = $true)][string]$TautulliUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)][string]$Command,
        [hashtable]$Parameters = @{}
    )

    $baseUri = $null
    if (-not [Uri]::TryCreate($TautulliUrl, [UriKind]::Absolute, [ref]$baseUri) -or
        $baseUri.Scheme -notin @('http', 'https') -or $baseUri.UserInfo -or $baseUri.Query -or $baseUri.Fragment) {
        throw 'TautulliUrl must be an HTTP(S) server URL without credentials, query, or fragment.'
    }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("cmd={0}" -f [Uri]::EscapeDataString($Command))
    foreach ($entry in $Parameters.GetEnumerator()) {
        if ([string]$entry.Key -ieq 'apikey') { throw 'Tautulli API keys must be sent in the request header.' }
        $parts.Add("{0}={1}" -f [Uri]::EscapeDataString([string]$entry.Key), [Uri]::EscapeDataString([string]$entry.Value))
    }

    $uri = "{0}/api/v2?{1}" -f $TautulliUrl.TrimEnd('/'), ($parts -join '&')
    try {
        $raw = Invoke-RestMethod -Uri $uri -Headers @{ 'X-Api-Key' = $ApiKey } -MaximumRedirection 0 -Method Get -TimeoutSec 20
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

    Get-TautWeeklyLibraryRoster -Query {
        param($Command, $Parameters)
        Invoke-TautWeeklyLibraryApi -TautulliUrl $TautulliUrl -ApiKey $ApiKey -Command $Command -Parameters $Parameters
    }
}

function Group-TautWeeklyLibraryRows {
    param([AllowEmptyCollection()][object[]]$Rows)

    $byId = @{}
    foreach ($row in $Rows) {
        $id = ([string](Get-TautWeeklyLibraryObjectValue $row 'section_id')).Trim()
        if ($id -eq '') { continue }
        if (-not $byId.ContainsKey($id)) { $byId[$id] = [Collections.Generic.List[object]]::new() }
        $byId[$id].Add($row)
    }
    return $byId
}

function Get-TautWeeklyLibraryRoster {
    param([scriptblock]$Query, [object[]]$FrozenLibraries)

    $live = if ($PSBoundParameters.ContainsKey('FrozenLibraries')) { $FrozenLibraries } else { & $Query 'get_libraries' @{} }
    $known = @(& $Query 'get_library_names' @{ include_archived = 1 })
    ConvertTo-TautWeeklySelectableLibraries -LiveLibraries @($live) -KnownLibraries $known -Query $Query
}

function Resolve-TautWeeklyTableLibrary {
    param($Details, $Names, [string]$ServerId, [bool]$ArchiveCapable)

    $active = $null
    $nonDeleted = 0
    foreach ($row in $Details) {
        $isActive = [string](Get-TautWeeklyLibraryObjectValue $row 'is_active')
        $deleted = [string](Get-TautWeeklyLibraryObjectValue $row 'deleted_section')
        $archived = [string](Get-TautWeeklyLibraryObjectValue $row 'is_archived')
        if ($isActive -notin @('0','1','false','true')) { return }
        # Before 2.19 the table excludes deleted rows and has no archive flag.
        if ($ArchiveCapable -and ($deleted -notin @('0','1','false','true') -or $archived -notin @('0','1','false','true'))) { return }
        if ($deleted -notin @('1','true')) { $nonDeleted++ }
        if ($isActive -in @('1','true')) {
            if ($null -ne $active) { return }
            $active = $row
        }
    }
    if ($null -eq $active) { return }
    if ($null -ne $Names -and $nonDeleted -lt $Names.Count) { return }
    if ($ServerId -ceq '' -or $ServerId -cne [string](Get-TautWeeklyLibraryObjectValue $active 'server_id')) { return }

    if ([string](Get-TautWeeklyLibraryObjectValue $active 'deleted_section') -in @('1','true')) { return $active }

    # Other servers can have different types or archive settings under this ID.
    $type = [string](Get-TautWeeklyLibraryObjectValue $active 'section_type')
    $archived = [string](Get-TautWeeklyLibraryObjectValue $active 'is_archived' '0')
    foreach ($name in $Names) {
        $nameArchive = [string](Get-TautWeeklyLibraryObjectValue $name 'is_archived')
        if ($ArchiveCapable -and $nameArchive -notin @('1','0','true','false')) { continue }
        if ([string](Get-TautWeeklyLibraryObjectValue $name 'section_type') -eq $type -and
            (($archived -in @('1','true')) -eq ($nameArchive -in @('1','true')))) { return $active }
    }
}

function ConvertTo-TautWeeklySelectableLibraries {
    param([AllowEmptyCollection()][object[]]$LiveLibraries, [AllowEmptyCollection()][object[]]$KnownLibraries, [scriptblock]$Query)

    $liveById = Group-TautWeeklyLibraryRows $LiveLibraries
    $knownById = Group-TautWeeklyLibraryRows $KnownLibraries
    $archiveCapable = $false
    foreach ($name in $KnownLibraries) {
        if ($null -ne $name -and $null -ne $name.PSObject.Properties['is_archived']) { $archiveCapable = $true; break }
    }
    $useTable = $archiveCapable
    foreach ($library in $LiveLibraries) {
        if ($null -eq $library) { continue }
        if (Get-TautWeeklyLibraryObjectValue $library 'archive_capable' $false) { $archiveCapable = $true }
        $id = ([string](Get-TautWeeklyLibraryObjectValue $library 'section_id')).Trim()
        if (($knownById.ContainsKey($id) -and $knownById[$id].Count -gt 1) -or
            (Get-TautWeeklyLibraryObjectValue $library 'server_id')) { $useTable = $true }
    }

    $detailsById = @{}
    $serverId = ''
    if ($useTable -and $null -ne $Query) {
        try {
            # Even a singleton name can be stale: names omit deleted rows.
            $table = & $Query 'get_libraries_table' @{ include_archived = 1; include_deleted = 1; start = 0; length = -1 }
            if ($null -eq $table -or $null -eq $table.PSObject.Properties['data'] -or $table.data -isnot [array]) {
                throw 'Missing library table.'
            }
            foreach ($row in $table.data) {
                if ($null -ne $row -and $null -ne $row.PSObject.Properties['is_archived']) { $archiveCapable = $true; break }
            }
            [int]$count = 0
            [int]$total = 0
            if (-not [int]::TryParse([string](Get-TautWeeklyLibraryObjectValue $table 'recordsFiltered'), [ref]$count) -or
                -not [int]::TryParse([string](Get-TautWeeklyLibraryObjectValue $table 'recordsTotal'), [ref]$total) -or
                $count -ne $table.data.Count -or $total -lt $count -or ($archiveCapable -and $total -ne $count)) {
                throw 'Incomplete library table.'
            }
            $identity = & $Query 'get_server_identity' @{}
            $serverId = ([string](Get-TautWeeklyLibraryObjectValue $identity 'machine_identifier')).Trim()
            $detailsById = Group-TautWeeklyLibraryRows $table.data
        }
        catch {
            if ($archiveCapable) { throw 'Could not verify the complete archive-aware Tautulli library table and current Plex server identity.' }
            # Older servers may lack detailed evidence. Their uniquely named
            # sections remain usable; ambiguous IDs stay unavailable.
        }
    }

    $libraries = [Collections.Generic.List[object]]::new()
    foreach ($sectionId in @(@($liveById.Keys) + @($knownById.Keys) | Sort-Object -Unique)) {
        $live = if ($liveById.ContainsKey($sectionId) -and $liveById[$sectionId].Count -eq 1) { $liveById[$sectionId][0] }
        $names = $knownById[$sectionId]
        $name = if ($null -ne $names -and $names.Count -eq 1) { $names[0] }
        $library = if ($null -ne $live) { $live } else { $name }
        $type = ([string](Get-TautWeeklyLibraryObjectValue $library 'section_type')).ToLowerInvariant()
        $expectedServer = [string](Get-TautWeeklyLibraryObjectValue $live 'server_id')
        $needsDetails = ($archiveCapable -or $expectedServer -ne '' -or ($null -ne $names -and $names.Count -gt 1))
        # Preserve the archive label for an inactive, DB-only singleton. It
        # has no live counterpart and can never become selectable.
        $known = if (-not $liveById.ContainsKey($sectionId) -and $null -ne $name -and
            $detailsById.ContainsKey($sectionId) -and $detailsById[$sectionId].Count -eq 1) {
            $detailsById[$sectionId][0]
        } elseif ($needsDetails) {
            Resolve-TautWeeklyTableLibrary -Details $detailsById[$sectionId] -Names $names -ServerId $serverId -ArchiveCapable $archiveCapable
        } else { $name }
        $archived = [string](Get-TautWeeklyLibraryObjectValue $known 'is_archived' '0') -notin @('0','false')
        $deleted = [string](Get-TautWeeklyLibraryObjectValue $known 'deleted_section' '0') -notin @('0','false')
        $active = ($null -ne $live -and $null -ne $known -and -not $deleted -and
            [string](Get-TautWeeklyLibraryObjectValue $live 'is_active' '1') -in @('1','true') -and
            $type -eq [string](Get-TautWeeklyLibraryObjectValue $known 'section_type') -and
            ($expectedServer -eq '' -or $expectedServer -ceq $serverId))

        $libraries.Add([PSCustomObject]@{
            SectionId = [string]$sectionId
            Name = [string](Get-TautWeeklyLibraryObjectValue $library 'section_name' "Library $sectionId")
            Type = $type
            ItemCount = [string](Get-TautWeeklyLibraryObjectValue $library 'count' '')
            IsActive = $active
            IsArchived = $archived
            DeletedSection = $deleted
            Selectable = ($active -and -not $archived -and $type -in @('movie','show'))
            ServerId = if ($needsDetails) { $serverId } else { '' }
            ArchiveCapable = $archiveCapable
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
            $status = if ($null -ne $library.PSObject.Properties['IsArchived'] -and $library.IsArchived) { 'archived' } elseif (-not $library.IsActive) { 'unavailable' } else { 'unsupported' }
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
