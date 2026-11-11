param(
    [Parameter(Mandatory)]
    [ValidateSet('append-events', 'read-log', 'write-snapshot')]
    [string]$Operation,
    [Parameter(Mandatory)]
    [string]$Path,
    [string]$PayloadPath
)

$ErrorActionPreference = 'Stop'
$resolvedPath = [IO.Path]::GetFullPath($Path)
$parent = Split-Path -Parent $resolvedPath
if (-not [IO.Directory]::Exists($parent)) {
    $null = [IO.Directory]::CreateDirectory($parent)
}

switch ($Operation) {
    'append-events' {
        $payloadJson = [IO.File]::ReadAllText([IO.Path]::GetFullPath($PayloadPath), [Text.Encoding]::UTF8)
        $payload = ConvertFrom-Json -InputObject $payloadJson
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($event in $payload) {
            $lines.Add((ConvertTo-Json -InputObject $event -Depth 100 -Compress))
        }
        if ($lines.Count -gt 0) {
            [IO.File]::AppendAllLines($resolvedPath, $lines, [Text.UTF8Encoding]::new($false))
        }
        [Console]::Out.Write("{`"appended`":$($lines.Count)}")
    }
    'read-log' {
        if ([IO.File]::Exists($resolvedPath)) {
            [Console]::Out.Write([IO.File]::ReadAllText($resolvedPath, [Text.Encoding]::UTF8))
        }
    }
    'write-snapshot' {
        $payloadJson = [IO.File]::ReadAllText([IO.Path]::GetFullPath($PayloadPath), [Text.Encoding]::UTF8)
        $temporaryPath = "$resolvedPath.$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllText($temporaryPath, $payloadJson, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $resolvedPath, $true)
        [Console]::Out.Write('{"published":true}')
    }
}
