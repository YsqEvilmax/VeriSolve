# VeriSolve Copilot instructions

- The only reasoning Agent kinds are TriageAgent and ResolverAgent. The
  `VeriSolve` custom Agent is a deterministic coordinator, not a third
  reasoning kind. Review is ResolverAgent's review mode.
- Use only the contracts and JSON configuration in `.github/config/` and
  `.github/contracts/`. Treat configured limits as authoritative and fail fast
  on invalid settings. The runtime design and invariant list live in
  `.github/references/architecture.md`; read it before changing behaviour.
- Never send open containers (`raw`, `features`, `artifacts`, `metadata`) to an
  Agent. Only explicitly extracted, bounded fields may enter projections:
  `problem_id`, triage `category`, `severity`, `keywords`, an optional
  `raw.summary` of at most 200 code points, and — for review — the bounded
  `diff` and `acceptance_criteria`.
- Never let ResolverAgent author a verdict. `verify-change` obtains the Oracle
  verdict, and its boolean `ok` is authoritative. A verdict that violates the
  contract is an infrastructure failure, never a pass.
- Every ResolverAgent resolve/retry/review invocation has a fresh context.
  Retry feedback is limited to the previous summary (<=200 code points), the
  `fail_category`, and at most three top errors. Never re-inject logs.
- Guardrails precede apply and verification. A rejected change must not reach
  `apply-change` or `verify-change`.
- Verification is two-stage. `verify-change/start.ps1` returns immediately after
  triggering the pipeline and persisting the verification id; it must never poll
  or wait. `verify-change/check.ps1` performs bounded status queries only. Never
  block the Copilot conversation on an external pipeline.
- `timeout` and `oracle_error` are infrastructure failures: retry them under
  `infra_retry` and never charge them to `retry_per_bug`.
- Pending verification updates use the shared file lock and atomic replacement.
- Playbook queries read the pinned immutable in-memory snapshot with zero IO and
  zero locks. Writes go through the event queue and a single append-only writer;
  publish snapshots only at batch boundaries.
- Ordering is configuration-driven: Playbook hit first, then match score,
  severity, and creation time, with `ingest_seq` as the final deterministic tie
  break.
- PowerShell lives only in `.github/lib/`, `.github/skills/*/`, `scripts/`, and
  `tests/`. It performs IO transport and deterministic, fully config-driven rule
  evaluation. It never reasons, ranks by judgment, authors verdicts, or
  orchestrates the workflow.
- `verisolve-cleanup` is destructive. Show its exact plan and obtain explicit
  confirmation before executing.
