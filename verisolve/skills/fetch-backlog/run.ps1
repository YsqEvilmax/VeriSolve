param(
    [Parameter(Mandatory)]
    [string]$RequestPath
)

$ErrorActionPreference = 'Stop'
$RequestJson = [IO.File]::ReadAllText([IO.Path]::GetFullPath($RequestPath), [Text.Encoding]::UTF8)
$request = ConvertFrom-Json -InputObject $RequestJson -AsHashtable
$configPath = Join-Path (Split-Path -Parent $PSScriptRoot) '..\config\verisolve.cli.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($request.source -ceq 'example') {
    [Console]::Out.Write((ConvertTo-Json -InputObject $config.example_adapter.backlog_response -Depth 100 -Compress))
    exit 0
}

$source = $config.problem_sources[$request.source]
if ($null -eq $source -or [string]::IsNullOrWhiteSpace([string]$source.command)) {
    throw "No IO command is configured for problem source '$($request.source)'."
}
$sourceArguments = @($source.arguments)
$result = $RequestJson | & $source.command @sourceArguments
if ($LASTEXITCODE -ne 0) {
    throw "Problem source command exited with code $LASTEXITCODE."
}
[Console]::Out.Write(($result -join [Environment]::NewLine))
