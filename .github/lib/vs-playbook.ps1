# Deterministic Playbook primitives: event validation, replay, confidence, scoring.
# Pure functions over in-memory values. No filesystem access, no locks, no inference.

function Get-VSLaplaceConfidence {
    param([Parameter(Mandatory)][int]$Successes, [Parameter(Mandatory)][int]$Failures)
    if ($Successes -lt 0 -or $Failures -lt 0) { throw 'Playbook counters must be non-negative.' }
    return ([double]$Successes + 1.0) / ([double]$Successes + [double]$Failures + 2.0)
}

function Get-VSNormalizedKeywords {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Keywords)
    $result = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($keyword in @($Keywords)) {
        if ($keyword -isnot [string]) { continue }
        $normalized = $keyword.Trim().ToLowerInvariant()
        if ($normalized.Length -eq 0) { continue }
        if ($seen.Add($normalized)) { $result.Add($normalized) }
    }
    return @($result)
}

function Get-VSTextKeywords {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $tokens = [regex]::Split($Text.ToLowerInvariant(), '[^a-z0-9_]+')
    return @(Get-VSNormalizedKeywords -Keywords @($tokens))
}

function Get-VSKeywordCosine {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Left,
        [AllowNull()][AllowEmptyCollection()][object[]]$Right
    )
    $leftSet = @(Get-VSNormalizedKeywords -Keywords @($Left))
    $rightSet = @(Get-VSNormalizedKeywords -Keywords @($Right))
    if ($leftSet.Count -eq 0 -or $rightSet.Count -eq 0) { return 0.0 }
    $shared = 0
    foreach ($token in $leftSet) { if ($rightSet -ccontains $token) { $shared++ } }
    return [double]$shared / [Math]::Sqrt([double]$leftSet.Count * [double]$rightSet.Count)
}

function Get-VSTruthyFeatureKeys {
    param([AllowNull()]$Features)
    if ($Features -isnot [System.Collections.IDictionary]) { return @() }
    $keys = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Features.Keys) {
        $value = $Features[$key]
        if ($value -eq $true -or ($value -is [string] -and $value.Length -gt 0)) { $keys.Add(([string]$key).ToLowerInvariant()) }
    }
    return @($keys)
}

function Get-VSFeatureJaccard {
    param([AllowNull()]$Left, [AllowNull()]$Right)
    $leftKeys = @(Get-VSTruthyFeatureKeys -Features $Left)
    $rightKeys = @(Get-VSTruthyFeatureKeys -Features $Right)
    if ($leftKeys.Count -eq 0 -and $rightKeys.Count -eq 0) { return 0.0 }
    $union = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $shared = 0
    foreach ($key in $leftKeys) { $null = $union.Add($key) }
    foreach ($key in $rightKeys) {
        $null = $union.Add($key)
        if ($leftKeys -ccontains $key) { $shared++ }
    }
    if ($union.Count -eq 0) { return 0.0 }
    return [double]$shared / [double]$union.Count
}

function Get-VSPlaybookPatternConfidence {
    param([Parameter(Mandatory)]$Pattern)
    return Get-VSLaplaceConfidence -Successes ([int]$Pattern.stats.successes) -Failures ([int]$Pattern.stats.failures)
}

function Get-VSPlaybookScore {
    param(
        [Parameter(Mandatory)]$Pattern,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Query,
        [Parameter(Mandatory)][System.Collections.IDictionary]$KnowledgeBase
    )
    $embedding = Get-VSKeywordCosine -Left @($Query.keywords) -Right @($Pattern.signature.keywords)
    $feature = Get-VSFeatureJaccard -Left $Query.features -Right $Pattern.signature.features
    $confidence = Get-VSPlaybookPatternConfidence -Pattern $Pattern
    $score = [double]$KnowledgeBase.embedding_weight * $embedding +
        [double]$KnowledgeBase.feature_weight * $feature +
        [double]$KnowledgeBase.confidence_weight * $confidence
    return [pscustomobject]@{
        score = [Math]::Round($score, 10)
        embedding_similarity = [Math]::Round($embedding, 10)
        feature_similarity = [Math]::Round($feature, 10)
        confidence = [Math]::Round($confidence, 10)
    }
}

function Select-VSPlaybookMatches {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Request,
        [Parameter(Mandatory)][System.Collections.IDictionary]$KnowledgeBase
    )
    $topK = if ($null -ne $Request.top_k) { [int]$Request.top_k } else { [int]$KnowledgeBase.top_k }
    $minScore = if ($null -ne $Request.min_score) { [double]$Request.min_score } else { [double]$KnowledgeBase.min_score }
    $category = [string]$Request.category
    $query = [ordered]@{
        keywords = @($Request.signature.keywords)
        features = $Request.signature.features
    }
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($pattern in @($Snapshot.patterns)) {
        if (-not [string]::IsNullOrEmpty($category) -and [string]$pattern.category -cne $category) { continue }
        $scored = Get-VSPlaybookScore -Pattern $pattern -Query $query -KnowledgeBase $KnowledgeBase
        if ($scored.score -lt $minScore) { continue }
        $matched.Add([pscustomobject]@{
            pattern_id = [string]$pattern.pattern_id
            category = [string]$pattern.category
            solution_summary = [string]$pattern.solution_summary
            score = $scored.score
            confidence = $scored.confidence
            embedding_similarity = $scored.embedding_similarity
            feature_similarity = $scored.feature_similarity
            stats = [pscustomobject]@{ successes = [int]$pattern.stats.successes; failures = [int]$pattern.stats.failures }
            downgraded = ($scored.confidence -lt [double]$KnowledgeBase.low_conf_threshold)
        })
    }
    $ordered = @($matched | Sort-Object -Property `
        @{ Expression = 'score'; Descending = $true }, `
        @{ Expression = 'confidence'; Descending = $true }, `
        @{ Expression = 'pattern_id'; Descending = $false })
    if ($topK -ge 0 -and $ordered.Count -gt $topK) { $ordered = @($ordered[0..($topK - 1)]) }
    return @($ordered)
}

function Test-VSPlaybookEvent {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Value -isnot [System.Collections.IDictionary]) {
        $errors.Add('Playbook event must be an object.')
        return [pscustomobject]@{ valid = $false; errors = @($errors) }
    }
    $v = $Config.verification
    $domain = @($Config.categories.category_values)
    switch -CaseSensitive ([string]$Value.type) {
        'ArchiveEvent' {
            $pattern = $Value.pattern
            if ($pattern -isnot [System.Collections.IDictionary]) {
                $errors.Add('ArchiveEvent.pattern must be an object.')
                break
            }
            if ([string]::IsNullOrWhiteSpace([string]$pattern.pattern_id)) { $errors.Add('ArchiveEvent.pattern.pattern_id is required.') }
            if (@($domain) -cnotcontains [string]$pattern.category) { $errors.Add("ArchiveEvent.pattern.category must be one of $($domain -join '|').") }
            if ($null -eq $pattern.solution_summary) { $errors.Add('ArchiveEvent.pattern.solution_summary is required.') }
            else {
                $length = Get-VSCodePointLength ([string]$pattern.solution_summary)
                if ($length -lt [int]$v.playbook_solution_summary_min_length -or $length -gt [int]$v.playbook_solution_summary_max_length) {
                    $errors.Add("solution_summary must be $($v.playbook_solution_summary_min_length)..$($v.playbook_solution_summary_max_length) code points (actual $length).")
                }
            }
            $signature = $pattern.signature
            if ($signature -isnot [System.Collections.IDictionary]) { $errors.Add('ArchiveEvent.pattern.signature must be an object.'); break }
            if ($signature.keywords -isnot [System.Collections.IList]) {
                $errors.Add('ArchiveEvent.pattern.signature.keywords must be an array.')
            } else {
                $count = @($signature.keywords).Count
                if ($count -gt [int]$v.signature_keywords_max_count) { $errors.Add("signature.keywords must contain at most $($v.signature_keywords_max_count) items (actual $count).") }
                foreach ($keyword in @($signature.keywords)) {
                    if ($keyword -isnot [string]) { $errors.Add('signature.keywords entries must be strings.'); continue }
                    if ((Get-VSCodePointLength $keyword) -gt [int]$v.signature_keyword_max_length) { $errors.Add("signature keyword must be at most $($v.signature_keyword_max_length) code points.") }
                }
            }
            if ($signature.features -isnot [System.Collections.IDictionary]) { $errors.Add('ArchiveEvent.pattern.signature.features must be an object.') }
        }
        'ConfidenceUpdateEvent' {
            if ([string]::IsNullOrWhiteSpace([string]$Value.pattern_id)) { $errors.Add('ConfidenceUpdateEvent.pattern_id is required.') }
            if (@('success', 'failure') -cnotcontains [string]$Value.outcome) { $errors.Add("ConfidenceUpdateEvent.outcome must be 'success' or 'failure'.") }
        }
        'SkipEvent' {
            if ([string]::IsNullOrWhiteSpace([string]$Value.problem_id)) { $errors.Add('SkipEvent.problem_id is required.') }
        }
        'ReviewRejectEvent' {
            if ([string]::IsNullOrWhiteSpace([string]$Value.problem_id)) { $errors.Add('ReviewRejectEvent.problem_id is required.') }
        }
        default {
            $errors.Add("Unsupported playbook event type '$($Value.type)'. Allowed: ArchiveEvent, ConfidenceUpdateEvent, SkipEvent, ReviewRejectEvent.")
        }
    }
    return [pscustomobject]@{ valid = ($errors.Count -eq 0); errors = @($errors) }
}

function Invoke-VSPlaybookReplay {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Events
    )
    $patterns = [ordered]@{}
    $skips = [System.Collections.Generic.List[object]]::new()
    $rejects = [System.Collections.Generic.List[object]]::new()
    $sequence = 0
    foreach ($event in @($Events)) {
        if ($null -eq $event) { continue }
        $sequence++
        switch -CaseSensitive ([string]$event.type) {
            'ArchiveEvent' {
                $patternId = [string]$event.pattern.pattern_id
                if (-not $patterns.Contains($patternId)) {
                    $patterns[$patternId] = [ordered]@{
                        pattern_id = $patternId
                        category = [string]$event.pattern.category
                        signature = [ordered]@{
                            keywords = @($event.pattern.signature.keywords)
                            features = $event.pattern.signature.features
                        }
                        solution_summary = [string]$event.pattern.solution_summary
                        stats = [ordered]@{ successes = 0; failures = 0; uses = 0; last_event_seq = $sequence }
                    }
                }
                $entry = $patterns[$patternId]
                $entry.stats.successes = [int]$entry.stats.successes + 1
                $entry.stats.uses = [int]$entry.stats.uses + 1
                $entry.stats.last_event_seq = $sequence
            }
            'ConfidenceUpdateEvent' {
                $patternId = [string]$event.pattern_id
                if (-not $patterns.Contains($patternId)) { throw "ConfidenceUpdateEvent references unknown pattern '$patternId' at event $sequence." }
                $entry = $patterns[$patternId]
                if ([string]$event.outcome -ceq 'success') { $entry.stats.successes = [int]$entry.stats.successes + 1 }
                else { $entry.stats.failures = [int]$entry.stats.failures + 1 }
                $entry.stats.uses = [int]$entry.stats.uses + 1
                $entry.stats.last_event_seq = $sequence
            }
            'SkipEvent' {
                $skips.Add([pscustomobject]@{ problem_id = [string]$event.problem_id; seq = $sequence })
            }
            'ReviewRejectEvent' {
                $patternId = [string]$event.pattern_id
                if (-not [string]::IsNullOrWhiteSpace($patternId) -and $patterns.Contains($patternId)) {
                    $entry = $patterns[$patternId]
                    $entry.stats.failures = [int]$entry.stats.failures + 1
                    $entry.stats.last_event_seq = $sequence
                }
                $rejects.Add([pscustomobject]@{ problem_id = [string]$event.problem_id; pattern_id = $patternId; seq = $sequence })
            }
            default { throw "Unsupported playbook event type '$($event.type)' at event $sequence." }
        }
    }
    return [pscustomobject]@{
        sequence = $sequence
        patterns = $patterns
        skips = @($skips)
        review_rejects = @($rejects)
    }
}

function Get-VSPlaybookSnapshot {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Events,
        [Parameter(Mandatory)][System.Collections.IDictionary]$KnowledgeBase
    )
    $replay = Invoke-VSPlaybookReplay -Events $Events
    $published = [System.Collections.Generic.List[object]]::new()
    foreach ($patternId in ($replay.patterns.Keys | Sort-Object)) {
        $pattern = $replay.patterns[$patternId]
        $confidence = Get-VSPlaybookPatternConfidence -Pattern $pattern
        $published.Add([ordered]@{
            pattern_id = $pattern.pattern_id
            category = $pattern.category
            signature = [ordered]@{
                keywords = @($pattern.signature.keywords)
                features = $pattern.signature.features
            }
            solution_summary = $pattern.solution_summary
            stats = [ordered]@{
                successes = [int]$pattern.stats.successes
                failures = [int]$pattern.stats.failures
                uses = [int]$pattern.stats.uses
                last_event_seq = [int]$pattern.stats.last_event_seq
                confidence = [Math]::Round($confidence, 10)
                downgraded = ($confidence -lt [double]$KnowledgeBase.low_conf_threshold)
            }
        })
    }
    return [ordered]@{
        version = [int]$replay.sequence
        published_at = [DateTimeOffset]::UtcNow.ToString('o')
        patterns = @($published)
    }
}
