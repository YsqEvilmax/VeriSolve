---
name: rank-and-schedule
description: Deterministically group triaged problems by category and order them within each category.
---

# rank-and-schedule

## When to use

Once per batch, after TriageAgent returned controlled output for every Problem and
after `playbook-query` resolved the best match for each of them.

## Input / output

`run.ps1 -RequestPath <json-file>` with
`{items:[{problem_id,triage_category,severity,priority_score,created_at,ingest_seq,playbook_matched,match_score}]}`.
Output is `{schedule_order, groups:[{category,group_priority,problem_ids}], problem_order}`.

Group order uses `priority_matrix` (descending) from config. Within a category the
ordering keys come from `schedule_order`: `playbook_matched`, `match_score`,
`severity`, `created_at`, `ingest_seq`. `created_at` and `ingest_seq` sort
ascending; every other key sorts descending. `ingest_seq` is the monotonic
sequence assigned by `fetch-backlog`, so identical items never depend on
dictionary order.

## Prohibited

No triage, no Playbook lookup, no Agent call, and no mutation of the input
items. The script must not invent ordering keys; an unknown `schedule_order`
entry fails fast.

## Called by

`agents/verisolve.agent.md` following `workflows/run-pipeline.workflow.md`, and
`scripts/verisolve.ps1 rank` for local runs.

## Config dependencies

`config/verisolve.categories.json#category_values`, `priority_matrix`,
`priority_matrix_default`, `severity_order`, `schedule_order`.
