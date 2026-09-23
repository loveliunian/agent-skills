#!/usr/bin/env bash
# P5 Gate 脚本 v3.30.5
# 用途：验证 P5 阶段是否完成（支持诊断与修复建议）

set -euo pipefail

FEATURE="${1:-}"
SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载诊断系统
source "$SKILL_ROOT/scripts/gate_diagnostics.sh" 2>/dev/null || true

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "════════════════════════════════════════════════════════════════"
echo "  P5 Gate 检查 v3.28.0"
echo "════════════════════════════════════════════════════════════════"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

check_pass() {
  echo -e "${GREEN}✓${NC} $1"
  ((PASS_COUNT++))
}

check_fail() {
  echo -e "${RED}✗${NC} $1"
  ((FAIL_COUNT++))
}

check_warn() {
  echo -e "${YELLOW}⚠${NC} $1"
}

# 1. 检查参数
if [ -z "$FEATURE" ]; then
  echo -e "${RED}❌ 缺少 feature 名称${NC}"
  echo "用法: bash $0 <feature-name>"
  exit 1
fi

echo "[检查 1/6] 测试代码存在性"
echo "─────────────────────────────────────────────────────────────"

# JUnit 测试
JUNIT_COUNT=$(find backend/src/test/java -name "*Test.java" 2>/dev/null | wc -l || echo 0)
if [ "$JUNIT_COUNT" -ge 3 ]; then
  check_pass "JUnit 测试文件数量：$JUNIT_COUNT"
else
  check_fail "JUnit 测试文件数量不足：${JUNIT_COUNT}（预期 ≥ 3）"
fi

# Playwright 测试
E2E_COUNT=$(find frontend/tests/e2e -name "*.spec.ts" 2>/dev/null | wc -l || echo 0)
if [ "$E2E_COUNT" -ge 1 ]; then
  check_pass "Playwright 测试文件数量：$E2E_COUNT"
else
  check_fail "Playwright 测试文件数量不足：${E2E_COUNT}（预期 ≥ 1）"
fi

echo ""
echo "[检查 2/6] TODO 清理检查"
echo "─────────────────────────────────────────────────────────────"

TODO_COUNT=$(grep -rn "TODO:" backend/src/test/java/ frontend/tests/e2e/ 2>/dev/null | wc -l || echo 0)
if [ "$TODO_COUNT" -eq 0 ]; then
  check_pass "所有 TODO 已处理"
else
  check_warn "仍有 $TODO_COUNT 个未处理的 TODO"
  
  # 诊断与修复建议
  if type diagnose_and_suggest &>/dev/null; then
    diagnose_and_suggest "P5 Gate" "TODO_NOT_CLEARED" "$FEATURE"
  else
    echo ""
    echo "  请运行以下命令查看详情："
    echo "  grep -rn \"TODO:\" backend/src/test/java/ frontend/tests/e2e/"
    echo ""
  fi
fi

echo ""
echo "[检查 3/6] 编译通过检查"
echo "─────────────────────────────────────────────────────────────"

# JUnit 编译
if mvn test-compile -q 2>/dev/null; then
  check_pass "JUnit 测试编译通过"
else
  check_fail "JUnit 测试编译失败"
  
  # 诊断与修复建议
  if type diagnose_and_suggest &>/dev/null; then
    diagnose_and_suggest "P5 Gate" "COMPILATION_ERROR" "backend/src/test/java"
  fi
fi

# TypeScript 编译
if [ -d "frontend" ]; then
  cd frontend
  if tsc --noEmit 2>/dev/null; then
    check_pass "TypeScript 测试编译通过"
  else
    check_fail "TypeScript 测试编译失败"
    
    # 诊断与修复建议
    if type diagnose_and_suggest &>/dev/null; then
      diagnose_and_suggest "P5 Gate" "COMPILATION_ERROR" "frontend/tests/e2e"
    fi
  fi
  cd ..
fi

echo ""
echo "[检查 4/6] 测试用例文档完整性"
echo "─────────────────────────────────────────────────────────────"

TEST_CASE_DOC="docs/测试用例/${FEATURE}-测试用例.md"
if [ ! -f "$TEST_CASE_DOC" ]; then
  TEST_CASE_DOC="docs/test-cases/${FEATURE}-test-cases.md"
fi

if [ -f "$TEST_CASE_DOC" ]; then
  DOC_LINES=$(wc -l < "$TEST_CASE_DOC")
  if [ "$DOC_LINES" -ge 200 ]; then
    check_pass "测试用例文档存在且完整（$DOC_LINES 行）"
  else
    check_fail "测试用例文档行数不足：${DOC_LINES}（预期 ≥ 200）"
  fi
else
  check_fail "测试用例文档不存在：$TEST_CASE_DOC"
fi

echo ""
echo "[检查 5/6] 测试覆盖率预检"
echo "─────────────────────────────────────────────────────────────"

# JUnit 测试方法数量
JUNIT_TEST_COUNT=$(grep -r "@Test" backend/src/test/java/ 2>/dev/null | wc -l || echo 0)
if [ "$JUNIT_TEST_COUNT" -ge 10 ]; then
  check_pass "JUnit 测试方法数量：$JUNIT_TEST_COUNT"
else
  check_warn "JUnit 测试方法数量较少：${JUNIT_TEST_COUNT}（建议 ≥ 10）"
fi

# Playwright 测试用例数量
E2E_TEST_COUNT=$(grep -r "test(" frontend/tests/e2e/ 2>/dev/null | wc -l || echo 0)
if [ "$E2E_TEST_COUNT" -ge 5 ]; then
  check_pass "Playwright 测试用例数量：$E2E_TEST_COUNT"
else
  check_warn "Playwright 测试用例数量较少：${E2E_TEST_COUNT}（建议 ≥ 5）"
fi

echo ""
echo "[检查 6/6] 结构化产物检查"
echo "─────────────────────────────────────────────────────────────"

TEST_CASES_JSON=".devflow/$FEATURE/test-cases.json"
if [ -f "$TEST_CASES_JSON" ]; then
  check_pass "test-cases.json 存在"
else
  check_warn "test-cases.json 不存在（非强制）"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  P5 Gate 检查结果"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo -e "通过：${GREEN}${PASS_COUNT}${NC}"
echo -e "失败：${RED}${FAIL_COUNT}${NC}"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}✅ P5 Gate 通过${NC}"
  echo ""
  echo "下一步："
  echo "  进入 P6 阶段（执行测试）"
  echo ""
  exit 0
else
  echo -e "${RED}❌ P5 Gate 失败${NC}"
  echo ""
  echo "修复建议："
  echo "  1. 补充缺失的测试文件"
  echo "  2. 处理所有 TODO 标记"
  echo "  3. 修复编译错误"
  echo "  4. 补充测试用例文档"
  echo ""
  exit 1
fi
