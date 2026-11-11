---
name: verisolve-cleanup
description: Safely uninstall VeriSolve-owned scaffold files and clear local pending verification state.
---

# verisolve-cleanup

## When to use

Only when the user explicitly asks to uninstall/remove VeriSolve from a
workspace. This is destructive and must not run as an automatic follow-up.

## Input / output

Run `run.ps1 -Mode plan -Workspace <path>` first. Show the exact files that
will be deleted, modified files that will be retained, and the warning that
clearing pending state does not cancel external pipelines. Obtain explicit
confirmation. Then run `run.ps1 -Mode uninstall -Workspace <path>
-ConfirmUninstall`.

Output a deletion/retention report. Pending, completed, and infrastructure
failure records are cleared only after confirmation and under the pending
state lock.

## Prohibited

- Never delete paths absent from the init ownership manifest.
- Never delete a manifest-owned file whose current SHA-256 differs from the
  scaffold hash; report it as modified and retain it.
- Never follow reparse points or paths outside the workspace `.github`.
- Never stop arbitrary processes; stop only the poller PID after validating its
  command line.
- Never claim pending external pipelines were cancelled.

## Called by

Explicit user request in Copilot Chat only; not called by init or workflows.

## Config dependencies

`config/verisolve.cli.json#pending_verifications_path`, `lock_file`;
`config/verisolve.system.json` lock timeout/poll interval.
