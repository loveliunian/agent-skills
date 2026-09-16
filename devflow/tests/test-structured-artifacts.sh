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
printf 'M01-F01-A01\nM01-F01-A02\nM01-F02-A01\n' > /dev/null
cat > criteria.md <<'EOF'
| M01-F01-A01 | x |
| M01-F01-A02 | x |
| M01-F02-A01 | x |
EOF
# v3.24.0(A04)：prd_anchor 来源文件必须真实存在——样例锚点指向 docs/requirements/ 下
mkdir -p docs/requirements && cp criteria.md docs/requirements/demo-pay-acceptance-criteria.md
check_rc 0 "sample design validates" python3 "$V" --kind design --input design.json --criteria criteria.md
check_rc 0 "sample design pipeline renders into skeleton" python3 "$P" design --input design.json --doc doc.md --criteria criteria.md
grep -q "覆盖率：3/3 = 100%，全部验收点都完成了设计" doc.md && ok "human-readable coverage line rendered" || bad "human-readable coverage line rendered"
grep -q "df:begin:trace-matrix" doc.md && grep -q "M01-F02-A01" doc.md && ok "trace matrix spliced" || bad "trace matrix spliced"
grep -q "异步受理模式" doc.md && ok "zero-result declaration rendered" || bad "zero-result declaration rendered"

# 2. 骨架缺锚点块 → 渲染失败关闭（不静默跳过、不落盘）
cp "$ROOT/examples/structured/design.skeleton.md" partial.md
python3 - <<'PYEOF'
from pathlib import Path
lines = Path("partial.md").read_text(encoding="utf-8").splitlines(keepends=True)
Path("partial.md").write_text(
    "".join(ln for ln in lines if "df:begin:trace-matrix" not in ln and "df:end:trace-matrix" not in ln),
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

# 3b. v3.17.1: 接口概览↔详细定义闭环 + DDR↔字段一一对应
grep -q "df:begin:ddr-index" doc.md && ok "skeleton carries ddr blocks" || bad "skeleton carries ddr blocks"
grep -q "df:begin:resource-operations" doc.md && grep -q "df:begin:integrations-configs" doc.md && ok "skeleton carries compensation/integration blocks" || bad "skeleton carries compensation/integration blocks"
grep -q "| pay_order | order_no | DDR-1 |" doc.md && ok "ddr matrix rendered (field-level mapping)" || bad "ddr matrix rendered (field-level mapping)"
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
  "rules": [{"id": "R1", "anchor": "§5.1", "summary": "校验"}],
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
