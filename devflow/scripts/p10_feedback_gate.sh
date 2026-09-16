#!/usr/bin/env bash
# P10 closes project feedback without mutating the installed skill · 版本随 SKILL.md
set -uo pipefail

FEATURE="${1:-}"
[ -n "$FEATURE" ] || { echo "Usage: $0 <feature>"; exit 2; }
# v3.15.4→v3.15.5: feature 名白名单升级为共享函数（devflow_feature.sh）——路径穿越（../../evil 写穿项目外）封堵
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
devflow_feature_validate "$FEATURE" || exit 2

# v3.15.5: STATE_DIR 前置——FEEDBACK 此前写死 .devflow/，隔离部署（STATE_DIR 自定义）下
# 读错目录（误报 feedback missing）且收据与 state 读取口径分裂。
STATE_DIR="${STATE_DIR:-.devflow}"
RETRO="docs/retrospectives/${FEATURE}-retro.md"
KNOWLEDGE="docs/knowledge/${FEATURE}-sharing.md"
FEEDBACK="${STATE_DIR}/${FEATURE}/feedback/feedback.md"
PASS=0
FAIL=0

pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
hash_file() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

if [ -f "$RETRO" ]; then
  grep -q '^## 上次遗漏了什么' "$RETRO" && pass "retro has prior-gap section" || fail "retro lacks prior-gap section"
  grep -q '^## 本次新发现' "$RETRO" && pass "retro has new-findings section" || fail "retro lacks new-findings section"
else
  fail "retro missing: $RETRO"
fi

if [ -f "$KNOWLEDGE" ]; then
  lesson_count=$(grep -cE '^[[:space:]]*-[[:space:]]+' "$KNOWLEDGE" 2>/dev/null || true)
  [ "$lesson_count" -ge 3 ] && pass "knowledge sharing has >=3 lessons" || fail "knowledge sharing has <3 lessons"
else
  fail "knowledge sharing missing: $KNOWLEDGE"
fi

if [ -f "$FEEDBACK" ]; then
  grep -q '^FEEDBACK_ID=' "$FEEDBACK" && pass "feedback has identifier" || fail "feedback lacks FEEDBACK_ID"
  grep -q '^SCOPE=project$' "$FEEDBACK" && pass "feedback remains project-local" || fail "feedback scope must be project"
  grep -qE '^STATUS=(PROPOSED|ACCEPTED)$' "$FEEDBACK" && pass "feedback has review status" || fail "feedback status must be PROPOSED or ACCEPTED"
  # v3.14.6: 根因与处理决定字段
  grep -qE '^ROOT_CAUSE=.+' "$FEEDBACK" && pass "root cause documented" || fail "feedback lacks ROOT_CAUSE"
  grep -qE '^TARGET_FILES?=(.+,)*.+' "$FEEDBACK" && pass "target files listed" || fail "feedback lacks TARGET_FILES"
  grep -qE '^DECISION=(fix|defer)' "$FEEDBACK" && pass "decision recorded" || fail "feedback lacks DECISION (fix|defer)"
  if grep -qE '^DECISION=defer' "$FEEDBACK"; then
    grep -qE '^DEFER_REASON=.+' "$FEEDBACK" && pass "defer reason documented" || fail "DEFER requires DEFER_REASON"
  fi
else
  fail "project feedback missing: $FEEDBACK"
fi

# v3.15.4: s8b 应用收据闭环校验——STATUS=APPLIED 悬挂 = apply 后未跑 verify（文档声称的硬门禁落地）
S8B_APPLY_RECEIPT="$STATE_DIR/${FEATURE}/s8b/s8b-apply-receipt.env"
if [ -f "$S8B_APPLY_RECEIPT" ]; then
  s8b_status=$(sed -n 's/^STATUS=//p' "$S8B_APPLY_RECEIPT" | head -1)
  if [ "$s8b_status" = "APPLIED" ]; then
    fail "s8b apply receipt dangling: STATUS=APPLIED（apply 后未完成 verify 闭环——先运行 s8b --verify）"
  else
    pass "s8b apply receipt closed: STATUS=${s8b_status:-empty}"
  fi
fi

RECEIPT_DIR="$STATE_DIR/${FEATURE}/gates/P10"
mkdir -p "$RECEIPT_DIR"
EXIT_CODE=$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "PHASE=P10"
  echo "VERSION=p10-feedback@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "RETRO=$RETRO"
  echo "KNOWLEDGE=$KNOWLEDGE"
  echo "FEEDBACK=$FEEDBACK"
  echo "EVIDENCE_PATH=$FEEDBACK"
  # v3.15.5: 与 artifact_gate 同语义——证据缺失输出 missing（空串会被误读为"未声明"）
  echo "EVIDENCE_SHA256=$([ -f "$FEEDBACK" ] && hash_file "$FEEDBACK" || echo missing)"
  echo "PASS=$PASS FAIL=$FAIL"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt"
mkdir -p "docs/${FEATURE}/gates/P10" && cp "$RECEIPT_DIR/receipt.txt" "docs/${FEATURE}/gates/P10/receipt.txt"

echo "P10 FEEDBACK GATE: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
