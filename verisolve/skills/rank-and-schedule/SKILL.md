---
name: rank-and-schedule
description: Deterministically group and order a triaged batch against one pinned snapshot.
---

# rank-and-schedule

## When to use

After all bounded TriageAgent calls and Playbook searches for the batch finish.

## Input

UTF-8 request file path passed to `run.ps1`. Its JSON contains items with
Problem ID, controlled triage result, `created_at`, nullable
`priority_score`, `playbook_matched`, `match_score`; pinned category priority
matrix and the batch snapshot version.

## Output

Stable ordered items grouped by triage category. Category order follows the
configured priority matrix. Within each category order by playbook match first,
match score descending, severity descending, then `created_at` ascending.
Retain source order for exact ties and report the pinned snapshot version.

## Implementation

Sorting/grouping are deterministic runtime-native operations; `run.ps1` only
transports JSON and does not rank or call an agent.

## Prohibited

No mutable current-snapshot reads, random tie-breaking, extra agent, or
severity-based high-risk classification.
