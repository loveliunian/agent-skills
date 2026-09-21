#!/usr/bin/env bash
# P5 测试生成快速演示 v3.28.10
# 用途：30 秒演示 P5 自动生成测试流程

set -euo pipefail

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "════════════════════════════════════════════════════════════════"
echo "  P5 测试生成快速演示 v3.28.1"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 1. 创建临时目录
DEMO_DIR="/tmp/devflow-p5-demo"
rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"
cd "$DEMO_DIR"

echo -e "${BLUE}[1/5]${NC} 创建项目结构..."
mkdir -p .devflow/user-management
mkdir -p backend/src/test/java/{controller,service,mapper}
mkdir -p frontend/tests/e2e/{pages,helpers}
mkdir -p docs/测试用例

# 2. 创建 design.json（简化版）
echo -e "${BLUE}[2/5]${NC} 创建 design.json..."
cat > .devflow/user-management/design.json << 'JSON_END'
{
  "feature": "user-management",
  "apis": [
    {
      "path": "/api/users",
      "method": "POST",
      "description": "创建用户",
      "controller": "UserController",
      "service_method": "createUser",
      "request_dto": "UserCreateDTO",
      "response_dto": "UserVO",
      "permission": "user:create"
    },
    {
      "path": "/api/users/{id}",
      "method": "GET",
      "description": "获取用户详情",
      "controller": "UserController",
      "service_method": "getUser",
      "request_dto": null,
      "response_dto": "UserVO",
      "permission": "user:view"
    }
  ],
  "services": [
    {
      "name": "UserService",
      "methods": ["createUser", "getUser", "updateUser", "deleteUser"]
    }
  ],
  "mappers": [
    {
      "name": "UserMapper",
      "methods": ["toVO", "toDO"]
    }
  ]
}
JSON_END

# 3. 创建 acceptance.json（简化版）
echo -e "${BLUE}[3/5]${NC} 创建 acceptance.json..."
cat > .devflow/user-management/acceptance.json << 'JSON_END'
{
  "feature": "user-management",
  "module": "M-01",
  "acceptance_points": [
    {
      "id": "M-01-F01-A01",
      "description": "用户列表页面展示所有用户",
      "page": "UserListPage",
      "path": "/users",
      "steps": [
        "导航到用户列表页面",
        "验证表格中显示所有用户",
        "验证用户名、邮箱、状态等字段"
      ],
      "expected": "列表显示所有用户，数据正确"
    },
    {
      "id": "M-01-F01-A02",
      "description": "点击新增按钮弹出表单",
      "page": "UserListPage",
      "path": "/users",
      "steps": [
        "点击新增用户按钮",
        "验证表单对话框显示",
        "验证表单字段完整"
      ],
      "expected": "表单对话框正确显示"
    }
  ]
}
JSON_END

# 4. 运行测试生成器
echo -e "${BLUE}[4/5]${NC} 运行测试生成器..."
bash "$SKILL_ROOT/scripts/generate_tests.sh" user-management

# 5. 展示生成结果
echo ""
echo -e "${BLUE}[5/5]${NC} 查看生成的测试文件..."
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  JUnit 测试（Controller）"
echo "═══════════════════════════════════════════════════════════════"
if [ -f "backend/src/test/java/controller/UserControllerTest.java" ]; then
  head -n 50 backend/src/test/java/controller/UserControllerTest.java
  echo ""
  echo "... （完整内容见文件）"
else
  echo -e "${YELLOW}⚠️  未生成 UserControllerTest.java${NC}"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Playwright 测试（Page Object）"
echo "═══════════════════════════════════════════════════════════════"
if [ -f "frontend/tests/e2e/pages/UserListPage.ts" ]; then
  head -n 30 frontend/tests/e2e/pages/UserListPage.ts
  echo ""
  echo "... （完整内容见文件）"
else
  echo -e "${YELLOW}⚠️  未生成 UserListPage.ts${NC}"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  生成的文件列表"
echo "═══════════════════════════════════════════════════════════════"
find backend/src/test frontend/tests/e2e -type f 2>/dev/null | sort

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo -e "${GREEN}✅ 演示完成！${NC}"
echo ""
echo "生成的测试文件位于："
echo "  $DEMO_DIR"
echo ""
echo "查看完整文件："
echo "  cat $DEMO_DIR/backend/src/test/java/controller/UserControllerTest.java"
echo "  cat $DEMO_DIR/frontend/tests/e2e/pages/UserListPage.ts"
echo ""
echo "清理演示目录："
echo "  rm -rf $DEMO_DIR"
echo "═══════════════════════════════════════════════════════════════"
