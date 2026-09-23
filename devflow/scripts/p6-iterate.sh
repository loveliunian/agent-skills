#!/usr/bin/env bash
# p6-iterate.sh · P6 修复循环增量重跑（v3.30.1）
#
# 用法:
#   bash scripts/p6-iterate.sh <feature> <unit|integration|client|load|staging> [--filter <expr>] [--dry-run]
#   bash scripts/p6-iterate.sh <feature> --list
#
# --dry-run：只打印拼接后的完整命令，不执行、不写日志（预检 --filter 拼接）。
#
# 定位（m01-base 复盘速度优化 #2）：P6 修复循环里「改一行 → 全量五类重跑」是
# 实测最大时间坑之一（登录死锁修复一轮全量 mvn 51 用例 + playwright）。本脚本
# 从终验同一事实源 `.devflow/<feature>/test-evidence.env` 读取指定套件的命令，
# 只重跑该套件，支持按测试类/用例过滤；输出写入 iterations/ 目录，与终验证据
# 严格分离。
#
# 边界（与 P6-final 反自报契约的一致性——本脚本不削弱任何门禁）：
#   - 只读 test-evidence.env：不写 *_EXIT / *_REPORT_PATH，迭代运行不是终验证据；
#   - P6-final 门禁仍全量真实重执行五类命令，并拒绝内容未变的陈旧报告（不变）；
#   - 修复循环收敛后，按常规流程跑 s6_first_pass_accuracy.sh + s6_final_verification_gate.sh；
#   - 迭代产物只存在于 .devflow/<feature>/iterations/，不进入任何收据证据树。
#
# --filter 按命令首词做框架感知拼接（Maven 多个 -Dtest 时后者生效=过滤覆盖，符合迭代语义）：
#   mvn/mvnw/./mvnw → -Dtest='<expr>'   gradle/gradlew/./gradlew → --tests '<expr>'
#   npm → -- --grep='<expr>'     pnpm/yarn → --grep '<expr>'
#   pytest → -k '<expr>'         go → -run '<expr>'    cargo → '<expr>'
#   其他运行器不支持过滤 → 拒绝执行（exit 2），去掉 --filter 即整套件重跑。
#   expr 含引号/反引号/$/;/&/反斜杠一律拒绝（防 eval 注入）。
set -uo pipefail

SKILL="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=devflow_feature.sh
. "$SKILL/scripts/devflow_feature.sh"

FEATURE="${1:-}"
KIND_ARG="${2:-}"
FILTER=""
DRY_RUN=0

usage() {
  echo "用法: $0 <feature> <unit|integration|client|load|staging> [--filter <expr>] [--dry-run]" >&2
  echo "      $0 <feature> --list" >&2
}

[ -n "$FEATURE" ] && [ -n "$KIND_ARG" ] || { usage; exit 2; }
devflow_feature_validate "$FEATURE" || exit 2
shift 2 || true
while [ $# -gt 0 ]; do
  case "$1" in
    --filter) [ $# -ge 2 ] || { echo "[iterate] --filter 缺少参数" >&2; usage; exit 2; }; FILTER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "[iterate] 未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

EV=".devflow/${FEATURE}/test-evidence.env"
[ -f "$EV" ] || { echo "[iterate] 缺少 ${EV}（五类测试命令未声明——先完成 P5/P6 测试设计）" >&2; exit 2; }

if [ "$KIND_ARG" = "--list" ]; then
  echo "[iterate] ${EV} 声明的测试命令："
  grep -E '^(UNIT|INTEGRATION|CLIENT|LOAD|STAGING)_CMD=' "$EV" | sed -E 's/^([A-Z]+)_CMD=/  \1 /'
  exit 0
fi

case "$KIND_ARG" in
  unit) KIND_UP="UNIT" ;;
  integration) KIND_UP="INTEGRATION" ;;
  client) KIND_UP="CLIENT" ;;
  load) KIND_UP="LOAD" ;;
  staging) KIND_UP="STAGING" ;;
  *) echo "[iterate] 未知套件: ${KIND_ARG}（须 unit|integration|client|load|staging）" >&2; exit 2 ;;
esac

# 逐行解析（env 值含空格/引号，不可 source——与 s6 同一教训）
CMD=$(sed -n "s/^${KIND_UP}_CMD=//p" "$EV" | head -1)
[ -n "$CMD" ] || { echo "[iterate] ${KIND_UP}_CMD 未声明于 ${EV}" >&2; exit 2; }

FIRST=$(printf '%s' "$CMD" | awk '{print $1}')
FIRST="${FIRST#./}"   # 识别 ./mvnw、./gradlew 包装器（v3.29.2：此前只匹配裸 mvnw/gradlew）
FULL_CMD="$CMD"
if [ -n "$FILTER" ]; then
  if printf '%s' "$FILTER" | grep -qE "[\"'\`\$;&\\]"; then
    echo "[iterate] --filter 含危险字符（引号/反引号/\$/;/&/反斜杠被拒）: ${FILTER}" >&2; exit 2
  fi
  case "$FIRST" in
    mvn|mvnw|mvnw.cmd)      FULL_CMD="${CMD} -Dtest='${FILTER}'" ;;
    gradle|gradlew|gradlew.cmd) FULL_CMD="${CMD} --tests '${FILTER}'" ;;
    npm)             FULL_CMD="${CMD} -- --grep='${FILTER}'" ;;
    pnpm|yarn)       FULL_CMD="${CMD} --grep '${FILTER}'" ;;
    pytest)          FULL_CMD="${CMD} -k '${FILTER}'" ;;
    go)              FULL_CMD="${CMD} -run '${FILTER}'" ;;
    cargo)           FULL_CMD="${CMD} '${FILTER}'" ;;
    *)
      echo "[iterate] 运行器 ${FIRST} 不支持自动过滤——去掉 --filter 整套件重跑" >&2; exit 2 ;;
  esac
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "[iterate][dry-run] cmd=${FULL_CMD}"
  exit 0
fi

case "$KIND_ARG" in
  client)  echo "[iterate] 提示：client 依赖前端 dev server 已就绪（与终验同前提）" ;;
  staging) echo "[iterate] 提示：staging 依赖后端容器已就绪（与终验同前提）" ;;
esac

TS=$(date +%Y%m%d-%H%M%S)
LOG_DIR=".devflow/${FEATURE}/iterations"
LOG="${LOG_DIR}/${TS}-${KIND_ARG}.log"
mkdir -p "$LOG_DIR" || { echo "[iterate] 无法创建 ${LOG_DIR}" >&2; exit 2; }

{
  echo "feature=${FEATURE}"
  echo "kind=${KIND_ARG}"
  echo "cmd=${FULL_CMD}"
  echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "---"
} > "$LOG"

echo "[iterate] ▶ ${FULL_CMD}"
eval "$FULL_CMD" 2>&1 | tee -a "$LOG"
RC=$?
{
  echo "---"
  echo "exit=${RC}"
  echo "finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$LOG"

echo "[iterate] ${KIND_ARG} exit=${RC} log=${LOG}"
echo "[iterate] 迭代运行≠终验证据（未写 test-evidence.env）；收敛后仍须全量跑 P6-final"
exit "$RC"
