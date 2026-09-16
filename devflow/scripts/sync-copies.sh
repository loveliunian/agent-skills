#!/usr/bin/env bash
# Synchronize devflow copies. Read-only verification is the default.
# 历史（早期版本 跨平台修复，详见 CHANGELOG）：
#   - 目标列表支持冒号或换行分隔；含 Windows 盘符路径（C:\ 或 C:/）时不做冒号切分（换行分隔），
#     并兼容 CRLF 行尾；
#   - rsync 不再是硬依赖：缺失时自动回退 find+cp+rmdir 的可移植同步（Git Bash/Windows 兼容）。
# v3.15.4 参数/排除集修复：
#   - --target 缺值/空值 fail-closed（旧实现 shift 2 失败后位置参数不变 → 死循环）；
#   - 空目标列表 fail-closed（bash>=4.4 零循环输出 ALL OK 假绿、bash 3.2 unbound 崩溃）；
#   - 排除集与 gate-skill-tree 对齐（.git/.devflow/*.bak/*.bak-devflow）——否则
#     rsync --delete 会删除目标副本的 .git 历史；portable 路径 check 把 .git 误报 extra、
#     apply 直接删除 .git 文件；运行产物（.devflow/）被同步进用户副本造成永久 DIFF。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd -P)"
USER_HOME_DIR="${HOME:?HOME is required}"
DEFAULT_TARGETS="$USER_HOME_DIR/.trae-cn/skills/devflow:$USER_HOME_DIR/.claude/skills/devflow:$USER_HOME_DIR/.cursor/skills/devflow"
# v3.15.5: 必须用 `-` 而非 `:-`——`:-` 把"已设置但为空"（SYNC_TARGETS=""）误判为未设置并
# 回退默认目标，空目标 fail-closed 守卫（len==0 → exit 2）从未被触发：测试以空
# SYNC_TARGETS 调用时会真实 --check 三个用户副本（读外部状态）并 exit 1 而非 2。
TARGETS="${SYNC_TARGETS-$DEFAULT_TARGETS}"
MODE="check"

usage() {
  echo "Usage: $0 [--check|--apply|--link] [--target <absolute-or-tilde skill path>]"
  echo "  --check  Compare every active file; default and read-only."
  echo "  --apply  Synchronize validated */skills/devflow targets with rsync --delete"
  echo "           (or the portable find+cp fallback when rsync is unavailable)."
  echo "  --link   One-time migration: replace a verified-identical real copy with a"
  echo "           symlink to this source tree (v3.20.3 single-source distribution)."
  echo ""
  echo "  SYNC_TARGETS separator: colon or newline. On Windows, use newline-separated"
  echo "  targets so drive-letter paths (C:/...) are not split at the colon."
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --apply) MODE="apply"; shift ;;
    --link)  MODE="link"; shift ;;
    --target) { [ -n "${2:-}" ] && [ "${2#-}" = "${2:-}" ]; } || { echo "[FAIL] --target requires a non-flag value"; usage; }
      TARGETS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "[FAIL] unknown argument: $1"; usage ;;
  esac
done

HAS_RSYNC=0
command -v rsync >/dev/null 2>&1 && HAS_RSYNC=1
[ "$HAS_RSYNC" -eq 1 ] || echo "[WARN] rsync 不可用——使用 find+cp 可移植同步回退（Git Bash/Windows 兼容）"

# v3.15.18: portable 分支 fail-closed 前置——两个 SHA 工具均缺失时 _hash_one 恒返回
# 空串，空哈希相等使被篡改目标判 SYNCED ALL OK（假绿，PoC 实证）。无 rsync 且无
# SHA 工具 = portable 对账不可信，拒绝运行。
HAS_SHA=0
command -v shasum >/dev/null 2>&1 && HAS_SHA=1
command -v sha256sum >/dev/null 2>&1 && HAS_SHA=1
if [ "$HAS_RSYNC" -eq 0 ] && [ "$HAS_SHA" -eq 0 ]; then
  echo "[FAIL] 无 rsync 且无 shasum/sha256sum——portable 对账将产生空哈希相等假绿，fail-closed 拒绝运行" >&2
  exit 2
fi

validate_target() {
  local raw="$1" target parent
  target="${raw/#\~/$USER_HOME_DIR}"
  target="${target%$'\r'}"
  [ -d "$target" ] || { echo "[FAIL] target does not exist: $target" >&2; return 1; }
  target="$(cd "$target" && pwd -P)"
  parent="$(dirname "$target")"
  [ "$(basename "$target")" = "devflow" ] || { echo "[FAIL] target basename must be devflow: $target" >&2; return 1; }
  [ "$(basename "$parent")" = "skills" ] || { echo "[FAIL] target must be directly under a skills directory: $target" >&2; return 1; }
  [ -f "$target/SKILL.md" ] || { echo "[FAIL] target is not an existing skill: $target" >&2; return 1; }
  [ "$target" != "$SRC" ] || return 2
  printf '%s\n' "$target"
}

# 发布树范围内的活动文件清单（相对路径，与 gate-skill-tree 同口径）
list_active_rel() {
  # v3.16.0: _archive 排除——与 release-audit/gen-skill-manifest 三方统一
  # v3.20.3: tests/logs 排除——run-tests 运行日志是运行期产物，与 gate-skill-tree 同口径
  (cd "$SRC" && find . -type f \
    ! -path './.backups/*' ! -path './_archive/*' ! -path './.git/*' ! -path './.devflow/*' \
    ! -path './tests/logs/*' \
    ! -name '.bak-*' ! -name '*.bak' ! -name '*.bak-devflow' ! -name '.DS_Store' \
    ! -path '*/__pycache__/*' ! -name '*.pyc' | sed 's|^\./||' | LC_ALL=C sort)
}

_hash_one() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

# v3.15.18: portable 分支目标 symlink 拒绝——cp/mkdir 会写穿目标树内 symlink 到
# skill 目录外（PoC：dst/README.md → 外部文件被源内容覆盖）。rsync 分支以替换
# 语义不跟随目标 symlink，天然安全；portable 分支必须显式扫描 fail-closed。
portable_reject_symlinks() {
  local dst="$1" badlinks
  badlinks=$(cd "$dst" 2>/dev/null && find . -type l \
    ! -path './.git/*' ! -path './.backups/*' ! -path './.devflow/*' 2>/dev/null | head -5)
  if [ -n "$badlinks" ]; then
    echo "[FAIL] 目标树包含 symlink（portable 同步经 cp/mkdir 写穿到 skill 目录外，拒绝同步）: $dst" >&2
    while IFS= read -r l; do
      [ -n "$l" ] && echo "  $l" >&2
    done <<< "$badlinks"
    return 1
  fi
  return 0
}

# 可移植 diff：活动文件逐个比对哈希 + 找出目标侧多余文件；输出差异明细，无差异输出空
portable_diff() {
  local dst="$1" rel h1 h2
  while IFS= read -r rel; do
    if [ ! -f "$dst/$rel" ]; then
      echo "missing: $rel"
      continue
    fi
    h1=$(_hash_one "$SRC/$rel"); h2=$(_hash_one "$dst/$rel")
    # v3.15.18: 空哈希防御——哈希计算失败（如权限）不得按相等放行
    if [ -z "$h1" ] || [ -z "$h2" ]; then
      echo "no-hash: $rel"
    elif [ "$h1" != "$h2" ]; then
      echo "differ: $rel"
    fi
  done < <(list_active_rel)
  while IFS= read -r rel; do
    [ -f "$SRC/$rel" ] || echo "extra: $rel"
  done < <(cd "$dst" && find . -type f \
    ! -path './.git/*' ! -path './.backups/*' ! -path './_archive/*' ! -path './.devflow/*' \
    ! -path './tests/logs/*' \
    ! -name '.DS_Store' ! -name '.bak-*' ! -name '*.bak' ! -name '*.bak-devflow' \
    ! -path '*/__pycache__/*' ! -name '*.pyc' 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort)
}

# 可移植 apply：复制全部活动文件 + 删除目标侧多余文件 + 清理空目录
portable_apply() {
  local dst="$1" rel
  while IFS= read -r rel; do
    mkdir -p "$dst/$(dirname "$rel")" || return 1
    cp "$SRC/$rel" "$dst/$rel" || return 1
  done < <(list_active_rel)
  while IFS= read -r rel; do
    [ -f "$SRC/$rel" ] || rm -f "$dst/$rel"
  done < <(cd "$dst" && find . -type f \
    ! -path './.git/*' ! -path './.backups/*' ! -path './_archive/*' ! -path './.devflow/*' \
    ! -path './tests/logs/*' \
    ! -name '.DS_Store' ! -name '.bak-*' ! -name '*.bak' ! -name '*.bak-devflow' 2>/dev/null | sed 's|^\./||')
  find "$dst" -depth -mindepth 1 -type d -exec rmdir {} \; 2>/dev/null || true
  return 0
}

# v3.15.1: 目标列表解析——含盘符路径时不做冒号切分（换行分隔）；兼容 CRLF
# 盘符判定：仅当盘符位于串首或空白边界时才视为 Windows 路径（POSIX 冒号列表不误判）
if printf '%s' "$TARGETS" | grep -qE '(^|[[:space:]])[A-Za-z]:[\\/]'; then
  target_arr=()
  while IFS= read -r _line; do
    _line="${_line%$'\r'}"
    [ -n "$_line" ] && target_arr+=("$_line")
  done <<< "$TARGETS"
else
  IFS=':' read -ra target_arr <<< "$TARGETS"
fi

# v3.15.4: 空目标 fail-closed——bash>=4.4 零循环输出 ALL OK（同步被跳过却报成功）、bash 3.2 unbound 崩溃
[ "${#target_arr[@]}" -gt 0 ] || { echo "[FAIL] no sync targets (empty SYNC_TARGETS/--target)"; exit 2; }

# v3.15.4: 排除集与 gate-skill-tree 对齐——.git 保护目标副本 git 历史，.devflow 防运行产物污染
sync_args=(--exclude='.git/' --exclude='.backups/' --exclude='.devflow/' --exclude='_archive/'
  --exclude='tests/logs/'
  --exclude='.bak-*' --exclude='*.bak' --exclude='*.bak-devflow' --exclude='.DS_Store'
  --exclude='__pycache__/' --exclude='*.pyc')
FAIL=0
# v3.20.3: 结构性错误与内容漂移分道——0=一致/LINKED，1=仅内容漂移（新版本首发预期），2=结构错误
DIFF_ONLY=0

for raw in "${target_arr[@]}"; do
  raw="${raw%$'\r'}"
  [ -n "$raw" ] || continue
  # v3.20.3: symlink 目标感知——指向本源即 LINKED（单一源分发形态），指向他处即结构错误
  _raw_exp="${raw/#\~/$USER_HOME_DIR}"
  _raw_exp="${_raw_exp%$'\r'}"
  if [ -L "$_raw_exp" ]; then
    _link_dst=$(readlink -f "$_raw_exp" 2>/dev/null || printf '%s' "")
    if [ -n "$_link_dst" ] && [ "$_link_dst" = "$SRC" ]; then
      echo "[LINKED] ${_raw_exp} -> ${SRC}（单一源，无需同步）"
      continue
    fi
    echo "[FAIL] symlink target does not point to this source: $_raw_exp -> ${_link_dst:-unresolvable}"
    FAIL=1
    continue
  fi
  target=$(validate_target "$raw")
  code=$?
  if [ "$code" -eq 2 ]; then
    echo "[SKIP] source target: $SRC"
    continue
  elif [ "$code" -ne 0 ]; then
    FAIL=1
    continue
  fi

  # v3.16.0（P1-1）: check 统一走 portable_diff（文件集合 + SHA-256 内容对账）——
  # rsync -ani 按 size+mtime 快速判定（即使 --checksum，-a 的 -t 仍把纯 mtime 漂移
  # itemize 为 .f..T.... 误红发布）；同大小+恢复 mtime 的内容篡改则在反方向漏检。
  # portable_diff 逐文件 SHA 对账天然 mtime 免疫且内容敏感（双变异 PoC 验证）。
  # rsync 仅用于 apply（--checksum 确保内容漂移被复制修复）。
  # v3.15.18: portable 分支 symlink 写穿守卫保持
  if ! portable_reject_symlinks "$target"; then
    FAIL=1
    continue
  fi
  changes=$(portable_diff "$target")
  if [ "$MODE" = "check" ]; then
    if [ -n "$changes" ]; then
      echo "[DIFF] $target"
      printf '%s\n' "$changes"
      DIFF_ONLY=1
    else
      echo "[SYNCED] $target"
    fi
    continue
  fi

  # v3.20.3: --link 一次性迁移——内容逐字节一致的真实副本才能替换为符号链接
  if [ "$MODE" = "link" ]; then
    if [ -n "$changes" ]; then
      echo "[FAIL] --link refuses divergent copy（先 --apply 对齐后再 --link）: $target"
      printf '%s\n' "$changes" | head -5
      FAIL=1
      continue
    fi
    if rm -rf "$target" && ln -s "$SRC" "$target"; then
      echo "[LINKED] $target -> $SRC"
    else
      echo "[FAIL] --link migration failed: $target"
      FAIL=1
    fi
    continue
  fi

  if [ -z "$changes" ]; then
    echo "[SYNCED] $target"
    continue
  fi
  echo "[APPLY] $SRC -> $target"
  if [ "$HAS_RSYNC" -eq 1 ]; then
    # v3.16.0（P1-1）: apply 同口径 --checksum——否则 mtime 相同的篡改内容不被复制
    if rsync -a --checksum --delete "${sync_args[@]}" "$SRC/" "$target/"; then
      echo "[SYNCED] $target"
    else
      echo "[FAIL] rsync failed: $target"
      FAIL=1
    fi
  else
    if portable_apply "$target"; then
      echo "[SYNCED] $target (portable)"
    else
      echo "[FAIL] portable sync failed: $target"
      FAIL=1
    fi
  fi
done

if [ "$FAIL" -eq 0 ] && [ "$DIFF_ONLY" -eq 0 ]; then
  echo "sync-copies: ALL OK"
  exit 0
fi
if [ "$FAIL" -eq 0 ]; then
  echo "sync-copies: DIFF ONLY（内容漂移；--apply 可对齐）"
  exit 1
fi
echo "sync-copies: FAIL（含结构性错误）"
exit 2
