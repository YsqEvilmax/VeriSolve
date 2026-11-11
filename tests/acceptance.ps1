param(
    [string[]]$Only = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\harness.ps1')
. (Join-Path $script:Root '.github\lib\vs-contracts.ps1')
. (Join-Path $script:Root '.github\lib\vs-filelock.ps1')
. (Join-Path $script:Root '.github\lib\vs-playbook.ps1')
. (Join-Path $script:Root '.github\lib\vs-schedule.ps1')

Write-Host "VeriSolve acceptance suite" -ForegroundColor White
Write-Host "repo: $($script:Root)"

$caseFiles = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'cases') -Filter '*.ps1' | Sort-Object Name
foreach ($caseFile in $caseFiles) {
    if ($Only.Count -gt 0 -and -not ($Only | Where-Object { $caseFile.Name -like "*$_*" })) { continue }
    . $caseFile.FullName
}

$ok = Write-VSReport
if (-not $ok) { exit 1 }
exit 0
