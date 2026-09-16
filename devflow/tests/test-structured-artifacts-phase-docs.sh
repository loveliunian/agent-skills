#!/usr/bin/env bash
# test-structured-artifacts-phase-docs.sh · v3.25.0 全阶段结构化产物回归测试
# 覆盖：clarification/acceptance/constraints/prd-review/tech-selection/design-review/
#       self-check/code-review/prd-validation/test-cases/deployment/monitoring/
#       docs-index/retrospective/small-change 的 validate → render → gate 兼容性。
# 每个 kind：样例正向通过 + 一个代表性负向被拦截 + 渲染含 Gate 机器标记。
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

V="$ROOT/scripts/df_validate.py"
R="$ROOT/scripts/df_render.py"
P="$ROOT/scripts/df_pipeline.py"
EX="$ROOT/examples/structured"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devflow-phase-docs-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

# ---------- 0. 组件与样例存在 ----------
for k in clarification acceptance constraints prd-review tech-selection design-review \
         self-check code-review prd-validation test-cases deployment monitoring \
         docs-index retrospective sharing demo-signoff small-change; do
  [ -f "$ROOT/schemas/$k.schema.json" ] && ok "schema exists: $k" || bad "missing schema: $k"
  [ -f "$EX/$k.sample.json" ] && ok "sample exists: $k" || bad "missing sample: $k"
done

# ---------- 1. 测试环境：产物引用的真实文件 ----------
mkdir -p docs/PRD docs/需求 docs/测试 docs/监控 docs/发布 docs/使用指南 docs/接口文档 docs/运维手册 \
         deploy/prometheus/rules .devflow/demo-pay/gates/P0 .devflow/demo-pay/gates/P2 .devflow/c-sort-default
printf 'demo prd\n' > docs/PRD/demo-pay.md
printf 'raw validation evidence\napi POST => PASS\n' > docs/测试/demo-pay-raw-validation.md
printf 'id\tstatus\nM-01-F01-A01\tPASS\n' > docs/测试/demo-pay-p4-results.tsv
printf 'log line1\nlog line2\n' > docs/监控/demo-pay-log-query.txt
printf 'ALERT_TRIGGERED=1\nNOTIFICATION_CONFIRMED=1\nRECOVERY_RECORDED=1\n' > docs/监控/demo-pay-alert-test.txt
printf 'groups:\n  - alert: PayHighErrorRate\n    expr: rate(pay_error_total[5m]) > 0.05\n' > deploy/prometheus/rules/demo-pay-alerts.yml
printf 'release run\n' > docs/发布/demo-pay-release-run.md
printf 'receipt P0\n' > .devflow/demo-pay/gates/P0/receipt.txt
printf 'receipt P2\n' > .devflow/demo-pay/gates/P2/receipt.txt
printf '3rd party skip\n' > .devflow/demo-pay/skip-log.txt
printf 'verify log\n' > .devflow/c-sort-default/verify.log
mkdir -p docs/原型
printf 'prototype fig placeholder content\n' > docs/原型/demo-pay-支付单管理.fig
printf 'prototype png placeholder content\n' > docs/原型/demo-pay-关闭流程.png
cat > criteria.md <<'EOF'
| M-01-F01-A01 | x |
| M-01-F01-A02 | x |
| M-01-F02-A01 | x |
EOF
cat > constraints-contract.md <<'EOF'
<!-- DEVFLOW:CONSTRAINTS
constraint_id=TC-TECH-001
type=MUST_USE
subject=workflow-engine
required_product=camunda
status=FROZEN
confirmed=true
DEVFLOW:END -->
EOF

validate() { # <kind> <json> [extra args...]
  local kind="$1" json="$2"; shift 2
  python3 "$V" --kind "$kind" --input "$json" --workspace . "$@"
}

# ---------- 2. 各 kind 正向 ----------
for k in clarification acceptance constraints prd-review tech-selection design-review \
         self-check code-review prd-validation deployment monitoring retrospective sharing demo-signoff; do
  check_rc 0 "sample validates: $k" validate "$k" "$EX/$k.sample.json"
done
check_rc 0 "sample validates: test-cases (+criteria 覆盖对照)" validate test-cases "$EX/test-cases.sample.json" --criteria criteria.md
check_rc 0 "sample validates: tech-selection (+constraints 绑定对账)" validate tech-selection "$EX/tech-selection.sample.json" --constraints constraints-contract.md

# docs-index：样例 SHA 为占位，测试内生成真实文档与指纹后校验
EX="$EX" python3 - <<'PYEOF'
import hashlib, json, os
from pathlib import Path
ex = os.environ["EX"]
docs = [
    ("USER_DOC", "docs/使用指南/demo-pay-使用指南.md", ["# 使用指南", "## 快速开始", "正文行一", "正文行二", "正文行三", "正文行四", "正文行五", "正文行六", "正文行七", "正文行八"]),
    ("DEVELOPER_DOC", "docs/使用指南/demo-pay-开发指南.md", ["# 开发指南", "## 构建与运行", "正文一", "正文二", "正文三", "正文四", "正文五", "正文六", "正文七", "正文八"]),
    ("API_DOC", "docs/接口文档/demo-pay-接口文档.md", ["# 接口文档", "## API 列表", "正文一", "正文二", "正文三", "正文四", "正文五", "正文六", "正文七", "正文八"]),
    ("OPERATIONS_DOC", "docs/运维手册/demo-pay-运维手册.md", ["# 运维手册", "## 部署与监控", "正文一", "正文二", "正文三", "正文四", "正文五", "正文六", "正文七", "正文八"]),
    ("RELEASE_NOTES", "docs/发布/demo-pay-发布说明.md", ["# 发布说明", "## 版本变更", "正文一", "正文二", "正文三", "正文四", "正文五", "正文六", "正文七", "正文八"]),
]
items = []
for kind, path, lines in docs:
    text = "\n".join(lines) + "\n"
    Path(path).write_text(text, encoding="utf-8")
    items.append({"kind": kind, "path": path, "sha256": hashlib.sha256(text.encode()).hexdigest()})
base = json.loads(Path(ex + "/docs-index.sample.json").read_text(encoding="utf-8"))
base["docs"] = items
Path("docs-index.generated.json").write_text(json.dumps(base, ensure_ascii=False, indent=2), encoding="utf-8")
PYEOF
check_rc 0 "docs-index validates (真实文档+实算 SHA)" validate docs-index docs-index.generated.json

# ---------- 3. 各 kind 负向（失败关闭） ----------
mutate() { python3 -c "$1"; }

mutate 'import json; d=json.load(open("'"$EX"'/clarification.sample.json")); d["ambiguities"][0]["status"]="pending"; json.dump(d, open("neg-clarification.json","w"), ensure_ascii=False)'
check_rc 1 "clarification: P0 未澄清被拦截" validate clarification neg-clarification.json

mutate 'import json; d=json.load(open("'"$EX"'/acceptance.sample.json")); d["points"][0]["status"]="REVIEWING"; json.dump(d, open("neg-acceptance.json","w"), ensure_ascii=False)'
check_rc 1 "acceptance: 非 FROZEN 被拦截" validate acceptance neg-acceptance.json

mutate 'import json; d=json.load(open("'"$EX"'/acceptance.sample.json")); d["points"][0]["prd_anchor"]="docs/PRD/does-not-exist.md#L1"; json.dump(d, open("neg-acceptance2.json","w"), ensure_ascii=False)'
check_rc 1 "acceptance: PRD 来源不存在被拦截" validate acceptance neg-acceptance2.json

mutate 'import json; d=json.load(open("'"$EX"'/constraints.sample.json")); d["constraints"][0]["status"]="DRAFT"; json.dump(d, open("neg-constraints.json","w"), ensure_ascii=False)'
check_rc 1 "constraints: DRAFT 被拦截" validate constraints neg-constraints.json

mutate 'import json; d=json.load(open("'"$EX"'/prd-review.sample.json")); d["zero_df_roles"]=[z for z in d["zero_df_roles"] if z["role"]!="安全"]; json.dump(d, open("neg-prd-review.json","w"), ensure_ascii=False)'
check_rc 1 "prd-review: 角色 DF/ZERO-DF 缺失被拦截" validate prd-review neg-prd-review.json

mutate 'import json; d=json.load(open("'"$EX"'/tech-selection.sample.json")); d["dimensions"][0]["weight"]=75; json.dump(d, open("neg-tech-selection.json","w"), ensure_ascii=False)'
check_rc 1 "tech-selection: 权重合计≠100 被拦截" validate tech-selection neg-tech-selection.json --constraints constraints-contract.md

mutate 'import json; d=json.load(open("'"$EX"'/design-review.sample.json")); d["receipts"][0]["session_id"]="REV-OTHER"; json.dump(d, open("neg-design-review.json","w"), ensure_ascii=False)'
check_rc 1 "design-review: 收据 session 与 run_id 不一致被拦截" validate design-review neg-design-review.json

mutate 'import json; d=json.load(open("'"$EX"'/self-check.sample.json")); d["checks"][0]["status"]="FAIL"; json.dump(d, open("neg-self-check.json","w"), ensure_ascii=False)'
check_rc 1 "self-check: 核心检查 FAIL 被拦截" validate self-check neg-self-check.json

mutate 'import json; d=json.load(open("'"$EX"'/code-review.sample.json")); d["reviewer_id"]=d["developer_id"]; json.dump(d, open("neg-code-review.json","w"), ensure_ascii=False)'
check_rc 1 "code-review: 同人自签被拦截" validate code-review neg-code-review.json

mutate 'import json; d=json.load(open("'"$EX"'/prd-validation.sample.json")); d["machine"]["p0_blockers"]=2; json.dump(d, open("neg-prd-validation.json","w"), ensure_ascii=False)'
check_rc 1 "prd-validation: 机器字段与阻断清单不一致被拦截" validate prd-validation neg-prd-validation.json

mutate 'import json; d=json.load(open("'"$EX"'/test-cases.sample.json")); d["cases"][0]["acceptance_refs"]=["M-09-F09-A09"]; json.dump(d, open("neg-test-cases.json","w"), ensure_ascii=False)'
check_rc 1 "test-cases: 验收点未覆盖/悬空引用被拦截" validate test-cases neg-test-cases.json --criteria criteria.md

mutate 'import json; d=json.load(open("'"$EX"'/deployment.sample.json")); d["artifact"]["sha256"]="zzzz"; json.dump(d, open("neg-deployment.json","w"), ensure_ascii=False)'
check_rc 1 "deployment: 制品指纹非 64hex 被拦截" validate deployment neg-deployment.json

mutate 'import json; d=json.load(open("'"$EX"'/monitoring.sample.json")); d["machine"]["alert_rule"]="deploy/missing-alerts.yml"; json.dump(d, open("neg-monitoring.json","w"), ensure_ascii=False)'
check_rc 1 "monitoring: 告警规则文件不存在被拦截" validate monitoring neg-monitoring.json

python3 - <<'PYEOF'
import json
from pathlib import Path
d = json.loads(Path("docs-index.generated.json").read_text(encoding="utf-8"))
d["docs"][0]["sha256"] = "0" * 64
Path("neg-docs-index.json").write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
PYEOF
check_rc 1 "docs-index: SHA-256 与实算不一致被拦截" validate docs-index neg-docs-index.json

mutate 'import json; d=json.load(open("'"$EX"'/retrospective.sample.json")); d["phase_facts"][0]["receipt_path"]=".devflow/demo-pay/gates/P0/missing.txt"; json.dump(d, open("neg-retro.json","w"), ensure_ascii=False)'
check_rc 1 "retrospective: 收据文件不存在被拦截" validate retrospective neg-retro.json

mutate 'import json; d=json.load(open("'"$EX"'/small-change.sample.json")); d["scan"]["permission"]="HIT"; json.dump(d, open("neg-small-change.json","w"), ensure_ascii=False)'
check_rc 1 "small-change: 风险面命中但声明 MICRO 被拦截" validate small-change neg-small-change.json

mutate 'import json; d=json.load(open("'"$EX"'/demo-signoff.sample.json")); d["kufs"]=d["kufs"][:2]; json.dump(d, open("neg-demo.json","w"), ensure_ascii=False)'
check_rc 1 "demo-signoff: KUF <3 被拦截" validate demo-signoff neg-demo.json

mutate 'import json; d=json.load(open("'"$EX"'/demo-signoff.sample.json")); d["po_conclusion"]="待确认，迭代中"; json.dump(d, open("neg-demo2.json","w"), ensure_ascii=False)'
check_rc 1 "demo-signoff: PO 未决结论被拦截" validate demo-signoff neg-demo2.json

mutate 'import json; d=json.load(open("'"$EX"'/sharing.sample.json")); d["lessons"]=d["lessons"][:1]; json.dump(d, open("neg-sharing.json","w"), ensure_ascii=False)'
check_rc 1 "sharing: lesson <3 被拦截" validate sharing neg-sharing.json

# ---------- 4. 渲染含 Gate 机器标记 ----------
OUT=render; mkdir -p "$OUT"
for k in clarification acceptance constraints prd-review tech-selection design-review \
         self-check code-review prd-validation test-cases deployment monitoring docs-index retrospective sharing demo-signoff; do
  check_rc 0 "render: $k" python3 "$R" "$k" --input "$EX/$k.sample.json" --out "$OUT/$k.md"
done
check_rc 0 "render: small-change 三件套" python3 "$R" small-change --input "$EX/small-change.sample.json" \
  --out "$OUT/small-change.md" --out-env "$OUT/small-change.env" --out-scan "$OUT/project-scan.txt"
check_rc 0 "render: retrospective 四件套(--out-feedback)" python3 "$R" retrospective --input "$EX/retrospective.sample.json" \
  --out "$OUT/retrospective.md" --out-feedback "$OUT/feedback.md"

grep -q '分母已冻结：验收点总计 3 个' "$OUT/acceptance.md" && ok "acceptance: 分母冻结行(s0 §4)" || bad "acceptance: 分母冻结行(s0 §4)"
grep -q '^## 模糊点清单' "$OUT/clarification.md" && grep -q '^## 签字确认' "$OUT/clarification.md" && ok "clarification: 模板 H2 对齐(s0 §5)" || bad "clarification: 模板 H2 对齐(s0 §5)"
grep -q 'DEVFLOW:CONSTRAINTS' "$OUT/constraints.md" && grep -q 'constraint_set\|constraint_id' "$OUT/constraints.md" && ok "constraints: 机器契约块" || bad "constraints: 机器契约块"
grep -qE '^#### DF-01 ' "$OUT/prd-review.md" && grep -qE '^- AW-1 场景：' "$OUT/prd-review.md" && grep -q '探针执行记录' "$OUT/prd-review.md" && ok "prd-review: DF/AW/探针标记(P0b gate)" || bad "prd-review: DF/AW/探针标记(P0b gate)"
grep -q '决策矩阵' "$OUT/tech-selection.md" && grep -q 'DEVFLOW:CONSTRAINT-BINDINGS' "$OUT/tech-selection.md" && ok "tech-selection: 决策矩阵+绑定块(s1 gate)" || bad "tech-selection: 决策矩阵+绑定块(s1 gate)"
grep -q '^REVIEW_RUN_ID=' "$OUT/design-review.md" && grep -qE '^#### DF-01 ' "$OUT/design-review.md" && ok "design-review: RUN_ID+DF 标记(p2a gate)" || bad "design-review: RUN_ID+DF 标记(p2a gate)"
grep -qE '^FINDING\|P0\|P0-1\|STATUS=CLOSED\|' "$OUT/code-review.md" && grep -q '^DEVELOPER_ID=dev-zhangsan' "$OUT/code-review.md" && ok "code-review: FINDING 行+角色分离字段(p3b gate)" || bad "code-review: FINDING 行+角色分离字段(p3b gate)"
grep -qx 'P0_BLOCKERS=0' "$OUT/prd-validation.md" && grep -q '^P4_CMD=' "$OUT/prd-validation.md" && ok "prd-validation: P4 机器字段(p4 gate)" || bad "prd-validation: P4 机器字段(p4 gate)"
grep -qE '^\| TC-demo-pay-001 \|' "$OUT/test-cases.md" && grep -q 'M-01-F01-A01' "$OUT/test-cases.md" && ok "test-cases: 用例行首列 TC-ID(p5 gate)" || bad "test-cases: 用例行首列 TC-ID(p5 gate)"
grep -q '^DEPLOYMENT_ID=' "$OUT/deployment.md" && grep -qx 'HEALTH_HTTP_STATUS=200' "$OUT/deployment.md" && ok "deployment: P7 机器证据行" || bad "deployment: P7 机器证据行"
grep -q '^METRICS_ENDPOINT=' "$OUT/monitoring.md" && grep -qx 'ALERT_TESTED=PASS' "$OUT/monitoring.md" && ok "monitoring: P8 机器证据行" || bad "monitoring: P8 机器证据行"
grep -q '^USER_DOC=' "$OUT/docs-index.md" && grep -qE '^USER_DOC_SHA256=[0-9a-f]{64}' "$OUT/docs-index.md" && ok "docs-index: KEY=VALUE 机器行" || bad "docs-index: KEY=VALUE 机器行"
grep -q '^FEEDBACK_ID=FB-' "$OUT/retrospective.md" && grep -q 'SCOPE=project' "$OUT/retrospective.md" && ok "retrospective: 反馈队列契约行(p10 词汇)" || bad "retrospective: 反馈队列契约行(p10 词汇)"
grep -q '^## 上次遗漏了什么' "$OUT/retrospective.md" && grep -q '^## 本次新发现' "$OUT/retrospective.md" && ok "retrospective: p10 强制章节 H2" || bad "retrospective: p10 强制章节 H2"
grep -qE '^\| KUF-1 \|.*走查' "$OUT/demo-signoff.md" && grep -q 'PO（产品负责人）结论' "$OUT/demo-signoff.md" && grep -q 'docs/原型/demo-pay-支付单管理.fig' "$OUT/demo-signoff.md" && ok "demo-signoff: KUF/走查/PO/原型引用标记(p2b gate)" || bad "demo-signoff: KUF/走查/PO/原型引用标记(p2b gate)"
grep -cE '^- \*\*' "$OUT/sharing.md" | grep -qE '^[3-9]$' && ok "sharing: ≥3 条 lesson 列表项(p10 gate)" || bad "sharing: ≥3 条 lesson 列表项(p10 gate)"
grep -q '^ROOT_CAUSE=.' "$OUT/feedback.md" && grep -q '^TARGET_FILES=.' "$OUT/feedback.md" && grep -q '^DECISION=fix' "$OUT/feedback.md" && ok "feedback.md: p10 必填字段齐备" || bad "feedback.md: p10 必填字段齐备"
grep -q '^CHANGE_KIND=ui-behavior' "$OUT/small-change.env" && grep -q "^SCAN_PERMISSION=NA" "$OUT/project-scan.txt" && grep -qF "列表默认排序改为更新时间倒序" "$OUT/project-scan.txt" && ok "small-change: env+scan 契约(gate 同字段)" || bad "small-change: env+scan 契约(gate 同字段)"

# ---------- 5. 真实 s0 Gate 跑渲染产物（clarification/acceptance/constraints 端到端） ----------
cp "$OUT/acceptance.md" "docs/需求/demo-pay-验收点.md"
cp "$OUT/clarification.md" "docs/需求/demo-pay-需求澄清.md"
cp "$OUT/constraints.md" "docs/需求/demo-pay-技术约束.md"
mkdir -p docs/详细设计
printf '# 权限矩阵\n\nperm:pay:add\nperm:pay:view\nperm:pay:close\n' > docs/详细设计/_权限矩阵.md
S0_OUT=$(bash "$ROOT/scripts/s0_acceptance_gate.sh" demo-pay 2>&1)
echo "$S0_OUT" | grep -q 'P0 RESULT: PASS=1[0-9] FAIL=0' && ok "s0 gate 端到端通过(渲染产物)" || {
  bad "s0 gate 端到端通过(渲染产物)"
  echo "$S0_OUT" | grep '\[P0\]' | head -5
}

# ---------- 6. 管线失败关闭：坏 JSON 不落盘 ----------
cp "$OUT/acceptance.md" pipeline-doc.before
check_rc 1 "pipeline: 校验失败即中止(不渲染)" python3 "$P" acceptance --input neg-acceptance.json --out pipeline-doc.md
[ ! -f pipeline-doc.md ] && ok "pipeline: 校验失败未产出文档" || bad "pipeline: 校验失败未产出文档"
check_rc 0 "pipeline: 正向 validate→render" python3 "$P" acceptance --input "$EX/acceptance.sample.json" --out pipeline-doc.md --workspace .
grep -q '分母已冻结' pipeline-doc.md && ok "pipeline: 渲染产物含确定性层" || bad "pipeline: 渲染产物含确定性层"
check_rc 2 "pipeline: 缺 --out 报用法错误(argparse 退出码 2)" python3 "$P" acceptance --input "$EX/acceptance.sample.json"

echo "=== phase-docs structured artifacts RESULT PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
