#!/usr/bin/env bash
# ============================================================
# devflow-state.sh (dispatcher；版本随 SKILL.md)
# ------------------------------------------------------------
# 用途:devflow 工作流状态管理(向后兼容入口)
#
# v3.9 拆分:
#   本文件仅做命令分发,业务逻辑下沉到 3 个子脚本:
#     - devflow-state-core.sh      (init / checkpoint / resume / status / list)
#     - devflow-state-complete.sh  (complete / complete-s / acceptance / snapshot / accuracy / graph / block / reconcile)
#     - devflow-state-template.sh  (generate)
#
# 用法(保持 v3.8 用法 100% 兼容):
#   bash devflow-state.sh init <feature>
#   bash devflow-state.sh checkpoint <feature> [note]
#   bash devflow-state.sh resume <feature>
#   bash devflow-state.sh status <feature>
#   bash devflow-state.sh complete <feature> <phase>
#   bash devflow-state.sh complete-s <feature> <S-stage>
#   bash devflow-state.sh list
# ============================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="${SKILL_ROOT:-$SCRIPT_DIR/..}"

CORE="$SCRIPT_DIR/devflow-state-core.sh"
COMPLETE="$SCRIPT_DIR/devflow-state-complete.sh"
TEMPLATE="$SCRIPT_DIR/devflow-state-template.sh"

# 帮助文本(只在这里,子脚本不再重复)
cmd_help() {
  cat <<EOF
DevFlow 状态管理 (v3.9.0 dispatcher)

用法:
  bash "$SCRIPT_DIR/devflow-state.sh" <command> [args]

命令(按职责分散到子脚本):

  [core] 初始化与恢复:
    init <feature> [--frontend=pc-web|mini-program|app|not-applicable] [--frontend-dir=<path>]
                                    初始化新工作流并冻结前端范围
    checkpoint <feature> [note]     保存检查点
    reconcile <feature> [--apply]   状态机与收据链对账（--apply 只进不退）
    resume <feature>                从检查点恢复
    status <feature>                查看详细状态
    list                            列出所有工作流
    repair <feature> [--frontend=pc-web|mini-program|app|not-applicable] [--frontend-dir=<path>]
                                    修复已验证的历史空阶段键；可补录前端范围（不触碰冻结树 hash）
    migrate-tree <feature>          显式迁移 skill 树锚点（skill 升级后旧收据树≠state 冻结树时；
                                    写入 SKILL-TREE-MIGRATION 收据后才更新冻结值）
    client-freeze <feature>         冻结小程序/APP manifest 哈希（P2 完成后、P3 前）
    constraints-freeze <feature>    冻结技术约束契约 SHA（P0 Gate 后、P1 前调用）
    constraints-inherit <feature> [--from <source>|@latest]
                                    从既有 feature 继承技术约束机器块（P0 只澄清 delta；
                                    继承稿仍须 s0 门禁 + constraints-freeze，冻结契约不变）

  [complete] 阶段完成与审计:
    complete <feature> <P-phase>    标记 P-阶段完成 (P0, P3, P3b, ...)
    complete-s|complete-stage <feature> <P-stage>
                                    兼容别名：转发主阶段状态机（不创建独立状态轨）
    acceptance <feature> <action>   验收点管理(set-count/freeze/complete/inc)
    snapshot <feature> [path]       首轮快照
    accuracy <feature> [n%]         首轮准确率
    graph <feature> [status] [score] 图谱状态
    block <feature> <message>       添加阻塞项

  [template] 文档生成:
    generate <feature> <phase> <output>  从模板生成文档
    list-templates                       列出可用模板

  help                              显示本帮助

v3.9 拆分:
  实际逻辑在以下三个子脚本,本文件只负责分发:
    - \$CORE
    - \$COMPLETE
    - \$TEMPLATE

Gate 收据机制 (v3.8.0 P0-6 修复):
  Gate 收据路径: .devflow/<feature>/gates/<stage>/receipt.txt
  收据格式:
    EXIT_CODE=<exit_code>
    ARTIFACT_HASH=<hash>
    OUTPUT=<summary>
EOF
}

# 检查子脚本存在
for f in "$CORE" "$COMPLETE" "$TEMPLATE"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: 子脚本不存在: $f" >&2
    echo "       拆分可能未完成,请从 git 恢复 devflow-state.sh.*.bak" >&2
    exit 2
  fi
done

# v3.15.5: feature 白名单统一入口校验——所有子命令以 $2 为 feature；此前 init/complete 等直接拼
# $STATE_DIR/<feature>.state.json 路径（../../evil 可写穿项目外）。list/help 无 feature 参数，跳过。
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
if [ -n "${2:-}" ]; then
  devflow_feature_validate "$2" || exit 2
fi

# 主入口 — 按命令分发
case "${1:-help}" in
  # --- core ---
  init)         bash "$CORE"     "$@" ;;
  checkpoint)   bash "$CORE"     "$@" ;;
  resume)       bash "$CORE"     "$@" ;;
  status)       bash "$CORE"     "$@" ;;
  list)         bash "$CORE"     "$@" ;;
  repair)       bash "$CORE"     "$@" ;;
  migrate-tree) bash "$CORE"     "$@" ;;
  client-freeze) bash "$CORE"     "$@" ;;
  constraints-freeze) bash "$CORE" "$@" ;;
  constraints-inherit) bash "$CORE" "$@" ;;

  # --- complete ---
  complete)       bash "$COMPLETE" "$@" ;;
  complete-s)     bash "$COMPLETE" "$@" ;;
  complete-stage) bash "$COMPLETE" "$@" ;;
  acceptance)     bash "$COMPLETE" "$@" ;;
  snapshot)       bash "$COMPLETE" "$@" ;;
  accuracy)       bash "$COMPLETE" "$@" ;;
  graph)          bash "$COMPLETE" "$@" ;;
  block)          bash "$COMPLETE" "$@" ;;
  reconcile)      bash "$COMPLETE" "$@" ;;

  # --- template ---
  generate)       bash "$TEMPLATE" "$@" ;;
  list-templates) bash "$TEMPLATE" "$@" ;;

  # --- meta ---
  help|--help|-h) cmd_help ;;
  *)
    echo "ERROR: 未知命令: $1" >&2
    echo "运行 'devflow-state.sh help' 查看帮助" >&2
    exit 1
    ;;
esac
