---
name: playbook-query
description: Search one immutable in-memory Playbook snapshot.
---

# playbook-query

## When to use

Once per Problem after triage, using the snapshot pinned at batch start.

## Input

UTF-8 request file path passed to `run.ps1`, containing
`{"snapshot":Snapshot,"category":string,"signature":object,
"top_k":number,"min_score":number}`.

## Output

Matches containing the immutable pattern projection, score, and
`downgraded` flag, sorted by score descending then stable pattern ID. Return no
more than `top_k` matches and omit scores below `min_score`.

## Deterministic scoring

`embedding * embedding_weight + feature * feature_weight + confidence *
confidence_weight`. Use configured weights. Mark a match downgraded when its
Laplace-smoothed confidence is below `low_conf_threshold`.

Embedding similarity is cosine similarity normalized to `[0,1]` as
`(cosine + 1) / 2`; return zero for missing, dimension-mismatched, or zero-norm
vectors. Feature similarity is Jaccard similarity over ordinal sets containing
keyword tokens and feature-key/serialized-value tokens; return zero for an
empty union.

## Implementation

Search is runtime-native, pure in-memory, zero-lock and zero-IO. `run.ps1`
provides only JSON transport; it must never open the snapshot file.

## Prohibited

No disk lookup, snapshot mutation, blocking lock, or agent-based ranking.
