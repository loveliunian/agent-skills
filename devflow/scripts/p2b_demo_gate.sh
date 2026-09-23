#!/usr/bin/env bash
# P2b Demo Gate · 版本随 SKILL.md
# 检查 docs/原型/<feature>-原型确认.md（兼容历史 docs/demo/<feature>-demo-signoff.md） 存在且含签字人+日期
# 修复：①无参时输出 usage；②顶层 local 非法 + $local_count 未定义（set -u 下炸）；
#            ③补收据双写（.devflow + docs 镜像）
set -uo pipefail

FEATURE="${1:-}"
if [ -z "$FEATURE" ]; then
  echo "用法: p2b_demo_gate.sh <feature>"
  echo "  检查 docs/原型/<feature>-原型确认.md（兼容历史 docs/demo/<feature>-demo-signoff.md）（3-5 个 KUF walkthrough，含签字人+日期）"
  exit 2
fi
# v3.15.5: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 写穿项目外）与 grep -E 正则注入
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# v3.22.0: 文档层中文化（中文优先、英文回退）
source "$(cd "$(dirname "$0")" && pwd)/devflow_paths.sh"
# v3.30.0: Gate JSON 强制（demo-signoff 正本——需 py_runtime + 强制库）
source "$(cd "$(dirname "$0")" && pwd)/py_runtime.sh"
source "$(cd "$(dirname "$0")" && pwd)/gate_json_lib.sh"
# shellcheck disable=SC2034  # GJ_SKILL 由 gate_json_lib 函数消费
GJ_SKILL="$(cd "$(dirname "$0")/.." && pwd)"
devflow_feature_validate "$FEATURE" || exit 2

FAIL=0; PASS=0; WARN=0
pass() { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
REPORT_DIR="${STATE_DIR:-.devflow}/${FEATURE}"; mkdir -p "$REPORT_DIR"
signoff="$(df_resolve_doc "$FEATURE" demo_signoff .md demo)"
[ -n "$signoff" ] || signoff="docs/demo/${FEATURE}-demo-signoff.md"

echo ""; echo "=== P2b Demo Gate ==="

# ---------- v3.14.6: 用户显式授权跳过（skip-log.txt 契约） ----------
SKIP_LOG="${STATE_DIR:-.devflow}/${FEATURE}/skip-log.txt"
# v3.14.6: 跳过行必须含授权人（authorized-by=）——防无人授权的静默跳过
SKIP_LINE=$(grep -E '^SKIP_P2b=' "$SKIP_LOG" 2>/dev/null | head -1)
# v3.14.11: 跳过必须同时满足：理由非空 | 授权人非空 | 授权时间合法 | 审批证据非空
_skip_ok=0; SKIP_REASON=""; SKIP_BY=""; SKIP_AT=""; SKIP_EVID=""
if [ -n "$SKIP_LINE" ]; then
  # v3.14.11: 理由以 | 分隔提取并显式判空——空理由（SKIP_P2b=|...）不得整行回传
  if echo "$SKIP_LINE" | grep -qE '^SKIP_P2b=[^|]'; then
    SKIP_REASON=$(echo "$SKIP_LINE" | cut -d'|' -f1 | sed 's/^SKIP_P2b=//')
  else
    SKIP_REASON=""
  fi
  SKIP_BY=$(echo "$SKIP_LINE" | grep -oE 'authorized-by=[^|]*' | cut -d= -f2)
  SKIP_AT=$(echo "$SKIP_LINE" | grep -oE 'at=[^|]*' | cut -d= -f2)
  SKIP_EVID=$(echo "$SKIP_LINE" | grep -oE 'approval=[^|]*' | cut -d= -f2)
  if [ -n "$SKIP_REASON" ] && [ -n "${SKIP_BY//[[:space:]]/}" ] \
     && echo "$SKIP_AT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2})?' \
     && [ -n "${SKIP_EVID//[[:space:]]/}" ]; then
    _skip_ok=1
  fi
fi
if [ "$_skip_ok" = "1" ]; then
  pass "用户显式授权跳过 P2b：${SKIP_REASON}（authorized-by=${SKIP_BY}, at=${SKIP_AT}, approval=${SKIP_EVID}）"
  WARN=$((WARN+1))
  EXIT_CODE=0
  RECEIPT_DIR="$REPORT_DIR/gates/P2b"
  mkdir -p "$RECEIPT_DIR"
  {
    echo "EXIT_CODE=0"
    echo "VERSION=p2b@$(bash "$(dirname "$0")/gate-version.sh")"
    echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "PHASE=P2b"
  printf '%s' "$GJ_BIND"
    echo "SKIPPED=1"
    echo "SKIP_REASON=$SKIP_REASON"
    echo "AUTHORIZED_BY=${SKIP_BY:-}"
    echo "AUTHORIZED_AT=${SKIP_AT:-}"
    echo "APPROVAL_EVIDENCE=${SKIP_EVID:-}"
    echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
    echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$RECEIPT_DIR/receipt.txt" 2>/dev/null
  DOCS_MIRROR="docs/${FEATURE}/gates/P2b"
  mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"
  echo "[RECEIPT] Generated (skipped): $RECEIPT_DIR/receipt.txt"
  echo "P2b RESULT: SKIPPED（用户授权）"
  exit 0
fi

if [ ! -f "$signoff" ]; then
  fail "缺失: $signoff"
  echo "       产物要求：≥3 个关键用户旅程（KUF）walkthrough 记录 + 原型文件引用 + PO 结论 + 签字人/日期"
else
  # v3.14.6: KUF ≥3、走查路径、原型文件、PO 结论、签字人、日期 全部实质校验
  # v3.14.6: 按唯一编号计数，重复 KUF-1 不再凑数
  KUF_UNIQUE=$(grep -oE 'KUF-[0-9]+' "$signoff" 2>/dev/null | sort -u)
  KUF_COUNT=$(printf '%s\n' "$KUF_UNIQUE" | grep -c . || true)
  PO_SIGN=$(grep -E '(PO|产品负责人|产品 Owner).{0,24}' "$signoff" 2>/dev/null | grep -cvE '不通过|驳回|❌|待确认|待定|未确认|进行中' || true)
  SIGNERS=$(grep -cE '签字[人：:]|签名|Reviewer|Sign-off|签署' "$signoff" 2>/dev/null || true)
  HAS_DATE=$(grep -cE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$signoff" 2>/dev/null || true)

  [ "${KUF_COUNT:-0}" -ge 3 ] && pass "KUF 唯一数量 ${KUF_COUNT} (>= 3)" \
    || fail "KUF 唯一数量 ${KUF_COUNT} < 3（关键用户旅程须逐条列出 KUF-1..N，重复编号不计）"

  # v3.14.6: 每个唯一 KUF 都须有对应走查记录
  MISSING_WALK=""
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    if ! grep -qE "$k.{0,80}(walkthrough|走查)" "$signoff" 2>/dev/null; then
      MISSING_WALK="$MISSING_WALK $k"
    fi
  done <<< "$KUF_UNIQUE"
  [ -z "$MISSING_WALK" ] && pass "每个 KUF 均有 walkthrough" \
    || fail "以下 KUF 缺少 walkthrough:$MISSING_WALK"
  PROTO_HITS=""
  # v3.22.0: 原型引用路径中英目录都接受（docs/原型、docs/demo）
  for pf in $(grep -oE 'docs/(原型|demo)/[^[:space:])）]+' "$signoff" 2>/dev/null | sort -u); do
    [ -f "$pf" ] && PROTO_HITS="$PROTO_HITS ✓$(basename "$pf")"
  done
  if [ -n "$PROTO_HITS" ]; then
    pass "原型文件实存:${PROTO_HITS}"
  else
    fail "sign-off 引用的原型文件均不存在于 docs/原型/（或历史 docs/demo/）"
  fi
  [ "${PO_SIGN:-0}" -ge 1 ] && pass "PO 结论确认" || fail "缺少 PO（产品负责人）明确结论"
  [ "${SIGNERS:-0}" -ge 1 ] && [ "${HAS_DATE:-0}" -ge 1 ] && pass "签字人与日期齐备" \
    || fail "签字人或日期缺失"
fi

# ---------- 收据（双写 .devflow + docs 镜像） ----------
STATE_DIR="${STATE_DIR:-.devflow}"
# v3.30.0: demo-signoff JSON 正本强制
gj_enforce demo-signoff || { echo "P2b RESULT: demo-signoff JSON 正本未通过"; exit 1; }
RECEIPT_DIR="$STATE_DIR/${FEATURE}/gates/P2b"
mkdir -p "$RECEIPT_DIR" 2>/dev/null
EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "VERSION=p2b@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "PHASE=P2b"
  echo "ARTIFACTS=$signoff"
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt" 2>/dev/null
echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
DOCS_MIRROR="docs/${FEATURE}/gates/P2b"
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"

echo "P2b RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
