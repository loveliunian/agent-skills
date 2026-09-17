#!/usr/bin/env bash
# gate-skill-tree.sh · 不可变 Skill 树哈希（fail-closed；版本随 SKILL.md）
# 对整棵 skill 内容（排除运行期产物/自引用）计算 SHA-256 树哈希。
# 用途：冻结进 state 与收据，使"同一版本号"可区分具体内容树
#       （防止"未发布本地修复"混入同名版本后收据无法溯源）。
# v3.15.1: 完全 fail-closed——任一文件读取/哈希失败即 exit 1 且不产出 hash；
#          LC_ALL=C 固定字节序（Linux/macOS/Git Bash 确定性）；sha256sum 回退。
# v3.26.1: 性能——旧版逐文件串行 fork shasum（~268 文件 ≈ 270 次进程 ≈ 4.6s/次调用，
#          收据脚本每次写收据都调它，成为全量测试墙钟的主热点）。改 python3 单进程批量
#          哈希（~0.1s），输出与旧版逐字节一致（路径\t哈希 + LC_ALL=C 排序）；
#          无 python3 的环境回退旧 shell 实现，两者 fail-closed 语义相同。
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

# 排除谓词必须与下面 shell 回退路径完全一致（两处修改需同步，回归由 test-v3140 /
# test-version-hardening 树锚点与 manifest hash 钉住）。
_tree_hash_python() {
  python3 - "$ROOT" <<'PYEOF'
import hashlib, os, subprocess, sys
ROOT = sys.argv[1]
proc = subprocess.run(['find', ROOT, '-type', 'f',
  '!', '-path', f'{ROOT}/tests/logs/*',
  '!', '-path', f'{ROOT}/.backups/*',
  '!', '-path', f'{ROOT}/_archive/*',
  '!', '-path', f'{ROOT}/.devflow/*',
  '!', '-path', f'{ROOT}/.git/*',
  '!', '-path', f'{ROOT}/references/manifest/*',
  '!', '-name', '.DS_Store',
  '!', '-name', '*.bak',
  '!', '-name', '*.bak-devflow',
  '!', '-path', '*/__pycache__/*',
  '!', '-name', '*.pyc',
], capture_output=True)
if proc.returncode != 0:
    sys.exit(1)
files = sorted(proc.stdout.decode('utf-8', 'surrogateescape').splitlines())
if not files:
    sys.stderr.write('[gate-skill-tree] FATAL: 树文件清单为空——枚举异常，拒绝产出空树 hash\n')
    sys.exit(1)
h = hashlib.sha256()
for f in files:
    try:
        with open(f, 'rb') as fh:
            fh = hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        sys.stderr.write(f'[gate-skill-tree] FATAL: 文件哈希失败（不可读）: {f}\n')
        sys.exit(1)
    if len(fh) != 64:
        sys.stderr.write(f'[gate-skill-tree] FATAL: 文件哈希异常: {f}\n')
        sys.exit(1)
    h.update(f[len(ROOT) + 1:].encode('utf-8', 'surrogateescape'))
    h.update(b'\t')
    h.update(fh.encode())
    h.update(b'\n')
print(h.hexdigest())
PYEOF
}

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

# ---------- 快速路径：python3 单进程批量哈希 ----------
if command -v python3 >/dev/null 2>&1; then
  FAST_HASH=$(_tree_hash_python) && [ -n "$FAST_HASH" ] || exit 1
  if printf '%s' "$FAST_HASH" | grep -qE '^[0-9a-f]{64}$'; then
    printf '%s\n' "$FAST_HASH"
    exit 0
  fi
  echo "[gate-skill-tree] FATAL: 快速路径哈希格式异常，拒绝产出" >&2
  exit 1
fi

# ---------- 回退路径：无 python3 时的原 shell 实现（逐文件 fork） ----------
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
