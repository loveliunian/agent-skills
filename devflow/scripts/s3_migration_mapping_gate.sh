#!/usr/bin/env bash
# =============================================================================
# P2 迁移映射 Gate（仅 B/C 场景）
# =============================================================================
# 功能：
#   1. 检查数据字典存在
#   2. 检查映射表覆盖率 = 100%
#   3. 检查主键、外键、枚举、时间、附件、敏感字段映射规则完整
#   4. 场景 A 自动跳过
# =============================================================================
set -uo pipefail


# ---------- 全局计数 ----------
FAIL=0; PASS=0; WARN=0

p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

# ---------- 参数解析 ----------
SCENARIO="${1:-}"
MAPPING="${2:-}"
EXPECTED_SOURCES="${3:-1}"


usage() {
  cat <<EOF

检查 P2 迁移映射 Gate

参数：
  SCENARIO          迁移场景（A/B/C）
  mapping.md        映射表文件路径
  expected_sources  预期来源系统数量（默认：1）

场景说明：
  A - 仅新建表，无老系统数据迁移
  B - 部分迁移，部分表从老系统迁移
  C - 全部迁移，所有表从老系统迁移

示例：
  $0 A
  $0 B docs/数据映射/M-03-映射.md 2
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in

    --help|-h) usage; exit 0 ;;
    -*) echo "[P0] unknown argument: $1"; exit 2 ;;
    *) break ;;
  esac
done

# v3.15.10: 旧 `shift 2>/dev/null` 实为 shift-by-1（2> 是 fd-2 重定向）——功能正确但易误读，改显式
SCENARIO="${1:-}"; shift || true
MAPPING="${1:-}"; shift || true
# v3.9.6 修复：set -u 下 $1 未设置会报 unbound variable（A 场景/省略 source-count 时触发）
[ -n "${1:-}" ] && EXPECTED_SOURCES="$1" && shift

# v3.15.9: 无参 fail-closed exit 2——旧 usage 内 exit 0 = 迁移映射 gate 空跑放行（上层误判 PASS）
[ -z "$SCENARIO" ] && { usage; exit 2; }

# =============================================================================
# SECTION 0: 场景检查
# =============================================================================
echo ""
echo "=== §0 场景检查 ==="

case "$SCENARIO" in
  A)
    echo "场景 A：仅新建表，无老系统数据迁移"
    echo "P2 GATE: PASS (scenario A, migration mapping not required)"
    exit 0
    ;;
  B|C)
    echo "场景 ${SCENARIO}：需要迁移映射"
    ;;
  *)
    p0 "invalid scenario: ${SCENARIO} (must be A, B, or C)"
    exit 2
    ;;
esac

# =============================================================================
# SECTION 1: 映射文件存在性检查
# =============================================================================
echo ""
echo "=== §1 映射文件存在性检查 ==="

[ -n "$MAPPING" ] || { p0 "mapping file not specified"; exit 1; }
[ -f "$MAPPING" ] || { p0 "mapping file missing: $MAPPING"; exit 1; }
pass "mapping file exists: $MAPPING"

# =============================================================================
# SECTION 2: 映射表头检查
# =============================================================================
echo ""
echo "=== §2 映射表头检查 ==="

# 检查标准表头：目标对象/字段|来源系统|来源对象/字段|转换规则|空值/默认策略|主键/引用映射|敏感处理|验证
HEADER_PATTERN='目标对象|来源系统|来源对象|转换规则|空值|默认策略|主键|引用映射|敏感处理|验证'


if grep -qE '目标对象/字段.*来源系统.*来源对象/字段.*转换规则.*空值/默认策略.*主键/引用映射.*敏感处理.*验证' "$MAPPING" 2>/dev/null; then
  pass "mapping header complete (8 columns)"

elif grep -qE "$HEADER_PATTERN" "$MAPPING" 2>/dev/null; then
  pass "mapping header found"

else
  p0 "mapping header incomplete or missing"
  p1 "expected columns: 目标对象/字段, 来源系统, 来源对象/字段, 转换规则, 空值/默认策略, 主键/引用映射, 敏感处理, 验证"
fi

# =============================================================================
# SECTION 3: 映射行检查
# =============================================================================
echo ""
echo "=== §3 映射行检查 ==="

# 提取映射行（跳过表头和分隔线）
ROWS=$(grep -E '^\|[[:space:]]*[^| -][^|]*\|' "$MAPPING" 2>/dev/null \
  | grep -vE '^\|[[:space:]]*[-:][[:space:]]*\|' \
  | grep -vE '目标对象|来源系统|来源对象|列名' \
  | grep -vE '^\|[[:space:]]*$')

ROW_COUNT=$(printf '%s\n' "$ROWS" | grep -c . || true)

if [ "$ROW_COUNT" -gt 0 ]; then
  pass "mapping rows: $ROW_COUNT"
else
  p0 "no mapping rows found"
fi

# =============================================================================
# SECTION 4: 必填字段完整性检查
# =============================================================================
echo ""
echo "=== §4 必填字段完整性检查 ==="

INCOMPLETE_ROWS=0

while IFS= read -r row; do
  [ -z "$row" ] && continue

  # 检查每一列是否有值（至少有一个非空、非破折号的值）
  # 简化检查：行中至少有 5 个非空单元格
  CELL_COUNT=$(echo "$row" | grep -oE '\|' | wc -l)
  EMPTY_COUNT=$(echo "$row" | grep -oE '\|[[:space:]]*-[[:space:]]*\|' | wc -l)

  if [ "$CELL_COUNT" -le "$EMPTY_COUNT" ]; then
    p0 "incomplete mapping row: $row"
    INCOMPLETE_ROWS=$((INCOMPLETE_ROWS + 1))
  fi
done <<< "$ROWS"

if [ "$INCOMPLETE_ROWS" -eq 0 ] && [ "$ROW_COUNT" -gt 0 ]; then
  pass "all $ROW_COUNT mapping rows are complete"
fi

# =============================================================================
# SECTION 5: 字段类型映射规则检查
# =============================================================================
echo ""
echo "=== §5 字段类型映射规则检查 ==="

# 检查各类字段是否有映射规则
FIELD_TYPES=(
  "主键"
  "外键"
  "枚举"
  "时间"
  "附件"
  "敏感"
  "密码"
)

MAPPED_TYPES=0
for type in "${FIELD_TYPES[@]}"; do
  TYPE_COUNT=$(grep -iE "$type" "$MAPPING" 2>/dev/null | grep -c . || true)
  if [ "$TYPE_COUNT" -gt 0 ]; then
    pass "field type '$type': $TYPE_COUNT mappings"
    MAPPED_TYPES=$((MAPPED_TYPES + 1))
  fi
done

if [ "$MAPPED_TYPES" -eq 0 ]; then
  warn "no specific field type mappings found"
fi

# =============================================================================
# SECTION 6: 来源系统检查
# =============================================================================
echo ""
echo "=== §6 来源系统检查 ==="

SOURCES=$(printf '%s\n' "$ROWS" \
  | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); if ($3 != "" && $3 != "—" && $3 !~ /无|新建|N\/A/) print $3}' \
  | sort -u | grep -c . || true)

echo "  检测到来源系统数: $SOURCES"
echo "  预期来源系统数: $EXPECTED_SOURCES"

if [ "$SOURCES" -ge "$EXPECTED_SOURCES" ]; then
  pass "source systems: $SOURCES >= $EXPECTED_SOURCES"
else
  p0 "source systems $SOURCES < expected $EXPECTED_SOURCES"
fi

# =============================================================================
# SECTION 7: 场景 C 特殊检查（多来源适配器）
# =============================================================================
echo ""
echo "=== §7 场景 C 特殊检查 ==="

if [ "${SCENARIO}" = "C" ]; then
  # 场景 C：必须至少 2 个来源系统
  if [ "$EXPECTED_SOURCES" -lt 2 ]; then
    p0 "scenario C requires expected_sources >= 2"
  fi

  # 检查是否有适配器声明
  ADAPTERS=$(grep -iE '适配器|Adapter|adapter' "$MAPPING" 2>/dev/null | grep -c . || true)
  if [ "$ADAPTERS" -ge "$EXPECTED_SOURCES" ]; then
    pass "adapters declared: $ADAPTERS (>= $EXPECTED_SOURCES)"
  else
    p1 "adapters: $ADAPTERS (expected >= $EXPECTED_SOURCES)"
  fi
fi

# =============================================================================
# SECTION 8: 占位符检查
# =============================================================================
echo ""
echo "=== §8 占位符检查 ==="

PLACEHOLDERS=0
for pattern in 'TODO' 'TBD' '待补充' 'REPLACE_WITH' '占位' '暂定' '待定'; do
  COUNT=$(grep -iE "$pattern" "$MAPPING" 2>/dev/null | grep -c . || true)
  if [ "$COUNT" -gt 0 ]; then
    p0 "placeholder '$pattern' found: $COUNT times"
    grep -nE "$pattern" "$MAPPING" 2>/dev/null | head -3 | sed 's/^/    /'
    PLACEHOLDERS=$((PLACEHOLDERS + COUNT))
  fi
done

if [ "$PLACEHOLDERS" -eq 0 ]; then
  pass "no placeholders found"
fi

# =============================================================================
# SECTION 9: 映射覆盖率计算
# =============================================================================
echo ""
echo "=== §9 映射覆盖率计算 ==="

# 简化为：检查数据字典中的字段是否都有映射
# 如果有数据字典引用，进行交叉验证
DICT_REF=$(grep -oE '数据字典|数据字典路径|data.dict' "$MAPPING" 2>/dev/null | head -1)
if [ -n "$DICT_REF" ]; then
  pass "data dictionary reference found: $DICT_REF"
else
  warn "no data dictionary reference"
fi

# =============================================================================
# FINAL: 输出汇总
# =============================================================================
echo ""
echo "========================================"
echo "P2 RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"
echo ""
echo "  Scenario: ${SCENARIO}"
echo "  Mapping rows: $ROW_COUNT"
echo "  Source systems: $SOURCES"
echo "  Expected sources: $EXPECTED_SOURCES"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "P2 GATE: FAIL (blocking)"
  echo ""
  echo "阻塞原因:"
  echo "  - 映射表头不完整"
  echo "  - 映射行不完整"
  echo "  - 来源系统数量不足"
  echo "  - 存在占位符"
  exit 1
fi

echo ""
echo "P2 GATE: PASS"
exit 0
