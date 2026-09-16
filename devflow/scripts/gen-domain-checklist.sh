#!/usr/bin/env bash
# gen-domain-checklist.sh · 领域专项评审清单生成器（版本随 SKILL.md frontmatter）
# 用途：按 state 冻结的平台 + 需求/详设中的外部依赖信号，生成针对性评审问题清单，
#      供 P0b（PRD 评审）与 P2a（详设评审）作为强制证据。
# 用法：
#   gen-domain-checklist.sh <feature> --stage prd|design [--out <path>]
set -uo pipefail

FEATURE="${1:-}"
STAGE="design"
shift || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    # v3.15.9: 带值 flag 缺值前置检查——旧 `${2:-design}` 掩护了赋值，但 shift 2 失败
    # 不改位置参数（bash 语义），set -u 无 -e 吞错 → while 永真死循环（p3 v3.15.8 同型漏网）
    --stage) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --stage requires a non-flag value" >&2; exit 2; }; STAGE="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --out requires a non-flag value" >&2; exit 2; }; OUT_OVERRIDE="$2"; shift 2 ;;
    *) echo "[FAIL] unknown arg: $1"; exit 2 ;;
  esac
done
[ -n "$FEATURE" ] || { echo "Usage: $0 <feature> --stage prd|design"; exit 2; }
# v3.15.5: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 写穿项目外）与 grep -E 正则注入
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
devflow_feature_validate "$FEATURE" || exit 2
case "$STAGE" in prd|design) ;; *) echo "[FAIL] --stage 必须为 prd 或 design"; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PLAYBOOK_DIR="$SKILL_ROOT/references/playbooks"
STATE_DIR="${STATE_DIR:-.devflow}"
STATE="$STATE_DIR/${FEATURE}.state.json"

PLATFORM="pc-web"
if [ -f "$STATE" ] && command -v jq >/dev/null 2>&1; then
  PLATFORM=$(jq -r '.scope.frontend // "pc-web"' "$STATE" 2>/dev/null)
fi
case "$PLATFORM" in
  miniprogram|mini-program) PB_PLATFORM="$PLAYBOOK_DIR/playbook-miniprogram.md"; LABEL="微信小程序" ;;
  app)                      PB_PLATFORM="$PLAYBOOK_DIR/playbook-app.md";         LABEL="APP（iOS/Android）" ;;
  not-applicable)           PB_PLATFORM="";                      LABEL="无前端平台" ;;
  *)                        PB_PLATFORM="$PLAYBOOK_DIR/playbook-pcweb.md";       LABEL="PC Web" ;;
esac
[ "$PLATFORM" = "mini-program" ] && PLATFORM="miniprogram"

# 外部数据依赖检测：需求/详设中出现对接信号即触发 external-data 剧本
DEP_HIT=0
# v3.14.3: 检测范围收窄到本 feature 的文档（其他 feature 的对接描述不得误触发）
for f in "docs/requirements/${FEATURE}"*.md "docs/detailed-design/${FEATURE}"*.md; do
  [ -f "$f" ] || continue
  if grep -qE '(外部系统|第三方|对接|接口文档|数据源|依赖).{0,48}(系统|平台|接口|API|数据)|API 文档' "$f" 2>/dev/null; then
    DEP_HIT=1; break
  fi
done

if [ "$STAGE" = "prd" ]; then
  OUT="${OUT_OVERRIDE:-docs/requirements/${FEATURE}-prd-domain-checklist.md}"
else
  OUT="${OUT_OVERRIDE:-docs/review/${FEATURE}-domain-checklist.md}"
fi
mkdir -p "$(dirname "$OUT")"

{
  STAGE_UP=$(printf '%s' "$STAGE" | tr '[:lower:]' '[:upper:]')
  echo "# ${FEATURE} 领域专项评审清单（${STAGE_UP} 阶段 · 平台：${LABEL}）"
  echo ""
  echo "> 由 \`scripts/gen-domain-checklist.sh\` 自动生成于 $(date '+%F %R')。"
  echo "> **填写规则**：每项改为 \`- [x] ……（证据：<具体内容/链接/章节号>）\`；不适用写 \`- [x] N-A <理由>\`。gate 会拒绝无证据的勾选。"
  if [ "$STAGE" = "design" ]; then
    echo "> ❌ 不通过的问题必须登记为评审发现（DF-xx），进入问题闭环。"
  else
    echo "> PRD 阶段允许暂标 N-A，但 P2a 详设评审时必须重新回答。"
  fi
  echo ""
  if [ "$PLATFORM" != "not-applicable" ]; then
    echo "## 平台剧本：${LABEL}"
    echo ""
    cat "$PB_PLATFORM"
    echo ""
  fi
  if [ "$DEP_HIT" = "1" ]; then
    echo "## 外部数据依赖剧本（检测到对接信号）"
    echo ""
    cat "$PLAYBOOK_DIR/playbook-external-data.md"
  else
    echo "## 外部数据依赖剧本"
    echo ""
    echo "> 未检测到外部对接信号，本节跳过。若实际存在对接，请补充到需求文档后重新生成。"
    echo ""
  fi
} > "$OUT"

TOTAL=$(grep -cE '^- \[ \]' "$OUT" 2>/dev/null || true)
echo "[OK] 已生成领域专项清单: ${OUT}（待答项 ${TOTAL}）"
if [ "$PLATFORM" = "not-applicable" ] && [ "$DEP_HIT" = "0" ]; then
  echo "[OK] 纯后端项目无外部对接信号——清单为占位说明，gate 不要求"
  exit 0
fi
[ "${TOTAL:-0}" -gt 0 ] || { echo "[FAIL] 清单内容为空，playbook 缺失？"; exit 1; }
