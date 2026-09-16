#!/usr/bin/env bash

# : 推导 feature，避免写入 default 目录
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# =============================================================================
# P6 首轮准确率 Gate（first-pass accuracy —— 质量指标，非部署闸门）
# =============================================================================
# v3.16.0 定位澄清（P0-1 修复）：本 Gate 度量"首轮"准确率——首轮允许失败
#（FAILED>0 是首轮记录的一部分，仅作指标与阈值判定）。部署前终验由
# s6_final_verification_gate.sh 负责：验收点 FAIL=0 + unit/integration/client/
# load/staging 五类测试证据（CMD/EXIT/REPORT_PATH；REPORT_SHA256 可选）+ 环境边界。
# 两件事已拆开，不得互相替代。
# 功能：
#   1. 解析首轮测试结果
#   2. 解析首轮 Review 结果
#   3. 计算首轮代码准确率 = 通过数 / 总数
#   4. 检查首轮代码准确率 >= 80%
#   5. 检查失败验收点保持原 ID
#   6. 防止修复后回写首轮统计
# =============================================================================
set -uo pipefail


# ---------- 全局计数 ----------
FAIL=0; PASS=0; WARN=0

p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

# ---------- 参数解析 ----------
# v3.15.9: ①去 $1/$2 预取 + `a && b || c && d` 链式赋值——左结合下 `s6 "" 85` 形态
#   会把 THRESHOLD 清空且不再校验 → 阈值 0 恒过（fail-open）；改 if/elif 显式填充
#   （s2 v3.15.8 同模式）
# ②usage 拆分：--help 显式 exit 0；无参/缺 feature 改 exit 2 fail-closed——
#   旧 usage 内 exit 0 = 无参空跑被上层误判为 P6 gate PASS
usage() {
  cat <<EOF

检查 P6 首轮准确率 Gate

参数：
  feature         功能模块名
  threshold       通过率阈值（默认：80）

示例：
  $0 m-03
  $0 m-04 85
EOF
}

FEATURE=""
THRESHOLD=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    -*) echo "[P0] unknown argument: $1"; exit 2 ;;
    *) if [ -z "$FEATURE" ]; then FEATURE="$1";
       elif [ -z "$THRESHOLD" ]; then THRESHOLD="$1";
       else echo "[P0] too many positional args: $1"; exit 2; fi; shift ;;
  esac
done
[ -n "$THRESHOLD" ] || THRESHOLD="80"
printf '%s' "$THRESHOLD" | grep -qE '^[0-9]+(\.[0-9]+)?$' || { echo "[P0] threshold 必须为数字: $THRESHOLD"; exit 2; }
[ -n "$FEATURE" ] || { usage; exit 2; }
# v3.14.1: 一次性推导；失败（多 state/无 state）即拒绝执行，杜绝 default 目录
EFF_FEATURE="$(devflow_feature "${FEATURE:-}")" || { echo "[FATAL] feature 推导失败，拒绝继续"; exit 2; }
[ -n "$EFF_FEATURE" ] || { echo "[FATAL] feature 为空，拒绝继续"; exit 2; }
STATE_ROOT="${STATE_DIR:-.devflow}"

DIR="$STATE_ROOT/$FEATURE"
BASE="$DIR/first-pass-baseline.tsv"
RESULTS="$DIR/first-pass-results.tsv"
META="$DIR/first-pass-meta.env"
REVIEW="$DIR/first-pass-review.tsv"

# =============================================================================
# SECTION 0: 快照文件检查
# =============================================================================
echo ""
echo "=== §0 快照文件检查 ==="

[ -f "$BASE" ] || { p0 "baseline missing: $BASE"; exit 1; }
pass "baseline exists: $BASE"

[ -f "$RESULTS" ] || { p0 "results missing: $RESULTS"; exit 1; }
pass "results exists: $RESULTS"

[ -f "$META" ] || { p0 "meta missing: $META"; exit 1; }
pass "meta exists: $META"

# =============================================================================
# SECTION 1: 文件完整性验证（防止篡改）
# =============================================================================
echo ""
echo "=== §1 文件完整性验证 ==="

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

value() { sed -n "s/^$1=//p" "$META" | tail -1; }

# 验证 results 文件哈希
if [ -f "$RESULTS" ]; then
  stored_hash=$(value results_sha256)
  current_hash=$(hash_file "$RESULTS")

  if [ "$stored_hash" = "$current_hash" ]; then
    pass "results file integrity verified"
  else
    p0 "results file has been modified (tampering detected)"
    echo "  stored: $stored_hash"
    echo "  current: $current_hash"
    exit 1
  fi
fi

# 验证 design 文件未被修改
design_path=$(value design_path)
if [ -n "$design_path" ] && [ -f "$design_path" ]; then
  stored_sha=$(value design_sha256)
  current_sha=$(hash_file "$design_path")

  if [ "$stored_sha" = "$current_sha" ]; then
    pass "design file unchanged: $(basename "$design_path")"
  else
    p0 "design file has been modified: $design_path"
    echo "  original sha: $stored_sha"
    echo "  current sha:  $current_sha"
  fi
fi

# 验证 criteria 文件未被修改
criteria_path=$(value criteria_path)
if [ -n "$criteria_path" ] && [ -f "$criteria_path" ]; then
  stored_sha=$(value criteria_sha256)
  current_sha=$(hash_file "$criteria_path")

  if [ "$stored_sha" = "$current_sha" ]; then
    pass "criteria file unchanged: $(basename "$criteria_path")"
  else
    p0 "criteria file has been modified: $criteria_path"
    echo "  original sha: $stored_sha"
    echo "  current sha:  $current_sha"
  fi
fi

# =============================================================================
# SECTION 2: ID 一致性检查
# =============================================================================
echo ""
echo "=== §2 ID 一致性检查 ==="

base_ids=$(tail -n +2 "$BASE" | cut -f1 | sort)
result_ids=$(tail -n +2 "$RESULTS" | cut -f1 | sort)

base_count=$(printf '%s\n' "$base_ids" | grep -c . || true)
result_count=$(printf '%s\n' "$result_ids" | grep -c . || true)

if [ "$base_ids" = "$result_ids" ]; then
  pass "result IDs match baseline: $base_count IDs"
else
  p0 "result IDs differ from baseline"
  echo "  baseline: $base_count IDs"
  echo "  results: $result_count IDs"

  # 找出差异
  missing=$(comm -23 <(printf '%s\n' "$base_ids") <(printf '%s\n' "$result_ids") || true)
  extra=$(comm -13 <(printf '%s\n' "$base_ids") <(printf '%s\n' "$result_ids") || true)

  [ -n "$missing" ] && echo "  missing IDs: $missing"
  [ -n "$extra" ] && echo "  extra IDs: $extra"
fi

# =============================================================================
# SECTION 3: 结果状态验证
# =============================================================================
echo ""
echo "=== §3 结果状态验证 ==="

# 验证所有状态必须是 PASS 或 FAIL
INVALID_STATUS=$(awk -F'\t' 'NR>1 && $2!="PASS" && $2!="FAIL" && $2!="SKIP" {print}' "$RESULTS" | head -5)
if [ -n "$INVALID_STATUS" ]; then
  p0 "invalid status found in results"
  echo "$INVALID_STATUS" | head -5 | sed 's/^/    /'
else
  pass "all results have valid status (PASS/FAIL/SKIP)"
fi

# =============================================================================
# SECTION 4: 准确率计算（修复：除以冻结验收点总数）
# =============================================================================
echo ""
echo "=== §4 准确率计算 ==="

TOTAL=$(printf '%s\n' "$base_ids" | grep -c . || true)
PASSED=$(awk -F'\t' 'NR>1 && $2=="PASS" {n++} END {print n+0}' "$RESULTS")
FAILED=$(awk -F'\t' 'NR>1 && $2=="FAIL" {n++} END {print n+0}' "$RESULTS")
SKIPPED=$(awk -F'\t' 'NR>1 && $2=="SKIP" {n++} END {print n+0}' "$RESULTS")

[ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ] && { p0 "empty baseline"; exit 1; }
[ -z "$PASSED" ] && PASSED=0
[ -z "$FAILED" ] && FAILED=0
[ -z "$SKIPPED" ] && SKIPPED=0

# 从 meta 文件读取冻结验收点总数
FROZEN_COUNT=$(value frozen_acceptance_count 2>/dev/null || echo "$TOTAL")
[ -z "$FROZEN_COUNT" ] || [ "$FROZEN_COUNT" -eq 0 ] && FROZEN_COUNT="$TOTAL"

# 准确率 = PASS / 冻结验收点总数（SKIP 计入分母但不计入分子）
if [ "$FROZEN_COUNT" -gt 0 ]; then
  ACCURACY=$(awk -v p="$PASSED" -v t="$FROZEN_COUNT" 'BEGIN {printf "%.2f", (p/t)*100}')
else
  p0 "frozen acceptance count is 0"
  exit 1
fi

# 覆盖率（有多少验收点被测试，排除 SKIP）
EVALUABLE=$((PASSED + FAILED))
COVERAGE=$(awk -v t="$TOTAL" -v e="$EVALUABLE" 'BEGIN {printf "%.2f", (e/t)*100}')

echo "  Frozen Total: $FROZEN_COUNT"
echo "  TOTAL: $TOTAL"
echo "  PASSED: $PASSED"
echo "  FAILED: $FAILED"
echo "  SKIPPED: $SKIPPED"
echo "  Accuracy: $ACCURACY% (threshold: ${THRESHOLD}%)"
echo "  Coverage: $COVERAGE%"

# 验证：PASS + FAIL + SKIP 应该接近冻结总数
ACTUAL_TOTAL=$((PASSED + FAILED + SKIPPED))
if [ "$ACTUAL_TOTAL" -lt "$FROZEN_COUNT" ]; then
  p1 "Test coverage incomplete: $ACTUAL_TOTAL / $FROZEN_COUNT"
fi

# =============================================================================
# SECTION 5: 阈值检查
# =============================================================================
echo ""
echo "=== §5 阈值检查 ==="

if awk -v r="$ACCURACY" -v t="$THRESHOLD" 'BEGIN {exit !(r+0 >= t+0)}'; then
  pass "accuracy $ACCURACY% >= threshold ${THRESHOLD}%"
else
  p0 "accuracy $ACCURACY% < threshold ${THRESHOLD}%"
fi

# 检查覆盖率（不应有太多 SKIP）
if awk -v c="$COVERAGE" 'BEGIN {exit !(c+0 >= 80.0)}'; then
  pass "test coverage $COVERAGE% >= 80%"
else
  p1 "test coverage $COVERAGE% < 80% (too many skipped tests)"
fi

# =============================================================================
# SECTION 6: Review 结果检查（可选）
# =============================================================================
echo ""
echo "=== §6 Review 结果检查（缺失即 P0）==="

if [ -f "$REVIEW" ]; then
  REVIEW_PASSED=$(awk -F'\t' 'NR>1 && $2=="PASS" {n++} END {print n+0}' "$REVIEW")
  REVIEW_TOTAL=$(tail -n +2 "$REVIEW" | grep -c . || true)

  if [ -n "$REVIEW_PASSED" ] && [ -n "$REVIEW_TOTAL" ]; then
    REVIEW_RATE=$(awk -v p="$REVIEW_PASSED" -v t="$REVIEW_TOTAL" 'BEGIN {printf "%.2f", (p/t)*100}')
    echo "  Review: $REVIEW_PASSED/$REVIEW_TOTAL ($REVIEW_RATE%)"

    if awk -v r="$REVIEW_RATE" 'BEGIN {exit !(r+0 >= 80.0)}'; then
      pass "review pass rate $REVIEW_RATE% >= 80%"
    else
      p1 "review pass rate $REVIEW_RATE% < 80%"
    fi
  else
    warn "review file has no valid data"
  fi
else
  p0 "first-pass-review.tsv missing: ${REVIEW}（record 阶段必须落盘 Review 明细，否则首轮质量无法闭环）"
fi

# =============================================================================
# SECTION 7: 失败验收点 ID 保持检查
# =============================================================================
echo ""
echo "=== §7 失败验收点 ID 保持检查 ==="

# 获取失败的验收点 ID
FAILED_IDS=$(awk -F'\t' 'NR>1 && $2=="FAIL" {print $1}' "$RESULTS" | sort)
FAILED_COUNT=$(printf '%s\n' "$FAILED_IDS" | grep -c . || true)

if [ "$FAILED_COUNT" -gt 0 ]; then
  echo "  Failed acceptance points: $FAILED_COUNT"

  # 检查这些 ID 是否在基准中存在（确保未被修改）
  INVALID_IDS=""
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! printf '%s\n' "$base_ids" | grep -qF "$id"; then
      INVALID_IDS="$INVALID_IDS $id"
    fi
  done <<< "$FAILED_IDS"

  if [ -n "$INVALID_IDS" ]; then
    p0 "failed IDs modified or invalid:$INVALID_IDS"
  else
    pass "all failed IDs are valid and unchanged"
  fi

  # 显示失败的验收点
  echo "  Failed IDs:"
  printf '%s\n' "$FAILED_IDS" | sed 's/^/    /'
else
  pass "no failed acceptance points"
fi

# =============================================================================
# FINAL: 输出汇总
# =============================================================================
echo ""
echo "========================================"
echo "P6 RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"
echo ""
echo "  Accuracy: $ACCURACY% (threshold: ${THRESHOLD}%)"
echo "  Coverage: $COVERAGE%"
echo "  Frozen Total: $FROZEN_COUNT"
echo "  Total: $TOTAL"
echo "  Passed: $PASSED"
echo "  Failed: $FAILED"
echo "  Skipped: $SKIPPED"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "P6 GATE: FAIL (blocking)"
  echo ""
  echo "阻塞原因:"
  echo "  - 首轮准确率 < ${THRESHOLD}%"
  echo "  - 文件完整性验证失败（可能被篡改）"
  echo "  - ID 一致性检查失败"
  # ---------- 收据双写（FAIL 路径） ----------
  STATE_DIR="${STATE_DIR:-.devflow}"
  RECEIPT_DIR="$STATE_DIR/${EFF_FEATURE}/gates/P6"
  mkdir -p "$RECEIPT_DIR" 2>/dev/null
  {
    echo "EXIT_CODE=1"
    echo "VERSION=p6@$(bash "$(dirname "$0")/gate-version.sh")"
    echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
    echo "PHASE=P6"
    echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
    echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$RECEIPT_DIR/receipt.txt" 2>/dev/null
[ -s "$RECEIPT_DIR/receipt.txt" ] || { echo "[RECEIPT] WRITE FAILED" >&2; exit 1; }
  echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
  exit 1
fi

echo ""
echo "P6 GATE: PASS"
# ---------- 收据双写：保留首轮计数，避免只有 EXIT_CODE 的黑盒回执 ----------
STATE_DIR="${STATE_DIR:-.devflow}"
RECEIPT_DIR="$STATE_DIR/${EFF_FEATURE}/gates/P6"
mkdir -p "$RECEIPT_DIR" 2>/dev/null
{
  echo "EXIT_CODE=0"
  echo "VERSION=p6@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "PHASE=P6"
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt" 2>/dev/null
[ -s "$RECEIPT_DIR/receipt.txt" ] || { echo "[RECEIPT] WRITE FAILED" >&2; exit 1; }
echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
DOCS_MIRROR="docs/${EFF_FEATURE}/gates/P6"
if [ "${EFF_FEATURE}" != "default" ]; then
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"
fi
exit 0
