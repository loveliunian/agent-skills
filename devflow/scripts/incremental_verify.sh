#!/usr/bin/env bash
# 增量变更验证脚本 v3.28.2
# 用途：验证增量变更是否正确完成

set -euo pipefail

FEATURE="${1:-}"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "════════════════════════════════════════════════════════════════"
echo "  增量变更验证 v3.28.1"
echo "════════════════════════════════════════════════════════════════"
echo ""

if [ -z "$FEATURE" ]; then
  echo -e "${RED}❌ 缺少 feature 名称${NC}"
  echo "用法: bash $0 <feature-name>"
  exit 1
fi

INCREMENTAL_STATE=".devflow/$FEATURE/incremental.json"

if [ ! -f "$INCREMENTAL_STATE" ]; then
  echo -e "${RED}❌ 未找到增量变更状态文件${NC}"
  echo "请先运行: bash scripts/incremental_change_mode.sh $FEATURE <change-type>"
  exit 1
fi

echo -e "${BLUE}Feature:${NC} $FEATURE"
echo ""

# 读取变更列表
CHANGE_COUNT=$(python3 -c "import json; f=open('$INCREMENTAL_STATE'); d=json.load(f); print(len(d['changes']))")

echo "════════════════════════════════════════════════════════════════"
echo "  变更列表（共 $CHANGE_COUNT 项）"
echo "════════════════════════════════════════════════════════════════"
echo ""

python3 - "$INCREMENTAL_STATE" << 'PYTHON_END'
import json
import sys

with open(sys.argv[1], 'r') as f:
    state = json.load(f)

for i, change in enumerate(state['changes'], 1):
    print(f"{i}. [{change['type']}] {change['scope']}")
    print(f"   状态: {change['status']}")
    print(f"   时间: {change['timestamp']}")
    if 'warning' in change:
        print(f"   ⚠️  {change['warning']}")
    print()
PYTHON_END

echo "════════════════════════════════════════════════════════════════"
echo "  验证检查"
echo "════════════════════════════════════════════════════════════════"
echo ""

PASS=0
FAIL=0

# 1. 检查设计文档是否更新
echo -e "${CYAN}[1/5]${NC} 检查设计文档..."
DESIGN_FILE="docs/detailed-design/${FEATURE}-design.md"
if [ -f "$DESIGN_FILE" ]; then
  # 检查最近修改时间
  MODIFIED=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$DESIGN_FILE" 2>/dev/null || stat -c "%y" "$DESIGN_FILE" 2>/dev/null | cut -d' ' -f1-2)
  echo -e "${GREEN}✓${NC} 设计文档存在（最后修改: ${MODIFIED}）"
  ((PASS++))
else
  echo -e "${RED}✗${NC} 设计文档不存在"
  ((FAIL++))
fi
echo ""

# 2. 检查 design.json 是否重新渲染
echo -e "${CYAN}[2/5]${NC} 检查 design.json..."
DESIGN_JSON=".devflow/$FEATURE/design.json"
if [ -f "$DESIGN_JSON" ]; then
  MODIFIED=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$DESIGN_JSON" 2>/dev/null || stat -c "%y" "$DESIGN_JSON" 2>/dev/null | cut -d' ' -f1-2)
  echo -e "${GREEN}✓${NC} design.json 存在（最后修改: ${MODIFIED}）"
  ((PASS++))
else
  echo -e "${RED}✗${NC} design.json 不存在，请运行："
  echo "   python3 scripts/df_pipeline.py design $FEATURE"
  ((FAIL++))
fi
echo ""

# 3. 检查受影响的代码文件
echo -e "${CYAN}[3/5]${NC} 检查受影响的代码文件..."

python3 - "$INCREMENTAL_STATE" << 'PYTHON_END'
import json
import sys
import os

with open(sys.argv[1], 'r') as f:
    state = json.load(f)

affected_files = set()

for change in state['changes']:
    if change['type'] == 'add-field' or change['type'] == 'modify-field':
        table = change.get('table', '')
        if table:
            affected_files.add(f"backend/src/main/java/entity/{table.capitalize()}DO.java")
            affected_files.add(f"backend/src/main/java/dto/{table.capitalize()}VO.java")
    
    if change['type'] == 'add-api' or change['type'] == 'modify-api':
        # 假设 Controller 文件存在
        affected_files.add(f"backend/src/main/java/controller/*Controller.java")

for f in sorted(affected_files):
    if '*' in f:
        # 通配符匹配
        print(f"  • {f} (需手动检查)")
    elif os.path.exists(f):
        print(f"  ✓ {f}")
    else:
        print(f"  ✗ {f} (不存在)")
PYTHON_END
echo ""

# 4. 检查测试是否补充
echo -e "${CYAN}[4/5]${NC} 检查测试补充..."
TEST_COUNT=$(find backend/src/test/java -name "*Test.java" 2>/dev/null | wc -l || echo 0)
if [ "$TEST_COUNT" -ge 1 ]; then
  echo -e "${GREEN}✓${NC} 测试文件数量: $TEST_COUNT"
  ((PASS++))
else
  echo -e "${YELLOW}⚠${NC} 测试文件数量较少: $TEST_COUNT"
fi
echo ""

# 5. 检查编译是否通过
echo -e "${CYAN}[5/5]${NC} 检查编译..."
if mvn compile -q 2>/dev/null; then
  echo -e "${GREEN}✓${NC} 编译通过"
  ((PASS++))
else
  echo -e "${RED}✗${NC} 编译失败，请检查代码"
  ((FAIL++))
fi
echo ""

# 输出结果
echo "════════════════════════════════════════════════════════════════"
echo "  验证结果"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo -e "通过: ${GREEN}${PASS}${NC}"
echo -e "失败: ${RED}${FAIL}${NC}"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}✅ 增量变更验证通过${NC}"
  echo ""
  echo "下一步："
  echo "  1. 运行测试: mvn test"
  echo "  2. 提交变更: git add . && git commit -m 'feat: <description>'"
  echo "  3. 清理状态: rm $INCREMENTAL_STATE"
  echo ""
  exit 0
else
  echo -e "${RED}❌ 增量变更验证失败${NC}"
  echo ""
  echo "请修复上述问题后重新运行验证"
  echo ""
  exit 1
fi
