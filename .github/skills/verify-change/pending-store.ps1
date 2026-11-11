# Pending-verification state store: shared lock, atomic replacement, bounded external calls.
# Every read-modify-write of the pending file must go through Invoke-VSPendingStateLock.

. (Join-Path $PSScriptRoot '..\..\lib\vs-filelock.ps1')

function Read-VSPendingState {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) {
        return [ordered]@{ schema_version = 1; pending = @(); completed = @(); infra_failed = @() }
    }
    $state = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -AsHashtable
    if ($state.schema_version -ne 1 -or $state.pending -isnot [System.Collections.IList] -or
        $state.completed -isnot [System.Collections.IList] -or $state.infra_failed -isnot [System.Collections.IList]) {
        throw "Pending verification state '$Path' has an invalid shape."
    }
    return $state
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
