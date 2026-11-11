# Acceptance-suite harness: assertions, sandboxes, and bounded child-process invocation.
$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$script:Passed = 0
$script:Failed = 0
$script:FailureMessages = [System.Collections.Generic.List[string]]::new()

function Write-VSSection {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Add-VSPass {
    param([Parameter(Mandatory)][string]$Name)
    $script:Passed++
    Write-Host "  PASS $Name" -ForegroundColor Green
}

function Add-VSFail {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Message)
    $script:Failed++
    $script:FailureMessages.Add("$Name :: $Message")
    Write-Host "  FAIL $Name :: $Message" -ForegroundColor Red
}

function Reset-VSTestEnvironment {
    # Parallel runspaces share the process environment; clear mock fixtures between cases so a stale
    # path can never leak into the next child process.
    foreach ($name in @('VERISOLVE_MOCK_ORACLE_MODE', 'VERISOLVE_MOCK_ORACLE_COUNTER', 'VERISOLVE_MOCK_ORACLE_FAIL_CATEGORY', 'VERISOLVE_MOCK_ORACLE_DELAY_MS', 'VERISOLVE_MOCK_EXECUTOR_COUNTER')) {
        [Environment]::SetEnvironmentVariable($name, $null)
    }
}

function Invoke-VSTest {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    Reset-VSTestEnvironment
    try {
        & $Body
        Add-VSPass $Name
    } catch {
        Add-VSFail $Name $_.Exception.Message
    } finally {
        Reset-VSTestEnvironment
    }
}

function Assert-VSTrue {
    param([AllowNull()]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-VSEqual {
    param([AllowNull()]$Expected, [AllowNull()]$Actual, [Parameter(Mandatory)][string]$Message)
    if ("$Expected" -cne "$Actual") { throw "$Message (expected '$Expected', actual '$Actual')" }
}

function Assert-VSThrows {
    param([Parameter(Mandatory)][scriptblock]$Body, [Parameter(Mandatory)][string]$Message, [string]$Match = '')
    $threw = $false
    $text = ''
    try { $null = & $Body }
    catch { $threw = $true; $text = $_.Exception.Message }
    if (-not $threw) { throw "Expected failure: $Message" }
    if ($Match -and $text -notlike "*$Match*") { throw "Expected failure containing '$Match' for $Message (actual: $text)" }
}

function New-VSSandbox {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("verisolve-acceptance-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $path -Force
    Copy-Item -LiteralPath (Join-Path $script:Root '.github') -Destination (Join-Path $path '.github') -Recurse -Force
    $playbook = Join-Path $path '.github\playbook'
    foreach ($artifact in @('event-queue.log', 'playbook-writer.lock', 'pending-verifications.lock', 'poller.log', 'poller.error.log')) {
        $candidate = Join-Path $playbook $artifact
        if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force }
    }
    Get-ChildItem -LiteralPath $playbook -Filter 'verify-start-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    return $path
}

function Remove-VSSandbox {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-VSSandboxGithub {
    param([Parameter(Mandatory)][string]$Sandbox)
    return (Join-Path $Sandbox '.github')
}

function Invoke-VSScript {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][object[]]$Arguments = @(),
        [AllowNull()][hashtable]$Env = @{}
    )
    $saved = @{}
    foreach ($key in $Env.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, [string]$Env[$key])
    }
    try {
        $output = & $script:Pwsh -NoProfile -File $Path @($Arguments | ForEach-Object { [string]$_ }) 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
    $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    return [pscustomobject]@{ exit_code = $exitCode; text = $text }
}

function Invoke-VSScriptJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][object[]]$Arguments = @(),
        [AllowNull()][hashtable]$Env = @{}
    )
    $result = Invoke-VSScript -Path $Path -Arguments $Arguments -Env $Env
    if ($result.exit_code -ne 0) { throw "Script '$Path' failed: $($result.text)" }
    return $result.text | ConvertFrom-Json -AsHashtable
}

function New-VSRequestFile {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)]$Payload
    )
    $path = Join-Path $Directory ("request-" + [guid]::NewGuid().ToString('N') + '.json')
    $json = ConvertTo-Json -InputObject $Payload -Depth 100
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
    return $path
}

function New-VSChangeFixture {
    param(
        [string]$ChangeId = 'chg-1',
        [string]$ProblemId = 'prob-1',
        [string]$Summary = 'apply bounded fix',
        [string]$Diff = "--- a/src/app.ps1`n+++ b/src/app.ps1`n+Write-Output 'fixed'`n",
        [string[]]$Targets = @('src/app.ps1'),
        [string]$PlaybookRef = $null
    )
    return [ordered]@{
        change_id = $ChangeId
        problem_id = $ProblemId
        diff = $Diff
        summary = $Summary
        targets = @($Targets)
        playbook_ref = $PlaybookRef
        change_at = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function New-VSProblemFixture {
    param(
        [string]$ProblemId = 'prob-1',
        [string]$Category = 'bug',
        [string]$Severity = 'high',
        [string[]]$Keywords = @('null-reference', 'checkout'),
        [string]$CreatedAt = '2026-01-01T00:00:00Z'
    )
    return [ordered]@{
        problem_id = $ProblemId
        source = 'example'
        raw = [ordered]@{ summary = 'checkout throws'; logs = @('do-not-project-me') }
        category = $Category
        severity = $Severity
        priority_score = 2.5
        signature = [ordered]@{ keywords = @($Keywords); features = [ordered]@{ area = 'checkout' }; location = 'src/checkout.ps1' }
        created_at = $CreatedAt
        metadata = [ordered]@{ adapter = 'example' }
    }
}

function New-VSVerdictFixture {
    param(
        [bool]$Ok = $false,
        [AllowNull()][object]$FailCategory = 'tests_failed',
        [string[]]$TopErrors = @('one failure')
    )
    return [ordered]@{
        ok = $Ok
        fail_category = if ($null -eq $FailCategory) { $null } else { [string]$FailCategory }
        evidence = [ordered]@{
            top_errors = @($TopErrors)
            signals = [ordered]@{ build_ok = $false }
            artifacts = [ordered]@{}
        }
        verdict_at = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Get-VSConfigSet {
    param([Parameter(Mandatory)][string]$GithubRoot)
    $set = [ordered]@{}
    foreach ($name in @('system', 'agents', 'categories', 'verification', 'knowledge_base', 'cli')) {
        $set[$name] = Get-Content -LiteralPath (Join-Path $GithubRoot "config\verisolve.$name.json") -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    }
    return $set
}

function Set-VSConfigValue {
    param(
        [Parameter(Mandatory)][string]$GithubRoot,
        [Parameter(Mandatory)][string]$ConfigName,
        [Parameter(Mandatory)][string]$JsonPath,
        [AllowNull()]$Value
    )
    $path = Join-Path $GithubRoot "config\verisolve.$ConfigName.json"
    $config = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $config[$JsonPath] = $Value
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $config -Depth 100), [Text.UTF8Encoding]::new($false))
}

function Write-VSReport {
    Write-Host ''
    Write-Host ("passed={0} failed={1}" -f $script:Passed, $script:Failed) -ForegroundColor ($(if ($script:Failed -eq 0) { 'Green' } else { 'Red' }))
    if ($script:Failed -gt 0) {
        Write-Host 'Failures:' -ForegroundColor Red
        foreach ($message in $script:FailureMessages) { Write-Host "  - $message" -ForegroundColor Red }
    }
    return ($script:Failed -eq 0)
}
