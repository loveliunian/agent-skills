#!/usr/bin/env bash
# devflow_profile.sh · Runtime Profile 解析与能力门禁（v3.30.0）
# =============================================================================
# PROFILE_ID 冻结于 state.scope.profile_id（devflow-state.sh init --profile=<id>，
# 须存在 references/profiles/<id>.md）。未冻结的历史项目按参考实现
# java-spring-flyway 处理（向后兼容，见 references/runtime-profile.md 实现状态节）。
#
# 消费方：p3_completion_gate / build-watchdog(gate) / p4_prd_vs_code —— 这三处
# 的 build/test/coverage/flyway/orm-mapping 命令位目前只有 java-spring-flyway
# 实现；其他 profile 在这些 Gate 上 BLOCKED(MISSING_CAPABILITY)，不得静默运行
# 错误技术栈的命令（SKILL.md 原则 13、runtime-profile.md 实现状态节）。
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
