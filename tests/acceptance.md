# VeriSolve acceptance specification

Executable form: `tests/acceptance.ps1`. Every item below maps to a named case in
`tests/cases/*.ps1`; run `pwsh tests/acceptance.ps1` and require
`passed=N failed=0`.

The suite releases the shipped payload once with the real
`.github/skills/verisolve-init/scripts/scaffold.ps1`, then clones that scaffold
for every case. Nothing is tested against a hand-maintained live `.github` tree,
so the artefact under test is exactly what users install.

## A. Contracts and configuration (`01-contracts.ps1`)

- [x] `config-set-loads-and-validates` — all six JSON configs parse and pass the
  cross-field assertion (weights sum to 1.0, bounds ordered, enums preserved).
- [x] `schema-files-are-draft-2020-12-and-strict` — three schemas, draft 2020-12,
  `additionalProperties:false`.
- [x] `false-fail-category-requires-enum-when-config-extension-is-invalid` —
  extension must not duplicate a built-in, is limited to 1–64 `[a-z0-9_]`
  characters, must be unique, and a valid extension is accepted by the verdict
  validator.
- [x] `problem-accepts-valid-fixture`.
- [x] `problem-id-128-accepted-129-rejected`.
- [x] `problem-keywords-20-accepted-21-rejected`.
- [x] `problem-keyword-64-accepted-65-rejected`.
- [x] `problem-keyword-counts-code-points-not-utf16-units` — astral characters
  count as one code point.
- [x] `problem-rejects-unknown-and-missing-fields`.
- [x] `problem-severity-and-priority-score-types` — severity enum/null; boolean,
  string, NaN priority scores rejected.
- [x] `problem-created-at-must-be-iso8601`.
- [x] `verdict-top-errors-3-accepted-4-rejected`.
- [x] `verdict-fail-category-rules` — `ok=false` requires a non-null enum,
  `ok=true` allows null, matching is case-sensitive, every built-in is accepted.
- [x] `verdict-evidence-shape-is-closed`.
- [x] `change-summary-200-accepted-201-rejected`, plus empty rejected.
- [x] `change-summary-counts-astral-code-points`.
- [x] `change-diff-100000-accepted-100001-rejected`, plus empty rejected.
- [x] `change-targets-1-and-50-accepted-0-and-51-rejected`.
- [x] `change-id-and-problem-id-bounds`.
- [x] `change-rejects-unknown-fields`.
- [x] `triage-output-accepts-only-controlled-enums` — out-of-domain category,
  prose field, and over-long keyword rejected.
- [x] `resolve-projection-rejects-open-containers` — `raw`, `features`,
  `artifacts`, `metadata` rejected top-level and nested.
- [x] `retry-feedback-bounds` — `previous_summary<=200`, `top_errors<=3`,
  `fail_category` enum, no added log fields.
- [x] `review-projection-is-diff-and-acceptance-criteria-only`.
- [x] `high-risk-defaults-single-multi-and-empty-items`.
- [x] `high-risk-out-of-domain-and-wrong-case-fail-fast`.
- [x] `high-risk-null-and-out-of-domain-triage-warn-not-fail`.
- [x] `laplace-confidence-and-downgrade-flag`.

## B. Guardrails, Playbook, scheduling (`02-guardrails-playbook.ps1`)

- [x] `guardrail-accepts-clean-change`.
- [x] `guardrail-rejects-forbidden-target-and-never-calls-oracle` — mock Oracle
  counter file absent proves the Oracle was not invoked; directory-level
  `forbidden_targets` also rejected.
- [x] `guardrail-rejects-forbidden-pattern`.
- [x] `guardrail-enforces-patch-boundaries` — files, bytes, and lines.
- [x] `guardrail-rejects-contract-invalid-change`.
- [x] `playbook-rebuild-empty-snapshot`.
- [x] `playbook-enqueue-drain-archive-and-query` — queued events are invisible
  before the drain; snapshot republished once.
- [x] `playbook-query-never-touches-live-snapshot-file` — query still matches
  after `playbook/snapshot.json` is deleted.
- [x] `playbook-negative-feedback-lowers-confidence-and-downgrades`.
- [x] `playbook-skip-and-review-reject-do-not-create-patterns` — failed attempts
  never pollute the Playbook.
- [x] `playbook-scoring-weights-ordering-and-filters` — configured weights,
  score ordering, `min_score`, `top_k`, category filter.
- [x] `playbook-concurrent-submits-lose-nothing` — 100 concurrent submitters, all
  queued once, drained in order, snapshot version 100.
- [x] `playbook-rebuild-recovers-after-truncated-append`.
- [x] `playbook-rejects-invalid-events`.
- [x] `schedule-orders-by-configured-keys`.
- [x] `schedule-tie-breaks-with-ingest-seq-and-is-reproducible`.
- [x] `schedule-rejects-unsupported-order-key-and-missing-ingest-seq`.

## C. Two-stage verification (`03-verification.ps1`)

- [x] `verify-start-triggers-pipeline-and-never-polls` — one trigger, no status
  query, prompt return, pending persisted.
- [x] `verify-start-is-idempotent-per-change` — same verification id, one
  pipeline trigger, one apply.
- [x] `verify-start-serializes-concurrent-duplicate-starts`.
- [x] `verify-check-is-bounded-by-check-batch-limit` — inspects at most the
  configured limit, still tracks the full backlog, one query per entry.
- [x] `verify-check-completes-verdict-and-acknowledges` — carries the triage
  category for the high-risk decision.
- [x] `verify-check-business-failure-is-not-an-infrastructure-failure`.
- [x] `verify-infra-failure-retries-only-infrastructure` — two restarts under
  `infra_retry=2`, no re-apply, never becomes a business verdict.
- [x] `verify-invalid-verdict-is-treated-as-infrastructure-failure`.
- [x] `verify-start-rejects-invalid-change-before-any-external-call`.
- [x] `verify-pending-state-survives-concurrent-check-and-start`.

## D. Release payload: init and uninstall (`04-scaffold.ps1`)

- [x] `check-prerequisites-reports-environment-readonly` — pwsh 7, git, and every
  command placeholder reported; the check creates nothing.
- [x] `check-prerequisites-never-exits-nonzero` — missing prerequisites never
  abort the script.
- [x] `detect-state-reports-init-before-scaffolding` — `scaffolded:false`,
  `suggested_action:"init"`, no files created.
- [x] `detect-state-reads-pending-and-last-run-without-orchestrating` — pending
  count, last-run resolved/skipped/escalation counts, and pending state is not
  rewritten.
- [x] `scaffold-releases-the-whole-linked-system` — 40+ files released,
  `pending-verifications.json` seeded as `[]`, empty `events.log`, version-0
  snapshot.
- [x] `scaffold-is-idempotent-and-preserves-user-edits` — second run creates
  nothing, reports every file as skipped, and keeps user edits.
- [x] `scaffold-rolls-back-when-templates-are-incomplete` — missing template
  fails with exit 1 and removes everything released by that run.
- [x] `scaffold-keeps-existing-copilot-instructions` — a user-authored
  `copilot-instructions.md` is skipped, never overwritten.
- [x] `cleanup-plan-is-read-only` — plan lists deletions and warns that external
  pipelines keep running, changing nothing.
- [x] `cleanup-refuses-without-confirmation`.
- [x] `cleanup-backs-up-then-deletes-allowlist-and-itself-last` — timestamped
  backup under `.github/verisolve-backup-*`, allowlist-only deletion, user
  agents/skills and `copilot-instructions.md` retained, cleanup directory
  deleted last.

## E. CLI and structural invariants (`05-cli-invariants.ps1`)

- [x] `cli-validate-reports-contracts-and-agents`.
- [x] `cli-run-example-dry-run-writes-nothing`.
- [x] `cli-run-status-and-report-end-to-end` — markdown and JSON reports contain
  overview, archived, skipped, and escalation sections.
- [x] `cli-rank-uses-triage-output-and-scheduling-keys`.
- [x] `cli-kb-rebuild-stats-and-query`.
- [x] `cli-rejects-unsupported-commands`.
- [x] `exactly-two-reasoning-agent-kinds`.
- [x] `review-is-a-resolver-mode-not-a-new-agent`.
- [x] `no-psm1-modules-and-all-json-parses`.
- [x] `every-skill-documents-its-contract`.
- [x] `every-skill-is-invoked-from-an-agent-or-workflow`.
- [x] `all-powershell-parses-under-pwsh-7`.
- [x] `config-keys-are-consumed-outside-the-config-folder`.
- [x] `release-payload-is-the-only-deliverable-and-stays-inert` — the repository
  `.github` holds only `skills/verisolve-init`, no live `agents/config/contracts/
  playbook/workflows/lib`, three agent templates, no agent file nested under
  `skills/`, and the reference documents skill-local-inertness plus reload.

## F. Manual checks that require a real pipeline

These cannot be automated without an external CI system; document the result of
each when you wire a real Oracle:

- [ ] Replace `oracle.start` / `oracle.check` with the real integration and
  confirm `start` returns within one command timeout while the pipeline runs for
  minutes or hours.
- [ ] Confirm `check` stays bounded across a long pipeline (no blocking) and
  that the optional `poll-verifications` worker advances results between turns.
- [ ] Confirm a real guardrail rejection leaves the pipeline untouched.
- [ ] Confirm a high-risk review rejection reverts the change and emits
  `ReviewRejectEvent`.
