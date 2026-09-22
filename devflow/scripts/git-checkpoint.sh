#!/usr/bin/env bash
# =============================================================================
# git-checkpoint.sh · Gate PASS 后的强制 git 检查点（v3.29.3）
# -----------------------------------------------------------------------------
# 背景（m01-base 复盘）：P0→P10 全程 6.7h、19 个 Gate、4046 个文件，git 零 commit——
# 任何一步写坏都无法回滚，收据时间也无 commit 时间可交叉验证（补票不可检测）。
# devflow-state.sh complete 在 P2/P3/P6/P10 强制校验本脚本产出的台账条目。
#
# 用法：
#   bash git-checkpoint.sh <feature> <phase> [note]
# 行为：
#   1. 校验当前处于 git 仓库，且该阶段 Gate 收据存在且 EXIT_CODE=0
#   2. 防泄密：.devflow/<feature>/review-keys/ 未被 .gitignore 排除时自动补写并提示
#   3. git add -A（尊重 .gitignore）+ commit（消息含收据 sha 前 12 位）
#   4. 追加台账 .devflow/<feature>/git-checkpoints.tsv（UTC \t phase \t commit \t note）
#   5. 幂等：该 phase 已有台账且工作树干净则跳过
# 豁免：DEVFLOW_GIT_CHECKPOINT=off（complete 侧同读），或在 skip-log.txt 显式授权记录。
# =============================================================================
set -euo pipefail

FEATURE="${1:?用法: git-checkpoint.sh <feature> <phase> [note]}"
PHASE="${2:?用法: git-checkpoint.sh <feature> <phase> [note]}"
NOTE="${3:-}"

FAIL() { echo "[GIT-CP-ERR] $*" >&2; exit 1; }
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

printf '%s' "$FEATURE" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || FAIL "feature 非法"
printf '%s' "$PHASE"   | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || FAIL "phase 非法"

command -v git >/dev/null 2>&1 || FAIL "git 不可用"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || FAIL "当前目录不在 git 仓库内——回滚能力是硬要求，先 git init"

RECEIPT=".devflow/${FEATURE}/gates/${PHASE}/receipt.txt"
[ -f "$RECEIPT" ] || FAIL "Gate 收据不存在: ${RECEIPT}（先跑 Gate 再做检查点）"
grep -q '^EXIT_CODE=0$' "$RECEIPT" || FAIL "Gate 收据非成功，拒绝做检查点: $RECEIPT"
RSHA=$(sha256 "$RECEIPT")

TSV=".devflow/${FEATURE}/git-checkpoints.tsv"

# 幂等：同 phase 已有成功台账且工作树干净 → 跳过
if [ -f "$TSV" ] && awk -F'\t' -v p="$PHASE" '$2 == p' "$TSV" | grep -q .; then
  if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
    echo "[GIT-CP] skip: $PHASE 已有检查点且工作树干净"
    exit 0
  fi
fi

# 防泄密：评审私钥必须在 .gitignore 内（未入库前补写，已 track 则拒绝）
KEYDIR=".devflow/${FEATURE}/review-keys"
if [ -d "$KEYDIR" ] && [ -n "$(ls -A "$KEYDIR" 2>/dev/null)" ]; then
  if ! git check-ignore -q "$KEYDIR/attest.pem" 2>/dev/null; then
    if git ls-files --error-unmatch "$KEYDIR/attest.pem" >/dev/null 2>&1; then
      FAIL "$KEYDIR/attest.pem 已被 git track（私钥入库）——先 git rm --cached 并轮换密钥"
    fi
    printf '\n# devflow: 评审签名私钥不得入库（git-checkpoint.sh 自动补写）\n.devflow/%s/review-keys/\n' "$FEATURE" >> .gitignore
    echo "[GIT-CP] 已将 $KEYDIR/ 追加进 .gitignore（评审私钥不得入库）"
  fi
fi

git add -A
# add 后若无可提交内容（全部被 ignore），记录台账并退出
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p ".devflow/${FEATURE}"
  [ -f "$TSV" ] || printf 'utc\tphase\tcommit\tnote\n' > "$TSV"
  printf '%s\t%s\t%s\t%s\n' "$NOW" "$PHASE" "no-dirty-files" "receipt=$RSHA $NOTE" >> "$TSV"
  echo "[GIT-CP] 工作树无变更，仅记录台账: $TSV"
  exit 0
fi
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
git commit -q -m "devflow(${FEATURE}): ${PHASE} gate PASS (receipt ${RSHA:0:12})

Co-Authored-By: Claude Code <noreply@anthropic.com>" || FAIL "git commit 失败"
COMMIT=$(git rev-parse HEAD)

mkdir -p ".devflow/${FEATURE}"
[ -f "$TSV" ] || printf 'utc\tphase\tcommit\tnote\n' > "$TSV"
printf '%s\t%s\t%s\t%s\n' "$NOW" "$PHASE" "$COMMIT" "receipt=$RSHA $NOTE" >> "$TSV"
echo "[GIT-CP] commit=$COMMIT phase=$PHASE receipt=${RSHA:0:12}"
echo "[GIT-CP] 台账: $TSV"
