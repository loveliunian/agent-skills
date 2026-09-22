#!/usr/bin/env bash
# test-refresh-receipts.sh · refresh-receipts.sh 回归（v3.29.2）
#   T1 未知参数拒绝（exit 2 + 用法，不静默忽略）
#   T2 --prd/--evidence 缺参拒绝（exit 2，不再 $2: unbound variable）
#   T3 feature 白名单（路径穿越形态拒绝）
#   T4 Gate 清单完整性（静态声明覆盖 SKILL.md Gate 矩阵 P0→P10 + reconcile --apply）
#   T5 fail-fast 动态验证（空工作区首个 Gate 失败即停，后续 Gate 不被执行）
set -uo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
R="$ROOT/scripts/refresh-receipts.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "[FAIL] $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/refresh-receipts-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# T1 未知参数
_out=$(bash "$R" fx --bogus-flag 2>&1); _rc=$?
if [ "$_rc" = "2" ] && printf '%s' "$_out" | grep -q "用法"; then
  ok "未知参数拒绝（exit 2 + 用法）"
else
  bad "未知参数未正确拒绝（rc=$_rc）: $_out"
fi

# T2 缺参（--prd / --evidence 无值）——不得出现 unbound variable
_out=$(bash "$R" fx --prd 2>&1); _rc=$?
if [ "$_rc" = "2" ] && ! printf '%s' "$_out" | grep -q "unbound"; then
  ok "--prd 缺参拒绝（exit 2，无 unbound）"
else
  bad "--prd 缺参处理异常（rc=$_rc）: $_out"
fi
_out=$(bash "$R" fx --evidence 2>&1); _rc=$?
if [ "$_rc" = "2" ] && ! printf '%s' "$_out" | grep -q "unbound"; then
  ok "--evidence 缺参拒绝（exit 2，无 unbound）"
else
  bad "--evidence 缺参处理异常（rc=$_rc）: $_out"
fi

# T3 feature 白名单（路径穿越）
_out=$(bash "$R" "../escape" 2>&1); _rc=$?
[ "$_rc" = "2" ] && ok "路径穿越 feature 拒绝（exit 2）" || bad "路径穿越 feature 未拒绝（rc=$_rc）"

# T4 Gate 清单完整性（静态声明 vs SKILL.md Gate 矩阵）
_missing=""
for _g in s0 P0b P1 design s2 P2a P2b P3build P3 P3b P3cd P4 P4b P5 s5migB s5migC s6acc p6cred s6final P7 P8 P9 P10; do
  grep -qE "^gate ${_g}( |$)" "$R" || _missing="$_missing $_g"
done
[ -z "$_missing" ] && ok "Gate 清单覆盖 P0→P10 全矩阵（22 Gate）" || bad "Gate 清单缺失:$_missing"
grep -q 'reconcile "$FEATURE" --apply' "$R" \
  && ok "reconcile --apply 已接线（末尾对账）" || bad "缺 reconcile --apply"
grep -q "Gate 非零立即停止" "$R" \
  && ok "失败即停语义在案（铁律 8）" || bad "缺失败即停语义"

# T5 fail-fast 动态验证：空工作区首个 Gate（s0）必失败 → exit 1 且只跑了 s0
W="$TMP/ws"; mkdir -p "$W"
_out=$(cd "$W" && bash "$R" fixture 2>&1); _rc=$?
_logroot=$(ls -td "$W"/.devflow/fixture/refresh-logs/* 2>/dev/null | head -1)
if [ "$_rc" = "1" ] && [ -n "$_logroot" ] \
   && [ -f "$_logroot/s0.log" ] \
   && [ "$(ls "$_logroot" | wc -l | tr -d ' ')" = "1" ]; then
  ok "失败即停：s0 失败 exit 1，后续 Gate 未执行（日志数=1）"
else
  _n=$([ -n "$_logroot" ] && ls "$_logroot" | wc -l | tr -d ' ' || echo 0)
  bad "fail-fast 行为异常（rc=$_rc, 日志数=$_n）: $(printf '%s' "$_out" | tail -3)"
fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
