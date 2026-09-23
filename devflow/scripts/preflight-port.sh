#!/usr/bin/env bash
# 启动前端口占用预检
# 用法:
#  preflight-port.sh <port>         # 启动前：端口必须空闲
#   preflight-port.sh --expect-listening <port> [owner-pattern]
#                                             # 监控前：端口必须已被监听；
#                                             # 给出 owner-pattern 时额外校验监听进程匹配
set -uo pipefail
EXPECT_LISTENING=0
if [ "${1:-}" = "--expect-listening" ]; then
  EXPECT_LISTENING=1; shift
fi
PORT="${1:-}"
if ! printf '%s' "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "[FAIL] invalid TCP port: ${PORT:-missing}"; exit 2
fi

if [ "$EXPECT_LISTENING" = "1" ]; then
  OWNER="${2:-}"
  if command -v lsof >/dev/null 2>&1; then
    LISTEN_OUT=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2)
    if [ -z "$LISTEN_OUT" ]; then
      echo "[FAIL] TCP port $PORT is NOT listening — 监控目标服务未运行"; exit 1
    fi
    if [ -n "$OWNER" ]; then
      # 用 ps 取完整命令行（lsof 的 COMMAND 列截断且不含参数）
      PID=$(printf '%s\n' "$LISTEN_OUT" | awk '{print $2}' | head -1)
      FULL_CMD=$(ps -p "$PID" -o command= 2>/dev/null || true)
      if ! printf '%s' "$FULL_CMD" | grep -qi "$OWNER"; then
        echo "[FAIL] TCP port $PORT is listening but owner command '$FULL_CMD' does not match '$OWNER'"; exit 1
      fi
    fi
    echo "[PASS] TCP port $PORT is listening${OWNER:+ by $OWNER}"; exit 0
  fi
  if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    echo "[PASS] TCP port $PORT is listening"; exit 0
  fi
  # v3.29.8（Linux 实证）: lsof/nc 均缺时用 bash 内建 /dev/tcp 兜底（随 bash 必在）
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
    exec 3>&- 3<&- 2>/dev/null || true
    echo "[PASS] TCP port $PORT is listening (/dev/tcp probe)"; exit 0
  fi
  echo "[FAIL] TCP port $PORT is NOT listening — 监控目标服务未运行"; exit 1
fi

if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2 | grep -q .; then
    echo "[FAIL] TCP port $PORT is already listening"; exit 1
  fi
  echo "[PASS] TCP port $PORT is available"; exit 0
fi

if command -v nc >/dev/null 2>&1; then
  if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    echo "[FAIL] TCP port $PORT is already accepting connections"; exit 1
  fi
  echo "[PASS] TCP port $PORT is available"; exit 0
fi

# v3.29.8: /dev/tcp 兜底（lsof/nc 均缺——如精简 Linux 容器）
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  exec 3>&- 3<&- 2>/dev/null || true
  echo "[FAIL] TCP port $PORT is already listening"; exit 1
fi
echo "[PASS] TCP port $PORT is available (/dev/tcp probe)"; exit 0
