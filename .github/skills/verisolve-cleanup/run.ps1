param(
    [Parameter(Mandatory)]
    [ValidateSet('plan', 'uninstall')]
    [string]$Mode,
    [string]$Workspace = (Get-Location).Path,
    [switch]$ConfirmUninstall
)
$ErrorActionPreference = 'Stop'
$workspaceRoot = [IO.Path]::GetFullPath($Workspace)
$github = Join-Path $workspaceRoot '.github'
$manifestPath = Join-Path $github 'verisolve-init.manifest.json'

function Get-VSConfiguredPath {
    param(
        [Parameter(Mandatory)][string]$ConfigRelative,
        [Parameter(Mandatory)][string]$Property,
        [Parameter(Mandatory)][string]$Fallback
    )
    $configPath = Join-Path $github $ConfigRelative
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $configured = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            if (-not [string]::IsNullOrWhiteSpace([string]$configured[$Property])) {
                return [IO.Path]::GetFullPath((Join-Path $github ([string]$configured[$Property])))
            }
        } catch {
            # Cleanup must still produce a plan when configuration is unreadable.
        }
    }
    return [IO.Path]::GetFullPath((Join-Path $github $Fallback))
}

$statePath = Get-VSConfiguredPath -ConfigRelative 'config\verisolve.verification.json' -Property 'pending_verifications_path' -Fallback 'playbook\pending-verifications.json'
$lockPath = Get-VSConfiguredPath -ConfigRelative 'config\verisolve.cli.json' -Property 'lock_file' -Fallback 'playbook\pending-verifications.lock'
$pollerPidPath = Join-Path $github 'playbook\poller.pid'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    [pscustomobject]@{
        mode = $Mode
        deletable = @()
        retained = @('No VeriSolve init ownership manifest; no scaffold files will be deleted.')
        warning = 'Pending state is not cleared without an explicit VeriSolve ownership manifest.'
    } | ConvertTo-Json -Depth 20
    exit 0
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($manifest.format_version -ne 1 -or $manifest.created_by -cne 'verisolve-init') {
    throw 'Unsupported or invalid VeriSolve ownership manifest.'
}
$deletable = [System.Collections.Generic.List[string]]::new()
$retained = [System.Collections.Generic.List[string]]::new()
$deletePaths = [System.Collections.Generic.List[string]]::new()
foreach ($file in $manifest.files) {
    $relative = [string]$file.path
    if ([IO.Path]::IsPathRooted($relative)) { throw "Manifest contains rooted path '$relative'." }
    $target = [IO.Path]::GetFullPath((Join-Path $github $relative))
    if (-not $target.StartsWith($github + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest path escapes .github: '$relative'."
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
    if ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $retained.Add("$relative (reparse point)")
        continue
    }
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($hash -ceq [string]$file.sha256) {
        $deletable.Add($relative)
        $deletePaths.Add($target)
    } else {
        $retained.Add("$relative (modified since scaffold)")
    }
}
if (Test-Path -LiteralPath $statePath -PathType Leaf) { $deletable.Add('playbook/pending-verifications.json (state reset)') }
if (Test-Path -LiteralPath $pollerPidPath -PathType Leaf) { $deletable.Add('playbook/poller.pid (after stopping owned poller)') }

if ($Mode -eq 'plan') {
    [pscustomobject]@{
        mode = 'plan'
        deletable = @($deletable)
        retained = @($retained)
        warning = 'Deleting pending records only clears local tracking. External pipelines continue running.'
    } | ConvertTo-Json -Depth 20
    exit 0
}
if (-not $ConfirmUninstall) { throw 'Uninstall requires -ConfirmUninstall after the user reviews the plan.' }

if (Test-Path -LiteralPath $pollerPidPath -PathType Leaf) {
    $pollerScript = Join-Path $github 'skills\poll-verifications\run.ps1'
    & pwsh -NoProfile -File $pollerScript -Mode stop -Root $workspaceRoot | Out-Null
}
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    . (Join-Path $github 'skills\verify-change\pending-store.ps1')
    $verification = Get-Content -LiteralPath (Join-Path $github 'config\verisolve.verification.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $system = Get-Content -LiteralPath (Join-Path $github 'config\verisolve.system.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    Invoke-VSPendingStateLock $statePath $lockPath $system.file_lock_timeout_seconds $system.file_lock_poll_interval_ms {
        param($state)
        $state.pending = @()
        $state.completed = @()
        $state.infra_failed = @()
    } | Out-Null
    Remove-Item -LiteralPath $statePath -Force
}
foreach ($target in $deletePaths) { Remove-Item -LiteralPath $target -Force }
Remove-Item -LiteralPath $manifestPath -Force
if (Test-Path -LiteralPath $lockPath -PathType Leaf) { Remove-Item -LiteralPath $lockPath -Force }

$removedDirectories = [System.Collections.Generic.List[string]]::new()
$directories = @($deletePaths | ForEach-Object { Split-Path -Parent $_ } | Sort-Object Length -Descending -Unique)
foreach ($directory in $directories) {
    $current = $directory
    while ($current.StartsWith($github, [StringComparison]::OrdinalIgnoreCase) -and $current -ne $github) {
        if (@(Get-ChildItem -LiteralPath $current -Force).Count -ne 0) { break }
        Remove-Item -LiteralPath $current -Force
        $removedDirectories.Add([IO.Path]::GetRelativePath($github, $current))
        $current = Split-Path -Parent $current
    }
}
[pscustomobject]@{
    mode = 'uninstalled'
    deleted = @($deletable)
    retained = @($retained)
    removed_empty_directories = @($removedDirectories | Select-Object -Unique)
    warning = 'External pipelines were not cancelled; any deleted pending records cannot be used to resume them.'
} | ConvertTo-Json -Depth 20
