#!/usr/bin/env bash
# test-design-contract-hardening.sh · v3.24.0 详设体系体检报告修复回归
# 每条负向断言从"能通过完整链路的合法样本"变异单一因素（报告 A15 要求），
# 覆盖体检报告 A01-A09/A16 的可执行修复：
#   A01 业务操作覆盖闭环；A02 基线工作区反查；A03 JSON↔正文对账/空壳拦截；
#   A04 PRD 来源/嵌套锚点；A06 无表无接口豁免+冻结 frontend 对账；A07 块注册表；
#   A08 p2a 表格解析；A09/A14 深度契约静态钉；A16 花括号占位。
set -u
set -o pipefail

# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
# v3.30.0: gj_copy_sample（testlib 助手）——Gate JSON 强制夹具
source "$TEST_DIR/testlib.sh"
PASS=0
FAIL=0
ok() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
check_rc() { local expect="$1" desc="$2"; shift 2
  "$@" >/dev/null 2>&1; local rc=$?
  [ "$rc" = "$expect" ] && ok "$desc (exit=$rc)" || bad "$desc (expect=$expect got=$rc)"
}
assert_out() { # <pattern> <desc> <cmd...>
  local pat="$1" desc="$2"; shift 2
  local out; out=$("$@" 2>&1 || true)
  printf '%s' "$out" | grep -q "$pat" && ok "$desc" || bad "${desc}（输出未含: ${pat}）"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devflow-hardening.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
V="$ROOT/scripts/df_validate.py"
R="$ROOT/scripts/df_render.py"

echo "=== design contract hardening (v3.24.0) ==="
cd "$WORK" || exit 1
mkdir -p docs/requirements
cp "$ROOT/examples/structured/design.sample.json" design.json
cp "$ROOT/examples/structured/design.skeleton.md" doc.md
cat > criteria.md <<'EOF'
| M01-F01-A01 | x |
| M01-F01-A02 | x |
| M01-F02-A01 | x |
EOF
cp criteria.md docs/requirements/demo-pay-acceptance-criteria.md
# 基线工作区隔离：样例 MODIFY 目标在本仓不存在 → 无工程标志时反查关闭
check_rc 0 "baseline sample validates without workspace markers" "${DEVFLOW_PY[@]}" "$V" --kind design --input design.json --criteria criteria.md --doc doc.md

# ---------- A07：块注册表同源（v3.28.1：详设 10 块 + DB 2 块 + 追溯 1 块） ----------
DESIGN_BLOCKS="summary table-index api-index permission-matrix rule-index biz-ops resource-operations integrations-configs"
DB_BLOCKS="ddr-index ddr-matrix"
TRACE_BLOCKS="trace-matrix"
BLOCKS="$DESIGN_BLOCKS $DB_BLOCKS $TRACE_BLOCKS"
NB=0
for b in $DESIGN_BLOCKS; do NB=$((NB+1)); done
for t in "详细设计-完整版-模板.md" "详细设计-总分总文档-模板.md" "详细设计-总分分文档-模板.md"; do
  _miss=""
  for b in $DESIGN_BLOCKS; do
    grep -q "df:begin:$b" "$ROOT/templates/$t" || _miss="$_miss $b"
  done
  [ -z "$_miss" ] && ok "design template carries all $NB render blocks: $t" || bad "design template missing blocks ($_miss): $t"
done
_miss=""
for b in $DB_BLOCKS; do
  grep -q "df:begin:$b" "$ROOT/templates/数据库设计决策-模板.md" || _miss="$_miss $b"
done
[ -z "$_miss" ] && ok "db design doc template carries ddr blocks" || bad "db design doc template missing blocks ($_miss)"
_miss=""
for b in $TRACE_BLOCKS; do
  grep -q "df:begin:$b" "$ROOT/templates/需求追溯-模板.md" || _miss="$_miss $b"
done
[ -z "$_miss" ] && ok "traceability template carries trace blocks" || bad "traceability template missing blocks ($_miss)"
# init-doc 初始化入口
check_rc 0 "init-doc creates skeleton" "${DEVFLOW_PY[@]}" "$R" design --input design.json --init-doc fresh-skeleton.md
for b in $BLOCKS; do
  grep -q "df:begin:$b" fresh-skeleton.md || bad "init-doc skeleton missing block $b"
done
ok "init-doc skeleton has all blocks"
check_rc 1 "init-doc refuses existing doc" "${DEVFLOW_PY[@]}" "$R" design --input design.json --init-doc fresh-skeleton.md
# 旧反例复现：删 resource-operations/integrations-configs → 渲染失败关闭且报缺块
"${DEVFLOW_PY[@]}" - <<'PYEOF'
from pathlib import Path
t = Path("fresh-skeleton.md").read_text(encoding="utf-8")
for k in ("resource-operations", "integrations-configs"):
    t = t.replace(f"<!-- df:begin:{k} -->\n<!-- df:end:{k} -->", "")
Path("ten-blocks.md").write_text(t, encoding="utf-8")
PYEOF
check_rc 1 "doc missing registry blocks fails closed (A07)" "${DEVFLOW_PY[@]}" "$R" design --input design.json --doc ten-blocks.md
assert_out "resource-operations" "missing-block error names the undeclared block (A07)" "${DEVFLOW_PY[@]}" "$R" design --input design.json --doc ten-blocks.md
# 全量骨架（13 块）→ 渲染：详设 11 块必需；骨架中存量 ddr 块一并刷新（升级期兼容）
check_rc 0 "full skeleton renders via renderer (A07)" "${DEVFLOW_PY[@]}" "$R" design --input design.json --doc fresh-skeleton.md
grep -q "df:begin:biz-ops" fresh-skeleton.md && grep -q "BOP-1\|创建支付订单" fresh-skeleton.md && ok "biz-ops block rendered (A01)" || bad "biz-ops block rendered"

# ---------- A01：业务操作覆盖闭环 ----------
"${DEVFLOW_PY[@]}" - <<'PYEOF'
import json
d = json.load(open("design.json")); d["business_operations"].pop()   # 删掉覆盖 M01-F02-A01 的退款操作
json.dump(d, open("d-bopgap.json", "w"), ensure_ascii=False)
e = json.load(open("design.json"))
e["business_operations"][0]["stateless"] = False; e["business_operations"][0].pop("source_state", None)
json.dump(e, open("d-bopstate.json", "w"), ensure_ascii=False)
PYEOF
assert_out "覆盖缺口" "missing restore/refund operation caught as coverage gap (A01)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input d-bopgap.json --criteria criteria.md
assert_out "M01-F02-A01" "coverage gap names the exact uncovered acceptance ID (A15)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input d-bopgap.json --criteria criteria.md
assert_out "source_state" "stateful op without source_state rejected (A01)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input d-bopstate.json --criteria criteria.md

# ---------- A02：基线工作区反查 ----------
WSA="$WORK/ws-a"; mkdir -p "$WSA/backend/x/src/main/java" "$WSA/docs/requirements"
printf 'class FooController {}\n' > "$WSA/backend/x/src/main/java/FooController.java"
cp criteria.md "$WSA/docs/requirements/demo-pay-acceptance-criteria.md"
touch "$WSA/pom.xml"   # 工程标志：启用全仓反查
"${DEVFLOW_PY[@]}" - <<'PYEOF'
import json
d = json.load(open("design.json"))
# 同一夹具内自洽：configs 消费点与基线目标都指向真实存在的 FooController
d["configs"][0]["consumption_points"][0]["location"] = "backend/x/src/main/java/FooController.java#list"
d["configs"][0]["key"] = "FooController"
d["baseline"] = {"repo_root": ".", "entries": [
  {"id": "BL-1", "target": "backend/x/src/main/java/FooController.java", "decision": "MODIFY",
   "existing_contract": "FooController#list", "verify": "FooControllerTest"}]}
json.dump(d, open("ws-a/base.json", "w"), ensure_ascii=False)
e = json.loads(json.dumps(d))
e["baseline"]["entries"][0]["target"] = "backend/x/src/main/java/NotFound.java#list"
json.dump(e, open("ws-a/miss.json", "w"), ensure_ascii=False)
PYEOF
# 工程标志存在时反查生效：MODIFY 目标真实存在 → 通过
check_rc 0 "baseline MODIFY target exists passes reverse lookup (A02)" \
  bash -c "cd '$WSA' && \$DEVFLOW_PY_STR '$V' --kind design --input base.json --criteria '$WSA/docs/requirements/demo-pay-acceptance-criteria.md' --workspace ."
assert_out "目标文件不存在" "fictional MODIFY target rejected in real workspace (A02)" \
  bash -c "cd '$WSA' && \$DEVFLOW_PY_STR '$V' --kind design --input miss.json --criteria '$WSA/docs/requirements/demo-pay-acceptance-criteria.md' --workspace ."
# v3.24.0(A02) 补充：fingerprint 证据指纹（64-hex = 文件 SHA-256，工作区反查时实算比对）
"${DEVFLOW_PY[@]}" - <<'PYEOF'
import hashlib, json
d = json.load(open("ws-a/base.json"))
fp = hashlib.sha256(open("ws-a/backend/x/src/main/java/FooController.java", "rb").read()).hexdigest()
d["baseline"]["entries"][0]["fingerprint"] = fp
d["baseline"]["entries"][0]["related_operations"] = ["BOP-1"]
json.dump(d, open("ws-a/fp-ok.json", "w"), ensure_ascii=False)
e = json.loads(json.dumps(d)); e["baseline"]["entries"][0]["fingerprint"] = "0" * 64
json.dump(e, open("ws-a/fp-bad.json", "w"), ensure_ascii=False)
f = json.loads(json.dumps(d)); f["baseline"]["entries"][0]["related_operations"] = ["BOP-9"]
json.dump(f, open("ws-a/rop-bad.json", "w"), ensure_ascii=False)
PYEOF
check_rc 0 "baseline fingerprint matching actual file accepted (A02)" \
  bash -c "cd '$WSA' && \$DEVFLOW_PY_STR '$V' --kind design --input fp-ok.json --criteria '$WSA/docs/requirements/demo-pay-acceptance-criteria.md' --workspace ."
assert_out "指纹" "stale baseline fingerprint rejected (A02)" \
  bash -c "cd '$WSA' && \$DEVFLOW_PY_STR '$V' --kind design --input fp-bad.json --criteria '$WSA/docs/requirements/demo-pay-acceptance-criteria.md' --workspace ."
assert_out "悬空引用" "baseline related_operations dangling id rejected (A02)" \
  bash -c "cd '$WSA' && \$DEVFLOW_PY_STR '$V' --kind design --input rop-bad.json --criteria '$WSA/docs/requirements/demo-pay-acceptance-criteria.md' --workspace ."

# ---------- A03：JSON↔正文对账 + 空壳拦截 ----------
# 正文 §2.1 注入五列表，order_no 类型与 JSON 冲突（BOOLEAN vs VARCHAR(64)）
"${DEVFLOW_PY[@]}" - <<'PYEOF'
from pathlib import Path
t = Path("doc.md").read_text(encoding="utf-8")
table = "\n| 字段名 | 类型 | 约束 | 默认值 | 口径说明 |\n|---|---|---|---|---|\n| order_no | BOOLEAN | PK | — | 冲突类型 |\n"
t = t.replace("### 2.2.1 支付订单表（pay_order）\n", "### 2.2.1 支付订单表（pay_order）\n" + table, 1)
Path("doc-typeconflict.md").write_text(t, encoding="utf-8")
PYEOF
assert_out "冲突" "JSON type vs doc table type conflict rejected (A03)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input design.json --criteria criteria.md --doc doc-typeconflict.md
# 字段从正文表格消失（正文有表但缺该字段）
"${DEVFLOW_PY[@]}" - <<'PYEOF'
from pathlib import Path
t = Path("doc-typeconflict.md").read_text(encoding="utf-8")
t = t.replace("| order_no | BOOLEAN | PK | — | 冲突类型 |\n", "| ref_no | BOOLEAN | PK | — | 另一字段 |\n", 1)
Path("doc-nofield.md").write_text(t, encoding="utf-8")
PYEOF
assert_out "未出现在" "JSON field missing from doc table rejected (A03)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input design.json --criteria criteria.md --doc doc-nofield.md
# 仅标题空壳正文
"${DEVFLOW_PY[@]}" - <<'PYEOF'
import re
from pathlib import Path
t = Path("doc.md").read_text(encoding="utf-8")
t = re.sub(r"(### 2\.2\.1 支付订单表（pay_order）\n)(.*?)(### 2\.2\.2)", r"\1\3", t, flags=re.S)
t = re.sub(r"(### 7\.1\.1 下单页\n)(.*?)(### 7\.1\.2)", r"\1\3", t, flags=re.S)
Path("doc-hollow.md").write_text(t, encoding="utf-8")
PYEOF
assert_out "空壳" "headings-only section rejected as hollow (A03)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input design.json --criteria criteria.md --doc doc-hollow.md

# ---------- A03 补充：约束列比对 + WHEN 逐字契约 ----------
"${DEVFLOW_PY[@]}" - <<'PYEOF'
import json
d = json.load(open("design.json"))
d["rules"][0]["when_line"] = "WHEN 同一 order_no 在 60 秒内重复提交：直接二次扣款。"   # 与正文反义
json.dump(d, open("d-wl.json", "w"), ensure_ascii=False)
PYEOF
assert_out "逐字" "JSON WHEN line diverging from doc pseudocode rejected (A03)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input d-wl.json --criteria criteria.md --doc doc.md
assert_out "约束" "doc table constraint column conflict rejected (A03)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input design.json --criteria criteria.md --doc doc-typeconflict.md

# ---------- A04 补充：一条验收行为关联多个对象（数组引用） ----------
"${DEVFLOW_PY[@]}" - <<'PYEOF'
import json
d = json.load(open("design.json"))
d["acceptance"][0]["page"] = ["§7.2.1", "§7.2.2"]
d["acceptance"][0]["api"] = ["§3.2.1"]
json.dump(d, open("d-multiref.json", "w"), ensure_ascii=False)
PYEOF
check_rc 0 "acceptance row may reference multiple objects via arrays (A04)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input d-multiref.json --criteria criteria.md --doc doc.md
"${DEVFLOW_PY[@]}" - <<'PYEOF'
import json
d = json.load(open("design.json"))
d["acceptance"][0]["page"] = ["§7.2.1", "§7.99"]
json.dump(d, open("d-multiref-bad.json", "w"), ensure_ascii=False)
PYEOF
assert_out "引用断链" "array reference with dangling element rejected (A04)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input d-multiref-bad.json --criteria criteria.md


# ---------- A04：PRD 来源存在 + 嵌套锚点 ----------
"${DEVFLOW_PY[@]}" - <<'PYEOF'
import json
d = json.load(open("design.json"))
d["acceptance"][0]["prd_anchor"] = "does-not-exist.md#L99999"
json.dump(d, open("d-prdmiss.json", "w"), ensure_ascii=False)
e = json.load(open("design.json"))
e["apis"][0]["request"]["anchor"] = "§9.9.9"
json.dump(e, open("d-nested.json", "w"), ensure_ascii=False)
PYEOF
assert_out "来源文件不存在" "nonexistent PRD source rejected (A04)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input d-prdmiss.json --criteria criteria.md
assert_out "嵌套引用断链" "dangling nested request anchor rejected (A04)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input d-nested.json --criteria criteria.md --doc doc.md

# ---------- A08：p2a 角色表解析（BSD awk $0 重建陷阱） ----------
cat > role-table.md <<'EOF'
| 角色 | REVIEWER_ID | REVIEW_SESSION_ID | 结论 |
|---|---|---|---|
| 架构师 | reviewer one | rev session 001 | ✅ 通过 |
| 后端专家 | reviewer two | rev session 001 | ✅ 通过 |
EOF
PARSED=$(awk -F'|' -v role="架构师" 'NF >= 6 || NF >= 3 {role_cell=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", role_cell); if (role_cell == role) {print; exit}}' role-table.md)
REVIEWER=$(printf '%s\n' "$PARSED" | awk -F'|' '{reviewer_cell=$3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", reviewer_cell); print reviewer_cell}')
SESSION=$(printf '%s\n' "$PARSED" | awk -F'|' '{session_cell=$4; gsub(/^[[:space:]]+|[[:space:]]+$/, "", session_cell); print session_cell}')
CONCL=$(printf '%s\n' "$PARSED" | awk -F'|' '{concl_cell=$5; gsub(/^[[:space:]]+|[[:space:]]+$/, "", concl_cell); print concl_cell}')
if [ "$REVIEWER" = "reviewer one" ] && [ "$SESSION" = "rev session 001" ] && printf '%s' "$CONCL" | grep -q "通过"; then
  ok "role row with spaces parses reviewer/session/conclusion (A08)"
else
  bad "role row parsing broken: reviewer='$REVIEWER' session='$SESSION' conclusion='$CONCL' (A08)"
fi
if grep -qE 'gsub\(/\^\[\[:space:\]\].*"\], "", \$2\); if \(\$2 == role\) \{print' "$ROOT/scripts/p2a_design_review_gate.sh" 2>/dev/null; then
  bad "p2a still contains gsub-on-\$2 rebuild pattern (A08 regression)"
else
  ok "p2a no longer rebuilds \$0 via gsub on \$2 (A08)"
fi

# ---------- A09/A14：深度契约静态钉 ----------
grep -q "ZERO-DF 块缺核查实质" "$ROOT/scripts/p2a_design_review_gate.sh" && ok "p2a enforces non-empty ZERO-DF records (A09)" || bad "p2a ZERO-DF hollow check missing (A09)"
grep -q "ZERO-DF 块缺核查实质" "$ROOT/scripts/artifact_gate.sh" && ok "P0b enforces non-empty ZERO-DF records (A14)" || bad "P0b ZERO-DF hollow check missing (A14)"
if grep -q "DF_MIN_TOTAL" "$ROOT/scripts/artifact_gate.sh"; then bad "P0b still mandates numeric DF minimums (A14)"; else ok "P0b counts DF by actual findings (A14)"; fi
grep -q "unresolvable 结果 references\|unresolvable" "$ROOT/scripts/p2a_design_review_gate.sh" && ok "p2a resolves AW references to real anchors (A09)" || bad "p2a AW reference resolution missing (A09)"

# ---------- A06/A16：s2 Gate 行为（复用 phase-gates 风格最小夹具） ----------
WS2="$WORK/s2"; mkdir -p "$WS2/docs/需求" "$WS2/docs/详细设计" "$WS2/.devflow/pure"
TPL_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p' "$ROOT/templates/详细设计-完整版-模板.md" | head -1)
cat > "$WS2/docs/需求/pure-验收点.md" <<'EOF'
| M-01-F01-A01 | FROZEN |
EOF
cat > "$WS2/docs/需求/pure-技术约束.md" <<'EOF'
# pure 技术约束
<!-- DEVFLOW:CONSTRAINTS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->
EOF
cat > "$WS2/docs/prd-pure.md" <<'EOF'
# pure PRD
EOF
cat > "$WS2/.devflow/pure/design.json" <<EOF
{
  "feature": "pure",
  "generated_at": "2026-09-16T00:00:00Z",
  "template": {"id": "详细设计-完整版-模板", "version": "$TPL_VER", "mode": "monolith"},
  "acceptance": [{"id": "M-01-F01-A01", "prd_anchor": "docs/prd-pure.md#L1", "page": "—", "api": "—", "data": "—", "rule": "R1", "test_case": "TC-PURE-001", "status": "COMPLETE"}],
  "tables": [], "apis": [], "pages": [],
  "rules": [{"id": "R1", "anchor": "§5", "summary": "纯计算校验"}],
  "test_isolation": {"applicable": true, "strategy": "类内 @Order + 每类自清理登录态（fixture）"},
  "business_operations": [{"id": "BOP-1", "name": "执行纯计算", "trigger": "请求触发", "actor": "调用方", "stateless": true, "steps": ["读入", "计算", "返回"], "result": "返回计算结果", "failure": "输入非法返回 400", "test_scenarios": ["正常", "非法输入"], "acceptance_refs": ["M-01-F01-A01"], "anchor": "§6"}],
  "baseline": {"repo_root": ".", "db_evidence": {"source": "none"}, "entries": [{"id": "BL-1", "target": "backend/pure/CalcService.java", "decision": "ADD", "target_module": "pure 模块", "verify": "CalcServiceTest"}]},
  "client": {"scope": "not-applicable", "not_applicable_reason": "纯计算无前端"},
  "migrations": {"applicable": false, "not_applicable_reason": "无数据库"},
  "decisions": [{"id": "DDR-1", "topic": "算法选型", "reason": "量化解：O(n log n) 满足上限", "unreferenced_reason": "无表字段"}],
  "zero_results": [
    {"path": "pages", "reason": "无前端"}, {"path": "apis", "reason": "纯函数计算"},
    {"path": "tables", "reason": "无持久化"}, {"path": "resources", "reason": "无资源占用"},
    {"path": "operations", "reason": "无资源即无补偿链"}, {"path": "integrations", "reason": "无外部调用"},
    {"path": "configs", "reason": "无新增配置键"}
  ]
}
EOF
# 详设正文：无五列/六列表头（声明空集合后合法），含 WHEN+时序图+四要素+模板身份
cat > "$WS2/docs/详细设计/pure-详细设计.md" <<EOF
# pure 详细设计

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

## §10 依赖项
无。

## §10.3 资源与补偿链
无受管资源。

## §8 验收标准（零结果）（追溯矩阵在存量位置，s2 回退读取）
<!-- anchor: acceptance-traceability -->
| M-01-F01-A01 | docs/prd-pure.md#L1 | — | — | — | R1 | TC-PURE-001 | COMPLETE |
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
(cd "$WS2" && WORKSPACE="$WS2" bash "$ROOT/scripts/devflow-state.sh" init pure --frontend=not-applicable >/dev/null 2>&1)
# 负向先跑：正文残留花括号变量 → s2 FAIL（A16）
cp "$WS2/docs/详细设计/pure-详细设计.md" "$WS2/docs/详细设计/pure-详细设计.md.bak"
printf '\n操作前置条件：{业务方填写}\n' >> "$WS2/docs/详细设计/pure-详细设计.md"
S2_A16=$(cd "$WS2" && bash "$ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/pure-详细设计.md docs/需求/pure-验收点.md 2>&1 || true)
printf '%s' "$S2_A16" | grep -q "unreplaced template variables" && ok "s2 rejects unreplaced brace placeholder (A16)" || bad "s2 missed brace placeholder (A16)"
mv "$WS2/docs/详细设计/pure-详细设计.md.bak" "$WS2/docs/详细设计/pure-详细设计.md"
# 正向：无表/无接口的纯计算设计 → s2 通过（五列/六列豁免，A06）
S2_PURE=$(cd "$WS2" && bash "$ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/pure-详细设计.md docs/需求/pure-验收点.md 2>&1 || true)
if (cd "$WS2" && bash "$ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/pure-详细设计.md docs/需求/pure-验收点.md >/dev/null 2>&1); then
  ok "s2 accepts legal no-table/no-API design (A06)"
else
  bad "s2 still rejects legal pure-compute design (A06): $(printf '%s' "$S2_PURE" | grep '\[P0\]' | head -3 | tr '\n' ' ')"
fi
printf '%s' "$S2_PURE" | grep -q "exempted" && ok "s2 reports five/six-column exemption (A06)" || bad "s2 exemption reporting missing"
# 负向：冻结 frontend 漂移（state=not-applicable，design.json 声明 pc-web）→ P0
"${DEVFLOW_PY[@]}" -c "import json; p='$WS2/.devflow/pure/design.json'; d=json.load(open(p)); d['client']={'scope':'pc-web','journeys':[{'name':'x','page':'§7.1.1','evidence':'真实浏览器'}]}; d['zero_results']=[z for z in d['zero_results'] if z['path']!='pages']; d['pages']=[{'anchor':'§7.1.1','name':'计算页','permission':'pure:view'}]; json.dump(d, open(p,'w'), ensure_ascii=False)"
printf '\n### 7.1 计算页\n计算页正文与权限说明。\n' >> "$WS2/docs/详细设计/pure-详细设计.md"
S2_DRIFT=$(cd "$WS2" && bash "$ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/pure-详细设计.md docs/需求/pure-验收点.md 2>&1 || true)
printf '%s' "$S2_DRIFT" | grep -q "client scope drift" && ok "s2 rejects frozen frontend drift (A06)" || bad "s2 missed client scope drift (A06)"

# ---------- CODE-BASELINE 探针（报告§5：新增基线探针，避免与流程阶段 P7 同名） ----------
WCB="$WORK/cb"; mkdir -p "$WCB/docs/detailed-design" "$WCB/docs/requirements" "$WCB/docs/review" "$WCB/.devflow/cb"
WORKSPACE="$WCB" bash "$ROOT/scripts/devflow-state.sh" init cb --frontend=not-applicable >/dev/null 2>&1
printf '# d\n## §1 概览\n含 REUSE/MODIFY 基线的设计。\n' > "$WCB/docs/detailed-design/cb-design.md"
printf '# c\n| M-01-F01-A01 | FROZEN |\n' > "$WCB/docs/requirements/cb-acceptance-criteria.md"
printf '# review\n' > "$WCB/docs/review/cb-design-review-report.md"
printf '{"feature":"cb","baseline":{"repo_root":".","entries":[{"id":"BL-1","target":"backend/x/Foo.java","decision":"MODIFY","existing_contract":"x","verify":"t"}]}}\n' \
  > "$WCB/.devflow/cb/design.json"
gj_copy_sample design-review cb "$WCB"
CB_OUT=$(cd "$WCB" && bash "$ROOT/scripts/p2a_design_review_gate.sh" cb 2>&1 || true)
printf '%s' "$CB_OUT" | grep -q "CODE-BASELINE execution row missing" \
  && ok "p2a requires CODE-BASELINE probe when baseline has MODIFY (A02/§5)" \
  || bad "p2a CODE-BASELINE probe not enforced"
printf '| CODE-BASELINE | 架构师+后端专家 | 不适用（改为核验 §1） | 证据：§1 |\n' >> "$WCB/docs/review/cb-design-review-report.md"
CB_OUT2=$(cd "$WCB" && bash "$ROOT/scripts/p2a_design_review_gate.sh" cb 2>&1 || true)
printf '%s' "$CB_OUT2" | grep -q "CODE-BASELINE execution row missing" \
  && bad "CODE-BASELINE answered row still rejected" \
  || ok "answered CODE-BASELINE row accepted (A02/§5)"
# v3.24.0(A13)：严重性修订纪律——无理由降级（P0→P2）直接 P0
cat >> "$WCB/docs/review/cb-design-review-report.md" <<'EOF'

## 严重性修订

| # | 原 DF | 原严重性 | 修订后严重性 | 修订理由 | 确认评委 |
|---|--------|----------|--------------|----------|----------|
| 1 | DF-01 | P0 | P2 | | |
EOF
CB_OUT3=$(cd "$WCB" && bash "$ROOT/scripts/p2a_design_review_gate.sh" cb 2>&1 || true)
printf '%s' "$CB_OUT3" | grep -q "severity revisions without reason" \
  && ok "downgrade without reason/confirmer rejected (A13)" \
  || bad "severity downgrade not policed"
# 补全理由与确认评委后放行
sed -i '' 's/| 1 | DF-01 | P0 | P2 | |/| 1 | DF-01 | P0 | P2 | 经复核确认为表层提示 | 评审主持人 |/' \
  "$WCB/docs/review/cb-design-review-report.md" 2>/dev/null || \
  sed -i 's/| 1 | DF-01 | P0 | P2 | |/| 1 | DF-01 | P0 | P2 | 经复核确认为表层提示 | 评审主持人 |/' \
  "$WCB/docs/review/cb-design-review-report.md"
CB_OUT4=$(cd "$WCB" && bash "$ROOT/scripts/p2a_design_review_gate.sh" cb 2>&1 || true)
printf '%s' "$CB_OUT4" | grep -q "severity revisions without reason" \
  && bad "documented downgrade still rejected" \
  || ok "documented downgrade with reason+confirmer accepted (A13)"

# ---------- A15：缺陷级断言升级（错误信息必须点名被变异对象） ----------
assert_out "does-not-exist.md" "PRD negative names the broken source path (A15)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input d-prdmiss.json --criteria criteria.md
assert_out "NotFound.java" "baseline negative names the fictional target (A15)" \
  bash -c "cd '$WSA' && \$DEVFLOW_PY_STR '$V' --kind design --input miss.json --criteria '$WSA/docs/requirements/demo-pay-acceptance-criteria.md' --workspace ."
assert_out "BOOLEAN" "type-conflict negative names the conflicting type (A15)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input design.json --criteria criteria.md --doc doc-typeconflict.md

# ---------- A14：s1 事实源元数据（来源/时点/适用范围） ----------
WSM="$WORK/s1meta"; mkdir -p "$WSM/docs/detailed-design"
WORKSPACE="$WSM" bash "$ROOT/scripts/devflow-state.sh" init s1m --frontend=not-applicable >/dev/null 2>&1
for f in _commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md; do
  printf '# %s\n1\n2\n3\n4\n5\n6\n7\n' "$f" > "$WSM/docs/detailed-design/$f"
done
S1M_OUT=$(cd "$WSM" && bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design 2>&1 || true)
printf '%s' "$S1M_OUT" | grep -q "缺事实源元数据块" \
  && ok "s1 warns fact sources without source/as_of/scope metadata (A14)" \
  || bad "s1 metadata warn missing"
for f in _commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md; do
  printf '<!-- DEVFLOW:FACT-SOURCE\nsource=代码走查\nas_of=2026-09-17\nscope=全局\n-->\n' >> "$WSM/docs/detailed-design/$f"
done
S1M_OUT2=$(cd "$WSM" && bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design 2>&1 || true)
printf '%s' "$S1M_OUT2" | grep -q "all fact sources carry source/as_of/scope metadata" \
  && ok "s1 metadata complete after DEVFLOW:FACT-SOURCE blocks (A14)" \
  || bad "s1 metadata completion not detected"

# ---------- P0：check_design_doc_quality.py 三类闭环（引用/规则/接口消费） ----------
DQL="$WORK/dql"; mkdir -p "$DQL"
cat > "$DQL/design.md" <<'EOF'
# 设计

## §3 业务规则
| 规则编号 | 规则描述 |
|---|---|
| R1 | 输入校验 |
| R2 | 幂等控制 |

## §5.3.1 创建
见 §3。

## §5.3.2 删除
详见 §3。

## §6 流程
WHEN 创建 (cmd): [R1]
  1. 校验

## §7.2 关键页面交互设计

> 页组在子小节内列出调用接口。

### 7.2.1 列表页交互

| 页面 | 接口 |
|---|---|
| 列表 | §5.3.1 |
EOF
DQ="$ROOT/scripts/check_design_doc_quality.py"
printf '%s' '{"api_detail_parent": "5.3"}' > "$DQL/rules-default.json"
DQ_OUT=$("${DEVFLOW_PY[@]}" "$DQ" "$DQL/design.md" --rules "$DQL/rules-default.json" 2>&1 || true)
printf '%s' "$DQ_OUT" | grep -q "DQ-002" && printf '%s' "$DQ_OUT" | grep -q "DQ-003" \
  && ok "lint catches unreferenced rule + unconsumed API detail" \
  || bad "lint missed violations: $DQ_OUT"
printf '%s' "$DQ_OUT" | grep -q "DQ-001" && bad "valid §3 ref falsely flagged" || ok "valid § cross-ref not flagged"
cat > "$DQL/rules.json" <<'EOF'
{"api_detail_parent": "5.3", "rules_without_flow_ref": ["R2"], "internal_endpoints": ["5.3.2"]}
EOF
check_rc 0 "lint passes with project rules whitelist" \
  "${DEVFLOW_PY[@]}" "$DQ" "$DQL/design.md" --rules "$DQL/rules.json" --root "$WORK"

# ---------- P1-b：P3c/P3d JSON 正本接线（waiver 路径正/负向） ----------
WP3="$WORK/p3"; mkdir -p "$WP3/.devflow/p3f" "$WP3/docs/评审" "$WP3/docs/测试"
printf 'P3CD_SECURITY=NOT_APPLICABLE\nP3CD_PERFORMANCE=NOT_APPLICABLE\n' > "$WP3/waiver.txt"
# v3.28.4(P0-4)：waiver 纳入 skip-log 授权契约——waiver 文件 + skip-log 授权行缺一即 P0
printf 'SKIP_P3CD_SECURITY=纯前端无安全面|authorized-by=user|at=2026-09-17|approval=slack-approval-001\nSKIP_P3CD_PERFORMANCE=无服务端目录|authorized-by=user|at=2026-09-17|approval=slack-approval-002\n' > "$WP3/.devflow/p3f/skip-log.txt"
"${DEVFLOW_PY[@]}" - "$WP3" <<'PYEOF'
import json, os, sys
os.chdir(sys.argv[1])
sec = {"feature": "p3f", "generated_at": "2026-09-17T00:00:00Z",
       "template": {"id": "安全审计-模板", "version": "1"},
       "write_operations_total": 0, "preauthorize_coverage": 100, "findings": [],
       "report_path": "docs/评审/p3f-安全审计报告.md",
       "zero_results": [{"path": "findings", "reason": "无写操作无发现"}]}
perf = {"feature": "p3f", "generated_at": "2026-09-17T00:00:00Z",
        "template": {"id": "性能审计-模板", "version": "1"},
        "scenarios": [{"name": "核心查询", "p95_ms": 380, "threshold_ms": 500, "status": "PASS"}],
        "nplus1_suspicious": 0, "conclusion": "达标",
        "report_path": "docs/测试/p3f-压测报告.md", "zero_results": []}
os.makedirs("docs/评审", exist_ok=True)
os.makedirs("docs/测试", exist_ok=True)
json.dump(sec, open(".devflow/p3f/security.json", "w"), ensure_ascii=False)
json.dump(perf, open(".devflow/p3f/performance.json", "w"), ensure_ascii=False)
PYEOF
# v3.25.2(P0)：报告由 df_pipeline 从 JSON 正本渲染（渲染器 + 管线端到端）
check_rc 0 "pipeline security renders audit report (P0-fix)" \
  bash -c "cd '$WP3' && \$DEVFLOW_PY_STR '$ROOT/scripts/df_pipeline.py' security --input .devflow/p3f/security.json --out docs/评审/p3f-安全审计报告.md"
check_rc 0 "pipeline performance renders load-test report (P0-fix)" \
  bash -c "cd '$WP3' && \$DEVFLOW_PY_STR '$ROOT/scripts/df_pipeline.py' performance --input .devflow/p3f/performance.json --out docs/测试/p3f-压测报告.md"
grep -q "P95 380 ms" "$WP3/docs/测试/p3f-压测报告.md" && ok "performance renderer emits machine P95 lines" || bad "performance renderer missing P95 lines"
P3_OUT=$(cd "$WP3" && bash "$ROOT/scripts/p3_security_perf_gate.sh" p3f --waiver waiver.txt 2>&1 || true)
if (cd "$WP3" && bash "$ROOT/scripts/p3_security_perf_gate.sh" p3f --waiver waiver.txt >/dev/null 2>&1); then
  ok "p3 gate passes with valid security/performance JSON (P1-b)"
else
  bad "p3 gate rejected valid JSONs: $(printf '%s' "$P3_OUT" | grep '\[P0\]' | head -3 | tr '\n' ' ')"
fi
grep -q "SECURITY_JSON_SHA256=" "$WP3/.devflow/p3f/gates/P3cd/receipt.txt" \
  && grep -q "PERFORMANCE_JSON_SHA256=" "$WP3/.devflow/p3f/gates/P3cd/receipt.txt" \
  && ok "P3cd receipt binds both JSON SHAs (P1-b)" || bad "P3cd receipt missing JSON binding"
grep -q "EVIDENCE_TREE_SHA256=" "$WP3/.devflow/p3f/gates/P3cd/receipt.txt" \
  && ok "P3cd receipt carries evidence tree (P1)" || bad "P3cd receipt missing evidence tree"
# v3.25.2(P1)：Gate 后替换 JSON → audit-receipts 证据树重验必须 FAIL（孤立 SHA 时代的漏洞关闭）
if (cd "$WP3" && bash "$ROOT/scripts/audit-receipts.sh" p3f .devflow docs >/dev/null 2>&1); then
  ok "audit passes before tamper (baseline)"
else
  bad "audit fails before any tamper (环境问题)"
fi
printf '\n{\n  "id": "SEC-99",\n  "severity": "P2",\n  "status": "CLOSED",\n  "title": "事后注入",\n  "evidence": "tamper"\n}\n' >> "$WP3/.devflow/p3f/security.json"
if (cd "$WP3" && bash "$ROOT/scripts/audit-receipts.sh" p3f .devflow docs >/dev/null 2>&1); then
  bad "post-gate security.json replacement NOT caught by audit (P1)"
else
  ok "post-gate security.json replacement caught by audit evidence tree (P1)"
fi
rm -f "$WP3/.devflow/p3f/security.json"
if (cd "$WP3" && bash "$ROOT/scripts/p3_security_perf_gate.sh" p3f --waiver waiver.txt >/dev/null 2>&1); then
  bad "p3 gate passed without security.json (bypass!)"
else
  ok "p3 gate rejects missing security.json even with waiver (P1-b)"
fi
# v3.25.2(P1)：性能双正本漂移——报告删掉 P95 机器行，Gate 必须与 JSON 对账拦截
"${DEVFLOW_PY[@]}" - "$WP3" <<'PYEOF'
import re, sys
from pathlib import Path
p = Path(sys.argv[1]) / "docs/测试/p3f-压测报告.md"
t = p.read_text(encoding="utf-8")
t = re.sub(r"P95 380 ms.*\n", "", t)
p.write_text(t, encoding="utf-8")
PYEOF
P3_DRIFT=$(cd "$WP3" && bash "$ROOT/scripts/p3_security_perf_gate.sh" p3f --waiver waiver.txt 2>&1 || true)
printf '%s' "$P3_DRIFT" | grep -qE "渲染产物不一致|双正本漂移" \
  && ok "perf report P95 drift vs JSON rejected (P1)" \
  || bad "perf dual-source drift not caught"

# ---------- v3.28.14：test_isolation 测试隔离策略必须 P2 冻结（m01-base 教训前置） ----------
cd "$WORK" || exit 1
"${DEVFLOW_PY[@]}" - <<'PYEOF'
import json, copy
src = json.load(open("design.json"))
variants = {}
d = copy.deepcopy(src); d.pop("test_isolation"); variants["ti-no-field"] = d
d = copy.deepcopy(src); d["test_isolation"].pop("strategy"); variants["ti-no-strategy"] = d
d = copy.deepcopy(src); d["test_isolation"] = {"applicable": False}; variants["ti-no-reason"] = d
for n, v in variants.items():
    json.dump(v, open(f"{n}.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "test_isolation 缺失被拒（P2 必须冻结隔离策略）" "${DEVFLOW_PY[@]}" "$V" --kind design --input ti-no-field.json --criteria criteria.md --doc doc.md
check_rc 1 "test_isolation applicable=true 缺 strategy 被拒" "${DEVFLOW_PY[@]}" "$V" --kind design --input ti-no-strategy.json --criteria criteria.md --doc doc.md
check_rc 1 "test_isolation applicable=false 缺 not_applicable_reason 被拒" "${DEVFLOW_PY[@]}" "$V" --kind design --input ti-no-reason.json --criteria criteria.md --doc doc.md

echo "=== design contract hardening RESULT PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
