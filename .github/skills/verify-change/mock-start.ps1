# Example Oracle start fixture: triggers nothing and returns immediately with a verification id.
# VERISOLVE_MOCK_ORACLE_DELAY_MS simulates a slow external pipeline for latency assertions only.
$ErrorActionPreference = 'Stop'
$requestJson = [Console]::In.ReadToEnd()
$request = $requestJson | ConvertFrom-Json -AsHashtable

$delay = 0
if (-not [string]::IsNullOrWhiteSpace($env:VERISOLVE_MOCK_ORACLE_DELAY_MS)) { $delay = [int]$env:VERISOLVE_MOCK_ORACLE_DELAY_MS }
if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }

$key = [string]$request.idempotency_key
if ([string]::IsNullOrWhiteSpace($key)) { throw 'mock-start requires idempotency_key.' }
$hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))
$id = [Convert]::ToHexString($hash).ToLowerInvariant().Substring(0, 24)

$counterPath = $env:VERISOLVE_MOCK_ORACLE_COUNTER
if (-not [string]::IsNullOrWhiteSpace($counterPath)) {
    $current = if (Test-Path -LiteralPath $counterPath) { [int](Get-Content -LiteralPath $counterPath -Raw) } else { 0 }
    [IO.File]::WriteAllText($counterPath, [string]($current + 1), [Text.UTF8Encoding]::new($false))
}

[Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                verification_id = "mock-$id"
                started_at = [DateTimeOffset]::UtcNow.ToString('o')
            }) -Compress))
