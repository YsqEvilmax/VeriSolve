param(
    [string]$Workspace = (Get-Location).Path
)
# Releases templates/ into <workspace>/.github. Idempotent: existing targets are skipped, never overwritten.
# Validates template completeness first and rolls back files created by this run if anything fails.
$ErrorActionPreference = 'Stop'

$workspaceRoot = [IO.Path]::GetFullPath($Workspace)
$github = [IO.Path]::GetFullPath((Join-Path $workspaceRoot '.github'))
$templateRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\templates'))

$requiredTemplates = @(
    'agents/verisolve.agent.md'
    'agents/triage.agent.md'
    'agents/resolver.agent.md'
    'config/verisolve.system.json'
    'config/verisolve.agents.json'
    'config/verisolve.categories.json'
    'config/verisolve.verification.json'
    'config/verisolve.knowledge_base.json'
    'config/verisolve.cli.json'
    'contracts/vs-problem.schema.json'
    'contracts/vs-verdict.schema.json'
    'contracts/vs-change.schema.json'
    'playbook/events.log'
    'playbook/snapshot.json'
    'playbook/pending-verifications.json'
    'workflows/run-pipeline.workflow.md'
    'workflows/high-risk-review.workflow.md'
    'lib/vs-contracts.ps1'
    'lib/vs-filelock.ps1'
    'lib/vs-playbook.ps1'
    'lib/vs-schedule.ps1'
    'copilot-instructions.md'
    'skills/fetch-backlog/SKILL.md'
    'skills/fetch-backlog/run.ps1'
    'skills/playbook-query/SKILL.md'
    'skills/playbook-query/run.ps1'
    'skills/playbook-commit/SKILL.md'
    'skills/playbook-commit/run.ps1'
    'skills/guardrail-check/SKILL.md'
    'skills/guardrail-check/run.ps1'
    'skills/apply-change/SKILL.md'
    'skills/apply-change/run.ps1'
    'skills/verify-change/SKILL.md'
    'skills/verify-change/start.ps1'
    'skills/verify-change/check.ps1'
    'skills/verify-change/pending-store.ps1'
    'skills/poll-verifications/SKILL.md'
    'skills/poll-verifications/run.ps1'
    'skills/rank-and-schedule/SKILL.md'
    'skills/rank-and-schedule/run.ps1'
    'skills/verisolve-cleanup/SKILL.md'
    'skills/verisolve-cleanup/scripts/cleanup.ps1'
)

$created = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()
$createdDirectories = [System.Collections.Generic.List[string]]::new()

function ConvertTo-VSRelativePath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetRelativePath($github, $Path).Replace('\', '/')
}

function New-VSDirectoryTracked {
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Directory]::Exists($Path)) { return }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and $parent -ne $Path) {
        New-VSDirectoryTracked -Path $parent
    }
    if (-not [IO.Directory]::Exists($Path)) {
        $null = [IO.Directory]::CreateDirectory($Path)
        $createdDirectories.Add($Path)
    }
}

function Undo-VSScaffold {
    for ($index = $created.Count - 1; $index -ge 0; $index--) {
        $path = $created[$index]
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    foreach ($directory in ($createdDirectories | Sort-Object Length -Descending)) {
        if ([IO.Directory]::Exists($directory) -and @([IO.Directory]::GetFileSystemEntries($directory)).Count -eq 0) {
            [IO.Directory]::Delete($directory)
        }
    }
}

function Write-VSScaffoldError {
    param([Parameter(Mandatory)][string]$Message)
    Undo-VSScaffold
    [Console]::Error.Write($Message)
    [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                    created     = @()
                    skipped     = @()
                    error       = $Message
                    rolled_back = @($created | ForEach-Object { ConvertTo-VSRelativePath $_ })
                }) -Depth 20 -Compress))
    exit 1
}

if (-not (Test-Path -LiteralPath $templateRoot -PathType Container)) {
    Write-VSScaffoldError "VeriSolve templates are missing at '$templateRoot'. Reinstall the verisolve-init skill folder."
}

$missing = [System.Collections.Generic.List[string]]::new()
foreach ($relative in $requiredTemplates) {
    $candidate = Join-Path $templateRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { $missing.Add($relative) }
}
$templateSkills = @(Get-ChildItem -LiteralPath (Join-Path $templateRoot 'skills') -Directory -ErrorAction SilentlyContinue)
if ($templateSkills.Count -lt 9) {
    $missing.Add("skills/ (expected at least 9 skill templates, found $($templateSkills.Count))")
}
foreach ($skillDirectory in $templateSkills) {
    if (-not (Test-Path -LiteralPath (Join-Path $skillDirectory.FullName 'SKILL.md') -PathType Leaf)) {
        $missing.Add("skills/$($skillDirectory.Name)/SKILL.md")
    }
}
if ($missing.Count -gt 0) {
    Write-VSScaffoldError ("Template validation failed; missing: " + ($missing -join ', '))
}

$mapping = @(
    @{ source = 'agents'; target = 'agents' }
    @{ source = 'skills'; target = 'skills' }
    @{ source = 'config'; target = 'config' }
    @{ source = 'contracts'; target = 'contracts' }
    @{ source = 'playbook'; target = 'playbook' }
    @{ source = 'workflows'; target = 'workflows' }
    @{ source = 'lib'; target = 'lib' }
)

try {
    foreach ($entry in $mapping) {
        $sourceRoot = Join-Path $templateRoot $entry.source
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { continue }
        $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File)
        foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($templateRoot, $file.FullName)
            $target = [IO.Path]::GetFullPath((Join-Path $github $relative))
            if (-not $target.StartsWith($github + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Template path escapes the workspace .github directory: $relative"
            }
            if ([IO.File]::Exists($target)) {
                $skipped.Add((ConvertTo-VSRelativePath $target))
                continue
            }
            New-VSDirectoryTracked -Path (Split-Path -Parent $target)
            [IO.File]::Copy($file.FullName, $target, $false)
            $created.Add($target)
        }
    }

    $instructionsSource = Join-Path $templateRoot 'copilot-instructions.md'
    $instructionsTarget = Join-Path $github 'copilot-instructions.md'
    if ([IO.File]::Exists($instructionsTarget)) {
        $skipped.Add('copilot-instructions.md')
    } else {
        New-VSDirectoryTracked -Path $github
        [IO.File]::Copy($instructionsSource, $instructionsTarget, $false)
        $created.Add($instructionsTarget)
    }
} catch {
    Write-VSScaffoldError "Scaffolding failed: $($_.Exception.Message)"
}

$pendingPath = Join-Path $github 'playbook\pending-verifications.json'
$playbookInitialized = $false
try {
    if (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) {
        New-VSDirectoryTracked -Path (Split-Path -Parent $pendingPath)
        [IO.File]::WriteAllText($pendingPath, "[]`n", [Text.UTF8Encoding]::new($false))
        $created.Add($pendingPath)
    }
    $eventsPath = Join-Path $github 'playbook\events.log'
    if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) {
        New-VSDirectoryTracked -Path (Split-Path -Parent $eventsPath)
        [IO.File]::WriteAllText($eventsPath, '', [Text.UTF8Encoding]::new($false))
        $created.Add($eventsPath)
    }
    $playbookInitialized = (Test-Path -LiteralPath $pendingPath -PathType Leaf)
} catch {
    Write-VSScaffoldError "Playbook initialisation failed: $($_.Exception.Message)"
}

[Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                workspace            = $workspaceRoot
                created              = @($created | ForEach-Object { ConvertTo-VSRelativePath $_ })
                skipped              = @($skipped)
                playbook_initialized = [bool]$playbookInitialized
            }) -Depth 20 -Compress))
exit 0
