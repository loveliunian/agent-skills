#!/usr/bin/env bash
# flow-test-contract skill 多工具同步脚本（第三十四轮 P0：发布门禁化）
# 源（唯一事实源）: ~/.agents/skills/flow-test-contract —— 所有编辑只在此目录做
# ⚠ 本脚本不分发到任何副本（rsync 排除自身）——**只能从 .agents 源目录执行**；
#   副本目录没有同步器，改副本无效且会被下次同步覆盖。
# 目标: 全部已安装 agent 的用户级 skills 目录（目录存在才同步；opencode 为指向本源的符号链接）
#       codex cursor trae trae-cn claude(cc) hermes cc-switch continue copilot gemini
#       ghcp-appmod qoder roo workbuddy
#
# 用法:
#   bash sync-to-tools.sh              # 同步到全部已安装工具的 skills 目录（编辑后必跑）
#   bash sync-to-tools.sh codex cursor # 只同步指定目标
#   bash sync-to-tools.sh --check      # 发布门禁：只校验全部副本与源字节一致，不写（退出码 0=一致）
# 排除: runtime/（skill 私有运行态：通道配置/证据库，属机器本地状态不同步）、__pycache__、.DS_Store
# 门禁约定（写入 SKILL.md）：改动本 skill 后必须重跑本脚本；发布前 --check 必须全绿。

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
NAME="$(basename "$SRC")"
EXCLUDES=(--exclude=sync-to-tools.sh --exclude=__pycache__ --exclude=.DS_Store --exclude=runtime)
# BSD/GNU diff 通用的短选项排除（--check 与同步后校验共用）
DIFF_EXCLUDES=(-x sync-to-tools.sh -x __pycache__ -x .DS_Store -x runtime)

ALL=(codex cursor trae trae-cn claude hermes cc-switch continue copilot gemini ghcp-appmod qoder roo workbuddy)
CHECK_ONLY=false; TARGETS=()
for a in "$@"; do
  if [ "$a" = "--check" ]; then CHECK_ONLY=true; else TARGETS+=("$a"); fi
done
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=("${ALL[@]}")

fail=0

# ---------- opencode 符号链接（第三十五轮 P3：纳入检查；同步模式自动修复，--check 只读） ----------
OC_LINK="$HOME/.config/opencode/skills/$NAME"
oc_link_status() {  # 返回码：0=链接且指向源 1=stale（悬空/指向他处） 2=缺失（或误为实体目录）
  if [ -L "$OC_LINK" ]; then
    _tgt="$(readlink "$OC_LINK")"
    [ "$_tgt" = "$SRC" ] && return 0 || return 1
  fi
  return 2
}
if [ "$CHECK_ONLY" = true ]; then
  _oc=0; oc_link_status check || _oc=$?   # set -e 保护：非零返回必须落在 || 链上捕获
  case $_oc in
    0) echo "✅ opencode 符号链接 → 源" ;;
    1) echo "⛔ opencode 符号链接 stale: $OC_LINK → $(readlink "$OC_LINK" 2>/dev/null || echo '?')（应为 ${SRC}）" >&2; fail=1 ;;
    2) echo "⚠ opencode 缺符号链接（可选修复：ln -s $SRC ${OC_LINK}）" ;;
  esac
elif [ -d "$HOME/.config/opencode/skills" ]; then
  if [ -L "$OC_LINK" ]; then
    oc_link_status check || { rm -f "$OC_LINK" && ln -s "$SRC" "$OC_LINK" && echo "✅ opencode 符号链接已修复 → $SRC"; }
  elif [ -e "$OC_LINK" ]; then
    echo "⚠ $OC_LINK 是实体目录（非符号链接）——手动处理：rm -rf 后 ln -s $SRC $OC_LINK"
  else
    ln -s "$SRC" "$OC_LINK" && echo "✅ opencode 符号链接已建 → $SRC"
  fi
fi

for t in "${TARGETS[@]}"; do
  DST="$HOME/.$t/skills/$NAME"
  # 工具未安装（其 skills 目录不存在）→ 跳过，不凭空创建目录
  if [ ! -d "$HOME/.$t/skills" ]; then
    echo "⏭  $t 未安装（$HOME/.$t/skills 不存在），跳过"
    continue
  fi
  if [ "$CHECK_ONLY" = true ]; then
    if [ ! -d "$DST" ]; then
      echo "⛔ $t 缺副本: ${DST}（重跑本脚本不带 --check 同步）" >&2; fail=1; continue
    fi
    if diff -r "${DIFF_EXCLUDES[@]}" "$SRC" "$DST" >/dev/null 2>&1; then
      echo "✅ $t 副本与源字节一致"
    else
      echo "⛔ $t 副本与源漂移: ${DST}（重跑本脚本同步后重测）" >&2; fail=1
    fi
    continue
  fi
  mkdir -p "$DST"
  # 目标端历史残留的字节码/运行态先清掉（rsync --exclude 只是不复制，不会删除目标端已有物）
  find "$DST" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  rsync -a --delete "${EXCLUDES[@]}" "$SRC/" "$DST/"
  # 校验内容一致
  if diff -r "${DIFF_EXCLUDES[@]}" "$SRC" "$DST" >/dev/null; then
    echo "✅ $t → $DST"
  else
    echo "⛔ $t 同步后校验不一致: $DST" >&2
    exit 1
  fi
done

if [ "$CHECK_ONLY" = true ]; then
  [ $fail -eq 0 ] && echo "发布门禁通过：${TARGETS[*]} 全部与源一致" || { echo "发布门禁失败——存在漂移副本" >&2; exit 1; }
else
  echo "完成：${TARGETS[*]}（源未动；更新后重跑本脚本即可全量刷新；发布前 --check 必须全绿）"
fi
