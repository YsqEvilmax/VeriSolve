$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'core\VeriSolve.Core.psm1') -Force -DisableNameChecking

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-True $threw $Message
}

$config = Get-VSVerificationConfig
$adapterPath = Join-Path $root 'adapters\ExampleAdapter.psm1'
Import-Module $adapterPath -Force -DisableNameChecking
$now = [DateTimeOffset]::UtcNow.ToString('o')
$problem = @{
    problem_id = 'p1'
    source = 'test'
    raw = @{}
    category = 'bug'
    severity = 'low'
    priority_score = $null
    signature = @{ keywords = @(); features = @{}; location = $null }
    created_at = $now
    metadata = @{}
}
Assert-True ((New-VSProblem $problem).problem_id -eq 'p1') 'accept base problem'
$exampleAdapter = New-VSExampleAdapter
$fetchResult = & $exampleAdapter.problemSource.fetchBacklog $null
Assert-True ($fetchResult.problems.Count -eq 0 -and $null -eq $fetchResult.next_cursor) 'ExampleAdapter source is a no-op'
$changeForAdapter = New-VSChange @{ change_id = 'example-test'; problem_id = 'p1'; diff = 'x'; summary = 'example'; targets = @('a'); playbook_ref = $null; change_at = $now }
$adapterVerdict = & $exampleAdapter.oracle.judge $changeForAdapter $problem 1
Assert-True (-not $adapterVerdict.ok -and $adapterVerdict.fail_category -eq 'unknown') 'ExampleAdapter Oracle always fails'
$assertedPort = Assert-VSAdapterPort $exampleAdapter.oracle @('judge', 'poll') 'VSOracleAdapter'
$null = & $exampleAdapter.executor.apply $changeForAdapter
$longId = $problem.Clone()
$longId.problem_id = 'x' * 128
Assert-True ((New-VSProblem $longId).problem_id.Length -eq 128) 'accept max problem id'
$longId.problem_id += 'x'
Assert-Throws { New-VSProblem $longId } 'reject problem id over max'
$keywords = $problem.Clone()
$keywords.signature = @{ keywords = @('x' * 64); features = @{}; location = $null }
Assert-True ((New-VSProblem $keywords).signature.keywords.Count -eq 1) 'accept max keyword'
$keywords.signature.keywords = @('x' * 65)
Assert-Throws { New-VSProblem $keywords } 'reject keyword over max'
$keywords.signature.keywords = @(1..20 | ForEach-Object { "k$_" })
Assert-True ((New-VSProblem $keywords).signature.keywords.Count -eq 20) 'accept max keyword count'
$keywords.signature.keywords += 'extra'
Assert-Throws { New-VSProblem $keywords } 'reject keyword count over max'

$change = @{
    change_id = 'c1'; problem_id = 'p1'; diff = 'x'; summary = 'x' * 200
    targets = @('a'); playbook_ref = $null; change_at = $now
}
 $changeId = $change.Clone()
$changeId.change_id = 'c' * 128
Assert-True ((New-VSChange $changeId).change_id.Length -eq 128) 'accept max change id'
$changeId.change_id += 'c'
Assert-Throws { New-VSChange $changeId } 'reject change id over max'
Assert-True ((New-VSChange $change).summary.Length -eq 200) 'accept max summary'
$change.summary += 'x'
Assert-Throws { New-VSChange $change } 'reject summary over max'
$change.summary = ''
Assert-Throws { New-VSChange $change } 'reject empty summary'
$change.summary = '😀' * 200
Assert-True ((New-VSChange $change).summary.Length -eq 400) 'count summary by Unicode code point'
$change.summary += '😀'
Assert-Throws { New-VSChange $change } 'reject summary over max Unicode code points'
$change.summary = 'ok'
$change.diff = 'x' * 100000
Assert-True ((New-VSChange $change).diff.Length -eq 100000) 'accept max diff'
$change.diff += 'x'
Assert-Throws { New-VSChange $change } 'reject diff over max'
$change.diff = 'x'
$change.targets = @(1..50 | ForEach-Object { "file$_" })
Assert-True ((New-VSChange $change).targets.Count -eq 50) 'accept max targets'
$change.targets += 'file51'
Assert-Throws { New-VSChange $change } 'reject target count over max'
$change.targets = @()
Assert-Throws { New-VSChange $change } 'reject empty targets'

$verdict = @{ ok = $false; fail_category = 'unknown'; evidence = @{ top_errors = @('a', 'b', 'c'); signals = @{}; artifacts = @{} }; verdict_at = $now }
Assert-True ((New-VSVerdict $verdict).evidence.top_errors.Count -eq 3) 'accept max top errors'
$verdict.evidence.top_errors = @()
Assert-True ((New-VSVerdict $verdict).evidence.top_errors.Count -eq 0) 'accept zero top errors'
$verdict.evidence.top_errors = @('a', 'b', 'c')
$verdict.evidence.top_errors += 'd'
Assert-Throws { New-VSVerdict $verdict } 'reject top errors over max'
$verdict.evidence.top_errors = @()
$verdict.fail_category = $null
Assert-Throws { New-VSVerdict $verdict } 'reject failure without fail category'
$verdict.ok = $true
Assert-True ((New-VSVerdict $verdict).ok) 'accept successful verdict without fail category'
$verdict.fail_category = 'Unknown'
Assert-Throws { New-VSVerdict $verdict } 'reject incorrectly cased fail category'

$feedback = New-VSResolverFailureFeedback ('s' * 200) 'unknown' @('a', 'b', 'c')
Assert-True ($feedback.previous_summary.Length -eq 200 -and $feedback.top_errors.Count -eq 3) 'accept retry feedback at limits'
Assert-Throws { New-VSResolverFailureFeedback ('s' * 201) 'unknown' @() } 'reject retry summary over limit'
Assert-Throws { New-VSResolverFailureFeedback 'summary' 'unknown' @('a', 'b', 'c', 'd') } 'reject retry top errors over limit'

Assert-True ((Get-VSHighRiskCategories $null) -contains 'incident') 'default high risk category'
Assert-True ((Get-VSHighRiskCategories ' incident,maintenance,, ' ).Count -eq 2) 'parse trimmed high risk categories'
Assert-Throws { Get-VSHighRiskCategories 'not-a-category' } 'reject out-of-domain high risk category'
Assert-True (-not (Test-VSHighRisk -Category $null)) 'null category is not high-risk'

$agentConfig = Get-Content (Join-Path $root 'config\verisolve.agents.json') -Raw | ConvertFrom-Json -AsHashtable
Assert-True ((New-VSTriageResult @{ category = 'bug'; severity = 'low'; keywords = @('x') } $agentConfig).category -eq 'bug') 'accept controlled triage result'
Assert-Throws { New-VSTriageResult @{ category = 'Bug'; severity = 'low'; keywords = @() } $agentConfig } 'reject out-of-domain triage category'
Assert-Throws { New-VSTriageResult @{ category = 'bug'; severity = 'low'; keywords = @('x' * 65) } $agentConfig } 'reject oversized triage keyword'
$priorityMatrix = (Get-Content (Join-Path $root 'config\verisolve.categories.json') -Raw | ConvertFrom-Json -AsHashtable).priority_matrix
$scheduled = @(
    @{ id = 'unmatched'; category = 'bug'; playbook_matched = $false; match_score = 0; priority_score = 99; created_at = [DateTimeOffset]::Parse($now) }
    @{ id = 'lower-match'; category = 'bug'; playbook_matched = $true; match_score = 0.2; priority_score = 0; created_at = [DateTimeOffset]::Parse($now) }
    @{ id = 'higher-match'; category = 'bug'; playbook_matched = $true; match_score = 0.9; priority_score = 0; created_at = [DateTimeOffset]::Parse($now) }
    @{ id = 'incident'; category = 'incident'; playbook_matched = $false; match_score = 0; priority_score = 0; created_at = [DateTimeOffset]::Parse($now) }
)
$sorted = Sort-VSScheduledProblems $scheduled $priorityMatrix
Assert-True (($sorted | ForEach-Object { $_.id }) -join ',' -ceq 'incident,higher-match,lower-match,unmatched') 'rank within category after category priority'
$runspaceWorker = 'param($Item, $Context) Start-Sleep -Milliseconds 250; [pscustomobject]@{ value = $Item * 2 }'
$runspaceClock = [Diagnostics.Stopwatch]::StartNew()
$parallelResult = Invoke-VSRunspaceBatch -Items @(1, 2, 3, 4) -ThrottleLimit 2 -WorkerScript $runspaceWorker -Context @{}
$runspaceClock.Stop()
Assert-True (($parallelResult | ForEach-Object { $_.value.value }) -join ',' -ceq '2,4,6,8') 'runspace batch preserves item order and results'
Assert-True ($runspaceClock.Elapsed.TotalSeconds -lt 1.5) 'independent tasks execute concurrently'

$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
$knowledge = Get-Content (Join-Path $root 'config\verisolve.knowledge_base.json') -Raw | ConvertFrom-Json -AsHashtable
$knowledge.event_log_path = Join-Path $temp 'events.jsonl'
Start-VSPlaybook $knowledge
try {
    $storePort = New-VSPlaybookPort
    $archiveEvents = @(1..100 | ForEach-Object { @{ type = 'archive'; pattern_id = "p$_"; category = 'bug'; signature = @{ keywords = @("k$_"); features = @{} }; solution = "fix $_" } })
    $submitWorker = 'param($Event, $Context) $Context.store.queue.Add((ConvertTo-Json -InputObject $Event -Depth 100 -Compress)); $Event.pattern_id'
    $submitted = Invoke-VSRunspaceBatch -Items $archiveEvents -ThrottleLimit 8 -WorkerScript $submitWorker -Context @{ store = $storePort }
    Assert-True ($submitted.Count -eq 100) 'enqueue 100 immutable events concurrently through the shared Playbook queue'
    $submittedIds = @($submitted | ForEach-Object value | Select-Object -Unique)
    Assert-True ($submittedIds.Count -eq 100) "all concurrent submit calls retain distinct IDs (unique=$($submittedIds.Count))"
    Wait-VSPlaybookWriter
    Assert-True ((& $storePort.readSnapshot).Count -eq 0) 'concurrent writes remain invisible until the batch snapshot refresh'
    $snapshot = Rebuild-VSPlaybook
    $missingArchives = @(1..100 | Where-Object { -not $snapshot.ContainsKey("p$_") })
    $loggedIds = @([IO.File]::ReadAllLines($knowledge.event_log_path) | ForEach-Object { (ConvertFrom-Json -InputObject $_ -AsHashtable).pattern_id })
    $duplicateIds = @($loggedIds | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    Assert-True ($snapshot.Count -eq 100) "persist all 100 concurrent archive events before feedback updates (found=$($snapshot.Count), missing=$($missingArchives -join ','), loglines=$($loggedIds.Count), duplicates=$($duplicateIds -join ','))"
    1..100 | ForEach-Object { Submit-VSPlaybookEvent @{ type = 'confidence_update'; pattern_id = "p$_"; success = $true } }
    Wait-VSPlaybookWriter
    $snapshot = Rebuild-VSPlaybook
    $playbookReadDiagnostics = Get-VSPlaybookIoDiagnostics
    Assert-True ($playbookReadDiagnostics.read_thread_id -ne [System.Threading.Thread]::CurrentThread.ManagedThreadId -and $playbookReadDiagnostics.read_elapsed_ms -ge 0) 'playbook log replay reads on a separate PowerShell execution thread with measured latency'
    Write-Output "Playbook log read: worker thread $($playbookReadDiagnostics.read_thread_id), elapsed $([math]::Round($playbookReadDiagnostics.read_elapsed_ms, 3)) ms."
    Assert-True ($snapshot.Count -eq 100) 'replay all submitted events and feedback updates'
    Assert-True ($snapshot['p1'].confidence -eq (2.0 / 3.0)) 'apply Laplace-smoothed feedback'
    Assert-True (@(Search-VSPlaybook -Category bug -Signature @{ keywords = @('k1'); features = @{} } -TopK 5 -MinScore 0).Count -gt 0) 'search immutable playbook snapshot'
    Assert-True ((& $storePort.readSnapshot).Count -eq 100) 'store port reads the published immutable snapshot'
    Assert-Throws { $snapshot['p1'].stats['successes'] = 99 } 'prevent mutation of nested snapshot values'
    Submit-VSPlaybookEvent @{ type = 'archive'; pattern_id = 'p101'; category = 'bug'; signature = @{ keywords = @('k101'); features = @{} }; solution = 's' * 300 }
    Assert-Throws { Submit-VSPlaybookEvent @{ type = 'archive'; pattern_id = 'over'; category = 'bug'; signature = @{ keywords = @(); features = @{} }; solution = 's' * 301 } } 'reject playbook summary over limit'
    Assert-True ((& $storePort.readSnapshot).Count -eq 100) 'keep current snapshot stable while writes are pending'
    Wait-VSPlaybookWriter
    Assert-True ((Rebuild-VSPlaybook).Count -eq 101) 'publish new snapshot only at refresh boundary'
    Assert-True ((& $storePort.readSnapshot).Count -eq 101) 'atomically publish the refreshed snapshot through the store port'

    $systemConfig = Get-Content (Join-Path $root 'config\verisolve.system.json') -Raw | ConvertFrom-Json -AsHashtable
    $verificationConfig = Get-VSVerificationConfig
    $oracleCounter = [pscustomobject]@{ count = 0 }
    $oracle = [pscustomobject]@{
        judge = {
            param($Change, $Problem, $Timeout)
            $oracleCounter.count++
            New-VSVerdict @{ ok = $false; fail_category = 'tests_failed'; evidence = @{ top_errors = @('one', 'two', 'three'); signals = @{}; artifacts = @{} }; verdict_at = [DateTimeOffset]::UtcNow.ToString('o') }
        }.GetNewClosure()
        poll = { param($ChangeId, $Timeout) $null }
    }
    $guardedResolver = {
        param($Request)
        New-VSChange ([ordered]@{ change_id = "guard-$([guid]::NewGuid().ToString('N'))"; problem_id = $Request.problem.problem_id; diff = "--- a/secrets/token.txt`n+++ b/secrets/token.txt`n@@`n+blocked`n"; summary = 'blocked'; targets = @('secrets/token.txt'); playbook_ref = $null; change_at = [DateTimeOffset]::UtcNow.ToString('o') })
    }
    $guardedFactory = [pscustomobject]@{ create = { [pscustomobject]@{ resolve = $guardedResolver; review = { param($Diff, $Criteria) $true } } }.GetNewClosure() }
    $executorCounter = [pscustomobject]@{ count = 0 }
    $executor = [pscustomobject]@{
        apply = { param($Change) $executorCounter.count++; @{ ok = $true } }.GetNewClosure()
        revert = { param($Change) $null }
    }
    $guardedResult = Invoke-VSProblemResolution -Problem $problem -Category bug -SystemConfig $systemConfig -Verification $verificationConfig -Knowledge $knowledge -TriageKeywords @() -ResolverFactory $guardedFactory -Executor $executor -Oracle $oracle
    Assert-True ($guardedResult.verdict.fail_category -eq 'guardrail_rejected' -and $oracleCounter.count -eq 0 -and $executorCounter.count -eq 0) 'guardrail rejection bypasses executor and Oracle'

    $requests = [System.Collections.Generic.List[object]]::new()
    $problem.raw = @{ summary = 's' * 200; log = 'private full log content'; acceptance_criteria = 'acceptance text' }
    $normalResolver = {
        param($Request)
        $requests.Add($Request)
        New-VSChange ([ordered]@{ change_id = "retry-$([guid]::NewGuid().ToString('N'))"; problem_id = $Request.problem.problem_id; diff = "--- a/src/test.txt`n+++ b/src/test.txt`n@@`n+change`n"; summary = 'bounded summary'; targets = @('src/test.txt'); playbook_ref = $null; change_at = [DateTimeOffset]::UtcNow.ToString('o') })
    }.GetNewClosure()
    $normalFactory = [pscustomobject]@{ create = { [pscustomobject]@{ resolve = $normalResolver; review = { param($Diff, $Criteria) $true } } }.GetNewClosure() }
    $retryResult = Invoke-VSProblemResolution -Problem $problem -Category bug -SystemConfig $systemConfig -Verification $verificationConfig -Knowledge $knowledge -TriageKeywords @('fix') -ResolverFactory $normalFactory -Executor $executor -Oracle $oracle
    Assert-True ($retryResult.attempts -eq 2 -and $requests.Count -eq 2) 'retry creates a fresh resolver context'
    Assert-True ($requests[1].previous_summary -eq 'bounded summary' -and $requests[1].feedback.fail_category -eq 'tests_failed' -and $requests[1].feedback.top_errors.Count -eq 3) 'retry feedback is structured and bounded'
    Assert-True ($retryResult.status -eq 'escalated' -and $retryResult.events.Count -eq 1 -and $retryResult.events[0].type -eq 'skip') 'two failed attempts enter escalation without archive events'
    Assert-True ((@($requests[0].problem.Keys | Sort-Object) -join ',') -ceq 'category,keywords,problem_id,severity,summary' -and $requests[0].problem.summary.Length -eq 200) 'resolver receives only the bounded problem projection'
    Assert-True ((ConvertTo-Json -InputObject $requests[0] -Depth 20 -Compress) -notmatch 'private full log content|acceptance text|metadata|raw') 'resolver context excludes logs, review criteria, metadata, and raw payload'
    $oversizedProblem = $problem.Clone()
    $oversizedProblem.raw = @{ summary = 's' * 201 }
    Assert-Throws { Invoke-VSProblemResolution -Problem $oversizedProblem -Category bug -SystemConfig $systemConfig -Verification $verificationConfig -Knowledge $knowledge -TriageKeywords @('fix') -ResolverFactory $normalFactory -Executor $executor -Oracle $oracle } 'reject resolver task summary over the configured bound'
    $snapshotCountBeforeFailedAttempt = (Get-VSPlaybookSnapshot).Count
    Submit-VSPlaybookEvent $retryResult.events[0]
    Wait-VSPlaybookWriter
    $snapshotAfterFailedAttempt = Rebuild-VSPlaybook
    Assert-True ($snapshotAfterFailedAttempt.Count -eq $snapshotCountBeforeFailedAttempt -and @($snapshotAfterFailedAttempt.Keys | Where-Object { $_ -like 'retry-*' }).Count -eq 0) 'failed retries do not create playbook entries'

    $parallelProblems = @(1..3 | ForEach-Object {
        $parallelProblem = $problem.Clone()
        $parallelProblem.problem_id = "parallel-$_"
        $parallelProblem.raw = @{ summary = "parallel issue $_" }
        $parallelProblem
    })
    $parallelWorker = @'
param($Problem, $Context)
$null = Get-VSVerificationConfig -Path $Context.verification_path
$resolverFactory = [pscustomobject]@{
    create = {
        [pscustomobject]@{
            resolve = {
                param($Request)
                $id = $Request.problem.problem_id
                $target = "src/$id.txt"
                [ordered]@{ change_id = "parallel-$id"; problem_id = $id; diff = "--- a/$target`n+++ b/$target`n@@`n+change`n"; summary = 'parallel validation'; targets = @($target); playbook_ref = $null; change_at = [DateTimeOffset]::UtcNow.ToString('o') }
            }
            review = { param($Diff, $Criteria) $true }
        }
    }
}
$executor = [pscustomobject]@{ apply = { param($Change) @{ ok = $true } }; revert = { param($Change) $null } }
$oracle = [pscustomobject]@{
    judge = {
        param($Change, $Problem, $Timeout)
        [System.Threading.Thread]::Sleep(2000)
        @{ ok = $true; fail_category = $null; evidence = @{ top_errors = @(); signals = @{}; artifacts = @{} }; verdict_at = [DateTimeOffset]::UtcNow.ToString('o') }
    }
    poll = { param($ChangeId, $Timeout) $null }
}
$result = Invoke-VSProblemResolution -Problem $Problem -Category bug -SystemConfig $Context.system -Verification $Context.verification -Knowledge $Context.knowledge -TriageKeywords @('parallel') -ResolverFactory $resolverFactory -Executor $executor -Oracle $oracle -PlaybookSnapshot $Context.snapshot -PlaybookConfig $Context.knowledge -TargetLocks $Context.target_locks
Write-Output $result
'@
    $parallelContext = @{
        module_path = Join-Path $root 'core\VeriSolve.Core.psm1'
        verification_path = Join-Path $root 'config\verisolve.verification.json'
        system = $systemConfig
        verification = $verificationConfig
        knowledge = $knowledge
        snapshot = Get-VSPlaybookSnapshot
        target_locks = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.SemaphoreSlim]]::new([StringComparer]::Ordinal)
    }
    $parallelClock = [Diagnostics.Stopwatch]::StartNew()
    $parallelResolutions = Invoke-VSRunspaceBatch -Items $parallelProblems -ThrottleLimit 3 -WorkerScript $parallelWorker -Context $parallelContext -ModulePath $parallelContext.module_path
    $parallelClock.Stop()
    $parallelSuccessCount = @($parallelResolutions | Where-Object { $_.value.status -eq 'success' }).Count
    Assert-True ($parallelSuccessCount -eq 3 -and $parallelClock.Elapsed.TotalSeconds -lt 5.5) "three two-second Oracle verifications complete concurrently (successes=$parallelSuccessCount, elapsed=$($parallelClock.Elapsed.TotalSeconds))"
    Write-Output "Oracle concurrency: 3 items, each mock waits 2000 ms; batch elapsed $([math]::Round($parallelClock.Elapsed.TotalSeconds, 3)) s."

    $reviewProblem = $problem.Clone()
    $reviewProblem.category = 'incident'
    $reviewProblem.raw = @{ acceptance_criteria = 'acceptance standard' }
    $reviewInputs = [System.Collections.Generic.List[object]]::new()
    $contextCount = [pscustomobject]@{ value = 0 }
    $reviewResolver = {
        param($Request)
        New-VSChange ([ordered]@{ change_id = "review-$([guid]::NewGuid().ToString('N'))"; problem_id = $Request.problem.problem_id; diff = "--- a/src/incident.txt`n+++ b/src/incident.txt`n@@`n+change`n"; summary = 'incident resolution'; targets = @('src/incident.txt'); playbook_ref = $null; change_at = [DateTimeOffset]::UtcNow.ToString('o') })
    }
    $reviewAgentFactory = [pscustomobject]@{
        create = {
            $contextCount.value++
            [pscustomobject]@{
                resolve = $reviewResolver
                review = { param($Diff, $AcceptanceCriteria) $reviewInputs.Add(@{ diff = $Diff; acceptance_criteria = $AcceptanceCriteria }); $true }.GetNewClosure()
            }
        }.GetNewClosure()
    }
    $successOracle = [pscustomobject]@{
        judge = { param($Change, $Problem, $Timeout)         @{ ok = $true; fail_category = $null; evidence = @{ top_errors = @(); signals = @{}; artifacts = @{} }; verdict_at = [DateTimeOffset]::UtcNow.ToString('o') } }
        poll = { param($ChangeId, $Timeout) $null }
    }
    $successResult = Invoke-VSProblemResolution -Problem $reviewProblem -Category incident -SystemConfig $systemConfig -Verification $verificationConfig -Knowledge $knowledge -TriageKeywords @('incident') -ResolverFactory $reviewAgentFactory -Executor $executor -Oracle $successOracle
    Assert-True ($successResult.status -eq 'success' -and $contextCount.value -eq 2) 'high-risk success invokes an independent resolver review context'
    Assert-True ($reviewInputs.Count -eq 1 -and (@($reviewInputs[0].Keys | Sort-Object) -join ',') -ceq 'acceptance_criteria,diff') 'review receives only diff and acceptance criteria'
    Assert-True ($reviewInputs[0].acceptance_criteria -eq 'acceptance standard') 'review receives acceptance criteria'
    $archivedPatternId = $successResult.events[0].pattern_id
    foreach ($event in $successResult.events) { Submit-VSPlaybookEvent $event }
    Wait-VSPlaybookWriter
    $publishedSnapshot = Rebuild-VSPlaybook
    Assert-True (@($publishedSnapshot.Keys) -ccontains $archivedPatternId) 'reviewed success is archived after acceptance'
} finally {
    Stop-VSPlaybook
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

Write-Output 'All VeriSolve PowerShell checks passed.'
