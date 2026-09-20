---
name: devflow-state
version: "3.28.7"
description: >-
  Use when initializing, checkpointing, resuming, or checking status of a devflow workflow,
  mentions "/devflow-state", "/checkpoint", "/resume", "/workflow-status", or "工作流状态".
  Manages devflow workflow state with init/checkpoint/resume/status/complete commands.
  v3.6 状态模型。
paths:
  - ".devflow/*.state.json"
disable-model-invocation: false
allowed-tools:
  - read
  - write
  - exec
  - glob
---

# /devflow-state - 工作流状态管理

> **用途**：管理 devflow 工作流状态，支持检查点保存和恢复。

## 使用方式

```
/devflow-state init <feature>              # 初始化新工作流
/devflow-state checkpoint <feature> [note] # 保存检查点
/devflow-state resume <feature>             # 从检查点恢复
/devflow-state status <feature>            # 查看详细状态
/devflow-state complete <feature> <phase>  # 标记阶段完成
/devflow-state complete-stage <feature> <P0..P10> # 兼容别名，实际完成主阶段
/devflow-state reconcile <feature> [--apply] # 收据链对账（--apply 只进不退）
/devflow-state repair <feature> [options]  # 修复历史空 phase 键（不触碰冻结树 hash）
/devflow-state migrate-tree <feature>      # skill 升级后显式迁移树锚点（v3.15.1）
/devflow-state list                       # 列出所有工作流
```

> **v3.15.1 树锚点规则**：`complete`/`reconcile`/`audit-receipts` 强制校验收据 `SKILL_TREE`
> == state 冻结树（`scope.skill_tree_sha256`）。skill 升级导致漂移时，唯一放行路径是
> `migrate-tree`（写入 `SKILL-TREE-MIGRATION` 收据 FROM_TREE/TO_TREE 后更新冻结值）；
> `repair` 绝不覆盖冻结树 hash。

## 示例

```
/devflow-state init m-03-basic-library
/devflow-state checkpoint m-03-basic-library "P3 编码完成"
/devflow-state resume m-03-basic-library
/devflow-state status m-03-basic-library
/devflow-state complete m-03-basic-library P3
/devflow-state list
```

## 底层脚本

本命令底层调用 `scripts/devflow-state.sh`：

```bash
# 初始化
bash "$SKILL_ROOT/scripts/devflow-state.sh" init m-03-basic-library

# 保存检查点
bash "$SKILL_ROOT/scripts/devflow-state.sh" checkpoint m-03-basic-library "P3 编码完成"

# 恢复
bash "$SKILL_ROOT/scripts/devflow-state.sh" resume m-03-basic-library

# 状态
bash "$SKILL_ROOT/scripts/devflow-state.sh" status m-03-basic-library

# 标记完成
bash "$SKILL_ROOT/scripts/devflow-state.sh" complete m-03-basic-library P3

# 列出所有
bash "$SKILL_ROOT/scripts/devflow-state.sh" list
```

## 状态文件

状态文件存储在项目 `.devflow/` 目录（可通过 `STATE_DIR` 环境变量覆盖）：

```
.devflow/
├── m-03-basic-library.state.json
├── payment-system.state.json
└── user-management.state.json
```

## 与 /devflow 集成

| 命令 | 场景 |
|------|------|
| `/devflow <feature>` | 开始新工作流时 |
| `/devflow-state checkpoint <feature>` | 每个 Phase 完成后 |
| `/devflow-state resume <feature>` | 中断后恢复 |
| `/devflow-state status <feature>` | 查看进度 |
| `/devflow-state complete <feature> <phase>` | Phase 切换时 |

## 输出示例

```
=== DevFlow 状态: m-03-basic-library ===
当前阶段: P3
完成阶段: P0, P0b, P1, P2
待完成: P3b, P3c, P3d, P4, P5, P6, P7, P8, P9, P10

检查点:
  cp_20260812_113000 - P3 - "编码完成"
  cp_20260812_120000 - P3 - "Review 完成"
```

## 角色约束

- 由主 Agent 执行
- 可在任意 Phase 切换前调用

## 注意事项

1. 状态文件是 JSON 格式，可手动编辑
2. 如果需要完整的 Phase 历史，使用 `complete` 命令标记阶段完成
3. 使用 `list` 可以查看所有运行中的工作流
4. 版本一致性检查：`bash "$SKILL_ROOT/scripts/check-skill-version.sh"`（确保所有 commands/phases/subagents 版本一致）
