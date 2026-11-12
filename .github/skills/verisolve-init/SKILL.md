---
name: verisolve-init
description: 初始化或续接 VeriSolve（环境检测、scaffolding、外部配置引导），不承载编排与推理。
context: fork
tools: ['terminal', 'read', 'edit']
---

# verisolve-init

本 Skill 是 VeriSolve 的**唯一发布物**：`templates/` 存放整套系统骨架，
`scripts/` 存放三个只负责 IO 的 PowerShell 脚本。init 只做"检测 → 释放 →
引导"，**绝不**执行 triage / resolve / verify，也**不**充当 VeriSolve 的运行时入口
（编排属于 `verisolve.agent.md`）。

## When to use

- 用户说"初始化 VeriSolve / 安装 / 部署这套系统"。
- 用户说"继续上次的 VeriSolve 任务"（此时只读状态，不做别的）。
- 用户刚把本目录拷进 `.github/skills/`。

## Input / output

输入：当前工作区路径（默认 `cwd`），以及用户的 `scaffold`（首次）或 `resume`（续接）意图。
输出：

1. 环境检测逐项结果（✅ 已就绪 / ❌ 缺失 + 安装建议，不自动安装）。
2. 状态结论：`scaffolded=false` → 执行 scaffolding；`scaffolded=true` → 仅汇报
   `X 已解决 / Y 待验证 / Z 待处理` 并引导切换 agent。
3. scaffolding 的 `created` / `skipped` 清单。
4. 未完成的外部配置项：字段名、示例值、环境变量建议（不写敏感信息）。
5. 就绪提示（重载窗口提示为硬要求，见步骤 6）。

## Steps

### 1. 环境检测（只读）

```powershell
pwsh -NoProfile -File .github/skills/verisolve-init/scripts/check-prerequisites.ps1 -Workspace <workspace>
```

逐项渲染为清单，每项必须给出 ✅ / ❌ 与建议命令：

| 项 | 判定 | 未通过时的建议（仅提示，不执行） |
| --- | --- | --- |
| `pwsh` | `$PSVersionTable.PSVersion.Major -ge 7` | `winget install Microsoft.PowerShell` |
| `git` | `git --version` 成功 | `winget install Git.Git` |
| `config_placeholders` | `verisolve.cli.json` 中 problem source / executor / oracle 命令非空 | 步骤 5 逐项引导 |

脚本恒以退出码 0 结束，缺失项只是 `ok:false`。是否继续由本 Skill 决定：
`pwsh` 缺失 → 停止（后续脚本无法运行）；`git` 缺失 → 提示但不阻断；
配置占位符缺失 → 继续 scaffolding，在步骤 5 引导。

### 2. 状态检测（只读）

```powershell
pwsh -NoProfile -File .github/skills/verisolve-init/scripts/detect-state.ps1 -Workspace <workspace>
```

- `scaffolded=false` → 进入步骤 3。
- `scaffolded=true` → **到此结束**。用 `last_run` 输出：

  > 已 scaffold。上次运行：`<resolved>` 已解决 / `<pending_count>` 待验证 /
  > `<skipped + escalation>` 待处理。
  > 请切换到 Copilot Chat 的 **VeriSolve** agent 继续任务。

  不执行任何编排，不调用其它 Skill，不修改文件。

### 3. Scaffolding（仅首次）

```powershell
pwsh -NoProfile -File .github/skills/verisolve-init/scripts/scaffold.ps1 -Workspace <workspace>
```

脚本把 `templates/` 释放到正确位置：

| 模板 | 目标 |
| --- | --- |
| `templates/agents/` | `.github/agents/` |
| `templates/skills/` | `.github/skills/` |
| `templates/config/` | `.github/config/` |
| `templates/contracts/` | `.github/contracts/` |
| `templates/playbook/` | `.github/playbook/`（`events.log` 空、`snapshot.json` 空结构、`pending-verifications.json` 为 `[]`） |
| `templates/workflows/` | `.github/workflows/` |
| `templates/lib/` | `.github/lib/` |
| `templates/copilot-instructions.md` | `.github/copilot-instructions.md`（已存在则跳过） |

必须**幂等**：目标文件已存在就跳过并计入 `skipped`，绝不覆盖用户改动。
模板缺失 → 脚本报错并回滚本次已释放的文件（退出码 1）；此时把错误原文告诉用户，
不要重试，也不要用"手工复制"绕过校验。

### 4. 生成 cleanup skill

`templates/skills/verisolve-cleanup/` 已在步骤 3 一并释放到
`.github/skills/verisolve-cleanup/`。不要另行创建或改写它。

### 5. 引导外部配置

读取 `.github/config/verisolve.cli.json`，逐项列出仍未填写的占位符：
`problem_sources.<name>.command/arguments`、`executor.apply|revert.command`、
`oracle.start|check.command`。对每一项给出：字段路径、示例值（JSON 片段）、
建议用环境变量注入凭据的方式。

禁止：写入任何 token、密码、私钥；禁止替用户猜测接口地址；禁止自动安装依赖或
自动调用外部服务。Checkmarx 等集成只是"外部报告源"的一个示例，全部走 config。

### 6. 输出就绪提示（必须原样提示重载）

> Scaffolding 完成。Copilot 不会自动加载新 Agent。请**重新加载 VS Code 窗口**
> （或开新会话），然后在 Chat 的 agent 下拉列表选择 **VeriSolve** 开始。
> 外部配置未完成的项请先补齐。

原因：Copilot 的 Agent 发现发生在会话初始化阶段；本 Skill 目录内的
`.agent.md` 只是被复制的资源文件，**不会**被当作 Agent 加载。详见
`references/architecture.md`。

### 7. 禁止事项

见下方 `## Prohibited` 小节。

## Prohibited

- 不在 init 内执行 triage / resolve / verify / playbook 检索。
- 不替代 `verisolve.agent.md` 承载编排。
- 不自动安装依赖。
- 不写用户敏感信息。
- 不覆盖已存在的文件，不删除用户自定义的 agent/skill。
- 不把 `templates/agents/*.agent.md` 当成已加载的 Agent：它们只是被复制的资源。

## Called by

用户在 Copilot Chat 直接触发 `/verisolve-init`。它是安装器，不是运行时入口。

## Config dependencies

`templates/config/verisolve.cli.json`（未 scaffold 时读模板做占位符检测）、
`.github/config/verisolve.cli.json`（已 scaffold 时读实配）、
`.github/config/verisolve.verification.json#pending_verifications_path`、
`.github/config/verisolve.cli.json#run_store_path`。
