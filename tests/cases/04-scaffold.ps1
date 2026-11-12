# Release-payload acceptance cases: prerequisites, state detection, idempotent scaffolding, uninstall.
Write-VSSection 'Release payload: prerequisites and state'

function New-VSEmptyWorkspace {
    return New-VSTempDirectory -Prefix 'verisolve-ws'
}

function Invoke-VSReleaseScript {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][object[]]$Arguments = @()
    )
    return Invoke-VSScriptJson -Path $Path -Arguments $Arguments
}

Invoke-VSTest 'check-prerequisites-reports-environment-readonly' {
    $workspace = New-VSEmptyWorkspace
    try {
        $before = @(Get-ChildItem -LiteralPath $workspace -Recurse -Force).Count
        $result = Invoke-VSReleaseScript -Path $script:PrerequisiteScript -Arguments @('-Workspace', $workspace)
        $after = @(Get-ChildItem -LiteralPath $workspace -Recurse -Force).Count

        Assert-VSEqual $before $after 'prerequisite check creates nothing'
        Assert-VSEqual $true $result.pwsh.ok 'pwsh 7+ detected'
        Assert-VSTrue ($result.pwsh.version -match '^7\.') 'pwsh version reported'
        Assert-VSEqual $true $result.git.ok 'git detected'
        Assert-VSTrue ($result.git.version -like 'git version*') 'git version reported'
        Assert-VSEqual 'template' $result.config_source 'empty workspace inspects the template config'

        $keys = @($result.config_placeholders | ForEach-Object { $_.key })
        foreach ($expected in @('executor.apply.command', 'executor.revert.command', 'oracle.start.command', 'oracle.check.command')) {
            Assert-VSTrue ($keys -contains $expected) "placeholder '$expected' reported"
        }
        $executor = @($result.config_placeholders | Where-Object { $_.key -eq 'executor.apply.command' })[0]
        Assert-VSEqual $false $executor.filled 'unconfigured executor reported as not filled'
        Assert-VSTrue (-not [string]::IsNullOrWhiteSpace($executor.example)) 'placeholder ships an example value'
        $oracle = @($result.config_placeholders | Where-Object { $_.key -eq 'oracle.start.command' })[0]
        Assert-VSEqual $true $oracle.filled 'shipped mock oracle counts as configured'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'check-prerequisites-never-exits-nonzero' {
    $workspace = New-VSEmptyWorkspace
    try {
        $result = Invoke-VSScript -Path $script:PrerequisiteScript -Arguments @('-Workspace', $workspace)
        Assert-VSEqual 0 $result.exit_code 'prerequisite check always exits 0'
        $null = $result.text | ConvertFrom-Json -AsHashtable
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'detect-state-reports-init-before-scaffolding' {
    $workspace = New-VSEmptyWorkspace
    try {
        $result = Invoke-VSReleaseScript -Path $script:DetectScript -Arguments @('-Workspace', $workspace)
        Assert-VSEqual $false $result.scaffolded 'empty workspace is not scaffolded'
        Assert-VSEqual 0 $result.pending_count 'no pending verifications'
        Assert-VSEqual $null $result.last_run 'no last run'
        Assert-VSEqual 'init' $result.suggested_action 'suggests init'
        Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $workspace '.github'))) 'state detection creates nothing'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'detect-state-reads-pending-and-last-run-without-orchestrating' {
    $workspace = New-VSEmptyWorkspace
    try {
        $null = Invoke-VSReleaseScript -Path $script:ScaffoldScript -Arguments @('-Workspace', $workspace)
        $github = Join-Path $workspace '.github'

        $pendingPath = Join-Path $github 'playbook\pending-verifications.json'
        $state = [ordered]@{
            schema_version = 1
            pending        = @([ordered]@{ verification_id = 'v1'; change_id = 'c1'; problem_id = 'p1' }, [ordered]@{ verification_id = 'v2'; change_id = 'c2'; problem_id = 'p2' })
            completed      = @()
            infra_failed   = @()
        }
        [IO.File]::WriteAllText($pendingPath, (ConvertTo-Json -InputObject $state -Depth 20), [Text.UTF8Encoding]::new($false))

        $runDirectory = Join-Path $github 'playbook\runs\run-20260101000000-abcdef01'
        $null = New-Item -ItemType Directory -Path $runDirectory -Force
        [IO.File]::WriteAllText((Join-Path $runDirectory 'status.json'), '{"state":"scheduled"}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $runDirectory 'results.json'), (ConvertTo-Json -InputObject ([ordered]@{
                        archived  = @([ordered]@{ problem_id = 'p1' }, [ordered]@{ problem_id = 'p2' }, [ordered]@{ problem_id = 'p3' })
                        skipped   = @([ordered]@{ problem_id = 'p4' })
                        escalated = @([ordered]@{ problem_id = 'p4' }, [ordered]@{ problem_id = 'p5' })
                    }) -Depth 10), [Text.UTF8Encoding]::new($false))

        $before = (Get-Item $pendingPath).LastWriteTimeUtc
        $result = Invoke-VSReleaseScript -Path $script:DetectScript -Arguments @('-Workspace', $workspace)
        $after = (Get-Item $pendingPath).LastWriteTimeUtc

        Assert-VSEqual $true $result.scaffolded 'scaffolded detected'
        Assert-VSEqual 2 $result.pending_count 'pending entries counted'
        Assert-VSEqual 'resume' $result.suggested_action 'suggests resume'
        Assert-VSEqual 'run-20260101000000-abcdef01' $result.last_run.id 'latest run id reported'
        Assert-VSEqual 3 $result.last_run.resolved 'resolved count reported'
        Assert-VSEqual 1 $result.last_run.skipped 'skipped count reported'
        Assert-VSEqual 2 $result.last_run.escalation 'escalation count reported'
        Assert-VSEqual $before $after 'state detection never writes pending state'
    } finally { Remove-VSSandbox -Path $workspace }
}

Write-VSSection 'Release payload: scaffolding'

Invoke-VSTest 'scaffold-releases-the-whole-linked-system' {
    $workspace = New-VSEmptyWorkspace
    try {
        $result = Invoke-VSReleaseScript -Path $script:ScaffoldScript -Arguments @('-Workspace', $workspace)
        Assert-VSTrue (@($result.created).Count -ge 40) "scaffold released the whole tree (created $(@($result.created).Count))"
        Assert-VSEqual 0 @($result.skipped).Count 'fresh workspace skips nothing'
        Assert-VSEqual $true $result.playbook_initialized 'playbook initialised'

        $github = Join-Path $workspace '.github'
        foreach ($relative in @(
                'agents/verisolve.agent.md', 'agents/triage.agent.md', 'agents/resolver.agent.md',
                'skills/fetch-backlog/run.ps1', 'skills/verify-change/start.ps1', 'skills/verify-change/check.ps1',
                'skills/verify-change/pending-store.ps1', 'skills/rank-and-schedule/run.ps1',
                'skills/verisolve-cleanup/SKILL.md', 'skills/verisolve-cleanup/scripts/cleanup.ps1',
                'config/verisolve.verification.json', 'contracts/vs-change.schema.json',
                'lib/vs-contracts.ps1', 'workflows/run-pipeline.workflow.md',
                'playbook/events.log', 'playbook/snapshot.json', 'playbook/pending-verifications.json',
                'copilot-instructions.md'
            )) {
            Assert-VSTrue (Test-Path -LiteralPath (Join-Path $github ($relative -replace '/', '\'))) "scaffolded $relative"
        }

        $pending = [IO.File]::ReadAllText((Join-Path $github 'playbook\pending-verifications.json'), [Text.Encoding]::UTF8).Trim()
        Assert-VSEqual '[]' $pending 'pending state seeded as an empty array'
        Assert-VSEqual 0 (Get-Item (Join-Path $github 'playbook\events.log')).Length 'event log seeded empty'
        $snapshot = Get-Content -LiteralPath (Join-Path $github 'playbook\snapshot.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert-VSEqual 0 $snapshot.version 'snapshot seeded at version 0'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'scaffold-is-idempotent-and-preserves-user-edits' {
    $workspace = New-VSEmptyWorkspace
    try {
        $first = Invoke-VSReleaseScript -Path $script:ScaffoldScript -Arguments @('-Workspace', $workspace)
        $github = Join-Path $workspace '.github'
        $agentsPath = Join-Path $github 'agents\verisolve.agent.md'
        [IO.File]::AppendAllText($agentsPath, "`n<!-- user edit -->`n", [Text.UTF8Encoding]::new($false))

        $second = Invoke-VSReleaseScript -Path $script:ScaffoldScript -Arguments @('-Workspace', $workspace)
        Assert-VSEqual 0 @($second.created).Count 'second run creates nothing'
        Assert-VSEqual @($first.created).Count @($second.skipped).Count 'second run reports every file as skipped'
        Assert-VSTrue ([IO.File]::ReadAllText($agentsPath, [Text.Encoding]::UTF8) -like '*user edit*') 'user edit preserved'
        Assert-VSEqual $true $second.playbook_initialized 'playbook still reported as initialised'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'scaffold-rolls-back-when-templates-are-incomplete' {
    $workspace = New-VSEmptyWorkspace
    $payload = New-VSTempDirectory -Prefix 'verisolve-payload'
    try {
        Copy-Item -LiteralPath $script:ReleaseSkill -Destination (Join-Path $payload 'verisolve-init') -Recurse -Force
        $brokenPayload = Join-Path $payload 'verisolve-init'
        Remove-Item -LiteralPath (Join-Path $brokenPayload 'templates\contracts\vs-verdict.schema.json') -Force

        $result = Invoke-VSScript -Path (Join-Path $brokenPayload 'scripts\scaffold.ps1') -Arguments @('-Workspace', $workspace)
        Assert-VSTrue ($result.exit_code -ne 0) 'incomplete templates fail the scaffold'
        Assert-VSTrue ($result.text -like '*vs-verdict.schema.json*') 'failure names the missing template'
        Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $workspace '.github'))) 'rollback removed every released file and directory'
    } finally {
        Remove-VSSandbox -Path $workspace
        Remove-VSSandbox -Path $payload
    }
}

Invoke-VSTest 'scaffold-keeps-existing-copilot-instructions' {
    $workspace = New-VSEmptyWorkspace
    try {
        $github = Join-Path $workspace '.github'
        $null = New-Item -ItemType Directory -Path $github -Force
        $instructions = Join-Path $github 'copilot-instructions.md'
        [IO.File]::WriteAllText($instructions, '# my own rules', [Text.UTF8Encoding]::new($false))

        $result = Invoke-VSReleaseScript -Path $script:ScaffoldScript -Arguments @('-Workspace', $workspace)
        Assert-VSTrue (@($result.skipped) -contains 'copilot-instructions.md') 'existing instructions reported as skipped'
        Assert-VSEqual '# my own rules' ([IO.File]::ReadAllText($instructions, [Text.Encoding]::UTF8)) 'user instructions untouched'
    } finally { Remove-VSSandbox -Path $workspace }
}

Write-VSSection 'Release payload: uninstall'

Invoke-VSTest 'cleanup-plan-is-read-only' {
    $workspace = New-VSSandbox
    try {
        $github = Get-VSSandboxGithub -Sandbox $workspace
        $cleanup = Join-Path $github 'skills\verisolve-cleanup\scripts\cleanup.ps1'
        $before = @(Get-ChildItem -LiteralPath $github -Recurse -File).Count
        $plan = Invoke-VSReleaseScript -Path $cleanup -Arguments @('-Mode', 'plan', '-Workspace', $workspace)
        $after = @(Get-ChildItem -LiteralPath $github -Recurse -File).Count

        Assert-VSEqual 'plan' $plan.mode 'plan mode reported'
        Assert-VSEqual $before $after 'plan deletes nothing'
        Assert-VSTrue (@($plan.would_delete).Count -ge 10) 'plan lists the VeriSolve files'
        Assert-VSTrue ($plan.warning -like '*not cancelled*') 'plan warns that pipelines keep running'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'cleanup-refuses-without-confirmation' {
    $workspace = New-VSSandbox
    try {
        $github = Get-VSSandboxGithub -Sandbox $workspace
        $cleanup = Join-Path $github 'skills\verisolve-cleanup\scripts\cleanup.ps1'
        $result = Invoke-VSScript -Path $cleanup -Arguments @('-Mode', 'uninstall', '-Workspace', $workspace)
        Assert-VSTrue ($result.exit_code -ne 0) 'uninstall without confirmation is refused'
        Assert-VSTrue ($result.text -like '*ConfirmUninstall*') 'refusal explains the confirmation flag'
        Assert-VSTrue (Test-Path -LiteralPath (Join-Path $github 'agents\verisolve.agent.md')) 'nothing deleted on refusal'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'cleanup-backs-up-then-deletes-allowlist-and-itself-last' {
    $workspace = New-VSSandbox
    try {
        $github = Get-VSSandboxGithub -Sandbox $workspace
        $cleanup = Join-Path $github 'skills\verisolve-cleanup\scripts\cleanup.ps1'

        $userAgent = Join-Path $github 'agents\my-own.agent.md'
        [IO.File]::WriteAllText($userAgent, '# user agent', [Text.UTF8Encoding]::new($false))
        $userSkill = Join-Path $github 'skills\my-own-skill'
        $null = New-Item -ItemType Directory -Path $userSkill -Force
        [IO.File]::WriteAllText((Join-Path $userSkill 'SKILL.md'), '# user skill', [Text.UTF8Encoding]::new($false))
        $configPath = Join-Path $github 'config\verisolve.verification.json'
        $originalConfig = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8)
        $instructions = Join-Path $github 'copilot-instructions.md'

        $result = Invoke-VSReleaseScript -Path $cleanup -Arguments @('-Mode', 'uninstall', '-Workspace', $workspace, '-ConfirmUninstall')
        Assert-VSEqual 'uninstalled' $result.mode 'uninstall completed'

        $backupRoot = Join-Path $workspace ($result.backup_path -replace '/', '\')
        Assert-VSTrue (Test-Path -LiteralPath $backupRoot -PathType Container) 'backup directory created'
        Assert-VSTrue ($result.backup_path -like '.github/verisolve-backup-*') 'backup path is timestamped under .github'
        $backedUp = Join-Path $backupRoot 'config-verisolve.verification.json'
        Assert-VSTrue (Test-Path -LiteralPath $backedUp) 'config backed up before deletion'
        Assert-VSEqual $originalConfig ([IO.File]::ReadAllText($backedUp, [Text.Encoding]::UTF8)) 'backup content matches'

        Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $github 'agents\verisolve.agent.md'))) 'scaffolded agent removed'
        Assert-VSTrue (-not (Test-Path -LiteralPath $configPath)) 'config removed'
        Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $github 'playbook'))) 'playbook removed'
        Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $github 'skills\fetch-backlog'))) 'scaffolded skill removed'
        Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $github 'skills\verisolve-init'))) 'installer directory removed'
        Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $github 'skills\verisolve-cleanup'))) 'cleanup removed itself last'

        Assert-VSTrue (Test-Path -LiteralPath $userAgent) 'user agent preserved'
        Assert-VSTrue (Test-Path -LiteralPath $userSkill) 'user skill preserved'
        Assert-VSTrue (Test-Path -LiteralPath $instructions) 'copilot-instructions.md preserved'

        $deleted = @($result.deleted)
        $selfIndex = [Array]::IndexOf($deleted, 'skills/verisolve-cleanup/')
        $initIndex = [Array]::IndexOf($deleted, 'skills/verisolve-init/')
        Assert-VSTrue ($selfIndex -ge 0) 'self directory appears in the deletion report'
        Assert-VSTrue ($initIndex -lt $selfIndex) 'installer directory is deleted before the cleanup skill itself'
        Assert-VSEqual ($deleted.Count - 1) $selfIndex 'cleanup skill is the final deletion'
    } finally { Remove-VSSandbox -Path $workspace }
}
