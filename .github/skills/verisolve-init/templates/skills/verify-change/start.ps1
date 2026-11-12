param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pending-store.ps1')
. (Join-Path $PSScriptRoot '..\..\lib\vs-contracts.ps1')

$github = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Read-VSConfigSet -GithubRoot $github
Assert-VSConfigSet -Config $config
$verification = $config.verification
$system = $config.system
$cli = $config.cli

$request = Get-Content -LiteralPath ([IO.Path]::GetFullPath($RequestPath)) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$change = $request.change
$validation = Test-VSChange -Value $change -Config $config
if (-not $validation.valid) { throw "verify-change start received an invalid VSChange: $($validation.errors -join ' ')" }
$changeId = [string]$change.change_id

$statePath = [IO.Path]::GetFullPath((Join-Path $github ([string]$verification.pending_verifications_path)))
$stateLockPath = [IO.Path]::GetFullPath((Join-Path $github ([string]$cli.lock_file)))
$startLockPath = [IO.Path]::GetFullPath((Join-Path $github ([string]$cli.start_lock_prefix)$changeId))
$lockTimeout = [int]$system.file_lock_timeout_seconds
$lockPoll = [int]$system.file_lock_poll_interval_ms
$commandTimeout = [int]$cli.command_timeout_seconds

function Find-VSPendingEntry {
    param([Parameter(Mandatory)][string]$ChangeId)
    $found = Invoke-VSPendingStateLock $statePath $stateLockPath $lockTimeout $lockPoll {
        param($state)
        @($state.pending | Where-Object { $_.change_id -ceq $ChangeId } | Select-Object -First 1)
    }
    return @($found)
}

$existing = @(Find-VSPendingEntry -ChangeId $changeId)
if ($existing.Count -gt 0) {
    [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                    verification_id = $existing[0].verification_id
                    problem_id = $existing[0].problem_id
                    started_at = $existing[0].started_at
                    reused = $true
                }) -Compress))
    exit 0
}

# The per-change lock serializes duplicate starts for the same change without holding the shared
# state lock across external commands. The external pipeline is triggered, never awaited.
$startLock = Enter-VSFileLock $startLockPath $lockTimeout $lockPoll
try {
    $existing = @(Find-VSPendingEntry -ChangeId $changeId)
    if ($existing.Count -gt 0) {
        $result = [ordered]@{
            verification_id = $existing[0].verification_id
            problem_id = $existing[0].problem_id
            started_at = $existing[0].started_at
            reused = $true
        }
    } else {
        $applyConfig = $cli.executor.apply
        if ([string]::IsNullOrWhiteSpace([string]$applyConfig.command)) { throw 'executor.apply.command is not configured.' }
        $applyRequest = [ordered]@{ operation = 'apply'; change = $change; idempotency_key = $changeId } | ConvertTo-Json -Depth 100 -Compress
        $applyOutput = Invoke-VSExternalJsonCommand ([string]$applyConfig.command) @($applyConfig.arguments) $applyRequest $commandTimeout $github
        $applyResult = $applyOutput | ConvertFrom-Json -AsHashtable
        if ($applyResult.ok -ne $true) { throw 'Idempotent apply command rejected the change.' }

        $oracle = $cli.oracle.start
        if ([string]::IsNullOrWhiteSpace([string]$oracle.command)) { throw 'oracle.start.command is not configured.' }
        $startRequest = [ordered]@{
            change = $change
            problem_id = $request.problem_id
            problem_projection = $request.problem_projection
            triage_category = $request.triage_category
            acceptance_criteria = $request.acceptance_criteria
            source_pattern_id = $request.source_pattern_id
            business_attempt = $request.business_attempt
            idempotency_key = $changeId
        } | ConvertTo-Json -Depth 100 -Compress
        $startOutput = Invoke-VSExternalJsonCommand ([string]$oracle.command) @($oracle.arguments) $startRequest $commandTimeout $github
        $startResult = $startOutput | ConvertFrom-Json -AsHashtable
        if ([string]::IsNullOrWhiteSpace([string]$startResult.verification_id)) { throw 'Oracle start response must include verification_id.' }
        $startedAt = if ([string]::IsNullOrWhiteSpace([string]$startResult.started_at)) { [DateTimeOffset]::UtcNow.ToString('o') } else { [string]$startResult.started_at }

        $entry = [ordered]@{
            verification_id = [string]$startResult.verification_id
            change_id = $changeId
            problem_id = [string]$request.problem_id
            started_at = $startedAt
            infrastructure_retries = 0
            request = $request
        }
        $null = Invoke-VSPendingStateLock $statePath $stateLockPath $lockTimeout $lockPoll {
            param($state)
            $duplicate = @($state.pending | Where-Object { $_.change_id -ceq $changeId })
            if ($duplicate.Count -eq 0) { $state.pending = @($state.pending) + $entry }
        }
        $result = [ordered]@{
            verification_id = $entry.verification_id
            problem_id = $entry.problem_id
            started_at = $entry.started_at
            reused = $false
        }
    }
} finally {
    $startLock.Dispose()
}
[Console]::Out.Write((ConvertTo-Json -InputObject $result -Compress))

