# Two-stage verification acceptance cases: non-blocking start, bounded check, infra retry.
$githubRoot = Join-Path $script:Root '.github'
$config = Get-VSConfigSet -GithubRoot $githubRoot

Write-VSSection 'Two-stage verification'

function Enable-VSMockExecutor {
    param([Parameter(Mandatory)][string]$Sandbox)
    $cliPath = Join-Path (Get-VSSandboxGithub -Sandbox $Sandbox) 'config\verisolve.cli.json'
    $cli = Get-Content -LiteralPath $cliPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    foreach ($operation in @('apply', 'revert')) {
        $cli.executor[$operation].command = 'pwsh'
        $cli.executor[$operation].arguments = @('-NoProfile', '-File', 'skills/apply-change/mock-executor.ps1')
    }
    [IO.File]::WriteAllText($cliPath, (ConvertTo-Json -InputObject $cli -Depth 100), [Text.UTF8Encoding]::new($false))
}

function New-VSStartRequest {
    param(
        [Parameter(Mandatory)][string]$ChangeId,
        [string]$ProblemId = 'prob-1',
        [string]$TriageCategory = 'bug'
    )
    return [ordered]@{
        change = New-VSChangeFixture -ChangeId $ChangeId -ProblemId $ProblemId
        problem_id = $ProblemId
        problem_projection = [ordered]@{ problem_id = $ProblemId; category = $TriageCategory; severity = 'high'; keywords = @('checkout') }
        triage_category = $TriageCategory
        acceptance_criteria = 'unit tests pass'
        source_pattern_id = $null
        business_attempt = 0
    }
}

function Invoke-VerifyStart {
    param([Parameter(Mandatory)][string]$Sandbox, [Parameter(Mandatory)]$Request, [hashtable]$Env = @{})
    $requestPath = New-VSRequestFile -Directory $Sandbox -Payload $Request
    try {
        return Invoke-VSScriptJson -Path (Join-Path (Get-VSSandboxGithub -Sandbox $Sandbox) 'skills\verify-change\start.ps1') -Arguments @('-RequestPath', $requestPath) -Env $Env
    } finally {
        if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
    }
}

function Invoke-VerifyCheck {
    param([Parameter(Mandatory)][string]$Sandbox, [hashtable]$Env = @{}, [string[]]$Acknowledge = @())
    $arguments = @()
    if ($Acknowledge.Count) { $arguments += @('-AcknowledgeVerificationIds') + $Acknowledge }
    return Invoke-VSScriptJson -Path (Join-Path (Get-VSSandboxGithub -Sandbox $Sandbox) 'skills\verify-change\check.ps1') -Arguments $arguments -Env $Env
}

function Get-VSPendingDocument {
    param([Parameter(Mandatory)][string]$Sandbox)
    $path = Join-Path (Get-VSSandboxGithub -Sandbox $Sandbox) 'playbook\pending-verifications.json'
    return Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
}

Invoke-VSTest 'verify-start-triggers-pipeline-and-never-polls' {
    $sandbox = New-VSSandbox
    try {
        Enable-VSMockExecutor -Sandbox $sandbox
        $oracleCounter = Join-Path $sandbox 'oracle-start.txt'
        $checkCounter = Join-Path $sandbox 'oracle-check.txt'
        $executorCounter = Join-Path $sandbox 'executor.txt'
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-VerifyStart -Sandbox $sandbox -Request (New-VSStartRequest -ChangeId 'chg-1') -Env @{
            VERISOLVE_MOCK_ORACLE_COUNTER = $oracleCounter
            VERISOLVE_MOCK_ORACLE_MODE    = 'pending'
        }
        $stopwatch.Stop()

        Assert-VSTrue (-not [string]::IsNullOrWhiteSpace([string]$result.verification_id)) 'start returns a verification id'
        Assert-VSEqual $false $result.reused 'first start is not a reuse'
        Assert-VSEqual 1 ([int](([IO.File]::ReadAllText($oracleCounter, [Text.Encoding]::UTF8)).Trim())) 'pipeline triggered exactly once'
        Assert-VSTrue (-not (Test-Path -LiteralPath $checkCounter)) 'start never queries pipeline status'
        Assert-VSTrue ($stopwatch.Elapsed.TotalSeconds -lt 30) 'start returns promptly instead of waiting for a pipeline'

        $state = Get-VSPendingDocument -Sandbox $sandbox
        Assert-VSEqual 1 @($state.pending).Count 'pending state persisted'
        Assert-VSEqual 'chg-1' @($state.pending)[0].change_id 'pending entry keyed by change id'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'verify-start-is-idempotent-per-change' {
    $sandbox = New-VSSandbox
    try {
        Enable-VSMockExecutor -Sandbox $sandbox
        $oracleCounter = Join-Path $sandbox 'oracle-start.txt'
        $executorCounter = Join-Path $sandbox 'executor.txt'
        $envVars = @{
            VERISOLVE_MOCK_ORACLE_COUNTER = $oracleCounter
            VERISOLVE_MOCK_EXECUTOR_COUNTER = $executorCounter
            VERISOLVE_MOCK_ORACLE_MODE    = 'pending'
        }
        $request = New-VSStartRequest -ChangeId 'chg-idem'
        $first = Invoke-VerifyStart -Sandbox $sandbox -Request $request -Env $envVars
        $second = Invoke-VerifyStart -Sandbox $sandbox -Request $request -Env $envVars

        Assert-VSEqual $first.verification_id $second.verification_id 'repeated start reuses the verification id'
        Assert-VSEqual $true $second.reused 'second start reports reuse'
        Assert-VSEqual 1 ([int](([IO.File]::ReadAllText($oracleCounter, [Text.Encoding]::UTF8)).Trim())) 'pipeline triggered once'
        Assert-VSEqual 1 (([IO.File]::ReadAllText($executorCounter, [Text.Encoding]::UTF8).Trim() -split "`n")).Count 'apply executed once'
        Assert-VSEqual 1 @((Get-VSPendingDocument -Sandbox $sandbox).pending).Count 'no duplicate pending entry'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'verify-start-serializes-concurrent-duplicate-starts' {
    $sandbox = New-VSSandbox
    try {
        Enable-VSMockExecutor -Sandbox $sandbox
        $sandboxGithub = Get-VSSandboxGithub -Sandbox $sandbox
        $startScript = Join-Path $sandboxGithub 'skills\verify-change\start.ps1'
        $oracleCounter = Join-Path $sandbox 'oracle-start.txt'
        $requestPath = New-VSRequestFile -Directory $sandbox -Payload (New-VSStartRequest -ChangeId 'chg-race')
        $pwshExe = $script:Pwsh

        $outputs = 1..2 | ForEach-Object -Parallel {
            $env:VERISOLVE_MOCK_ORACLE_COUNTER = $using:oracleCounter
            $env:VERISOLVE_MOCK_ORACLE_MODE = 'pending'
            & $using:pwshExe -NoProfile -File $using:startScript -RequestPath $using:requestPath 2>&1
        } -ThrottleLimit 2
        $ids = @($outputs | ForEach-Object { ($_ | Out-String).Trim() } | Where-Object { $_ -like '{*' } | ForEach-Object { ($_ | ConvertFrom-Json).verification_id } | Select-Object -Unique)
        Assert-VSEqual 1 @($ids).Count 'concurrent duplicate starts converge on one verification id'
        Assert-VSEqual 1 @((Get-VSPendingDocument -Sandbox $sandbox).pending).Count 'only one pending entry exists'
        Assert-VSEqual 1 ([int](([IO.File]::ReadAllText($oracleCounter, [Text.Encoding]::UTF8)).Trim())) 'pipeline triggered once under concurrency'    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'verify-check-is-bounded-by-check-batch-limit' {
    $sandbox = New-VSSandbox
    try {
        Enable-VSMockExecutor -Sandbox $sandbox
        Set-VSConfigValue -GithubRoot (Get-VSSandboxGithub -Sandbox $sandbox) -ConfigName 'verification' -JsonPath 'check_batch_limit' -Value 2
        for ($i = 1; $i -le 5; $i++) {
            $null = Invoke-VerifyStart -Sandbox $sandbox -Request (New-VSStartRequest -ChangeId "chg-$i") -Env @{ VERISOLVE_MOCK_ORACLE_MODE = 'pending' }
        }
        $checkCounter = Join-Path $sandbox 'oracle-check.txt'
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-VerifyCheck -Sandbox $sandbox -Env @{ VERISOLVE_MOCK_ORACLE_MODE = 'pending'; VERISOLVE_MOCK_ORACLE_CHECK_COUNTER = $checkCounter }
        $stopwatch.Stop()

        Assert-VSEqual 2 $result.check_batch_limit 'batch limit comes from config'
        Assert-VSEqual 2 $result.checked_count 'check inspects at most check_batch_limit entries'
        Assert-VSEqual 5 $result.pending_total 'every unresolved entry is still tracked'
        Assert-VSEqual 2 @($result.pending).Count 'pending output itself is bounded'
        Assert-VSEqual 2 ([int](([IO.File]::ReadAllText($checkCounter, [Text.Encoding]::UTF8)).Trim())) 'one status query per inspected entry'
        Assert-VSTrue ($stopwatch.Elapsed.TotalSeconds -lt 60) 'check performs bounded status queries only'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'verify-check-completes-verdict-and-acknowledges' {
    $sandbox = New-VSSandbox
    try {
        Enable-VSMockExecutor -Sandbox $sandbox
        $null = Invoke-VerifyStart -Sandbox $sandbox -Request (New-VSStartRequest -ChangeId 'chg-ok' -TriageCategory 'incident') -Env @{ VERISOLVE_MOCK_ORACLE_MODE = 'pending' }
        $result = Invoke-VerifyCheck -Sandbox $sandbox -Env @{ VERISOLVE_MOCK_ORACLE_MODE = 'pass' }

        Assert-VSEqual 0 @($result.pending).Count 'completed verification leaves the pending list'
        Assert-VSEqual 1 @($result.completed).Count 'completed verdict is reported'
        $entry = @($result.completed)[0]
        Assert-VSEqual $true $entry.verdict.ok 'ok comes from the Oracle verdict'
        Assert-VSEqual 'incident' $entry.triage_category 'triage category is carried for the high-risk decision'
        Assert-VSEqual 0 @($result.infra_failed).Count 'no infrastructure failure recorded'

        $acknowledged = Invoke-VerifyCheck -Sandbox $sandbox -Acknowledge @([string]$entry.verification_id) -Env @{ VERISOLVE_MOCK_ORACLE_MODE = 'pass' }
        Assert-VSEqual 0 @($acknowledged.completed).Count 'acknowledged results are removed'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'verify-check-business-failure-is-not-an-infrastructure-failure' {
    $sandbox = New-VSSandbox
    try {
        Enable-VSMockExecutor -Sandbox $sandbox
        $null = Invoke-VerifyStart -Sandbox $sandbox -Request (New-VSStartRequest -ChangeId 'chg-fail') -Env @{ VERISOLVE_MOCK_ORACLE_MODE = 'pending' }
        $result = Invoke-VerifyCheck -Sandbox $sandbox -Env @{ VERISOLVE_MOCK_ORACLE_MODE = 'fail'; VERISOLVE_MOCK_ORACLE_FAIL_CATEGORY = 'tests_failed' }

        Assert-VSEqual 1 @($result.completed).Count 'business failure is reported as a completed verdict'
        Assert-VSEqual $false @($result.completed)[0].verdict.ok 'ok=false preserved'
        Assert-VSEqual 'tests_failed' @($result.completed)[0].verdict.fail_category 'fail_category preserved'
        Assert-VSEqual 0 @($result.infra_failed).Count 'business failure never becomes an infrastructure failure'
        Assert-VSEqual 0 @($result.pending).Count 'business failure does not stay pending'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'verify-infra-failure-retries-only-infrastructure' {
    $sandbox = New-VSSandbox
    try {
        Enable-VSMockExecutor -Sandbox $sandbox
        Set-VSConfigValue -GithubRoot (Get-VSSandboxGithub -Sandbox $sandbox) -ConfigName 'system' -JsonPath 'infra_retry' -Value 2
        $oracleCounter = Join-Path $sandbox 'oracle-start.txt'
        $executorCounter = Join-Path $sandbox 'executor.txt'
        $startEnv = @{
            VERISOLVE_MOCK_ORACLE_COUNTER   = $oracleCounter
            VERISOLVE_MOCK_EXECUTOR_COUNTER = $executorCounter
            VERISOLVE_MOCK_ORACLE_MODE      = 'pending'
        }
        $null = Invoke-VerifyStart -Sandbox $sandbox -Request (New-VSStartRequest -ChangeId 'chg-infra') -Env $startEnv

        $checkEnv = @{
            VERISOLVE_MOCK_ORACLE_MODE           = 'fail'
            VERISOLVE_MOCK_ORACLE_FAIL_CATEGORY  = 'timeout'
            VERISOLVE_MOCK_ORACLE_COUNTER        = $oracleCounter
        }
        $first = Invoke-VerifyCheck -Sandbox $sandbox -Env $checkEnv
        Assert-VSEqual 1 @($first.pending).Count 'first infrastructure failure keeps the entry pending'
        Assert-VSEqual 1 @($first.pending)[0].infrastructure_retries 'infra retry counter incremented'

        $second = Invoke-VerifyCheck -Sandbox $sandbox -Env $checkEnv
        Assert-VSEqual 2 @($second.pending)[0].infrastructure_retries 'second infrastructure retry counted'

        $third = Invoke-VerifyCheck -Sandbox $sandbox -Env $checkEnv
        Assert-VSEqual 0 @($third.pending).Count 'exhausted infrastructure retries leave the pending list'
        Assert-VSEqual 1 @($third.infra_failed).Count 'exhausted entry reported as infrastructure failure'
        Assert-VSEqual 'timeout' @($third.infra_failed)[0].fail_category 'infrastructure category preserved'
        Assert-VSEqual 2 @($third.infra_failed)[0].infrastructure_retries 'retry count recorded'
        Assert-VSEqual 0 @($third.completed).Count 'infrastructure exhaustion never becomes a business verdict'
        Assert-VSEqual 3 ([int](([IO.File]::ReadAllText($oracleCounter, [Text.Encoding]::UTF8)).Trim())) 'one trigger plus two infrastructure restarts'
        Assert-VSEqual 1 (([IO.File]::ReadAllText($executorCounter, [Text.Encoding]::UTF8).Trim() -split "`n")).Count 'infrastructure retries never re-apply the change'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'verify-invalid-verdict-is-treated-as-infrastructure-failure' {
    $sandbox = New-VSSandbox
    try {
        Enable-VSMockExecutor -Sandbox $sandbox
        Set-VSConfigValue -GithubRoot (Get-VSSandboxGithub -Sandbox $sandbox) -ConfigName 'system' -JsonPath 'infra_retry' -Value 0
        $null = Invoke-VerifyStart -Sandbox $sandbox -Request (New-VSStartRequest -ChangeId 'chg-invalid') -Env @{ VERISOLVE_MOCK_ORACLE_MODE = 'pending' }
        $result = Invoke-VerifyCheck -Sandbox $sandbox -Env @{ VERISOLVE_MOCK_ORACLE_MODE = 'invalid' }
        Assert-VSEqual 0 @($result.completed).Count 'contract-invalid verdict is never accepted'
        Assert-VSEqual 1 @($result.infra_failed).Count 'contract-invalid verdict is an infrastructure failure'
        Assert-VSEqual 'oracle_error' @($result.infra_failed)[0].fail_category 'invalid verdict maps to oracle_error'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'verify-start-rejects-invalid-change-before-any-external-call' {
    $sandbox = New-VSSandbox
    try {
        Enable-VSMockExecutor -Sandbox $sandbox
        $oracleCounter = Join-Path $sandbox 'oracle-start.txt'
        $executorCounter = Join-Path $sandbox 'executor.txt'
        $request = New-VSStartRequest -ChangeId 'chg-bad'
        $request.change.summary = 's' * 201
        $requestPath = New-VSRequestFile -Directory $sandbox -Payload $request
        try {
            $result = Invoke-VSScript -Path (Join-Path (Get-VSSandboxGithub -Sandbox $sandbox) 'skills\verify-change\start.ps1') -Arguments @('-RequestPath', $requestPath) -Env @{
                VERISOLVE_MOCK_ORACLE_COUNTER   = $oracleCounter
                VERISOLVE_MOCK_EXECUTOR_COUNTER = $executorCounter
                VERISOLVE_MOCK_ORACLE_MODE      = 'pending'
            }
        } finally {
            if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
        }
        Assert-VSTrue ($result.exit_code -ne 0) 'contract-invalid change is rejected'
        Assert-VSTrue (-not (Test-Path -LiteralPath $oracleCounter)) 'no pipeline triggered for an invalid change'
        Assert-VSTrue (-not (Test-Path -LiteralPath $executorCounter)) 'no apply executed for an invalid change'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'verify-pending-state-survives-concurrent-check-and-start' {
    $sandbox = New-VSSandbox
    try {
        Enable-VSMockExecutor -Sandbox $sandbox
        $sandboxGithub = Get-VSSandboxGithub -Sandbox $sandbox
        $checkScript = Join-Path $sandboxGithub 'skills\verify-change\check.ps1'
        $startScript = Join-Path $sandboxGithub 'skills\verify-change\start.ps1'
        $pwshExe = $script:Pwsh

        for ($i = 1; $i -le 4; $i++) {
            $null = Invoke-VerifyStart -Sandbox $sandbox -Request (New-VSStartRequest -ChangeId "chg-base-$i") -Env @{ VERISOLVE_MOCK_ORACLE_MODE = 'pending' }
        }
        $requestPath = New-VSRequestFile -Directory $sandbox -Payload (New-VSStartRequest -ChangeId 'chg-parallel')

        $null = 1..3 | ForEach-Object -Parallel {
            $env:VERISOLVE_MOCK_ORACLE_MODE = 'pending'
            if ($_ -eq 1) { & $using:pwshExe -NoProfile -File $using:startScript -RequestPath $using:requestPath 2>&1 | Out-Null }
            else { & $using:pwshExe -NoProfile -File $using:checkScript 2>&1 | Out-Null }
        } -ThrottleLimit 3

        $path = Join-Path $sandboxGithub 'playbook\pending-verifications.json'
        $state = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert-VSEqual 5 @($state.pending).Count 'concurrent start and check never lose a pending entry'
        $ids = @($state.pending | ForEach-Object { [string]$_.verification_id })
        Assert-VSEqual 5 (@($ids | Select-Object -Unique).Count) 'no pending entry was duplicated'
    } finally { Remove-VSSandbox -Path $sandbox }
}
