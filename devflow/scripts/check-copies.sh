#!/usr/bin/env bash
# check-copies.sh · 已安装副本的"直连本 skill"校验（只读，fail-closed；v3.30.12）
# 副本形态约定："直连软链"——各工具 skills 目录中的 devflow 必须是解析到本 skill
# （仓库工作树）的符号链接，由仓库级同步入口或 scripts/install.sh 维护；
# 旧的 rsync 实体副本分发（sync-copies.sh）已删除，实体副本视为漂移。
# 用法:
#   bash scripts/check-copies.sh                                  # 校验默认候选目标
#   DEVFLOW_COPY_TARGETS="/p1:/p2" bash scripts/check-copies.sh    # 覆盖目标（冒号或换行分隔；
#                                                                  # 含 Windows 盘符时仅按换行切分）
# 退出码: 0=全部合格或未安装; 1=漂移（实体副本或指向他处）; 2=结构性错误（空目标/缺失/悬空链接）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

DEFAULT_TARGETS="$HOME/.codex/skills/devflow
$HOME/.agents/skills/devflow
$HOME/.claude/skills/devflow
$HOME/.trae/skills/devflow
$HOME/.trae-cn/skills/devflow
$HOME/.cursor/skills/devflow"
TARGETS_LIST="${DEVFLOW_COPY_TARGETS-$DEFAULT_TARGETS}"

for a in "$@"; do
  case "$a" in
    --check) ;;
    *) echo "[FAIL] 未知参数: ${a}（用法: check-copies.sh [--check]）" >&2; exit 2 ;;
  esac
done

# 空目标 fail-closed——零执行输出"通过"是假绿
if [ -z "$(printf '%s' "$TARGETS_LIST" | tr -d '[:space:]')" ]; then
  echo "[FAIL] 副本目标列表为空——拒绝零目标假绿" >&2
  exit 2
fi

fail=0
# 目标切分：含 Windows 盘符（C:\ 或 C:/）时按换行分隔，避免盘符冒号被拆开；兼容 CRLF
while IFS= read -r target; do
  [ -n "$target" ] || continue
  target="${target/#\~/$HOME}"
  if [ -L "$target" ]; then
    link_to="$(readlink "$target")"
    if [ ! -e "$target" ]; then
      echo "⛔ 悬空符号链接: $target → $link_to" >&2
      [ "$fail" -lt 2 ] && fail=2
      continue
    fi
    resolved="$(cd "$target" 2>/dev/null && pwd -P)" || resolved=""
    if [ -z "$resolved" ]; then
      echo "⛔ 链接不可解析: $target → $link_to" >&2
      [ "$fail" -lt 2 ] && fail=2
    elif [ "$resolved" = "$SKILL_ROOT" ]; then
      echo "✅ 直连: $target → $SKILL_ROOT"
    else
      echo "⛔ 指向他处: $target → ${link_to}（应为 ${SKILL_ROOT}）" >&2
      [ "$fail" -lt 1 ] && fail=1
    fi
  elif [ -e "$target" ]; then
    echo "⛔ 实体副本（应改为直连软链，跑仓库级 sync.sh 修复）: $target" >&2
    [ "$fail" -lt 1 ] && fail=1
  elif [ -d "$(dirname "$target")" ]; then
    echo "⛔ 缺失: ${target}（父目录存在但无 devflow 副本）" >&2
    [ "$fail" -lt 2 ] && fail=2
  else
    echo "⏭  未安装: ${target}（父目录不存在，跳过）"
  fi
done < <(
  if printf '%s' "$TARGETS_LIST" | grep -qE '(^|[[:space:]])[A-Za-z]:[\\/]'; then
    printf '%s\n' "$TARGETS_LIST" | while IFS= read -r _line; do printf '%s\n' "${_line%$'\r'}"; done
  else
    printf '%s\n' "$TARGETS_LIST" | tr ':' '\n'
  fi
)

if [ "$fail" -eq 0 ]; then
  echo "副本直连校验通过（全部合格或未安装）"
else
  echo "副本直连校验失败（rc=${fail}：1=漂移，2=结构性错误）" >&2
fi
exit "$fail"
