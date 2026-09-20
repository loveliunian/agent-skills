# 技术约束契约 - 演示支付

> 冻结日期：2026-09-16　确认人：用户　PRD：docs/PRD/demo-pay.md


<!-- 审计指纹: constraints.json sha256=bdd478d08265e0869233a9838203037d0262dbc605232584649e1413ef138ea5（由 df_render 自动生成，人工勿改） -->

> 本文件是 P0 的冻结事实源。MUST_USE、MUST_NOT_USE 和固定版本属于硬约束，
> 不能被 P1 的加权评分或 Agent 自主决策覆盖。Gate 只解析下方机器契约块。

## 机器契约（唯一机读事实源；字段格式勿改）

<!-- DEVFLOW:CONSTRAINTS
constraint_id=TC-TECH-001
type=MUST_USE
subject=workflow-engine
required_product=camunda
required_version=7.24.0
status=FROZEN
confirmed=true
DEVFLOW:END -->

## 约束清单（人读展示，与机器契约一致）

| constraint_id | 类型 | 技术/组件 | 必须值/禁止值 | 来源锚点 | 状态 |
|---|---|---|---|---|---|
| TC-TECH-001 | MUST_USE | workflow-engine | camunda 7.24.0 | `docs/PRD/demo-pay.md#L5` | FROZEN |

## 变更规则

- 任何选型与 MUST_USE 或 MUST_NOT_USE 冲突时，P1 立即 BLOCKED。
- 只有用户明确批准、更新 PRD/本契约并重新冻结（status=FROZEN + confirmed=true）后，才能恢复。
- P2 详设必须逐条引用 constraint_id；P3 依赖/config 与 P4b 代码对账使用同一组 constraint_id。
