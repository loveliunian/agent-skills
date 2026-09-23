#!/usr/bin/env bash
# test-design-diagrams.sh · 图表体系机器闭环回归（v3.30.0）
#   T1 schema/validator：非法 type 与归位锚拒绝；合法六类通过
#   T2 s2 DB 中立扫描：详设出现产品名 → P0；DB 泛称 → 通过
#   T3 s2 结构图登记 ↔ 文档落位：登记但文档缺图 → P0；有图 → 通过
#   T4 双次渲染 SHA 稳定性：design.sample 两次渲染逐字节一致（gen 确定性契约）
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
# shellcheck source=py_runtime.sh
. "$ROOT/scripts/py_runtime.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "[FAIL] $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/design-diagrams.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT


# ── T1 validator：diagrams.structure_charts 契约 ──
T1="$TMP/t1"; mkdir -p "$T1/.devflow/t1"
printf '{"feature":"t1","diagrams":{"structure_charts":[{"type":"时序图","section":"x"}]}}' > "$T1/.devflow/t1/design.json"
_e1=$("${DEVFLOW_PY[@]}" "$ROOT/scripts/df_validate.py" --kind design --input "$T1/.devflow/t1/design.json" 2>&1 || true)
printf '%s' "$_e1" | grep -q "type 非法" && printf '%s' "$_e1" | grep -q "section 归位锚非法" \
  && ok "T1a 非法 type + 非法归位锚均被拒" || bad "T1a validator 未拦截: $(printf '%s' "$_e1" | grep diagrams | head -2)"

printf '{"feature":"t1","diagrams":{"structure_charts":[{"type":"状态机","section":"§2.3"},{"type":"状态机","section":"§9"}]}}' > "$T1/.devflow/t1/design.json"
_e2=$("${DEVFLOW_PY[@]}" "$ROOT/scripts/df_validate.py" --kind design --input "$T1/.devflow/t1/design.json" 2>&1 || true)
printf '%s' "$_e2" | grep -q "type 重复登记" \
  && ok "T1b 一类多处登记被拒（一类一处）" || bad "T1b 重复登记未拦"

# ── T2/T3: 真实 s2 gate 端到端（DB 扫描 + 结构图落位——v3.30.3 从 grep 级升级为 gate 级） ──
mk_s2_fixture() { # <ws> <产品名|泛称> <登记类型|无> <文档是否含 stateDiagram>
  local w="$1" prod="$2" reg="$3" chart="$4"
  mkdir -p "$w/.devflow/fx" "$w/docs/详细设计" "$w/docs/需求"
  (cd "$w" && bash "$ROOT/scripts/devflow-state.sh" init fx --frontend=not-applicable >/dev/null 2>&1)
  {
    echo "# fx 详细设计"
    echo "## §1 概览"
    if [ "$prod" = "1" ]; then echo "数据存储采用 PostgreSQL。"; else echo "数据存储采用 DB（方言由部署配置）。"; fi
    if [ "$chart" = "1" ]; then
      echo "## §2.3 状态转移"
      echo '```mermaid'
      echo 'stateDiagram-v2'
      echo '  [*] --> Draft'
      echo '```'
    fi
  } > "$w/docs/详细设计/fx-详细设计.md"
  printf '# 验收点\n| M-01-F01-A01 | FROZEN |\n' > "$w/docs/需求/fx-验收点.md"
  if [ "$reg" = "none" ]; then
    printf '{"feature":"fx"}' > "$w/.devflow/fx/design.json"
  else
    printf '{"feature":"fx","diagrams":{"structure_charts":[{"type":"%s","section":"§2.3"}]}}' "$reg" > "$w/.devflow/fx/design.json"
  fi
}

S2G="$ROOT/scripts/s2_design_coverage_gate.sh"
run_s2() { (cd "$1" && bash "$S2G" docs/详细设计/fx-详细设计.md docs/需求/fx-验收点.md --mode=monolith 2>&1 || true); }

# T2 真实 gate：DB 产品名 → P0；泛称 → PASS 行
W2A="$TMP/s2a"; mk_s2_fixture "$W2A" 1 none 0
run_s2 "$W2A" | grep -q "详设正文出现具体数据库产品名" \
  && ok "T2a 真实 s2：DB 产品名被 P0 拦截" || bad "T2a 真实 s2 未拦产品名"
W2B="$TMP/s2b"; mk_s2_fixture "$W2B" 0 none 0
run_s2 "$W2B" | grep -q "DB 中立扫描：详设无具体数据库产品名" \
  && ok "T2b 真实 s2：DB 泛称通过" || bad "T2b 真实 s2 泛称误报"

# T3 真实 gate：登记↔落位对账（正/反）
W3A="$TMP/s3a"; mk_s2_fixture "$W3A" 0 状态机 1
run_s2 "$W3A" | grep -q "结构图登记 ↔ 文档落位对账通过" \
  && ok "T3a 真实 s2：状态机登记+落位对账通过" || bad "T3a 真实 s2 对账未通过"
W3B="$TMP/s3b"; mk_s2_fixture "$W3B" 0 决策链 1
run_s2 "$W3B" | grep -q "结构图登记 决策链（§2.3）但文档缺 flowchart 图" \
  && ok "T3b 真实 s2：决策链登记但缺 flowchart 被 P0" || bad "T3b 真实 s2 落位漂移未拦"

# ── T4 双次渲染 SHA 稳定性（gen 确定性契约的管线侧钉）──
W4="$TMP/t4"; mkdir -p "$W4/.devflow/t4"
cp "$ROOT/examples/structured/design.sample.json" "$W4/.devflow/t4/design.json"
(cd "$W4" \
  && "${DEVFLOW_PY[@]}" "$ROOT/scripts/df_render.py" design --input .devflow/t4/design.json --out r1.md >/dev/null 2>&1 \
  && "${DEVFLOW_PY[@]}" "$ROOT/scripts/df_render.py" design --input .devflow/t4/design.json --out r2.md >/dev/null 2>&1)
_s1=$(shasum -a 256 "$W4/r1.md" 2>/dev/null | awk '{print $1}')
_s2=$(shasum -a 256 "$W4/r2.md" 2>/dev/null | awk '{print $1}')
if [ -n "$_s1" ] && [ "$_s1" = "$_s2" ]; then
  ok "T4 双次渲染 SHA 稳定（${_s1:0:12}…）"
else
  bad "T4 渲染不稳定（s1=${_s1:0:12}, s2=${_s2:0:12}）"
fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
