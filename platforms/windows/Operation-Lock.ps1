Set-StrictMode -Version Latest

function Enter-TautWeeklyOperationLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [string]$Purpose = 'operation'
    )

    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "TautWeekly installation directory was not found: $resolvedRoot"
    }

    $lockPath = Join-Path $resolvedRoot '.tautweekly-operation.lock'
    try {
        $stream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch [IO.IOException] {
        throw 'Another TautWeekly operation is already running. Wait for it to finish before retrying.'
    }

    try {
        $stream.SetLength(0)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false), 1024, $true)
        try {
            $writer.WriteLine("Purpose: $Purpose")
            $writer.WriteLine("Process: $PID")
            $writer.WriteLine("Started: $([DateTime]::UtcNow.ToString('o'))")
            $writer.Flush()
        }
        finally {
            $writer.Dispose()
        }
        $stream.Position = 0
        return $stream
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Exit-TautWeeklyOperationLock {
    [CmdletBinding()]
    param([AllowNull()][IO.Stream]$Lock)

    if ($null -ne $Lock) {
        $Lock.Dispose()
    }
}
