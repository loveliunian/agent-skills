#!/usr/bin/env bash
# gate-contract.sh — 输出指定阶段的 Gate 契约卡（v3.31.4，FB-20260919-001）
# 用法：gate-contract.sh <P0|P0b|P1|P2|P2a|P2b|P3|P3b|P3cd|P4|P4b|P5|P6|P7|P8|P9|P10|all>
# 目的：让 Agent 在产出物写作【前】读到门禁契约，消除「渲染→跑gate→失败→反查脚本」试错循环。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
DOC="$SCRIPT_DIR/../references/gate-contracts.md"
[ -f "$DOC" ] || { echo "[P0] contract card missing: $DOC"; exit 1; }

PHASE="${1:-}"
[ -n "$PHASE" ] || { grep -E '^# 用法' "$DOC" | head -1; exit 1; }

emit_section() { # 打印从 "### $1" 到下一个 "### " / "## " 之前的内容
  awk -v key="$1" '
    $0 ~ "^### " key { found=1; print; next }
    found && (/^### / || /^## /) { exit }
    found { print }
  ' "$DOC"
}

if [ "$PHASE" = "all" ]; then
  cat "$DOC"; exit 0
fi

# 归一化别名
case "$PHASE" in
  P4) KEY="P4/P4b" ;;
  P6) KEY="P6 " ;;
  *)  KEY="$PHASE" ;;
esac

OUT=$(emit_section "$KEY")
if [ -z "$OUT" ]; then
  echo "[P0] unknown phase: ${PHASE}（可选：P0 P0b P1 P2 P2a P2b P3 P3b P3cd P4 P4b P5 P6 P7 P8 P9 P10 all）"
  exit 1
fi
# 通用规则永远附带——所有 gate 共享
echo "$OUT"
echo ""
awk '/^## 通用规则/,/^## 路径桥接/' "$DOC" | sed '$d'
