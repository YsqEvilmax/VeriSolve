---
name: playbook-commit
description: Queue validated Playbook events for the single append-only writer.
---

# playbook-commit

## When to use

After an accepted resolution, failed pattern attempt, review rejection, or
final escalation.

## Input

An ordered UTF-8 JSON batch file passed to `run.ps1` as `-PayloadPath`. The
writer action appends exactly typed events:

- `ArchiveEvent`: `type,pattern_id,category,signature,solution`
- `ConfidenceUpdateEvent`: `type,pattern_id,success`
- `SkipEvent`: `type,pattern_id`
- `ReviewRejectEvent`: `type,pattern_id`

`pattern_id` is at most 128 code points; `solution` is at most 300 code points.

## Output

Return `{queued:true,event_count:n}` immediately after enqueue. The event queue
has one consumer. That consumer serializes append operations and calls
`run.ps1` with an ordered batch; the IO worker never computes confidence or
rebuilds the snapshot.

## Snapshot publication

At a batch boundary, read the append-only log using `run.ps1` on an independent
IO task; never read it on the workflow event loop. Replay returned event data
and compute Laplace confidence `(successes + 1) / (successes + failures + 2)`
in deterministic runtime operations. Pass the completed snapshot to
`run.ps1` for atomic file replacement, then atomically swap the in-memory
immutable snapshot. For skips and review rejections of known patterns, update
failure statistics; unknown patterns do not create entries.

## Prohibited

No direct concurrent file writes, in-place log edits, partial snapshot
publication, or archive on failed/escalated attempts.
