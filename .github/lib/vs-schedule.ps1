# Deterministic batch scheduler: category grouping and in-category ordering.
# Ordering keys and severity ranks are fully supplied by config; nothing is inferred.

function Get-VSSeverityRank {
    param(
        [AllowNull()][AllowEmptyString()][string]$Severity,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SeverityOrder
    )
    if ([string]::IsNullOrWhiteSpace($Severity)) { return 0 }
    $index = [Array]::IndexOf($SeverityOrder, $Severity)
    if ($index -lt 0) { return 0 }
    return $index + 1
}

function Get-VSCompareValue {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Item,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    switch -CaseSensitive ($Key) {
        'playbook_matched' { return [int]([bool]$Item.playbook_matched) }
        'match_score' { if ($null -eq $Item.match_score) { return 0.0 } return [double]$Item.match_score }
        'priority_score' { if ($null -eq $Item.priority_score) { return 0.0 } return [double]$Item.priority_score }
        'severity' { return Get-VSSeverityRank -Severity ([string]$Item.severity) -SeverityOrder @($Config.categories.severity_order) }
        'created_at' { return [string]$Item.created_at }
        'ingest_seq' { return [long]$Item.ingest_seq }
        default { throw "Unsupported schedule ordering key '$Key'." }
    }
}

function New-VSSortProperty {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][bool]$Descending,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    $expression = { Get-VSCompareValue -Item $_.item -Key $Key -Config $Config }.GetNewClosure()
    return @{ Expression = $expression; Descending = $Descending }
}

function Invoke-VSRankSchedule {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    $order = @($Config.categories.schedule_order)
    if ($order.Count -eq 0) { throw 'categories.schedule_order must not be empty.' }
    foreach ($key in $order) {
        if (@('playbook_matched', 'match_score', 'priority_score', 'severity', 'created_at', 'ingest_seq') -cnotcontains [string]$key) {
            throw "schedule_order contains unsupported key '$key'."
        }
    }

    $enriched = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Items)) {
        $sequence = [long]$item.ingest_seq
        if ($sequence -le 0) { throw "Item '$($item.problem_id)' requires a positive ingest_seq assigned at fetch time." }
        $category = [string]$item.triage_category
        $priority = if ($Config.categories.priority_matrix.Contains($category)) {
            [int]$Config.categories.priority_matrix[$category]
        } else {
            [int]$Config.categories.priority_matrix_default
        }
        $enriched.Add([pscustomobject]@{ item = $item; category = $category; group_priority = $priority })
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($group in ($enriched | Group-Object -Property category)) {
        $properties = @(foreach ($key in $order) {
                New-VSSortProperty -Key $key -Descending ($key -cne 'created_at' -and $key -cne 'ingest_seq') -Config $Config
            })
        $sorted = @($group.Group | Sort-Object -Property $properties)
        $groups.Add([pscustomobject]@{
            category = [string]$group.Name
            group_priority = $group.Group[0].group_priority
            items = @($sorted | ForEach-Object { $_.item })
        })
    }

    $orderedGroups = @($groups | Sort-Object -Property `
        @{ Expression = 'group_priority'; Descending = $true }, `
        @{ Expression = 'category'; Descending = $false })

    $flattened = [System.Collections.Generic.List[string]]::new()
    foreach ($group in $orderedGroups) { foreach ($item in $group.items) { $flattened.Add([string]$item.problem_id) } }

    return [pscustomobject]@{
        schedule_order = @($order)
        groups = @($orderedGroups | ForEach-Object {
                [pscustomobject]@{
                    category = $_.category
                    group_priority = $_.group_priority
                    problem_ids = @($_.items | ForEach-Object { [string]$_.problem_id })
                }
            })
        problem_order = @($flattened)
    }
}
