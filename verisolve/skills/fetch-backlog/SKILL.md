---
name: fetch-backlog
description: Fetch backlog pages from a configured problem-source adapter.
---

# fetch-backlog

## When to use

At batch start and when the source returns a continuation cursor.

## Input

One UTF-8 request file passed as `-RequestPath`, containing
`{"source":"...", "cursor":null|string}`.

## Output

One JSON object: `{"problems":[VSProblem,...], "next_cursor":null|string}`.
The workflow validates each Problem against `contracts/vs-problem.schema.json`.

## Implementation

`run.ps1` performs source IO only. It may read a configured source file or call
a configured external source command. The `example` source returns an empty
page. It must not triage, rank, infer fields, or modify Problem semantics.

## Prohibited

No reasoning, validation beyond transport parsing, resolver calls, or
verification decisions.
