#!/usr/bin/env bash
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"
SKILL_VER=$(sed -n 's/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
set -u

echo "=== devflow report-regression tests ==="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/docs/test-cases" "$TMP/docs/test" "$TMP/frontend/node_modules" "$TMP/docs/requirements"
cat > "$TMP/docs/requirements/foo-acceptance-criteria.md" <<'EOF'
| M-01-F01-A01 | 待验证 |
| M-01-F01-A02 | 待验证 |
EOF
cat > "$TMP/docs/test-cases/foo-test-cases.md" <<'EOF'
# foo 测试用例
| 用例ID | 验收点 | 预置条件 | 步骤 | 预期结果 |
|---|---|---|---|---|
| TC-001 | M-01-F01-A01 | 已登录 | 提交查询条件 | 返回分页结果且状态 PASS |
| TC-002 | M-01-F01-A01 | 已登录 | 查询不存在关键字 | 返回空列表（边界：空结果） |
| TC-003 | M-01-F01-A02 | 已登录 | 传入非法参数 | 校验失败并提示错误 |
| 用户名 | test-user |
| 密码 | 从 seed 来源读取 |
代码来源：BuiltinDataInitializer
EOF
cat > "$TMP/docs/test/migration.env" <<'EOF'
structure=PASS
full_reconciliation=PASS
sample=PASS
boundary=PASS
recovery=PASS
mapping_coverage=100
difference_count=0
EOF
printf 'admin123\n' > "$TMP/frontend/node_modules/generated.js"

gj_copy_sample test-cases foo "$TMP"
if (cd "$TMP" && STATE_DIR="$TMP/.devflow" bash "$ROOT/scripts/p5_test_cases_gate.sh" foo docs/test-cases/foo-test-cases.md >/dev/null) && \
   grep -q "^VERSION=p5-test-cases@${SKILL_VER}\$" "$TMP/.devflow/foo/gates/P5/receipt.txt" && \
   grep -qE '^PASS=[0-9]+ FAIL=0 WARN=[0-9]+$' "$TMP/.devflow/foo/gates/P5/receipt.txt"; then
  ok "P5 test-case gate is the primary receipt with counters"
else
  bad "P5 test-case gate is the primary receipt with counters"
fi

# v3.30.1: Gate JSON 绑定对重验行为钉——篡改/删除正本，重验必须拦截
_TCASES="$TMP/.devflow/foo/test-cases.json"
cp "$_TCASES" "$_TCASES.keep"
cp "$_TCASES" "$_TCASES.bak"
printf '\n// tampered\n' >> "$_TCASES"
_TAMPER=$(cd "$TMP" && WORKSPACE="$TMP" bash -c "source '$ROOT/scripts/devflow_receipt.sh' && verify_receipt_evidence '.devflow/foo/gates/P5/receipt.txt' 2>&1 || true")
if printf '%s' "$_TAMPER" | grep -q "TEST_CASES_JSON 哈希不匹配"; then
  ok "Gate JSON 绑定重验：篡改正本被拦截（哈希不匹配）"
else
  bad "Gate JSON 绑定重验未拦截篡改（${_TAMPER}）"
fi
mv "$_TCASES.bak" "$_TCASES"
rm -f "$_TCASES"
_DEL=$(cd "$TMP" && WORKSPACE="$TMP" bash -c "source '$ROOT/scripts/devflow_receipt.sh' && verify_receipt_evidence '.devflow/foo/gates/P5/receipt.txt' 2>&1 || true")
if printf '%s' "$_DEL" | grep -q "TEST_CASES_JSON 绑定文件缺失"; then
  ok "Gate JSON 绑定重验：删除正本被拦截（绑定文件缺失）"
else
  bad "Gate JSON 绑定重验未拦截删除（${_DEL}）"
fi
cp "$_TCASES.keep" "$_TCASES" && rm -f "$_TCASES.keep"

if (cd "$TMP" && STATE_DIR="$TMP/.devflow" bash "$ROOT/scripts/s5_migration_gate.sh" foo B docs/test/migration.env >/dev/null) && \
   [ -f "$TMP/.devflow/foo/gates/P5-migration/receipt.txt" ] && \
   [ -f "$TMP/docs/foo/gates/P5-migration/receipt.txt" ]; then
  ok "migration evidence uses an auxiliary P5-migration receipt"
else
  bad "migration evidence uses an auxiliary P5-migration receipt"
fi

# v3.14.1: p6 转为 fail-closed——fixture 需提供最小合法证据（报告 + state 声明 not-applicable）
mkdir -p "$TMP/docs/tests"
printf 'coverage ok\n' > "$TMP/docs/tests/foo-测试报告.md"
mkdir -p "$TMP/.devflow"
printf '{"feature":"foo","scope":{"frontend":"not-applicable"}}\n' > "$TMP/.devflow/foo.state.json"
if (cd "$TMP" && STATE_DIR="$TMP/.devflow" bash "$ROOT/scripts/p6_credential_gate.sh" foo >/dev/null) && \
   grep -qE '^PASS=[0-9]+ FAIL=0 WARN=[0-9]+$' "$TMP/.devflow/foo/gates/P6-credential/receipt.txt"; then
  ok "credential scan excludes generated dependency directories"
else
  bad "credential scan excludes generated dependency directories"
fi

if (cd "$TMP" && bash "$ROOT/scripts/audit-receipts.sh" foo "$TMP/.devflow" "$TMP/docs" >/dev/null); then
  ok "receipt audit accepts matching internal and document mirrors"
else
  bad "receipt audit accepts matching internal and document mirrors"
fi

printf '\n' >> "$TMP/docs/foo/gates/P5/receipt.txt"
if (cd "$TMP" && bash "$ROOT/scripts/audit-receipts.sh" foo "$TMP/.devflow" "$TMP/docs" >/dev/null); then
  bad "receipt audit rejects mirror content drift"
else
  ok "receipt audit rejects mirror content drift"
fi

cp "$TMP/.devflow/foo/gates/P5/receipt.txt" "$TMP/docs/foo/gates/P5/receipt.txt"
sed "s/@${SKILL_VER}/@3.9.6/" "$TMP/.devflow/foo/gates/P6-credential/receipt.txt" > "$TMP/old-version.receipt"
mv "$TMP/old-version.receipt" "$TMP/.devflow/foo/gates/P6-credential/receipt.txt"
cp "$TMP/.devflow/foo/gates/P6-credential/receipt.txt" "$TMP/docs/foo/gates/P6-credential/receipt.txt"
if (cd "$TMP" && bash "$ROOT/scripts/audit-receipts.sh" foo "$TMP/.devflow" "$TMP/docs" >/dev/null); then
  bad "receipt audit rejects mixed gate versions"
else
  ok "receipt audit rejects mixed gate versions"
fi

if bash "$ROOT/scripts/preflight-port.sh" 0 >/dev/null 2>&1; then
  bad "port preflight rejects invalid ports"
else
  ok "port preflight rejects invalid ports"
fi

REPAIR="$TMP/state-repair"
WORKSPACE="$REPAIR" bash "$ROOT/scripts/devflow-state.sh" init legacy-partial --frontend=not-applicable >/dev/null
jq '.phases.P6.status="completed" | .phases.P6a={"status":"in_progress"} | .phases.P6b={"status":"pending"} | .current_phase="P6"' \
  "$REPAIR/.devflow/legacy-partial.state.json" > "$REPAIR/state.tmp" && mv "$REPAIR/state.tmp" "$REPAIR/.devflow/legacy-partial.state.json"
if WORKSPACE="$REPAIR" bash "$ROOT/scripts/devflow-state.sh" repair legacy-partial >/dev/null && \
   jq -e '.phases.P6.status == "in_progress" and (.phases.P6a | not) and (.phases.P6b | not)' \
   "$REPAIR/.devflow/legacy-partial.state.json" >/dev/null; then
  ok "repair re-evaluates an existing completed P6 with partial P6a-f residue"
else
  bad "repair re-evaluates an existing completed P6 with partial P6a-f residue"
fi

REPAIR_VALID="$TMP/state-repair-valid"
WORKSPACE="$REPAIR_VALID" bash "$ROOT/scripts/devflow-state.sh" init legacy-valid --frontend=not-applicable >/dev/null
jq '.phases.P6.status="completed" | .phases.P6a={"status":"in_progress"} | .current_phase="P6"' \
  "$REPAIR_VALID/.devflow/legacy-valid.state.json" > "$REPAIR_VALID/state.tmp" && mv "$REPAIR_VALID/state.tmp" "$REPAIR_VALID/.devflow/legacy-valid.state.json"
mkdir -p "$REPAIR_VALID/.devflow/legacy-valid/gates/P6"
printf 'EXIT_CODE=0\nVERSION=p6@'"${SKILL_VER}"'\nPHASE=P6\nPASS=1 FAIL=0 WARN=0\n' > "$REPAIR_VALID/.devflow/legacy-valid/gates/P6/receipt.txt"
if WORKSPACE="$REPAIR_VALID" bash "$ROOT/scripts/devflow-state.sh" repair legacy-valid >/dev/null && \
   jq -e '.phases.P6.status == "completed" and (.phases.P6a | not)' \
   "$REPAIR_VALID/.devflow/legacy-valid.state.json" >/dev/null; then
  ok "repair preserves completed P6 when its current receipt is valid"
else
  bad "repair preserves completed P6 when its current receipt is valid"
fi


# v3.15.14（第 13 轮审查 P2-1/P2-2）: 生成器假成功负回归——python3 失败时
# schema-changelog / er-index 必须 exit 1（第一段 -s 守卫 + 第二段 rc 终验，
# 纯 [ -f ] 遇 mktemp 预创建/陈旧产物恒放行 → 假绿）
GEN="$TMP/gen-fail"; mkdir -p "$GEN/docs" "$GEN/fakebin"
printf '#!/bin/sh\nexit 127\n' > "$GEN/fakebin/python3"; chmod +x "$GEN/fakebin/python3"
printf 'stale artifact\n' > "$GEN/docs/stale-schema.md"
GSOUT=$(cd "$GEN" && PATH="$GEN/fakebin:$PATH" DOC_DIR="$GEN/docs" OUTPUT_FILE="$GEN/docs/stale-schema.md" bash "$ROOT/scripts/generate-schema-changelog.sh" 2>&1); GSRC=$?
if [ "$GSRC" -ne 0 ]; then
  ok "schema-changelog fails loud when python3 dead (rc=$GSRC)"; else bad "schema-changelog fails loud when python3 dead (${GSOUT:-rc=$GSRC})"; fi
printf 'stale artifact\n' > "$GEN/docs/stale-er.md"
GEOUT=$(cd "$GEN" && PATH="$GEN/fakebin:$PATH" OUTPUT_FILE="$GEN/docs/stale-er.md" bash "$ROOT/scripts/generate-er-index.sh" 2>&1); GERC=$?
if [ "$GERC" -ne 0 ]; then
  ok "er-index fails loud when python3 dead (rc=$GERC)"; else bad "er-index fails loud when python3 dead (${GEOUT:-rc=$GERC})"; fi


# v3.15.15（第 14 轮审查 P1 根因收口）: 生成器正向 happy-path 回归——封掉
# "只测守卫不测功能"的系统性盲区（er-index L367 SyntaxError 曾致正向 100%
# 失败却无人发现，负回归被歪打正着满足）
GH="$TMP/gen-happy"; mkdir -p "$GH/backend/svc-a/src/main/resources/db/migration/h2" "$GH/docs/detailed-design"
printf 'CREATE TABLE foo (id BIGINT PRIMARY KEY);\n' > "$GH/backend/svc-a/src/main/resources/db/migration/h2/V1.0.0__init.sql"
HE=$(cd "$GH" && bash "$ROOT/scripts/generate-er-index.sh" 2>&1); HERC=$?
if [ "$HERC" -eq 0 ] && [ -s "$GH/docs/detailed-design/_ER图索引.md" ]; then
  ok "er-index happy path generates non-empty artifact"; else bad "er-index happy path (${HE:-rc=$HERC})"; fi
HS=$(cd "$GH" && bash "$ROOT/scripts/generate-schema-changelog.sh" 2>&1); HSRC=$?
if [ "$HSRC" -eq 0 ] && [ -s "$GH/docs/detailed-design/_Schema变更日志.md" ]; then
  ok "schema-changelog happy path generates non-empty artifact"; else bad "schema-changelog happy path (${HS:-rc=$HSRC})"; fi
for g in generate-master-index generate-interface-index generate-permission-matrix generate-postmortem-index generate-table-index; do
  HG=$(cd "$GH" && bash "$ROOT/scripts/$g.sh" 2>&1); HGRC=$?
  if [ "$HGRC" -eq 0 ]; then
    ok "$g happy path exits 0"; else bad "$g happy path (${HG:-rc=$HGRC})"; fi
done


# v3.15.19（第 16 轮 P3 收口）: 四生成器显式终验负回归——python3 死亡时
# rc=1（显式 GEN_RC 终验；旧隐式传播为 127，末尾追加命令即静默破坏）
GFB="$TMP/gen-fb4"; mkdir -p "$GFB/backend/svc-a/src/main/resources/db/migration/h2" "$GFB/fb4" "$GFB/docs/detailed-design"
printf 'CREATE TABLE foo (id BIGINT PRIMARY KEY);\n' > "$GFB/backend/svc-a/src/main/resources/db/migration/h2/V1.0.0__init.sql"
# v3.15.21（第 18 轮 P3-1）: 陈旧产物维度——GEN_RC 终验被移除时非空检查不再
# 歪打正着提供 rc=1 假区分度（变异实证：删 GEN_RC 块 + 无陈旧产物 → 测试仍 PASS）
printf 'stale\n' > "$GFB/MASTER.md"
printf 'stale\n' > "$GFB/docs/detailed-design/INDEX-接口-auto.md"
printf 'stale\n' > "$GFB/docs/detailed-design/_权限矩阵.md"
printf 'stale\n' > "$GFB/docs/detailed-design/INDEX-表-auto.md"
printf '#!/bin/sh\nexit 127\n' > "$GFB/fb4/python3"; chmod +x "$GFB/fb4/python3"
for g in generate-master-index generate-interface-index generate-permission-matrix generate-table-index; do
  G4RC=$(cd "$GFB" && PATH="$GFB/fb4:/usr/bin:/bin" bash "$ROOT/scripts/$g.sh" >/dev/null 2>&1; echo $?)
  if [ "$G4RC" -eq 1 ]; then
    ok "$g python3 dead → explicit rc=1"; else bad "$g python3 dead rc=${G4RC}（非显式终验 1）"; fi
done

# v3.15.22（第 19 轮 P3-1/P3-2）: check 家族显式终验负回归——死 python3 必须
# rc=1 且报"环境故障"（rc=1 业务判定透传不误报，见 v3.15.22 语义区分）
CKF="$TMP/chk-fb"; mkdir -p "$CKF" "$CKF/fbc" "$CKF/frontend/src" "$CKF/backend/svc/src/main/java/com/x"
for t in bash sh grep find sort head wc awk; do ln -s "$(command -v "$t")" "$CKF/fbc/$t" 2>/dev/null || true; done
printf '#!/bin/sh
exit 127
' > "$CKF/fbc/python3"; chmod +x "$CKF/fbc/python3"
printf '<template><div>x</div></template>
' > "$CKF/frontend/src/Foo.vue"
# v3.15.23（第 20 轮 P3-3）: 夹具补 backend/——4/6 脚本（code-standards/entity-db/
# n+1/scorecard）曾走"目录不存在"早退，从未到达 python 段（M5 变异删 CHK_RC 后
# 测试仍全绿的夹具缺口）
printf 'public class Foo { private Long id; }
' > "$CKF/backend/svc/src/main/java/com/x/Foo.java"
# v3.15.24（第 21 轮 P3-A）: 夹具补 _权限矩阵.md——permission-consistency 曾走
# "文档不存在"早退 exit 2，CHK_RC 断言被 doc-missing 路径空洞满足（M1 变异删
# 整个透传块后测试仍 36/36 全绿的夹具缺口）
mkdir -p "$CKF/docs/detailed-design"
printf '| 权限码 | 用途 |
|---|---|
| order:view:list | 列表 |
' > "$CKF/docs/detailed-design/_权限矩阵.md"
for c in check-code-standards check-entity-db-consistency check-frontend-standards check-permission-consistency detect-n-plus-one super-scorecard; do
  cdir="$ROOT/checks"; [ "$c" = "super-scorecard" ] && cdir="$ROOT/scripts"
  CHK=$(cd "$CKF" && PATH="$CKF/fbc:/usr/bin:/bin" bash "$cdir/$c.sh" 2>&1); CHKRC=$?
  if [ "$CHKRC" -eq 1 ] || [ "$CHKRC" -eq 2 ]; then
    ok "$c python3 dead → fail-closed (rc=$CHKRC)"; else bad "$c python3 dead rc=${CHKRC}（假成功）：${CHK:-无输出}"; fi
done
# 环境故障消息断言（frontend-standards 有 frontend 目录时走到 python 段）
FC=$(cd "$CKF" && PATH="$CKF/fbc:/usr/bin:/bin" bash "$ROOT/checks/check-frontend-standards.sh" 2>&1); FCRC=$?
if printf '%s' "$FC" | grep -q '环境故障'; then
  ok "check family reports env-failure (not business-fail) on interpreter death"; else bad "check family env/business failure message conflated (${FC:-rc=$FCRC})"; fi

# v3.15.23（第 20 轮 P3-4）: 业务侧语义断言——fake python3 exit 1（sys.exit(1) 业务
# 判定模拟）必须静默透传 rc=1 且不误报"环境故障"（M3a 变异删透传分支曾无测试捕获）
printf '#!/bin/sh
exit 1
' > "$CKF/fbc/python3"; chmod +x "$CKF/fbc/python3"
for c in check-code-standards check-entity-db-consistency check-frontend-standards check-permission-consistency detect-n-plus-one super-scorecard; do
  cdir="$ROOT/checks"; [ "$c" = "super-scorecard" ] && cdir="$ROOT/scripts"
  FB=$(cd "$CKF" && PATH="$CKF/fbc:/usr/bin:/bin" bash "$cdir/$c.sh" 2>&1); FBRC=$?
  if [ "$FBRC" -ne 0 ] && ! printf '%s' "$FB" | grep -q '环境故障'; then
    ok "$c business-fail (python exit 1) passes through silently"; else bad "$c business-fail conflated with env-failure (rc=${FBRC})"; fi
done

# v3.15.20（第 17 轮 P3）: permission-matrix --section-only 不写产物（§2 输出到
# stdout）——非空终验不得误杀（v3.15.19 引入回归：豁免条件漏 SECTION_ONLY）
SSO=$(cd "$GFB" && bash "$ROOT/scripts/generate-permission-matrix.sh" --section-only >/dev/null 2>&1; echo $?)
if [ "$SSO" -eq 0 ]; then
  ok "permission-matrix --section-only 无产物场景 rc=0（终验不误杀）"
else
  bad "permission-matrix --section-only 被 --section-only 终验误杀（rc=${SSO}）"
fi

finish REPORT_REGRESSIONS
