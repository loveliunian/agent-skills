#!/usr/bin/env bash

# : 推导 feature，避免写入 default 目录
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# v3.14.1: 一次性推导；失败（多 state/无 state）即拒绝执行，杜绝 default 目录
EFF_FEATURE="$(devflow_feature "${FEATURE:-}")" || { echo "[FATAL] feature 推导失败，拒绝继续"; exit 2; }
[ -n "$EFF_FEATURE" ] || { echo "[FATAL] feature 为空，拒绝继续"; exit 2; }
# =============================================================================
# P1 工程事实源 Gate (v3.9.1 · 含模板-产物对齐检查)
# =============================================================================
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEMPLATES_DIR="$SKILL_ROOT/templates"

FAIL=0; PASS=0; WARN=0
p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

DOC_DIR="${1:-docs/detailed-design}"
DOC_DIR="${DOC_DIR%/}"

# v3.16.25: P1 必须验证 P0 技术硬约束与技术选型报告，不能只验证事实源。
TECH_REPORT="${TECH_SELECTION_FILE:-$DOC_DIR/${EFF_FEATURE}-tech-selection.md}"
TECH_CONSTRAINTS="${TECH_CONSTRAINTS_FILE:-docs/requirements/${EFF_FEATURE}-technology-constraints.md}"

# BSD bash 不支持 declare -A key 含 . — 用普通数组
FACT_FILES="_commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md"

echo ""
echo "=== §1 7 份事实源存在性 ==="
for fname in $FACT_FILES; do
  f="$DOC_DIR/$fname"
  if [ -f "$f" ]; then
    LINES=$(wc -l < "$f" 2>/dev/null || echo 0)
    if [ "$LINES" -gt 5 ]; then
      pass "$f exists ($LINES lines)"
    else
      p0 "$f too short ($LINES lines)"
    fi
  else
    p0 "$f missing"
  fi
done

# ---------- §1b 技术选型与硬约束契约 ----------
echo ""
echo "=== §1b 技术选型报告与硬约束契约 ==="
for f in "$TECH_CONSTRAINTS" "$TECH_REPORT"; do
  if [ ! -f "$f" ]; then
    p0 "$f missing"
  elif [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -le 5 ]; then
    p0 "$f too short"
  else
    pass "$f exists"
  fi
done

source "$SCRIPT_DIR/tech_constraints_lib.sh"

if [ -f "$TECH_CONSTRAINTS" ]; then
  # 展示层结构（人读表格）仍须存在
  grep -qE 'MUST_USE|MUST_NOT_USE|NONE' "$TECH_CONSTRAINTS" || p0 "technology constraints must declare MUST_USE/MUST_NOT_USE or explicit NONE"
  # NONE 契约（constraint_set=NONE）没有逐条约束表，同样合法
  grep -qE '约束清单|constraint_id|constraint_set' "$TECH_CONSTRAINTS" || p0 "technology constraints table missing"

  # v3.16.26: 机器契约是唯一判定源——缺失即阻断，不从自然语言推断合规
  TC_INVALID=$(mktemp -t s1-tc-inv.XXXXXX)
  if ! tc_validate_constraints "$TECH_CONSTRAINTS" 2> "$TC_INVALID" >/dev/null; then
    while IFS= read -r line; do p0 "$line"; done < "$TC_INVALID"
  else
    pass "technology constraints machine contract valid (all FROZEN + confirmed)"
  fi
  rm -f "$TC_INVALID"

  # v3.16.26: 约束文件 SHA 必须先经 devflow-state.sh constraints-freeze 冻结进 state
  STATE_FILE="${STATE_DIR:-.devflow}/${EFF_FEATURE}.state.json"
  if [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
    FROZEN_TC_SHA=$(jq -r '.scope.tech_constraints_sha256 // empty' "$STATE_FILE" 2>/dev/null || true)
    ACTUAL_TC_SHA=$(tc_sha256 "$TECH_CONSTRAINTS")
    if [ -z "$FROZEN_TC_SHA" ]; then
      p0 "technology constraints not frozen in state — run: devflow-state.sh constraints-freeze $EFF_FEATURE"
    elif [ "$FROZEN_TC_SHA" != "$ACTUAL_TC_SHA" ]; then
      p0 "technology constraints file changed after freeze (state=$FROZEN_TC_SHA actual=$ACTUAL_TC_SHA) — re-freeze via constraints-freeze"
    else
      pass "technology constraints SHA matches state freeze"
    fi
  else
    p0 "state file missing or jq unavailable — cannot verify constraints freeze"
  fi
fi
if [ -f "$TECH_REPORT" ]; then
  grep -qE '决策矩阵' "$TECH_REPORT" || p0 "technology selection report missing decision matrix"
  grep -qE '决策结论' "$TECH_REPORT" || p0 "technology selection report missing decision conclusion"
  grep -qE 'constraint_id|constraint_set' "$TECH_REPORT" || p0 "technology selection report missing constraint bindings"

  # v3.16.26: 用户确认正则修复——LC_ALL=C 下 [^[:alnum:]] 会吞掉多字节汉字，
  # 旧正则曾把"用户确认: 未确认"误判为已确认。现在：正向匹配必须在冒号后直接出现
  # 肯定词；并显式拒绝否定词。
  if grep -qE '用户确认[：:][[:space:]]*(YES|已确认|CONFIRMED|true)' "$TECH_REPORT"; then
    if grep -qE '用户确认[：:][[:space:]]*(未确认|待确认|尚未确认|NOT_CONFIRMED|NO$)' "$TECH_REPORT"; then
      p0 "technology selection report contains negative user confirmation (未确认/待确认)"
    else
      pass "technology selection report has explicit user confirmation"
    fi
  else
    p0 "technology selection report missing explicit user confirmation (用户确认: YES|已确认)"
  fi

  # v3.16.26: 每条 FROZEN 硬约束必须在 P1 报告中有唯一机读绑定且合规（含版本）；
  # MUST_NOT_USE 的 selected_product 含禁用产品即阻断——"未引入 FlowCore"这类描述不再参与判定。
  if [ -f "$TECH_CONSTRAINTS" ]; then
    TC_VIOLATIONS=$(mktemp -t s1-tc-viol.XXXXXX)
    if ! tc_check_compliance "$TECH_CONSTRAINTS" "$TECH_REPORT" > "$TC_VIOLATIONS"; then
      while IFS= read -r line; do [ -n "$line" ] && p0 "$line"; done < "$TC_VIOLATIONS"
    else
      pass "all hard constraints bound and compliant in tech selection report"
    fi
    rm -f "$TC_VIOLATIONS"
  fi
fi

# ---------- §2 (v3.9.1 NEW) 模板-产物对齐检查 ----------
echo ""
echo "=== §2 (v3.9.1 NEW) 模板-产物章节对齐 ==="

# 用文件列表替代 declare -A（兼容 BSD bash）
TMPL_FILES="_commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md"

for tpl in $TMPL_FILES; do
  TPL="$TEMPLATES_DIR/$tpl"
  PROD="$DOC_DIR/$tpl"

  if [ ! -f "$TPL" ]; then
    warn "template missing: $TPL (skip alignment for $PROD)"
    continue
  fi
  if [ ! -f "$PROD" ]; then
    continue
  fi

  TPL_H2=$(grep -E '^## ' "$TPL" 2>/dev/null | sed 's/^## //' | LC_ALL=C sort)
  PROD_H2=$(cat "$PROD" 2>/dev/null | grep -E '^## ' | sed 's/^## //' | LC_ALL=C sort)

  # v3.9.1: 比例检查（容忍"按功能模块组织"vs"按元数据章节组织"）
  # 规则：产物 H2 数 ≥ 模板 H2 数 × 60%，视为对齐
  TPL_COUNT=$(echo "$TPL_H2" | grep -c . || true)
  PROD_COUNT=$(echo "$PROD_H2" | grep -c . || true)
  if [ "$TPL_COUNT" -gt 0 ] && [ "$PROD_COUNT" -gt 0 ]; then
    RATIO=$(awk -v p="$PROD_COUNT" -v t="$TPL_COUNT" 'BEGIN {printf "%.0f", (p/t)*100}')
    if [ "$PROD_COUNT" -ge "$TPL_COUNT" ]; then
      pass "$PROD 章节数对齐 (tpl=$TPL_COUNT, prod=$PROD_COUNT)"
    elif [ "$RATIO" -ge 60 ]; then
      pass "$PROD 章节数 ≥60% 模板 (tpl=$TPL_COUNT, prod=$PROD_COUNT, ratio=${RATIO}%)"
    else
      p0 "$PROD 章节数不足 (tpl=$TPL_COUNT, prod=$PROD_COUNT, ratio=${RATIO}% < 60%)"
      echo "    参考模板: $TPL"
    fi
  fi
done

# ---------- §3 菜单种子通配符 ----------
echo ""
echo "=== §3 _菜单Seed索引 通配符检查 ==="
if [ -f "$DOC_DIR/_菜单Seed索引.md" ]; then
  if grep -E '/\*' "$DOC_DIR/_菜单Seed索引.md" >/dev/null 2>&1; then
    p0 "_菜单Seed索引.md 含通配符路径，可能误触发"
  else
    pass "菜单种子无通配符路径冲突"
  fi
fi

echo ""
echo "========================================"
echo "P1 RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"

STATE_DIR="${STATE_DIR:-.devflow}"
RECEIPT_DIR="$STATE_DIR/${EFF_FEATURE}/gates/P1"
mkdir -p "$RECEIPT_DIR"
EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "VERSION=p1@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "PHASE=P1"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "ARTIFACTS=$DOC_DIR/_commons.md,$DOC_DIR/_权限矩阵.md,$DOC_DIR/_环境与账号.md,$DOC_DIR/_菜单Seed索引.md,$DOC_DIR/INDEX-章节锚点.md,$DOC_DIR/INDEX-表.md,$DOC_DIR/INDEX-接口.md,$TECH_CONSTRAINTS,$TECH_REPORT"
  if [ -f "$TECH_CONSTRAINTS" ]; then
    echo "CONSTRAINTS_PATH=$TECH_CONSTRAINTS"
    echo "CONSTRAINTS_SHA256=$(tc_sha256 "$TECH_CONSTRAINTS")"
  fi
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt"
echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
# v3.9.5: mirror receipt into docs/ (version-controlled evidence; .devflow/ was missing in all 4 audited projects)
DOCS_MIRROR="docs/${EFF_FEATURE}/gates/P1"
if [ "${EFF_FEATURE}" != "default" ]; then
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"
fi

[ "$FAIL" -gt 0 ] && { echo ""; echo "P1 GATE: FAIL (blocking)"; exit 1; }
echo ""
echo "P1 GATE: PASS"
exit 0
