#!/usr/bin/env bash
# refresh-receipts.sh · 一键刷新全阶段收据（skill 升版/树漂移后的机械性重跑）
# 用法: refresh-receipts.sh <feature> [--prd <路径>] [--evidence <tsv>] [--skip-p2a]
# 依赖: 仓库根有 pom.xml(或 backend/<service>/pom.xml) 与 frontend/package.json 的场景按需自行增删 gate 行。
# 说明: 按 P0→P10 依赖序重跑各 Gate，使收据 VERSION 行对齐当前 skill 版本；末尾 reconcile --apply 回填钉定。
set -u
FEATURE="${1:?用法: refresh-receipts.sh <feature> [--prd <路径>] [--evidence <tsv>] [--skip-p2a]}"
shift
PRD="docs/PRD/${FEATURE}.md"; EVID="docs/test/${FEATURE}-implementation-evidence.tsv"
while [ $# -gt 0 ]; do
  case "$1" in
    --prd) PRD="$2"; shift 2;;
    --evidence) EVID="$2"; shift 2;;
    --skip-p2a) SKIP_P2A=1; shift;;
    *) shift;;
  esac
done
ROOT=$(pwd -P)
SKILL="$(cd "$(dirname "$0")/.." && pwd -P)"
export REVIEW_ATTESTATION_PUBKEY="${REVIEW_ATTESTATION_PUBKEY:-$ROOT/.devflow/$FEATURE/review-keys/attest.pub.pem}"
PASS=0; FAILCNT=0; FAILED=""
gate() { local name="$1"; shift
  if "$@" > "/tmp/refresh-$name.log" 2>&1; then PASS=$((PASS+1)); echo "[OK] $name"
  else FAILCNT=$((FAILCNT+1)); FAILED="$FAILED $name"; echo "[FAIL] $name (日志: /tmp/refresh-$name.log)"; fi
}
run() { "$@" > "/tmp/refresh-step.log" 2>&1 || echo "[WARN] step 失败: $* (日志: /tmp/refresh-step.log)"; }

gate s0      bash "$SKILL/scripts/s0_acceptance_gate.sh" "$FEATURE"
gate P0b     bash "$SKILL/scripts/artifact_gate.sh" P0b "$FEATURE"
gate P1      env TECH_SELECTION_FILE="docs/详细设计/$FEATURE-技术选型.md" \
             bash "$SKILL/scripts/s1_fact_sources_gate.sh" docs/详细设计
gate design  python3 "$SKILL/scripts/df_pipeline.py" design \
             --input ".devflow/$FEATURE/design.json" \
             --doc "docs/详细设计/$FEATURE-详细设计.md" \
             --db-doc "docs/详细设计/$FEATURE-数据库设计决策.md" \
             --trace-doc "docs/详细设计/$FEATURE-需求追溯.md"
gate s2      bash "$SKILL/scripts/s2_design_coverage_gate.sh" "docs/详细设计/$FEATURE-详细设计.md" "docs/需求/$FEATURE-验收点.md" --mode=monolith
if [ "${SKIP_P2A:-0}" != "1" ]; then
  gate P2a   bash "$SKILL/scripts/p2a_design_review_gate.sh" "$FEATURE"
fi
gate P2b     bash "$SKILL/scripts/p2b_demo_gate.sh" "$FEATURE"
gate P3build bash "$SKILL/scripts/build-watchdog.sh" gate "$FEATURE"
gate P3      bash "$SKILL/scripts/p3_completion_gate.sh" "$FEATURE" "$FEATURE"
gate P3b     bash "$SKILL/scripts/p3b_code_review_gate.sh" "$FEATURE"
gate P3cd    bash "$SKILL/scripts/p3_security_perf_gate.sh" "$FEATURE"
gate P4      bash "$SKILL/scripts/p4_validation_gate.sh" "$FEATURE"
gate P4b     bash "$SKILL/scripts/p4_prd_vs_code.sh" "$FEATURE" --prd "$PRD" \
             --design "docs/详细设计/$FEATURE-详细设计.md" \
             --criteria "docs/需求/$FEATURE-验收点.md" --evidence "$EVID" --service "$FEATURE"
gate P5      bash "$SKILL/scripts/p5_test_cases_gate.sh" "$FEATURE"
gate P10     bash "$SKILL/scripts/p10_feedback_gate.sh" "$FEATURE"
echo "── 本轮收据刷新: OK=$PASS FAIL=$FAILCNT${FAILED:+ (失败:$FAILED)} ──"
[ "$FAILCNT" -eq 0 ] || exit 1
