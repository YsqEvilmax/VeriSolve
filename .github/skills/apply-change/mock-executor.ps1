# Example executor fixture: idempotent apply/revert transport with an optional call counter.
# Replace it by configuring executor.apply / executor.revert in config/verisolve.cli.json.
$ErrorActionPreference = 'Stop'
$requestJson = [Console]::In.ReadToEnd()
$request = $requestJson | ConvertFrom-Json -AsHashtable
if (@('apply', 'revert') -cnotcontains [string]$request.operation) { throw "Unsupported operation '$($request.operation)'." }
if ([string]::IsNullOrWhiteSpace([string]$request.idempotency_key)) { throw 'idempotency_key is required.' }

$counterPath = $env:VERISOLVE_MOCK_EXECUTOR_COUNTER
if (-not [string]::IsNullOrWhiteSpace($counterPath)) {
    $line = "$($request.operation)|$($request.idempotency_key)" + [Environment]::NewLine
    [IO.File]::AppendAllText($counterPath, $line, [Text.UTF8Encoding]::new($false))
}

if ([string]$request.operation -ceq 'apply') {
    [Console]::Out.Write('{"ok":true}')
} else {
    [Console]::Out.Write('{"reverted":true}')
}
