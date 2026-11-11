param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\lib\vs-contracts.ps1')
. (Join-Path $PSScriptRoot '..\..\lib\vs-schedule.ps1')
$github = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Read-VSConfigSet -GithubRoot $github
Assert-VSConfigSet -Config $config
$request = Get-Content -LiteralPath ([IO.Path]::GetFullPath($RequestPath)) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
if ($request.items -isnot [System.Collections.IList]) { throw 'rank-and-schedule requires an items array.' }
$schedule = Invoke-VSRankSchedule -Items @($request.items) -Config $config
[Console]::Out.Write((ConvertTo-Json -InputObject $schedule -Depth 100 -Compress))
