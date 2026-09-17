#!/usr/bin/env bash
# run-tests.sh · 完整测试套件编排（v3.20.3 可观测性改造）
#   - 分组计时：每组输出开始/结束/耗时；套件级汇总表
#   - 独立日志：tests/logs/<ts>-<pid>/<group>.log + 失败组尾部回显
#   - 超时保护：每组独立超时（默认 900s，RUN_TESTS_TIMEOUT 覆盖；rc=124 表示超时）
#   - 树哈希首尾锚定：套件启动和收尾各真实计算一次，确保运行期间发布树未漂移。
#   - 可选并行：默认并行（各组独立 mktemp 工作区）；RUN_TESTS_PARALLEL=0 回到串行
set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
# v3.26.0: 并行默认开启——串行全量 ~45min 不可接受；并行实测（2026-09-17 全绿运行）
# 各组独立 mktemp 工作区无共享状态。需要串行调试时 RUN_TESTS_PARALLEL=0。
PARALLEL="${RUN_TESTS_PARALLEL:-1}"
PER_GROUP_TIMEOUT="${RUN_TESTS_TIMEOUT:-900}"

SUITES=(
  "test-contracts.sh:契约面"
  "test-trigger-eval.sh:触发评测语料"
  "test-state.sh:state 机"
  "test-client-platforms.sh:客户端平台"
  "test-phase-gates.sh:阶段门控"
  "test-v3140-regressions.sh:v3.14.0 回归"
  "test-chinese-paths.sh:中文产物路径"
  "test-maintainability.sh:可维护性"
  "test-small-change.sh:小改动"
  "test-release-hardening.sh:发布硬化"
  "test-structured-artifacts.sh:结构化产物"
  "test-structured-artifacts-phase-docs.sh:结构化产物-全阶段(v3.25.0)"
  "test-design-contract-hardening.sh:详设契约硬化（v3.24.0）"
  "test-design-package-modes.sh:设计包与三模式（v3.24.0）"
  "test-review-receipt-lifecycle.sh:收据生命周期与完整 P2a 正向（v3.24.0）"
  "test-prompt-refs.sh:提示词引用完整性（v3.24.0）"
  "test-evidence-hardening.sh:证据硬化-核心"
  "test-evidence-hardening-rounds.sh:证据硬化-行为钉轮次"
  "test-report-regressions.sh:报告回归"
  "test-p6-hardening.sh:P6 硬化"
  "test-version-hardening.sh:历史版本硬化（v3.20.3/v3.21.1/v3.21.2）"
  "test-dev-hardening.sh:开发面硬化（v3.26.0）"
  "test-release.sh:发布审计"
)

LOG_ROOT="$TEST_DIR/logs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$LOG_ROOT" || { echo "[FAIL] 无法创建日志目录: $LOG_ROOT"; exit 2; }

# 启动时真实计算树哈希一次（首尾锚定的起点）
echo "[run-tests] 计算发布树锚点 hash（启动锚定）..."
TREE_ANCHOR=$(bash "$SKILL_ROOT/scripts/gate-skill-tree.sh") || {
  echo "[FAIL] 树哈希锚点计算失败"; exit 1
}
START_ALL=$(date +%s)

run_group() {
  local script="$1" label="$2"
  local log="$LOG_ROOT/${script%.sh}.log"
  local t0 t1 rc waited pid timeout_hit=0
  t0=$(date +%s)
  if [ "${QUIET:-0}" != "1" ]; then
    echo "[GROUP ▶] $label ($script) 开始 $(date +%H:%M:%S)"
  fi
  bash "$TEST_DIR/$script" >"$log" 2>&1 &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$PER_GROUP_TIMEOUT" ]; then
      timeout_hit=1
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
  rc=$?
  t1=$(date +%s)
  [ "$timeout_hit" -eq 1 ] && rc=124
  printf '%s|%s|%s|%s\n' "$script" "$label" "$rc" "$((t1 - t0))" >> "$LOG_ROOT/summary.tsv"
  if [ "${QUIET:-0}" != "1" ]; then
    if [ "$rc" -eq 0 ]; then
      echo "[GROUP ✓] $label 通过（$((t1 - t0))s）"
    elif [ "$rc" -eq 124 ]; then
      echo "[GROUP ⏱] $label 超时（>${PER_GROUP_TIMEOUT}s）——日志: $log"
    else
      echo "[GROUP ✗] $label 失败 rc=${rc} ($((t1 - t0))s) 日志: $log"
      echo "───────── 失败输出尾部 ─────────"
      tail -15 "$log"
      echo "────────────────────────────────"
    fi
  fi
  return "$rc"
}

if [ "$PARALLEL" = "1" ]; then
  echo "[run-tests] 并行模式（RUN_TESTS_PARALLEL=1）：各组并发，独立 mktemp 工作区"
  pids=()
  for entry in "${SUITES[@]}"; do
    script="${entry%%:*}"; label="${entry#*:}"
    run_group "$script" "$label" & pids+=("$!")
    sleep 0.2
  done
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
else
  for entry in "${SUITES[@]}"; do
    script="${entry%%:*}"; label="${entry#*:}"
    run_group "$script" "$label" || true
  done
fi

END_ALL=$(date +%s)
# 收尾真实计算锚定（防套件运行期间发布树漂移被缓存掩盖）
FINAL_TREE=$(bash "$SKILL_ROOT/scripts/gate-skill-tree.sh") || FINAL_TREE="HASH-FAILED"
TREE_STABLE="OK"
if [ "$FINAL_TREE" != "$TREE_ANCHOR" ]; then
  TREE_STABLE="DRIFTED"
fi

echo ""
echo "═══════════════ 测试套件汇总 ═══════════════"
printf '%-38s %-5s %-7s %s\n' "GROUP" "RC" "SECS" "LABEL"
TOTAL_FAIL=0
FAILED_SUITES=""
while IFS='|' read -r script label rc secs; do
  printf '%-38s %-5s %-7s %s\n' "$script" "$rc" "${secs}s" "$label"
  if [ "$rc" != "0" ]; then
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_SUITES="$FAILED_SUITES $label"
  fi
done < "$LOG_ROOT/summary.tsv"
DUR=$((END_ALL - START_ALL))
echo "═══════════════════════════════════════════"
echo "总计: $TOTAL_FAIL 组失败 / ${#SUITES[@]} 组 · 耗时 ${DUR}s · 树锚点: $TREE_STABLE"
echo "日志目录: $LOG_ROOT"

if [ "$TOTAL_FAIL" -gt 0 ]; then
  echo "失败组:$FAILED_SUITES"
  exit 1
fi
if [ "$TREE_STABLE" != "OK" ]; then
  echo "[FAIL] 套件运行期间发布树漂移（首尾锚点不一致）——结果不可信"
  exit 1
fi
exit 0
