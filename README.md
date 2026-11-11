# VeriSolve

**Verification-driven continuous problem resolution**, delivered as an AI Agent
Assistant for VS Code Copilot.

VeriSolve takes a backlog of problems, classifies them, tries a known fix from a
learning Playbook (or generates a new one), gates it through deterministic
guardrails, applies it, and lets an **external Oracle** decide whether the change
is actually good. Nothing is archived until an external pipeline says `ok`.

- Only two reasoning agents exist: **TriageAgent** and **ResolverAgent**
  (review is a mode of ResolverAgent, not a third agent).
- The verdict is external: ResolverAgent can never author `ok`.
- Verification is two-stage and non-blocking: `start` returns immediately,
  `check` performs bounded status queries. A 3-hour pipeline never blocks Copilot.
- Every limit, weight, threshold, path, and external command lives in JSON.

Design details: [docs/architecture.md](docs/architecture.md).

---

## 1. Layout

```
.github/
  agents/       verisolve.agent.md (coordinator), triage.agent.md, resolver.agent.md
  skills/       fetch-backlog, playbook-query, playbook-commit, guardrail-check,
                apply-change, verify-change, rank-and-schedule,
                poll-verifications, verisolve-init, verisolve-cleanup
  workflows/    run-pipeline.workflow.md, high-risk-review.workflow.md
  contracts/    vs-problem / vs-verdict / vs-change JSON Schemas
  config/       verisolve.*.json (system, agents, categories, verification,
                knowledge_base, cli)
  lib/          shared deterministic PowerShell primitives
  playbook/     events.log, snapshot.json, pending-verifications.json
scripts/        verisolve.ps1 — thin local CLI
tests/          acceptance.ps1 — executable acceptance suite
docs/           architecture.md
```

## 2. Requirements

- PowerShell 7 (`pwsh`) for skills, CLI, and tests.
- VS Code with Copilot Chat for agent execution.

## 3. Quick start

### 3.1 Install the system

In Copilot Chat, run the **`verisolve-init`** skill. It scaffolds the whole
`.github` tree into your workspace, writes an ownership manifest, and tells you
which integrations are still unconfigured. Running it again resumes an existing
installation instead of overwriting it.

From a shell you can do the same:

```powershell
pwsh .github/skills/verisolve-init/run.ps1 -Mode inspect
pwsh .github/skills/verisolve-init/run.ps1 -Mode scaffold -Workspace .
```

### 3.2 Configure your integrations

Everything external is a command template in
[`.github/config/verisolve.cli.json`](.github/config/verisolve.cli.json). Fill in
the three that matter:

| Key | Meaning |
| --- | --- |
| `problem_sources.<name>.command` + `arguments` | Reads one page of problems from stdin JSON and returns `{problems, next_cursor}` |
| `executor.apply.command` / `executor.revert.command` | Applies or reverts a change; must be **idempotent** on `idempotency_key` |
| `oracle.start.command` / `oracle.check.command` | Triggers the external pipeline and reports its status |

The shipped Oracle points at mock fixtures (`mock-start.ps1` / `mock-check.ps1`)
and `mock_mode` is `true`. Replace them with a real pipeline before trusting any
verdict. Checkmarx or any other report tool is configured the same way — nothing
is hard-coded.

Every command is invoked with JSON on stdin and must answer with JSON on stdout.

### 3.3 Run

Select the **VeriSolve** agent in Copilot Chat and ask it to run a batch, for
example:

> Run a VeriSolve batch from the `checkmarx_example` backlog.

The coordinator fetches problems, triages them, searches the Playbook, schedules
by category, resolves each problem, checks guardrails, applies, and starts
verification. On the next turn it calls `verify-change` in check mode to harvest
completed verdicts.

You never wait for a pipeline: `start` returns a `verification_id` and the
pending entry is written to `.github/playbook/pending-verifications.json`.

Optional autonomous refresh (independent PowerShell worker):

```powershell
pwsh .github/skills/poll-verifications/run.ps1 -Mode start -Root .
pwsh .github/skills/poll-verifications/run.ps1 -Mode status -Root .
pwsh .github/skills/poll-verifications/run.ps1 -Mode stop -Root .
```

## 4. Local CLI

The CLI prepares batches, renders reports, and inspects the Playbook. It never
reasons about a fix and never decides a verdict.

```powershell
pwsh scripts/verisolve.ps1 validate
pwsh scripts/verisolve.ps1 run --backlog example --dry-run
pwsh scripts/verisolve.ps1 run --backlog example
pwsh scripts/verisolve.ps1 rank --run <run-id> --triage triage.json
pwsh scripts/verisolve.ps1 status --run <run-id>
pwsh scripts/verisolve.ps1 report --run <run-id> --format md
pwsh scripts/verisolve.ps1 report --run <run-id> --format json
pwsh scripts/verisolve.ps1 kb query --category bug --signature signature.json
pwsh scripts/verisolve.ps1 kb stats
pwsh scripts/verisolve.ps1 kb drain
pwsh scripts/verisolve.ps1 kb rebuild
```

`run` fetches and validates the backlog, assigns `ingest_seq`, and writes
`plan.json` / `status.json` under `.github/playbook/runs/<run-id>/`. `rank`
consumes TriageAgent output (`{problems:[{problem_id, output}]}`), runs the
Playbook query against one pinned snapshot, and writes `schedule.json`.
`report` always renders an overview table, an archived list, a skipped list, an
Escalation list, and the Playbook hit rate.

`kb query --signature` accepts a JSON file (`{keywords, features}`) or a plain
text file, which is tokenized into keywords.

## 5. Skills

| Skill | Purpose |
| --- | --- |
| `verisolve-init` | Scaffold or resume the workspace system (forked context) |
| `fetch-backlog` | Read a configured source, validate, assign `ingest_seq` |
| `playbook-query` | Pin one snapshot; search it in memory with zero IO |
| `playbook-commit` | Queue events, single-writer drain, replay/rebuild |
| `guardrail-check` | Forbidden targets/patterns and patch bounds; blocks apply/verify |
| `apply-change` | Idempotent apply/revert through the configured executor |
| `verify-change` | Two-stage: non-blocking `start`, bounded `check` |
| `poll-verifications` | Optional background worker for check mode |
| `rank-and-schedule` | Deterministic category grouping and ordering |
| `verisolve-cleanup` | Plan-first, hash-checked uninstall |

Each skill documents *when to use*, input/output, prohibitions, caller, and the
config keys it depends on.

## 6. Tests

```powershell
pwsh tests/acceptance.ps1          # full suite
pwsh tests/acceptance.ps1 -Only 03 # one case file
```

The suite proves, among other things:

- boundary `±1` handling for every contract limit (`top_errors<=3`,
  `summary<=200`, `diff<=100000`, `targets<=50`, `keywords<=20`, …);
- open containers (`raw`, `features`, `artifacts`, `metadata`) are rejected from
  every agent projection, including nested ones;
- a guardrail rejection never invokes the Oracle (mock counter evidence);
- 100 concurrent Playbook submissions lose no event, and a truncated log tail is
  discarded on rebuild;
- `start` triggers the pipeline once, never polls, and is idempotent per change,
  including under concurrent duplicate starts;
- `check` inspects at most `check_batch_limit` entries;
- `timeout`/`oracle_error` retry through `infra_retry` without consuming
  `retry_per_bug`, and an invalid verdict is an infrastructure failure;
- scheduling is reproducible and tie-breaks on `ingest_seq`;
- scaffolding is additive, uninstall is manifest-gated and preserves modified
  files.

## 7. Uninstall

```powershell
pwsh .github/skills/verisolve-cleanup/run.ps1 -Mode plan -Workspace .
# review the plan, then
pwsh .github/skills/verisolve-cleanup/run.ps1 -Mode uninstall -Workspace . -ConfirmUninstall
```

Uninstall only removes files listed in the init manifest whose SHA-256 still
matches. Modified files are retained and reported. Pending verification records
are cleared locally; **external pipelines keep running**.

## 8. Key invariants

1. Exactly two reasoning agent kinds; review is a ResolverAgent mode.
2. Cross-agent context has two bounded forms only; open containers never enter.
3. The Oracle owns `ok`; the Resolver never produces a verdict.
4. Verification is asynchronous and two-stage; Copilot never blocks on it.
5. Guardrails always precede apply and verify.
6. Playbook reads use a pinned snapshot with zero IO; writes are queued,
   single-writer, append-only.
7. Ordering: Playbook hit → match score → severity → time, tie-broken by
   `ingest_seq`.
8. Two failed attempts escalate; failed attempts never touch the Playbook.
9. All configuration is JSON; PowerShell performs IO and deterministic rule
   evaluation only.
