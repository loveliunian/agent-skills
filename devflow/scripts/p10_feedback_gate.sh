#!/usr/bin/env bash
# P10 closes project feedback without mutating the installed skill · 版本随 SKILL.md
set -uo pipefail

FEATURE="${1:-}"
[ -n "$FEATURE" ] || { echo "Usage: $0 <feature>"; exit 2; }
# v3.15.4→v3.15.5: feature 名白名单升级为共享函数（devflow_feature.sh）——路径穿越（../../evil 写穿项目外）封堵
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# v3.22.0: 文档层中文化（中文优先、英文回退）
source "$(cd "$(dirname "$0")" && pwd)/devflow_paths.sh"
# v3.30.0: Gate JSON 强制（retrospective + sharing 双正本）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/py_runtime.sh"
source "$SCRIPT_DIR/gate_json_lib.sh"
# shellcheck disable=SC2034  # GJ_SKILL 由 gate_json_lib 函数消费
GJ_SKILL="$(cd "$SCRIPT_DIR/.." && pwd)"
devflow_feature_validate "$FEATURE" || exit 2

# v3.15.5: STATE_DIR 前置——FEEDBACK 此前写死 .devflow/，隔离部署（STATE_DIR 自定义）下
# 读错目录（误报 feedback missing）且收据与 state 读取口径分裂。
STATE_DIR="${STATE_DIR:-.devflow}"
# v3.22.0: 复盘/知识分享 中文优先、英文回退
RETRO="$(df_resolve_doc "$FEATURE" retro .md retro)"
[ -n "$RETRO" ] || RETRO="docs/复盘/${FEATURE}-复盘报告.md"
KNOWLEDGE="$(df_resolve_doc "$FEATURE" sharing .md knowledge)"
[ -n "$KNOWLEDGE" ] || KNOWLEDGE="docs/知识沉淀/${FEATURE}-知识分享.md"
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

# v3.28.4(P1-10)：知识分享是人类仪式检查项——显式 not-applicable 出口（skip-log 契约，
# 与 P2b/P2a/P3CD 同格式：SKIP_P10_SHARING=理由|authorized-by=授权人|at=日期|approval=审批证据）
P10_NA_LINE=$(grep -E '^SKIP_P10_SHARING=' "${STATE_DIR}/${FEATURE}/skip-log.txt" 2>/dev/null | head -1)
if [ -f "$KNOWLEDGE" ]; then
  lesson_count=$(grep -cE '^[[:space:]]*-[[:space:]]+' "$KNOWLEDGE" 2>/dev/null || true)
  [ "$lesson_count" -ge 3 ] && pass "knowledge sharing has >=3 lessons" || fail "knowledge sharing has <3 lessons"
elif [ -n "$P10_NA_LINE" ]; then
  NA_REASON=$(echo "$P10_NA_LINE" | cut -d'|' -f1 | sed 's/^SKIP_P10_SHARING=//')
  NA_BY=$(echo "$P10_NA_LINE" | grep -oE 'authorized-by=[^|]*' | cut -d= -f2)
  NA_AT=$(echo "$P10_NA_LINE" | grep -oE 'at=[^|]*' | cut -d= -f2)
  NA_EVID=$(echo "$P10_NA_LINE" | grep -oE 'approval=[^|]*' | cut -d= -f2)
  if [ -n "$NA_REASON" ] && [ -n "${NA_BY//[[:space:]]/}" ] \
     && echo "$NA_AT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2})?' \
     && [ -n "${NA_EVID//[[:space:]]/}" ]; then
    pass "knowledge sharing not-applicable（authorized-by=${NA_BY}, at=${NA_AT}, approval=${NA_EVID}）"
  else
    fail "SKIP_P10_SHARING 授权行不完整（须含 理由|authorized-by=|at=YYYY-MM-DD|approval=）"
  fi
else
  fail "knowledge sharing missing: ${KNOWLEDGE}（单人/AI 场景可用 skip-log 显式声明 not-applicable：SKIP_P10_SHARING=理由|authorized-by=|at=|approval=）"
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

# v3.26.3: L-MON-003 入检——P10 复盘前必须跑孤岛产物检测，报告留痕
# （.devflow/<feature>/orphans-report.txt）；关键产物缺失（✗ 行）即 FAIL。
ORPHANS_REPORT="$STATE_DIR/${FEATURE}/orphans-report.txt"
if bash "$(cd "$(dirname "$0")" && pwd)/checkpoint-state.sh" orphans "$FEATURE" > "$ORPHANS_REPORT" 2>&1; then
  # v3.26.3: grep -c 无命中时输出 0 且退出 1——不可用 "|| echo 0" 兜底（会追加第二行
  # 非数字，-gt 比较即 "integer expression expected"）；空值兜底用 ${x:-0}。
  ORPHAN_MISSING=$(grep -c '✗' "$ORPHANS_REPORT" 2>/dev/null)
  ORPHAN_MISSING=${ORPHAN_MISSING:-0}
  case "$ORPHAN_MISSING" in ''|*[!0-9]*) ORPHAN_MISSING=0 ;; esac
  if [ "${ORPHAN_MISSING}" -gt 0 ]; then
    fail "orphans 检测发现 ${ORPHAN_MISSING} 处关键产物缺失（报告: ${ORPHANS_REPORT}）"
  else
    pass "orphans 检测通过（报告: ${ORPHANS_REPORT}）"
  fi
else
  fail "orphans 检测执行失败（checkpoint-state.sh orphans ${FEATURE}）"
fi

RECEIPT_DIR="$STATE_DIR/${FEATURE}/gates/P10"
# v3.30.0: 双 JSON 正本强制（sharing 的 not-applicable 是其 JSON 内声明，不免除正本存在）
gj_enforce retrospective || { echo "[P0] retrospective JSON 正本未通过"; exit 1; }
gj_enforce sharing || { echo "[P0] sharing JSON 正本未通过"; exit 1; }
mkdir -p "$RECEIPT_DIR"
EXIT_CODE=$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "PHASE=P10"
  printf '%s' "$GJ_BIND"
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
