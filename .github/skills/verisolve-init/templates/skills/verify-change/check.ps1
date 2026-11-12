param(
    [string[]]$AcknowledgeVerificationIds = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pending-store.ps1')
. (Join-Path $PSScriptRoot '..\..\lib\vs-contracts.ps1')

$github = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Read-VSConfigSet -GithubRoot $github
Assert-VSConfigSet -Config $config
$verification = $config.verification
$system = $config.system
$cli = $config.cli
$commandTimeout = [int]$cli.command_timeout_seconds

$statePath = [IO.Path]::GetFullPath((Join-Path $github ([string]$verification.pending_verifications_path)))
$stateLockPath = [IO.Path]::GetFullPath((Join-Path $github ([string]$cli.lock_file)))
$lockTimeout = [int]$system.file_lock_timeout_seconds
$lockPoll = [int]$system.file_lock_poll_interval_ms
$infraCategories = @($cli.oracle.timeout_categories | ForEach-Object { [string]$_ })

$newCompleted = [System.Collections.Generic.List[object]]::new()
$newInfraFailed = [System.Collections.Generic.List[object]]::new()
$updates = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)

if ($AcknowledgeVerificationIds.Count) {
    $ack = @($AcknowledgeVerificationIds | ForEach-Object { [string]$_ })
    $null = Invoke-VSPendingStateLock $statePath $stateLockPath $lockTimeout $lockPoll {
        param($state)
        $state.completed = @($state.completed | Where-Object { $ack -cnotcontains [string]$_.verification_id })
        $state.infra_failed = @($state.infra_failed | Where-Object { $ack -cnotcontains [string]$_.verification_id })
    }
}

function New-VSInfraRetry {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$ErrorMessage)
    $nextRetry = [int]$Entry.infrastructure_retries + 1
    if ($nextRetry -gt [int]$system.infra_retry) { return $null }

    $updated = $Entry.Clone()
    $updated.infrastructure_retries = $nextRetry
    $updated.last_infrastructure_error = $ErrorMessage
    try {
        $oracle = $cli.oracle.start
        $startRequest = [ordered]@{
            change = $Entry.request.change
            problem_id = $Entry.problem_id
            problem_projection = $Entry.request.problem_projection
            triage_category = $Entry.request.triage_category
            acceptance_criteria = $Entry.request.acceptance_criteria
            source_pattern_id = $Entry.request.source_pattern_id
            business_attempt = $Entry.request.business_attempt
            idempotency_key = "$($Entry.change_id):infra:$nextRetry"
        } | ConvertTo-Json -Depth 100 -Compress
        $restartOutput = Invoke-VSCommandJson -Command ([string]$oracle.command) -Arguments @($oracle.arguments) -Json $startRequest -TimeoutSeconds $commandTimeout -WorkingDirectory $github
        $restart = $restartOutput | ConvertFrom-Json -AsHashtable
        if ([string]::IsNullOrWhiteSpace([string]$restart.verification_id)) { throw 'Oracle restart response omitted verification_id.' }
        $updated.verification_id = [string]$restart.verification_id
        $updated.started_at = if ($restart.started_at) { [string]$restart.started_at } else { [DateTimeOffset]::UtcNow.ToString('o') }
    } catch {
        $updated.last_infrastructure_error = "$ErrorMessage; restart failed: $($_.Exception.Message)"
    }
    return $updated
}

$snapshot = Get-VSPendingStateSnapshot $statePath $stateLockPath $lockTimeout $lockPoll
$limit = [int]$verification.check_batch_limit
$selected = @($snapshot.pending | Select-Object -First $limit)

foreach ($entry in $selected) {
    try {
        $oracle = $cli.oracle.check
        $request = ConvertTo-Json -InputObject ([ordered]@{ verification_id = $entry.verification_id }) -Compress
        $output = Invoke-VSCommandJson -Command ([string]$oracle.command) -Arguments @($oracle.arguments) -Json $request -TimeoutSeconds $commandTimeout -WorkingDirectory $github
        $response = $output | ConvertFrom-Json -AsHashtable
        if ($response.state -ceq 'pending') { continue }
        if ($response.state -cne 'completed') { throw "Oracle check returned unsupported state '$($response.state)'." }

        $verdict = $response.verdict
        $verdictValidation = Test-VSVerdict -Value $verdict -Config $config
        if (-not $verdictValidation.valid) { throw "Oracle returned an invalid VSVerdict: $($verdictValidation.errors -join ' ')" }

        if ($verdict.ok -eq $false -and $infraCategories -ccontains [string]$verdict.fail_category) {
            $retried = New-VSInfraRetry -Entry $entry -ErrorMessage ([string]$verdict.fail_category)
            if ($null -ne $retried) {
                $updates[$entry.verification_id] = @{ kind = 'replace'; entry = $retried }
            } else {
                $newInfraFailed.Add([ordered]@{
                        verification_id = $entry.verification_id
                        problem_id = $entry.problem_id
                        fail_category = [string]$verdict.fail_category
                        infrastructure_retries = [int]$entry.infrastructure_retries
                        request = $entry.request
                    })
                $updates[$entry.verification_id] = @{ kind = 'remove' }
            }
            continue
        }

        $newCompleted.Add([ordered]@{
                verification_id = $entry.verification_id
                change_id = $entry.change_id
                problem_id = $entry.problem_id
                triage_category = [string]$entry.request.triage_category
                completed_at = if ($response.completed_at) { [string]$response.completed_at } else { [DateTimeOffset]::UtcNow.ToString('o') }
                verdict = $verdict
                request = $entry.request
            })
        $updates[$entry.verification_id] = @{ kind = 'remove' }
    } catch {
        $retried = New-VSInfraRetry -Entry $entry -ErrorMessage $_.Exception.Message
        if ($null -ne $retried) {
            $updates[$entry.verification_id] = @{ kind = 'replace'; entry = $retried }
        } else {
            $newInfraFailed.Add([ordered]@{
                    verification_id = $entry.verification_id
                    problem_id = $entry.problem_id
                    fail_category = 'oracle_error'
                    error = $_.Exception.Message
                    infrastructure_retries = [int]$entry.infrastructure_retries
                    request = $entry.request
                })
            $updates[$entry.verification_id] = @{ kind = 'remove' }
        }
    }
}

if ($updates.Count) {
    $null = Invoke-VSPendingStateLock $statePath $stateLockPath $lockTimeout $lockPoll {
        param($latest)
        $merged = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($item in $latest.pending) {
            $id = [string]$item.verification_id
            $null = $seen.Add($id)
            if (-not $updates.ContainsKey($id)) { $merged.Add($item); continue }
            $update = $updates[$id]
            if ($update.kind -ceq 'replace') { $merged.Add($update.entry) }
        }
        $latest.pending = @($merged.ToArray())
        $latest.completed = @($latest.completed) + @($newCompleted | Where-Object { $seen.Contains([string]$_.verification_id) })
        $latest.infra_failed = @($latest.infra_failed) + @($newInfraFailed | Where-Object { $seen.Contains([string]$_.verification_id) })
    }
}

$latest = Get-VSPendingStateSnapshot $statePath $stateLockPath $lockTimeout $lockPoll
[Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                checked_count = $selected.Count
                check_batch_limit = $limit
                pending_total = @($latest.pending).Count
                pending = @($latest.pending | Select-Object -First $limit | ForEach-Object {
                        [ordered]@{ verification_id = $_.verification_id; problem_id = $_.problem_id; infrastructure_retries = $_.infrastructure_retries }
                    })
                completed = @($latest.completed | Select-Object -First $limit)
                infra_failed = @($latest.infra_failed | Select-Object -First $limit)
            }) -Depth 100 -Compress))
