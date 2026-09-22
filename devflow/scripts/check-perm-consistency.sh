#!/usr/bin/env bash
# =============================================================================
# P0b↔P2 权限码双口径一致性校验（v3.29.2，FB-20260918-004）
# =============================================================================
# 检查：P0b 冻结的权限码集合 ↔ P2 详设权限矩阵权限码集合 必须全等。
# 来源：L-P0-001（权限码双口径人工对账教训——v3.27.5 自动化落地）
#
# Usage:
#   bash scripts/check-perm-consistency.sh <clarification.md> <design.md>
# =============================================================================
set -uo pipefail
LC_ALL=C; export LC_ALL

CLAR="${1:?Usage: $0 <clarification.md> <design.md>}"
DESIGN="${2:?Usage: $0 <clarification.md> <design.md>}"

[ -f "$CLAR" ] || { echo "[FAIL] clarification not found: $CLAR"; exit 1; }
[ -f "$DESIGN" ] || { echo "[FAIL] design not found: $DESIGN"; exit 1; }

# 提取权限码：格式 = xxx:yyy:zzz（三段冒号分隔，不含大写）
CLAR_CODES=$(grep -vE 'df:begin|df:end|df_' "$CLAR" 2>/dev/null | grep -oE '(org|user|permgrp|menu|recycle|login):[a-z_-]+:[a-z_-]+' | LC_ALL=C sort -u)
DESIGN_CODES=$(grep -vE 'df:begin|df:end|df_' "$DESIGN" 2>/dev/null | grep -oE '(org|user|permgrp|menu|recycle|login):[a-z_-]+:[a-z_-]+' | LC_ALL=C sort -u)

CLAR_COUNT=$(printf '%s\n' "$CLAR_CODES" | grep -c . || true)
DESIGN_COUNT=$(printf '%s\n' "$DESIGN_CODES" | grep -c . || true)

echo "=== 权限码双口径一致性校验 ==="
echo "  P0b 澄清权限码: $CLAR_COUNT"
echo "  P2 权限矩阵码:  $DESIGN_COUNT"

# 设计文档多出的码 = 越权新增
EXTRA=$(comm -13 <(printf '%s\n' "$CLAR_CODES") <(printf '%s\n' "$DESIGN_CODES") | grep -c . || true)
# 澄清有的码设计缺失 = 漏覆
MISSING=$(comm -23 <(printf '%s\n' "$CLAR_CODES") <(printf '%s\n' "$DESIGN_CODES") | grep -c . || true)

if [ "$CLAR_COUNT" -eq 0 ] && [ "$DESIGN_COUNT" -eq 0 ]; then
  echo "[SKIP] 两文件均未检出权限码（可能为非权限阶段）"
  exit 0
fi

if [ "$EXTRA" -gt 0 ]; then
  echo "[FAIL] P2 设计新增了 P0b 未冻结的权限码（$EXTRA 个）："
  comm -13 <(printf '%s\n' "$CLAR_CODES") <(printf '%s\n' "$DESIGN_CODES") | head -5 | sed 's/^/  + /'
  exit 1
fi

if [ "$MISSING" -gt 0 ]; then
  echo "[FAIL] P0b 权限码未被 P2 设计覆盖（$MISSING 个）："
  comm -23 <(printf '%s\n' "$CLAR_CODES") <(printf '%s\n' "$DESIGN_CODES") | head -5 | sed 's/^/  - /'
  exit 1
fi

echo "[PASS] 权限码双口径一致（$CLAR_COUNT 码全等）"
exit 0
