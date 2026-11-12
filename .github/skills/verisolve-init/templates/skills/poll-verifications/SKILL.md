---
name: poll-verifications
description: Optionally run an independent PowerShell worker to refresh pending verification results.
---

# poll-verifications

## When to use

Use only when the user requests autonomous background status refresh. Normally
Copilot calls `verify-change/check.ps1` on a later turn.

## Input / output

`run.ps1 -Mode start|status|stop`. Start returns a PID and worker status. The
worker runs check mode once per configured interval; status reports the PID
file. Stop targets only that recorded worker process.

## Prohibited

Do not block Copilot on long pipelines, edit Verdicts, run resolver logic, or
write pending state without `verify-change/pending-store.ps1` locking. The
poller is optional and decoupled from Agent context.

## Called by

Explicit user request or `verisolve-init` setup guidance.

## Config dependencies

`config/verisolve.verification.json#poll_interval_sec`,
`pending_verifications_path`; `config/verisolve.cli.json#lock_file`,
`oracle.check`, and `command_timeout_seconds`.
