#!/usr/bin/env bash
# ftc-runtime.sh —— flow-test-contract 运行态根解析（唯一实现；python 侧在
# run-contract-scenarios.py:runtime_root() 镜像同一推导，勿单侧改规则）。
#
# 本目录只存**通道配置与 gate 证据库**（systems api/browser 等）——属私有配置目录，
# 不是交付物；执行产物（截图/采集/账本/结论/最终 md 报告）落
# <项目>/docs/<流程名>/自动化测试/对比测试/<run-id>/（ftc_output_root，见下），
# 与旧 FlowTrace 流水线的 <root>/.flowtrace/ 彻底分离：
#   1) env FLOWTEST_RUNTIME_DIR（整体覆盖，最高优先）
#   2) skill 布局（scripts 同级有 assets/）→ $SKILL/runtime/<项目键>-<hash8>/
#   3) 项目部署布局（install.sh）→ <root>/.flow-test-contract/runtime/
# 项目键 = basename(项目根) 消毒 + sha1(项目根绝对路径) 前 8 位——多项目同 skill 互不串扰。
# 用法：RUNTIME_DIR="$(bash ftc-runtime.sh resolve "$PROJECT_ROOT")"（$SCRIPT_DIR 由调用方传入）
#       或 source ftc-runtime.sh 后调 ftc_runtime_dir <PROJECT_ROOT> <SCRIPT_DIR>
ftc_runtime_dir() {  # $1=PROJECT_ROOT  $2=SCRIPT_DIR
  if [ -n "${FLOWTEST_RUNTIME_DIR:-}" ]; then printf '%s\n' "$FLOWTEST_RUNTIME_DIR"; return 0; fi
  local _root="$1" _here="$2" _key _hash _base
  _key="$(basename "${_root:-/nonexistent}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')"
  [ -n "$_key" ] || _key="proj"
  _hash="$(printf %s "$_root" | (md5 -q 2>/dev/null || md5sum 2>/dev/null | cut -d' ' -f1 || echo unknown) | cut -c1-8)"
  _base="$(cd "$_here/.." && pwd)"
  if [ -d "$_base/assets" ]; then
    printf '%s\n' "$_base/runtime/${_key}-${_hash}"     # skill 自持布局
  else
    printf '%s\n' "$_base/runtime"                      # 项目部署布局（.flow-test-contract/scripts）
  fi
}
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "resolve" ]; then
  ftc_runtime_dir "${2:-$PWD}" "$(cd "$(dirname "$0")" && pwd)"
fi

# ftc_output_root —— 执行产物根（第三十轮）：执行产生的截图/文档/记录/账本一律落
# 项目 docs/<流程名>/自动化测试/对比测试/（按流程名归档、多轮同放）；
# 流程名取契约路径 docs/ 下首段；FLOWTEST_OUTPUT_DIR 整体覆盖；无契约 → 空串（调用方回退 runtime）。
ftc_output_root() {  # $1=PROJECT_ROOT  $2=CONTRACT(绝对/相对)
  if [ -n "${FLOWTEST_OUTPUT_DIR:-}" ]; then printf '%s\n' "$FLOWTEST_OUTPUT_DIR"; return 0; fi
  [ -n "$2" ] || { printf '\n'; return 0; }
  local c="$2" slug=""
  case "$c" in "$1"/*) c="${c#"$1"/}";; /*) c="${c#/}";; esac
  if [ "${c#docs/}" != "$c" ]; then
    slug="${c#docs/}"; slug="${slug%%/*}"
  else
    slug="$(basename "$(dirname "$(dirname "$c")")" 2>/dev/null)"
  fi
  if [ -n "$slug" ] && [ "$slug" != "/" ] && [ "$slug" != "." ]; then
    printf '%s\n' "$1/docs/$slug/自动化测试/对比测试"
  else
    printf '\n'
  fi
}
