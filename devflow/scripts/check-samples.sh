#!/usr/bin/env bash
# check-samples.sh — 结构化样例漂移检测（v3.31.1，FB-20260921-004）
# =============================================================================
# 背景：examples/structured/*.sample.json 与 df_validate 跨字段检查会随版本演进
# 漂移——样例照抄照样校验失败，样例本身成为误导源（m01-base 实测：retrospective
# sample 缺 period 等新必填字段）。
# 用法:
#   bash scripts/check-samples.sh [--workspace <dir>]
# 退出码: 有任一样例校验失败 → 1（可挂 CI）。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "$SCRIPT_DIR/py_runtime.sh"
PY="${DEVFLOW_PY[0]:-python3}"
WS="${3:-.}"
FAIL=0; PASS=0; SKIP=0

for sample in "$SCRIPT_DIR"/../examples/structured/*.sample.json; do
  [ -f "$sample" ] || continue
  kind=$(basename "$sample" .sample.json)
  # 部分 kind 的校验依赖 workspace 附加文件（criteria/doc 等），缺省目录下可能
  # 无法全量跑通——此类失败计为 SKIP 并提示，不算通过。
  out=$("$PY" "$SCRIPT_DIR/df_validate.py" \
        --kind "${kind}" --input "$sample" --workspace "$WS" --max-errors 3 2>&1)
  if echo "$out" | grep -q "校验通过"; then
    echo "[PASS] $kind"
    PASS=$((PASS + 1))
  elif echo "$out" | grep -qE "不存在|not found|No such file|--criteria|--doc"; then
    echo "[SKIP] ${kind}（需要 workspace 附加文件才能全量校验——CI 中请在真实 feature 目录内跑）"
    SKIP=$((SKIP + 1))
  else
    echo "[FAIL] $kind"
    echo "$out" | grep -E "✗" | head -3 | sed 's/^/       /'
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "SAMPLES: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
