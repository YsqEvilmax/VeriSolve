# VeriSolve

**Verification-driven continuous problem resolution**, delivered as an AI Agent
Assistant for VS Code Copilot.

VeriSolve takes a backlog of problems, classifies them, tries a known fix from a
learning Playbook (or generates a new one), gates it through deterministic
guardrails, applies it, and lets an **external Oracle** decide whether the change
is actually good. Nothing is archived until an external pipeline says `ok`.

The whole product ships as **one directory**:

```
.github/skills/verisolve-init/
```

Copy it in, run `/verisolve-init` in Copilot Chat, reload the window, and pick
the **VeriSolve** agent. See [Install](#2-install) below.

- Only two reasoning agents exist: **TriageAgent** and **ResolverAgent**
  (review is a mode of ResolverAgent, not a third agent).
- The verdict is external: ResolverAgent can never author `ok`.
- Verification is two-stage and non-blocking: `start` returns immediately,
  `check` performs bounded status queries. A 3-hour pipeline never blocks Copilot.
- Every limit, weight, threshold, path, and external command lives in JSON.

Two documents, split by audience:

- Installer mechanics and the three script contracts:
  [`.github/skills/verisolve-init/references/loading-and-contracts.md`](.github/skills/verisolve-init/references/loading-and-contracts.md)
- Runtime design and invariants:
  [`.github/skills/verisolve-init/templates/references/architecture.md`](.github/skills/verisolve-init/templates/references/architecture.md)
  (released to `.github/references/architecture.md`)

---

## 1. What is in the box

```
.github/skills/verisolve-init/
├── SKILL.md                          # /verisolve-init: detect → release → guide
├── scripts/
│   ├── check-prerequisites.ps1       # read-only: pwsh, git, config placeholders
│   ├── detect-state.ps1              # read-only: scaffolded? pending? last run?
│   └── scaffold.ps1                  # idempotent release, rollback on failure
├── templates/                        # everything that gets released
│   ├── agents/                       verisolve / triage / resolver .agent.md
│   ├── skills/                       fetch-backlog, playbook-query, playbook-commit,
│   │                                 guardrail-check, apply-change, verify-change,
│   │                                 poll-verifications, rank-and-schedule,
│   │                                 verisolve-cleanup
│   ├── config/                       verisolve.{system,agents,categories,
│   │                                 verification,knowledge_base,cli}.json
│   ├── contracts/                    vs-{problem,verdict,change}.schema.json
│   ├── playbook/                     events.log (empty), snapshot.json (v0),
│   │                                 pending-verifications.json ([])
│   ├── lib/                          vs-{contracts,filelock,playbook,schedule}.ps1
│   ├── references/                   architecture.md → .github/references/
│   ├── workflows/                    run-pipeline, high-risk-review
│   └── copilot-instructions.md       project-level constraints (skipped if present)
└── references/
    └── loading-and-contracts.md      installer mechanics + script contracts
```

Repository-only tooling (not part of the release): `scripts/verisolve.ps1` (local
CLI) and `tests/` (executable acceptance suite).

## 2. Install

### 2.1 Prerequisites

- PowerShell 7+ (`pwsh`)
- git
- VS Code with Copilot Chat

`/verisolve-init` checks these and prints the install command for anything
missing. It never installs anything itself.

### 2.2 Copy the payload

Copy `.github/skills/verisolve-init/` into your repository at the same path:

```
<your-repo>/.github/skills/verisolve-init/
```

That directory is the entire distribution. Nothing else needs to be copied.

### 2.3 Run the initializer

In Copilot Chat:

```
/verisolve-init
```

It will:

1. report environment status (`✅` ready / `❌` missing + hint) for `pwsh`, `git`
   and every unfilled command placeholder;
2. detect whether VeriSolve is already scaffolded — if it is, it only summarises
   `resolved / pending / outstanding` and tells you to switch agents;
3. otherwise release `templates/` into `.github/{agents,skills,config,contracts,
   playbook,workflows,lib,references}`, skipping anything that already exists;
4. tell you which integration commands are still placeholders;
5. print the reload instruction.

### 2.4 Reload the window — required

> Scaffolding 完成。Copilot 不会自动加载新 Agent。请**重新加载 VS Code 窗口**
> （或开新会话），然后在 Chat 的 agent 下拉列表选择 **VeriSolve** 开始。

Copilot discovers agents only at session initialization. Files scaffolded into
`.github/agents/` do not appear in the agent picker until the window reloads, and
an `.agent.md` sitting inside a skill folder is never treated as an agent. That
is why the initializer stops after prompting for the reload instead of running
the pipeline itself.

### 2.5 Configure integrations

Everything external is a command template in `.github/config/verisolve.cli.json`:

| Key | Meaning |
| --- | --- |
| `problem_sources.<name>.command` + `arguments` | Reads one page of problems from stdin JSON, returns `{problems, next_cursor}` |
| `executor.apply.command` / `executor.revert.command` | Applies or reverts a change; must be **idempotent** on `idempotency_key` |
| `oracle.start.command` / `oracle.check.command` | Triggers the external pipeline and reports its status |

The shipped Oracle points at mock fixtures (`mock-start.ps1` / `mock-check.ps1`)
and `mock_mode` is `true`. Replace them before trusting any verdict. Checkmarx or
any other report tool is configured the same way — nothing is hard-coded.

Every command receives JSON on stdin and must answer with JSON on stdout.

## 3. Run

Select the **VeriSolve** agent in Copilot Chat and ask for a batch, for example:

> Run a VeriSolve batch from the `checkmarx_example` backlog.

The coordinator fetches problems, triages them, searches the Playbook, schedules
by category, resolves each problem, checks guardrails, applies, and starts
verification. On a later turn it calls `verify-change` in check mode to harvest
completed verdicts; you never wait for a pipeline.

Pending verifications live in `.github/playbook/pending-verifications.json`.
Optional autonomous refresh:

```powershell
pwsh .github/skills/poll-verifications/run.ps1 -Mode start  -Root .
pwsh .github/skills/poll-verifications/run.ps1 -Mode status -Root .
pwsh .github/skills/poll-verifications/run.ps1 -Mode stop   -Root .
```

## 4. Resume a previous run

Run `/verisolve-init` again. When the system is already scaffolded it performs a
read-only check and reports:

> 已 scaffold。上次运行：X 已解决 / Y 待验证 / Z 待处理。

Then switch to the VeriSolve agent — the initializer never orchestrates.

## 5. Uninstall

```powershell
pwsh .github/skills/verisolve-cleanup/scripts/cleanup.ps1 -Mode plan -Workspace .
# review the plan, then
pwsh .github/skills/verisolve-cleanup/scripts/cleanup.ps1 -Mode uninstall -Workspace . -ConfirmUninstall
```

The uninstaller backs up `.github/config/verisolve.*.json` (plus Playbook state)
to `.github/verisolve-backup-<timestamp>/`, deletes only its allowlisted files and
directories, and removes its own skill directory last. It never deletes
`copilot-instructions.md` or your own agents/skills, and it never claims that
external pipelines were cancelled. The released
`.github/references/architecture.md` is deleted with the rest of the allowlist
and is not backed up (it is shipped documentation, not user configuration).

## 6. Local CLI (repository tooling)

`scripts/verisolve.ps1` operates on a **scaffolded workspace** and is not part of
the release payload:

```powershell
pwsh scripts/verisolve.ps1 validate --workspace <repo>
pwsh scripts/verisolve.ps1 run --backlog example --dry-run --workspace <repo>
pwsh scripts/verisolve.ps1 run --backlog example --workspace <repo>
pwsh scripts/verisolve.ps1 rank --run <run-id> --triage triage.json --workspace <repo>
pwsh scripts/verisolve.ps1 status --run <run-id> --workspace <repo>
pwsh scripts/verisolve.ps1 report --run <run-id> --format md --workspace <repo>
pwsh scripts/verisolve.ps1 kb query --category bug --signature signature.json --workspace <repo>
pwsh scripts/verisolve.ps1 kb stats --workspace <repo>
pwsh scripts/verisolve.ps1 kb drain --workspace <repo>
pwsh scripts/verisolve.ps1 kb rebuild --workspace <repo>
pwsh scripts/verisolve.ps1 init --mode inspect --workspace <repo>
pwsh scripts/verisolve.ps1 cleanup --mode plan --workspace <repo>
```

`run` fetches and validates the backlog, assigns `ingest_seq`, and writes
`plan.json` / `status.json` under `.github/playbook/runs/<run-id>/`. `rank`
consumes TriageAgent output and writes `schedule.json`. `report` always renders
an overview table plus archived, skipped, and escalation lists and the Playbook
hit rate.

## 7. Tests

```powershell
pwsh tests/acceptance.ps1          # full suite (83 cases)
pwsh tests/acceptance.ps1 -Only 04 # one case file
```

The suite releases the payload with the real scaffold script and runs every case
against that scaffold, so it validates the shipped artefact rather than a
hand-maintained copy. It covers, among other things:

- boundary `±1` handling for every contract limit;
- open containers (`raw`, `features`, `artifacts`, `metadata`) rejected from every
  agent projection, including nested ones;
- guardrail rejections never invoking the Oracle (mock counter evidence);
- 100 concurrent Playbook submissions with no lost events, plus truncated-log
  recovery;
- non-blocking `start`, bounded `check`, idempotent starts under concurrency, and
  infrastructure retries that never consume `retry_per_bug`;
- deterministic scheduling with `ingest_seq` tie-breaks;
- read-only prerequisites/state detection, idempotent scaffolding with rollback,
  and an uninstall that backs up first and deletes itself last.

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
10. `verisolve-init` installs and `verisolve-cleanup` uninstalls; neither
    orchestrates. Orchestration belongs to `verisolve.agent.md`, which Copilot
    only loads after a window reload.
