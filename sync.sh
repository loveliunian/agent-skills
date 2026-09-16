#!/usr/bin/env bash
# sync.sh —— 本仓库唯一同步入口（一步到位）
#   1) 软链自愈：各工具 skills 目录里的 devflow / flow-test-contract 一律直连本仓库，不经任何中转路径
#   2) flow-test-contract 分发：调 sync-to-tools.sh 把内容同步到其余 14 个工具的实体副本（runtime 除外）
#   3) git：有变更则提交并推送 GitHub（--local 可跳过）
#
# 用法:
#   bash ~/dev/agent-skills/sync.sh "提交信息"
#   bash ~/dev/agent-skills/sync.sh --local        # 只做本地分发与软链自愈
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
LOCAL_ONLY=false
MSG=""
for a in "$@"; do
  if [ "$a" = "--local" ]; then LOCAL_ONLY=true; else MSG="$a"; fi
done

# ---------- 1) 软链自愈：直连仓库，不经其他路径 ----------
heal_link() { # $1=skill 名 $2=软链路径
  local skill="$1" path="$2" want="$ROOT/$1"
  [ -d "$(dirname "$path")" ] || return 0
  if [ -L "$path" ]; then
    [ "$(readlink "$path")" = "$want" ] && { echo "✅ $path → $want"; return 0; }
    rm -f "$path"
  elif [ -e "$path" ]; then
    echo "⚠ $path 是实体目录（非软链），跳过自愈；如确认由软链接管请手工 rm -rf 后重跑" >&2
    return 0
  fi
  ln -s "$want" "$path"
  echo "🔗 $path → $want"
}

for base in .codex .agents .claude .trae .trae-cn .cursor; do
  heal_link devflow "$HOME/$base/skills/devflow"
done
for base in .agents .config/opencode; do
  heal_link flow-test-contract "$HOME/$base/skills/flow-test-contract"
done
# 其余工具（.codex/.claude/.trae/.trae-cn/.cursor/... 共 14 处）的 flow-test-contract 是实体副本，由下一步分发维护

# ---------- 2) flow-test-contract 分发（源=本仓库） ----------
echo ""
echo "── flow-test-contract 分发 ──"
bash "$ROOT/flow-test-contract/sync-to-tools.sh"

# ---------- 3) git 提交并推送 ----------
echo ""
echo "── git ──"
if [ "$LOCAL_ONLY" = true ]; then
  echo "（--local：跳过提交推送）"
  exit 0
fi
git -C "$ROOT" add -A
if git -C "$ROOT" diff --cached --quiet; then
  echo "✅ 无新变更，跳过提交"
else
  git -C "$ROOT" commit -m "${MSG:-sync: $(date '+%Y-%m-%d %H:%M')}"
  git -C "$ROOT" push
  echo "✅ 已提交并推送 GitHub"
fi
