#!/usr/bin/env bash
# gate-skill-tree.sh · 不可变 Skill 树哈希（fail-closed；版本随 SKILL.md）
# 对整棵 skill 内容（排除运行期产物/自引用）计算 SHA-256 树哈希。
# 用途：冻结进 state 与收据，使"同一版本号"可区分具体内容树
#       （防止"未发布本地修复"混入同名版本后收据无法溯源）。
# v3.15.1: 完全 fail-closed——任一文件读取/哈希失败即 exit 1 且不产出 hash；
#          LC_ALL=C 固定字节序（Linux/macOS/Git Bash 确定性）；sha256sum 回退。
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

_hash_tool() {
  if command -v shasum >/dev/null 2>&1; then printf 'shasum'; return 0; fi
  if command -v sha256sum >/dev/null 2>&1; then printf 'sha256sum'; return 0; fi
  return 1
}

hash_one() {
  # hash_one <file> —— 失败时输出空并以非零退出（文件不可读/工具失败）
  local tool
  tool=$(_hash_tool) || return 1
  case "$tool" in
    shasum)    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' ;;
    sha256sum) sha256sum "$1" 2>/dev/null | awk '{print $1}' ;;
    *) return 1 ;;
  esac
}

_hash_stream() {
  local tool
  tool=$(_hash_tool) || return 1
  case "$tool" in
    shasum)    shasum -a 256 | awk '{print $1}' ;;
    sha256sum) sha256sum | awk '{print $1}' ;;
  esac
}

TREE_INPUT=$(find "$ROOT" -type f \
  ! -path "$ROOT/tests/logs/*" \
  ! -path "$ROOT/.backups/*" \
  ! -path "$ROOT/_archive/*" \
  ! -path "$ROOT/.devflow/*" \
  ! -path "$ROOT/.git/*" \
  ! -path "$ROOT/references/manifest/*" \
  ! -name '.DS_Store' \
  ! -name '*.bak' ! -name '*.bak-devflow' \
  ! -path '*/__pycache__/*' ! -name '*.pyc' 2>/dev/null | LC_ALL=C sort)
if [ -z "$TREE_INPUT" ]; then
  echo "[gate-skill-tree] FATAL: 树文件清单为空——枚举异常，拒绝产出空树 hash" >&2
  exit 1
fi

BUF=$(mktemp) || { echo "[gate-skill-tree] FATAL: 无法创建临时文件" >&2; exit 1; }
trap 'rm -f "$BUF"' EXIT
status=0
while IFS= read -r f; do
  H=$(hash_one "$f")
  if [ -z "$H" ] || ! printf '%s' "$H" | grep -qE '^[0-9a-f]{64}$'; then
    echo "[gate-skill-tree] FATAL: 文件哈希失败（不可读或哈希工具异常）: $f" >&2
    status=1
    break
  fi
  printf '%s\t%s\n' "${f#$ROOT/}" "$H" >> "$BUF"
done <<< "$TREE_INPUT"

if [ "$status" -ne 0 ]; then
  exit 1
fi

HASH=$(_hash_stream < "$BUF")
if [ -z "$HASH" ] || ! printf '%s' "$HASH" | grep -qE '^[0-9a-f]{64}$'; then
  echo "[gate-skill-tree] FATAL: 树哈希计算失败" >&2
  exit 1
fi
printf '%s\n' "$HASH"
exit 0
