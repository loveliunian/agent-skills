---
name: prd-vs-code
version: "3.21.1"
description: Use when a user asks to compare frozen PRD acceptance points with implementation evidence or run the P4b completeness Gate.
paths: ["docs/prd/**", "docs/detailed-design/**", "docs/test/**", "backend/**", "frontend/**"]
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
- `docs/test/<feature>-implementation-evidence.tsv`:

```text
acceptance_id<TAB>code_paths<TAB>test_paths<TAB>status
M-01-F01-A01<TAB>backend/.../Foo.java<TAB>backend/.../FooTest.java<TAB>PASS
```

Comma-separate multiple paths. Every path must exist. Every frozen ID appears exactly once; unknown IDs, missing IDs, missing paths, TODO/FIXME, permissions, design Gate, or four-dialect differences are P0.

## Execute

```bash
bash "$SKILL_ROOT/scripts/p4_prd_vs_code.sh" <feature> --prd <PRD-path> --design docs/detailed-design/<feature>-design.md --criteria docs/requirements/<feature>-acceptance-criteria.md --evidence docs/test/<feature>-implementation-evidence.tsv --service <service>
```

Exit 0 is required before P5. The report records full stdout and command exit code in `docs/test/<feature>-prd-vs-code-report.md`.

Counts, keyword samples, unrelated repository pages/tests, or empty design sets never prove coverage.
