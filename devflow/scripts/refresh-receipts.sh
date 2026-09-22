#!/usr/bin/env bash
# refresh-receipts.sh · 一键刷新全阶段收据（skill 升版/树漂移后的机械性重跑）
# 用法: refresh-receipts.sh <feature> [--prd <路径>] [--evidence <tsv>] [--skip-p2a]
# 依赖: 仓库根有 pom.xml(或 backend/<service>/pom.xml) 与 frontend/package.json 的场景按需自行增删 gate 行。
# 说明: 按 P0→P10 依赖序重跑 SKILL.md Gate 矩阵全部 Gate，使收据 VERSION 行对齐当前
#       skill 版本；全部通过后 reconcile --apply 回填钉定。
#       v3.29.2 修复（对齐声明——此前只跑到 P5 即跳 P10）：
#         - 补全 P5-migration(B/C)、P6 accuracy、P6 credential、P6-final、P7、P8、P9；
#         - 失败即停（铁律 8：Gate 非零立即停止，修复后重跑同一 Gate）；
#         - 末尾 reconcile --apply（状态机与收据链对账，只进不退）；
#         - 严格参数解析（未知参数/缺参 exit 2 + 用法，不再 unbound variable）；
#         - feature 白名单校验（devflow_feature_validate，封堵路径穿越）；
#         - 日志落 .devflow/<feature>/refresh-logs/<TS>/（非收据证据，不进 gates/ 树）。
set -u
SKILL="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=devflow_feature.sh
. "$SKILL/scripts/devflow_feature.sh"

usage() { echo "用法: refresh-receipts.sh <feature> [--prd <路径>] [--evidence <tsv>] [--skip-p2a]" >&2; }

FEATURE="${1:-}"
[ -n "$FEATURE" ] || { usage; exit 2; }
devflow_feature_validate "$FEATURE" || exit 2
shift

PRD="docs/PRD/${FEATURE}.md"; EVID="docs/test/${FEATURE}-implementation-evidence.tsv"
while [ $# -gt 0 ]; do
  case "$1" in
    --prd)      [ $# -ge 2 ] || { echo "[FAIL] --prd 缺少参数" >&2; usage; exit 2; }; PRD="$2"; shift 2;;
    --evidence) [ $# -ge 2 ] || { echo "[FAIL] --evidence 缺少参数" >&2; usage; exit 2; }; EVID="$2"; shift 2;;
    --skip-p2a) SKIP_P2A=1; shift;;
    --help|-h)  usage; exit 0;;
    *)          echo "[FAIL] 未知参数: $1" >&2; usage; exit 2;;
  esac
done

ROOT=$(pwd -P)
export REVIEW_ATTESTATION_PUBKEY="${REVIEW_ATTESTATION_PUBKEY:-$ROOT/.devflow/$FEATURE/review-keys/attest.pub.pem}"
LOGDIR="$ROOT/.devflow/$FEATURE/refresh-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR" || { echo "[FAIL] 无法创建日志目录: $LOGDIR" >&2; exit 2; }
echo "[refresh] 日志目录: $LOGDIR"

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
gate s0      bash "$SKILL/scripts/s0_acceptance_gate.sh" "$FEATURE"
gate P0b     bash "$SKILL/scripts/artifact_gate.sh" P0b "$FEATURE"
# ── P1 ──
gate P1      env TECH_SELECTION_FILE="docs/详细设计/$FEATURE-技术选型.md" \
             bash "$SKILL/scripts/s1_fact_sources_gate.sh" docs/详细设计
# ── P2 ──
gate design  python3 "$SKILL/scripts/df_pipeline.py" design \
             --input ".devflow/$FEATURE/design.json" \
             --doc "docs/详细设计/$FEATURE-详细设计.md" \
             --db-doc "docs/详细设计/$FEATURE-数据库设计决策.md" \
             --trace-doc "docs/详细设计/$FEATURE-需求追溯.md"
gate s2      bash "$SKILL/scripts/s2_design_coverage_gate.sh" "docs/详细设计/$FEATURE-详细设计.md" "docs/需求/$FEATURE-验收点.md" --mode=monolith
if [ "${SKIP_P2A:-0}" = "1" ]; then
  echo "[SKIP] P2a（--skip-p2a 显式豁免）"
else
  gate P2a   bash "$SKILL/scripts/p2a_design_review_gate.sh" "$FEATURE"
fi
gate P2b     bash "$SKILL/scripts/p2b_demo_gate.sh" "$FEATURE"
# ── P3 ──
gate P3build bash "$SKILL/scripts/build-watchdog.sh" gate "$FEATURE"
gate P3      bash "$SKILL/scripts/p3_completion_gate.sh" "$FEATURE" "$FEATURE"
gate P3b     bash "$SKILL/scripts/p3b_code_review_gate.sh" "$FEATURE"
gate P3cd    bash "$SKILL/scripts/p3_security_perf_gate.sh" "$FEATURE"
# ── P4 ──
gate P4      bash "$SKILL/scripts/p4_validation_gate.sh" "$FEATURE"
gate P4b     bash "$SKILL/scripts/p4_prd_vs_code.sh" "$FEATURE" --prd "$PRD" \
             --design "docs/详细设计/$FEATURE-详细设计.md" \
             --criteria "docs/需求/$FEATURE-验收点.md" --evidence "$EVID" --service "$FEATURE"
# ── P5 ──
gate P5      bash "$SKILL/scripts/p5_test_cases_gate.sh" "$FEATURE"
# P5-migration（B/C 迁移辅助证据；策略 A 无迁移证据——env 不存在时显式 SKIP，不静默）
MIG_ENV="docs/测试/${FEATURE}-migration-evidence.env"
if [ -f "$MIG_ENV" ]; then
  gate s5migB bash "$SKILL/scripts/s5_migration_gate.sh" B "$MIG_ENV"
  gate s5migC bash "$SKILL/scripts/s5_migration_gate.sh" C "$MIG_ENV"
else
  echo "[SKIP] s5migB/s5migC（$MIG_ENV 不存在——迁移策略 A 或未产出；如应存在先补 P5）"
fi
# ── P6 ──
gate s6acc   bash "$SKILL/scripts/s6_first_pass_accuracy.sh" "$FEATURE"
gate p6cred  bash "$SKILL/scripts/p6_credential_gate.sh" "$FEATURE"
gate s6final bash "$SKILL/scripts/s6_final_verification_gate.sh" "$FEATURE"
# ── P7 / P8 / P9 ──
gate P7      bash "$SKILL/scripts/artifact_gate.sh" P7 "$FEATURE"
gate P8      bash "$SKILL/scripts/artifact_gate.sh" P8 "$FEATURE"
gate P9      bash "$SKILL/scripts/artifact_gate.sh" P9 "$FEATURE"
# ── P10 ──
gate P10     bash "$SKILL/scripts/p10_feedback_gate.sh" "$FEATURE"

# ── 末尾对账：状态机与收据链 reconcile（--apply 只进不退），失败同样即停 ──
if bash "$SKILL/scripts/devflow-state.sh" reconcile "$FEATURE" --apply > "$LOGDIR/reconcile.log" 2>&1; then
  echo "[OK] reconcile --apply"
else
  echo "[FAIL] reconcile --apply (日志: $LOGDIR/reconcile.log)"
  tail -5 "$LOGDIR/reconcile.log" | sed 's/^/    │ /'
  exit 1
fi

echo "── 本轮收据刷新: OK=$PASS FAIL=0（全部通过）──"
echo "── 日志: $LOGDIR ──"
