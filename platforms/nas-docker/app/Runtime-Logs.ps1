function Assert-TautWeeklyRegularLog {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    $link = $item.PSObject.Properties['LinkType']
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($null -ne $link -and -not [string]::IsNullOrEmpty([string]$link.Value))) {
        throw 'Runtime logging refuses links and nonregular files.'
    }
}

function Open-TautWeeklyLogStream {
    param([Parameter(Mandatory)][string]$Path)
    Assert-TautWeeklyRegularLog -Path $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try {
        if (-not $stream.CanSeek) { throw 'Runtime logging refuses nonregular files.' }
        Assert-TautWeeklyRegularLog -Path $Path
    }
    catch { $stream.Dispose(); throw }
    return $stream
}

function Limit-TautWeeklyLogTail {
    param([Parameter(Mandatory)][IO.FileStream]$Stream, [Parameter(Mandatory)][int]$MaximumBytes)
    if ($Stream.Length -le $MaximumBytes) { return }
    $tail = New-Object byte[] $MaximumBytes
    [void]$Stream.Seek(-$MaximumBytes, [IO.SeekOrigin]::End)
    $read = 0
    while ($read -lt $tail.Length) {
        $count = $Stream.Read($tail, $read, $tail.Length - $read)
        if ($count -le 0) { throw 'Runtime log changed while retaining its recent tail.' }
        $read += $count
    }
    $Stream.SetLength(0)
    [void]$Stream.Seek(0, [IO.SeekOrigin]::Begin)
    $Stream.Write($tail, 0, $tail.Length)
}

function Limit-TautWeeklySchedulerLogs {
    param([string]$LogDirectory, [string]$CurrentPath, [int]$MaximumBytes, [int]$MaximumFiles)
    $owned = @(Get-ChildItem -LiteralPath $LogDirectory -Filter 'scheduler_*.log*' -Force | Where-Object {
        $_.Name -cmatch '^scheduler_(\d{8})\.log(?:\.([1-9][0-9]*))?$'
    })
    foreach ($item in $owned) { Assert-TautWeeklyRegularLog -Path $item.FullName }
    $others = @($owned | Where-Object { $_.FullName -ne $CurrentPath } | Sort-Object -Property @{
        Expression = { $_.Name.Substring(10, 8) }; Descending = $true
    }, @{
        Expression = { if ($_.Name -match '\.log\.([0-9]+)$') { $Matches[1].Length } else { 0 } }; Descending = $false
    }, @{
        Expression = { if ($_.Name -match '\.log\.([0-9]+)$') { $Matches[1] } else { '' } }; Descending = $false
    })
    for ($index = 0; $index -lt $others.Count; $index++) {
        $path = $others[$index].FullName
        if ($index -ge $MaximumFiles - 1) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            continue
        }
        if ($others[$index].Length -le $MaximumBytes) { continue }
        $stream = Open-TautWeeklyLogStream -Path $path
        try { Limit-TautWeeklyLogTail -Stream $stream -MaximumBytes $MaximumBytes }
        finally { $stream.Dispose() }
    }
}

function Write-TautWeeklySchedulerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$LocalNow,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [ValidateRange(1, 2147483647)][int]$MaximumBytes = 1048576,
        [ValidateRange(2, 32)][int]$MaximumFiles = 4
    )
    $directory = Get-Item -LiteralPath $LogDirectory -Force -ErrorAction Stop
    if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Runtime log directory must be an existing directory, not a link.'
    }
    $currentPath = Join-Path $directory.FullName ('scheduler_{0}.log' -f $LocalNow.ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture))
    Limit-TautWeeklySchedulerLogs -LogDirectory $directory.FullName -CurrentPath $currentPath -MaximumBytes $MaximumBytes -MaximumFiles $MaximumFiles
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Line + [Environment]::NewLine)
    if ($bytes.Length -gt $MaximumBytes) {
        $tail = New-Object byte[] $MaximumBytes
        [Array]::Copy($bytes, $bytes.Length - $MaximumBytes, $tail, 0, $MaximumBytes)
        $bytes = $tail
    }
    $stream = Open-TautWeeklyLogStream -Path $currentPath
    try {
        Limit-TautWeeklyLogTail -Stream $stream -MaximumBytes $MaximumBytes
        if ($stream.Length + $bytes.Length -gt $MaximumBytes) {
            $stream.Dispose()
            $stream = $null
            for ($index = $MaximumFiles - 1; $index -ge 1; $index--) {
                $destination = $currentPath + '.' + $index
                $source = if ($index -eq 1) { $currentPath } else { $currentPath + '.' + ($index - 1) }
                Assert-TautWeeklyRegularLog -Path $destination
                Assert-TautWeeklyRegularLog -Path $source
                if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force -ErrorAction Stop }
                if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination $destination -ErrorAction Stop }
            }
            Limit-TautWeeklySchedulerLogs -LogDirectory $directory.FullName -CurrentPath $currentPath -MaximumBytes $MaximumBytes -MaximumFiles $MaximumFiles
            $stream = Open-TautWeeklyLogStream -Path $currentPath
        }
        [void]$stream.Seek(0, [IO.SeekOrigin]::End)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    Limit-TautWeeklySchedulerLogs -LogDirectory $directory.FullName -CurrentPath $currentPath -MaximumBytes $MaximumBytes -MaximumFiles $MaximumFiles
}
