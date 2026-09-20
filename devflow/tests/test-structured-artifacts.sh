#!/usr/bin/env bash
# test-structured-artifacts.sh · 结构化业务产物层（v3.17.0）回归测试
# 覆盖：df_validate / df_render / df_pipeline 的失败关闭语义与跨字段检查。
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
PASS=0
FAIL=0
ok() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
check_rc() { # <expect-rc> <desc> <cmd...>
  local expect="$1" desc="$2"; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  [ "$rc" = "$expect" ] && ok "$desc (exit=$rc)" || bad "$desc (expect=$expect got=$rc)"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devflow-sbal-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
V="$ROOT/scripts/df_validate.py"
P="$ROOT/scripts/df_pipeline.py"

echo "=== structured business artifact layer tests ==="

# 0. 组件与契约文件存在
for f in scripts/df_validate.py scripts/df_render.py scripts/df_pipeline.py \
         schemas/design.schema.json schemas/verification.schema.json \
         examples/structured/design.sample.json examples/structured/verification.sample.json; do
  [ -f "$ROOT/$f" ] && ok "artifact exists: $f" || bad "missing artifact: $f"
done

# 1. 样例正向：validate / render / pipeline 全链路（design）
cd "$WORK" || exit 1
cp "$ROOT/examples/structured/design.sample.json" design.json
cp "$ROOT/examples/structured/design.skeleton.md" doc.md
cp "$ROOT/examples/structured/数据库设计决策.skeleton.md" dbdoc.md
cp "$ROOT/examples/structured/需求追溯.skeleton.md" tracedoc.md
printf 'M01-F01-A01\nM01-F01-A02\nM01-F02-A01\n' > /dev/null
cat > criteria.md <<'EOF'
| M01-F01-A01 | x |
| M01-F01-A02 | x |
| M01-F02-A01 | x |
EOF
# v3.24.0(A04)：prd_anchor 来源文件必须真实存在——样例锚点指向 docs/requirements/ 下
mkdir -p docs/requirements && cp criteria.md docs/requirements/demo-pay-acceptance-criteria.md
check_rc 0 "sample design validates" python3 "$V" --kind design --input design.json --criteria criteria.md
check_rc 0 "sample design pipeline renders into skeleton" python3 "$P" design --input design.json --doc doc.md --criteria criteria.md --db-doc dbdoc.md --trace-doc tracedoc.md
grep -q "覆盖率：3/3 = 100%，全部验收点都完成了设计" tracedoc.md && ok "human-readable coverage line rendered" || bad "human-readable coverage line rendered"
grep -q "df:begin:trace-matrix" tracedoc.md && grep -q "M01-F02-A01" tracedoc.md && ok "trace matrix spliced" || bad "trace matrix spliced"

# 2. 骨架缺锚点块 → 渲染失败关闭（不静默跳过、不落盘）
cp "$ROOT/examples/structured/design.skeleton.md" partial.md
python3 - <<'PYEOF'
from pathlib import Path
lines = Path("partial.md").read_text(encoding="utf-8").splitlines(keepends=True)
Path("partial.md").write_text(
    "".join(ln for ln in lines if "df:begin:summary" not in ln and "df:end:summary" not in ln),
    encoding="utf-8",
)
PYEOF
cp partial.md partial.before
check_rc 1 "missing anchor block fails closed (render)" python3 "$P" design --input design.json --doc partial.md --criteria criteria.md
cmp -s partial.md partial.before && ok "partial skeleton untouched after failed render" || bad "partial skeleton untouched after failed render"

# 3. design 反向：孤儿表 / 引用断链 / 零结果未声明 / 占位话术
python3 - <<'PYEOF'
import json
d = json.load(open("design.json"))
d["tables"].append({"anchor": "§2.9", "name": "orphan_log", "fields": [{"name": "id", "type": "BIGINT", "constraint": "PK", "default": "-", "note": "x"}]})
json.dump(d, open("d-orphan.json", "w"), ensure_ascii=False)
e = json.load(open("design.json"))
e["acceptance"][0]["data"] = "§2.99"
json.dump(e, open("d-broken-ref.json", "w"), ensure_ascii=False)
f = json.load(open("design.json"))
f["zero_results"] = []
json.dump(f, open("d-zero.json", "w"), ensure_ascii=False)
g = json.load(open("design.json"))
g["rules"][0]["summary"] = "幂等（待补充细节）"
json.dump(g, open("d-ph.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "orphan table rejected without unreferenced_reason" python3 "$V" --kind design --input d-orphan.json --criteria criteria.md
check_rc 0 "orphan accepted with unreferenced_reason" bash -c "python3 -c \"import json;d=json.load(open('d-orphan.json'));d['tables'][-1]['unreferenced_reason']='共享日志表';d['tables'][-1]['fields']=[{'name':'id','type':'BIGINT','constraint':'PK','default':'-','note':'x','ddr':['DDR-1']}];json.dump(d,open('d-orphan2.json','w'),ensure_ascii=False)\" && python3 '$V' --kind design --input d-orphan2.json --criteria criteria.md"
check_rc 1 "broken anchor reference rejected" python3 "$V" --kind design --input d-broken-ref.json --criteria criteria.md
check_rc 1 "undeclared empty collection rejected" python3 "$V" --kind design --input d-zero.json --criteria criteria.md
check_rc 1 "placeholder wording rejected" python3 "$V" --kind design --input d-ph.json --criteria criteria.md
check_rc 1 "criteria set inequality rejected" bash -c "printf '| M01-F01-A01 |\n' > few.md && python3 '$V' --kind design --input design.json --criteria few.md"

# 3b. v3.17.1: 接口概览↔详细定义闭环 + DDR↔字段一一对应（v3.28.1：DDR 在数据库设计决策文档）
grep -q "df:begin:ddr-index" dbdoc.md && ok "db doc skeleton carries ddr blocks" || bad "db doc skeleton carries ddr blocks"
grep -q "df:begin:resource-operations" doc.md && grep -q "df:begin:integrations-configs" doc.md && ok "skeleton carries compensation/integration blocks" || bad "skeleton carries compensation/integration blocks"
grep -q "| pay_order | order_no | DDR-1 |" dbdoc.md && ok "ddr matrix rendered (field-level mapping)" || bad "ddr matrix rendered (field-level mapping)"
# 正向：含详细定义小节的文档通过（含文档对账）
check_rc 0 "design validates with --doc (overview↔detail closure)" python3 "$V" --kind design --input design.json --criteria criteria.md --doc doc.md
# 反向：概览有、详细定义缺
grep -v "3.2.2 创建退款单" doc.md > doc-missing.md
check_rc 1 "overview API without detail section rejected" python3 "$V" --kind design --input design.json --doc doc-missing.md
# 反向：文档多余小节未被概览收录
python3 - <<'PYEOF'
from pathlib import Path
t = Path("doc.md").read_text(encoding="utf-8")
Path("doc-extra.md").write_text(
    t.replace("#### 3.2.2 创建退款单", "#### 3.2.2 创建退款单\n\nx\n\n#### 3.2.3 导出对账单"),
    encoding="utf-8",
)
PYEOF
check_rc 1 "detail section missing from overview rejected" python3 "$V" --kind design --input design.json --doc doc-extra.md
# 反向：detail_anchor 重复
python3 - <<'PYEOF'
import json
d = json.load(open("design.json")); d["apis"][1]["detail_anchor"] = "§3.2.1"
json.dump(d, open("d-dup-anchor.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "duplicate detail_anchor rejected" python3 "$V" --kind design --input d-dup-anchor.json --doc doc.md
# 反向：字段漏 DDR / 悬空引用 / 孤儿决策（含豁免放行）
python3 - <<'PYEOF'
import json
d = json.load(open("design.json"))
d["tables"][0]["fields"][0]["ddr"] = []
json.dump(d, open("d-noddr.json", "w"), ensure_ascii=False)
e = json.load(open("design.json")); e["tables"][0]["fields"][0]["ddr"] = ["DDR-9"]
json.dump(e, open("d-dangling.json", "w"), ensure_ascii=False)
f = json.load(open("design.json")); f["decisions"].append({"id": "DDR-4", "topic": "全局命名", "reason": "统一蛇形命名"})
json.dump(f, open("d-orphan-ddr.json", "w"), ensure_ascii=False)
g = json.loads(json.dumps(f)); g["decisions"][-1]["unreferenced_reason"] = "全局规范，覆盖全部字段"
json.dump(g, open("d-orphan-ok.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "field without DDR reference rejected" python3 "$V" --kind design --input d-noddr.json --doc doc.md
check_rc 1 "dangling DDR reference rejected" python3 "$V" --kind design --input d-dangling.json --doc doc.md
check_rc 1 "orphan DDR without waiver rejected" python3 "$V" --kind design --input d-orphan-ddr.json --doc doc.md
check_rc 0 "orphan DDR with unreferenced_reason accepted" python3 "$V" --kind design --input d-orphan-ok.json --doc doc.md

# 3c. v3.27.9：页面规格结构化（route/component/page_type 必填 + §7.2/§7.3 对账 + 弹窗接口锚点闭环）
python3 - <<'PYEOF'
import json
d = json.load(open("design.json"))
a = json.loads(json.dumps(d)); del a["pages"][0]["route"]
json.dump(a, open("d-noroute.json", "w"), ensure_ascii=False)
b = json.loads(json.dumps(d)); b["pages"][0]["dialogs"][0]["api"] = "§3.9.9"
json.dump(b, open("d-dangling-dialog.json", "w"), ensure_ascii=False)
c = json.loads(json.dumps(d)); c["pages"][1]["table_columns"][0]["field"] = "ghostField"
json.dump(c, open("d-doc-drift.json", "w"), ensure_ascii=False)
e = json.loads(json.dumps(d)); e["pages"][0]["dialogs"][0]["component"] = "views/pay/GhostDialog.vue"
json.dump(e, open("d-dialog-drift.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "page missing route rejected (required)" python3 "$V" --kind design --input d-noroute.json --criteria criteria.md
check_rc 1 "dialog api anchor dangling rejected" python3 "$V" --kind design --input d-dangling-dialog.json --criteria criteria.md
check_rc 1 "table_columns field not in doc rejected" python3 "$V" --kind design --input d-doc-drift.json --criteria criteria.md --doc doc.md
check_rc 1 "dialog component not in doc row rejected" python3 "$V" --kind design --input d-dialog-drift.json --criteria criteria.md --doc doc.md
# 3c2. v3.28.1：链路列（列/控件→接口→表）机检——悬空即拒，闭环放行
python3 - <<'PYEOF'
import json
from pathlib import Path
d = json.load(open("design.json"))
a = json.loads(json.dumps(d))
a["pages"][1]["table_columns"][0]["api_field"] = "§3.2.1 orderId"
a["pages"][1]["table_columns"][0]["source"] = "pay_refund.refund_no"
json.dump(a, open("d-chain-ok.json", "w"), ensure_ascii=False)
b = json.loads(json.dumps(a)); b["pages"][1]["table_columns"][0]["api_field"] = "§3.9.9 orderId"
json.dump(b, open("d-chain-badapi.json", "w"), ensure_ascii=False)
c = json.loads(json.dumps(a)); c["pages"][1]["table_columns"][0]["source"] = "pay_refund.ghost"
json.dump(c, open("d-chain-badsrc.json", "w"), ensure_ascii=False)
e = json.loads(json.dumps(a)); e["pages"][0]["form_controls"][0]["submit_api"] = "§3.9.9"
json.dump(e, open("d-chain-badform.json", "w"), ensure_ascii=False)
t = Path("doc.md").read_text(encoding="utf-8")
t = t.replace("| orderNo | 订单号 | 文本；超长省略 | — ← — |",
              "| orderNo | 订单号 | 文本；超长省略 | §3.2.1 orderId ← pay_refund.refund_no |")
Path("doc-chain.md").write_text(t, encoding="utf-8")
PYEOF
check_rc 0 "page element → API → table chain resolves, doc row matches" python3 "$V" --kind design --input d-chain-ok.json --criteria criteria.md --doc doc-chain.md
CH_API=$(python3 "$V" --kind design --input d-chain-badapi.json --criteria criteria.md 2>&1 || true)
printf '%s' "$CH_API" | grep -q "链路断链" \
  && ok "dangling api_field anchor rejected (v3.28.1)" || bad "api_field closure missed: $CH_API"
CH_SRC=$(python3 "$V" --kind design --input d-chain-badsrc.json --criteria criteria.md 2>&1 || true)
printf '%s' "$CH_SRC" | grep -q "落库字段必须真实存在" \
  && ok "dangling source table field rejected (v3.28.1)" || bad "source closure missed: $CH_SRC"
check_rc 1 "dangling form submit_api rejected (v3.28.1)" python3 "$V" --kind design --input d-chain-badform.json --criteria criteria.md
# v3.28.1：全部弹窗/抽屉进 §7.1 清单——清单缺弹窗行即拒
python3 - <<'PYEOF'
from pathlib import Path
t = Path("doc.md").read_text(encoding="utf-8")
t = t.replace("| 3 | 支付 | 提交确认 | /pay/order/create | views/pay/SubmitConfirmDialog.vue | 弹窗（确认） | pay:order:create |\n", "")
Path("doc-nodialogrow.md").write_text(t, encoding="utf-8")
PYEOF
NDR_OUT=$(python3 "$V" --kind design --input design.json --criteria criteria.md --doc doc-nodialogrow.md 2>&1 || true)
printf '%s' "$NDR_OUT" | grep -q "未出现在 §7.1 页面清单表" \
  && ok "dialog missing from §7.1 inventory rejected (v3.28.1)" \
  || bad "dialog §7.1 inventory closure missed: $NDR_OUT"
# 3c3. v3.29.0：测试锚点——form_controls/dialogs 必填 test_anchor、全文档唯一、actions 闭环
python3 - <<'PYEOF'
import json
d = json.load(open("design.json"))
a = json.loads(json.dumps(d)); del a["pages"][0]["form_controls"][0]["test_anchor"]
json.dump(a, open("d-ta-missing.json", "w"), ensure_ascii=False)
b = json.loads(json.dumps(d)); b["pages"][0]["actions"].append(
    {"name": "重复按钮", "type": "工具栏", "test_anchor": b["pages"][0]["form_controls"][0]["test_anchor"]})
json.dump(b, open("d-ta-dup.json", "w"), ensure_ascii=False)
c = json.loads(json.dumps(d)); c["pages"][0]["actions"][0]["api"] = "§3.9.9"
json.dump(c, open("d-ta-badapi.json", "w"), ensure_ascii=False)
e = json.loads(json.dumps(d)); e["pages"][0]["actions"][0]["dialog"] = "不存在的弹窗"
json.dump(e, open("d-ta-baddialog.json", "w"), ensure_ascii=False)
f = json.loads(json.dumps(d)); f["pages"][0]["form_controls"][0]["test_anchor"] = "Bad_Anchor"
json.dump(f, open("d-ta-badfmt.json", "w"), ensure_ascii=False)
from pathlib import Path
t = Path("doc.md").read_text(encoding="utf-8")
t = t.replace("| pay-p1-input-amount |", "|")
Path("doc-no-ta.md").write_text(t, encoding="utf-8")
PYEOF
check_rc 1 "missing form_controls.test_anchor rejected (v3.29.0)" python3 "$V" --kind design --input d-ta-missing.json --criteria criteria.md
TA_DUP=$(python3 "$V" --kind design --input d-ta-dup.json --criteria criteria.md 2>&1 || true)
printf '%s' "$TA_DUP" | grep -q "测试锚点重复" \
  && ok "duplicate test_anchor rejected (v3.29.0)" || bad "test_anchor uniqueness missed: $TA_DUP"
TA_API=$(python3 "$V" --kind design --input d-ta-badapi.json --criteria criteria.md 2>&1 || true)
printf '%s' "$TA_API" | grep -q "操作接口引用断链" \
  && ok "actions.api dangling rejected (v3.29.0)" || bad "actions.api closure missed: $TA_API"
TA_DLG=$(python3 "$V" --kind design --input d-ta-baddialog.json --criteria criteria.md 2>&1 || true)
printf '%s' "$TA_DLG" | grep -q "触发弹窗/抽屉断链" \
  && ok "actions.dialog dangling rejected (v3.29.0)" || bad "actions.dialog closure missed: $TA_DLG"
TA_FMT=$(python3 "$V" --kind design --input d-ta-badfmt.json --criteria criteria.md 2>&1 || true)
printf '%s' "$TA_FMT" | grep -q "不匹配 pattern" \
  && ok "test_anchor bad naming rejected (v3.29.0)" || bad "test_anchor pattern missed: $TA_FMT"
TA_DOC=$(python3 "$V" --kind design --input design.json --criteria criteria.md --doc doc-no-ta.md 2>&1 || true)
printf '%s' "$TA_DOC" | grep -q "未出现在 §7.2 表单控件规格表对应行" \
  && ok "doc row without test_anchor rejected (v3.29.0)" || bad "test_anchor doc reconciliation missed: $TA_DOC"

# 3e. v3.28.1：表名/字段名保留字分层机检（fail→FAIL；warn→WARN 不阻断）
python3 - <<'PYEOF'
import json
d = json.load(open("design.json"))
a = json.loads(json.dumps(d)); a["tables"][0]["fields"][0]["name"] = "order"
json.dump(a, open("d-reserved-fail.json", "w"), ensure_ascii=False)
b = json.loads(json.dumps(d)); b["tables"][0]["fields"][0]["name"] = "status"
json.dump(b, open("d-reserved-warn.json", "w"), ensure_ascii=False)
PYEOF
RWF_OUT=$(python3 "$V" --kind design --input d-reserved-fail.json --criteria criteria.md 2>&1 || true)
printf '%s' "$RWF_OUT" | grep -q "命中数据库保留字（fail 层）" \
  && ok "reserved fail-tier field rejected (v3.28.1)" \
  || bad "reserved fail-tier not rejected: $RWF_OUT"
RWW_OUT=$(python3 "$V" --kind design --input d-reserved-warn.json --criteria criteria.md 2>&1 || true)
printf '%s' "$RWW_OUT" | grep -q "软关键字（warn 层）" \
  && ok "reserved warn-tier field warns without blocking (v3.28.1)" \
  || bad "reserved warn-tier warning missing: $RWW_OUT"

# 3d. v3.27.11：惰性字段接线（related_acceptance 闭环 / test_scenarios 非空 / 执行契约切片闭环）
python3 - <<'PYEOF'
import json
d = json.load(open("design.json"))
a = json.loads(json.dumps(d)); a["baseline"]["entries"][0]["related_acceptance"] = ["M-99-F99-A99"]
json.dump(a, open("d-relacc.json", "w"), ensure_ascii=False)
b = json.loads(json.dumps(d)); b["business_operations"][0]["test_scenarios"] = []
json.dump(b, open("d-noscen.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "baseline.related_acceptance dangling rejected" python3 "$V" --kind design --input d-relacc.json --criteria criteria.md
check_rc 1 "business_operations empty test_scenarios rejected" python3 "$V" --kind design --input d-noscen.json --criteria criteria.md
# 3d2. v3.28.1：错误码契约（重复/格式/正文出现）
python3 - <<'PYEOF'
import json
d = json.load(open("design.json"))
a = json.loads(json.dumps(d))
a["rules"][0]["error_codes"] = [{"code": "DUPLICATE_CODE", "meaning": "x"}]
a["rules"][1]["error_codes"] = [{"code": "DUPLICATE_CODE", "meaning": "y"}]
json.dump(a, open("d-ec-dup.json", "w"), ensure_ascii=False)
b = json.loads(json.dumps(d))
b["rules"][1]["error_codes"] = [{"code": "ghost_code", "meaning": "x"}]
json.dump(b, open("d-ec-format.json", "w"), ensure_ascii=False)
c = json.loads(json.dumps(d))
c["rules"][1]["error_codes"] = [{"code": "GHOST_CODE", "meaning": "x"}]
json.dump(c, open("d-ec-docmiss.json", "w"), ensure_ascii=False)
PYEOF
EC_DUP=$(python3 "$V" --kind design --input d-ec-dup.json --criteria criteria.md 2>&1 || true)
printf '%s' "$EC_DUP" | grep -q "错误码 DUPLICATE_CODE .*重复" \
  && ok "duplicate error code rejected (v3.28.1)" || bad "duplicate error code missed: $EC_DUP"
check_rc 1 "lowercase error code rejected by schema pattern" python3 "$V" --kind design --input d-ec-format.json --criteria criteria.md
EC_DOC=$(python3 "$V" --kind design --input d-ec-docmiss.json --criteria criteria.md --doc doc.md 2>&1 || true)
printf '%s' "$EC_DOC" | grep -q "错误码 GHOST_CODE 未出现在详设正文" \
  && ok "error code absent from doc rejected (v3.28.1)" || bad "error code doc closure missed: $EC_DOC"
cp "$ROOT/examples/structured/execution-plan.sample.json" ep.json
check_rc 0 "execution-plan sample validates" python3 "$V" --kind execution-plan --input ep.json
# 3d3. v3.28.1：执行契约 design_refs 锚点闭环
python3 - <<'PYEOF'
import json
d = json.load(open("ep.json"))
a = json.loads(json.dumps(d)); a["tasks"][0]["design_refs"] = ["not-anchor"]
json.dump(a, open("ep-ref-format.json", "w"), ensure_ascii=False)
b = json.loads(json.dumps(d)); b["tasks"][0]["design_refs"] = ["anchor: made-up"]
json.dump(b, open("ep-ref-unknown.json", "w"), ensure_ascii=False)
PYEOF
EP_FMT=$(python3 "$V" --kind execution-plan --input ep-ref-format.json 2>&1 || true)
printf '%s' "$EP_FMT" | grep -q "格式非法" \
  && ok "execution-plan malformed design_ref rejected (v3.28.1)" || bad "design_ref format missed: $EP_FMT"
EP_UNK=$(python3 "$V" --kind execution-plan --input ep-ref-unknown.json 2>&1 || true)
printf '%s' "$EP_UNK" | grep -q "不在语义锚点集合" \
  && ok "execution-plan unknown anchor rejected (v3.28.1)" || bad "design_ref anchor closure missed: $EP_UNK"
# 3d4. v3.28.1：规则锚点单一化——页组级共同锚点合法；通用锚点仍拒
python3 - <<'PYEOF'
import json
d = json.load(open("design.json"))
def five(anchor):
    rs = []
    for i in range(1, 6):
        r = {"id": f"R{i}", "anchor": anchor, "summary": f"规则{i}"}
        if i > 1: r["unreferenced_reason"] = "演示"
        rs.append(r)
    return rs
a = json.loads(json.dumps(d)); a["rules"] = five("§7.2.1")
json.dump(a, open("d-rules-page.json", "w"), ensure_ascii=False)
b = json.loads(json.dumps(d)); b["rules"] = five("§5")
json.dump(b, open("d-rules-generic.json", "w"), ensure_ascii=False)
PYEOF
check_rc 0 "rules sharing a page-group anchor accepted (v3.28.1)" python3 "$V" --kind design --input d-rules-page.json --criteria criteria.md --doc doc.md
RGEN=$(python3 "$V" --kind design --input d-rules-generic.json --criteria criteria.md --doc doc.md 2>&1 || true)
printf '%s' "$RGEN" | grep -q "锚点单一化" \
  && ok "rules piled on a generic anchor rejected (v3.28.1)" || bad "generic-anchor pileup missed: $RGEN"
python3 - <<'PYEOF'
import json
d = json.load(open("ep.json"))
a = json.loads(json.dumps(d)); a["slices"][0]["task_ids"] = ["T-999"]
json.dump(a, open("ep-bad.json", "w"), ensure_ascii=False)
b = json.loads(json.dumps(d)); b["slices"][0]["components"] = [""]
json.dump(b, open("ep-bad2.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "execution-plan slice task_id dangling rejected" python3 "$V" --kind execution-plan --input ep-bad.json
check_rc 1 "execution-plan empty component rejected" python3 "$V" --kind execution-plan --input ep-bad2.json

# 4. verification 正向：baseline 全等 + SHA 实算 + exec-record 对账
cp "$ROOT/examples/structured/verification.sample.json" verification.json
python3 - <<'PYEOF'
import json
d = json.load(open("verification.json"))
d["evidence"]["unit"]["report_sha256"] = ""
json.dump(d, open("verification.json", "w"), ensure_ascii=False)
PYEOF
for k in unit integration client load staging; do
  printf 'real report content for %s — 12 tests 0 failures\n' "$k" > "report-$k.txt"
done
printf 'unit run log: 12/12 passed\n' > unit.log
printf 'ID\tSTATUS\nM01-F01-A01\tPASS\nM01-F01-A02\tPASS\nM01-F02-A01\tPASS\n' > baseline.tsv
cat > exec.env <<'EOF'
UNIT_CMD=pytest -q
UNIT_ACTUAL_EXIT=0
INTEGRATION_CMD=mvn verify
INTEGRATION_ACTUAL_EXIT=0
CLIENT_CMD=npm run test:e2e
CLIENT_ACTUAL_EXIT=0
LOAD_CMD=jmeter -n -t plan.jmx
LOAD_ACTUAL_EXIT=0
STAGING_CMD=./scripts/smoke.sh staging
STAGING_ACTUAL_EXIT=0
EOF
SHA=$(shasum -a 256 report-unit.txt | awk '{print $1}')
python3 - "$SHA" <<'PYEOF'
import json, sys
d = json.load(open("verification.json"))
d["evidence"]["unit"]["report_sha256"] = sys.argv[1]
json.dump(d, open("verification.json", "w"), ensure_ascii=False)
PYEOF
check_rc 0 "sample verification validates with baseline + exec record" python3 "$V" --kind verification --input verification.json --baseline baseline.tsv --exec-record exec.env
check_rc 0 "verification pipeline renders report" python3 "$P" verification --input verification.json --out report.md --baseline baseline.tsv --exec-record exec.env
grep -q "共 3 个验收点：通过 3 个，未通过 0 个" report.md && ok "report stats in human language" || bad "report stats in human language"
grep -q "结论：全部通过，可以部署" report.md && ok "report conclusion sentence present" || bad "report conclusion sentence present"
grep -q "795d\|report-unit.txt" report.md && ok "evidence binding table rendered" || bad "evidence binding table rendered"

# 5. verification 反向：FAIL 行 / baseline 不等 / 假 SHA / 占位命令 / 退出码不一致 / 共用报告
python3 - <<'PYEOF'
import json
base = json.load(open("verification.json"))
a = json.loads(json.dumps(base)); a["acceptance_results"][0]["status"] = "FAIL"
json.dump(a, open("v-fail.json", "w"), ensure_ascii=False)
b = json.loads(json.dumps(base)); b["acceptance_results"].pop()
json.dump(b, open("v-less.json", "w"), ensure_ascii=False)
c = json.loads(json.dumps(base)); c["evidence"]["unit"]["report_sha256"] = "0" * 64
json.dump(c, open("v-sha.json", "w"), ensure_ascii=False)
e = json.loads(json.dumps(base)); e["evidence"]["load"]["cmd"] = "true"
json.dump(e, open("v-cmd.json", "w"), ensure_ascii=False)
f = json.loads(json.dumps(base)); f["evidence"]["staging"]["cmd"] = "bash -c 'echo ok'"
json.dump(f, open("v-wrap.json", "w"), ensure_ascii=False)
g = json.loads(json.dumps(base))
for k in ("integration", "client", "load", "staging"):
    g["evidence"][k]["report_path"] = "report-unit.txt"
json.dump(g, open("v-dup.json", "w"), ensure_ascii=False)
h = json.loads(json.dumps(base)); h["evidence"]["unit"]["exit_code"] = 0
json.dump(h, open("v-exit.json", "w"), ensure_ascii=False)
i = json.loads(json.dumps(base))
i["evidence"]["client"] = None; i["evidence"]["client"] = None
del i["evidence"]["client"]
i["client_not_applicable"] = {"declared": True, "frontend_scope": "pc-web", "reason": "无前端"}
json.dump(i, open("v-cna.json", "w"), ensure_ascii=False)
PYEOF
printf 'UNIT_CMD=pytest -q\nUNIT_ACTUAL_EXIT=2\nINTEGRATION_CMD=mvn verify\nINTEGRATION_ACTUAL_EXIT=0\nCLIENT_CMD=npm run test:e2e\nCLIENT_ACTUAL_EXIT=0\nLOAD_CMD=jmeter -n -t plan.jmx\nLOAD_ACTUAL_EXIT=0\nSTAGING_CMD=./scripts/smoke.sh staging\nSTAGING_ACTUAL_EXIT=0\n' > exec-bad.env
check_rc 1 "FAIL row rejected (FAIL=0 hard rule)" python3 "$V" --kind verification --input v-fail.json --baseline baseline.tsv
check_rc 1 "baseline set inequality rejected" python3 "$V" --kind verification --input v-less.json --baseline baseline.tsv
check_rc 1 "tampered report SHA rejected" python3 "$V" --kind verification --input v-sha.json --baseline baseline.tsv
check_rc 1 "placeholder cmd rejected" python3 "$V" --kind verification --input v-cmd.json --baseline baseline.tsv
check_rc 1 "shell wrapper cmd rejected" python3 "$V" --kind verification --input v-wrap.json --baseline baseline.tsv
check_rc 1 "shared report file rejected" python3 "$V" --kind verification --input v-dup.json --baseline baseline.tsv
check_rc 1 "declared exit != gate actual rejected" python3 "$V" --kind verification --input v-exit.json --baseline baseline.tsv --exec-record exec-bad.env
check_rc 1 "client waiver with wrong scope rejected" python3 "$V" --kind verification --input v-cna.json --baseline baseline.tsv

# 5b. v3.17.2 修复回归：H1 占位黑名单变体 / cmd 对账 / M1 伪造零结果 / M2 纯后端 / M3 标题宽容 / L5 / L7
python3 - <<'PYEOF'
import json
base = json.load(open("verification.json"))
variants = {
    "v-true-and.json": "true && echo pwned",
    "v-colon.json": ": > report-unit.txt",
    "v-ls.json": "ls -la; cat report-unit.txt",
    "v-bash-anywhere.json": "pytest && bash -c 'echo fake > report-unit.txt'",
}
for name, cmd in variants.items():
    d = json.loads(json.dumps(base)); d["evidence"]["load"]["cmd"] = cmd
    json.dump(d, open(name, "w"), ensure_ascii=False)
PYEOF
for v in v-true-and v-colon v-ls v-bash-anywhere; do
  check_rc 1 "placeholder variant rejected: $v" python3 "$V" --kind verification --input "$v.json" --baseline baseline.tsv
done
printf 'UNIT_CMD=pytest -q\nUNIT_ACTUAL_EXIT=0\nINTEGRATION_CMD=mvn verify\nINTEGRATION_ACTUAL_EXIT=0\nCLIENT_CMD=npm run test:e2e\nCLIENT_ACTUAL_EXIT=0\nLOAD_CMD=UNKNOWN\nLOAD_ACTUAL_EXIT=0\nSTAGING_CMD=./scripts/smoke.sh staging\nSTAGING_ACTUAL_EXIT=0\n' > exec-cmd-mismatch.env
check_rc 1 "declared cmd != gate cmd rejected" python3 "$V" --kind verification --input verification.json --baseline baseline.tsv --exec-record exec-cmd-mismatch.env
# CLIENT_EXEMPT 双向一致
python3 - <<'PYEOF'
import json
d = json.load(open("verification.json"))
del d["evidence"]["client"]
d["client_not_applicable"] = {"declared": True, "frontend_scope": "not-applicable", "reason": "纯后端服务"}
json.dump(d, open("v-exempt-ok.json", "w"), ensure_ascii=False)
e = json.loads(json.dumps(d)); e["client_not_applicable"] = {"declared": False, "frontend_scope": "pc-web"}
json.dump(e, open("v-exempt-bad.json", "w"), ensure_ascii=False)
PYEOF
printf 'UNIT_CMD=pytest -q\nUNIT_ACTUAL_EXIT=0\nINTEGRATION_CMD=mvn verify\nINTEGRATION_ACTUAL_EXIT=0\nLOAD_CMD=jmeter -n -t plan.jmx\nLOAD_ACTUAL_EXIT=0\nSTAGING_CMD=./scripts/smoke.sh staging\nSTAGING_ACTUAL_EXIT=0\nCLIENT_EXEMPT=1\n' > exec-exempt.env
check_rc 0 "CLIENT_EXEMPT=1 with matching declaration accepted" python3 "$V" --kind verification --input v-exempt-ok.json --baseline baseline.tsv --exec-record exec-exempt.env
check_rc 1 "CLIENT_EXEMPT=1 with contradicting declaration rejected" python3 "$V" --kind verification --input v-exempt-bad.json --baseline baseline.tsv --exec-record exec-exempt.env
# M1: 非空集合的伪造零结果声明
python3 - <<'PYEOF'
import json
d = json.load(open("design.json")); d["zero_results"].append({"path": "pages", "reason": "伪造"})
json.dump(d, open("d-forged-zero.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "forged zero-result declaration on non-empty collection rejected" python3 "$V" --kind design --input d-forged-zero.json --doc doc.md
# L7: 重复声明
python3 - <<'PYEOF'
import json
d = json.load(open("design.json")); z = d["zero_results"][0]
d["zero_results"].append(dict(z))
json.dump(d, open("d-dup-zero.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "duplicate zero-result path rejected" python3 "$V" --kind design --input d-dup-zero.json --doc doc.md
# M2: 纯后端 feature（pages/tables/apis 合法为空 + 声明）
# v3.24.0(A01/A02)：须含 business_operations 覆盖冻结验收点 + baseline 契约
cat > d-backend.json <<'EOF'
{
  "feature": "backend-only",
  "generated_at": "2026-09-12T00:00:00Z",
  "template": {"id": "详细设计-完整版-模板", "version": "1", "mode": "monolith"},
  "acceptance": [{"id": "M-01-F01-A01", "prd_anchor": "criteria.md#M-01-F01-A01", "page": "—", "api": "—", "data": "—", "rule": "R1", "test_case": "TC-B-001", "status": "COMPLETE"}],
  "tables": [], "apis": [], "pages": [],
  "rules": [{"id": "R1", "anchor": "§5", "summary": "校验"}],
  "business_operations": [{"id": "BOP-1", "name": "执行每日汇总", "trigger": "每日 02:00 定时触发", "actor": "调度系统", "stateless": true, "steps": ["读取上游输入", "计算并写出结果"], "result": "任务完成并写审计", "failure": "失败按退避重试并告警", "test_scenarios": ["正常汇总", "输入缺失跳过并告警"], "acceptance_refs": ["M-01-F01-A01"], "anchor": "§6.1"}],
  "baseline": {"repo_root": ".", "db_evidence": {"source": "none"}, "entries": [{"id": "BL-1", "target": "backend/job/SummaryJob.java", "decision": "ADD", "target_module": "job 模块（同类模式参照现有 ExportJob）", "verify": "SummaryJobTest"}]},
  "client": {"scope": "not-applicable", "not_applicable_reason": "纯后端"},
  "migrations": {"applicable": true, "dialects": ["h2", "postgresql", "oracle", "kingbase"]},
  "decisions": [{"id": "DDR-1", "topic": "全局命名", "reason": "统一规范", "unreferenced_reason": "无表字段"}],
  "zero_results": [{"path": "pages", "reason": "无前端"}, {"path": "apis", "reason": "纯内部定时任务"}, {"path": "tables", "reason": "复用既有表"}, {"path": "resources", "reason": "无跨请求资源占用"}, {"path": "operations", "reason": "无资源即无补偿链"}, {"path": "integrations", "reason": "无外部调用"}, {"path": "configs", "reason": "无新增配置键"}]
}
EOF
check_rc 0 "backend-only feature with declared-empty collections accepted" python3 "$V" --kind design --input d-backend.json --doc doc.md
# M3: 中文无空格标题 / 围栏内伪标题不误报
python3 - <<'PYEOF'
from pathlib import Path
t = Path("doc.md").read_text(encoding="utf-8")
t = t.replace("#### 3.2.1 创建支付订单", "#### §3.2.1创建支付订单")
t = t.replace("#### 3.2.2 创建退款单", "#### 3.2.2 创建退款单\n\n```\n#### 3.2.9 围栏内伪标题\n```")
Path("doc-m3.md").write_text(t, encoding="utf-8")
PYEOF
check_rc 0 "CJK no-space heading and fenced pseudo-heading accepted (M3)" python3 "$V" --kind design --input design.json --doc doc-m3.md
# L5: pipeline 空 --gate 报用法错误
check_rc 2 "pipeline empty --gate rejected" python3 "$P" design --input design.json --doc doc.md --criteria criteria.md --gate

# 5c. v3.19.0 七项修复回归
# (1) pipeline 无 baseline/exec-record → 拒（曾渲染假「可以部署」）
check_rc 2 "pipeline without baseline/exec-record rejected" python3 "$P" verification --input verification.json --out report-x.md
# (2) 空报告文件 → 拒（曾以空文件渲染「可以部署」）
mkdir -p empty-ws && cd empty-ws || exit 1
printf 'ID\tSTATUS\nM01-F01-A01\tPASS\nM01-F01-A02\tPASS\nM01-F02-A01\tPASS\n' > baseline.tsv
printf 'UNIT_CMD=pytest -q\nUNIT_ACTUAL_EXIT=0\nINTEGRATION_CMD=mvn verify\nINTEGRATION_ACTUAL_EXIT=0\nCLIENT_CMD=npm run test:e2e\nCLIENT_ACTUAL_EXIT=0\nLOAD_CMD=jmeter -n -t plan.jmx\nLOAD_ACTUAL_EXIT=0\nSTAGING_CMD=./scripts/smoke.sh staging\nSTAGING_ACTUAL_EXIT=0\n' > exec.env
printf '' > empty-report.txt
python3 - <<'PYEOF'
import json
d = json.load(open("../verification.json"))
for k in d["evidence"]:
    d["evidence"][k]["report_path"] = "empty-report.txt"
    d["evidence"][k].pop("report_sha256", None)
d["evidence"]["unit"].pop("log_path", None)
json.dump(d, open("v-empty.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "empty report files rejected by content check" python3 "$V" --kind verification --input v-empty.json --baseline baseline.tsv --exec-record exec.env
# (3) 伪造 verification zero_results → 拒
cd "${WORK:-.}" || exit 1
python3 - <<'PYEOF'
import json
d = json.load(open("verification.json"))
d["zero_results"] = [{"path": "evidence.unit", "reason": "伪造空结果"}]
json.dump(d, open("v-forged-zero.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "forged verification zero-result rejected" python3 "$V" --kind verification --input v-forged-zero.json --baseline baseline.tsv --exec-record exec.env
# (4) 冻结前端范围 pc-web + 声明免客户端 → 拒
python3 - <<'PYEOF'
import json
d = json.load(open("v-exempt-ok.json"))
d["client_not_applicable"] = {"declared": True, "frontend_scope": "not-applicable", "reason": "伪造"}
json.dump(d, open("v-frozen-mismatch.json", "w"), ensure_ascii=False)
PYEOF
printf 'UNIT_CMD=pytest -q
UNIT_ACTUAL_EXIT=0
INTEGRATION_CMD=mvn verify
INTEGRATION_ACTUAL_EXIT=0
LOAD_CMD=jmeter -n -t plan.jmx
LOAD_ACTUAL_EXIT=0
STAGING_CMD=./scripts/smoke.sh staging
STAGING_ACTUAL_EXIT=0
CLIENT_EXEMPT=1
' > exec-frozen.env
check_rc 1 "CLIENT_EXEMPT against frozen pc-web scope rejected" python3 "$V" --kind verification --input v-frozen-mismatch.json --baseline baseline.tsv --exec-record exec-frozen.env --frontend-scope pc-web
check_rc 0 "CLIENT_EXEMPT with frozen not-applicable accepted" python3 "$V" --kind verification --input v-exempt-ok.json --baseline baseline.tsv --exec-record exec-exempt.env --frontend-scope not-applicable
# (5) 文档锚点对账：删掉 §2.1 表章节标题 → 拦
python3 - <<'PYEOF'
from pathlib import Path
lines = Path("doc.md").read_text(encoding="utf-8").splitlines(keepends=True)
Path("doc-noanchor.md").write_text(
    "".join(ln for ln in lines if "2.1 支付订单表" not in ln), encoding="utf-8")
PYEOF
check_rc 1 "table anchor missing from doc rejected" python3 "$V" --kind design --input design.json --doc doc-noanchor.md
check_rc 0 "all sample anchors resolve in doc" python3 "$V" --kind design --input design.json --doc doc.md
# (6) 重复 verification zero_results → 拒
python3 - <<'PYEOF'
import json
d = json.load(open("verification.json"))
d["zero_results"] = [{"path": "acceptance_results", "reason": "x"}, {"path": "acceptance_results", "reason": "y"}]
json.dump(d, open("v-dup-zero.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "duplicate verification zero-result rejected" python3 "$V" --kind verification --input v-dup-zero.json --baseline baseline.tsv --exec-record exec.env

# 5d. v3.20.0 补偿链/集成/配置回归
python3 - <<'PYEOF'
import json
d = json.load(open("design.json"))
a = json.loads(json.dumps(d)); a["operations"] = []
json.dump(a, open("d-noops.json", "w"), ensure_ascii=False)
b = json.loads(json.dumps(d)); b["operations"][1]["resource_closure"] = []
json.dump(b, open("d-noclosure.json", "w"), ensure_ascii=False)
c = json.loads(json.dumps(d))
c["operations"][1]["resource_closure"][0]["release_timing"] = "never"
c["operations"][1]["resource_closure"][0]["evidence"] = ""
json.dump(c, open("d-never.json", "w"), ensure_ascii=False)
e = json.loads(json.dumps(d)); del e["integrations"][0]["endpoint"]
json.dump(e, open("d-noend.json", "w"), ensure_ascii=False)
f = json.loads(json.dumps(d))
f["configs"][0]["consumption_points"][0]["status"] = "dead_code"
f["configs"][0]["confidence"] = "low"
json.dump(f, open("d-dead.json", "w"), ensure_ascii=False)
g = json.loads(json.dumps(d)); g["integrations"] = []; g["configs"] = []
json.dump(g, open("d-nodecl.json", "w"), ensure_ascii=False)
PYEOF
check_rc 1 "resources without operations rejected (compensation chain missing)" python3 "$V" --kind design --input d-noops.json
check_rc 1 "reverse operation missing resource stance rejected" python3 "$V" --kind design --input d-noclosure.json
check_rc 1 "never release without evidence rejected" python3 "$V" --kind design --input d-never.json
check_rc 1 "integration without endpoint rejected" python3 "$V" --kind design --input d-noend.json
check_rc 1 "dead-only config + low confidence without reason rejected" python3 "$V" --kind design --input d-dead.json
check_rc 1 "undeclared empty optional collections rejected" python3 "$V" --kind design --input d-nodecl.json

# 6. 失败关闭：校验失败 → 不渲染
rm -f report2.md
check_rc 1 "pipeline aborts on invalid verification JSON" python3 "$P" verification --input v-fail.json --out report2.md --baseline baseline.tsv --exec-record exec.env
[ ! -f report2.md ] && ok "no report rendered after failed validation" || bad "no report rendered after failed validation"

echo "=== structured artifacts RESULT PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
