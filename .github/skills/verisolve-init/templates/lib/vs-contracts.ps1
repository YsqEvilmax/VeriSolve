# VeriSolve contract and configuration primitives.
# Deterministic only: no inference, no verdict authorship, no orchestration.
# All bounds come from config/verisolve.*.json; nothing here is a tunable constant.

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'VeriSolve scripts require PowerShell 7 or later.'
}

$script:VSConfigFiles = [ordered]@{
    system         = 'config/verisolve.system.json'
    agents         = 'config/verisolve.agents.json'
    categories     = 'config/verisolve.categories.json'
    verification   = 'config/verisolve.verification.json'
    knowledge_base = 'config/verisolve.knowledge_base.json'
    cli            = 'config/verisolve.cli.json'
}

$script:VSBuiltinFailCategories = @(
    'pipeline_failed'
    'new_issue_introduced'
    'tests_failed'
    'coverage_dropped'
    'guardrail_rejected'
    'timeout'
    'oracle_error'
    'review_rejected'
    'unknown'
)

$script:VSInfraFailCategories = @('timeout', 'oracle_error')
$script:VSOpenContainers = @('raw', 'features', 'artifacts', 'metadata')

function Get-VSCodePointLength {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return 0 }
    $count = 0
    for ($i = 0; $i -lt $Value.Length; $i++) {
        if ([char]::IsLowSurrogate($Value[$i]) -and $i -gt 0 -and [char]::IsHighSurrogate($Value[$i - 1])) { continue }
        $count++
    }
    return $count
}

function Get-VSBuiltinFailCategories { return @($script:VSBuiltinFailCategories) }

function Get-VSInfraFailCategories { return @($script:VSInfraFailCategories) }

function Read-VSConfigSet {
    param([Parameter(Mandatory)][string]$GithubRoot)
    $set = [ordered]@{}
    foreach ($key in $script:VSConfigFiles.Keys) {
        $relative = ([string]$script:VSConfigFiles[$key]).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $path = Join-Path $GithubRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing VeriSolve config file: $path" }
        try {
            $set[$key] = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        } catch {
            throw "Invalid JSON in '$path': $($_.Exception.Message)"
        }
    }
    return $set
}

function Test-VSNumberOrNull {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [bool]) { return $false }
    if ($Value -is [string]) { return $false }
    if ($Value -is [double] -and ([double]::IsNaN($Value) -or [double]::IsInfinity($Value))) { return $false }
    if ($Value -is [single] -and ([single]::IsNaN($Value) -or [single]::IsInfinity($Value))) { return $false }
    return ($Value -is [ValueType])
}

function Test-VSDateTimeString {
    param([AllowNull()]$Value)
    # PowerShell 7.5+ converts ISO-8601 strings to DateTime while parsing JSON, so both forms are valid.
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) { return $true }
    if ($Value -isnot [string]) { return $false }
    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T') { return $false }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
}

function Test-VSHasOnlyKeys {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory)][string]$Label
    )
    foreach ($key in $Value.Keys) {
        if ($Allowed -cnotcontains [string]$key) { $Errors.Add("$Label has unexpected field '$key'.") }
    }
    foreach ($required in $Allowed) {
        if (-not $Value.Contains($required)) { $Errors.Add("$Label is missing field '$required'.") }
    }
}

function Test-VSStringBound {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][int]$Min,
        [Parameter(Mandatory)][int]$Max,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors
    )
    if ($Value -isnot [string]) { $Errors.Add("$Label must be a string."); return }
    $length = Get-VSCodePointLength $Value
    if ($length -lt $Min -or $length -gt $Max) {
        $Errors.Add("$Label must be $Min..$Max code points (actual $length).")
    }
}

function Test-VSProjectionSafety {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory)][string]$Label
    )
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($script:VSOpenContainers -ccontains [string]$key) {
                $Errors.Add("$Label must not contain open container '$key'.")
            }
            Test-VSProjectionSafety -Value $Value[$key] -Errors $Errors -Label $Label
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary]) {
        foreach ($item in $Value) { Test-VSProjectionSafety -Value $item -Errors $Errors -Label $Label }
    }
}

function New-VSResult {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors)
    return [pscustomobject]@{ valid = ($Errors.Count -eq 0); errors = @($Errors) }
}

function Assert-VSConfigSet {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $v = $Config.verification
    if ($null -eq $v) { throw 'verisolve.verification.json is missing.' }

    $nonNegative = @(
        'problem_id_max_length', 'change_id_max_length', 'top_errors_max_count',
        'change_summary_max_length', 'retry_summary_max_length',
        'resolver_context_summary_max_length', 'playbook_solution_summary_min_length',
        'playbook_solution_summary_max_length', 'change_diff_max_length',
        'change_targets_min_count', 'change_targets_max_count',
        'signature_keywords_min_count', 'signature_keywords_max_count',
        'signature_keyword_max_length', 'max_playbook_try', 'check_batch_limit'
    )
    foreach ($key in $nonNegative) {
        if ($null -eq $v[$key]) { throw "verisolve.verification.json#$key is required." }
        if ([int]$v[$key] -lt 0) { throw "verisolve.verification.json#$key must be non-negative." }
    }
    if ([int]$v.playbook_solution_summary_min_length -gt [int]$v.playbook_solution_summary_max_length) {
        throw 'playbook_solution_summary_min_length must not exceed playbook_solution_summary_max_length.'
    }
    if ([int]$v.change_targets_min_count -lt 1) { throw 'change_targets_min_count must be at least 1.' }
    if ([int]$v.change_targets_min_count -gt [int]$v.change_targets_max_count) { throw 'change_targets_min_count must not exceed change_targets_max_count.' }
    if ([int]$v.signature_keywords_min_count -gt [int]$v.signature_keywords_max_count) { throw 'signature_keywords_min_count must not exceed signature_keywords_max_count.' }

    $severity = @($v.severity_values)
    foreach ($expected in @('critical', 'high', 'medium', 'low')) {
        if ($severity -cnotcontains $expected) { throw "severity_values must contain '$expected'." }
    }

    $builtin = @($v.fail_categories)
    foreach ($expected in $script:VSBuiltinFailCategories) {
        if ($builtin -cnotcontains $expected) { throw "fail_categories must preserve built-in value '$expected'." }
    }
    if ([int]$v.additional_fail_category_max_length -gt 64) {
        throw 'additional_fail_category_max_length must not exceed 64.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$v.additional_fail_category_pattern)) {
        throw 'additional_fail_category_pattern is required.'
    }
    try { $null = [regex]::new([string]$v.additional_fail_category_pattern) }
    catch { throw "additional_fail_category_pattern is not a valid regex: $($_.Exception.Message)" }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidate in @($v.additional_fail_categories)) {
        if ($candidate -isnot [string]) { throw 'additional_fail_categories entries must be strings.' }
        $length = Get-VSCodePointLength $candidate
        if ($length -lt 1 -or $length -gt [int]$v.additional_fail_category_max_length) {
            throw "additional fail_category '$candidate' must be 1..$($v.additional_fail_category_max_length) characters."
        }
        if ($candidate -cnotmatch [string]$v.additional_fail_category_pattern) {
            throw "additional fail_category '$candidate' violates $($v.additional_fail_category_pattern)."
        }
        if ($script:VSBuiltinFailCategories -ccontains $candidate) {
            throw "additional fail_category '$candidate' conflicts with a built-in value."
        }
        if (-not $seen.Add($candidate)) { throw "additional fail_category '$candidate' is duplicated." }
    }

    $domain = @($Config.categories.category_values)
    foreach ($expected in @('bug', 'incident', 'maintenance', 'other')) {
        if ($domain -cnotcontains $expected) { throw "category_values must contain '$expected'." }
    }
    if ([string]::IsNullOrWhiteSpace([string]$v.high_risk_categories_default)) {
        throw 'high_risk_categories_default is required.'
    }
    $null = Get-VSHighRiskCategories -Config $Config

    $guardrails = $v.guardrails
    if ($null -eq $guardrails) { throw 'verisolve.verification.json#guardrails is required.' }
    foreach ($key in @('max_patch_files', 'max_patch_bytes', 'max_patch_lines')) {
        if ($null -eq $guardrails[$key] -or [int]$guardrails[$key] -lt 0) { throw "guardrails.$key must be a non-negative integer." }
    }
    foreach ($key in @('forbidden_targets', 'forbidden_patterns')) {
        if ($guardrails[$key] -isnot [System.Collections.IList]) { throw "guardrails.$key must be an array." }
    }
    foreach ($pattern in @($guardrails.forbidden_patterns)) {
        try { $null = [regex]::new([string]$pattern) }
        catch { throw "guardrails.forbidden_patterns entry '$pattern' is not a valid regex." }
    }

    if ($null -eq $Config.knowledge_base) { throw 'verisolve.knowledge_base.json is missing.' }
    foreach ($key in @('embedding_weight', 'feature_weight', 'confidence_weight')) {
        if ($null -eq $Config.knowledge_base[$key]) { throw "knowledge_base.$key is required." }
    }
    $weightSum = [double]$Config.knowledge_base.embedding_weight + [double]$Config.knowledge_base.feature_weight + [double]$Config.knowledge_base.confidence_weight
    if ([Math]::Abs($weightSum - 1.0) -gt 0.0001) { throw "knowledge_base scoring weights must sum to 1.0 (actual $weightSum)." }
    if ([double]$Config.knowledge_base.low_conf_threshold -lt 0 -or [double]$Config.knowledge_base.low_conf_threshold -gt 1) {
        throw 'knowledge_base.low_conf_threshold must be within 0..1.'
    }

    if ($null -eq $Config.system) { throw 'verisolve.system.json is missing.' }
    foreach ($key in @('retry_per_bug', 'infra_retry', 'file_lock_timeout_seconds', 'file_lock_poll_interval_ms')) {
        if ($null -eq $Config.system[$key] -or [int]$Config.system[$key] -lt 0) { throw "system.$key must be a non-negative integer." }
    }
}

function Get-VSHighRiskCategories {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $v = $Config.verification
    $domain = @($Config.categories.category_values)
    $defaultValue = [string]$v.high_risk_categories_default
    $raw = [string]$v.high_risk_categories
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $defaultValue }
    $items = @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    if ($items.Count -eq 0) { $items = @($defaultValue) }
    foreach ($item in $items) {
        if ($domain -cnotcontains $item) {
            throw "high_risk_categories value '$item' is outside the controlled domain $($domain -join '|')."
        }
    }
    $unique = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $items) { if (-not $unique.Contains($item)) { $unique.Add($item) } }
    return @($unique)
}

function Test-VSHighRisk {
    param(
        [AllowNull()][AllowEmptyString()][string]$TriageCategory,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$HighRiskCategories,
        [Parameter(Mandatory)][string[]]$Domain
    )
    if ([string]::IsNullOrWhiteSpace($TriageCategory)) {
        return [pscustomobject]@{ is_high_risk = $false; warning = 'triage_category_null: treated as non-high-risk' }
    }
    if ($Domain -cnotcontains $TriageCategory) {
        return [pscustomobject]@{ is_high_risk = $false; warning = "triage_category_out_of_domain:$TriageCategory" }
    }
    return [pscustomobject]@{ is_high_risk = ($HighRiskCategories -ccontains $TriageCategory); warning = $null }
}

function Get-VSFailCategoryAllowList {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $v = $Config.verification
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($v.fail_categories)) { $all.Add([string]$item) }
    foreach ($item in @($v.additional_fail_categories)) { $all.Add([string]$item) }
    return @($all)
}

function Test-VSProblem {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Value -isnot [System.Collections.IDictionary]) {
        $errors.Add('VSProblem must be an object.')
        return New-VSResult $errors
    }
    $v = $Config.verification
    Test-VSHasOnlyKeys $Value @('problem_id', 'source', 'raw', 'category', 'severity', 'priority_score', 'signature', 'created_at', 'metadata') $errors 'VSProblem'

    Test-VSStringBound $Value.problem_id 1 ([int]$v.problem_id_max_length) 'problem_id' $errors
    if ($Value.source -isnot [string] -or [string]::IsNullOrEmpty([string]$Value.source)) { $errors.Add('source must be a non-empty string.') }
    if ($Value.raw -isnot [System.Collections.IDictionary]) { $errors.Add('raw must be an object.') }
    if ($null -ne $Value.category -and $Value.category -isnot [string]) { $errors.Add('category must be a string or null.') }
    if ($null -ne $Value.severity -and @($v.severity_values) -cnotcontains [string]$Value.severity) {
        $errors.Add("severity must be one of $((@($v.severity_values)) -join '|') or null.")
    }
    if (-not (Test-VSNumberOrNull $Value.priority_score)) { $errors.Add('priority_score must be a finite number or null.') }

    $signature = $Value.signature
    if ($signature -isnot [System.Collections.IDictionary]) {
        $errors.Add('signature must be an object.')
    } else {
        Test-VSHasOnlyKeys $signature @('keywords', 'features', 'location') $errors 'signature'
        $keywords = $signature.keywords
        if ($keywords -isnot [System.Collections.IList]) {
            $errors.Add('signature.keywords must be an array.')
        } else {
            $count = @($keywords).Count
            if ($count -lt [int]$v.signature_keywords_min_count -or $count -gt [int]$v.signature_keywords_max_count) {
                $errors.Add("signature.keywords must contain $($v.signature_keywords_min_count)..$($v.signature_keywords_max_count) items (actual $count).")
            }
            foreach ($keyword in @($keywords)) {
                if ($keyword -isnot [string]) { $errors.Add('signature.keywords entries must be strings.'); continue }
                $length = Get-VSCodePointLength $keyword
                if ($length -gt [int]$v.signature_keyword_max_length) {
                    $errors.Add("signature keyword must be at most $($v.signature_keyword_max_length) code points (actual $length).")
                }
            }
        }
        if ($signature.features -isnot [System.Collections.IDictionary]) { $errors.Add('signature.features must be an object.') }
        if ($null -ne $signature.location -and $signature.location -isnot [string]) { $errors.Add('signature.location must be a string or null.') }
    }
    if (-not (Test-VSDateTimeString $Value.created_at)) { $errors.Add('created_at must be an ISO-8601 date-time string.') }
    if ($Value.metadata -isnot [System.Collections.IDictionary]) { $errors.Add('metadata must be an object.') }
    return New-VSResult $errors
}

function Test-VSVerdict {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Value -isnot [System.Collections.IDictionary]) {
        $errors.Add('VSVerdict must be an object.')
        return New-VSResult $errors
    }
    $v = $Config.verification
    Test-VSHasOnlyKeys $Value @('ok', 'fail_category', 'evidence', 'verdict_at') $errors 'VSVerdict'
    if ($Value.ok -isnot [bool]) { $errors.Add('ok must be a boolean.') }

    $allowList = Get-VSFailCategoryAllowList $Config
    $failCategory = $Value.fail_category
    if ($null -ne $failCategory) {
        if ($failCategory -isnot [string]) {
            $errors.Add('fail_category must be a string or null.')
        } elseif ($allowList -cnotcontains $failCategory) {
            $errors.Add("fail_category '$failCategory' is not an allowed enum value (matching is case-sensitive).")
        }
    }
    if ($Value.ok -eq $false -and $null -eq $failCategory) {
        $errors.Add('fail_category is required when ok is false.')
    }

    $evidence = $Value.evidence
    if ($evidence -isnot [System.Collections.IDictionary]) {
        $errors.Add('evidence must be an object.')
    } else {
        Test-VSHasOnlyKeys $evidence @('top_errors', 'signals', 'artifacts') $errors 'evidence'
        $topErrors = $evidence.top_errors
        if ($topErrors -isnot [System.Collections.IList]) {
            $errors.Add('evidence.top_errors must be an array.')
        } else {
            $count = @($topErrors).Count
            if ($count -gt [int]$v.top_errors_max_count) {
                $errors.Add("evidence.top_errors must contain at most $($v.top_errors_max_count) items (actual $count).")
            }
            foreach ($item in @($topErrors)) {
                if ($item -isnot [string]) { $errors.Add('evidence.top_errors entries must be strings.') }
            }
        }
        if ($evidence.signals -isnot [System.Collections.IDictionary]) {
            $errors.Add('evidence.signals must be an object.')
        } else {
            foreach ($key in $evidence.signals.Keys) {
                if ($evidence.signals[$key] -isnot [bool]) { $errors.Add("evidence.signals.$key must be a boolean.") }
            }
        }
        if ($evidence.artifacts -isnot [System.Collections.IDictionary]) { $errors.Add('evidence.artifacts must be an object.') }
    }
    if (-not (Test-VSDateTimeString $Value.verdict_at)) { $errors.Add('verdict_at must be an ISO-8601 date-time string.') }
    return New-VSResult $errors
}

function Test-VSChange {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Value -isnot [System.Collections.IDictionary]) {
        $errors.Add('VSChange must be an object.')
        return New-VSResult $errors
    }
    $v = $Config.verification
    Test-VSHasOnlyKeys $Value @('change_id', 'problem_id', 'diff', 'summary', 'targets', 'playbook_ref', 'change_at') $errors 'VSChange'
    Test-VSStringBound $Value.change_id 1 ([int]$v.change_id_max_length) 'change_id' $errors
    Test-VSStringBound $Value.problem_id 1 ([int]$v.problem_id_max_length) 'problem_id' $errors
    Test-VSStringBound $Value.diff 1 ([int]$v.change_diff_max_length) 'diff' $errors
    Test-VSStringBound $Value.summary 1 ([int]$v.change_summary_max_length) 'summary' $errors

    $targets = $Value.targets
    if ($targets -isnot [System.Collections.IList]) {
        $errors.Add('targets must be an array.')
    } else {
        $count = @($targets).Count
        if ($count -lt [int]$v.change_targets_min_count -or $count -gt [int]$v.change_targets_max_count) {
            $errors.Add("targets must contain $($v.change_targets_min_count)..$($v.change_targets_max_count) items (actual $count).")
        }
        foreach ($target in @($targets)) {
            if ($target -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$target)) { $errors.Add('targets entries must be non-empty strings.') }
        }
    }
    if ($null -ne $Value.playbook_ref -and $Value.playbook_ref -isnot [string]) { $errors.Add('playbook_ref must be a string or null.') }
    if (-not (Test-VSDateTimeString $Value.change_at)) { $errors.Add('change_at must be an ISO-8601 date-time string.') }
    return New-VSResult $errors
}

function Test-VSTriageOutput {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Value -isnot [System.Collections.IDictionary]) {
        $errors.Add('TriageAgent output must be a JSON object.')
        return New-VSResult $errors
    }
    Test-VSHasOnlyKeys $Value @('category', 'severity', 'keywords') $errors 'TriageAgent output'
    $domain = @($Config.categories.category_values)
    if ($Value.category -isnot [string] -or $domain -cnotcontains [string]$Value.category) {
        $errors.Add("category must be exactly one of $($domain -join '|').")
    }
    $v = $Config.verification
    if ($null -ne $Value.severity -and @($v.severity_values) -cnotcontains [string]$Value.severity) {
        $errors.Add("severity must be one of $((@($v.severity_values)) -join '|') or null.")
    }
    $agentsConfig = $Config.agents.triage
    $keywords = $Value.keywords
    if ($keywords -isnot [System.Collections.IList]) {
        $errors.Add('keywords must be an array.')
    } else {
        $count = @($keywords).Count
        if ($count -gt [int]$agentsConfig.max_keywords) { $errors.Add("keywords must contain at most $($agentsConfig.max_keywords) items (actual $count).") }
        foreach ($keyword in @($keywords)) {
            if ($keyword -isnot [string]) { $errors.Add('keywords entries must be strings.'); continue }
            $length = Get-VSCodePointLength $keyword
            if ($length -gt [int]$agentsConfig.max_keyword_length) {
                $errors.Add("keyword must be at most $($agentsConfig.max_keyword_length) code points (actual $length).")
            }
        }
    }
    return New-VSResult $errors
}

function Test-VSResolverProjection {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [ValidateSet('resolve', 'review')][string]$Mode = 'resolve'
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Value -isnot [System.Collections.IDictionary]) {
        $errors.Add('Resolver projection must be an object.')
        return New-VSResult $errors
    }
    $v = $Config.verification
    $agentsConfig = $Config.agents.resolver
    Test-VSProjectionSafety -Value $Value -Errors $errors -Label 'Resolver projection'
    if ($Mode -eq 'review') {
        Test-VSHasOnlyKeys $Value @('diff', 'acceptance_criteria') $errors 'Resolver review projection'
        Test-VSStringBound $Value.diff 1 ([int]$v.change_diff_max_length) 'review diff' $errors
        Test-VSStringBound $Value.acceptance_criteria 0 ([int]$agentsConfig.review_acceptance_criteria_max_length) 'acceptance_criteria' $errors
        return New-VSResult $errors
    }

    $allowed = @('problem_id', 'category', 'severity', 'keywords', 'summary', 'previous_summary', 'fail_category', 'top_errors', 'pattern_id', 'solution_summary')
    foreach ($key in $Value.Keys) {
        if ($allowed -cnotcontains [string]$key) { $errors.Add("Resolver projection has unexpected field '$key'.") }
    }
    if ($Value.Contains('problem_id')) { Test-VSStringBound $Value.problem_id 1 ([int]$v.problem_id_max_length) 'problem_id' $errors }
    if ($Value.Contains('summary') -and $null -ne $Value.summary) {
        Test-VSStringBound $Value.summary 0 ([int]$v.resolver_context_summary_max_length) 'summary' $errors
    }
    if ($Value.Contains('previous_summary') -and $null -ne $Value.previous_summary) {
        Test-VSStringBound $Value.previous_summary 1 ([int]$v.retry_summary_max_length) 'previous_summary' $errors
    }
    if ($Value.Contains('solution_summary') -and $null -ne $Value.solution_summary) {
        Test-VSStringBound $Value.solution_summary ([int]$v.playbook_solution_summary_min_length) ([int]$v.playbook_solution_summary_max_length) 'solution_summary' $errors
    }
    if ($Value.Contains('fail_category')) {
        $allowList = Get-VSFailCategoryAllowList $Config
        if ($Value.fail_category -isnot [string] -or $allowList -cnotcontains [string]$Value.fail_category) {
            $errors.Add('Retry feedback fail_category must be an allowed enum value.')
        }
    }
    if ($Value.Contains('top_errors')) {
        if ($Value.top_errors -isnot [System.Collections.IList]) {
            $errors.Add('top_errors must be an array.')
        } elseif (@($Value.top_errors).Count -gt [int]$v.top_errors_max_count) {
            $errors.Add("top_errors must contain at most $($v.top_errors_max_count) items (actual $(@($Value.top_errors).Count)).")
        }
    }
    return New-VSResult $errors
}
