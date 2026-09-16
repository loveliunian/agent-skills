---
name: plan
version: "3.22.0"
description: >-
  Use when decomposing a detailed design into actionable tasks, mentions
  "/plan", "任务分解", "任务清单", "分解任务", "break down", "task list", or "work items".
  Input: frozen acceptance criteria and detailed design. Output: vertical-slice tasks mapped to acceptance IDs and design anchors.
paths:
  - "docs/详细设计/**"
  - "tasks/**"
disable-model-invocation: false
allowed-tools:
  - read
  - write
  - exec
  - glob
  - task
---

# /plan - 任务分解规划

> **前置依赖**：`/spec` 已完成 → `docs/详细设计/<feature>-详细设计.md` 已冻结。
> **核心原则**：每个任务必须映射至少一个冻结验收ID和设计锚点；切片本身必须可独立验收。

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

### 1. 读取详设

```bash
test -f docs/详细设计/<feature>-详细设计.md || { echo "BLOCKED: 详设缺失"; exit 1; }
test -f docs/需求/<feature>-验收点.md || { echo "BLOCKED: 验收基线缺失"; exit 1; }
bash "$SKILL_ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/<feature>-详细设计.md docs/需求/<feature>-验收点.md
```

### 2. 解析详设章节

- 按原子验收ID聚合共同变化的表、接口、页面/任务、权限和测试
- 每个验收ID必须被至少一个任务消费
- 设计锚点使用语义标题，不依赖固定章节号

### 3. 任务分级

按 v2.0 任务复杂度分级（见 SKILL.md "Agent 类型分级"）：

| 级别 | 规模 | Agent 类型 |
|------|------|-----------|
| XS | 1 个文件 | `shell` / 直接执行 |
| S | 1-2 个文件 | 子 Agent |
| M | 3-5 个文件 | 子 Agent |
| L | 5-8 个文件 | 主 Agent |
| XL | 8+ 个文件 | **必须拆分** |

### 4. 依赖排序

按垂直切片（vertical slice）划分：
- 一个功能 = 一个后端端点 + 一个 Mapper + 一张表 + 一个前端组件 + 一个测试用例
- 不要按层级（"先写所有 Service 再写 Controller"），那是瀑布模式

### 5. 输出任务清单

写入 `tasks/plan.md` 与 `tasks/todo.md`：

```markdown
# <feature> 任务分解

## 任务矩阵（与详设交叉引用）
| 任务 ID | 验收ID | 详设引用 | 任务描述 | 级别 | 依赖 | 责任人 | ETA |
|---------|--------|----------|----------|------|------|--------|-----|
| T-01 | M-01-F01-A01 | 数据模型/接口/页面/规则锚点 | 完成一个可验收垂直切片 | M | - | slice-owner | D1 |
| T-02 | M-01-F01-A02 | 下一组语义锚点 | 下一可验收垂直切片 | M | T-01 | slice-owner | D2 |

## 切片要求
- 每个切片同时包含适用的Flyway、后端、前端/后台任务、权限、Seed和测试
- 禁止“先全部后端、再全部前端”的水平批次

## P3 完成度自检绑定
- 全部 T-* 任务完成后才能运行 `/audit-completeness P3 <feature>`
```

Gate

| 项 | 强制条件 |
|----|----------|
| 验收覆盖 | 冻结验收ID集合与任务引用集合完全相等 |
| 详设交叉引用 | 每个任务有语义锚点 |
| 级别标注 | 每个任务标 XS/S/M/L/XL |
| 依赖闭环 | 不能有循环依赖 |
| ETA 标注 | 每个任务有截止日 |

## 输出

- `tasks/plan.md`（任务矩阵 + 切片）
- `tasks/todo.md`（按优先级排序的执行清单）

## 角色约束

- 主 Agent 执行
- 可调用 `tech-selection-agent` 协助估算

## 自检命令

```bash
# /plan 自检：详设交叉引用 + 无循环依赖 + 级别标注
test -f docs/详细设计/<feature>-详细设计.md && echo "详设 OK"

# 冻结验收ID集合必须与计划引用集合相等
FROZEN=$(grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' docs/需求/<feature>-验收点.md | sort -u)
PLANNED=$(grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' tasks/plan.md | sort -u)
test "$FROZEN" = "$PLANNED"

# 无循环依赖（依赖关系 DAG 检测，可用 make / tsort）
grep "^| T-" tasks/plan.md | awk -F'|' '
  {
    task=$2; deps=$7
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
- `/build` 必须按本任务清单执行，不允许临时添加未在 `plan.md` 中出现的任务（如出现需先回 `/plan` 更新）
- 建议在 `/audit-completeness P2` PASS 后再跑 `/plan`

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
EXPECT_DATA=1 EXPECT_API=1 bash "$SKILL_ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/<feature>-详细设计.md docs/需求/<feature>-验收点.md
# 期望：exit 0 = 设计覆盖率 100%
```
