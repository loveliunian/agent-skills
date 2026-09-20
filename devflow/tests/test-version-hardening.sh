#!/usr/bin/env bash
# test-version-hardening.sh · 历史版本硬化回归（v3.20.3 / v3.21.1 / v3.21.2 合并，v3.23.0 瘦身）
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
SKILL_VER=$(sed -n 's/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
hash_test() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
hash_file() { hash_test "$1"; }
echo "=== devflow 历史版本硬化回归 (v${SKILL_VER}) ==="

# ---------- v3.20.3：收据两阶段 / 图谱身份绑定 / manifest hash-chain ----------
RR="$ROOT/scripts/review-receipt.sh"

# 严格模式：测试进程扮演外部 attester，skill 只接收临时公钥。
openssl genrsa -out "$TMP/review-attester-private.pem" 2048 >/dev/null 2>&1 || { bad "生成测试 attester 私钥失败"; finish V3203_HARDENING; }
openssl rsa -in "$TMP/review-attester-private.pem" -pubout -out "$TMP/review-attester-public.pem" >/dev/null 2>&1 || { bad "生成测试 attester 公钥失败"; finish V3203_HARDENING; }
export REVIEW_ATTESTATION_PUBKEY="$TMP/review-attester-public.pem"
ATTEST_N=0
make_attestation() { # event role agent feature session input output destination
  local event="$1" role="$2" agent="$3" feature="$4" session="$5" input="$6" output="$7" dest="$8" input_sha output_sha payload sig
  ATTEST_N=$((ATTEST_N + 1))
  input_sha=$(hash_test "$input")
  output_sha=""
  [ "$event" = "begin" ] || output_sha=$(hash_test "$output")
  payload=$(jq -cn --arg feature "$feature" --arg session "$session" --arg role "$role" --arg agent "$agent" --arg event "$event" --arg input "$input_sha" --arg output "$output_sha" --arg nonce "testnonce-${ATTEST_N}-0123456789" \
    '{schema:"devflow-review-attestation-v1",feature:$feature,session_id:$session,role:$role,agent_id:$agent,event:$event,input_sha:$input,output_sha:$output,issued_at:"2026-09-16T00:00:00Z",nonce:$nonce}')
  printf '%s' "$payload" | jq -cS . > "$TMP/payload-${ATTEST_N}.json"
  openssl dgst -sha256 -sign "$TMP/review-attester-private.pem" -out "$TMP/sig-${ATTEST_N}.bin" "$TMP/payload-${ATTEST_N}.json" || return 1
  sig=$(openssl base64 -A -in "$TMP/sig-${ATTEST_N}.bin")
  jq -n --argjson payload "$payload" --arg signature "$sig" '{payload:$payload,signature_b64:$signature}' > "$dest"
}
rr_begin() { # role agent
  local role="$1" agent="$2" att="$TMP/begin-${ATTEST_N}.json"
  make_attestation begin "$role" "$agent" m-01 s-ok "$D1/design.md" "" "$att" || return 1
  (cd "$D1" && STATE_DIR="$D1/state" bash "$RR" begin --feature m-01 --role "$role" --agent-id "$agent" --session-id s-ok --input design.md --output report.md --attestation "$att")
}
rr_complete() { # role agent
  local role="$1" agent="$2" att="$TMP/complete-${ATTEST_N}.json"
  make_attestation complete "$role" "$agent" m-01 s-ok "$D1/design.md" "$D1/report.md" "$att" || return 1
  (cd "$D1" && STATE_DIR="$D1/state" bash "$RR" complete --feature m-01 --role "$role" --agent-id "$agent" --session-id s-ok --input design.md --output report.md --attestation "$att")
}

# ---------- ① 收据两阶段 ----------
D1="$TMP/rr"; mkdir -p "$D1"
printf 'design v1\n' > "$D1/design.md"

# 正向：六角色 begin → 报告 → complete → verify PASS
PAIRS="AUTHOR:ag-a 架构师:ag-b 后端专家:ag-c 前端专家:ag-d 测试开发:ag-e DBA:ag-f"
for pair in $PAIRS; do
  ROLE="${pair%%:*}"; AG="${pair##*:}"
  rr_begin "$ROLE" "$AG" >/dev/null 2>&1 || bad "收据正向 begin $ROLE"
done
printf 'final report\n' > "$D1/report.md"
for pair in $PAIRS; do
  ROLE="${pair%%:*}"; AG="${pair##*:}"
  rr_complete "$ROLE" "$AG" >/dev/null 2>&1 || bad "收据正向 complete $ROLE"
done
(cd "$D1" && STATE_DIR="$D1/state" bash "$RR" verify --feature m-01 --session-id s-ok --input design.md --output report.md) >/dev/null 2>&1 \
  && ok "收据两阶段正向全流程 PASS" || bad "收据两阶段正向全流程失败"

# 伪造①：报告已存在时 begin 被拒（旧 create 整批补写通道关闭）
(cd "$D1" && STATE_DIR="$D1/state" bash "$RR" begin --feature m-01 --role 架构师 --agent-id ag-x --session-id s-fake --input design.md --output report.md) >/dev/null 2>&1 \
  && bad "报告在先的 begin 未被拒绝" || ok "报告在先的 begin 被拒绝（补写通道关闭）"

# 伪造②：feature 路径逃逸被白名单拒绝
(cd "$D1" && STATE_DIR="$D1/state" bash "$RR" begin --feature ../escape --role AUTHOR --agent-id ag-x --session-id s-e --input design.md --output r-esc.md) >/dev/null 2>&1 \
  && bad "../escape 未被拒绝" || ok "../escape 路径逃逸被白名单拒绝"
[ -e "$TMP/escape" ] && bad "escape 目录仍被创建（containment 失效）" || ok "无 STATE_DIR 外写出（containment）"

# 伪造③：角色集合——缺角色 / 评审者==作者 均拒
mkdir -p "$D1/state/miss/review-sessions/sm"
for pair in "AUTHOR:ag-a" "架构师:ag-b" "后端专家:ag-c" "前端专家:ag-d" "测试开发:ag-e"; do
  ROLE="${pair%%:*}"; AG="${pair##*:}"
  (cd "$D1" && STATE_DIR="$D1/state" bash "$RR" begin --feature miss --role "$ROLE" --agent-id "$AG" --session-id sm --input design.md --output r-miss.md) >/dev/null 2>&1
done
printf 'x\n' > "$D1/r-miss.md"
for pair in "AUTHOR:ag-a" "架构师:ag-b" "后端专家:ag-c" "前端专家:ag-d" "测试开发:ag-e"; do
  ROLE="${pair%%:*}"; AG="${pair##*:}"
  (cd "$D1" && STATE_DIR="$D1/state" bash "$RR" complete --feature miss --role "$ROLE" --agent-id "$AG" --session-id sm --input design.md --output r-miss.md) >/dev/null 2>&1
done
(cd "$D1" && STATE_DIR="$D1/state" bash "$RR" verify --feature miss --session-id sm --input design.md --output r-miss.md) >/dev/null 2>&1 \
  && bad "缺 DBA 角色未拒" || ok "角色集合缺一即拒（DBA 缺失）"

for pair in "AUTHOR:same1" "架构师:same1"; do
  ROLE="${pair%%:*}"; AG="${pair##*:}"
  (cd "$D1" && STATE_DIR="$D1/state" bash "$RR" begin --feature dup --role "$ROLE" --agent-id "$AG" --session-id sd --input design.md --output r-dup.md) >/dev/null 2>&1
done
printf 'x\n' > "$D1/r-dup.md"
for pair in "AUTHOR:same1" "架构师:same1"; do
  ROLE="${pair%%:*}"; AG="${pair##*:}"
  (cd "$D1" && STATE_DIR="$D1/state" bash "$RR" complete --feature dup --role "$ROLE" --agent-id "$AG" --session-id sd --input design.md --output r-dup.md) >/dev/null 2>&1
done
(cd "$D1" && STATE_DIR="$D1/state" bash "$RR" verify --feature dup --session-id sd --input design.md --output r-dup.md) >/dev/null 2>&1 \
  && bad "评审者==作者未拒" || ok "评审者==作者被拒（独立性）"

# ---------- ② 图谱 Gate 身份绑定（mock 服务） ----------
GATE="$ROOT/maintenance/s8_graph_health_gate.sh"
mkgraph() { # mkgraph <dir> <status-json>
  printf '%s' "$2" > "$1/st.json"
  STATUS_FILE="$1/st.json" "${DEVFLOW_PY[@]}" "$TMP/fake-graph.py" "$1/port" & echo $!
}
cat > "$TMP/fake-graph.py" <<'PYEOF'
import json, sys, os, time
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        data = json.load(open(os.environ["STATUS_FILE"]))
        body = json.dumps({"status":"ok","service":"fake"} if self.path.startswith("/health") else data).encode()
        self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF

G1="$TMP/graph"; mkdir -p "$G1" && (cd "$G1" && git init -q && git config user.email t@t && git config user.name t && echo x > f.txt && git add . && git commit -qm c1)
run_gate() { # run_gate <status-json> [extra-env]
  local port
  port=$((20000 + RANDOM % 20000))
  printf '%s' "$1" > "$G1/st.json"
  STATUS_FILE="$G1/st.json" "${DEVFLOW_PY[@]}" "$TMP/fake-graph.py" "$port" >/dev/null 2>&1 &
  local srv=$!
  sleep 0.5
  (cd "$G1" && env GRAPH_URL="http://127.0.0.1:$port" ${2:-} REPORT=rep.env bash "$GATE" m-01 >/dev/null 2>&1)
  local rc=$?
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
  return $rc
}

run_gate '{"status":"ready","project":"'"$G1"'"}' \
  && ok "图谱身份绑定：本仓路径 PASS" || bad "图谱身份绑定：本仓路径被误拒"
run_gate '{"status":"ready","project":"/tmp/OTHER-PROJECT"}' \
  && bad "wrong-project 未被拒（假绿）" || ok "wrong-project 索引被拒（身份不符）"
run_gate '{"status":"indexing","project":"'"$G1"'"}' \
  && bad "stale 索引未阻断（WARN 假绿）" || ok "stale 索引被阻断（不再 WARN 放行）"
run_gate '{"status":"ready"}' \
  && bad "无身份字段未拒（fail-closed 失效）" || ok "无身份字段 fail-closed"
OPAQUE_ID="opaque-uuid-$RANDOM"
run_gate '{"status":"ready","index_id":"'"$OPAQUE_ID"'"}' "GRAPH_EXPECTED_ID=$OPAQUE_ID" \
  && ok "显式 GRAPH_EXPECTED_ID 绑定 PASS" || bad "显式 GRAPH_EXPECTED_ID 被误拒"
run_gate '{"status":"ready","index_id":"other-id"}' "GRAPH_EXPECTED_ID=$OPAQUE_ID" \
  && bad "GRAPH_EXPECTED_ID 不符未拒" || ok "GRAPH_EXPECTED_ID 不符被拒"

# fallback 清单重算（FINDINGS=0 合法 + 清单篡改检出）
printf 'source A\n' > "$G1/src-a.md"
SL_SHA=$(hash_test "$G1/src-a.md")
printf '%s  src-a.md\n' "$SL_SHA" > "$G1/fb-list.txt"
LIST_SHA=$(hash_test "$G1/fb-list.txt")
mkdir -p "$G1/docs/test"
cat > "$G1/docs/test/fb.md" <<EOF
FALLBACK_COMMAND=grep TODO src-a.md
FALLBACK_SCOPE=m-01
FALLBACK_FILES=1
FALLBACK_FINDINGS=0
FALLBACK_SHA256=$LIST_SHA
FALLBACK_FILE_LIST=fb-list.txt
EOF
printf 'status=fallback\nsource_fallback_evidence=docs/test/fb.md\n' > "$G1/rep.env"
(cd "$G1" && REPORT=rep.env bash "$GATE" --force-fallback >/dev/null 2>&1) \
  && ok "fallback FINDINGS=0+清单重算通过（零发现合法）" || bad "fallback 合法零发现被误拒"
printf 'tampered\n' >> "$G1/src-a.md"
(cd "$G1" && REPORT=rep.env bash "$GATE" --force-fallback >/dev/null 2>&1) \
  && bad "fallback 清单文件篡改未检出" || ok "fallback 清单文件篡改被重算检出"
printf 'source A\n' > "$G1/src-a.md"

# v3.20.4 钉：仓名子串边界（repo-backup 拒、段边界 repo 过）、短 SHA 接受、清单路径约束
run_gate '{"status":"ready","project":"'"$G1"'/../other/'"${G1##*/}"'-backup"}' \
  && bad "仓名子串误匹配未拒（repo-backup）" || ok "仓名子串 repo-backup 被拒（段边界）"
# v3.20.6 钉（第 2 轮对抗复查收口）：报告行注入、归一化、段级 .. 约束
run_gate '{"status":"ready","project":"x\nsource_fallback_evidence=docs/attack.md"}' \
  && bad "换行注入身份串未拒" || ok "换行注入身份串被拒（净化+对账失败）"
# 注入值不得成为有效证据指针：指针若存在，其值须不等于注入串（被 PREV 回写链消费即危险）
if grep -q '^source_fallback_evidence=' "$G1/rep.env" 2>/dev/null; then
  EV_VAL=$(grep '^source_fallback_evidence=' "$G1/rep.env" | cut -d= -f2-)
  { [ "$EV_VAL" != "xsource_fallback_evidence=docs/attack.md" ] && [ "$EV_VAL" != "docs/attack.md" ]; } \
    && ok "注入串未被回写为证据指针" || bad "注入串被 PREV 回写为证据指针"
else
  ok "注入未产生独立证据指针行"
fi
run_gate '{"status":"ready","project":"'"$G1"'/../other/xyz"}' \
  && bad "归一化后本仓段消失的 ../ 串未拒" || ok "未归一化 ../ 段归一化后对账失败被拒"
# v3.20.7 钉（第 3 轮对抗复查收口）：status 字段注入通道
run_gate '{"status":"ready\nsource_fallback_evidence=docs/test/attack2.md","project":"'"$G1"'"}' \
  && bad "status 字段换行注入未拒" || ok "status 字段换行注入被拒（净化+枚举白名单）"
grep -q '^source_fallback_evidence=docs/test/attack2.md' "$G1/rep.env" 2>/dev/null \
  && bad "status 注入产生了独立证据指针行" || ok "status 注入未产生独立证据指针行"
# 段级 .. 约束不误伤文件名中间含 .. 的仓内文件
printf 'ok\n' > "$G1/weird..name.md"
W_SHA=$(hash_test "$G1/weird..name.md")
printf '%s  weird..name.md\n' "$W_SHA" > "$G1/fb-w.txt"
W_LIST_SHA=$(hash_test "$G1/fb-w.txt")
cat > "$G1/docs/test/fb3.md" <<EOF
FALLBACK_COMMAND=x
FALLBACK_SCOPE=m-01
FALLBACK_FILES=1
FALLBACK_FINDINGS=0
FALLBACK_SHA256=$W_LIST_SHA
FALLBACK_FILE_LIST=fb-w.txt
EOF
printf 'status=fallback\nsource_fallback_evidence=docs/test/fb3.md\n' > "$G1/rep.env"
(cd "$G1" && REPORT=rep.env bash "$GATE" --force-fallback >/dev/null 2>&1) \
  && ok "文件名中间含 .. 的仓内文件不误伤" || bad "段级 .. 约束误伤合法文件名"

printf 'outside\n' > "$G1/../outside-md"
OUT_SHA=$(hash_test "$G1/../outside-md")
printf '%s  ../outside-md\n' "$OUT_SHA" > "$G1/fb-dd.txt"
DD_SHA=$(hash_test "$G1/fb-dd.txt")
cat > "$G1/docs/test/fb2.md" <<EOF
FALLBACK_COMMAND=x
FALLBACK_SCOPE=m-01
FALLBACK_FILES=1
FALLBACK_FINDINGS=0
FALLBACK_SHA256=$DD_SHA
FALLBACK_FILE_LIST=fb-dd.txt
EOF
printf 'status=fallback\nsource_fallback_evidence=docs/test/fb2.md\n' > "$G1/rep.env"
(cd "$G1" && REPORT=rep.env bash "$GATE" --force-fallback >/dev/null 2>&1) \
  && bad "清单 .. 逃逸路径未拒" || ok "fallback 清单 .. 逃逸路径被拒"

# ---------- ③ manifest hash-chain ----------
MC="$TMP/man"; cp -R "$ROOT" "$MC" 2>/dev/null
rm -rf "$MC/.backups" "$MC/_archive" "$MC/.git" "$MC/tests/logs" "$MC/scripts/__pycache__"
# 源树已发布 3.20.3 manifest——沙箱演练"新版本首发"须先移除当前版本 manifest 与台账（generate 拒绝同版本重写是正确行为）
rm -f "$MC/references/manifest/${SKILL_VER}.json" "$MC/references/manifest/CHAIN.json"
(cd "$MC" && bash scripts/gen-skill-manifest.sh chain-init >/dev/null 2>&1) || bad "chain-init 引导失败"
(cd "$MC" && bash scripts/gen-skill-manifest.sh generate >/dev/null 2>&1) || bad "v3.20.3 generate 失败"
(cd "$MC" && bash scripts/gen-skill-manifest.sh check >/dev/null 2>&1) \
  && ok "manifest 链 generate+check 全绿" || bad "manifest 链 generate+check 失败"
jq '.tree_hash="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$MC/references/manifest/3.20.2.json" > "$MC/t.json" 2>/dev/null && mv "$MC/t.json" "$MC/references/manifest/3.20.2.json"
(cd "$MC" && bash scripts/gen-skill-manifest.sh check >/dev/null 2>&1) \
  && bad "历史 manifest 篡改未检出（审计假绿复现）" || ok "历史 manifest 篡改被台账字节 SHA 检出"
(cd "$MC" && bash scripts/gen-skill-manifest.sh generate >/dev/null 2>&1) \
  && bad "历史污染后 generate 未被台账拒绝" || ok "台账污染后 generate 拒绝在新链上追加"

rm -f "$G1/../outside-md" "$G1/weird..name.md"

# ---------- v3.21.1：P4 可执行台账 / P6 状态元数据 / 非空 runner 抓取 ----------
mk_p4_workspace() { # $1=status
  local w="$TMP/p4-$1"
  mkdir -p "$w/docs/test" "$w/docs/requirements" "$w/scripts"
  printf '| M-01-F01-A01 | x |\n| M-01-F01-A02 | x |\n' > "$w/docs/requirements/fx-acceptance-criteria.md"
  printf 'raw validation evidence\n' > "$w/docs/test/fx-raw.log"
  # v3.28.4(P1-9)：受信 runner 改 make（STATUS 经 make 变量传入；配方行以 TAB 缩进）
  cat > "$w/Makefile" <<'MKEOF'
p4-verify:
	printf 'ID\tSTATUS\nM-01-F01-A01\tPASS\nM-01-F01-A02\t$(STATUS)\n' > docs/test/fx-p4-results.tsv
	printf 'executed P4 validation\n'
MKEOF
  cat > "$w/docs/test/fx-validation-report.md" <<EOF
P0_BLOCKERS=0
VALIDATION_EVIDENCE=docs/test/fx-raw.log
P4_CMD=make p4-verify STATUS=$1
P4_RESULTS_PATH=docs/test/fx-p4-results.tsv
EOF
  printf '%s\n' "$w"
}

WP4_FAIL=$(mk_p4_workspace FAIL)
P4_FAIL_OUT=$(cd "$WP4_FAIL" && bash "$ROOT/scripts/p4_validation_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$P4_FAIL_OUT" | grep -q 'P4_ACCEPTANCE_FAIL' && ! printf '%s' "$P4_FAIL_OUT" | grep -q 'rc=0$'; then
  ok "P4 rejects a generated FAIL acceptance row"
else
  bad "P4 accepts a generated FAIL acceptance row"
fi

WP4_PASS=$(mk_p4_workspace PASS)
P4_PASS_OUT=$(cd "$WP4_PASS" && bash "$ROOT/scripts/p4_validation_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$P4_PASS_OUT" | grep -q 'rc=0$' \
   && grep -q '^EVIDENCE_PATHS_JSON=' "$WP4_PASS/.devflow/fx/gates/P4/receipt.txt" \
   && grep -q '^EVIDENCE_TREE_SHA256=' "$WP4_PASS/.devflow/fx/gates/P4/receipt.txt"; then
  ok "P4 binds report, raw evidence, results, and execution capture as a tree"
else
  bad "P4 lacks tree-bound executable evidence :: report=[$(cat "$WP4_PASS/docs/test/fx-validation-report.md" | tr '\n' '|')] tsv=[$(cat "$WP4_PASS/docs/test/fx-p4-results.tsv" 2>/dev/null | tr '\n' '|')]"
fi

mk_p6_receipts() { # $1=workspace
  local w="$1" evidence paths tree
  mkdir -p "$w/.devflow/fx/gates/P6" "$w/.devflow/fx/gates/P6-credential" "$w/.devflow/fx/gates/P6-final" "$w/docs/fx/gates/P6" "$w/docs/fx/gates/P6-credential" "$w/docs/fx/gates/P6-final"
  printf 'acceptance_id\tstatus\nM-01-F01-A01\tFROZEN\nM-01-F01-A02\tFROZEN\n' > "$w/.devflow/fx/first-pass-baseline.tsv"
  printf 'results\n' > "$w/.devflow/fx/first-pass-results.tsv"
  printf 'ENVIRONMENT=staging\n' > "$w/.devflow/fx/test-evidence.env"
  evidence='.devflow/fx/first-pass-baseline.tsv'
  paths=$(jq -cn --arg p "$evidence" '[$p]')
  tree=$(cd "$w" && hash_test "$evidence" | awk -v p="$evidence" '{print $1 "  " p}' | { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi; })
  printf 'EXIT_CODE=0\nVERSION=p6@%s\nPHASE=P6\nSKILL_TREE=%s\nPASS=1 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" > "$w/.devflow/fx/gates/P6/receipt.txt"
  printf 'EXIT_CODE=0\nVERSION=p6-credential@%s\nPHASE=P6-credential\nSKILL_TREE=%s\nPASS=1 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" > "$w/.devflow/fx/gates/P6-credential/receipt.txt"
  printf 'EXIT_CODE=0\nVERSION=p6-final@%s\nPHASE=P6-final\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPASS=1 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$paths" "$tree" > "$w/.devflow/fx/gates/P6-final/receipt.txt"
  for p in P6 P6-credential P6-final; do cp "$w/.devflow/fx/gates/$p/receipt.txt" "$w/docs/fx/gates/$p/receipt.txt"; done
}

WSTATE="$TMP/state"; mkdir -p "$WSTATE/.devflow"
printf '{"feature":"fx","scope":{"skill_tree_sha256":"%s"},"current_phase":"P6","phases":{"P6":{"status":"completed"}},"acceptance_criteria":{"count":0,"frozen":0,"complete":0},"first_pass_snapshot":{"path":null,"accuracy":null}}\n' "$TREE" > "$WSTATE/.devflow/fx.state.json"
mk_p6_receipts "$WSTATE"
STATE_BAD=$(cd "$WSTATE" && bash "$ROOT/scripts/audit-receipts.sh" fx .devflow docs 2>&1; echo "rc=$?")
if printf '%s' "$STATE_BAD" | grep -q 'STATE_P6_ACCEPTANCE' && ! printf '%s' "$STATE_BAD" | grep -q 'rc=0$'; then
  ok "receipt audit rejects completed P6 with empty acceptance state"
else
  bad "receipt audit accepts completed P6 with empty acceptance state"
fi

jq '.acceptance_criteria={"count":2,"frozen":2,"complete":2} | .first_pass_snapshot={"path":".devflow/fx/first-pass-results.tsv","accuracy":100,"created_at":"2026-09-15T00:00:00Z"}' "$WSTATE/.devflow/fx.state.json" > "$WSTATE/state.tmp" && mv "$WSTATE/state.tmp" "$WSTATE/.devflow/fx.state.json"
STATE_OK=$(cd "$WSTATE" && bash "$ROOT/scripts/audit-receipts.sh" fx .devflow docs 2>&1; echo "rc=$?")
if printf '%s' "$STATE_OK" | grep -q 'rc=0$'; then ok "receipt audit accepts coherent completed P6 state"; else bad "receipt audit rejects coherent completed P6 state"; fi

mk_final_workspace() { # $1=workspace
  local w="$1" k
  mkdir -p "$w/.devflow/fx/reports"
  printf '{"feature":"fx","scope":{"frontend":"pc-web"},"current_phase":"P6"}\n' > "$w/.devflow/fx.state.json"
  printf 'acceptance_id\tstatus\nM-01-F01-A01\tFROZEN\n' > "$w/.devflow/fx/first-pass-baseline.tsv"
  printf 'feature=fx\nacceptance_count=1\n' > "$w/.devflow/fx/first-pass-meta.env"
  printf 'ID\tSTATUS\nM-01-F01-A01\tPASS\n' > "$w/.devflow/fx/final-verification.tsv"
  cat > "$w/Makefile" <<'EOF'
test-report:
	@k=`echo $(KIND) | tr "A-Z" "a-z"`; printf '# %s report\ncases: 1\npassed: 1\n' "$$k" > .devflow/fx/reports/$$k.txt
EOF
  {
    for k in UNIT INTEGRATION CLIENT LOAD STAGING; do
      low=$(printf '%s' "$k" | tr 'A-Z' 'a-z')
      printf '%s_CMD=make test-report KIND=%s > .devflow/fx/reports/%s.txt 2>&1\n%s_EXIT=0\n%s_REPORT_PATH=.devflow/fx/reports/%s.txt\n' "$k" "$k" "$low" "$k" "$k" "$low"
    done
    printf 'ENVIRONMENT=staging\n'
  } > "$w/.devflow/fx/test-evidence.env"
  "${DEVFLOW_PY[@]}" - "$w" <<'PYEOF'
import json, pathlib, sys
w=pathlib.Path(sys.argv[1]); env={}
for line in (w/'.devflow/fx/test-evidence.env').read_text().splitlines():
    if '=' in line: k,v=line.split('=',1); env[k]=v
doc={'feature':'fx','environment':'staging','acceptance_results':[{'id':'M-01-F01-A01','status':'PASS'}], 'evidence':{}, 'client_not_applicable':{'declared':False,'frontend_scope':'pc-web'}, 'zero_results':[]}
for k in ('unit','integration','client','load','staging'):
    K=k.upper(); doc['evidence'][k]={'cmd':env[K+'_CMD'],'exit_code':0,'report_path':env[K+'_REPORT_PATH']}
json.dump(doc, open(w/'.devflow/fx/verification.json','w'))
PYEOF
}

WEMPTY="$TMP/empty-capture"; mk_final_workspace "$WEMPTY"
EMPTY_OUT=$(cd "$WEMPTY" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$EMPTY_OUT" | grep -q 'P6_EXECUTION_LOG_EMPTY' && ! printf '%s' "$EMPTY_OUT" | grep -q 'rc=0$'; then
  ok "P6 final rejects commands that empty the Gate capture"
else
  bad "P6 final accepts commands that empty the Gate capture"
fi


# ---------- v3.21.2：发布树哈希防伪 / 严格评审收据 / 副本与元数据完整性 ----------
REAL=$(env -u RUN_TESTS_ACTIVE -u DEVFLOW_SKILL_TREE_SHA -u DEVFLOW_SKILL_TREE_ROOT \
  bash "$ROOT/scripts/gate-skill-tree.sh")
FORGED=$(RUN_TESTS_ACTIVE=1 \
  DEVFLOW_SKILL_TREE_SHA=0000000000000000000000000000000000000000000000000000000000000000 \
  DEVFLOW_SKILL_TREE_ROOT="$ROOT" \
  bash "$ROOT/scripts/gate-skill-tree.sh")

if [ "$FORGED" = "$REAL" ] && [ "$FORGED" != "0000000000000000000000000000000000000000000000000000000000000000" ]; then
  ok "production tree hash ignores test-cache environment injection"
else
  bad "production tree hash accepts forged test-cache environment injection"
fi

printf 'design\n' > "$TMP/design.md"
if STATE_DIR="$TMP/state" bash "$ROOT/scripts/review-receipt.sh" begin \
  --feature strict --role AUTHOR --agent-id self-declared --session-id strict-session \
  --input "$TMP/design.md" --output "$TMP/report.md" >/dev/null 2>&1; then
  bad "strict reviewer receipt accepts an unsigned self-declared identity"
else
  ok "strict reviewer receipt blocks an unsigned self-declared identity"
fi

grep -q 'scripts/check-copies.sh' "$ROOT/scripts/release.sh" \
  && ok "release gate verifies copy links (check-copies)" \
  || bad "release gate lost copy link verification"
grep -q '副本终验漂移"; FAIL=1; B_ROLLBACK_NEEDED=1' "$ROOT/scripts/release.sh" \
  && ok "B2 copy drift requests rollback" \
  || bad "B2 copy drift can leave an activated manifest"
if "${DEVFLOW_PY[@]}" - "$ROOT/agents/openai.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
raise SystemExit(0 if all(k in d for k in ("interface", "policy", "dependencies")) else 1)
PY
then
  ok "Codex metadata uses documented top-level keys"
else
  bad "Codex metadata lacks documented top-level keys"
fi


finish VERSION_HARDENING
