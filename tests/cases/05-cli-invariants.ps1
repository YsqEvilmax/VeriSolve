# CLI behaviour and static structure invariant acceptance cases.
$githubRoot = $script:BaseGithub
$config = Get-VSConfigSet -GithubRoot $githubRoot

Write-VSSection 'CLI surface'

function New-VSCliWorkspace {
    # A scaffolded workspace is what the developer CLI is meant to operate on.
    return New-VSSandbox
}

function Invoke-VSCli {
    param([Parameter(Mandatory)][string]$Workspace, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Arguments, [hashtable]$Env = @{})
    return Invoke-VSScript -Path $script:CliScript -Arguments (@('--workspace', $Workspace) + $Arguments) -Env $Env
}

function Invoke-VSCliJson {
    param([Parameter(Mandatory)][string]$Workspace, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Arguments, [hashtable]$Env = @{})
    $result = Invoke-VSCli -Workspace $Workspace -Arguments $Arguments -Env $Env
    if ($result.exit_code -ne 0) { throw "CLI failed: $($result.text)" }
    return $result.text | ConvertFrom-Json -AsHashtable
}

function Assert-VSReportUnknownRunRejected {
    param([Parameter(Mandatory)][string]$Workspace)
    $result = Invoke-VSCli -Workspace $Workspace -Arguments @('report', '--run', 'run-does-not-exist', '--format', 'md')
    Assert-VSTrue ($result.exit_code -ne 0) 'report on an unknown run fails'
}

Invoke-VSTest 'cli-validate-reports-contracts-and-agents' {
    $workspace = New-VSCliWorkspace
    try {
        $result = Invoke-VSCliJson -Workspace $workspace -Arguments @('validate')
        Assert-VSEqual 3 @($result.schemas).Count 'all three contracts validated'
        Assert-VSEqual 3 @($result.agents).Count 'all three agent definitions present'
        Assert-VSEqual 'incident' (@($result.high_risk_categories) -join ',') 'high-risk categories resolved from config'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'cli-run-example-dry-run-writes-nothing' {
    $workspace = New-VSCliWorkspace
    try {
        $result = Invoke-VSCliJson -Workspace $workspace -Arguments @('run', '--backlog', 'example', '--dry-run')
        Assert-VSEqual 0 $result.problem_count 'example source yields no problems'
        Assert-VSEqual $true $result.dry_run 'dry run flagged'
        $runsPath = Join-Path $workspace '.github\playbook\runs'
        Assert-VSTrue (-not (Test-Path -LiteralPath $runsPath)) 'dry run creates no run directory'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'cli-run-status-and-report-end-to-end' {
    $workspace = New-VSCliWorkspace
    try {
        $run = Invoke-VSCliJson -Workspace $workspace -Arguments @('run', '--backlog', 'example')
        Assert-VSEqual 0 $run.problem_count 'example backlog is empty'
        Assert-VSTrue (-not [string]::IsNullOrWhiteSpace([string]$run.run_id)) 'run id returned'

        $status = Invoke-VSCliJson -Workspace $workspace -Arguments @('status', '--run', [string]$run.run_id)
        Assert-VSEqual 'planned' $status.state 'status reports the planned state'

        $report = Invoke-VSCli -Workspace $workspace -Arguments @('report', '--run', [string]$run.run_id, '--format', 'md')
        Assert-VSEqual 0 $report.exit_code "report succeeded: $($report.text)"
        foreach ($section in @('## Overview', '## Archived \(ok\)', '## Skipped', '## Escalations', 'Playbook hit rate')) {
            Assert-VSTrue ($report.text -match $section) "markdown report contains $section"
        }

        $json = Invoke-VSCliJson -Workspace $workspace -Arguments @('report', '--run', [string]$run.run_id, '--format', 'json')
        foreach ($key in @('overview', 'archived', 'skipped', 'escalations', 'playbook_hit_rate')) {
            Assert-VSTrue ($json.Contains($key)) "json report contains $key"
        }
        Assert-VSReportUnknownRunRejected -Workspace $workspace
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'cli-rank-uses-triage-output-and-scheduling-keys' {
    $workspace = New-VSCliWorkspace
    try {
        $cliPath = Join-Path $workspace '.github\config\verisolve.cli.json'
        $cliConfig = Get-Content -LiteralPath $cliPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $cliConfig.problem_sources['mock'] = [ordered]@{
            command     = 'pwsh'
            arguments   = @('-NoProfile', '-File', (Join-Path $script:Root 'tests\fixtures\mock-problem-source.ps1'))
            description = 'acceptance fixture'
        }
        [IO.File]::WriteAllText($cliPath, (ConvertTo-Json -InputObject $cliConfig -Depth 100), [Text.UTF8Encoding]::new($false))

        $run = Invoke-VSCliJson -Workspace $workspace -Arguments @('run', '--backlog', 'mock')
        Assert-VSEqual 2 $run.problem_count 'mock source returned both problems'

        $plan = Get-Content -LiteralPath (Join-Path $workspace ".github\playbook\runs\$($run.run_id)\plan.json") -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert-VSEqual '1,2' ((@($plan.ingest_envelopes | ForEach-Object { $_.ingest_seq })) -join ',') 'ingest_seq assigned monotonically at fetch'

        $triage = [ordered]@{
            problems = @(
                [ordered]@{ problem_id = 'mock-1'; output = [ordered]@{ category = 'bug'; severity = 'high'; keywords = @('null-reference') } },
                [ordered]@{ problem_id = 'mock-2'; output = [ordered]@{ category = 'incident'; severity = 'critical'; keywords = @('pipeline') } }
            )
        }
        $triagePath = New-VSRequestFile -Directory $workspace -Payload $triage
        $rank = Invoke-VSCliJson -Workspace $workspace -Arguments @('rank', '--run', [string]$run.run_id, '--triage', $triagePath)
        Assert-VSEqual 'mock-2,mock-1' (@($rank.problem_order) -join ',') 'incident group precedes bug group'

        $status = Invoke-VSCliJson -Workspace $workspace -Arguments @('status', '--run', [string]$run.run_id)
        Assert-VSEqual 'scheduled' $status.state 'status advances to scheduled'
        Assert-VSEqual 2 $status.scheduled 'both problems scheduled'

        $results = [ordered]@{
            archived  = @([ordered]@{ problem_id = 'mock-2'; change_id = 'chg-2'; triage_category = 'incident' })
            skipped   = @([ordered]@{ problem_id = 'mock-1'; triage_category = 'bug'; reason = 'retry_exhausted' })
            escalated = @([ordered]@{ problem_id = 'mock-1'; reason = 'retry_exhausted' })
            attempts  = @([ordered]@{ problem_id = 'mock-2'; source = 'playbook' }, [ordered]@{ problem_id = 'mock-1'; source = 'resolver' })
        }
        [IO.File]::WriteAllText(
            (Join-Path $workspace ".github\playbook\runs\$($run.run_id)\results.json"),
            (ConvertTo-Json -InputObject $results -Depth 20),
            [Text.UTF8Encoding]::new($false))
        $report = Invoke-VSCliJson -Workspace $workspace -Arguments @('report', '--run', [string]$run.run_id, '--format', 'json')
        Assert-VSEqual 1 @($report.archived).Count 'archived list rendered'
        Assert-VSEqual 1 @($report.skipped).Count 'skipped list rendered'
        Assert-VSEqual 1 @($report.escalations).Count 'escalation list rendered'
        Assert-VSEqual 0.5 $report.playbook_hit_rate 'hit rate computed from attempts'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'cli-kb-rebuild-stats-and-query' {
    $workspace = New-VSCliWorkspace
    try {
        $rebuilt = Invoke-VSCliJson -Workspace $workspace -Arguments @('kb', 'rebuild')
        Assert-VSEqual 0 $rebuilt.version 'empty log rebuilds version 0'

        $stats = Invoke-VSCliJson -Workspace $workspace -Arguments @('kb', 'stats')
        Assert-VSEqual 0 $stats.pattern_count 'no patterns yet'
        Assert-VSEqual 0 $stats.queue_depth 'empty queue'

        $payload = New-VSRequestFile -Directory $workspace -Payload @([ordered]@{
                type    = 'ArchiveEvent'
                pattern = [ordered]@{
                    pattern_id       = 'pat-cli'
                    category         = 'bug'
                    signature        = [ordered]@{ keywords = @('null-reference', 'checkout'); features = [ordered]@{ area = 'checkout' } }
                    solution_summary = 'guard the nullable checkout result'
                }
            })
        $commitScript = Join-Path $workspace '.github\skills\playbook-commit\run.ps1'
        $null = Invoke-VSScriptJson -Path $commitScript -Arguments @('-Operation', 'enqueue', '-PayloadPath', $payload)
        $null = Invoke-VSCliJson -Workspace $workspace -Arguments @('kb', 'drain')

        $stats = Invoke-VSCliJson -Workspace $workspace -Arguments @('kb', 'stats')
        Assert-VSEqual 1 $stats.pattern_count 'pattern published'

        $signaturePath = Join-Path $workspace 'signature.txt'
        [IO.File]::WriteAllText($signaturePath, 'null-reference checkout', [Text.UTF8Encoding]::new($false))
        $query = Invoke-VSCliJson -Workspace $workspace -Arguments @('kb', 'query', '--category', 'bug', '--signature', $signaturePath)
        Assert-VSEqual 1 $query.match_count 'plain-text signature still matches'
        Assert-VSEqual 'pat-cli' @($query.matches)[0].pattern_id 'matched pattern id'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'cli-rejects-unsupported-commands' {
    $workspace = New-VSCliWorkspace
    try {
        $result = Invoke-VSCli -Workspace $workspace -Arguments @('teleport')
        Assert-VSTrue ($result.exit_code -ne 0) 'unsupported command fails'
        Assert-VSTrue ($result.text -like '*Unsupported VeriSolve command*') 'failure names the command'
        $missing = Invoke-VSCli -Workspace $workspace -Arguments @('run')
        Assert-VSTrue ($missing.exit_code -ne 0) 'run without --backlog fails'
    } finally { Remove-VSSandbox -Path $workspace }
}

Write-VSSection 'Structural invariants'

Invoke-VSTest 'exactly-two-reasoning-agent-kinds' {
    $agentFiles = @(Get-ChildItem -LiteralPath (Join-Path $githubRoot 'agents') -Filter '*.agent.md')
    Assert-VSEqual 3 $agentFiles.Count 'one coordinator plus two reasoning agents'
    $kinds = @($config.agents.agent_kinds)
    Assert-VSEqual 2 $kinds.Count 'config declares exactly two agent kinds'
    Assert-VSEqual 'TriageAgent,ResolverAgent' ($kinds -join ',') 'agent kinds are triage and resolver'
    Assert-VSEqual 2 @($config.agents.agent_files.Keys | Where-Object { $_ -cne 'coordinator' }).Count 'only two delegated agent files'
    foreach ($name in $kinds) {
        Assert-VSTrue (Test-Path -LiteralPath (Join-Path $githubRoot ([string]$config.agents.agent_files[$name]))) "$name definition exists"
    }
}

Invoke-VSTest 'review-is-a-resolver-mode-not-a-new-agent' {
    $resolver = Get-Content -LiteralPath (Join-Path $githubRoot 'agents\resolver.agent.md') -Raw -Encoding utf8
    Assert-VSTrue ($resolver -match '## Resolve mode') 'resolver documents resolve mode'
    Assert-VSTrue ($resolver -match '## Review mode') 'resolver documents review mode'
    Assert-VSTrue ($resolver -match 'never return `ok`') 'resolver is forbidden from authoring ok'
    $modes = @($config.agents.resolver.modes)
    Assert-VSEqual 'resolve,review' ($modes -join ',') 'resolver modes configured'
}

Invoke-VSTest 'no-psm1-modules-and-all-json-parses' {
    $modules = @(Get-ChildItem -LiteralPath $script:Root -Recurse -Filter '*.psm1' -ErrorAction SilentlyContinue)
    Assert-VSEqual 0 $modules.Count 'no PowerShell modules carry orchestration'
    $jsonFiles = @(Get-ChildItem -LiteralPath $githubRoot -Recurse -Filter '*.json')
    Assert-VSTrue ($jsonFiles.Count -ge 9) 'config, contracts, and playbook json discovered'
    foreach ($file in $jsonFiles) {
        try { $null = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable }
        catch { throw "Invalid JSON in $($file.Name): $($_.Exception.Message)" }
    }
}

Invoke-VSTest 'every-skill-documents-its-contract' {
    $required = @('## When to use', '## Input / output', '## Prohibited', '## Called by', '## Config dependencies')
    $skillDirs = @(Get-ChildItem -LiteralPath (Join-Path $githubRoot 'skills') -Directory)
        Assert-VSTrue ($skillDirs.Count -ge 10) 'all expected skills are present'
    foreach ($directory in $skillDirs) {
        $skillPath = Join-Path $directory.FullName 'SKILL.md'
        Assert-VSTrue (Test-Path -LiteralPath $skillPath) "$($directory.Name) has a SKILL.md"
        $content = Get-Content -LiteralPath $skillPath -Raw -Encoding utf8
        foreach ($section in $required) {
            Assert-VSTrue ($content.Contains($section)) "$($directory.Name)/SKILL.md documents '$section'"
        }
        Assert-VSTrue ($content -match '(?m)^---') "$($directory.Name)/SKILL.md has frontmatter"
    }
}

Invoke-VSTest 'every-skill-is-invoked-from-an-agent-or-workflow' {
    $referencingFiles = @(
        (Join-Path $githubRoot 'agents\verisolve.agent.md'),
        (Join-Path $githubRoot 'workflows\run-pipeline.workflow.md'),
        (Join-Path $githubRoot 'workflows\high-risk-review.workflow.md')
    )
    $referenceText = ($referencingFiles | ForEach-Object { if (Test-Path -LiteralPath $_) { [IO.File]::ReadAllText($_, [Text.Encoding]::UTF8) } }) -join "`n"
    $userInvoked = @('verisolve-init', 'verisolve-cleanup')
    foreach ($directory in @(Get-ChildItem -LiteralPath (Join-Path $githubRoot 'skills') -Directory)) {
        if ($userInvoked -ccontains $directory.Name) {
            $content = [IO.File]::ReadAllText((Join-Path $directory.FullName 'SKILL.md'), [Text.Encoding]::UTF8)
            Assert-VSTrue ($content -match 'Called by') "$($directory.Name) documents that the user invokes it directly"
            continue
        }
        Assert-VSTrue ($referenceText -match [regex]::Escape($directory.Name)) "skill '$($directory.Name)' is referenced by an agent or workflow"
    }
}

Invoke-VSTest 'all-powershell-parses-under-pwsh-7' {
    $scripts = @(Get-ChildItem -LiteralPath $script:Root -Recurse -Filter '*.ps1' -File |
            Where-Object { $_.FullName -notlike '*\.git\*' })
    Assert-VSTrue ($scripts.Count -ge 15) 'all scripts discovered'
    foreach ($file in $scripts) {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-VSEqual 0 $parseErrors.Count "parse errors in $($file.Name): $((@($parseErrors | ForEach-Object { $_.Message })) -join '; ')"
    }
}

Invoke-VSTest 'config-keys-are-consumed-outside-the-config-folder' {
    $roots = @(
        (Join-Path $script:Templates 'agents'),
        (Join-Path $script:Templates 'skills'),
        (Join-Path $script:Templates 'workflows'),
        (Join-Path $script:Templates 'lib'),
        (Join-Path $script:ReleaseSkill 'scripts'),
        (Join-Path $script:Root 'scripts'),
        $script:PayloadReferences,
        $script:RuntimeReferences,
        (Join-Path $script:Templates 'copilot-instructions.md')
    )
    $consumers = @(Get-ChildItem -LiteralPath $roots -Recurse -Include '*.ps1', '*.md' -File -ErrorAction SilentlyContinue)
    $consumerText = ($consumers | ForEach-Object { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) }) -join "`n"
    $unused = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('system', 'agents', 'categories', 'verification', 'knowledge_base', 'cli')) {
        $configValue = Get-Content -LiteralPath (Join-Path $script:Templates "config\verisolve.$name.json") -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        foreach ($key in $configValue.Keys) {
            if ($consumerText -notmatch [regex]::Escape([string]$key)) { $unused.Add("verisolve.$name.json#$key") }
        }
    }
    Assert-VSEqual 0 $unused.Count ("settings without a consumer: " + ($unused -join ', '))
}

Invoke-VSTest 'release-payload-is-the-only-deliverable-and-stays-inert' {
    $repoGithub = Join-Path $script:Root '.github'
    $topLevel = @(Get-ChildItem -LiteralPath $repoGithub -Force | ForEach-Object { $_.Name })
    Assert-VSEqual 'skills' ($topLevel -join ',') 'repository .github only carries the release skill directory'

    foreach ($inert in @('agents', 'config', 'contracts', 'playbook', 'workflows', 'lib', 'references')) {
        Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $repoGithub $inert))) "no live .github/$inert before scaffolding"
    }
    Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $repoGithub 'copilot-instructions.md'))) 'no live copilot-instructions.md before scaffolding'

    $templateAgents = @(Get-ChildItem -LiteralPath (Join-Path $script:Templates 'agents') -Filter '*.agent.md' -File)
    Assert-VSEqual 3 $templateAgents.Count 'exactly three agent templates ship in the payload'
    $strayAgents = @(Get-ChildItem -LiteralPath $script:Templates -Recurse -Filter '*.agent.md' -File |
            Where-Object { $_.DirectoryName -ne (Join-Path $script:Templates 'agents') })
    Assert-VSEqual 0 $strayAgents.Count 'no agent templates live inside skills/ (they would never load)'
}

Invoke-VSTest 'payload-reference-is-installer-only' {
    $payloadDoc = Join-Path $script:PayloadReferences 'loading-and-contracts.md'
    Assert-VSTrue (Test-Path -LiteralPath $payloadDoc) 'installer reference ships beside SKILL.md'
    $text = [IO.File]::ReadAllText($payloadDoc, [Text.Encoding]::UTF8)

    Assert-VSTrue ($text -match 'inside a skill directory is not an Agent') 'documents that skill-local agents never load'
    Assert-VSTrue ($text -match 'session initialisation') 'documents agent discovery timing'
    Assert-VSTrue ($text -match 'reload') 'documents the reload requirement'
    foreach ($script in @('check-prerequisites.ps1', 'detect-state.ps1', 'scaffold.ps1')) {
        Assert-VSTrue ($text -match [regex]::Escape($script)) "documents the $script contract"
    }
    Assert-VSTrue ($text -match 'rolled_back') 'documents scaffold rollback output'

    Assert-VSTrue ($text -notmatch 'Invariants checklist') 'does not duplicate the runtime invariants list'
    Assert-VSTrue ($text -notmatch 'new_issue_introduced') 'does not duplicate the fail_category enum'
    Assert-VSTrue ($text -notmatch 'successes \+ failures \+ 2') 'does not duplicate the Playbook confidence formula'
    Assert-VSTrue ($text -notmatch 'embedding_weight') 'does not duplicate scoring weights'

    $staleDoc = Join-Path $script:PayloadReferences 'architecture.md'
    Assert-VSTrue (-not (Test-Path -LiteralPath $staleDoc)) 'the mixed-audience architecture doc is gone'
}

Invoke-VSTest 'runtime-reference-ships-and-is-reachable' {
    $runtimeDoc = Join-Path $script:RuntimeReferences 'architecture.md'
    Assert-VSTrue (Test-Path -LiteralPath $runtimeDoc) 'runtime architecture ships inside templates/'
    $text = [IO.File]::ReadAllText($runtimeDoc, [Text.Encoding]::UTF8)

    Assert-VSTrue ($text -match 'Invariants checklist') 'runtime doc owns the invariants list'
    Assert-VSTrue ($text -match 'max_patch_bytes') 'runtime doc uses the real guardrail key names'
    Assert-VSTrue ($text -match 'downgraded = true') 'runtime doc states downgrade is a signal only'
    Assert-VSTrue ($text -match 'match-score-descending, then confidence-descending') 'runtime doc states the implemented attempt order'
    Assert-VSTrue ($text -match 'never inside the VSProblem contract') 'runtime doc keeps ingest_seq out of the contract'

    $releasedDoc = Join-Path $script:BaseGithub 'references\architecture.md'
    Assert-VSTrue (Test-Path -LiteralPath $releasedDoc) 'scaffolding releases references/architecture.md'

    $coordinator = [IO.File]::ReadAllText((Join-Path $script:BaseGithub 'agents\verisolve.agent.md'), [Text.Encoding]::UTF8)
    Assert-VSTrue ($coordinator -match 'references/architecture\.md') 'coordinator agent points at the released reference'
    $instructions = [IO.File]::ReadAllText((Join-Path $script:BaseGithub 'copilot-instructions.md'), [Text.Encoding]::UTF8)
    Assert-VSTrue ($instructions -match 'references/architecture\.md') 'project instructions point at the released reference'
}

Invoke-VSTest 'docs-and-workflows-agree-on-bounded-context-and-ordering' {
    $workflow = [IO.File]::ReadAllText((Join-Path $script:BaseGithub 'workflows\run-pipeline.workflow.md'), [Text.Encoding]::UTF8)
    Assert-VSTrue ($workflow -notmatch 'complete\s+VSProblem') 'workflow never lets a full VSProblem reach TriageAgent'
    Assert-VSTrue ($workflow -match 'No open-container field') 'workflow states the projection rule for every agent'
    Assert-VSTrue ($workflow -match 'match-score-descending') 'workflow uses the implemented attempt order'
    Assert-VSTrue ($workflow -match 'infrastructure failure') 'workflow maps contract-invalid verdicts to infrastructure failure'

    $resolver = [IO.File]::ReadAllText((Join-Path $script:BaseGithub 'agents\resolver.agent.md'), [Text.Encoding]::UTF8)
    Assert-VSTrue ($resolver -notmatch 'raw\.acceptance_criteria') 'resolver never asks for the raw container'
    Assert-VSTrue ($resolver -match 'acceptance_criteria') 'resolver documents the extracted acceptance criteria'

    $triage = [IO.File]::ReadAllText((Join-Path $script:BaseGithub 'agents\triage.agent.md'), [Text.Encoding]::UTF8)
    Assert-VSTrue ($triage -match 'never includes an open container') 'triage documents the projection rule'

    $runtimeDoc = [IO.File]::ReadAllText((Join-Path $script:RuntimeReferences 'architecture.md'), [Text.Encoding]::UTF8)
    Assert-VSTrue ($runtimeDoc -match 'Never receives `raw`|never receives `raw`|never projects') 'runtime doc forbids open containers for ResolverAgent'
    Assert-VSTrue ($runtimeDoc -match 'Review is a mode of `ResolverAgent`') 'runtime doc states review is not a new agent'
}
