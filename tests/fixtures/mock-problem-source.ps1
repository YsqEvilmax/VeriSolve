# Example problem-source fixture used by the acceptance suite. Reads one page request on stdin.
$ErrorActionPreference = 'Stop'
$requestJson = [Console]::In.ReadToEnd()
$request = $requestJson | ConvertFrom-Json -AsHashtable
if (-not [string]::IsNullOrWhiteSpace([string]$request.cursor)) {
    [Console]::Out.Write('{"problems":[],"next_cursor":null}')
    exit 0
}
$problems = @(
    [ordered]@{
        problem_id = 'mock-1'
        source = 'mock'
        raw = [ordered]@{ summary = 'checkout throws on empty cart'; logs = @('log-line-that-must-never-be-projected') }
        category = 'bug'
        severity = 'high'
        priority_score = 2.5
        signature = [ordered]@{ keywords = @('null-reference', 'checkout'); features = [ordered]@{ area = 'checkout' }; location = 'src/checkout.ps1' }
        created_at = '2026-01-01T00:00:00Z'
        metadata = [ordered]@{ adapter = 'mock' }
    },
    [ordered]@{
        problem_id = 'mock-2'
        source = 'mock'
        raw = [ordered]@{ summary = 'pipeline flaked at midnight' }
        category = 'incident'
        severity = 'critical'
        priority_score = 9.0
        signature = [ordered]@{ keywords = @('pipeline', 'flake'); features = [ordered]@{ area = 'ci' }; location = 'ci/build.yml' }
        created_at = '2026-01-02T00:00:00Z'
        metadata = [ordered]@{ adapter = 'mock' }
    }
)
[Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{ problems = $problems; next_cursor = $null }) -Depth 100 -Compress))
