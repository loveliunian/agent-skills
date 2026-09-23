---
name: small-change
version: "3.30.8"
description: Use when a user requests a bounded change to an existing project, such as a local UI behavior, configuration, bugfix, optional API addition, validation/default adjustment, or additive persistence update.
allowed-tools: [read, write, exec, glob, grep, task]
---

# /small-change - 现有项目的小需求 / 小改动

不要按需求字数判断“小”。必须先扫描当前项目，再让机器契约决定 MICRO 或 FULL。

> Gate 阶段名 `SMALL-CHANGE`（收据 `gates/SMALL-CHANGE/`）：`classify` 产出分类合同，`verify` 产出完成收据。

## 用法

```text
/small-change <change-id> "<自然语言需求>" [--target=merge-ready|released]
/devflow --mode=small-change <change-id> "<自然语言需求>"
```

默认 `merge-ready`。只有绑定并重验 P7 部署和 P8 监控收据，才可声明 `RELEASED`。

## 项目扫描与自动路由

将命令、范围、命中文件和结论写入 `.devflow/<change-id>/project-scan.txt`。十个表面必须逐项填写 `HIT|MISS|NA`：DB、领域模型、API、客户端、配置、测试、权限、流程、跨服务、历史数据。

```bash
bash "$SKILL_ROOT/scripts/small-change-gate.sh" classify <change-id>
```

- `DECISION=MICRO`：一个有界改动，执行聚焦验证。
- `DECISION=FULL`：自动改走 `/devflow --mode=change`，不得手工降级。
- 扫描缺项、无法定位受影响面或合同矛盾：`BLOCKED`。

分类矩阵见 `references/small-change-classification.md`。

## MICRO 验证

1. 用 `templates/小需求变更-模板.md` 冻结主题、影响面、受影响文件、验收条件和验证命令。
2. 对现有垂直切片做最小实现；持久化改动仍须按 Runtime Profile 的 MIGRATION_ADAPTER 执行。
3. 执行：

```bash
bash "$SKILL_ROOT/scripts/small-change-gate.sh" verify <change-id>
```

4. Gate 绑定合同、扫描、报告、受影响文件、实际验证日志和必要的迁移/P7/P8 收据。

## Bug 修复契约（bugfix 类）

1. 修复前：复现问题，保存失败命令与原始输出（`BASELINE_FAIL: command/exit_code/evidence`）。
2. 定位最小根因（`ROOT_CAUSE: file:line/explanation`）。
3. 修复后必须新增 `FAIL_TO_PASS` 回归测试，并运行相关 `PASS_TO_PASS` 回归套件。
4. 禁止删除/放宽失败测试、用 catch/默认值屏蔽错误或顺手重构；不得改变未被 bug 涉及的公共行为。
5. 修复范围扩大时升级 FULL。

完成条件：`FAIL_TO_PASS=PASS`、`PASS_TO_PASS=PASS`、`SCOPE_DRIFT=0`。

## 强制升级 FULL

破坏性 API、schema 破坏、权限、状态机、跨服务、新模块/服务、大回填、多项逻辑变更，或扫描命中权限/流程/跨服务/历史数据，必须 FULL。

---

## 结构化产物层（v3.25.2）

本阶段产物已结构化：AI 按 `schemas/small-change.schema.json`（样例 `examples/structured/small-change.sample.json`）填 `.devflow/<change-id>/small-change.json`（feature 字段即 change-id），再跑管线校验并确定性渲染 Markdown——**校验失败不渲染、不落盘、不进 Gate**；空集合必须 `zero_results` 显式声明。渲染格式与阶段 Gate 的机器解析契约逐字段兼容，模板保留为语义参考。

```bash
python3 scripts/df_pipeline.py small-change --input .devflow/<feature>/(<change-id>/)small-change.json --out docs/小需求变更/<change-id>-小需求变更.md
```
