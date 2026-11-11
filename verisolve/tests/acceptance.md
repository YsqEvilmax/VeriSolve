# VeriSolve acceptance checklist

Run these checks with the configured Agent runtime and mock source, executor,
and Oracle adapters. All length limits count Unicode code points, including
both endpoints. The prior PowerShell suite covered these scenarios; this file
is the runtime-independent acceptance specification.

## Contract schemas

- [ ] Accept VSProblem with all exact fields; reject missing or extra
  top-level/signature fields.
- [ ] Accept `problem_id` at 1 and 128 code points; reject empty and 129.
- [ ] Accept severity `critical|high|medium|low|null`; reject other values.
- [ ] Accept finite `priority_score` number or null; reject booleans, NaN, and
  infinity.
- [ ] Accept 0 and 20 signature keywords; reject 21. Accept a 64-code-point
  keyword; reject 65.
- [ ] Accept VSVerdict with 0 and 3 top_errors; reject 4.
- [ ] A failed verdict requires a case-sensitive built-in or configured
  additional fail_category. A successful verdict permits null.
- [ ] Accept VSChange IDs at 1 and 128 code points; reject empty and 129.
- [ ] Accept diff lengths 1 and 100000; reject empty and 100001.
- [ ] Accept summary lengths 1 and 200; reject empty and 201.
- [ ] Accept target counts 1 and 50; reject 0 and 51.
- [ ] Reject changes missing or adding fields.
- [ ] Count an astral Unicode character as one code point in summary and other
  bounded strings.
- [ ] Accept retry summaries at 1 and 200; reject empty and 201. Accept
  top_errors counts 0 and 3; reject 4.
- [ ] Accept Playbook solution summaries at 0 and 300; reject 301.

## Agent contracts and contexts

- [ ] Runtime loads exactly `triage.agent.md` and `resolver.agent.md`; review
  selects ResolverAgent's review mode and adds no agent kind.
- [ ] Triage returns only category, severity, and bounded keywords; reject
  prose, unexpected fields, invalid categories, and overlong keywords.
- [ ] Each problem gets a fresh TriageAgent context.
- [ ] Each resolve attempt, retry, and review gets a fresh ResolverAgent
  context. Resolve input contains only the bounded projection and optional
  bounded Playbook projection. Retry feedback contains only prior summary,
  fail_category, and at most three top_errors in addition to that projection.
- [ ] Review context contains only diff and acceptance criteria. Inject
  canary log text and verify it never appears in any Agent context.
- [ ] Resolver output is VSChange only; only verify-change may produce
  VSVerdict or author `ok`.

## Scheduling, guardrails, verification

- [ ] With several categories and same-category items, verify category priority
  and in-category order: Playbook hit first, match score descending, severity
  descending, creation time ascending; exact ties preserve input order.
- [ ] All items in one batch search the same pinned snapshot; queued writes are
  invisible until atomic batch-boundary publication.
- [ ] A forbidden target, forbidden pattern, or patch-boundary violation
  bypasses both apply and verify. Assert Oracle mock invocation count is zero.
- [ ] With three independent Oracle calls delayed two seconds each, total
  elapsed verification time is near two seconds rather than six; other Problem
  tasks continue while a verdict is pending.
- [ ] Verify deadline and polling use JSON configuration. Oracle timeout and
  transport failure are surfaced as failures, never success.
- [ ] Apply is reverted after failed verification or rejected high-risk
  review. Locks cover all targets in stable order and do not serialize
  unrelated targets.

## High-risk review

- [ ] Default category list is `incident`; parse comma-separated values using
  trim, empty-item removal, and case-sensitive matching.
- [ ] Accept one/multiple values from `bug|incident|maintenance|other`; fail
  startup on any outside value.
- [ ] Null or out-of-domain triage category warns and behaves as non-high-risk.
- [ ] Review runs only after `Verdict.ok == true` and only for configured
  TriageAgent categories, never source category, severity, or adapter.
- [ ] A review rejection emits ReviewRejectEvent and fails/reverts that attempt.

## Playbook concurrency and durability

- [ ] Run 100 concurrent submitters; the single consumer appends all events
  exactly once and in queue order.
- [ ] Reads during queued writes continue seeing the prior immutable snapshot;
  nested snapshot values cannot be mutated by callers.
- [ ] Confidence equals `(successes + 1) / (successes + failures + 2)` and
  patterns below `low_conf_threshold` are marked downgraded.
- [ ] Measure a delayed/large log replay: file reads occur in the IO worker and
  do not stall the workflow event loop.
- [ ] Stop/restart the runtime and rebuild from `events.log`; assert snapshot
  matches the pre-shutdown state.

## Retry and escalation

- [ ] One initial attempt plus one configured retry creates two distinct
  ResolverAgent contexts. Feedback size never exceeds the stated limits.
- [ ] Two failed attempts produce one Escalation/Skip result and no Archive
  event. Verify failed attempts do not create or contaminate Playbook entries.
- [ ] Successful Oracle verdict without high-risk review archives only after
  acceptance. Successful high-risk review archives only after approval.

## CLI and PowerShell boundary

- [ ] Example source returns an empty page and null cursor; its Oracle fixture
  always returns `ok=false` with `fail_category=unknown`.
- [ ] `scripts/verisolve.ps1` forwards the requested command and original
  arguments to the configured runtime/workflow; unsupported commands and
  missing runtime configuration fail explicitly.
- [ ] Every `skills/*/run.ps1` performs only adapter/process/file IO and JSON
  transport. No script contains orchestration, scoring, ranking, guardrail
  decisions, confidence calculation, or Agent reasoning.
- [ ] Every configuration file is valid JSON. No `.psm1` is used for
  orchestration, reasoning, or hidden business logic.
