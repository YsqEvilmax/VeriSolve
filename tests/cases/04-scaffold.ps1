# Scaffolding, resume detection, and uninstall acceptance cases.
$githubRoot = Join-Path $script:Root '.github'
$initScript = Join-Path $githubRoot 'skills\verisolve-init\run.ps1'
$cleanupScript = Join-Path $githubRoot 'skills\verisolve-cleanup\run.ps1'

Write-VSSection 'Scaffolding and uninstall'

function New-VSWorkspace {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("verisolve-ws-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $path -Force
    return $path
}

Invoke-VSTest 'init-scaffolds-the-linked-system' {
    $workspace = New-VSWorkspace
    try {
        $result = Invoke-VSScriptJson -Path $initScript -Arguments @('-Mode', 'scaffold', '-Workspace', $workspace)
        Assert-VSEqual 'scaffolded' $result.mode 'scaffold mode reported'
        Assert-VSTrue ([int]$result.created_count -gt 20) 'the full system tree was copied'

        $targetGithub = Join-Path $workspace '.github'
        foreach ($relative in @(
                'agents\verisolve.agent.md',
                'agents\triage.agent.md',
                'agents\resolver.agent.md',
                'skills\verify-change\start.ps1',
                'skills\verify-change\check.ps1',
                'skills\playbook-commit\run.ps1',
                'skills\rank-and-schedule\run.ps1',
                'lib\vs-contracts.ps1',
                'config\verisolve.verification.json',
                'contracts\vs-change.schema.json',
                'workflows\run-pipeline.workflow.md',
                'playbook\events.log',
                'playbook\snapshot.json',
                'playbook\pending-verifications.json'
            )) {
            Assert-VSTrue (Test-Path -LiteralPath (Join-Path $targetGithub $relative)) "scaffolded $relative"
        }
        Assert-VSTrue (Test-Path -LiteralPath (Join-Path $targetGithub 'verisolve-init.manifest.json')) 'ownership manifest written'

        $manifest = Get-Content -LiteralPath (Join-Path $targetGithub 'verisolve-init.manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert-VSEqual 'verisolve-init' $manifest.created_by 'manifest records the scaffold owner'
        Assert-VSTrue (@($manifest.files | Where-Object { $_.path -like 'playbook/*' }).Count -ge 3) 'runtime state files recorded in the manifest'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'init-reports-unconfigured-external-integrations' {
    $workspace = New-VSWorkspace
    try {
        $result = Invoke-VSScriptJson -Path $initScript -Arguments @('-Mode', 'scaffold', '-Workspace', $workspace)
        $missing = @($result.unconfigured_integrations)
        Assert-VSTrue ($missing -contains 'executor.apply.command') 'unconfigured executor is reported'
        Assert-VSTrue ($missing -contains 'executor.revert.command') 'unconfigured revert is reported'
        Assert-VSTrue ($missing -contains 'problem_sources.checkmarx_example.command') 'example external source is reported'
        Assert-VSTrue (-not ($missing -contains 'oracle.start.command')) 'mock Oracle start is configured out of the box'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'init-refuses-to-overwrite-and-inspect-detects-resume' {
    $workspace = New-VSWorkspace
    try {
        $null = Invoke-VSScriptJson -Path $initScript -Arguments @('-Mode', 'scaffold', '-Workspace', $workspace)
        $second = Invoke-VSScript -Path $initScript -Arguments @('-Mode', 'scaffold', '-Workspace', $workspace)
        Assert-VSTrue ($second.exit_code -ne 0) 'second scaffold refuses to overwrite'

        $pendingPath = Join-Path $workspace '.github\playbook\pending-verifications.json'
        $state = Get-Content -LiteralPath $pendingPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $state.pending = @([ordered]@{ verification_id = 'mock-1'; change_id = 'c1'; problem_id = 'p1'; started_at = '2026-01-01T00:00:00Z'; infrastructure_retries = 0; request = [ordered]@{} })
        $state.completed = @([ordered]@{ verification_id = 'mock-2'; problem_id = 'p2'; verdict = [ordered]@{}; request = [ordered]@{} })
        [IO.File]::WriteAllText($pendingPath, (ConvertTo-Json -InputObject $state -Depth 20), [Text.UTF8Encoding]::new($false))

        $inspect = Invoke-VSScriptJson -Path $initScript -Arguments @('-Mode', 'inspect', '-Workspace', $workspace)
        Assert-VSEqual 'resume' $inspect.mode 'existing system reports resume mode'
        Assert-VSEqual 1 $inspect.pending_count 'pending count surfaced'
        Assert-VSEqual 1 $inspect.completed_count 'completed count surfaced'
        Assert-VSEqual $true $inspect.manifest_exists 'manifest presence surfaced'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'cleanup-plan-is-non-destructive-and-explicit' {
    $workspace = New-VSWorkspace
    try {
        $null = Invoke-VSScriptJson -Path $initScript -Arguments @('-Mode', 'scaffold', '-Workspace', $workspace)
        $before = @(Get-ChildItem -LiteralPath (Join-Path $workspace '.github') -Recurse -File).Count
        $plan = Invoke-VSScriptJson -Path $cleanupScript -Arguments @('-Mode', 'plan', '-Workspace', $workspace)
        Assert-VSTrue (@($plan.deletable).Count -gt 20) 'plan lists scaffold-owned files'
        Assert-VSTrue ($plan.warning -like '*External pipelines continue running*') 'plan warns that external pipelines keep running'
        $after = @(Get-ChildItem -LiteralPath (Join-Path $workspace '.github') -Recurse -File).Count
        Assert-VSEqual $before $after 'plan deletes nothing'

        $unconfirmed = Invoke-VSScript -Path $cleanupScript -Arguments @('-Mode', 'uninstall', '-Workspace', $workspace)
        Assert-VSTrue ($unconfirmed.exit_code -ne 0) 'uninstall without confirmation is refused'
        Assert-VSTrue ($unconfirmed.text -like '*ConfirmUninstall*') 'refusal explains the confirmation requirement'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'cleanup-removes-scaffold-retains-modified-files-and-clears-pending' {
    $workspace = New-VSWorkspace
    try {
        $null = Invoke-VSScriptJson -Path $initScript -Arguments @('-Mode', 'scaffold', '-Workspace', $workspace)
        $targetGithub = Join-Path $workspace '.github'
        $modified = Join-Path $targetGithub 'config\verisolve.system.json'
        [IO.File]::AppendAllText($modified, ' ', [Text.UTF8Encoding]::new($false))

        $pendingPath = Join-Path $targetGithub 'playbook\pending-verifications.json'
        $state = Get-Content -LiteralPath $pendingPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $state.pending = @([ordered]@{ verification_id = 'mock-1'; change_id = 'c1'; problem_id = 'p1'; started_at = '2026-01-01T00:00:00Z'; infrastructure_retries = 0; request = [ordered]@{} })
        [IO.File]::WriteAllText($pendingPath, (ConvertTo-Json -InputObject $state -Depth 20), [Text.UTF8Encoding]::new($false))

        $result = Invoke-VSScriptJson -Path $cleanupScript -Arguments @('-Mode', 'uninstall', '-Workspace', $workspace, '-ConfirmUninstall')
        Assert-VSEqual 'uninstalled' $result.mode 'uninstall completed'
        Assert-VSTrue (Test-Path -LiteralPath $modified) 'modified file is retained'
        Assert-VSTrue ($result.retained -join ' ' -like '*modified since scaffold*') 'retained file is explained'
        Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $targetGithub 'agents\verisolve.agent.md'))) 'unmodified agent file removed'
        Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $targetGithub 'playbook\pending-verifications.json'))) 'pending state cleared'
        Assert-VSTrue (-not (Test-Path -LiteralPath (Join-Path $targetGithub 'verisolve-init.manifest.json'))) 'manifest removed'
    } finally { Remove-VSSandbox -Path $workspace }
}

Invoke-VSTest 'cleanup-refuses-without-ownership-manifest' {
    $workspace = New-VSWorkspace
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $workspace '.github\playbook') -Force
        [IO.File]::WriteAllText((Join-Path $workspace '.github\playbook\pending-verifications.json'), '{"schema_version":1,"pending":[],"completed":[],"infra_failed":[]}', [Text.UTF8Encoding]::new($false))
        $result = Invoke-VSScriptJson -Path $cleanupScript -Arguments @('-Mode', 'uninstall', '-Workspace', $workspace, '-ConfirmUninstall')
        Assert-VSEqual 0 @($result.deletable).Count 'nothing is deletable without a manifest'
        Assert-VSTrue ($result.retained -join ' ' -like '*No VeriSolve init ownership manifest*') 'missing manifest is explained'
        Assert-VSTrue (Test-Path -LiteralPath (Join-Path $workspace '.github\playbook\pending-verifications.json')) 'state is preserved without an ownership manifest'
    } finally { Remove-VSSandbox -Path $workspace }
}
