Set-StrictMode -Version Latest

$corePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'core\VeriSolve.Core.psm1'
if (-not (Get-Command New-VSProblem -ErrorAction SilentlyContinue)) {
    Import-Module $corePath -DisableNameChecking
}

function Assert-VSAdapterPort {
    param(
        [Parameter(Mandatory)][object]$Adapter,
        [Parameter(Mandatory)][string[]]$Methods,
        [Parameter(Mandatory)][string]$Name
    )
    foreach ($method in $Methods) {
        if ($Adapter.PSObject.Properties.Name -cnotcontains $method -or $Adapter.$method -isnot [scriptblock]) {
            throw "$Name adapter must implement scriptblock method '$method'"
        }
    }
}

function Assert-VSAdapterFields {
    param([System.Collections.IDictionary]$Value, [string[]]$Fields, [string]$Name)
    if ($Value.Count -ne $Fields.Count -or @($Value.Keys | Where-Object { $_ -notin $Fields }).Count -gt 0 -or @($Fields | Where-Object { $_ -cnotin @($Value.Keys) }).Count -gt 0) {
        throw "$Name fields do not match the contract"
    }
}

function New-VSExampleAdapter {
    $source = [pscustomobject]@{
        fetchBacklog = {
            param([AllowNull()][string]$Cursor)
            [pscustomobject]@{ problems = @(); next_cursor = $null }
        }
    }
    $executor = [pscustomobject]@{
        apply = {
            param([Parameter(Mandatory)][System.Collections.IDictionary]$Change)
            @{ ok = $true }
        }
        revert = {
            param([Parameter(Mandatory)][System.Collections.IDictionary]$Change)
            $null
        }
    }
    $oracle = [pscustomobject]@{
        judge = {
            param(
                [Parameter(Mandatory)][System.Collections.IDictionary]$Change,
                [Parameter(Mandatory)][System.Collections.IDictionary]$Problem,
                [AllowNull()][Nullable[double]]$Timeout
            )
            @{
                ok = $false
                fail_category = 'unknown'
                evidence = @{ top_errors = @(); signals = @{}; artifacts = @{} }
                verdict_at = [DateTimeOffset]::UtcNow.ToString('o')
            }
        }
        poll = {
            param([Parameter(Mandatory)][string]$ChangeId, [AllowNull()][Nullable[double]]$Timeout)
            $null
        }
    }
    Assert-VSAdapterPort $source @('fetchBacklog') 'VSProblemSourceAdapter'
    Assert-VSAdapterPort $executor @('apply', 'revert') 'VSChangeExecutorAdapter'
    Assert-VSAdapterPort $oracle @('judge', 'poll') 'VSOracleAdapter'
    return [pscustomobject]@{ problemSource = $source; executor = $executor; oracle = $oracle }
}

function New-VSExampleTriageAgent {
    [pscustomobject]@{
        triage = {
            param([Parameter(Mandatory)][System.Collections.IDictionary]$Problem, [Parameter(Mandatory)][string]$PromptRef)
            $category = if ($Problem.category -cin @('bug', 'incident', 'maintenance', 'other')) { $Problem.category } else { 'other' }
            @{ category = $category; severity = $Problem.severity; keywords = @($Problem.signature.keywords) }
        }
    }
}

function New-VSExampleResolverFactory {
    $factory = [pscustomobject]@{
        create = {
            [pscustomobject]@{
                resolve = {
                    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request)
                    $problem = $Request.problem
                    $target = 'example.patch'
                    [ordered]@{
                        change_id = "example-$([guid]::NewGuid().ToString('N'))"
                        problem_id = $problem.problem_id
                        diff = "--- a/$target`n+++ b/$target`n@@`n+example change`n"
                        summary = 'Example change for adapter smoke testing'
                        targets = @($target)
                        playbook_ref = if ($null -ne $Request.pattern) { $Request.pattern.pattern_id } else { $null }
                        change_at = [DateTimeOffset]::UtcNow.ToString('o')
                    }
                }
                review = {
                    param([Parameter(Mandatory)][string]$Diff, [Parameter(Mandatory)][string]$AcceptanceCriteria)
                    $true
                }
            }
        }
    }
    return $factory
}

function New-VSJsonProblemSourceAdapter {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Backlog file not found: $Path" }
    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $data = ConvertFrom-Json -InputObject $content -AsHashtable
    if ($data -is [System.Collections.IDictionary]) {
        Assert-VSAdapterFields $data @('problems') 'backlog'
        $data = $data.problems
    }
    if ($data -isnot [System.Collections.IList]) { throw 'backlog must be a JSON array of VSProblem objects' }
    $problems = @($data | ForEach-Object { New-VSProblem $_ })
    $source = [pscustomobject]@{
        fetchBacklog = {
            param([AllowNull()][string]$Cursor)
            $offset = 0
            if (-not [string]::IsNullOrEmpty($Cursor) -and ($Cursor -notmatch '^\d+$' -or [int]$Cursor -gt $problems.Count)) { throw 'Backlog cursor is out of range' }
            if (-not [string]::IsNullOrEmpty($Cursor)) { $offset = [int]$Cursor }
            $page = @($problems | Select-Object -Skip $offset)
            [pscustomobject]@{ problems = $page; next_cursor = $null }
        }.GetNewClosure()
    }
    Assert-VSAdapterPort $source @('fetchBacklog') 'VSProblemSourceAdapter'
    return $source
}

Export-ModuleMember -Function Assert-VSAdapterPort, New-VSExampleAdapter, New-VSExampleTriageAgent, New-VSExampleResolverFactory, New-VSJsonProblemSourceAdapter
