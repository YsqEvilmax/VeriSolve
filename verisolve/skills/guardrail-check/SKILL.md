---
name: guardrail-check
description: Deterministically reject unsafe or over-limit changes before apply or verification.
---

# guardrail-check

## When to use

For every VSChange, before invoking either `apply-change` or `verify-change`.

## Input

`{"change":VSChange,"guardrails":config.verification.guardrails}`.

## Output

Exactly one decision: `{"accepted":true,"reasons":[]}` or
`{"accepted":false,"fail_category":"guardrail_rejected","reasons":[...]}`.
The rejection reasons passed onward are capped at three strings.

## Deterministic rules

Reject any forbidden target or content-pattern match, or patch exceeding the
configured file, byte, or line limits. Do not use a model to evaluate these
rules. The workflow runtime evaluates them as deterministic predicates.

## Implementation

Pass the UTF-8 request file path to `run.ps1`. It is a JSON transport bridge
only and performs no matching, policy evaluation, or decision-making.

## Prohibited

Never call the Oracle after rejection; never edit a Change or return a
success-shaped fallback.
