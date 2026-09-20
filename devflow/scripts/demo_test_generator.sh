#!/bin/bash
# 测试生成器 Demo - 快速体验
#
# 此脚本创建一个最小化的 design.json 和 acceptance.json 示例，
# 然后运行测试生成器，展示完整流程。

set -euo pipefail

# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/py_runtime.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}========================================"
echo "  测试生成器 Demo"
echo "========================================${NC}"
echo ""

# 创建临时目录
DEMO_DIR="/tmp/devflow-test-generator-demo"
rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR/.devflow/demo-feature"

echo -e "${GREEN}[1/5]${NC} 创建示例 design.json..."

cat > "$DEMO_DIR/.devflow/demo-feature/design.json" <<'EOF'
{
  "feature": "demo-feature",
  "generated_at": "2026-09-20T10:00:00Z",
  "template": {
    "id": "详细设计-模板",
    "version": "3.27.0",
    "mode": "monolith"
  },
  "acceptance": [
    {
      "id": "M-01-F01-A01",
      "description": "查询用户列表",
      "design_anchor": "§3.1"
    }
  ],
  "tables": [
    {
      "name": "user",
      "description": "用户表",
      "fields": [
        {
          "name": "id",
          "type": "BIGINT",
          "constraints": "PRIMARY KEY",
          "default": "AUTO_INCREMENT",
          "description": "主键",
          "ddr": ["DDR-001"]
        },
        {
          "name": "username",
          "type": "VARCHAR(50)",
          "constraints": "NOT NULL UNIQUE",
          "default": "",
          "description": "用户名",
          "ddr": ["DDR-001"]
        },
        {
          "name": "email",
          "type": "VARCHAR(100)",
          "constraints": "NOT NULL",
          "default": "",
          "description": "邮箱",
          "ddr": ["DDR-001"]
        }
      ]
    }
  ],
  "apis": [
    {
      "endpoint": "/api/users",
      "method": "GET",
      "description": "查询用户列表",
      "detail_anchor": "§3.2.1",
      "request_fields": [
        {
          "name": "page",
          "type": "Integer",
          "required": false,
          "description": "页码"
        },
        {
          "name": "size",
          "type": "Integer",
          "required": false,
          "description": "每页大小"
        }
      ],
      "response_fields": [
        {
          "name": "total",
          "type": "Long",
          "description": "总数"
        },
        {
          "name": "items",
          "type": "List<User>",
          "description": "用户列表"
        }
      ]
    },
    {
      "endpoint": "/api/users",
      "method": "POST",
      "description": "创建用户",
      "detail_anchor": "§3.2.2",
      "request_fields": [
        {
          "name": "username",
          "type": "String",
          "required": true,
          "description": "用户名"
        },
        {
          "name": "email",
          "type": "String",
          "required": true,
          "description": "邮箱"
        }
      ],
      "response_fields": [
        {
          "name": "id",
          "type": "Long",
          "description": "用户ID"
        }
      ]
    }
  ],
  "pages": [],
  "rules": [
    {
      "id": "R-001",
      "description": "用户名必须唯一",
      "type": "校验",
      "enforcement": "必须",
      "detail_anchor": "§4.1"
    }
  ],
  "client": {
    "scope": "not-applicable"
  },
  "migrations": [],
  "decisions": [
    {
      "id": "DDR-001",
      "title": "用户表设计",
      "context": "需要存储用户基本信息",
      "decision": "使用单表存储",
      "rationale": "数据量小，单表足够",
      "alternatives": [],
      "consequences": []
    }
  ],
  "business_operations": [],
  "baseline": {
    "prd_hash": "abc123",
    "criteria_hash": "def456"
  },
  "zero_results": []
}
EOF

echo -e "${GREEN}[2/5]${NC} 创建示例 acceptance.json..."

cat > "$DEMO_DIR/.devflow/demo-feature/acceptance.json" <<'EOF'
{
  "feature": "demo-feature",
  "generated_at": "2026-09-20T10:00:00Z",
  "template": {
    "id": "验收点-模板",
    "version": "3.27.0"
  },
  "feature_name": "用户管理 Demo",
  "module": "01",
  "prd_doc": "docs/prd/demo.md",
  "date": "2026-09-20",
  "splitter": "devflow",
  "points": [
    {
      "id": "M-01-F01-A01",
      "feature_label": "用户列表",
      "description": "用户列表页面展示所有用户",
      "verify_method": "UI",
      "prd_anchor": "docs/prd/demo.md#用户列表",
      "status": "FROZEN"
    },
    {
      "id": "M-01-F01-A02",
      "feature_label": "用户列表",
      "description": "点击新增按钮跳转到创建页面",
      "verify_method": "UI",
      "prd_anchor": "docs/prd/demo.md#新增用户",
      "status": "FROZEN"
    },
    {
      "id": "M-01-F01-A03",
      "feature_label": "用户列表",
      "description": "API 返回用户列表数据正确",
      "verify_method": "API",
      "prd_anchor": "docs/prd/demo.md#API",
      "status": "FROZEN"
    }
  ],
  "reviews": [],
  "signoffs": [
    {
      "role": "产品",
      "name": "Demo User",
      "date": "2026-09-20"
    }
  ],
  "zero_results": []
}
EOF

echo -e "${GREEN}[3/5]${NC} 生成 JUnit 测试..."
echo ""

cd "$DEMO_DIR"
"${DEVFLOW_PY[@]}" "$SCRIPT_DIR/generate_junit_tests.py" \
  ".devflow/demo-feature/design.json" \
  "backend/src/test/java"

echo ""
echo -e "${GREEN}[4/5]${NC} 生成 Playwright 测试..."
echo ""

"${DEVFLOW_PY[@]}" "$SCRIPT_DIR/generate_playwright_tests.py" \
  ".devflow/demo-feature/acceptance.json" \
  "frontend/tests/e2e"

echo ""
echo -e "${GREEN}[5/5]${NC} 查看生成结果..."
echo ""

tree "$DEMO_DIR" -I '.devflow' || find "$DEMO_DIR" -type f | grep -v '/\.devflow/' | sort

echo ""
echo -e "${CYAN}========================================"
echo "  生成完成！"
echo "========================================${NC}"
echo ""
echo -e "${YELLOW}生成的文件位置:${NC}"
echo "  $DEMO_DIR"
echo ""
echo -e "${YELLOW}查看生成的测试:${NC}"
echo "  # JUnit 测试"
echo "  cat $DEMO_DIR/backend/src/test/java/controller/UserControllerTest.java"
echo ""
echo "  # Playwright 测试"
echo "  cat $DEMO_DIR/frontend/tests/e2e/demo-feature-M-01-F01.spec.ts"
echo ""
echo -e "${YELLOW}下一步:${NC}"
echo "  1. 查看生成的测试代码"
echo "  2. 了解需要补充的 TODO 部分"
echo "  3. 在实际项目中运行 scripts/generate_tests.sh"
echo ""
