# VeriSolve pipeline workflow

The VeriSolve custom Agent is a deterministic coordinator, not a third
reasoning-agent kind. Only TriageAgent and ResolverAgent reason. Follow these
steps; delegate only to the two configured subagents.

## Startup and batch

1. Read all `config/verisolve.*.json` and validate the three JSON Schemas.
   Ensure config limits match schema bounds. Fail fast unless built-in
   fail_categories are preserved and each additional category is unique,
   differs from all built-ins, is 1–64 chars, and matches `[a-z0-9_]+`.
   Parse `high_risk_categories` by comma/trim/remove empty; default to
   `incident`, and fail fast for values outside `bug|incident|maintenance|other`.
2. Read `playbook/snapshot.json` once and pin the immutable snapshot in memory.
   Query it without filesystem IO or locks.
3. Call `fetch-backlog` until no cursor remains. For every fetched Problem,
   assign a strictly increasing per-batch `ingest_seq` in fetch order before
   concurrent triage. Keep `ingest_seq` in the scheduler envelope; do not add
   it to the VSProblem contract.
4. Delegate each single Problem to a fresh TriageAgent context. Validate exact
   output shape and controlled enums. Triage input may be the complete
   VSProblem; Resolver projections may not contain any open-container field.
5. Call `playbook-query` for each Problem using the pinned snapshot. Use
   `rank-and-schedule` deterministic runtime logic: category priority from
   config, then within category Playbook hit first, match score descending,
   severity descending, `created_at` ascending, `ingest_seq` ascending.

## Problem attempts

1. Run each scheduled Problem in its own task, bounded by configured
   concurrency. Attempt matching solutions in confidence-descending then
   match-score-descending order up to `max_playbook_try`. If needed, make one
   initial new-solution attempt plus `retry_per_bug` further solution attempts.
2. Every resolve/retry uses a new ResolverAgent context and only this
   allowlist: `problem_id`, triage `category`, triage `severity`, triage
   `keywords`, and optional one-line `summary` extracted from raw and capped at
   200 code points. A Playbook projection is `pattern_id` and
   `solution_summary` only. Retry adds `previous_summary`<=200,
   `fail_category`, `top_errors`<=3. Never pass open containers, logs,
   metadata, acceptance criteria, or verdict evidence in resolve mode.
3. Validate VSChange against `contracts/vs-change.schema.json`. Call
   `guardrail-check` before `apply-change` and `verify-change`. If rejected,
   do not call either.
4. Acquire deterministic target locks; call idempotent `apply-change`. Start
   verification with `verify-change/start.ps1`; it must return promptly and
   persist the verification ID. Do not wait, sleep, or poll in this workflow
   turn. Continue with other Problems; persist enough bounded workflow state
   to resume later.
5. Do not archive or retry a problem-solution attempt until check returns a
   completed result. On a later turn, call `verify-change/check.ps1` once. It
   checks at most `check_batch_limit` entries and never waits. Completed
   results are processed and acknowledged after workflow actions are durable.
6. Only a VSVerdict returned by the configured Oracle has authority over
   `ok`. `timeout` and `oracle_error` are infrastructure failures. Retry
   verification up to `infra_retry` without consuming a business attempt or
   creating a Resolver context. Other failed verdicts consume the current
   solution attempt; revert idempotently and retry only if
   `retry_per_bug` permits.
7. After `Verdict.ok == true` only, if the triage category is high-risk, run
   `high-risk-review.workflow.md` in a fresh ResolverAgent review context. The
   review projection contains only `diff` and explicitly extracted bounded
   acceptance criteria. Review returns `{approved:boolean,reason<=200}`. A
   rejection fails/reverts that solution attempt and queues ReviewRejectEvent.
8. Accepted changes queue ArchiveEvent and confidence updates. Exhausted
   solution attempts queue one SkipEvent and enter Escalation. Infrastructure
   exhaustion is reported separately and never increments `retry_per_bug`.

## Batch boundary

`playbook-commit` enqueues validated events. Exactly one writer serializes
append-only writes to `playbook/events.log`; its IO is outside the event loop.
Replay and confidence calculations are deterministic runtime operations.
Atomically publish a new immutable snapshot only at the batch boundary.

## Resumption

On each new Copilot turn, inspect `playbook/pending-verifications.json` first.
Use bounded check calls, handle completed Verdicts, persist workflow decisions,
then acknowledge processed verification IDs. Never synchronously wait for a
pipeline, regardless of its duration.

If the user wants verification results to advance without reopening Copilot,
the optional `poll-verifications` skill starts an independent PowerShell worker
that runs the same bounded check on `poll_interval_sec`. Copilot still only
reads the state file; the worker never reasons about results.

## Concurrency

Honour `max_parallel_triage` while triaging and `max_parallel_resolution` while
resolving. Both are configured in `config/verisolve.system.json`.
