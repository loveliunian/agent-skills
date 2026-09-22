---
name: review
version: "3.29.0"
description: >-
  Use when reviewing code changes for correctness, security, and style, mentions
  "/review", "code review", "代码审查", "review this", "cr", or "check the code".
  Must run in independent session (code-reviewer subagent). P0 issues must be zero before entering P4.
paths:
  - "backend/**/*.java"
  - "frontend/src/**"
disable-model-invocation: false
allowed-tools:
  - read
  - write
  - exec
  - grep
  - glob
  - task
---

# /review - Code Review（P3b）

> **核心约束**：必须由 `code-reviewer` 角色在**独立 session** 中执行，**禁止开发 Agent 自评**。

## 使用方式

```
/review <feature>
/review <feature> --scope=<path>
```

## 示例

```
/review m-03-basic-library
/review payment-system --scope=backend/payment-service
```

## 命名约定

输出：`docs/评审/<feature>-代码审查报告.md`

## 执行步骤

### 1. 强制独立性

```bash
# 检查：当前 session 不是开发 session
# 报告必须记录新的 session/subagent/thread ID。
# git author不能证明会话独立；如果无法创建独立会话，返回BLOCKED。
```

### 2. 加载详设与代码

```bash
test -f docs/详细设计/<feature>-详细设计.md || echo "详设缺失"
test -f docs/复盘/<feature>-audit-P3.md || echo "P3 自检未完成"
```

### 3. 五轴 Review

| 轴 | 检查点 | 严重程度 |
|----|--------|----------|
| **正确性** | 业务逻辑错误、边界条件、空指针、并发安全 | P0 必修复 |
| **安全性** | SQL注入、权限缺失、敏感信息泄露 | P0 必修复 |
| **可读性** | 命名、注释、复杂度 | P1 建议修复 |
| **性能** | N+1、缺索引、慢查询 | P1 建议修复 |
| **可测试性** | 单测覆盖、Mock 使用 | P2 可选 |

### 4. 详设交叉对照

按语义锚点对照 `docs/详细设计/<feature>-详细设计.md`：

- 原子验收ID ↔ 代码/测试证据
- 数据模型 ↔ Entity/DDL/四方言
- 接口字段契约 ↔ Controller/DTO/OpenAPI
- 规则与准伪代码 ↔ Service、事务、幂等、异常与降级
- 页面/后台任务 ↔ 前端/调度/权限/菜单Seed

### 5. 项目专项检查

通用 Review 不内置某个项目或模块的类名、端口和业务字段。项目专项检查必须通过
`docs/评审/<feature>-设计领域清单.md` 或项目提供的显式 hook 注入，并记录文件/行号证据。

### 6. 输出报告

写入 `docs/评审/<feature>-代码审查报告.md`：

```markdown
# <feature> Code Review 报告

## 基本信息
- Reviewer：code-reviewer（独立 session ID）
- DEVELOPER_ID：<developer-id>
- REVIEWER_ID：<reviewer-id>
- REVIEW_SESSION_ID：<independent-session-id>
- Date：YYYY-MM-DD
- Scope：<改动范围>

## 变更摘要
<变更概述>

## 问题列表

### 🔴 P0: 严重问题（必须修复才能进 P4）
#### [#1] <标题>
- `FINDING|P0|P0-1|STATUS=OPEN|<summary>`
- 文件：<path:line>
- 问题：<描述>
- 建议：<修复方案>
- 验证：<grep 命令输出>

### 🟡 P1: 高优先级（建议修复）
...

### 🔵 P2: 中优先级（可选）
...

## 统计数据
- 总问题数：N
- P0：X（OPEN 必须 0；历史 P0 必须逐条 `STATUS=CLOSED`）
- P1：Y（**必须显式列 owner + ETA**）
- P2：Z

## 结论
- [ ] PASS — 不存在 OPEN P0，可以进 P4
- [ ] FAIL — 存在 OPEN 或格式非法 P0，必须修复后重审
```

Gate（强制）

| 项 | 强制条件 |
|----|----------|
| 报告路径 | `docs/评审/<feature>-代码审查报告.md` 实际写入 |
| P0 项 | **OPEN = 0；历史项必须逐条 `STATUS=CLOSED` 才能进 P4** |
| P1/P2 项 | 显式列 owner + ETA（不阻塞推进但不充耳不闻） |
| 独立性 | 必须独立 session（不得与开发同 session） |

## 输出

- `docs/评审/<feature>-代码审查报告.md`

## 自检命令

```bash
# P3b Gate: 代码审查（v3.9.4 · 集中 Gate）
bash "$SKILL_ROOT/scripts/p3b_code_review_gate.sh" <feature> [service]

# 等价自检：只允许不存在 OPEN P0；历史 P0 必须逐条标记 STATUS=CLOSED
bash "$SKILL_ROOT/scripts/p3b_code_review_gate.sh" <feature> [service]
```

## 角色约束

- ❌ **禁止同 session 自评**（写完代码的 session 立即 Review = 自评）
- ✅ **必须独立 session** 切换 `code-reviewer` 角色
- ✅ **P0 项必须含 grep 输出**作为证据
- ❌ **禁止"全部通过"无具体证据**

## 与其他命令关系

- P3 完成度自检（`/audit-completeness P3`）必须 PASS 后才能跑 `/review`
- `/review` 不得有 OPEN/格式非法 P0，历史 P0 必须逐条 CLOSED，才能进 `/test` (P4 PRD 验证)
- 与 `/security` `/performance` **并行**执行（不阻塞彼此）

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
bash "$SKILL_ROOT/scripts/p3b_code_review_gate.sh" <feature>
# 期望：exit 0 = 代码审查 Gate 通过
```

---

## 状态机口径（单命令模式 · P1-6）

- 本命令运行于**单命令模式**：豁免状态机——不调用 `devflow-state.sh complete`，不推进阶段状态、不产出阶段收据链。
- 执行时必须在输出首部显式携带降级声明：`MODE=single-command STATE_MACHINE=exempt（阶段状态不推进；完整门禁链走 /devflow 编排）`。
- 需要完整门禁、收据链、checkpoint 恢复与"不可跳过阶段"约束时，改走 `/devflow` 编排路径（commands/devflow.md）。
