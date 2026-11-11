---
name: guardrail-check
description: Apply deterministic configured guardrails before a change is applied or verified.
---

# guardrail-check

## When to use

For every VSChange, after contract validation and before `apply-change` or
`verify-change`. A rejected change must never reach either skill.

## Input / output

`run.ps1 -RequestPath <json-file>` with `{change, guardrails}` where
`guardrails` is copied from `config/verisolve.verification.json#guardrails`.
The script validates the change against `contracts/vs-change.schema.json`,
then evaluates:

- `forbidden_targets` — glob patterns (`**`, `*`, `?`) matched against every
  target; a trailing `/**` also matches the directory itself.
- `forbidden_patterns` — regular expressions matched against the diff.
- `max_patch_files`, `max_patch_bytes` (UTF-8), `max_patch_lines`.

Output: `{accepted, fail_category, reasons, metrics}`.
`accepted:false` always carries `fail_category:"guardrail_rejected"` and at
least one reason prefixed `contract:`, `forbidden_target:`, `forbidden_pattern:`,
`patch_files:`, `patch_lines:`, or `patch_bytes:`.

## Prohibited

- No Agent judgment, no execution of the change, and no Oracle or executor call.
- Never start a verification from this skill; the caller decides that only when
  `accepted` is true.
- Never soften a configured limit or invent one that is not in config.

## Called by

`agents/verisolve.agent.md` and `workflows/run-pipeline.workflow.md`.

## Config dependencies

`config/verisolve.verification.json#guardrails` and the contract bounds used by
`contracts/vs-change.schema.json`.
