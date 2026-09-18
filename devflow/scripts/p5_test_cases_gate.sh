#!/usr/bin/env bash
# P5 测试用例证据 Gate
set -uo pipefail

FEATURE="${1:-}"
CASES="${2:-}"
STATE_DIR="${STATE_DIR:-.devflow}"
[ -n "$FEATURE" ] || { echo "Usage: $0 <feature> [test-case-file]"; exit 2; }
# v3.15.5: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 写穿项目外）与 grep -E 正则注入
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# v3.27.1: 路径解析统一走 devflow_paths（中文优先、英文回退）——旧版验收点路径
# 纯英文硬编码，中文命名走完 P0 的项目到 P5 必失败（审查报告发现 3）。
source "$(cd "$(dirname "$0")" && pwd)/devflow_paths.sh"
devflow_feature_validate "$FEATURE" || exit 2

if [ -z "$CASES" ]; then
  # v3.22.0: 目录中英双语（docs/测试用例 优先，回退 docs/test-cases）
  P5_CASE_DIRS=()
  for _d in "$(df_zh_dir testcases)" "$(df_en_dir testcases)"; do [ -d "$_d" ] && P5_CASE_DIRS+=("$_d"); done
  if [ "${#P5_CASE_DIRS[@]}" -gt 0 ]; then
    CASES=$(find "${P5_CASE_DIRS[@]}" -maxdepth 1 -type f \( -name "${FEATURE}*.md" -o -name "*${FEATURE}*测试用例*.md" -o -name "${FEATURE}-测试用例.md" \) 2>/dev/null | sort | head -1 || true)
  fi
fi

FAIL=0; PASS=0; WARN=0
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
p0() { echo "[P0] $*"; FAIL=$((FAIL + 1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }
hash_file() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

echo "=== P5 Test Cases Gate ==="
if [ -z "$CASES" ] || [ ! -f "$CASES" ]; then
  p0 "test-case evidence missing: ${CASES:-docs/test-cases/${FEATURE}*.md}"
else
  pass "test-case evidence exists: $CASES"
  if grep -qE '(^|[[:space:]])TC-[A-Za-z0-9._-]+' "$CASES"; then
    pass "test case IDs are present"
  else
    p0 "test case IDs (TC-*) are missing"
  fi
  if grep -qE '预置条件|步骤|预期结果|PASS|FAIL' "$CASES"; then
    pass "test case structure is present"
  else
    p0 "test case structure is incomplete"
  fi
  # ---------- v3.14.3: 实质内容校验 ----------
  DATA_ROWS=$(grep -E '^\|[[:space:]]*TC-[A-Za-z0-9._-]+' "$CASES" 2>/dev/null | grep -vE '^\|[[:space:]]*-{2,}' || true)

  # 1) TC ID 唯一性
  DUP_IDS=$(printf '%s\n' "$DATA_ROWS" | grep -oE 'TC-[A-Za-z0-9._-]+' | sort | uniq -d | head -3)
  if [ -n "$DUP_IDS" ]; then
    p0 "重复 TC ID: $(echo $DUP_IDS)"
  else
    pass "TC ID 无重复"
  fi

  # 2) 四要素列实质化：验收点/预置条件/步骤/预期结果 每格 ≥2 字符且互不完全雷同
  THIN=$(printf '%s\n' "$DATA_ROWS" | awk -F'|' '
    { for (i=3;i<=6;i++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
      if (length($3)<2 || length($4)<2 || length($5)<2 || length($6)<2 ||
          ($4==$5 && $5==$6)) c++ }
    END { print c+0 }')
  [ "${THIN:-0}" -eq 0 ] && pass "用例行四要素均实质化" \
    || p0 "${THIN} 行存在占位/雷同单元格（预置条件/步骤/预期结果须具体）"

  # 3) 验收点覆盖对照：用例必须引用合法 M-ID 且全覆盖 criteria
  # v3.27.1: 验收点路径统一解析（中文优先、英文回退）——旧版纯英文硬编码
  CRIT="$(df_resolve_doc "$FEATURE" acceptance .md requirements 2>/dev/null || true)"
  [ -n "$CRIT" ] || CRIT="docs/需求/${FEATURE}-验收点.md"
  if [ -f "$CRIT" ]; then
    CRIT_IDS=$(grep -oE 'M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$CRIT" 2>/dev/null | sort -u)
    CASE_AIDS=$(printf '%s\n' "$DATA_ROWS" | grep -oE 'M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}' | sort -u)
    if [ -z "$CRIT_IDS" ]; then
      p0 "验收点文件无任何 M-ID（${CRIT}）——无法建立用例↔验收点对照，拒绝放行"
    else
      NOT_COVERED=$(comm -23 <(printf '%s\n' "$CRIT_IDS") <(printf '%s\n' "$CASE_AIDS") | head -5)
      ILLEGAL=$(comm -13 <(printf '%s\n' "$CRIT_IDS") <(printf '%s\n' "$CASE_AIDS") | head -5)
      [ -z "$NOT_COVERED" ] && pass "验收点全覆盖（$(printf '%s\n' "$CRIT_IDS" | grep -c .) 个）" \
        || p0 "验收点未被用例覆盖: $(echo $NOT_COVERED | tr '\n' ' ')"
      [ -z "$ILLEGAL" ] || p0 "用例引用了不存在的验收点 ID: $(echo $ILLEGAL | tr '\n' ' ')"
    fi
  else
    p0 "验收点文件不存在: $CRIT —— 无法建立用例↔验收点对照，拒绝放行"
  fi

  # 4) 边界/异常用例 ≥1
  BOUNDARY=$(printf '%s\n' "$DATA_ROWS" | grep -ciE '边界|异常|空|超长|并发|失败|拒绝|非法' || true)
  [ "${BOUNDARY:-0}" -ge 1 ] && pass "含边界/异常用例 ${BOUNDARY} 条" \
    || p0 "缺少边界/异常类用例（至少 1 条：空输入/越界/失败路径等）"
fi

RECEIPT_DIR="$STATE_DIR/$FEATURE/gates/P5"
mkdir -p "$RECEIPT_DIR"
EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "VERSION=p5-test-cases@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "PHASE=P5"
  echo "EVIDENCE_PATH=$CASES"
  if [ -n "$CASES" ] && [ -f "$CASES" ]; then echo "EVIDENCE_SHA256=$(hash_file "$CASES")"; else echo "EVIDENCE_SHA256=missing"; fi
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt"
DOCS_MIRROR="docs/$FEATURE/gates/P5"
mkdir -p "$DOCS_MIRROR" && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/receipt.txt"
echo "[RECEIPT] Generated and mirrored: $RECEIPT_DIR/receipt.txt"

[ "$FAIL" -eq 0 ] && { echo "P5 TEST CASES GATE: PASS"; exit 0; }
echo "P5 TEST CASES GATE: FAIL (blocking)"
exit 1
