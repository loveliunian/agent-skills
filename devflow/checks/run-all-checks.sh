#!/usr/bin/env bash
# ============================================================
# run-all-checks.sh (v3.4 - skill-grade)
# ------------------------------------------------------------
# 用途：一键跑所有 6 个 check 脚本（编排器）
# 子脚本（必须与本脚本同目录）：
#   - detect-n-plus-one.sh
#   - check-code-standards.sh
#   - check-entity-db-consistency.sh
#   - check-frontend-standards.sh
#   - check-permission-consistency.sh
#
# 退出码：0 = 全部 PASS；1 = 至少一个 FAIL
#
# 用法：
#   bash "$SKILL_ROOT/checks/run-all-checks.sh"                # 跑所有
#   bash "$SKILL_ROOT/checks/run-all-checks.sh" --only n+1,code  # 指定子集
#   bash "$SKILL_ROOT/checks/run-all-checks.sh" --no-frontend  # 跳过前端
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ONLY=""
SKIP_FRONTEND=0

# v3.15.2: 修复参数解析——case 内已按需 shift，删除外层无条件 shift
# （旧逻辑：--only 消费 2 个参数后再 shift 共 3 个，--no-frontend 消费 2 个——后续 flag 被吞）
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      # v3.15.11: 补 flag 吞参守卫（v3.15.10 全树口径的第 19 处漏网——--only --no-frontend 会吞 flag）
      [ $# -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --only 需要参数（如 --only n+1,code，不得为 flag）" >&2; exit 2; }
      ONLY="$2"; shift 2 ;;
    --no-frontend) SKIP_FRONTEND=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "[ERR] unknown flag: $1" >&2; exit 2 ;;
  esac
done

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }

# 5 个子脚本
CHECKS=(
  "n+1:detect-n-plus-one.sh"
  "code:check-code-standards.sh"
  "entity-db:check-entity-db-consistency.sh"
  "frontend:check-frontend-standards.sh"
  "permission:check-permission-consistency.sh"
  "arch-pitfalls:check-arch-pitfalls.sh"
)

# v3.15.2: 修复 --only 筛选——旧逻辑先清空 CHECKS 再"从空数组筛选"，任何子集都零执行
# （bash 4.4+ 下静默零执行 + "全部 PASS" exit 0 假绿；bash 3.2 + set -u 直接 unbound 崩溃）。
# 新逻辑：保留全量副本 ALL_CHECKS，从副本精确筛选；非法名/零匹配均 exit 2 fail-closed。
if [ -n "$ONLY" ]; then
  IFS=',' read -ra WANTED <<< "$ONLY"
  ALL_CHECKS=("${CHECKS[@]}")
  CHECKS=()
  for want in "${WANTED[@]}"; do
    want="${want//[[:space:]]/}"
    [ -n "$want" ] || continue
    # v3.15.3: 已选中的 check 跳过（--only n+1,n+1 不再重复执行）
    case ":${SELECTED:-}:" in *":$want:"*) continue ;; esac
    SELECTED="${SELECTED:-}$want:"
    matched=0
    for ck in "${ALL_CHECKS[@]}"; do
      if [ "${ck%%:*}" = "$want" ]; then
        CHECKS+=("$ck"); matched=1; break
      fi
    done
    [ "$matched" -eq 1 ] || {
      echo "[ERR] unknown check: $want (valid: n+1,code,entity-db,frontend,permission,arch-pitfalls)" >&2
      exit 2
    }
  done
  [ ${#CHECKS[@]} -gt 0 ] || { echo "[ERR] --only 未选中任何 check" >&2; exit 2; }
fi

echo "============================================="
echo "  跑所有 check"
echo "============================================="
echo "子脚本目录: $SCRIPT_DIR"
echo "执行项: ${ONLY:-全部}"
[ "$SKIP_FRONTEND" -eq 1 ] && echo "跳过前端"
echo

total_fail=0
# v3.15.2: 子进程输出落临时文件再取 rc——旧 if/PIPESTATUS 写法依赖管道求值时序，
# 且 if 条件实际测试的是 tail 的退出码（else 分支不可达的死代码）
LOG_FILE=$(mktemp) || { echo "[ERR] 无法创建临时文件" >&2; exit 2; }
trap 'rm -f "$LOG_FILE"' EXIT
for ck in "${CHECKS[@]}"; do
  key="${ck%%:*}"
  script="${ck##*:}"
  if [ "$key" = "frontend" ] && [ "$SKIP_FRONTEND" -eq 1 ]; then
    echo "[SKIP] $key"
    continue
  fi
  if [ ! -f "$SCRIPT_DIR/$script" ]; then
    err "[MISS] $script 不存在"
    total_fail=$((total_fail + 1))
    continue
  fi
  echo ">>> $key ($script)"
  bash "$SCRIPT_DIR/$script" > "$LOG_FILE" 2>&1
  rc=$?
  tail -3 "$LOG_FILE"
  [ "$rc" -eq 0 ] || total_fail=$((total_fail + 1))
  echo
done

echo "============================================="
echo "  总结"
echo "============================================="
if [ "$total_fail" -gt 0 ]; then
  err "总失败: $total_fail"
  exit 1
else
  ok "全部 PASS"
  exit 0
fi
