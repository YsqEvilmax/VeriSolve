---
name: verisolve-init
description: Scaffold VeriSolve in this workspace or resume its pending verification work.
context: fork
tools: ['terminal', 'read', 'edit']
---

# verisolve-init

## When to use

Use when a user asks to initialize VeriSolve, install its workspace scaffold,
or continue an existing VeriSolve setup. This Skill runs in a forked context;
do not block the main conversation on long verification pipelines.

## Input / output

Input: current workspace path and an optional `scaffold` or `resume` intent.
Output: whether the system was scaffolded or already existed, integrations that
still need configuration, pending/completed verification counts, and a closing
prompt to select the VeriSolve agent in Copilot Chat.

## Steps

1. Use `run.ps1 -Mode inspect` to check for
   `.github/agents/verisolve.agent.md`.
2. If absent, show the planned files and call `run.ps1 -Mode scaffold`.
   Scaffolding is additive: never overwrite existing files. It writes an
   ownership manifest for files it created.
3. If present, do not overwrite or reset anything. Read pending verification
   and latest run status; recommend resuming through the VeriSolve Agent.
4. Read `config/verisolve.cli.json`. Report every unconfigured non-example
   problem source, executor apply/revert command, and Oracle start/check
   command. Explain users configure integrations in JSON; Checkmarx is only an
   optional external-report example.
5. Tell the user they can start optional background checks with
   `poll-verifications`.

## Prohibited

- Never overwrite existing files, clear user data, or invoke the cleanup Skill.
- Never run a long pipeline or wait for verification.
- Never infer missing integration commands or secrets.
- Do not perform triage, resolution, verdict decisions, or orchestration.

## Called by

The user directly triggers this Skill in Copilot Chat. It prepares the
workspace for the `.github/agents/verisolve.agent.md` coordinator.

## Config dependencies

`config/verisolve.cli.json` for source/executor/Oracle readiness;
`config/verisolve.verification.json` for the pending file path;
`config/verisolve.system.json` for lock timeout and polling values.
