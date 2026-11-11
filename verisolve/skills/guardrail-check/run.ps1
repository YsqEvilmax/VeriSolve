param(
    [Parameter(Mandatory)]
    [string]$RequestPath
)

$ErrorActionPreference = 'Stop'
$RequestJson = [IO.File]::ReadAllText([IO.Path]::GetFullPath($RequestPath), [Text.Encoding]::UTF8)
$null = ConvertFrom-Json -InputObject $RequestJson
[Console]::Out.Write($RequestJson)
