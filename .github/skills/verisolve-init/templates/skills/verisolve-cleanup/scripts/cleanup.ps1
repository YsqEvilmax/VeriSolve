param(
    [Parameter(Mandatory)]
    [ValidateSet('plan', 'uninstall')]
    [string]$Mode,
    [string]$Workspace = (Get-Location).Path,
    [switch]$ConfirmUninstall
)
# VeriSolve uninstaller. Backs up configuration first, then deletes only allowlisted paths,
# removing its own skill directory last. Never deletes user-authored agents, skills, or settings.
$ErrorActionPreference = 'Stop'

$workspaceRoot = [IO.Path]::GetFullPath($Workspace)
$github = [IO.Path]::GetFullPath((Join-Path $workspaceRoot '.github'))

$configFiles = @(
    'config/verisolve.system.json'
    'config/verisolve.agents.json'
    'config/verisolve.categories.json'
    'config/verisolve.verification.json'
    'config/verisolve.knowledge_base.json'
    'config/verisolve.cli.json'
)
$stateFiles = @(
    'playbook/pending-verifications.json'
    'playbook/snapshot.json'
    'playbook/events.log'
)
$agentFiles = @(
    'agents/verisolve.agent.md'
    'agents/triage.agent.md'
    'agents/resolver.agent.md'
)
$contractFiles = @(
    'contracts/vs-problem.schema.json'
    'contracts/vs-verdict.schema.json'
    'contracts/vs-change.schema.json'
)
$workflowFiles = @(
    'workflows/run-pipeline.workflow.md'
    'workflows/high-risk-review.workflow.md'
)
# Installed skill directories, deleted in order; the cleanup skill itself must come last.
$skillDirectories = @(
    'skills/fetch-backlog'
    'skills/playbook-query'
    'skills/playbook-commit'
    'skills/guardrail-check'
    'skills/apply-change'
    'skills/verify-change'
    'skills/poll-verifications'
    'skills/rank-and-schedule'
    'skills/verisolve-init'
    'skills/verisolve-cleanup'
)
$supportDirectories = @('lib', 'playbook', 'references')

function ConvertTo-VSFullPath {
    param([Parameter(Mandatory)][string]$Relative)
    $candidate = [IO.Path]::GetFullPath((Join-Path $github ($Relative -replace '/', [IO.Path]::DirectorySeparatorChar)))
    if (-not ($candidate -eq $github -or $candidate.StartsWith($github + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Refusing to touch a path outside the workspace .github directory: $Relative"
    }
    return $candidate
}

function Get-VSPlannedPaths {
    $planned = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in ($agentFiles + $contractFiles + $workflowFiles + $configFiles)) {
        $planned.Add([pscustomobject]@{ relative = $relative; full = (ConvertTo-VSFullPath $relative); kind = 'file' })
    }
    foreach ($relative in $supportDirectories) {
        $planned.Add([pscustomobject]@{ relative = $relative; full = (ConvertTo-VSFullPath $relative); kind = 'directory' })
    }
    # The cleanup skill directory must be deleted after everything else, including the installer.
    foreach ($relative in $skillDirectories) {
        $planned.Add([pscustomobject]@{ relative = $relative; full = (ConvertTo-VSFullPath $relative); kind = 'directory' })
    }
    return @($planned)
}

function Copy-VSBackup {
    $timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $backupRoot = Join-Path $github "verisolve-backup-$timestamp"
    $null = [IO.Directory]::CreateDirectory($backupRoot)
    $copied = [System.Collections.Generic.List[string]]::new()
    foreach ($relative in ($configFiles + $stateFiles)) {
        $source = ConvertTo-VSFullPath $relative
        if (-not [IO.File]::Exists($source)) { continue }
        $name = $relative -replace '/', '-'
        [IO.File]::Copy($source, (Join-Path $backupRoot $name), $true)
        $copied.Add($name)
    }
    return [pscustomobject]@{ path = $backupRoot; files = @($copied) }
}

$planned = Get-VSPlannedPaths
$present = @($planned | Where-Object {
        if ($_.kind -eq 'file') { [IO.File]::Exists($_.full) } else { [IO.Directory]::Exists($_.full) }
    })

if ($Mode -eq 'plan') {
    [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                    mode         = 'plan'
                    backup_path  = $null
                    would_delete = @($present | ForEach-Object { $_.relative })
                    not_found    = @($planned | Where-Object { $present -notcontains $_ } | ForEach-Object { $_.relative })
                    retained     = @(
                        'copilot-instructions.md (left in place: it may contain user-authored instructions)'
                    )
                    warning      = 'Backup is created during uninstall. External pipelines are not cancelled by this cleanup.'
                }) -Depth 20 -Compress))
    exit 0
}

if (-not $ConfirmUninstall) {
    [Console]::Error.Write('Uninstall requires -ConfirmUninstall after the user reviews the plan.')
    [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                    mode    = 'refused'
                    error   = 'Missing -ConfirmUninstall'
                    deleted = @()
                }) -Depth 20 -Compress))
    exit 1
}

$backup = $null
try {
    $backup = Copy-VSBackup
} catch {
    [Console]::Error.Write("Backup failed; nothing was deleted: $($_.Exception.Message)")
    [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                    mode    = 'aborted'
                    error   = "Backup failed: $($_.Exception.Message)"
                    deleted = @()
                }) -Depth 20 -Compress))
    exit 1
}

$deleted = [System.Collections.Generic.List[string]]::new()
$notFound = [System.Collections.Generic.List[string]]::new()
$retained = [System.Collections.Generic.List[string]]::new()
$retained.Add('copilot-instructions.md (left in place: it may contain user-authored instructions)')

foreach ($entry in ($present | Where-Object { $_.kind -eq 'file' })) {
    try {
        [IO.File]::Delete($entry.full)
        $deleted.Add($entry.relative)
    } catch {
        $retained.Add("$($entry.relative) (delete failed: $($_.Exception.Message))")
    }
}
foreach ($entry in ($planned | Where-Object { $_.kind -eq 'file' -and $present -notcontains $_ })) {
    $notFound.Add($entry.relative)
}

foreach ($entry in ($present | Where-Object { $_.kind -eq 'directory' })) {
    if (-not [IO.Directory]::Exists($entry.full)) { continue }
    try {
        [IO.Directory]::Delete($entry.full, $true)
        $deleted.Add("$($entry.relative)/")
    } catch {
        $retained.Add("$($entry.relative)/ (delete failed: $($_.Exception.Message))")
    }
}
foreach ($entry in ($planned | Where-Object { $_.kind -eq 'directory' -and $present -notcontains $_ })) {
    $notFound.Add("$($entry.relative)/")
}

[Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                mode        = 'uninstalled'
                backup_path = [IO.Path]::GetRelativePath($workspaceRoot, $backup.path).Replace('\', '/')
                backup_files = @($backup.files)
                deleted     = @($deleted)
                retained    = @($retained)
                not_found   = @($notFound)
                warning     = 'External pipelines were not cancelled; the backup contains only VeriSolve configuration and Playbook state.'
            }) -Depth 20 -Compress))
exit 0
