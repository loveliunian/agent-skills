#!/usr/bin/env bash
# release_git_lib.sh · release.sh 的 Git 快照判定（抽为库——生产接线与测试共用，
# 替代此前"fixture 驱动完整 release + 环境变量降级"的形态：两个生产后门 + 300s 瓶颈）。
# 函数：
#   release_git_in_repo <root>                是否 Git 工作树（rc 0/1）
#   release_git_dirty <root>                  工作树脏 → rc=1（stdout 脏行）；干净 rc=0
#   release_git_final <root> <manifest已存在>  终态判定：
#       非 Git 仓库                     → RELEASED 行，rc=0
#       Git，manifest_exists=0（首发） → READY_TO_COMMIT 块（含提交指令），rc=3，不回滚
#       Git，manifest_exists=1（复跑） → RELEASED 行，rc=0
# v3.29.7: 新建（P0：RUN_TESTS_GROUPS/DEVFLOW_COPY_TARGETS 后门移除的配套重构）。
set -u

release_git_in_repo() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

release_git_dirty() {
  local root="$1" dirty
  dirty=$(git -C "$root" status --porcelain 2>/dev/null | head -5)
  if [ -n "$dirty" ]; then
    printf '%s\n' "$dirty"
    return 1
  fi
  return 0
}

release_git_final() {
  local root="$1" manifest_exists="$2" ver
  ver=$(sed -n 's/^  version: "//p' "$root/SKILL.md" | head -1 | sed 's/"$//')
  if ! release_git_in_repo "$root"; then
    echo "RELEASE GATE: RELEASED — 发布完成（非 Git 环境：manifest+台账+副本一致）"
    return 0
  fi
  if [ "$manifest_exists" = "0" ]; then
    echo ""
    echo "RELEASE GATE: READY_TO_COMMIT — manifest+台账已生成（本地发布完成，非 Git 发布完成）"
    echo "  提交后复跑 release.sh 完成 RELEASED 验证:"
    echo "    git -C $root add references/manifest/${ver}.json references/manifest/CHAIN.json"
    echo "    git -C $root commit -m 'v${ver}: release manifest+ledger'"
    echo "    bash scripts/release.sh"
    return 3
  fi
  echo "RELEASE GATE: RELEASED — 发布完成（manifest+台账+副本直连一致，Git 快照自洽）"
  return 0
}
