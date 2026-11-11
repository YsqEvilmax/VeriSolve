param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\lib\vs-contracts.ps1')
. (Join-Path $PSScriptRoot '..\..\lib\vs-filelock.ps1')
$github = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Read-VSConfigSet -GithubRoot $github
Assert-VSConfigSet -Config $config
$cli = $config.cli
$request = Get-Content -LiteralPath ([IO.Path]::GetFullPath($RequestPath)) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable

$sourceName = [string]$request.source
if ([string]::IsNullOrWhiteSpace($sourceName)) { throw 'fetch-backlog request requires a source name.' }
$startSeq = if ($null -ne $request.start_ingest_seq) { [long]$request.start_ingest_seq } else { 1L }
if ($startSeq -le 0) { throw 'start_ingest_seq must be positive.' }

if ($sourceName -ceq 'example') {
    $page = @{ problems = @(); next_cursor = $null }
} else {
    $source = $cli.problem_sources[$sourceName]
    if ($null -eq $source -or [string]::IsNullOrWhiteSpace([string]$source.command)) {
        throw "No external command configured for problem source '$sourceName' in config/verisolve.cli.json."
    }
    $payload = [ordered]@{ source = $sourceName; cursor = $request.cursor } | ConvertTo-Json -Depth 20 -Compress
    $output = Invoke-VSCommandJson -Command ([string]$source.command) -Arguments @($source.arguments) -Json $payload -TimeoutSeconds ([int]$cli.command_timeout_seconds) -WorkingDirectory $github
    $page = $output | ConvertFrom-Json -AsHashtable
}

$problems = @($page.problems)
$envelopes = [System.Collections.Generic.List[object]]::new()
$sequence = $startSeq
foreach ($problem in $problems) {
    $validation = Test-VSProblem -Value $problem -Config $config
    if (-not $validation.valid) {
        throw "Fetched problem failed contract validation: $($validation.errors -join ' ')"
    }
    $envelopes.Add([ordered]@{ problem_id = [string]$problem.problem_id; ingest_seq = $sequence })
    $sequence++
}
[Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                problems = @($problems)
                next_cursor = $page.next_cursor
                ingest_envelopes = @($envelopes)
                next_ingest_seq = $sequence
            }) -Depth 100 -Compress))
