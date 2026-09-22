#!/usr/bin/env bash
# p6-prewarm.sh · P6 环境预热（v3.29.1）
#
# 用法:
#   bash scripts/p6-prewarm.sh <feature> --backend-cmd <cmd> [--frontend-cmd <cmd>] [选项]
#   bash scripts/p6-prewarm.sh <feature> --status        # 只探测就绪态，不启动
#   bash scripts/p6-prewarm.sh <feature> --stop          # 停掉本脚本记录的服务
#
# 定位（m01-base 复盘速度优化 #3，教训 L-PROC-005）：E2E/CLIENT 冷启动超时重试
# （实测 J1/J2 两次超时）源于 P6 开始才启动后端容器与前端 dev server。本脚本在
# **P5 测试设计期间**以后台方式启动并轮询健康，P6 开始即热。
#
# 幂等：健康检查已绿则跳过启动直接报 warm（可放心重复执行）。
# 产物：日志与 PID 落 .devflow/<feature>/prewarm/（非终验证据，不进收据树）。
#
# 选项（默认值可经 .devflow/<feature>/prewarm.env 的同名变量覆盖）:
#   --backend-cmd <cmd>   后端启动命令（必填，或经 prewarm.env BACKEND_CMD）
#   --frontend-cmd <cmd>  前端启动命令（可选）
#   --health-url <url>    后端健康 URL（默认 http://localhost:8080/api/actuator/health）
#   --frontend-url <url>  前端就绪 URL（默认 http://localhost:5173）
#   --timeout <sec>       就绪等待上限（默认 180；0=只启动不等待）
#
# 退出码：0=就绪/已就绪；2=参数错误；3=超时未就绪。
set -uo pipefail

FEATURE="${1:-}"
[ -n "$FEATURE" ] || { echo "用法: $0 <feature> --backend-cmd <cmd>|--status|--stop [选项]" >&2; exit 2; }
shift || true

PREWARM_DIR=".devflow/${FEATURE}/prewarm"
EV="${PREWARM_DIR}/prewarm.env"
# 项目侧一次性写好的默认值（KEY=VALUE，值不含引号空格）；路径由 feature 名拼接
# shellcheck source=/dev/null
[ -f "$EV" ] && . "$EV"

BACKEND_CMD="${BACKEND_CMD:-}"
FRONTEND_CMD="${FRONTEND_CMD:-}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/api/actuator/health}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost:5173}"
TIMEOUT="${TIMEOUT:-180}"
MODE="warm"

while [ $# -gt 0 ]; do
  case "$1" in
    --backend-cmd)  BACKEND_CMD="${2:?}"; shift 2 ;;
    --frontend-cmd) FRONTEND_CMD="${2:?}"; shift 2 ;;
    --health-url)   HEALTH_URL="${2:?}"; shift 2 ;;
    --frontend-url) FRONTEND_URL="${2:?}"; shift 2 ;;
    --timeout)      TIMEOUT="${2:?}"; shift 2 ;;
    --status)       MODE="status"; shift ;;
    --stop)         MODE="stop"; shift ;;
    *) echo "[prewarm] 未知参数: $1" >&2; exit 2 ;;
  esac
done

probe() { # <url> —— 2xx 即就绪
  curl -sf -o /dev/null --max-time 3 "$1" 2>/dev/null
}

if [ "$MODE" = "stop" ]; then
  if [ -f "${PREWARM_DIR}/pids.env" ]; then
    while IFS='=' read -r _name _pid; do
      case "$_name" in ''|'#'*) continue ;; esac
      if kill "$_pid" 2>/dev/null; then
        echo "[prewarm] 已停止 ${_name}（pid=${_pid}）"
      else
        echo "[prewarm] ${_name}（pid=${_pid}）已不在运行"
      fi
    done < "${PREWARM_DIR}/pids.env"
    rm -f "${PREWARM_DIR}/pids.env"
  else
    echo "[prewarm] 无已记录的服务（${PREWARM_DIR}/pids.env 不存在）"
  fi
  exit 0
fi

BE_UP=1; FE_UP=1
probe "$HEALTH_URL" && BE_UP=0
[ -z "$FRONTEND_CMD" ] || { probe "$FRONTEND_URL" && FE_UP=0; }

if [ "$MODE" = "status" ]; then
  [ "$BE_UP" = "0" ] && echo "[prewarm] backend  ${HEALTH_URL} → 就绪" || echo "[prewarm] backend  ${HEALTH_URL} → 未就绪"
  if [ -n "$FRONTEND_CMD" ] || [ "$FE_UP" = "0" ]; then
    [ "$FE_UP" = "0" ] && echo "[prewarm] frontend ${FRONTEND_URL} → 就绪" || echo "[prewarm] frontend ${FRONTEND_URL} → 未就绪"
  fi
  [ "$BE_UP" = "0" ] && { [ -z "$FRONTEND_CMD" ] || [ "$FE_UP" = "0" ]; }
  exit
fi

mkdir -p "$PREWARM_DIR" || { echo "[prewarm] 无法创建 ${PREWARM_DIR}" >&2; exit 2; }

start_and_wait() { # <label> <cmd> <url> <log> —— 返回 0=就绪 3=超时
  local label="$1" cmd="$2" url="$3" log="$4" pid rc
  if probe "$url"; then
    echo "[prewarm] ${label} 已就绪（${url}），跳过启动（保留既有 pid 记录）"
    return 0
  fi
  [ -n "$cmd" ] || { echo "[prewarm] ${label} 未就绪且未提供启动命令" >&2; return 3; }
  echo "[prewarm] 启动 ${label}: ${cmd}"
  nohup sh -c "exec ${cmd}" >> "$log" 2>&1 &
  pid=$!
  echo "${label}=${pid}" >> "${PREWARM_DIR}/pids.env"
  if [ "$TIMEOUT" = "0" ]; then
    echo "[prewarm] ${label} 已后台启动（pid=${pid}），--timeout 0 不等待"
    return 0
  fi
  rc=3
  while [ "$SECONDS" -lt "$TIMEOUT" ]; do
    if probe "$url"; then
      echo "[prewarm] ${label} 就绪（pid=${pid}，${SECONDS}s 内）"
      rc=0
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[prewarm] ${label} 进程（pid=${pid}）提前退出——查 ${log}" >&2
      return 3
    fi
    sleep 2
  done
  [ "$rc" = "0" ] || echo "[prewarm] ${label} ${TIMEOUT}s 内未就绪（${url}）——查 ${log}" >&2
  return "$rc"
}

RC_BE=0
start_and_wait backend "$BACKEND_CMD" "$HEALTH_URL" "${PREWARM_DIR}/backend.log" || RC_BE=$?
RC_FE=0
[ -z "$FRONTEND_CMD" ] || start_and_wait frontend "$FRONTEND_CMD" "$FRONTEND_URL" "${PREWARM_DIR}/frontend.log" || RC_FE=$?

if [ "$RC_BE" = "0" ] && { [ -z "$FRONTEND_CMD" ] || [ "$RC_FE" = "0" ]; }; then
  echo "[prewarm] 全部就绪——P6 可直接开始（终验仍会真实重执行全部命令）"
  exit 0
fi
exit 3
