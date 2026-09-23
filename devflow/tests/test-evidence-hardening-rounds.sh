#!/usr/bin/env bash
# test-evidence-hardening-rounds.sh · 行为钉轮次回归（v3.20.3 自 test-evidence-hardening.sh 按领域拆分）
# 覆盖 v3.16.6+ 各轮行为钉（N27/N28/N29/N30/N32）。头部环境与前文件保持同构。
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"
source "$ROOT/scripts/devflow_receipt.sh"
SKILL_VER=$(sed -n 's/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh")
mkrc() { # mkrc <feature> <phase> [evidence-file]
  local f="$1" ph="$2" ev="${3:-}" d="$PWD" paths tree
  mkdir -p "$d/.devflow/$f/gates/$ph" "$d/docs/$f/gates/$ph"
  if [ "$ph" = "P4" ]; then
    if [ -z "$ev" ]; then
      ev=".devflow/$f/p4-fixture-evidence.txt"
      printf 'p4 fixture evidence\n' > "$d/$ev"
    fi
    paths=$(jq -cn --arg p "$ev" '[$p]')
    tree=$(cd "$d" && receipt_evidence_tree "$ev")
    _binds4=$(gj_bind_lines "$f" "$d" "P4")
    printf "EXIT_CODE=0\nVERSION=p4-validation@%s\nPHASE=P4\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\n%b\nPASS=1 FAIL=0 WARN=0\n" \
      "$SKILL_VER" "$TREE" "$paths" "$tree" "$_binds4" > "$d/.devflow/$f/gates/$ph/receipt.txt"
    cp "$d/.devflow/$f/gates/$ph/receipt.txt" "$d/docs/$f/gates/$ph/receipt.txt"
    return
  fi
  _binds=$(gj_bind_lines "$f" "$d" "$ph")
  if [ -n "$ev" ]; then
    printf "EXIT_CODE=0\nVERSION=g@${SKILL_VER}\nPHASE=%s\nSKILL_TREE=%s\nEVIDENCE_PATH=%s\nEVIDENCE_SHA256=%s\n%b\nPASS=1 FAIL=0 WARN=0\n" \
      "$ph" "$TREE" "$ev" "$(hash_file_test "$d/$ev" 2>/dev/null || true)" "$_binds" > "$d/.devflow/$f/gates/$ph/receipt.txt"
  else
    printf "EXIT_CODE=0\nVERSION=g@${SKILL_VER}\nPHASE=%s\nSKILL_TREE=%s\n%b\nPASS=1 FAIL=0 WARN=0\n" "$ph" "$TREE" "$_binds" > "$d/.devflow/$f/gates/$ph/receipt.txt"
  fi
  cp "$d/.devflow/$f/gates/$ph/receipt.txt" "$d/docs/$f/gates/$ph/receipt.txt"
}
hash_file_test() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

echo "=== devflow hardening round tests (v${SKILL_VER}) ==="
TMP=$(mktemp -d)
# v3.21.0: STAGING 真实容器签名夹具——本地 HTTP 探测服务（kernel 分配端口 +
# --directory 服务目录；RUN_TESTS_PARALLEL 下各套件各占各端口；套件退出统一回收）
STAGING_PROBE_PORT=""
STAGING_SRV=""
_start_staging_probe() {
  STAGING_PROBE_PORT=$("${DEVFLOW_PY[@]}" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  local d="$TMP/staging-probe"; mkdir -p "$d"
  printf '{"status":"UP","service":"fx-staging-probe","suite":"fx","cases":42,"passed":42,"failed":0}\n' > "$d/healthz"
  "${DEVFLOW_PY[@]}" -m http.server "$STAGING_PROBE_PORT" --bind 127.0.0.1 --directory "$d" >/dev/null 2>&1 &
  STAGING_SRV=$!
  sleep 0.5
}
_start_staging_probe
trap 'kill "$STAGING_SRV" 2>/dev/null; wait "$STAGING_SRV" 2>/dev/null; rm -rf "$TMP"' EXIT

# ===== v3.16.6（第 27 轮 N27）: 行为钉 T23a-f =====

# T23a (N27-P1-1): 证据绑定调包到 workspace 外部稳定文件 → complete P3b 拒绝
# （PoC 复原：EVIDENCE_PATHS_JSON=["/etc/hosts"] + 按该文件算树哈希 + 双份一致——
#  v3.16.5 校验无边界，外部文件"永远存在"，删证据防线整体失效）
W77="$TMP/v3166bnd"; mkdir -p "$W77/docs/review" "$W77/docs/detailed-design" "$W77/docs/requirements" "$W77/backend/svc/src/main/java"
printf '# d\nM-01-F01-A01\n' > "$W77/docs/detailed-design/foo-design.md"
printf '# c\nM-01-F01-A01\n' > "$W77/docs/requirements/foo-acceptance-criteria.md"
printf '# r\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$W77/docs/review/foo-code-review-report.md"
WORKSPACE="$W77" bash "$ROOT/scripts/devflow-state.sh" init foo --frontend=not-applicable >/dev/null 2>&1
gj_copy_sample code-review foo "$W77"
(cd "$W77" && bash "$ROOT/scripts/p3b_code_review_gate.sh" foo >/dev/null 2>&1 || true)
jq '.current_phase = "P3b" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="in_progress"' "$W77/.devflow/foo.state.json" > "$W77/s.tmp" && mv "$W77/s.tmp" "$W77/.devflow/foo.state.json"
_EXT_T=$(receipt_evidence_tree /etc/hosts)
for _rf in "$W77/.devflow/foo/gates/P3b/receipt.txt" "$W77/docs/foo/gates/P3b/receipt.txt"; do
  sed -i '' "s|^EVIDENCE_PATHS_JSON=.*|EVIDENCE_PATHS_JSON=[\"/etc/hosts\"]|" "$_rf" 2>/dev/null || sed -i "s|^EVIDENCE_PATHS_JSON=.*|EVIDENCE_PATHS_JSON=[\"/etc/hosts\"]|" "$_rf"
  sed -i '' "s|^EVIDENCE_TREE_SHA256=.*|EVIDENCE_TREE_SHA256=${_EXT_T}|" "$_rf" 2>/dev/null || sed -i "s|^EVIDENCE_TREE_SHA256=.*|EVIDENCE_TREE_SHA256=${_EXT_T}|" "$_rf"
done
_BNDLIB=$(cd "$W77" && WORKSPACE="$W77" bash -c "source '$ROOT/scripts/devflow_receipt.sh' && verify_receipt_evidence '.devflow/foo/gates/P3b/receipt.txt'" 2>&1)
_BND=$(cd "$W77" && WORKSPACE="$W77" bash "$ROOT/scripts/devflow-state.sh" complete foo P3b 2>&1)
if printf '%s' "$_BNDLIB" | grep -q '越界' \
   && printf '%s' "$_BND" | grep -q 'P3b 收据证据绑定校验失败'; then
  ok "证据调包到 workspace 外部文件被拒（N27-P1-1 workspace 边界钉）"
else
  bad "证据调包到 workspace 外部文件被拒（N27-P1-1；库级未报越界或 complete 未拒）"
fi

# T23b (N27-P1-2): s6-final 无表头 TSV——首行 FAIL 行藏入「表头位」→ 必须阻断
W78="$TMP/v3166hdr"; mkdir -p "$W78/.devflow/hf6"
printf 'A01\tFAIL\nA02\tPASS\n' > "$W78/.devflow/hf6/final-verification.tsv"
for _k in unit integ client load staging; do printf 'r-%s\n' "$_k" > "$W78/.devflow/hf6/${_k}-report.txt"; done
_RU=$(hash_file_test "$W78/.devflow/hf6/unit-report.txt"); _RI=$(hash_file_test "$W78/.devflow/hf6/integ-report.txt")
_RC=$(hash_file_test "$W78/.devflow/hf6/client-report.txt"); _RL=$(hash_file_test "$W78/.devflow/hf6/load-report.txt")
_RS=$(hash_file_test "$W78/.devflow/hf6/staging-report.txt")
cat > "$W78/.devflow/hf6/test-evidence.env" <<EOF
UNIT_CMD=echo u
UNIT_EXIT=0
UNIT_REPORT_PATH=.devflow/hf6/unit-report.txt
UNIT_REPORT_SHA256=$_RU
INTEGRATION_CMD=echo i
INTEGRATION_EXIT=0
INTEGRATION_REPORT_PATH=.devflow/hf6/integ-report.txt
INTEGRATION_REPORT_SHA256=$_RI
CLIENT_CMD=echo c
CLIENT_EXIT=0
CLIENT_REPORT_PATH=.devflow/hf6/client-report.txt
CLIENT_REPORT_SHA256=$_RC
LOAD_CMD=echo l
LOAD_EXIT=0
LOAD_REPORT_PATH=.devflow/hf6/load-report.txt
LOAD_REPORT_SHA256=$_RL
STAGING_CMD=echo s
STAGING_EXIT=0
STAGING_REPORT_PATH=.devflow/hf6/staging-report.txt
STAGING_REPORT_SHA256=$_RS
ENVIRONMENT=staging
EOF
_HDRNEG=$(cd "$W78" && bash "$ROOT/scripts/s6_final_verification_gate.sh" hf6 2>&1; echo "rc=$?")
if printf '%s' "$_HDRNEG" | grep -q '非 ID<TAB>STATUS 表头'; then
  ok "s6-final 无表头 TSV（首行 FAIL 藏表头位）被阻断（N27-P1-2 表头钉）"
else
  bad "s6-final 无表头 TSV 未被阻断（N27-P1-2）"
fi
# 对照：带表头同数据（A01 FAIL 在数据位）也必须阻断——证明拦截点在数据语义而非形式
printf 'ID\tSTATUS\nA01\tFAIL\nA02\tPASS\n' > "$W78/.devflow/hf6/final-verification.tsv"
_HDRCTL=$(cd "$W78" && bash "$ROOT/scripts/s6_final_verification_gate.sh" hf6 >/dev/null 2>&1; echo $?)
[ "$_HDRCTL" != "0" ] && ok "s6-final 带表头 FAIL 数据行仍阻断（对照组）" || bad "s6-final 带表头 FAIL 数据行未阻断（对照组）"

# T23c (N27-P1-3/P27-P2-1): complete P7 前置链复查辅助收据——缺 P6-final 拒；补齐后过
W79="$TMP/v3166p7"; WORKSPACE="$W79" bash "$ROOT/scripts/devflow-state.sh" init p7f --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P7" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="completed" | .phases.P4b.status="completed" | .phases.P5.status="completed" | .phases.P6.status="completed" | .phases.P7.status="in_progress"' "$W79/.devflow/p7f.state.json" > "$W79/s.tmp" && mv "$W79/s.tmp" "$W79/.devflow/p7f.state.json"
printf 'deploy-evidence\n' > "$W79/evidence-p7.txt"
# v3.16.8（N29-P2-1/2）: 契约阶段（P0b/P3b/P3cd/P4/P4b/P5）补绑定（映射硬口径）
(cd "$W79" && for _ph in P0 P1 P2 P2a P2b P3 P6; do mkrc p7f "$_ph"; done; for _ph in P0b P3b P3cd P4 P4b P5; do mkrc p7f "$_ph" evidence-p7.txt; done; mkrc p7f P6-credential; mkrc p7f P7 evidence-p7.txt)
(cd "$W79" && bash "$ROOT/checks/check-arch-pitfalls.sh" --all --receipt p7f >/dev/null 2>&1 || true)
_P7NEG=$(cd "$W79" && WORKSPACE="$W79" bash "$ROOT/scripts/devflow-state.sh" complete p7f P7 2>&1)
if printf '%s' "$_P7NEG" | grep -q 'P6-final'; then
  ok "complete P7 缺 P6-final 辅助收据被拒（N27-P1-3 前置链钉）"
else
  bad "complete P7 缺 P6-final 未被拒（N27-P1-3）"
fi
# 补齐 P6-final 后同一夹具 complete P7 必须成功（证明拒绝变量就是 P6-final，非侧翼）
(cd "$W79" && \
  mkdir -p .devflow/p7f/gates/P6-final docs/p7f/gates/P6-final && \
  printf 'ID\tSTATUS\nA01\tPASS\n' > .devflow/p7f/final-verification.tsv && \
  printf 'ENVIRONMENT=staging\n' > .devflow/p7f/test-evidence.env && \
  _P7J=$(jq -cn --arg a ".devflow/p7f/final-verification.tsv" --arg b ".devflow/p7f/test-evidence.env" '[$a,$b]') && \
  _P7T=$(receipt_evidence_tree .devflow/p7f/final-verification.tsv .devflow/p7f/test-evidence.env) && \
  printf 'EXIT_CODE=0\nVERSION=p6-final@%s\nPHASE=P6-final\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPRODUCER_ROLE=final-verifier\nSESSION_ID=s1\nENVIRONMENT=staging\nPASS=8 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$_P7J" "$_P7T" > .devflow/p7f/gates/P6-final/receipt.txt && \
  mkdir -p docs/p7f/gates/P6-final && cp .devflow/p7f/gates/P6-final/receipt.txt docs/p7f/gates/P6-final/receipt.txt)
if WORKSPACE="$W79" bash "$ROOT/scripts/devflow-state.sh" complete p7f P7 >/dev/null 2>&1 \
   && [ "$(jq -r '.current_phase' "$W79/.devflow/p7f.state.json")" = "P8" ]; then
  ok "补齐 P6-final 后 complete P7 成功（对照通过——P6-final 是判别变量）"
else
  bad "补齐 P6-final 后 complete P7 仍未过（对照失败）"
fi

# T23d (N27-P2-2): audit 在 jq 缺失时对 completed-无收据 fail-closed（不再静默跳过）
W80="$TMP/v3166nojq"; WORKSPACE="$W80" bash "$ROOT/scripts/devflow-state.sh" init njq --frontend=not-applicable >/dev/null 2>&1
jq '.phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed"' "$W80/.devflow/njq.state.json" > "$W80/s.tmp" && mv "$W80/s.tmp" "$W80/.devflow/njq.state.json"
# fakebin 软链法：PATH 仅含 fakebin（全工具软链、唯独无 jq）——jq 位于 /usr/bin 时
# 删目录法会连带删掉 head/dirname 等同级工具使 audit 早退，测不到目标分支
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$W80/fb"
  for _t in bash sed grep find sort shasum awk cut head tail wc dirname basename mktemp date cmp cat tr env rm; do
    _bt=$(command -v "$_t" 2>/dev/null) && [ -n "$_bt" ] && ln -sf "$_bt" "$W80/fb/$_t"
  done
  _NOJQ=$(cd "$W80" && PATH="$W80/fb" bash "$ROOT/scripts/audit-receipts.sh" njq .devflow docs 2>&1)
  _NOJQ_RC=$(cd "$W80" && PATH="$W80/fb" bash "$ROOT/scripts/audit-receipts.sh" njq .devflow docs >/dev/null 2>&1; echo $?)
  if printf '%s' "$_NOJQ" | grep -q 'jq 缺失' && [ "$_NOJQ_RC" != "0" ]; then
    ok "audit jq 缺失时 state-scope fail-closed（N27-P2-2 钉）"
  else
    bad "audit jq 缺失时未 fail-closed（N27-P2-2；rc=${_NOJQ_RC}）"
  fi
else
  ok "本机无 jq（audit 的 jq 缺失分支即常态）——N27-P2-2 由实现保证"
fi

# T23e (N27-P2-3): state JSON 损坏 → audit fail（不再 || true 吞掉）
W81="$TMP/v3166badstate"; WORKSPACE="$W81" bash "$ROOT/scripts/devflow-state.sh" init bst --frontend=not-applicable >/dev/null 2>&1
printf '{"phases": "truncated-garbage' > "$W81/.devflow/bst.state.json"
_BST=$(cd "$W81" && bash "$ROOT/scripts/audit-receipts.sh" bst .devflow docs 2>&1)
if printf '%s' "$_BST" | grep -q '不可解析'; then
  ok "state JSON 损坏时 audit fail-closed（N27-P2-3 钉）"
else
  bad "state JSON 损坏时 audit 未 fail（N27-P2-3）"
fi

# T23f (v3.16.6 → v3.16.7 重写): 删 P3b 证据 → reconcile --apply 停在 P3b（N26-P2-2 行为钉）
# v3.16.7（N28-P2-2）: 修复空转钉——init 产生的 P0 基线收据（VERSION=state-init@）被
# _reconcile_receipt_ok 拒，reconcile 在「链完整性断裂: P0」处提前死亡，从未到达 P3b
# 分支；断言被早退路径的恰好状态（state 未动）空洞满足（M8 变异删 P3b 校验后仍绿）。
# 重写：P0..P3 全部用合法 g@ 版本 mkrc 收据（P0 覆盖 state-init 基线），使 P3b 证据
# 删除成为唯一判别变量。
W76="$TMP/v3167rec"; mkdir -p "$W76/docs/review" "$W76/docs/detailed-design" "$W76/docs/requirements" "$W76/backend/svc/src/main/java"
printf '# d\nM-01-F01-A01\n' > "$W76/docs/detailed-design/foo-design.md"
printf '# c\nM-01-F01-A01\n' > "$W76/docs/requirements/foo-acceptance-criteria.md"
printf '# r\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$W76/docs/review/foo-code-review-report.md"
WORKSPACE="$W76" bash "$ROOT/scripts/devflow-state.sh" init foo --frontend=not-applicable >/dev/null 2>&1
gj_copy_sample code-review foo "$W76"
(cd "$W76" && bash "$ROOT/scripts/p3b_code_review_gate.sh" foo >/dev/null 2>&1 || true)
jq '.current_phase = "P3b" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="in_progress"' "$W76/.devflow/foo.state.json" > "$W76/s.tmp" && mv "$W76/s.tmp" "$W76/.devflow/foo.state.json"
# v3.16.7: P0..P3 合法收据（g@ 版本 + 双镜像）——P0 覆盖 state-init 基线（基线收据
# 不构成 Gate 证据，reconcile 链完整性会先拒它）
# v3.16.8: P0b 补绑定（映射硬口径——reconcile 链完整性对 completed P0b 强制）
(cd "$W76" && for _ph in P0 P1 P2 P2a P2b P3; do mkrc foo "$_ph"; done; mkrc foo P0b docs/detailed-design/foo-design.md)
# v3.16.8（N29-P4-1）: 正向基线——证据在 → reconcile 推进 P3b（基线失败=测试无效，
# 防 reconcile 更早死亡时断言被早退路径空洞满足——N28-P2-2 模式重演风险）
(cd "$W76" && WORKSPACE="$W76" bash "$ROOT/scripts/devflow-state.sh" reconcile foo --apply >/dev/null 2>&1)
_R3B_BASE=$(jq -r '.phases.P3b.status' "$W76/.devflow/foo.state.json")
# 回滚 state（隔离攻击变量）
jq '.current_phase = "P3b" | .phases.P3b.status = "in_progress" | .phases.P3b.completed_at = null | .phases.P3c.status = "pending" | .phases.P3c.started_at = null' "$W76/.devflow/foo.state.json" > "$W76/s.tmp" && mv "$W76/s.tmp" "$W76/.devflow/foo.state.json"
rm "$W76/docs/review/foo-code-review-report.md"
(cd "$W76" && WORKSPACE="$W76" bash "$ROOT/scripts/devflow-state.sh" reconcile foo --apply >/dev/null 2>&1)
if [ "$_R3B_BASE" = "completed" ] && [ "$(jq -r '.phases.P3b.status' "$W76/.devflow/foo.state.json")" != "completed" ] \
   && [ "$(jq -r '.current_phase' "$W76/.devflow/foo.state.json")" = "P3b" ]; then
  ok "删 P3b 证据后 reconcile --apply 停在 P3b（N28-P2-2 重写钉；基线=completed）"
else
  bad "删 P3b 证据后 reconcile 仍推进 P3b（N28-P2-2；基线=${_R3B_BASE}——基线失败=测试无效）"
fi

# ===== v3.16.7（第 28 轮 N28）: 行为钉 T24a-c =====

# T24a (N28-P1-1/P3-2): 旧契约证据越界——双站点（verify_evidence_receipt 词法前缀/相对路径
# 无边界 + verify_receipt_evidence 旧契约分支）均须拒绝
W82="$TMP/v3167old"; mkdir -p "$W82/docs/review" "$W82/docs/detailed-design" "$W82/docs/requirements" "$W82/backend/svc/src/main/java"
printf '# d\nM-01-F01-A01\n' > "$W82/docs/detailed-design/foo-design.md"
printf '# c\nM-01-F01-A01\n' > "$W82/docs/requirements/foo-acceptance-criteria.md"
printf '# r\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$W82/docs/review/foo-code-review-report.md"
WORKSPACE="$W82" bash "$ROOT/scripts/devflow-state.sh" init foo --frontend=not-applicable >/dev/null 2>&1
gj_copy_sample code-review foo "$W82"
(cd "$W82" && bash "$ROOT/scripts/p3b_code_review_gate.sh" foo >/dev/null 2>&1 || true)
jq '.current_phase = "P3b" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="in_progress"' "$W82/.devflow/foo.state.json" > "$W82/s.tmp" && mv "$W82/s.tmp" "$W82/.devflow/foo.state.json"
(cd "$W82" && for _ph in P0 P0b P1 P2 P2a P2b P3; do mkrc foo "$_ph"; done)
# 站点 1：devflow_receipt.sh 旧契约分支——剥新契约绑定行、换 EVIDENCE_PATH=/etc/hosts
# （外部稳定文件 + 双份一致哈希）→ verify_receipt_evidence 必须报越界、complete 拒
_HOSTS_SHA=$(hash_file_test /etc/hosts)
for _rf in "$W82/.devflow/foo/gates/P3b/receipt.txt" "$W82/docs/foo/gates/P3b/receipt.txt"; do
  sed -i '' '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d' "$_rf" 2>/dev/null || sed -i '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d' "$_rf"
  printf 'EVIDENCE_PATH=/etc/hosts\nEVIDENCE_SHA256=%s\n' "$_HOSTS_SHA" >> "$_rf"
done
_OLDLIB=$(cd "$W82" && WORKSPACE="$W82" bash -c "source '$ROOT/scripts/devflow_receipt.sh' && verify_receipt_evidence '.devflow/foo/gates/P3b/receipt.txt'" 2>&1)
_OLDRUN=$(cd "$W82" && WORKSPACE="$W82" bash "$ROOT/scripts/devflow-state.sh" complete foo P3b 2>&1)
if printf '%s' "$_OLDLIB" | grep -q '越界' && printf '%s' "$_OLDRUN" | grep -q 'P3b 收据证据绑定校验失败'; then
  ok "旧契约证据越界（外部稳定文件绑定）库级+状态机级均拒（N28-P1-1 站点1钉）"
else
  bad "旧契约证据越界未被拒（N28-P1-1 站点1；库级或 complete 级放行）"
fi

# 站点 2：verify_evidence_receipt（core，词法前缀+相对路径双变体）——P4 主收据校验
# 变体 A：绝对路径 + ../（词法命中 $WS/* 前缀但物理在 workspace 外）
W82A="$TMP/v3167oldA"; WORKSPACE="$W82A" bash "$ROOT/scripts/devflow-state.sh" init p4a --frontend=not-applicable >/dev/null 2>&1
# 外部稳定文件放 workspace 外（$TMP 根）——词法上 $W82A/../x 命中 "$W82A"/* 前缀，
# 物理归一后落在 $W82A 之外（旧词法前缀校验放行、cd -P 后必拒）
printf 'external-stable-A\n' > "$TMP/outside-stable-A.txt"
_OSA=$(hash_file_test "$TMP/outside-stable-A.txt")
jq '.current_phase = "P4" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="in_progress"' "$W82A/.devflow/p4a.state.json" > "$W82A/s.tmp" && mv "$W82A/s.tmp" "$W82A/.devflow/p4a.state.json"
(cd "$W82A" && for _ph in P0 P0b P1 P2 P2a P2b P3 P3b P3cd; do mkrc p4a "$_ph"; done)
mkdir -p "$W82A/.devflow/p4a/gates/P4" "$W82A/docs/p4a/gates/P4"
printf 'EXIT_CODE=0\nVERSION=g@%s\nPHASE=P4\nSKILL_TREE=%s\nEVIDENCE_PATH=%s/../outside-stable-A.txt\nEVIDENCE_SHA256=%s\nPASS=1 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$W82A" "$_OSA" > "$W82A/.devflow/p4a/gates/P4/receipt.txt"
gj_bind_lines p4a "$W82A" P4 >> "$W82A/.devflow/p4a/gates/P4/receipt.txt"
cp "$W82A/.devflow/p4a/gates/P4/receipt.txt" "$W82A/docs/p4a/gates/P4/receipt.txt"
_RUNA=$(cd "$W82A" && WORKSPACE="$W82A" bash "$ROOT/scripts/devflow-state.sh" complete p4a P4 2>&1)
if printf '%s' "$_RUNA" | grep -q '新证据树字段缺失'; then
  ok "P4 新证据树契约拒绝旧单文件绝对路径收据（N28-P1-1 变体A）"
else
  bad "P4 新证据树契约未拒绝旧单文件绝对路径收据（N28-P1-1 变体A）"
fi
# 变体 B：相对路径 ../（此前该分支完全无边界检查）
W82B="$TMP/v3167oldB"; WORKSPACE="$W82B" bash "$ROOT/scripts/devflow-state.sh" init p4b --frontend=not-applicable >/dev/null 2>&1
# 外部稳定文件放 workspace 外——相对 ../ 解析到 $W82B 之外（旧相对分支无边界校验放行）
printf 'external-stable-B\n' > "$TMP/outside-stable-B.txt"
_OSB=$(hash_file_test "$TMP/outside-stable-B.txt")
jq '.current_phase = "P4" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="in_progress"' "$W82B/.devflow/p4b.state.json" > "$W82B/s.tmp" && mv "$W82B/s.tmp" "$W82B/.devflow/p4b.state.json"
(cd "$W82B" && for _ph in P0 P0b P1 P2 P2a P2b P3 P3b P3cd; do mkrc p4b "$_ph"; done)
mkdir -p "$W82B/.devflow/p4b/gates/P4" "$W82B/docs/p4b/gates/P4"
printf 'EXIT_CODE=0\nVERSION=g@%s\nPHASE=P4\nSKILL_TREE=%s\nEVIDENCE_PATH=../outside-stable-B.txt\nEVIDENCE_SHA256=%s\nPASS=1 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$_OSB" > "$W82B/.devflow/p4b/gates/P4/receipt.txt"
gj_bind_lines p4b "$W82B" P4 >> "$W82B/.devflow/p4b/gates/P4/receipt.txt"
cp "$W82B/.devflow/p4b/gates/P4/receipt.txt" "$W82B/docs/p4b/gates/P4/receipt.txt"
_RUNB=$(cd "$W82B" && WORKSPACE="$W82B" bash "$ROOT/scripts/devflow-state.sh" complete p4b P4 2>&1)
if printf '%s' "$_RUNB" | grep -q '新证据树字段缺失'; then
  ok "P4 新证据树契约拒绝旧单文件相对路径收据（N28-P1-1 变体B）"
else
  bad "P4 新证据树契约未拒绝旧单文件相对路径收据（N28-P1-1 变体B）"
fi

# T24b (N28-P3-1): reconcile P7+ 推进复查辅助收据——删 P6-final 后不得推进 P7
# 夹具口径：reconcile 链完整性对 completed 的 P3cd/P4/P5（旧契约白名单）与 P3b
#（新契约，rc=3 硬拒）均强制证据绑定——P3b 用真实 gate 产物、P3cd/P4/P5/P7 收据带 ev
W83="$TMP/v3167rec7"; mkdir -p "$W83/docs/review" "$W83/docs/detailed-design" "$W83/docs/requirements" "$W83/backend/svc/src/main/java"
printf '# d\nM-01-F01-A01\n' > "$W83/docs/detailed-design/p7r-design.md"
printf '# c\nM-01-F01-A01\n' > "$W83/docs/requirements/p7r-acceptance-criteria.md"
printf '# r\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$W83/docs/review/p7r-code-review-report.md"
WORKSPACE="$W83" bash "$ROOT/scripts/devflow-state.sh" init p7r --frontend=not-applicable >/dev/null 2>&1
gj_copy_sample code-review p7r "$W83"
(cd "$W83" && bash "$ROOT/scripts/p3b_code_review_gate.sh" p7r >/dev/null 2>&1 || true)
jq '.current_phase = "P7" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="completed" | .phases.P4b.status="completed" | .phases.P5.status="completed" | .phases.P6.status="completed" | .phases.P7.status="in_progress"' "$W83/.devflow/p7r.state.json" > "$W83/s.tmp" && mv "$W83/s.tmp" "$W83/.devflow/p7r.state.json"
printf 'p7-evidence\n' > "$W83/evidence-p7.txt"
# v3.16.8（N29-P2-1/2）: P0b/P4b 移入绑定组（映射硬口径）
(cd "$W83" && for _ph in P0 P1 P2 P2a P2b P3 P6; do mkrc p7r "$_ph"; done; for _ph in P0b P3cd P4 P4b P5 P7; do mkrc p7r "$_ph" evidence-p7.txt; done; mkrc p7r P6-credential)
(cd "$W83" && bash "$ROOT/checks/check-arch-pitfalls.sh" --all --receipt p7r >/dev/null 2>&1 || true)
(cd "$W83" && \
  printf 'ID\tSTATUS\nA01\tPASS\n' > .devflow/p7r/final-verification.tsv && \
  printf 'ENVIRONMENT=staging\n' > .devflow/p7r/test-evidence.env && \
  _RB7J=$(jq -cn --arg a ".devflow/p7r/final-verification.tsv" --arg b ".devflow/p7r/test-evidence.env" '[$a,$b]') && \
  _RB7T=$(receipt_evidence_tree .devflow/p7r/final-verification.tsv .devflow/p7r/test-evidence.env) && \
  mkdir -p .devflow/p7r/gates/P6-final docs/p7r/gates/P6-final && \
  printf 'EXIT_CODE=0\nVERSION=p6-final@%s\nPHASE=P6-final\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPRODUCER_ROLE=final-verifier\nSESSION_ID=s1\nENVIRONMENT=staging\nPASS=8 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$_RB7J" "$_RB7T" > .devflow/p7r/gates/P6-final/receipt.txt && \
  cp .devflow/p7r/gates/P6-final/receipt.txt docs/p7r/gates/P6-final/receipt.txt)
# 基线：收据齐备 → reconcile --apply 推进 P7 为 completed
(cd "$W83" && WORKSPACE="$W83" bash "$ROOT/scripts/devflow-state.sh" reconcile p7r --apply >/dev/null 2>&1)
_R7BASE=$(jq -r '.phases.P7.status' "$W83/.devflow/p7r.state.json")
# 攻击：删 P6-final（双份）+ 回滚 state → reconcile 不得推进 P7
rm -f "$W83/.devflow/p7r/gates/P6-final/receipt.txt" "$W83/docs/p7r/gates/P6-final/receipt.txt"
jq '.phases.P7.status = "in_progress" | .phases.P7.completed_at = null | .current_phase = "P7"' "$W83/.devflow/p7r.state.json" > "$W83/s.tmp" && mv "$W83/s.tmp" "$W83/.devflow/p7r.state.json"
(cd "$W83" && WORKSPACE="$W83" bash "$ROOT/scripts/devflow-state.sh" reconcile p7r --apply >/dev/null 2>&1)
if [ "$_R7BASE" = "completed" ] && [ "$(jq -r '.phases.P7.status' "$W83/.devflow/p7r.state.json")" != "completed" ]; then
  ok "删 P6-final 后 reconcile --apply 不推进 P7（N28-P3-1 钉；基线=completed）"
else
  bad "删 P6-final 后 reconcile 仍推进 P7（N28-P3-1；基线=${_R7BASE}——基线失败=测试无效）"
fi

# T24c (N28-P2-1): 删 P4 绑定证据 → complete P7 拒（对照：证据在 → 过）
W84="$TMP/v3167p7e"; WORKSPACE="$W84" bash "$ROOT/scripts/devflow-state.sh" init p7e --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P7" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="completed" | .phases.P4b.status="completed" | .phases.P5.status="completed" | .phases.P6.status="completed" | .phases.P7.status="in_progress"' "$W84/.devflow/p7e.state.json" > "$W84/s.tmp" && mv "$W84/s.tmp" "$W84/.devflow/p7e.state.json"
printf 'p4-ev\n' > "$W84/evidence-p4.txt"; printf 'p7-ev\n' > "$W84/evidence-p7.txt"
# v3.16.8（N29-P2-1/2/3）: 契约阶段（P0b/P3b/P3cd/P4b/P5）补绑定（映射硬口径）
(cd "$W84" && for _ph in P0 P1 P2 P2a P2b P3 P6; do mkrc p7e "$_ph"; done; for _ph in P0b P3b P3cd P4b P5; do mkrc p7e "$_ph" evidence-p7.txt; done; mkrc p7e P4 evidence-p4.txt; mkrc p7e P6-credential; mkrc p7e P7 evidence-p7.txt)
(cd "$W84" && bash "$ROOT/checks/check-arch-pitfalls.sh" --all --receipt p7e >/dev/null 2>&1 || true)
(cd "$W84" && \
  printf 'ID\tSTATUS\nA01\tPASS\n' > .devflow/p7e/final-verification.tsv && \
  printf 'ENVIRONMENT=staging\n' > .devflow/p7e/test-evidence.env && \
  _P7EJ=$(jq -cn --arg a ".devflow/p7e/final-verification.tsv" --arg b ".devflow/p7e/test-evidence.env" '[$a,$b]') && \
  _P7ET=$(receipt_evidence_tree .devflow/p7e/final-verification.tsv .devflow/p7e/test-evidence.env) && \
  mkdir -p .devflow/p7e/gates/P6-final docs/p7e/gates/P6-final && \
  printf 'EXIT_CODE=0\nVERSION=p6-final@%s\nPHASE=P6-final\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPRODUCER_ROLE=final-verifier\nSESSION_ID=s1\nENVIRONMENT=staging\nPASS=8 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$_P7EJ" "$_P7ET" > .devflow/p7e/gates/P6-final/receipt.txt && \
  cp .devflow/p7e/gates/P6-final/receipt.txt docs/p7e/gates/P6-final/receipt.txt)
# 基线：P4 证据在 → complete P7 成功推进 P8
(cd "$W84" && WORKSPACE="$W84" bash "$ROOT/scripts/devflow-state.sh" complete p7e P7 >/dev/null 2>&1)
_E7BASE=$(jq -r '.current_phase' "$W84/.devflow/p7e.state.json")
# 攻击：回滚 state + 删 P4 证据 → complete P7 必须拒
jq '.current_phase = "P7" | .phases.P7.status = "in_progress" | .phases.P7.completed_at = null | .phases.P8.status = "pending" | .phases.P8.started_at = null' "$W84/.devflow/p7e.state.json" > "$W84/s.tmp" && mv "$W84/s.tmp" "$W84/.devflow/p7e.state.json"
rm -f "$W84/evidence-p4.txt"
_E7RUN=$(cd "$W84" && WORKSPACE="$W84" bash "$ROOT/scripts/devflow-state.sh" complete p7e P7 2>&1)
if [ "$_E7BASE" = "P8" ] && printf '%s' "$_E7RUN" | grep -q '证据绑定复查失败'; then
  ok "删 P4 绑定证据后 complete P7 被拒（N28-P2-1 钉；基线=P8）"
else
  bad "删 P4 绑定证据后 complete P7 未被拒（N28-P2-1；基线=${_E7BASE}——基线失败=测试无效）"
fi

# ===== v3.16.8（第 29 轮 N29）: 行为钉 T24a-C + T25a-e =====

# T24a 变体 C (N29-P3-3): REPORT_PATH 越界——verify_evidence_receipt 报告路径边界
W85="$TMP/v3168rpc"; WORKSPACE="$W85" bash "$ROOT/scripts/devflow-state.sh" init p4c --frontend=not-applicable >/dev/null 2>&1
printf 'rpc-ev\n' > "$W85/evidence-p4c.txt"
_RPC_SHA=$(hash_file_test "$W85/evidence-p4c.txt"); _HOSTS2=$(hash_file_test /etc/hosts)
jq '.current_phase = "P4" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="in_progress"' "$W85/.devflow/p4c.state.json" > "$W85/s.tmp" && mv "$W85/s.tmp" "$W85/.devflow/p4c.state.json"
(cd "$W85" && for _ph in P0 P1 P2 P2a P2b P3; do mkrc p4c "$_ph"; done; mkrc p4c P0b evidence-p4c.txt; mkrc p4c P3b evidence-p4c.txt; mkrc p4c P3cd evidence-p4c.txt)
mkdir -p "$W85/.devflow/p4c/gates/P4" "$W85/docs/p4c/gates/P4"
printf 'EXIT_CODE=0\nVERSION=g@%s\nPHASE=P4\nSKILL_TREE=%s\nEVIDENCE_PATH=evidence-p4c.txt\nEVIDENCE_SHA256=%s\nREPORT_PATH=/etc/hosts\nREPORT_SHA256=%s\nPASS=1 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$_RPC_SHA" "$_HOSTS2" > "$W85/.devflow/p4c/gates/P4/receipt.txt"
gj_bind_lines p4c "$W85" P4 >> "$W85/.devflow/p4c/gates/P4/receipt.txt"
cp "$W85/.devflow/p4c/gates/P4/receipt.txt" "$W85/docs/p4c/gates/P4/receipt.txt"
_RPCR=$(cd "$W85" && WORKSPACE="$W85" bash "$ROOT/scripts/devflow-state.sh" complete p4c P4 2>&1)
if printf '%s' "$_RPCR" | grep -q '新证据树字段缺失'; then
  ok "P4 新证据树契约拒绝旧单文件 REPORT_PATH 收据（N29-P3-3 变体C）"
else
  bad "P4 新证据树契约未拒绝旧单文件 REPORT_PATH 收据（N29-P3-3）"
fi

# T25a (N29-P2-1): 删 P4b 绑定证据 → complete P4b 拒（对照：证据在 → 过）
W86="$TMP/v3168p4b"; WORKSPACE="$W86" bash "$ROOT/scripts/devflow-state.sh" init p4bx --frontend=not-applicable >/dev/null 2>&1
printf 'p4b-ev\n' > "$W86/evidence-p4b.txt"
jq '.current_phase = "P4b" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="completed" | .phases.P4b.status="in_progress"' "$W86/.devflow/p4bx.state.json" > "$W86/s.tmp" && mv "$W86/s.tmp" "$W86/.devflow/p4bx.state.json"
(cd "$W86" && mkrc p4bx P4b evidence-p4b.txt)
if WORKSPACE="$W86" bash "$ROOT/scripts/devflow-state.sh" complete p4bx P4b >/dev/null 2>&1 \
   && [ "$(jq -r '.current_phase' "$W86/.devflow/p4bx.state.json")" = "P5" ]; then
  _P4B_BASE=ok
else
  _P4B_BASE=bad
fi
jq '.current_phase = "P4b" | .phases.P4b.status = "in_progress" | .phases.P4b.completed_at = null | .phases.P5.status = "pending" | .phases.P5.started_at = null' "$W86/.devflow/p4bx.state.json" > "$W86/s.tmp" && mv "$W86/s.tmp" "$W86/.devflow/p4bx.state.json"
rm -f "$W86/evidence-p4b.txt"
_P4BR=$(cd "$W86" && WORKSPACE="$W86" bash "$ROOT/scripts/devflow-state.sh" complete p4bx P4b 2>&1)
if [ "$_P4B_BASE" = "ok" ] && printf '%s' "$_P4BR" | grep -q 'P4b 收据'; then
  ok "删 P4b 绑定证据后 complete P4b 被拒（N29-P2-1 钉；基线=ok）"
else
  bad "删 P4b 绑定证据后 complete P4b 未被拒（N29-P2-1；基线=${_P4B_BASE}——基线失败=测试无效）"
fi

# T25b (N29-P2-2): 删 P0b 绑定证据 → complete P0b 拒（对照：证据在 → 过）
W87="$TMP/v3168p0b"; WORKSPACE="$W87" bash "$ROOT/scripts/devflow-state.sh" init p0bx --frontend=not-applicable >/dev/null 2>&1
printf 'p0b-ev\n' > "$W87/evidence-p0b.txt"
jq '.current_phase = "P0b" | .phases.P0.status="completed" | .phases.P0b.status="in_progress"' "$W87/.devflow/p0bx.state.json" > "$W87/s.tmp" && mv "$W87/s.tmp" "$W87/.devflow/p0bx.state.json"
(cd "$W87" && mkrc p0bx P0b evidence-p0b.txt)
if WORKSPACE="$W87" bash "$ROOT/scripts/devflow-state.sh" complete p0bx P0b >/dev/null 2>&1 \
   && [ "$(jq -r '.current_phase' "$W87/.devflow/p0bx.state.json")" = "P1" ]; then
  _P0B_BASE=ok
else
  _P0B_BASE=bad
fi
jq '.current_phase = "P0b" | .phases.P0b.status = "in_progress" | .phases.P0b.completed_at = null | .phases.P1.status = "pending" | .phases.P1.started_at = null' "$W87/.devflow/p0bx.state.json" > "$W87/s.tmp" && mv "$W87/s.tmp" "$W87/.devflow/p0bx.state.json"
rm -f "$W87/evidence-p0b.txt"
_P0BR=$(cd "$W87" && WORKSPACE="$W87" bash "$ROOT/scripts/devflow-state.sh" complete p0bx P0b 2>&1)
if [ "$_P0B_BASE" = "ok" ] && printf '%s' "$_P0BR" | grep -q 'P0b 收据'; then
  ok "删 P0b 绑定证据后 complete P0b 被拒（N29-P2-2 钉；基线=ok）"
else
  bad "删 P0b 绑定证据后 complete P0b 未被拒（N29-P2-2；基线=${_P0B_BASE}——基线失败=测试无效）"
fi

# T25c (N29-P2-3): 旧契约收据剥离绑定行 → complete P7 拒（链复查硬口径）
#（对照组：绑定行保留仅删证据 → 拒（T24c 已证）——判别变量即剥离行为本身）
W88="$TMP/v3168strip"; WORKSPACE="$W88" bash "$ROOT/scripts/devflow-state.sh" init p7s --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P7" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="completed" | .phases.P4b.status="completed" | .phases.P5.status="completed" | .phases.P6.status="completed" | .phases.P7.status="in_progress"' "$W88/.devflow/p7s.state.json" > "$W88/s.tmp" && mv "$W88/s.tmp" "$W88/.devflow/p7s.state.json"
printf 'p7s-ev\n' > "$W88/evidence-p7s.txt"
(cd "$W88" && for _ph in P0 P1 P2 P2a P2b P3 P6; do mkrc p7s "$_ph"; done; for _ph in P0b P3b P3cd P4 P4b P5 P7; do mkrc p7s "$_ph" evidence-p7s.txt; done; mkrc p7s P6-credential)
(cd "$W88" && bash "$ROOT/checks/check-arch-pitfalls.sh" --all --receipt p7s >/dev/null 2>&1 || true)
(cd "$W88" && \
  printf 'ID\tSTATUS\nA01\tPASS\n' > .devflow/p7s/final-verification.tsv && \
  printf 'ENVIRONMENT=staging\n' > .devflow/p7s/test-evidence.env && \
  _P7SJ=$(jq -cn --arg a ".devflow/p7s/final-verification.tsv" --arg b ".devflow/p7s/test-evidence.env" '[$a,$b]') && \
  _P7ST=$(receipt_evidence_tree .devflow/p7s/final-verification.tsv .devflow/p7s/test-evidence.env) && \
  mkdir -p .devflow/p7s/gates/P6-final docs/p7s/gates/P6-final && \
  printf 'EXIT_CODE=0\nVERSION=p6-final@%s\nPHASE=P6-final\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPRODUCER_ROLE=final-verifier\nSESSION_ID=s1\nENVIRONMENT=staging\nPASS=8 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$_P7SJ" "$_P7ST" > .devflow/p7s/gates/P6-final/receipt.txt && \
  cp .devflow/p7s/gates/P6-final/receipt.txt docs/p7s/gates/P6-final/receipt.txt)
if (cd "$W88" && WORKSPACE="$W88" bash "$ROOT/scripts/devflow-state.sh" complete p7s P7 >/dev/null 2>&1) \
   && [ "$(jq -r '.current_phase' "$W88/.devflow/p7s.state.json")" = "P8" ]; then
  _P7S_BASE=ok
else
  _P7S_BASE=bad
fi
jq '.current_phase = "P7" | .phases.P7.status = "in_progress" | .phases.P7.completed_at = null | .phases.P8.status = "pending" | .phases.P8.started_at = null' "$W88/.devflow/p7s.state.json" > "$W88/s.tmp" && mv "$W88/s.tmp" "$W88/.devflow/p7s.state.json"
# 攻击：剥离 P4 收据 EVIDENCE 两行（双份一致）——剥离使收据降级 legacy 绕过软口径
for _rf in "$W88/.devflow/p7s/gates/P4/receipt.txt" "$W88/docs/p7s/gates/P4/receipt.txt"; do
  sed -i '' '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d' "$_rf" 2>/dev/null || sed -i '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d' "$_rf"
done
_P7SR=$(cd "$W88" && WORKSPACE="$W88" bash "$ROOT/scripts/devflow-state.sh" complete p7s P7 2>&1)
if [ "$_P7S_BASE" = "ok" ] && printf '%s' "$_P7SR" | grep -q 'P4'; then
  ok "剥离 P4 绑定行后 complete P7 被拒（N29-P2-3 钉；基线=ok）"
else
  bad "剥离 P4 绑定行后 complete P7 未被拒（N29-P2-3；基线=${_P7S_BASE}——基线失败=测试无效）"
fi

# T25d (N29-P3-1): 旧契约收据剥离绑定行 → audit FAIL（fail-open 收口）
W89="$TMP/v3168astrip"; WORKSPACE="$W89" bash "$ROOT/scripts/devflow-state.sh" init ast --frontend=not-applicable >/dev/null 2>&1
printf 'ast-ev\n' > "$W89/evidence-ast.txt"
(cd "$W89" && mkrc ast P4 evidence-ast.txt)
for _rf in "$W89/.devflow/ast/gates/P4/receipt.txt" "$W89/docs/ast/gates/P4/receipt.txt"; do
  sed -i '' '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d' "$_rf" 2>/dev/null || sed -i '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d' "$_rf"
done
_ASTR=$(cd "$W89" && bash "$ROOT/scripts/audit-receipts.sh" ast .devflow docs 2>&1)
if printf '%s' "$_ASTR" | grep -q '新契约收据.*缺证据绑定行\|缺证据绑定行.*EVIDENCE_PATHS_JSON'; then
  ok "新 P4 契约剥离证据树字段被审计阻断（N29-P3-1 钉）"
else
  bad "旧契约收据剥离绑定行审计未 FAIL（N29-P3-1）"
fi

# T25e (N29-P3-2): 辅助收据双份删除 → audit FAIL（零感知面收口）
W90="$TMP/v3168auxdel"; WORKSPACE="$W90" bash "$ROOT/scripts/devflow-state.sh" init axd --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P7" | .phases.P3b.status="completed" | .phases.P6.status="completed"' "$W90/.devflow/axd.state.json" > "$W90/s.tmp" && mv "$W90/s.tmp" "$W90/.devflow/axd.state.json"
printf 'axd-ev\n' > "$W90/evidence-axd.txt"
(cd "$W90" && mkrc axd P3b evidence-axd.txt; mkrc axd P6 evidence-axd.txt)
_AXD=$(cd "$W90" && bash "$ROOT/scripts/audit-receipts.sh" axd .devflow docs 2>&1)
if printf '%s' "$_AXD" | grep -q 'ARCH-PITFALLS 收据缺失' && printf '%s' "$_AXD" | grep -q 'P6-final 收据缺失'; then
  ok "辅助收据双份删除被审计阻断（N29-P3-2 钉：ARCH + P6-credential/P6-final）"
else
  bad "辅助收据双份删除审计零感知（N29-P3-2）"
fi

# ===== v3.16.9（第 30 轮 N30）: 行为钉 T26a-c =====

# T26a (N30-P2-1): 剥离绑定行 + VERSION 降级到阈值以下 → complete P7 拒（链 VERSION 钉）
#（v3.16.8 收口只封住"保留版本行"的剥离——双行攻击成本仅多改 1 行）
W91="$TMP/v3169ver"; WORKSPACE="$W91" bash "$ROOT/scripts/devflow-state.sh" init p7v --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P7" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="completed" | .phases.P4b.status="completed" | .phases.P5.status="completed" | .phases.P6.status="completed" | .phases.P7.status="in_progress"' "$W91/.devflow/p7v.state.json" > "$W91/s.tmp" && mv "$W91/s.tmp" "$W91/.devflow/p7v.state.json"
printf 'p7v-ev\n' > "$W91/evidence-p7v.txt"
(cd "$W91" && for _ph in P0 P1 P2 P2a P2b P3 P6; do mkrc p7v "$_ph"; done; for _ph in P0b P3b P3cd P4 P4b P5 P7; do mkrc p7v "$_ph" evidence-p7v.txt; done; mkrc p7v P6-credential)
(cd "$W91" && bash "$ROOT/checks/check-arch-pitfalls.sh" --all --receipt p7v >/dev/null 2>&1 || true)
(cd "$W91" && \
  printf 'ID\tSTATUS\nA01\tPASS\n' > .devflow/p7v/final-verification.tsv && \
  printf 'ENVIRONMENT=staging\n' > .devflow/p7v/test-evidence.env && \
  _V9J=$(jq -cn --arg a ".devflow/p7v/final-verification.tsv" --arg b ".devflow/p7v/test-evidence.env" '[$a,$b]') && \
  _V9T=$(receipt_evidence_tree .devflow/p7v/final-verification.tsv .devflow/p7v/test-evidence.env) && \
  mkdir -p .devflow/p7v/gates/P6-final docs/p7v/gates/P6-final && \
  printf 'EXIT_CODE=0\nVERSION=p6-final@%s\nPHASE=P6-final\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPRODUCER_ROLE=final-verifier\nSESSION_ID=s1\nENVIRONMENT=staging\nPASS=8 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$_V9J" "$_V9T" > .devflow/p7v/gates/P6-final/receipt.txt && \
  cp .devflow/p7v/gates/P6-final/receipt.txt docs/p7v/gates/P6-final/receipt.txt)
if (cd "$W91" && WORKSPACE="$W91" bash "$ROOT/scripts/devflow-state.sh" complete p7v P7 >/dev/null 2>&1) \
   && [ "$(jq -r '.current_phase' "$W91/.devflow/p7v.state.json")" = "P8" ]; then
  _V9_BASE=ok
else
  _V9_BASE=bad
fi
jq '.current_phase = "P7" | .phases.P7.status = "in_progress" | .phases.P7.completed_at = null | .phases.P8.status = "pending" | .phases.P8.started_at = null' "$W91/.devflow/p7v.state.json" > "$W91/s.tmp" && mv "$W91/s.tmp" "$W91/.devflow/p7v.state.json"
# 攻击：剥离 P4 绑定行 + VERSION 降级到阈值以下（g@3.9.0 < 3.13.4，双份一致）
for _rf in "$W91/.devflow/p7v/gates/P4/receipt.txt" "$W91/docs/p7v/gates/P4/receipt.txt"; do
  sed -i '' '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d' "$_rf" 2>/dev/null || sed -i '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d' "$_rf"
  sed -i '' "s|^VERSION=p4-validation@.*|VERSION=p4-validation@3.9.0|" "$_rf" 2>/dev/null || sed -i "s|^VERSION=p4-validation@.*|VERSION=p4-validation@3.9.0|" "$_rf"
done
_V9R=$(cd "$W91" && WORKSPACE="$W91" bash "$ROOT/scripts/devflow-state.sh" complete p7v P7 2>&1)
if [ "$_V9_BASE" = "ok" ] && printf '%s' "$_V9R" | grep -q '版本不匹配\|自报降级'; then
  ok "剥离+版本降级双行攻击被链 VERSION 钉拦截（N30-P2-1 钉；基线=ok）"
else
  bad "剥离+版本降级绕过链复查（N30-P2-1；基线=${_V9_BASE}——基线失败=测试无效）"
fi

# T26b (N30-P3-1): 失败轮收据无绑定行 → audit WARN 放行（不误报"被剥离"）
W92="$TMP/v3169fr"; WORKSPACE="$W92" bash "$ROOT/scripts/devflow-state.sh" init fr9 --frontend=not-applicable >/dev/null 2>&1
mkdir -p "$W92/.devflow/fr9/gates/P4" "$W92/docs/fr9/gates/P4"
# 模拟 p4 gate 失败轮真实产物：EXIT_CODE=1 且 EVIDENCE_PATH 为空行（报告缺失时 gate 仍写收据）
printf 'EXIT_CODE=1\nVERSION=g@%s\nPHASE=P4\nSKILL_TREE=%s\nEVIDENCE_PATH=\nEVIDENCE_SHA256=\nPASS=0 FAIL=3 WARN=0\n' "$SKILL_VER" "$TREE" > "$W92/.devflow/fr9/gates/P4/receipt.txt"
cp "$W92/.devflow/fr9/gates/P4/receipt.txt" "$W92/docs/fr9/gates/P4/receipt.txt"
_FR9=$(cd "$W92" && bash "$ROOT/scripts/audit-receipts.sh" fr9 .devflow docs 2>&1)
_FR9_RC=$(cd "$W92" && bash "$ROOT/scripts/audit-receipts.sh" fr9 .devflow docs >/dev/null 2>&1; echo $?)
if printf '%s' "$_FR9" | grep -q '失败轮收据无证据绑定' && [ "$_FR9_RC" = "0" ] \
   && ! printf '%s' "$_FR9" | grep -q '被剥离'; then
  ok "失败轮收据无绑定被 WARN 放行不误报（N30-P3-1 正向钉）"
else
  bad "失败轮收据被误报剥离（N30-P3-1；rc=${_FR9_RC}）"
fi

# T26c (N30-P3-2): 辅助收据双份一致降级 EXIT_CODE=1 → audit FAIL（存在性+终态）
W93="$TMP/v3169deg2"; WORKSPACE="$W93" bash "$ROOT/scripts/devflow-state.sh" init dg9 --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P7" | .phases.P6.status="completed"' "$W93/.devflow/dg9.state.json" > "$W93/s.tmp" && mv "$W93/s.tmp" "$W93/.devflow/dg9.state.json"
printf 'dg9-ev\n' > "$W93/evidence-dg9.txt"
(cd "$W93" && mkrc dg9 P6 evidence-dg9.txt; mkrc dg9 P6-credential)
(cd "$W93" && bash "$ROOT/checks/check-arch-pitfalls.sh" --all --receipt dg9 >/dev/null 2>&1 || true)
(cd "$W93" && \
  printf 'ID\tSTATUS\nA01\tPASS\n' > .devflow/dg9/final-verification.tsv && \
  printf 'ENVIRONMENT=staging\n' > .devflow/dg9/test-evidence.env && \
  _D9J=$(jq -cn --arg a ".devflow/dg9/final-verification.tsv" --arg b ".devflow/dg9/test-evidence.env" '[$a,$b]') && \
  _D9T=$(receipt_evidence_tree .devflow/dg9/final-verification.tsv .devflow/dg9/test-evidence.env) && \
  mkdir -p .devflow/dg9/gates/P6-final docs/dg9/gates/P6-final && \
  printf 'EXIT_CODE=0\nVERSION=p6-final@%s\nPHASE=P6-final\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPRODUCER_ROLE=final-verifier\nSESSION_ID=s1\nENVIRONMENT=staging\nPASS=8 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$_D9J" "$_D9T" > .devflow/dg9/gates/P6-final/receipt.txt && \
  cp .devflow/dg9/gates/P6-final/receipt.txt docs/dg9/gates/P6-final/receipt.txt)
for _rf in "$W93/.devflow/dg9/gates/P6-final/receipt.txt" "$W93/docs/dg9/gates/P6-final/receipt.txt"; do
  sed -i '' 's/^EXIT_CODE=0/EXIT_CODE=1/' "$_rf" 2>/dev/null || sed -i 's/^EXIT_CODE=0/EXIT_CODE=1/' "$_rf"
done
_DG9=$(cd "$W93" && bash "$ROOT/scripts/audit-receipts.sh" dg9 .devflow docs 2>&1)
if printf '%s' "$_DG9" | grep -q '辅助收据 P6-final.*值降级\|P6-final EXIT_CODE'; then
  ok "辅助收据双份一致降级被审计阻断（N30-P3-2 钉）"
else
  bad "辅助收据降级审计零感知（N30-P3-2）"
fi

# T27 (v3.16.10, N31-P3-1): P3b 未 completed + ARCH 失败轮收据 → audit 放行（不误报值降级）
W94="$TMP/v31610aux"; WORKSPACE="$W94" bash "$ROOT/scripts/devflow-state.sh" init ax10 --frontend=not-applicable >/dev/null 2>&1
mkdir -p "$W94/.devflow/ax10/gates/ARCH-PITFALLS" "$W94/docs/ax10/gates/ARCH-PITFALLS"
# ARCH 失败轮收据（EXIT_CODE=1，gate 迭代中合法产物；P3b 未 completed——state 默认全 pending）
printf 'EXIT_CODE=1\nVERSION=arch-pitfalls@%s\nPHASE=ARCH-PITFALLS\nSKILL_TREE=%s\nPASS=0 FAIL=2 WARN=0\n' "$SKILL_VER" "$TREE" > "$W94/.devflow/ax10/gates/ARCH-PITFALLS/receipt.txt"
cp "$W94/.devflow/ax10/gates/ARCH-PITFALLS/receipt.txt" "$W94/docs/ax10/gates/ARCH-PITFALLS/receipt.txt"
_AX10=$(cd "$W94" && bash "$ROOT/scripts/audit-receipts.sh" ax10 .devflow docs 2>&1)
_AX10_RC=$(cd "$W94" && bash "$ROOT/scripts/audit-receipts.sh" ax10 .devflow docs >/dev/null 2>&1; echo $?)
if [ "$_AX10_RC" = "0" ] && printf '%s' "$_AX10" | grep -q '失败轮辅助收据' \
   && ! printf '%s' "$_AX10" | grep -q '值降级篡改'; then
  ok "P3b 未 completed 时 ARCH 失败轮收据 WARN 放行（N31-P3-1 钉）"
else
  bad "失败轮辅助收据被误报值降级（N31-P3-1；rc=${_AX10_RC}）"
fi

# ===== v3.16.11（用户压力夹具第 32 轮）: 行为钉 T28a-h =====

# _mkfull: 构造完整合法终验场景（冻结 baseline 3 点全 PASS + 五类真实报告）
# 用途：T28a 正向基线 / T28d 删报告攻击起点
_mkverif() { # $1=workspace —— 从 test-evidence.env 生成合法 verification.json（命令逐字一致）
  "${DEVFLOW_PY[@]}" - "$1" <<'PYEOF'
import json, sys, pathlib
w = pathlib.Path(sys.argv[1])
env = {}
for ln in (w / ".devflow/fx/test-evidence.env").read_text(encoding="utf-8").splitlines():
    if "=" in ln and not ln.startswith("#"):
        k, v = ln.split("=", 1)
        env[k] = v
kinds = ["unit", "integration", "client", "load", "staging"]
ids = [ln.split("\t")[0] for ln in (w / ".devflow/fx/final-verification.tsv").read_text(encoding="utf-8").splitlines()[1:] if ln.strip()]
evidence = {}
for k in kinds:
    K = k.upper()
    evidence[k] = {"cmd": env[f"{K}_CMD"], "exit_code": int(env[f"{K}_EXIT"]), "report_path": env[f"{K}_REPORT_PATH"]}
doc = {
    "feature": "fx", "generated_at": "2026-09-13T00:00:00Z", "environment": env.get("ENVIRONMENT", "staging"),
    "acceptance_results": [{"id": i, "status": "PASS"} for i in ids],
    "evidence": evidence,
    "client_not_applicable": {"declared": False, "frontend_scope": "pc-web"},
    "zero_results": [],
}
json.dump(doc, open(w / ".devflow/fx/verification.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PYEOF
}

_mkfull() { # $1=workspace
  local w="$1" k
  mkdir -p "$w/.devflow/fx"
  # v3.19.0(P0-1/P0-3): s6 对账冻结前端范围 + verification.json 必填——夹具同步冻结 pc-web
  printf '{"feature":"fx","scope":{"frontend":"pc-web","frontend_dir":"frontend"},"current_phase":"P6"}\n' > "$w/.devflow/fx.state.json"
  printf 'acceptance_id\tstatus\nM-01-F01-A01\tFROZEN\nM-01-F01-A02\tFROZEN\nM-01-F02-A01\tFROZEN\n' > "$w/.devflow/fx/first-pass-baseline.tsv"
  printf 'feature=fx\ngit_sha=UNCOMMITTED\ndesign_path=docs/detailed-design/fx-design.md\ncriteria_path=docs/requirements/fx-acceptance-criteria.md\ndesign_sha256=abc\ncriteria_sha256=abc\nfrozen_at=2026-08-30T00:00:00Z\nacceptance_count=3\n' > "$w/.devflow/fx/first-pass-meta.env"
  printf 'ID\tSTATUS\nM-01-F01-A01\tPASS\nM-01-F01-A02\tPASS\nM-01-F02-A01\tPASS\n' > "$w/.devflow/fx/final-verification.tsv"
  mkdir -p "$w/.devflow/fx/reports"
  # v3.20.2(P0-3): awk 生成器已被 provenance 拒绝——夹具改用 make 受信运行器
  cat > "$w/Makefile" <<'MKEOF'
test-report:
	@k=`echo $(KIND) | tr "A-Z" "a-z"`; \
		printf "# %s test report\nsuite: %s-suite\ncases: 42\npassed: 42\nfailed: 0\nrun: %s\n" "$$k" "$$k" "$$(date +%s)" > .devflow/fx/reports/$$k-report.txt; \
		echo "runner=$$k"
MKEOF
  # v3.20.2: 报告由 make test-report 在 gate 执行期生成（预制报告会触发陈旧证据拒绝）
  {
    printf 'UNIT_CMD=make test-report KIND=UNIT\nUNIT_EXIT=0\nUNIT_REPORT_PATH=.devflow/fx/reports/unit-report.txt\n'
    printf 'INTEGRATION_CMD=make test-report KIND=INTEGRATION\nINTEGRATION_EXIT=0\nINTEGRATION_REPORT_PATH=.devflow/fx/reports/integration-report.txt\n'
    printf 'CLIENT_CMD=make test-report KIND=CLIENT RUNNER=playwright\nCLIENT_EXIT=0\nCLIENT_REPORT_PATH=.devflow/fx/reports/client-report.txt\n'
    printf 'LOAD_CMD=make test-report KIND=LOAD\nLOAD_EXIT=0\nLOAD_REPORT_PATH=.devflow/fx/reports/load-report.txt\n'
    # v3.21.0: STAGING 须为真实容器执行（curl http(s) 探测）；date 追加使每轮报告
    # 内容变化，避免重复运行同一 workspace 时触发陈旧证据拒绝
    printf 'STAGING_CMD=curl -fsS http://127.0.0.1:%s/healthz -o .devflow/fx/reports/staging-report.txt && date +%%s >> .devflow/fx/reports/staging-report.txt && printf staging-probe-captured\\n\nSTAGING_EXIT=0\nSTAGING_REPORT_PATH=.devflow/fx/reports/staging-report.txt\n' "$STAGING_PROBE_PORT"
    printf 'ENVIRONMENT=staging\n'
  } > "$w/.devflow/fx/test-evidence.env"
  _mkverif "$w"
}

# T28a (P0-2 正向基线): 完整合法场景 → gate PASS（基线失败=后续攻击钉全部无效）
W95="$TMP/v31611base"; _mkfull "$W95"
_T28A=$(cd "$W95" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T28A" | grep -q 'rc=0' && printf '%s' "$_T28A" | grep -q 'P6-FINAL GATE: PASS'; then
  ok "完整合法终验场景 gate PASS（T28 正向基线）"
else
  bad "完整合法终验场景 gate 未 PASS（T28 正向基线失败=后续攻击钉无效）: $(printf '%s' "$_T28A" | grep -E '\[P0\]|rc=' | head -3 | tr '\n' ' ')"
fi

# T28a-2 (v3.19.0 P0-1): 冻结前端 pc-web + CLIENT_EXEMPT=1 → 拒（声明不可覆盖冻结）
W95X="$TMP/v3190exempt"; _mkfull "$W95X"
printf 'CLIENT_EXEMPT=1\n' >> "$W95X/.devflow/fx/test-evidence.env"
_T28A2=$(cd "$W95X" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T28A2" | grep -q '冻结前端范围' && ! printf '%s' "$_T28A2" | grep -q 'rc=0$'; then
  ok "CLIENT_EXEMPT 无法覆盖冻结前端范围 pc-web（P0-1 钉）"
else
  bad "CLIENT_EXEMPT 绕过冻结前端范围仍 PASS（P0-1 回归）: $(printf '%s' "$_T28A2" | grep -E '\[P0\]|rc=' | head -2 | tr '\n' ' ')"
fi

# T28a-3 (v3.21.0): make 级命令冒充 STAGING → 拒（P6_STAGING_NOT_CONTAINER 钉；
# 治理服务复盘：MockMvc 全绿 ≠ 容器可用，STAGING 须真实容器签名）
W95Y="$TMP/v3210staging"; _mkfull "$W95Y"
printf 'STAGING_CMD=make test-report KIND=STAGING\nSTAGING_EXIT=0\nSTAGING_REPORT_PATH=.devflow/fx/reports/staging-report.txt\n' > "$W95Y/.devflow/fx/test-evidence.env"
printf 'UNIT_CMD=make test-report KIND=UNIT\nUNIT_EXIT=0\nUNIT_REPORT_PATH=.devflow/fx/reports/unit-report.txt\n' >> "$W95Y/.devflow/fx/test-evidence.env"
printf 'INTEGRATION_CMD=make test-report KIND=INTEGRATION\nINTEGRATION_EXIT=0\nINTEGRATION_REPORT_PATH=.devflow/fx/reports/integration-report.txt\n' >> "$W95Y/.devflow/fx/test-evidence.env"
printf 'CLIENT_CMD=make test-report KIND=CLIENT RUNNER=playwright\nCLIENT_EXIT=0\nCLIENT_REPORT_PATH=.devflow/fx/reports/client-report.txt\n' >> "$W95Y/.devflow/fx/test-evidence.env"
printf 'LOAD_CMD=make test-report KIND=LOAD\nLOAD_EXIT=0\nLOAD_REPORT_PATH=.devflow/fx/reports/load-report.txt\n' >> "$W95Y/.devflow/fx/test-evidence.env"
printf 'ENVIRONMENT=staging\n' >> "$W95Y/.devflow/fx/test-evidence.env"
_T28A3=$(cd "$W95Y" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T28A3" | grep -q 'P6_STAGING_NOT_CONTAINER'; then
  ok "make 级命令冒充 STAGING 被拒（v3.21.0 容器签名钉）"
else
  bad "make 级命令冒充 STAGING 未被拒（v3.21.0 回归）: $(printf '%s' "$_T28A3" | grep -E '\[P0\]|rc=' | head -2 | tr '\n' ' ')"
fi

# T28b (P0-1): 无 baseline + ONLY-ONE PASS → 拒（用户 PoC 复刻）
W96="$TMP/v31611poc1"; mkdir -p "$W96/.devflow/fx"
printf 'ID\tSTATUS\nONLY-ONE\tPASS\n' > "$W96/.devflow/fx/final-verification.tsv"
printf 'ENVIRONMENT=dev\n' > "$W96/.devflow/fx/test-evidence.env"
_T28B=$(cd "$W96" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T28B" | grep -q 'rc=1' && printf '%s' "$_T28B" | grep -q 'first-pass-baseline.tsv 缺失'; then
  ok "无 baseline 的 ONLY-ONE PASS 被拒（P0-1 钉：冻结集合对账前置）"
else
  bad "无 baseline 的 ONLY-ONE PASS 未被拒（P0-1；rc=$(printf '%s' "$_T28B" | grep -o 'rc=.' | head -1)）"
fi

# T28c (P0-1): baseline 3 点但 final 只交 1 点（缺失）/ 额外 ID / 重复 ID → 拒
W97="$TMP/v31611poc2"; _mkfull "$W97"
printf 'ID\tSTATUS\nM-01-F01-A01\tPASS\n' > "$W97/.devflow/fx/final-verification.tsv"
_T28C1=$(cd "$W97" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T28C1" | grep -q '缺失冻结验收点: 2 个'; then
  ok "终验缺失冻结点（3 冻结只交 1）被拒（P0-1 钉）"
else
  bad "终验缺失冻结点未被拒（P0-1）"
fi
printf 'ID\tSTATUS\nM-01-F01-A01\tPASS\nM-01-F01-A02\tPASS\nM-01-F02-A01\tPASS\nEXTRA-99\tPASS\n' > "$W97/.devflow/fx/final-verification.tsv"
_T28C2=$(cd "$W97" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T28C2" | grep -q '未冻结的额外 ID'; then
  ok "终验额外未冻结 ID 被拒（P0-1 钉）"
else
  bad "终验额外未冻结 ID 未被拒（P0-1）"
fi
printf 'ID\tSTATUS\nM-01-F01-A01\tPASS\nM-01-F01-A01\tPASS\nM-01-F01-A02\tPASS\nM-01-F02-A01\tPASS\n' > "$W97/.devflow/fx/final-verification.tsv"
_T28C3=$(cd "$W97" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T28C3" | grep -q '重复 ID'; then
  ok "终验重复 ID 被拒（P0-1 钉）"
else
  bad "终验重复 ID 未被拒（P0-1）"
fi

# T28d (P0-2): 五类全自报（CMD=true + 同一份 ok 文件）→ 拒（用户 PoC 复刻）
W98="$TMP/v31611poc3"; _mkfull "$W98"
printf 'ok\n' > "$W98/.devflow/fx/reports/shared-ok.txt"
_OK_SHA=$(hash_file_test "$W98/.devflow/fx/reports/shared-ok.txt")
{
  for k in UNIT INTEGRATION CLIENT LOAD STAGING; do
    printf '%s_CMD=true\n%s_EXIT=0\n%s_REPORT_PATH=.devflow/fx/reports/shared-ok.txt\n%s_REPORT_SHA256=%s\n' "$k" "$k" "$k" "$k" "$_OK_SHA"
  done
  printf 'ENVIRONMENT=dev\n'
} > "$W98/.devflow/fx/test-evidence.env"
_T28D=$(cd "$W98" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T28D" | grep -q '占位命令' && printf '%s' "$_T28D" | grep -q '同一报告文件'; then
  ok "五类自报（true+共用 ok 文件）被拒（P0-2 钉：占位命令+互异+实质内容三层）"
else
  bad "五类自报未被拒（P0-2；命中: $(printf '%s' "$_T28D" | grep -oE '占位命令|同一报告文件|占位（' | sort -u | tr '\n' ' ')）"
fi

# T28e (P0-2): 删五类报告后 audit 阻断（报告入收据证据树——用户 PoC 复刻）
W99="$TMP/v31611poc4"; _mkfull "$W99"
(cd "$W99" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx >/dev/null 2>&1)
_BASE_RC=$(cd "$W99" && bash "$ROOT/scripts/audit-receipts.sh" fx .devflow docs >/dev/null 2>&1; echo $?)
rm -f "$W99/.devflow/fx/reports/client-report.txt"
_DEL_RC=$(cd "$W99" && bash "$ROOT/scripts/audit-receipts.sh" fx .devflow docs >/dev/null 2>&1; echo $?)
if [ "$_BASE_RC" = "0" ] && [ "$_DEL_RC" != "0" ]; then
  ok "删五类报告后 audit 阻断（P0-2 钉：报告入 EVIDENCE_PATHS_JSON；基线=${_BASE_RC}）"
else
  bad "删五类报告后 audit 未阻断（P0-2；基线=${_BASE_RC} 删后=${_DEL_RC}——基线失败=测试无效）"
fi

# T28f (P1-3): 最终层 symlink 指向 workspace 外稳定文件 → verify 拒（用户 PoC 复刻）
W100="$TMP/v31611link"; _EXTF=$(mktemp -t v31611extXXXXXX)
printf 'external-stable-content\n' > "$_EXTF"
mkdir -p "$W100/.devflow/fx/gates/P3b"
ln -s "$_EXTF" "$W100/evidence-link"
_EXT_SHA=$(hash_file_test "$_EXTF")
printf 'EXIT_CODE=0\nVERSION=g@%s\nPHASE=P3b\nEVIDENCE_PATH=evidence-link\nEVIDENCE_SHA256=%s\n' "$SKILL_VER" "$_EXT_SHA" > "$W100/.devflow/fx/gates/P3b/receipt.txt"
_RCPT="$W100/.devflow/fx/gates/P3b/receipt.txt"
_T28F=$(cd "$W100" && WORKSPACE="$W100" _RCPT="$_RCPT" bash -c 'source "$0/../devflow_receipt.sh" 2>/dev/null || true' /dev/null 2>/dev/null; true)
_T28F=$(cd "$W100" && WORKSPACE="$W100" RCPT="$_RCPT" ROOT="$ROOT" bash -c 'source "$ROOT/scripts/devflow_receipt.sh"; verify_receipt_evidence "$RCPT"' 2>&1)
if printf '%s' "$_T28F" | grep -q '越界'; then
  ok "最终层 symlink 指向外部文件被拒（P1-3 钉：完整 realpath）"
else
  bad "最终层 symlink 逃逸未被拒（P1-3）"
fi
rm -f "$_EXTF"

# T28g (P1-4): p3b service 路径穿越（../clean）真实服务含 TODO → 拒（用户 PoC 复刻）
W101="$TMP/v31611svc"; mkdir -p "$W101/docs/review" "$W101/docs/detailed-design" "$W101/docs/requirements" "$W101/backend/svc-real/src/main/java" "$W101/clean/src/main/java"
printf '# d\nM-01-F01-A01\n' > "$W101/docs/detailed-design/fx-design.md"
printf '# c\nM-01-F01-A01\n' > "$W101/docs/requirements/fx-acceptance-criteria.md"
printf '# r\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$W101/docs/review/fx-code-review-report.md"
printf 'class A { /* TODO fix */ }\n' > "$W101/backend/svc-real/src/main/java/A.java"
printf 'class Clean {}\n' > "$W101/clean/src/main/java/C.java"
WORKSPACE="$W101" bash "$ROOT/scripts/devflow-state.sh" init fx --frontend=not-applicable >/dev/null 2>&1
_T28G=$(cd "$W101" && bash "$ROOT/scripts/p3b_code_review_gate.sh" fx ../clean 2>&1; echo "rc=$?")
# g-1: 穿越参数 → 白名单 p0 拒（rc≠0）
if printf '%s' "$_T28G" | grep -q '路径成分' && printf '%s' "$_T28G" | grep -qv 'rc=0$'; then
  ok "service=../clean 穿越被白名单拒绝（P1-4 钉 1/2）"
else
  bad "service 穿越未被拒（P1-4 钉 1/2）"
fi
# g-2: 合法服务名 + 真实服务含 TODO → 全服务扫描检出（指定干净服务名也无法掩盖）
_T28G2=$(cd "$W101" && bash "$ROOT/scripts/p3b_code_review_gate.sh" fx svc-real 2>&1; echo "rc=$?")
if printf '%s' "$_T28G2" | grep -q 'TODO/FIXME found: 1' && printf '%s' "$_T28G2" | grep -q '全部 1 个服务'; then
  ok "真实服务 TODO 被全服务扫描检出（P1-4 钉 2/2）"
else
  bad "全服务扫描未检出真实 TODO（P1-4 钉 2/2）"
fi

# T28h (P1-5): 阶段注册表一致性——注册表每个 gate 的 docs 引用须真实含该 gate 名
if command -v jq >/dev/null 2>&1 && [ -f "$ROOT/references/phase-registry.json" ]; then
  _REG_MISS=""
  while IFS=$'\t' read -r _stage _doc; do
    [ -n "$_stage" ] || continue
    grep -q "$_stage" "$ROOT/$_doc" 2>/dev/null || _REG_MISS="$_REG_MISS $_doc:$_stage"
  done < <(jq -r '.gates[] | .stage as $s | .docs[] | "\($s)\t\(.)"' "$ROOT/references/phase-registry.json" 2>/dev/null || true)
  if [ -z "$_REG_MISS" ]; then
    ok "阶段注册表文档引用全一致（P1-5 钉：SKILL/ROUTING/test 无 gate 遗漏）"
  else
    bad "注册表引用文档缺 gate 描述（P1-5）:$_REG_MISS"
  fi
else
  bad "phase-registry.json 缺失或 jq 不可用（P1-5 注册表）"
fi

# T29a（P0-2 真实执行）: 配置自报 UNIT_EXIT=0，但实际 UNIT_CMD 退出 1。
# Gate 必须亲自执行命令并拒绝，不能仅核对手写的 EXIT/HASH/报告。
W102="$TMP/v31611live"; _mkfull "$W102"
sed -i '' "s|^UNIT_CMD=.*|UNIT_CMD=grep -q '^never-matches$' .devflow/fx/reports/unit-report.txt|" "$W102/.devflow/fx/test-evidence.env" 2>/dev/null \
  || sed -i "s|^UNIT_CMD=.*|UNIT_CMD=grep -q '^never-matches$' .devflow/fx/reports/unit-report.txt|" "$W102/.devflow/fx/test-evidence.env"
_T29A=$(cd "$W102" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T29A" | grep -qE '实际执行.*exit=1|P6_CMD_(NOT_RUNNER|PROVENANCE)' && ! printf '%s' "$_T29A" | grep -q 'rc=0$'; then
  ok "P6-final 亲自执行 UNIT_CMD，拒绝自报 EXIT=0 但实际 exit=1（T29a）"
else
  bad "P6-final 未执行 UNIT_CMD 或未拒绝实际 exit=1（T29a）"
fi

# T29b（P0-2 收据闭环）: 真实执行记录和 stdout/stderr 日志必须进入收据证据树；
# 删除其中任一日志后 audit 必须阻断，不能只绑定配置文件。
W103="$TMP/v31612logs"; _mkfull "$W103"
(cd "$W103" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx >/dev/null 2>&1)
_T29B_RC=$(cd "$W103" && bash "$ROOT/scripts/audit-receipts.sh" fx .devflow docs >/dev/null 2>&1; echo $?)
_T29B_R="$W103/.devflow/fx/test-execution-results.env"
_T29B_L="$W103/.devflow/fx/test-executions/unit.log"
if [ "$_T29B_RC" = "0" ] && grep -q '^UNIT_ACTUAL_EXIT=0$' "$_T29B_R" \
   && grep -q 'test-execution-results.env' "$W103/.devflow/fx/gates/P6-final/receipt.txt"; then
  _T29B_BASE=ok
else
  _T29B_BASE=bad
fi
rm -f "$_T29B_L"
_T29B_DEL=$(cd "$W103" && bash "$ROOT/scripts/audit-receipts.sh" fx .devflow docs >/dev/null 2>&1; echo $?)
if [ "$_T29B_BASE" = ok ] && [ "$_T29B_DEL" != "0" ]; then
  ok "P6-final 实际执行记录/日志入收据树，删日志后 audit 阻断（T29b）"
else
  bad "P6-final 执行日志未被收据绑定（T29b；基线=${_T29B_BASE} 删后=${_T29B_DEL}）"
fi

# T30a（P0-2）：bash -c 包装命令自造合格报告，不得绕过“真实测试命令”门禁。
W104="$TMP/v31612wrapper"; _mkfull "$W104"
sed -i '' "s|^UNIT_CMD=.*|UNIT_CMD=bash -c 'printf real-test-report-data > .devflow/fx/reports/unit-report.txt'|" "$W104/.devflow/fx/test-evidence.env" 2>/dev/null \
  || sed -i "s|^UNIT_CMD=.*|UNIT_CMD=bash -c 'printf real-test-report-data > .devflow/fx/reports/unit-report.txt'|" "$W104/.devflow/fx/test-evidence.env"
_T30A=$(cd "$W104" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T30A" | grep -qE '包装命令|shell wrapper|shell' && ! printf '%s' "$_T30A" | grep -q 'rc=0$'; then
  ok "P6-final 拒绝 bash -c 自造报告包装命令（T30a）"
else
  bad "P6-final 允许 bash -c 自造报告包装命令（T30a）"
fi

# T30b（P1）：报告绝对路径在 workspace 外时，Gate 本身必须拒绝，不能等到 state 才报错。
W105="$TMP/v31612external"; _mkfull "$W105"
_EXT105=$(mktemp -t devflow316-external-reportXXXXXX)
(cd "$W105" && make test-report KIND=UNIT >/dev/null)
cp "$W105/.devflow/fx/reports/unit-report.txt" "$_EXT105"
_EXT105_SHA=$(hash_file_test "$_EXT105")
sed -i '' "s|^UNIT_REPORT_PATH=.*|UNIT_REPORT_PATH=$_EXT105|; s|^UNIT_REPORT_SHA256=.*|UNIT_REPORT_SHA256=$_EXT105_SHA|" "$W105/.devflow/fx/test-evidence.env" 2>/dev/null \
  || sed -i "s|^UNIT_REPORT_PATH=.*|UNIT_REPORT_PATH=$_EXT105|; s|^UNIT_REPORT_SHA256=.*|UNIT_REPORT_SHA256=$_EXT105_SHA|" "$W105/.devflow/fx/test-evidence.env"
_T30B=$(cd "$W105" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T30B" | grep -qE 'workspace|越界|外部' && ! printf '%s' "$_T30B" | grep -q 'rc=0$'; then
  ok "P6-final 拒绝 workspace 外绝对报告路径（T30b）"
else
  bad "P6-final 允许 workspace 外绝对报告路径（T30b）"
fi
rm -f "$_EXT105"

# T30c（P0）：P3b 必须做验收 ID 集合相等与逐条 P0 闭环，不能用数量和全局 resolved 凑过。
W106="$TMP/v31612p3bsemantic"; mkdir -p "$W106/docs/review" "$W106/docs/detailed-design" "$W106/docs/requirements" "$W106/backend/svc/src/main/java"
printf '# design\nM-01-F01-A01\n' > "$W106/docs/detailed-design/fx-design.md"
printf '# criteria\nM-01-F01-A01\n' > "$W106/docs/requirements/fx-acceptance-criteria.md"
printf '# review\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nP0-1 问题: open defect\nP0-2 问题: another open defect\nresolved unrelated line\nresolved unrelated line\nM-01-F02-A01 mapped\n' > "$W106/docs/review/fx-code-review-report.md"
_T30C=$(cd "$W106" && bash "$ROOT/scripts/p3b_code_review_gate.sh" fx svc 2>&1; echo "rc=$?")
if printf '%s' "$_T30C" | grep -q 'acceptance coverage set mismatch' \
   && printf '%s' "$_T30C" | grep -qE 'P0 issues unclosed|P0.*open' \
   && ! printf '%s' "$_T30C" | grep -q 'rc=0$'; then
  ok "P3b 拒绝验收 ID 数量相等但集合不同且 P0 未逐条闭环（T30c）"
else
  bad "P3b 仍可用数量/全局 resolved 凑过验收与 P0（T30c）"
fi

# T31（P0）：shell wrapper 前置环境变量赋值也必须拒绝；只看命令首词会被 X=1 绕过。
W107="$TMP/v31613envwrapper"; _mkfull "$W107"
sed -i '' "s|^UNIT_CMD=.*|UNIT_CMD=X=1 bash -c 'cat .devflow/fx/reports/unit-report.txt >/dev/null'|" "$W107/.devflow/fx/test-evidence.env" 2>/dev/null \
  || sed -i "s|^UNIT_CMD=.*|UNIT_CMD=X=1 bash -c 'cat .devflow/fx/reports/unit-report.txt >/dev/null'|" "$W107/.devflow/fx/test-evidence.env"
_T31=$(cd "$W107" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T31" | grep -qE '包装命令|shell wrapper|shell' && ! printf '%s' "$_T31" | grep -q 'rc=0$'; then
  ok "P6-final 拒绝前置环境变量赋值的 bash wrapper（T31）"
else
  bad "P6-final 允许 X=1 bash -c wrapper 绕过命令黑名单（T31）"
fi

# T32a（P0）：带空格的环境变量赋值会让 awk 首词解析落到 b'，仍不得绕过 shell wrapper。
W108="$TMP/v31614quotedwrapper"; _mkfull "$W108"
sed -i '' "s|^UNIT_CMD=.*|UNIT_CMD=X='a b' bash -c 'cat .devflow/fx/reports/unit-report.txt >/dev/null'|" "$W108/.devflow/fx/test-evidence.env" 2>/dev/null \
  || sed -i "s|^UNIT_CMD=.*|UNIT_CMD=X='a b' bash -c 'cat .devflow/fx/reports/unit-report.txt >/dev/null'|" "$W108/.devflow/fx/test-evidence.env"
_T32A=$(cd "$W108" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$_T32A" | grep -qE '包装命令|shell wrapper|shell' && ! printf '%s' "$_T32A" | grep -q 'rc=0$'; then
  ok "P6-final 拒绝带空格环境赋值的 bash wrapper（T32a）"
else
  bad "P6-final 允许 X='a b' bash -c wrapper 绕过命令黑名单（T32a）"
fi

# T32b（P0）：P0 finding 必须逐条有结构化 CLOSED 状态；unresolved 不能按子串误判为 closed。
W109="$TMP/v31614p0status"; mkdir -p "$W109/docs/review" "$W109/docs/detailed-design" "$W109/docs/requirements" "$W109/backend/svc/src/main/java"
printf '# design\nM-01-F01-A01\n' > "$W109/docs/detailed-design/fx-design.md"
printf '# criteria\nM-01-F01-A01\n' > "$W109/docs/requirements/fx-acceptance-criteria.md"
printf '# review\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nP0-1 问题: unresolved\nM-01-F01-A01 mapped\n' > "$W109/docs/review/fx-code-review-report.md"
_T32B=$(cd "$W109" && bash "$ROOT/scripts/p3b_code_review_gate.sh" fx svc 2>&1; echo "rc=$?")
if printf '%s' "$_T32B" | grep -qE 'P0.*(unclosed|CLOSED|STATUS)' && ! printf '%s' "$_T32B" | grep -q 'rc=0$'; then
  ok "P3b 拒绝无结构化 CLOSED 状态的 unresolved P0（T32b）"
else
  bad "P3b 将 unresolved P0 误判为已关闭（T32b）"
fi

# T32c（P1）：phase registry 的每个 script 必须真实存在，且 P0/P2/P2a/P3 映射到实际 Gate。
if command -v jq >/dev/null 2>&1 && [ -f "$ROOT/references/phase-registry.json" ]; then
  _REG_SCRIPT_BAD=""
  while IFS=$'\t' read -r _stage _script; do
    [ -n "$_stage" ] || continue
    [ -f "$ROOT/$_script" ] || _REG_SCRIPT_BAD="$_REG_SCRIPT_BAD $_stage=$_script"
  done < <(jq -r '.gates[] | [.stage, (.script | split(" ")[0])] | @tsv' "$ROOT/references/phase-registry.json" 2>/dev/null || true)
  _P0_REG=$(jq -r '.gates[] | select(.stage=="P0") | .script' "$ROOT/references/phase-registry.json")
  _P2_REG=$(jq -r '.gates[] | select(.stage=="P2") | .script' "$ROOT/references/phase-registry.json")
  _P2A_REG=$(jq -r '.gates[] | select(.stage=="P2a") | .script' "$ROOT/references/phase-registry.json")
  _P3_REG=$(jq -r '.gates[] | select(.stage=="P3") | .script' "$ROOT/references/phase-registry.json")
  if [ -z "$_REG_SCRIPT_BAD" ] && printf '%s\n' "$_P0_REG" | grep -q 's0_acceptance_gate' \
     && printf '%s\n' "$_P2_REG" | grep -q 's2_design_coverage_gate' \
     && printf '%s\n' "$_P2A_REG" | grep -q 'p2a_design_review_gate' \
     && printf '%s\n' "$_P3_REG" | grep -q 'p3_completion_gate'; then
    ok "phase registry script paths exist and map to real gates（T32c）"
  else
    bad "phase registry contains dead or wrong gate mappings（T32c）"
  fi
else
  bad "phase registry unavailable for script existence check（T32c）"
fi

# T22e: 假 shasum（空输出）→ arch --receipt exit 2（N25-P3-2 树哈希守卫钉）
W73="$TMP/v3164sha"; mkdir -p "$W73/fbs" "$W73/.devflow/foo"
printf '#!/bin/sh\nexit 1\n' > "$W73/fbs/shasum"; chmod +x "$W73/fbs/shasum"
_SHA1=$(cd "$W73" && PATH="$W73/fbs:$PATH" bash "$ROOT/checks/check-arch-pitfalls.sh" --all --receipt foo >/dev/null 2>&1; echo $?)
[ "$_SHA1" = "2" ] && ok "arch --receipt 假 shasum → exit 2（树哈希守卫钉）" || bad "arch --receipt 假 shasum rc=${_SHA1}（树哈希守卫钉）"

finish EVIDENCE_HARDENING_ROUNDS
