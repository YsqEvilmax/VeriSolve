# VeriSolve architecture

VeriSolve is a verification-driven continuous problem resolution system that
runs as an **AI Agent Assistant hosted by VS Code Copilot**.

## 0. Release shape and Copilot loading mechanism

The single delivery artifact is the directory
`.github/skills/verisolve-init/`. It carries the installer (`SKILL.md`,
`scripts/`), the whole system skeleton (`templates/`), and the architecture
reference (`references/architecture.md`). A user copies that one directory into
their repository, triggers `/verisolve-init` in Copilot Chat, and the skill
releases `templates/` into `.github/{agents,skills,config,contracts,playbook,workflows,lib}`.

Three loading rules must always be honoured:

1. **An `.agent.md` inside a skill directory is not an Agent.** Copilot only
   discovers agents from `.github/agents/`. Anything under
   `.github/skills/**` is a plain resource file, so `templates/agents/*.agent.md`
   is inert until scaffolded.
2. **Agent discovery happens at session initialisation.** After scaffolding, the
   new agents do not appear in the chat agent picker until the VS Code window is
   reloaded or a new session is started.
3. Therefore `verisolve-init` only detects, releases, and guides. It never acts
   as the VeriSolve runtime entry point; after scaffolding it must print the
   reload instruction and stop. Orchestration belongs to
   `.github/agents/verisolve.agent.md`.

`host` is always VS Code Copilot; it is declared in `config/verisolve.cli.json`.
Reasoning lives in exactly two Agent definitions. Everything else is
deterministic code, declarative workflow, or JSON configuration.


## 1. System boundaries

```text
User picks the VeriSolve agent in Copilot Chat
  └─ .github/agents/verisolve.agent.md                (deterministic coordinator)
       ├─ .github/workflows/run-pipeline.workflow.md
       │    ├─ skills/fetch-backlog      -> source adapter IO, ingest_seq
       │    ├─ TriageAgent               -> {category, severity, keywords}
       │    ├─ skills/playbook-query     -> pinned snapshot, zero IO in query
       │    ├─ skills/rank-and-schedule  -> deterministic ordering
       │    └─ per-problem task
       │         ├─ ResolverAgent (resolve mode) -> VSChange
       │         ├─ skills/guardrail-check       -> accept/reject, no Oracle
       │         ├─ skills/apply-change          -> idempotent executor IO
       │         ├─ skills/verify-change start    -> returns immediately
       │         ├─ skills/verify-change check    -> bounded status queries
       │         └─ .github/workflows/high-risk-review.workflow.md
       │              └─ ResolverAgent (review mode)
       └─ skills/playbook-commit         -> queue + single writer + append-only

Local debugging (not required by Copilot):
scripts/verisolve.ps1 validate|run|rank|status|report|kb|init|cleanup
```

Layering rules:

| Layer | Location | May contain |
| --- | --- | --- |
| Release artifact | `.github/skills/verisolve-init/` | Installer skill, templates, architecture reference |
| Agent definitions | `templates/agents/*.agent.md` → `.github/agents/` | Instructions, tool lists, bounded input/output contracts |
| Declarative orchestration | `templates/workflows/*.workflow.md` → `.github/workflows/` | Ordered steps, branching, retry/escalation policy |
| Skills | `templates/skills/<name>/SKILL.md` + `run.ps1` | IO transport, deterministic rule evaluation |
| Shared deterministic primitives | `templates/lib/*.ps1` → `.github/lib/` | Validation, locking, replay, scoring, ordering |
| Configuration | `templates/config/*.json` → `.github/config/` | Every bound, threshold, weight, path, and command |
| Contracts | `templates/contracts/*.schema.json` → `.github/contracts/` | `VSProblem`, `VSVerdict`, `VSChange` |

A `.psm1` module is never used, and PowerShell never carries orchestration,
ranking judgment, verdict authorship, or reasoning.

## 2. The two reasoning agents

### TriageAgent (`.github/agents/triage.agent.md`)

Fresh context per Problem. Returns exactly:

```json
{ "category": "bug", "severity": "high", "keywords": ["null-reference"] }
```

`category` is a controlled enum from `verisolve.categories.json`
(`bug`, `incident`, `maintenance`, `other`). No prose, no extra keys, no
proposed change. The coordinator validates the shape before using it.

### ResolverAgent (`.github/agents/resolver.agent.md`)

One file, two modes:

- **resolve** — outputs a `VSChange` for the bounded projection.
- **review** — outputs `{approved, reason}` for `diff` + `acceptance_criteria`
  only. Used by the high-risk review workflow.

Every resolve, retry, and review starts a new context. ResolverAgent never
returns `ok`; only the Oracle verdict decides acceptance.

### Coordinator (`.github/agents/verisolve.agent.md`)

A deterministic workflow coordinator, deliberately *not* a third reasoning kind.
It reads config, pins a snapshot, delegates to the two agents, calls skills in
order, and records state. It never classifies, never writes patches, and never
judges verification.

## 3. Cross-agent context is bounded

Only two transfers exist:

1. **TriageAgent → coordinator**: `{category, severity, keywords}`.
2. **ResolverAgent ↔ coordinator**: a `VSChange`, or the bounded retry feedback
   `{previous_summary<=200, fail_category, top_errors<=3, top_errors count<=3}`.

Input projections are allowlisted:

| Agent | Allowed projection fields |
| --- | --- |
| TriageAgent | `problem_id`, source `category`, `severity`, `keywords`, optional `raw.summary` <= 200 code points |
| ResolverAgent resolve | `problem_id`, triage `category`, `severity`, `keywords`, optional `summary` <= 200, optional `pattern_id` + `solution_summary` 0–300, retry fields |
| ResolverAgent review | `diff`, `acceptance_criteria` |

Open containers — `raw`, `features`, `artifacts`, `metadata` — are **never**
projected into any agent input. `Test-VSResolverProjection` rejects them, even
when nested.

## 4. Verification is external and two-stage

```
start:  apply (idempotent) -> trigger pipeline -> persist pending -> return {verification_id}
check:  read pending -> query status (bounded) -> merge completed / retry infra
```

- `start.ps1` never polls. It takes a per-change lock, performs the idempotent
  apply, triggers the external pipeline, writes `pending-verifications.json`
  under the shared lock, and returns immediately. Pipelines may run for hours.
- `check.ps1` inspects at most `check_batch_limit` entries, one status query per
  entry, and returns. No waiting, no sleeping, no pipeline dependency.
- `pending-verifications.json` is only ever mutated while holding
  `playbook/pending-verifications.lock` (FileShare.None) and is replaced
  atomically (temp file + `File.Move -Force`).
- `poll-verifications` optionally runs the same bounded check from an
  independent PowerShell worker; Copilot only reads the state file.

Failures are split:

| Kind | `fail_category` | Counts against |
| --- | --- | --- |
| Business failure | any non-infra category | `retry_per_bug` |
| Infrastructure failure | `timeout`, `oracle_error` (config `oracle.timeout_categories`) | `infra_retry` only |

Infrastructure retries restart the pipeline without re-applying the change and
never consume a business attempt.

## 5. Verdict authority

`VSVerdict.ok` is produced by the configured Oracle command and is the only
authority over acceptance. The coordinator reads the boolean; the ResolverAgent
never sees verdict evidence and never writes `ok`. An Oracle response that
violates `contracts/vs-verdict.schema.json` is treated as an infrastructure
failure (`oracle_error`), not as a pass.

## 6. Guardrails precede apply and verification

`guardrail-check` is deterministic and config-driven:

- `forbidden_targets` — glob patterns (`.git/**`, `secrets/**`).
- `forbidden_patterns` — regular expressions over the diff.
- `max_patch_files`, `max_patch_bytes`, `max_patch_lines`.

A rejected change returns `{accepted:false, fail_category:"guardrail_rejected"}`
and the workflow must not call `apply-change` or `verify-change`. The Oracle is
provably never invoked (see the acceptance suite's mock-counter evidence).

## 7. Playbook: split read/write

Read path (`playbook-query`):

- `pin` reads `playbook/snapshot.json` once per batch.
- `query` receives the pinned copy and performs **zero** filesystem IO, zero
  locks, and zero writes; deleting the live snapshot file does not affect it.
- Score = `embedding_weight * lexical similarity + feature_weight * feature
  Jaccard + confidence_weight * laplace confidence` (weights from config, sum
  must be 1.0).
- Confidence = `(successes + 1) / (successes + failures + 2)`; below
  `low_conf_threshold` the match is flagged `downgraded`.

Write path (`playbook-commit`):

- `enqueue` appends validated events to `playbook/event-queue.log` under the
  writer lock and returns. 100 concurrent submitters lose nothing.
- `drain` is the single writer: it consumes at most `writer_batch_size` queued
  events in order, appends them to `playbook/events.log`, clears the consumed
  entries atomically, then republishes the snapshot atomically.
- `rebuild` replays the append-only log, discards a truncated tail, and rewrites
  the snapshot — the crash-recovery path.
- Snapshots are only published at batch boundaries.

Event kinds: `ArchiveEvent`, `ConfidenceUpdateEvent`, `SkipEvent`,
`ReviewRejectEvent`. Failed attempts emit `SkipEvent` and never create or
mutate a pattern, so two failures cannot pollute the Playbook.

## 8. Ordering

Grouping and ordering are configuration, not code constants.

- Groups: `priority_matrix` descending, then category name ascending. Unknown
  categories use `priority_matrix_default`.
- Within a group: `schedule_order` from config, default
  `playbook_matched` → `match_score` → `severity` → `created_at` → `ingest_seq`.
  `created_at` and `ingest_seq` sort ascending; all others descending.
- `ingest_seq` is a strictly increasing per-batch sequence assigned at fetch
  time, so ties never depend on dictionary or completion order.

## 9. High-risk review

Risk is decided only by the controlled TriageAgent category:

- `high_risk_categories` is a comma-separated string; trim, drop empty items,
  match case-sensitively. Values outside `bug|incident|maintenance|other` fail
  at startup. Unset or empty falls back to `high_risk_categories_default`
  (`incident`).
- Review runs **only** after `Verdict.ok == true`, in a fresh ResolverAgent
  context containing just the diff and bounded acceptance criteria.
- A rejection reverts the change, emits `ReviewRejectEvent`, and fails the
  attempt. A null or out-of-domain triage category warns and counts as
  non-high-risk; it never aborts the run.

## 10. Configuration inventory

| File | Owns |
| --- | --- |
| `verisolve.system.json` | Concurrency, `retry_per_bug`, `infra_retry`, `ingest_seq` semantics, Playbook refresh cadence, lock timeouts, `log_level` |
| `verisolve.agents.json` | Agent kinds, agent file paths, triage bounds, resolver modes and retry/review projection limits |
| `verisolve.categories.json` | Category domain, priority matrix, severity order, `schedule_order` |
| `verisolve.verification.json` | Contract bounds, `fail_category` enum and extension rules, high-risk categories, guardrails, pending-verification paths, `check_batch_limit`, `poll_interval_sec` |
| `verisolve.knowledge_base.json` | Event log/queue/snapshot paths, writer batch and flush settings, scoring weights, `low_conf_threshold`, `top_k`, `min_score` |
| `verisolve.cli.json` | `host`, `mock_mode`, external command templates (problem source, executor, Oracle start/check), run store, lock files, `external_integration_notes` |

`mock_mode` marks the shipped Oracle fixtures as mocks; replace them with a real
pipeline before trusting verdicts. `external_integration_notes` records the
policy that every integration — including Checkmarx — is configured, never
hard-coded.

`additional_fail_categories` may extend the enum, but a value must not duplicate
a built-in, must match `^[a-z0-9_]{1,64}$`, and must be unique; violations fail
at startup. Extension never redefines an existing built-in category.

## 11. Delivery, install, and uninstall

**Install / resume** — `verisolve-init` (`context: fork`) runs three read-then-act
steps:

1. `scripts/check-prerequisites.ps1` (read-only) reports `pwsh` >= 7, `git`, and
   every unfinished command placeholder in `verisolve.cli.json`. It always exits
   0; the Skill decides whether to continue.
2. `scripts/detect-state.ps1` (read-only) reports
   `{scaffolded, pending_count, last_run, suggested_action}`. When
   `scaffolded=true` the Skill only summarises state and tells the user to switch
   to the VeriSolve agent — it never orchestrates.
3. `scripts/scaffold.ps1` validates `templates/` completeness, copies anything
   missing, and skips whatever already exists. Any failure rolls back the files
   created by that run and exits 1. `playbook/pending-verifications.json` is
   seeded as `[]`; `verify-change` treats `[]` or a missing file as empty state
   and upgrades to the canonical object shape on the first write.

After scaffolding the Skill must print the reload instruction: Copilot does not
load newly scaffolded agents until the window reloads or a new session starts.

**Uninstall** — `verisolve-cleanup` prints a read-only plan first, then on
explicit `-ConfirmUninstall` backs up `config/verisolve.*.json` (plus Playbook
state) to `.github/verisolve-backup-<UTC timestamp>/`, deletes only its
allowlisted files and directories, and removes its own skill directory last.
It never deletes `.github/copilot-instructions.md` or any user-authored agent or
skill, and it never claims that external pipelines were cancelled.

**Local CLI** — `scripts/verisolve.ps1` is a developer tool, not part of the
release payload. It accepts `--workspace <path>` (default: current directory) and
dispatches `validate`, `run`, `rank`, `status`, `report`, `kb`, `init`, and
`cleanup`. It prepares batches and renders reports; it never reasons. Reports
always carry archived, skipped, and escalation lists plus the Playbook hit rate
in both `md` and `json` forms.

## 12. Verification of the design

`tests/acceptance.ps1` is executable and covers every boundary above, including
`boundary ±1` contract checks, open-container rejection, guardrail/Oracle
decoupling via mock counters, 100-way concurrent Playbook submission, truncated
log recovery, two-stage verification timing, infrastructure-vs-business retry
separation, deterministic scheduling, scaffolding, and uninstall safety.

```powershell
pwsh tests/acceptance.ps1
pwsh tests/acceptance.ps1 -Only 03
```
