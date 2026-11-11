param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\lib\vs-contracts.ps1')
$github = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Read-VSConfigSet -GithubRoot $github
Assert-VSConfigSet -Config $config
$request = Get-Content -LiteralPath ([IO.Path]::GetFullPath($RequestPath)) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable

function ConvertTo-VSGlobRegex {
    param([Parameter(Mandatory)][string]$Pattern)
    $builder = [Text.StringBuilder]::new('^')
    for ($i = 0; $i -lt $Pattern.Length; $i++) {
        $character = $Pattern[$i]
        if ($character -eq '*') {
            if ($i + 1 -lt $Pattern.Length -and $Pattern[$i + 1] -eq '*') {
                $null = $builder.Append('.*')
                $i++
            } else {
                $null = $builder.Append('[^/\\]*')
            }
        } elseif ($character -eq '?') {
            $null = $builder.Append('[^/\\]')
        } elseif ($character -eq '/') {
            $null = $builder.Append('[\\/]')
        } else {
            $null = $builder.Append([regex]::Escape([string]$character))
        }
    }
    $null = $builder.Append('$')
    return [regex]::new(
        $builder.ToString(),
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
}

function Test-VSTargetForbidden {
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ForbiddenTargets)
    $normalized = $Target.Replace('\', '/')
    foreach ($pattern in $ForbiddenTargets) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $candidates = @($pattern)
        if ($pattern.EndsWith('/**')) { $candidates += $pattern.Substring(0, $pattern.Length - 3) }
        foreach ($candidate in $candidates) {
            if ((ConvertTo-VSGlobRegex -Pattern $candidate).IsMatch($normalized)) { return $pattern }
        }
    }
    return $null
}

$result = [ordered]@{
    accepted = $false
    fail_category = 'guardrail_rejected'
    reasons = @()
    metrics = [ordered]@{ target_count = 0; diff_bytes = 0; diff_lines = 0 }
}

$change = $request.change
$guardrails = $request.guardrails
if ($guardrails -isnot [System.Collections.IDictionary]) {
    $result.reasons = @('Request must include the guardrails object copied from config/verisolve.verification.json#guardrails.')
    [Console]::Out.Write((ConvertTo-Json -InputObject $result -Depth 20 -Compress))
    exit 0
}
$contract = Test-VSChange -Value $change -Config $config
if (-not $contract.valid) {
    $result.reasons = @($contract.errors | ForEach-Object { "contract: $_" })
    [Console]::Out.Write((ConvertTo-Json -InputObject $result -Depth 20 -Compress))
    exit 0
}

$reasons = [System.Collections.Generic.List[string]]::new()
$targets = @($change.targets)
$diff = [string]$change.diff
$lineCount = if ($diff.Length -eq 0) { 0 } else { ([regex]::Matches($diff, "`n")).Count + 1 }
$byteCount = [Text.Encoding]::UTF8.GetByteCount($diff)
$result.metrics = [ordered]@{ target_count = $targets.Count; diff_bytes = $byteCount; diff_lines = $lineCount }

foreach ($target in $targets) {
    $hit = Test-VSTargetForbidden -Target ([string]$target) -ForbiddenTargets @($guardrails.forbidden_targets)
    if ($null -ne $hit) { $reasons.Add("forbidden_target: '$target' matches '$hit'.") }
}
foreach ($pattern in @($guardrails.forbidden_patterns)) {
    if ([string]::IsNullOrWhiteSpace([string]$pattern)) { continue }
    $regex = [regex]::new([string]$pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($regex.IsMatch($diff)) { $reasons.Add("forbidden_pattern: diff matches '$pattern'.") }
}
if ($targets.Count -gt [int]$guardrails.max_patch_files) {
    $reasons.Add("patch_files: $($targets.Count) exceeds max_patch_files $($guardrails.max_patch_files).")
}
if ($lineCount -gt [int]$guardrails.max_patch_lines) {
    $reasons.Add("patch_lines: $lineCount exceeds max_patch_lines $($guardrails.max_patch_lines).")
}
if ($byteCount -gt [int]$guardrails.max_patch_bytes) {
    $reasons.Add("patch_bytes: $byteCount exceeds max_patch_bytes $($guardrails.max_patch_bytes).")
}

$result.reasons = @($reasons)
$result.accepted = ($reasons.Count -eq 0)
if ($result.accepted) { $result.fail_category = $null }
[Console]::Out.Write((ConvertTo-Json -InputObject $result -Depth 20 -Compress))
