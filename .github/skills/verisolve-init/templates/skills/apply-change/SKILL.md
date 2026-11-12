---
name: apply-change
description: Idempotently apply or revert a validated VSChange using configured executor commands.
---

# apply-change

## When to use

Apply after guardrail acceptance and before verify-change/start. Revert after a
failed verdict or rejected review. verify-change/start repeats apply
idempotently before triggering the external pipeline.

## Input / output

Request file contains `{operation:"apply"|"revert",change:VSChange}`.
Apply returns `{ok:boolean}`; revert returns completion status.
`change_id` is the idempotency key for both operations; repeated identical
requests must not duplicate side effects.

## Prohibited

No verification judgment, policy checks, diff edits, or inferred success.

The shipped `mock-executor.ps1` in this directory is a fixture used by the
acceptance suite; replace `executor.apply` / `executor.revert` with the real
integration before running live.

## Called by

VeriSolve coordinator and pipeline workflow.

## Config dependencies

`config/verisolve.cli.json#executor.apply` and `executor.revert`.
