#!/usr/bin/env bash
# test-refresh-receipts.sh · refresh-receipts 回归（v3.29.4）
#   负向：T1 未知参数 / T2 缺参 / T3 路径穿越
#   清单：T4 22 Gate 静态声明 + reconcile + COMPLETED 终验 + 生产后门移除
#   动态：T5 真实 s0 失败即停
#   编排（桩 Gate 目录 + 真实状态机，经 source 库注入——非环境变量）：
#     T6 全链正向：init → 22 Gate → reconcile → COMPLETED；冻结策略 B 单次
#     T7 树漂移拒绝/显式迁移双路径
#     T8 冻结策略语义：自动取冻结值；CLI 与冻结不等拒绝；证据在策略未冻结拒绝
#     T9 --skip-p2a 合法化
#     T10 reconcile 停驻钉（rc=0 不假报全过）
set -uo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
R="$ROOT/scripts/refresh-receipts.sh"
LIB="$ROOT/scripts/refresh_receipts_lib.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "[FAIL] $1"; }
hash_fn() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
# shellcheck source=py_runtime.sh
. "$ROOT/scripts/py_runtime.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/refresh-receipts-test.XXXXXX")"
if [ "${RR_KEEP:-0}" = "1" ]; then echo "[keep] TMP=$TMP"; else trap 'rm -rf "$TMP"' EXIT; fi

# ── 静态负向（无需工作区）──
_out=$(bash "$R" fx --bogus-flag 2>&1); _rc=$?
if [ "$_rc" = "2" ] && printf '%s' "$_out" | grep -q "用法"; then
  ok "T1 未知参数拒绝（exit 2 + 用法）"
else
  bad "T1 未知参数未正确拒绝（rc=${_rc}）"
fi

for _opt in --prd --evidence --service --design-mode --migration; do
  _out=$(bash "$R" fx "$_opt" 2>&1); _rc=$?
  if [ "$_rc" = "2" ] && ! printf '%s' "$_out" | grep -q "unbound"; then
    ok "T2 ${_opt} 缺参拒绝（exit 2，无 unbound）"
  else
    bad "T2 ${_opt} 缺参处理异常（rc=${_rc}）"
  fi
done

_out=$(bash "$R" "../escape" 2>&1); _rc=$?
[ "$_rc" = "2" ] && ok "T3 路径穿越 feature 拒绝（exit 2）" || bad "T3 路径穿越未拒绝（rc=${_rc}）"

_missing=""
for _g in s0 P0b P1 design s2 P2a P2b P3build P3 P3b P3cd P4 P4b P5 s5mig s6acc p6cred s6final P7 P8 P9 P10; do
  grep -qE "^[[:space:]]*gate ${_g}( |$)" "$LIB" || _missing="$_missing $_g"
done
[ -z "$_missing" ] && ok "T4 Gate 清单覆盖 22 Gate（P0→P10，s5mig 单场景）" || bad "T4 Gate 清单缺失:$_missing"
grep -q 'reconcile "$FEATURE" --apply' "$LIB" \
  && ok "T4 reconcile --apply 已接线" || bad "T4 缺 reconcile --apply"
grep -q "current_phase 未达 COMPLETED\|state COMPLETED" "$LIB" \
  && grep -q "Gate 非零立即停止" "$LIB" \
  && ok "T4 终验 COMPLETED + 失败即停语义在案" || bad "T4 缺终验/失败即停语义"
# v3.29.4: 生产入口 Gate 替换后门必须移除（只查非注释行——移除说明本身不应触发）
if ! grep -qE "^[^#]*DEVFLOW_REFRESH_GATE_DIR" "$R" \
   && grep -q 'RF_GATE_BIN="$SKILL/scripts"' "$R" \
   && ! grep -qE "^[^#]*DEVFLOW_REFRESH_GATE_DIR" "$LIB"; then
  ok "T4 生产 Gate 替换后门已移除（RF_GATE_BIN 固定）"
else
  bad "T4 生产入口仍可经环境变量替换 Gate（绕过构建/审查/P6-final）"
fi

# ── 测试桩 Gate 工厂 ──
make_stub_gates() { # <dir>
  local d="$1"; mkdir -p "$d"
  local common
  common='LOG="${RC_LOG:?}"; VER="${RC_VER:?}"; TREE="${RC_TREE:?}"
hash_fn() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk "{print \$1}"; else sha256sum "$1" | awk "{print \$1}"; fi; }
EVID=".devflow/fx/evidence-stub.txt"
ESH=$(hash_fn "$PWD/$EVID" 2>/dev/null)
binds_for() { # <ph> → 该收据目录对应的必备 TAG 集（v3.30.4 映射）
  case "$1" in
    P0) printf "ACCEPTANCE\\n" ;;
    P0b) printf "PRD_REVIEW\\n" ;;
    P1) printf "TECH_SELECTION\\nCLARIFICATION\\nCONSTRAINTS\\n" ;;
    P2a) printf "DESIGN_REVIEW\\n" ;;
    P2b) printf "DEMO_SIGNOFF\\n" ;;
    P3) printf "SELF_CHECK\\n" ;;
    P3cd) printf "SECURITY\\nPERFORMANCE\\n" ;;
    P3b) printf "CODE_REVIEW\\n" ;;
    P4) printf "PRD_VALIDATION\\n" ;;
    P5) printf "TEST_CASES\\n" ;;
    P7) printf "DEPLOYMENT\\n" ;;
    P8) printf "MONITORING\\n" ;;
    P9) printf "DOCS_INDEX\\n" ;;
    P10) printf "RETROSPECTIVE\\nSHARING\\n" ;;
  esac
}
emit() { # <path-phase> <version> [extra-lines] [phase-line 覆盖]
  local ph="$1" ver="$2" extra="${3:-}"
  local pl="${4:-$ph}"
  local d=".devflow/fx/gates/$ph"
  local _bt
  mkdir -p "$d" "docs/fx/gates/$ph"
  { printf "EXIT_CODE=0\nVERSION=%s\nPHASE=%s\nSKILL_TREE=%s\n" "$ver" "$pl" "$TREE"
    [ -n "$extra" ] && printf "%b\n" "$extra"
    while IFS= read -r _bt; do
      [ -n "$_bt" ] || continue
      printf "%s_JSON=%s/.devflow/fx/evidence-stub.txt\n%s_JSON_SHA256=%s\n" "$_bt" "$PWD" "$_bt" "$ESH"
    done < <(binds_for "$ph")
    printf "PASS=1 FAIL=0 WARN=0\nCHECKED_AT=2026-09-22T00:00:00Z\n"
  } > "$d/receipt.txt"
  cp "$d/receipt.txt" "docs/fx/gates/$ph/receipt.txt"
}
evbind() { printf "EVIDENCE_PATH=%s\nEVIDENCE_SHA256=%s\n" "$EVID" "$ESH"; }'

  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "s0 %s\n" "$*" >> "$LOG"; emit P0 "g@$VER"'; } > "$d/s0_acceptance_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "artifact %s %s\n" "$1" "$2" >> "$LOG"'
    echo 'case "$1" in P0b|P7|P8|P9) emit "$1" "g@$VER" "$(evbind)";; *) exit 2;; esac'; } > "$d/artifact_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "s1 %s\n" "$*" >> "$LOG"; emit P1 "g@$VER"'; } > "$d/s1_fact_sources_gate.sh"
  cat > "$d/df_pipeline.py" <<'PYEOF'
#!/usr/bin/env python3
import os
with open(os.environ["RC_LOG"], "a") as f:
    f.write("design " + " ".join(os.sys.argv[1:]) + "\n")
PYEOF
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "s2 %s\n" "$*" >> "$LOG"; emit P2 "g@$VER"'; } > "$d/s2_design_coverage_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p2a %s\n" "$*" >> "$LOG"; emit P2a "g@$VER"'; } > "$d/p2a_design_review_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p2b %s\n" "$*" >> "$LOG"; emit P2b "g@$VER"'; } > "$d/p2b_demo_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p3build %s\n" "$*" >> "$LOG"; exit 0'; } > "$d/build-watchdog.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p3 %s\n" "$*" >> "$LOG"; emit P3 "g@$VER"'; } > "$d/p3_completion_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "p3b %s\n" "$*" >> "$LOG"; emit P3b "g@$VER" "$(evbind)"; emit ARCH-PITFALLS "g@$VER" "$(evbind)"'; } > "$d/p3b_code_review_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "p3cd %s\n" "$*" >> "$LOG"; emit P3cd "g@$VER" "$(evbind)" P3cd'; } > "$d/p3_security_perf_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "p4 %s\n" "$*" >> "$LOG"'
    echo 'ETREE=$(printf "%s  %s\n" "$ESH" "$EVID" | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; } | awk "{print \$1}")'
    echo 'emit P4 "p4-validation@$VER" "EVIDENCE_PATHS_JSON=[\"$EVID\"]\nEVIDENCE_TREE_SHA256=$ETREE\n"'; } > "$d/p4_validation_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p4b %s\n" "$*" >> "$LOG"; emit P4b "g@$VER" "$(evbind)"'; } > "$d/p4_prd_vs_code.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "p5 %s\n" "$*" >> "$LOG"'
    echo 'if [ "${RC_BREAK_PHASE:-}" = "P5" ]; then emit P5 "g@0.0.1" "$(evbind)"; else emit P5 "g@$VER" "$(evbind)"; fi'; } > "$d/p5_test_cases_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "s5mig %s\n" "$*" >> "$LOG"; mkdir -p .devflow/fx/gates/P5-migration docs/fx/gates/P5-migration'
    echo '{ printf "EXIT_CODE=0\nVERSION=g@%s\nPHASE=P5-migration\nSKILL_TREE=%s\nSCENARIO=%s\nPASS=1 FAIL=0 WARN=0\n" "$VER" "$TREE" "$2"; } > .devflow/fx/gates/P5-migration/receipt.txt'
    echo 'cp .devflow/fx/gates/P5-migration/receipt.txt docs/fx/gates/P5-migration/receipt.txt'; } > "$d/s5_migration_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "s6acc %s\n" "$*" >> "$LOG"; exit 0'; } > "$d/s6_first_pass_accuracy.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p6cred %s\n" "$*" >> "$LOG"; emit P6-credential "p6-credential@$VER"'; } > "$d/p6_credential_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "s6final %s\n" "$*" >> "$LOG"; emit P6 "g@$VER"; emit P6-final "g@$VER" "$(evbind)"'; } > "$d/s6_final_verification_gate.sh"
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p10 %s\n" "$*" >> "$LOG"; emit P10 "g@$VER" "$(evbind)"'; } > "$d/p10_feedback_gate.sh"
  chmod +x "$d"/*.sh "$d"/*.py
}

write_design_json() { # <ws> <applicable> <strategy> —— 写冻结迁移策略正本
  local w="$1" app="$2" strat="${3:-}"
  mkdir -p "$w/.devflow/fx"
  local mig="'applicable': ${app}"
  if [ "$app" = "True" ]; then mig="$mig, 'strategy': '${strat}', 'dialects': ['h2','postgresql','oracle','kingbase']"
  else mig="$mig, 'not_applicable_reason': '无数据迁移'"; fi
  (python3 -c "import json,sys; print(json.dumps({'feature':'fx','migrations':{$mig}}))") > "$w/.devflow/fx/design.json"
}

init_fixture() { # <ws> <applicable> <strategy>
  local w="$1" app="${2:-True}" strat="${3:-B}"
  mkdir -p "$w/.devflow/fx"
  printf 'stub-evidence\n' > "$w/.devflow/fx/evidence-stub.txt"
  (cd "$w" && bash "$ROOT/scripts/devflow-state.sh" init fx --frontend=not-applicable >/dev/null 2>&1)
  [ -f "$w/.devflow/fx.state.json" ] || { echo "[test] state init 失败: $w" >&2; return 1; }
  write_design_json "$w" "$app" "$strat"
  RC_VER=$(bash "$ROOT/scripts/gate-version.sh" 2>/dev/null)
  RC_TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh" 2>/dev/null)
  RC_LOG="$w/invocations.log"; : > "$RC_LOG"
  export RC_LOG RC_VER RC_TREE
}

run_orch() { # <ws> [extra source args] —— source py_runtime+库；注入桩 Gate 目录（非环境变量后门）
  local w="$1"; shift
  (cd "$w" \
    && RF_SKILL="$ROOT" RF_ROOT="$w" RF_FEATURE="fx" \
       RF_GATE_BIN="$STUBS" env "$@" \
       bash -c '. "$1"; . "$2"; refresh_receipts_run' _ "$ROOT/scripts/py_runtime.sh" "$LIB" 2>&1)
}

# ── T5 真实 s0 失败即停 ──
W5="$TMP/t5"; mkdir -p "$W5"
(cd "$W5" && bash "$ROOT/scripts/devflow-state.sh" init fx --frontend=not-applicable >/dev/null 2>&1)
_out=$(cd "$W5" && bash "$R" fx 2>&1); _rc=$?
_logroot=$(ls -td "$W5"/.devflow/fx/refresh-logs/* 2>/dev/null | head -1)
if [ "$_rc" = "1" ] && [ -n "$_logroot" ] \
   && [ -f "$_logroot/s0.log" ] \
   && [ "$(ls "$_logroot" | wc -l | tr -d ' ')" = "1" ]; then
  ok "T5 失败即停：真实 s0 失败 exit 1，后续 Gate 未执行（日志数=1）"
else
  _n=$([ -n "$_logroot" ] && ls "$_logroot" | wc -l | tr -d ' ' || echo 0)
  bad "T5 fail-fast 行为异常（rc=${_rc}, 日志数=${_n}）"
fi

STUBS="$TMP/stubs"; make_stub_gates "$STUBS"

# ── T6 全链正向（冻结策略 B）──
W6="$TMP/t6"; init_fixture "$W6" True B || exit 1
_out=$(run_orch "$W6"); _rc=$?
_phase=$(jq -r '.current_phase // ""' "$W6/.devflow/fx.state.json" 2>/dev/null)
_s5mig_n=$(grep -c "^s5mig " "$RC_LOG" 2>/dev/null || true)
if [ "$_rc" = "0" ] && [ "$_phase" = "COMPLETED" ] && [ "${_s5mig_n:-0}" = "1" ] \
   && grep -q "^s5mig fx B " "$RC_LOG"; then
  ok "T6 全链正向：exit 0 + COMPLETED + 冻结策略 B 单次"
else
  bad "T6 全链正向异常（rc=${_rc}, phase=${_phase}, s5mig=${_s5mig_n:-0}）: $(printf '%s' "$_out" | tail -3)"
fi
_l_s0=$(grep -n "^s0 " "$RC_LOG" | head -1 | cut -d: -f1)
_l_p10=$(grep -n "^p10 " "$RC_LOG" | head -1 | cut -d: -f1)
_l_p5=$(grep -n "^p5 " "$RC_LOG" | head -1 | cut -d: -f1)
if [ -n "${_l_s0:-}" ] && [ -n "${_l_p5:-}" ] && [ -n "${_l_p10:-}" ] \
   && [ "$_l_s0" -lt "$_l_p5" ] && [ "$_l_p5" -lt "$_l_p10" ]; then
  ok "T6 执行序 P0→P5→P10 依赖序正确"
else
  bad "T6 执行序异常（s0=${_l_s0:-无}, p5=${_l_p5:-无}, p10=${_l_p10:-无}）"
fi

# ── T7 树漂移 ──
W7="$TMP/t7"; init_fixture "$W7" True B
jq '.scope.skill_tree_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$W7/.devflow/fx.state.json" > "$W7/s.tmp" && mv "$W7/s.tmp" "$W7/.devflow/fx.state.json"
_out=$(run_orch "$W7"); _rc=$?
if [ "$_rc" = "1" ] && printf '%s' "$_out" | grep -q "migrate-tree"; then
  ok "T7a 树漂移拒绝并指示显式迁移"
else
  bad "T7a 树漂移未拒绝（rc=${_rc}）: $(printf '%s' "$_out" | tail -2)"
fi

# ── T8 冻结策略语义 ──
W8="$TMP/t8"; init_fixture "$W8" True B
: > "$RC_LOG"
_out=$(run_orch "$W8"); _rc=$?
if [ "$_rc" = "0" ] && grep -q "^s5mig fx B " "$RC_LOG"; then
  ok "T8a CLI 省略时自动取冻结策略 B（s5mig 单次 B）"
else
  bad "T8a 未自动取冻结策略（rc=${_rc}）"
fi

W8B="$TMP/t8b"; init_fixture "$W8B" True B
RC_LOG="$W8B/invocations.log"; export RC_LOG
_out=$(run_orch "$W8B" RF_MIGRATION="A"); _rc=$?
if [ "$_rc" = "1" ] && printf '%s' "$_out" | grep -q "≠ 冻结策略 B"; then
  ok "T8b CLI A ≠ 冻结 B → 拒绝（命令行不是事实源）"
else
  bad "T8b CLI 与冻结不等未拒绝（rc=${_rc}）"
fi

W8C="$TMP/t8c"; init_fixture "$W8C" False
RC_LOG="$W8C/invocations.log"; export RC_LOG
mkdir -p "$W8C/docs/测试"
printf 'scenario=B\n' > "$W8C/docs/测试/fx-migration-evidence.env"
_out=$(run_orch "$W8C"); _rc=$?
if [ "$_rc" = "1" ] && printf '%s' "$_out" | grep -q "证据在而策略未冻结"; then
  ok "T8c 迁移证据在但冻结策略缺失 → 拒绝（状态不一致）"
else
  bad "T8c 证据/策略不一致未拒绝（rc=${_rc}）"
fi

W8D="$TMP/t8d"; init_fixture "$W8D" False
RC_LOG="$W8D/invocations.log"; export RC_LOG
_out=$(run_orch "$W8D" RF_MIGRATION="B"); _rc=$?
if [ "$_rc" = "1" ] && printf '%s' "$_out" | grep -q "design.json 未冻结迁移策略"; then
  ok "T8d 无冻结策略时 CLI 自报 --migration → 拒绝"
else
  bad "T8d 无冻结自报未拒绝（rc=${_rc}）"
fi

# T8e（v3.29.5）: 冻结策略 A + 遗留迁移证据冲突
W8E="$TMP/t8e"; init_fixture "$W8E" True A
RC_LOG="$W8E/invocations.log"; export RC_LOG
mkdir -p "$W8E/docs/测试"
printf 'scenario=C\n' > "$W8E/docs/测试/fx-migration-evidence.env"
_out=$(run_orch "$W8E"); _rc=$?
if [ "$_rc" = "1" ] && printf '%s' "$_out" | grep -q "遗留迁移证据\|stale-evidence"; then
  ok "T8e 冻结 A + 遗留证据 → FAIL（stale-evidence 冲突）"
else
  bad "T8e A-证据冲突未拒绝（rc=${_rc}）"
fi
W9="$TMP/t9"; init_fixture "$W9" True B
RC_LOG="$W9/invocations.log"; export RC_LOG
_out=$(run_orch "$W9" RF_SKIP_P2A=1); _rc=$?
if [ "$_rc" = "1" ] && printf '%s' "$_out" | grep -q "SKIP_P2a="; then
  ok "T9a --skip-p2a 无授权行 → 拒绝（附契约说明）"
else
  bad "T9a 无授权行未拒绝（rc=${_rc}）"
fi
printf 'SKIP_P2a=评审密钥未配置|authorized-by=huymac|at=2026-09-22|approval=meeting-minutes-42\n' \
  > "$W9/.devflow/fx/skip-log.txt"
: > "$RC_LOG"
_out=$(run_orch "$W9" RF_SKIP_P2A=1); _rc=$?
_phase=$(jq -r '.current_phase // ""' "$W9/.devflow/fx.state.json" 2>/dev/null)
_skipped=$(grep -c "^SKIPPED=1" "$W9/.devflow/fx/gates/P2a/receipt.txt" 2>/dev/null || true)
_p2a_n=$(grep -c "^p2a " "$RC_LOG" 2>/dev/null || true)
if [ "$_rc" = "0" ] && [ "$_phase" = "COMPLETED" ] && [ "${_skipped:-0}" = "1" ] && [ "${_p2a_n:-0}" = "0" ]; then
  ok "T9b 合法授权跳过：SKIPPED 收据落位、P2a Gate 未调用、推进 COMPLETED"
else
  bad "T9b 合法跳过异常（rc=${_rc}, phase=${_phase}, SKIPPED=${_skipped:-0}, p2a=${_p2a_n:-0}）"
fi

# ── T10 reconcile 停驻钉 ──
W10="$TMP/t10"; init_fixture "$W10" True B
RC_LOG="$W10/invocations.log"; export RC_LOG
_out=$(run_orch "$W10" RC_BREAK_PHASE=P5); _rc=$?
_phase=$(jq -r '.current_phase // ""' "$W10/.devflow/fx.state.json" 2>/dev/null)
if [ "$_rc" = "1" ] && [ "$_phase" != "COMPLETED" ] && printf '%s' "$_out" | grep -q "COMPLETED"; then
  ok "T10 停驻钉：坏收据停驻 → FAIL（不假报全过）"
else
  bad "T10 停驻未被发现（rc=${_rc}, phase=${_phase}）"
fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
