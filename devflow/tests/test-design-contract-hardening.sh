#!/usr/bin/env bash
# test-design-contract-hardening.sh · v3.24.0 详设体系体检报告修复回归
# 每条负向断言从"能通过完整链路的合法样本"变异单一因素（报告 A15 要求），
# 覆盖体检报告 A01-A09/A16 的可执行修复：
#   A01 业务操作覆盖闭环；A02 基线工作区反查；A03 JSON↔正文对账/空壳拦截；
#   A04 PRD 来源/嵌套锚点；A06 无表无接口豁免+冻结 frontend 对账；A07 块注册表；
#   A08 p2a 表格解析；A09/A14 深度契约静态钉；A16 花括号占位。
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
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
check_rc 0 "baseline sample validates without workspace markers" python3 "$V" --kind design --input design.json --criteria criteria.md --doc doc.md

# ---------- A07：块注册表 13 块同源 ----------
BLOCKS="summary trace-matrix table-index api-index permission-matrix rule-index biz-ops client-scope zero-results ddr-index ddr-matrix resource-operations integrations-configs"
NB=0
for b in $BLOCKS; do NB=$((NB+1)); done
for t in "详细设计-完整版-模板.md" "详细设计-总分总文档-模板.md" "详细设计-总分分文档-模板.md"; do
  _miss=""
  for b in $BLOCKS; do
    grep -q "df:begin:$b" "$ROOT/templates/$t" || _miss="$_miss $b"
  done
  [ -z "$_miss" ] && ok "template carries all $NB render blocks: $t" || bad "template missing blocks ($_miss): $t"
done
# init-doc 初始化入口
check_rc 0 "init-doc creates skeleton" python3 "$R" design --input design.json --init-doc fresh-skeleton.md
for b in $BLOCKS; do
  grep -q "df:begin:$b" fresh-skeleton.md || bad "init-doc skeleton missing block $b"
done
ok "init-doc skeleton has all blocks"
check_rc 1 "init-doc refuses existing doc" python3 "$R" design --input design.json --init-doc fresh-skeleton.md
# 旧反例复现：只保留声明的 10 块（删 resource-operations/integrations-configs）→ 渲染失败关闭且报缺块
python3 - <<'PYEOF'
from pathlib import Path
t = Path("fresh-skeleton.md").read_text(encoding="utf-8")
for k in ("resource-operations", "integrations-configs"):
    t = t.replace(f"<!-- df:begin:{k} -->\n<!-- df:end:{k} -->", "")
Path("ten-blocks.md").write_text(t, encoding="utf-8")
PYEOF
check_rc 1 "10-block doc fails closed (registry mismatch, A07)" python3 "$R" design --input design.json --doc ten-blocks.md
assert_out "resource-operations" "missing-block error names the undeclared block (A07)" python3 "$R" design --input design.json --doc ten-blocks.md
# 13 块骨架 → 管线全链路（校验+渲染）
check_rc 0 "13-block skeleton renders via renderer (A07)" python3 "$R" design --input design.json --doc fresh-skeleton.md
grep -q "df:begin:biz-ops" fresh-skeleton.md && grep -q "BOP-1\|创建支付订单" fresh-skeleton.md && ok "biz-ops block rendered (A01)" || bad "biz-ops block rendered"

# ---------- A01：业务操作覆盖闭环 ----------
python3 - <<'PYEOF'
import json
d = json.load(open("design.json")); d["business_operations"].pop()   # 删掉覆盖 M01-F02-A01 的退款操作
json.dump(d, open("d-bopgap.json", "w"), ensure_ascii=False)
e = json.load(open("design.json"))
e["business_operations"][0]["stateless"] = False; e["business_operations"][0].pop("source_state", None)
json.dump(e, open("d-bopstate.json", "w"), ensure_ascii=False)
PYEOF
assert_out "覆盖缺口" "missing restore/refund operation caught as coverage gap (A01)" \
  python3 "$V" --kind design --input d-bopgap.json --criteria criteria.md
assert_out "source_state" "stateful op without source_state rejected (A01)" \
  python3 "$V" --kind design --input d-bopstate.json --criteria criteria.md

# ---------- A02：基线工作区反查 ----------
WSA="$WORK/ws-a"; mkdir -p "$WSA/backend/x/src/main/java" "$WSA/docs/requirements"
printf 'class FooController {}\n' > "$WSA/backend/x/src/main/java/FooController.java"
cp criteria.md "$WSA/docs/requirements/demo-pay-acceptance-criteria.md"
touch "$WSA/pom.xml"   # 工程标志：启用全仓反查
python3 - <<'PYEOF'
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
  bash -c "cd '$WSA' && python3 '$V' --kind design --input base.json --criteria '$WSA/docs/requirements/demo-pay-acceptance-criteria.md' --workspace ."
assert_out "目标文件不存在" "fictional MODIFY target rejected in real workspace (A02)" \
  bash -c "cd '$WSA' && python3 '$V' --kind design --input miss.json --criteria '$WSA/docs/requirements/demo-pay-acceptance-criteria.md' --workspace ."

# ---------- A03：JSON↔正文对账 + 空壳拦截 ----------
# 正文 §2.1 注入五列表，order_no 类型与 JSON 冲突（BOOLEAN vs VARCHAR(64)）
python3 - <<'PYEOF'
from pathlib import Path
t = Path("doc.md").read_text(encoding="utf-8")
table = "\n| 字段名 | 类型 | 约束 | 默认值 | 口径说明 |\n|---|---|---|---|---|\n| order_no | BOOLEAN | PK | — | 冲突类型 |\n"
t = t.replace("### 2.1 支付订单表（pay_order）\n", "### 2.1 支付订单表（pay_order）\n" + table, 1)
Path("doc-typeconflict.md").write_text(t, encoding="utf-8")
PYEOF
assert_out "冲突" "JSON type vs doc table type conflict rejected (A03)" \
  python3 "$V" --kind design --input design.json --criteria criteria.md --doc doc-typeconflict.md
# 字段从正文表格消失（正文有表但缺该字段）
python3 - <<'PYEOF'
from pathlib import Path
t = Path("doc-typeconflict.md").read_text(encoding="utf-8")
t = t.replace("| order_no | BOOLEAN | PK | — | 冲突类型 |\n", "| ref_no | BOOLEAN | PK | — | 另一字段 |\n", 1)
Path("doc-nofield.md").write_text(t, encoding="utf-8")
PYEOF
assert_out "未出现在" "JSON field missing from doc table rejected (A03)" \
  python3 "$V" --kind design --input design.json --criteria criteria.md --doc doc-nofield.md
# 仅标题空壳正文
python3 - <<'PYEOF'
import re
from pathlib import Path
t = Path("doc.md").read_text(encoding="utf-8")
t = re.sub(r"(### 2\.1 支付订单表（pay_order）\n)(.*?)(### 2\.2)", r"\1\3", t, flags=re.S)
t = re.sub(r"(### 7\.1 下单页\n)(.*?)(### 7\.2)", r"\1\3", t, flags=re.S)
Path("doc-hollow.md").write_text(t, encoding="utf-8")
PYEOF
assert_out "空壳" "headings-only section rejected as hollow (A03)" \
  python3 "$V" --kind design --input design.json --criteria criteria.md --doc doc-hollow.md

# ---------- A04：PRD 来源存在 + 嵌套锚点 ----------
python3 - <<'PYEOF'
import json
d = json.load(open("design.json"))
d["acceptance"][0]["prd_anchor"] = "does-not-exist.md#L99999"
json.dump(d, open("d-prdmiss.json", "w"), ensure_ascii=False)
e = json.load(open("design.json"))
e["apis"][0]["request"]["anchor"] = "§9.9.9"
json.dump(e, open("d-nested.json", "w"), ensure_ascii=False)
PYEOF
assert_out "来源文件不存在" "nonexistent PRD source rejected (A04)" \
  python3 "$V" --kind design --input d-prdmiss.json --criteria criteria.md
assert_out "嵌套引用断链" "dangling nested request anchor rejected (A04)" \
  python3 "$V" --kind design --input d-nested.json --criteria criteria.md --doc doc.md

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

## §0 总分架构决策
单体模式：单模块纯计算。

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

## §11 需求追溯与覆盖率基线
<!-- anchor: acceptance-traceability -->
| M-01-F01-A01 | docs/prd-pure.md#L1 | — | — | — | R1 | TC-PURE-001 | COMPLETE |
设计覆盖率 = 100%

## §12 组件复用与公共抽取
<!-- anchor: component-reuse -->
<!-- anchor: common-extraction -->
无新增复用与抽取（纯标准库计算）。

## §13 规范遵循
<!-- anchor: standards-compliance -->
遵循阿里巴巴 Java 开发手册；无偏离。

## §14 实现交接（Implementation Handoff）
<!-- anchor: implementation-handoff -->
| 文件/符号 | ADD/MODIFY/DELETE | 设计依据 | 验收点 |
|---|---|---|---|
| backend/pure/CalcService.java | ADD | §6 | M-01-F01-A01 |

## §15 变更历史
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
python3 -c "import json; p='$WS2/.devflow/pure/design.json'; d=json.load(open(p)); d['client']={'scope':'pc-web','journeys':[{'name':'x','page':'§7.1','evidence':'真实浏览器'}]}; d['zero_results']=[z for z in d['zero_results'] if z['path']!='pages']; d['pages']=[{'anchor':'§7.1','name':'计算页','permission':'pure:view'}]; json.dump(d, open(p,'w'), ensure_ascii=False)"
printf '\n### 7.1 计算页\n计算页正文与权限说明。\n' >> "$WS2/docs/详细设计/pure-详细设计.md"
S2_DRIFT=$(cd "$WS2" && bash "$ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/pure-详细设计.md docs/需求/pure-验收点.md 2>&1 || true)
printf '%s' "$S2_DRIFT" | grep -q "client scope drift" && ok "s2 rejects frozen frontend drift (A06)" || bad "s2 missed client scope drift (A06)"

echo "=== design contract hardening RESULT PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
