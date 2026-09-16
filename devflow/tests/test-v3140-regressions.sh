#!/usr/bin/env bash
# test-v3140-regressions.sh · v3.14.0 特性常驻回归
# 覆盖：DF/AW 深度评审阈值、reconcile 强收据校验、default 回退拒绝、
#       P8 告警一致性交叉核对、monitor 监听模式、client-adapter 生命周期拆分
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"
SKILL_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
# v3.15.2: 夹具收据须含 SKILL_TREE（== init 冻结树）
TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh")

echo "=== devflow v3.14.x regressions ==="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mk_receipt() { # dir phase ver [evidence-file]
  mkdir -p "$1" "docs-mirror/$(basename "$(dirname "$1")")"
  local ev=""
  [ -n "$4" ] && ev=$'\n'"EVIDENCE_PATH=$4"$'\n'"EVIDENCE_SHA256=$(shasum -a 256 "$4" | awk '{print $1}')"
  printf 'EXIT_CODE=0\nVERSION=%s\nPHASE=%s%s\nPASS=2 FAIL=0 WARN=0\n' "$3" "$2" "$ev" > "$1/receipt.txt"
  cp "$1/receipt.txt" "docs-mirror/$(basename "$(dirname "$1")")/receipt.txt"
}

# ---------- R1: reconcile 拒绝旧版本/无版本收据 ----------
WORKSPACE="$TMP/r1" bash "$ROOT/scripts/devflow-state.sh" init rr --frontend=not-applicable >/dev/null 2>&1
# v3.15.2: P0 写合法 Gate 收据（基线收据不再是证据），使 P0b 的旧版本成为唯一拦截点
mkdir -p "$TMP/r1/.devflow/rr/gates/P0"
printf "EXIT_CODE=0\nVERSION=p0@%s\nPHASE=P0\nSKILL_TREE=%s\n" "$SKILL_VER" "$TREE" > "$TMP/r1/.devflow/rr/gates/P0/receipt.txt"
mkdir -p "$TMP/r1/.devflow/rr/gates/P0b" "$TMP/r1/docs-mirror-bad/P0b"
printf 'EXIT_CODE=0\nVERSION=artifact@3.9.6\nPHASE=P0b\n' > "$TMP/r1/.devflow/rr/gates/P0b/receipt.txt"
cp "$TMP/r1/.devflow/rr/gates/P0b/receipt.txt" "$TMP/r1/docs-mirror-bad/P0b/"
if WORKSPACE="$TMP/r1" bash "$ROOT/scripts/devflow-state.sh" reconcile rr --apply >/dev/null 2>&1 && \
   [ "$(jq -r '.phases.P0b.status' "$TMP/r1/.devflow/rr.state.json")" != "completed" ]; then
  ok "reconcile 拒绝旧版本收据（P0b 未被推进）"
else
  bad "reconcile 拒绝旧版本收据"
fi

# ---------- R2: reconcile 拒绝 PHASE 不匹配的 P7 收据 ----------
WORKSPACE="$TMP/r2" bash "$ROOT/scripts/devflow-state.sh" init r7 --frontend=not-applicable >/dev/null 2>&1
mkdir -p "$TMP/r2/.devflow/r7/gates/P7"
printf 'deploy\n' > "$TMP/r2/evidence-p7.txt"
EV_SHA=$(shasum -a 256 "$TMP/r2/evidence-p7.txt" | awk '{print $1}')
printf "EXIT_CODE=0\nVERSION=g@${SKILL_VER}\nPHASE=P6\nEVIDENCE_PATH=evidence-p7.txt\nEVIDENCE_SHA256=%s\n" "$EV_SHA" > "$TMP/r2/.devflow/r7/gates/P7/receipt.txt"
jq '.phases |= map_values(.status = "completed") | .current_phase = "P7" | .phases.P7.status = "in_progress"' \
  "$TMP/r2/.devflow/r7.state.json" > "$TMP/r2/s.tmp" && mv "$TMP/r2/s.tmp" "$TMP/r2/.devflow/r7.state.json"
if WORKSPACE="$TMP/r2" bash "$ROOT/scripts/devflow-state.sh" complete r7 P7 >/dev/null 2>&1; then
  bad "complete 拒绝 PHASE 不匹配的 P7 收据"
else
  ok "complete 拒绝 PHASE 不匹配的 P7 收据"
fi

# ---------- R3: 无 state 时 s gate 拒绝运行且不产生 default 目录 ----------
T3="$TMP/nostate"; mkdir -p "$T3/docs/detailed-design"
for f in _commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md; do
  printf '# %s\nl1\nl2\nl3\nl4\nl5\nl6\n' "$f" > "$T3/docs/detailed-design/$f"
done
if (cd "$T3" && bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design >/dev/null 2>&1); then
  bad "无 state 时 s1 应拒绝"
elif [ -d "$T3/.devflow/default" ]; then
  bad "无 state 时不得产生 default 目录"
else
  ok "无 state 时 s1 fail-closed 且无 default 目录"
fi

# ---------- R4: p2a DF 五字段契约生效（v3.24.0/A15 重写：旧"9<10 阈值"已随按实际发现口径移除） ----------
W4="$TMP/p2a"; mkdir -p "$W4/docs/detailed-design" "$W4/docs/requirements" "$W4/docs/review"
WORKSPACE="$W4" bash "$ROOT/scripts/devflow-state.sh" init p2a --frontend=mini-program >/dev/null 2>&1
printf '# d\n| M-01-F01-A01 | COMPLETE |\n' > "$W4/docs/detailed-design/p2a-design.md"
printf '# c\n| M-01-F01-A01 | 待验证 |\n' > "$W4/docs/requirements/p2a-acceptance-criteria.md"
# 外部依赖信号：触发外部数据剧本（同时使领域清单成为强制项）
echo "本功能需与 CRM 系统对接获取客户数据。" >> "$W4/docs/detailed-design/p2a-design.md"
{ echo "# 报告"
  for r in 架构师 后端专家 前端专家 测试开发 DBA; do echo "- 归属评委：$r"; done
  for i in $(seq 1 9); do echo "#### DF-$i 深层发现"; done   # 故意只有标题、五字段全缺
  for i in 1 2 3; do echo "- AW-$i 场景：x｜走查路径：y｜结果：z"; done
} > "$W4/docs/review/p2a-design-review-report.md"
R4_OUT=$(cd "$W4" && bash "$ROOT/scripts/p2a_design_review_gate.sh" p2a 2>&1 || true)
if printf '%s' "$R4_OUT" | grep -q "incomplete DF blocks"; then
  ok "p2a 五字段缺失 DF 被判无效（incomplete DF blocks）"
else
  bad "p2a 空 DF 块未被五字段契约拦截"
fi
if printf '%s' "$R4_OUT" | grep -qE "AW entries with empty segments or unresolvable"; then
  ok "p2a AW 三段/引用解析契约生效（结果无锚点/DF 引用被拒）"
else
  bad "p2a AW 结果引用未校验"
fi

# ---------- R5: artifact_gate P8 告警输出含 FAIL 时交叉拦截 ----------
W5="$TMP/p8"; mkdir -p "$W5/docs/deploy" "$W5/artifacts"
printf 'artifact\n' > "$W5/artifacts/a.bin"
AS=$(shasum -a 256 "$W5/artifacts/a.bin" | awk '{print $1}')
printf 'release out\n' > "$W5/release.out"
printf 'DEPLOYMENT_ID=d1\nARTIFACT_PATH=artifacts/a.bin\nARTIFACT_SHA256=%s\nENVIRONMENT=staging\nHEALTH_HTTP_STATUS=200\nRELEASE_EVIDENCE_PATH=release.out\n' "$AS" > "$W5/docs/deploy/p8-deploy-record.md"
cat > "$W5/docs/deploy/p8-monitor-config.md" <<'EOF'
METRICS_ENDPOINT=http://127.0.0.1:1/metrics
LOG_QUERY=q
ALERT_RULE=r1
ALERT_TESTED=PASS
ALERT_TEST_OUTPUT=alert-out.txt
EOF
printf 'alert rule check: FAIL\n' > "$W5/alert-out.txt"
if (cd "$W5" && bash "$ROOT/scripts/artifact_gate.sh" P8 p8 >/dev/null 2>&1); then
  bad "P8 交叉核对：ALERT_TESTED=PASS 但输出含 FAIL 应阻断"
else
  ok "P8 交叉核对拦截文档与实测矛盾"
fi

# ---------- R6: monitor 监听模式语义 ----------
W6="$TMP/mon"; mkdir -p "$W6"
MON_PORT_FILE="$W6/listening-port"
# 由内核分配端口 0，并等待子进程明确写入就绪端口；旧夹具用 $RANDOM + sleep 1，
# 端口碰撞/启动失败会让“启动前应 FAIL”和“owner 匹配应 PASS”同时误红。
python3 - "$MON_PORT_FILE" <<'PY' >/dev/null 2>&1 & MPID=$!
import http.server, socketserver, sys
port_file = sys.argv[1]
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
open(port_file, "w").write(str(server.server_address[1]))
server.serve_forever()
PY
for _ in $(seq 1 50); do [ -s "$MON_PORT_FILE" ] && break; sleep 0.1; done
MON_PORT=$(cat "$MON_PORT_FILE" 2>/dev/null || true)
if ! printf '%s' "$MON_PORT" | grep -qE '^[0-9]+$'; then
  bad "监控端口夹具未就绪（未取得内核分配端口）"
  kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null
  
# ---------- R23: "用户确认: 未确认" 必须阻断（LC_ALL=C 多字节正则缺陷回归钉） ----------
W23="$TMP/r23"; export WORKSPACE="$W23"
mkdir -p "$W23/docs/detailed-design" "$W23/docs/requirements"
bash "$ROOT/scripts/devflow-state.sh" init r23 --frontend=not-applicable >/dev/null 2>&1
for f in _commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md; do
  printf '# %s\n1\n2\n3\n4\n5\n' "$f" > "$W23/docs/detailed-design/$f"
done
cat > "$W23/docs/requirements/r23-technology-constraints.md" <<'EOF'
# r23 技术约束
<!-- DEVFLOW:CONSTRAINTS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->
EOF
cat > "$W23/docs/detailed-design/r23-tech-selection.md" <<'EOF'
# r23 技术选型
## 决策矩阵
| 维度 | A | B |
|---|---|---|
| 成本 | 4 | 4 |
## 决策结论
用户确认: 未确认
## 硬约束绑定
<!-- DEVFLOW:CONSTRAINT-BINDINGS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->
EOF
R23_OUT=$(cd "$W23" && bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design 2>&1 || true)
if printf '%s' "$R23_OUT" | grep -q "explicit user confirmation\|negative user confirmation"; then
  ok "P1 '用户确认: 未确认' 被阻断（正则缺陷已修）"
else
  bad "P1 '用户确认: 未确认' 未被阻断"
fi

# ---------- R24: DRAFT 状态 MUST_USE 必须阻断而非跳过 ----------
W24="$TMP/r24"; export WORKSPACE="$W24"
mkdir -p "$W24/docs/detailed-design" "$W24/docs/requirements"
bash "$ROOT/scripts/devflow-state.sh" init r24 --frontend=not-applicable >/dev/null 2>&1
for f in _commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md; do
  printf '# %s\n1\n2\n3\n4\n5\n' "$f" > "$W24/docs/detailed-design/$f"
done
cat > "$W24/docs/requirements/r24-technology-constraints.md" <<'EOF'
# r24 技术约束
<!-- DEVFLOW:CONSTRAINTS
constraint_id=TC-TECH-001
type=MUST_USE
subject=workflow-engine
required_product=camunda
status=DRAFT
confirmed=false
DEVFLOW:END -->
EOF
cat > "$W24/docs/detailed-design/r24-tech-selection.md" <<'EOF'
# r24 技术选型
## 决策矩阵
| 维度 | A | B |
|---|---|---|
| 成本 | 4 | 4 |
## 决策结论
用户确认: YES
EOF
R24_OUT=$(cd "$W24" && bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design 2>&1 || true)
if printf '%s' "$R24_OUT" | grep -q "status must be FROZEN.*DRAFT\|DRAFT constraints block"; then
  ok "P1 DRAFT MUST_USE 被阻断（不再静默跳过）"
else
  bad "P1 DRAFT MUST_USE 未被阻断"
fi

# ---------- R25: 合规 MUST_NOT_USE（selected 不含禁用产品）必须放行 ----------
W25="$TMP/r25"; export WORKSPACE="$W25"
mkdir -p "$W25/docs/detailed-design" "$W25/docs/requirements"
bash "$ROOT/scripts/devflow-state.sh" init r25 --frontend=not-applicable >/dev/null 2>&1
for f in _commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md; do
  printf '# %s\n1\n2\n3\n4\n5\n' "$f" > "$W25/docs/detailed-design/$f"
done
cat > "$W25/docs/requirements/r25-technology-constraints.md" <<'EOF'
# r25 技术约束
<!-- DEVFLOW:CONSTRAINTS
constraint_id=TC-TECH-002
type=MUST_NOT_USE
subject=workflow-engine
required_product=FlowCore
status=FROZEN
confirmed=true
DEVFLOW:END -->
EOF
cat > "$W25/docs/detailed-design/r25-tech-selection.md" <<'EOF'
# r25 技术选型
## 决策矩阵
| 维度 | Camunda | FlowCore |
|---|---|---|
| 风险 | 4 | 2 |
## 决策结论
用户确认: YES
## 硬约束绑定
<!-- DEVFLOW:CONSTRAINT-BINDINGS
constraint_id=TC-TECH-002
selected_product=camunda
compliance=PASS
evidence=backend/pom.xml
DEVFLOW:END -->
EOF
(cd "$W25" && bash "$ROOT/scripts/devflow-state.sh" constraints-freeze r25 >/dev/null 2>&1)
if (cd "$W25" && bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design >/dev/null 2>&1); then
  ok "P1 合规 MUST_NOT_USE（selected=camunda）放行——'未引入X'类自然语言不再参与判定"
else
  bad "P1 合规 MUST_NOT_USE 被误拒"
fi

finish EVIDENCE_V3140
fi
if bash "$ROOT/scripts/preflight-port.sh" "$MON_PORT" >/dev/null 2>&1; then
  bad "启动前模式对监听端口应 FAIL"
else
  ok "启动前模式对监听端口 FAIL"
fi
# macOS Framework Python 的 ps command 可执行名是 `Python`（不是 shell 启动名
# `python3`）；owner 断言应匹配真实进程命令行，而不是调用别名。
MON_OWNER_OUT=$(bash "$ROOT/scripts/preflight-port.sh" --expect-listening "$MON_PORT" Python 2>&1)
if [ "$?" -eq 0 ]; then
  ok "监控模式对运行中服务 PASS（owner 匹配）"
else
  bad "监控模式 owner 匹配失败: ${MON_OWNER_OUT}"
fi
kill $MPID 2>/dev/null; wait $MPID 2>/dev/null
if bash "$ROOT/scripts/preflight-port.sh" --expect-listening "$MON_PORT" >/dev/null 2>&1; then
  bad "监控模式对已停服务应 FAIL"
else
  ok "监控模式对已停服务 FAIL"
fi

# ---------- R7: client-adapter validate/hash 不要求 P7 制品；release 要求 ----------
W7="$TMP/ca"; mkdir -p "$W7/miniprogram/pages/home"
printf '{"pages":["pages/home/index"]}\n' > "$W7/miniprogram/app.json"
printf '{"platform":"mini-program","commands":{"build":["./c.sh"],"test":["./c.sh"],"release":["./c.sh"]},"pages":["pages/home/index"],"release_evidence":""}\n' > "$W7/miniprogram/devflow-client.json"
printf '<view/>\n' > "$W7/miniprogram/pages/home/index.wxml"
CA="$ROOT/scripts/client-adapter.sh"
if (cd "$W7" && bash "$CA" validate mini-program miniprogram >/dev/null 2>&1) && \
   (cd "$W7" && bash "$CA" hash mini-program miniprogram >/dev/null 2>&1); then
  ok "validate/hash 不要求 P7 制品（生命周期拆分）"
else
  bad "validate/hash 仍要求 P7 制品（死锁回归）"
fi
if (cd "$W7" && bash "$CA" release mini-program miniprogram >/dev/null 2>&1); then
  bad "release 缺 release_evidence 应 FAIL"
else
  ok "release 缺制品被拦截"
fi

# ---------- R8: 领域专项清单强制（缺失给出明确拦截提示；生成并全答后该项消失） ----------
# v3.22.0: 生成器默认输出中文名 docs/评审/p2a-设计领域清单.md（英文历史名作为回退）
DC="$W4/docs/评审/p2a-设计领域清单.md"
P2A_OUT=$(cd "$W4" && bash "$ROOT/scripts/p2a_design_review_gate.sh" p2a 2>&1)
if echo "$P2A_OUT" | grep -q "领域专项评审清单缺失"; then
  ok "p2a 缺领域清单时拦截并提示生成命令"
else
  bad "p2a 缺领域清单未拦截"
fi

# v3.14.3: 勾选必须附证据——无证据的一键全勾会被 gate 拒绝（负向断言）
(cd "$W4" && bash "$ROOT/scripts/gen-domain-checklist.sh" p2a --stage design >/dev/null 2>&1)
sed -i.bak 's/^- \[ \]/- [x]/' "$DC"; rm -f "$DC.bak"
P2A_NEG_OUT=$(cd "$W4" && bash "$ROOT/scripts/p2a_design_review_gate.sh" p2a 2>&1)
if echo "$P2A_NEG_OUT" | grep -q "领域专项清单有.*缺证据"; then
  ok "无证据一键全勾被 gate 拒绝（附证据要求生效）"
else
  bad "无证据一键全勾未被拒绝——领域清单可被形式化走过场"
fi

# 正向：逐项追加（证据：…）后，该 P0 消失且出现 fully answered with evidence
python3 - "$DC" <<'PY'
import sys, hashlib
path = sys.argv[1]
out = []
n = 0
for l in open(path, encoding="utf-8"):
    l = l.rstrip("\n"); n += 1
    if l.startswith("- [x]") and "（证据：" not in l:
        h = hashlib.sha256((l + str(n)).encode()).hexdigest()[:8]
        l += f"（证据：评审记录 #{h} §对应章节）"
    out.append(l)
open(path, "w", encoding="utf-8").write("\n".join(out))
PY
P2A_POS_OUT=$(cd "$W4" && bash "$ROOT/scripts/p2a_design_review_gate.sh" p2a 2>&1)
if printf '%s' "$P2A_POS_OUT" | grep -q "fully answered with evidence"; then
  ok "附证据后清单通过（fully answered with evidence）"
else
  bad "附证据后清单未通过"
fi

# ---------- R9/R10: p5 实质化负向断言 ----------
W9="$TMP/p5neg"; mkdir -p "$W9/docs/test-cases" "$W9/docs/requirements"
printf '# c\n| M-01-F01-A01 | 待验证 |\n| M-01-F01-A02 | 待验证 |\n' > "$W9/docs/requirements/p5neg-acceptance-criteria.md"
# R9: 占位/雷同行（A|B|C|D 型）应被拒
cat > "$W9/docs/test-cases/p5neg-test-cases.md" <<'EOF'
| 用例ID | 验收点 | 预置条件 | 步骤 | 预期结果 |
|---|---|---|---|---|
| TC-1 | A | B | C | D |
EOF
if (cd "$W9" && bash "$ROOT/scripts/p5_test_cases_gate.sh" p5neg docs/test-cases/p5neg-test-cases.md >/dev/null 2>&1); then
  bad "p5 占位雷同数据不应通过"
else
  ok "p5 拒绝占位/雷同用例数据"
fi
# R10: 验收点未全覆盖（只写 A01）应被拒
cat > "$W9/docs/test-cases/p5neg2-test-cases.md" <<'EOF'
| 用例ID | 验收点 | 预置条件 | 步骤 | 预期结果 |
|---|---|---|---|---|
| TC-101 | M-01-F01-A01 | 已登录 | 正常提交查询 | 返回分页数据 |
| TC-102 | M-01-F01-A01 | 已登录 | 提交空关键字 | 返回空列表（边界） |
EOF
NEG_OUT=$(cd "$W9" && bash "$ROOT/scripts/p5_test_cases_gate.sh" p5neg docs/test-cases/p5neg2-test-cases.md 2>&1)
if echo "$NEG_OUT" | grep -q "未被用例覆盖"; then
  ok "p5 验收点未覆盖被检出"
else
  bad "p5 未检出验收点覆盖缺口"
fi

# ---------- R11: s8b patch 内容判定——BSD grep ^\+\+\+ 陷阱回归 ----------
P11_PATCH="$TMP/r11.patch"
printf 'diff --git a/templates/T.md b/templates/T.md\n--- a/templates/T.md\n+++ b/templates/T.md\n@@ -1 +1,2 @@\n 原内容\n+新增行\n' > "$P11_PATCH"
R11_CNT=$(awk '
  /^<!--/ {next}
  /^#/ {next}
  /^---([[:space:]]|$)/ {next}
  /^[+][+][+]/{next}
  /^@@/{next}
  /^## /{next}
  NF>0 {c++}
  END{print c+0}' "$P11_PATCH")
if [ "${R11_CNT:-0}" -ge 1 ] && ! grep -qF 'grep -v "^\+\+\+"' "$ROOT/maintenance/s8b_feedback_gate.sh"; then
  ok "s8b patch 内容判定兼容 BSD grep（真实 diff 计数=${R11_CNT}）"
else
  bad "s8b patch 判定回归（BSD grep 陷阱复发或计数错误）"
fi

# ---------- R12: complete 全阶段收据契约（旧版本/错 PHASE 拒绝） ----------
W12="$TMP/r12"; mkdir -p "$W12/docs/requirements"
WORKSPACE="$W12" bash "$ROOT/scripts/devflow-state.sh" init r12 --frontend=not-applicable >/dev/null 2>&1
printf '| M-01-F01-A01 | 待验证 |\n' > "$W12/docs/requirements/r12-acceptance-criteria.md"
mkdir -p "$W12/.devflow/r12/gates/P1"
printf 'EXIT_CODE=0\nVERSION=p1@3.9.9\nPHASE=WRONG\n' > "$W12/.devflow/r12/gates/P1/receipt.txt"
if WORKSPACE="$W12" bash "$ROOT/scripts/devflow-state.sh" complete r12 P1 >/dev/null 2>&1; then
  bad "complete 接受旧版本+错 PHASE 收据"
else
  ok "complete 拒绝旧版本/错 PHASE 收据（全阶段契约）"
fi

# ---------- R13: 收据戳动态派生——scripts 内禁止硬编码 @x.y.z 字面量 ----------
LIT_STAMPS=$(grep -rhoE '@[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/scripts" 2>/dev/null | grep -v "@${SKILL_VER}$" | sort -u || true)
if [ -z "$LIT_STAMPS" ]; then
  ok "scripts 内无硬编码版本戳（全部经 gate-version.sh 动态派生）"
else
  bad "发现硬编码版本戳: $(echo $LIT_STAMPS | tr '\n' ' ')"
fi

# ---------- R14: p5 零 M-ID 路径——多字节吞噬崩溃回归（v3.14.7 虚假声明修正） ----------
W14="$TMP/r14"; mkdir -p "$W14/docs/test-cases" "$W14/docs/requirements"
printf '# c\n无 M-ID 内容\n' > "$W14/docs/requirements/r14-acceptance-criteria.md"
cat > "$W14/docs/test-cases/r14-test-cases.md" <<'EOF'
| 用例ID | 验收点 | 预置条件 | 步骤 | 预期结果 |
|---|---|---|---|---|
| TC-201 | M-01-F01-A01 | 已登录 | 提交查询条件 | 返回分页结果且状态 PASS |
| TC-202 | M-01-F01-A01 | 已登录 | 提交空关键字 | 返回空列表（边界） |
EOF
NEG_OUT=$(cd "$W14" && STATE_DIR="$W14/.devflow" bash "$ROOT/scripts/p5_test_cases_gate.sh" r14 docs/test-cases/r14-test-cases.md 2>&1)
if echo "$NEG_OUT" | grep -q "M-ID"; then
  ok "p5 零 M-ID 路径给出明确 P0 且不崩溃"
else
  bad "p5 零 M-ID 路径异常退出或无提示（多字节吞噬回归）"
fi
if ! (cd "$W14" && STATE_DIR="$W14/.devflow" bash "$ROOT/scripts/p5_test_cases_gate.sh" r14 docs/test-cases/r14-test-cases.md 2>&1) | grep -q "unbound variable"; then
  ok "p5 无 unbound variable 崩溃"
else
  bad "p5 unbound variable 崩溃复发"
fi

# 静态扫描：scripts 可执行行禁止未花括号 $var 紧邻多字节字符
# v3.15.23: 扫描扩域至 tests/ 与 commands/*.md 执行片段——第 20 轮实证测试代码
# 自身含同型缺陷（bad 行 $CHKRC+全角括号，回归检出时套件崩溃截断）
# v3.15.24（第 21 轮 P3-B）: perl 前置 fail-closed——无 perl 环境（slim/alpine CI）
# 时 find -exec perl 2>/dev/null 输出空、断言假 PASS（同型：管道退出码取自 sort）
command -v perl >/dev/null 2>&1 || { bad "perl 不可用——静态扫描 fail-closed（无法检测未花括号多字节缺陷）"; }
# v3.16.11（第 6 次自踩坑→扫描器升级）: 行级 ${ 豁免有盲区——同行其他未花括号变量
# 被 ${var} 的存在掩盖（s6_final L139 `$rp——` 与 `${_R_BYTES:-0}` 同行实测漏报→
# 运行时 unbound 崩溃）。升级：先删 ${...} 再查——豁免只作用于该变量本身
UNBRACED=$(find "$ROOT/scripts" "$ROOT/tests" -name '*.sh' ! -name '*.bak-*' -exec perl -ne 'next if /^\s*#/; my $l=$_; $l =~ s/\$\{[^}]*\}//g; print "$ARGV\n" if $l =~ /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/;' {} + 2>/dev/null | sort -u)
if [ -z "$UNBRACED" ]; then
  ok "静态扫描：scripts/tests 无未花括号 \$var+多字节"
else
  bad "未花括号残留: $UNBRACED"
fi
MD_UNBRACED=$(perl -ne 'next if /^\s*#/; my $l=$_; $l =~ s/\$\{[^}]*\}//g; print "$ARGV\n" if $l =~ /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/;' "$ROOT"/commands/*.md 2>/dev/null | sort -u)
if [ -z "$MD_UNBRACED" ]; then
  ok "静态扫描：commands/*.md 执行片段无未花括号 \$var+多字节"
else
  bad "commands md 未花括号残留: $MD_UNBRACED"
fi

# ---------- R15: P6-credential 绑定（缺失即拒）+ P7 链完整性（缺前置即拒） ----------
W15="$TMP/r15"; export WORKSPACE="$W15"
bash "$ROOT/scripts/devflow-state.sh" init r15 --frontend=not-applicable >/dev/null 2>&1
# P6 场景：有 P6 主收据、无 credential → 拒
jq '.current_phase="P6" | (.phases |= map_values(.status="completed")) | .phases.P6.status="in_progress"' "$W15/.devflow/r15.state.json" > "$W15/s.tmp" && mv "$W15/s.tmp" "$W15/.devflow/r15.state.json"
mkdir -p "$W15/.devflow/r15/gates/P6"
printf "EXIT_CODE=0\nVERSION=p6@${SKILL_VER}\nPHASE=P6\nPASS=1 FAIL=0 WARN=0\n" > "$W15/.devflow/r15/gates/P6/receipt.txt"
if bash "$ROOT/scripts/devflow-state.sh" complete r15 P6 >/dev/null 2>&1; then
  bad "P6 缺 P6-credential 仍被完成"
else
  ok "P6 缺 P6-credential 被拒绝"
fi
# P7 场景：P0-P6 链不完整 → 拒
jq '.current_phase="P7" | (.phases |= map_values(.status="completed")) | .phases.P7.status="in_progress"' "$W15/.devflow/r15.state.json" > "$W15/s.tmp" && mv "$W15/s.tmp" "$W15/.devflow/r15.state.json"
rm -f "$W15/.devflow/r15/gates/P6/receipt.txt"
mkdir -p "$W15/.devflow/r15/gates/P7"
printf "EXIT_CODE=0\nVERSION=artifact@${SKILL_VER}\nPHASE=P7\nPASS=1 FAIL=0 WARN=0\n" > "$W15/.devflow/r15/gates/P7/receipt.txt"
if bash "$ROOT/scripts/devflow-state.sh" complete r15 P7 >/dev/null 2>&1; then
  bad "P7 前置链不完整仍被完成"
else
  ok "P7 前置链不完整被拒绝"
fi

# ---------- R16: P7 实时健康探测强制（不可达即拒） ----------
W16="$TMP/r16"; export WORKSPACE="$W16"
bash "$ROOT/scripts/devflow-state.sh" init r16 --frontend=not-applicable >/dev/null 2>&1
mkdir -p "$W16/docs/deploy" "$W16/artifacts"
printf 'artifact\n' > "$W16/artifacts/a.bin"
printf 'deploy-run-001\nfinished_at=2026-08-26T12:00:00Z\nexit=0\n' > "$W16/release.out"
cat > "$W16/docs/deploy/r16-deploy-record.md" <<EOF
DEPLOYMENT_ID=d1
ARTIFACT_PATH=artifacts/a.bin
ARTIFACT_SHA256=$(shasum -a 256 "$W16/artifacts/a.bin" | awk '{print $1}')
ENVIRONMENT=staging
HEALTH_HTTP_STATUS=200
HEALTH_URL=http://127.0.0.1:1/health
RELEASE_EVIDENCE_PATH=release.out
EOF
NEG=$(cd "$W16" && bash "$ROOT/scripts/artifact_gate.sh" P7 r16 2>&1)
if echo "$NEG" | grep -q "live HEALTH_URL"; then
  ok "P7 健康地址不可达被阻断"
else
  bad "P7 健康地址不可达未阻断"
fi

# ---------- R17: audit-receipts state-scope 正向（completed+有效收据 → PASS） ----------
W17="$TMP/r17"; export WORKSPACE="$W17"
bash "$ROOT/scripts/devflow-state.sh" init r17 --frontend=not-applicable >/dev/null 2>&1
# v3.15.2: 基线收据不再能 complete P0——夹具写真实 Gate 收据
printf "EXIT_CODE=0\nVERSION=p0@%s\nPHASE=P0\nSKILL_TREE=%s\n" "$SKILL_VER" "$TREE" > "$W17/.devflow/r17/gates/P0/receipt.txt"
bash "$ROOT/scripts/devflow-state.sh" complete r17 P0 >/dev/null 2>&1
mkdir -p "$W17/docs/r17/gates/P0"
cp "$W17/.devflow/r17/gates/P0/receipt.txt" "$W17/docs/r17/gates/P0/receipt.txt"
AUDIT_OUT=$(cd "$W17" && bash "$ROOT/scripts/audit-receipts.sh" r17 .devflow docs 2>&1 || true)
if printf '%s' "$AUDIT_OUT" | grep -q "state-scope: P0=completed"; then
  ok "audit-receipts state-scope 正向（completed+收据存在 → PASS）"
else
  bad "audit-receipts state-scope 正向失败"
fi

# ---------- R18: p2b 空理由 skip 拒绝 ----------
W18="$TMP/r18"; export WORKSPACE="$W18"
bash "$ROOT/scripts/devflow-state.sh" init r18 --frontend=pc-web >/dev/null 2>&1
mkdir -p "$W18/docs/demo" "$W18/.devflow/r18"
printf 'x\n' > "$W18/docs/demo/r18-demo-signoff.md"
printf 'SKIP_P2b=|authorized-by=alice|at=2026-08-26|approval=ticket-1\n' > "$W18/.devflow/r18/skip-log.txt"
if (cd "$W18" && bash "$ROOT/scripts/p2b_demo_gate.sh" r18 >/dev/null 2>&1); then
  bad "p2b 空理由+有效三要素仍被跳过"
else
  ok "p2b 空理由 skip 被拒绝"
fi

# ---------- R19: v3.15.0 不可变树机制断言 ----------
# ① init 冻结 skill_tree_sha256 且 == 当前树
W19="$TMP/r19"; export WORKSPACE="$W19"
bash "$ROOT/scripts/devflow-state.sh" init r19 --frontend=not-applicable >/dev/null 2>&1
FROZEN=$(jq -r '.scope.skill_tree_sha256 // empty' "$W19/.devflow/r19.state.json")
CUR_TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh")
if [ -n "$FROZEN" ] && [ "$FROZEN" = "$CUR_TREE" ]; then
  ok "init 冻结 skill_tree_sha256 且等于当前树"
else
  bad "init 冻结树 hash 异常（frozen=${FROZEN:-空} cur=${CUR_TREE:-空}）"
fi
# ② P0 基线收据含 SKILL_TREE
if grep -q "^SKILL_TREE=" "$W19/.devflow/r19/gates/P0/receipt.txt"; then
  ok "P0 基线收据含 SKILL_TREE"
else
  bad "P0 基线收据缺 SKILL_TREE"
fi
# ③ 新版本在首次发布前尚无 immutable manifest 是合法状态：完整测试必须可先通过，
# 再由 release.sh 在测试成功后生成一次。已有 manifest 则仍必须只读校验通过，
# 不允许以“首次发布”为由掩盖已发布树漂移。
MANIFEST="$ROOT/references/manifest/${SKILL_VER}.json"
if [ -f "$MANIFEST" ]; then
if bash "$ROOT/scripts/gen-skill-manifest.sh" check >/dev/null 2>&1; then
    ok "已发布版本 manifest 只读校验通过"
  else
    bad "已发布版本 manifest check 失败"
  fi
else
  ok "新版本尚无 manifest：完整测试不循环依赖发布产物（release.sh 测试通过后生成）"
fi

# R20（P1）：release 外部 state 路径必须逐行解析，不能用 tr + 未引用命令替换按空格拆词。
if grep -qE 'for st in \$\(' "$ROOT/scripts/release.sh"; then
  bad "release 外部 state 路径仍使用易拆词的命令替换解析"
else
  ok "release 外部 state 路径使用保留空格/盘符的逐行解析"
fi

# ---------- R21: P1 MUST_USE 冲突（Camunda 被 FlowCore 替换）必须阻断 ----------
W21="$TMP/r21"; export WORKSPACE="$W21"
mkdir -p "$W21/docs/detailed-design" "$W21/docs/requirements"
bash "$ROOT/scripts/devflow-state.sh" init r21 --frontend=not-applicable >/dev/null 2>&1
for f in _commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md; do
  printf '# %s\n1\n2\n3\n4\n5\n' "$f" > "$W21/docs/detailed-design/$f"
done
cat > "$W21/docs/requirements/r21-technology-constraints.md" <<'EOF'
# r21 技术约束
## 机器契约
<!-- DEVFLOW:CONSTRAINTS
constraint_id=TC-TECH-001
type=MUST_USE
subject=workflow-engine
required_product=camunda
required_version=7.24.0
status=FROZEN
confirmed=true
DEVFLOW:END -->
## 约束清单
| constraint_id | 类型 | 技术/组件 | 必须值/禁止值 | 来源锚点 | 确认人 | 状态 |
|---|---|---|---|---|---|---|
| TC-TECH-001 | MUST_USE | Camunda | 7.24.0 | docs/prd/r21.md#L1 | user | FROZEN |
EOF
cat > "$W21/docs/detailed-design/r21-tech-selection.md" <<'EOF'
# r21 技术选型
## 决策矩阵
| 维度 | Camunda | FlowCore |
|---|---|---|
| 风险 | 4 | 2 |
## 决策结论
用户确认: YES
## 硬约束绑定
<!-- DEVFLOW:CONSTRAINT-BINDINGS
constraint_id=TC-TECH-001
selected_product=FlowCore
selected_version=1.0.0
compliance=PASS
evidence=design
DEVFLOW:END -->
EOF
R21_OUT=$(cd "$W21" && bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design 2>&1 || true)
if printf '%s' "$R21_OUT" | grep -q "MUST_USE.*requires"; then
  ok "P1 MUST_USE 冲突（Camunda→FlowCore）被阻断"
else
  bad "P1 MUST_USE 冲突未被阻断"
fi

# ---------- R22: P2a 缺少独立 reviewer/session 收据必须阻断 ----------
W22="$TMP/r22"; export WORKSPACE="$W22"
mkdir -p "$W22/docs/detailed-design" "$W22/docs/requirements" "$W22/docs/review"
bash "$ROOT/scripts/devflow-state.sh" init r22 --frontend=not-applicable >/dev/null 2>&1
printf '# d\n' > "$W22/docs/detailed-design/r22-design.md"
printf '# c\n| M-01-F01-A01 | FROZEN |\n' > "$W22/docs/requirements/r22-acceptance-criteria.md"
printf '# review\n' > "$W22/docs/review/r22-design-review-report.md"
R22_OUT=$(cd "$W22" && bash "$ROOT/scripts/p2a_design_review_gate.sh" r22 2>&1 || true)
if printf '%s' "$R22_OUT" | grep -q "AUTHOR_ID missing"; then
  ok "P2a 缺独立 reviewer/session 收据被阻断"
else
  bad "P2a 缺独立 reviewer/session 收据未被阻断"
fi


# ---------- R23: "用户确认: 未确认" 必须阻断（LC_ALL=C 多字节正则缺陷回归钉） ----------
W23="$TMP/r23"; export WORKSPACE="$W23"
mkdir -p "$W23/docs/detailed-design" "$W23/docs/requirements"
bash "$ROOT/scripts/devflow-state.sh" init r23 --frontend=not-applicable >/dev/null 2>&1
for f in _commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md; do
  printf '# %s\n1\n2\n3\n4\n5\n' "$f" > "$W23/docs/detailed-design/$f"
done
cat > "$W23/docs/requirements/r23-technology-constraints.md" <<'EOF'
# r23 技术约束
<!-- DEVFLOW:CONSTRAINTS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->
EOF
cat > "$W23/docs/detailed-design/r23-tech-selection.md" <<'EOF'
# r23 技术选型
## 决策矩阵
| 维度 | A | B |
|---|---|---|
| 成本 | 4 | 4 |
## 决策结论
用户确认: 未确认
## 硬约束绑定
<!-- DEVFLOW:CONSTRAINT-BINDINGS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->
EOF
R23_OUT=$(cd "$W23" && bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design 2>&1 || true)
if printf '%s' "$R23_OUT" | grep -q "explicit user confirmation\|negative user confirmation"; then
  ok "P1 '用户确认: 未确认' 被阻断（正则缺陷已修）"
else
  bad "P1 '用户确认: 未确认' 未被阻断"
fi

# ---------- R24: DRAFT 状态 MUST_USE 必须阻断而非跳过 ----------
W24="$TMP/r24"; export WORKSPACE="$W24"
mkdir -p "$W24/docs/detailed-design" "$W24/docs/requirements"
bash "$ROOT/scripts/devflow-state.sh" init r24 --frontend=not-applicable >/dev/null 2>&1
for f in _commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md; do
  printf '# %s\n1\n2\n3\n4\n5\n' "$f" > "$W24/docs/detailed-design/$f"
done
cat > "$W24/docs/requirements/r24-technology-constraints.md" <<'EOF'
# r24 技术约束
<!-- DEVFLOW:CONSTRAINTS
constraint_id=TC-TECH-001
type=MUST_USE
subject=workflow-engine
required_product=camunda
status=DRAFT
confirmed=false
DEVFLOW:END -->
EOF
cat > "$W24/docs/detailed-design/r24-tech-selection.md" <<'EOF'
# r24 技术选型
## 决策矩阵
| 维度 | A | B |
|---|---|---|
| 成本 | 4 | 4 |
## 决策结论
用户确认: YES
EOF
R24_OUT=$(cd "$W24" && bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design 2>&1 || true)
if printf '%s' "$R24_OUT" | grep -q "status must be FROZEN.*DRAFT\|DRAFT constraints block"; then
  ok "P1 DRAFT MUST_USE 被阻断（不再静默跳过）"
else
  bad "P1 DRAFT MUST_USE 未被阻断"
fi

# ---------- R25: 合规 MUST_NOT_USE（selected 不含禁用产品）必须放行 ----------
W25="$TMP/r25"; export WORKSPACE="$W25"
mkdir -p "$W25/docs/detailed-design" "$W25/docs/requirements"
bash "$ROOT/scripts/devflow-state.sh" init r25 --frontend=not-applicable >/dev/null 2>&1
for f in _commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md; do
  printf '# %s\n1\n2\n3\n4\n5\n' "$f" > "$W25/docs/detailed-design/$f"
done
cat > "$W25/docs/requirements/r25-technology-constraints.md" <<'EOF'
# r25 技术约束
<!-- DEVFLOW:CONSTRAINTS
constraint_id=TC-TECH-002
type=MUST_NOT_USE
subject=workflow-engine
required_product=FlowCore
status=FROZEN
confirmed=true
DEVFLOW:END -->
EOF
cat > "$W25/docs/detailed-design/r25-tech-selection.md" <<'EOF'
# r25 技术选型
## 决策矩阵
| 维度 | Camunda | FlowCore |
|---|---|---|
| 风险 | 4 | 2 |
## 决策结论
用户确认: YES
## 硬约束绑定
<!-- DEVFLOW:CONSTRAINT-BINDINGS
constraint_id=TC-TECH-002
selected_product=camunda
compliance=PASS
evidence=backend/pom.xml
DEVFLOW:END -->
EOF
(cd "$W25" && bash "$ROOT/scripts/devflow-state.sh" constraints-freeze r25 >/dev/null 2>&1)
if (cd "$W25" && bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design >/dev/null 2>&1); then
  ok "P1 合规 MUST_NOT_USE（selected=camunda）放行——'未引入X'类自然语言不再参与判定"
else
  bad "P1 合规 MUST_NOT_USE 被误拒"
fi

finish EVIDENCE_V3140
