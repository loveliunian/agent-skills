---
name: plan
version: "3.29.2"
description: >-
  Use when decomposing a detailed design into actionable tasks, mentions
  "/plan", "任务分解", "任务清单", "分解任务", "break down", "task list", or "work items".
  Input: frozen acceptance criteria and detailed design. Output: execution-contract tasks (target + action + invariants + verify) mapped to acceptance IDs and semantic anchors.
paths:
  - "docs/详细设计/**"
  - "任务/**"
  - "tasks/**"
disable-model-invocation: false
allowed-tools:
  - read
  - write
  - exec
  - glob
  - task
---

# /plan - 任务分解规划（执行契约）

> **前置依赖**：`/spec` 已完成 → `docs/详细设计/<feature>-详细设计.md` 已冻结。
> **职责边界**：详设负责 WHAT + CONTRACT；实现交接文档（`<feature>-实现交接.md`）是施工图正本（baseline/变更/不变量）；`/plan` 负责 **WHERE + HOW TO VERIFY**
> （把每个行为翻译成 exact target、修改类型、不变量、验证方式）；`/build` 负责最小补丁实现与证据。
> **核心原则**：每个任务必须映射至少一个冻结验收 ID 和语义锚点；每个 Target 是一条可独立验证的修改。

## 使用方式

```
/plan <feature>
/plan
```

## 示例

```
/plan m-03-basic-library
/plan payment-system
```

## 执行步骤

### 1. 读取详设与附属文档

```bash
test -f docs/详细设计/<feature>-详细设计.md || { echo "BLOCKED: 详设缺失"; exit 1; }
test -f docs/详细设计/<feature>-实现交接.md || { echo "BLOCKED: 实现交接文档缺失（施工图正本）"; exit 1; }
test -f docs/详细设计/<feature>-需求追溯.md || { echo "BLOCKED: 需求追溯文档缺失"; exit 1; }
test -f docs/需求/<feature>-验收点.md || { echo "BLOCKED: 验收基线缺失"; exit 1; }
bash "$SKILL_ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/<feature>-详细设计.md docs/需求/<feature>-验收点.md
# v3.24.0(A12)：设计完成 = P2 + P2a——/plan 与 /build 消费同一份设计批准收据，
# 不接受"P2 过了但未评审"的分歧口径（design-only 同样须过 P2a）。
test -f ".devflow/<feature>/gates/P2a/receipt.txt" && grep -q '^EXIT_CODE=0$' ".devflow/<feature>/gates/P2a/receipt.txt" \
  || { echo "BLOCKED: P2a 设计评审未通过——先运行 p2a_design_review_gate.sh <feature>"; exit 1; }
```

### 2. 从实现交接文档生成执行契约

- 以 `docs/详细设计/<feature>-实现交接.md`（`<!-- anchor: implementation-handoff -->`）为施工图正本：现有实现基线、预计代码变更、不变量（v3.27.15 起从详设移出）；
  同时按原子验收 ID 聚合共同变化的表、接口、页面、权限与测试。
- 实现交接文档缺失或 Target 与实际代码不符：`BLOCKED`，回 P2 补齐后重跑（不得凭猜测补 Target）。
- 设计锚点一律用语义锚点引用（`anchor: data-model` / `api-contracts` / `business-rules` /
  `acceptance-traceability` / `implementation-handoff`），章节号仅作展示。
- 每个验收 ID 必须被至少一个任务消费。

### 3. 垂直切片定义

一个垂直切片 = **一个可独立验证的行为闭环**（不是"CRUD 五件套"）。切片按需包含：

| 组成 | 是否必需 | 说明 |
|------|----------|------|
| 测试 | 凡存在可执行验证手段则必需 | 没有验证方式的切片不允许开工 |
| DB / 迁移 | 可选 | 涉及持久化时 |
| 后端 / API | 可选 | 涉及服务端行为时 |
| 前端 / 页面 | 可选 | 涉及客户端时 |
| 任务 / 消息 / 配置 | 可选 | 定时任务、消息消费、批量、纯配置等场景 |

bugfix、缓存、定时任务、纯算法、纯 UI、配置变更等都不需要凑齐 CRUD 五件套；禁止按层级切分
（"先写所有 Service 再写 Controller"），那是瀑布模式。

### 3.5 结构化产物层（v3.27.3）

任务矩阵先落结构化 JSON 正本，再由管线校验+渲染为 Markdown（失败关闭）：

1. 按 `schemas/execution-plan.schema.json` 填 `.devflow/<feature>/execution-plan.json`：
   `tasks[]`（task_id/acceptance_ids/design_refs/target/action/invariants/verify/depends_on）、
   `slices[]`（切片分组）、`report_path`；
2. 渲染：`python3 "$SKILL_ROOT/scripts/df_pipeline.py" execution-plan \
   --input .devflow/<feature>/execution-plan.json --out 任务/执行契约.md`（校验失败不渲染）；
3. 渲染产物 `任务/执行契约.md` 是人类视图；JSON 正本供 /build 与审计程序消费。

### 4. 输出任务清单

写入 `任务/执行契约.md` 与 `任务/待办.md`（v3.24.0 起默认中文名；历史 `tasks/plan.md`、`tasks/todo.md`
继续被 `/build` 与自检命令识别，无需迁移）：

```markdown
# <feature> 执行契约

## 任务矩阵（Task = 切片；每行 = 一个 exact target）
| Task | Acceptance | DesignRef | Target | Action | Invariants | Verify | Risk | 依赖 |
|------|-----------|-----------|--------|--------|------------|--------|------|------|
| T-01 | M-01-F01-A01 | anchor: api-contracts §3.2.1（分文档 §5.3.1） | `XxxController#list` | MODIFY | 响应结构不得变化 | `XxxControllerTest` | LOW | - |
| T-01 | M-01-F01-A01 | anchor: business-rules R1 | `XxxService#page` | MODIFY | 未指定条件时行为不变 | `XxxServiceTest` | MEDIUM | - |
| T-01 | M-01-F01-A01 | anchor: data-model §2.2 {表名}（分文档 §2.3） | `XxxMapper.xml#selectPage` | MODIFY | 不得引入 N+1 | repository test | MEDIUM | - |
| T-02 | M-01-F01-A02 | anchor: implementation-handoff §2（`<feature>-实现交接.md`） | `XxxServiceTest` | ADD | - | 目标测试命令 | LOW | T-01 |

## 切片要求
- 每个切片是一个可独立验证的行为闭环；测试随切片同时提交
- 禁止"先全部后端、再全部前端"的水平批次

## P3 完成度自检绑定
- 全部 T-* 任务完成后才能运行 `/audit-completeness P3 <feature>`
```

## Gate

| 项 | 强制条件 |
|----|----------|
| 验收覆盖 | 冻结验收 ID 集合与任务引用集合完全相等 |
| 锚点引用 | 每个 Task 的 DesignRef 至少一个语义锚点 |
| Target 明确 | 每行 Target 为文件/符号级定位（能直接开工，不需要再研究） |
| Action 合法 | 每行 Action ∈ ADD / MODIFY / DELETE |
| 不变量 | 每行 MODIFY 的 Invariants 非空 |
| 验证方式 | 每行 Verify 非空（测试命令或测试符号） |
| 依赖闭环 | 不能有循环依赖 |

## 输出

- `任务/执行契约.md`（执行契约矩阵 + 切片；兼容历史 `tasks/plan.md`）
- `任务/待办.md`（按依赖排序的执行清单；兼容历史 `tasks/todo.md`）

## 角色约束

- 主 Agent 执行
- 可调用 `tech-selection-agent` 协助确认依赖与版本约束

## 自检命令

```bash
# /plan 自检：详设交叉引用 + 无循环依赖 + Action 合法性
test -f docs/详细设计/<feature>-详细设计.md && echo "详设 OK"

# 任务产物中英双语解析（中文默认 任务/执行契约.md，历史 tasks/plan.md 回退）
PLAN_F="任务/执行契约.md"; [ -f "$PLAN_F" ] || PLAN_F="tasks/plan.md"

# 冻结验收ID集合必须与计划引用集合相等
FROZEN=$(grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' docs/需求/<feature>-验收点.md | sort -u)
PLANNED=$(grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$PLAN_F" | sort -u)
test "$FROZEN" = "$PLANNED"

# Action 合法性 + MODIFY 行不变量非空
grep "^| T-" "$PLAN_F" | awk -F'|' '
  { action=$6; inv=$7; gsub(/^[ \t]+|[ \t]+$/, "", action); gsub(/^[ \t]+|[ \t]+$/, "", inv);
    if (action !~ /^(ADD|MODIFY|DELETE)$/) { print "BAD ACTION: " $0; bad=1 }
    if (action=="MODIFY" && inv=="") { print "EMPTY INVARIANTS: " $0; bad=1 }
  } END { exit bad }' && echo "ACTION OK"

# 无循环依赖（依赖关系 DAG 检测，可用 make / tsort；依赖列=第 10 列）
grep "^| T-" "$PLAN_F" | awk -F'|' '
  {
    task=$2; deps=$10
    gsub(/^[ \t]+|[ \t]+$/, "", task)
    gsub(/^[ \t]+|[ \t]+$/, "", deps)
    if (deps=="-" || deps=="") print task
    else {
      n=split(deps,a,",")
      for(i=1;i<=n;i++){gsub(/^[ \t]+|[ \t]+$/, "", a[i]); print a[i], task}
    }
  }
' | tsort >/dev/null && echo "DAG OK"
```

## 与其他命令关系

- `/plan` 完成后才能进入 `/build`
- `/build` 必须按本执行契约施工，不允许临时添加未在 `plan.md` 中出现的 Target（如出现需先回 `/plan` 更新）
- 前置口径（v3.24.0/A12）：设计完成 = P2 内容校验 + P2a 实施可行性评审通过（同一批准收据）；P2b 按原型适用性及授权执行

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
EXPECT_DATA=1 EXPECT_API=1 bash "$SKILL_ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/<feature>-详细设计.md docs/需求/<feature>-验收点.md
# 期望：exit 0 = 设计覆盖率 100%
```
