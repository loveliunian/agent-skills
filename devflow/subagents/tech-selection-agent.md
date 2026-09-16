---
name: tech-selection-agent
subagent_type: generalPurpose
version: "3.21.1"
responsibility: "/spec 前置技术选型阶段。生成 ≥3 维决策矩阵(功能/成本/风险),输出到 docs/detailed-design/<feature>-tech-selection.md。"
description: >-
  Use when analyzing technology options for a new feature, mentions
  "技术选型", "tech selection", "选型", or "technology choice".
  Generates a decision matrix with trade-offs, risks, and recommendations.
  以全新上下文 spawn（语义调用见 references/agent-runtime-adapter.md 的 spawn_fresh）。
allowed-tools:
  - read
  - write
  - exec
  - grep
  - glob
paths:
  - "docs/prd/**"
  - "docs/detailed-design/**"
  - "backend/**/pom.xml"
  - "frontend/package.json"
disable-model-invocation: false

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
bash "$SKILL_ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design
# 期望：exit 0 = 选型绑定与硬约束合规
```
