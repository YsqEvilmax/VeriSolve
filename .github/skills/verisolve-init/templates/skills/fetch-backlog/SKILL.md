---
name: fetch-backlog
description: Read a configured backlog source and return contract-shaped problems with ingest_seq.
---

# fetch-backlog

## When to use

At the start of a batch and for every follow-up page while `next_cursor` is not
null.

## Input / output

`run.ps1 -RequestPath <json-file>` with
`{source, cursor, start_ingest_seq?}`. Output:

```json
{ "problems": [ ... ], "next_cursor": null,
  "ingest_envelopes": [ { "problem_id": "p1", "ingest_seq": 1 } ],
  "next_ingest_seq": 2 }
```

Every Problem is validated against `contracts/vs-problem.schema.json`; an
invalid item aborts the fetch instead of entering the pipeline. `ingest_seq` is
a strictly increasing per-batch sequence assigned in fetch order and kept in
the envelope, never inside the VSProblem contract. `source:"example"` returns an
empty page.

## Prohibited

- Do not triage, infer or repair fields, rank, deduplicate by guesswork, or edit
  the source.
- Never swallow a contract violation; fail loudly so the batch stops.
- Never embed `ingest_seq` in the Problem payload.

## Called by

`agents/verisolve.agent.md` following `workflows/run-pipeline.workflow.md`, and
`scripts/verisolve.ps1 run`.

## Config dependencies

`config/verisolve.cli.json#problem_sources`, `command_timeout_seconds`. Every
external source command is configured; Checkmarx is only an example.
