---
name: playbook-commit
description: Queue validated Playbook events and drain them through a single append-only writer.
---

# playbook-commit

## When to use

`enqueue` for archive, confidence updates, skips, and review rejections.
`drain` at a batch boundary. `rebuild` after a crash or for `kb rebuild`.
`status` for observability.

## Input / output

- `-Operation enqueue -PayloadPath <json array>` — validates every event
  (`ArchiveEvent`, `ConfidenceUpdateEvent`, `SkipEvent`, `ReviewRejectEvent`),
  appends the JSON lines to `playbook/event-queue.log` under the writer lock,
  and returns `{queued, queue_depth}` immediately. Nothing is replayed here.
- `-Operation drain` — the single writer. Takes at most `writer_batch_size`
  queued events in submission order, appends them to `playbook/events.log`,
  clears the consumed entries atomically, republishes the snapshot atomically,
  and returns `{appended, queue_remaining, snapshot_version, pattern_count}`.
- `-Operation rebuild` — replays the append-only log, drops a truncated tail,
  and rewrites the snapshot; returns `{version, pattern_count,
  skipped_partial_tail}`.
- `-Operation status` — returns `{queue_depth, log_events, snapshot_version}`.
- `-Operation read-log` / `write-snapshot` — raw log access and atomic
  publication for advanced tooling.

Confidence is Laplace-smoothed `(successes+1)/(successes+failures+2)`;
`ReviewRejectEvent` counts as a failure for negative feedback; patterns below
`low_conf_threshold` are published as `downgraded`.

## Prohibited

- Never write the log outside the writer lock, never edit the log in place, and
  never publish a snapshot mid-batch.
- `SkipEvent` and rejected attempts must not create or mutate a pattern, so
  failed attempts cannot pollute the Playbook.
- The script performs IO and deterministic replay only; it never decides that a
  change succeeded.

## Called by

`agents/verisolve.agent.md`, `workflows/run-pipeline.workflow.md`, and
`scripts/verisolve.ps1 kb drain|rebuild|stats`.

## Config dependencies

`config/verisolve.knowledge_base.json#event_log_path`, `event_queue_path`,
`snapshot_path`, `writer_lock_path`, `writer_batch_size`,
`writer_flush_timeout_seconds`, `writer_poll_interval_ms`,
`low_conf_threshold`; `config/verisolve.verification.json` for event bounds;
`config/verisolve.system.json#playbook_refresh_every_batches`.
