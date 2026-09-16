#!/usr/bin/env bash
# =============================================================================
# check-skill-usage.sh (UPGRADED · 历史升级记录见 CHANGELOG)
# =============================================================================
# 审计本项目是否"实际使用了 skill"，暴露三类系统性失败：
#   1. templates/*.md 是否被 Read 过
#   2. s0/s1/s2/s3/p3/p4/p6 gates 是否实际跑过
#   3. acceptance-criteria.md 是否独立存在（与 clarification.md 分离）
#
# 用法：bash scripts/check-skill-usage.sh
# 期望：FAIL=0
# =============================================================================
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"

if [ "$PROJECT_ROOT" = "$SKILL_ROOT" ]; then
  PROJECT_ROOT="$(cd "$SKILL_ROOT/.." && pwd -P)"
fi

cd "$PROJECT_ROOT" || exit 1

FAIL=0; PASS=0; WARN=0
echo ""
echo "=== check-skill-usage (v3.9.1) ==="
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo ""

# ---------- §1 templates 是否被 Read 过 ----------
echo "--- §1 templates/ 使用率 ---"
if [ -d "$SKILL_ROOT/templates" ]; then
  TEMPLATE_COUNT=$(find "$SKILL_ROOT/templates" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  USED_COUNT=0
  for tpl in "$SKILL_ROOT/templates"/*.md; do
    [ -f "$tpl" ] || continue
    # 检查项目 docs/ 下是否引用了模板的某个 H2 章节
    if find "$PROJECT_ROOT/docs" -name "*.md" 2>/dev/null | head -30 | xargs grep -lE "^## .*$(grep -E '^## ' "$tpl" 2>/dev/null | head -1 | sed 's/^## //' | sed 's/[0-9§].*//' | head -c 1)" 2>/dev/null | grep -q .; then
      USED_COUNT=$((USED_COUNT + 1))
    fi
  done
  echo "  模板总数: $TEMPLATE_COUNT"
  echo "  产物引用数: $USED_COUNT"
  if [ "$USED_COUNT" -lt "$TEMPLATE_COUNT" ]; then
    echo "[P0] 仅 $USED_COUNT/$TEMPLATE_COUNT 个模板被实际引用"
    FAIL=$((FAIL + 1))
  else
    echo "[PASS] $USED_COUNT/$TEMPLATE_COUNT 模板被引用"
    PASS=$((PASS + 1))
  fi
else
  echo "[WARN] templates/ not found"
  WARN=$((WARN + 1))
fi

# ---------- §2 gates 是否跑过 ----------
echo ""
echo "--- §2 gate 执行率 ---"
# v3.9.5: 收据双计 — .devflow/（运行时） + docs/**/gates/（版本管理镜像，gate 脚本自动双写）
GATE_RECEIPTS=$(find "$PROJECT_ROOT/.devflow" "$PROJECT_ROOT/docs" -name "*receipt*.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$GATE_RECEIPTS" -gt 0 ]; then
  echo "[PASS] 找到 $GATE_RECEIPTS 个 gate 收据（.devflow/ 或 docs/**/gates/ 镜像）"
  PASS=$((PASS + 1))
else
  echo "[P0] 没有 gate 收据 → 从未实际跑过任何 gate"
  FAIL=$((FAIL + 1))
fi

# ---------- §3 acceptance-criteria 是否独立 ----------
echo ""
echo "--- §3 acceptance-criteria 独立性 ---"
CLAR=$(find "$PROJECT_ROOT/docs/requirements" -name "*-clarification.md" 2>/dev/null | head -1)
CRIT=$(find "$PROJECT_ROOT/docs/requirements" -name "*-acceptance-criteria.md" 2>/dev/null | head -1)
if [ -n "$CLAR" ] && [ -n "$CRIT" ]; then
  if [ "$CLAR" != "$CRIT" ]; then
    echo "[PASS] acceptance-criteria.md 与 clarification.md 独立存在"
    PASS=$((PASS + 1))
  else
    echo "[P0] acceptance-criteria 与 clarification 是同一个文件"
    FAIL=$((FAIL + 1))
  fi
elif [ -n "$CLAR" ]; then
  echo "[P0] acceptance-criteria.md 缺失（与 clarification 合并了）"
  FAIL=$((FAIL + 1))
else
  echo "[WARN] 无 requirements 目录"
  WARN=$((WARN + 1))
fi

# ---------- §4 详设格式 ----------
echo ""
echo "--- §4 详设格式合规 ---"
DESIGN=$(find "$PROJECT_ROOT/docs/detailed-design" -name "*-design.md" 2>/dev/null | head -1)
if [ -n "$DESIGN" ]; then
  HAS_7COL=$(grep -cE '字段名.*类型.*约束.*默认值.*口径说明' "$DESIGN" 2>/dev/null || true)
  HAS_6COL_REQ=$(grep -cE '字段.*类型.*必填.*校验规则.*数据来源.*脱敏' "$DESIGN" 2>/dev/null || true)
  HAS_6COL_RES=$(grep -cE '字段.*类型.*恒出性.*取值规则.*数据来源.*脱敏' "$DESIGN" 2>/dev/null || true)
  HAS_WHEN=$(grep -cE '^WHEN[[:space:]]+' "$DESIGN" 2>/dev/null || true)
  HAS_R=$(grep -cE '^R[0-9]+\.' "$DESIGN" 2>/dev/null || true)
  if [ "$HAS_7COL" -gt 0 ] && [ "$HAS_6COL_REQ" -gt 0 ] && [ "$HAS_6COL_RES" -gt 0 ] && [ "$HAS_WHEN" -gt 0 ] && [ "$HAS_R" -gt 0 ]; then
    echo "[PASS] 详设格式合规（7列+6列+WHEN+R 编号）"
    PASS=$((PASS + 1))
  else
    echo "[P0] 详设格式不合规: 7列=$HAS_7COL 6列REQ=$HAS_6COL_REQ 6列RES=$HAS_6COL_RES WHEN=$HAS_WHEN R=$HAS_R"
    FAIL=$((FAIL + 1))
  fi
else
  echo "[WARN] 无 design.md"
  WARN=$((WARN + 1))
fi

echo ""
echo "========================================"
echo "check-skill-usage: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"

# ---------- §5 v3.9.2 中断恢复验证 ----------
echo ""
echo "--- §5 v3.9.2 中断恢复 (state.json + checkpoint) ---"
STATE_DIR="$PROJECT_ROOT/.devflow"
if [ -d "$STATE_DIR" ]; then
  STATE_COUNT=$(find "$STATE_DIR" -name "state.json" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$STATE_COUNT" -gt 0 ]; then
    # v3.15.21: python3 死亡/解析失败 fail-closed——旧版 find -exec python3 输出为空 →
    # grep -c 得 0 → 假 PASS "全部无 blocker"（第 18 轮 PoC：state 含 blocker + 死
    # python3 仍报 clean）。三重防御：'E' 解析失败标记 / 行数对账 / 空输出对账。
    BLOCKER_LINES=$(find "$STATE_DIR" -name "state.json" -exec python3 -c "import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
    print('1' if d.get('blockers') else '0')
except Exception:
    print('E')" {} \; 2>/dev/null || true)
    TOTAL=$(find "$STATE_DIR" -name "state.json" 2>/dev/null | wc -l | tr -d ' ')
    LINE_COUNT=$(printf '%s\n' "$BLOCKER_LINES" | grep -cE '^[01E]$' || true)
    HAS_ERRORS=$(printf '%s\n' "$BLOCKER_LINES" | grep -c '^E$' || true)
    HAS_BLOCKERS=$(printf '%s\n' "$BLOCKER_LINES" | grep -c '^1$' || true)
    if [ "$HAS_ERRORS" -gt 0 ]; then
      echo "[FAIL] ${HAS_ERRORS} 个 state.json 解析失败——blockers 审计 fail-closed（不判 clean）"
      FAIL=$((FAIL + 1))
    elif [ "$LINE_COUNT" -ne "$TOTAL" ]; then
      echo "[FAIL] python3 输出不完整（${LINE_COUNT}/${TOTAL}，解释器死亡或 find 失败）——fail-closed 不判 clean"
      FAIL=$((FAIL + 1))
    elif [ "$HAS_BLOCKERS" -eq 0 ]; then
      echo "[PASS] $TOTAL 个 state.json 全部无 blocker = clean"
      PASS=$((PASS + 1))
    else
      echo "[WARN] $HAS_BLOCKERS/$TOTAL state.json 有 blocker — checkpoint 机制生效但项目卡住"
      echo "       跑 'bash ~/.<tool>/skills/devflow/scripts/checkpoint-state.sh resume <feature>' 看下一步"
      WARN=$((WARN + 1))
    fi
  else
    echo "[WARN] .devflow 存在但无 state.json — 中断恢复机制未触发"
    WARN=$((WARN + 1))
  fi
else
  echo "[WARN] .devflow 不存在 — checkpoint-state.sh 从未跑过"
  WARN=$((WARN + 1))
fi

# ---------- §6 v3.9.3 build-watchdog 验证 ----------
echo ""
echo "--- §6 v3.9.3 build-watchdog ---"
BUILD_GATE=$(find "$PROJECT_ROOT/.devflow" -name "receipt.txt" -type f 2>/dev/null | grep '/P3-build/' | head -1)
if [ -n "$BUILD_GATE" ]; then
  EXIT_CODE=$(grep "^EXIT_CODE=" "$BUILD_GATE" | cut -d= -f2 | tr -d ' ')
  if [ "$EXIT_CODE" = "0" ]; then
    echo "[PASS] build-watchdog gate 收据存在且 PASS"
    PASS=$((PASS + 1))
  else
    echo "[WARN] build-watchdog gate 收据存在但 FAIL=1 — 项目卡 P3 build"
    echo "       跑 'bash ~/.<tool>/skills/devflow/scripts/build-watchdog.sh gate <feature>' 看失败项"
    WARN=$((WARN + 1))
  fi
elif [ -d "$PROJECT_ROOT/backend" ] || [ -d "$PROJECT_ROOT/frontend" ]; then
  echo "[P0] 有 backend/frontend 但 P3-build 收据缺失 — build-watchdog 没跑过"
  FAIL=$((FAIL + 1))
else
  echo "[WARN] 无 backend/frontend — build-watchdog 不适用"
  WARN=$((WARN + 1))
fi

# ---------- §7 v3.9.3 watch 模式证据 ----------
echo ""
echo "--- §7 v3.9.3 watch 模式 ---"
WATCH_RUNNING=$(pgrep -f "build-watchdog.sh watch" 2>/dev/null | wc -l | tr -d ' ')
if [ "$WATCH_RUNNING" -gt 0 ]; then
  echo "[PASS] build-watchdog watch 守护进程在跑 ($WATCH_RUNNING 个)"
  PASS=$((PASS + 1))
else
  echo "[WARN] build-watchdog watch 未运行（可选 — 写代码时才需要）"
  WARN=$((WARN + 1))
fi

# ---------- §8 templates 使用率（v3.9.1 升级版） ----------
echo ""
echo "--- §8 templates 使用率（v3.9.1 §1 升级版） ---"
TPL_DIR="$SKILL_ROOT/templates"
if [ -d "$TPL_DIR" ]; then
  TPL_COUNT=$(find "$TPL_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$TPL_COUNT" -gt 0 ]; then
    # 用 python 算 (避开 bash 中文匹配问题)；路径经环境变量传入，避免注入/转义问题
    USED=$(TPL_DIR="$TPL_DIR" PROJ_DOCS="$PROJECT_ROOT/docs" python3 - <<'PY'
import os, re
tpl_dir = os.environ["TPL_DIR"]
proj = os.environ["PROJ_DOCS"]
used = 0
total = 0
for fn in os.listdir(tpl_dir):
    if not fn.endswith(".md"):
        continue
    total += 1
    # 提取模板名关键词（去 -模板.md 后缀）
    keyword = fn.replace("-模板.md", "").replace(".md", "")
    # 在 docs/ 里找是否被引用（关键词作为 H2/H3 出现）
    for root, _, files in os.walk(proj):
        for f in files:
            if f.endswith(".md"):
                p = os.path.join(root, f)
                try:
                    content = open(p, encoding="utf-8").read()
                    if re.search(r"^#+ .*" + re.escape(keyword), content, re.MULTILINE):
                        used += 1
                        break
                except Exception:
                    pass
        else:
            continue
        break
print(used, total)
PY
)
    # v3.15.23: 输出格式对账 fail-closed——python3 死亡时 USED 空输出曾走
    # "使用率 0%" 假 WARN（第 20 轮 P3-7：解释器故障 ≠ 使用率为零，§5 同口径）
    if ! printf '%s\n' "$USED" | grep -qE '^[0-9]+[[:space:]]+[0-9]+$'; then
      echo "[FAIL] templates 使用率审计输出异常（python3 故障？输出='${USED:-空}'）——fail-closed 不判 0%"
      FAIL=$((FAIL + 1))
    else
      # v3.15.24: 正常输出才走 PASS/WARN 判定——FAIL 分支后不再打印"使用率 0%"
      # 矛盾 WARN（第 21 轮 P4-1：主信号 FAIL 后跟"仅 0% (/)"误导）
      USED_NUM=$(echo "$USED" | awk '{print $1}' || true)
      TOT_NUM=$(echo "$USED" | awk '{print $2}' || true)
      if [ "$TOT_NUM" -gt 0 ] 2>/dev/null; then
        USAGE_PCT=$((USED_NUM * 100 / TOT_NUM))
      else
        USAGE_PCT=0
      fi
      if [ "$USAGE_PCT" -ge 60 ]; then
        echo "[PASS] templates 使用率 $USAGE_PCT% ($USED_NUM/$TOT_NUM)"
        PASS=$((PASS + 1))
      else
        echo "[WARN] templates 使用率仅 $USAGE_PCT% ($USED_NUM/$TOT_NUM) — agent 没读模板就写产物"
        WARN=$((WARN + 1))
      fi
    fi
  fi
else
  echo "[WARN] 无 templates 目录"
  WARN=$((WARN + 1))
fi

echo ""
echo "========================================"
echo "check-skill-usage: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
