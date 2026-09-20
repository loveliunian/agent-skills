#!/usr/bin/env bash
# P4 PRD validation gate. P4b remains the separate exact PRD-vs-Code gate.
# P4 evidence is executable: report text alone must never self-certify PASS.
set -uo pipefail

FEATURE="${1:-}"
REPORT="${2:-}"
[ -n "$FEATURE" ] || { echo "Usage: $0 <feature> [validation-report]"; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "$SCRIPT_DIR/devflow_feature.sh"
source "$SCRIPT_DIR/devflow_receipt.sh"
# v3.22.0: 文档层中文化（中文优先、英文回退）
source "$SCRIPT_DIR/devflow_paths.sh"
devflow_feature_validate "$FEATURE" || exit 2

WORKSPACE="${WORKSPACE:-$PWD}"
cd "$WORKSPACE" || { echo "[P0] workspace unavailable: $WORKSPACE"; exit 2; }
if [ -z "$REPORT" ]; then
  REPORT="$(df_resolve_doc "$FEATURE" validation_report .md test)"
  [ -n "$REPORT" ] || REPORT="docs/测试/${FEATURE}-PRD验证报告.md"
fi
STATE_DIR="${STATE_DIR:-.devflow}"
RECEIPT_DIR="$STATE_DIR/${FEATURE}/gates/P4"
EXEC_DIR="$STATE_DIR/${FEATURE}/test-executions"
EXEC_LOG="$EXEC_DIR/p4-validation.log"
CRITERIA="$(df_resolve_doc "$FEATURE" acceptance .md requirements)"
[ -n "$CRITERIA" ] || CRITERIA="docs/需求/${FEATURE}-验收点.md"

PASS=0; FAIL=0
P4_STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
p0() { echo "[P0] $*"; FAIL=$((FAIL + 1)); }
field() { sed -n "s/^$1=//p" "$REPORT" 2>/dev/null | head -1; }

P4_CMD=""; RESULTS_PATH=""; EVIDENCE_PATH=""
if [ ! -f "$REPORT" ]; then
  p0 "validation report missing: $REPORT"
else
  pass "validation report exists"
  grep -qx 'P0_BLOCKERS=0' "$REPORT" && pass "P0 blockers are closed" || p0 "report must declare P0_BLOCKERS=0"
  P4_CMD=$(field P4_CMD)
  RESULTS_PATH=$(field P4_RESULTS_PATH)
  EVIDENCE_PATH=$(field VALIDATION_EVIDENCE)
  [ -n "$P4_CMD" ] || p0 "P4_CMD missing: Gate must execute the validation command"
  [ -n "$RESULTS_PATH" ] || p0 "P4_RESULTS_PATH missing: require ID<TAB>STATUS results"
  [ -n "$EVIDENCE_PATH" ] || p0 "VALIDATION_EVIDENCE missing"
fi

is_trusted_command() {
  local command="$1" first
  case "$command" in *'`'*|*'$('*|*';'*|*'&&'*|*'||'*|*'|'*|*'<'*|*'>'*) return 1 ;; esac
  first=$(printf '%s' "$command" | awk '{print $1}')
  case "$first" in
    ./scripts/*) [ -x "$first" ] && return 0 ;;
    mvn|mvnw|./mvnw|gradle|./gradlew|npm|pnpm|yarn|pytest|python|python3|go|cargo|make|dotnet|flutter) return 0 ;;
  esac
  return 1
}

if [ -n "$P4_CMD" ] && [ "$FAIL" -eq 0 ]; then
  if ! is_trusted_command "$P4_CMD"; then
    p0 "P4_CMD is not a direct trusted validation runner (P4_CMD_PROVENANCE): $P4_CMD"
  else
    mkdir -p "$EXEC_DIR" || p0 "cannot create P4 execution directory: $EXEC_DIR"
    TMP_LOG=$(mktemp "${TMPDIR:-/tmp}/devflow-p4.XXXXXX" 2>/dev/null || true)
    [ -n "$TMP_LOG" ] || p0 "cannot create isolated P4 capture"
    if [ -n "${TMP_LOG:-}" ]; then
      bash -c "$P4_CMD" > "$TMP_LOG" 2>&1
      P4_CMD_EXIT=$?
      mv "$TMP_LOG" "$EXEC_LOG" || p0 "cannot retain P4 execution capture: $EXEC_LOG"
      [ "$P4_CMD_EXIT" -eq 0 ] && pass "P4 command executed with exit=0" || p0 "P4 command failed: exit=$P4_CMD_EXIT"
      [ -s "$EXEC_LOG" ] && pass "P4 execution capture is non-empty" || p0 "P4 execution capture is empty (P4_EXECUTION_LOG_EMPTY)"
    fi
  fi
fi

if [ -n "$EVIDENCE_PATH" ]; then
  EVIDENCE_RESOLVED=$(_receipt_norm_file "$EVIDENCE_PATH" 2>/dev/null || true)
  [ -n "$EVIDENCE_RESOLVED" ] && [ -f "$EVIDENCE_RESOLVED" ] && pass "raw validation evidence exists" || p0 "VALIDATION_EVIDENCE must resolve inside workspace: $EVIDENCE_PATH"
  # v3.28.1(FB-20260919-001): 证据快照解耦——P6-final 重跑测试会改写 target/ 下的
  # surefire 报告，活文件绑定曾使 P4 证据树在下游 gate 重跑后连锁失效（P4↔P6 互踩）。
  # 绑定 .devflow/<feature>/p4-evidence/ 下的隔离副本。
  if [ -n "$EVIDENCE_RESOLVED" ] && [ -f "$EVIDENCE_RESOLVED" ]; then
    EV_SNAP_DIR="$STATE_DIR/${FEATURE}/p4-evidence"
    mkdir -p "$EV_SNAP_DIR" 2>/dev/null || true
    EV_SNAP="$EV_SNAP_DIR/$(basename "$EVIDENCE_RESOLVED")"
    if cp "$EVIDENCE_RESOLVED" "$EV_SNAP" 2>/dev/null; then
      EVIDENCE_PATH="$EV_SNAP"
      pass "validation evidence snapshotted to ${EV_SNAP}（与 target/ 解耦）"
    fi
  fi
fi

TMP_IDS=$(mktemp "${TMPDIR:-/tmp}/devflow-p4-ids.XXXXXX" 2>/dev/null || true)
TMP_RESULTS=$(mktemp "${TMPDIR:-/tmp}/devflow-p4-results.XXXXXX" 2>/dev/null || true)
cleanup() { rm -f "${TMP_IDS:-}" "${TMP_RESULTS:-}"; }
trap cleanup EXIT
if [ ! -f "$CRITERIA" ]; then
  p0 "frozen acceptance criteria missing: $CRITERIA"
elif [ -z "$TMP_IDS" ] || [ -z "$TMP_RESULTS" ]; then
  p0 "cannot create P4 acceptance comparison files"
elif [ -n "$RESULTS_PATH" ]; then
  RESULTS_RESOLVED=$(_receipt_norm_file "$RESULTS_PATH" 2>/dev/null || true)
  if [ -z "$RESULTS_RESOLVED" ] || [ ! -f "$RESULTS_RESOLVED" ]; then
    p0 "P4_RESULTS_PATH must resolve to a generated workspace file: $RESULTS_PATH"
  elif [ ! -s "$RESULTS_RESOLVED" ]; then
    p0 "P4 results are empty: $RESULTS_PATH"
  elif ! head -1 "$RESULTS_RESOLVED" 2>/dev/null | grep -qE '^(ID	STATUS|acceptance_id	(	code_paths	test_paths	status)?)'; then
    # v3.27.5（FB-20260918-003）：统一接受两种表头——2 列（ID/STATUS，p4 专用）
    # 与 4 列（acceptance_id/code_paths/test_paths/status，与 p4b --evidence 共用一份），
    # 消除"同文件两门格式冲突"（M-01 实测返工点）。
    p0 "P4 results header must be ID<TAB>STATUS or acceptance_id<TAB>code_paths<TAB>test_paths<TAB>status: $RESULTS_PATH"
  else
    grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$CRITERIA" | sort -u > "$TMP_IDS"
    awk -F '\t' 'NR > 1 && NF >= 2 {print $1}' "$RESULTS_RESOLVED" | sort > "$TMP_RESULTS"
    EXPECTED_COUNT=$(grep -c . "$TMP_IDS" 2>/dev/null || true)
    [ "$EXPECTED_COUNT" -gt 0 ] || p0 "frozen acceptance criteria contains no atomic IDs"
    DUPLICATES=$(uniq -d "$TMP_RESULTS" | tr '\n' ' ')
    [ -z "$DUPLICATES" ] || p0 "P4 results contain duplicate IDs: $DUPLICATES"
    if ! diff -u "$TMP_IDS" <(sort -u "$TMP_RESULTS") >/dev/null 2>&1; then p0 "P4 result ID set differs from frozen criteria (P4_ACCEPTANCE_SET_MISMATCH)"; else pass "P4 result ID set equals frozen criteria ($EXPECTED_COUNT IDs)"; fi
    # 状态列：2 列格式取 $2，4 列格式取 $4（code_paths 内不含制表符）
    BAD_ROWS=$(awk -F '\t' 'NR > 1 && $NF != "PASS" {print $1 "=" $NF}' "$RESULTS_RESOLVED" | tr '\n' ' ')
    [ -z "$BAD_ROWS" ] && pass "all P4 acceptance rows PASS" || p0 "P4 acceptance has non-PASS/invalid rows (P4_ACCEPTANCE_FAIL): $BAD_ROWS"
  fi
fi

mkdir -p "$RECEIPT_DIR" "docs/${FEATURE}/gates/P4" || { echo "[P0] cannot create P4 receipt directories"; exit 2; }
P4_FINISHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EXIT_CODE=$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
EVIDENCE_PATHS_JSON="[]"; EVIDENCE_TREE_SHA256=""
if [ "$EXIT_CODE" = 0 ]; then
  EV_FILES=("$REPORT" "$EVIDENCE_PATH" "$RESULTS_PATH" "$EXEC_LOG")
  EVIDENCE_TREE_SHA256=$(receipt_evidence_tree "${EV_FILES[@]}" 2>/dev/null || true)
  if command -v jq >/dev/null 2>&1; then EVIDENCE_PATHS_JSON=$(printf '%s\n' "${EV_FILES[@]}" | jq -R . | jq -sc . 2>/dev/null || echo '[]'); fi
  [ -n "$EVIDENCE_TREE_SHA256" ] && [ "$EVIDENCE_PATHS_JSON" != '[]' ] || { p0 "cannot create P4 evidence tree"; EXIT_CODE=1; }
fi
{
  echo "COMMAND=p4_validation_gate.sh $FEATURE"; echo "EXIT_CODE=$EXIT_CODE"; echo "PHASE=P4"
  echo "VERSION=p4-validation@$(bash "$SCRIPT_DIR/gate-version.sh")"; echo "SKILL_TREE=$(bash "$SCRIPT_DIR/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "REPORT=$REPORT"; echo "P4_CMD=$P4_CMD"; echo "P4_RESULTS_PATH=$RESULTS_PATH"
  echo "EVIDENCE_PATHS_JSON=$EVIDENCE_PATHS_JSON"; echo "EVIDENCE_TREE_SHA256=$EVIDENCE_TREE_SHA256"
  echo "PRODUCER_ROLE=validation-gate"; echo "STARTED_AT=$P4_STARTED_AT"; echo "FINISHED_AT=$P4_FINISHED_AT"; echo "PASS=$PASS FAIL=$FAIL"
} > "$RECEIPT_DIR/receipt.txt"
cp "$RECEIPT_DIR/receipt.txt" "docs/${FEATURE}/gates/P4/receipt.txt"
echo "P4 VALIDATION GATE: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
