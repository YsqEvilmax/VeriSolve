---
name: verisolve-cleanup
description: 卸载 VeriSolve（先备份配置，再按白名单删除，最后删除自身）。
---

# verisolve-cleanup

本 Skill 由 `verisolve-init` 的 scaffolding 一并释放到
`.github/skills/verisolve-cleanup/`。它只删除 VeriSolve 自己安装的文件，
绝不触碰用户自定义的其它 agent / skill / 配置。

## When to use

仅在用户明确要求"卸载 / 移除 VeriSolve"时使用。这是破坏性操作，不能作为
任何流程的自动后续步骤。

## Input / output

输入：工作区路径（默认 `cwd`），以及用户的显式确认。

1. 先出计划（只读，不改任何文件）：

   ```powershell
   pwsh -NoProfile -File .github/skills/verisolve-cleanup/scripts/cleanup.ps1 -Mode plan -Workspace <workspace>
   ```

   把 `would_delete` 清单和"外部流水线不会被取消"的警告原样展示给用户。

2. 用户确认后执行：

   ```powershell
   pwsh -NoProfile -File .github/skills/verisolve-cleanup/scripts/cleanup.ps1 -Mode uninstall -Workspace <workspace> -ConfirmUninstall
   ```

输出：`{backup_path, deleted, retained, not_found}`。
未带 `-ConfirmUninstall` 时脚本拒绝执行。

## Deletion order（脚本内固定）

1. **备份**：把当前 `.github/config/verisolve.*.json` 复制到
   `.github/verisolve-backup-<UTC timestamp>/`。备份失败 → 中止，不删任何东西。
2. 删除文件：`.github/agents/{verisolve,triage,resolver}.agent.md`、
   `.github/contracts/vs-*.schema.json`、
   `.github/workflows/{run-pipeline,high-risk-review}.workflow.md`。
3. 删除目录：`.github/skills/{fetch-backlog,playbook-query,playbook-commit,
   guardrail-check,apply-change,verify-change,poll-verifications,
   rank-and-schedule}`、`.github/lib/`、`.github/playbook/`。
4. 删除安装器自身目录 `.github/skills/verisolve-init/`。
5. **最后**删除 `.github/skills/verisolve-cleanup/`（正在运行的脚本所在目录）。

## Prohibited

- 不删除白名单之外的任何路径；不按通配符批量删除 `.github/skills/*`。
- 不删除 `.github/copilot-instructions.md`（可能是用户自己的文件），
  只把它列入 `retained` 并提示用户自行确认。
- 未备份不删除；未确认不删除。
- 不停止或取消外部流水线，也不声称已取消。

## Called by

用户在 Copilot Chat 明确要求卸载时直接触发；不被 init 或任何 workflow 调用。

## Config dependencies

`.github/config/verisolve.verification.json#pending_verifications_path`
（用于备份与统计）、`.github/config/verisolve.cli.json#run_store_path`。
配置缺失时脚本仍可运行，只是备份集合为空并在 `retained` 中说明。
