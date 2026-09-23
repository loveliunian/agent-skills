#!/usr/bin/env bash
# =============================================================================
# P0 Gate 扩展：实体/操作提取稳定性对比 (v3.30.7)
# =============================================================================
# 
# 用途：在 P0 Gate 后增加稳定性对比检查
#       对比当前 clarification.json 与历史版本的实体/操作提取结果
#       评估提取稳定性（稳定性分数 < 90 = 警告，不阻断）
#
# 触发条件：
#   1. 存在历史 clarification.json（.devflow/<feature>/clarification-history/ 目录）
#   2. 当前 clarification.json 已通过 s0_acceptance_gate.sh
#
# 产物：
#   - .devflow/<feature>/gates/P0/stability-report.txt
#   - docs/<feature>/gates/P0/stability-report.txt (镜像)
#
# 退出码：
#   0 - 对比完成（即使稳定性低也不阻断）
#   1 - 脚本错误（文件缺失、JSON 格式错误等）
# =============================================================================

set -euo pipefail

# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/py_runtime.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# 推导 feature
source "$SCRIPT_DIR/devflow_feature.sh"
EFF_FEATURE="$(devflow_feature "${FEATURE:-}")" || { echo "[FATAL] feature 推导失败"; exit 1; }
[ -n "$EFF_FEATURE" ] || { echo "[FATAL] feature 为空"; exit 1; }

STATE_DIR="${STATE_DIR:-.devflow}"
HISTORY_DIR="$STATE_DIR/${EFF_FEATURE}/clarification-history"
CURRENT_JSON="$STATE_DIR/${EFF_FEATURE}/clarification.json"

echo ""
echo "=== P0 实体/操作提取稳定性对比 (v3.28.1) ==="
echo "Feature: $EFF_FEATURE"
echo ""

# 检查当前 clarification.json 是否存在
if [ ! -f "$CURRENT_JSON" ]; then
  echo "⚠️  当前 clarification.json 不存在: $CURRENT_JSON"
  echo "   跳过稳定性对比"
  exit 0
fi

# 检查历史目录是否存在
if [ ! -d "$HISTORY_DIR" ]; then
  echo "ℹ️  历史目录不存在: $HISTORY_DIR"
  echo "   这是首次提取，跳过稳定性对比"
  echo "   备份当前版本到历史目录..."
  
  mkdir -p "$HISTORY_DIR"
  TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
  cp "$CURRENT_JSON" "$HISTORY_DIR/clarification-${TIMESTAMP}.json"
  echo "   已备份: $HISTORY_DIR/clarification-${TIMESTAMP}.json"
  exit 0
fi

# 查找最近的历史版本
LATEST_HISTORY=$(ls -t "$HISTORY_DIR"/clarification-*.json 2>/dev/null | head -1 || true)

if [ -z "$LATEST_HISTORY" ]; then
  echo "ℹ️  历史目录为空，跳过稳定性对比"
  echo "   备份当前版本到历史目录..."
  
  TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
  cp "$CURRENT_JSON" "$HISTORY_DIR/clarification-${TIMESTAMP}.json"
  echo "   已备份: $HISTORY_DIR/clarification-${TIMESTAMP}.json"
  exit 0
fi

echo "对比版本:"
echo "  历史: $LATEST_HISTORY"
echo "  当前: $CURRENT_JSON"
echo ""

# 调用对比工具
COMPARE_SCRIPT="$SCRIPT_DIR/compare_clarification_stability.py"

if [ ! -f "$COMPARE_SCRIPT" ]; then
  echo "❌ 对比工具不存在: $COMPARE_SCRIPT"
  exit 1
fi

if ! devflow_py_ok; then
  echo "❌ Python 3 未安装（python3/python/py 均未找到），无法执行稳定性对比"
  exit 1
fi

# 执行对比
REPORT_OUTPUT=$(mktemp -t p0-stability.XXXXXX)

if "${DEVFLOW_PY[@]}" "$COMPARE_SCRIPT" "$LATEST_HISTORY" "$CURRENT_JSON" > "$REPORT_OUTPUT" 2>&1; then
  cat "$REPORT_OUTPUT"
  
  # 提取综合稳定性分数
  STABILITY_SCORE=$(grep '综合稳定性分数:' "$REPORT_OUTPUT" | grep -oE '[0-9]+\.[0-9]+' || echo "0")
  
  echo ""
  echo "=== 稳定性评估 ==="
  
  if awk "BEGIN {exit !($STABILITY_SCORE >= 90)}"; then
    echo "✅ 提取稳定性良好 (分数: $STABILITY_SCORE/100)"
  elif awk "BEGIN {exit !($STABILITY_SCORE >= 75)}"; then
    echo "⚠️  提取稳定性一般，有波动 (分数: $STABILITY_SCORE/100)"
  else
    echo "⚠️  提取稳定性较差，波动较大 (分数: $STABILITY_SCORE/100)"
    echo "   建议："
    echo "   1. 复查 PRD 理解是否一致"
    echo "   2. 检查实体/操作定义的边界是否清晰"
    echo "   3. 确认是否有重命名而非真正的新增/删除"
  fi
  
  # 保存报告到 receipt
  RECEIPT_DIR="$STATE_DIR/${EFF_FEATURE}/gates/P0"
  mkdir -p "$RECEIPT_DIR"
  cp "$REPORT_OUTPUT" "$RECEIPT_DIR/stability-report.txt"
  echo ""
  echo "[RECEIPT] 稳定性报告已保存: $RECEIPT_DIR/stability-report.txt"
  
  # 镜像到 docs
  DOCS_MIRROR="docs/${EFF_FEATURE}/gates/P0"
  if [ "$EFF_FEATURE" != "default" ]; then
    mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$REPORT_OUTPUT" "$DOCS_MIRROR/stability-report.txt" 2>/dev/null \
      && echo "[RECEIPT] 已镜像: $DOCS_MIRROR/stability-report.txt"
  fi
  
  # 备份当前版本到历史
  TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
  cp "$CURRENT_JSON" "$HISTORY_DIR/clarification-${TIMESTAMP}.json"
  echo "[BACKUP] 已备份当前版本: $HISTORY_DIR/clarification-${TIMESTAMP}.json"
  
else
  echo "❌ 稳定性对比失败"
  cat "$REPORT_OUTPUT"
  rm -f "$REPORT_OUTPUT"
  exit 1
fi

rm -f "$REPORT_OUTPUT"

echo ""
echo "✅ P0 稳定性对比完成（不阻断 Gate）"
exit 0
