#!/usr/bin/env bash
# devflow-finalize.sh — 终段收据链一次通过编排（v3.30.11，FB-20260921-003）
# =============================================================================
# 背景（m01-base 实测）：P3b/P4/P6-final 的收据绑定证据文件会被后续任何测试运行
# 改写——收据 SHA 绑定断裂 → P7/P8 的 receipt chain audit 连锁失败 → 被迫手工
# 按序刷新 5 个 Gate（实测浪费 ~40min）。本命令把「正确顺序 + 期间禁止扰动」
# 固化为一个复合动作。
#
# 用法:
#   bash scripts/devflow-finalize.sh <feature> [--service <svc>]
#        [--skip-p3b] [--skip-p4] [--skip-p8]
#
# 顺序（依赖驱动，不可调换）:
#   P3b(代码审查) → P4(PRD验证) → P6-final(终验,重执行五类命令) → P7(部署记录) → P8(监控)
#
# 前置（调用方自行保证，脚本只做探测）:
#   1. 后端服务已运行（STAGING/LOAD 探测目标，默认 http://localhost:8080）
#   2. 前端 dev server 由 playwright webServer 自起（CLIENT）
#   3. ★ 网格纪律：本命令执行期间，禁止并行运行任何 mvn test / npm test /
#      playwright / 触碰 docs/测试 与 target/surefire-reports 的动作——
#      任何证据文件变更都会打断 P6-final 刚建立的 SHA 绑定。
#
# 若链后仍需跑测试：测试完毕后【重跑本命令】刷新整条链，而非只补跑单个 Gate。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
FEATURE="${1:-}"
shift || true
SERVICE="m01-base-service"
SKIP_P3B=0; SKIP_P4=0; SKIP_P8=0
BASE_URL="${M01_BASE_URL:-http://localhost:8080}"
while [ $# -gt 0 ]; do
  case "$1" in
    --service) SERVICE="${2:?}"; shift 2 ;;
    --skip-p3b) SKIP_P3B=1; shift ;;
    --skip-p4) SKIP_P4=1; shift ;;
    --skip-p8) SKIP_P8=1; shift ;;
    --base-url) BASE_URL="${2:?}"; shift 2 ;;
    *) echo "[finalize] 未知参数: $1" >&2; exit 2 ;;
  esac
done
[ -n "$FEATURE" ] || { echo "用法: $0 <feature> [--service <svc>] [--skip-p3b|--skip-p4|--skip-p8]"; exit 2; }
STATE=".devflow/$FEATURE.state.json"
[ -f "$STATE" ] || { echo "[finalize][P0] state 不存在: $STATE"; exit 2; }

echo "[finalize] feature=$FEATURE service=$SERVICE"
echo "[finalize] ⚠ 链式执行期间禁止并行运行任何测试或触碰证据文件"

run_gate() { # <name> <cmd...>
  local name="$1"; shift
  echo ""
  echo "[finalize] ▶ $name"
  if "$@"; then
    echo "[finalize] ✓ $name"
  else
    local rc=$?
    echo "[finalize][P0] $name 失败 (exit=$rc)——链停止；修复后【重跑本命令】（勿只补跑单个 Gate，避免链上其余绑定再次漂移）" >&2
    exit "$rc"
  fi
}

# 前置探测：后端容器（P6-final STAGING / LOAD 目标）
HEALTH=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "${BASE_URL}/api/actuator/health" 2>/dev/null || echo 000)
case "$HEALTH" in
  2[0-9][0-9]) echo "[finalize] 后端容器: $HEALTH ✓" ;;
  *) echo "[finalize][P0] 后端未运行（${BASE_URL} health=${HEALTH}）——P6-final STAGING/LOAD 需要真实容器；先启动后端再执行本命令" >&2; exit 2 ;;
esac

# 顺序 1/4: P3b 代码审查（刷新 findings 收据绑定）
if [ "$SKIP_P3B" -eq 0 ]; then
  run_gate "P3b 代码审查" bash "$SCRIPT_DIR/p3b_code_review_gate.sh" "$FEATURE"
else
  echo "[finalize] --skip-p3b：保留既有 P3b 收据（调用方须保证其绑定未漂移）"
fi

# 顺序 2/4: P4 PRD 验证
if [ "$SKIP_P4" -eq 0 ]; then
  run_gate "P4 PRD 验证" bash "$SCRIPT_DIR/p4_validation_gate.sh" "$FEATURE"
else
  echo "[finalize] --skip-p4：保留既有 P4 收据"
fi

# 顺序 3/4: P6-final 终验（内部实执五类命令并重建证据绑定）
run_gate "P6-final 终验" bash "$SCRIPT_DIR/s6_final_verification_gate.sh" "$FEATURE"

# 顺序 4/5: P7 部署记录（audit 依赖 P6-final 新绑定）
run_gate "P7 部署记录" bash "$SCRIPT_DIR/artifact_gate.sh" P7 "$FEATURE"

# 顺序 5/5: P8 监控配置
if [ "$SKIP_P8" -eq 0 ]; then
  run_gate "P8 监控配置" bash "$SCRIPT_DIR/artifact_gate.sh" P8 "$FEATURE"
else
  echo "[finalize] --skip-p8：跳过（P8 未完成时不阻塞链）"
fi

echo ""
echo "[finalize] ✅ 终段收据链全部通过且绑定一致（P3b→P4→P6-final→P7→P8）"
echo "[finalize] 后续如需跑测试：跑完后【重跑本命令】刷新整条链。"
