---
name: prd-vs-code
version: "3.29.3"
description: Use when a user asks to compare frozen PRD acceptance points with implementation evidence or run the P4b completeness Gate.
paths: ["docs/PRD/**", "docs/详细设计/**", "docs/测试/**", "backend/**", "frontend/**"]
allowed-tools: [read, write, exec, glob, grep, task]
---

# /prd-vs-code — exact acceptance evidence Gate

## Input contract

```
/prd-vs-code <feature> --prd <path> --design <path> --service <service>
```

Required artifacts:

- Frozen acceptance criteria with unique `M-xx-Fyy-Azz` IDs.
- Design with the same IDs marked `COMPLETE`.
- `docs/测试/<feature>-implementation-evidence.tsv`:

```text
acceptance_id<TAB>code_paths<TAB>test_paths<TAB>status
M-01-F01-A01<TAB>backend/.../Foo.java<TAB>backend/.../FooTest.java<TAB>PASS
```

Comma-separate multiple paths. Every path must exist. Every frozen ID appears exactly once; unknown IDs, missing IDs, missing paths, TODO/FIXME, permissions, design Gate, or four-dialect differences are P0.

## Execute

```bash
bash "$SKILL_ROOT/scripts/p4_prd_vs_code.sh" <feature> --prd <PRD-path> --design docs/详细设计/<feature>-详细设计.md --criteria docs/需求/<feature>-验收点.md --evidence docs/测试/<feature>-implementation-evidence.tsv --service <service>
```

Exit 0 is required before P5. The report records full stdout and command exit code in `docs/测试/<feature>-PRD实现对比.md`.

Counts, keyword samples, unrelated repository pages/tests, or empty design sets never prove coverage.

---

## 状态机口径（单命令模式 · P1-6）

- 本命令运行于**单命令模式**：豁免状态机——不调用 `devflow-state.sh complete`，不推进阶段状态、不产出阶段收据链。
- 执行时必须在输出首部显式携带降级声明：`MODE=single-command STATE_MACHINE=exempt（阶段状态不推进；完整门禁链走 /devflow 编排）`。
- 需要完整门禁、收据链、checkpoint 恢复与"不可跳过阶段"约束时，改走 `/devflow` 编排路径（commands/devflow.md）。
