# Contract, configuration, and high-risk boundary acceptance cases.
$githubRoot = $script:BaseGithub
$config = Get-VSConfigSet -GithubRoot $githubRoot

Write-VSSection 'Configuration and JSON Schemas'

Invoke-VSTest 'config-set-loads-and-validates' {
    Assert-VSConfigSet -Config $config
    Assert-VSEqual 2 @($config.agents.agent_kinds).Count 'exactly two reasoning agent kinds are configured'
}

Invoke-VSTest 'schema-files-are-draft-2020-12-and-strict' {
    foreach ($name in @('vs-problem', 'vs-verdict', 'vs-change')) {
        $schema = Get-Content -LiteralPath (Join-Path $githubRoot "contracts\$name.schema.json") -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert-VSTrue ($schema.'$schema' -like '*2020-12*') "$name declares draft 2020-12"
        Assert-VSEqual $false $schema.additionalProperties "$name rejects unknown fields"
    }
}

Invoke-VSTest 'false-fail-category-requires-enum-when-config-extension-is-invalid' {
    $sandbox = New-VSSandbox
    try {
        $sandboxGithub = Get-VSSandboxGithub -Sandbox $sandbox
        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'additional_fail_categories' -Value @('tests_failed')
        $bad = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSThrows { Assert-VSConfigSet -Config $bad } 'duplicate of a built-in fail_category fails fast' 'conflicts with a built-in'

        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'additional_fail_categories' -Value @('Security-Regression')
        $bad = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSThrows { Assert-VSConfigSet -Config $bad } 'invalid characters fail fast' 'violates'

        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'additional_fail_categories' -Value @(('x' * 65))
        $bad = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSThrows { Assert-VSConfigSet -Config $bad } 'over-long additional category fails fast' 'must be 1..64'

        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'additional_fail_categories' -Value @('security_regression')
        $good = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSConfigSet -Config $good
        $extended = New-VSVerdictFixture -Ok $false -FailCategory 'security_regression'
        Assert-VSTrue (Test-VSVerdict -Value $extended -Config $good).valid 'configured additional fail_category is accepted'

        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'additional_fail_categories' -Value @('security_regression', 'security_regression')
        $bad = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSThrows { Assert-VSConfigSet -Config $bad } 'duplicate additional categories fail fast' 'duplicated'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Write-VSSection 'VSProblem boundaries'

Invoke-VSTest 'problem-accepts-valid-fixture' {
    $result = Test-VSProblem -Value (New-VSProblemFixture) -Config $config
    Assert-VSTrue $result.valid "fixture valid: $($result.errors -join '; ')"
}

Invoke-VSTest 'problem-id-128-accepted-129-rejected' {
    $problem = New-VSProblemFixture -ProblemId ('p' * 128)
    Assert-VSTrue (Test-VSProblem -Value $problem -Config $config).valid 'problem_id at 128 code points is accepted'
    $problem.problem_id = 'p' * 129
    $result = Test-VSProblem -Value $problem -Config $config
    Assert-VSTrue (-not $result.valid) 'problem_id at 129 code points is rejected'
    Assert-VSTrue ($result.errors -join ' ' -like '*problem_id*') 'rejection names problem_id'
}

Invoke-VSTest 'problem-keywords-20-accepted-21-rejected' {
    $problem = New-VSProblemFixture
    $problem.signature.keywords = @(1..20 | ForEach-Object { "kw$_" })
    Assert-VSTrue (Test-VSProblem -Value $problem -Config $config).valid '20 keywords accepted'
    $problem.signature.keywords = @(1..21 | ForEach-Object { "kw$_" })
    Assert-VSTrue (-not (Test-VSProblem -Value $problem -Config $config).valid) '21 keywords rejected'
}

Invoke-VSTest 'problem-keyword-64-accepted-65-rejected' {
    $problem = New-VSProblemFixture
    $problem.signature.keywords = @('k' * 64)
    Assert-VSTrue (Test-VSProblem -Value $problem -Config $config).valid '64 code point keyword accepted'
    $problem.signature.keywords = @('k' * 65)
    Assert-VSTrue (-not (Test-VSProblem -Value $problem -Config $config).valid) '65 code point keyword rejected'
}

Invoke-VSTest 'problem-keyword-counts-code-points-not-utf16-units' {
    $problem = New-VSProblemFixture
    $astral = [char]::ConvertFromUtf32(0x1F600)
    $problem.signature.keywords = @($astral * 64)
    Assert-VSTrue (Test-VSProblem -Value $problem -Config $config).valid '64 astral code points accepted'
    $problem.signature.keywords = @($astral * 65)
    Assert-VSTrue (-not (Test-VSProblem -Value $problem -Config $config).valid) '65 astral code points rejected'
}

Invoke-VSTest 'problem-rejects-unknown-and-missing-fields' {
    $problem = New-VSProblemFixture
    $problem.raw_note = 'extra'
    Assert-VSTrue (-not (Test-VSProblem -Value $problem -Config $config).valid) 'unknown top-level field rejected'
    $problem = New-VSProblemFixture
    $problem.Remove('metadata')
    Assert-VSTrue (-not (Test-VSProblem -Value $problem -Config $config).valid) 'missing metadata rejected'
    $problem = New-VSProblemFixture
    $problem.signature.extra = 'x'
    Assert-VSTrue (-not (Test-VSProblem -Value $problem -Config $config).valid) 'unknown signature field rejected'
}

Invoke-VSTest 'problem-severity-and-priority-score-types' {
    foreach ($severity in @('critical', 'high', 'medium', 'low', $null)) {
        $problem = New-VSProblemFixture
        $problem.severity = $severity
        Assert-VSTrue (Test-VSProblem -Value $problem -Config $config).valid "severity '$severity' accepted"
    }
    $problem = New-VSProblemFixture
    $problem.severity = 'urgent'
    Assert-VSTrue (-not (Test-VSProblem -Value $problem -Config $config).valid) 'unknown severity rejected'

    $problem = New-VSProblemFixture
    $problem.priority_score = $null
    Assert-VSTrue (Test-VSProblem -Value $problem -Config $config).valid 'null priority_score accepted'
    $problem.priority_score = $true
    Assert-VSTrue (-not (Test-VSProblem -Value $problem -Config $config).valid) 'boolean priority_score rejected'
    $problem.priority_score = [double]::NaN
    Assert-VSTrue (-not (Test-VSProblem -Value $problem -Config $config).valid) 'NaN priority_score rejected'
    $problem.priority_score = '3'
    Assert-VSTrue (-not (Test-VSProblem -Value $problem -Config $config).valid) 'string priority_score rejected'
}

Invoke-VSTest 'problem-created-at-must-be-iso8601' {
    $problem = New-VSProblemFixture
    $problem.created_at = '2026-13-45'
    Assert-VSTrue (-not (Test-VSProblem -Value $problem -Config $config).valid) 'non ISO-8601 created_at rejected'
}

Write-VSSection 'VSVerdict boundaries'

Invoke-VSTest 'verdict-top-errors-3-accepted-4-rejected' {
    $verdict = New-VSVerdictFixture -Ok $false -FailCategory 'tests_failed' -TopErrors @('a', 'b', 'c')
    Assert-VSTrue (Test-VSVerdict -Value $verdict -Config $config).valid '3 top_errors accepted'
    $verdict = New-VSVerdictFixture -Ok $false -FailCategory 'tests_failed' -TopErrors @('a', 'b', 'c', 'd')
    $result = Test-VSVerdict -Value $verdict -Config $config
    Assert-VSTrue (-not $result.valid) '4 top_errors rejected'
    Assert-VSTrue ($result.errors -join ' ' -like '*top_errors*') 'rejection names top_errors'
}

Invoke-VSTest 'verdict-fail-category-rules' {
    $failed = New-VSVerdictFixture -Ok $false -FailCategory $null
    Assert-VSTrue (-not (Test-VSVerdict -Value $failed -Config $config).valid) 'ok=false with null fail_category rejected'
    $passed = New-VSVerdictFixture -Ok $true -FailCategory $null -TopErrors @()
    Assert-VSTrue (Test-VSVerdict -Value $passed -Config $config).valid 'ok=true with null fail_category accepted'
    $bogus = New-VSVerdictFixture -Ok $false -FailCategory 'not_a_category'
    Assert-VSTrue (-not (Test-VSVerdict -Value $bogus -Config $config).valid) 'unknown fail_category rejected'
    $wrongCase = New-VSVerdictFixture -Ok $false -FailCategory 'TESTS_FAILED'
    Assert-VSTrue (-not (Test-VSVerdict -Value $wrongCase -Config $config).valid) 'fail_category matching is case-sensitive'
    foreach ($category in @(Get-VSFailCategoryAllowList -Config $config)) {
        $candidate = New-VSVerdictFixture -Ok $false -FailCategory $category
        Assert-VSTrue (Test-VSVerdict -Value $candidate -Config $config).valid "built-in fail_category '$category' accepted"
    }
}

Invoke-VSTest 'verdict-evidence-shape-is-closed' {
    $verdict = New-VSVerdictFixture
    $verdict.evidence.raw_log = 'leak'
    Assert-VSTrue (-not (Test-VSVerdict -Value $verdict -Config $config).valid) 'extra evidence field rejected'
    $verdict = New-VSVerdictFixture
    $verdict.evidence.signals.build_ok = 'yes'
    Assert-VSTrue (-not (Test-VSVerdict -Value $verdict -Config $config).valid) 'non-boolean signal rejected'
}

Write-VSSection 'VSChange boundaries'

Invoke-VSTest 'change-summary-200-accepted-201-rejected' {
    $change = New-VSChangeFixture -Summary ('s' * 200)
    Assert-VSTrue (Test-VSChange -Value $change -Config $config).valid '200 code point summary accepted'
    $change = New-VSChangeFixture -Summary ('s' * 201)
    $result = Test-VSChange -Value $change -Config $config
    Assert-VSTrue (-not $result.valid) '201 code point summary rejected'
    Assert-VSTrue ($result.errors -join ' ' -like '*summary*') 'rejection names summary'
    Assert-VSTrue (-not (Test-VSChange -Value (New-VSChangeFixture -Summary '') -Config $config).valid) 'empty summary rejected'
}

Invoke-VSTest 'change-summary-counts-astral-code-points' {
    $astral = [char]::ConvertFromUtf32(0x1F600)
    Assert-VSTrue (Test-VSChange -Value (New-VSChangeFixture -Summary ($astral * 200)) -Config $config).valid '200 astral summary accepted'
    Assert-VSTrue (-not (Test-VSChange -Value (New-VSChangeFixture -Summary ($astral * 201)) -Config $config).valid) '201 astral summary rejected'
}

Invoke-VSTest 'change-diff-100000-accepted-100001-rejected' {
    Assert-VSTrue (Test-VSChange -Value (New-VSChangeFixture -Diff ('d' * 100000)) -Config $config).valid '100000 code point diff accepted'
    Assert-VSTrue (-not (Test-VSChange -Value (New-VSChangeFixture -Diff ('d' * 100001)) -Config $config).valid) '100001 code point diff rejected'
    Assert-VSTrue (-not (Test-VSChange -Value (New-VSChangeFixture -Diff '') -Config $config).valid) 'empty diff rejected'
}

Invoke-VSTest 'change-targets-1-and-50-accepted-0-and-51-rejected' {
    Assert-VSTrue (Test-VSChange -Value (New-VSChangeFixture -Targets @('a')) -Config $config).valid '1 target accepted'
    Assert-VSTrue (Test-VSChange -Value (New-VSChangeFixture -Targets @(1..50 | ForEach-Object { "f$_" })) -Config $config).valid '50 targets accepted'
    Assert-VSTrue (-not (Test-VSChange -Value (New-VSChangeFixture -Targets @()) -Config $config).valid) '0 targets rejected'
    Assert-VSTrue (-not (Test-VSChange -Value (New-VSChangeFixture -Targets @(1..51 | ForEach-Object { "f$_" })) -Config $config).valid) '51 targets rejected'
}

Invoke-VSTest 'change-id-and-problem-id-bounds' {
    Assert-VSTrue (Test-VSChange -Value (New-VSChangeFixture -ChangeId ('c' * 128)) -Config $config).valid 'change_id 128 accepted'
    Assert-VSTrue (-not (Test-VSChange -Value (New-VSChangeFixture -ChangeId ('c' * 129)) -Config $config).valid) 'change_id 129 rejected'
    Assert-VSTrue (-not (Test-VSChange -Value (New-VSChangeFixture -ProblemId ('p' * 129)) -Config $config).valid) 'problem_id 129 rejected'
}

Invoke-VSTest 'change-rejects-unknown-fields' {
    $change = New-VSChangeFixture
    $change.confidence = 0.9
    Assert-VSTrue (-not (Test-VSChange -Value $change -Config $config).valid) 'unknown change field rejected'
}

Write-VSSection 'Agent projections and retry feedback bounds'

Invoke-VSTest 'triage-output-accepts-only-controlled-enums' {
    $valid = [ordered]@{ category = 'bug'; severity = 'high'; keywords = @('a', 'b') }
    Assert-VSTrue (Test-VSTriageOutput -Value $valid -Config $config).valid 'valid triage output accepted'
    $bad = [ordered]@{ category = 'security'; severity = 'high'; keywords = @() }
    Assert-VSTrue (-not (Test-VSTriageOutput -Value $bad -Config $config).valid) 'out-of-domain triage category rejected'
    $bad = [ordered]@{ category = 'bug'; severity = 'high'; keywords = @('a'); explanation = 'because' }
    Assert-VSTrue (-not (Test-VSTriageOutput -Value $bad -Config $config).valid) 'prose field rejected'
    $bad = [ordered]@{ category = 'bug'; severity = 'high'; keywords = @('k' * 65) }
    Assert-VSTrue (-not (Test-VSTriageOutput -Value $bad -Config $config).valid) 'over-long keyword rejected'
}

Invoke-VSTest 'resolve-projection-rejects-open-containers' {
    $clean = [ordered]@{ problem_id = 'p1'; category = 'bug'; severity = 'high'; keywords = @('a'); summary = 'checkout throws' }
    Assert-VSTrue (Test-VSResolverProjection -Value $clean -Config $config).valid 'clean projection accepted'
    foreach ($container in @('raw', 'features', 'artifacts', 'metadata')) {
        $dirty = [ordered]@{ problem_id = 'p1'; category = 'bug'; severity = 'high'; keywords = @(); $container = [ordered]@{ log = 'secret' } }
        $result = Test-VSResolverProjection -Value $dirty -Config $config
        Assert-VSTrue (-not $result.valid) "open container '$container' rejected"
        Assert-VSTrue ($result.errors -join ' ' -like "*$container*") "rejection names '$container'"
    }
    $nested = [ordered]@{ problem_id = 'p1'; category = 'bug'; severity = 'high'; keywords = @(); summary = 'x'; extra = [ordered]@{ metadata = @{ a = 1 } } }
    Assert-VSTrue (-not (Test-VSResolverProjection -Value $nested -Config $config).valid) 'nested open container rejected'
}

Invoke-VSTest 'retry-feedback-bounds' {
    $retry = [ordered]@{
        problem_id = 'p1'; category = 'bug'; severity = 'high'; keywords = @('a')
        previous_summary = 's' * 200; fail_category = 'tests_failed'; top_errors = @('a', 'b', 'c')
    }
    Assert-VSTrue (Test-VSResolverProjection -Value $retry -Config $config).valid 'bounded retry feedback accepted'
    $retry.previous_summary = 's' * 201
    Assert-VSTrue (-not (Test-VSResolverProjection -Value $retry -Config $config).valid) '201 retry summary rejected'
    $retry.previous_summary = 's'
    $retry.top_errors = @('a', 'b', 'c', 'd')
    Assert-VSTrue (-not (Test-VSResolverProjection -Value $retry -Config $config).valid) '4 retry top_errors rejected'
    $retry.top_errors = @('a')
    $retry.fail_category = 'BOGUS'
    Assert-VSTrue (-not (Test-VSResolverProjection -Value $retry -Config $config).valid) 'retry fail_category must be an allowed enum'
    $retry.fail_category = 'tests_failed'
    $retry.log_full_text = 'x'
    Assert-VSTrue (-not (Test-VSResolverProjection -Value $retry -Config $config).valid) 'retry feedback cannot add log fields'
}

Invoke-VSTest 'review-projection-is-diff-and-acceptance-criteria-only' {
    $review = [ordered]@{ diff = 'x'; acceptance_criteria = 'tests must pass' }
    Assert-VSTrue (Test-VSResolverProjection -Value $review -Config $config -Mode 'review').valid 'review projection accepted'
    $leak = [ordered]@{ diff = 'x'; acceptance_criteria = 'y'; summary = 'generation note' }
    Assert-VSTrue (-not (Test-VSResolverProjection -Value $leak -Config $config -Mode 'review').valid) 'review projection rejects extra fields'
    $long = [ordered]@{ diff = 'x'; acceptance_criteria = ('a' * 4001) }
    Assert-VSTrue (-not (Test-VSResolverProjection -Value $long -Config $config -Mode 'review').valid) 'over-long acceptance criteria rejected'
}

Write-VSSection 'High-risk category resolution'

Invoke-VSTest 'high-risk-defaults-single-multi-and-empty-items' {
    $sandbox = New-VSSandbox
    try {
        $sandboxGithub = Get-VSSandboxGithub -Sandbox $sandbox
        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'high_risk_categories' -Value $null
        $cfg = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSEqual 'incident' ((Get-VSHighRiskCategories -Config $cfg) -join ',') 'unset high_risk_categories defaults to incident'

        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'high_risk_categories' -Value ''
        $cfg = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSEqual 'incident' ((Get-VSHighRiskCategories -Config $cfg) -join ',') 'empty high_risk_categories defaults to incident'

        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'high_risk_categories' -Value 'maintenance'
        $cfg = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSEqual 'maintenance' ((Get-VSHighRiskCategories -Config $cfg) -join ',') 'single value parsed'

        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'high_risk_categories' -Value ' incident , maintenance ,, '
        $cfg = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSEqual 'incident,maintenance' ((Get-VSHighRiskCategories -Config $cfg) -join ',') 'multi value trimmed and empty items removed'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'high-risk-out-of-domain-and-wrong-case-fail-fast' {
    $sandbox = New-VSSandbox
    try {
        $sandboxGithub = Get-VSSandboxGithub -Sandbox $sandbox
        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'high_risk_categories' -Value 'incident,security'
        $cfg = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSThrows { Get-VSHighRiskCategories -Config $cfg } 'out-of-domain value fails fast' 'outside the controlled domain'
        Assert-VSThrows { Assert-VSConfigSet -Config $cfg } 'configuration assertion fails fast' 'outside the controlled domain'

        Set-VSConfigValue -GithubRoot $sandboxGithub -ConfigName 'verification' -JsonPath 'high_risk_categories' -Value 'Incident'
        $cfg = Get-VSConfigSet -GithubRoot $sandboxGithub
        Assert-VSThrows { Get-VSHighRiskCategories -Config $cfg } 'case-sensitive matching fails fast' 'outside the controlled domain'
    } finally { Remove-VSSandbox -Path $sandbox }
}

Invoke-VSTest 'high-risk-null-and-out-of-domain-triage-warn-not-fail' {
    $domain = @($config.categories.category_values)
    $high = @(Get-VSHighRiskCategories -Config $config)
    $nullResult = Test-VSHighRisk -TriageCategory $null -HighRiskCategories $high -Domain $domain
    Assert-VSEqual $false $nullResult.is_high_risk 'null triage category is not high risk'
    Assert-VSTrue ($nullResult.warning -like '*null*') 'null triage category warns'

    $invalid = Test-VSHighRisk -TriageCategory 'security' -HighRiskCategories $high -Domain $domain
    Assert-VSEqual $false $invalid.is_high_risk 'out-of-domain triage category is not high risk'
    Assert-VSTrue ($invalid.warning -like '*out_of_domain*') 'out-of-domain triage category warns'

    $incident = Test-VSHighRisk -TriageCategory 'incident' -HighRiskCategories $high -Domain $domain
    Assert-VSEqual $true $incident.is_high_risk 'configured incident is high risk'
    Assert-VSEqual $null $incident.warning 'no warning for a controlled category'

    $bug = Test-VSHighRisk -TriageCategory 'bug' -HighRiskCategories $high -Domain $domain
    Assert-VSEqual $false $bug.is_high_risk 'bug is not high risk by default'
}

Invoke-VSTest 'laplace-confidence-and-downgrade-flag' {
    Assert-VSEqual 0.6666666667 ([Math]::Round((Get-VSLaplaceConfidence -Successes 1 -Failures 0), 10)) 'laplace (1+1)/(1+0+2)'
    Assert-VSEqual 0.5 ([Math]::Round((Get-VSLaplaceConfidence -Successes 1 -Failures 1), 10)) 'laplace (1+1)/(1+1+2)'
    Assert-VSEqual 0.3333333333 ([Math]::Round((Get-VSLaplaceConfidence -Successes 1 -Failures 3), 10)) 'laplace (1+1)/(1+3+2)'
    Assert-VSThrows { Get-VSLaplaceConfidence -Successes -1 -Failures 0 } 'negative counters rejected'
}
