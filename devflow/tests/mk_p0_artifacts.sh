#!/usr/bin/env bash
# mk_p0_artifacts.sh — s0 Gate 全部强制产物一次性生成
# 用法: bash tests/mk_p0_artifacts.sh <feature> <workspace>
set -u
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
FEATURE="${1:?feature}"
WS="${2:?workspace}"
REQ_DIR="$WS/docs/需求"
DEV_DIR="$WS/.devflow/$FEATURE"
mkdir -p "$REQ_DIR" "$DEV_DIR" "$WS/docs/PRD"

# 验收点.md
cat > "$REQ_DIR/$FEATURE-验收点.md" <<EOF
# $FEATURE 验收点

## 基本信息

| 项 | 内容 |
|---|---|
| 功能名称 | $FEATURE |
| 模块编码 | M-01 |
| 拆分日期 | 2026-01-01 |
| 冻结状态 | FROZEN |

分母已冻结：验收点总计 1 个

## 验收点清单

| 验收点ID | 验收点描述 | 验证方式 | PRD原文锚点 | 状态 |
|----------|------------|----------|-------------|------|
| M-01-F01-A01 | 查询${FEATURE}列表 | API | docs/PRD/${FEATURE}.md#L1 | FROZEN |
EOF

# 需求澄清.md（H2 与模板对齐：基本信息/模糊点清单/澄清结论汇总/遗留项/签字确认）
cat > "$REQ_DIR/$FEATURE-需求澄清.md" <<EOF
# $FEATURE 需求澄清

## 基本信息

| 项 | 内容 |
|---|---|
| 功能名称 | $FEATURE |
| 日期 | 2026-01-01 |
| 参与者 | fixture |

## 模糊点清单

| # | 问题 | 回答 | 确认人 |
|---|------|------|--------|
| 1 | fixture | fixture | fixture |

## 澄清结论汇总

fixture 澄清完成

## 遗留项（需后续跟进）

无

## 签字确认

| 角色 | 姓名 | 日期 |
|------|------|------|
| PM | fixture | 2026-01-01 |

权限矩阵=not-applicable（fixture 纯服务端，无权限码）
EOF

# 技术约束（>5 行才能过 s1）
cat > "$REQ_DIR/$FEATURE-技术约束.md" <<EOF
<!-- DEVFLOW:CONSTRAINTS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->

# $FEATURE 技术约束

本 feature 无技术硬约束。
constraint_set=NONE 已确认。
由 fixture 生成。
EOF

# PRD 文件
printf '# %s PRD\nfixture PRD\n' "$FEATURE" > "$WS/docs/PRD/$FEATURE.md"

# clarification.json
"${DEVFLOW_PY[@]}" - "$FEATURE" "$DEV_DIR" <<'PYEOF'
import json, sys
feature, dev_dir = sys.argv[1], sys.argv[2]
d = {
    "feature": feature, "generated_at": "2026-01-01T00:00:00Z",
    "template": {"id": "需求澄清-模板", "version": "3.28.2"},
    "feature_name": feature, "prd_path": "docs/需求/" + feature + "-需求澄清.md",
    "date": "2026-01-01", "participants": ["fixture"],
    "ambiguities": [], "conclusion": "fixture 澄清完成",
    "entities": [{"id": "E1", "name": feature, "description": "fixture 实体",
                   "key_fields": ["id"], "states": [], "acceptance_refs": ["M-01-F01-A01"]}],
    "operations": [{"id": "O1", "name": "查询", "description": "fixture 操作",
                    "actor": "用户", "inputs": ["page"], "outputs": ["data"],
                    "preconditions": [], "postconditions": [],
                    "acceptance_refs": ["M-01-F01-A01"]}],
    "constraints": [], "risks": [], "assumptions": [], "out_of_scope": [],
    "clarifications": [],
    "acceptance_points": [{"id": "M-01-F01-A01", "description": "查询" + feature,
                           "priority": "P0", "testable": "API"}],
    "clarified_at": "2026-01-01", "deep_probes": [], "followups": [],
    "signoffs": [{"role": "PM", "name": "fixture", "date": "2026-01-01"}],
    "zero_results": []
}
json.dump(d, open(dev_dir + "/clarification.json", "w"), ensure_ascii=False)
PYEOF

# acceptance.json（signoffs ≥1 + prd_anchor 指向真实文件）
"${DEVFLOW_PY[@]}" - "$FEATURE" "$DEV_DIR" <<'PYEOF'
import json, sys
feature, dev_dir = sys.argv[1], sys.argv[2]
d = {
    "feature": feature, "generated_at": "2026-01-01T00:00:00Z",
    "template": {"id": "验收点-模板", "version": "1"},
    "feature_name": feature, "module": "01",
    "prd_doc": "docs/需求/" + feature + "-验收点.md", "date": "2026-01-01",
    "splitter": "fixture",
    "points": [{"id": "M-01-F01-A01", "description": "查询" + feature,
                "verify_method": "API",
                "prd_anchor": "docs/PRD/" + feature + ".md#L1",
                "status": "FROZEN"}],
    "reviews": [{"round": 1, "reviewer": "fixture", "date": "2026-01-01",
                 "verdict": "通过", "leftovers": "无"}],
    "signoffs": [{"role": "PM", "name": "fixture", "date": "2026-01-01"}],
    "zero_results": []
}
json.dump(d, open(dev_dir + "/acceptance.json", "w"), ensure_ascii=False)
PYEOF

# constraints.json
printf '{"feature":"%s","constraints":[],"signoffs":[],"zero_results":[]}' "$FEATURE" > "$DEV_DIR/constraints.json"

bash "$(dirname "${BASH_SOURCE[0]}")/mk_design_conventions.sh" "$FEATURE" "$WS" >/dev/null 2>&1

# 技术约束冻结进 state（s1 要求）
SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
WORKSPACE="$WS" bash "$SCRIPT_DIR_REAL/devflow-state.sh" constraints-freeze "$FEATURE" >/dev/null 2>&1 || true

# 设计决策文档也要 >5 行
mkdir -p "$WS/docs/detailed-design"
cat > "$WS/docs/detailed-design/$FEATURE-设计决策.md" <<EOF
# $FEATURE 设计决策

## 决策矩阵

| 维度 | 候选A | 候选B | 选定 |
|------|-------|-------|------|
| 数据库 | PostgreSQL | MySQL | PostgreSQL |
| 框架 | Spring Boot 3.x | Quarkus | Spring Boot 3.x |

## 决策结论

用户确认: YES

## 详设文档结构决策

design_doc_structure_mode=monolith

## 约束绑定

<!-- DEVFLOW:CONSTRAINT-BINDINGS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->
EOF

echo "[mk_p0_artifacts] done for $FEATURE in $WS"
