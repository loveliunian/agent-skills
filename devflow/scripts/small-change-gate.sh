#!/usr/bin/env bash
# small-change-gate.sh · controlled fast path for one bounded existing-project change
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
source "$SCRIPT_DIR/devflow_feature.sh"
source "$SCRIPT_DIR/devflow_receipt.sh"

MODE="${1:-}"
CHANGE_ID="${2:-}"
CONTRACT="${3:-}"
[ "$MODE" = classify ] || [ "$MODE" = verify ] || { echo "Usage: $0 classify|verify <change-id> [contract]"; exit 2; }
devflow_feature_validate "$CHANGE_ID" || exit 2
CONTRACT="${CONTRACT:-${STATE_DIR:-.devflow}/$CHANGE_ID/small-change.env}"
[ -f "$CONTRACT" ] || { echo "[P0] small-change contract missing: $CONTRACT"; exit 1; }

value() { sed -n "s/^$1=//p" "$CONTRACT" 2>/dev/null | head -1; }
fail() { echo "[P0] $*"; FAIL=$((FAIL + 1)); }
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
sha_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else return 1; fi
}

workspace_file() {
  local path="$1" label="$2" resolved base
  base=$(_receipt_ws_base)
  resolved=$(_receipt_norm_file "$path" 2>/dev/null || true)
  if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
    fail "$label missing/unresolvable: $path"
    return 1
  fi
  case "$resolved" in
    "$base"|"$base"/*) return 0 ;;
    *) fail "$label 路径越界（必须在 workspace 内）: $path"; return 1 ;;
  esac
}

is_shell_wrapper() {
  printf '%s' "$1" | grep -qE '(^|[[:space:];|&()])([^[:space:];|&()]*/)?(bash|sh|zsh|env|command|exec)([[:space:];|&()]|$)'
}

FAIL=0; PASS=0
GATE_STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
workspace_file "$CONTRACT" CONTRACT || true
for key in CHANGE_KIND CHANGE_SUBJECT LOGICAL_CHANGE_COUNT TARGET SURFACES PROJECT_SCAN_EVIDENCE CHANGE_REPORT AFFECTED_PATHS BREAKING_API TYPE_OR_NULLABILITY_BREAKING PERMISSION_CHANGE STATE_MACHINE_CHANGE CROSS_SERVICE_CHANGE NEW_TABLE_OR_SERVICE LARGE_BACKFILL MIGRATION_REQUIRED DIALECTS VERIFY_CMD MIGRATION_VERIFY_CMD DEPLOY_RECEIPT_PATH MONITOR_RECEIPT_PATH DECISION DECISION_REASON; do
  key_count=$(grep -c "^${key}=" "$CONTRACT" 2>/dev/null || true)
  [ "$key_count" -le 1 ] || fail "duplicate key: $key"
done
CHANGE_KIND=$(value CHANGE_KIND)
CHANGE_SUBJECT=$(value CHANGE_SUBJECT)
LOGICAL_CHANGE_COUNT=$(value LOGICAL_CHANGE_COUNT)
TARGET=$(value TARGET)
SURFACES=$(value SURFACES)
PROJECT_SCAN_EVIDENCE=$(value PROJECT_SCAN_EVIDENCE)
CHANGE_REPORT=$(value CHANGE_REPORT)
AFFECTED_PATHS=$(value AFFECTED_PATHS)
MIGRATION_REQUIRED=$(value MIGRATION_REQUIRED)
DIALECTS=$(value DIALECTS)
VERIFY_CMD=$(value VERIFY_CMD)
MIGRATION_VERIFY_CMD=$(value MIGRATION_VERIFY_CMD)
DECLARED_DECISION=$(value DECISION)
DECISION_REASON=$(value DECISION_REASON)

for key in CHANGE_KIND CHANGE_SUBJECT LOGICAL_CHANGE_COUNT TARGET SURFACES PROJECT_SCAN_EVIDENCE CHANGE_REPORT AFFECTED_PATHS MIGRATION_REQUIRED DECISION DECISION_REASON; do
  [ -n "$(value "$key")" ] || fail "$key missing"
done
case "$TARGET" in merge-ready|released) ;; *) fail "TARGET must be merge-ready|released" ;; esac
case "$MIGRATION_REQUIRED" in 0|1) ;; *) fail "MIGRATION_REQUIRED must be 0|1" ;; esac
for surface in $(printf '%s' "$SURFACES" | tr ',' ' '); do
  case "$surface" in ui|api|persistence|validation|config) ;; *) fail "unsupported SURFACES item: $surface" ;; esac
done

PROJECT_RISK=0; PROJECT_HITS=0
if workspace_file "$PROJECT_SCAN_EVIDENCE" PROJECT_SCAN_EVIDENCE; then
  [ "$(wc -c < "$PROJECT_SCAN_EVIDENCE" | tr -d ' ')" -ge 32 ] || fail "PROJECT_SCAN_EVIDENCE too small"
  grep -qF "$CHANGE_SUBJECT" "$PROJECT_SCAN_EVIDENCE" || fail "PROJECT_SCAN_EVIDENCE does not mention CHANGE_SUBJECT=$CHANGE_SUBJECT"
  for scan_key in SCAN_DB SCAN_DOMAIN SCAN_API SCAN_CLIENT SCAN_CONFIG SCAN_TEST SCAN_PERMISSION SCAN_WORKFLOW SCAN_CROSS_SERVICE SCAN_HISTORY_DATA; do
    scan_count=$(grep -c "^${scan_key}=" "$PROJECT_SCAN_EVIDENCE" 2>/dev/null || true)
    scan_value=$(sed -n "s/^${scan_key}=//p" "$PROJECT_SCAN_EVIDENCE" | head -1)
    [ "$scan_count" -eq 1 ] || fail "$scan_key must appear exactly once in project scan"
    case "$scan_value" in HIT|MISS|NA) ;; *) fail "$scan_key must be HIT|MISS|NA" ;; esac
    [ "$scan_value" = HIT ] && PROJECT_HITS=$((PROJECT_HITS + 1))
    case "$scan_key:$scan_value" in
      SCAN_PERMISSION:HIT|SCAN_WORKFLOW:HIT|SCAN_CROSS_SERVICE:HIT|SCAN_HISTORY_DATA:HIT) PROJECT_RISK=1 ;;
    esac
  done
  [ "$PROJECT_HITS" -gt 0 ] || fail "project scan found no change-relevant references"
fi

RISK=$PROJECT_RISK
case "$LOGICAL_CHANGE_COUNT" in ''|*[!0-9]*) fail "LOGICAL_CHANGE_COUNT must be a positive integer" ;; 1) ;; *) RISK=1 ;; esac
for flag in BREAKING_API TYPE_OR_NULLABILITY_BREAKING PERMISSION_CHANGE STATE_MACHINE_CHANGE CROSS_SERVICE_CHANGE NEW_TABLE_OR_SERVICE LARGE_BACKFILL; do
  flag_value=$(value "$flag")
  case "$flag_value" in
    0) ;;
    1) RISK=1 ;;
    *) fail "$flag must be 0|1" ;;
  esac
done

case "$CHANGE_KIND" in
  ui-copy|ui-behavior|bugfix|additive-api|additive-persistence|validation-default|config) COMPUTED_DECISION=MICRO ;;
  breaking-api|schema-breaking|permission|state-machine|cross-service|new-module-service|large-backfill|multi-change) COMPUTED_DECISION=FULL ;;
  *) fail "unsupported CHANGE_KIND: ${CHANGE_KIND:-<empty>}"; COMPUTED_DECISION=FULL ;;
esac
[ "$RISK" -eq 0 ] || COMPUTED_DECISION=FULL

has_surface() { case ",$SURFACES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
case "$CHANGE_KIND" in
  ui-copy|ui-behavior) has_surface ui || fail "$CHANGE_KIND requires SURFACES=ui" ;;
  additive-api) has_surface api || fail "additive-api requires api surface" ;;
  additive-persistence) has_surface persistence || fail "additive-persistence requires persistence surface" ;;
  config) has_surface config || fail "config requires config surface" ;;
esac
if has_surface persistence; then
  [ "$MIGRATION_REQUIRED" = 1 ] || fail "persistence surface requires MIGRATION_REQUIRED=1"
  [ "$DIALECTS" = "h2,postgresql,oracle,kingbase" ] || fail "DIALECTS must be h2,postgresql,oracle,kingbase"
elif [ "$MIGRATION_REQUIRED" = 1 ]; then
  fail "MIGRATION_REQUIRED=1 requires persistence surface"
fi

if [ "$CHANGE_KIND" = additive-persistence ]; then
  [ "$MIGRATION_REQUIRED" = 1 ] || fail "additive-persistence requires MIGRATION_REQUIRED=1"
  [ "$DIALECTS" = "h2,postgresql,oracle,kingbase" ] || fail "DIALECTS must be h2,postgresql,oracle,kingbase"
fi
if [ "$COMPUTED_DECISION" = MICRO ] && [ "$DECLARED_DECISION" != MICRO ]; then
  fail "declared DECISION=$DECLARED_DECISION but project facts classify MICRO"
elif [ "$COMPUTED_DECISION" = FULL ] && [ "$DECLARED_DECISION" != FULL ]; then
  fail "declared DECISION=$DECLARED_DECISION but risk facts require FULL"
fi

if [ "$FAIL" -gt 0 ]; then
  echo "SMALL-CHANGE CLASSIFICATION: FAIL"
  exit 1
fi

echo "DECISION=$COMPUTED_DECISION"
echo "CHANGE_SUBJECT=$CHANGE_SUBJECT"
echo "SURFACES=$SURFACES"
if [ "$COMPUTED_DECISION" = FULL ]; then
  echo "ROUTE=/devflow --mode=change"
  echo "REASON=$DECISION_REASON"
  if [ "$MODE" = verify ]; then
    echo "ESCALATE_TO_FULL=1"
    exit 1
  fi
  exit 0
fi
echo "ROUTE=/small-change"
[ "$MODE" = classify ] && exit 0

if ! workspace_file "$CHANGE_REPORT" CHANGE_REPORT; then
  :
elif [ "$(wc -c < "$CHANGE_REPORT" | tr -d ' ')" -lt 32 ]; then
  fail "CHANGE_REPORT too small"
fi
AFFECTED_FILES=()
while IFS= read -r affected_path; do
  [ -n "$affected_path" ] || continue
  if workspace_file "$affected_path" AFFECTED_PATH; then AFFECTED_FILES+=("$affected_path"); fi
done < <(printf '%s\n' "$AFFECTED_PATHS" | tr ',' '\n')
if [ "$MIGRATION_REQUIRED" = 1 ]; then
  for dialect in h2 postgresql oracle kingbase; do
    case "$AFFECTED_PATHS" in
      *"/$dialect/"*) ;;
      *) fail "persistence verification missing $dialect migration file in AFFECTED_PATHS" ;;
    esac
  done
fi
[ -n "$VERIFY_CMD" ] || fail "VERIFY_CMD missing"
case "$VERIFY_CMD" in true|true\ *|:|echo|echo\ *|printf\ *|touch\ *) fail "VERIFY_CMD is a placeholder" ;; esac
is_shell_wrapper "$VERIFY_CMD" && fail "VERIFY_CMD must be a direct test/build command, not a shell wrapper"
[ "$MIGRATION_REQUIRED" != 1 ] || [ -n "$MIGRATION_VERIFY_CMD" ] || fail "MIGRATION_VERIFY_CMD required for persistence change"
if [ "$MIGRATION_REQUIRED" = 1 ] && [ -n "$MIGRATION_VERIFY_CMD" ]; then
  is_shell_wrapper "$MIGRATION_VERIFY_CMD" && fail "MIGRATION_VERIFY_CMD must be direct"
fi

CONTRACT_SHA_BEFORE=$(sha_file "$CONTRACT" 2>/dev/null || true)
SCAN_SHA_BEFORE=$(sha_file "$PROJECT_SCAN_EVIDENCE" 2>/dev/null || true)
REPORT_SHA_BEFORE=$(sha_file "$CHANGE_REPORT" 2>/dev/null || true)
[ -n "$CONTRACT_SHA_BEFORE" ] && [ -n "$SCAN_SHA_BEFORE" ] && [ -n "$REPORT_SHA_BEFORE" ] || { echo "[FATAL] hash tool/evidence unavailable"; exit 2; }
AFFECTED_TREE_BEFORE=$(receipt_evidence_tree "${AFFECTED_FILES[@]:-}")
[ -n "$AFFECTED_TREE_BEFORE" ] || { echo "[FATAL] affected implementation tree hash unavailable"; exit 2; }

STATE_ROOT="${STATE_DIR:-.devflow}/$CHANGE_ID"
LOG_DIR="$STATE_ROOT/small-change-executions"
mkdir -p "$LOG_DIR"
VERIFY_LOG="$LOG_DIR/focused.log"
MIGRATION_LOG="$LOG_DIR/migration.log"
if [ -n "$VERIFY_CMD" ]; then
  bash -c "$VERIFY_CMD" > "$VERIFY_LOG" 2>&1
  VERIFY_EXIT=$?
  [ "$VERIFY_EXIT" -eq 0 ] && pass "focused verification exit=0" || fail "实际验证失败: exit=$VERIFY_EXIT"
fi
if [ "$MIGRATION_REQUIRED" = 1 ] && [ -n "$MIGRATION_VERIFY_CMD" ]; then
  bash -c "$MIGRATION_VERIFY_CMD" > "$MIGRATION_LOG" 2>&1
  MIGRATION_EXIT=$?
  [ "$MIGRATION_EXIT" -eq 0 ] && pass "migration verification exit=0" || fail "迁移验证失败: exit=$MIGRATION_EXIT"
fi
[ "$(sha_file "$CONTRACT" 2>/dev/null || true)" = "$CONTRACT_SHA_BEFORE" ] || fail "verification mutated small-change contract"
[ "$(sha_file "$PROJECT_SCAN_EVIDENCE" 2>/dev/null || true)" = "$SCAN_SHA_BEFORE" ] || fail "verification mutated project scan evidence"
[ "$(sha_file "$CHANGE_REPORT" 2>/dev/null || true)" = "$REPORT_SHA_BEFORE" ] || fail "verification mutated change report"
AFFECTED_TREE_AFTER=$(receipt_evidence_tree "${AFFECTED_FILES[@]:-}")
[ "$AFFECTED_TREE_AFTER" = "$AFFECTED_TREE_BEFORE" ] || fail "verification mutated affected implementation files"

DEPLOY_RECEIPT_PATH=$(value DEPLOY_RECEIPT_PATH)
MONITOR_RECEIPT_PATH=$(value MONITOR_RECEIPT_PATH)
if [ "$TARGET" = released ]; then
  # v3.28.4(P0-1)：released 声明同样需要发布授权收据（与 P7 gate 同契约）
  SC_AUTH="${STATE_DIR:-.devflow}/$CHANGE_ID/authorizations/release.json"
  if [ ! -f "$SC_AUTH" ]; then
    fail "TARGET=released requires release authorization: ${SC_AUTH}（见 commands/devflow.md §Release Authorization）"
  fi
  if [ -z "$DEPLOY_RECEIPT_PATH" ] || [ ! -f "$DEPLOY_RECEIPT_PATH" ]; then
    fail "TARGET=released requires DEPLOY_RECEIPT_PATH"
  elif ! workspace_file "$DEPLOY_RECEIPT_PATH" DEPLOY_RECEIPT_PATH; then
    :
  elif ! grep -q '^EXIT_CODE=0$' "$DEPLOY_RECEIPT_PATH" || ! grep -q '^PHASE=P7$' "$DEPLOY_RECEIPT_PATH"; then
    fail "deployment receipt is not successful"
  elif ! verify_receipt_evidence "$DEPLOY_RECEIPT_PATH" >/dev/null 2>&1; then
    fail "deployment receipt evidence binding invalid"
  fi
  if [ -z "$MONITOR_RECEIPT_PATH" ] || [ ! -f "$MONITOR_RECEIPT_PATH" ]; then
    fail "TARGET=released requires MONITOR_RECEIPT_PATH"
  elif ! workspace_file "$MONITOR_RECEIPT_PATH" MONITOR_RECEIPT_PATH; then
    :
  elif ! grep -q '^EXIT_CODE=0$' "$MONITOR_RECEIPT_PATH" || ! grep -q '^PHASE=P8$' "$MONITOR_RECEIPT_PATH"; then
    fail "monitor receipt is not successful"
  elif ! verify_receipt_evidence "$MONITOR_RECEIPT_PATH" >/dev/null 2>&1; then
    fail "monitor receipt evidence binding invalid"
  fi
fi

RECEIPT_DIR="$STATE_ROOT/gates/SMALL-CHANGE"
mkdir -p "$RECEIPT_DIR"
RECEIPT="$RECEIPT_DIR/receipt.txt"
EVIDENCE=("$CONTRACT" "$PROJECT_SCAN_EVIDENCE" "$CHANGE_REPORT")
for affected_path in "${AFFECTED_FILES[@]:-}"; do [ -n "$affected_path" ] && EVIDENCE+=("$affected_path"); done
[ -f "$VERIFY_LOG" ] && EVIDENCE+=("$VERIFY_LOG")
[ -f "$MIGRATION_LOG" ] && EVIDENCE+=("$MIGRATION_LOG")
[ -n "$DEPLOY_RECEIPT_PATH" ] && [ -f "$DEPLOY_RECEIPT_PATH" ] && EVIDENCE+=("$DEPLOY_RECEIPT_PATH")
[ -n "$MONITOR_RECEIPT_PATH" ] && [ -f "$MONITOR_RECEIPT_PATH" ] && EVIDENCE+=("$MONITOR_RECEIPT_PATH")
command -v jq >/dev/null 2>&1 || { echo "[FATAL] jq required for receipt"; exit 2; }
EVIDENCE_JSON='['; first=1
for evidence in "${EVIDENCE[@]}"; do
  encoded=$(jq -cn --arg p "$evidence" '$p') || exit 2
  [ "$first" -eq 1 ] || EVIDENCE_JSON="$EVIDENCE_JSON,"
  EVIDENCE_JSON="$EVIDENCE_JSON$encoded"; first=0
done
EVIDENCE_JSON="$EVIDENCE_JSON]"
EVIDENCE_TREE=$(receipt_evidence_tree "${EVIDENCE[@]}")
[ -n "$EVIDENCE_TREE" ] || { echo "[FATAL] evidence tree hash failed"; exit 2; }
GATE_VERSION=$(sed -n 's/^  version: "\([0-9.]*\)"/\1/p' "$SKILL_ROOT/SKILL.md" | head -1)
RESULT_EXIT=$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
if [ "$FAIL" -gt 0 ]; then RESULT_STATUS=FAILED; elif [ "$TARGET" = released ]; then RESULT_STATUS=RELEASED; else RESULT_STATUS=MERGE_READY; fi
cat > "$RECEIPT" <<EOF
COMMAND=small-change-gate.sh verify $CHANGE_ID
EXIT_CODE=$RESULT_EXIT
VERSION=small-change@$GATE_VERSION
PHASE=SMALL-CHANGE
SKILL_TREE=$(bash "$SCRIPT_DIR/gate-skill-tree.sh")
EVIDENCE_PATHS_JSON=$EVIDENCE_JSON
EVIDENCE_TREE_SHA256=$EVIDENCE_TREE
PRODUCER_ROLE=small-change-verifier
SESSION_ID=${SESSION_ID:-unknown}
STARTED_AT=$GATE_STARTED_AT
FINISHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ENVIRONMENT=${ENVIRONMENT:-dev}
CHANGE_SUBJECT=$CHANGE_SUBJECT
CHANGE_KIND=$CHANGE_KIND
TARGET=$TARGET
STATUS=$RESULT_STATUS
PASS=$PASS FAIL=$FAIL WARN=0
EOF
DOCS_RECEIPT="docs/$CHANGE_ID/gates/SMALL-CHANGE"
mkdir -p "$DOCS_RECEIPT" && cp "$RECEIPT" "$DOCS_RECEIPT/receipt.txt"

echo "STATUS=$RESULT_STATUS"
echo "SMALL-CHANGE GATE: $([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)"
[ "$FAIL" -eq 0 ]
