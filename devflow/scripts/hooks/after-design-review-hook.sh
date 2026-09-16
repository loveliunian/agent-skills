#!/usr/bin/env bash
# ============================================================
# after-design-review-hook.sh 
# ------------------------------------------------------------
# 用途：设计评审结束后，分析评审问题，更新详细设计相关模板
# 用法：bash after-design-review-hook.sh <feature>
# ============================================================

set -eo pipefail


# 颜色定义
GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; NC='\033[0m'
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
success(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# 主函数
main() {
  local feature="$1"
  local design_review="docs/detailed-design/${feature}-design-review.md"
  local improvements_file
  improvements_file="${PROJECT_ROOT:-$PWD}/.devflow/template-improvements/design-$(date +%Y%m).md"

  # v3.14.1: feature 名白名单校验，防误传旗标当 feature
  if [ -z "$feature" ]; then
    echo "用法: $0 <feature>"
    exit 1
  fi
  case "$feature" in
    ''-*|*[!A-Za-z0-9._-]*) echo "[FAIL] 非法 feature 名（应为字母数字/点/下划线/连字符）: $feature"; exit 2 ;;
  esac

  info "分析设计评审问题..."

  mkdir -p "$(dirname "$improvements_file")"

  # 分析问题
  local schema_issues
  schema_issues=$(grep -cE "数据模型.*问题|字段.*不清|表结构" "$design_review" 2>/dev/null || true)
  schema_issues=${schema_issues:-0}
  local api_issues
  api_issues=$(grep -cE "接口.*不清|契约.*问题|参数" "$design_review" 2>/dev/null || true)
  api_issues=${api_issues:-0}
  local flow_issues
  flow_issues=$(grep -cE "流程.*不清|逻辑.*问题|异常.*处理" "$design_review" 2>/dev/null || true)
  flow_issues=${flow_issues:-0}

  local issue_count
  issue_count=$((schema_issues + api_issues + flow_issues))

  {
    echo "# 详细设计模板改进建议 ($(date))"
    echo ""
    echo "Feature: $feature"
    echo "问题数: $issue_count"
    echo ""
  } > "$improvements_file"

  if [ "$schema_issues" -gt 0 ]; then
    echo "### 详细设计-模板.md 添加字段完整性检查清单" >> "$improvements_file"
    warn "建议改进详设模板：添加字段完整性检查清单"
  fi

  if [ "$api_issues" -gt 0 ]; then
    echo "### 详细设计-模板.md 添加接口契约示例" >> "$improvements_file"
    warn "建议改进详设模板：添加接口契约示例"
  fi

  if [ "$flow_issues" -gt 0 ]; then
    echo "### 详细设计-模板.md 添加异常流程说明模板" >> "$improvements_file"
    warn "建议改进详设模板：添加异常流程说明模板"
  fi

  success "改进建议已生成: $improvements_file"
}

main "$@"
