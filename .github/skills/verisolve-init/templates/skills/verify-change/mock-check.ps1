# Example Oracle check fixture. VERISOLVE_MOCK_ORACLE_MODE selects pending|pass|fail (default fail).
# VERISOLVE_MOCK_ORACLE_FAIL_CATEGORY selects the reported fail_category (default unknown).
$ErrorActionPreference = 'Stop'
$requestJson = [Console]::In.ReadToEnd()
$request = $requestJson | ConvertFrom-Json -AsHashtable
if ([string]::IsNullOrWhiteSpace([string]$request.verification_id)) { throw 'mock-check requires verification_id.' }

$checkCounterPath = $env:VERISOLVE_MOCK_ORACLE_CHECK_COUNTER
if (-not [string]::IsNullOrWhiteSpace($checkCounterPath)) {
    $seen = if (Test-Path -LiteralPath $checkCounterPath) { [int](Get-Content -LiteralPath $checkCounterPath -Raw) } else { 0 }
    [IO.File]::WriteAllText($checkCounterPath, [string]($seen + 1), [Text.UTF8Encoding]::new($false))
}

$mode = if ([string]::IsNullOrWhiteSpace($env:VERISOLVE_MOCK_ORACLE_MODE)) { 'fail' } else { $env:VERISOLVE_MOCK_ORACLE_MODE }
switch -CaseSensitive ($mode) {
    'pending' {
        [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                        state = 'pending'
                        verification_id = [string]$request.verification_id
                    }) -Compress))
        exit 0
    }
    'pass' {
        $verdict = [ordered]@{
            ok = $true
            fail_category = $null
            evidence = [ordered]@{ top_errors = @(); signals = [ordered]@{}; artifacts = [ordered]@{} }
            verdict_at = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }
    'fail' {
        $failCategory = if ([string]::IsNullOrWhiteSpace($env:VERISOLVE_MOCK_ORACLE_FAIL_CATEGORY)) { 'unknown' } else { $env:VERISOLVE_MOCK_ORACLE_FAIL_CATEGORY }
        $verdict = [ordered]@{
            ok = $false
            fail_category = $failCategory
            evidence = [ordered]@{ top_errors = @('mock Oracle reported a failure'); signals = [ordered]@{}; artifacts = [ordered]@{} }
            verdict_at = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }
    'invalid' {
        $verdict = [ordered]@{
            ok = $false
            fail_category = $null
            evidence = [ordered]@{ top_errors = @(); signals = [ordered]@{}; artifacts = [ordered]@{} }
            verdict_at = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }
    default { throw "Unsupported VERISOLVE_MOCK_ORACLE_MODE '$mode'." }
}

[Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                state = 'completed'
                verification_id = [string]$request.verification_id
                completed_at = [DateTimeOffset]::UtcNow.ToString('o')
                verdict = $verdict
            }) -Depth 20 -Compress))
