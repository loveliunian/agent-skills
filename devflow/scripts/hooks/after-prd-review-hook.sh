#!/usr/bin/env bash
# ============================================================
# after-prd-review-hook.sh 
# ------------------------------------------------------------
# 用途：PRD 评审结束后，分析评审问题，更新 PRD 相关模板
# 用法：bash after-prd-review-hook.sh <feature>
# ============================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
TEMPLATES_DIR="$SKILL_ROOT/templates"

# 颜色定义
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; NC='\033[0m'
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
success(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 主函数
main() {
  local feature="$1"
  # v3.22.0: PRD 评审产物中英双语
  local prd_review=""
  source "$(cd "$(dirname "$0")" && pwd)/../devflow_paths.sh"
  prd_review="$(df_resolve_doc "$feature" prd_review .md requirements)"
  [ -n "$prd_review" ] || prd_review="docs/requirements/${feature}-prd-review.md"
  local improvements_file
  improvements_file="${PROJECT_ROOT:-$PWD}/.devflow/template-improvements/prd-review-$(date +%Y%m).md"

  # v3.14.1: feature 名白名单校验，防误传旗标当 feature
  if [ -z "$feature" ]; then
    echo "用法: $0 <feature>"
    echo "示例: $0 m-03"
    exit 1
  fi
  case "$feature" in
    ''-*|*[!A-Za-z0-9._-]*) echo "[FAIL] 非法 feature 名（应为字母数字/点/下划线/连字符）: $feature"; exit 2 ;;
  esac

  info "分析 PRD 评审问题: $prd_review"

  # 创建改进建议目录
  mkdir -p "$(dirname "$improvements_file")"

  # 分析评审问题
  local business_issues=0
  local tech_issues=0
  local test_issues=0
  local security_issues=0

  if [ -f "$prd_review" ]; then
    business_issues=$(grep -cE "业务.*疑问|需求.*不清|歧义" "$prd_review" 2>/dev/null || true)
    business_issues=${business_issues:-0}
    tech_issues=$(grep -cE "技术.*疑问|可行性.*不确定|风险" "$prd_review" 2>/dev/null || true)
    tech_issues=${tech_issues:-0}
    test_issues=$(grep -cE "测试.*疑问|验收.*不清|边界.*模糊" "$prd_review" 2>/dev/null || true)
    test_issues=${test_issues:-0}
    security_issues=$(grep -cE "安全.*疑问|权限.*不清|合规" "$prd_review" 2>/dev/null || true)
    security_issues=${security_issues:-0}
  fi

  local issue_count
  issue_count=$((business_issues + tech_issues + test_issues + security_issues))

  echo "" > "$improvements_file"
  echo "# PRD 相关模板改进建议 ($(date))" >> "$improvements_file"
  echo "" >> "$improvements_file"
  echo "Feature: $feature" >> "$improvements_file"
  echo "评审问题数: $issue_count" >> "$improvements_file"
  echo "" >> "$improvements_file"

  # 生成改进建议
  {
    echo "## 问题分布"
    echo "- 业务问题: $business_issues"
    echo "- 技术问题: $tech_issues"
    echo "- 测试问题: $test_issues"
    echo "- 安全问题: $security_issues"
    echo ""
    echo "## 具体改进"
  } >> "$improvements_file"

  if [ "$business_issues" -gt 0 ]; then
    echo "" >> "$improvements_file"
    echo "### 需求澄清-模板.md 添加歧义检测清单" >> "$improvements_file"
    warn "建议改进需求澄清模板：添加歧义检测清单"
  fi

  if [ "$tech_issues" -gt 0 ]; then
    echo "" >> "$improvements_file"
    echo "### PRD评审-模板.md 添加技术可行性评审章节" >> "$improvements_file"
    warn "建议改进 PRD评审模板：添加技术可行性评审章节"
  fi

  if [ "$test_issues" -gt 0 ]; then
    echo "" >> "$improvements_file"
    echo "### 测试用例-模板.md 添加边界条件检测清单" >> "$improvements_file"
    warn "建议改进测试用例模板：添加边界条件检测清单"
  fi

  if [ "$security_issues" -gt 0 ]; then
    echo "" >> "$improvements_file"
    echo "### PRD评审-模板.md 添加安全合规评审章节" >> "$improvements_file"
    warn "建议改进 PRD评审模板：添加安全合规评审章节"
  fi

  success "改进建议已生成: $improvements_file"
  echo ""
  echo "请查看改进建议，手动更新模板："
  echo "  vim $TEMPLATES_DIR/需求澄清-模板.md"
  echo "  vim $TEMPLATES_DIR/PRD评审-模板.md"
}

main "$@"
