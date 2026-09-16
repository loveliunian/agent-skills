#!/usr/bin/env bash
# devflow_feature.sh · 版本随 SKILL.md
# 从状态机推导 feature，避免 gate 在无显式 feature 时静默写入 default 目录
#（code02/code03 教训：default 误初始化导致收据混入）。
# 用法: source 后在 RECEIPT_DIR 赋值时用 $(devflow_feature "$FEATURE")。
# v3.15.5:
#   - 移除 `set -uo pipefail`——被 source 的库不得改写调用方 shell 选项
#     （现有消费者 s0/s1/s2/s5/s6 均在 source 之后有自己的 set 行，行为不变）；
#   - 新增 devflow_feature_validate：feature 名白名单共享校验——v3.15.4 只覆盖
#     p10/s8b 两处，其余 gate 入口直接拼 $STATE_DIR/$FEATURE 路径（可写穿项目外）；
#   - devflow_feature() 自身也走白名单（s0/s1/s2/s5/s6 的 EFF_FEATURE 推导同步受保护）。

devflow_feature_validate() {
  local feature="${1:-}"
  if ! printf '%s' "$feature" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    echo "[FAIL] invalid feature name: ${feature:-<empty>}（白名单 ^[A-Za-z0-9][A-Za-z0-9._-]*\$，封堵路径穿越/正则注入）" >&2
    return 1
  fi
  return 0
}

devflow_feature() {
  local feature="${1:-}"
  local state_dir="${STATE_DIR:-.devflow}"
  if [ -n "$feature" ] && [ "$feature" != "default" ]; then
    devflow_feature_validate "$feature" || return 1
    printf '%s' "$feature"
    return 0
  fi
  if [ -d "$state_dir" ]; then
    local n
    n=$(ls "$state_dir"/*.state.json 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "$n" -eq 1 ]; then
      basename "$state_dir"/*.state.json .state.json 2>/dev/null | head -1 || true
      return 0
    fi
    if [ "$n" -gt 1 ]; then
      _list=""
      for _f in "$state_dir"/*.state.json; do _list="$_list $(basename "$_f")"; done
      echo "[WARN] 检测到多个 state 文件:$_list" >&2
    fi
  fi
  echo "[FATAL] 无法从状态机推导 feature（${feature:-<empty>}）。请显式传入 feature 参数，或确保 .devflow/ 下仅有一个工作流（当前拒绝写入 default 目录）" >&2
  return 1
}
