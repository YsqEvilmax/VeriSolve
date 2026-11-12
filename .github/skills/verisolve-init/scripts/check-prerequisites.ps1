param(
    [string]$Workspace = (Get-Location).Path
)
# Read-only environment probe for verisolve-init. Never creates, modifies, or deletes anything.
# Always exits 0: missing prerequisites are reported as ok=false and the Skill decides what to do.
$ErrorActionPreference = 'Stop'

$workspaceRoot = [IO.Path]::GetFullPath($Workspace)
$github = Join-Path $workspaceRoot '.github'
$templateRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\templates'))

function Get-VSCommandVersion {
    param([Parameter(Mandatory)][string]$Command, [AllowEmptyCollection()][string[]]$Arguments = @())
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $Command
        foreach ($argument in $Arguments) { $null = $startInfo.ArgumentList.Add([string]$argument) }
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) { return $null }
        $stdout = $process.StandardOutput.ReadToEnd()
        $null = $process.StandardError.ReadToEnd()
        if (-not $process.WaitForExit(10000)) { $process.Kill($true); return $null }
        if ($process.ExitCode -ne 0) { return $null }
        return $stdout.Trim()
    } catch {
        return $null
    }
}

function Test-VSPlaceholderValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Collections.IList]) { return (@($Value).Count -gt 0) }
    return -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function Get-VSConfigPlaceholders {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$Source)
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        $result.Add([ordered]@{ key = 'config/verisolve.cli.json'; filled = $false; example = 'Run verisolve-init scaffolding first.' })
        return [pscustomobject]@{ entries = @($result); source = 'missing' }
    }
    try {
        $cli = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    } catch {
        $result.Add([ordered]@{ key = 'config/verisolve.cli.json'; filled = $false; example = "Invalid JSON: $($_.Exception.Message)" })
        return [pscustomobject]@{ entries = @($result); source = 'invalid' }
    }

    foreach ($name in @($cli.problem_sources.Keys)) {
        if ([string]$name -ceq 'example') { continue }
        $sourceEntry = $cli.problem_sources[$name]
        $result.Add([ordered]@{
                key     = "problem_sources.$name.command"
                filled  = (Test-VSPlaceholderValue $sourceEntry.command)
                example = '"command": "pwsh", "arguments": ["-NoProfile","-File","scripts/fetch-' + $name + '.ps1"]'
            })
    }
    foreach ($operation in @('apply', 'revert')) {
        $executor = $cli.executor[$operation]
        $result.Add([ordered]@{
                key     = "executor.$operation.command"
                filled  = (Test-VSPlaceholderValue $executor.command)
                example = '"command": "${env:VERISOLVE_EXECUTOR}", "arguments": ["apply"]'
            })
    }
    foreach ($operation in @('start', 'check')) {
        $oracle = $cli.oracle[$operation]
        $result.Add([ordered]@{
                key     = "oracle.$operation.command"
                filled  = (Test-VSPlaceholderValue $oracle.command)
                example = '"command": "${env:VERISOLVE_ORACLE}", "arguments": ["' + $operation + '"]'
            })
    }
    return [pscustomobject]@{ entries = @($result); source = $Source }
}

$payload = [ordered]@{
    workspace = $workspaceRoot
    pwsh              = [ordered]@{ ok = $false; version = $null; hint = 'winget install Microsoft.PowerShell' }
    git               = [ordered]@{ ok = $false; version = $null; hint = 'winget install Git.Git' }
    config_placeholders = @()
    config_source     = 'missing'
}

try {
    $pwshVersion = $PSVersionTable.PSVersion
    $payload.pwsh = [ordered]@{
        ok      = ($pwshVersion.Major -ge 7)
        version = $pwshVersion.ToString()
        hint    = if ($pwshVersion.Major -ge 7) { $null } else { 'PowerShell 7+ is required: winget install Microsoft.PowerShell' }
    }
} catch {
    $payload.pwsh = [ordered]@{ ok = $false; version = $null; hint = 'winget install Microsoft.PowerShell' }
}

try {
    $gitVersion = Get-VSCommandVersion -Command 'git' -Arguments @('--version')
    $payload.git = [ordered]@{
        ok      = (-not [string]::IsNullOrWhiteSpace($gitVersion))
        version = $gitVersion
        hint    = if ([string]::IsNullOrWhiteSpace($gitVersion)) { 'winget install Git.Git' } else { $null }
    }
} catch {
    $payload.git = [ordered]@{ ok = $false; version = $null; hint = 'winget install Git.Git' }
}

try {
    $scaffoldedConfig = Join-Path $github 'config\verisolve.cli.json'
    $templateConfig = Join-Path $templateRoot 'config\verisolve.cli.json'
    if (Test-Path -LiteralPath $scaffoldedConfig -PathType Leaf) {
        $placeholders = Get-VSConfigPlaceholders -ConfigPath $scaffoldedConfig -Source 'scaffolded'
    } else {
        $placeholders = Get-VSConfigPlaceholders -ConfigPath $templateConfig -Source 'template'
    }
    $payload.config_placeholders = @($placeholders.entries)
    $payload.config_source = $placeholders.source
} catch {
    $payload.config_placeholders = @([ordered]@{ key = 'config/verisolve.cli.json'; filled = $false; example = $_.Exception.Message })
    $payload.config_source = 'error'
}

[Console]::Out.Write((ConvertTo-Json -InputObject $payload -Depth 20 -Compress))
exit 0
