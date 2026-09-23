#!/usr/bin/env bash
# gate_json_lib.sh · Gate JSON 强制闭环共享库（13 处 Gate 侧统一接线）
#
# 背景：此前 13 处阶段的 JSON 正本只在管线（df_pipeline：校验失败不渲染 Markdown）强制，
# Gate 脚本本身不解析 JSON——可绕过管线直接产出产物。本库给每个 Gate 接上与
# s0 §1b 同口径的三步：解析正本 → fail-closed 校验 → 收据绑定（audit 重验即篡改拦截）。
#
# 调用前置（由 Gate 脚本设置）：
#   STATE_DIR        通常 .devflow
#   FEATURE          已过 devflow_feature_validate
#   GJ_SKILL         skill 根（Gate 脚本的 SCRIPT_DIR/..）
#   DEVFLOW_PY       py_runtime 解析的解释器数组
# Gate 用法：
#   . gate_json_lib.sh
#   gj_enforce <kind> [额外透传给 df_validate 的参数...]   # 失败 rc=1（消息到 stderr）
#   ...
#   收据体内插入：printf '%s' "$GJ_BIND"                  # KIND_JSON + 其 SHA256 绑定行
# 多个 kind（如 P1 三正本）顺序调用 gj_enforce 即可，绑定行自动累积。
set -u
GJ_BIND=""   # 收据绑定累积（多次 gj_enforce 追加；Gate 写收据时 printf '%s' "$GJ_BIND"）

gj_json_path() { # <kind> → .devflow/<feature>/<kind>.json
  printf '%s/%s/%s.json' "${STATE_DIR:-.devflow}" "$FEATURE" "$1"
}

gj_enforce() { # <kind> [df_validate 额外参数...] —— 缺失/校验失败 rc=1
  local kind="$1"; shift
  local p sha tag err
  p=$(gj_json_path "$kind")
  if [ ! -f "$p" ]; then
    echo "[P0] JSON 正本缺失: ${p}（kind=${kind}；须经管线产出，不得绕过）" >&2
    return 1
  fi
  if ! err=$("${DEVFLOW_PY[@]}" "$GJ_SKILL/scripts/df_validate.py" \
       --kind "$kind" --input "$p" "$@" 2>&1); then
    printf '%s\n' "$err" | sed 's/^/    /' >&2
    echo "[P0] JSON 正本校验失败: ${p}（kind=${kind}）" >&2
    return 1
  fi
  sha=$(if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$p" | awk '{print $1}'; else sha256sum "$p" | awk '{print $1}'; fi)
  tag=$(printf '%s' "$kind" | tr 'a-z-' 'A-Z_')
  GJ_BIND="${GJ_BIND}${tag}_JSON=${p}
${tag}_JSON_SHA256=${sha}
"
  echo "[OK] JSON 正本强制通过: ${kind}（${p}）"
}
