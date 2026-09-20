#!/bin/bash
# 测试生成器与 Runtime Profile 验证脚本
#
# 用法: bash scripts/verify_test_generators.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check_pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    ((PASS++))
}

check_fail() {
    echo -e "  ${RED}✗${NC} $1"
    ((FAIL++))
}

check_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
    ((WARN++))
}

echo -e "${BLUE}========================================"
echo "  测试生成器验证"
echo "========================================${NC}"
echo ""

# 1. 检查 Python 环境
echo "[1/8] 检查 Python 环境..."
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version | awk '{print $2}')
    MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
    MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)
    
    if [[ $MAJOR -ge 3 ]] && [[ $MINOR -ge 8 ]]; then
        check_pass "Python $PYTHON_VERSION (>= 3.8)"
    else
        check_fail "Python $PYTHON_VERSION (需要 >= 3.8)"
    fi
else
    check_fail "Python 3 未安装"
fi
echo ""

# 2. 检查 Runtime Profiles
echo "[2/8] 检查 Runtime Profiles..."
PROFILES=(
    "java-spring-flyway"
    "node-express-prisma"
    "python-fastapi-sqlalchemy"
)

for profile in "${PROFILES[@]}"; do
    if [[ -f "$SKILL_ROOT/runtime-profiles/$profile.json" ]]; then
        # 验证 JSON 格式
        if python3 -c "import json; json.load(open('$SKILL_ROOT/runtime-profiles/$profile.json'))" 2>/dev/null; then
            check_pass "$profile.json 格式正确"
        else
            check_fail "$profile.json JSON 格式错误"
        fi
    else
        check_fail "$profile.json 不存在"
    fi
done
echo ""

# 3. 检查 JSON Schema
echo "[3/8] 检查 JSON Schema..."
SCHEMA_FILE="$SKILL_ROOT/schemas/runtime-profile.schema.json"
if [[ -f "$SCHEMA_FILE" ]]; then
    if python3 -c "import json; json.load(open('$SCHEMA_FILE'))" 2>/dev/null; then
        check_pass "runtime-profile.schema.json 存在且格式正确"
    else
        check_fail "runtime-profile.schema.json JSON 格式错误"
    fi
else
    check_fail "runtime-profile.schema.json 不存在"
fi
echo ""

# 4. 检查生成器脚本
echo "[4/8] 检查生成器脚本..."
GENERATORS=(
    "generate_junit_tests.py"
    "generate_playwright_tests.py"
    "generate_tests.sh"
    "demo_test_generator.sh"
)

for gen in "${GENERATORS[@]}"; do
    GEN_PATH="$SCRIPT_DIR/$gen"
    if [[ -f "$GEN_PATH" ]]; then
        if [[ -x "$GEN_PATH" ]] || [[ "$gen" == *.py ]]; then
            check_pass "$gen 存在"
        else
            check_warn "$gen 存在但不可执行"
        fi
    else
        check_fail "$gen 不存在"
    fi
done
echo ""

# 5. 检查 Python 脚本语法
echo "[5/8] 检查 Python 脚本语法..."
for py_script in generate_junit_tests.py generate_playwright_tests.py; do
    if python3 -m py_compile "$SCRIPT_DIR/$py_script" 2>/dev/null; then
        check_pass "$py_script 语法正确"
    else
        check_fail "$py_script 语法错误"
    fi
done
echo ""

# 6. 检查文档
echo "[6/8] 检查文档..."
DOCS=(
    "references/test-generators.md"
    "runtime-profiles/README.md"
)

for doc in "${DOCS[@]}"; do
    DOC_PATH="$SKILL_ROOT/$doc"
    if [[ -f "$DOC_PATH" ]]; then
        LINES=$(wc -l < "$DOC_PATH")
        check_pass "$doc 存在 ($LINES 行)"
    else
        check_fail "$doc 不存在"
    fi
done
echo ""

# 7. 检查 SKILL.md 更新
echo "[7/8] 检查 SKILL.md 更新..."
if grep -q "测试生成器" "$SKILL_ROOT/SKILL.md"; then
    check_pass "SKILL.md 已更新（包含测试生成器说明）"
else
    check_warn "SKILL.md 未提及测试生成器"
fi
echo ""

# 8. 运行简单的功能测试
echo "[8/8] 运行功能测试..."

# 创建临时测试数据
TEST_DIR="/tmp/devflow-verify-$$"
mkdir -p "$TEST_DIR/.devflow/test-feature"

# 创建最小的 design.json
cat > "$TEST_DIR/.devflow/test-feature/design.json" <<'EOF'
{
  "feature": "test-feature",
  "apis": [{"endpoint": "/api/test", "method": "GET", "description": "Test API"}],
  "tables": [{"name": "test_table"}],
  "rules": [{"id": "R-001", "description": "Test rule"}]
}
EOF

# 测试 JUnit 生成器
if python3 "$SCRIPT_DIR/generate_junit_tests.py" \
    "$TEST_DIR/.devflow/test-feature/design.json" \
    "$TEST_DIR/backend/src/test/java" &>/dev/null; then
    check_pass "JUnit 生成器可运行"
else
    check_fail "JUnit 生成器运行失败"
fi

# 创建最小的 acceptance.json
cat > "$TEST_DIR/.devflow/test-feature/acceptance.json" <<'EOF'
{
  "feature": "test-feature",
  "points": [
    {"id": "M-01-F01-A01", "description": "Test acceptance", "verify_method": "UI"}
  ]
}
EOF

# 测试 Playwright 生成器
if python3 "$SCRIPT_DIR/generate_playwright_tests.py" \
    "$TEST_DIR/.devflow/test-feature/acceptance.json" \
    "$TEST_DIR/frontend/tests/e2e" &>/dev/null; then
    check_pass "Playwright 生成器可运行"
else
    check_fail "Playwright 生成器运行失败"
fi

# 清理
rm -rf "$TEST_DIR"
echo ""

# 总结
echo -e "${BLUE}========================================"
echo "  验证结果"
echo "========================================${NC}"
echo ""
echo -e "${GREEN}通过: $PASS${NC}"
echo -e "${YELLOW}警告: $WARN${NC}"
echo -e "${RED}失败: $FAIL${NC}"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}✓ 所有检查通过！测试生成器已正确安装。${NC}"
    echo ""
    echo "下一步："
    echo "  1. 运行 Demo: bash scripts/demo_test_generator.sh"
    echo "  2. 查看文档: cat references/test-generators.md"
    echo "  3. 在实际项目中使用: bash scripts/generate_tests.sh <feature>"
    echo ""
    exit 0
else
    echo -e "${RED}✗ 发现 $FAIL 个错误，请修复后重试。${NC}"
    echo ""
    exit 1
fi
