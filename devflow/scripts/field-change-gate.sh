#!/usr/bin/env bash
# DEPRECATED：本脚本进入弃用期，下一主版本与 /field-change 一并删除。
# 兼容别名：字段变更统一走 small-change-gate.sh（SMALL-CHANGE 契约）。
# (v3.16.26 起弃用)
echo "[DEPRECATED] field-change-gate.sh 已弃用，请改用 small-change-gate.sh；下一主版本移除" >&2
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
exec bash "$SCRIPT_DIR/small-change-gate.sh" "$@"
