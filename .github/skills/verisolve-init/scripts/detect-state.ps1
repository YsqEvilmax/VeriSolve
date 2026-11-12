param(
    [string]$Workspace = (Get-Location).Path
)
# Read-only state probe for verisolve-init. Never creates, modifies, or deletes anything.
$ErrorActionPreference = 'Stop'

$workspaceRoot = [IO.Path]::GetFullPath($Workspace)
$github = Join-Path $workspaceRoot '.github'

function Read-VSJsonIfPresent {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text | ConvertFrom-Json -AsHashtable
    } catch {
        return $null
    }
}

function Get-VSPendingCount {
    param([Parameter(Mandatory)][string]$Path)
    $state = Read-VSJsonIfPresent -Path $Path
    if ($null -eq $state) { return 0 }
    if ($state -is [System.Collections.IList]) { return @($state).Count }
    if ($state.pending -is [System.Collections.IList]) { return @($state.pending).Count }
    return 0
}

$payload = [ordered]@{
    scaffolded       = $false
    pending_count    = 0
    last_run         = $null
    suggested_action = 'init'
}

try {
    $agentPath = Join-Path $github 'agents\verisolve.agent.md'
    $payload.scaffolded = (Test-Path -LiteralPath $agentPath -PathType Leaf)
    $payload.suggested_action = if ($payload.scaffolded) { 'resume' } else { 'init' }

    if ($payload.scaffolded) {
        $verificationConfig = Read-VSJsonIfPresent -Path (Join-Path $github 'config\verisolve.verification.json')
        $pendingRelative = if ($null -ne $verificationConfig -and -not [string]::IsNullOrWhiteSpace([string]$verificationConfig.pending_verifications_path)) {
            [string]$verificationConfig.pending_verifications_path
        } else {
            'playbook/pending-verifications.json'
        }
        $pendingPath = Join-Path $github ($pendingRelative -replace '/', [IO.Path]::DirectorySeparatorChar)
        $payload.pending_count = Get-VSPendingCount -Path $pendingPath

        $cliConfig = Read-VSJsonIfPresent -Path (Join-Path $github 'config\verisolve.cli.json')
        $runRelative = if ($null -ne $cliConfig -and -not [string]::IsNullOrWhiteSpace([string]$cliConfig.run_store_path)) {
            [string]$cliConfig.run_store_path
        } else {
            'playbook/runs'
        }
        $runStore = Join-Path $github ($runRelative -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $runStore -PathType Container) {
            $latest = Get-ChildItem -LiteralPath $runStore -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
            if ($null -ne $latest) {
                $status = Read-VSJsonIfPresent -Path (Join-Path $latest.FullName 'status.json')
                $results = Read-VSJsonIfPresent -Path (Join-Path $latest.FullName 'results.json')
                $resolved = 0
                $skipped = 0
                $escalation = 0
                if ($null -ne $results) {
                    if ($results.archived -is [System.Collections.IList]) { $resolved = @($results.archived).Count }
                    if ($results.skipped -is [System.Collections.IList]) { $skipped = @($results.skipped).Count }
                    if ($results.escalated -is [System.Collections.IList]) { $escalation = @($results.escalated).Count }
                }
                $payload.last_run = [ordered]@{
                    id         = $latest.Name
                    ts         = $latest.LastWriteTimeUtc.ToString('o')
                    resolved   = $resolved
                    skipped    = $skipped
                    escalation = $escalation
                    state      = if ($null -ne $status) { [string]$status.state } else { $null }
                }
            }
        }
    }
} catch {
    $payload.scaffolded = (Test-Path -LiteralPath (Join-Path $github 'agents\verisolve.agent.md') -PathType Leaf)
    $payload.suggested_action = if ($payload.scaffolded) { 'resume' } else { 'init' }
}

[Console]::Out.Write((ConvertTo-Json -InputObject $payload -Depth 20 -Compress))
exit 0
