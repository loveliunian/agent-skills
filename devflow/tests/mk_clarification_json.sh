#!/usr/bin/env bash
# mk_clarification_json.sh — s0 强制结构化正本 clarification.json
# 用法: bash tests/mk_clarification_json.sh <feature> <workspace> [prd_path]
set -u
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
FEATURE="${1:?feature}"
WS="${2:?workspace}"
PRD_PATH="${3:-docs/需求/$FEATURE-需求澄清.md}"
DEV_DIR="$WS/.devflow/$FEATURE"
mkdir -p "$DEV_DIR"

"${DEVFLOW_PY[@]}" - "$FEATURE" "$PRD_PATH" "$DEV_DIR" <<'PYEOF'
import json, sys
feature, prd_path, dev_dir = sys.argv[1], sys.argv[2], sys.argv[3]
d = {
    "feature": feature, "generated_at": "2026-01-01T00:00:00Z",
    "template": {"id": "需求澄清-模板", "version": "3.28.2"},
    "feature_name": feature, "prd_path": prd_path,
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

echo "[mk_clarification_json] done for $FEATURE in $WS"
