# Deterministic file-lock and atomic-file primitives shared by VeriSolve Skills.

function Enter-VSFileLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$PollIntervalMilliseconds
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not [IO.Directory]::Exists($parent)) { $null = [IO.Directory]::CreateDirectory($parent) }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            return [IO.FileStream]::new(
                $Path,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        } catch [IO.IOException] {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Timed out acquiring file lock '$Path'." }
            Start-Sleep -Milliseconds ([Math]::Max(1, $PollIntervalMilliseconds))
        }
    }
}

function Invoke-VSFileLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$PollIntervalMilliseconds,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $lock = Enter-VSFileLock $Path $TimeoutSeconds $PollIntervalMilliseconds
    try { return (& $Action) } finally { $lock.Dispose() }
}

function Write-VSAtomicFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not [IO.Directory]::Exists($parent)) { $null = [IO.Directory]::CreateDirectory($parent) }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
    try {
        [IO.File]::Move($temporary, $Path, $true)
    } catch {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        throw
    }
}

function Read-VSJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json -AsHashtable
}

function Invoke-VSCommandJson {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Command
    $startInfo.WorkingDirectory = $WorkingDirectory
    foreach ($argument in $Arguments) { $null = $startInfo.ArgumentList.Add([string]$argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start configured command '$Command'." }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($Json)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        throw "Configured command '$Command' exceeded its $TimeoutSeconds second deadline."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        throw "Configured command '$Command' failed with exit code $($process.ExitCode): $stderr"
    }
    return $stdout
}

function Write-VSJsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [switch]$Compress
    )
    $json = if ($Compress) { ConvertTo-Json -InputObject $Value -Depth 100 -Compress } else { ConvertTo-Json -InputObject $Value -Depth 100 }
    Write-VSAtomicFile -Path $Path -Content $json
}
