param(
    [Parameter(Mandatory)]
    [string]$RequestPath
)

$ErrorActionPreference = 'Stop'
$RequestJson = [IO.File]::ReadAllText([IO.Path]::GetFullPath($RequestPath), [Text.Encoding]::UTF8)
$request = ConvertFrom-Json -InputObject $RequestJson -AsHashtable
if ($request.operation -cnotin @('apply', 'revert')) {
    throw "Unsupported change operation '$($request.operation)'."
}
$configPath = Join-Path (Split-Path -Parent $PSScriptRoot) '..\config\verisolve.cli.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$executor = $config.executor
if ($null -eq $executor -or [string]::IsNullOrWhiteSpace([string]$executor.command)) {
    throw 'No executor command is configured in config/verisolve.cli.json.'
}
$executorArguments = @($executor.arguments)
$result = $RequestJson | & $executor.command @executorArguments
if ($LASTEXITCODE -ne 0) {
    throw "Executor command exited with code $LASTEXITCODE."
}
if ($request.operation -ceq 'apply') {
    [Console]::Out.Write(($result -join [Environment]::NewLine))
}
