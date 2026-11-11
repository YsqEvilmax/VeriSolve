---
name: verify-change
description: Obtain an Oracle verdict for an applied change, asynchronously.
---

# verify-change

## When to use

Only after `guardrail-check` accepts and `apply-change` completes.

## Input

UTF-8 request file passed as `-RequestPath`, containing
`{"operation":"start|poll","change":VSChange,"problem":VSProblem,
"timeout_seconds":number,"cursor":null|string}`.

## Output

Start returns either a complete `VSVerdict` or
`{"state":"pending","cursor":"..."}`. Poll returns the same shapes. The
workflow applies the configured deadline and interval; this Skill never waits
in a way that blocks another Problem. The oracle's `ok` value is authoritative.

## Implementation

`run.ps1` calls only the configured Oracle command and relays its response.
VSVerdict is checked against `contracts/verdict.schema.json` plus configured
fail-category extensions by the deterministic runtime. The configured
ExampleAdapter fixture always returns `ok=false` with `unknown`.

## Prohibited

No ResolverAgent call, verdict inference, or passing Oracle evidence to an
Agent. Do not silently turn transport errors into an `ok` verdict.
