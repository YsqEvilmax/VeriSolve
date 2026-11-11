param(
    [Parameter(Mandatory)]
    [string]$RequestPath
)

$ErrorActionPreference = 'Stop'
$RequestJson = [IO.File]::ReadAllText([IO.Path]::GetFullPath($RequestPath), [Text.Encoding]::UTF8)
$request = ConvertFrom-Json -InputObject $RequestJson -AsHashtable
$configPath = Join-Path (Split-Path -Parent $PSScriptRoot) '..\config\verisolve.cli.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($request.operation -ceq 'start' -and $request.problem.source -ceq 'example') {
    [Console]::Out.Write((ConvertTo-Json -InputObject $config.example_adapter.oracle_verdict -Depth 100 -Compress))
    exit 0
}
$oracle = $config.oracle
if ($null -eq $oracle -or [string]::IsNullOrWhiteSpace([string]$oracle.command)) {
    throw 'No Oracle command is configured in config/verisolve.cli.json.'
}
$oracleArguments = @($oracle.arguments)
$result = $RequestJson | & $oracle.command @oracleArguments
if ($LASTEXITCODE -ne 0) {
    throw "Oracle command exited with code $LASTEXITCODE."
}
[Console]::Out.Write(($result -join [Environment]::NewLine))
