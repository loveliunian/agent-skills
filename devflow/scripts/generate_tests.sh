#!/bin/bash
# 测试生成器入口脚本
#
# 用法: 
#   bash scripts/generate_tests.sh <feature> [--junit-only|--playwright-only]
#
# 示例:
#   bash scripts/generate_tests.sh user-mgmt
#   bash scripts/generate_tests.sh user-mgmt --junit-only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
测试生成器 - 从 design.json 和 acceptance.json 生成测试代码

用法:
  $0 <feature> [options]

选项:
  --junit-only         只生成 JUnit 单元测试
  --playwright-only    只生成 Playwright E2E 测试
  --output-backend     后端测试输出目录（默认: backend/<service>/src/test/java）
  --output-frontend    前端测试输出目录（默认: frontend/tests/e2e）
  --profile            Runtime Profile ID（默认: java-spring-flyway）

示例:
  $0 user-mgmt
  $0 user-mgmt --junit-only
  $0 user-mgmt --output-backend backend/user-service/src/test/java

要求:
  - .devflow/<feature>/design.json 必须存在（用于 JUnit）
  - .devflow/<feature>/acceptance.json 必须存在（用于 Playwright）
  - Python 3.8+ 可用
EOF
}

# 解析参数
FEATURE=""
JUNIT_ONLY=false
PLAYWRIGHT_ONLY=false
OUTPUT_BACKEND=""
OUTPUT_FRONTEND=""
PROFILE_ID="java-spring-flyway"

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            usage
            exit 0
            ;;
        --junit-only)
            JUNIT_ONLY=true
            shift
            ;;
        --playwright-only)
            PLAYWRIGHT_ONLY=true
            shift
            ;;
        --output-backend)
            OUTPUT_BACKEND="$2"
            shift 2
            ;;
        --output-frontend)
            OUTPUT_FRONTEND="$2"
            shift 2
            ;;
        --profile)
            PROFILE_ID="$2"
            shift 2
            ;;
        -*)
            echo -e "${RED}[ERROR]${NC} 未知选项: $1"
            usage
            exit 1
            ;;
        *)
            FEATURE="$1"
            shift
            ;;
    esac
done

if [[ -z "$FEATURE" ]]; then
    echo -e "${RED}[ERROR]${NC} 缺少 feature 参数"
    usage
    exit 1
fi

# 设置默认输出路径
if [[ -z "$OUTPUT_BACKEND" ]]; then
    # 尝试从 profile 推断
    if [[ -f "$SKILL_ROOT/runtime-profiles/$PROFILE_ID.json" ]]; then
        SERVICE_NAME=$(echo "$FEATURE" | cut -d'-' -f1)
        OUTPUT_BACKEND="backend/${SERVICE_NAME}-service/src/test/java"
    else
        OUTPUT_BACKEND="backend/src/test/java"
    fi
fi

if [[ -z "$OUTPUT_FRONTEND" ]]; then
    OUTPUT_FRONTEND="frontend/tests/e2e"
fi

# 检查 Python
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}[ERROR]${NC} Python 3 未安装"
    exit 1
fi

PYTHON_VERSION=$(python3 --version | awk '{print $2}')
echo -e "${GREEN}[INFO]${NC} 使用 Python $PYTHON_VERSION"

# 路径
DEVFLOW_DIR=".devflow/$FEATURE"
DESIGN_JSON="$DEVFLOW_DIR/design.json"
ACCEPTANCE_JSON="$DEVFLOW_DIR/acceptance.json"

echo "========================================"
echo "  测试生成器 v1.0.0"
echo "========================================"
echo "Feature: $FEATURE"
echo "Profile: $PROFILE_ID"
echo "Backend Output: $OUTPUT_BACKEND"
echo "Frontend Output: $OUTPUT_FRONTEND"
echo "========================================"

# 生成 JUnit 测试
if [[ "$PLAYWRIGHT_ONLY" == false ]]; then
    echo ""
    echo -e "${GREEN}[1/2]${NC} 生成 JUnit 单元测试..."
    
    if [[ ! -f "$DESIGN_JSON" ]]; then
        echo -e "${YELLOW}[WARN]${NC} design.json 不存在，跳过 JUnit 生成: $DESIGN_JSON"
    else
        python3 "$SCRIPT_DIR/generate_junit_tests.py" "$DESIGN_JSON" "$OUTPUT_BACKEND"
        
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}[SUCCESS]${NC} JUnit 测试生成完成"
        else
            echo -e "${RED}[ERROR]${NC} JUnit 测试生成失败"
            exit 1
        fi
    fi
fi

# 生成 Playwright 测试
if [[ "$JUNIT_ONLY" == false ]]; then
    echo ""
    echo -e "${GREEN}[2/2]${NC} 生成 Playwright E2E 测试..."
    
    if [[ ! -f "$ACCEPTANCE_JSON" ]]; then
        echo -e "${YELLOW}[WARN]${NC} acceptance.json 不存在，跳过 Playwright 生成: $ACCEPTANCE_JSON"
    else
        python3 "$SCRIPT_DIR/generate_playwright_tests.py" "$ACCEPTANCE_JSON" "$OUTPUT_FRONTEND"
        
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}[SUCCESS]${NC} Playwright 测试生成完成"
        else
            echo -e "${RED}[ERROR]${NC} Playwright 测试生成失败"
            exit 1
        fi
    fi
fi

echo ""
echo "========================================"
echo -e "${GREEN}[DONE]${NC} 测试生成完成"
echo "========================================"
echo ""
echo "下一步:"
echo "  1. 检查生成的测试代码"
echo "  2. 补充 TODO 标记的测试逻辑"
echo "  3. 调整选择器和断言"
echo ""
echo "运行测试:"
echo "  # JUnit"
echo "  mvn test"
echo ""
echo "  # Playwright"
echo "  cd frontend && npx playwright test"
echo ""
