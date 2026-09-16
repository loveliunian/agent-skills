#!/usr/bin/env bash

# : 推导 feature，避免写入 default 目录
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# =============================================================================
# P0 验收点冻结 Gate (v3.9.1 · 含模板-产物对齐检查)
# =============================================================================
# 功能：
#   1. (v3.8/v3.22.0) 检查 docs/需求/*-需求澄清.md（中文优先，英文历史路径回退）
#   2. (v3.8) 检查原子验收点格式 Mxx-Fyy-Azz
#   3. (v3.8) 检查 P0 歧义数量 = 0
#   4. (v3.8) 检查无 "待补充" 字样
#   5. (v3.8) 检查验收点分母已冻结
#   6. (v3.8) 生成 Gate 收据到 .devflow/<feature>/gates/P0/receipt.txt
#   7. **(v3.9.1 NEW)** 检查 clarification.md / acceptance-criteria.md 的 H2 章节
#      与 templates/需求澄清-模板.md 的 H2 章节对齐
# =============================================================================
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEMPLATES_DIR="$SKILL_ROOT/templates"
# v3.22.0: 文档层产物中文化（中文优先、英文回退）
source "$SCRIPT_DIR/devflow_paths.sh"

# ---------- 全局计数 ----------
FAIL=0; PASS=0; WARN=0

p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

# ---------- 参数解析 ----------
FEATURE=""
CRITERIA_PATH=""
CLARIFICATION_PATH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    # v3.15.8: 带值 flag 缺值前置检查（裸 $2 在 set -u 下 unbound 崩溃，报错不友好）
    --criteria) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --criteria requires a non-flag value" >&2; exit 2; }; CRITERIA_PATH="$2"; shift 2 ;;
    --matrix) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --matrix requires a non-flag value" >&2; exit 2; }; CLARIFICATION_PATH="$2"; shift 2 ;;
    --check-only) shift ;;
    --legacy) shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) [ -z "$FEATURE" ] && FEATURE="$1"; shift ;;
  esac
done

if [ -n "$CRITERIA_PATH" ] || [ -n "$CLARIFICATION_PATH" ]; then
  [ -z "$CRITERIA_PATH" ] || [ -z "$CLARIFICATION_PATH" ] && { echo "--criteria and --matrix must be used together" >&2; exit 2; }
else
  [ -z "$FEATURE" ] && { echo "Usage: $0 <feature> | --criteria <p> --matrix <p>"; exit 2; }
fi
EFF_FEATURE="$(devflow_feature "${FEATURE:-}")" || { echo "[FATAL] feature 推导失败，拒绝继续"; exit 2; }
[ -n "$EFF_FEATURE" ] || { echo "[FATAL] feature 为空，拒绝继续"; exit 2; }
# v3.22.0: 未显式传参时解析实际产物（中文优先 docs/需求，回退英文 docs/requirements）
if [ -z "$CLARIFICATION_PATH" ] && [ -z "$CRITERIA_PATH" ]; then
  CLARIFICATION_PATH="$(df_resolve_doc "$EFF_FEATURE" clarification .md requirements)"
  CRITERIA_PATH="$(df_resolve_doc "$EFF_FEATURE" acceptance .md requirements)"
  [ -n "$CLARIFICATION_PATH" ] || CLARIFICATION_PATH="$(df_default_doc "$EFF_FEATURE" clarification .md requirements)"
  [ -n "$CRITERIA_PATH" ] || CRITERIA_PATH="$(df_default_doc "$EFF_FEATURE" acceptance .md requirements)"
fi

# ---------- §0 基础存在性 ----------
echo ""
echo "=== §0 基础产物存在性 ==="
[ -f "$CLARIFICATION_PATH" ] && pass "clarification exists: $CLARIFICATION_PATH" || p0 "clarification missing"
[ -f "$CRITERIA_PATH" ] && pass "acceptance criteria exists: $CRITERIA_PATH" || p0 "acceptance criteria missing"

# ---------- §1 验收点格式 ----------
echo ""
echo "=== §1 原子验收点格式 (Mxx-Fyy-Azz) ==="
TOTAL=0
if [ ! -f "$CRITERIA_PATH" ]; then
  warn "skip format check: criteria missing"
else
  ATOMIC_IDS=$(grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$CRITERIA_PATH" 2>/dev/null | sort -u)
  TOTAL=$(printf '%s\n' "$ATOMIC_IDS" | grep -c . || true)
  UNIQUE=$(printf '%s\n' "$ATOMIC_IDS" | sort -u | grep -c . || true)
  if [ "$TOTAL" -gt 0 ]; then
    pass "atomic acceptance points: $TOTAL"
    INVALID=$(grep -oE 'M-?[0-9]{1,2}-F[0-9]{1,2}-A[0-9]{1,2}' "$CRITERIA_PATH" 2>/dev/null \
      | grep -vE '^M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}$' | grep -c . || true)
    [ "$INVALID" -gt 0 ] && p0 "invalid acceptance format found: $INVALID" || pass "all acceptance IDs match Mxx-Fyy-Azz"
    [ "$TOTAL" -eq "$UNIQUE" ] && pass "acceptance IDs are unique: $UNIQUE/$TOTAL" || p0 "duplicates: $((TOTAL-UNIQUE))"
  else
    p0 "no atomic acceptance points found"
  fi
fi

# ---------- §2 P0 歧义数 (v3.9.1: regex 收紧到表格行) ----------
echo ""
echo "=== §2 P0 歧义数 ==="
P0_AMBIG=0
if [ -f "$CLARIFICATION_PATH" ]; then
  # v3.9.1: 只匹配表格行 `| P0 | ... | 待澄清|未澄清|延后`
  P0_AMBIG=$(grep -E '^\|[[:space:]]*P0[[:space:]]*\|[[:space:]]*[^|]*[[:space:]]*\|' "$CLARIFICATION_PATH" 2>/dev/null \
    | grep -ciE '待澄清|未澄清|延后|TBD|待补充' || true)
  # v3.9.1: 同样扫描 P1/P2 中提到的 P0 状态
  P0_STATUS_BAD=$(grep -E '^\|[[:space:]]*P0[[:space:]]*\|' "$CLARIFICATION_PATH" 2>/dev/null \
    | grep -cvE '已澄清|✅|已解决' || true)
  EFFECTIVE_P0_AMBIG=$((P0_AMBIG + P0_STATUS_BAD))
  if [ "$EFFECTIVE_P0_AMBIG" -gt 0 ]; then
    p0 "P0 未澄清数 = $EFFECTIVE_P0_AMBIG (must be 0)"
    grep -E '^\|[[:space:]]*P0[[:space:]]*\|' "$CLARIFICATION_PATH" 2>/dev/null | head -5 | sed 's/^/    /'
  else
    pass "P0 未澄清数 = 0"
  fi
fi

# ---------- §3 占位符 ----------
echo ""
echo "=== §3 占位符 ==="
PLACEHOLDERS=0
for f in "$CLARIFICATION_PATH" "$CRITERIA_PATH"; do
  [ -f "$f" ] || continue
  COUNT=$(grep -iE '待补充|TODO|FIXME|TBD|REPLACE_WITH|暂定' "$f" 2>/dev/null | grep -c . || true)
  if [ "$COUNT" -gt 0 ]; then
    p0 "placeholder found in $(basename "$f"): $COUNT"
    grep -inE '待补充|TODO|FIXME|TBD|REPLACE_WITH' "$f" 2>/dev/null | head -3 | sed 's/^/    /'
    PLACEHOLDERS=$((PLACEHOLDERS + COUNT))
  fi
done
[ "$PLACEHOLDERS" -eq 0 ] && pass "no placeholders"

# ---------- §4 分母冻结 ----------
echo ""
echo "=== §4 验收点分母冻结 ==="
if [ -f "$CRITERIA_PATH" ]; then
  TOTAL_LINE=$(grep -iE '总计|分母|合计.*验收点|验收点.*合计|分母已冻结|冻结分母' "$CRITERIA_PATH" 2>/dev/null | tail -1)
  if [ -n "$TOTAL_LINE" ]; then
    DENOM=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+' | tail -1)
    if [ -n "$DENOM" ] && [ "$DENOM" -gt 0 ]; then
      pass "denominator frozen: $DENOM"
    else
      p0 "denominator not frozen: $TOTAL_LINE"
    fi
  else
    p0 "no denominator line found"
  fi
fi

# ---------- §5 (v3.9.1 NEW) 模板-产物对齐检查 ----------
echo ""
echo "=== §5 (v3.9.1 NEW) 模板-产物章节对齐 ==="

TEMPLATE_FILE="$TEMPLATES_DIR/需求澄清-模板.md"
if [ ! -f "$TEMPLATE_FILE" ]; then
  warn "skip template alignment: template not found at $TEMPLATE_FILE"
else
  TEMPLATE_H2=$(grep -E '^## ' "$TEMPLATE_FILE" 2>/dev/null | sed 's/^## //' | sort)
  PRODUCT_H2=$(cat "$CLARIFICATION_PATH" 2>/dev/null | grep -E '^## ' | sed 's/^## //' | sort)

  # v3.9.1: 整行比较 + 别名映射（中文 substr 多字节 bug 规避）
  TEMPLATE_H2_NORMALIZED=$(printf '%s\n' "$TEMPLATE_H2" \
    | sed 's/^[^a-zA-Z§0-9]*[0-9]\+\. //' \
    | LC_ALL=C sort)
  PRODUCT_H2_NORMALIZED=$(printf '%s\n' "$PRODUCT_H2" \
    | sed 's/^歧义说明/模糊点/' \
    | sed 's/^歧义$/模糊点/' \
    | LC_ALL=C sort)

  MISSING_IN_PRODUCT=$(comm -23 <(printf '%s\n' "$TEMPLATE_H2_NORMALIZED") <(printf '%s\n' "$PRODUCT_H2_NORMALIZED") | grep -v '^$' | head -5)
  MISSING_COUNT=$(echo "$MISSING_IN_PRODUCT" | grep -c . || true)

  if [ "$MISSING_COUNT" -gt 0 ]; then
    p0 "产物 $CLARIFICATION_PATH 缺少模板章节 ($MISSING_COUNT 个):"
    echo "$MISSING_IN_PRODUCT" | sed 's/^/    - /'
    echo "    参考模板: $TEMPLATE_FILE"
  else
    pass "clarification.md 章节与模板对齐"
  fi

  # acceptance-criteria.md 最小必需章节
  PRODUCT_CRITERIA_H2=$(cat "$CRITERIA_PATH" 2>/dev/null | grep -E '^## ' | sed 's/^## //' | sort)
  # v3.9.1: OR 逻辑 — 验收点分母 / 验收清单 / 基本信息 任一即可
  if echo "$PRODUCT_CRITERIA_H2" | grep -qE '基本|验|用例'; then
    pass "acceptance-criteria.md 含验收相关章节"
  else
    p0 "acceptance-criteria.md 缺少验收相关章节（必须含'基本'/'验'/'用例'之一）"
  fi
fi

# ---------- §6 技术硬约束冻结 (v3.16.26) ----------
echo ""
echo "=== §6 技术硬约束冻结 ==="
if [ -n "${TECH_CONSTRAINTS_FILE:-}" ]; then
  TC_PATH="$TECH_CONSTRAINTS_FILE"
else
  TC_PATH="$(df_resolve_doc "$EFF_FEATURE" constraints .md requirements)"
  [ -n "$TC_PATH" ] || TC_PATH="$(df_default_doc "$EFF_FEATURE" constraints .md requirements)"
fi
source "$SCRIPT_DIR/tech_constraints_lib.sh"
if [ ! -f "$TC_PATH" ]; then
  p0 "technology constraints missing: $TC_PATH (P0 必须冻结硬约束；无约束也须写 constraint_set=NONE 契约块)"
else
  pass "technology constraints exists: $TC_PATH"
  TC_INVALID=$(mktemp -t s0-tc-inv.XXXXXX)
  if ! tc_validate_constraints "$TC_PATH" 2> "$TC_INVALID" >/dev/null; then
    while IFS= read -r line; do p0 "$line"; done < "$TC_INVALID"
  else
    pass "technology constraints machine contract valid (FROZEN + confirmed)"
  fi
  rm -f "$TC_INVALID"
  TC_SHA=$(tc_sha256 "$TC_PATH")
  echo "  constraints_sha256=$TC_SHA"
fi

# ---------- §7 权限码三方对账 (v3.21.0 · L-P0-001 · perm_reconcile_lib) ----------
echo ""
echo "=== §7 权限码三方对账 (Lesson L-P0-001) ==="
# v3.21.0: 抽取 perm_reconcile_lib 共享库（与 artifact_gate P0b 同库同口径，机检前移）——
# (1) 双格式归一：此前仅认 perm: 前缀，真实矩阵（generate-permission-matrix.sh）为
#     反引号三段式，提取恒空 → 对账空转（治理服务复盘发现）；
# (2) 缺矩阵 warn → P0（声明式豁免：澄清文档声明 权限矩阵=not-applicable）；
# (3) 可选第三方菜单 Seed 索引（seed ⊆ matrix）。
# `|| true`：p0() 计数已入 FAIL，返回码仅防未来 set -e 误传播。
source "$SCRIPT_DIR/perm_reconcile_lib.sh"
# v3.22.0: 事实源目录双语（docs/详细设计 优先，回退 docs/detailed-design）；文件名是机器 grep 契约不翻译
PERM_MATRIX="docs/详细设计/_权限矩阵.md"; [ -f "$PERM_MATRIX" ] || PERM_MATRIX="docs/detailed-design/_权限矩阵.md"
MENU_SEED="docs/详细设计/_菜单Seed索引.md"; [ -f "$MENU_SEED" ] || MENU_SEED="docs/detailed-design/_菜单Seed索引.md"
perm_reconcile_three_way "$PERM_MATRIX" "$CLARIFICATION_PATH" "$MENU_SEED" || true

# ---------- §7b 排除条款对账 (v3.21.0 · 排除条款一等需求) ----------
echo ""
echo "=== §7b 排除条款对账 ==="
# PRD 的「排除条款」（不走/除外/手动输入…）与包含条款同为一级需求：必须落为排除性
# 验收点（治理服务事故：PRD M-02 F03 明确三类不走命名规则，生成链仍强制命名配置
# → ENTITY_CONFIG_NOT_FOUND）。豁免：验收点已覆盖排除场景，或澄清文档显式声明
# 「无排除条款」。误报降噪阀门：p0 → warn 一行降级（当前保持 P0 强制）。
EXCL_PAT='不走|除外|手动输入|不通过|无需|不在范围内'
EXCL_HITS=$(grep -cE "$EXCL_PAT" "$CLARIFICATION_PATH" 2>/dev/null || true)
case "${EXCL_HITS:-0}" in ''|*[!0-9]*) EXCL_HITS=0 ;; esac
if [ "$EXCL_HITS" -gt 0 ]; then
  if [ -f "$CRITERIA_PATH" ] && grep -qE "$EXCL_PAT" "$CRITERIA_PATH" 2>/dev/null; then
    pass "排除类表述 ${EXCL_HITS} 处，验收点已有排除场景覆盖"
  elif grep -q '无排除条款' "$CLARIFICATION_PATH" 2>/dev/null; then
    pass "explicit 无排除条款 declaration"
  else
    p0 "PRD/澄清出现排除类表述 ${EXCL_HITS} 处，但验收点无排除场景覆盖且无「无排除条款」声明——排除条款是一等需求，必须落为验收点或显式豁免"
  fi
else
  pass "未出现排除类语言（无需排除条款对账）"
fi

# ---------- FINAL ----------
echo ""
echo "========================================"
echo "P0 RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"

STATE_DIR="${STATE_DIR:-.devflow}"
RECEIPT_DIR="$STATE_DIR/${EFF_FEATURE}/gates/P0"
mkdir -p "$RECEIPT_DIR"
EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "VERSION=p0@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "PHASE=P0"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "ARTIFACTS=$CRITERIA_PATH,$CLARIFICATION_PATH"
  echo "CONSTRAINTS_PATH=$TC_PATH"
  [ -f "$TC_PATH" ] && echo "CONSTRAINTS_SHA256=$(tc_sha256 "$TC_PATH")" || echo "CONSTRAINTS_SHA256=missing"
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN total=${TOTAL:-0}"
  echo "EXCL_HITS=${EXCL_HITS:-0}"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt"
echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
# v3.9.5: mirror receipt into docs/ (version-controlled evidence; .devflow/ was missing in all 4 audited projects)
DOCS_MIRROR="docs/${EFF_FEATURE}/gates/P0"
if [ "${EFF_FEATURE}" != "default" ]; then
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"
fi

[ "$FAIL" -gt 0 ] && { echo ""; echo "P0 GATE: FAIL (blocking)"; exit 1; }
echo ""
echo "P0 GATE: PASS"
exit 0
