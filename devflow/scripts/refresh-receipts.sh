#!/usr/bin/env bash
# refresh-receipts.sh · 一键刷新全阶段收据（skill 升版/树漂移后的机械性重跑）
# 用法:
#   refresh-receipts.sh <feature> [--prd <路径>] [--evidence <tsv>] [--service <名>]
#       [--design-mode monolith|total|sub] [--migration <A|B|C>] [--skip-p2a] [--migrate-tree]
#
# v3.29.3 修复（外部审计 P0/P1）:
#   - 前置树漂移检查：state 冻结树 ≠ 当前树 → FAIL 并指示显式
#     `devflow-state.sh migrate-tree <feature>`；加 --migrate-tree 才随本脚本执行
#     （树迁移必须显式留痕——FROM_TREE/TO_TREE 收据，绝不静默覆盖）
#   - 末尾不再信任 reconcile 的 rc=0（其停驻仅 warn 仍返回 0 是既有契约）：
#     刷新后 state current_phase 必须到达 COMPLETED，否则 FAIL
#   - P5-migration 场景互斥：--migration <A|B|C> 显式指定（A=免收据显式 SKIP；
#     有证据 env 但未指定场景 → FAIL）。修复 B/C 双跑覆盖同一收据的缺陷
#   - --skip-p2a 合法化：必须存在 skip-log.txt 的 SKIP_P2a= 四字段授权行
#     （对齐 P2b skip 契约），写当前版本+当前树的 SKIPPED 收据；否则拒绝
#   - 通用性：--service（默认=feature）、--design-mode 透传 s2 模板契约、
#     py_runtime.sh 跨平台 Python（python3→python→py -3）
#   - 测试钩子：DEVFLOW_REFRESH_GATE_DIR 可覆盖 Gate 脚本目录（仅测试桩用）
set -u
SKILL="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=devflow_feature.sh
. "$SKILL/scripts/devflow_feature.sh"
# shellcheck source=py_runtime.sh
. "$SKILL/scripts/py_runtime.sh"

usage() {
  echo "用法: refresh-receipts.sh <feature> [--prd <路径>] [--evidence <tsv>]" >&2
  echo "      [--service <名>] [--design-mode monolith|total|sub] [--migration <A|B|C>]" >&2
  echo "      [--skip-p2a] [--migrate-tree]" >&2
}

FEATURE="${1:-}"
[ -n "$FEATURE" ] || { usage; exit 2; }
devflow_feature_validate "$FEATURE" || exit 2
shift

PRD="docs/PRD/${FEATURE}.md"; EVID="docs/test/${FEATURE}-implementation-evidence.tsv"
SERVICE="$FEATURE"; DESIGN_MODE="monolith"; OPT_MIGRATION=""; OPT_SKIP_P2A=0; OPT_MIGRATE_TREE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prd)         [ $# -ge 2 ] || { echo "[FAIL] --prd 缺少参数" >&2; usage; exit 2; }; PRD="$2"; shift 2;;
    --evidence)    [ $# -ge 2 ] || { echo "[FAIL] --evidence 缺少参数" >&2; usage; exit 2; }; EVID="$2"; shift 2;;
    --service)     [ $# -ge 2 ] || { echo "[FAIL] --service 缺少参数" >&2; usage; exit 2; }; SERVICE="$2"; shift 2;;
    --design-mode) [ $# -ge 2 ] || { echo "[FAIL] --design-mode 缺少参数" >&2; usage; exit 2; }; DESIGN_MODE="$2"; shift 2;;
    --migration)   [ $# -ge 2 ] || { echo "[FAIL] --migration 缺少参数" >&2; usage; exit 2; }; OPT_MIGRATION="$2"; shift 2;;
    --skip-p2a)    OPT_SKIP_P2A=1; shift;;
    --migrate-tree) OPT_MIGRATE_TREE=1; shift;;
    --help|-h)     usage; exit 0;;
    *)             echo "[FAIL] 未知参数: $1" >&2; usage; exit 2;;
  esac
done
case "$DESIGN_MODE" in monolith|total|sub) ;; *)
  echo "[FAIL] --design-mode 仅支持 monolith|total|sub，收到: ${DESIGN_MODE}" >&2; exit 2;;
esac
case "$OPT_MIGRATION" in ""|A|B|C) ;; *)
  echo "[FAIL] --migration 仅支持 A|B|C（互斥的冻结迁移策略），收到: ${OPT_MIGRATION}" >&2; exit 2;;
esac

ROOT=$(pwd -P)
STATE_FILE="$ROOT/.devflow/${FEATURE}.state.json"
GATE_BIN="${DEVFLOW_REFRESH_GATE_DIR:-$SKILL/scripts}"
export REVIEW_ATTESTATION_PUBKEY="${REVIEW_ATTESTATION_PUBKEY:-$ROOT/.devflow/$FEATURE/review-keys/attest.pub.pem}"
LOGDIR="$ROOT/.devflow/$FEATURE/refresh-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR" || { echo "[FAIL] 无法创建日志目录: $LOGDIR" >&2; exit 2; }
echo "[refresh] 日志目录: $LOGDIR"

# ── 前置 1：state 必须已初始化（reconcile/migrate-tree 都依赖 state）──
if [ ! -f "$STATE_FILE" ]; then
  echo "[FAIL] state 不存在: ${STATE_FILE}——先初始化: bash $SKILL/scripts/devflow-state.sh init $FEATURE" >&2
  exit 1
fi

# ── 前置 2：树漂移检查（P0）——新收据用当前树，旧冻结树会令 reconcile 拒收 ──
CUR_TREE=$(bash "$SKILL/scripts/gate-skill-tree.sh" 2>/dev/null)
FROZEN_TREE=$(jq -r '.scope.skill_tree_sha256 // empty' "$STATE_FILE" 2>/dev/null)
if [ -n "$FROZEN_TREE" ] && [ "$FROZEN_TREE" != "$CUR_TREE" ]; then
  if [ "$OPT_MIGRATE_TREE" = "1" ]; then
    echo "[refresh] 检测到树漂移——执行显式迁移（--migrate-tree）..."
    if ! bash "$SKILL/scripts/devflow-state.sh" migrate-tree "$FEATURE" > "$LOGDIR/migrate-tree.log" 2>&1; then
      echo "[FAIL] migrate-tree 失败 (日志: $LOGDIR/migrate-tree.log)" >&2
      tail -5 "$LOGDIR/migrate-tree.log" | sed 's/^/    │ /'
      exit 1
    fi
    echo "[OK] migrate-tree（SKILL-TREE-MIGRATION 收据已留痕）"
  else
    echo "[FAIL] state 冻结树 ≠ 当前 skill 树——刷新前必须显式迁移（收据树对账硬门禁）:" >&2
    echo "  bash $SKILL/scripts/devflow-state.sh migrate-tree $FEATURE" >&2
    echo "  或本脚本加 --migrate-tree 一并执行（写 SKILL-TREE-MIGRATION 收据留痕）" >&2
    exit 1
  fi
fi

# ── 前置 3：P5-migration 场景解析（B/C 互斥，禁止双跑覆盖同一收据）──
MIG_ENV="docs/测试/${FEATURE}-migration-evidence.env"
MIG_SCENARIO=""
if [ -n "$OPT_MIGRATION" ]; then
  MIG_SCENARIO="$OPT_MIGRATION"
elif [ -f "$MIG_ENV" ]; then
  echo "[FAIL] 检测到迁移证据 $MIG_ENV 但未指定 --migration——B/C 是互斥的冻结迁移策略，" >&2
  echo "       拒绝猜测。请显式指定: --migration B 或 --migration C（A 免迁移收据）" >&2
  exit 1
fi

PASS=0
# 失败即停（铁律 8）：任一 Gate 非零 → 立即终止，不执行后续 Gate
gate() { local name="$1"; shift
  if "$@" > "$LOGDIR/$name.log" 2>&1; then
    PASS=$((PASS+1)); echo "[OK] $name"
  else
    echo "[FAIL] $name (日志: $LOGDIR/$name.log)"
    tail -5 "$LOGDIR/$name.log" | sed 's/^/    │ /'
    echo "── 铁律 8：Gate 非零立即停止。修复后重跑：bash $SKILL/scripts/refresh-receipts.sh $FEATURE ──"
    exit 1
  fi
}

# ── P0 ──
gate s0      bash "$GATE_BIN/s0_acceptance_gate.sh" "$FEATURE"
gate P0b     bash "$GATE_BIN/artifact_gate.sh" P0b "$FEATURE"
# ── P1 ──
gate P1      env TECH_SELECTION_FILE="docs/详细设计/$FEATURE-技术选型.md" \
             bash "$GATE_BIN/s1_fact_sources_gate.sh" docs/详细设计
# ── P2 ──
gate design  "${DEVFLOW_PY[@]}" "$GATE_BIN/df_pipeline.py" design \
             --input ".devflow/$FEATURE/design.json" \
             --doc "docs/详细设计/$FEATURE-详细设计.md" \
             --db-doc "docs/详细设计/$FEATURE-数据库设计决策.md" \
             --trace-doc "docs/详细设计/$FEATURE-需求追溯.md"
gate s2      bash "$GATE_BIN/s2_design_coverage_gate.sh" "docs/详细设计/$FEATURE-详细设计.md" "docs/需求/$FEATURE-验收点.md" --mode="$DESIGN_MODE"
if [ "$OPT_SKIP_P2A" = "1" ]; then
  # 合法跳过：对齐 P2b skip 契约——skip-log 四字段授权行 + 当前版本/当前树 SKIPPED 收据
  SKIP_LOG_F="$ROOT/.devflow/$FEATURE/skip-log.txt"
  SKIP_LINE=$(grep -E '^SKIP_P2a=' "$SKIP_LOG_F" 2>/dev/null | head -1)
  SKIP_REASON=""; SKIP_BY=""; SKIP_AT=""; SKIP_EVID=""
  if [ -n "$SKIP_LINE" ]; then
    echo "$SKIP_LINE" | grep -qE '^SKIP_P2a=[^|]' && SKIP_REASON=$(echo "$SKIP_LINE" | cut -d'|' -f1 | sed 's/^SKIP_P2a=//')
    SKIP_BY=$(echo "$SKIP_LINE" | grep -oE 'authorized-by=[^|]*' | cut -d= -f2)
    SKIP_AT=$(echo "$SKIP_LINE" | grep -oE 'at=[^|]*' | cut -d= -f2)
    SKIP_EVID=$(echo "$SKIP_LINE" | grep -oE 'approval=[^|]*' | cut -d= -f2)
  fi
  if [ -z "$SKIP_REASON" ] || [ -z "${SKIP_BY//[[:space:]]/}" ] \
     || ! echo "$SKIP_AT" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2})?' \
     || [ -z "${SKIP_EVID//[[:space:]]/}" ]; then
    echo "[FAIL] --skip-p2a 要求 skip-log.txt 存在合法授权行（否则 P2a 收据链断裂、reconcile 停驻）:" >&2
    echo "  SKIP_P2a=<理由>|authorized-by=<授权人>|at=<YYYY-MM-DD[Thh:mm]>|approval=<审批证据>" >&2
    echo "  文件: $SKIP_LOG_F" >&2
    exit 1
  fi
  P2A_DIR="$ROOT/.devflow/$FEATURE/gates/P2a"
  mkdir -p "$P2A_DIR" "$ROOT/docs/$FEATURE/gates/P2a"
  {
    echo "EXIT_CODE=0"
    echo "VERSION=p2a@$(bash "$SKILL/scripts/gate-version.sh" 2>/dev/null)"
    echo "SKILL_TREE=${CUR_TREE}"
    echo "PHASE=P2a"
    echo "SKIPPED=1"
    echo "SKIP_REASON=$SKIP_REASON"
    echo "AUTHORIZED_BY=$SKIP_BY"
    echo "AUTHORIZED_AT=$SKIP_AT"
    echo "APPROVAL_EVIDENCE=$SKIP_EVID"
    echo "PASS=0 FAIL=0 WARN=1"
    echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$P2A_DIR/receipt.txt"
  cp "$P2A_DIR/receipt.txt" "$ROOT/docs/$FEATURE/gates/P2a/receipt.txt"
  echo "[SKIP] P2a（用户授权：${SKIP_REASON}，authorized-by=${SKIP_BY}；SKIPPED 收据已写）"
else
  gate P2a   bash "$GATE_BIN/p2a_design_review_gate.sh" "$FEATURE"
fi
gate P2b     bash "$GATE_BIN/p2b_demo_gate.sh" "$FEATURE"
# ── P3 ──
gate P3build bash "$GATE_BIN/build-watchdog.sh" gate "$FEATURE"
gate P3      bash "$GATE_BIN/p3_completion_gate.sh" "$SERVICE" "$FEATURE"
gate P3b     bash "$GATE_BIN/p3b_code_review_gate.sh" "$FEATURE"
gate P3cd    bash "$GATE_BIN/p3_security_perf_gate.sh" "$FEATURE"
# ── P4 ──
gate P4      bash "$GATE_BIN/p4_validation_gate.sh" "$FEATURE"
gate P4b     bash "$GATE_BIN/p4_prd_vs_code.sh" "$FEATURE" --prd "$PRD" \
             --design "docs/详细设计/$FEATURE-详细设计.md" \
             --criteria "docs/需求/$FEATURE-验收点.md" --evidence "$EVID" --service "$SERVICE"
# ── P5 ──
gate P5      bash "$GATE_BIN/p5_test_cases_gate.sh" "$FEATURE"
if [ -n "$MIG_SCENARIO" ]; then
  if [ "$MIG_SCENARIO" = "A" ]; then
    echo "[SKIP] s5mig（--migration A：免迁移收据）"
  else
    # 三参契约: <feature> <A|B|C> <evidence>；单场景单次执行——收据不被异性场景覆盖
    gate s5mig  bash "$GATE_BIN/s5_migration_gate.sh" "$FEATURE" "$MIG_SCENARIO" "$MIG_ENV"
  fi
else
  echo "[SKIP] s5mig（$MIG_ENV 不存在——迁移策略 A 或未产出；如应存在先补 P5 并显式 --migration）"
fi
# ── P6 ──
gate s6acc   bash "$GATE_BIN/s6_first_pass_accuracy.sh" "$FEATURE"
gate p6cred  bash "$GATE_BIN/p6_credential_gate.sh" "$FEATURE"
gate s6final bash "$GATE_BIN/s6_final_verification_gate.sh" "$FEATURE"
# ── P7 / P8 / P9 ──
gate P7      bash "$GATE_BIN/artifact_gate.sh" P7 "$FEATURE"
gate P8      bash "$GATE_BIN/artifact_gate.sh" P8 "$FEATURE"
gate P9      bash "$GATE_BIN/artifact_gate.sh" P9 "$FEATURE"
# ── P10 ──
gate P10     bash "$GATE_BIN/p10_feedback_gate.sh" "$FEATURE"

# ── 末尾对账：reconcile --apply（只进不退）──
if ! bash "$SKILL/scripts/devflow-state.sh" reconcile "$FEATURE" --apply > "$LOGDIR/reconcile.log" 2>&1; then
  echo "[FAIL] reconcile --apply 异常退出 (日志: $LOGDIR/reconcile.log)"
  tail -5 "$LOGDIR/reconcile.log" | sed 's/^/    │ /'
  exit 1
fi
echo "[OK] reconcile --apply"

# ── 终验 state：reconcile 停驻仍返回 0 是既有契约——自行验证推进到位 ──
CUR_PHASE=$(jq -r '.current_phase // ""' "$STATE_FILE" 2>/dev/null)
if [ "$CUR_PHASE" != "COMPLETED" ]; then
  echo "[FAIL] reconcile 后 state 未达 COMPLETED（current_phase=${CUR_PHASE:-空}）——收据链存在停驻" >&2
  grep -E "停在|断裂|拒绝" "$LOGDIR/reconcile.log" | head -3 | sed 's/^/    │ /'
  exit 1
fi

echo "── 本轮收据刷新: OK=$PASS FAIL=0（全部通过，state 已推进至 COMPLETED）──"
echo "── 日志: $LOGDIR ──"
