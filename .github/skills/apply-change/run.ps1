param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
$base = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($request.operation -cnotin @('apply', 'revert')) { throw "Unsupported operation '$($request.operation)'." }
$config = Get-Content -LiteralPath (Join-Path $base 'config\verisolve.cli.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$executor = $config.executor[$request.operation]
if ([string]::IsNullOrWhiteSpace([string]$executor.command)) { throw "executor.$($request.operation).command is not configured." }
$json = Get-Content -LiteralPath $RequestPath -Raw -Encoding utf8
$arguments = @($executor.arguments)
$output = $json | & $executor.command @arguments
if ($LASTEXITCODE -ne 0) { throw "Executor exited with code $LASTEXITCODE." }
if ($request.operation -eq 'apply') { [Console]::Out.Write(($output -join [Environment]::NewLine)) }
else { [Console]::Out.Write('{"reverted":true}') }
