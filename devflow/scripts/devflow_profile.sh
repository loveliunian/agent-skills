#!/usr/bin/env bash
# devflow_profile.sh · Runtime Profile 解析与能力门禁（v3.31.1）
# =============================================================================
# PROFILE_ID 冻结于 state.scope.profile_id（devflow-state.sh init --profile=<id>，
# 须存在 references/profiles/<id>.md）。未冻结的历史项目按参考实现
# java-spring-flyway 处理（向后兼容，见 references/runtime-profile.md 实现状态节）。
#
# 消费方：p3_completion_gate / build-watchdog(gate) / p4_prd_vs_code。
#
# v3.31.1（审查报告-0924 中期项：Runtime Profile 真正执行化）：
#   - 新增 devflow_profile_capability_exec——按 profile JSON 的 gate_bindings 解析
#     adapter（结构化 executable/args/cwd），经 df_executor.py 安全执行（workspace
#     边界/env 白名单/timeout）；模板变量 {service}/{scope} 由调用方上下文替换。
#   - devflow_profile_require_impl 语义升级：profile JSON 有对应 adapter 即可执行
#     （经 executor，不再仅 Java）；无 adapter 才 BLOCKED（MISSING_CAPABILITY）。
#     三个消费方 gate 保持 BLOCKED 收据契约不变。
# =============================================================================


devflow_profile_of() { # <feature> → 打印 PROFILE_ID（未冻结时默认参考实现）
  local feature="$1"
  local state_file="${STATE_DIR:-.devflow}/${feature}.state.json"
  local pid=""
  if [ -f "$state_file" ] && command -v jq >/dev/null 2>&1; then
    pid=$(jq -r '.scope.profile_id // empty' "$state_file" 2>/dev/null || true)
  fi
  printf '%s' "${pid:-java-spring-flyway}"
}

devflow_profile_require_impl() { # <feature> <gate-name> → 0=可运行；1=BLOCKED
  local feature="$1" gate="$2" pid
  pid=$(devflow_profile_of "$feature")
  [ "$pid" = "java-spring-flyway" ] && return 0
  echo "[BLOCKED] MISSING_CAPABILITY=build,test,coverage,flyway,orm-mapping (PROFILE_ID=$pid, gate=$gate)"
  echo "  当前仅 PROFILE_ID=java-spring-flyway 提供该 Gate 的命令位实现"
  echo "  （见 references/runtime-profile.md 实现状态节）；其他技术栈项目在此阶段"
  echo "  BLOCKED，不得静默运行错误技术栈的命令。"
  return 1
}


# v3.31.1: 能力执行化——按 gate_bindings 解析 adapter 并经 df_executor 安全执行。
# 输出：JSON 回执（rc/duration_ms/spec）到 stdout 的尾行由调用方按需解析；
# 返回值=命令 rc（127=命令缺失/解析失败，2=spec 非法，124=超时）。
devflow_profile_capability_exec() { # <feature> <binding-key> <service> <scope> [timeout]
  local feature="$1" key="$2" service="${3:-}" scope="${4:-}" to="${5:-}"
  local pid json bpath adapter
  pid=$(devflow_profile_of "$feature")
  json="$STATE_DIR/${feature}/runtime-profile.json"
  [ -f "$json" ] || json="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/runtime-profiles/${pid}.json"
  [ -f "$json" ] || { echo "[P0] profile JSON 缺失: $json" >&2; return 127; }
  bpath=$(jq -r --arg k "$key" '.gate_bindings[$k] // empty' "$json" 2>/dev/null)
  [ -n "$bpath" ] || { echo "[P0] gate_bindings 无 ${key}（profile=${pid}）" >&2; return 127; }
  adapter=$(jq -r ".$bpath // empty" "$json" 2>/dev/null)
  [ -n "$adapter" ] || { echo "[P0] adapter 为空: ${bpath}（profile=${pid}）" >&2; return 127; }
  # 模板变量替换（service/scope 由调用方上下文提供）
  adapter=${adapter//\{service\}/$service}
  adapter=${adapter//\{scope\}/$scope}
  local args=()
  [ -n "$to" ] && args+=(--timeout "$to")
  "${DEVFLOW_PY[@]}" "$(dirname "${BASH_SOURCE[0]}")/df_executor.py" \
    --profile-verify "$pid" --capability "$key" --workspace "$PWD" "${args[@]}" \
    || return $?
}

# 升级版语义：有 adapter → 可执行（经 executor）；无 → BLOCKED。
# gate 名→binding-key 映射（对齐 profile JSON 的 gate_bindings 键）。
devflow_profile_gate_key() { # <gate-name> → binding-key（无映射输出空）
  case "$1" in
    P3-build)      echo "P3-build" ;;
    p3_completion) echo "P3-completion" ;;
    P4b)           echo "test" ;;   # P4b 消费 test 能力（PRD-vs-Code 需跑测试证据）
    *)             echo "" ;;
  esac
}

devflow_profile_require_impl_v2() { # <feature> <gate-name> <service> → 0=有 adapter 可执行
  local feature="$1" gate="$2" service="${3:-}" key
  key=$(devflow_profile_gate_key "$gate")
  local pid json bpath
  pid=$(devflow_profile_of "$feature")
  json="$STATE_DIR/${feature}/runtime-profile.json"
  [ -f "$json" ] || json="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/runtime-profiles/${pid}.json"
  if [ "$key" = "test" ]; then
    bpath=$(jq -r '.gate_bindings["P3-completion"][0] // empty' "$json" 2>/dev/null)
  else
    bpath=$(jq -r --arg k "$key" '.gate_bindings[$k] // empty' "$json" 2>/dev/null)
  fi
  # gate_bindings 值是 "backend.build_adapter" 形态——jq 路径须前导点（.backend.build_adapter）
  if [ -n "$bpath" ] && jq -e ".$bpath // empty" "$json" >/dev/null 2>&1; then
    return 0   # 有 adapter 声明 → 能力存在（执行交给 devflow_profile_capability_exec）
  fi
  echo "[BLOCKED] MISSING_CAPABILITY (PROFILE_ID=$pid, gate=$gate)——profile JSON 无 gate_bindings.$key"
  return 1
}
