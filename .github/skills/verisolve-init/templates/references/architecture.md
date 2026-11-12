# VeriSolve architecture

VeriSolve is a verification-driven continuous problem resolution system that
runs as an **AI Agent Assistant hosted by VS Code Copilot**. Reasoning is
confined to two agents; guardrails, scheduling, persistence, and verification
waiting are deterministic code driven entirely by JSON configuration.

This document is released to `.github/references/architecture.md` by
`scaffold.ps1`. It describes the **running system**. Installation mechanics and
Copilot loading constraints are documented in the installer payload at
`.github/skills/verisolve-init/references/loading-and-contracts.md` and are not
repeated here.

---

## 1. Design principles

1. **Two agents only.** Reasoning is confined to `TriageAgent` and
   `ResolverAgent`. Review is a mode of `ResolverAgent`, not a third agent.
   Scheduling, ranking, guardrails, verification waiting, and persistence are
   deterministic code.
2. **Verdict authority is external.** `ResolverAgent` produces changes; it never
   decides success. Only the configured Oracle returns `VSVerdict.ok`, and the
   coordinator reads that boolean.
3. **Bounded agent contexts.** Every resolve attempt, retry, and review starts a
   fresh context. Inputs are allowlisted projections; logs, full Oracle
   evidence, and prior generation history are never injected.
4. **Guardrails before verification.** A change that violates guardrails is
   rejected without invoking the executor or the Oracle.
5. **Verification is two-phase and non-blocking.** `start` triggers the pipeline
   and returns; `check` performs bounded status queries later. No agent waits for
   a multi-hour pipeline inside a single tool call.
6. **Read/write separation for the Playbook.** Readers use an immutable
   in-memory snapshot with no IO and no locks. Writers enqueue events consumed by
   a single writer that appends to a durable log. Snapshots publish only at batch
   boundaries.
7. **Configuration over code.** Every bound, threshold, weight, path, and
   external command is JSON. Nothing domain-specific is hard-coded.

## 2. Released layout

After scaffolding, the workspace contains:

```
.github/
├── agents/
│   ├── verisolve.agent.md      coordinator (user-selected entry point)
│   ├── triage.agent.md         TriageAgent
│   └── resolver.agent.md       ResolverAgent (resolve + review modes)
├── skills/
│   ├── fetch-backlog/          SKILL.md + run.ps1
│   ├── playbook-query/         SKILL.md + run.ps1
│   ├── playbook-commit/        SKILL.md + run.ps1
│   ├── guardrail-check/        SKILL.md + run.ps1
│   ├── apply-change/           SKILL.md + run.ps1 (+ mock-executor.ps1 fixture)
│   ├── verify-change/          SKILL.md + start.ps1 + check.ps1
│   │                           + pending-store.ps1 + mock-start/mock-check fixtures
│   ├── poll-verifications/     SKILL.md + run.ps1
│   ├── rank-and-schedule/      SKILL.md + run.ps1
│   ├── verisolve-cleanup/      SKILL.md + scripts/cleanup.ps1
│   └── verisolve-init/         installer payload (retained; removed by cleanup)
├── config/                     verisolve.{system,agents,categories,
│                               verification,knowledge_base,cli}.json
├── contracts/                  vs-{problem,verdict,change}.schema.json
├── lib/                        vs-{contracts,filelock,playbook,schedule}.ps1
├── playbook/                   events.log, snapshot.json,
│                               pending-verifications.json (seeded as [])
├── references/                 architecture.md (this document)
├── workflows/                  run-pipeline.workflow.md,
│                               high-risk-review.workflow.md
└── copilot-instructions.md     project-level constraints (skipped if present)
```

| Layer | May contain |
| --- | --- |
| Agents (`agents/*.agent.md`) | Instructions, tool lists, bounded input/output contracts |
| Workflows (`workflows/*.workflow.md`) | Ordered steps, branching, retry/escalation policy |
| Skills (`skills/<name>/`) | `SKILL.md` contract plus PowerShell IO transport |
| Shared primitives (`lib/*.ps1`) | Deterministic, fully config-driven validation, locking, replay, scoring, ordering |
| Configuration (`config/`) | Every bound, threshold, weight, path, and command |
| Contracts (`contracts/`) | `VSProblem`, `VSVerdict`, `VSChange` schemas |

No `.psm1` module exists anywhere. PowerShell carries IO transport and
deterministic rule evaluation only — never orchestration, ranking judgment,
verdict authorship, or reasoning.

## 3. The two reasoning agents

### TriageAgent — `agents/triage.agent.md`

Fresh context per Problem. Input is a **bounded projection**, never the full
contract object:

`problem_id`, source `category`, `severity`, `keywords`, and an optional
single-line `summary` extracted from `raw.summary` (≤200 code points). No open
container is ever included.

Output is exactly one object, no prose and no extra keys:

```json
{ "category": "bug", "severity": "high", "keywords": ["null-reference"] }
```

`category` is the controlled enum from `verisolve.categories.json`
(`bug`, `incident`, `maintenance`, `other`); `severity` is
`critical|high|medium|low|null`; keyword count and length are bounded by
`verisolve.agents.json#triage`. The coordinator validates the shape before use.

### ResolverAgent — `agents/resolver.agent.md`

One file, two modes, both with a fresh context each invocation:

- **resolve** — outputs a `VSChange`.
  - Base projection: `problem_id`, triage `category`, `severity`, `keywords`,
    optional `summary` (≤200 code points).
  - An optional matched Playbook entry contributes only `pattern_id` and
    `solution_summary` (0–300 code points).
  - A retry adds only `previous_summary` (≤200 code points), one
    `fail_category`, and at most three `top_errors`.
- **review** — used only for configured high-risk categories after a successful
  verdict. Input is only the change `diff` and the explicitly extracted
  `acceptance_criteria` (0–4000 code points from
  `agents.json#resolver.review_acceptance_criteria_max_length`). Output is
  `{approved: boolean, reason: string ≤200 code points}`.

`ResolverAgent` never receives `raw`, `features`, `artifacts`, `metadata`, logs,
Oracle evidence, or generation history, and never authors `VSVerdict` or `ok`.

### Coordinator — `agents/verisolve.agent.md`

The user-selected entry point and a **deterministic coordinator**, deliberately
not a third reasoning kind. It reads configuration, pins a snapshot, delegates
to the two agents through the `agents` frontmatter field, calls skills in order,
and records state. It never classifies, never writes patches, and never judges
verification.

## 4. Cross-agent context is bounded

Exactly two transfers exist:

1. **TriageAgent → coordinator:** `{category, severity, keywords}`.
2. **ResolverAgent ↔ coordinator:** a `VSChange`, or the bounded retry feedback
   `{previous_summary, fail_category, top_errors}`.

| Agent | Allowed projection fields |
| --- | --- |
| TriageAgent | `problem_id`, source `category`, `severity`, `keywords`, optional `summary` ≤200 |
| ResolverAgent resolve | `problem_id`, triage `category`, `severity`, `keywords`, optional `summary` ≤200, optional `pattern_id` + `solution_summary` 0–300, retry fields |
| ResolverAgent review | `diff`, `acceptance_criteria` |

`raw`, `features`, `artifacts`, and `metadata` are the only open containers and
are **never** projected into any agent input. The validator
(`lib/vs-contracts.ps1` → `Test-VSResolverProjection`) rejects them, including
when nested.

## 5. Contracts and bounds

`contracts/` holds strict JSON Schemas (draft 2020-12, `additionalProperties:
false`). Bounds come from `config/verisolve.verification.json`. All limits are
inclusive and counted in Unicode code points, not UTF-16 units.

| Field | Bound |
| --- | --- |
| `problem_id`, `change_id` | 1–128 |
| `VSChange.summary` | 1–200 |
| Retry `previous_summary` | 1–200 |
| Resolver context `summary` | 0–200 |
| Playbook `solution_summary` | 0–300 |
| `VSChange.diff` | 1–100000 |
| `VSChange.targets` | 1–50 |
| `signature.keywords` | 0–20 items, each ≤64 |
| `evidence.top_errors` | 0–3 strings |

Rules:

- `ok == false` requires a `fail_category`; it must be non-null and an allowed
  value, matched case-sensitively. `ok == true` may use `null`.
- Built-in fail categories are fixed: `pipeline_failed`, `new_issue_introduced`,
  `tests_failed`, `coverage_dropped`, `guardrail_rejected`, `timeout`,
  `oracle_error`, `review_rejected`, `unknown`.
- `additional_fail_categories` may extend the enum. Each value must not
  duplicate a built-in, must be unique, must be 1–64 characters, and must match
  `additional_fail_category_pattern` (`^[a-z0-9_]{1,64}$`). Violation fails at
  startup. Extension never redefines a built-in.
- Only `raw`, `features`, `artifacts`, and `metadata` are open containers, and
  they never enter an agent projection.

## 6. Batch flow

1. **Startup.** Load and validate all `config/verisolve.*.json` and the three
   schemas. Validate the `fail_categories` extension rules. Parse
   `high_risk_categories` (comma split, trim, drop empties, case-sensitive match
   against `bug|incident|maintenance|other`; empty falls back to
   `high_risk_categories_default`, default `incident`). Any invalid value fails
   startup.
2. **Pin snapshot.** Read `playbook/snapshot.json` exactly once and keep it in
   memory for the batch.
3. **Fetch.** Call `fetch-backlog` until no cursor remains. Each Problem is
   validated against `contracts/vs-problem.schema.json`; `ingest_seq` is
   assigned as a strictly increasing per-batch sequence in fetch order and kept
   in the **scheduler envelope only — never inside the VSProblem contract**.
4. **Triage.** Delegate each Problem to a fresh TriageAgent context, bounded by
   `max_parallel_triage`. Validate the exact output shape and controlled enums.
5. **Query and schedule.** Call `playbook-query` per Problem against the pinned
   snapshot, then order deterministically as described in §7.
6. **Resolve.** Run each scheduled Problem in its own task, bounded by
   `max_parallel_resolution`. Attempt matched Playbook solutions in
   **match-score-descending, then confidence-descending, then `pattern_id`
   ascending** order up to `max_playbook_try`. Then make one initial
   new-solution attempt plus up to `retry_per_bug` further attempts. Every
   attempt is a fresh ResolverAgent context.
7. **Guard.** Validate the `VSChange` against `contracts/vs-change.schema.json`
   and call `guardrail-check`. A rejection ends the attempt here — the executor
   and Oracle are never called.
8. **Apply and start.** Acquire the deterministic per-target locks, call
   idempotent `apply-change`, then `verify-change/start.ps1`, which returns
   immediately with a `verification_id`. Do not wait, sleep, or poll in this
   turn. Continue with other Problems.
9. **Check later.** On a later turn call `verify-change/check.ps1` once. It
   inspects at most `check_batch_limit` entries and never waits. Completed
   verdicts are reported; unreported entries stay pending.
10. **Adjudicate.** Only the Oracle's `ok` decides acceptance. A business failure
    reverts idempotently and retries only if `retry_per_bug` permits. A
    high-risk triage category additionally requires a fresh ResolverAgent review
    after `ok == true` (§10).
11. **Archive or escalate.** Accepted changes queue `ArchiveEvent` plus
    confidence updates. Exhausted solution attempts queue exactly one
    `SkipEvent` and enter Escalation. Failed attempts never create or mutate a
    Playbook pattern.
12. **Acknowledge.** Remove processed verification IDs from the pending file
    only after archival/retry/escalation actions are durable.
13. **Batch boundary.** Drain the event queue through the single writer, replay
    the durable log, and publish the next immutable snapshot atomically.

## 7. Ordering

Grouping and ordering are configuration, never code constants.

- **Groups:** `priority_matrix` descending, then category name ascending.
  Categories absent from the matrix use `priority_matrix_default`.
- **Within a group:** `schedule_order` from
  `config/verisolve.categories.json`, default
  `playbook_matched` → `match_score` → `severity` → `created_at` → `ingest_seq`.
  `playbook_matched` and numeric/severity keys sort descending; `created_at` and
  `ingest_seq` sort ascending. Severity rank comes from `severity_order`.
- **Stability:** `ingest_seq` is the final tie-break, so identical items never
  depend on dictionary or completion order.

## 8. Playbook: split read/write

### 8.1 Read path (`playbook-query`)

- `pin` reads `playbook/snapshot.json` once per batch and returns
  `{version, pinned_at, patterns}`.
- `query` receives the pinned copy and performs **zero** filesystem IO, zero
  locks, and zero writes. Deleting the live snapshot file after pinning does not
  change results — this is asserted by the acceptance suite.
- Filters: patterns of another category are excluded; `min_score` and `top_k`
  default to `knowledge_base.min_score` and `knowledge_base.top_k`.
- Score = `embedding_weight × keyword cosine + feature_weight × feature Jaccard
  + confidence_weight × Laplace confidence`. Weights come from config and must
  sum to 1.0 (validated at startup).
- Matches are ordered by `score` descending, `confidence` descending, then
  `pattern_id`.

### 8.2 Write path (`playbook-commit`)

- `enqueue` validates events, appends them to `playbook/event-queue.log` under
  the writer lock, and returns immediately. 100 concurrent submitters lose no
  events and preserve submission order.
- `drain` is the single writer: it consumes at most `writer_batch_size` queued
  events in order, appends them to `playbook/events.log`, clears the consumed
  entries atomically, then republishes the snapshot atomically.
- `rebuild` is the crash-recovery path: it replays the append-only log, discards
  a truncated trailing record, and rewrites the snapshot.
- One pinned snapshot is visible to the whole batch; a new snapshot becomes
  visible only at the next batch boundary. This prevents a single fresh pattern
  from steering same-batch ranking.

Event kinds: `ArchiveEvent`, `ConfidenceUpdateEvent`, `SkipEvent`,
`ReviewRejectEvent`. `SkipEvent` and `ReviewRejectEvent` never create a pattern.

### 8.3 Confidence

```
confidence = (successes + 1) / (successes + failures + 2)
```

`ReviewRejectEvent` counts as a failure, so negative feedback lowers confidence.
A pattern whose confidence falls below `knowledge_base.low_conf_threshold` is
published with `stats.downgraded = true`. Downgrading is a **signal only**: it
does not filter results and does not change sort order. The coordinator decides
whether a downgraded match is still worth attempting.

## 9. Verification: two stages, never blocking

```
start:  apply (idempotent) -> trigger pipeline -> persist pending -> return {verification_id}
check:  read pending -> bounded status queries -> merge completed / retry infra
```

- `start.ps1` takes a **per-change start lock**
  (`cli.start_lock_prefix` + `change_id`), performs the idempotent `apply`
  (`executor.apply`, keyed by `change_id`), triggers `oracle.start` (keyed by
  `idempotency_key`), writes the pending entry under the shared state lock, and
  returns. It never polls. Duplicate concurrent starts for the same change
  converge on one `verification_id`.
- `check.ps1` inspects at most `check_batch_limit` entries, issues exactly one
  `oracle.check` call per inspected entry, and returns `checked_count`,
  `pending_total`, the pending subset, `completed`, and `infra_failed`. No
  waiting and no sleeping.
- `pending-verifications.json` is only mutated while holding
  `cli.lock_file` (FileShare.None) and is replaced atomically (temp file +
  move). Its canonical shape is
  `{schema_version:1, pending:[], completed:[], infra_failed:[]}`. Scaffolding
  seeds it as `[]`; a bare `[]` or a missing file is treated as empty state and
  upgraded to the canonical shape on the first write.
- `-AcknowledgeVerificationIds` removes only the listed IDs, after the workflow
  has durably handled them, so concurrent checks never reprocess a verdict.
- `poll-verifications` optionally runs the same bounded check from an
  independent PowerShell worker on `poll_interval_sec`; Copilot only reads the
  state file.

Failure accounting:

| Kind | `fail_category` | Counts against |
| --- | --- | --- |
| Business failure | any non-infrastructure category | `retry_per_bug` |
| Infrastructure failure | values in `cli.oracle.timeout_categories` (`timeout`, `oracle_error`) | `infra_retry` only |

An Oracle response that violates `contracts/vs-verdict.schema.json` is treated
as an infrastructure failure (`oracle_error`), never as a pass. Infrastructure
retries restart the pipeline without re-applying the change and never create a
Resolver context.

## 10. High-risk review

- Risk uses **only** the controlled TriageAgent `category`. Source `category`,
  `severity`, and adapter identity are never consulted.
- `high_risk_categories` is a comma-separated string in
  `config/verisolve.verification.json`; values outside
  `bug|incident|maintenance|other` fail at startup. Unset or empty falls back to
  `high_risk_categories_default` (`incident`).
- Review runs **only after** `Verdict.ok == true`, in a fresh ResolverAgent
  context containing just the diff and bounded acceptance criteria
  (`workflows/high-risk-review.workflow.md`).
- A rejection emits `ReviewRejectEvent`, reverts the change idempotently, and
  fails that attempt. A null or out-of-domain triage category warns and is
  treated as non-high-risk — it never aborts the run.

## 11. Guardrails

`guardrail-check` is deterministic and config-driven, evaluated **before**
`apply-change` and `verify-change`:

- `forbidden_targets` — glob patterns (default examples: `.git/**`, `secrets/**`).
- `forbidden_patterns` — regular expressions evaluated against the diff.
- `max_patch_files`, `max_patch_bytes` (UTF-8), `max_patch_lines`.

A rejection returns `{accepted:false, fail_category:"guardrail_rejected"}` with
at least one reason. The workflow must not call the executor or the Oracle; the
acceptance suite proves this with a mock call counter that stays untouched.

## 12. Configuration inventory

### `verisolve.system.json`

`max_parallel_triage`, `max_parallel_resolution`, `retry_per_bug`,
`infra_retry`, `ingest_seq{field,assignment,tie_breaker}`,
`playbook_refresh_every_batches`, `file_lock_timeout_seconds`,
`file_lock_poll_interval_ms`, `log_level`.

### `verisolve.agents.json`

`agent_kinds` (`TriageAgent`, `ResolverAgent`), `agent_files{coordinator,
TriageAgent, ResolverAgent}`, `triage{prompt_ref,max_keywords,
max_keyword_length,max_parallel_triage}`, `resolver{modes,
review_uses_same_agent_file,max_summary_length,review_reason_max_length,
review_acceptance_criteria_max_length,retry_context_fields,max_top_errors,
review_context_fields}`.

### `verisolve.categories.json`

`category_values`, `priority_matrix`, `priority_matrix_default`,
`severity_order`, `schedule_order`.

### `verisolve.verification.json`

Contract bounds: `problem_id_max_length`, `change_id_max_length`,
`top_errors_max_count`, `change_summary_max_length`, `retry_summary_max_length`,
`resolver_context_summary_max_length`, `playbook_solution_summary_min_length`,
`playbook_solution_summary_max_length`, `change_diff_max_length`,
`change_targets_min_count`, `change_targets_max_count`,
`signature_keywords_min_count`, `signature_keywords_max_count`,
`signature_keyword_max_length`, `severity_values`.

Enums and risk: `fail_categories`, `additional_fail_categories`,
`additional_fail_category_max_length`, `additional_fail_category_pattern`,
`high_risk_categories`, `high_risk_categories_default`.

Runtime: `max_playbook_try`, `pending_verifications_path`, `check_batch_limit`,
`poll_interval_sec`, `triage{prompt_ref,max_parallel_triage,playbook_top_k,
playbook_min_score}`, `signals{top_errors_max_count}`,
`guardrails{max_patch_files,max_patch_bytes,max_patch_lines,forbidden_targets,
forbidden_patterns}`.

### `verisolve.knowledge_base.json`

`event_log_path`, `event_queue_path`, `snapshot_path`, `writer_lock_path`,
`writer_batch_size`, `writer_flush_timeout_seconds`, `writer_poll_interval_ms`,
`embedding_weight`, `feature_weight`, `confidence_weight`, `low_conf_threshold`,
`top_k`, `min_score`.

### `verisolve.cli.json`

`host`, `command_timeout_seconds`, `problem_sources{example,checkmarx_example,
...}`, `executor{apply,revert}{command,arguments,idempotency_key_field}`,
`oracle{start{command,arguments,request_idempotency_key_field},
check{command,arguments},timeout_categories}`, `run_store_path`,
`pending_verifications_path`, `lock_file`, `start_lock_prefix`, `mock_mode`,
`external_integration_notes`.

`mock_mode` marks the shipped Oracle and executor fixtures as mocks; replace
them before trusting verdicts. Every external integration — including scanners
such as Checkmarx — is expressed only as a configured command. Nothing is
hard-coded.

## 13. Invariants checklist

1. Exactly two reasoning agent kinds; review is a ResolverAgent mode.
2. Exactly two agent context transfers exist, both structured and bounded.
3. Resolver never authors `ok`; verdict authority is external.
4. Fresh context for every resolve, retry, and review.
5. Guardrails precede apply and verify; a rejected change reaches neither.
6. Verification is two-phase; `start` never waits; `check` is bounded.
7. Pending writes are locked and atomically replaced; concurrent checks are safe.
8. Playbook reads use a pinned snapshot with no IO and no locks; writes use a
   queue, a single writer, and an append-only log; publication at batch
   boundaries only.
9. In-category ordering: playbook hit → match score → severity → `created_at` →
   `ingest_seq`.
10. Two failed solution attempts escalate; `timeout`/`oracle_error` count toward
    `infra_retry`, never `retry_per_bug`.
11. Open containers never enter an agent input projection.
12. Configuration is JSON; PowerShell performs IO transport and deterministic,
    config-driven rule evaluation only — never orchestration or reasoning.

## 14. Verification of the design

`tests/acceptance.ps1` releases this payload with the real `scaffold.ps1`, then
runs every case against that scaffold. It covers boundary ±1 contract checks,
open-container rejection (including nested), guardrail/Oracle decoupling via mock
counters, 100-way concurrent Playbook submission, truncated-log recovery,
non-blocking `start`, bounded `check`, idempotent starts under concurrency,
infrastructure-vs-business retry separation, deterministic scheduling,
scaffolding rollback, and uninstall safety.

```powershell
pwsh tests/acceptance.ps1
pwsh tests/acceptance.ps1 -Only 03
```

Repository-only developer tooling, not part of the release payload:
`scripts/verisolve.ps1 --workspace <path>` dispatches
`validate|run|rank|status|report|kb|init|cleanup` and renders reports containing
archived, skipped, and escalation lists plus the Playbook hit rate. It never
reasons.
