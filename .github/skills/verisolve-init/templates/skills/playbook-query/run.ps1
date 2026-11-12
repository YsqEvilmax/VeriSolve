param(
    [Parameter(Mandatory)]
    [ValidateSet('pin', 'query')]
    [string]$Operation,
    [Parameter(Mandatory)][string]$RequestPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\lib\vs-contracts.ps1')
. (Join-Path $PSScriptRoot '..\..\lib\vs-playbook.ps1')
$github = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Read-VSConfigSet -GithubRoot $github
Assert-VSConfigSet -Config $config
$knowledgeBase = $config.knowledge_base
$request = Get-Content -LiteralPath ([IO.Path]::GetFullPath($RequestPath)) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable

switch ($Operation) {
    'pin' {
        $snapshotPath = [IO.Path]::GetFullPath((Join-Path $github ([string]$knowledgeBase.snapshot_path)))
        if (-not [IO.File]::Exists($snapshotPath)) { throw "Playbook snapshot '$snapshotPath' does not exist. Run playbook-commit -Operation rebuild first." }
        $snapshot = [IO.File]::ReadAllText($snapshotPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -AsHashtable
        if ($snapshot.patterns -isnot [System.Collections.IList]) { throw "Playbook snapshot '$snapshotPath' has an invalid shape." }
        $pinned = [ordered]@{
            version = [int]$snapshot.version
            pinned_at = [DateTimeOffset]::UtcNow.ToString('o')
            patterns = @($snapshot.patterns)
        }
        [Console]::Out.Write((ConvertTo-Json -InputObject $pinned -Depth 100 -Compress))
    }
    'query' {
        # $request.snapshot is the batch-pinned copy held by the coordinator. This operation never
        # touches playbook/snapshot.json, takes no lock, and performs no writes.
        $snapshot = $request.snapshot
        if ($snapshot -isnot [System.Collections.IDictionary] -or $snapshot.patterns -isnot [System.Collections.IList]) {
            throw 'Query request must include the pinned snapshot object with a patterns array.'
        }
        if ($request.category -isnot [string]) { throw 'Query request must include a triage category.' }
        if ($request.signature -isnot [System.Collections.IDictionary]) { throw 'Query request must include a signature object.' }
        $features = if ($request.signature.features -is [System.Collections.IDictionary]) { $request.signature.features } else { [ordered]@{} }
        $queryRequest = [ordered]@{
            category = [string]$request.category
            signature = [ordered]@{ keywords = @($request.signature.keywords); features = $features }
            top_k = $request.top_k
            min_score = $request.min_score
        }
        $matches = Select-VSPlaybookMatches -Snapshot $snapshot -Request $queryRequest -KnowledgeBase $knowledgeBase
        $payload = [ordered]@{
            snapshot_version = [int]$snapshot.version
            category = $queryRequest.category
            top_k = if ($null -ne $queryRequest.top_k) { [int]$queryRequest.top_k } else { [int]$knowledgeBase.top_k }
            min_score = if ($null -ne $queryRequest.min_score) { [double]$queryRequest.min_score } else { [double]$knowledgeBase.min_score }
            match_count = $matches.Count
            matches = @($matches)
        }
        [Console]::Out.Write((ConvertTo-Json -InputObject $payload -Depth 100 -Compress))
    }
}
