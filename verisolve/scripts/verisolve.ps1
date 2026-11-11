param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'VeriSolve CLI requires PowerShell 7 or later.'
}
if ($Arguments.Count -eq 0) {
    throw 'Usage: verisolve.ps1 run|status|report|kb [options]'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot 'config\verisolve.cli.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$command = $Arguments[0]
$workflowKey = switch -CaseSensitive ($command) {
    'run' { 'run' }
    'status' { 'status' }
    'report' { 'report' }
    'kb' { 'kb' }
    default { throw "Unsupported VeriSolve command '$command'." }
}
$runtimeConfig = $config.agent_runtime
$runtime = [Environment]::GetEnvironmentVariable([string]$runtimeConfig.command_env)
if ([string]::IsNullOrWhiteSpace($runtime)) {
    throw "Set $($runtimeConfig.command_env) to the configured Agent runtime executable."
}
$workflowPath = Join-Path $projectRoot ([string]$runtimeConfig.workflow_map[$workflowKey])
$runtimeArguments = @(
    [string]$runtimeConfig.workflow_option,
    $workflowPath,
    [string]$runtimeConfig.argument_separator
) + @($Arguments)
& $runtime @runtimeArguments
if ($null -ne $LASTEXITCODE) {
    exit $LASTEXITCODE
}
