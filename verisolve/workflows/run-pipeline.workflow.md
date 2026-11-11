# Run-pipeline workflow

Declarative workflow for one batch. The runtime must execute collection
operations, conditional branches, resource locks, queues, and asynchronous tasks
as deterministic primitives; no third reasoning agent is introduced.

## Batch setup

1. Load and validate all `config/verisolve.*.json` files and the three schemas.
   Treat configured contract limits as authoritative and fail fast if any
   schema boundary disagrees with its corresponding config value. Before
   validating VSVerdict, clone `verdict.schema.json` in memory and append only
   `additional_fail_categories` to its fail-category enum. Preserve every
   built-in value; reject empty, duplicate, or built-in-replacement extension
   values. Parse `high_risk_categories` from
   `config/verisolve.verification.json` by comma, trim each item, discard empty
   items, and fail fast if any remaining item is outside
   `bug|incident|maintenance|other`. An absent/empty setting means `incident`.
2. Read the Playbook snapshot once and pin that immutable version for this
   batch. Snapshot reads and search do not access files or take locks.
3. Fetch backlog pages through `fetch-backlog`; validate each returned item
   against `vs-problem.schema.json`.
4. For each Problem, start an independent TriageAgent context, limited by
   `max_parallel_triage`. Validate its exact three-field structured output.
5. Search the pinned snapshot using configured weights and thresholds. Group
   by triage category; order categories by the configured priority matrix.
   Within a category sort stably by playbook match first, match score
   descending, severity descending, then `created_at` ascending. Preserve
   original order for exact ties.

## Per-problem tasks

Run each scheduled Problem in its own task; a waiting verification task must
not block another Problem.

1. Try matched patterns by confidence descending, then match score descending,
   up to `max_playbook_try`. Each attempt creates a new ResolverAgent context
   in resolve mode. If no pattern succeeds, create new-solution attempts using
   `retry_per_bug` (one retry after the first attempt).
2. Pass only the bounded projection specified in `resolver.agent.md`. For a
   retry, provide a new context and only the permitted bounded failure feedback
   in addition to the base projection.
3. Validate each returned VSChange. Call `guardrail-check` before
   `apply-change` or `verify-change`. A rejected change is a failed attempt and
   must not invoke verify-change.
4. Acquire deterministic resource locks for all targets in ordinal order.
   Apply through `apply-change`. Start `verify-change` as an independent
   asynchronous task and release the ResolverAgent context immediately. The
   verifier alone produces VSVerdict; the workflow only validates and reads
   its boolean `ok`. Poll only according to configured timeout/interval. Keep
   target locks until verdict handling, optional review, and any required
   revert finish; then release them.
5. On a failed verdict, revert the applied change, cap feedback to the last
   summary (<=200), fail_category, and top_errors (<=3), then retry if an
   attempt remains. Never provide logs or full evidence to ResolverAgent.
6. Only after `Verdict.ok == true`, invoke `high-risk-review.workflow.md` when
   the TriageAgent category is configured high-risk. A null or out-of-domain
   category is non-high-risk and emits a warning. A review rejection is a
   failed attempt, is reverted, and submits `ReviewRejectEvent`.
7. On success, submit ArchiveEvent and a successful ConfidenceUpdateEvent for
   the new pattern; if a matched pattern was used, submit its successful
   ConfidenceUpdateEvent too. On a failed matched-pattern attempt, submit its
   negative ConfidenceUpdateEvent; on review rejection, submit
   ReviewRejectEvent. On final failure, submit a single SkipEvent and add the
   Problem to Escalation. Two failed attempts therefore escalate without an
   ArchiveEvent or new Playbook entry.

## Playbook writer and batch boundary

`playbook-commit` enqueues validated events and returns immediately. A single
deterministic writer task consumes the queue in order and uses its IO worker to
append batches to `playbook/events.log`. The file worker performs no scoring,
validation, replay, or confidence calculations. At a batch boundary, read the
event log on an independent IO task, replay the returned event data using
deterministic runtime operations, atomically write `snapshot.json` through the
IO worker, and atomically swap the in-memory immutable snapshot. Later batches
see that version only; pending writes never mutate a snapshot already pinned
for a batch.

## CLI dispatch

The configured external agent runtime receives the requested CLI action and
this workflow path. `run` accepts backlog, dry-run, and parallelism options;
dry-run stops before applying changes or verifying them. `status` reads the
requested run record. `report` preserves the category totals, total count,
Playbook matches, success/skip/escalation lists, and hit-rate summary.
`kb query`, `kb stats`, and `kb rebuild` use the configured Playbook paths and
snapshot rules. All these actions are deterministic runtime operations; they
do not introduce new agents or move business logic into PowerShell.
