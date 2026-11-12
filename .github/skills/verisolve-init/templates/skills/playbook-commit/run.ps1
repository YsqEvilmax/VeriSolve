param(
    [Parameter(Mandatory)]
    [ValidateSet('enqueue', 'drain', 'rebuild', 'read-log', 'status', 'write-snapshot')]
    [string]$Operation,
    [string]$PayloadPath,
    [string]$GithubRoot
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\lib\vs-contracts.ps1')
. (Join-Path $PSScriptRoot '..\..\lib\vs-filelock.ps1')
. (Join-Path $PSScriptRoot '..\..\lib\vs-playbook.ps1')

$github = if ([string]::IsNullOrWhiteSpace($GithubRoot)) {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
} else {
    [IO.Path]::GetFullPath($GithubRoot)
}
$config = Read-VSConfigSet -GithubRoot $github
Assert-VSConfigSet -Config $config
$knowledgeBase = $config.knowledge_base

$eventLogPath = [IO.Path]::GetFullPath((Join-Path $github ([string]$knowledgeBase.event_log_path)))
$queuePath = [IO.Path]::GetFullPath((Join-Path $github ([string]$knowledgeBase.event_queue_path)))
$snapshotPath = [IO.Path]::GetFullPath((Join-Path $github ([string]$knowledgeBase.snapshot_path)))
$lockPath = [IO.Path]::GetFullPath((Join-Path $github ([string]$knowledgeBase.writer_lock_path)))
$lockTimeout = [int]$knowledgeBase.writer_flush_timeout_seconds
$lockPoll = [int]$knowledgeBase.writer_poll_interval_ms

function Read-VSLogLines {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{ lines = @(); partial_tail = $null } }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ($text.Length -eq 0) { return [pscustomobject]@{ lines = @(); partial_tail = $null } }
    $partial = $null
    if (-not $text.EndsWith("`n")) {
        $lastNewline = $text.LastIndexOf("`n")
        $partial = if ($lastNewline -ge 0) { $text.Substring($lastNewline + 1) } else { $text }
        $text = if ($lastNewline -ge 0) { $text.Substring(0, $lastNewline + 1) } else { '' }
    }
    $lines = @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 })
    return [pscustomobject]@{ lines = $lines; partial_tail = $partial }
}

function ConvertFrom-VSEventLines {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines, [Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $events = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($line in $Lines) {
        $index++
        try { $event = $line | ConvertFrom-Json -AsHashtable }
        catch { throw "Playbook event line $index is not valid JSON: $($_.Exception.Message)" }
        $validation = Test-VSPlaybookEvent -Value $event -Config $Config
        if (-not $validation.valid) { throw "Playbook event line $index is invalid: $($validation.errors -join ' ')" }
        $events.Add($event)
    }
    return @($events)
}

function Publish-VSSnapshot {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $log = Read-VSLogLines -Path $eventLogPath
    $events = ConvertFrom-VSEventLines -Lines $log.lines -Config $Config
    $snapshot = Get-VSPlaybookSnapshot -Events $events -KnowledgeBase $knowledgeBase
    Write-VSJsonFile -Path $snapshotPath -Value $snapshot
    return [pscustomobject]@{
        version = [int]$snapshot.version
        patterns = @($snapshot.patterns).Count
        skipped_partial_tail = (-not [string]::IsNullOrWhiteSpace([string]$log.partial_tail))
    }
}

switch ($Operation) {
    'enqueue' {
        if ([string]::IsNullOrWhiteSpace($PayloadPath)) { throw 'enqueue requires -PayloadPath with a JSON event array.' }
        $payload = Get-Content -LiteralPath ([IO.Path]::GetFullPath($PayloadPath)) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $events = @($payload)
        if ($events.Count -eq 0) { [Console]::Out.Write('{"queued":0}'); exit 0 }
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($event in $events) {
            $validation = Test-VSPlaybookEvent -Value $event -Config $config
            if (-not $validation.valid) { throw "Rejected playbook event: $($validation.errors -join ' ')" }
            $lines.Add((ConvertTo-Json -InputObject $event -Depth 100 -Compress))
        }
        # Submitting returns as soon as the durable append completes; nothing is replayed here.
        $depth = Invoke-VSFileLock -Path $lockPath -TimeoutSeconds $lockTimeout -PollIntervalMilliseconds $lockPoll -Action {
            [IO.File]::AppendAllLines($queuePath, $lines, [Text.UTF8Encoding]::new($false))
            (Read-VSLogLines -Path $queuePath).lines.Count
        }
        [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{ queued = $lines.Count; queue_depth = [int]$depth }) -Compress))
    }
    'drain' {
        # Single writer: exactly one drain runs at a time and consumes queue order.
        $result = Invoke-VSFileLock -Path $lockPath -TimeoutSeconds $lockTimeout -PollIntervalMilliseconds $lockPoll -Action {
            $queue = Read-VSLogLines -Path $queuePath
            $batchSize = [int]$knowledgeBase.writer_batch_size
            $batch = @($queue.lines | Select-Object -First $batchSize)
            if ($batch.Count -eq 0) { return [pscustomobject]@{ appended = 0; remaining = @($queue.lines).Count } }
            $events = ConvertFrom-VSEventLines -Lines $batch -Config $config
            $payloadLines = @($events | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 100 -Compress })
            [IO.File]::AppendAllLines($eventLogPath, [string[]]$payloadLines, [Text.UTF8Encoding]::new($false))
            $remaining = @($queue.lines | Select-Object -Skip $batch.Count)
            $content = if ($remaining.Count -eq 0) { '' } else { ($remaining -join "`n") + "`n" }
            Write-VSAtomicFile -Path $queuePath -Content $content
            [pscustomobject]@{ appended = $batch.Count; remaining = $remaining.Count }
        }
        $published = Publish-VSSnapshot -Config $config
        [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                        appended = [int]$result.appended
                        queue_remaining = [int]$result.remaining
                        snapshot_version = [int]$published.version
                        pattern_count = [int]$published.patterns
                    }) -Compress))
    }
    'rebuild' {
        $published = Publish-VSSnapshot -Config $config
        [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                        version = [int]$published.version
                        pattern_count = [int]$published.patterns
                        skipped_partial_tail = [bool]$published.skipped_partial_tail
                    }) -Compress))
    }
    'read-log' {
        if ([IO.File]::Exists($eventLogPath)) { [Console]::Out.Write([IO.File]::ReadAllText($eventLogPath, [Text.Encoding]::UTF8)) }
    }
    'status' {
        $queue = Read-VSLogLines -Path $queuePath
        $log = Read-VSLogLines -Path $eventLogPath
        $snapshotVersion = if ([IO.File]::Exists($snapshotPath)) {
            [int](([IO.File]::ReadAllText($snapshotPath, [Text.Encoding]::UTF8) | ConvertFrom-Json).version)
        } else { -1 }
        [Console]::Out.Write((ConvertTo-Json -InputObject ([ordered]@{
                        queue_depth = @($queue.lines).Count
                        log_events = @($log.lines).Count
                        snapshot_version = $snapshotVersion
                    }) -Compress))
    }
    'write-snapshot' {
        if ([string]::IsNullOrWhiteSpace($PayloadPath)) { throw 'write-snapshot requires -PayloadPath with a snapshot JSON document.' }
        if (-not (Test-Path -LiteralPath $snapshotPath)) { throw 'Snapshot publication requires a rebuilt snapshot path.' }
        $payload = [IO.File]::ReadAllText([IO.Path]::GetFullPath($PayloadPath), [Text.Encoding]::UTF8)
        Write-VSAtomicFile -Path $snapshotPath -Content $payload
        [Console]::Out.Write('{"published":true}')
    }
}
