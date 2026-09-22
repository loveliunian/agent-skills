#!/usr/bin/env bash
# test-refresh-receipts.sh · refresh-receipts.sh 回归（v3.29.3）
#   负向：T1 未知参数 / T2 缺参 / T3 路径穿越
#   清单：T4 22 Gate 静态声明对账 + reconcile --apply + 失败即停语义
#   动态：T5 真实 s0 失败即停（仅首个 Gate 被执行）
#   编排（测试桩 Gate + 真实状态机）：
#     T6 全链正向：init → 22 Gate → reconcile → current_phase=COMPLETED；s5mig 单次
#     T7 树漂移：无 --migrate-tree 拒绝并指示显式迁移；有则留痕收据后继续
#     T8 场景互斥：--migration A 跳过；有证据未指定场景拒绝（不再 B/C 双跑）
#     T9 --skip-p2a 合法化：无授权行拒绝；有则写 SKIPPED 收据且不调用 P2a
#     T10 reconcile 停驻钉：坏版本收据 → 刷新必须 FAIL（不再把 rc=0 当全过）
set -uo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
R="$ROOT/scripts/refresh-receipts.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "[FAIL] $1"; }
hash_fn() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

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
  grep -qE "^[[:space:]]*gate ${_g}( |$)" "$R" || _missing="$_missing $_g"
done
[ -z "$_missing" ] && ok "T4 Gate 清单覆盖 22 Gate（P0→P10，s5mig 单场景）" || bad "T4 Gate 清单缺失:$_missing"
grep -q 'reconcile "$FEATURE" --apply' "$R" \
  && ok "T4 reconcile --apply 已接线" || bad "T4 缺 reconcile --apply"
grep -q 'COMPLETED' "$R" && grep -q "Gate 非零立即停止" "$R" \
  && ok "T4 终验 COMPLETED + 失败即停语义在案" || bad "T4 缺终验/失败即停语义"

# ── 测试桩 Gate 工厂 ──
make_stub_gates() { # <dir>
  local d="$1"; mkdir -p "$d"
  local common
  common='LOG="${RC_LOG:?}"; VER="${RC_VER:?}"; TREE="${RC_TREE:?}"
hash_fn() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk "{print \$1}"; else sha256sum "$1" | awk "{print \$1}"; fi; }
EVID=".devflow/fx/evidence-stub.txt"
ESH=$(hash_fn "$PWD/$EVID" 2>/dev/null)
emit() { # <path-phase> <version> [extra-lines] [phase-line 覆盖]（P3c/P3d 收据 PHASE 须字面 P3cd）
  # 两条 local：bash 同一 local 语句内后项展开时前项未赋值（ph 需先落定）
  local ph="$1" ver="$2" extra="${3:-}"
  local pl="${4:-$ph}"
  local d=".devflow/fx/gates/$ph"
  mkdir -p "$d" "docs/fx/gates/$ph"
  { printf "EXIT_CODE=0\nVERSION=%s\nPHASE=%s\nSKILL_TREE=%s\n" "$ver" "$pl" "$TREE"
    [ -n "$extra" ] && printf "%b\n" "$extra"   # $(evbind) 会剥尾部换行——补回
    printf "PASS=1 FAIL=0 WARN=0\nCHECKED_AT=2026-09-22T00:00:00Z\n"
  } > "$d/receipt.txt"
  cp "$d/receipt.txt" "docs/fx/gates/$ph/receipt.txt"
}
evbind() { printf "EVIDENCE_PATH=%s\nEVIDENCE_SHA256=%s\n" "$EVID" "$ESH"; }'

  # s0 → P0（覆盖 state-init 基线）
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "s0 %s\n" "$*" >> "$LOG"; emit P0 "g@$VER"'; } > "$d/s0_acceptance_gate.sh"
  # artifact_gate：按 $1 写 P0b/P7/P8/P9（old 契约 → 证据绑定）
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "artifact %s %s\n" "$1" "$2" >> "$LOG"'
    echo 'case "$1" in P0b|P7|P8|P9) emit "$1" "g@$VER" "$(evbind)";; *) exit 2;; esac'; } > "$d/artifact_gate.sh"
  # s1 → P1
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "s1 %s\n" "$*" >> "$LOG"; emit P1 "g@$VER"'; } > "$d/s1_fact_sources_gate.sh"
  # df_pipeline.py（design 渲染校验）→ 只记录不产收据
  cat > "$d/df_pipeline.py" <<'PYEOF'
#!/usr/bin/env python3
import os
with open(os.environ["RC_LOG"], "a") as f:
    f.write("design " + " ".join(os.sys.argv[1:]) + "\n")
PYEOF
  # s2 → P2
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "s2 %s\n" "$*" >> "$LOG"; emit P2 "g@$VER"'; } > "$d/s2_design_coverage_gate.sh"
  # p2a → P2a（--skip-p2a 合法路径下不得被调用）
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p2a %s\n" "$*" >> "$LOG"; emit P2a "g@$VER"'; } > "$d/p2a_design_review_gate.sh"
  # p2b → P2b
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p2b %s\n" "$*" >> "$LOG"; emit P2b "g@$VER"'; } > "$d/p2b_demo_gate.sh"
  # build-watchdog → P3-build 标记（不在 RECONCILE_ORDER）
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p3build %s\n" "$*" >> "$LOG"; exit 0'; } > "$d/build-watchdog.sh"
  # p3_completion → P3
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p3 %s\n" "$*" >> "$LOG"; emit P3 "g@$VER"'; } > "$d/p3_completion_gate.sh"
  # p3b → P3b（new 契约证据绑定）+ ARCH-PITFALLS（P3b 推进复查项）
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "p3b %s\n" "$*" >> "$LOG"; emit P3b "g@$VER" "$(evbind)"; emit ARCH-PITFALLS "g@$VER" "$(evbind)"'; } > "$d/p3b_code_review_gate.sh"
  # p3_security_perf → P3c+P3d（PHASE=P3cd，old 契约）
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "p3cd %s\n" "$*" >> "$LOG"; emit P3cd "g@$VER" "$(evbind)" P3cd'; } > "$d/p3_security_perf_gate.sh"
  # p4_validation → P4（new 特殊：PATHS_JSON + 树哈希）
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "p4 %s\n" "$*" >> "$LOG"'
    echo 'ETREE=$(printf "%s  %s\n" "$ESH" "$EVID" | hash_fn /dev/stdin 2>/dev/null || printf "%s  %s\n" "$ESH" "$EVID" | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; } | awk "{print \$1}")'
    echo 'emit P4 "p4-validation@$VER" "EVIDENCE_PATHS_JSON=[\"$EVID\"]\nEVIDENCE_TREE_SHA256=$ETREE\n"'; } > "$d/p4_validation_gate.sh"
  # p4_prd_vs_code → P4b（old4b）
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p4b %s\n" "$*" >> "$LOG"; emit P4b "g@$VER" "$(evbind)"'; } > "$d/p4_prd_vs_code.sh"
  # p5_test_cases → P5（RC_BREAK_PHASE=P5 时写坏版本收据——钉 reconcile 停驻）
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "p5 %s\n" "$*" >> "$LOG"'
    echo 'if [ "${RC_BREAK_PHASE:-}" = "P5" ]; then emit P5 "g@0.0.1" "$(evbind)"; else emit P5 "g@$VER" "$(evbind)"; fi'; } > "$d/p5_test_cases_gate.sh"
  # s5_migration → P5-migration（记录场景参数）
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "s5mig %s\n" "$*" >> "$LOG"; mkdir -p .devflow/fx/gates/P5-migration docs/fx/gates/P5-migration'
    echo '{ printf "EXIT_CODE=0\nVERSION=g@%s\nPHASE=P5-migration\nSKILL_TREE=%s\nSCENARIO=%s\nPASS=1 FAIL=0 WARN=0\n" "$VER" "$TREE" "$2"; } > .devflow/fx/gates/P5-migration/receipt.txt'
    echo 'cp .devflow/fx/gates/P5-migration/receipt.txt docs/fx/gates/P5-migration/receipt.txt'; } > "$d/s5_migration_gate.sh"
  # s6_first_pass_accuracy → 仅标记
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "s6acc %s\n" "$*" >> "$LOG"; exit 0'; } > "$d/s6_first_pass_accuracy.sh"
  # p6_credential → P6-credential（专项校验：PASS/FAIL/WARN 行 + 双镜像）
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p6cred %s\n" "$*" >> "$LOG"; emit P6-credential "p6-credential@$VER"'; } > "$d/p6_credential_gate.sh"
  # s6_final → P6（ORDER 收据）+ P6-final（new 契约 + 镜像）
  { echo '#!/usr/bin/env bash'; echo "$common"
    echo 'printf "s6final %s\n" "$*" >> "$LOG"; emit P6 "g@$VER"; emit P6-final "g@$VER" "$(evbind)"'; } > "$d/s6_final_verification_gate.sh"
  # p10 → P10（old 契约）
  { echo '#!/usr/bin/env bash'; echo "$common"; echo 'printf "p10 %s\n" "$*" >> "$LOG"; emit P10 "g@$VER" "$(evbind)"'; } > "$d/p10_feedback_gate.sh"
  chmod +x "$d"/*.sh "$d"/*.py
}

init_fixture() { # <ws> —— 初始化工作区 + 状态机 + 桩环境
  local w="$1"
  mkdir -p "$w/.devflow/fx"
  printf 'stub-evidence\n' > "$w/.devflow/fx/evidence-stub.txt"
  (cd "$w" && bash "$ROOT/scripts/devflow-state.sh" init fx --frontend=not-applicable >/dev/null 2>&1)
  [ -f "$w/.devflow/fx.state.json" ] || { echo "[test] state init 失败: $w" >&2; return 1; }
  RC_VER=$(bash "$ROOT/scripts/gate-version.sh" 2>/dev/null)
  RC_TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh" 2>/dev/null)
  export RC_VER RC_TREE
  export RC_LOG="$w/invocations.log"; : > "$RC_LOG"
}

# ── T5 真实 s0 失败即停（真实 Gate，无桩）──
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

# ── T6 全链正向编排 ──
STUBS="$TMP/stubs"; make_stub_gates "$STUBS"
W6="$TMP/t6"; init_fixture "$W6"
_out=$(cd "$W6" && DEVFLOW_REFRESH_GATE_DIR="$STUBS" bash "$R" fx --migration B 2>&1); _rc=$?
_phase=$(jq -r '.current_phase // ""' "$W6/.devflow/fx.state.json" 2>/dev/null)
_s5mig_n=$(grep -c "^s5mig " "$RC_LOG" 2>/dev/null || true)
if [ "$_rc" = "0" ] && [ "$_phase" = "COMPLETED" ] && [ "${_s5mig_n:-0}" = "1" ] \
   && grep -q "^s5mig fx B " "$RC_LOG"; then
  ok "T6 全链正向：exit 0 + state COMPLETED + s5mig 单次且场景 B"
else
  bad "T6 全链正向异常（rc=${_rc}, phase=${_phase}, s5mig 次数=${_s5mig_n:-0}）: $(printf '%s' "$_out" | tail -3)"
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
W7="$TMP/t7"; init_fixture "$W7"
jq '.scope.skill_tree_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$W7/.devflow/fx.state.json" > "$W7/s.tmp" && mv "$W7/s.tmp" "$W7/.devflow/fx.state.json"
_out=$(cd "$W7" && DEVFLOW_REFRESH_GATE_DIR="$STUBS" bash "$R" fx --migration B 2>&1); _rc=$?
if [ "$_rc" = "1" ] && printf '%s' "$_out" | grep -q "migrate-tree"; then
  ok "T7a 树漂移拒绝并指示显式迁移"
else
  bad "T7a 树漂移未拒绝（rc=${_rc}）: $(printf '%s' "$_out" | tail -2)"
fi
_out=$(cd "$W7" && DEVFLOW_REFRESH_GATE_DIR="$STUBS" bash "$R" fx --migration B --migrate-tree 2>&1); _rc=$?
_phase=$(jq -r '.current_phase // ""' "$W7/.devflow/fx.state.json" 2>/dev/null)
if [ "$_rc" = "0" ] && [ "$_phase" = "COMPLETED" ] \
   && [ -f "$W7/.devflow/fx/gates/SKILL-TREE-MIGRATION/receipt.txt" ]; then
  ok "T7b --migrate-tree 显式迁移留痕后刷新完成"
else
  bad "T7b 迁移刷新异常（rc=${_rc}, phase=${_phase}）"
fi

# ── T8 场景互斥 ──
W8="$TMP/t8"; init_fixture "$W8"
mkdir -p "$W8/docs/测试"
printf 'scenario=B\n' > "$W8/docs/测试/fx-migration-evidence.env"
_out=$(cd "$W8" && DEVFLOW_REFRESH_GATE_DIR="$STUBS" bash "$R" fx 2>&1); _rc=$?
if [ "$_rc" = "1" ] && printf '%s' "$_out" | grep -q -- "--migration"; then
  ok "T8a 有迁移证据未指定场景 → 拒绝（不猜测 B/C）"
else
  bad "T8a 未指定场景未拒绝（rc=${_rc}）"
fi
: > "$RC_LOG"
_out=$(cd "$W8" && DEVFLOW_REFRESH_GATE_DIR="$STUBS" bash "$R" fx --migration A 2>&1); _rc=$?
_s5mig_n=$(grep -c "^s5mig " "$RC_LOG" 2>/dev/null || true)
if [ "$_rc" = "0" ] && [ "${_s5mig_n:-0}" = "0" ] && printf '%s' "$_out" | grep -q "\[SKIP\] s5mig"; then
  ok "T8b --migration A：显式 SKIP（免迁移收据）"
else
  bad "T8b 场景 A 处理异常（rc=${_rc}, s5mig 次数=${_s5mig_n:-0}）"
fi

# ── T9 --skip-p2a 合法化 ──
W9="$TMP/t9"; init_fixture "$W9"
_out=$(cd "$W9" && DEVFLOW_REFRESH_GATE_DIR="$STUBS" bash "$R" fx --skip-p2a --migration B 2>&1); _rc=$?
if [ "$_rc" = "1" ] && printf '%s' "$_out" | grep -q "SKIP_P2a="; then
  ok "T9a --skip-p2a 无授权行 → 拒绝（附契约说明）"
else
  bad "T9a 无授权行未拒绝（rc=${_rc}）"
fi
printf 'SKIP_P2a=评审密钥未配置|authorized-by=huymac|at=2026-09-22|approval=meeting-minutes-42\n' \
  > "$W9/.devflow/fx/skip-log.txt"
: > "$RC_LOG"
_out=$(cd "$W9" && DEVFLOW_REFRESH_GATE_DIR="$STUBS" bash "$R" fx --skip-p2a --migration B 2>&1); _rc=$?
_phase=$(jq -r '.current_phase // ""' "$W9/.devflow/fx.state.json" 2>/dev/null)
_skipped=$(grep -c "^SKIPPED=1" "$W9/.devflow/fx/gates/P2a/receipt.txt" 2>/dev/null || true)
_p2a_n=$(grep -c "^p2a " "$RC_LOG" 2>/dev/null || true)
if [ "$_rc" = "0" ] && [ "$_phase" = "COMPLETED" ] && [ "${_skipped:-0}" = "1" ] && [ "${_p2a_n:-0}" = "0" ]; then
  ok "T9b 合法授权跳过：SKIPPED 收据落位、P2a Gate 未调用、链仍推进至 COMPLETED"
else
  bad "T9b 合法跳过异常（rc=${_rc}, phase=${_phase}, SKIPPED=${_skipped:-0}, p2a 调用=${_p2a_n:-0}）"
fi

# ── T10 reconcile 停驻钉（rc=0 不再被当成全过）──
W10="$TMP/t10"; init_fixture "$W10"
_out=$(cd "$W10" && RC_BREAK_PHASE=P5 DEVFLOW_REFRESH_GATE_DIR="$STUBS" bash "$R" fx --migration B 2>&1); _rc=$?
_phase=$(jq -r '.current_phase // ""' "$W10/.devflow/fx.state.json" 2>/dev/null)
if [ "$_rc" = "1" ] && [ "$_phase" != "COMPLETED" ] && printf '%s' "$_out" | grep -q "COMPLETED"; then
  ok "T10 停驻钉：坏收据致 reconcile 停驻 → 刷新 FAIL（不假报全部通过）"
else
  bad "T10 停驻未被发现（rc=${_rc}, phase=${_phase}）"
fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
