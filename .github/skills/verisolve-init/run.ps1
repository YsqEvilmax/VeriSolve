param(
    [Parameter(Mandatory)]
    [ValidateSet('inspect', 'scaffold')]
    [string]$Mode,
    [string]$Workspace = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = [IO.Path]::GetFullPath($Workspace)
$targetGithub = Join-Path $workspaceRoot '.github'
$targetAgent = Join-Path $targetGithub 'agents\verisolve.agent.md'
$manifestPath = Join-Path $targetGithub 'verisolve-init.manifest.json'
$sourceGithub = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Get-IntegrationStatus {
    param([string]$GithubRoot)
    $cliPath = Join-Path $GithubRoot 'config\verisolve.cli.json'
    if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
        return @('config/verisolve.cli.json')
    }
    $cli = Get-Content -LiteralPath $cliPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($source in $cli.problem_sources.Keys) {
        if ($source -ne 'example' -and [string]::IsNullOrWhiteSpace([string]$cli.problem_sources[$source].command)) {
            $missing.Add("problem_sources.$source.command")
        }
    }
    foreach ($operation in @('apply', 'revert')) {
        if ([string]::IsNullOrWhiteSpace([string]$cli.executor[$operation].command)) {
            $missing.Add("executor.$operation.command")
        }
    }
    foreach ($operation in @('start', 'check')) {
        if ([string]::IsNullOrWhiteSpace([string]$cli.oracle[$operation].command)) {
            $missing.Add("oracle.$operation.command")
        }
    }
    return @($missing)
}

if ($Mode -eq 'inspect') {
    $exists = Test-Path -LiteralPath $targetAgent -PathType Leaf
    $pendingCount = 0
    $completedCount = 0
    $pendingPath = Join-Path $targetGithub 'playbook\pending-verifications.json'
    if (Test-Path -LiteralPath $pendingPath -PathType Leaf) {
        $state = Get-Content -LiteralPath $pendingPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $pendingCount = @($state.pending).Count
        $completedCount = @($state.completed).Count
    }
    $runPath = Join-Path $targetGithub 'playbook\runs'
    $latestRun = $null
    if (Test-Path -LiteralPath $runPath -PathType Container) {
        $latestRun = Get-ChildItem -LiteralPath $runPath -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 -ExpandProperty Name
    }
    $missing = if ($exists) { Get-IntegrationStatus $targetGithub } else { @() }
    [pscustomobject]@{
        mode = if ($exists) { 'resume' } else { 'scaffold_required' }
        workspace = $workspaceRoot
        pending_count = $pendingCount
        completed_count = $completedCount
        latest_run = $latestRun
        unconfigured_integrations = @($missing)
        manifest_exists = Test-Path -LiteralPath $manifestPath
    } | ConvertTo-Json -Depth 20 -Compress
    exit 0
}

if (Test-Path -LiteralPath $targetAgent -PathType Leaf) {
    throw 'VeriSolve is already initialized. Inspect/resume; refusing to overwrite the existing workspace.'
}

$created = [System.Collections.Generic.List[object]]::new()
$runtimeArtifacts = @(
    '\playbook\events.log',
    '\playbook\snapshot.json',
    '\playbook\pending-verifications.json',
    '\playbook\event-queue.log',
    '\playbook\playbook-writer.lock',
    '\playbook\pending-verifications.lock',
    '\playbook\poller.pid',
    '\playbook\poller.log',
    '\playbook\poller.error.log'
)
Get-ChildItem -LiteralPath $sourceGithub -Recurse -File | Where-Object {
    $candidate = $_
    if ($candidate.FullName -eq $manifestPath) { return $false }
    if ($candidate.FullName -like '*\playbook\runs\*') { return $false }
    foreach ($artifact in $runtimeArtifacts) {
        if ($candidate.FullName -like "*$artifact") { return $false }
    }
    return $true
} | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($sourceGithub, $_.FullName).Replace('\', '/')
    $destination = [IO.Path]::GetFullPath((Join-Path $targetGithub $relative))
    if (-not $destination.StartsWith($targetGithub + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Scaffold path escapes target: $relative"
    }
    if (-not (Test-Path -LiteralPath $destination)) {
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
        }
        Copy-Item -LiteralPath $_.FullName -Destination $destination
        $created.Add([pscustomobject]@{
            path = $relative
            sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        })
    }
}

$playbook = Join-Path $targetGithub 'playbook'
if (-not (Test-Path -LiteralPath $playbook)) {
    $null = New-Item -ItemType Directory -Path $playbook -Force
}
foreach ($file in @(
    @{ name = 'events.log'; content = '' },
    @{ name = 'snapshot.json'; content = "{`n  `"version`": 0,`n  `"patterns`": []`n}`n" },
    @{ name = 'pending-verifications.json'; content = "{`n  `"schema_version`": 1,`n  `"pending`": [],`n  `"completed`": [],`n  `"infra_failed`": []`n}`n" }
)) {
    $destination = Join-Path $playbook $file.name
    if (-not (Test-Path -LiteralPath $destination)) {
        [IO.File]::WriteAllText($destination, $file.content, [Text.UTF8Encoding]::new($false))
        $created.Add([pscustomobject]@{
            path = "playbook/$($file.name)"
            sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        })
    }
}

$manifest = [ordered]@{
    format_version = 1
    created_by = 'verisolve-init'
    files = @($created)
}
$manifestJson = ConvertTo-Json -InputObject $manifest -Depth 20
[IO.File]::WriteAllText($manifestPath, $manifestJson, [Text.UTF8Encoding]::new($false))
$missing = Get-IntegrationStatus $targetGithub
[pscustomobject]@{
    mode = 'scaffolded'
    workspace = $workspaceRoot
    created_count = $created.Count
    unconfigured_integrations = @($missing)
    manifest = $manifestPath
} | ConvertTo-Json -Depth 20 -Compress
