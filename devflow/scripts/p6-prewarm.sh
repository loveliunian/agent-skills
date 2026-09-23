#!/usr/bin/env bash
# p6-prewarm.sh · P6 环境预热（v3.30.10）
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
# v3.29.2 加固：feature 白名单（devflow_feature_validate，封堵路径穿越）；prewarm.env
#   白名单化加载（仅纯 KEY=VALUE，值含 ;|&<>$/反引号 一律拒绝——防 source 注入）；
#   --stop 校验 pid 为正整数且进程命令行与启动时记录一致（防陈旧 PID 复用误杀）；
#   每服务独立就绪超时（修复共用 SECONDS 全局变量挤占）；pid 记录按 label 去重（不再累积）。
set -uo pipefail

SKILL="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=devflow_feature.sh
. "$SKILL/scripts/devflow_feature.sh"

usage() { echo "用法: $0 <feature> --backend-cmd <cmd>|--status|--stop [选项]" >&2; }

FEATURE="${1:-}"
[ -n "$FEATURE" ] || { usage; exit 2; }
devflow_feature_validate "$FEATURE" || exit 2
shift || true

PREWARM_DIR=".devflow/${FEATURE}/prewarm"
EV="${PREWARM_DIR}/prewarm.env"
# 项目侧一次性写好的默认值；路径由 feature 名拼接。
# 安全加载：仅接受注释/空行行 + 五个白名单键（BACKEND_CMD/FRONTEND_CMD/HEALTH_URL/
# FRONTEND_URL/TIMEOUT）的纯 KEY=VALUE 行——其他变量名（PATH/IFS 等可劫持后续
# curl/ps/nohup/mv 行为的键）与含 ;|&<>$` 的值一律整体拒绝（防 source 注入）
if [ -f "$EV" ]; then
  if grep -vE '^[[:space:]]*(#|$)' "$EV" | grep -qvE '^(BACKEND_CMD|FRONTEND_CMD|HEALTH_URL|FRONTEND_URL|TIMEOUT)='; then
    echo "[prewarm] $EV 含白名单外变量名（只允许 BACKEND_CMD/FRONTEND_CMD/HEALTH_URL/FRONTEND_URL/TIMEOUT）——拒绝加载" >&2
    exit 2
  fi
  if grep -vE '^[[:space:]]*(#|$)' "$EV" | grep -qE '[;|&<>$`]'; then
    echo "[prewarm] $EV 值含危险字符（;|&<>\$/反引号）——拒绝加载（防 source 注入）" >&2
    exit 2
  fi
  TIMEOUT_VAL=$(sed -n 's/^TIMEOUT=//p' "$EV" | head -1)
  case "$TIMEOUT_VAL" in '')
  ;; *[!0-9]*)
    echo "[prewarm] $EV TIMEOUT 必须为非负整数——拒绝加载" >&2
    exit 2 ;;
  esac
  # shellcheck source=/dev/null
  . "$EV"
fi

BACKEND_CMD="${BACKEND_CMD:-}"
FRONTEND_CMD="${FRONTEND_CMD:-}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/api/actuator/health}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost:5173}"
TIMEOUT="${TIMEOUT:-180}"
MODE="warm"

need_value() { # <flag> <下一个参数存在性> —— 缺值即 exit 2（不再依赖 \${2:?} 的 unbound 退出）
  echo "[prewarm] $1 缺少参数" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --backend-cmd)  [ $# -ge 2 ] || need_value "$1";  BACKEND_CMD="$2";  shift 2 ;;
    --frontend-cmd) [ $# -ge 2 ] || need_value "$1";  FRONTEND_CMD="$2"; shift 2 ;;
    --health-url)   [ $# -ge 2 ] || need_value "$1";  HEALTH_URL="$2";   shift 2 ;;
    --frontend-url) [ $# -ge 2 ] || need_value "$1";  FRONTEND_URL="$2"; shift 2 ;;
    --timeout)      [ $# -ge 2 ] || need_value "$1";  TIMEOUT="$2";      shift 2 ;;
    --status)       MODE="status"; shift ;;
    --stop)         MODE="stop"; shift ;;
    *) echo "[prewarm] 未知参数: $1" >&2; exit 2 ;;
  esac
done

# v3.29.4: 最终 TIMEOUT 统一校验——CLI --timeout 直接覆盖 env 值（env 已校验过也不能信）
case "$TIMEOUT" in ''|*[!0-9]*)
  echo "[prewarm] --timeout 必须为非负整数，收到: ${TIMEOUT}" >&2; exit 2 ;;
esac

probe() { # <url> —— 2xx 即就绪
  curl -sf -o /dev/null --max-time 3 "$1" 2>/dev/null
}

if [ "$MODE" = "stop" ]; then
  if [ -f "${PREWARM_DIR}/pids.env" ]; then
    _keep=0
    while IFS='=' read -r _name _pid; do
      case "$_name" in ''|'#'*) continue ;; esac
      case "$_name" in *.cmd|*.lstart) continue ;; esac   # 伴生记录行（label.cmd=/label.lstart=），非 pid 行
      case "$_pid" in ''|*[!0-9]*|0)
        echo "[prewarm] ${_name} 记录非法（pid='${_pid}' 非正整数）——跳过且保留记录（须人工核查）" >&2
        _keep=1
        continue ;;
      esac
      # 身份核验：PID+启动时间（lstart）双匹配——PID 复用必然新 lstart，陈旧记录不误杀
      _expect_ls=$(grep -m1 "^${_name}.lstart=" "${PREWARM_DIR}/pids.env" | cut -d= -f2-)
      _cur=$(ps -p "$_pid" -o command= 2>/dev/null || true)
      _ls_now=$(ps -p "$_pid" -o lstart= 2>/dev/null || true)
      if [ -z "$_cur" ]; then
        echo "[prewarm] ${_name}（pid=${_pid}）已不在运行"
      elif [ -n "$_expect_ls" ] && [ -n "$_ls_now" ] && [ "$_ls_now" = "$_expect_ls" ]; then
        if kill "$_pid" 2>/dev/null; then
          echo "[prewarm] 已停止 ${_name}（pid=${_pid}，lstart 身份核验通过）"
        else
          echo "[prewarm] ${_name}（pid=${_pid}）kill 失败——保留记录" >&2
          _keep=1
        fi
      else
        echo "[prewarm] ⚠ pid=${_pid} 已非本脚本启动的 ${_name} 实例（lstart 不符或旧格式记录）——不误杀，保留记录待人工核查" >&2
        _keep=1
      fi
    done < "${PREWARM_DIR}/pids.env"
    if [ "$_keep" = "0" ]; then
      rm -f "${PREWARM_DIR}/pids.env"
    else
      echo "[prewarm] 存在未处置条目——pids.env 保留（人工核查后可删除）"
    fi
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

record_pid() { # <label> <pid> <cmd> —— 按 label 去重重写（修复追加模式累积陈旧记录）
  local label="$1" pid="$2" cmd="$3" tmp="${PREWARM_DIR}/pids.env.tmp"
  local lstart; lstart=$(ps -p "$pid" -o lstart= 2>/dev/null || true)
  { grep -vE "^${label}(=|\\.cmd=|\\.lstart=)" "${PREWARM_DIR}/pids.env" 2>/dev/null || true
    printf '%s=%s\n' "$label" "$pid"
    printf '%s.cmd=%s\n' "$label" "$cmd"
    printf '%s.lstart=%s\n' "$label" "$lstart"
  } > "$tmp" && mv "$tmp" "${PREWARM_DIR}/pids.env"
}

start_and_wait() { # <label> <cmd> <url> <log> —— 返回 0=就绪 3=超时（每服务独立超时窗）
  local label="$1" cmd="$2" url="$3" log="$4" pid rc t0 deadline
  if probe "$url"; then
    echo "[prewarm] ${label} 已就绪（${url}），跳过启动（保留既有 pid 记录）"
    return 0
  fi
  [ -n "$cmd" ] || { echo "[prewarm] ${label} 未就绪且未提供启动命令" >&2; return 3; }
  echo "[prewarm] 启动 ${label}: ${cmd}"
  nohup sh -c "exec ${cmd}" >> "$log" 2>&1 &
  pid=$!
  record_pid "$label" "$pid" "$cmd"
  if [ "$TIMEOUT" = "0" ]; then
    echo "[prewarm] ${label} 已后台启动（pid=${pid}），--timeout 0 不等待"
    return 0
  fi
  rc=3
  t0=$SECONDS
  deadline=$(( SECONDS + TIMEOUT ))   # 每服务独立窗口（修复共用 SECONDS 挤占）
  while [ "$SECONDS" -lt "$deadline" ]; do
    if probe "$url"; then
      echo "[prewarm] ${label} 就绪（pid=${pid}，$(( SECONDS - t0 ))s 内）"
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
