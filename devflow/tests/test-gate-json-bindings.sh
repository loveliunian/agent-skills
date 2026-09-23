#!/usr/bin/env bash
# test-gate-json-bindings.sh · Gate JSON 绑定全链回归（v3.30.6）
#   背景（子代理实证）：v3.30.0-5 声称的"收据绑定全量"存在系统性断裂——P0b 崩溃
#   （SCRIPT_DIR unbound）、p2b/small-change 绑定行落不进收据、P3cd SHA-only 盲区。
#   本组用**真实 gate** 产出收据，断言绑定行落盘且 verify_stage_json_binding 接受。
#   T1 p2b 绿路径（rc=0 + DEMO_SIGNOFF_JSON 双行 + binding rc=0）
#   T2 artifact P0b 不再崩溃（收据写出 + PRD_REVIEW_JSON 双行）
#   T3 p3cd 双正本（SECURITY/PERFORMANCE_JSON 双行各就位）
#   T4 small-change（SMALL_CHANGE_JSON 双行 + binding rc=0——绿路径在 test-small-change）
set -uo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
# shellcheck source=py_runtime.sh
. "$ROOT/scripts/py_runtime.sh"
. "$TEST_DIR/testlib.sh"
PASS=0; FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gj-bindings.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

binds_ok() { # <receipt> <stage> <tag...> —— 收据含全部 TAG_JSON= 行且 binding 校验过
  local receipt="$1" stage="$2"; shift 2
  local t okall=1
  for t in "$@"; do
    grep -q "^${t}_JSON=" "$receipt" || { echo "  缺 ${t}_JSON 行"; okall=0; }
    grep -q "^${t}_JSON_SHA256=" "$receipt" || { echo "  缺 ${t}_JSON_SHA256 行"; okall=0; }
  done
  [ "$okall" = "1" ] || return 1
  (WORKSPACE="$(dirname "$receipt" | sed 's|/\(.devflow\)/.*|\1|;s|^\(.devflow\)$|.|')" \
    bash -c ". '$ROOT/scripts/devflow_receipt.sh' && verify_stage_json_binding '$receipt' '$stage'")
}

# ── T1 p2b 绿路径 ──
W1="$TMP/p2b"; mkdir -p "$W1/.devflow/fx" "$W1/docs/原型"
cp "$ROOT/examples/structured/demo-signoff.sample.json" "$W1/.devflow/fx/demo-signoff.json"
cat > "$W1/docs/原型/fx-原型确认.md" <<'EOF'
# fx 原型确认
## 演示记录
- KUF-1 用户登录 walkthrough 走查：旅程走通
- KUF-2 订单查询 walkthrough 走查：旅程走通
- KUF-3 订单筛选 walkthrough 走查：旅程走通
原型文件：docs/原型/fx-登录页.md
原型文件：docs/原型/fx-订单页.md
原型文件：docs/原型/fx-筛选面板.md
## PO 结论
PO 确认：通过，符合预期，同意进入详设。
签字人：张三（PO）
日期：2026-09-23
EOF
touch "$W1/docs/原型/fx-登录页.md" "$W1/docs/原型/fx-订单页.md" "$W1/docs/原型/fx-筛选面板.md"
if (cd "$W1" && bash "$ROOT/scripts/p2b_demo_gate.sh" fx >/dev/null 2>&1) \
   && binds_ok "$W1/.devflow/fx/gates/P2b/receipt.txt" P2b DEMO_SIGNOFF >/dev/null 2>&1; then
  ok "T1 p2b 绿路径：收据含 DEMO_SIGNOFF 双行且 binding 接受"
else
  bad "T1 p2b 绑定链断裂（v3.30.5 前主路径缺 printf 的回归）"
fi

# ── T2 artifact P0b：不崩溃 + 绑定落盘 ──
W2="$TMP/p0b"; mkdir -p "$W2/.devflow/fx" "$W2/docs/需求"
printf '{"feature":"fx","scope":{"frontend":"not-applicable"}}' > "$W2/.devflow/fx.state.json"
cp "$ROOT/examples/structured/prd-review.sample.json" "$W2/.devflow/fx/prd-review.json"
{ echo "# fx PRD 评审报告"; for i in 1 2 3 4 5 6 7 8 9; do echo "行$i 评审内容（实质行）。"; done; echo "最终结论：通过。"; } > "$W2/docs/需求/fx-PRD评审.md"
(cd "$W2" && bash "$ROOT/scripts/artifact_gate.sh" P0b fx >/dev/null 2>&1 || true)
if [ -f "$W2/.devflow/fx/gates/P0b/receipt.txt" ] \
   && binds_ok "$W2/.devflow/fx/gates/P0b/receipt.txt" P0b PRD_REVIEW >/dev/null 2>&1; then
  ok "T2 P0b 不崩溃且 PRD_REVIEW 绑定落盘（v3.30.6 前 SCRIPT_DIR unbound 全灭）"
else
  bad "T2 P0b 崩溃回归或绑定缺失"
fi

# ── T3 p3cd 双正本 ──
W3="$TMP/p3cd"; mkdir -p "$W3/.devflow/fx"
cp "$ROOT/examples/structured/security.sample.json" "$W3/.devflow/fx/security.json"
cp "$ROOT/examples/structured/performance.sample.json" "$W3/.devflow/fx/performance.json"
(cd "$W3" && bash "$ROOT/scripts/p3_security_perf_gate.sh" fx --mode full >/dev/null 2>&1 || true)
if binds_ok "$W3/.devflow/fx/gates/P3cd/receipt.txt" P3cd SECURITY PERFORMANCE >/dev/null 2>&1; then
  ok "T3 P3cd 双正本配对行落盘（v3.30.6 前 SHA-only 无路径行——剥离不可检）"
else
  bad "T3 P3cd 绑定配对缺失"
fi

# ── T4 small-change 绑定落盘（绿断言在 test-small-change） ──
W4="$TMP/sc"; mkdir -p "$W4/.devflow/order-filter"
cp "$ROOT/examples/structured/small-change.sample.json" "$W4/.devflow/order-filter/small-change.json"
cat > "$W4/.devflow/order-filter/persist.env" <<'EOF'
CHANGE_KIND=ui-behavior
CHANGE_SUBJECT=order-list-filter
LOGICAL_CHANGE_COUNT=1
TARGET=merge-ready
SURFACES=ui
PROJECT_SCAN_EVIDENCE=.devflow/order-filter/project-scan.txt
CHANGE_REPORT=docs/changes/order-filter-small-change.md
AFFECTED_PATHS=frontend/src/views/order-list.vue
BREAKING_API=0
TYPE_OR_NULLABILITY_BREAKING=0
PERMISSION_CHANGE=0
STATE_MACHINE_CHANGE=0
CROSS_SERVICE_CHANGE=0
NEW_TABLE_OR_SERVICE=0
LARGE_BACKFILL=0
MIGRATION_REQUIRED=0
DIALECTS=
VERIFY_CMD=awk 'BEGIN { print "ok" }'
MIGRATION_VERIFY_CMD=
DEPLOY_RECEIPT_PATH=
MONITOR_RECEIPT_PATH=
DECISION=MICRO
DECISION_REASON=single page tweak
EOF
printf 'subject=order-list-filter\nreferences=frontend/src/views/order-list.vue\nscan_command=rg order-list-filter\nSCAN_DB=MISS\nSCAN_DOMAIN=MISS\nSCAN_API=MISS\nSCAN_CLIENT=HIT\nSCAN_CONFIG=MISS\nSCAN_TEST=HIT\nSCAN_PERMISSION=MISS\nSCAN_WORKFLOW=MISS\nSCAN_CROSS_SERVICE=MISS\nSCAN_HISTORY_DATA=NA\n' > "$W4/.devflow/order-filter/project-scan.txt"
mkdir -p "$W4/docs/changes" "$W4/frontend/src/views"
printf '# small change\nsubject: order-list-filter\n' > "$W4/docs/changes/order-filter-small-change.md"
touch "$W4/frontend/src/views/order-list.vue"
(cd "$W4" && bash "$ROOT/scripts/small-change-gate.sh" verify order-filter .devflow/order-filter/persist.env >/dev/null 2>&1 || true)
if [ -f "$W4/.devflow/order-filter/gates/SMALL-CHANGE/receipt.txt" ] \
   && binds_ok "$W4/.devflow/order-filter/gates/SMALL-CHANGE/receipt.txt" SMALL-CHANGE SMALL_CHANGE >/dev/null 2>&1; then
  ok "T4 small-change 绑定落盘（v3.30.6 前 heredoc 把 printf 写成字面文本）"
else
  bad "T4 small-change 绑定字面化回归"
fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
