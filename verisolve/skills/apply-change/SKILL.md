---
name: apply-change
description: Apply or revert a validated VSChange through the configured executor.
---

# apply-change

## When to use

After deterministic guardrail acceptance to apply; after a failed verification
or review to revert.

## Input

UTF-8 request file passed as `-RequestPath`, containing
`{"operation":"apply|revert","change":VSChange}`.

## Output

For apply, return exactly `{"ok":boolean}`. For revert, return no payload on
success. Transport errors are explicit failures.

## Implementation

`run.ps1` forwards the JSON request to the configured external executor. It
does not validate, edit, or synthesize the diff.

## Prohibited

No guardrail bypass, verification, verdict interpretation, or resolver calls.
