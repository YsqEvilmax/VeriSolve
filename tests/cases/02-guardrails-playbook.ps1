# Guardrail, Playbook, and scheduling acceptance cases.
$githubRoot = Join-Path $script:Root '.github'
$config = Get-VSConfigSet -GithubRoot $githubRoot
$guardrails = $config.verification.guardrails

Write-VSSection 'Guardrails precede apply and verification'

function Invoke-Guardrail {
    param([Parameter(Mandatory)][string]$Sandbox, [Parameter(Mandatory)]$Change, $GuardrailOverride = $null)
    $sandboxGithub = Get-VSSandboxGithub -Sandbox $Sandbox
    $effective = if ($null -ne $GuardrailOverride) { $GuardrailOverride } else { $guardrails }
    $requestPath = New-VSRequestFile -Directory $Sandbox -Payload ([ordered]@{ change = $Change; guardrails = $effective })
    try {
        return Invoke-VSScriptJson -Path (Join-Path $sandboxGithub 'skills\guardrail-check\run.ps1') -Arguments @('-RequestPath', $requestPath)
    } finally {
        if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
    }
}

Invoke-VSTest 'guardrail-accepts-clean-change' {
    $sandbox = New-VSSandbox
    try {
        $result = Invoke-Guardrail -Sandbox $sandbox -Change (New-VSChangeFixture)
        Assert-VSEqual $true $result.accepted 'clean change accepted'
        Assert-VSEqual 0 @($result.reasons).Count 'no rejection reasons'
        Assert-VSEqual $null $result.fail_category 'accepted change has no fail_category'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'guardrail-rejects-forbidden-target-and-never-calls-oracle' {
    $sandbox = New-VSSandbox
    try {
        $counterPath = Join-Path $sandbox 'oracle-calls.txt'
        $requestPath = New-VSRequestFile -Directory $sandbox -Payload ([ordered]@{
                change      = New-VSChangeFixture -Targets @('.git/config')
                guardrails  = $guardrails
            })
        $result = Invoke-VSScriptJson -Path (Join-Path (Get-VSSandboxGithub -Sandbox $sandbox) 'skills\guardrail-check\run.ps1') -Arguments @('-RequestPath', $requestPath) -Env @{ VERISOLVE_MOCK_ORACLE_COUNTER = $counterPath }
        Assert-VSEqual $false $result.accepted 'forbidden target rejected'
        Assert-VSEqual 'guardrail_rejected' $result.fail_category 'rejection carries guardrail_rejected'
        Assert-VSTrue ((@($result.reasons) -join ' ') -like '*forbidden_target*') 'reason names forbidden_target'
        Assert-VSTrue (-not (Test-Path -LiteralPath $counterPath)) 'Oracle command was never invoked'

        $result = Invoke-Guardrail -Sandbox $sandbox -Change (New-VSChangeFixture -Targets @('.git'))
        Assert-VSEqual $false $result.accepted 'forbidden target directory itself rejected'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'guardrail-rejects-forbidden-pattern' {
    $sandbox = New-VSSandbox
    try {
        $sandboxGithub = Get-VSSandboxGithub -Sandbox $sandbox
        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'guardrails' -Value ([ordered]@{
                max_patch_files    = $guardrails.max_patch_files
                max_patch_bytes    = $guardrails.max_patch_bytes
                max_patch_lines    = $guardrails.max_patch_lines
                forbidden_targets  = @($guardrails.forbidden_targets)
                forbidden_patterns = @('password\s*=')
            })
        $override = [ordered]@{
            max_patch_files    = $guardrails.max_patch_files
            max_patch_bytes    = $guardrails.max_patch_bytes
            max_patch_lines    = $guardrails.max_patch_lines
            forbidden_targets  = @($guardrails.forbidden_targets)
            forbidden_patterns = @('password\s*=')
        }
        $change = New-VSChangeFixture -Diff "--- a/x`n+++ b/x`n+password = 'hunter2'`n"
        $result = Invoke-Guardrail -Sandbox $sandbox -Change $change -GuardrailOverride $override
        Assert-VSEqual $false $result.accepted 'forbidden pattern rejected'
        Assert-VSTrue ((@($result.reasons) -join ' ') -like '*forbidden_pattern*') 'reason names forbidden_pattern'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'guardrail-enforces-patch-boundaries' {
    $sandbox = New-VSSandbox
    try {
        $base = [ordered]@{
            max_patch_files    = 2
            max_patch_bytes    = 40
            max_patch_lines    = 1
            forbidden_targets  = @($guardrails.forbidden_targets)
            forbidden_patterns = @()
        }
        $result = Invoke-Guardrail -Sandbox $sandbox -Change (New-VSChangeFixture -Targets @('a', 'b', 'c')) -GuardrailOverride $base
        Assert-VSTrue ((@($result.reasons) -join ' ') -like '*patch_files*') 'target count beyond max_patch_files rejected'

        $result = Invoke-Guardrail -Sandbox $sandbox -Change (New-VSChangeFixture -Diff ('d' * 41)) -GuardrailOverride $base
        Assert-VSTrue ((@($result.reasons) -join ' ') -like '*patch_bytes*') 'diff bytes beyond max_patch_bytes rejected'

        $result = Invoke-Guardrail -Sandbox $sandbox -Change (New-VSChangeFixture) -GuardrailOverride $base
        Assert-VSTrue ((@($result.reasons) -join ' ') -like '*patch_lines*') 'diff lines beyond max_patch_lines rejected'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'guardrail-rejects-contract-invalid-change' {
    $sandbox = New-VSSandbox
    try {
        $result = Invoke-Guardrail -Sandbox $sandbox -Change (New-VSChangeFixture -Summary ('s' * 201))
        Assert-VSEqual $false $result.accepted 'contract-invalid change rejected'
        Assert-VSTrue ((@($result.reasons) -join ' ') -like '*contract:*') 'reason marks a contract violation'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Write-VSSection 'Playbook write path, read path, and durability'

function Invoke-PlaybookCommit {
    param(
        [Parameter(Mandatory)][string]$Sandbox,
        [Parameter(Mandatory)][string]$Operation,
        [string]$PayloadPath,
        [hashtable]$Env = @{}
    )
    $scriptPath = Join-Path (Get-VSSandboxGithub -Sandbox $Sandbox) 'skills\playbook-commit\run.ps1'
    $arguments = @('-Operation', $Operation)
    if ($PayloadPath) { $arguments += @('-PayloadPath', $PayloadPath) }
    return Invoke-VSScriptJson -Path $scriptPath -Arguments $arguments -Env $Env
}

function Invoke-PlaybookQuery {
    param([Parameter(Mandatory)][string]$Sandbox, [Parameter(Mandatory)][string]$Operation, [Parameter(Mandatory)]$Payload)
    $requestPath = New-VSRequestFile -Directory $Sandbox -Payload $Payload
    try {
        return Invoke-VSScriptJson -Path (Join-Path (Get-VSSandboxGithub -Sandbox $Sandbox) 'skills\playbook-query\run.ps1') -Arguments @('-Operation', $Operation, '-RequestPath', $requestPath)
    } finally {
        if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
    }
}

function New-VSArchiveEvent {
    param(
        [string]$PatternId = 'pat-1',
        [string]$Category = 'bug',
        [string[]]$Keywords = @('null-reference', 'checkout'),
        [string]$SolutionSummary = 'guard the nullable checkout result'
    )
    return [ordered]@{
        type    = 'ArchiveEvent'
        pattern = [ordered]@{
            pattern_id       = $PatternId
            category         = $Category
            signature        = [ordered]@{ keywords = @($Keywords); features = [ordered]@{ area = 'checkout' } }
            solution_summary = $SolutionSummary
        }
    }
}

Invoke-VSTest 'playbook-rebuild-empty-snapshot' {
    $sandbox = New-VSSandbox
    try {
        $result = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'rebuild'
        Assert-VSEqual 0 $result.version 'empty log rebuilds version 0'
        Assert-VSEqual 0 $result.pattern_count 'no patterns'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'playbook-enqueue-drain-archive-and-query' {
    $sandbox = New-VSSandbox
    try {
        $payload = New-VSRequestFile -Directory $sandbox -Payload @(New-VSArchiveEvent)
        $queued = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'enqueue' -PayloadPath $payload
        Assert-VSEqual 1 $queued.queued 'one event queued'
        $beforeDrain = Invoke-PlaybookQuery -Sandbox $sandbox -Operation 'pin' -Payload ([ordered]@{})
        Assert-VSEqual 0 @($beforeDrain.patterns).Count 'queued events are invisible before the drain'

        $drained = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'drain'
        Assert-VSEqual 1 $drained.appended 'one event appended'
        Assert-VSEqual 1 $drained.pattern_count 'snapshot republished with one pattern'

        $pinned = Invoke-PlaybookQuery -Sandbox $sandbox -Operation 'pin' -Payload ([ordered]@{})
        $query = Invoke-PlaybookQuery -Sandbox $sandbox -Operation 'query' -Payload ([ordered]@{
                snapshot  = $pinned
                category  = 'bug'
                signature = [ordered]@{ keywords = @('null-reference', 'checkout'); features = [ordered]@{ area = 'checkout' } }
            })
        Assert-VSEqual 1 $query.match_count 'exact-signature query matches'
        $match = @($query.matches)[0]
        Assert-VSEqual 'pat-1' $match.pattern_id 'matched pattern id'
        Assert-VSEqual 0.6666666667 ([Math]::Round([double]$match.confidence, 10)) 'laplace confidence after one success'
        Assert-VSEqual $false $match.downgraded 'confidence above threshold is not downgraded'
        Assert-VSEqual 0.9666666667 ([Math]::Round([double]$match.score, 10)) 'score combines configured weights with laplace confidence'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'playbook-query-never-touches-live-snapshot-file' {
    $sandbox = New-VSSandbox
    try {
        $payload = New-VSRequestFile -Directory $sandbox -Payload @(New-VSArchiveEvent)
        $null = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'enqueue' -PayloadPath $payload
        $null = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'drain'
        $pinned = Invoke-PlaybookQuery -Sandbox $sandbox -Operation 'pin' -Payload ([ordered]@{})

        $snapshotPath = Join-Path (Get-VSSandboxGithub -Sandbox $sandbox) 'playbook\snapshot.json'
        Remove-Item -LiteralPath $snapshotPath -Force

        $query = Invoke-PlaybookQuery -Sandbox $sandbox -Operation 'query' -Payload ([ordered]@{
                snapshot  = $pinned
                category  = 'bug'
                signature = [ordered]@{ keywords = @('null-reference', 'checkout'); features = [ordered]@{} }
            })
        Assert-VSEqual 1 $query.match_count 'query still matches with the live snapshot file deleted'
        Assert-VSEqual 1 $query.snapshot_version 'query reports the pinned snapshot version'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'playbook-negative-feedback-lowers-confidence-and-downgrades' {
    $sandbox = New-VSSandbox
    try {
        $events = @(
            (New-VSArchiveEvent)
            [ordered]@{ type = 'ReviewRejectEvent'; problem_id = 'prob-1'; pattern_id = 'pat-1' }
            [ordered]@{ type = 'ReviewRejectEvent'; problem_id = 'prob-1'; pattern_id = 'pat-1' }
            [ordered]@{ type = 'ReviewRejectEvent'; problem_id = 'prob-1'; pattern_id = 'pat-1' }
        )
        $payload = New-VSRequestFile -Directory $sandbox -Payload $events
        $null = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'enqueue' -PayloadPath $payload
        $drained = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'drain'
        Assert-VSEqual 4 $drained.appended 'four events appended'

        $pinned = Invoke-PlaybookQuery -Sandbox $sandbox -Operation 'pin' -Payload ([ordered]@{})
        $pattern = @($pinned.patterns)[0]
        Assert-VSEqual 1 $pattern.stats.successes 'one success recorded'
        Assert-VSEqual 3 $pattern.stats.failures 'three failures recorded'
        Assert-VSEqual 0.3333333333 ([Math]::Round([double]$pattern.stats.confidence, 10)) 'confidence lowered by negative feedback'
        Assert-VSEqual $true $pattern.stats.downgraded 'pattern below low_conf_threshold is downgraded'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'playbook-skip-and-review-reject-do-not-create-patterns' {
    $sandbox = New-VSSandbox
    try {
        $payload = New-VSRequestFile -Directory $sandbox -Payload @(
            [ordered]@{ type = 'SkipEvent'; problem_id = 'prob-9'; pattern_id = 'unknown-pattern' }
            [ordered]@{ type = 'ReviewRejectEvent'; problem_id = 'prob-9'; pattern_id = 'unknown-pattern' }
        )
        $null = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'enqueue' -PayloadPath $payload
        $drained = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'drain'
        Assert-VSEqual 0 $drained.pattern_count 'failed attempts never create Playbook patterns'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'playbook-scoring-weights-ordering-and-filters' {
    $sandbox = New-VSSandbox
    try {
        $payload = New-VSRequestFile -Directory $sandbox -Payload @(
            (New-VSArchiveEvent -PatternId 'pat-exact' -Keywords @('null-reference', 'checkout')),
            (New-VSArchiveEvent -PatternId 'pat-partial' -Keywords @('null-reference')),
            (New-VSArchiveEvent -PatternId 'pat-other-category' -Category 'maintenance')
        )
        $null = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'enqueue' -PayloadPath $payload
        $null = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'drain'
        $pinned = Invoke-PlaybookQuery -Sandbox $sandbox -Operation 'pin' -Payload ([ordered]@{})

        $query = Invoke-PlaybookQuery -Sandbox $sandbox -Operation 'query' -Payload ([ordered]@{
                snapshot  = $pinned
                category  = 'bug'
                signature = [ordered]@{ keywords = @('null-reference', 'checkout'); features = [ordered]@{} }
            })
        $ids = @($query.matches | ForEach-Object { $_.pattern_id })
        Assert-VSEqual 'pat-exact,pat-partial' ($ids -join ',') 'matches ordered by descending score and category filtered'
        $exact = @($query.matches)[0]
        $expected = [Math]::Round((0.6 * 1.0) + (0.3 * 0.0) + (0.1 * (2.0 / 3.0)), 10)
        Assert-VSEqual $expected ([Math]::Round([double]$exact.score, 10)) 'score uses configured weights'

        $filtered = Invoke-PlaybookQuery -Sandbox $sandbox -Operation 'query' -Payload ([ordered]@{
                snapshot  = $pinned
                category  = 'bug'
                signature = [ordered]@{ keywords = @('null-reference', 'checkout'); features = [ordered]@{} }
                min_score = 0.65
            })
        Assert-VSEqual 'pat-exact' ((@($filtered.matches | ForEach-Object { $_.pattern_id })) -join ',') 'min_score filters weak matches'

        $limited = Invoke-PlaybookQuery -Sandbox $sandbox -Operation 'query' -Payload ([ordered]@{
                snapshot  = $pinned
                category  = 'bug'
                signature = [ordered]@{ keywords = @('null-reference', 'checkout'); features = [ordered]@{} }
                top_k     = 1
            })
        Assert-VSEqual 1 $limited.match_count 'top_k limits matches'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'playbook-concurrent-submits-lose-nothing' {
    $sandbox = New-VSSandbox
    try {
        $sandboxGithub = Get-VSSandboxGithub -Sandbox $sandbox
        $commitScript = Join-Path $sandboxGithub 'skills\playbook-commit\run.ps1'
        $pwshExe = $script:Pwsh
        $payloads = [System.Collections.Generic.List[string]]::new()
        for ($i = 1; $i -le 100; $i++) {
            $payloads.Add((New-VSRequestFile -Directory $sandbox -Payload @(New-VSArchiveEvent -PatternId "pat-$i")))
        }
        $null = $payloads | ForEach-Object -Parallel {
            $null = & $using:pwshExe -NoProfile -File $using:commitScript -Operation enqueue -PayloadPath $_ 2>&1
        } -ThrottleLimit 20

        $status = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'status'
        Assert-VSEqual 100 $status.queue_depth 'all 100 concurrent submits are queued exactly once'

        $null = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'drain'
        $null = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'drain'
        $final = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'status'
        Assert-VSEqual 0 $final.queue_depth 'queue drained completely'
        Assert-VSEqual 100 $final.log_events 'append-only log holds exactly 100 events'
        Assert-VSEqual 100 $final.snapshot_version 'snapshot version equals event count'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'playbook-rebuild-recovers-after-truncated-append' {
    $sandbox = New-VSSandbox
    try {
        $sandboxGithub = Get-VSSandboxGithub -Sandbox $sandbox
        $payload = New-VSRequestFile -Directory $sandbox -Payload @((New-VSArchiveEvent), (New-VSArchiveEvent -PatternId 'pat-2'))
        $null = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'enqueue' -PayloadPath $payload
        $null = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'drain'

        $logPath = Join-Path $sandboxGithub 'playbook\events.log'
        $existing = [IO.File]::ReadAllText($logPath, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($logPath, $existing + '{"type":"ArchiveEvent","pattern":', [Text.UTF8Encoding]::new($false))

        $rebuilt = Invoke-PlaybookCommit -Sandbox $sandbox -Operation 'rebuild'
        Assert-VSEqual 2 $rebuilt.version 'only complete events are replayed'
        Assert-VSEqual 2 $rebuilt.pattern_count 'both patterns recovered'
        Assert-VSEqual $true $rebuilt.skipped_partial_tail 'truncated tail detected and discarded'

        $snapshot = Get-Content -LiteralPath (Join-Path $sandboxGithub 'playbook\snapshot.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert-VSEqual 2 @($snapshot.patterns).Count 'snapshot is valid JSON with the recovered patterns'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'playbook-rejects-invalid-events' {
    $sandbox = New-VSSandbox
    try {
        foreach ($bad in @(
                @([ordered]@{ type = 'UnknownEvent'; problem_id = 'p' }),
                @([ordered]@{ type = 'ArchiveEvent'; pattern = [ordered]@{ pattern_id = 'x'; category = 'nope'; signature = [ordered]@{ keywords = @(); features = @{} }; solution_summary = '' } }),
                @([ordered]@{ type = 'ConfidenceUpdateEvent'; pattern_id = 'x'; outcome = 'maybe' })
            )) {
            $payload = New-VSRequestFile -Directory $sandbox -Payload $bad
            $result = Invoke-VSScript -Path (Join-Path (Get-VSSandboxGithub -Sandbox $sandbox) 'skills\playbook-commit\run.ps1') -Arguments @('-Operation', 'enqueue', '-PayloadPath', $payload)
            Assert-VSTrue ($result.exit_code -ne 0) 'invalid playbook event rejected'
        }
    } finally { Remove-VSSandbox -Path $sandbox }
}

Write-VSSection 'Deterministic scheduling'

function New-VSScheduleItem {
    param(
        [string]$ProblemId,
        [string]$Category = 'bug',
        [string]$Severity = 'medium',
        [bool]$Matched = $false,
        [double]$Score = 0.0,
        [string]$CreatedAt = '2026-01-01T00:00:00Z',
        [long]$IngestSeq = 1
    )
    return [ordered]@{
        problem_id       = $ProblemId
        triage_category  = $Category
        severity         = $Severity
        created_at       = $CreatedAt
        ingest_seq       = $IngestSeq
        playbook_matched = $Matched
        match_score      = $Score
        priority_score   = 1.0
    }
}

Invoke-VSTest 'schedule-orders-by-configured-keys' {
    $items = @(
        (New-VSScheduleItem -ProblemId 'p1' -Matched $true -Score 0.8 -Severity 'high' -CreatedAt '2026-01-02T00:00:00Z' -IngestSeq 4),
        (New-VSScheduleItem -ProblemId 'p2' -Matched $true -Score 0.9 -Severity 'low' -CreatedAt '2026-01-03T00:00:00Z' -IngestSeq 2),
        (New-VSScheduleItem -ProblemId 'p3' -Severity 'critical' -CreatedAt '2026-01-01T00:00:00Z' -IngestSeq 3),
        (New-VSScheduleItem -ProblemId 'p4' -Category 'incident' -Severity 'low' -IngestSeq 1)
    )
    $schedule = Invoke-VSRankSchedule -Items $items -Config $config
    Assert-VSEqual 'p4,p2,p1,p3' ($schedule.problem_order -join ',') 'category priority then playbook hit, score, severity'
    Assert-VSEqual 'incident,bug' ((@($schedule.groups | ForEach-Object { $_.category })) -join ',') 'groups ordered by priority matrix'
}

Invoke-VSTest 'schedule-tie-breaks-with-ingest-seq-and-is-reproducible' {
    $items = @(
        (New-VSScheduleItem -ProblemId 'later' -IngestSeq 9),
        (New-VSScheduleItem -ProblemId 'earlier' -IngestSeq 2)
    )
    $first = Invoke-VSRankSchedule -Items $items -Config $config
    $second = Invoke-VSRankSchedule -Items $items -Config $config
    Assert-VSEqual 'earlier,later' ($first.problem_order -join ',') 'identical items tie-break by ascending ingest_seq'
    Assert-VSEqual ($first.problem_order -join ',') ($second.problem_order -join ',') 'ordering is reproducible'
}

Invoke-VSTest 'schedule-rejects-unsupported-order-key-and-missing-ingest-seq' {
    $sandbox = New-VSSandbox
    try {
        $sandboxGithub = Get-VSSandboxGithub -Sandbox $sandbox
        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'categories' -JsonPath 'schedule_order' -Value @('playbook_matched', 'nonsense')
        $bad = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSThrows { Invoke-VSRankSchedule -Items @(New-VSScheduleItem -ProblemId 'p') -Config $bad } 'unsupported ordering key fails fast' 'unsupported key'
    } finally { Remove-VSSandbox -Path $sandbox }
    Assert-VSThrows {
        Invoke-VSRankSchedule -Items @([ordered]@{ problem_id = 'p'; triage_category = 'bug'; severity = 'low'; created_at = '2026-01-01T00:00:00Z'; playbook_matched = $false; match_score = 0; ingest_seq = 0 }) -Config $config
    } 'missing ingest_seq fails fast' 'ingest_seq'
}
