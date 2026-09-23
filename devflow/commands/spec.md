---
name: spec
version: "3.30.1"
description: Use when a user asks to clarify a PRD, produce field-level detailed design, design a database or legacy mapping, or complete /spec without implementing code.
paths: [docs/PRD/**, docs/需求/**, docs/详细设计/**]
disable-model-invocation: false
allowed-tools: [read, write, exec, glob, grep, task]
---

# /spec — P0-P2: PRD to Detailed Design

> **方法论权威参考**：`concepts/PRD实施方法论.md`（V1.1）
> **铁律**：`concepts/core.md`
> **命名体系**：本 skill 采用 P0-P10 单轨（v3.9.6 起旧编号描述已全部清除，脚本文件名中的 s 前缀仅为历史标识）。

## Usage

```
/spec <PRD-path> [--scenario=A|B|C] [--sources=N] [--depth=easy|medium|hard]
```

The PRD must exist. Do not substitute a same-topic file.

## Phase File Map

Load these in order before taking any action:

| Phase | Skill File | Gate Script |
|-------|-----------|-------------|
| P0 | `phases/00-需求澄清.md` | `scripts/s0_acceptance_gate.sh` |
| P1 | `phases/01-技术选型.md` | `scripts/s1_fact_sources_gate.sh` |
| P2 | `phases/02-详细设计.md` | `scripts/s2_design_coverage_gate.sh` |
| P2a（v3.9.5） | `commands/design-review.md` + `phases/02a-详细设计评审.md` | `scripts/p2a_design_review_gate.sh` |
| P2b（v3.9.5） | `phases/02b-原型Demo.md` | `scripts/p2b_demo_gate.sh` |
| P3 | `phases/03-规范实现.md` | `scripts/p3_completion_gate.sh`（迁移映射见 `scripts/s3_migration_mapping_gate.sh`） |
| P4 | `phases/04-PRD验证.md` | `scripts/p4_validation_gate.sh` |
| P4b | `phases/04b-PRD-实现对比.md` | `scripts/p4_prd_vs_code.sh` |
| P5 | `phases/05-测试用例.md` | `scripts/p5_test_cases_gate.sh`（主收据）+ `scripts/s5_migration_gate.sh`(B/C) |
| P6 | `phases/06a-单元测试.md`~`06f` | `scripts/s6_first_pass_accuracy.sh` + `scripts/p6_credential_gate.sh` |
| P7 | `phases/07-发布部署.md` | `scripts/artifact_gate.sh P7` |
| P8 | `phases/08-监控配置.md` | `scripts/artifact_gate.sh P8` + `maintenance/s8_graph_health_gate.sh` |
| P9 | `phases/09-文档更新.md` | `scripts/artifact_gate.sh P9` |
| P10 | `phases/10-知识沉淀.md` | `scripts/p10_feedback_gate.sh` + `maintenance/s8b_feedback_gate.sh` |

> **v3.9.5 修复**：P2a/P2b 此前未出现在任何 Phase File Map 中（`p2b_demo_gate.sh` 全 skill 零引用），导致 4 个实测项目原型 Demo 执行率为 0%。`/spec --design-only` 模式现也必须过 P2a；P2b 在改动 < 1 人日或纯后端场景可由用户显式授权跳过（写入 skip-log）。

## P0 — source and acceptance baseline

Load `phases/00-需求澄清.md`. Create:

- `docs/需求/<feature>-需求澄清.md`（需求澄清，模糊点=0）
- `docs/需求/<feature>-验收点.md`（**原子验收点清单，FROZEN**）
- `docs/需求/<feature>-技术约束.md`（使用 `templates/技术约束-模板.md`，状态 FROZEN）

> **P0 强制产出**：`*-验收点.md` 必须包含全部功能点拆分的原子验收点，ID 格式 `M-xx-Fyy-Azz`。
>
> **追溯链**：P0 冻结验收点 → P2 详设需求追溯（acceptance-traceability）→ P5 测试用例 → P6 测试报告。

- `docs/需求/<feature>-PRD评审.md`

Each acceptance row uses `M-xx-Fyy-Azz`, one behavior per row, and status `FROZEN`.

技术硬约束必须先冻结。用户明确指定的组件、版本、许可证或部署方式记录为
`MUST_USE/MUST_NOT_USE`；P1 选型若冲突只能 `BLOCKED`，不得自主替换。只有用户
批准并更新契约后才能恢复。

### P0 Gate Check

```bash
# 模式1：Feature 模式（推荐）
bash "$SKILL_ROOT/scripts/s0_acceptance_gate.sh" <feature>

# 模式2：显式路径模式
bash "$SKILL_ROOT/scripts/s0_acceptance_gate.sh" --criteria docs/需求/<feature>-验收点.md --matrix docs/需求/<feature>-需求澄清.md
```

**Checks (all must pass):**

| # | Check | Command | Pass Condition |
|---|-------|---------|----------------|
| 1 | 验收点数量 | `grep -cE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}'` | > 0 |
| 2 | ID 格式 | each ID matches `M-xx-Fyy-Azz` | all valid |
| 3 | ID 唯一性 | unique count == total count | = 100% |
| 4 | FROZEN 状态 | each ID row has `FROZEN` status | all rows |
| 5 | 无占位符 | `grep -cE 'TODO\|TBD\|待补充\|REPLACE_WITH'` | = 0 |
| 6 | 来源矩阵行数 | authority rows in source matrix | > 0 |
| 7 | 设计覆盖率 | COMPLETE rows / total rows | = 100% |

> **标题缺失 = FAIL**：如果 grep 无匹配，不要输出 `MISSING` 后继续，必须立即 FAIL 并 exit 1。

## P1 — architecture and fact sources

Load `phases/01-技术选型.md`. Reuse project architecture only when it exists; otherwise freeze it through tech selection.

P1 必须读取 P0 技术约束契约，并逐条生成 `constraint_id` 绑定、合规状态和证据。

> **技术选型标准**：所有详设必须遵循项目技术选型文档（如 `docs/技术选型.md`），模板中技术栈以 `{xxx}` 占位，由用户根据实际项目填写。

**必须在进入 P2 前执行** `/init-fact-sources`，至少建立 7 份事实源（`/init-fact-sources` 生成的
文件自带 `DEVFLOW:FACT-SOURCE` 元数据块——来源/时点/适用范围；缺块时 P1 Gate WARN 提示补登记，
「事实文件存在不等于调查完成」）：

### 手维护事实源（5份）

| 文件 | 说明 |
|------|------|
| `_commons.md` | 公共约定、错误码、幂等策略 |
| `_权限矩阵.md` | 角色-权限映射 |
| `_环境与账号.md` | 测试环境、账号凭据 |
| `_菜单Seed索引.md` | 前端菜单结构 |
| `INDEX-章节锚点.md` | 详设章节索引 |

### 自动生成索引（2份）

| 文件 | 说明 |
|------|------|
| `INDEX-表.md` | 数据表索引 |
| `INDEX-接口.md` | API 接口索引 |

### P1 Gate Check

```bash
bash "$SKILL_ROOT/scripts/s1_fact_sources_gate.sh" docs/详细设计
```

**Checks (all must exist and be non-empty):**

| # | Check | Pass Condition |
|---|-------|----------------|
| 1 | `_commons.md` | exists + non-empty |
| 2 | `_权限矩阵.md` | exists + non-empty |
| 3 | `_环境与账号.md` | exists + non-empty |
| 4 | `_菜单Seed索引.md` | exists + non-empty |
| 5 | `INDEX-章节锚点.md` | exists + non-empty |
| 6 | `INDEX-表.md` | exists + non-empty |
| 7 | `INDEX-接口.md` | exists + non-empty |

## P2 — 100% field-level design

Load `phases/02-详细设计.md`. The design must contain:

If the project has no approved `docs/templates/详细设计-模板.md`, initialize from `$SKILL_ROOT/templates/详细设计-模板.md`; do not invent a weaker structure.

### P2.1 文档结构：执行 P1 冻结决策（本阶段不再决策）

> **决策已在 P1 技术选型完成**：详设写单文档（monolith）还是总分文档（total），
> 记录在设计决策记录《详设文档结构决策》（JSON 字段 `design_doc_structure`，机检行
> `design_doc_structure_mode=`）。P2 只读取该冻结结论并选对应模板，**禁止在详设里
> 重新做总分/单体决策或再写决策矩阵**；认为结论不适用时回到 P1 走变更，不得在 P2 自行改结构。

**按冻结结构取模板**（结构、章节与写作细则一律以模板为正本）：

| P1 冻结 mode | 模板 | Gate |
|------|----------|------|
| `monolith`（单文档，默认） | `templates/详细设计-完整版-模板.md` | `--mode=monolith` |
| `total`（总分）· 总文档 | `templates/详细设计-总分总文档-模板.md` | `--mode=total` |
| `total`（总分）· 分文档 | `templates/详细设计-总分分文档-模板.md` | `--mode=sub` |

按选定模式全文复制对应模板作为起点；产物必须替换 `{{template_version}}` 为所用模板 frontmatter 的 version。

**总分模式设计包（v3.24.0/A05）**：P1 冻结为 total 时，必须在 P2 冻结
`.devflow/<feature>/design-package.json`（`docs[].path/mode/acceptance_ids`）——分文档按自己的
验收子集对账，子集**并集必须与 P0 冻结分母全等**，缺文档或并集不全等即 P2 Gate FAIL；
跨模块引用以语义锚点解析。

### P2.2 设计覆盖率检查

- Acceptance-ID trace rows, all `COMPLETE`.
- Seven-column data dictionaries.
- Six-column request and response contracts.
- Numbered rules and `WHEN` pseudo-code for core write paths.
- Page/background-task to API, permission, rule, and test mappings.
- Frontend page specs backed by `pages[]`: route/component/page_type (required), table-column specs (`table_columns`), form-control specs (`form_controls`: control, validation, candidate source), dialog/drawer mappings (`dialogs`, API anchor closed to `apis[]`), reconciled with §7.2 when provided.
- Explicit errors, idempotency, transactions, failure and fallback behavior.
- Implementation handoff: existing-implementation baseline, planned ADD/MODIFY/DELETE targets, invariants.

Chapter numbers are not authoritative; semantic anchors are the machine contract:
`data-model` / `api-contracts` / `business-rules`（详设正文）/ `acceptance-traceability`（`<feature>-需求追溯.md`）/ `implementation-handoff`（`<feature>-实现交接.md`）
（详见 `phases/02-详细设计.md`）。

### P2 Gate Check

```bash
bash "$SKILL_ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/<feature>-详细设计.md docs/需求/<feature>-验收点.md --mode=<P1 冻结 mode: monolith|total|sub>
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category config
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category api
```

**P2 Design Coverage Gate (must all pass):**

| # | Check | Pass Condition |
|---|-------|----------------|
| 1 | 验收点 COMPLETE 覆盖率 | `COMPLETE` rows / total acceptance IDs = 100% |
| 2 | 五列数据模型 | 存在字段名/类型/约束/默认值/口径说明（v3.9.8 删'老系统来源/迁移转换规则'，迁移映射在 docs/数据映射/） |
| 3 | 六列请求字段 | 存在字段/类型/必填/校验规则/数据来源/脱敏 |
| 4 | 六列响应字段 | 存在字段/类型/恒出性/取值规则/数据来源/脱敏 |
| 5 | 准伪代码 | 存在 `WHEN` 关键字（核心写路径） |
| 6 | 规则编号 | 存在 `R[0-9]+.` 格式编号 |
| 7 | 无占位符 | `grep -cE 'TODO\|TBD\|待补充\|REPLACE_WITH'` = 0 |
| 8 | 设计覆盖率公式 | 存在 `设计覆盖率.*100%` 文本 |
| 9 | 文档结构来源 P1 | 设计决策记录含详设文档结构决策（`design_doc_structure_mode=` 机检行）；详设不内嵌总分/单体决策矩阵，s2 `--mode` 与 P1 冻结 mode 一致 |
| 10 | 实现交接 | `<feature>-实现交接.md` 存在 `anchor: implementation-handoff`（基线/变更/不变量） |

**P2 Pseudo-code Keywords (at least one present in core write paths):**

| Keyword | Meaning |
|---------|---------|
| `WHEN` | 触发条件或入口 |
| `IF` | 条件分支 |
| `LOOP` | 循环处理 |
| `TX` | 事务边界 |

### P2 Architecture Pitfalls Check

```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category config
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category api
```

- `critical = 0` 方可进入 P3
- blocking issues 必须修复后重跑

## P2（迁移场景）— data scenario and migration design

Load `phases/03-规范实现.md`（迁移场景 A/B/C 时）。

| 场景 | 判定标准 | 数据字典 | 新老映射 | 历史数据迁移 |
|------|----------|----------|----------|--------------|
| **A 全新模块** | 无老系统对应物 | 必做 | **不做** | **不做** |
| **B 替换/迁移** | 有老系统对应物且需继承历史数据 | 必做 | 必做（§5.1-5.2） | 必做 |
| **C 多老系统适配** | 同类数据来自 ≥2 个老系统 | 必做 | 必做，且迁移能力独立成模块 | 走独立迁移模块 |

**判型在 P0 功能矩阵中完成（每个模块标注 A/B/C）**

### 迁移映射 Gate Check（P2 内）

```bash
bash "$SKILL_ROOT/scripts/s3_migration_mapping_gate.sh" <A|B|C> docs/数据映射/<feature>-映射.md <source-count>
```

**迁移 Gate by Scenario:**

| 场景 | 映射表头 | 映射行数 | 8列完整 | 覆盖率 | 来源系统数 |
|------|----------|----------|---------|--------|-----------|
| A | N/A | N/A | N/A | N/A | N/A |
| B | 必须 | 必须 > 0 | 必须 100% | 100% | ≥ 1 |
| C | 必须 | 必须 > 0 | 必须 100% | 100% | ≥ 2 + 适配器 |

### Mapping Coverage Formula

```
映射覆盖率 = 有转换规则的映射行 / 总映射行 = 100%
```

每个字段必须填转换规则，不得留空。

## P3-P10 — 实施、测试门控与上线

After completing P2 (含迁移设计), continue to:

| Phase | Skill File | Gate Script |
|-------|-----------|-------------|
| P3 规范实现 | `phases/03-规范实现.md` | `scripts/p3_completion_gate.sh` |
| P4 PRD 验证 | `phases/04-PRD验证.md` | `scripts/p4_validation_gate.sh` |
| P4b PRD-vs-Code | `phases/04b-PRD-实现对比.md` | `scripts/p4_prd_vs_code.sh` |
| P5 测试用例 | `phases/05-测试用例.md` | `scripts/p5_test_cases_gate.sh`（主）+ `scripts/s5_migration_gate.sh`(B/C) |
| P6 首轮准确性+凭证 | `phases/06a-单元测试.md`~`06f` | `scripts/s6_first_pass_accuracy.sh`, `scripts/p6_credential_gate.sh` |
| 图谱健康度（可选） | `phases/05-测试用例.md` | `maintenance/s8_graph_health_gate.sh` |

## Exit Gate

All phase gate scripts must return exit code 0. Then run:

```
/audit-completeness P0 <feature>
/audit-completeness P1 <feature>
/audit-completeness P2 <feature>
```

If the user requested design only, stop here and report:

- Design coverage evidence (COMPLETE / total = 100%).
- Migration scenario and mapping boundary.
- Current implementation remains unverified.
- No code/runtime/deployment claim.

## Complete Gate Summary

| Phase | Script | Blocking If |
|-------|--------|-------------|
| P0 | `s0_acceptance_gate.sh` | FAIL > 0, P0 ambiguous, placeholder exists |
| P1 | `s1_fact_sources_gate.sh` | any of 7 fact sources missing or empty |
| P2 | `s2_design_coverage_gate.sh` + `check-arch-pitfalls.sh` | any acceptance point not COMPLETE, critical > 0 |
| P2（迁移） | `s3_migration_mapping_gate.sh` | coverage < 100% for B/C, source count mismatch |
| P3-P10 | respective gate scripts | see each phase file |

---

## 状态机口径（单命令模式 · P1-6）

- 本命令运行于**单命令模式**：豁免状态机——不调用 `devflow-state.sh complete`，不推进阶段状态、不产出阶段收据链。
- 执行时必须在输出首部显式携带降级声明：`MODE=single-command STATE_MACHINE=exempt（阶段状态不推进；完整门禁链走 /devflow 编排）`。
- 需要完整门禁、收据链、checkpoint 恢复与"不可跳过阶段"约束时，改走 `/devflow` 编排路径（commands/devflow.md）。
