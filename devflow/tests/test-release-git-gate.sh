#!/usr/bin/env bash
# test-release-git-gate.sh · release.sh Git 快照门禁回归（v3.29.5）
#   T1 脏工作树 → release FAIL（秒失败：不跑全量测试——Git 门禁已前置）
#   T2 干净树首发 → READY_TO_COMMIT（exit 3，新 manifest 未提交，不回滚）
#   T3 manifest 提交后复跑 → RELEASED（exit 0）
set -uo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "[FAIL] $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/release-git-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── 临时 Git 仓库：复制当前 skill（排除 .git/测试日志/pycache）──
COPY="$TMP/skill"; mkdir -p "$COPY"
(cd "$ROOT" \
  && tar --exclude='./.git' --exclude='./tests/logs' \
     --exclude='*/__pycache__' --exclude='.DS_Store' -cf - .) \
  | (cd "$COPY" && tar -xf -)
[ -f "$COPY/scripts/release.sh" ] || { echo "[test] skill 复制失败" >&2; exit 2; }
(cd "$COPY" && git init -q && git config user.email "t@t" && git config user.name "t" \
  && git add -A && git commit -qm "init fixture")
# 模拟"当前版本首次发布"：先补 CHANGELOG 条目（版本门禁硬性要求），再副本 bump 到
# 无 manifest 的新版本（旧 manifest 保留——台账链需 parent；当前 manifest 缺失=合法首发态）
python3 - "$COPY/references/CHANGELOG.md" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
entry="## v3.29.5 (2026-09-22) — fixture release entry\n\nfixture.\n\n"
lines=s.split('\n')
# 插在 H1 之后（首行空行后的标题行前）
i=next(i for i,l in enumerate(lines) if l.startswith('## '))
lines[i:i]=entry.rstrip('\n').split('\n')+['']
open(p,'w').write('\n'.join(lines))
PYEOF
(cd "$COPY" && bash scripts/bump-version.sh 3.29.5 >/dev/null 2>&1 \
  && git add -A && git commit -qm "bump fixture")
RUN_REL() {
  (cd "$COPY" \
    && DEVFLOW_COPY_TARGETS="$COPY/no-parent/devflow" \
       RUN_TESTS_GROUPS="test-schema-guards,test-state,test-chinese-paths" \
       bash scripts/release.sh 2>&1)
}

# ── T1 脏树 → FAIL 且不跑全量测试 ──
printf 'dirty\n' > "$COPY/untracked-dirty.txt"
_out=$(RUN_REL); _rc=$?
if [ "$_rc" != "0" ] && printf '%s' "$_out" | grep -q "Git 工作树有未提交" \
   && ! printf '%s' "$_out" | grep -q "GROUP ▶"; then
  ok "T1 脏树 → release FAIL（秒失败，未跑全量测试）"
else
  bad "T1 脏树门禁异常（rc=${_rc}）: $(printf '%s' "$_out" | head -4)"
fi

# ── T2 干净树首发 → READY_TO_COMMIT（exit 3）──
rm -f "$COPY/untracked-dirty.txt"
_out=$(RUN_REL); _rc=$?
_manifest="$COPY/references/manifest/"$(grep -m1 '^  version:' "$COPY/SKILL.md" | sed 's/.*"\(.*\)".*/\1/').json
if [ "$_rc" = "3" ] && printf '%s' "$_out" | grep -q "READY_TO_COMMIT" \
   && [ -f "$_manifest" ] \
   && [ "$(cd "$COPY" && git status --porcelain "$_manifest" | grep -c '^??')" = "1" ]; then
  ok "T2 首发新 manifest 未提交 → READY_TO_COMMIT（exit 3，manifest 在案待提交）"
else
  bad "T2 首发语义异常（rc=${_rc}, manifest=$([ -f "$_manifest" ] && echo yes || echo no)）"
fi

# ── T3 提交 manifest 后复跑 → RELEASED（exit 0）──
(cd "$COPY" && git add -A && git commit -qm "release manifest")
_out=$(RUN_REL); _rc=$?
if [ "$_rc" = "0" ] && printf '%s' "$_out" | grep -q "RELEASED"; then
  ok "T3 manifest 已提交，复跑 → RELEASED（exit 0）"
else
  bad "T3 复跑未达 RELEASED（rc=${_rc}）: $(printf '%s' "$_out" | tail -3)"
fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
