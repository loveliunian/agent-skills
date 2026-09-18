#!/usr/bin/env bash
# =============================================================================
# after-gate-fail-hook.sh (v3.9.1 NEW)
# =============================================================================
# 触发时机：任何 P0-P10 gate 失败时自动调用（v3.9.5 起挂接 execute_gate 失败分支，也可手动调用）
# 作用：把失败原因写入项目本地 .devflow/<feature>/feedback/，由 P10 形成
#      可审查反馈；不得自动修改已安装 skill 或同步其他运行时副本。
#
# 用法：
#   bash scripts/hooks/after-gate-fail-hook.sh <feature> <stage> "<reason>"
#   GATE_LOG=<gate-output.log> bash scripts/hooks/after-gate-fail-hook.sh <feature> <stage> "<reason>"
#     # 可选：附 Gate 输出分类（gate-fail-classify.sh），报告落在 <feature>/feedback/
#   bash scripts/hooks/after-gate-fail-hook.sh --latest
# =============================================================================
set -uo pipefail

STATE_DIR="${STATE_DIR:-.devflow}"

if [ "$#" -eq 0 ]; then
  echo "Usage:"
  echo "  $0 <feature> <stage> <reason>"
  echo "  $0 --latest"
  exit 2
fi

MODE=""
case "$1" in
  --latest)
    MODE="--latest"
    ;;
  -h|--help)
    echo "Usage:"
    echo "  $0 <feature> <stage> <reason>"
    echo "  $0 --latest"
    exit 0
    ;;
  *)
    MODE="manual"
    ;;
esac

case "$MODE" in
  --latest)
    # v3.15.12: 旧三级 xargs 链在无失败收据时以零参数执行 `ls -t` 列出当前目录——head -1
    # 使 LATEST 恒非空，"no recent fail receipts" 优雅退出永不触发（cwd 首文件被误当收据）。
    # 改判空短路（含空格路径断链为已知次要观察项，不引入新复杂度）
    FAIL_RECEIPTS=$(find "$STATE_DIR" -name "receipt.txt" -mtime -7 -print0 2>/dev/null | xargs -0 grep -l "EXIT_CODE=1" 2>/dev/null || true)
    if [ -n "$FAIL_RECEIPTS" ]; then
      LATEST=$(ls -t $FAIL_RECEIPTS 2>/dev/null | head -1)
    else
      LATEST=""
    fi
    if [ -z "$LATEST" ]; then
      echo "no recent fail receipts found"
      exit 0
    fi
    FEATURE=$(echo "$LATEST" | sed -E "s|$STATE_DIR/||;s|/gates/.*||")
    STAGE=$(echo "$LATEST" | sed -E "s|.*/gates/||;s|/.*||")
    REASON=$(cat "$LATEST" | grep -E '^(FAIL|WARN)=' | head -1)
    ;;
  manual)
    FEATURE="${1:-unknown}"
    STAGE="${2:-P0}"
    # v3.9.1: 把剩余参数合并成 REASON（容忍空格）；v3.14.0 参数不足时不再让 shift 报错
    if [ "$#" -ge 2 ]; then shift 2; elif [ "$#" -ge 1 ]; then shift 1; fi
    REASON="${*:-unknown reason}"
    ;;
esac

# v3.15.11: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（实测
# `after-gate-fail-hook.sh "../../evil" P3 "boom"` 在项目外建 feedback 目录写文件）；
# --latest 分支 FEATURE 源自 find 输出一并校验；build-watchdog v3.15.10 同型收口
source "$(cd "$(dirname "$0")/.." && pwd)/devflow_feature.sh" || { echo "[FATAL] devflow_feature.sh 加载失败" >&2; exit 2; }
SKILL_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
devflow_feature_validate "$FEATURE" || exit 2

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FEEDBACK_DIR="$STATE_DIR/${FEATURE}/feedback"
FEEDBACK_FILE="$FEEDBACK_DIR/feedback.md"
mkdir -p "$FEEDBACK_DIR"
if [ ! -f "$FEEDBACK_FILE" ]; then
  cat > "$FEEDBACK_FILE" <<EOF
# Project feedback queue

SCOPE=project
STATUS=PROPOSED
EOF
fi
cat >> "$FEEDBACK_FILE" <<EOF

FEEDBACK_ID=GF-$(date +%Y%m%d%H%M%S)-${STAGE}
OCCURRED_AT=$TIMESTAMP
STAGE=$STAGE
REASON=$REASON
EOF

# v3.27.11: 可选 Gate 输出分类——execute_gate 失败时把 Gate 日志写入 GATE_LOG，
# 这里生成错误分类/修复建议/关联教训报告，供修复与 P10 复盘消费（失败不阻断钩子）。
GATE_LOG="${GATE_LOG:-}"
CLASSIFY="$SKILL_ROOT/scripts/gate-fail-classify.sh"
if [ -n "$GATE_LOG" ] && [ -f "$GATE_LOG" ] && [ -f "$CLASSIFY" ]; then
  CLASSIFY_OUT="$FEEDBACK_DIR/gate-classification-$(date -u +%Y%m%dT%H%M%SZ).md"
  bash "$CLASSIFY" "$GATE_LOG" "$SKILL_ROOT/concepts/lessons-learned.md" > "$CLASSIFY_OUT" 2>&1 || true
  echo "[HOOK] Gate 分类报告: $CLASSIFY_OUT"
fi

echo "[HOOK] 失败反馈已写入: $FEEDBACK_FILE"
echo "[HOOK] Feature: $FEATURE  Stage: $STAGE"
echo "[HOOK] Reason:  $REASON"
exit 0
