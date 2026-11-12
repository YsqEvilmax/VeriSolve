# Pending-verification state store: shared lock, atomic replacement, bounded external calls.
# Every read-modify-write of the pending file must go through Invoke-VSPendingStateLock.

. (Join-Path $PSScriptRoot '..\..\lib\vs-filelock.ps1')

function New-VSEmptyPendingState {
    return [ordered]@{ schema_version = 1; pending = @(); completed = @(); infra_failed = @() }
}

function Read-VSPendingState {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return New-VSEmptyPendingState }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { return New-VSEmptyPendingState }
    $parsed = $text | ConvertFrom-Json -AsHashtable
    if ($text.TrimStart().StartsWith('[')) {
        # scaffold.ps1 seeds an empty array; accept a bare array as the pending list and upgrade to
        # the canonical object shape on the next write. ConvertFrom-Json yields no output for `[]`,
        # so the array wrapper is what preserves the empty case.
        return [ordered]@{ schema_version = 1; pending = @($parsed); completed = @(); infra_failed = @() }
    }
    if ($parsed.schema_version -ne 1 -or $parsed.pending -isnot [System.Collections.IList] -or
        $parsed.completed -isnot [System.Collections.IList] -or $parsed.infra_failed -isnot [System.Collections.IList]) {
        throw "Pending verification state '$Path' has an invalid shape."
    }
    return $parsed
}

function Write-VSPendingState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$State)
    Write-VSJsonFile -Path $Path -Value $State
}

function Get-VSPendingStateSnapshot {
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$PollIntervalMilliseconds
    )
    return Invoke-VSFileLock -Path $LockPath -TimeoutSeconds $TimeoutSeconds -PollIntervalMilliseconds $PollIntervalMilliseconds -Action {
        Read-VSPendingState $StatePath
    }
}

function Invoke-VSPendingStateLock {
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$PollIntervalMilliseconds,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    # Captured under a distinct name: a nested scriptblock that referenced $Action would resolve the
    # lock helper's own parameter and recurse into itself.
    $mutate = $Action
    return Invoke-VSFileLock -Path $LockPath -TimeoutSeconds $TimeoutSeconds -PollIntervalMilliseconds $PollIntervalMilliseconds -Action {
        $state = Read-VSPendingState $StatePath
        $result = & $mutate $state
        Write-VSPendingState $StatePath $state
        $result
    }
}

function Invoke-VSExternalJsonCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )
    return Invoke-VSCommandJson -Command $Command -Arguments $Arguments -Json $Json -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $WorkingDirectory
}
