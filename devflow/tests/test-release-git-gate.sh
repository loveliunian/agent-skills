#!/usr/bin/env bash
# test-release-git-gate.sh · release Git 判定库回归（v3.29.7：抽函数后直接单测）
#   T1 release_git_dirty：脏树 rc=1（stdout 脏行）；干净 rc=0
#   T2 release_git_final 首发（manifest_exists=0）→ READY_TO_COMMIT rc=3 + 提交指令
#   T3 复跑（exists=1）→ RELEASED rc=0
#   T4 非 Git 目录 → RELEASED rc=0
#   T5 生产接线钉：release.sh 对 RUN_TESTS_GROUPS/DEVFLOW_COPY_TARGETS env -u（后门关闭）
# 纯 bash + git，无 Python/全量 release（旧形态 300s → 秒级）。
set -uo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
LIB="$ROOT/scripts/release_git_lib.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "[FAIL] $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/release-git-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=release_git_lib.sh
. "$LIB"

# ── 最小临时 Git 仓库（含一个 SKILL.md——终态函数从中读版本号）──
REPO="$TMP/repo"; mkdir -p "$REPO"
printf '  version: "3.29.7"\n' > "$REPO/SKILL.md"
(cd "$REPO" && git init -q && git config user.email "t@t" && git config user.name "t" \
  && git add -A && git commit -qm init)

# ── T1 脏/净 ──
printf 'x\n' > "$REPO/untracked.txt"
_d=$(release_git_dirty "$REPO"); rc=$?
if [ -z "$_d" ] || [ "$rc" != "1" ] || ! printf '%s' "$_d" | grep -q "untracked"; then
  bad "T1 脏树未报 rc=1+脏行（rc=${rc}, out=${_d}）"
else
  ok "T1 脏树 → rc=1 并输出脏行"
fi
rm -f "$REPO/untracked.txt"
if release_git_dirty "$REPO" >/dev/null 2>&1; then
  ok "T1 干净树 → rc=0"
else
  bad "T1 干净树未通过"
fi

# ── T2 首发 READY_TO_COMMIT（rc=3）──
_out=$(release_git_final "$REPO" 0 2>&1); _rc=$?
if [ "$_rc" = "3" ] && printf '%s' "$_out" | grep -q "READY_TO_COMMIT" \
   && printf '%s' "$_out" | grep -q "git -C"; then
  ok "T2 首发（exists=0）→ READY_TO_COMMIT rc=3 + 提交指令"
else
  bad "T2 首发语义异常（rc=${_rc}）"
fi

# ── T3 复跑 RELEASED（rc=0）──
_out=$(release_git_final "$REPO" 1 2>&1); _rc=$?
if [ "$_rc" = "0" ] && printf '%s' "$_out" | grep -q "RELEASED"; then
  ok "T3 复跑（exists=1）→ RELEASED rc=0"
else
  bad "T3 复跑语义异常（rc=${_rc}）"
fi

# ── T4 非 Git 目录 → RELEASED rc=0 ──
NON="$TMP/nongit"; mkdir -p "$NON"; printf '  version: "3.29.7"\n' > "$NON/SKILL.md"
_out=$(release_git_final "$NON" 0 2>&1); _rc=$?
if [ "$_rc" = "0" ] && printf '%s' "$_out" | grep -q "RELEASED"; then
  ok "T4 非 Git 目录 → RELEASED rc=0（READY 语义仅对 Git）"
else
  bad "T4 非 Git 语义异常（rc=${_rc}）"
fi

# ── T5 生产接线钉：两个环境变量后门必须 env -u ──
REL="$ROOT/scripts/release.sh"
if grep -q "env -u RUN_TESTS_GROUPS bash" "$REL" \
   && grep -q "env -u DEVFLOW_COPY_TARGETS bash" "$REL"; then
  _n=$(grep -c "env -u DEVFLOW_COPY_TARGETS bash" "$REL")
  if [ "$_n" = "2" ]; then
    ok "T5 release.sh 对两个后门 env -u（测试步 + 两处副本检查）"
  else
    bad "T5 DEVFLOW_COPY_TARGETS env -u 覆盖数=${_n}（应 2：Phase A/B2）"
  fi
else
  bad "T5 release.sh 缺少 env -u（RUN_TESTS_GROUPS/DEVFLOW_COPY_TARGETS 后门仍开）"
fi
# 生产脚本本身不得出现旧后门变量消费（env -u 除外）
if grep -E '^[^#]*(RUN_TESTS_GROUPS|DEVFLOW_COPY_TARGETS)' "$REL" \
   | grep -v "env -u" | grep -q .; then
  bad "T5 release.sh 仍有旧后门变量消费"
else
  ok "T5 release.sh 无旧后门变量消费（仅 env -u 清除）"
fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
