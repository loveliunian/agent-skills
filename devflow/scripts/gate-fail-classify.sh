#!/usr/bin/env bash
# =============================================================================
# Gate 失败分类器 + 教训自动匹配（v3.29.2，FB-20260918-002）
# =============================================================================
# 用法：
#   bash scripts/gate-fail-classify.sh <gate-output.log> [feature]
#   bash scripts/gate-fail-classify.sh <gate-output.log> <lesson-lib.md>
#
# 功能：
#   1. 解析 Gate 输出中的 [P0]/[FAIL]/ERROR 行
#   2. 按错误模式分类（ MISSING_FILE / VALIDATION / DEPENDENCY / INFRA / TEST_FAIL / PLACEHOLDER ）
#   3. 匹配 lessons-learned.md 中的相关教训
#   4. 输出结构化建议
# =============================================================================
set -uo pipefail
LC_ALL=C; export LC_ALL

LOG_FILE="${1:?Usage: $0 <gate-output.log> [lesson-lib.md]}"
LESSON_LIB="${2:-}"

[ -f "$LOG_FILE" ] || { echo "[ERR] log file not found: $LOG_FILE"; exit 2; }

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
# 输出重定向到文件时关闭颜色（v3.27.11：分类报告常由失败钩子落盘，避免 ANSI 转义污染日志）
if [ ! -t 1 ]; then RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''; fi

# ---------- 分类规则（v3.27.11：删除未接线的逐行 classify()，只保留全文匹配表） ----------
# 规格：pattern|CATEGORY|建议动作|教训关键词（教训为空则跳过教训匹配）

# ---------- 解析 Gate 输出 ----------
P0_COUNT=0
FAIL_COUNT=0
matched_categories=""
matched_suggestions=""
matched_lessons=""

while IFS= read -r line; do
  if echo "$line" | grep -qE '\[P0\]|\[FAIL\]|ERROR:|COMPILATION ERROR'; then
    if echo "$line" | grep -q '\[P0\]'; then P0_COUNT=$((P0_COUNT+1)); fi
    if echo "$line" | grep -q '\[FAIL\]'; then FAIL_COUNT=$((FAIL_COUNT+1)); fi
  fi
done < "$LOG_FILE"

# 对整个文件做分类（不用逐行，用 grep 对全文匹配）
for spec in \
  "missing.*file|MISSING_FILE|检查前置产物是否存在|L-M01-002 基线冒烟" \
  "Field missing|SCHEMA_FIELD|检查实体字段短类型名|L-M01-003" \
  "sha.*mismatch|EVIDENCE_DRIFT|确认证据未被修改；重跑对应 Gate 刷新收据|L-M01-005" \
  "version.*expected|VERSION_DRIFT|运行 devflow-state.sh migrate-tree|L-M01-008" \
  "占位符|PLACEHOLDER|填实事实源骨架占位符|L-M01-009" \
  "TODO|FIXME|TODO_RESIDUE|删除或完成所有 TODO/FIXME|" \
  "PreAuthorize|PERMISSION|检查 @PreAuthorize；对照 _权限矩阵.md|R38" \
  "menu.*seed|MENU_SEED|确认四方言 seed 覆盖 4 张表|菜单Seed索引" \
  "logic.delete|LOGIC_DELETE|禁用全局 logic-delete；LambdaUpdateWrapper.set 显式置位|L-M01-001" \
  "LIMIT 1|SQL_DIALECT|用 selectList 替代 .last(LIMIT)|L-M01-002 四方言" \
  "FAILED.*test|TEST_FAIL|查看 surefire-reports；修复后重跑|" \
  "cannot find symbol|COMPILE_ERROR|检查 import/类型/方法签名|" \
  "springdoc|swagger|DEAD_CONFIG|引入 springdoc 依赖或移除死配置|L-M01-010" ; do
  IFS='|' read -r pattern cat fix lesson <<< "$spec"
  if grep -qiE "$pattern" "$LOG_FILE" 2>/dev/null; then
    matched_categories+="$cat "
    matched_suggestions+="[$cat] ${fix}（关联: ${lesson:-—}）"$'\n'
    if [ -n "$lesson" ] && [ -n "$LESSON_LIB" ] && [ -f "$LESSON_LIB" ]; then
      hits=$(grep -iE "$lesson" "$LESSON_LIB" 2>/dev/null | grep -E "^##" | head -1 | sed 's/^##*[[:space:]]*/📚 /')
      [ -n "$hits" ] && matched_lessons+="$hits"$'\n'
    fi
  fi
done

# ---------- 教训库匹配（基于错误关键词全文搜索） ----------
if [ -n "$LESSON_LIB" ] && [ -f "$LESSON_LIB" ]; then
  for kw in "logic.delete" "LIMIT 1" "FQCN\|短类型名" "updateById.*null\|空值.*陷阱" "渲染.*事故\|整篇覆盖" "menu.*seed\|四方言"; do
    if grep -qiE "$kw" "$LOG_FILE" 2>/dev/null; then
      hits=$(grep -iE "$kw" "$LESSON_LIB" | grep -E "^#{2,3} " | head -2 | sed 's/^#*//;s/^/  📚 /')
      if [ -n "$hits" ]; then
        matched_lessons+="$hits"$'\n'
      fi
    fi
  done
fi

# ---------- 输出 ----------
echo "============================================="
echo "  Gate 失败分类器（v1.0）"
echo "============================================="
echo "日志: $LOG_FILE"
echo ""

if [ "$P0_COUNT" -eq 0 ] && [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${GREEN}[PASS] 未检测到失败${NC}"
  exit 0
fi

echo -e "${RED}检测到失败：P0=$P0_COUNT FAIL=$FAIL_COUNT${NC}"
echo ""

if [ -n "$matched_categories" ]; then
  echo -e "${CYAN}错误分类：${NC}"
  for cat in $matched_categories; do
    echo "  • $cat"
  done
  echo ""
fi

if [ -n "$matched_suggestions" ]; then
  echo -e "${YELLOW}修复建议：${NC}"
  echo "$matched_suggestions" | while IFS= read -r s; do
    [ -n "$s" ] && echo "  → $s"
  done
  echo ""
fi

if [ -n "$matched_lessons" ] && [ -n "$LESSON_LIB" ]; then
  echo -e "${CYAN}关联教训：${NC}"
  echo "$matched_lessons"
fi

echo "============================================="
echo ""
echo "修复后重跑对应 Gate；连续失败 3 次建议人工介入。"
exit 1
