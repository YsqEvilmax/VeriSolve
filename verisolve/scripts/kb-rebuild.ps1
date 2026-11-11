param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"
if ($Arguments.Count -eq 0) {
    & (Join-Path $PSScriptRoot "verisolve.ps1") kb rebuild
}
else {
    & (Join-Path $PSScriptRoot "verisolve.ps1") kb @Arguments
}
