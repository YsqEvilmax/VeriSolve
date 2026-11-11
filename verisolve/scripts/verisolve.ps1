param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "VeriSolve CLI requires PowerShell 7 or later."
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot "core\VeriSolve.Core.psm1") -Force -DisableNameChecking
Invoke-VSCommand -Arguments $Arguments
