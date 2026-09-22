#!/usr/bin/env bash
# refresh-receipts.sh · 一键刷新全阶段收据（skill 升版/树漂移后的机械性重跑）
# 用法:
#   refresh-receipts.sh <feature> [--prd <路径>] [--evidence <tsv>] [--service <名>]
#       [--design-mode monolith|total|sub] [--migration <A|B|C>] [--skip-p2a] [--migrate-tree]
#
# 说明: 编排逻辑在 scripts/refresh_receipts_lib.sh；本入口解析参数后固定以
#       $SKILL/scripts 为 Gate 目录调用——**不接受任何替换 Gate 的环境变量**
#       （v3.29.4 移除 DEVFLOW_REFRESH_GATE_DIR：生产环境变量后门可绕过构建/审查/P6-final）。
#       迁移策略以 design.json migrations.strategy 冻结值为唯一事实源，
#       --migration 只能与之相等；结束以 state current_phase COMPLETED 为准。
set -u
SKILL="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=devflow_feature.sh
. "$SKILL/scripts/devflow_feature.sh"
# shellcheck source=py_runtime.sh
. "$SKILL/scripts/py_runtime.sh"
# shellcheck source=refresh_receipts_lib.sh
. "$SKILL/scripts/refresh_receipts_lib.sh"

usage() {
  echo "用法: refresh-receipts.sh <feature> [--prd <路径>] [--evidence <tsv>]" >&2
  echo "      [--service <名>] [--design-mode monolith|total|sub] [--migration <A|B|C>]" >&2
  echo "      [--skip-p2a] [--migrate-tree]" >&2
}

FEATURE="${1:-}"
[ -n "$FEATURE" ] || { usage; exit 2; }
devflow_feature_validate "$FEATURE" || exit 2
shift

RF_PRD="docs/PRD/${FEATURE}.md"; RF_EVID="docs/test/${FEATURE}-implementation-evidence.tsv"
RF_SERVICE="$FEATURE"; RF_DESIGN_MODE="monolith"; RF_MIGRATION=""; RF_SKIP_P2A=0; RF_MIGRATE_TREE=0
# shellcheck disable=SC2034  # RF_* 由 source 的 refresh_receipts_run 消费
while [ $# -gt 0 ]; do
  case "$1" in
    --prd)          [ $# -ge 2 ] || { echo "[FAIL] --prd 缺少参数" >&2; usage; exit 2; }; RF_PRD="$2"; shift 2;;
    --evidence)     [ $# -ge 2 ] || { echo "[FAIL] --evidence 缺少参数" >&2; usage; exit 2; }; RF_EVID="$2"; shift 2;;
    --service)      [ $# -ge 2 ] || { echo "[FAIL] --service 缺少参数" >&2; usage; exit 2; }; RF_SERVICE="$2"; shift 2;;
    --design-mode)  [ $# -ge 2 ] || { echo "[FAIL] --design-mode 缺少参数" >&2; usage; exit 2; }; RF_DESIGN_MODE="$2"; shift 2;;
    --migration)    [ $# -ge 2 ] || { echo "[FAIL] --migration 缺少参数" >&2; usage; exit 2; }; RF_MIGRATION="$2"; shift 2;;
    --skip-p2a)     RF_SKIP_P2A=1; shift;;
    --migrate-tree) RF_MIGRATE_TREE=1; shift;;
    --help|-h)      usage; exit 0;;
    *)              echo "[FAIL] 未知参数: $1" >&2; usage; exit 2;;
  esac
done
case "$RF_DESIGN_MODE" in monolith|total|sub) ;; *)
  echo "[FAIL] --design-mode 仅支持 monolith|total|sub，收到: ${RF_DESIGN_MODE}" >&2; exit 2;;
esac
case "$RF_MIGRATION" in ""|A|B|C) ;; *)
  echo "[FAIL] --migration 仅支持 A|B|C（互斥的冻结迁移策略），收到: ${RF_MIGRATION}" >&2; exit 2;;
esac

RF_SKILL="$SKILL"; RF_ROOT="$(pwd -P)"; RF_FEATURE="$FEATURE"
RF_GATE_BIN="$SKILL/scripts"
: "$RF_SKILL" "$RF_ROOT" "$RF_FEATURE" "$RF_GATE_BIN"  # 显式使用（RF_* 转 source 库函数）
refresh_receipts_run
