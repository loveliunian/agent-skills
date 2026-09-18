---
name: prd-vs-code-phase
version: "3.27.4"
description: Use when running the P4b exact acceptance evidence Gate.
---

# P4b PRD vs Code

## Purpose

Prove that every frozen acceptance ID has concrete code and test evidence. Counts, keyword samples, and unrelated repository artifacts are not coverage.

> **三层验证法（v3.20.0，验收证据的深度口径）**：每个验收点的证据按三层组织，缺一层即证据不完整——
> ① **路径**：实现代码位置（文件#方法，行号）——证明代码路径存在；
> ② **条件**：把该点的边界值/配置值代入判断逻辑——证明条件在该点会放行（不是只被别处复用的通用路径）；
> ③ **落点**：测试断言或运行证据——证明最终行为真实生效，而非仅"代码看起来会生效"。
> 三层与 implementation-evidence TSV 行一一对应；P3b 评审复用时按同一口径抽查。

## Required artifacts

- PRD path supplied by the user.
- Frozen acceptance criteria from P0.
- COMPLETE design from P2.
- Implementation evidence TSV, one row per acceptance ID.
- Feature service scope.

## Gate

```bash
bash "$SKILL_ROOT/scripts/p4_prd_vs_code.sh" <feature> --prd <PRD-path> --design docs/详细设计/<feature>-详细设计.md --criteria docs/需求/<feature>-验收点.md --evidence docs/测试/<feature>-implementation-evidence.tsv --service <service>
```

Exit 0 is required before P5. Any missing ID/path, non-PASS evidence, permission gap, TODO/FIXME, design Gate failure, or four-dialect table-set difference is P0.

See `commands/prd-vs-code.md` for the evidence format.
