#!/usr/bin/env bash
# design_parse_lib.sh · 详设正文解析（v3.31.2）
# 背景：结构化项目的详设由 df_render 确定性渲染——接口概览在 api-index 块
#（详细定义|方法|路径|…），表索引在 table-index 块（锚点|表名|字段数）；
# 旧版手写文档仍须兼容：① 接口=方法首列概览表；② 表=正文 CREATE TABLE 字面量。
# 本库由 p4_prd_vs_code.sh 与 p3_completion_gate.sh 共用，避免两处解析口径漂移。
# 用法：source scripts/design_parse_lib.sh
# 注意：调用方 set -u 时函数内部不得引用未定义变量；两个函数总是返回 0。

design_apis_from_doc() { # <design.md> → METHOD|path（每行一项，去重排序）
  awk -F'|' '
    /^\|/ {
      if ($0 ~ /^[|][[:space:]]*[-:]+[[:space:]]*\|/) next
      m1=$2; p2=$3; m2=$3; p3=$4
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", m1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", p2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", m2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", p3)
      re="^(GET|POST|PUT|DELETE|PATCH|OPTIONS|HEAD)(/(GET|POST|PUT|DELETE|PATCH|OPTIONS|HEAD))*$"
      if (m1 ~ re && p2 ~ /^\//) print m1 "|" p2
      else if (m2 ~ re && p3 ~ /^\//) print m2 "|" p3
    }' "$1" 2>/dev/null | sort -u || true
}

design_tables_from_doc() { # <design.md> → 表名（小写，每行一项，去重排序）
  local out
  out=$(awk -F'|' '
    /df:begin:table-index/ { inb=1; next }
    /df:end:table-index/   { inb=0; next }
    inb && /^\|/ {
      name=$3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && name != "表名") print tolower(name)
    }' "$1" 2>/dev/null | sort -u || true)
  if [ -z "$out" ]; then
    out=$(grep -hiE 'CREATE TABLE[[:space:]]+(IF NOT EXISTS[[:space:]]+)?[`"]?([a-z_][a-z0-9_]*)[`"]?' "$1" 2>/dev/null \
      | sed -E 's/.*CREATE TABLE[[:space:]]+(IF NOT EXISTS[[:space:]]+)?[`"]?([a-z_][a-z0-9_]*)[`"]?.*/\2/' \
      | tr '[:upper:]' '[:lower:]' | sort -u || true)
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}
