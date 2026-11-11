Set-StrictMode -Version Latest

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:PlaybookSnapshot = [System.Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new([System.Collections.Generic.Dictionary[string, object]]::new())
$script:PlaybookVersion = 0
$script:PlaybookQueue = $null
$script:PlaybookWorker = $null
$script:PlaybookWorkerPowerShell = $null
$script:PlaybookLogPath = $null
$script:PlaybookConfig = $null
$script:ContractConfig = $null
$script:PlaybookLastReadThreadId = $null
$script:PlaybookLastReadElapsedMilliseconds = $null

function Get-VSCodePointCount {
    param([Parameter(Mandatory)][string]$Value)
    $count = 0
    foreach ($rune in $Value.EnumerateRunes()) {
        $count++
    }
    return $count
}

function Assert-VSExactFields {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Fields,
        [Parameter(Mandatory)][string]$Name
    )
    $missing = @($Fields | Where-Object { -not $Value.Contains($_) })
    $extra = @($Value.Keys | Where-Object { $_ -notin $Fields })
    if ($missing.Count -or $extra.Count) {
        throw "$Name fields mismatch; missing=[$($missing -join ',')], unexpected=[$($extra -join ',')]"
    }
}

function Assert-VSIdentifier {
    param([Parameter(Mandatory)][object]$Value, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Maximum)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or (Get-VSCodePointCount $Value) -gt $Maximum) {
        throw "$Name must be a non-empty string of at most $Maximum characters"
    }
}

function Get-VSVerificationConfig {
    param([string]$Path = (Join-Path $script:ProjectRoot 'config\verisolve.verification.json'))
    $config = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    Assert-VSExactFields $config @('problem_id_max_length', 'change_id_max_length', 'top_errors_max_count', 'change_summary_max_length', 'retry_summary_max_length', 'resolver_context_summary_max_length', 'playbook_solution_summary_max_length', 'change_diff_max_length', 'change_targets_min_count', 'change_targets_max_count', 'signature_keywords_min_count', 'signature_keywords_max_count', 'signature_keyword_max_length', 'severity_values', 'fail_categories', 'additional_fail_categories', 'high_risk_categories', 'max_playbook_try', 'oracle_timeout_seconds', 'oracle_poll_interval_seconds', 'guardrails', 'signals', 'triage') 'verification config'
    $expectedLimits = @{
        problem_id_max_length = 128
        change_id_max_length = 128
        top_errors_max_count = 3
        change_summary_max_length = 200
        retry_summary_max_length = 200
        resolver_context_summary_max_length = 200
        playbook_solution_summary_max_length = 300
        change_diff_max_length = 100000
        change_targets_min_count = 1
        change_targets_max_count = 50
        signature_keywords_min_count = 0
        signature_keywords_max_count = 20
        signature_keyword_max_length = 64
    }
    foreach ($name in $expectedLimits.Keys) {
        if ($config[$name] -is [bool] -or $config[$name] -isnot [ValueType] -or [double]$config[$name] -ne $expectedLimits[$name]) {
            throw "$name must remain $($expectedLimits[$name])"
        }
    }
    $builtInFailures = @('pipeline_failed', 'new_issue_introduced', 'tests_failed', 'coverage_dropped', 'guardrail_rejected', 'timeout', 'oracle_error', 'review_rejected', 'unknown')
    if (@($config.fail_categories) -cnotcontains $builtInFailures[0] -or (@($config.fail_categories) -join "`n") -cne ($builtInFailures -join "`n")) {
        throw 'Built-in fail_categories cannot be removed, reordered, or changed'
    }
    if (@($config.severity_values) -join "`n" -cne "critical`nhigh`nmedium`nlow") { throw 'severity_values cannot be removed, reordered, or changed' }
    Assert-VSExactFields $config.guardrails @('max_patch_files', 'max_patch_bytes', 'max_patch_lines', 'forbidden_targets', 'forbidden_patterns') 'guardrails config'
    Assert-VSExactFields $config.signals @('top_errors_max_count') 'signals config'
    Assert-VSExactFields $config.triage @('prompt_ref', 'max_parallel_triage', 'playbook_top_k', 'playbook_min_score') 'triage config'
    if ([int]$config.signals.top_errors_max_count -ne [int]$config.top_errors_max_count) { throw 'signals.top_errors_max_count must match the evidence contract' }
    if ([int]$config.max_playbook_try -lt 0 -or [double]$config.oracle_timeout_seconds -le 0 -or [double]$config.oracle_poll_interval_seconds -le 0) { throw 'Verification retry and Oracle settings must be positive or zero as defined' }
    if ([int]$config.triage.max_parallel_triage -lt 1 -or [int]$config.triage.playbook_top_k -lt 1 -or [double]$config.triage.playbook_min_score -lt 0 -or [double]$config.triage.playbook_min_score -gt 1) { throw 'Triage settings are outside allowed bounds' }
    foreach ($limit in @('max_patch_files', 'max_patch_bytes', 'max_patch_lines')) { if ([int]$config.guardrails[$limit] -lt 0) { throw "$limit must be non-negative" } }
    foreach ($field in @('forbidden_targets', 'forbidden_patterns')) { if ($config.guardrails[$field] -isnot [System.Collections.IList] -or @($config.guardrails[$field] | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count) { throw "$field must be an array of non-empty strings" } }
    $additional = @($config.additional_fail_categories)
    if (($additional | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) -or $_ -cin $builtInFailures } | Measure-Object).Count -gt 0 -or @($additional | Select-Object -Unique).Count -ne $additional.Count) {
        throw 'additional_fail_categories may only append unique non-empty values'
    }
    $script:ContractConfig = $config
    return $config
}

function Get-VSAllowedFailCategories {
    if ($null -eq $script:ContractConfig) { $null = Get-VSVerificationConfig }
    return @($script:ContractConfig.fail_categories) + @($script:ContractConfig.additional_fail_categories)
}

function Assert-VSDateTime {
    param([Parameter(Mandatory)][object]$Value, [Parameter(Mandatory)][string]$Name)
    if ($Value -is [DateTimeOffset]) { $Value = $Value.ToString('o') }
    elseif ($Value -is [DateTime]) { $Value = ([DateTimeOffset]$Value).ToString('o') }
    if ($Value -isnot [string]) { throw "$Name must be an ISO-8601 timestamp" }
    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$') { throw "$Name must be an ISO-8601 timestamp" }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [ref]$parsed)) { throw "$Name must be an ISO-8601 timestamp" }
}

function New-VSProblem {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Value)
    if ($null -eq $script:ContractConfig) { $null = Get-VSVerificationConfig }
    Assert-VSExactFields $Value @('problem_id', 'source', 'raw', 'category', 'severity', 'priority_score', 'signature', 'created_at', 'metadata') 'VSProblem'
    Assert-VSIdentifier $Value.problem_id 'problem_id' $script:ContractConfig.problem_id_max_length
    if ($Value.source -isnot [string] -or [string]::IsNullOrWhiteSpace($Value.source)) { throw 'source must be a non-empty string' }
    if ($null -ne $Value.category -and $Value.category -isnot [string]) { throw 'category must be a string or null' }
    if ($null -ne $Value.severity -and $Value.severity -cnotin @('critical', 'high', 'medium', 'low')) { throw 'severity must be critical, high, medium, low, or null' }
    if ($null -ne $Value.priority_score -and ($Value.priority_score -isnot [ValueType] -or $Value.priority_score -is [bool] -or [double]::IsNaN([double]$Value.priority_score) -or [double]::IsInfinity([double]$Value.priority_score))) { throw 'priority_score must be a finite number or null' }
    foreach ($field in @('raw', 'metadata', 'signature')) { if ($Value[$field] -isnot [System.Collections.IDictionary]) { throw "$field must be an object" } }
    Assert-VSExactFields $Value.signature @('keywords', 'features', 'location') 'signature'
    if ($Value.signature.keywords -isnot [System.Collections.IList]) { throw 'signature.keywords must be an array' }
    if ($Value.signature.keywords.Count -gt $script:ContractConfig.signature_keywords_max_count) { throw 'signature.keywords exceeds configured maximum' }
    foreach ($keyword in $Value.signature.keywords) {
        if ($keyword -isnot [string] -or (Get-VSCodePointCount $keyword) -gt $script:ContractConfig.signature_keyword_max_length) { throw 'signature keyword must be a string of at most configured length' }
    }
    if ($Value.signature.features -isnot [System.Collections.IDictionary]) { throw 'signature.features must be an object' }
    if ($null -ne $Value.signature.location -and $Value.signature.location -isnot [string]) { throw 'signature.location must be a string or null' }
    if ($Value.created_at -is [DateTimeOffset]) { $Value.created_at = $Value.created_at.ToString('o') }
    elseif ($Value.created_at -is [DateTime]) { $Value.created_at = ([DateTimeOffset]$Value.created_at).ToString('o') }
    Assert-VSDateTime $Value.created_at 'created_at'
    return $Value
}

function New-VSVerdict {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Value)
    if ($null -eq $script:ContractConfig) { $null = Get-VSVerificationConfig }
    Assert-VSExactFields $Value @('ok', 'fail_category', 'evidence', 'verdict_at') 'VSVerdict'
    if ($Value.ok -isnot [bool]) { throw 'ok must be a boolean' }
    if ($Value.ok) {
        if ($null -ne $Value.fail_category -and $Value.fail_category -cnotin (Get-VSAllowedFailCategories)) { throw 'fail_category is not an allowed enum value' }
    } elseif ($null -eq $Value.fail_category -or $Value.fail_category -cnotin (Get-VSAllowedFailCategories)) {
        throw 'failed verdict requires an allowed fail_category'
    }
    if ($Value.evidence -isnot [System.Collections.IDictionary]) { throw 'evidence must be an object' }
    Assert-VSExactFields $Value.evidence @('top_errors', 'signals', 'artifacts') 'evidence'
    if ($Value.evidence.top_errors -isnot [System.Collections.IList] -or $Value.evidence.top_errors.Count -gt $script:ContractConfig.top_errors_max_count) { throw 'evidence.top_errors must contain at most configured maximum entries' }
    if (@($Value.evidence.top_errors | Where-Object { $_ -isnot [string] }).Count) { throw 'evidence.top_errors entries must be strings' }
    if ($Value.evidence.signals -isnot [System.Collections.IDictionary] -or $Value.evidence.artifacts -isnot [System.Collections.IDictionary]) { throw 'evidence.signals and evidence.artifacts must be objects' }
    if (@($Value.evidence.signals.Values | Where-Object { $_ -isnot [bool] }).Count) { throw 'evidence.signals values must be booleans' }
    if ($Value.verdict_at -is [DateTimeOffset]) { $Value.verdict_at = $Value.verdict_at.ToString('o') }
    elseif ($Value.verdict_at -is [DateTime]) { $Value.verdict_at = ([DateTimeOffset]$Value.verdict_at).ToString('o') }
    Assert-VSDateTime $Value.verdict_at 'verdict_at'
    return $Value
}

function New-VSChange {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Value)
    if ($null -eq $script:ContractConfig) { $null = Get-VSVerificationConfig }
    Assert-VSExactFields $Value @('change_id', 'problem_id', 'diff', 'summary', 'targets', 'playbook_ref', 'change_at') 'VSChange'
    Assert-VSIdentifier $Value.change_id 'change_id' $script:ContractConfig.change_id_max_length
    Assert-VSIdentifier $Value.problem_id 'problem_id' $script:ContractConfig.problem_id_max_length
    if ($Value.diff -isnot [string] -or [string]::IsNullOrEmpty($Value.diff) -or (Get-VSCodePointCount $Value.diff) -gt $script:ContractConfig.change_diff_max_length) { throw 'diff must contain 1..configured maximum characters' }
    if ($Value.summary -isnot [string] -or [string]::IsNullOrEmpty($Value.summary) -or (Get-VSCodePointCount $Value.summary) -gt $script:ContractConfig.change_summary_max_length) { throw 'summary must contain 1..configured maximum characters' }
    if ($Value.targets -isnot [System.Collections.IList] -or $Value.targets.Count -lt $script:ContractConfig.change_targets_min_count -or $Value.targets.Count -gt $script:ContractConfig.change_targets_max_count) { throw 'targets count is outside configured bounds' }
    if (@($Value.targets | Where-Object { $_ -isnot [string] -or [string]::IsNullOrEmpty($_) }).Count) { throw 'targets must contain non-empty strings' }
    if ($null -ne $Value.playbook_ref -and $Value.playbook_ref -isnot [string]) { throw 'playbook_ref must be a string or null' }
    if ($Value.change_at -is [DateTimeOffset]) { $Value.change_at = $Value.change_at.ToString('o') }
    elseif ($Value.change_at -is [DateTime]) { $Value.change_at = ([DateTimeOffset]$Value.change_at).ToString('o') }
    Assert-VSDateTime $Value.change_at 'change_at'
    return $Value
}

function New-VSResolverFailureFeedback {
    param([Parameter(Mandatory)][string]$PreviousSummary, [Parameter(Mandatory)][string]$FailCategory, [Parameter(Mandatory)][System.Collections.IList]$TopErrors)
    if ($null -eq $script:ContractConfig) { $null = Get-VSVerificationConfig }
    if ([string]::IsNullOrEmpty($PreviousSummary) -or (Get-VSCodePointCount $PreviousSummary) -gt $script:ContractConfig.retry_summary_max_length) { throw 'previous_summary must contain 1..configured maximum characters' }
    if ($FailCategory -cnotin (Get-VSAllowedFailCategories)) { throw 'fail_category is not an allowed enum value' }
    if ($TopErrors.Count -gt $script:ContractConfig.top_errors_max_count -or @($TopErrors | Where-Object { $_ -isnot [string] }).Count) { throw 'top_errors exceeds configured contract' }
    return [ordered]@{ previous_summary = $PreviousSummary; fail_category = $FailCategory; top_errors = @($TopErrors) }
}

function Get-VSHighRiskCategories {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = 'incident' }
    $valid = @('bug', 'incident', 'maintenance', 'other')
    $parsed = @($Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $invalid = @($parsed | Where-Object { $_ -cnotin $valid })
    if ($invalid.Count) { throw "Invalid high-risk category: $($invalid -join ', ')" }
    return @($parsed | Select-Object -Unique)
}

function Test-VSHighRisk {
    param([AllowNull()][string]$Category, [string]$Configured = 'incident')
    if ([string]::IsNullOrWhiteSpace($Category)) { Write-Warning 'Problem category is null; treating as non-high-risk'; return $false }
    $valid = @('bug', 'incident', 'maintenance', 'other')
    if ($Category -cnotin $valid) { Write-Warning "Invalid triage category '$Category'; treating as non-high-risk"; return $false }
    return $Category -cin (Get-VSHighRiskCategories $Configured)
}

function New-VSTriageResult {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Value, [Parameter(Mandatory)][System.Collections.IDictionary]$AgentConfig)
    Assert-VSExactFields $Value @('category', 'severity', 'keywords') 'VSTriageResult'
    if ($Value.category -isnot [string] -or $Value.category -cnotin @('bug', 'incident', 'maintenance', 'other')) { throw 'Triage category is outside the controlled enum' }
    if ($null -ne $Value.severity -and $Value.severity -cnotin @('critical', 'high', 'medium', 'low')) { throw 'Triage severity is outside the controlled enum' }
    if ($Value.keywords -isnot [System.Collections.IList] -or $Value.keywords.Count -gt $AgentConfig.triage.max_keywords) { throw 'Triage keywords exceed configured count' }
    foreach ($keyword in $Value.keywords) {
        if ($keyword -isnot [string] -or (Get-VSCodePointCount $keyword) -gt $AgentConfig.triage.max_keyword_length) { throw 'Triage keyword is invalid or too long' }
    }
    return $Value
}

function Sort-VSScheduledProblems {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][System.Collections.IDictionary]$PriorityMatrix)
    $indexed = for ($index = 0; $index -lt $Items.Count; $index++) {
        [pscustomobject]@{ item = $Items[$index]; index = $index }
    }
    $categoryGroups = foreach ($group in ($indexed | Group-Object { $_.item.category })) {
        [pscustomobject]@{ name = $group.Name; priority = [int]$PriorityMatrix[$group.Name]; first_index = ($group.Group | Measure-Object -Property index -Minimum).Minimum; rows = $group.Group }
    }
    $categoryGroups = @($categoryGroups | Sort-Object @{ Expression = { -$_.priority } }, @{ Expression = { $_.first_index } })
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($group in $categoryGroups) {
        $categoryItems = @($indexed | Where-Object { $_.item.category -ceq $group.Name } | Sort-Object `
            @{ Expression = { -[int]$_.item.playbook_matched } }, `
            @{ Expression = { -[double]$_.item.match_score } }, `
            @{ Expression = { -[double]$_.item.priority_score } }, `
            @{ Expression = { [DateTimeOffset]$_.item.created_at } }, `
            @{ Expression = { $_.index } })
        foreach ($row in $categoryItems) { $ordered.Add($row.item) }
    }
    return ,$ordered.ToArray()
}

function Get-VSImmutableSnapshot {
    param([System.Collections.IDictionary]$Entries)
    $copy = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $Entries.Keys) { $copy.Add([string]$key, (ConvertTo-VSImmutableValue $Entries[$key])) }
    return [System.Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($copy)
}

function ConvertTo-VSImmutableValue {
    param([Parameter(Mandatory)][object]$Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($key in $Value.Keys) { $copy.Add([string]$key, (ConvertTo-VSImmutableValue $Value[$key])) }
        return [System.Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($copy)
    }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-VSImmutableValue $item)) }
        return [System.Collections.ObjectModel.ReadOnlyCollection[object]]::new($items)
    }
    return $Value
}

function Assert-VSPlaybookEvent {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Event)
    switch -CaseSensitive ($Event.type) {
        'archive' {
            Assert-VSExactFields $Event @('type', 'pattern_id', 'category', 'signature', 'solution') 'ArchiveEvent'
            Assert-VSIdentifier $Event.pattern_id 'pattern_id' $script:ContractConfig.problem_id_max_length
            if ($Event.category -isnot [string] -or [string]::IsNullOrWhiteSpace($Event.category)) { throw 'archive category must be non-empty' }
            if ($Event.signature -isnot [System.Collections.IDictionary]) { throw 'archive signature must be an object' }
            if ($Event.solution -isnot [string] -or (Get-VSCodePointCount $Event.solution) -gt $script:ContractConfig.playbook_solution_summary_max_length) { throw 'playbook solution summary exceeds configured limit' }
        }
        'confidence_update' {
            Assert-VSExactFields $Event @('type', 'pattern_id', 'success') 'ConfidenceUpdateEvent'
            Assert-VSIdentifier $Event.pattern_id 'pattern_id' $script:ContractConfig.problem_id_max_length
            if ($Event.success -isnot [bool]) { throw 'confidence update success must be a boolean' }
        }
        'skip' {
            Assert-VSExactFields $Event @('type', 'pattern_id') 'SkipEvent'
            Assert-VSIdentifier $Event.pattern_id 'pattern_id' $script:ContractConfig.problem_id_max_length
        }
        'review_reject' {
            Assert-VSExactFields $Event @('type', 'pattern_id') 'ReviewRejectEvent'
            Assert-VSIdentifier $Event.pattern_id 'pattern_id' $script:ContractConfig.problem_id_max_length
        }
        default { throw "Unsupported playbook event type: $($Event.type)" }
    }
}

function Get-VSSignatureParts {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Signature)
    $keywords = @($Signature.keywords)
    $features = @{}
    if ($Signature.features -is [System.Collections.IDictionary]) {
        foreach ($key in $Signature.features.Keys) {
            if ($key -cne 'embedding') { $features[[string]$key] = $Signature.features[$key] }
        }
    }
    $embedding = @()
    if (@($Signature.Keys) -ccontains 'embedding' -and $null -ne $Signature['embedding']) { $embedding = @($Signature['embedding']) }
    elseif ($Signature.features -is [System.Collections.IDictionary] -and @($Signature.features.Keys) -ccontains 'embedding') { $embedding = @($Signature.features['embedding']) }
    if (@($keywords | Where-Object { $_ -isnot [string] }).Count) { throw 'signature keywords must be strings' }
    if ($embedding.Count -and @($embedding | Where-Object { $_ -isnot [ValueType] -or $_ -is [bool] -or [double]::IsNaN([double]$_) -or [double]::IsInfinity([double]$_) }).Count) { throw 'signature embedding must contain finite numbers' }
    return [pscustomobject]@{ keywords = $keywords; features = $features; embedding = @($embedding | ForEach-Object { [double]$_ }) }
}

function Get-VSEmbeddingSimilarity {
    param([double[]]$Left, [double[]]$Right)
    if (-not $Left.Count -or -not $Right.Count -or $Left.Count -ne $Right.Count) { return 0.0 }
    $dot = 0.0; $leftNorm = 0.0; $rightNorm = 0.0
    for ($i = 0; $i -lt $Left.Count; $i++) {
        $dot += $Left[$i] * $Right[$i]
        $leftNorm += $Left[$i] * $Left[$i]
        $rightNorm += $Right[$i] * $Right[$i]
    }
    if ($leftNorm -eq 0 -or $rightNorm -eq 0) { return 0.0 }
    $score = (($dot / ([math]::Sqrt($leftNorm) * [math]::Sqrt($rightNorm))) + 1) / 2
    return [math]::Min(1.0, [math]::Max(0.0, $score))
}

function Get-VSFeatureSimilarity {
    param([object]$Left, [object]$Right)
    $leftItems = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $rightItems = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($word in $Left.keywords) { $null = $leftItems.Add("keyword:$word") }
    foreach ($word in $Right.keywords) { $null = $rightItems.Add("keyword:$word") }
    foreach ($key in $Left.features.Keys) { $null = $leftItems.Add("feature:$key=$(ConvertTo-Json -InputObject $Left.features[$key] -Depth 100 -Compress)") }
    foreach ($key in $Right.features.Keys) { $null = $rightItems.Add("feature:$key=$(ConvertTo-Json -InputObject $Right.features[$key] -Depth 100 -Compress)") }
    $union = [System.Collections.Generic.HashSet[string]]::new($leftItems, [System.StringComparer]::Ordinal)
    $null = $union.UnionWith($rightItems)
    if ($union.Count -eq 0) { return 0.0 }
    $null = $leftItems.IntersectWith($rightItems)
    return [double]$leftItems.Count / $union.Count
}

function Start-VSPlaybook {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    if ($null -ne $script:PlaybookQueue) { throw 'Playbook writer is already started' }
    foreach ($name in @('writer_batch_size', 'writer_flush_timeout_seconds', 'writer_poll_interval_ms')) {
        if ($Config[$name] -is [bool] -or $Config[$name] -isnot [ValueType] -or [double]$Config[$name] -le 0) { throw "$name must be a positive number" }
    }
    $weights = @([double]$Config.embedding_weight, [double]$Config.feature_weight, [double]$Config.confidence_weight)
    if (@($weights | Where-Object { [double]::IsNaN($_) -or [double]::IsInfinity($_) -or $_ -lt 0 -or $_ -gt 1 }).Count -gt 0 -or [math]::Abs(($weights | Measure-Object -Sum).Sum - 1.0) -gt 1e-9) { throw 'Playbook weights must be finite values between zero and one that sum to one' }
    if ([double]$Config.low_conf_threshold -lt 0 -or [double]$Config.low_conf_threshold -gt 1) { throw 'low_conf_threshold must be between zero and one' }
    $script:PlaybookConfig = $Config
    $script:PlaybookLogPath = if ([IO.Path]::IsPathRooted([string]$Config.event_log_path)) { [IO.Path]::GetFullPath([string]$Config.event_log_path) } else { [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Config.event_log_path)) }
    $script:PlaybookQueue = [System.Collections.Concurrent.BlockingCollection[object]]::new()
    $writerScript = @'
param($Queue, $Path, $BatchSize)
$ErrorActionPreference = 'Stop'
$encoding = [Text.UTF8Encoding]::new($false)
function Flush-EventBatch {
    param($Events, $Path, $Encoding)
    if ($Events.Count -eq 0) { return }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $writer = [IO.StreamWriter]::new($stream, $Encoding, 4096, $true)
        try {
            foreach ($event in $Events) { $writer.WriteLine([string]$event) }
            $writer.Flush()
            $stream.Flush($true)
        } finally { $writer.Dispose() }
    } finally { $stream.Dispose() }
}
$batch = [System.Collections.Generic.List[object]]::new()
foreach ($event in $Queue.GetConsumingEnumerable()) {
    if ($event.type -eq '__stop') {
        Flush-EventBatch $batch $Path $encoding
        break
    }
    if ($event.type -eq '__barrier') {
        Flush-EventBatch $batch $Path $encoding
        $batch.Clear()
        $event.completion.Set()
        continue
    }
    $batch.Add($event)
    if ($batch.Count -ge $BatchSize) {
        Flush-EventBatch $batch $Path $encoding
        $batch.Clear()
    }
}
'@
    $ps = [powershell]::Create()
    $null = $ps.AddScript($writerScript).AddArgument($script:PlaybookQueue).AddArgument($script:PlaybookLogPath).AddArgument([int]$Config.writer_batch_size)
    $script:PlaybookWorkerPowerShell = $ps
    $script:PlaybookWorker = $ps.BeginInvoke()
    $null = Rebuild-VSPlaybook
}

function Submit-VSPlaybookEvent {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Event)
    if ($null -eq $script:PlaybookQueue -or $script:PlaybookWorker.IsCompleted) { throw 'Playbook writer is not running' }
    Assert-VSPlaybookEvent $Event
    $script:PlaybookQueue.Add((ConvertTo-Json -InputObject $Event -Depth 100 -Compress))
}

function Wait-VSPlaybookWriter {
    if ($null -eq $script:PlaybookQueue) { return }
    $barrier = [pscustomobject]@{ type = '__barrier'; completion = [System.Threading.ManualResetEventSlim]::new($false) }
    $script:PlaybookQueue.Add($barrier)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds([double]$script:PlaybookConfig.writer_flush_timeout_seconds)
    try {
        while (-not $barrier.completion.IsSet) {
            if ($script:PlaybookWorker.IsCompleted) {
                $workerErrors = @($script:PlaybookWorkerPowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
                $workerState = $script:PlaybookWorkerPowerShell.InvocationStateInfo.State
                $workerReason = $script:PlaybookWorkerPowerShell.InvocationStateInfo.Reason
                throw "Playbook writer stopped unexpectedly (state=$workerState, reason=$workerReason). Writer errors: $workerErrors"
            }
            if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Timed out waiting for playbook writer flush' }
            $waitMilliseconds = [math]::Min([int]$script:PlaybookConfig.writer_poll_interval_ms, [math]::Max(1, [int]($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds))
            $null = $barrier.completion.Wait([TimeSpan]::FromMilliseconds($waitMilliseconds))
        }
    } finally {
        $barrier.completion.Dispose()
    }
}

function Read-VSPlaybookLog {
    param([Parameter(Mandatory)][string]$Path)
    $reader = [powershell]::Create()
    $null = $reader.AddScript('param($LogPath) $timer = [Diagnostics.Stopwatch]::StartNew(); $lines = if ([IO.File]::Exists($LogPath)) { [IO.File]::ReadAllLines($LogPath) } else { [string[]]@() }; $timer.Stop(); [pscustomobject]@{ thread_id = [System.Threading.Thread]::CurrentThread.ManagedThreadId; elapsed_ms = $timer.Elapsed.TotalMilliseconds; lines = $lines }').AddArgument($Path)
    $handle = $reader.BeginInvoke()
    try {
        $output = @($reader.EndInvoke($handle))
        if ($reader.Streams.Error.Count -gt 0) { throw ($reader.Streams.Error | Out-String) }
        if ($output.Count -ne 1) { throw "Playbook log reader returned $($output.Count) results; expected one" }
        $script:PlaybookLastReadThreadId = [int]$output[0].thread_id
        $script:PlaybookLastReadElapsedMilliseconds = [double]$output[0].elapsed_ms
        return ,$output[0].lines
    } finally {
        $reader.Dispose()
    }
}

function Rebuild-VSPlaybook {
    if ($null -eq $script:PlaybookLogPath) { throw 'Playbook is not started' }
    if ($null -eq $script:ContractConfig) { $null = Get-VSVerificationConfig }
    Wait-VSPlaybookWriter
    $entries = @{}
    $version = 0
    $lineNumber = 0
    foreach ($line in (Read-VSPlaybookLog $script:PlaybookLogPath)) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $event = ConvertFrom-Json -InputObject $line -AsHashtable
                if ($event.type -eq '__barrier') { continue }
                Assert-VSPlaybookEvent $event
                switch ($event.type) {
                    'archive' {
                        $existing = $entries[$event.pattern_id]
                        $stats = if ($null -eq $existing) { @{ successes = 0; failures = 0; skips = 0; review_rejections = 0 } } else { $existing.stats }
                        $entries[$event.pattern_id] = @{ pattern_id = $event.pattern_id; category = $event.category; signature = $event.signature; solution = $event.solution; stats = $stats; confidence = [double](($stats.successes + 1) / ($stats.successes + $stats.failures + 2)) }
                    }
                    'confidence_update' {
                        if (-not $entries.ContainsKey($event.pattern_id)) { throw "Unknown pattern $($event.pattern_id)" }
                        $entry = $entries[$event.pattern_id]
                        $field = if ($event.success) { 'successes' } else { 'failures' }
                        $entry.stats[$field]++
                        $entry.confidence = [double](($entry.stats.successes + 1) / ($entry.stats.successes + $entry.stats.failures + 2))
                    }
                    { $_ -in @('skip', 'review_reject') } {
                        if (-not $entries.ContainsKey($event.pattern_id)) { break }
                        $entry = $entries[$event.pattern_id]
                        $entry.stats.failures++
                        if ($event.type -eq 'skip') { $entry.stats.skips++ } else { $entry.stats.review_rejections++ }
                        $entry.confidence = [double](($entry.stats.successes + 1) / ($entry.stats.successes + $entry.stats.failures + 2))
                    }
                    '__barrier' { continue }
                    default { throw "Unknown playbook event type $($event.type)" }
                }
                $version++
            } catch {
                throw "Invalid playbook event on line $lineNumber`: $($_.Exception.Message)"
            }
    }
    $script:PlaybookSnapshot = Get-VSImmutableSnapshot $entries
    $script:PlaybookVersion = $version
    return ,$script:PlaybookSnapshot
}

function Get-VSPlaybookSnapshot {
    if ($null -eq $script:PlaybookSnapshot) { throw 'Playbook snapshot is not initialized' }
    return ,$script:PlaybookSnapshot
}

function Get-VSPlaybookIoDiagnostics {
    return [pscustomobject]@{ read_thread_id = $script:PlaybookLastReadThreadId; read_elapsed_ms = $script:PlaybookLastReadElapsedMilliseconds }
}

function Search-VSPlaybook {
    param([Parameter(Mandatory)][string]$Category, [Parameter(Mandatory)][System.Collections.IDictionary]$Signature, [int]$TopK = 5, [double]$MinScore = 0, [System.Collections.IDictionary]$Snapshot = $null, [System.Collections.IDictionary]$Config = $null)
    if ($TopK -lt 0 -or $MinScore -lt 0 -or $MinScore -gt 1) { throw 'top_k and min_score are outside allowed bounds' }
    if ($null -eq $Snapshot) { $Snapshot = $script:PlaybookSnapshot }
    if ($null -eq $Config) { $Config = $script:PlaybookConfig }
    if ($null -eq $Config) { throw 'Playbook search configuration is not initialized' }
    $query = Get-VSSignatureParts $Signature
    $results = foreach ($pattern in $Snapshot.Values) {
        if ($pattern.category -cne $Category) { continue }
        $candidate = Get-VSSignatureParts $pattern.signature
        $embeddingScore = Get-VSEmbeddingSimilarity $query.embedding $candidate.embedding
        $featureScore = Get-VSFeatureSimilarity $query $candidate
        $confidence = [double]$pattern.confidence
        $score = $embeddingScore * [double]$Config.embedding_weight + $featureScore * [double]$Config.feature_weight + $confidence * [double]$Config.confidence_weight
        if ($score -ge $MinScore) { [pscustomobject]@{ pattern = $pattern; score = $score; downgraded = ($confidence -lt [double]$Config.low_conf_threshold) } }
    }
    return @($results | Sort-Object @{ Expression = { -$_.score } }, @{ Expression = { $_.pattern.pattern_id } } | Select-Object -First $TopK)
}

function Stop-VSPlaybook {
    if ($null -eq $script:PlaybookQueue) { return }
    Wait-VSPlaybookWriter
    $script:PlaybookQueue.Add(@{ type = '__stop' })
    $script:PlaybookWorkerPowerShell.EndInvoke($script:PlaybookWorker) | Out-Null
    $script:PlaybookWorkerPowerShell.Dispose()
    $script:PlaybookQueue.Dispose()
    $script:PlaybookQueue = $null
    $script:PlaybookWorkerPowerShell = $null
    $script:PlaybookWorker = $null
}

function New-VSPlaybookPort {
    if ($null -eq $script:PlaybookQueue) { throw 'Playbook store has not been started' }
    return [pscustomobject]@{
        readSnapshot = { Get-VSPlaybookSnapshot }
        submit = { param([System.Collections.IDictionary]$Event) Submit-VSPlaybookEvent $Event }
        queue = $script:PlaybookQueue
    }
}

function Test-VSChangeGuardrail {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Change, [Parameter(Mandatory)][System.Collections.IDictionary]$Guardrails)
    foreach ($target in $Change.targets) {
        foreach ($rule in @($Guardrails.forbidden_targets)) {
            $regex = '^' + [regex]::Escape([string]$rule).Replace('\*\*', '.*').Replace('\*', '[^/]*') + '$'
            if ([string]$target -match $regex) { return 'change target is forbidden by configuration' }
        }
    }
    foreach ($rule in @($Guardrails.forbidden_patterns)) {
        if ($Change.diff -match [string]$rule) { return 'change matches a forbidden content pattern' }
    }
    $files = @([regex]::Matches($Change.diff, '(?m)^\+\+\+ b/(.+)$') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($files.Count -gt [int]$Guardrails.max_patch_files) { return 'patch file count exceeds configured limit' }
    if ([Text.Encoding]::UTF8.GetByteCount($Change.diff) -gt [int]$Guardrails.max_patch_bytes) { return 'patch byte count exceeds configured limit' }
    if (@($Change.diff -split "`n").Count -gt [int]$Guardrails.max_patch_lines) { return 'patch line count exceeds configured limit' }
    return $null
}

function Invoke-VSOracleWithPolling {
    param([object]$Oracle, [System.Collections.IDictionary]$Change, [System.Collections.IDictionary]$Problem, [System.Collections.IDictionary]$Verification)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $timeout = [double]$Verification.oracle_timeout_seconds
    $verdict = & $Oracle.judge $Change $Problem $timeout
    if ($verdict -is [System.Threading.Tasks.Task]) {
        if (-not $verdict.Wait([TimeSpan]::FromSeconds($timeout))) { throw [TimeoutException]::new('Oracle timed out') }
        $verdict = $verdict.GetAwaiter().GetResult()
    }
    while ($null -eq $verdict) {
        $remaining = $timeout - $timer.Elapsed.TotalSeconds
        if ($remaining -le 0) { throw [TimeoutException]::new('Oracle timed out') }
        Start-Sleep -Seconds ([math]::Min([double]$Verification.oracle_poll_interval_seconds, $remaining))
        $remaining = $timeout - $timer.Elapsed.TotalSeconds
        if ($remaining -le 0) { throw [TimeoutException]::new('Oracle timed out') }
        $verdict = & $Oracle.poll $Change.change_id $remaining
        if ($verdict -is [System.Threading.Tasks.Task]) {
            if (-not $verdict.Wait([TimeSpan]::FromSeconds($remaining))) { throw [TimeoutException]::new('Oracle timed out') }
            $verdict = $verdict.GetAwaiter().GetResult()
        }
    }
    if ($verdict -isnot [System.Collections.IDictionary]) { throw 'Oracle must return a VSVerdict object or null while pending' }
    return New-VSVerdict $verdict
}

function Invoke-VSChangePipeline {
    param(
        [System.Collections.IDictionary]$Change,
        [System.Collections.IDictionary]$Problem,
        [string]$Category,
        [System.Collections.IDictionary]$Verification,
        [object]$ResolverFactory,
        [object]$Executor,
        [object]$Oracle,
        [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.SemaphoreSlim]]$TargetLocks,
        [System.Collections.IDictionary]$SourcePattern
    )
    $locks = [System.Collections.Generic.List[System.Threading.SemaphoreSlim]]::new()
    try {
        foreach ($target in @($Change.targets | ForEach-Object { [string]$_ } | Sort-Object -Unique)) {
            $lock = $TargetLocks.GetOrAdd($target, [System.Threading.SemaphoreSlim]::new(1, 1))
            $lock.Wait()
            $locks.Add($lock)
        }
        try {
            $applyResult = & $Executor.apply $Change
            if ($applyResult -isnot [System.Collections.IDictionary] -or $applyResult.ok -ne $true) {
                return [pscustomobject]@{ ok = $false; category = 'pipeline_failed'; top_errors = @('change executor rejected the change'); verdict = $null; revert = $false; review_reject_pattern_id = $null }
            }
        } catch {
            Write-Warning "Change application failed for problem $($Problem.problem_id): $($_.Exception.Message)"
            return [pscustomobject]@{ ok = $false; category = 'pipeline_failed'; top_errors = @('change application failed'); verdict = $null; revert = $false; review_reject_pattern_id = $null }
        }
        try {
            $verdict = Invoke-VSOracleWithPolling $Oracle $Change $Problem $Verification
        } catch [TimeoutException] {
            Write-Warning "Oracle timed out for change $($Change.change_id)"
            $verdict = New-VSVerdict @{ ok = $false; fail_category = 'timeout'; evidence = @{ top_errors = @('oracle timed out'); signals = @{}; artifacts = @{} }; verdict_at = [DateTimeOffset]::UtcNow.ToString('o') }
        } catch {
            Write-Warning "Oracle failed for change $($Change.change_id): $($_.Exception.Message)"
            $verdict = New-VSVerdict @{ ok = $false; fail_category = 'oracle_error'; evidence = @{ top_errors = @('oracle failed'); signals = @{}; artifacts = @{} }; verdict_at = [DateTimeOffset]::UtcNow.ToString('o') }
        }
        if ($verdict.ok -and (Test-VSHighRisk -Category $Category -Configured $Verification.high_risk_categories)) {
            $criteria = $Problem.raw.acceptance_criteria
            if ($criteria -isnot [string]) {
                Write-Warning "Problem $($Problem.problem_id) has no string acceptance_criteria; rejecting independent review"
                $criteria = ''
                $approved = $false
            }
            else {
                try {
                    $reviewer = & $ResolverFactory.create
                    $approved = & $reviewer.review $Change.diff $criteria
                } catch {
                    Write-Warning "Independent review failed for problem $($Problem.problem_id): $($_.Exception.Message)"
                    $approved = $false
                }
            }
            if ($approved -isnot [bool] -or -not $approved) {
                $patternId = if ($null -ne $SourcePattern) { $SourcePattern.pattern_id } else { $Change.change_id }
                return [pscustomobject]@{ ok = $false; category = 'review_rejected'; top_errors = @('independent review rejected the change'); verdict = $verdict; review_reject_pattern_id = $patternId; revert = $true }
            }
        }
        if (-not $verdict.ok) {
            return [pscustomobject]@{ ok = $false; category = $verdict.fail_category; top_errors = @($verdict.evidence.top_errors); verdict = $verdict; revert = $true; review_reject_pattern_id = $null }
        }
        return [pscustomobject]@{ ok = $true; category = $null; top_errors = @(); verdict = $verdict; revert = $false; review_reject_pattern_id = $null }
    } finally {
        for ($index = $locks.Count - 1; $index -ge 0; $index--) { $locks[$index].Release() | Out-Null }
    }
}

function Enter-VSRunLock {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][double]$TimeoutSeconds, [Parameter(Mandatory)][int]$PollIntervalMilliseconds)
    if ($TimeoutSeconds -le 0 -or $PollIntervalMilliseconds -le 0) { throw 'Run-lock timeout and poll interval must be positive' }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            $stream = [IO.FileStream]::new($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stream.SetLength(0)
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false), 1024, $true)
            $writer.Write([Environment]::ProcessId)
            $writer.Flush()
            $writer.Dispose()
            return $stream
        } catch [IO.IOException] {
            if ([DateTimeOffset]::UtcNow -ge $deadline) { throw [TimeoutException]::new("Timed out waiting for run lock '$Path'") }
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
        }
    }
}

function Invoke-VSRunspaceBatch {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][int]$ThrottleLimit, [Parameter(Mandatory)][string]$WorkerScript, [Parameter(Mandatory)][object]$Context, [string]$ModulePath)
    if ($ThrottleLimit -lt 1) { throw 'runspace throttle limit must be positive' }
    if ($Items.Count -eq 0) { return @() }
    if ([string]::IsNullOrWhiteSpace($ModulePath)) {
        $pool = [RunspaceFactory]::CreateRunspacePool(1, $ThrottleLimit)
    } else {
        $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $initialState.ImportPSModule([string[]]@($ModulePath))
        $pool = [RunspaceFactory]::CreateRunspacePool(1, $ThrottleLimit, $initialState, $Host)
    }
    $pool.Open()
    $active = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        for ($index = 0; $index -lt $Items.Count; $index++) {
            $powershell = [powershell]::Create()
            $powershell.RunspacePool = $pool
            $null = $powershell.AddScript($WorkerScript).AddArgument($Items[$index]).AddArgument($Context)
            $active.Add([pscustomobject]@{ index = $index; item = $Items[$index]; powershell = $powershell; handle = $powershell.BeginInvoke() })
        }
        foreach ($job in $active) {
            try {
                $output = @($job.powershell.EndInvoke($job.handle))
                if ($job.powershell.Streams.Error.Count -gt 0) { throw ($job.powershell.Streams.Error | Out-String) }
                if ($output.Count -ne 1) { throw "Runspace worker returned $($output.Count) values; expected exactly one" }
                $results.Add([pscustomobject]@{ index = $job.index; item = $job.item; value = $output[0] })
            } finally {
                $job.powershell.Dispose()
            }
        }
    } finally {
        foreach ($job in $active) {
            if ($job.powershell.RunspacePool -and $job.handle.IsCompleted -eq $false) { $job.powershell.Stop(); $job.powershell.Dispose() }
        }
        $pool.Close()
        $pool.Dispose()
    }
    return ,$results.ToArray()
}

function New-VSResolverRequest {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Problem,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][System.Collections.IList]$Keywords,
        [AllowNull()][System.Collections.IDictionary]$Pattern,
        [AllowNull()][string]$PreviousSummary,
        [AllowNull()][System.Collections.IDictionary]$Feedback
    )
    $summary = ''
    if ($Problem.raw.Contains('summary')) {
        $summary = $Problem.raw.summary
        if ($summary -isnot [string] -or $summary.Contains("`n") -or $summary.Contains("`r") -or (Get-VSCodePointCount $summary) -gt $script:ContractConfig.resolver_context_summary_max_length) {
            throw 'raw.summary must be a single-line string within the configured resolver context limit'
        }
    }
    $safeProblem = [ordered]@{
        problem_id = $Problem.problem_id
        category = $Category
        severity = $Problem.severity
        summary = $summary
        keywords = @($Keywords)
    }
    $safePattern = if ($null -eq $Pattern) {
        $null
    } else {
        [ordered]@{ pattern_id = $Pattern.pattern_id; solution = $Pattern.solution }
    }
    return @{
        problem = $safeProblem
        category = $Category
        keywords = @($Keywords)
        pattern = $safePattern
        previous_summary = $PreviousSummary
        feedback = $Feedback
    }
}

function Invoke-VSProblemResolution {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Problem,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SystemConfig,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Verification,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Knowledge,
        [Parameter(Mandatory)][System.Collections.IList]$TriageKeywords,
        [Parameter(Mandatory)][object]$ResolverFactory,
        [Parameter(Mandatory)][object]$Executor,
        [Parameter(Mandatory)][object]$Oracle,
        [System.Collections.IDictionary]$PlaybookSnapshot = $null,
        [object]$PlaybookConfig = $null,
        [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.SemaphoreSlim]]$TargetLocks = $null
    )
    $signature = @{ keywords = @($TriageKeywords); features = $Problem.signature.features }
    if ($null -eq $PlaybookSnapshot) { $PlaybookSnapshot = Get-VSPlaybookSnapshot }
    if ($null -eq $PlaybookConfig) { $PlaybookConfig = $script:PlaybookConfig }
    if ($null -eq $TargetLocks) { $TargetLocks = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.SemaphoreSlim]]::new([StringComparer]::Ordinal) }
    $matches = @(Search-VSPlaybook -Category $Category -Signature $signature -TopK ([int]$Verification.triage.playbook_top_k) -MinScore ([double]$Verification.triage.playbook_min_score) -Snapshot $PlaybookSnapshot -Config $PlaybookConfig | Sort-Object @{ Expression = { -$_.pattern.confidence } }, @{ Expression = { -$_.score } }, @{ Expression = { $_.pattern.pattern_id } } | Select-Object -First ([int]$Verification.max_playbook_try))
    $attempts = 0
    $lastCategory = 'unknown'
    $topErrors = @()
    $previousSummary = $null
    $lastChangeId = $Problem.problem_id
    $events = [System.Collections.Generic.List[object]]::new()
    $attemptSpecs = [System.Collections.Generic.List[object]]::new()
    foreach ($match in $matches) {
        $attemptSpecs.Add([pscustomobject]@{ pattern = $match.pattern; is_retry = $false })
    }
    for ($retry = 0; $retry -le [int]$SystemConfig.retry_per_bug; $retry++) {
        $attemptSpecs.Add([pscustomobject]@{ pattern = $null; is_retry = ($retry -gt 0) })
    }
    foreach ($spec in $attemptSpecs) {
        $attempts++
        $feedback = if ($spec.is_retry -and $null -ne $previousSummary) {
            $validatedFeedback = New-VSResolverFailureFeedback $previousSummary $lastCategory @($topErrors | Select-Object -First ([int]$Verification.top_errors_max_count))
            @{ fail_category = $validatedFeedback.fail_category; top_errors = @($validatedFeedback.top_errors) }
        } else { $null }
        $request = New-VSResolverRequest -Problem $Problem -Category $Category -Keywords $TriageKeywords -Pattern $spec.pattern -PreviousSummary $(if ($spec.is_retry) { $previousSummary } else { $null }) -Feedback $feedback
        if ($spec.is_retry -and $null -ne $previousSummary -and (Get-VSCodePointCount $previousSummary) -gt $script:ContractConfig.retry_summary_max_length) { throw 'Retry summary exceeds configured limit' }
        $agent = & $ResolverFactory.create
        try {
            $change = New-VSChange (& $agent.resolve $request)
        } catch {
            Write-Warning "Resolver failed for problem $($Problem.problem_id): $($_.Exception.Message)"
            $lastCategory = 'unknown'
            $topErrors = @('resolver returned an invalid change')
            if ($null -ne $spec.pattern) { $events.Add(@{ type = 'confidence_update'; pattern_id = $spec.pattern.pattern_id; success = $false }) }
            continue
        }
        $lastChangeId = $change.change_id
        $previousSummary = $change.summary
        $guardrailError = Test-VSChangeGuardrail $change $Verification.guardrails
        if ($null -ne $guardrailError) {
            $lastCategory = 'guardrail_rejected'
            $topErrors = @($guardrailError)
            if ($null -ne $spec.pattern) { $events.Add(@{ type = 'confidence_update'; pattern_id = $spec.pattern.pattern_id; success = $false }) }
            continue
        }
        $pipeline = Invoke-VSChangePipeline -Change $change -Problem $Problem -Category $Category -Verification $Verification -ResolverFactory $ResolverFactory -Executor $Executor -Oracle $Oracle -TargetLocks $TargetLocks -SourcePattern $spec.pattern
        if ($pipeline.revert) {
            try { $null = & $Executor.revert $change } catch {
                Write-Warning "Change revert failed for problem $($Problem.problem_id): $($_.Exception.Message)"
                $pipeline.category = 'pipeline_failed'
                $pipeline.top_errors = @('change revert failed')
            }
        }
        if (-not $pipeline.ok) {
            $lastCategory = $pipeline.category
            $topErrors = @($pipeline.top_errors | Select-Object -First ([int]$Verification.top_errors_max_count))
            if ($null -ne $pipeline.review_reject_pattern_id) { $events.Add(@{ type = 'review_reject'; pattern_id = $pipeline.review_reject_pattern_id }) }
            elseif ($null -ne $spec.pattern) { $events.Add(@{ type = 'confidence_update'; pattern_id = $spec.pattern.pattern_id; success = $false }) }
            continue
        }
        $events.Add(@{ type = 'archive'; pattern_id = $change.change_id; category = $Category; signature = $signature; solution = $change.summary })
        $events.Add(@{ type = 'confidence_update'; pattern_id = $change.change_id; success = $true })
        if ($null -ne $spec.pattern) { $events.Add(@{ type = 'confidence_update'; pattern_id = $spec.pattern.pattern_id; success = $true }) }
        return [pscustomobject]@{ problem_id = $Problem.problem_id; category = $Category; status = 'success'; reason = $null; attempts = $attempts; playbook_matched = ($matches.Count -gt 0); verdict = $pipeline.verdict; events = $events.ToArray() }
    }
    $events.Add(@{ type = 'skip'; pattern_id = $lastChangeId })
    return [pscustomobject]@{
        problem_id = $Problem.problem_id
        category = $Category
        status = 'escalated'
        reason = $lastCategory
        attempts = $attempts
        playbook_matched = ($matches.Count -gt 0)
        verdict = @{ ok = $false; fail_category = $lastCategory; evidence = @{ top_errors = @($topErrors | Select-Object -First ([int]$Verification.top_errors_max_count)); signals = @{}; artifacts = @{} }; verdict_at = [DateTimeOffset]::UtcNow.ToString('o') }
        events = $events.ToArray()
    }
}

function Invoke-VSCommand {
    param([string[]]$Arguments = @())
    if (-not $Arguments.Count) { throw 'Expected a command: run, status, report, or kb' }
    $cliConfig = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'config\verisolve.cli.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $systemConfigPath = Join-Path $script:ProjectRoot ('config\' + $cliConfig.config_files.system)
    $agentsConfig = Get-Content -LiteralPath (Join-Path $script:ProjectRoot ('config\' + $cliConfig.config_files.agents)) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $categoriesConfig = Get-Content -LiteralPath (Join-Path $script:ProjectRoot ('config\' + $cliConfig.config_files.categories)) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $verification = Get-VSVerificationConfig (Join-Path $script:ProjectRoot ('config\' + $cliConfig.config_files.verification))
    $knowledge = Get-Content -LiteralPath (Join-Path $script:ProjectRoot ('config\' + $cliConfig.config_files.knowledge_base)) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $system = Get-Content -LiteralPath $systemConfigPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    Assert-VSExactFields $cliConfig @('runtime', 'entry_script', 'command_templates', 'backlog_endpoints', 'run_store', 'lock_file', 'config_files', 'reports') 'CLI config'
    if ($cliConfig.runtime -cne 'PowerShell 7' -or $cliConfig.entry_script -cne 'scripts/verisolve.ps1') { throw 'CLI runtime and entry script must remain PowerShell 7' }
    Assert-VSExactFields $cliConfig.command_templates @('run', 'status', 'report', 'kb_query', 'kb_stats', 'kb_rebuild') 'CLI command templates'
    Assert-VSExactFields $cliConfig.config_files @('system', 'agents', 'categories', 'verification', 'knowledge_base') 'CLI config files'
    Assert-VSExactFields $cliConfig.reports @('markdown_filename', 'json_filename') 'CLI reports'
    if (@($agentsConfig.resolver.retry_context_fields) -join ',' -cne 'previous_summary,fail_category,top_errors' -or @($agentsConfig.resolver.review_context_fields) -join ',' -cne 'diff,acceptance_criteria') { throw 'Resolver retry and review context contracts cannot be changed' }
    if ([int]$agentsConfig.triage.max_keywords -ne [int]$verification.signature_keywords_max_count -or [int]$agentsConfig.triage.max_keyword_length -ne [int]$verification.signature_keyword_max_length -or [int]$agentsConfig.resolver.max_summary_length -ne [int]$verification.change_summary_max_length -or [int]$agentsConfig.resolver.max_top_errors -ne [int]$verification.top_errors_max_count) { throw 'Agent bounds must match the validated VS contracts' }
    if ($agentsConfig.triage.prompt_ref -cne $verification.triage.prompt_ref -or [int]$verification.triage.max_parallel_triage -ne [int]$system.max_parallel_triage) { throw 'Triage settings must match system and agent configuration' }
    if (@($agentsConfig.agent_kinds) -join "`n" -cne "TriageAgent`nResolverAgent") { throw 'Exactly TriageAgent and ResolverAgent must be configured' }
    if (@($categoriesConfig.category_values) -join "`n" -cne "bug`nincident`nmaintenance`nother") { throw 'Configured triage categories do not match the controlled enum' }
    $categoryRisk = @(Get-VSHighRiskCategories $categoriesConfig.high_risk_categories | Sort-Object)
    $verificationRisk = @(Get-VSHighRiskCategories $verification.high_risk_categories | Sort-Object)
    if (($categoryRisk -join ',') -cne ($verificationRisk -join ',')) { throw 'Category and verification high-risk settings must match' }
    if ((@($categoriesConfig.priority_matrix.Keys | Sort-Object) -join ',') -cne 'bug,incident,maintenance,other' -or @($categoriesConfig.priority_matrix.Values | Where-Object { $_ -is [bool] -or $_ -isnot [ValueType] -or [double]$_ -lt 0 -or [double]$_ -ne [math]::Truncate([double]$_) }).Count) { throw 'priority_matrix must contain non-negative integer priorities for each category' }
    if ([int]$system.retry_per_bug -lt 0 -or [int]$system.max_parallel_resolution -lt 1 -or [int]$system.max_parallel_triage -lt 1 -or [int]$knowledge.top_k -lt 1 -or [double]$knowledge.min_score -lt 0 -or [double]$knowledge.min_score -gt 1) { throw 'System or knowledge-base configuration is outside its valid range' }
    $script:PlaybookConfig = $knowledge
    $script:ProjectRoot = [IO.Path]::GetFullPath($script:ProjectRoot)
    $runStore = Join-Path $script:ProjectRoot $cliConfig.run_store
    $logPath = Join-Path $script:ProjectRoot $knowledge.event_log_path
    if ($Arguments[0] -eq 'run') {
        $runLockPath = if ([IO.Path]::IsPathRooted([string]$cliConfig.lock_file)) { $cliConfig.lock_file } else { Join-Path $script:ProjectRoot $cliConfig.lock_file }
        $runLock = Enter-VSRunLock -Path $runLockPath -TimeoutSeconds ([double]$system.file_lock_timeout_seconds) -PollIntervalMilliseconds ([int]$system.file_lock_poll_interval_ms)
        try {
        $params = @{ backlog = 'example'; dry_run = $false; max_parallel = $null }
        for ($i = 1; $i -lt $Arguments.Count; $i++) {
            switch ($Arguments[$i]) {
                '--backlog' { $i++; if ($i -ge $Arguments.Count) { throw '--backlog requires a value' }; $params.backlog = $Arguments[$i] }
                '--dry-run' { $params.dry_run = $true }
                '--max-parallel' { $i++; if ($i -ge $Arguments.Count -or $Arguments[$i] -notmatch '^[1-9][0-9]*$') { throw '--max-parallel must be a positive integer' }; $params.max_parallel = [int]$Arguments[$i] }
                default { throw "Unknown run option: $($Arguments[$i])" }
            }
        }
        $problems = @()
        Import-Module (Join-Path $script:ProjectRoot 'adapters\ExampleAdapter.psm1') -Force -DisableNameChecking
        $exampleAdapter = New-VSExampleAdapter
        $resolverFactory = New-VSExampleResolverFactory
        $triageAgent = New-VSExampleTriageAgent
        if ($params.backlog -eq 'example') {
            $sourceResult = & $exampleAdapter.problemSource.fetchBacklog $null
            $problems = @($sourceResult.problems)
        } else {
            $backlogPath = if ([IO.Path]::IsPathRooted($params.backlog)) { [IO.Path]::GetFullPath($params.backlog) } else { [IO.Path]::GetFullPath((Join-Path (Get-Location) $params.backlog)) }
            $source = New-VSJsonProblemSourceAdapter $backlogPath
            $cursor = $null
            do {
                $sourceResult = & $source.fetchBacklog $cursor
                $problems += @($sourceResult.problems)
                $cursor = $sourceResult.next_cursor
            } while ($null -ne $cursor)
        }
        $runStartedAt = [DateTimeOffset]::UtcNow.ToString('o')
        $runId = [guid]::NewGuid().ToString()
        $runPath = Join-Path $runStore $runId
        $null = New-Item -ItemType Directory -Path $runPath -Force
        $script:PlaybookConfig = $knowledge
        $script:PlaybookLogPath = [IO.Path]::GetFullPath($logPath)
        Start-VSPlaybook $knowledge
        $records = [System.Collections.Generic.List[object]]::new()
        try {
            $triageWorker = @'
param($Problem, $Context)
$result = & $Context.agent.triage $Problem $Context.prompt_ref
Write-Output $result
'@
            $triageLimit = if ($null -ne $params.max_parallel) { [int]$params.max_parallel } else { [int]$system.max_parallel_triage }
            $triageBatch = Invoke-VSRunspaceBatch -Items $problems -ThrottleLimit $triageLimit -WorkerScript $triageWorker -Context @{ agent = $triageAgent; prompt_ref = [string]$agentsConfig.triage.prompt_ref }
            $scheduledInput = [System.Collections.Generic.List[object]]::new()
            foreach ($triageRow in $triageBatch) {
                $problem = $triageRow.item
                $triage = New-VSTriageResult $triageRow.value $agentsConfig
                $category = $triage.category
                $matches = @(Search-VSPlaybook -Category $category -Signature @{ keywords = @($triage.keywords); features = $problem.signature.features } -TopK 1 -MinScore ([double]$verification.triage.playbook_min_score))
                $scheduledInput.Add([pscustomobject]@{ problem = $problem; triage = $triage; category = $category; playbook_matched = ($matches.Count -gt 0); match_score = if ($matches.Count) { $matches[0].score } else { 0 }; priority_score = if ($null -eq $problem.priority_score) { 0 } else { [double]$problem.priority_score }; created_at = [DateTimeOffset]::Parse($problem.created_at) })
            }
            $scheduled = Sort-VSScheduledProblems @($scheduledInput) $categoriesConfig.priority_matrix
            foreach ($item in $scheduled) {
                $problem = $item.problem
                if ($params.dry_run) {
                    $record = [pscustomobject]@{ problem_id = $problem.problem_id; category = $item.category; status = 'skipped'; reason = 'dry_run'; attempts = 0; playbook_matched = $item.playbook_matched; severity = $problem.severity; priority_score = $problem.priority_score; verdict = $null }
                    $records.Add($record)
                }
            }
            if (-not $params.dry_run -and $scheduled.Count) {
                $resolutionWorker = @'
param($Item, $Context)
$null = Get-VSVerificationConfig -Path $Context.verification_path
$result = Invoke-VSProblemResolution -Problem $Item.problem -Category $Item.category -SystemConfig $Context.system -Verification $Context.verification -Knowledge $Context.knowledge -TriageKeywords $Item.triage.keywords -ResolverFactory $Context.resolver_factory -Executor $Context.executor -Oracle $Context.oracle -PlaybookSnapshot $Context.snapshot -PlaybookConfig $Context.knowledge -TargetLocks $Context.target_locks
Write-Output $result
'@
                $targetLocks = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.SemaphoreSlim]]::new([StringComparer]::Ordinal)
                $resolutionContext = @{
                    module_path = Join-Path $script:ProjectRoot 'core\VeriSolve.Core.psm1'
                    verification_path = Join-Path $script:ProjectRoot ('config\' + $cliConfig.config_files.verification)
                    system = $system
                    verification = $verification
                    knowledge = $knowledge
                    resolver_factory = $resolverFactory
                    executor = $exampleAdapter.executor
                    oracle = $exampleAdapter.oracle
                    snapshot = Get-VSPlaybookSnapshot
                    target_locks = $targetLocks
                }
                $resolutionLimit = if ($null -ne $params.max_parallel) { [int]$params.max_parallel } else { [int]$system.max_parallel_resolution }
                $resolutionBatch = Invoke-VSRunspaceBatch -Items $scheduled -ThrottleLimit $resolutionLimit -WorkerScript $resolutionWorker -Context $resolutionContext -ModulePath $resolutionContext.module_path
                foreach ($resolutionRow in $resolutionBatch) {
                    $record = $resolutionRow.value
                    foreach ($event in $record.events) { Submit-VSPlaybookEvent $event }
                    $record.PSObject.Properties.Remove('events')
                    $problem = $resolutionRow.item.problem
                    $record | Add-Member -NotePropertyName severity -NotePropertyValue $problem.severity
                    $record | Add-Member -NotePropertyName priority_score -NotePropertyValue $problem.priority_score
                    $records.Add($record)
                }
            }
            Wait-VSPlaybookWriter
            $null = Rebuild-VSPlaybook
        } finally {
            Stop-VSPlaybook
        }
        $report = New-VSReport $runId $records
        $run = [ordered]@{ run_id = $runId; backlog = $params.backlog; started_at = $runStartedAt; completed_at = [DateTimeOffset]::UtcNow.ToString('o'); status = 'completed'; dry_run = $params.dry_run; results = @($records); escalation_queue = @($records | Where-Object status -eq 'escalated'); report = $report }
        $json = ConvertTo-Json -InputObject $run -Depth 100
        [IO.File]::WriteAllText((Join-Path $runPath 'run.json'), $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $runPath $cliConfig.reports.json_filename), (ConvertTo-Json -InputObject $report -Depth 100), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $runPath $cliConfig.reports.markdown_filename), (Format-VSReportMarkdown $report), [Text.UTF8Encoding]::new($false))
        Write-Output $runId
        return
        } finally {
            $runLock.Dispose()
        }
    }
    if ($Arguments[0] -in @('status', 'report')) {
        $command = $Arguments[0]
        $runId = $null
        $format = 'md'
        for ($i = 1; $i -lt $Arguments.Count; $i++) {
            switch ($Arguments[$i]) {
                '--run' { $i++; if ($i -ge $Arguments.Count) { throw '--run requires a value' }; $runId = $Arguments[$i] }
                '--format' { $i++; if ($i -ge $Arguments.Count -or $Arguments[$i] -notin @('md', 'json')) { throw '--format must be md or json' }; $format = $Arguments[$i] }
                default { throw "Unknown $command option: $($Arguments[$i])" }
            }
        }
        if (-not $runId) { throw "$command requires --run" }
        $parsedRunId = [guid]::Empty
        if (-not [guid]::TryParse($runId, [ref]$parsedRunId)) { throw 'Run id must be a UUID' }
        $runFile = Join-Path (Join-Path $runStore $runId) 'run.json'
        if (-not (Test-Path -LiteralPath $runFile)) { throw "Run not found: $runId" }
        $run = Get-Content -LiteralPath $runFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        if ($command -eq 'status') { $run | ConvertTo-Json -Depth 100; return }
        if ($format -eq 'json') { Get-Content -LiteralPath (Join-Path (Join-Path $runStore $runId) $cliConfig.reports.json_filename) -Raw -Encoding utf8 }
        else { Get-Content -LiteralPath (Join-Path (Join-Path $runStore $runId) $cliConfig.reports.markdown_filename) -Raw -Encoding utf8 }
        return
    }
    if ($Arguments[0] -eq 'kb') {
        if ($Arguments.Count -lt 2) { throw 'kb requires query, stats, or rebuild' }
        if ($Arguments[1] -eq 'rebuild') {
            $script:PlaybookLogPath = [IO.Path]::GetFullPath($logPath)
            $null = Rebuild-VSPlaybook
            Write-Output "Rebuilt playbook snapshot ($($script:PlaybookVersion) events)"
            return
        }
        if ($Arguments[1] -eq 'stats') {
            $script:PlaybookLogPath = [IO.Path]::GetFullPath($logPath)
            $script:PlaybookConfig = $knowledge
            $null = Rebuild-VSPlaybook
            $categories = @{}
            foreach ($pattern in $script:PlaybookSnapshot.Values) { $categories[$pattern.category] = 1 + [int]$categories[$pattern.category] }
            [pscustomobject]@{ version = $script:PlaybookVersion; pattern_count = $script:PlaybookSnapshot.Count; category_counts = $categories; low_confidence_count = @($script:PlaybookSnapshot.Values | Where-Object { $_.confidence -lt $knowledge.low_conf_threshold }).Count } | ConvertTo-Json -Depth 20
            return
        }
        if ($Arguments[1] -eq 'query') {
            $category = $null; $signatureFile = $null
            for ($i = 2; $i -lt $Arguments.Count; $i++) {
                switch ($Arguments[$i]) {
                    '--category' { $i++; if ($i -lt $Arguments.Count) { $category = $Arguments[$i] } }
                    '--signature' { $i++; if ($i -lt $Arguments.Count) { $signatureFile = $Arguments[$i] } }
                    default { throw "Unknown kb query option: $($Arguments[$i])" }
                }
            }
            if (-not $category -or -not $signatureFile) { throw 'kb query requires --category and --signature' }
            $signature = Get-Content -LiteralPath $signatureFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            $script:PlaybookConfig = $knowledge
            $script:PlaybookLogPath = [IO.Path]::GetFullPath($logPath)
            $null = Rebuild-VSPlaybook
            Search-VSPlaybook -Category $category -Signature $signature -TopK $knowledge.top_k -MinScore $knowledge.min_score | ConvertTo-Json -Depth 50
            return
        }
        throw "Unknown kb command: $($Arguments[1])"
    }
    throw "Unknown command: $($Arguments[0])"
}

function New-VSReport {
    param([string]$RunId, [object[]]$Records)
    $categories = @($Records | Group-Object category | ForEach-Object {
        $group = $_.Group
        [pscustomobject]@{ category = $_.Name; total = $group.Count; playbook_hits = @($group | Where-Object playbook_matched).Count; succeeded = @($group | Where-Object status -eq 'success').Count; skipped = @($group | Where-Object status -eq 'skipped').Count; escalated = @($group | Where-Object status -eq 'escalated').Count }
    })
    $hits = @($Records | Where-Object playbook_matched).Count
    return [pscustomobject]@{ run_id = $RunId; total = $Records.Count; playbook_hits = $hits; hit_rate = if ($Records.Count) { $hits / $Records.Count } else { 0 }; categories = $categories; successes = @($Records | Where-Object status -eq 'success'); skipped = @($Records | Where-Object status -eq 'skipped'); escalations = @($Records | Where-Object status -eq 'escalated') }
}

function Format-VSReportMarkdown {
    param([Parameter(Mandatory)][object]$Report)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# VeriSolve run $($Report.run_id)")
    $lines.Add('')
    $lines.Add("Total: $($Report.total) | Playbook hits: $($Report.playbook_hits) | Hit rate: $([math]::Round($Report.hit_rate * 100, 2))%")
    $lines.Add('')
    $lines.Add('| Category | Total | Hits | Success | Skipped | Escalated |')
    $lines.Add('|---|---:|---:|---:|---:|---:|')
    foreach ($row in $Report.categories) { $lines.Add("| $($row.category) | $($row.total) | $($row.playbook_hits) | $($row.succeeded) | $($row.skipped) | $($row.escalated) |") }
    foreach ($section in @(@('Successes', $Report.successes), @('Skipped', $Report.skipped), @('Escalations', $Report.escalations))) {
        $lines.Add('')
        $lines.Add("## $($section[0])")
        if (-not $section[1].Count) { $lines.Add('- None'); continue }
        foreach ($item in $section[1]) { $lines.Add("- $($item.problem_id) [$($item.category)] — $($item.reason)") }
    }
    return $lines -join "`n"
}

Export-ModuleMember -Function Get-VSVerificationConfig, Get-VSAllowedFailCategories, New-VSProblem, New-VSVerdict, New-VSChange, New-VSResolverFailureFeedback, New-VSTriageResult, Sort-VSScheduledProblems, Get-VSHighRiskCategories, Test-VSHighRisk, Start-VSPlaybook, Submit-VSPlaybookEvent, Wait-VSPlaybookWriter, Rebuild-VSPlaybook, Get-VSPlaybookSnapshot, Get-VSPlaybookIoDiagnostics, New-VSPlaybookPort, Search-VSPlaybook, Stop-VSPlaybook, Test-VSChangeGuardrail, Invoke-VSRunspaceBatch, Invoke-VSProblemResolution, Invoke-VSCommand
