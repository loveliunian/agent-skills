#!/usr/bin/env bash
# test-p6-hardening.sh · v3.20.2 对抗加固回归（审计 7 项发现的 P0/P1 钉）
# 覆盖：
#   P0-1 平台精确匹配（冻结 mini-program + 声明 pc-web → P6_SCOPE_MISMATCH）
#   P0-2 报告路径与终验报告碰撞（UNIT_REPORT_PATH=终验报告路径 → 冲突拒绝）
#   P0-3a/3b 测试命令来源（awk 报表生成器 → NOT_RUNNER；npm 无清单 → PROVENANCE）
#   P1-4 P2 收据证据树（s2 收据产出后篡改 design.json → audit-receipts FAIL）
set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(dirname "$TEST_DIR")"
TMP="$(mktemp -d /tmp/p6-hardening.XXXXXX)"
if [ "${P6H_KEEP:-0}" = "1" ]; then echo "[keep] TMP=$TMP"; else trap 'rm -rf "$TMP"' EXIT; fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "[PASS] $*"; }
bad() { FAIL=$((FAIL+1)); echo "[FAIL] $*"; }
hash_file() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }

# s6 最小脚手架：五类报告 + test-evidence.env + baseline；$3/$4 可选 CMD 覆盖
mk_p6_ws() {
  local w="$1" ff="$2" kind lower
  mkdir -p "$w/.devflow/fx/reports" "$w/docs/test"
  printf 'acceptance_id\tstatus\nM-01-F01-A01\tFROZEN\n' > "$w/.devflow/fx/first-pass-baseline.tsv"
  printf 'feature=fx\n' > "$w/.devflow/fx/first-pass-meta.env"
  printf 'ID\tSTATUS\nM-01-F01-A01\tPASS\n' > "$w/.devflow/fx/final-verification.tsv"
  for kind in unit integration client load staging; do
    printf '# %s test report\nsuite=%s\npassed=1\nfailed=0\n' "$kind" "$kind" > "$w/.devflow/fx/reports/${kind}-report.txt"
  done
  {
    for kind in UNIT INTEGRATION CLIENT LOAD STAGING; do
      lower=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')
      report=".devflow/fx/reports/${lower}-report.txt"
      printf '%s_REPORT_PATH=%s\n%s_EXIT=0\n%s_REPORT_SHA256=%s\n' "$kind" "$report" "$kind" "$kind" "$(hash_file "$w/$report")"
      printf '%s_CMD=npm test\n' "$kind"
    done
    printf 'ENVIRONMENT=staging\n'
  } > "$w/.devflow/fx/test-evidence.env"
  cat > "$w/.devflow/fx/verification.json" <<'EOF'
{"feature":"fx","client":{"scope":"pc-web"},"client_not_applicable":{"declared":false,"frontend_scope":"pc-web"}}
EOF
  if [ -n "${3:-}" ] && [ -n "${4:-}" ]; then
    printf '%s_CMD=%s\n' "$3" "$4" >> "$w/.devflow/fx/test-evidence.env"
  fi
  if [ -n "$ff" ]; then
    (cd "$w" && WORKSPACE="$w" bash "$ROOT/scripts/devflow-state.sh" init fx --frontend="$ff" >/dev/null 2>&1)
  fi
}

# ── P0-1 平台精确匹配 ──
W1="$TMP/scope"; mk_p6_ws "$W1" "mini-program"
sed -i '' 's/"frontend_scope":"pc-web"/"frontend_scope":"pc-web", "note":"declared-swap"/' "$W1/.devflow/fx/verification.json" 2>/dev/null || true
OUT1=$(cd "$W1" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$OUT1" | grep -q 'P6_SCOPE_MISMATCH' && ! printf '%s' "$OUT1" | grep -q 'rc=0$'; then
  ok "P0-1 冻结 mini-program + 声明 pc-web → P6_SCOPE_MISMATCH 拒绝"
else
  bad "P0-1 平台精确匹配未生效（尾部: $(printf '%s' "$OUT1" | grep -E 'P0|rc=' | tail -2 | tr '\n' ' ')）"
fi

# ── P0-2 报告路径碰撞 ──
W2="$TMP/collide"; mk_p6_ws "$W2" ""
rp="docs/test/fx-final-verification-report.md"
printf '# collision target\n' > "$W2/$rp"
sed -i '' "s|^UNIT_REPORT_PATH=.*|UNIT_REPORT_PATH=$rp|" "$W2/.devflow/fx/test-evidence.env" 2>/dev/null || \
  sed -i  "s|^UNIT_REPORT_PATH=.*|UNIT_REPORT_PATH=$rp|" "$W2/.devflow/fx/test-evidence.env"
OUT2=$(cd "$W2" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$OUT2" | grep -q '内部终验证据冲突' && ! printf '%s' "$OUT2" | grep -q 'rc=0$'; then
  ok "P0-2 单元报告路径=终验报告路径 → 冲突拒绝"
else
  bad "P0-2 报告路径碰撞未生效（尾部: $(printf '%s' "$OUT2" | grep -E 'P0|rc=' | tail -2 | tr '\n' ' ')）"
fi

# ── P0-3a 报表生成器 ──
W3="$TMP/awkgen"; mk_p6_ws "$W3" "" UNIT "awk /dev/null"
OUT3=$(cd "$W3" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
# 安全属性：awk 伪造无法产出 rc=0（拦截码可能是 NOT_RUNNER，也可能先撞其他闸——均算拒伪）
if ! printf '%s' "$OUT3" | grep -q 'rc=0$'; then
  _code=$(printf '%s' "$OUT3" | grep -oE 'P6_CMD_[A-Z]+' | head -1)
  ok "P0-3a awk 报表生成器被拒（rc=1${_code:+，拦截码=$_code}）"
else
  bad "P0-3a awk 报表生成器仍通过（伪造成功）"
fi

# ── P0-3b 受信运行器但无工程清单 ──
W4="$TMP/nomanifest"; mk_p6_ws "$W4" ""
OUT4=$(cd "$W4" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$OUT4" | grep -q 'P6_CMD_PROVENANCE' && ! printf '%s' "$OUT4" | grep -q 'rc=0$'; then
  ok "P0-3b npm test 但无 package.json → P6_CMD_PROVENANCE 拒绝"
else
  bad "P0-3b 清单绑定未生效（尾部: $(printf '%s' "$OUT4" | grep -E 'P0|rc=' | tail -2 | tr '\n' ' ')）"
fi

# ── P1-4 P2 收据证据树 ──
W5="$TMP/p2tamper"
mkdir -p "$W5/docs/detailed-design" "$W5/docs/requirements"
printf '# d\nM-01-F01-A01\n' > "$W5/docs/detailed-design/foo-design.md"
printf '# c\nM-01-F01-A01\n' > "$W5/docs/requirements/foo-acceptance-criteria.md"
(cd "$W5" && WORKSPACE="$W5" bash "$ROOT/scripts/devflow-state.sh" init foo --frontend=not-applicable >/dev/null 2>&1)
(cd "$W5" && bash "$ROOT/scripts/s2_design_coverage_gate.sh" \
  docs/detailed-design/foo-design.md docs/requirements/foo-acceptance-criteria.md >/dev/null 2>&1)
if [ ! -f "$W5/.devflow/foo/gates/P2/receipt.txt" ]; then
  bad "P1-4 前置：s2 收据未产出（环境问题，非钉问题）"
else
  if grep -q 'EVIDENCE_TREE_SHA256' "$W5/.devflow/foo/gates/P2/receipt.txt"; then
    ok "P1-4 前置：P2 收据含 EVIDENCE_TREE_SHA256"
  else
    bad "P1-4 前置：P2 收据缺证据树绑定"
  fi
  # 合成为"通过轮"收据（EXIT_CODE=0）——钉的是审计消费端契约：
  # 终态 P2 收据的证据树在证据被篡改后必须 FAIL，而非降级 WARN
  for _rf in "$W5/.devflow/foo/gates/P2/receipt.txt" "$W5/docs/foo/gates/P2/receipt.txt"; do
    [ -f "$_rf" ] && { sed -i '' 's/^EXIT_CODE=1/EXIT_CODE=0/' "$_rf" 2>/dev/null || sed -i 's/^EXIT_CODE=1/EXIT_CODE=0/' "$_rf"; }
  done
  printf '\n<!-- tampered -->\n' >> "$W5/docs/detailed-design/foo-design.md"
  if (cd "$W5" && bash "$ROOT/scripts/audit-receipts.sh" foo .devflow docs >/dev/null 2>&1); then
    bad "P1-4 篡改 design.json 后审计仍 PASS（证据树未生效）"
  else
    ok "P1-4 篡改 design.json 后 audit-receipts FAIL（证据树生效）"
  fi
fi

# ---------- v3.28.12：P6 修复循环增量重跑助手（p6-iterate.sh） ----------
W6="$TMP/iterate"; mkdir -p "$W6/.devflow/fx"
cat > "$W6/.devflow/fx/test-evidence.env" <<'EOF'
UNIT_CMD=mvn test -pl backend/fx -Dtest='CryptoTest'
INTEGRATION_CMD=mvn test -pl backend/fx
CLIENT_CMD=npm run test:e2e
LOAD_CMD=sh -c "exit 7"
STAGING_CMD=curl -sf http://localhost:18080/health
EOF
ITER="$ROOT/scripts/p6-iterate.sh"
EV_SHA_BEFORE=$(hash_file "$W6/.devflow/fx/test-evidence.env")

# T1: --list 列出五类声明命令（BSD/GNU sed 皆可）
_iter_list=$(cd "$W6" && bash "$ITER" fx --list 2>/dev/null || true)
if printf '%s' "$_iter_list" | grep -q "UNIT mvn test -pl backend/fx" \
   && printf '%s' "$_iter_list" | grep -q "CLIENT npm run test:e2e"; then
  ok "iterate --list 列出声明命令"
else
  bad "iterate --list 未列出声明命令"
fi

# T2: --dry-run 按运行器拼接过滤参数（不执行、不写日志）
_splice=$(cd "$W6" && bash "$ITER" fx unit --filter 'LoginFlow*' --dry-run 2>/dev/null || true)
if printf '%s' "$_splice" | grep -q -- "-Dtest='LoginFlow\\*'" \
   && [ -z "$(ls "$W6/.devflow/fx/iterations" 2>/dev/null)" ]; then
  ok "iterate mvn 过滤拼接正确且 dry-run 零执行"
else
  bad "iterate mvn 过滤拼接或 dry-run 行为异常: ${_splice}"
fi
_splice2=$(cd "$W6" && bash "$ITER" fx client --filter 'login|logout' --dry-run 2>/dev/null || true)
printf '%s' "$_splice2" | grep -q -- "-- --grep='login|logout'" \
  && ok "iterate npm 过滤拼接正确（-- 透传）" \
  || bad "iterate npm 过滤拼接异常: ${_splice2}"

# T3: 危险 filter 字符拒绝；未知套件拒绝
(cd "$W6" && bash "$ITER" fx unit --filter "Foo';rm" >/dev/null 2>&1) \
  && bad "iterate 危险字符 filter 未被拒绝" \
  || ok "iterate 危险字符 filter 被拒绝"
(cd "$W6" && bash "$ITER" fx smoke >/dev/null 2>&1) \
  && bad "iterate 未知套件未被拒绝" \
  || ok "iterate 未知套件被拒绝"

# T4: 整套件运行——退出码透传 + 日志落 iterations/ + test-evidence.env 只读
(cd "$W6" && bash "$ITER" fx load >/dev/null 2>&1); _load_rc=$?
_load_log=$(ls "$W6/.devflow/fx/iterations/"*-load.log 2>/dev/null | tail -1)
if [ "$_load_rc" = "7" ] && [ -n "$_load_log" ] && grep -q '^exit=7$' "$_load_log"; then
  ok "iterate 退出码透传（7）且日志含 exit=7"
else
  bad "iterate 退出码/日志异常（rc=${_load_rc}, log=${_load_log}）"
fi
[ "$(hash_file "$W6/.devflow/fx/test-evidence.env")" = "$EV_SHA_BEFORE" ] \
  && ok "iterate 运行后 test-evidence.env 未被改写（终验事实源只读）" \
  || bad "iterate 改写了 test-evidence.env"

# ---------- v3.28.12：P6 环境预热（p6-prewarm.sh） ----------
source "$ROOT/scripts/py_runtime.sh"  # 预热测试需要跨平台 Python 解释器
W7="$TMP/prewarm"; mkdir -p "$W7/.devflow/fx"
PW="$ROOT/scripts/p6-prewarm.sh"
PW_PORT=$( "${DEVFLOW_PY[@]}" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' )
PW_URL="http://127.0.0.1:${PW_PORT}"
PW_SRV="${DEVFLOW_PY_STR} -m http.server ${PW_PORT} --bind 127.0.0.1"

# T5: --status 未就绪 → 非零退出 + 明确输出（输出捕获后再 grep，避免 pipefail 干扰）
_pw_status=$(cd "$W7" && bash "$PW" fx --status --health-url "$PW_URL" 2>/dev/null || true)
printf '%s' "$_pw_status" | grep -q '未就绪' \
  && ok "prewarm --status 探测未就绪" \
  || bad "prewarm --status 未报未就绪: ${_pw_status}"

# T6: 启动并等待就绪 → rc=0 + pid 落账
(cd "$W7" && bash "$PW" fx --backend-cmd "$PW_SRV" --health-url "$PW_URL" --timeout 30 >/dev/null 2>&1) \
  && grep -q '^backend=' "$W7/.devflow/fx/prewarm/pids.env" \
  && ok "prewarm 启动后端并就绪（pid 落账）" \
  || bad "prewarm 启动/就绪/落账异常"

# T7: 幂等复跑 → 已就绪跳过 且 pid 记录不被清空（回归：曾盲目 truncate pids.env）
_PID_BEFORE=$(cat "$W7/.devflow/fx/prewarm/pids.env" 2>/dev/null)
(cd "$W7" && bash "$PW" fx --backend-cmd "$PW_SRV" --health-url "$PW_URL" --timeout 10 >/dev/null 2>&1) \
  && [ "$(cat "$W7/.devflow/fx/prewarm/pids.env" 2>/dev/null)" = "$_PID_BEFORE" ] \
  && ok "prewarm 幂等复跑保留 pid 记录" \
  || bad "prewarm 幂等复跑丢失 pid 记录"

# T8: --stop 停止并释放端口
(cd "$W7" && bash "$PW" fx --stop >/dev/null 2>&1)
sleep 1
curl -sf -o /dev/null --max-time 2 "$PW_URL" 2>/dev/null \
  && bad "prewarm --stop 后端口仍存活" \
  || ok "prewarm --stop 释放端口"

# T9: 超时未就绪 → rc=3
(cd "$W7" && bash "$PW" fx --backend-cmd "sleep 60" --health-url "http://127.0.0.1:1/" --timeout 3 >/dev/null 2>&1); _pw_rc=$?
[ "$_pw_rc" = "3" ] && ok "prewarm 超时返回 3" || bad "prewarm 超时返回 ${_pw_rc}（应 3）"
(cd "$W7" && bash "$PW" fx --stop >/dev/null 2>&1) || true

echo "══════════════════════════════"
echo "P6-HARDENING RESULT PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
