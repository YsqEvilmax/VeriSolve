# VeriSolve installer reference

**Audience: the agent running `/verisolve-init`, and anyone maintaining this
payload.** This document covers only how the installer works and what Copilot
does with the files it releases.

The runtime design — agents, contracts, verification, Playbook, ordering,
guardrails, configuration, invariants — lives in
`templates/references/architecture.md`, which scaffolding releases to
`.github/references/architecture.md`. Do not duplicate that content here.
Installation *steps* live in `../SKILL.md`; this file holds the machine-checkable
contracts behind those steps.

---

## 1. Copilot loading constraints (hard platform behaviour)

1. **An `.agent.md` inside a skill directory is not an Agent.** Copilot discovers
   custom agents only from `.github/agents/*.agent.md`. Everything under
   `.github/skills/**` is a resource file, so `templates/agents/*.agent.md` is
   inert until released.
2. **Agent discovery happens at session initialisation.** Newly released agents
   do not appear in the chat agent picker until the VS Code window reloads or a
   new session starts.
3. **`verisolve-init` is therefore an installer, not an entry point.** After
   scaffolding it must print the reload instruction and stop. It never performs
   triage, resolution, or verification, and never substitutes for
   `.github/agents/verisolve.agent.md`.

Accepted trade-off: one extra reload per install, in exchange for a payload that
is a single directory with no external runtime requirement.

## 2. Script contracts

All three scripts are PowerShell 7, take `-Workspace <path>` (default: current
directory), and print exactly one JSON object on stdout.

### 2.1 `scripts/check-prerequisites.ps1`

Read-only: creates, modifies, and deletes nothing. Always exits `0`.

```json
{
  "workspace": "<abs path>",
  "pwsh": { "ok": true, "version": "7.7.0", "hint": null },
  "git":  { "ok": true, "version": "git version 2.x", "hint": null },
  "config_placeholders": [ { "key": "executor.apply.command", "filled": false, "example": "..." } ],
  "config_source": "template"
}
```

- `pwsh.ok` requires major version >= 7. `hint` carries the install command when
  `ok` is false, otherwise `null`.
- `config_placeholders` enumerates `problem_sources.<name>.command` (excluding
  the `example` fixture), `executor.{apply,revert}.command`, and
  `oracle.{start,check}.command`.
- `config_source` is `scaffolded` when `.github/config/verisolve.cli.json`
  exists, `template` when the probe fell back to this payload's templates, or
  `missing`/`invalid`/`error`.
- Missing prerequisites are reported as `ok:false`; **the Skill decides whether
  to continue**. `pwsh` missing stops the flow, `git` missing only warns,
  unfilled placeholders continue into scaffolding.

### 2.2 `scripts/detect-state.ps1`

Read-only. Always exits `0`.

```json
{
  "scaffolded": true,
  "pending_count": 2,
  "last_run": { "id": "run-...", "ts": "...", "resolved": 3, "skipped": 1, "escalation": 2, "state": "scheduled" },
  "suggested_action": "resume"
}
```

- `scaffolded` is true only when `.github/agents/verisolve.agent.md` exists.
- `pending_count` counts `pending` entries in
  `config/verisolve.verification.json#pending_verifications_path`; a bare `[]`
  state file counts as zero.
- `last_run` comes from the newest directory under
  `config/verisolve.cli.json#run_store_path`; counts come from `results.json`
  (`archived`/`skipped`/`escalated`) and `state` from `status.json`. `null` when
  no run exists.
- `suggested_action` is `"resume"` when scaffolded, `"init"` otherwise.
- When `scaffolded` is true the Skill stops here: it reports state and tells the
  user to switch to the VeriSolve agent. It must not orchestrate.

### 2.3 `scripts/scaffold.ps1`

```json
{
  "workspace": "<abs path>",
  "created": ["agents/verisolve.agent.md", "..."],
  "skipped": ["config/verisolve.cli.json"],
  "playbook_initialized": true
}
```

Exit `0` on success, `1` on failure. On failure it also prints
`{created: [], skipped: [], error: "...", rolled_back: [...]}`.

Guarantees:

| Guarantee | Behaviour |
| --- | --- |
| Template validation first | 43 required template paths plus a minimum of 9 skill directories with `SKILL.md`; any gap aborts before writing |
| Idempotent | An existing target file is never overwritten; it is reported in `skipped` |
| Path containment | Every target is asserted to resolve inside `<workspace>/.github` |
| Rollback | A failure deletes every file created by this run, then removes the directories it created if empty |
| Seeds | `playbook/pending-verifications.json` is written as `[]`, `events.log` as an empty file; `snapshot.json` ships as `{version:0, patterns:[]}` |
| Instruction file | `copilot-instructions.md` is skipped when the user already has one |

Release mapping (each template directory is copied recursively):

| Template | Target |
| --- | --- |
| `templates/agents/` | `.github/agents/` |
| `templates/skills/` | `.github/skills/` |
| `templates/config/` | `.github/config/` |
| `templates/contracts/` | `.github/contracts/` |
| `templates/playbook/` | `.github/playbook/` |
| `templates/workflows/` | `.github/workflows/` |
| `templates/lib/` | `.github/lib/` |
| `templates/references/` | `.github/references/` |
| `templates/copilot-instructions.md` | `.github/copilot-instructions.md` |

## 3. Cleanup semantics (`templates/skills/verisolve-cleanup`)

`scripts/cleanup.ps1 -Mode plan|uninstall -Workspace <path> [-ConfirmUninstall]`.

- `plan` is read-only and returns `would_delete`, `not_found`, `retained`, and a
  warning that external pipelines are not cancelled.
- `uninstall` without `-ConfirmUninstall` refuses and exits `1`.
- Backups happen **before** any deletion: `config/verisolve.*.json` plus
  `playbook/{pending-verifications,snapshot}.json` and `events.log` are copied to
  `.github/verisolve-backup-<UTC timestamp>/`. A backup failure aborts with
  nothing deleted.
- Deletion is an explicit allowlist: three agent files, `contracts/vs-*.schema.json`,
  two workflow files, nine VeriSolve skill directories, and `lib/`, `playbook/`,
  `references/`.
- `.github/skills/verisolve-init/` is removed, then `.github/skills/verisolve-cleanup/`
  **last** (it deletes the directory the running script lives in).
- `copilot-instructions.md` is always retained: it may contain user-authored
  rules. User agents and skills outside the allowlist are never touched.

## 4. What protects these guarantees

| Contract | Acceptance case |
| --- | --- |
| Prerequisites are read-only and never exit non-zero | `check-prerequisites-reports-environment-readonly`, `check-prerequisites-never-exits-nonzero` |
| State detection is read-only and never orchestrates | `detect-state-reports-init-before-scaffolding`, `detect-state-reads-pending-and-last-run-without-orchestrating` |
| Scaffolding releases the full tree and seeds Playbook state | `scaffold-releases-the-whole-linked-system` |
| Scaffolding is idempotent and preserves user edits | `scaffold-is-idempotent-and-preserves-user-edits`, `scaffold-keeps-existing-copilot-instructions` |
| Template gaps roll back completely | `scaffold-rolls-back-when-templates-are-incomplete` |
| Cleanup plans read-only, refuses unconfirmed, backs up first, self-deletes last | `cleanup-plan-is-read-only`, `cleanup-refuses-without-confirmation`, `cleanup-backs-up-then-deletes-allowlist-and-itself-last` |
| The payload stays inert and this split is preserved | `release-payload-is-the-only-deliverable-and-stays-inert`, `payload-reference-is-installer-only`, `runtime-reference-ships-and-is-reachable` |

Run `pwsh tests/acceptance.ps1` from the repository root.
