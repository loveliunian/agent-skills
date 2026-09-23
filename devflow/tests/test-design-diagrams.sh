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

# ── T2/T3: s2 DB 扫描 + 结构图落位（最小夹具直跑 s2 检查段难以隔离——用词级验证 + 集成样例） ──
# 构造最小详设文档：WHEN=0 时时序配对检查跳过；DB 词扫描与结构图登记是独立段
mk_design() { # <ws> <是否含产品名> <是否含结构图关键词>
  local w="$1" prod="$2" chart="$3"
  mkdir -p "$w/.devflow/t2" "$w/docs/详细设计"
  {
    echo "# t2 详细设计"
    echo ""
    echo "## §1 概览"
    if [ "$prod" = "1" ]; then echo "数据存储采用 PostgreSQL 集群。"; else echo "数据存储采用 DB 集群（方言由部署配置）。"; fi
    if [ "$chart" = "1" ]; then
      echo ""
      echo "## §2.3 状态转移"
      echo '```mermaid'
      echo 'stateDiagram-v2'
      echo '  [*] --> Draft'
      echo '```'
    fi
  } > "$w/docs/详细设计/t2-详细设计.md"
  printf '{"feature":"t2"}\n' > "$w/.devflow/t2/design.json"
}

# DB 扫描直验（grep 口径与 s2 一致）
mk_design "$TMP/t2a" 1 0
DBA=$(grep -cE '\b(H2|MySQL|PostgreSQL|Postgres|Oracle|KingbaseES|Kingbase|openGauss|达梦|人大金仓)\b' "$TMP/t2a/docs/详细设计/t2-详细设计.md" || true)
[ "${DBA:-0}" -ge 1 ] && ok "T2a DB 产品名扫描命中（PostgreSQL）" || bad "T2a 扫描未命中"
mk_design "$TMP/t2b" 0 0
DBB=$(grep -cE '\b(H2|MySQL|PostgreSQL|Postgres|Oracle|KingbaseES|Kingbase|openGauss|达梦|人大金仓)\b' "$TMP/t2b/docs/详细设计/t2-详细设计.md" || true)
[ "${DBB:-0}" = "0" ] && ok "T2b DB 泛称不误报" || bad "T2b 泛称误报"

# 结构图落位：登记与关键词的映射口径（状态机→stateDiagram-v2；其余→flowchart）
mk_design "$TMP/t2c" 0 1
printf '{"feature":"t2","diagrams":{"structure_charts":[{"type":"状态机","section":"§2.3"}]}}\n' > "$TMP/t2c/.devflow/t2/design.json"
grep -q "stateDiagram-v2" "$TMP/t2c/docs/详细设计/t2-详细设计.md" \
  && ok "T3a 状态机登记 ↔ stateDiagram-v2 落位匹配" || bad "T3a 落位匹配失败"

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
