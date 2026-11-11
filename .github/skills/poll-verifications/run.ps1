param(
    [ValidateSet('start', 'worker', 'status', 'stop')]
    [string]$Mode = 'start',
    [string]$Root = (Get-Location).Path
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath($Root)
$github = Join-Path $workspace '.github'
$pollerPidPath = Join-Path $github 'playbook\poller.pid'
$checkScript = Join-Path $github 'skills\verify-change\check.ps1'
$system = Get-Content -LiteralPath (Join-Path $github 'config\verisolve.system.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$verification = Get-Content -LiteralPath (Join-Path $github 'config\verisolve.verification.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable

switch ($Mode) {
    'start' {
        if (Test-Path -LiteralPath $pollerPidPath) {
            $existingPid = [int](Get-Content -LiteralPath $pollerPidPath -Raw)
            $existingProcess = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
            if ($null -ne $existingProcess) { throw "Verification poller is already running with PID $existingPid." }
            Remove-Item -LiteralPath $pollerPidPath -Force
        }
        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $scriptPath = $PSCommandPath
        $quotedScript = '"' + $scriptPath.Replace('"', '\"') + '"'
        $quotedRoot = '"' + $workspace.Replace('"', '\"') + '"'
        $arguments = "-NoProfile -WindowStyle Hidden -File $quotedScript -Mode worker -Root $quotedRoot"
        $process = Start-Process -FilePath $pwsh -ArgumentList $arguments -WorkingDirectory $workspace -WindowStyle Hidden -PassThru
        [IO.File]::WriteAllText($pollerPidPath, [string]$process.Id, [Text.UTF8Encoding]::new($false))
        [pscustomobject]@{ started = $true; pid = $process.Id; poll_interval_sec = $verification.poll_interval_sec } | ConvertTo-Json -Compress
    }
    'worker' {
        while ($true) {
            try {
                $output = & pwsh -NoProfile -File $checkScript
                if ($LASTEXITCODE -ne 0) { throw "check.ps1 exited with code $LASTEXITCODE" }
                $logPath = Join-Path $github 'playbook\poller.log'
                [IO.File]::AppendAllText($logPath, ([DateTimeOffset]::UtcNow.ToString('o') + ' ' + ($output -join '') + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            } catch {
                $errorPath = Join-Path $github 'playbook\poller.error.log'
                [IO.File]::AppendAllText($errorPath, ([DateTimeOffset]::UtcNow.ToString('o') + ' ' + $_.Exception.Message + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            }
            Start-Sleep -Seconds ([int]$verification.poll_interval_sec)
        }
    }
    'status' {
        if (-not (Test-Path -LiteralPath $pollerPidPath)) {
            [pscustomobject]@{ running = $false } | ConvertTo-Json -Compress
            exit 0
        }
        $pidValue = [int](Get-Content -LiteralPath $pollerPidPath -Raw)
        [pscustomobject]@{ running = ($null -ne (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)); pid = $pidValue } | ConvertTo-Json -Compress
    }
    'stop' {
        if (-not (Test-Path -LiteralPath $pollerPidPath)) { [pscustomobject]@{ stopped = $false; reason = 'no_pid_file' } | ConvertTo-Json -Compress; exit 0 }
        $pidValue = [int](Get-Content -LiteralPath $pollerPidPath -Raw)
        $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if ($null -ne $process) {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $pidValue" -ErrorAction Stop).CommandLine
            if ($commandLine -notlike "*$($PSCommandPath)*" -or $commandLine -notlike '*-Mode worker*') {
                throw "PID $pidValue does not identify this VeriSolve poller; refusing to stop it."
            }
            Stop-Process -Id $pidValue
        }
        Remove-Item -LiteralPath $pollerPidPath -Force
        [pscustomobject]@{ stopped = ($null -ne $process); pid = $pidValue } | ConvertTo-Json -Compress
    }
}
