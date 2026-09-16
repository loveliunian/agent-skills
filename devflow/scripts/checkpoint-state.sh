#!/usr/bin/env bash
# =============================================================================
# checkpoint-state.sh (NEW · 修复"中断遗忘"；版本随 SKILL.md)
# =============================================================================
# 问题：上次 M-01 项目跑到 P3 (mvn compile) 卡住，用户切换话题改 skill 后，
#      没有任何机制记录"做到哪、剩什么、下次从哪接"。下次重跑时无法恢复。
#
# 解决：每次 phase / sub-phase 完成时自动 checkpoint。
#       任何中断场景（用户换话题、agent 退出、build 失败）都能从 .devflow/<feature>/state.json 恢复。
#
# 用法：
#   bash scripts/checkpoint-state.sh save <feature> <phase>   # 保存状态
#   bash scripts/checkpoint-state.sh resume <feature>         # 恢复并打印下一步
#   bash scripts/checkpoint-state.sh list <feature>           # 列出所有 checkpoint
#   bash scripts/checkpoint-state.sh orphans <feature>        # 检查"残留产物"（上次中断留下未关联的产物）
#
# 状态文件：.devflow/<feature>/state.json
#   {
#     "feature": "M-01",
#     "current_phase": "P3",
#     "current_subphase": "p3_mvn_compile",
#     "blockers": ["PaginationInnerInterceptor not found"],
#     "next_action": "Add mybatis-plus-jsqlparser to xyls-common/pom.xml",
#     "checkpoints": [
#       {"phase": "P0", "at": "2026-08-19T...", "exit_code": 0},
#       {"phase": "P3", "subphase": "p3_mvn_compile", "at": "2026-08-20T...", "exit_code": 1, "blocker": "..."}
#     ],
#     "last_updated": "2026-08-20T..."
#   }
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
STATE_DIR="${STATE_DIR:-.devflow}"

# ---------- 参数解析 ----------
ACTION="${1:-help}"
FEATURE="${2:-}"

[ -z "$FEATURE" ] && { echo "Usage: $0 {save|resume|list|orphans} <feature>"; exit 2; }
# v3.15.5: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 写穿项目外）与 grep -E 正则注入
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
devflow_feature_validate "$FEATURE" || exit 2

STATE_FILE="$STATE_DIR/$FEATURE/state.json"
mkdir -p "$(dirname "$STATE_FILE")"

# ---------- 子命令实现 ----------
case "$ACTION" in
  save)
    PHASE="${3:-unknown}"
    SUBPHASE="${4:-}"
    EXIT_CODE="${5:-0}"
    BLOCKER="${6:-}"
    NEXT_ACTION="${7:-}"

    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # v3.14.0：统一走 python 路径（heredoc 直插 JSON 在 blocker 含引号时产生非法 JSON）
    python3 - "$STATE_FILE" "$PHASE" "$SUBPHASE" "$EXIT_CODE" "$BLOCKER" "$NEXT_ACTION" "$TIMESTAMP" "$FEATURE" <<'PY'
import json, sys, os
path, phase, subphase, exit_code, blocker, next_action, ts, feature = sys.argv[1:9]
try:
    with open(path, encoding="utf-8") as f:
      data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {"feature": feature, "checkpoints": []}
data["current_phase"] = phase
data["current_subphase"] = subphase
data["blockers"] = [blocker] if blocker else []
data["next_action"] = next_action
data["checkpoints"].append({
    "phase": phase,
    "subphase": subphase,
    "at": ts,
    "exit_code": int(exit_code),
    "blocker": blocker,
})
data["last_updated"] = ts
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY
    PYRC=$?
    if [ "$PYRC" -ne 0 ] || [ ! -s "$STATE_FILE" ]; then
      echo "[CHECKPOINT] FAILED (python3 rc=$PYRC): state 未落盘——中断恢复链路拒绝假成功" >&2
      exit 1
    fi
    echo "[CHECKPOINT] saved: $FEATURE @ $PHASE/$SUBPHASE (exit=$EXIT_CODE)"
    [ -n "$BLOCKER" ] && echo "[CHECKPOINT] blocker: $BLOCKER"
    [ -n "$NEXT_ACTION" ] && echo "[CHECKPOINT] next: $NEXT_ACTION"
    ;;

  resume)
    if [ ! -f "$STATE_FILE" ]; then
      echo "[RESUME] no state file found for $FEATURE — start from P0"
      echo "  → run: bash $SKILL_ROOT/scripts/s0_acceptance_gate.sh $FEATURE"
      exit 0
    fi
    echo "[RESUME] $FEATURE:"
    python3 - "$STATE_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"[RESUME] state 文件损坏或非法 JSON: {e}")
    sys.exit(2)
print(f"  current_phase:   {data.get('current_phase', '?')}")
print(f"  current_subphase:{data.get('current_subphase', '?')}")
print(f"  blockers:        {data.get('blockers', [])}")
print(f"  next_action:     {data.get('next_action', '(none)')}")
print(f"  last_updated:    {data.get('last_updated', '?')}")
print(f"  checkpoints:     {len(data.get('checkpoints', []))} total")
n_fail = sum(1 for c in data.get('checkpoints', []) if c.get('exit_code') != 0)
if n_fail:
    print(f"    ⚠ {n_fail} failed checkpoints (blocked)")
    for c in data['checkpoints']:
        if c.get('exit_code') != 0:
            print(f"      - {c['phase']}/{c.get('subphase','')}: {c.get('blocker','?')}")
PY
    # v3.15.22: resume 分支 fail-closed（第 19 轮 P3-2）——save 分支 P1 修复的
    # 兄弟分支：死 python3 时曾空输出 + rc=0 假成功（agent 误从 P0 重启）
    RESUME_RC=$?
    if [ "$RESUME_RC" -ne 0 ]; then
      echo "[RESUME] state 读取失败（python3 rc=${RESUME_RC}）——fail-closed" >&2
      exit 1
    fi
    echo ""
    echo "  → resume from: $(STATE_FILE="$STATE_FILE" python3 -c '
import json, os
try:
    d = json.load(open(os.environ["STATE_FILE"], encoding="utf-8"))
    print(d.get("current_phase", "?") + "/" + d.get("current_subphase", ""))
except Exception as e:
    print("?/?(state 文件损坏: %s)" % e)
')"
    ;;

  list)
    [ ! -f "$STATE_FILE" ] && { echo "no state file"; exit 0; }
    python3 - "$STATE_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"[LIST] state 文件损坏或非法 JSON: {e}")
    sys.exit(2)
print(f"Checkpoints for {data['feature']}:")
for c in data.get('checkpoints', []):
    status = "✓" if c.get('exit_code') == 0 else "✗"
    print(f"  {status} {c['phase']}/{c.get('subphase',''):20s} {c['at']}  blocker={c.get('blocker','-')[:50]}")
PY
    # v3.15.22: list 分支 fail-closed（与 resume/save 同口径）
    LIST_RC=$?
    if [ "$LIST_RC" -ne 0 ]; then
      echo "[LIST] state 读取失败（python3 rc=${LIST_RC}）——fail-closed" >&2
      exit 1
    fi
    ;;

  orphans)
    # 检查"上次中断留下未关联的产物"
    echo "[ORPHANS] 检查 $FEATURE 残留产物："
    # v3.22.0: 中英双名，任一存在即视为该产物在（展示解析到的实际路径）
    source "$(cd "$(dirname "$0")" && pwd)/devflow_paths.sh"
    EXPECTED_DOCS=()
    for _pair in "clarification:requirements" "acceptance:requirements" "design:design" "tech_selection:design"; do
      _skey="${_pair%%:*}"; _dkey="${_pair##*:}"
      _found="$(df_resolve_doc "$FEATURE" "$_skey" .md "$_dkey")"
      [ -n "$_found" ] || _found="$(df_default_doc "$FEATURE" "$_skey" .md "$_dkey")"
      # 中文默认不存在时回落到英文历史名做缺失提示
      if [ ! -f "$_found" ]; then
        case "$_skey" in
          clarification) _en="docs/requirements/$FEATURE-clarification.md" ;;
          acceptance) _en="docs/requirements/$FEATURE-acceptance-criteria.md" ;;
          design) _en="docs/detailed-design/$FEATURE-design.md" ;;
          tech_selection) _en="docs/detailed-design/$FEATURE-tech-selection.md" ;;
        esac
        [ -f "$_en" ] && _found="$_en"
      fi
      EXPECTED_DOCS+=("$_found")
    done
    FOUND_ORPHANS=0
    for doc in "${EXPECTED_DOCS[@]}"; do
      if [ -f "$doc" ]; then
        echo "  ✓ $doc (exists)"
      else
        echo "  ✗ $doc (missing)"
        FOUND_ORPHANS=$((FOUND_ORPHANS + 1))
      fi
    done
    # 检查未关联的 code
    JAVA_COUNT=$(find backend -name "*.java" -type f 2>/dev/null | grep -v '/target/' | wc -l | tr -d ' ')
    TEST_COUNT=$(find backend -name "*Test.java" -type f 2>/dev/null | grep -v '/target/' | wc -l | tr -d ' ')
    VUE_COUNT=$(find frontend -name "*.vue" 2>/dev/null | wc -l | tr -d ' ')
    echo ""
    echo "  代码统计："
    echo "    Java:    $JAVA_COUNT 文件"
    echo "    Test:    $TEST_COUNT 文件"
    echo "    Vue:     $VUE_COUNT 文件"
    if [ "$JAVA_COUNT" -gt 0 ] && [ "$TEST_COUNT" -eq 0 ]; then
      echo "    ⚠ Java 已写但 0 Test → P3 中途卡住"
    fi
    if [ "$VUE_COUNT" -eq 0 ] && [ "$JAVA_COUNT" -gt 0 ]; then
      echo "    ⚠ 后端有代码但前端 0 文件 → P6c 未启动"
    fi
    ;;

  *)
    echo "Usage: $0 {save|resume|list|orphans} <feature> [phase] [subphase] [exit] [blocker] [next]"
    exit 2
    ;;
esac
exit 0
