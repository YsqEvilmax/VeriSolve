param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"
& (Join-Path $PSScriptRoot "verisolve.ps1") kb query @Arguments
