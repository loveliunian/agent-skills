#!/usr/bin/env bash
# P5 测试生成脚本 v3.29.3
# 用途：在 P5 阶段自动调用测试生成器

set -euo pipefail

FEATURE="${1:-}"
SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "════════════════════════════════════════════════════════════════"
echo "  P5 阶段：自动生成测试骨架 v3.28.1"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 1. 检查参数
if [ -z "$FEATURE" ]; then
  echo -e "${RED}❌ 缺少 feature 名称${NC}"
  echo "用法: bash $0 <feature-name>"
  exit 1
fi

# 2. 检查结构化产物
DESIGN_JSON=".devflow/$FEATURE/design.json"
ACCEPTANCE_JSON=".devflow/$FEATURE/acceptance.json"

if [ ! -f "$DESIGN_JSON" ]; then
  echo -e "${YELLOW}⚠️  未找到 $DESIGN_JSON${NC}"
  echo "跳过自动生成，进入手动编写测试用例流程"
  exit 0
fi

if [ ! -f "$ACCEPTANCE_JSON" ]; then
  echo -e "${YELLOW}⚠️  未找到 $ACCEPTANCE_JSON${NC}"
  echo "跳过自动生成，进入手动编写测试用例流程"
  exit 0
fi

echo -e "${GREEN}✓${NC} 检测到结构化产物"
echo "  - $DESIGN_JSON"
echo "  - $ACCEPTANCE_JSON"
echo ""

# 3. 调用测试生成器
echo -e "${BLUE}[1/2]${NC} 调用测试生成器..."
bash "$SKILL_ROOT/scripts/generate_tests.sh" "$FEATURE"

if [ $? -ne 0 ]; then
  echo -e "${RED}❌ 测试生成器执行失败${NC}"
  exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "${GREEN}✅ 测试骨架生成完成！${NC}"
echo ""
echo "📋 下一步："
echo "  1. 查找 TODO 标记"
echo "     grep -rn \"TODO:\" backend/src/test frontend/tests/e2e"
echo ""
echo "  2. 补充 JUnit 测试"
echo "     - Mock 数据（搜索 'TODO: 补充 Mock 数据'）"
echo "     - 断言逻辑（搜索 'TODO: 补充断言逻辑'）"
echo "     - 边界情况（手动添加测试方法）"
echo ""
echo "  3. 补充 Playwright 测试"
echo "     - 调整选择器（搜索 'TODO: 调整实际选择器'）"
echo "     - 补充断言（搜索 'TODO: 补充断言逻辑'）"
echo "     - 配置测试数据（检查 helpers.ts）"
echo ""
echo "  4. 验证编译通过"
echo "     mvn test-compile"
echo "     cd frontend && tsc --noEmit"
echo ""
echo "  5. 继续 P5 后续步骤（编写测试用例文档）"
echo ""
echo "📖 详细指南："
echo "   ~/.cursor/skills/devflow/docs/P5-自动生成测试.md"
echo "════════════════════════════════════════════════════════════════"
