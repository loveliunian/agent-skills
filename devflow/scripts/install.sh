#!/usr/bin/env bash
# install.sh · devflow 软链安装器（v3.31.2）
# 把本 skill 目录以符号链接接入各 Agent 的 skills 目录；幂等可重复执行，绝不覆盖实体目录。
# 用法: bash scripts/install.sh --platform <claude|codex|cursor|trae|trae-cn|all> [--uninstall]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLATFORM=""
ACTION="install"

usage() {
  cat <<'EOF'
用法: install.sh --platform <claude|codex|cursor|trae|trae-cn|all> [--uninstall]

  claude   -> ~/.claude/skills/devflow
  codex    -> ~/.agents/skills/devflow   (OpenAI 当前 user scope；旧的 ~/.codex/skills 已过时)
  cursor   -> ~/.cursor/skills/devflow
  trae     -> ~/.trae/skills/devflow
  trae-cn  -> ~/.trae-cn/skills/devflow
EOF
}

fail() { echo "[FAIL] $*" >&2; exit 1; }

target_dir() {
  case "$1" in
    claude)  printf '%s' "$HOME/.claude/skills" ;;
    codex)   printf '%s' "$HOME/.agents/skills" ;;
    cursor)  printf '%s' "$HOME/.cursor/skills" ;;
    trae)    printf '%s' "$HOME/.trae/skills" ;;
    trae-cn) printf '%s' "$HOME/.trae-cn/skills" ;;
    *) return 1 ;;
  esac
}

resolved() {
  # 输出软链解析后的物理路径；悬空/不可解析时输出空
  (cd "$1" 2>/dev/null && pwd -P) || true
}

link_one() {
  local name="$1" dir target
  dir=$(target_dir "$name") || fail "未知平台: $name"
  target="$dir/devflow"
  case "$ACTION" in
    install)
      if [ -L "$target" ]; then
        if [ "$(resolved "$target")" = "$ROOT" ]; then
          echo "[OK]   已直连: $target -> $ROOT"
          return 0
        fi
        fail "$target 已是指向他处的软链——请先手工检查（或用 --uninstall 移除）"
      elif [ -e "$target" ]; then
        fail "$target 已是实体目录/文件——为防覆盖不自动处理，请手工迁移后重试"
      fi
      mkdir -p "$dir" || fail "无法创建 $dir"
      if ! ln -s "$ROOT" "$target" 2>/dev/null; then
        fail "创建软链失败: ${target}（Windows Git Bash 需开启开发者模式并设 MSYS=winsymlinks:nativestrict 后重试）"
      fi
      if [ ! -L "$target" ]; then
        echo "[WARN] MSYS 把 ln -s 当作复制执行：$target 是实体副本而非软链——"
        echo "       源仓更新后不会自动同步，需重跑 install.sh；启用真软链：开发者模式 + MSYS=winsymlinks:nativestrict"
      else
        echo "[OK]   已安装: $target -> $ROOT"
      fi
      ;;
    uninstall)
      if [ -L "$target" ]; then
        if [ "$(resolved "$target")" = "$ROOT" ]; then
          rm "$target" || fail "移除失败: $target"
          echo "[OK]   已移除: $target"
        else
          fail "$target 指向他处（$(readlink "$target")），拒绝移除"
        fi
      else
        echo "[SKIP] 未安装: $target"
      fi
      ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --platform)
      [ $# -ge 2 ] || fail "--platform 缺少参数"
      PLATFORM="$2"
      shift 2
      ;;
    --uninstall)
      ACTION="uninstall"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "未知参数: $1"
      ;;
  esac
done

[ -n "$PLATFORM" ] || { usage >&2; exit 2; }

if [ "$PLATFORM" = "all" ]; then
  rc=0
  for p in claude codex cursor trae trae-cn; do
    link_one "$p" || rc=1
  done
  exit "$rc"
fi
link_one "$PLATFORM"
