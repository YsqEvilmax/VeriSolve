# VeriSolve

VeriSolve is a verification-driven continuous problem-resolution core. Domain
specific input, change formats, and verification are isolated behind adapters.
The only reasoning-agent contracts are `TriageAgent` and `ResolverAgent`.

## Layout

- `core/` — PowerShell contracts, deterministic orchestration, ranking, guardrails, and the playbook.
- `adapters/` — PowerShell adapter contracts and the ExampleAdapter implementation.
- `config/verisolve.*.json` — system, agent, category, verification, knowledge-base, and CLI settings.
- `scripts/verisolve.ps1` — PowerShell 7 CLI dispatcher; command-specific scripts only forward arguments.
- `tests/` — executable PowerShell acceptance checks for platform invariants.

## Runtime flow

Triage returns only structured category and keywords. The core groups and ranks
problems, resolves them in bounded independent tasks, and verifies changes
asynchronously after deterministic guardrails. Every resolver generation,
retry, and high-risk review gets a fresh context. Playbook events are queued
and appended by a single writer; updated snapshots are published at batch
boundaries.

## Running tests

From the repository root, run the tests directly in PowerShell 7:

```powershell
pwsh -NoProfile -File .\verisolve\tests\Test-VeriSolve.ps1
```

## CLI

Run the ExampleAdapter smoke flow:

```powershell
pwsh -File .\verisolve\scripts\verisolve.ps1 run --backlog example
```

The `example` source is deliberately empty. This exercises adapter startup,
triage/scheduling, run persistence, and report generation without inventing
backlog data. A JSON backlog file can also be supplied with `--backlog`.

```powershell
pwsh -File .\verisolve\scripts\verisolve.ps1 status --run <run-id>
pwsh -File .\verisolve\scripts\verisolve.ps1 report --run <run-id> --format md
pwsh -File .\verisolve\scripts\verisolve.ps1 kb query --category bug --signature .\signature.json
pwsh -File .\verisolve\scripts\verisolve.ps1 kb stats
pwsh -File .\verisolve\scripts\verisolve.ps1 kb rebuild
```

`core/VeriSolve.Core.psm1` owns contracts, validation, deterministic
orchestration, run persistence, knowledge-base queries, and report formatting.
The PowerShell entry point and command wrappers run directly in PowerShell 7;
they do not launch Python. Run records are stored under the configured run
store. Markdown and JSON reports include category totals, playbook hits, hit
rate, and success, skipped, and escalation lists.

## Unified VS contracts and adapters

`core/VeriSolve.Core.psm1` defines the validated `VSProblem`, `VSVerdict`, and
`VSChange` data contracts and mockable adapter operations. Fail categories can
be extended by appending values under `additional_fail_categories`; existing
values and configured boundary limits are fixed and validated from JSON.

The playbook implementation is in `core/VeriSolve.Core.psm1`. Its
`Submit-VSPlaybookEvent` only enqueues; a single writer batches append-only log
writes on a separate PowerShell runspace. Log replay also reads on a separate
PowerShell runspace. Snapshot reads and search operate only on the published
in-memory snapshot. Knowledge-base weights, confidence threshold, writer batch
size, and log path are configured in
`config/verisolve.knowledge_base.json`.

## Triage and resolution

Triage returns only the controlled category, severity, and keywords.
Scheduling pins one playbook snapshot for the batch, applies configured
category priority and the stable in-category ranking keys.

The resolution core applies guardrails before the executor or Oracle and uses
the configured finite retry count. Successful changes are archived only after
Oracle acceptance and any required independent review. Failed items enter the
escalation queue after retries. `high_risk_categories` in
`config/verisolve.verification.json` is a comma-separated allowlist of triage
categories and defaults to `incident`; review receives only the generated diff
and `raw.acceptance_criteria`. Resolver requests contain a bounded projection,
not the full Problem: ID, triage category, severity, keywords, and optional
single-line `raw.summary` (maximum 200 Unicode code points). Matched playbook
context is limited to the pattern ID and solution summary; retries receive only
the previous summary, failure category, and up to three top errors.
