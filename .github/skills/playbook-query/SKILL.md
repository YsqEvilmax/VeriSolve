---
name: playbook-query
description: Pin one immutable Playbook snapshot per batch and search it in memory with zero IO.
---

# playbook-query

## When to use

`pin` once at batch start. `query` once per triaged Problem, against the pinned
copy only.

## Input / output

- `run.ps1 -Operation pin -RequestPath <json>` — ignores the request body, reads
  `playbook/snapshot.json` exactly once, and returns
  `{version, pinned_at, patterns}`. The coordinator keeps this in memory for the
  whole batch.
- `run.ps1 -Operation query -RequestPath <json>` with
  `{snapshot, category, signature:{keywords,features}, top_k?, min_score?}` and
  returns `{snapshot_version, category, top_k, min_score, match_count, matches}`.
  Each match carries `pattern_id`, `solution_summary` (0–300 code points),
  `score`, `confidence`, `downgraded`, and `stats`.

Scoring is `embedding_weight * lexical keyword cosine + feature_weight *
feature Jaccard + confidence_weight * laplace confidence`, with every weight and
threshold taken from config. Patterns of another category are excluded; results
are ordered by score descending, confidence descending, then pattern ID.

## Prohibited

- `query` must not read `playbook/snapshot.json`, take a lock, or write
  anything. Deleting the live snapshot after `pin` must not change results.
- No Agent call, no event emission, and no mutation of the pinned object.
- Never project `features`, `raw`, `artifacts`, or `metadata` into an Agent
  input; only `pattern_id` and `solution_summary` may leave this skill.

## Called by

`agents/verisolve.agent.md`, `workflows/run-pipeline.workflow.md`, and
`scripts/verisolve.ps1 rank` / `kb query`.

## Config dependencies

`config/verisolve.knowledge_base.json#snapshot_path`, `embedding_weight`,
`feature_weight`, `confidence_weight`, `low_conf_threshold`, `top_k`,
`min_score`.
