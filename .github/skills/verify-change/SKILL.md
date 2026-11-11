---
name: verify-change
description: Start a nonblocking external verification and harvest results with bounded checks.
---

# verify-change

## When to use

After deterministic guardrail acceptance and an idempotent apply. Use
`start.ps1` once per change; use `check.ps1` on later Copilot turns or from
the optional poller.

## Input / output

Start request JSON contains `change`, the bounded Problem projection,
acceptance criteria only if later high-risk review needs it, triage category,
source pattern ID, and business attempt number. Start idempotently applies by
`change_id`, invokes configured Oracle `start`, writes pending state under an
exclusive lock, and immediately returns
`{verification_id,problem_id,started_at}`.

Check reads at most `check_batch_limit` entries, calls Oracle `check` once per
selected ID, and immediately returns completed verdicts, pending IDs, and
infrastructure failures. Completed entries remain durable until the workflow
acknowledges them after handling. `check.ps1 -AcknowledgeVerificationIds`
removes only acknowledged IDs under the same lock.

## Nonblocking and idempotency guarantees

Pipeline duration belongs to the external provider. `start.ps1` never waits for
pipeline completion or polls. `check.ps1` performs one bounded status request
per selected entry and never sleeps/retries in place. Apply/revert are
idempotent by `change_id`; Oracle start uses configured `change_id` idempotency
key. Pending reads/writes are protected by exclusive lock and atomic
replacement. Concurrent checks merge by verification ID so new starts are
never lost.

## Prohibited

No long waits, polling loops, resolver calls, verdict inference, or direct
unlocked writes. Oracle `timeout` / `oracle_error` are infrastructure failures,
not solution failures. Retry infra independently up to `infra_retry`; do not
consume `retry_per_bug`.

## Called by

The VeriSolve coordinator in `.github/agents/verisolve.agent.md` and the
pipeline workflow. The optional `poll-verifications` Skill may call check mode.

## Config dependencies

`config/verisolve.verification.json#pending_verifications_path`,
`check_batch_limit`, `poll_interval_sec`; `config/verisolve.system.json`
lock/retry settings; `config/verisolve.cli.json#executor` and `oracle.start`,
`oracle.check`.
