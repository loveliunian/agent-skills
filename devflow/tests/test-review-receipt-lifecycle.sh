#!/usr/bin/env bash
# test-review-receipt-lifecycle.sh · v3.24.0 独立评审收据生命周期 + 完整 P2a 正向
# 覆盖体检报告：A08「完整 P2a 正向 fixture」（真实签名收据 + 报告深度契约全过 →
# 整道 Gate PASS）、A10 初审→修复复审（新 session）、缺平台证明时的清楚错误、
# 错误密钥签名拒绝。测试密钥仅用于本测试，不代表真实独立评审（同报告 §1 边界）。
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
PASS=0
# v3.28.9: 时长门禁与同输入拦截是独立机检（见 review-receipt.sh），本测试覆盖协议生命周期——
# 即时 begin/complete 与同输入多轮在此显式关闭/变基
export DEVFLOW_REVIEW_MIN_SECONDS=0

FAIL=0
ok() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devflow-rrlife.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "=== review receipt lifecycle / full P2a positive (v3.24.0) ==="

# ---------- 测试 attester 密钥与签名器（平台证明的测试替身） ----------
openssl genrsa -out "$WORK/attest-private.pem" 2048 >/dev/null 2>&1 || { bad "生成测试私钥失败"; exit 1; }
openssl rsa -in "$WORK/attest-private.pem" -pubout -out "$WORK/attest-public.pem" >/dev/null 2>&1 || { bad "生成测试公钥失败"; exit 1; }
export REVIEW_ATTESTATION_PUBKEY="$WORK/attest-public.pem"
openssl genrsa -out "$WORK/attest-other-private.pem" 2048 >/dev/null 2>&1
openssl rsa -in "$WORK/attest-other-private.pem" -pubout -out "$WORK/attest-other-public.pem" >/dev/null 2>&1
WRONG_KEY="$WORK/attest-other-public.pem"   # 另一对密钥的公钥——签名必验失败

ATTEST_N=0
make_attestation() { # event role agent feature session design report dest
  local event="$1" role="$2" agent="$3" feature="$4" session="$5" design="$6" report="$7" dest="$8"
  local input_sha output_sha payload sig
  ATTEST_N=$((ATTEST_N + 1))
  input_sha=$(shasum -a 256 "$design" 2>/dev/null | awk '{print $1}')
  output_sha=""
  [ "$event" = "begin" ] || output_sha=$(shasum -a 256 "$report" 2>/dev/null | awk '{print $1}')
  payload=$(jq -cn --arg feature "$feature" --arg session "$session" --arg role "$role" --arg agent "$agent" \
    --arg event "$event" --arg input "$input_sha" --arg output "$output_sha" \
    --arg nonce "testnonce-${ATTEST_N}-0123456789abcdef" \
    '{schema:"devflow-review-attestation-v1",feature:$feature,session_id:$session,role:$role,agent_id:$agent,
      event:$event,input_sha:$input,output_sha:$output,issued_at:"2026-09-17T00:00:00Z",nonce:$nonce}')
  printf '%s' "$payload" | jq -cS . > "$WORK/payload-$ATTEST_N.json"
  openssl dgst -sha256 -sign "$WORK/attest-private.pem" -out "$WORK/sig-$ATTEST_N.bin" "$WORK/payload-$ATTEST_N.json" >/dev/null 2>&1 || { bad "签名失败"; return 1; }
  sig=$(openssl base64 -A -in "$WORK/sig-$ATTEST_N.bin")
  jq -n --argjson payload "$payload" --arg signature "$sig" '{payload:$payload,signature_b64:$signature}' > "$dest"
}

# ---------- 纯计算 feature 夹具（与 hardening 测试同构：design.json 可过 §2c） ----------
W="$WORK/ws"
mkdir -p "$W/docs/需求" "$W/docs/详细设计" "$W/docs/评审" "$W/.devflow/pr"
TPL_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p' "$ROOT/templates/详细设计-完整版-模板.md" | head -1)
# v3.28.2：P2a 要求 clarification.json（PRD-to-Design 映射正本）。
# 纯计算夹具无实体/操作/约束——空集合即完备映射（映射器对空集合提前返回）。
cat > "$W/.devflow/pr/clarification.json" <<'CLAR_EOF'
{
  "feature": "pr",
  "feature_name": "pr",
  "prd_path": "docs/需求/pr-prd.md",
  "entities": [],
  "operations": [],
  "constraints": [],
  "acceptance_points": [],
  "zero_results": [
    {"path": "entities", "reason": "纯计算无持久化实体"},
    {"path": "operations", "reason": "无跨请求状态操作"},
    {"path": "constraints", "reason": "无约束条款"}
  ]
}
CLAR_EOF
cat > "$W/docs/需求/pr-验收点.md" <<'EOF'
| M-01-F01-A01 | FROZEN |
EOF
printf '# pr PRD\n' > "$W/docs/需求/pr-prd.md"
cat > "$W/docs/需求/pr-技术约束.md" <<'EOF'
<!-- DEVFLOW:CONSTRAINTS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->
EOF
cat > "$W/.devflow/pr/design.json" <<EOF
{
  "feature": "pr",
  "generated_at": "2026-09-17T00:00:00Z",
  "template": {"id": "详细设计-完整版-模板", "version": "$TPL_VER", "mode": "monolith"},
  "acceptance": [{"id": "M-01-F01-A01", "prd_anchor": "docs/需求/pr-prd.md#L1", "page": "—", "api": "—", "data": "—", "rule": "R1", "test_case": "TC-PR-001", "status": "COMPLETE"}],
  "tables": [], "apis": [], "pages": [],
  "rules": [{"id": "R1", "anchor": "§5", "summary": "输入校验"}],
  "business_operations": [{"id": "BOP-1", "name": "执行纯计算", "trigger": "请求触发", "actor": "调用方", "stateless": true, "steps": ["读入", "计算", "返回"], "result": "返回计算结果", "failure": "输入非法返回 400", "test_scenarios": ["正常", "非法输入"], "acceptance_refs": ["M-01-F01-A01"], "anchor": "§6"}],
  "baseline": {"repo_root": ".", "db_evidence": {"source": "none"}, "entries": [{"id": "BL-1", "target": "backend/pure/CalcService.java", "decision": "ADD", "target_module": "pure 模块", "verify": "CalcServiceTest"}]},
  "client": {"scope": "not-applicable", "not_applicable_reason": "纯计算无前端"},
  "migrations": {"applicable": false, "not_applicable_reason": "无数据库"},
  "decisions": [{"id": "DDR-1", "topic": "算法选型", "reason": "量化解：O(n log n) 满足上限", "unreferenced_reason": "无表字段"}],
  "zero_results": [
    {"path": "pages", "reason": "无前端"}, {"path": "apis", "reason": "纯函数计算"},
    {"path": "tables", "reason": "无持久化"}, {"path": "resources", "reason": "无资源占用"},
    {"path": "operations", "reason": "无资源即无补偿链"}, {"path": "integrations", "reason": "无外部调用"},
    {"path": "configs", "reason": "无新增配置键"}]
}
EOF
cat > "$W/docs/详细设计/pr-详细设计.md" <<EOF
# pr 详细设计

> 模板 ID：\`详细设计-完整版-模板\`
> 模板版本：\`$TPL_VER\`

## §0 文档结构
单体模式：单模块纯计算（结构经 P1 选型决策：design_doc_structure_mode=monolith）。

## §1 功能概述
纯计算功能：无表、无接口、无前端。

## §2 数据模型
<!-- anchor: data-model -->
本设计不涉及持久化（zero_results 已声明 tables 为空）。

## §2.3 设计决策记录（DDR）
<!-- anchor: design-decisions -->
算法选型决策见 design.json。

## §3 接口设计
<!-- anchor: api-contracts -->
本设计无对外接口（zero_results 已声明 apis 为空）。

## §4 权限矩阵
无页面无接口，权限不适用。

## §5 业务规则
<!-- anchor: business-rules -->

| 规则编号 | 规则描述 | 约束/错误处理 |
|----------|----------|--------------|
| R1 | 输入必须为正整数 | 非法返回 400 |

## §6 关键流程
<!-- anchor: business-operations -->
WHEN 执行纯计算 (input):
  1. 校验 input
  2. 返回结果

\`\`\`mermaid
sequenceDiagram
    participant 调用方
    participant Service
    调用方->>Service: calc(input)
    Service-->>调用方: 200 OK
\`\`\`

## §7 前端页面
无前端页面。

## §8 数据库迁移
不适用（无数据库，铁律 5 已冻结说明）。

## §9 验收标准
见追溯矩阵。

## §9 依赖项
无。

## §9.3 资源与补偿链
无受管资源。

## §8 验收标准（零结果）（追溯矩阵在存量位置，s2 回退读取）
<!-- anchor: acceptance-traceability -->
| M-01-F01-A01 | docs/需求/pr-prd.md#L1 | — | — | — | R1 | TC-PR-001 | COMPLETE |
设计覆盖率 = 100%

## §10 组件复用与公共抽取
<!-- anchor: component-reuse -->
<!-- anchor: common-extraction -->
无新增复用与抽取（纯标准库计算）。

## §9 依赖项（规范）
<!-- anchor: standards-compliance -->
遵循阿里巴巴 Java 开发手册；无偏离。

## §11 异常处理、安全与性能设计
沿用平台统一异常/认证/性能基线；纯计算无事务与缓存决策。

## §12 实现交接（Implementation Handoff）
<!-- anchor: implementation-handoff -->
| 文件/符号 | ADD/MODIFY/DELETE | 设计依据 | 验收点 |
|---|---|---|---|
| backend/pure/CalcService.java | ADD | §6 | M-01-F01-A01 |

## §12 变更历史
v1 初稿。

## 评审记录
待评审。
EOF
(cd "$W" && WORKSPACE="$W" bash "$ROOT/scripts/devflow-state.sh" init pr --frontend=not-applicable >/dev/null 2>&1)

# ---------- 评审报告（满足全部深度契约） ----------
REPORT="$W/docs/评审/pr-设计评审报告.md"
SESSION="rev-pr-001"
write_report() { # <session>
  local sess="$1"
  cat > "$REPORT" <<EOF
# pr 详细设计评审报告

| 项 | 内容 |
|---|------|
| 功能名称 | 纯计算 |
| AUTHOR_ID | ag-author |
| REVIEW_RUN_ID | $sess |

## 评审委员会

| 角色 | 评委 | 机构 |
|------|------|------|
| 架构师 | ag-arch | 独立会话 A |
| 后端专家 | ag-be | 独立会话 B |
| 前端专家 | ag-fe | 独立会话 C |
| 测试开发 | ag-qa | 独立会话 D |
| DBA | ag-dba | 独立会话 E |

### 独立性收据

| 角色 | REVIEWER_ID | REVIEW_SESSION_ID | 结论 |
|---|---|---|---|
| 架构师 | ag-arch | $sess | ✅ |
| 后端专家 | ag-be | $sess | ✅ |
| 前端专家 | ag-fe | $sess | ✅ |
| 测试开发 | ag-qa | $sess | ✅ |
| DBA | ag-dba | $sess | ✅ |

## 探针执行记录

| 探针 | 主责评委 | 执行情况 | 产出位置 / 结论 |
|------|----------|----------|-----------------|
| P1 对抗场景走查 | 全员 | 已执行 | 证据：§6，见 AW 清单 |
| P2 边界与极端值枚举 | 后端+测试开发 | 已执行 | 证据：§5，零输入/负数/超大值已核查 |
| P3 状态机×异常分支矩阵 | 测试开发 | 已执行 | 证据：§6，无状态设计仅输入分支 |
| P4 跨产物一致性核对 | 架构师 | 已执行 | 证据：§2.3，JSON 与正文一致 |
| P5 决策 Why 链 | DBA+架构师 | 已执行 | 证据：§2.3，量化解理由成立 |
| P6 数据量与时间演化 | DBA+架构师 | 已执行 | 证据：§11，无持久化不适用容量 |
| CODE-BASELINE 基线核验 | 架构师+后端专家 | 不适用（绿地纯 ADD） | 证据：§11 |

## ZERO-DF 核查记录

#### ZERO-DF 核查（架构师）
- 核查范围：§0 架构决策、§10 复用与抽取、§12 交接边界
- 证据：§10 复用清单已声明纯标准库；§12 交接表与 §6 一致
- 验证方式：对照 §12/§14 与 design.json baseline 逐条核对

#### ZERO-DF 核查（后端专家）
- 核查范围：§5 规则表、§6 流程伪代码
- 证据：§5 规则 R1 与 §6 WHEN 步骤一一对应
- 验证方式：CalcServiceTest 用例映射 R1

#### ZERO-DF 核查（前端专家）
- 核查范围：§7 前端页面声明
- 证据：§7 与 zero_results 的 pages 空声明一致
- 验证方式：对照 design.json zero_results

#### ZERO-DF 核查（测试开发）
- 核查范围：§9 验收标准与追溯矩阵
- 证据：§11 追溯矩阵 1/1 COMPLETE
- 验证方式：TC-PR-001 用例可由 §6 步骤推导

#### ZERO-DF 核查（DBA）
- 核查范围：§2.3 决策与迁移声明
- 证据：§2.3 量化解理由；§8 迁移不适用说明
- 验证方式：DDR-1 理由复核，四方言不适用确认

## 对抗场景走查

- AW-1 场景：重复提交同一输入｜走查路径：触发→输入→计算→返回｜结果：无缺陷，证据：§5
- AW-2 场景：非法输入（负数/非整数）｜走查路径：触发→校验→拒绝码｜结果：无缺陷，证据：§5
- AW-3 场景：超大输入溢出｜走查路径：触发→计算→上限保护｜结果：无缺陷，证据：§2.3

## 评审结论

- [x] 所有 DF 状态为 CLOSED（本轮零发现，五角色 ZERO-DF 核查齐全）
- [x] 需求追溯 100% 覆盖 P0 验收点
EOF
}

# ---------- A10：缺平台证明 → 清楚报错（fail-closed） ----------
NOATT_OUT=$(cd "$W" && env -u REVIEW_ATTESTATION_PUBKEY bash "$ROOT/scripts/review-receipt.sh" begin \
  --feature pr --role 架构师 --agent-id ag-arch --session-id "$SESSION" \
  --input docs/详细设计/pr-详细设计.md --output docs/评审/pr-设计评审报告.md 2>&1 || true)
printf '%s' "$NOATT_OUT" | grep -q "REVIEW_ATTESTATION_PUBKEY\|attestation" \
  && ok "missing platform attestation fails with clear error (A10)" \
  || bad "missing attestation error unclear: $NOATT_OUT"

# ---------- A08：完整 P2a 正向（真实签名收据 + 深度契约） ----------
PAIRS="AUTHOR:ag-author 架构师:ag-arch 后端专家:ag-be 前端专家:ag-fe 测试开发:ag-qa DBA:ag-dba"
run_round() { # <session>
  local sess="$1" pair role ag att
  # 协议要求 begin 时报告不存在——新一轮复审重建报告文件
  rm -f "$REPORT"
  for pair in $PAIRS; do
    role="${pair%%:*}"; ag="${pair##*:}"
    att="$WORK/begin-$sess-$ag.json"
    make_attestation begin "$role" "$ag" pr "$sess" "$W/docs/详细设计/pr-详细设计.md" "$REPORT" "$att"
    (cd "$W" && bash "$ROOT/scripts/review-receipt.sh" begin --feature pr --role "$role" --agent-id "$ag" \
      --session-id "$sess" --input docs/详细设计/pr-详细设计.md --output docs/评审/pr-设计评审报告.md \
      --attestation "$att" >/dev/null 2>&1) || return 1
  done
  write_report "$sess"
  for pair in $PAIRS; do
    role="${pair%%:*}"; ag="${pair##*:}"
    att="$WORK/complete-$sess-$ag.json"
    make_attestation complete "$role" "$ag" pr "$sess" "$W/docs/详细设计/pr-详细设计.md" "$REPORT" "$att"
    (cd "$W" && bash "$ROOT/scripts/review-receipt.sh" complete --feature pr --role "$role" --agent-id "$ag" \
      --session-id "$sess" --input docs/详细设计/pr-详细设计.md --output docs/评审/pr-设计评审报告.md \
      --attestation "$att" >/dev/null 2>&1) || return 1
  done
  return 0
}

if run_round "$SESSION"; then
  ok "round-1 two-phase signed receipts for AUTHOR+5 roles (A08/A10)"
else
  bad "round-1 receipt lifecycle failed"
fi

P2A_OUT=$(cd "$W" && bash "$ROOT/scripts/p2a_design_review_gate.sh" pr 2>&1 || true)
if (cd "$W" && bash "$ROOT/scripts/p2a_design_review_gate.sh" pr >/dev/null 2>&1); then
  ok "FULL P2a Gate PASSES with signed receipts and deep-contract report (A08)"
else
  bad "full P2a positive failed: $(printf '%s' "$P2A_OUT" | grep '\[P0\]' | head -4 | tr '\n' ' ')"
fi
printf '%s' "$P2A_OUT" | grep -q "independent review receipts verified" \
  && ok "gate verified orchestrator receipts (not self-reported IDs)" \
  || bad "gate receipt verification line missing"

# ---------- A10：修复复审——新一轮必须用新 session 全流程重跑 ----------
# v3.28.9 同输入拦截：复审前先修改产物（"修复"语义）——输入未变的整轮重评会被拒
printf '<!-- round-2 fix -->\n' >> "$W/docs/详细设计/pr-详细设计.md"
SESSION2="rev-pr-002"
if run_round "$SESSION2"; then
  ok "round-2 re-review with fresh session completes lifecycle (A10)"
else
  bad "round-2 re-review failed"
fi

# ---------- A10：错误密钥签名 → 拒绝（begin 协议要求报告尚不存在，先移除） ----------
# v3.28.9 同输入拦截：新一轮 begin 前同样先变基输入，保证本用例命中签名校验而非重评拦截
printf '<!-- round-3 wrongkey probe -->\n' >> "$W/docs/详细设计/pr-详细设计.md"
SESSION3="rev-pr-003"
rm -f "$REPORT"
export REVIEW_ATTESTATION_PUBKEY="$WRONG_KEY"
att="$WORK/begin-wrongkey.json"
make_attestation begin "架构师" "ag-arch" pr "$SESSION3" "$W/docs/详细设计/pr-详细设计.md" "$REPORT" "$att" 2>/dev/null
WK_OUT=$(cd "$W" && bash "$ROOT/scripts/review-receipt.sh" begin --feature pr --role 架构师 --agent-id ag-arch \
  --session-id "$SESSION3" --input docs/详细设计/pr-详细设计.md --output docs/评审/pr-设计评审报告.md \
  --attestation "$att" 2>&1 || true)
printf '%s' "$WK_OUT" | grep -q "attestation" \
  && ok "wrong-signer attestation rejected (A10)" \
  || bad "wrong-key attestation not rejected: $WK_OUT"

echo "=== review receipt lifecycle RESULT PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
