#!/usr/bin/env bash
# =============================================================================
# P2a 详细设计评审 Gate 
# =============================================================================
# 功能：
#   1. 评审报告存在性检查
#   2. 5 角色（架构/后端/前端/测试开发/DBA）全部有评审记录   ← v3.9.7 加 DBA
#   3. 所有角色结论 = ✅
#   4. 遗留问题 = 0
#   5. 需求追溯（acceptance-traceability）100% 覆盖 P0 验收点
#   6. P2 设计覆盖率 = 100% (调用 s2_design_coverage_gate.sh)
#   7. 无 TODO/占位符
#   8. 详设设计质量四要素（v3.9.7）：
#      组件复用 / 公共抽取 / 规范遵循 / 设计决策(DDR) 必须显性存在于详设
#   9. 评审深度契约（v3.14.0，规范见 concepts/review-depth-methodology.md）：
#      DF 按实际发现；每角色必须有 DF 或 ZERO-DF 核查证据，五字段非空、文档位置 §x.y；
#      AW 对抗走查 ≥3 条且每条以有效"结果:"收尾；六类探针执行记录齐全；
#      浅层信号（已阅/LGTM/无明显问题）直接 FAIL；SF>DF 仅 WARN
# =============================================================================
# v3.21.0: §1b/§2 角色行提取 awk 修复——gsub 直接作用于 $2 会以 OFS 重建 $0
#   （BSD awk：字段被修改即重排 $0，管道分隔符丢失），下游按 -F'|' 重拆恒为空，
#   导致真实带空格表格行必出假 P0（session ''/row incomplete）。改为局部变量
#   role_cell 修剪后输出原始行（治理服务 detailed-design-v2 复盘实证）。
# =============================================================================
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# ---------- 全局计数 ----------
FAIL=0; PASS=0; WARN=0
p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

# ---------- 参数解析 ----------
FEATURE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip=P2) SKIP_P2=1; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) [ -z "$FEATURE" ] && FEATURE="$1"; shift ;;
  esac
done

[ -z "$FEATURE" ] && { echo "Usage: $0 <feature> [--skip=P2]"; exit 2; }
# v3.15.5: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 写穿项目外）与 grep -E 正则注入
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# v3.22.0: 文档层中文化（中文优先、英文回退）
source "$(cd "$(dirname "$0")" && pwd)/devflow_paths.sh"
devflow_feature_validate "$FEATURE" || exit 2
source "$(cd "$(dirname "$0")" && pwd)/perf-track.sh"
perf_start "P2a"

DESIGN_PATH="$(df_resolve_doc "$FEATURE" design .md design)"
[ -n "$DESIGN_PATH" ] || DESIGN_PATH="docs/detailed-design/${FEATURE}-design.md"
REVIEW_PATH="$(df_resolve_doc "$FEATURE" design_review_report .md review)"
[ -n "$REVIEW_PATH" ] || REVIEW_PATH="docs/review/${FEATURE}-design-review-report.md"
CRITERIA_PATH="$(df_resolve_doc "$FEATURE" acceptance .md requirements)"
[ -n "$CRITERIA_PATH" ] || CRITERIA_PATH="docs/requirements/${FEATURE}-acceptance-criteria.md"

# ---------- §0 基础存在性 ----------
echo ""
echo "=== §0 基础产物存在性 ==="
[ -f "$DESIGN_PATH" ] && pass "design exists: $DESIGN_PATH" || { p0 "design missing: $DESIGN_PATH"; exit 1; }
[ -f "$REVIEW_PATH" ] && pass "review report exists: $REVIEW_PATH" || p0 "review report missing"
[ -f "$CRITERIA_PATH" ] && pass "acceptance criteria exists: $CRITERIA_PATH" || { p0 "acceptance missing"; exit 1; }

if [ "$FAIL" -gt 0 ]; then
  echo ""; echo "BLOCKED: 基础产物缺失"; exit 1
fi

# ---------- §1 评审报告非空 ----------
echo ""
echo "=== §1 评审报告内容检查 ==="
LINES=$(wc -l < "$REVIEW_PATH" 2>/dev/null || true)
if [ "$LINES" -gt 30 ]; then
  pass "review report non-empty: $LINES lines"
else
  p0 "review report too short: $LINES lines (expected > 30)"
fi

# ---------- §1b 独立评审收据（v3.16.26：验证编排器收据，不信任报告自报 ID） ----------
echo ""
echo "=== §1b 独立评审收据 ==="
AUTHOR_ID=$(sed -n 's/^|[[:space:]]*AUTHOR_ID[[:space:]]*|[[:space:]]*\([^|]*\)[[:space:]]*|.*/\1/p; s/^AUTHOR_ID=//p' "$REVIEW_PATH" | head -1 | sed 's/[[:space:]]//g')
RUN_ID=$(sed -n 's/^|[[:space:]]*REVIEW_RUN_ID[[:space:]]*|[[:space:]]*\([^|]*\)[[:space:]]*|.*/\1/p; s/^REVIEW_RUN_ID=//p; s/^REVIEW_SESSION_ID=//p' "$REVIEW_PATH" | head -1 | sed 's/[[:space:]]//g')
[ -n "$AUTHOR_ID" ] && pass "AUTHOR_ID present in report" || p0 "AUTHOR_ID missing in report"
[ -n "$RUN_ID" ] && pass "REVIEW_SESSION_ID present in report" || p0 "REVIEW_SESSION_ID missing in report"

# 编排器收据：create 于 spawn 各评审 Agent 时（含 AUTHOR），verify 于 Gate 执行。
# 收据携带 input_artifact_sha / output_report_sha / started_at / completed_at，
# Gate 据此验证报告未被收据后改写、评审者 != 作者、六角色收据齐全。
REVIEW_SESSION_ID="${RUN_ID}"
if [ -n "$REVIEW_SESSION_ID" ]; then
  RR_OUT=$(mktemp -t p2a-receipt.XXXXXX)
  if bash "$SCRIPT_DIR/review-receipt.sh" verify --feature "$FEATURE" --session-id "$REVIEW_SESSION_ID" \
      --input "$DESIGN_PATH" --output "$REVIEW_PATH" > "$RR_OUT" 2>&1; then
    pass "independent review receipts verified (session=$REVIEW_SESSION_ID)"
    # 报告独立性表的 REVIEW_SESSION_ID 必须等于收据 session，防"报告一套、收据一套"
    for role in "架构师" "后端专家" "前端专家" "测试开发" "DBA"; do
      row=$(awk -F'|' -v role="$role" 'NF >= 6 {role_cell=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", role_cell); if (role_cell == role) {print; exit}}' "$REVIEW_PATH" 2>/dev/null || true)
      rep_session=$(printf '%s\n' "$row" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4}')
      [ "$rep_session" = "$REVIEW_SESSION_ID" ] || p0 "${role} report session '${rep_session:-empty}' != receipt session '${REVIEW_SESSION_ID}'"
    done
  else
    while IFS= read -r line; do p0 "$line"; done < "$RR_OUT"
    p0 "independent review receipts invalid/missing — 编排器必须在 spawn 返回 agent_id 后 begin、产物落盘后 complete（review-receipt.sh 两阶段，见 phases/02a）"
  fi
  rm -f "$RR_OUT"
else
  p0 "REVIEW_SESSION_ID missing — 无法关联独立评审收据"
fi

# ---------- §2 5 角色均有评审（v3.9.7：+DBA） ----------
echo ""
echo "=== §2 5 角色均有评审 ==="
ROLES=("架构师" "后端专家" "前端专家" "测试开发" "DBA")
for role_pattern in "${ROLES[@]}"; do
  if grep -qE "^\\|[[:space:]]*${role_pattern}[[:space:]]*\\|" "$REVIEW_PATH" 2>/dev/null; then
    pass "role present: $role_pattern"
  else
    p0 "role missing in review: $role_pattern"
  fi
done

REVIEWER_IDS=""
SESSION_IDS=""
for role in "${ROLES[@]}"; do
  # v3.24.0(A08)：与 §1b 同款修复——gsub 直接作用于 $2 会以 OFS(空格)重建 $0，
  # print 输出空格分隔行，下游按 -F'|' 重拆恒得空字段（真实评审表被误拒实证）。
  # 改用局部变量 role_cell 修剪比对，print 输出原始行。
  row=$(awk -F'|' -v role="$role" 'NF >= 6 {role_cell=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", role_cell); if (role_cell == role) {print; exit}}' "$REVIEW_PATH" 2>/dev/null || true)
  reviewer=$(printf '%s\n' "$row" | awk -F'|' '{reviewer_cell=$3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", reviewer_cell); print reviewer_cell}')
  session=$(printf '%s\n' "$row" | awk -F'|' '{session_cell=$4; gsub(/^[[:space:]]+|[[:space:]]+$/, "", session_cell); print session_cell}')
  conclusion=$(printf '%s\n' "$row" | awk -F'|' '{concl_cell=$5; gsub(/^[[:space:]]+|[[:space:]]+$/, "", concl_cell); print concl_cell}')
  [ -n "$reviewer" ] && [ -n "$session" ] && [ -n "$conclusion" ] || p0 "${role} independence row incomplete"
  [ "$reviewer" != "$AUTHOR_ID" ] || p0 "${role} reviewer equals AUTHOR_ID"
  printf '%s\n' "$conclusion" | grep -qE '✅|通过' || p0 "${role} has no explicit PASS conclusion"
  REVIEWER_IDS="${REVIEWER_IDS}${reviewer}\n"
  SESSION_IDS="${SESSION_IDS}${session}\n"
done
if [ "$(printf '%b' "$REVIEWER_IDS" | sed '/^$/d' | sort | uniq -d | wc -l | tr -d ' ')" -gt 0 ]; then p0 "duplicate REVIEWER_ID"; fi
# LOCAL-PATCH(xingyun-platform 2026-09-13, 经用户自主决策授权): v3.16.26 §1b 已强制
# 5 角色行 session == 报告头 REVIEW_SESSION_ID（单会话多收据模型，review-receipt verify 按
# 单 session 校验 AUTHOR+5 角色收据），与本处旧版"行间互异"检查数学互斥。
# 对齐为非空+行数校验；席位独立性由收据 agent_id 唯一性与 verify 保证。
SESSION_ROWS=$(printf '%b' "$SESSION_IDS" | sed '/^$/d' | grep -c . || true)
if [ "$SESSION_ROWS" -ne 5 ]; then p0 "REVIEW_SESSION_ID rows = $SESSION_ROWS (expected 5)"; fi

# ---------- §2b 详设设计质量四要素（v3.9.7 NEW） ----------
echo ""
echo "=== §2b 详设设计质量四要素 ==="
# 用户的四项要求显性落进详设：组件复用 / 公共抽取 / 规范遵循 / 设计决策(DDR)
DQ_CHECKS=(
  "组件复用|成熟组件|复用组件|不重复造轮|拿来主义:组件复用（有成熟组件禁止自研）"
  "公共组件|公共服务|公共抽取|抽取登记:公共抽取（≥2 消费方的能力必须抽取登记）"
  "规范遵循|阿里巴巴|开发手册|命名规范|开发规范|注释规范:规范遵循（默认阿里 Java 开发手册）"
  "设计决策记录|设计决策|设计依据|备选方案:设计决策 DDR（非平凡决策必须写理由）"
)
for entry in "${DQ_CHECKS[@]}"; do
  pattern="${entry%%:*}"
  label="${entry#*:}"
  if grep -qE "$pattern" "$DESIGN_PATH" 2>/dev/null; then
    pass "design has: ${label}"
  else
    p0 "design missing: ${label} — 详设须显性包含该章节/内容"
  fi
done

# ---------- §3 所有角色结论 = ✅ ----------
echo ""
echo "=== §3 所有角色结论 = ✅ ==="
# v3.16.25: 仅接受独立性收据表中的五个唯一角色结论，不接受全文宽泛 PASS 凑数。
ROLE='架构师|后端专家|前端专家|测试开发|DBA'
APPROVE_COUNT=$(grep -cE "^\| *($ROLE) *\|.*\| *(✅|通过) *\|" "$REVIEW_PATH" 2>/dev/null || true)
REJECT_COUNT=$(grep -cE "^\| *($ROLE) *\|.*\| *(❌|驳回) *\|" "$REVIEW_PATH" 2>/dev/null || true)
if [ "$APPROVE_COUNT" -eq 5 ]; then
  pass "all five canonical roles approved"
else
  p0 "canonical role approvals != 5 (actual: $APPROVE_COUNT)"
fi
if [ "$REJECT_COUNT" -eq 0 ]; then
  pass "no rejection"
else
  p0 "rejections found: $REJECT_COUNT"
fi

# ---------- §3f 领域专项评审清单（v3.14.1：按平台/外部依赖生成针对性问题） ----------
echo ""
echo "=== §3f 领域专项评审清单 ==="
DC="$(df_resolve_doc "$FEATURE" design_domain_checklist .md review)"
[ -n "$DC" ] || DC="docs/review/${FEATURE}-domain-checklist.md"
DC_PLATFORM="pc-web"
DC_STATE="${STATE_DIR:-.devflow}/${FEATURE}.state.json"
if [ -f "$DC_STATE" ] && command -v jq >/dev/null 2>&1; then
  DC_PLATFORM=$(jq -r '.scope.frontend // "pc-web"' "$DC_STATE" 2>/dev/null)
fi
DC_DEP=0
# v3.22.0: 扫描目录双语（中文存在优先，历史英文一并扫）
DC_SCAN_DIRS=()
for _d in "docs/需求" "docs/requirements" "docs/详细设计" "docs/detailed-design"; do [ -d "$_d" ] && DC_SCAN_DIRS+=("$_d"); done
for f in $(for _d in "${DC_SCAN_DIRS[@]}"; do printf '%s/%s*.md\n' "$_d" "$FEATURE"; done); do
  [ -f "$f" ] || continue
  if grep -qE '(外部系统|第三方|对接|接口文档|数据源|依赖).{0,48}(系统|平台|接口|API|数据)|API 文档' "$f" 2>/dev/null; then
    DC_DEP=1; break
  fi
done
if [ "$DC_PLATFORM" = "not-applicable" ] && [ "$DC_DEP" = "0" ]; then
  pass "domain checklist not applicable (backend-only scope)"
else
  if [ ! -f "$DC" ]; then
    p0 "领域专项评审清单缺失: $DC —— 先运行 gen-domain-checklist.sh ${FEATURE} --stage design，逐项作答后重评"
  else
    # v3.14.3: 逐行分类——[x] 必须附"（证据：…）"或 N-A+理由，否则视为未答（防一键全勾走过场）
    DC_OPEN=$(awk '/^- \[ \]/{o++} END{print o+0}' "$DC")
    DC_DONE=$(awk '/^- \[[xX]\]/{d++} END{print d+0}' "$DC")
    # v3.14.3: 用 index() 字节子串判定——LC_ALL=C 下多字节否定字符类不可靠
        DC_BADFMT=$(awk '/^- \[[xX]\]/{{ ev=index($0,"（证据：")
      if (ev>0) { tail=substr($0,ev+15); gsub(/[[:space:]）]/,"",tail); if (length(tail)>0) e++; else b++ }
      else if (index($0,"N-A")>0) { na=substr($0,index($0,"N-A")+3); gsub(/[[:space:]）、，。]/,"",na); if (length(na)>=2) e++; else b++ }
      else b++ }} END{print b+0}' "$DC")
    if [ "${DC_OPEN:-0}" -gt 0 ]; then
      p0 "领域专项清单存在未勾选项 ${DC_OPEN}"
    elif [ "${DC_DONE:-0}" -lt 1 ]; then
      p0 "领域专项清单为空——重新运行 gen-domain-checklist.sh 生成并逐项作答"
    elif [ "${DC_BADFMT:-0}" -gt 0 ]; then
      p0 "领域专项清单有 ${DC_BADFMT} 项已勾选但缺证据：每项须附（证据：…）或 N-A+理由——防一键全勾走过场"
    else
      pass "domain checklist fully answered with evidence (${DC_DONE} items)"
    fi
  fi
fi

# ---------- v3.14.1: 章节结构位置检查——防"内容在、编号漂"（code03 教训） ----------
echo ""
echo "=== §3e 详设章节结构位置 ==="
STRUCT_MISSING=0
# v3.23.0: 语义锚点优先（正本）——章节编号仅展示，锚点是 /plan、/build 与评审定位契约
for _spec in "data-model:数据模型" "api-contracts:接口" "business-rules:业务规则" "acceptance-traceability:需求追溯" "implementation-handoff:实现交接"; do
  _a="${_spec%%:*}"; _t="${_spec#*:}"
  if grep -q "anchor: $_a" "$DESIGN_PATH" 2>/dev/null \
     || grep -qE "^## .*$_t" "$DESIGN_PATH" 2>/dev/null; then
    pass "design semantic anchor present: $_a"
  else
    p0 "design missing semantic anchor: ${_a}（补 <!-- anchor: ${_a} --> 或标题含「${_t}」的章节）"
    STRUCT_MISSING=$((STRUCT_MISSING+1))
  fi
done
# v3.24.0(A05)：四要素定位改语义锚点（正本）——单体/总文档/分文档编号各不相同
# （分文档 §11/§12/§13、总文档 §9.3/§9.4/§9.5），固定 §12.1/§12.2/§13/§2.3 编号
# 只适配单体模板，其余模式全部误报。锚点回落：语义锚点 → 同义 H2 标题。
for _spec in "component-reuse:组件复用|复用清单:组件复用" \
             "common-extraction:公共抽取|公共组件|抽取登记:公共抽取" \
             "standards-compliance:规范遵循|规范基线:规范遵循" \
             "design-decisions:设计决策|DDR:设计决策 DDR"; do
  _a="${_spec%%:*}"; _rest="${_spec#*:}"; _h2="${_rest%%:*}"; _t="${_rest#*:}"
  if grep -q "anchor: $_a" "$DESIGN_PATH" 2>/dev/null \
     || grep -qE "^## .*(${_h2})" "$DESIGN_PATH" 2>/dev/null; then
    pass "design semantic anchor present: $_a"
  else
    p0 "design missing semantic anchor: ${_a}（${_t}；补 <!-- anchor: ${_a} --> 或含「${_t}」的 H2 章节——编号在不同模板模式下不一致，语义锚点是唯一机器契约）"
    STRUCT_MISSING=$((STRUCT_MISSING+1))
  fi
done

# ---------- §3b 评审深度契约：DF 深层发现（v3.14.0） ----------
echo ""
echo "=== §3b DF 深层发现深度校验 ==="
AW_MIN="${DEEP_AW_MIN:-3}"

# 剥离 ``` 围栏代码块，避免模板示例干扰计数
STRIP_FILE=$(mktemp -t p2a-depth.XXXXXX)
awk '/^```/{infence=!infence; next} !infence' "$REVIEW_PATH" > "$STRIP_FILE"

# v3.24.0(A09)：设计文档标题编号集合（剥离围栏）——AW/探针证据引用的 §x.y
# 必须解析到真实对象（虚构锚点曾以“结果：§99.99”混过深度子检查）。
DESIGN_HEADINGS_FILE=$(mktemp -t p2a-dhead.XXXXXX)
awk '/^```/{infence=!infence; next} !infence && /^#{1,6} /' "$DESIGN_PATH" 2>/dev/null \
  | grep -oE '§?[0-9]+(\.[0-9]+)*' | sed 's/^§//' | sort -u > "$DESIGN_HEADINGS_FILE" || true

DF_TOTAL=$(grep -cE '^#### DF-[0-9]+' "$STRIP_FILE" || true)
pass "DF findings counted without padding (actual: $DF_TOTAL)"

DF_BAD=$(LC_ALL=C awk 'BEGIN{bad=0}
  # locale-proof 空字段判定：剥标签与 ASCII 杂质后，剩余仅为全角冒号(\357\274\232)或全角空格(\343\200\200)视为空
  function blank_tail(r) {
    gsub(/[- \t:]/, "", r)
    return (r == "" || r == "\357\274\232" || r == "\343\200\200" || r == "\357\274\232\343\200\200" || r == "\343\200\200\357\274\232")
  }
  /^#### DF-[0-9]+/ {
    if (inblock && (fsce || fimp || fsug || fver || floc)) { bad++ }
    inblock=1; fsce=1; fimp=1; fsug=1; fver=1; floc=1; next
  }
  /^#### / && inblock { if (fsce || fimp || fsug || fver || floc) { bad++ }; inblock=0; next }
  inblock {
    if ($0 ~ /^- 触发场景/) { r=$0; sub(/^- 触发场景/, "", r); if (!blank_tail(r)) fsce=0 }
    else if ($0 ~ /^- 影响链/) { r=$0; sub(/^- 影响链/, "", r); if (!blank_tail(r)) fimp=0 }
    else if ($0 ~ /^- 完善建议/) { r=$0; sub(/^- 完善建议/, "", r); if (!blank_tail(r)) fsug=0 }
    else if ($0 ~ /^- 验证方式/) { r=$0; sub(/^- 验证方式/, "", r); if (!blank_tail(r)) fver=0 }
    else if ($0 ~ /^- 文档位置/) {
      r=$0; sub(/^- 文档位置/, "", r)
      gsub(/[- \t:]/, "", r)
      gsub(/\302\247/, "", r)
      gsub(/\357\274\232/, "", r)
      if (r ~ /^[0-9]+(\.[0-9]+)*$/) floc=0
    }
  }
  END { if (inblock && (fsce || fimp || fsug || fver || floc)) { bad++ }; print bad }
' "$STRIP_FILE")
if [ "$DF_BAD" -eq 0 ]; then
  pass "all DF blocks complete (触发场景/影响链/完善建议/验证方式 non-empty, 位置 §x.y)"
else
  p0 "incomplete DF blocks: $DF_BAD — 五字段缺一判无效（规范见 concepts/review-depth-methodology.md §2）"
fi

# 每个角色必须有实际 DF，或有 ZERO-DF 核查证据；不再强制凑固定数量。
# v3.24.0(A09)：ZERO-DF 必须有非空核查记录——仅写空标题（无核查范围/证据/验证方式）
# 曾可混过深度子检查；零发现结论的证据含量与 DF 同级要求。
for role in "架构师" "后端专家" "前端专家" "测试开发" "DBA"; do
  role_cnt=$(grep -cE "^- 归属评委：${role}[[:space:]]*$" "$STRIP_FILE" || true)
  zero_cnt=$(grep -cE "^#### ZERO-DF.*${role}" "$STRIP_FILE" || true)
  if [ "$role_cnt" -gt 0 ] || [ "$zero_cnt" -gt 0 ]; then
    pass "review evidence by ${role}: DF=$role_cnt ZERO-DF=$zero_cnt"
  else
    p0 "${role} has neither DF nor ZERO-DF evidence"
  fi
  if [ "$role_cnt" -eq 0 ] && [ "$zero_cnt" -gt 0 ]; then
    # 该角色零发现：其 ZERO-DF 块必须含核查实质（核查范围/证据/验证方式任二字段非空，
    # 或块内实质内容 ≥3 行）——awk 局部变量防 $0 重建，块边界为下一个 #### 标题。
    zero_hollow=$(LC_ALL=C awk -v role="$role" '
      function blank(r){ gsub(/[[:space:]:：、，。-]/,"",r); return (r=="") }
      BEGIN{inblk=0; bad=0; fields=0; lines=0}
      /^#### ZERO-DF/ && $0 ~ role {inblk=1; fields=0; lines=0; next}
      /^#### / && inblk { if (fields<2 && lines<3) bad++; inblk=0; next }
      inblk {
        if (!blank($0)) {
          lines++
          if ($0 ~ /核查范围|核查清单|证据|验证方式|已核查|核对/) { if(!blank($0)) fields++ }
        }
      }
      END{ if (inblk && fields<2 && lines<3) bad++; print bad }
    ' "$STRIP_FILE")
    [ "$zero_hollow" -eq 0 ] || p0 "${role} 的 ZERO-DF 块缺核查实质（${zero_hollow} 个空块）——零发现必须附核查范围、证据锚点与验证方式，仅写标题不算证据"
  fi
done

DF_OPEN=$(grep -cE '^- 状态：OPEN|^- 状态:OPEN' "$STRIP_FILE" || true)
[ "$DF_OPEN" -eq 0 ] && pass "no OPEN DF findings" || p0 "OPEN DF findings: $DF_OPEN"
DF_STATUS_BAD=$(awk 'BEGIN{bad=0}
  /^#### DF-[0-9]+/ {if (inblock && !closed) bad++; inblock=1; closed=0; next}
  /^#### / && inblock {if (!closed) bad++; inblock=0; next}
  inblock && /^- 状态[：:]/ && /CLOSED/ {closed=1}
  END {if (inblock && !closed) bad++; print bad}' "$STRIP_FILE")
[ "$DF_STATUS_BAD" -eq 0 ] && pass "all DF findings have CLOSED status" || p0 "DF findings missing CLOSED status: $DF_STATUS_BAD"

# ---------- §3c 对抗场景走查 AW（v3.14.0） ----------
echo ""
echo "=== §3c 对抗场景走查（AW） ==="
AW_COUNT=$(grep -cE '^- AW-[0-9]+' "$STRIP_FILE" || true)
if [ "$AW_COUNT" -ge "$AW_MIN" ]; then
  pass "adversarial walkthroughs >= ${AW_MIN} (actual: $AW_COUNT)"
else
  p0 "adversarial walkthroughs < ${AW_MIN} (actual: $AW_COUNT) — 端到端走查是最有效的深挖探针"
fi

# v3.24.0(A09)：AW 三段契约——场景/走查路径/结果逐段非空，且「结果」中的
# §锚点必须存在于设计文档标题、DF 引用必须存在于本报告；只写"结果：§99.99"
# 式虚构锚点不再放行。
AW_BAD=0
while IFS= read -r awline; do
  [ -n "$awline" ] || continue
  aw_seg_bad=0
  for seg in "场景：" "走查路径：" "结果："; do
    _rest="${awline#*"$seg"}"
    [ "$_rest" = "$awline" ] && { aw_seg_bad=1; continue; }   # 缺该段标签
    _cell="${_rest%%｜*}"
    _cell="$(printf '%s' "$_cell" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$_cell" ] || aw_seg_bad=1
  done
  # 「结果」段引用解析：§锚点 → 设计标题集合；DF-xx → 本报告 DF 编号
  _result="${awline#*结果：}"; _result="${_result%%｜*}"
  _aw_refs=$(printf '%s' "$_result" | grep -oE '§[0-9]+(\.[0-9]+)*' | sed 's/^§//' | sort -u)
  _aw_dfs=$(printf '%s' "$_result" | grep -oE 'DF-[0-9]+' | sort -u)
  _aw_ref_bad=0
  if [ -z "$_aw_refs" ] && [ -z "$_aw_dfs" ]; then
    _aw_ref_bad=1   # 结果既无锚点也无 DF 引用
  fi
  for _a in $_aw_refs; do
    grep -qxF "$_a" "$DESIGN_HEADINGS_FILE" || _aw_ref_bad=1
  done
  for _d in $_aw_dfs; do
    grep -qE "^#### ${_d}([^0-9]|$)" "$STRIP_FILE" || _aw_ref_bad=1
  done
  [ "$aw_seg_bad" -eq 0 ] && [ "$_aw_ref_bad" -eq 0 ] || AW_BAD=$((AW_BAD+1))
done < <(grep -E '^- AW-[0-9]+' "$STRIP_FILE" 2>/dev/null || true)
if [ "$AW_BAD" -eq 0 ]; then
  pass "every AW has 场景/走查路径/结果 and 结果 resolves to real §anchor/DF"
else
  p0 "AW entries with empty segments or unresolvable 结果 references: $AW_BAD — 每条走查的三段非空，且「结果」的 §锚点必须存在于详设、DF 引用必须存在于本报告"
fi

# ---------- §3d 探针执行记录 + 浅层信号（v3.14.0） ----------
echo ""
echo "=== §3d 探针执行记录与浅层信号 ==="
if grep -q '探针执行记录' "$REVIEW_PATH"; then
  pass "probe execution record section present"
else
  p0 "missing 探针执行记录 — 六类探针未留痕不得下结论"
fi
for probe in "P1" "P2" "P3" "P4" "P5" "P6" "CODE-BASELINE"; do
  # v3.24.0(A02/报告§5)：CODE-BASELINE 代码基线核验探针——详设声明 REUSE/MODIFY/DELETE
  # 时必答（绿地纯 ADD 可不适用）；命名避开流程阶段 P7（部署）。
  _probe_required=1
  if [ "$probe" = "CODE-BASELINE" ]; then
    _probe_required=0
    P2A_DJ="${STATE_DIR:-.devflow}/${FEATURE}/design.json"
    if [ -f "$P2A_DJ" ] && command -v python3 >/dev/null 2>&1; then
      # $( ) 本身就是子 shell——unset LC_ALL 仅影响命令替换内部，不污染 Gate 环境
      _probe_required=$(unset LC_ALL; python3 -c 'import json,sys
try:
    es = json.load(open(sys.argv[1])).get("baseline", {}).get("entries", [])
    print(1 if any(e.get("decision") in ("REUSE", "MODIFY", "DELETE") for e in es) else 0)
except Exception:
    print(0)' "$P2A_DJ" 2>/dev/null || echo 0)
    fi
  fi
  probe_row=$(grep -E "^\\|[[:space:]]*${probe}[[:space:]]" "$REVIEW_PATH" 2>/dev/null | head -1 || true)
  if printf '%s' "$probe_row" | grep -qE '已执行|不适用' && printf '%s' "$probe_row" | grep -qE '证据|§[0-9]+\.[0-9]+'; then
    # v3.24.0(A09)：证据列的 §锚点必须解析到设计文档真实标题——
    # "已执行｜证据" 六行空壳曾原样通过探针子检查。
    probe_refs=$(printf '%s' "$probe_row" | grep -oE '§[0-9]+(\.[0-9]+)*' | sed 's/^§//' | sort -u)
    probe_ref_bad=0
    if [ -n "$probe_refs" ]; then
      for _pa in $probe_refs; do
        grep -qxF "$_pa" "$DESIGN_HEADINGS_FILE" || probe_ref_bad=1
      done
    fi
    if [ "$probe_ref_bad" -eq 0 ]; then
      pass "${probe} execution/evidence recorded"
    else
      p0 "${probe} evidence anchors do not resolve in design（§锚点必须指向详设真实标题）"
    fi
  elif [ "$_probe_required" = "0" ] && [ -z "$probe_row" ]; then
    pass "${probe} not applicable（详设无 REUSE/MODIFY/DELETE 基线条目）"
  else
    p0 "${probe} execution row missing status or evidence"
  fi
done

SHALLOW=$(grep -niE '已阅|LGTM|无明显问题|整体没问题|没有发现问题' "$REVIEW_PATH" || true)
if [ -z "$SHALLOW" ]; then
  pass "no shallow sign-off phrases"
else
  p0 "shallow sign-off phrases found: $(printf '%s' "$SHALLOW" | wc -l | tr -d ' ') 处 — 零发现结论必须附已核查清单+§锚点证据"
fi

SF_COUNT=$(grep -cE '(^|[^A-Za-z])SF-[0-9]+' "$STRIP_FILE" || true)
if [ "$SF_COUNT" -gt "$DF_TOTAL" ] && [ "$DF_TOTAL" -gt 0 ]; then
  warn "SF($SF_COUNT) > DF($DF_TOTAL) — 表层 nitpick 超过深层发现，凑数嫌疑"
fi
rm -f "$STRIP_FILE" "$DESIGN_HEADINGS_FILE"

# ---------- §3h 严重性修订纪律（v3.24.0/A13） ----------
echo ""
echo "=== §3h 严重性修订纪律 ==="
# 报告存在"严重性修订"表时：修订后严重性与原严重性不同的行必须给出修订理由——
# 不得靠把 P0/P1 改轻绕过关闭义务；确认评委列同步非空（当事人回避后须有人确认）。
SEV_BAD=$(LC_ALL=C awk -F'|' '
  function trim(s){gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s}
  /严重性修订/ {intab=1; next}
  /^\|/ && intab {
    # 数据行：| 序号 | 原DF | 原严重性 | 修订后 | 修订理由 | 确认评委 |
    if ($2 !~ /^[[:space:]]*[0-9]+[[:space:]]*$/) next
    orig=trim($4); rev=trim($5); reason=trim($6); conf=trim($7)
    if (orig != "" && rev != "" && orig != "—" && rev != "—" && orig != rev) {
      if (reason == "" || reason == "—" || conf == "" || conf == "—") bad++
    }
  }
  /^## / && intab && !/严重性修订/ {intab=0}
  END{print bad+0}' "$REVIEW_PATH" 2>/dev/null || echo 0)
if [ "${SEV_BAD:-0}" -eq 0 ]; then
  pass "severity revisions carry reason and confirmer（无理由改轻 = 绕过关闭义务，直接 P0）"
else
  p0 "severity revisions without reason/confirmer: $SEV_BAD — MINOR/降级接受须有理由、边界与批准记录，不得靠改严重性绕过"
fi

# ---------- §4 遗留问题 = 0 ----------
echo ""
echo "=== §4 遗留问题 = 0 ==="
# v3.14.1: 遗留问题升级为硬门禁（与 phases/02a、design-review.md 的"遗留问题=0"承诺对齐）
# v3.15.11: \b 在 BSD/BusyBox grep 不保证支持（v3.15.8 词边界收口政策漏网）——改 [^A-Za-z]（s4 先例）
LEFT_OVER=$(grep -ciE '(遗留|待修复|TBD|FIXME|未解决)[:：]|(^|[^A-Za-z])TBD([^A-Za-z]|$)|(^|[^A-Za-z])FIXME([^A-Za-z]|$)' "$REVIEW_PATH" 2>/dev/null || true)
if [ "${LEFT_OVER:-0}" -eq 0 ]; then
  pass "no leftover issues"
else
  p0 "leftover issues: $LEFT_OVER — 评审遗留必须清零后才能进入下一阶段"
fi

# ---------- §5 需求追溯（acceptance-traceability）100% 覆盖 ----------
echo ""
echo "=== §5 需求追溯（acceptance-traceability）100% 覆盖 ==="
P0_ID_FILE=$(mktemp -t p2a-criteria.XXXXXX)
DESIGN_ID_FILE=$(mktemp -t p2a-design.XXXXXX)
grep -oE 'M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$CRITERIA_PATH" 2>/dev/null | sort -u > "$P0_ID_FILE"
grep -oE 'M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$DESIGN_PATH" 2>/dev/null | sort -u > "$DESIGN_ID_FILE"
P0_IDS=$(grep -c . "$P0_ID_FILE" 2>/dev/null || true)
DESIGN_IDS=$(grep -c . "$DESIGN_ID_FILE" 2>/dev/null || true)
MISSING_TRACE=$(comm -23 "$P0_ID_FILE" "$DESIGN_ID_FILE" || true)
EXTRA_TRACE=$(comm -13 "$P0_ID_FILE" "$DESIGN_ID_FILE" || true)
if [ "$P0_IDS" -eq 0 ]; then
  p0 "no acceptance IDs in $CRITERIA_PATH"
elif [ -n "$MISSING_TRACE" ] || [ -n "$EXTRA_TRACE" ]; then
  p0 "design traceability set mismatch; missing=$(printf '%s' "$MISSING_TRACE" | tr '\n' ' ') extra=$(printf '%s' "$EXTRA_TRACE" | tr '\n' ' ')"
else
  pass "§9 traceability: $DESIGN_IDS / $P0_IDS (100%)"
fi
rm -f "$P0_ID_FILE" "$DESIGN_ID_FILE"

# ---------- §6 P2 设计覆盖率 = 100% ----------
echo ""
echo "=== §6 P2 设计覆盖率 = 100% ==="
if [ "${SKIP_P2:-0}" -eq 1 ]; then
  warn "P2 design coverage gate SKIPPED (--skip=P2)"
else
  P2A_LOG=$(mktemp -t p2a-s2.XXXXXX.log)
  # v3.16.26: 总分模式经 P2_DESIGN_MODE=total|sub 传入对应模板契约（默认 monolith）
  S2_MODE_ARG=""
  case "${P2_DESIGN_MODE:-monolith}" in
    total|sub) S2_MODE_ARG="--mode=${P2_DESIGN_MODE}" ;;
  esac
  if bash "$SKILL_ROOT/scripts/s2_design_coverage_gate.sh" "$DESIGN_PATH" "$CRITERIA_PATH" $S2_MODE_ARG > "$P2A_LOG" 2>&1; then
    pass "P2 design coverage = 100%"
  else
    p0 "P2 design coverage < 100% (see $P2A_LOG)"
  fi
  rm -f "$P2A_LOG"
fi

# ---------- §7 无 TODO/占位符 ----------
echo ""
echo "=== §7 无 TODO/占位符 ==="
TODO_COUNT=$(grep -cE 'TODO|TBD|FIXME|待补充|REPLACE_WITH' "$REVIEW_PATH" 2>/dev/null || true)
if [ "$TODO_COUNT" -eq 0 ]; then
  pass "no TODO/placeholder in review"
else
  p0 "TODO/placeholder found: $TODO_COUNT"
fi

# ---------- 收据 ----------
RECEIPT_DIR="${STATE_DIR:-.devflow}/${FEATURE}/gates/P2a"
mkdir -p "$RECEIPT_DIR"
P2A_EXIT=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
GATE_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$(cd "$(dirname "$0")/.." && pwd)/SKILL.md" 2>/dev/null | head -1)
[ -n "$GATE_VER" ] || { echo "[FATAL] 版本源读取失败，拒绝产出收据"; exit 2; }
cat > "$RECEIPT_DIR/receipt.txt" <<EOF
EXIT_CODE=$P2A_EXIT
VERSION=p2a@$GATE_VER
SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)
PHASE=P2a
PASS=$PASS FAIL=$FAIL WARN=$WARN
P2a 设计评审 Gate · v3.14.0
========================
feature: $FEATURE
design: $DESIGN_PATH
review: $REVIEW_PATH
criteria: $CRITERIA_PATH
pass: $PASS
warn: $WARN
fail: $FAIL
df_total: $DF_TOTAL
aw_total: $AW_COUNT
author_id: $AUTHOR_ID
review_run_id: $RUN_ID
timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
# v3.9.5: mirror receipt into docs/ (version-controlled evidence; .devflow/ was missing in all 4 audited projects)
DOCS_MIRROR="docs/${FEATURE}/gates/P2a"
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"

# ---------- 总结 ----------
echo ""
echo "════════════════════════════════════════════════════════════"
echo " P2a 设计评审 Gate · 总结"
echo "════════════════════════════════════════════════════════════"
echo " PASS: $PASS"
echo " WARN: $WARN"
echo " FAIL: $FAIL"
echo "════════════════════════════════════════════════════════════"

if [ "$FAIL" -eq 0 ]; then
  echo "✅ P2a 设计评审 Gate 通过"
  exit 0
else
  echo "❌ P2a 设计评审 Gate 失败（FAIL=${FAIL}）"
perf_end "P2a"
  exit 1
fi
