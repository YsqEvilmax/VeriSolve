# VeriSolve

VeriSolve is an AI Agent Assistant for verification-driven problem
resolution. Reasoning is defined by exactly two loadable agent files:
`TriageAgent` and `ResolverAgent`. Resolver review is a separate mode of the
same ResolverAgent definition. Workflows own deterministic orchestration;
PowerShell is limited to skill IO tools and thin CLI dispatch.

## Layout

- `agents/` — the two Agent runtime definitions.
- `skills/` — seven capability contracts and their PowerShell IO tools.
- `workflows/` — declarative pipeline and high-risk review orchestration.
- `contracts/` — JSON Schemas for VSProblem, VSVerdict, and VSChange.
- `config/verisolve.*.json` — all runtime, guardrail, retry, ranking, and
  adapter configuration.
- `playbook/` — append-only event log and published snapshot.
- `scripts/verisolve.ps1` — CLI-to-Agent-runtime dispatcher.
- `tests/acceptance.md` — acceptance checklist derived from the previous
  executable PowerShell suite.

## Runtime

Configure `VERISOLVE_AGENT_RUNTIME` with an executable implementing the
workflow dispatch protocol in `config/verisolve.cli.json`. It receives
`--workflow <workflow-path> -- <original CLI arguments>`. Configure external
source, executor, and Oracle commands in that JSON file. Missing integrations
fail explicitly; there is no success-shaped fallback.

The workflow contract requires the host runtime to provide deterministic
collection operations, asynchronous tasks, an in-memory pinned snapshot, and a
single-consumer event queue. The PowerShell tools perform only file/process IO;
they do not implement orchestration, scoring, guardrails, or reasoning.

## CLI

```powershell
pwsh -NoProfile -File .\verisolve\scripts\verisolve.ps1 run --backlog example
pwsh -NoProfile -File .\verisolve\scripts\verisolve.ps1 status --run <run-id>
pwsh -NoProfile -File .\verisolve\scripts\verisolve.ps1 report --run <run-id> --format md
pwsh -NoProfile -File .\verisolve\scripts\verisolve.ps1 kb query --category bug --signature .\signature.json
pwsh -NoProfile -File .\verisolve\scripts\verisolve.ps1 kb stats
pwsh -NoProfile -File .\verisolve\scripts\verisolve.ps1 kb rebuild
```

See `tests/acceptance.md` for contract boundaries and architecture checks.
