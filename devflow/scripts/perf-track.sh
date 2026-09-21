#!/usr/bin/env bash
# perf-track.sh · Gate 耗时监控（v3.28.10 · 来源：性能分析报告 §8）
# =============================================================================
# 用法（在被监控 Gate 脚本中）:
#   source "$(dirname "$0")/perf-track.sh"
#   perf_start "P4b"
#   ... Gate 逻辑 ...
#   perf_end "P4b"
#
# 行为: DF_PERF=1 时写 .devflow/perf-metrics.csv（phase,seconds,timestamp）；
#       DF_PERF 未设置时零开销（仅一次变量判断）。不改变 Gate 退出码。
#
# 报告: perf_report [csv]  → 按 phase 聚合 avg/n/p90
# 清零: : > .devflow/perf-metrics.csv
#
# 实测基线（2026-09-17，240 Java 文件 + 30 Vue，M系列芯片）:
#   P4b  全段 0.73-0.83s（1204 文件时 0.56-0.61s）——报告估计 60-180s 偏高 100 倍
#   P2a  收据生命周期测试全程 8-9s（含多次 p2a 调用）
#   测试套件  并行默认 155-213s（v3.27.0 起，非串行 189s）
# =============================================================================

perf_start() {
  [ "${DF_PERF:-0}" = "1" ] || return 0
  printf -v "_PERF_TS_$1" '%s' "$(date +%s)"
}

perf_end() {
  [ "${DF_PERF:-0}" = "1" ] || return 0
  local phase="$1" now dur
  now=$(eval "printf '%s' \$_PERF_TS_$phase" 2>/dev/null) || true
  [ -n "$now" ] || return 0
  dur=$(( $(date +%s) - now ))
  local dir="${STATE_DIR:-.devflow}"
  mkdir -p "$dir" 2>/dev/null
  echo "$phase,$dur,$(date +%s)" >> "$dir/perf-metrics.csv"
  unset "_PERF_TS_$phase"
}

perf_report() {
  local csv="${1:-.devflow/perf-metrics.csv}"
  [ -f "$csv" ] || { echo "[perf] no metrics file: $csv"; return 1; }
  echo "=== Gate 性能报告（${csv}）==="
  awk -F, '{sum[$1]+=$2; count[$1]++; if($2>max[$1])max[$1]=$2}
    END {for(p in sum) printf "  %-12s avg=%.1fs max=%ds n=%d\n", p, sum[p]/count[p], max[p], count[p]}' "$csv" | sort
}
