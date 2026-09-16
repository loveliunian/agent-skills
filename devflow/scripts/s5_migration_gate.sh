#!/usr/bin/env bash

# : 推导 feature，避免写入 default 目录
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# =============================================================================
# P5 迁移数据轨 Gate
# =============================================================================
# 功能：
#   1. 检查迁移证据报告存在
#   2. 验证 structure/full_reconciliation/sample/boundary/recovery 全 PASS
#   3. 验证 mapping_coverage=100
#   4. 验证 difference_count=0
#   5. 生成迁移辅助收据 (v3.14.0)
# =============================================================================
set -uo pipefail

# ---------- 依赖检查 ----------
command -v jq >/dev/null 2>&1 || { echo "[FAIL] jq is required but not installed"; exit 1; }

FEATURE="${FEATURE:-}"
if [ "$#" -ge 3 ]; then
  FEATURE="$1"
  SCENARIO="$2"
  REPORT="$3"
else
  SCENARIO="${1:-}"
  REPORT="${2:-}"
fi

# ---------- 全局计数 ----------
FAIL=0; PASS=0; WARN=0

p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

# ---------- 场景检查 ----------
echo ""
echo "=== §0 场景检查 ==="

case "$SCENARIO" in
  A)
    echo "场景 A：仅新建表，无老系统数据迁移"
    echo "P5 MIGRATION GATE: PASS (scenario A exempt; no migration receipt required)"
    exit 0
    ;;
  B|C)
    echo "场景 ${SCENARIO:-?}:需要迁移验证"
    ;;
  *)
    echo "[FAIL] scenario must be A/B/C, got: $SCENARIO"
    exit 2
    ;;
esac

# v3.14.1: 一次性推导；失败（多 state/无 state）即拒绝执行，杜绝 default 目录
EFF_FEATURE="$(devflow_feature "${FEATURE:-}")" || { echo "[FATAL] feature 推导失败，拒绝继续"; exit 2; }
[ -n "$EFF_FEATURE" ] || { echo "[FATAL] feature 为空，拒绝继续"; exit 2; }

# ---------- 报告文件检查 ----------
echo ""
echo "=== §1 迁移证据报告检查 ==="

if [ -z "$REPORT" ]; then
  p0 "migration evidence report path required for scenario B/C"
  exit 1
fi

if [ -f "$REPORT" ]; then
  pass "report exists: $REPORT"
else
  p0 "report missing: $REPORT"
  exit 1
fi

# ---------- 关键指标检查 ----------
echo ""
echo "=== §2 迁移指标检查 ==="

# 必须全 PASS 的项目
for key in structure full_reconciliation sample boundary recovery; do
  if grep -qE "^$key=PASS$" "$REPORT" 2>/dev/null; then
    pass "$key = PASS"
  else
    val=$(grep "^$key=" "$REPORT" 2>/dev/null | cut -d= -f2 || echo "MISSING")
    p0 "$key = $val (expected PASS)"
  fi
done

# mapping_coverage 必须 = 100
mapping_coverage=$(grep "^mapping_coverage=" "$REPORT" 2>/dev/null | cut -d= -f2 || echo "MISSING")
if [ "$mapping_coverage" = "100" ]; then
  pass "mapping_coverage = 100%"
elif [ "$mapping_coverage" = "MISSING" ]; then
  p0 "mapping_coverage not found in report"
else
  p0 "mapping_coverage = $mapping_coverage% (expected 100%)"
fi

# difference_count 必须 = 0
difference_count=$(grep "^difference_count=" "$REPORT" 2>/dev/null | cut -d= -f2 || echo "MISSING")
if [ "$difference_count" = "0" ]; then
  pass "difference_count = 0"
elif [ "$difference_count" = "MISSING" ]; then
  p0 "difference_count not found in report"
else
  p0 "difference_count = $difference_count (expected 0)"
fi

# ---------- 输出汇总 ----------
echo ""
echo "========================================"
echo "P5 RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"

# ---------- Gate 收据生成 (v3.8.1) ----------
if [ "$FAIL" -gt 0 ]; then
  EXIT_CODE=1
else
  EXIT_CODE=0
fi

OUTPUT_SUMMARY="PASS=$PASS FAIL=$FAIL WARN=$WARN scenario=$SCENARIO mapping_coverage=$mapping_coverage difference_count=$difference_count"

# 生成收据文件
state_dir="${STATE_DIR:-.devflow}"
receipt_dir="$state_dir/${EFF_FEATURE}/gates/P5-migration"
mkdir -p "$receipt_dir"
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "VERSION=p5-migration@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "PHASE=P5-migration"
  echo "ARTIFACTS=$REPORT"
  echo "OUTPUT=$OUTPUT_SUMMARY"
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$receipt_dir/receipt.txt"
echo "[RECEIPT] Generated: $receipt_dir/receipt.txt"
# v3.9.5: mirror receipt into docs/ (version-controlled evidence; .devflow/ was missing in all 4 audited projects)
DOCS_MIRROR="docs/${EFF_FEATURE}/gates/P5-migration"
if [ "${EFF_FEATURE}" != "default" ]; then
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$receipt_dir/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "P5 GATE: FAIL (blocking)"
  exit 1
fi

echo ""
echo "P5 MIGRATION GATE: PASS"
exit 0
