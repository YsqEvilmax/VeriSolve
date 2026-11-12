param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'VeriSolve CLI requires PowerShell 7 or later.' }
if ($Arguments.Count -eq 0) {
    throw 'Usage: verisolve.ps1 validate | run | rank | status | report | kb | init | cleanup'
}

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$effectiveArguments = [System.Collections.Generic.List[string]]::new()
$workspaceArgument = $null
for ($index = 0; $index -lt $Arguments.Count; $index++) {
    if ($Arguments[$index] -ceq '--workspace' -and $index + 1 -lt $Arguments.Count) {
        $workspaceArgument = $Arguments[$index + 1]
        $index++
        continue
    }
    $effectiveArguments.Add($Arguments[$index])
}
if ($effectiveArguments.Count -eq 0) {
    throw 'Usage: verisolve.ps1 <command> [options] [--workspace <path>]'
}
$workspaceRoot = if ([string]::IsNullOrWhiteSpace($workspaceArgument)) {
    $projectRoot
} else {
    [IO.Path]::GetFullPath($workspaceArgument)
}
$github = Join-Path $workspaceRoot '.github'
$pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
. (Join-Path $github 'lib\vs-contracts.ps1')
. (Join-Path $github 'lib\vs-filelock.ps1')
. (Join-Path $github 'lib\vs-playbook.ps1')
. (Join-Path $github 'lib\vs-schedule.ps1')

function Get-VSOption {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tokens, [Parameter(Mandatory)][string]$Name, [string]$Default = $null)
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        if ($Tokens[$i] -ceq "--$Name" -and $i + 1 -lt $Tokens.Count) { return $Tokens[$i + 1] }
    }
    return $Default
}

function Test-VSFlag {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tokens, [Parameter(Mandatory)][string]$Name)
    return ($Tokens -ccontains "--$Name")
}

function New-VSChildRequestFile {
    param([Parameter(Mandatory)]$Payload)
    $path = Join-Path ([IO.Path]::GetTempPath()) ("verisolve-request-" + [guid]::NewGuid().ToString('N') + '.json')
    $json = ConvertTo-Json -InputObject $Payload -Depth 100
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-VSChildScript {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyCollection()][string[]]$ScriptArguments = @())
    $output = & $pwshExe -NoProfile -File $Path @ScriptArguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "'$([IO.Path]::GetFileName($Path))' failed: $($output -join ' ')" }
    return (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine)
}

$command = $effectiveArguments[0]
$options = @($effectiveArguments | Select-Object -Skip 1)
$config = Read-VSConfigSet -GithubRoot $github
Assert-VSConfigSet -Config $config
$runStore = [IO.Path]::GetFullPath((Join-Path $github ([string]$config.cli.run_store_path)))

function Get-VSRunDirectory {
    param([Parameter(Mandatory)][string]$RunId)
    $path = [IO.Path]::GetFullPath((Join-Path $runStore $RunId))
    if (-not $path.StartsWith($runStore, [StringComparison]::OrdinalIgnoreCase)) { throw "Run id '$RunId' escapes the run store." }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Unknown run '$RunId'." }
    return $path
}

switch -CaseSensitive ($command) {
    'validate' {
        $results = [ordered]@{ ok = $true; config = $true; schemas = @(); agents = @() }
        foreach ($schemaName in @('vs-problem', 'vs-verdict', 'vs-change')) {
            $schemaPath = Join-Path $github "contracts\$schemaName.schema.json"
            $null = Get-Content -LiteralPath $schemaPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            $results.schemas += $schemaName
        }
        $agentKinds = @($config.agents.agent_kinds)
        if ($agentKinds.Count -ne 2) { throw "verisolve.agents.json#agent_kinds must declare exactly two reasoning agents (actual $($agentKinds.Count))." }
        foreach ($name in $agentKinds) {
            if (-not $config.agents.agent_files.Contains($name)) { throw "agent_files is missing an entry for '$name'." }
        }
        foreach ($agentFile in @($config.agents.agent_files.Values)) {
            if (-not (Test-Path -LiteralPath (Join-Path $github $agentFile) -PathType Leaf)) { throw "Missing agent definition '$agentFile'." }
            $results.agents += $agentFile
        }
        $results.agent_kinds = $agentKinds
        $results.high_risk_categories = @(Get-VSHighRiskCategories -Config $config)
        [Console]::Out.Write((ConvertTo-Json -InputObject $results -Depth 20 -Compress))
    }
    'run' {
        $source = Get-VSOption -Tokens $options -Name 'backlog'
        if ([string]::IsNullOrWhiteSpace($source)) { throw 'run requires --backlog <source>.' }
        $dryRun = Test-VSFlag -Tokens $options -Name 'dry-run'
        $maxParallel = [int](Get-VSOption -Tokens $options -Name 'max-parallel' -Default ([string]$config.system.max_parallel_triage))
        $fetchScript = Join-Path $github 'skills\fetch-backlog\run.ps1'

        $cursor = $null
        $nextSeq = 1L
        $problems = [System.Collections.Generic.List[object]]::new()
        $envelopes = [System.Collections.Generic.List[object]]::new()
        $pages = 0
        do {
            $requestPath = Join-Path ([IO.Path]::GetTempPath()) ("vs-fetch-" + [guid]::NewGuid().ToString('N') + '.json')
            $payload = ConvertTo-Json -InputObject ([ordered]@{ source = $source; cursor = $cursor; start_ingest_seq = $nextSeq }) -Compress
            [IO.File]::WriteAllText($requestPath, $payload, [Text.UTF8Encoding]::new($false))
            try {
                $page = Invoke-VSChildScript -Path $fetchScript -ScriptArguments @('-RequestPath', $requestPath) | ConvertFrom-Json -AsHashtable
            } finally {
                if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
            }
            foreach ($problem in @($page.problems)) { $problems.Add($problem) }
            foreach ($envelope in @($page.ingest_envelopes)) { $envelopes.Add($envelope) }
            $nextSeq = [long]$page.next_ingest_seq
            $cursor = $page.next_cursor
            $pages++
            if ($pages -gt 1000) { throw 'fetch-backlog exceeded the pagination safety bound.' }
        } while (-not [string]::IsNullOrWhiteSpace([string]$cursor))

        $runId = "run-" + [DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss') + "-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $plan = [ordered]@{
            run_id = $runId
            source = $source
            created_at = [DateTimeOffset]::UtcNow.ToString('o')
            max_parallel = $maxParallel
            pages = $pages
            problem_count = $problems.Count
            problems = @($problems)
            ingest_envelopes = @($envelopes)
        }
        if ($dryRun) {
            $plan.dry_run = $true
            [Console]::Out.Write((ConvertTo-Json -InputObject $plan -Depth 100 -Compress))
            break
        }
        $runDirectory = Join-Path $runStore $runId
        $null = New-Item -ItemType Directory -Path $runDirectory -Force
        Write-VSJsonFile -Path (Join-Path $runDirectory 'plan.json') -Value $plan
        Write-VSJsonFile -Path (Join-Path $runDirectory 'status.json') -Value ([ordered]@{
                run_id = $runId
                state = 'planned'
                triaged = 0
                scheduled = 0
                updated_at = [DateTimeOffset]::UtcNow.ToString('o')
            })
        [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                        run_id = $runId
                        problem_count = $plan.problem_count
                        pages = $pages
                        run_directory = $runDirectory
                    }) -Compress))
    }
    'rank' {
        $runId = Get-VSOption -Tokens $options -Name 'run'
        $triagePath = Get-VSOption -Tokens $options -Name 'triage'
        if ([string]::IsNullOrWhiteSpace($runId)) { throw 'rank requires --run <id>.' }
        if ([string]::IsNullOrWhiteSpace($triagePath)) { throw 'rank requires --triage <file> containing TriageAgent output per problem.' }
        $runDirectory = Get-VSRunDirectory -RunId $runId
        $plan = Get-Content -LiteralPath (Join-Path $runDirectory 'plan.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $triage = Get-Content -LiteralPath ([IO.Path]::GetFullPath($triagePath)) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $byProblem = @{}
        foreach ($entry in @($triage.problems)) { $byProblem[[string]$entry.problem_id] = $entry.output }

        $pinRequest = Join-Path ([IO.Path]::GetTempPath()) ("vs-pinreq-" + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($pinRequest, '{}', [Text.UTF8Encoding]::new($false))
        try {
            $pinned = Invoke-VSChildScript -Path (Join-Path $github 'skills\playbook-query\run.ps1') -ScriptArguments @('-Operation', 'pin', '-RequestPath', $pinRequest) | ConvertFrom-Json -AsHashtable
        } finally {
            if (Test-Path -LiteralPath $pinRequest) { Remove-Item -LiteralPath $pinRequest -Force }
        }

        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($envelope in @($plan.ingest_envelopes)) {
            $problemId = [string]$envelope.problem_id
            if (-not $byProblem.ContainsKey($problemId)) { throw "Missing TriageAgent output for problem '$problemId'." }
            $output = $byProblem[$problemId]
            $validation = Test-VSTriageOutput -Value $output -Config $config
            if (-not $validation.valid) { throw "Invalid TriageAgent output for '$problemId': $($validation.errors -join ' ')" }
            $problem = @($plan.problems | Where-Object { [string]$_.problem_id -ceq $problemId })[0]

            $queryRequest = Join-Path ([IO.Path]::GetTempPath()) ("vs-query-" + [guid]::NewGuid().ToString('N') + '.json')
            $requestBody = ConvertTo-Json -InputObject ([ordered]@{
                    snapshot = $pinned
                    category = [string]$output.category
                    signature = [ordered]@{ keywords = @($problem.signature.keywords); features = $problem.signature.features }
                    top_k = [int]$config.verification.triage.playbook_top_k
                    min_score = [double]$config.verification.triage.playbook_min_score
                }) -Depth 100
            [IO.File]::WriteAllText($queryRequest, $requestBody, [Text.UTF8Encoding]::new($false))
            try {
                $matches = (Invoke-VSChildScript -Path (Join-Path $github 'skills\playbook-query\run.ps1') -ScriptArguments @('-Operation', 'query', '-RequestPath', $queryRequest) | ConvertFrom-Json -AsHashtable).matches
            } finally {
                if (Test-Path -LiteralPath $queryRequest) { Remove-Item -LiteralPath $queryRequest -Force }
            }
            $topMatch = if (@($matches).Count -gt 0) { @($matches)[0] } else { $null }
            $items.Add([ordered]@{
                    problem_id = $problemId
                    triage_category = [string]$output.category
                    severity = [string]$output.severity
                    priority_score = $problem.priority_score
                    created_at = [string]$problem.created_at
                    ingest_seq = [long]$envelope.ingest_seq
                    playbook_matched = ($null -ne $topMatch)
                    match_score = if ($null -ne $topMatch) { [double]$topMatch.score } else { 0.0 }
                    pattern_id = if ($null -ne $topMatch) { [string]$topMatch.pattern_id } else { $null }
                    solution_summary = if ($null -ne $topMatch) { [string]$topMatch.solution_summary } else { $null }
                })
        }
        $schedule = Invoke-VSRankSchedule -Items @($items) -Config $config
        Write-VSJsonFile -Path (Join-Path $runDirectory 'schedule.json') -Value ([ordered]@{
                run_id = $runId
                generated_at = [DateTimeOffset]::UtcNow.ToString('o')
                snapshot_version = [int]$pinned.version
                problem_order = @($schedule.problem_order)
                groups = @($schedule.groups)
                items = @($items)
            })
        $statusPath = Join-Path $runDirectory 'status.json'
        $status = Get-Content -LiteralPath $statusPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $status.state = 'scheduled'
        $status.triaged = $items.Count
        $status.scheduled = $schedule.problem_order.Count
        $status.updated_at = [DateTimeOffset]::UtcNow.ToString('o')
        Write-VSJsonFile -Path $statusPath -Value $status
        [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                        run_id = $runId
                        scheduled = $schedule.problem_order.Count
                        problem_order = @($schedule.problem_order)
                    }) -Compress))
    }
    'status' {
        $runId = Get-VSOption -Tokens $options -Name 'run'
        if ([string]::IsNullOrWhiteSpace($runId)) { throw 'status requires --run <id>.' }
        $statusPath = Join-Path (Get-VSRunDirectory -RunId $runId) 'status.json'
        [Console]::Out.Write([IO.File]::ReadAllText($statusPath, [Text.Encoding]::UTF8))
    }
    'report' {
        $runId = Get-VSOption -Tokens $options -Name 'run'
        $format = [string](Get-VSOption -Tokens $options -Name 'format' -Default 'md')
        if ([string]::IsNullOrWhiteSpace($runId)) { throw 'report requires --run <id>.' }
        if (@('md', 'json') -cnotcontains $format) { throw "report --format must be md or json (actual '$format')." }
        $runDirectory = Get-VSRunDirectory -RunId $runId
        $plan = Get-Content -LiteralPath (Join-Path $runDirectory 'plan.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $status = Get-Content -LiteralPath (Join-Path $runDirectory 'status.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $schedulePath = Join-Path $runDirectory 'schedule.json'
        $schedule = if (Test-Path -LiteralPath $schedulePath) { Get-Content -LiteralPath $schedulePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } else { $null }
        $resultsPath = Join-Path $runDirectory 'results.json'
        $results = if (Test-Path -LiteralPath $resultsPath) { Get-Content -LiteralPath $resultsPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } else { $null }

        $archived = if ($null -ne $results) { @($results.archived) } else { @() }
        $skipped = if ($null -ne $results) { @($results.skipped) } else { @() }
        $escalated = if ($null -ne $results) { @($results.escalated) } else { @() }
        $attempts = if ($null -ne $results) { @($results.attempts) } else { @() }

        $categoryRows = [System.Collections.Generic.List[object]]::new()
        $items = if ($null -ne $schedule) { @($schedule.items) } else { @() }
        foreach ($group in ($items | Group-Object -Property triage_category)) {
            $matched = @($group.Group | Where-Object { $_.playbook_matched -eq $true }).Count
            $succeeded = @($archived | Where-Object { $_.triage_category -ceq $group.Name }).Count
            $skippedCount = @($skipped | Where-Object { $_.triage_category -ceq $group.Name }).Count
            $categoryRows.Add([ordered]@{
                    category = [string]$group.Name
                    total = @($group.Group).Count
                    playbook_matched = $matched
                    succeeded = $succeeded
                    skipped = $skippedCount
                })
        }
        $attemptCount = $attempts.Count
        $hitRate = if ($attemptCount -gt 0) {
            [Math]::Round((@($attempts | Where-Object { $_.source -ceq 'playbook' }).Count / $attemptCount), 4)
        } else { 0.0 }

        if ($format -ceq 'json') {
            [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                            run_id = $plan.run_id
                            source = $plan.source
                            state = $status.state
                            problem_count = $plan.problem_count
                            snapshot_version = if ($null -ne $schedule) { $schedule.snapshot_version } else { $null }
                            overview = @($categoryRows)
                            escalations = @($escalated)
                            skipped = @($skipped)
                            archived = @($archived)
                            playbook_hit_rate = $hitRate
                        }) -Depth 100 -Compress))
        } else {
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("# VeriSolve report - $($plan.run_id)")
            $lines.Add('')
            $lines.Add("- Source: $($plan.source)")
            $lines.Add("- State: $($status.state)")
            $lines.Add("- Problems: $($plan.problem_count)")
            $lines.Add("- Playbook hit rate: $([Math]::Round($hitRate * 100, 2))%")
            $lines.Add('')
            $lines.Add('## Overview')
            $lines.Add('')
            $lines.Add('| Category | Total | Playbook matched | Succeeded | Skipped |')
            $lines.Add('| --- | --- | --- | --- | --- |')
            foreach ($row in $categoryRows) {
                $lines.Add("| $($row.category) | $($row.total) | $($row.playbook_matched) | $($row.succeeded) | $($row.skipped) |")
            }
            $lines.Add('')
            $lines.Add('## Archived (ok)')
            $lines.Add('')
            if (@($archived).Count -eq 0) { $lines.Add('_none_') } else {
                foreach ($entry in $archived) { $lines.Add("- $($entry.problem_id) ($($entry.change_id))") }
            }
            $lines.Add('')
            $lines.Add('## Skipped')
            $lines.Add('')
            if (@($skipped).Count -eq 0) { $lines.Add('_none_') } else {
                foreach ($entry in $skipped) { $lines.Add("- $($entry.problem_id): $($entry.reason)") }
            }
            $lines.Add('')
            $lines.Add('## Escalations')
            $lines.Add('')
            if (@($escalated).Count -eq 0) { $lines.Add('_none_') } else {
                foreach ($entry in $escalated) { $lines.Add("- $($entry.problem_id): $($entry.reason)") }
            }
            [Console]::Out.Write(($lines -join [Environment]::NewLine))
        }
    }
    'kb' {
        $subCommand = if ($options.Count -gt 0) { $options[0] } else { '' }
        $subOptions = if ($options.Count -gt 1) { @($options | Select-Object -Skip 1) } else { @() }
        $commitScript = Join-Path $github 'skills\playbook-commit\run.ps1'
        $queryScript = Join-Path $github 'skills\playbook-query\run.ps1'
        switch -CaseSensitive ($subCommand) {
            'query' {
                $category = Get-VSOption -Tokens $subOptions -Name 'category'
                $signaturePath = Get-VSOption -Tokens $subOptions -Name 'signature'
                if ([string]::IsNullOrWhiteSpace($category)) { throw 'kb query requires --category <cat>.' }
                if ([string]::IsNullOrWhiteSpace($signaturePath)) { throw 'kb query requires --signature <file>.' }
                $signatureFile = [IO.Path]::GetFullPath($signaturePath)
                if (-not (Test-Path -LiteralPath $signatureFile -PathType Leaf)) { throw "Signature file '$signatureFile' does not exist." }
                $raw = [IO.File]::ReadAllText($signatureFile, [Text.Encoding]::UTF8)
                $keywords = $null
                $features = [ordered]@{}
                try {
                    $parsed = $raw | ConvertFrom-Json -AsHashtable
                    $keywords = @($parsed.keywords)
                    if ($parsed.features -is [System.Collections.IDictionary]) { $features = $parsed.features }
                } catch {
                    $keywords = @(Get-VSTextKeywords -Text $raw)
                }
                $pinRequest = New-VSChildRequestFile -Payload ([ordered]@{})
                $queryRequest = New-VSChildRequestFile -Payload ([ordered]@{})
                try {
                    $snapshot = Invoke-VSChildScript -Path $queryScript -ScriptArguments @('-Operation', 'pin', '-RequestPath', $pinRequest) | ConvertFrom-Json -AsHashtable
                    [IO.File]::WriteAllText($queryRequest, (ConvertTo-Json -InputObject ([ordered]@{
                                    snapshot = $snapshot
                                    category = $category
                                    signature = [ordered]@{ keywords = @($keywords); features = $features }
                                    top_k = [int]$config.knowledge_base.top_k
                                    min_score = [double]$config.knowledge_base.min_score
                                }) -Depth 100), [Text.UTF8Encoding]::new($false))
                    [Console]::Out.Write((Invoke-VSChildScript -Path $queryScript -ScriptArguments @('-Operation', 'query', '-RequestPath', $queryRequest)))
                } finally {
                    foreach ($temporary in @($pinRequest, $queryRequest)) { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
                }
            }
            'stats' {
                $status = Invoke-VSChildScript -Path $commitScript -ScriptArguments @('-Operation', 'status') | ConvertFrom-Json -AsHashtable
                $snapshotPath = Join-Path $github ([string]$config.knowledge_base.snapshot_path)
                $snapshot = if (Test-Path -LiteralPath $snapshotPath) { Get-Content -LiteralPath $snapshotPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } else { [ordered]@{ version = 0; patterns = @() } }
                $patterns = @($snapshot.patterns)
                $confidences = @($patterns | ForEach-Object { [double]$_.stats.confidence })
                [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                                snapshot_version = [int]$snapshot.version
                                pattern_count = $patterns.Count
                                downgraded_count = @($patterns | Where-Object { $_.stats.downgraded -eq $true }).Count
                                average_confidence = if ($confidences.Count -gt 0) { [Math]::Round((($confidences | Measure-Object -Average).Average), 4) } else { 0 }
                                queue_depth = [int]$status.queue_depth
                                log_events = [int]$status.log_events
                            }) -Depth 20 -Compress))
            }
            'rebuild' {
                [Console]::Out.Write((Invoke-VSChildScript -Path $commitScript -ScriptArguments @('-Operation', 'rebuild')))
            }
            'drain' {
                [Console]::Out.Write((Invoke-VSChildScript -Path $commitScript -ScriptArguments @('-Operation', 'drain')))
            }
            default { throw "Unknown kb subcommand '$subCommand'. Use query|stats|rebuild|drain." }
        }
    }
    'init' {
        $mode = Get-VSOption -Tokens $options -Name 'mode' -Default 'scaffold'
        switch -CaseSensitive ($mode) {
            'prerequisites' { [Console]::Out.Write((Invoke-VSChildScript -Path (Join-Path $github 'skills\verisolve-init\scripts\check-prerequisites.ps1') -ScriptArguments @('-Workspace', $workspaceRoot))) }
            'inspect' { [Console]::Out.Write((Invoke-VSChildScript -Path (Join-Path $github 'skills\verisolve-init\scripts\detect-state.ps1') -ScriptArguments @('-Workspace', $workspaceRoot))) }
            'scaffold' { [Console]::Out.Write((Invoke-VSChildScript -Path (Join-Path $github 'skills\verisolve-init\scripts\scaffold.ps1') -ScriptArguments @('-Workspace', $workspaceRoot))) }
            default { throw "Unknown init mode '$mode'. Use prerequisites|inspect|scaffold." }
        }
    }
    'cleanup' {
        $mode = Get-VSOption -Tokens $options -Name 'mode' -Default 'plan'
        $cleanupArguments = @('-Mode', $mode, '-Workspace', $workspaceRoot)
        if (Test-VSFlag -Tokens $options -Name 'confirm') { $cleanupArguments += '-ConfirmUninstall' }
        [Console]::Out.Write((Invoke-VSChildScript -Path (Join-Path $github 'skills\verisolve-cleanup\scripts\cleanup.ps1') -ScriptArguments $cleanupArguments))
    }
    default { throw "Unsupported VeriSolve command '$command'." }
}
