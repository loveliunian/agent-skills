#!/usr/bin/env bash
# py_runtime.sh · 统一 Python 解释器解析 v3.29.3
# 用法：source scripts/py_runtime.sh 后以 "${DEVFLOW_PY[@]}" 调用、devflow_py_ok 判可用。
# 解析顺序：python3 → python（须 3.x 探测通过）→ py -3；全缺时回退字面 python3，
# 保持与历史版本一致的"command not found"失败语义（守护点走 devflow_py_ok 优雅降级）。
# 背景：Windows python.org 安装包只创建 python.exe/py.exe、无 python3 别名，
# Git Bash 下硬编码 python3 会直接找不到命令（references/windows-compatibility.md）。
if command -v python3 >/dev/null 2>&1; then
  DEVFLOW_PY=(python3)
elif command -v python >/dev/null 2>&1 \
  && python -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
  DEVFLOW_PY=(python)
elif command -v py >/dev/null 2>&1 \
  && py -3 -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
  DEVFLOW_PY=(py -3)
else
  DEVFLOW_PY=(python3)
fi
devflow_py_ok() { [ "${#DEVFLOW_PY[@]}" -gt 0 ] && command -v "${DEVFLOW_PY[0]}" >/dev/null 2>&1; }
# 子 shell（bash -c "…"）用标量形态：内层展开后按空白分词（py -3 可用）
DEVFLOW_PY_STR="${DEVFLOW_PY[*]}"
export DEVFLOW_PY_STR
