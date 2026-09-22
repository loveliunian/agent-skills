#!/usr/bin/env bash
# refresh_receipts_lib.sh · 收据刷新编排库（被 refresh-receipts.sh 调用；测试可 source 注入桩 Gate 目录）
# 契约：调用前设置以下 RF_* 变量（无默认值依赖——缺省行为见各注释）：
#   RF_SKILL          skill 根目录（必填）
#   RF_ROOT           项目工作区（必填，通常为 pwd）
#   RF_FEATURE        feature 名（必填，已过白名单）
#   RF_GATE_BIN       Gate 脚本目录（必填——生产为 $RF_SKILL/scripts；**不接受环境变量**，
#                     仅由 CLI 固定传入或测试显式传桩目录，封堵生产环境变量后门）
#   RF_SERVICE        服务名（默认=RF_FEATURE）
#   RF_DESIGN_MODE    monolith|total|sub（默认 monolith）
#   RF_MIGRATION      A|B|C 或空（仅当与 design.json 冻结值相等时生效——命令行不是事实源）
#   RF_SKIP_P2A       1/0
#   RF_MIGRATE_TREE   1/0
#   RF_PRD/RF_EVID    路径覆盖
# 输出：进度到 stdout；Gate 日志落 .devflow/<feature>/refresh-logs/<TS>/。
# 退出码：0=全链通过且 state COMPLETED；1=任一 Gate 失败/停驻/前置不满足；2=参数非法（CLI 层）。
# v3.29.4: 自 refresh-receipts.sh 抽出——生产入口不再接受 DEVFLOW_REFRESH_GATE_DIR 环境变量。
set -u

refresh_receipts_run() {
  ROOT="$RF_ROOT"; SKILL="$RF_SKILL"; FEATURE="$RF_FEATURE"
  local PRD="${RF_PRD:-}" EVID="${RF_EVID:-}" SERVICE="${RF_SERVICE:-$FEATURE}"
  local DESIGN_MODE="${RF_DESIGN_MODE:-monolith}"
  local OPT_MIGRATION="${RF_MIGRATION:-}" OPT_SKIP_P2A="${RF_SKIP_P2A:-0}" OPT_MIGRATE_TREE="${RF_MIGRATE_TREE:-0}"
  local GATE_BIN="$RF_GATE_BIN"
  export REVIEW_ATTESTATION_PUBKEY="${REVIEW_ATTESTATION_PUBKEY:-$ROOT/.devflow/$FEATURE/review-keys/attest.pub.pem}"
  local LOGDIR
  LOGDIR="$ROOT/.devflow/$FEATURE/refresh-logs/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$LOGDIR" || { echo "[FAIL] 无法创建日志目录: $LOGDIR" >&2; return 1; }
  echo "[refresh] 日志目录: $LOGDIR"

  # ── 前置 1：state 必须已初始化（reconcile/migrate-tree 都依赖 state）──
  local STATE_FILE="$ROOT/.devflow/${FEATURE}.state.json"
  if [ ! -f "$STATE_FILE" ]; then
    echo "[FAIL] state 不存在: ${STATE_FILE}——先初始化: bash $SKILL/scripts/devflow-state.sh init $FEATURE" >&2
    return 1
  fi

  # ── 前置 2：树漂移检查——新收据用当前树，旧冻结树会令 reconcile 拒收；迁移必须显式 ──
  local CUR_TREE FROZEN_TREE
  CUR_TREE=$(bash "$SKILL/scripts/gate-skill-tree.sh" 2>/dev/null)
  FROZEN_TREE=$(jq -r '.scope.skill_tree_sha256 // empty' "$STATE_FILE" 2>/dev/null)
  if [ -n "$FROZEN_TREE" ] && [ "$FROZEN_TREE" != "$CUR_TREE" ]; then
    if [ "$OPT_MIGRATE_TREE" = "1" ]; then
      echo "[refresh] 检测到树漂移——执行显式迁移（--migrate-tree）..."
      if ! bash "$SKILL/scripts/devflow-state.sh" migrate-tree "$FEATURE" > "$LOGDIR/migrate-tree.log" 2>&1; then
        echo "[FAIL] migrate-tree 失败 (日志: $LOGDIR/migrate-tree.log)" >&2
        tail -5 "$LOGDIR/migrate-tree.log" | sed 's/^/    │ /'
        return 1
      fi
      echo "[OK] migrate-tree（SKILL-TREE-MIGRATION 收据已留痕）"
    else
      echo "[FAIL] state 冻结树 ≠ 当前 skill 树——刷新前必须显式迁移（收据树对账硬门禁）:" >&2
      echo "  bash $SKILL/scripts/devflow-state.sh migrate-tree $FEATURE" >&2
      echo "  或本脚本加 --migrate-tree 一并执行（写 SKILL-TREE-MIGRATION 收据留痕）" >&2
      return 1
    fi
  fi

  # ── 前置 3：迁移策略解析——design.json migrations.strategy 是唯一事实源，命令行只能与之相等 ──
  local MIG_ENV="docs/测试/${FEATURE}-migration-evidence.env"
  local MIG_SCENARIO="" FROZEN_STRAT=""
  if [ -f "$ROOT/.devflow/$FEATURE/design.json" ]; then
    local _mig_app
    _mig_app=$(jq -r '.migrations.applicable // empty' "$ROOT/.devflow/$FEATURE/design.json" 2>/dev/null)
    if [ "$_mig_app" = "true" ]; then
      FROZEN_STRAT=$(jq -r '.migrations.strategy // empty' "$ROOT/.devflow/$FEATURE/design.json" 2>/dev/null)
    fi
  fi
  if [ -n "$OPT_MIGRATION" ]; then
    if [ -z "$FROZEN_STRAT" ]; then
      echo "[FAIL] 命令行 --migration ${OPT_MIGRATION} 被拒绝：design.json 未冻结迁移策略" >&2
      echo "       （migrations.applicable=true 时 strategy 为必填；B/C 必须先在 P2 冻结）" >&2
      return 1
    fi
    if [ "$OPT_MIGRATION" != "$FROZEN_STRAT" ]; then
      echo "[FAIL] 命令行 --migration ${OPT_MIGRATION} ≠ 冻结策略 ${FROZEN_STRAT}" >&2
      echo "       （design.json migrations.strategy 是唯一事实源——命令行只能与之相等）" >&2
      return 1
    fi
    MIG_SCENARIO="$FROZEN_STRAT"
  elif [ -n "$FROZEN_STRAT" ]; then
    MIG_SCENARIO="$FROZEN_STRAT"
  elif [ -f "$MIG_ENV" ]; then
    echo "[FAIL] 检测到迁移证据 $MIG_ENV 但 design.json 未冻结 migrations.strategy——" >&2
    echo "       证据在而策略未冻结属状态不一致，拒绝刷新（先补 P2 冻结）" >&2
    return 1
  fi

  # v3.29.5: 冻结策略 A + 遗留迁移证据冲突（A 免迁移收据——旧 B/C 证据残留须先清理，防审计歧义）
  if [ "$FROZEN_STRAT" = "A" ] && [ -f "$MIG_ENV" ]; then
    echo "[FAIL] 冻结策略 A（仅新建表、免迁移收据）但存在遗留迁移证据: $MIG_ENV" >&2
    echo "       旧 B/C 证据与冻结策略冲突——删除或归档该证据后重跑（stale-evidence）" >&2
    return 1
  fi

  local PASS=0
  # 失败即停（铁律 8）：任一 Gate 非零 → 立即终止，不执行后续 Gate
  gate() { local name="$1"; shift
    if "$@" > "$LOGDIR/$name.log" 2>&1; then
      PASS=$((PASS+1)); echo "[OK] $name"
    else
      echo "[FAIL] $name (日志: $LOGDIR/$name.log)"
      tail -5 "$LOGDIR/$name.log" | sed 's/^/    │ /'
      echo "── 铁律 8：Gate 非零立即停止。修复后重跑：bash $SKILL/scripts/refresh-receipts.sh $FEATURE ──"
      return 1
    fi
  }

  # ── P0 ──
  gate s0      bash "$GATE_BIN/s0_acceptance_gate.sh" "$FEATURE" || return 1
  gate P0b     bash "$GATE_BIN/artifact_gate.sh" P0b "$FEATURE" || return 1
  # ── P1 ──
  gate P1      env TECH_SELECTION_FILE="docs/详细设计/$FEATURE-技术选型.md" \
               bash "$GATE_BIN/s1_fact_sources_gate.sh" docs/详细设计 || return 1
  # ── P2 ──
  gate design  "${DEVFLOW_PY[@]}" "$GATE_BIN/df_pipeline.py" design \
               --input ".devflow/$FEATURE/design.json" \
               --doc "docs/详细设计/$FEATURE-详细设计.md" \
               --db-doc "docs/详细设计/$FEATURE-数据库设计决策.md" \
               --trace-doc "docs/详细设计/$FEATURE-需求追溯.md" || return 1
  gate s2      bash "$GATE_BIN/s2_design_coverage_gate.sh" "docs/详细设计/$FEATURE-详细设计.md" "docs/需求/$FEATURE-验收点.md" --mode="$DESIGN_MODE" || return 1
  if [ "$OPT_SKIP_P2A" = "1" ]; then
    # 合法跳过：对齐 P2b skip 契约——skip-log 四字段授权行 + 当前版本/当前树 SKIPPED 收据
    local SKIP_LOG_F="$ROOT/.devflow/$FEATURE/skip-log.txt"
    local SKIP_LINE SKIP_REASON="" SKIP_BY="" SKIP_AT="" SKIP_EVID=""
    SKIP_LINE=$(grep -E '^SKIP_P2a=' "$SKIP_LOG_F" 2>/dev/null | head -1)
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
      return 1
    fi
    local P2A_DIR="$ROOT/.devflow/$FEATURE/gates/P2a"
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
    gate P2a   bash "$GATE_BIN/p2a_design_review_gate.sh" "$FEATURE" || return 1
  fi
  gate P2b     bash "$GATE_BIN/p2b_demo_gate.sh" "$FEATURE" || return 1
  # ── P3 ──
  gate P3build bash "$GATE_BIN/build-watchdog.sh" gate "$FEATURE" || return 1
  gate P3      bash "$GATE_BIN/p3_completion_gate.sh" "$SERVICE" "$FEATURE" || return 1
  gate P3b     bash "$GATE_BIN/p3b_code_review_gate.sh" "$FEATURE" || return 1
  gate P3cd    bash "$GATE_BIN/p3_security_perf_gate.sh" "$FEATURE" || return 1
  # ── P4 ──
  gate P4      bash "$GATE_BIN/p4_validation_gate.sh" "$FEATURE" || return 1
  gate P4b     bash "$GATE_BIN/p4_prd_vs_code.sh" "$FEATURE" --prd "$PRD" \
               --design "docs/详细设计/$FEATURE-详细设计.md" \
               --criteria "docs/需求/$FEATURE-验收点.md" --evidence "$EVID" --service "$SERVICE" || return 1
  # ── P5 ──
  gate P5      bash "$GATE_BIN/p5_test_cases_gate.sh" "$FEATURE" || return 1
  if [ -n "$MIG_SCENARIO" ]; then
    if [ "$MIG_SCENARIO" = "A" ]; then
      echo "[SKIP] s5mig（冻结策略 A：仅新建表，免迁移收据）"
    else
      # 三参契约: <feature> <A|B|C> <evidence>；冻结策略单次执行——收据不被异性场景覆盖
      gate s5mig  bash "$GATE_BIN/s5_migration_gate.sh" "$FEATURE" "$MIG_SCENARIO" "$MIG_ENV" || return 1
    fi
  else
    echo "[SKIP] s5mig（design.json 未冻结迁移策略 applicable=true.strategy，且无迁移证据）"
  fi
  # ── P6 ──
  gate s6acc   bash "$GATE_BIN/s6_first_pass_accuracy.sh" "$FEATURE" || return 1
  gate p6cred  bash "$GATE_BIN/p6_credential_gate.sh" "$FEATURE" || return 1
  gate s6final bash "$GATE_BIN/s6_final_verification_gate.sh" "$FEATURE" || return 1
  # ── P7 / P8 / P9 ──
  gate P7      bash "$GATE_BIN/artifact_gate.sh" P7 "$FEATURE" || return 1
  gate P8      bash "$GATE_BIN/artifact_gate.sh" P8 "$FEATURE" || return 1
  gate P9      bash "$GATE_BIN/artifact_gate.sh" P9 "$FEATURE" || return 1
  # ── P10 ──
  gate P10     bash "$GATE_BIN/p10_feedback_gate.sh" "$FEATURE" || return 1

  # ── 末尾对账：reconcile --apply（只进不退）──
  if ! bash "$SKILL/scripts/devflow-state.sh" reconcile "$FEATURE" --apply > "$LOGDIR/reconcile.log" 2>&1; then
    echo "[FAIL] reconcile --apply 异常退出 (日志: $LOGDIR/reconcile.log)"
    tail -5 "$LOGDIR/reconcile.log" | sed 's/^/    │ /'
    return 1
  fi
  echo "[OK] reconcile --apply"

  # ── 终验 state：reconcile 停驻仍返回 0 是既有契约——自行验证推进到位 ──
  local CUR_PHASE
  CUR_PHASE=$(jq -r '.current_phase // ""' "$STATE_FILE" 2>/dev/null)
  if [ "$CUR_PHASE" != "COMPLETED" ]; then
    echo "[FAIL] reconcile 后 state 未达 COMPLETED（current_phase=${CUR_PHASE:-空}）——收据链存在停驻" >&2
    grep -E "停在|断裂|拒绝" "$LOGDIR/reconcile.log" | head -3 | sed 's/^/    │ /'
    return 1
  fi

  echo "── 本轮收据刷新: OK=$PASS FAIL=0（全部通过，state 已推进至 COMPLETED）──"
  echo "── 日志: $LOGDIR ──"
  return 0
}
