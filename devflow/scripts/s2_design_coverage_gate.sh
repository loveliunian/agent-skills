#!/usr/bin/env bash

# : 推导 feature，避免写入 default 目录
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
source "$(cd "$(dirname "$0")" && pwd)/devflow_receipt.sh"
# v3.22.0: 文档层中文化（中文优先、英文回退）
source "$(cd "$(dirname "$0")" && pwd)/devflow_paths.sh"
# v3.14.1: 一次性推导；失败（多 state/无 state）即拒绝执行，杜绝 default 目录
EFF_FEATURE="$(devflow_feature "${FEATURE:-}")" || { echo "[FATAL] feature 推导失败，拒绝继续"; exit 2; }
[ -n "$EFF_FEATURE" ] || { echo "[FATAL] feature 为空，拒绝继续"; exit 2; }
# =============================================================================
# P2 设计覆盖率 Gate (v3.9.1 · 含模板-产物对齐检查)
# =============================================================================
set -uo pipefail
LC_ALL=C
export LC_ALL
# v3.20.2: python 子进程剥离 LC_ALL——C locale 下含非 ASCII site 配置的解释器
# （如 venv editable .pth 含中文路径）在 site 初始化即崩；grep/awk 仍保持 C locale。
_python3() { (unset LC_ALL; exec python3 "$@"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEMPLATES_DIR="$SKILL_ROOT/templates"

FAIL=0; PASS=0; WARN=0
p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

DESIGN=""
CRITERIA=""
MODE="monolith"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only) shift ;;
    --legacy) shift ;;
    # v3.16.26: --mode 决定模板身份与章节契约——单体=完整版；总分总文档；总分分文档
    --mode=monolith|--mode=total|--mode=sub) MODE="${1#--mode=}"; shift ;;
    --mode) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --mode requires a non-flag value" >&2; exit 2; }; MODE="$2"; shift 2 ;;
    # v3.15.8: 旧写法 `${1:-}` 预赋值 + `A && B || C && D` 左结合——单参数调用时 DESIGN 已非空，
    # 短路落到右支把 $1 再赋给 CRITERIA → criteria 与 design 同文件自证（独立冻结分母校验被绕过，
    # 覆盖率假绿 100%）。改 if/elif 显式填充，单参数恢复走下方默认路径推导。
    *) if [ -z "$DESIGN" ]; then DESIGN="$1";
       elif [ -z "$CRITERIA" ]; then CRITERIA="$1";
       else echo "[P0] too many positional args: $1"; FAIL=$((FAIL+1)); fi; shift ;;
  esac
done

case "$MODE" in
  monolith) TEMPLATE_NAME="详细设计-完整版-模板.md" ;;
  total)    TEMPLATE_NAME="详细设计-总分总文档-模板.md" ;;
  sub)      TEMPLATE_NAME="详细设计-总分分文档-模板.md" ;;
  *) echo "[P0] invalid --mode: $MODE (monolith|total|sub)"; exit 2 ;;
esac

[ -z "$DESIGN" ] && { echo "Usage: $0 <design.md> <criteria.md>"; exit 2; }
[ -z "$CRITERIA" ] && CRITERIA="$(echo "$DESIGN" | sed 's|detailed-design|requirements|;s|-design.md|-acceptance-criteria.md|')"
# v3.17.2(L6): 缺省推导坍缩（$DESIGN 不符合命名约定时 criteria==design）= 冻结分母自证
if [ "$CRITERIA" = "$DESIGN" ]; then
  echo "[P0] criteria 未提供且无法从 design 路径推导（${DESIGN}）——冻结分母不得与被验对象同一文件"; exit 2
fi

# ---------- §0 基础文件 ----------
echo ""
echo "=== §0 基础文件 ==="
[ -f "$DESIGN" ] || { p0 "design missing: $DESIGN"; exit 1; }
pass "design exists: $DESIGN"
# v3.21.0(L-P2-001): 跨模板视图必须独立文件——设计文档为硬链接别名时拒绝 Gate。
# 硬链接别名共享 inode，生成器/投影写入会经同一 inode 覆盖分文档详设
# （治理服务 v2.1.1 事故：聚合投影覆写分文档）。python3 缺失时跳过本检查
# （生成器侧 nlink 防护为主防线；§2c 仍有 python3 硬依赖兜底）。
if command -v python3 >/dev/null 2>&1; then
  _S2_NLINK=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_nlink)' "$DESIGN" 2>/dev/null || echo 1)
  case "$_S2_NLINK" in ''|*[!0-9]*) _S2_NLINK=1 ;; esac
  if [ "$_S2_NLINK" -gt 1 ]; then
    p0 "设计文档为硬链接（nlink=${_S2_NLINK}）: ${DESIGN} —— 跨模板视图必须独立文件（L-P2-001），请 unlink 别名后重跑"
    exit 1
  fi
  pass "design inode independent (nlink=1)"
fi
[ -f "$CRITERIA" ] || { p0 "criteria file not found: $CRITERIA"; exit 1; }

# ---------- §1 验收点解析 ----------
echo ""
echo "=== §1 验收点解析 ==="
TOTAL=0
ATOMIC_IDS=$(grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$CRITERIA" 2>/dev/null | sort -u)
TOTAL=$(printf '%s\n' "$ATOMIC_IDS" | grep -c . || true)
[ "$TOTAL" -gt 0 ] && pass "total acceptance points: $TOTAL" || p0 "no acceptance criteria found"

# v3.16.25: 设计验收点集合必须与冻结分母完全相等，不能只检查数量或文档内出现次数。
CRITERIA_IDS_FILE=$(mktemp -t devflow-criteria.XXXXXX)
DESIGN_IDS_FILE=$(mktemp -t devflow-design.XXXXXX)
printf '%s\n' "$ATOMIC_IDS" | sed '/^$/d' | sort -u > "$CRITERIA_IDS_FILE"
grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$DESIGN" 2>/dev/null | sort -u > "$DESIGN_IDS_FILE"
MISSING_IDS=$(comm -23 "$CRITERIA_IDS_FILE" "$DESIGN_IDS_FILE" || true)
EXTRA_IDS=$(comm -13 "$CRITERIA_IDS_FILE" "$DESIGN_IDS_FILE" || true)
[ -z "$MISSING_IDS" ] && pass "design acceptance-ID set has no missing IDs" || { p0 "design missing acceptance IDs: $(printf '%s' "$MISSING_IDS" | tr '\n' ' ')"; }
[ -z "$EXTRA_IDS" ] && pass "design acceptance-ID set has no extra IDs" || { p0 "design has extra acceptance IDs: $(printf '%s' "$EXTRA_IDS" | tr '\n' ' ')"; }

# ---------- §2 COMPLETE 行数 ----------
echo ""
echo "=== §2 COMPLETE 状态检查 ==="
COMPLETE=0
INCOMPLETE=0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  if grep -E "\|[[:space:]]*${id}[[:space:]]*\|" "$DESIGN" 2>/dev/null | grep -qE '\|[[:space:]]*COMPLETE[[:space:]]*\|'; then
    COMPLETE=$((COMPLETE + 1))
  else
    p0 "acceptance $id missing COMPLETE design row"
    INCOMPLETE=$((INCOMPLETE + 1))
  fi
done <<< "$ATOMIC_IDS"
[ "$INCOMPLETE" -eq 0 ] && [ "$TOTAL" -gt 0 ] && pass "all $COMPLETE/$TOTAL have COMPLETE"

# 每个验收点行必须包含完整追溯矩阵（ID、PRD锚点、页面/任务、接口、数据、规则、测试、状态），
# 且逐列验证：非空 + 锚点格式（v3.16.26：此前只查列数，空映射行曾可混过）。
TRACE_BAD=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  row=$(grep -E "^\\|[[:space:]]*${id}[[:space:]]*\\|" "$DESIGN" 2>/dev/null | head -1 || true)
  fields=$(printf '%s\n' "$row" | awk -F'|' '{print NF}')
  [ "${fields:-0}" -ge 9 ] || { p0 "acceptance $id trace row has incomplete columns"; TRACE_BAD=$((TRACE_BAD+1)); continue; }
      # 列布局：$2=ID $3=PRD锚点 $4=页面/任务 $5=接口 $6=数据字段 $7=规则 $8=测试用例 $9=状态
      # v3.19.0(P1-4): page/api/data 允许显式占位 —（纯后端 feature 的合法零结果，
      # 由 design.json zero_results 声明 + §2c 校验器把关）；prd#/TC-/COMPLETE 仍强制。
      colbad=$(printf '%s\n' "$row" | awk -F'|' -v id="$id" '
        function trim(s){gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s}
        {
          prd=trim($3); page=trim($4); api=trim($5); data=trim($6); rule=trim($7); tc=trim($8); st=trim($9)
          if (prd == "" || prd !~ /#/) print "PRD锚点缺失或无#锚点"
          if (page == "" || (page !~ /§/ && page != "—")) print "页面/任务须为§锚点或—"
          if (api == "" || (api !~ /§/ && api != "—")) print "接口契约须为§锚点或—"
          if (data == "" || (data !~ /§/ && data != "—")) print "数据字段须为§锚点或—"
          if (rule == "" || (rule !~ /§/ && rule !~ /^R[0-9]/ && rule !~ /R[0-9]+\./)) print "规则须为§锚点或R编号"
          if (tc == "" || tc !~ /^TC-[A-Za-z0-9-]+/) print "测试用例须为TC-编号"
          if (st != "COMPLETE") print "设计状态须为COMPLETE（实际:" st "）"
        }')
  if [ -n "$colbad" ]; then
    p0 "acceptance $id trace row invalid columns: $(printf '%s' "$colbad" | tr '\n' ';')"
    TRACE_BAD=$((TRACE_BAD+1))
  fi
done <<< "$ATOMIC_IDS"
[ "$TRACE_BAD" -eq 0 ] && pass "all acceptance trace rows have complete columns"
rm -f "$CRITERIA_IDS_FILE" "$DESIGN_IDS_FILE"

# ---------- §2b 技术硬约束引用 (v3.16.26 NEW) ----------
echo ""
echo "=== §2b 技术硬约束引用 ==="
if [ -n "${TECH_CONSTRAINTS_FILE:-}" ]; then
  TC_PATH="$TECH_CONSTRAINTS_FILE"
else
  TC_PATH="$(df_resolve_doc "$EFF_FEATURE" constraints .md requirements)"
  [ -n "$TC_PATH" ] || TC_PATH="docs/需求/${EFF_FEATURE}-技术约束.md"
fi
source "$SCRIPT_DIR/tech_constraints_lib.sh"
if [ ! -f "$TC_PATH" ]; then
  p0 "technology constraints missing: $TC_PATH — P2 详设必须逐条引用 constraint_id"
else
  CID_LIST=$(tc_validate_constraints "$TC_PATH" 2>/dev/null | awk -F'\t' '{print $1}')
  CID_TOTAL=$(printf '%s\n' "$CID_LIST" | grep -c . || true)
  CID_MISS=0
  if [ "$CID_TOTAL" -gt 0 ]; then
    while IFS= read -r cid; do
      [ -n "$cid" ] || continue
      if ! grep -qF "$cid" "$DESIGN" 2>/dev/null; then
        p0 "design does not reference hard constraint $cid — 详设必须逐条引用约束 ID"
        CID_MISS=$((CID_MISS+1))
      fi
    done <<< "$CID_LIST"
    [ "$CID_MISS" -eq 0 ] && pass "design references all $CID_TOTAL hard constraint IDs"
  else
    pass "no hard constraints declared (NONE)"
  fi
fi

# ---------- §2c 结构化产物层 design.json (v3.17.0 NEW; v3.17.1 升级为必填) ----------
# 失败关闭：design.json 缺失即 P0——手写模式无跨字段保证（覆盖率/追溯矩阵/接口概览↔
# 详细定义闭环/DDR↔字段一一对应全部失去机器校验，实测正是详设缺漏的根源）。
echo ""
echo "=== §2c 结构化产物层 (design.json) ==="
DESIGN_JSON="${STATE_DIR:-.devflow}/${EFF_FEATURE}/design.json"
if [ ! -f "$DESIGN_JSON" ]; then
  p0 "design.json 缺失: ${DESIGN_JSON}——P2 必须产出结构化业务产物层（契约 schemas/design.schema.json，管线 df_pipeline.py design，见 phases/02-详细设计.md §结构化产物层）"
elif ! command -v python3 >/dev/null 2>&1; then
  p0 "design.json 存在但 python3 不可用——结构化产物校验无法执行（失败关闭）: $DESIGN_JSON"
else
  # v3.24.0(A05)：--doc 全模式对账——旧逻辑仅 monolith 传 --doc，sub 文档删掉
  # 接口详细定义标题、JSON detail_anchor 指向不存在 §99.9.9 仍 exit=0（分文档
  # 跳过正文锚点对账）。总分模式 JSON 为 feature 级，但对账目标是对应的分/总文档。
  # --workspace .：仓库标志存在时启用基线/配置全仓反查（A02）。
  V_ARGS=(--kind design --input "$DESIGN_JSON" --workspace . --doc "$DESIGN")
  [ -n "$CRITERIA" ] && V_ARGS+=(--criteria "$CRITERIA")
  # v3.24.0(A05)：设计包清单——总分模式必填；子集并集=冻结分母、缺文档即失败；
  # 当前文档按其验收子集做范围过滤的文档对账（--scope-ids）。
  PKG_FILE="${STATE_DIR:-.devflow}/${EFF_FEATURE}/design-package.json"
  if [ "$MODE" != "monolith" ]; then
    if [ ! -f "$PKG_FILE" ]; then
      p0 "design-package.json 缺失: ${PKG_FILE}——总分模式必须登记设计包（docs[].path/mode/acceptance_ids；子集并集=冻结分母，缺文档即失败）"
    elif command -v python3 >/dev/null 2>&1; then
      PKG_OUT=$(_python3 "$SKILL_ROOT/scripts/df_design_package.py" --package "$PKG_FILE" --criteria "$CRITERIA" --doc "$DESIGN" 2>&1)
      if [ $? -eq 0 ]; then
        PKG_SCOPE=$(printf '%s\n' "$PKG_OUT" | sed -n 's/^SCOPE=//p')
        pass "design-package 清单校验通过（当前文档子集 ${#PKG_SCOPE} 字符）"
        [ -n "$PKG_SCOPE" ] && V_ARGS+=(--scope-ids "$PKG_SCOPE")
      else
        p0 "design-package 清单校验失败: $(printf '%s' "$PKG_OUT" | head -2 | tr '\n' ' ')"
      fi
    fi
  fi
  if _python3 "$SKILL_ROOT/scripts/df_validate.py" "${V_ARGS[@]}"; then
    pass "design.json 校验通过（schema + 跨字段 + criteria 全等 + 正文锚点/字段对账）"
  else
    p0 "design.json 校验失败——修复后重跑 df_pipeline.py design 再过 Gate（渲染器遇缺字段会静默降级，必须在渲染前拦截）"
  fi
fi

# ---------- §2d 冻结客户端范围对账（v3.24.0 A06） ----------
echo ""
echo "=== §2d 冻结客户端范围对账 ==="
S2_STATE_FILE="${STATE_DIR:-.devflow}/${EFF_FEATURE}.state.json"
if [ -f "$S2_STATE_FILE" ] && [ -f "$DESIGN_JSON" ] && command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  FROZEN_FE=$(jq -r '.scope.frontend // empty' "$S2_STATE_FILE" 2>/dev/null)
  DECL_FE=$(_python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("client",{}).get("scope",""))
except Exception: print("")' "$DESIGN_JSON" 2>/dev/null || true)
  if [ -n "$FROZEN_FE" ] && [ -n "$DECL_FE" ]; then
    if [ "$FROZEN_FE" = "$DECL_FE" ]; then
      pass "client scope reconciles with frozen state (${DECL_FE})"
    else
      p0 "client scope drift: state 冻结 frontend=${FROZEN_FE}，design.json 声明 ${DECL_FE}（P1/P2 必须消费同一冻结范围；范围变化须回 P0 重冻结——实测冻结 app 声明 not-applicable 曾静默通过）"
    fi
  fi
else
  warn "skip client-scope reconciliation: state 或 design.json 缺失"
fi

# ---------- §3 覆盖率 ----------
echo ""
echo "=== §3 设计覆盖率 ==="
COVERAGE_RATE=0
if [ "$TOTAL" -gt 0 ]; then
  COVERAGE_RATE=$(awk -v c="$COMPLETE" -v t="$TOTAL" 'BEGIN {printf "%.0f", (c/t)*100}')
  echo "  $COMPLETE / $TOTAL = ${COVERAGE_RATE}%"
  [ "$COMPLETE" -eq "$TOTAL" ] && pass "design coverage = 100%" || p0 "design coverage < 100%: ${COVERAGE_RATE}%"
fi

# ---------- §4 五列数据模型（v3.9.8：七列删'老系统来源/迁移转换规则'两列） ----------
echo ""
echo "=== §4 五列数据模型 ==="
# v3.24.0(A06)：design.json 声明 tables 为空（zero_results，由 df_validate 把关声明
# 合法性）的纯计算/纯任务需求，五列表头不再强制——合法无数据设计曾被误拒（实测
# 纯计算 JSON 校验 exit=0、s2 FAIL=3）。无 design.json 时维持强制。
DJ_TABLES_EMPTY=0
if [ -f "$DESIGN_JSON" ] && command -v python3 >/dev/null 2>&1; then
  DJ_TABLES_EMPTY=$(_python3 -c 'import json,sys
try: print(1 if not json.load(open(sys.argv[1])).get("tables") else 0)
except Exception: print(0)' "$DESIGN_JSON" 2>/dev/null || echo 0)
fi
FIVE_COL='字段名.*类型.*约束.*默认值.*口径说明'
if [ "$DJ_TABLES_EMPTY" = "1" ]; then
  pass "five-column data model exempted: design.json 声明 tables 为空（zero_results 已由 §2c 校验）"
elif grep -qE "$FIVE_COL" "$DESIGN" 2>/dev/null; then
  # 兼容提示：若仍带旧七列表头则告警（存量产物需升级）
  if grep -qE '字段名.*类型.*约束.*默认值.*口径说明.*老系统来源' "$DESIGN" 2>/dev/null; then
    warn "数据模型表仍含旧列'老系统来源/迁移转换规则'（v3.9.8 已删除，迁移信息移至 docs/数据映射/）"
  fi
  pass "five-column data model header found"
else
  p0 "five-column data model header missing"
  p1 "expected: 字段名|类型|约束|默认值|口径说明"
fi

# ---------- §5 六列接口字段 ----------
echo ""
echo "=== §5 六列接口字段 ==="
# v3.24.0(A06)：同 §4——design.json 声明 apis 为空时不强制六列表头。
DJ_APIS_EMPTY=0
if [ -f "$DESIGN_JSON" ] && command -v python3 >/dev/null 2>&1; then
  DJ_APIS_EMPTY=$(_python3 -c 'import json,sys
try: print(1 if not json.load(open(sys.argv[1])).get("apis") else 0)
except Exception: print(0)' "$DESIGN_JSON" 2>/dev/null || echo 0)
fi
REQ='字段.*类型.*必填.*校验规则.*数据来源.*脱敏'
RES='字段.*类型.*恒出性.*取值规则.*数据来源.*脱敏'
if [ "$DJ_APIS_EMPTY" = "1" ]; then
  pass "request/response six-column exempted: design.json 声明 apis 为空（zero_results 已由 §2c 校验）"
else
  if grep -qE "$REQ" "$DESIGN" 2>/dev/null; then
    pass "request six-column found"
  else
    p0 "request six-column missing"
  fi
  if grep -qE "$RES" "$DESIGN" 2>/dev/null; then
    pass "response six-column found"
  else
    p0 "response six-column missing"
  fi
fi

# ---------- §6 WHEN + R 编号 ----------
echo ""
echo "=== §6 WHEN 准伪代码 + R 编号 ==="
WHEN_COUNT=$(grep -cE '^WHEN[[:space:]]+' "$DESIGN" 2>/dev/null || true)
# v3.14.10: 同时接受行首 R1. 与表格 | R1 | 两种格式
RULE_COUNT=$(grep -cE '(^R[0-9]+\.)|^\| *R[0-9]+ *\|' "$DESIGN" 2>/dev/null || true)
[ "$WHEN_COUNT" -gt 0 ] && pass "WHEN clauses: $WHEN_COUNT" || p0 "WHEN clauses missing"
[ "$RULE_COUNT" -gt 0 ] && pass "numbered rules R1.-R$((RULE_COUNT)).: $RULE_COUNT" || p0 "R 编号规则缺失"
# v3.24.0(A01)：模板要求每个关键流程 WHEN 伪代码与时序图成对——旧 Gate 只查全文
# WHEN>0，流程缩成一行 `WHEN 查询` 也能过。每个 WHEN 至少对应一张时序图。
SEQ_COUNT=$(grep -c 'sequenceDiagram' "$DESIGN" 2>/dev/null || true)
if [ "$WHEN_COUNT" -gt 0 ] && [ "$SEQ_COUNT" -ge "$WHEN_COUNT" ]; then
  pass "WHEN/sequenceDiagram paired (${WHEN_COUNT}/${SEQ_COUNT})"
else
  p0 "关键流程缺时序图：WHEN=${WHEN_COUNT} sequenceDiagram=${SEQ_COUNT}（每个关键流程必须 WHEN 伪代码 + Mermaid 时序图成对）"
fi

# ---------- §6b 规则前置操作可达性（v3.26 NEW；L-P2-005 教训） ----------
# 事故：R6「先停用才可删除」+错误码 ELEMENT_NOT_DISABLED 引用的 toggle 端点只有
# 接口概览行、无字段级契约，五角色两轮评审与 §1-§6 全部漏过（正向追溯不覆盖反向可达性）。
# 有 design.json 时为强检查（P0：硬前置必须命中详定义 api）；无则降级提示（WARN）。
echo ""
echo "=== §6b 规则前置操作可达性 ==="
if command -v python3 >/dev/null 2>&1 && [ -f "$SKILL_ROOT/scripts/rule_operation_closure.py" ]; then
  ROC_ARGS=(--design "$DESIGN")
  [ -f "$DESIGN_JSON" ] && ROC_ARGS+=(--design-json "$DESIGN_JSON")
  if _python3 "$SKILL_ROOT/scripts/rule_operation_closure.py" "${ROC_ARGS[@]}"; then
    pass "rule operation closure（规则前置操作均有可达契约）"
  else
    if [ -f "$DESIGN_JSON" ]; then
      p0 "rule operation closure 缺口：规则/错误码引用的前置操作缺端点或字段级契约（见上；事故教训 L-P2-005）"
    else
      warn "rule operation closure 存在缺口（无 design.json，未做强前置判定；建议补结构化层后复跑）"
    fi
  fi
else
  warn "skip rule operation closure: python3 或检查脚本缺失"
fi

# ---------- §6c 内容充分性三防线（v3.26.4；治理服务第三轮复核 DF-57~70 教训） ----------
# 机械盲区实证：正向追溯门禁对「重写丢机制（DF-57/58/65）」「状态机交叉（DF-61/63/64）」
# 「跨文档契约（DF-60/67/68）」三类问题零拦截。本节为内容级兜底：
#   field-drift  —— archive 机制语义词丢失=P0（PRD 必填措辞仅 WARN，别名误报高）
#   state-matrix —— Gate 恒传 --strict（死状态 P0）；探针独立运行时默认 WARN
#   cross-doc    —— 提供 --peer/--matrix 时 jobKey/内部端点/权限码对账 P0
echo ""
echo "=== §6c 内容充分性三防线 ==="
CS_PROBE="$SKILL_ROOT/scripts/content_sufficiency_probes.py"
if command -v python3 >/dev/null 2>&1 && [ -f "$CS_PROBE" ]; then
  CS_FAIL=0
  # 输入发现（可选）：PRD 取验收点同目录；legacy 取 archive/ 下同域旧设计；peer 取同目录其他分文档
  # v3.26.4：发现目录必须用「设计真身」解析（DESIGN 可能是 symlink；同目录旧副本/
  # 自身副本会污染对端与 legacy 判定——治理服务实测：陈旧副本被当 peer 导致跨文档假 FAIL）
  CS_DIR="$(dirname "$DESIGN")"
  if command -v realpath >/dev/null 2>&1; then
    CS_DIR="$(dirname "$(realpath "$DESIGN" 2>/dev/null || echo "$DESIGN")")"
  fi
  DESIGN_SHA=$(shasum -a 256 "$DESIGN" 2>/dev/null | awk '{print $1}')
  CS_PRD=""; [ -n "$CRITERIA" ] && CS_PRD=$(ls "$CS_DIR/../PRD/"*.md 2>/dev/null | head -1)
  # legacy：仅取设计文档自身引用的 archive（changelog/承接声明），精确到模块——防无关归档误报
  CS_LEGACY=""
  for _ref in $(grep -oE 'archive/[A-Z]-[0-9]+[^ )）`，。；]*' "$DESIGN" 2>/dev/null | sed 's|archive/||' | sort -u); do
    for _f in "$CS_DIR/archive/${_ref}"*.md; do
      [ -f "$_f" ] && CS_LEGACY="$CS_LEGACY $_f"
    done
  done
  CS_LEGACY=$(printf '%s\n' $CS_LEGACY | sort -u | tr '\n' ' ')
  # peers：同目录其他分文档；按 realpath 与内容哈希双重排除自身（含 symlink 名不同但内容相同）
  CS_PEERS=""
  for _p in "$CS_DIR"/*-详细设计-v2.md; do
    [ -f "$_p" ] || continue
    _rp="$_p"
    command -v realpath >/dev/null 2>&1 && _rp="$(realpath "$_p" 2>/dev/null || echo "$_p")"
    [ "$_rp" = "$(realpath "$DESIGN" 2>/dev/null || echo "$DESIGN")" ] && continue
    _sha=$(shasum -a 256 "$_p" 2>/dev/null | awk '{print $1}')
    [ -n "$DESIGN_SHA" ] && [ "$_sha" = "$DESIGN_SHA" ] && continue
    CS_PEERS="$CS_PEERS $_p"
  done
  CS_MATRIX="$CS_DIR/_权限矩阵.md"
  # 1) field-drift（legacy 任一命中即判；PRD 仅 WARN）
  # v3.26.4: 补传 --prd（CS_PRD 此前计算后未消费——死代码 + SC2034；探针对 PRD 仅
  # WARN 不阻断，接线后完成"PRD 必填项 0 命中提示"的既定设计）。
  for LG in $CS_LEGACY; do
    CS_FD_ARGS=(--design "$DESIGN" --legacy "$LG")
    [ -n "$CS_PRD" ] && [ -f "$CS_PRD" ] && CS_FD_ARGS+=(--prd "$CS_PRD")
    if _python3 "$CS_PROBE" field-drift "${CS_FD_ARGS[@]}"; then :; else CS_FAIL=1; fi
  done
  [ -z "$CS_LEGACY" ] && pass "field-drift: 无 archive 旧设计输入，跳过机制承接核对"
  # 2) state-matrix（strict=P0 组合缺口；默认死状态 WARN 不阻断）
  if _python3 "$CS_PROBE" state-matrix --design "$DESIGN" --design-json "${DESIGN_JSON:-}" --strict; then :; else CS_FAIL=1; fi
  # 3) cross-doc（有 peer 或 matrix 输入才判）
  if [ -n "$CS_PEERS" ] || [ -f "$CS_MATRIX" ]; then
    CS_ARGS=(--design "$DESIGN")
    for PP in $CS_PEERS; do CS_ARGS+=(--peer "$PP"); done
    [ -f "$CS_MATRIX" ] && CS_ARGS+=(--matrix "$CS_MATRIX")
    if _python3 "$CS_PROBE" cross-doc "${CS_ARGS[@]}"; then :; else CS_FAIL=1; fi
  else
    pass "cross-doc: 无对端文档/权限矩阵输入，跳过"
  fi
  [ "$CS_FAIL" -eq 0 ] && pass "content sufficiency probes（field-drift/state-matrix/cross-doc）" \
                        || p0 "内容充分性缺口（见上三探针明细；修复或 DDR/豁免声明后重跑）"
else
  warn "skip §6c: python3 或 content_sufficiency_probes.py 缺失"
fi

# ---------- §7 占位符 ----------
echo ""
echo "=== §7 占位符 ==="
PLACEHOLDERS=0
for pattern in 'TODO' 'TBD' '待补充' 'REPLACE_WITH' '占位' '暂定'; do
  COUNT=$(grep -iE "$pattern" "$DESIGN" 2>/dev/null | grep -c . || true)
  if [ "$COUNT" -gt 0 ]; then
    p0 "placeholder '$pattern': $COUNT"
    grep -niE "$pattern" "$DESIGN" 2>/dev/null | head -3 | sed 's/^/    /'
    PLACEHOLDERS=$((PLACEHOLDERS + COUNT))
  fi
done
# v3.24.0(A16)：未替换模板变量检查——正文（剥离围栏后）残留的 {xxx}/{业务方填写}
# 式花括号变量即未完成（实测「操作前置条件：{业务方填写}」曾通过 P2）。围栏内
# 代码/JSON 示例的 braces 不算；${var} shell 变量不算。
S2_STRIP_FILE=$(mktemp -t s2-strip.XXXXXX)
awk '/^(```|~~~)/{f=!f;next} !f' "$DESIGN" > "$S2_STRIP_FILE" 2>/dev/null || true
BRACE_VARS=$(grep -oE '\{[^{}[:space:]]{1,24}\}' "$S2_STRIP_FILE" 2>/dev/null | grep -v '^\${' | sort | uniq -c | sort -rn | head -5 || true)
if [ -n "$BRACE_VARS" ]; then
  p0 "unreplaced template variables in body: $(printf '%s' "$BRACE_VARS" | tr '\n' ' ')"
  PLACEHOLDERS=$((PLACEHOLDERS + 1))
else
  pass "no unreplaced brace variables outside fenced blocks"
fi
rm -f "$S2_STRIP_FILE"
[ "$PLACEHOLDERS" -eq 0 ] && pass "no placeholders"

# ---------- §8 (v3.9.1 NEW) 模板-产物对齐检查 ----------
echo ""
echo "=== §8 (v3.9.1 NEW) 模板-产物章节对齐 ==="

TEMPLATE_FILE="$TEMPLATES_DIR/$TEMPLATE_NAME"
if [ ! -f "$TEMPLATE_FILE" ]; then
  warn "skip template alignment: template not found"
else
  TEMPLATE_H2=$(grep -E '^## ' "$TEMPLATE_FILE" 2>/dev/null | sed 's/^## //' | sort)
  PRODUCT_H2=$(cat "$DESIGN" 2>/dev/null | grep -E '^## ' | sed 's/^## //' | sort)

  # v3.9.1: 前缀匹配容忍"§6 关键流程"vs"§6 关键流程（WHEN 准伪代码）"类别名
  TEMPLATE_PREFIX=$(printf '%s\n' "$TEMPLATE_H2" | awk '{gsub(/^([0-9]+\. |§[0-9]+ )/, ""); print substr($0,1,4)}' | sort -u)
  PRODUCT_PREFIX=$(printf '%s\n' "$PRODUCT_H2" | awk '{gsub(/^([0-9]+\. |§[0-9]+ )/, ""); print substr($0,1,4)}' | sort -u)

  MISSING=$(comm -23 <(printf '%s\n' "$TEMPLATE_PREFIX") <(printf '%s\n' "$PRODUCT_PREFIX") | grep -v '^$')
  MISSING_COUNT=$(echo "$MISSING" | grep -c . || true)

  if [ "$MISSING_COUNT" -gt 0 ]; then
    p0 "design.md 缺少模板章节 ($MISSING_COUNT 个):"
    echo "$MISSING" | sed 's/^/    - /'
    echo "    参考模板: $TEMPLATE_FILE"
  else
    pass "design.md 章节与模板对齐"
  fi

  # 需求追溯语义锚点：§编号仅用于展示，Gate 只认 anchor: acceptance-traceability（或同义 H2）
  if grep -q 'anchor: acceptance-traceability' "$DESIGN" 2>/dev/null \
     || echo "$PRODUCT_H2" | grep -q '需求追溯'; then
    pass "design.md 需求追溯锚点存在 (acceptance-traceability)"
  else
    p0 "design.md 缺少需求追溯锚点: <!-- anchor: acceptance-traceability -->（章节号仅用于展示，语义锚点为唯一机器契约）"
  fi

  # v3.23.0: 语义锚点契约扩展——data-model / api-contracts / business-rules / implementation-handoff。
  # 前三个为历史必含章节，缺失锚点时按同义 H2 标题回退（兼容在途产物）；实现交接为新增必含节。
  check_semantic_anchor() {
    local anchor="$1" h2pat="$2" label="$3"
    if grep -q "anchor: $anchor" "$DESIGN" 2>/dev/null \
       || echo "$PRODUCT_H2" | grep -qE "$h2pat"; then
      pass "design.md 语义锚点存在: ${anchor}（${label}）"
    else
      p0 "design.md 缺少语义锚点: <!-- anchor: ${anchor} -->（${label}；章节编号仅展示，锚点是 /plan、/build 与评审的定位正本）"
    fi
  }
  check_semantic_anchor "data-model" '数据模型' "数据模型"
  check_semantic_anchor "api-contracts" '接口' "接口契约"
  check_semantic_anchor "business-rules" '业务规则' "业务规则"
  check_semantic_anchor "implementation-handoff" '实现交接' "实现交接（施工图：基线/变更/不变量）"

  # 必含章节（核心，仅单体模式强制——总分模式的章节契约由上方模板对齐检查覆盖）
  if [ "$MODE" = "monolith" ]; then
    REQUIRED=("§1 功能概述" "§2 数据模型" "§3 接口设计" "§4 权限矩阵" "§5 业务规则" "§6 关键流程" "§7 前端页面" "§8 数据库迁移" "§9 验收标准" "§11 需求追溯与覆盖率基线" "§14 实现交接")
    for sec in "${REQUIRED[@]}"; do
      # v3.9.1: 直接在产物 H2 里 grep 该章节前 5 字符（容忍"§6 关键流程（WHEN...）"）
      SEC_PREFIX="${sec:0:5}"
      if ! echo "$PRODUCT_H2" | grep -qF "$SEC_PREFIX"; then
        p0 "design.md 缺少关键章节: $sec"
      fi
    done
  fi
  [ "$FAIL" -eq 0 ] && pass "design.md 关键章节检查通过"
fi

# 模板身份必须写入产物，且精确匹配当前模式对应的模板与版本（v3.16.26 收紧：
# 旧检查只要求出现"模板 ID/模板版本"文字，任意字符串都能混过）。
TPL_ID_EXPECTED="${TEMPLATE_NAME%.md}"
TPL_ID_ACTUAL=$(sed -n 's/^>[[:space:]]*模板 ID[：:]*[[:space:]]*`\(.*\)`[[:space:]]*$/\1/p' "$DESIGN" 2>/dev/null | head -1)
TPL_VER_ACTUAL=$(sed -n 's/^>[[:space:]]*模板版本[：:]*[[:space:]]*`\(.*\)`[[:space:]]*$/\1/p' "$DESIGN" 2>/dev/null | head -1)
TPL_VER_EXPECTED=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p' "$TEMPLATE_FILE" 2>/dev/null | head -1)
if [ "$TPL_ID_ACTUAL" = "$TPL_ID_EXPECTED" ]; then
  pass "design template identity exact: $TPL_ID_ACTUAL (mode=$MODE)"
else
  p0 "design template identity mismatch: expected '$TPL_ID_EXPECTED' (mode=$MODE), got '${TPL_ID_ACTUAL:-empty}'"
fi
if [ -n "$TPL_VER_EXPECTED" ] && [ "$TPL_VER_ACTUAL" = "$TPL_VER_EXPECTED" ]; then
  pass "design template version matches template: $TPL_VER_ACTUAL"
else
  p0 "design template version mismatch: expected '$TPL_VER_EXPECTED', got '${TPL_VER_ACTUAL:-empty}'"
fi

# ---------- FINAL ----------
echo ""
echo "========================================"
echo "P2 RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"
echo "  Total: $TOTAL  COMPLETE: $COMPLETE  Coverage: ${COVERAGE_RATE}%"

STATE_DIR="${STATE_DIR:-.devflow}"
RECEIPT_DIR="$STATE_DIR/${EFF_FEATURE}/gates/P2"
mkdir -p "$RECEIPT_DIR"
EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "VERSION=p2@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "PHASE=P2"
  echo "MODE=$MODE"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  # v3.19.0(P0-3): design.json 绑定进 P2 收据——结构化产物是追溯矩阵/索引的机器事实源，
  # 不入收据则收据与产物可各自漂移（审计重验无锚点）。
  if [ -f "$DESIGN_JSON" ]; then
    echo "ARTIFACTS=$DESIGN,$CRITERIA,$DESIGN_JSON"
    echo "DESIGN_JSON_SHA256=$(shasum -a 256 "$DESIGN_JSON" 2>/dev/null | awk '{print $1}' || sha256sum "$DESIGN_JSON" 2>/dev/null | awk '{print $1}')"
  else
    echo "ARTIFACTS=$DESIGN,$CRITERIA"
  fi
  # v3.20.2(P1-4): 统一收据证据树——此前 DESIGN_JSON_SHA256 无消费者，篡改 design.json
  # 后 audit-receipts 仍 PASS。按 P3b/P6 同款契约绑定 design+criteria+design.json，
  # 审计侧 verify_receipt_evidence 即自动重验（篡改任一文件 → 审计 FAIL）。
  if command -v jq >/dev/null 2>&1; then
    _P2_EV_ARGS=("$DESIGN" "$CRITERIA")
    [ -f "$DESIGN_JSON" ] && _P2_EV_ARGS+=("$DESIGN_JSON")
    # v3.24.0(A02)：收据绑定调查过的源码证据——design.json baseline 中真实存在的
    # 目标文件一并纳入证据树；评审/实现期间源码被改写 → audit-receipts 重验 FAIL。
    if [ -f "$DESIGN_JSON" ] && command -v python3 >/dev/null 2>&1; then
      while IFS= read -r _bl_f; do
        [ -n "$_bl_f" ] && [ -f "$_bl_f" ] && _P2_EV_ARGS+=("$_bl_f")
      done < <(_python3 -c 'import json,sys
try:
    for e in json.load(open(sys.argv[1])).get("baseline", {}).get("entries", []):
        print((e.get("target") or "").split("#", 1)[0].strip())
except Exception:
    pass' "$DESIGN_JSON" 2>/dev/null || true)
    fi
    _P2_EV_TREE=$(receipt_evidence_tree "${_P2_EV_ARGS[@]}")
    if [ -n "$_P2_EV_TREE" ]; then
      _P2_PATHS='['
      _p2_first=1
      for _p2_f in "${_P2_EV_ARGS[@]}"; do
        _p2_one=$(jq -cn --arg p "$_p2_f" '$p' 2>/dev/null) || _p2_one=""
        [ -n "$_p2_one" ] || _p2_one='""'
        [ "$_p2_first" -eq 1 ] || _P2_PATHS="${_P2_PATHS},"
        _P2_PATHS="${_P2_PATHS}${_p2_one}"
        _p2_first=0
      done
      _P2_PATHS="${_P2_PATHS}]"
      echo "EVIDENCE_PATHS_JSON=$_P2_PATHS"
      echo "EVIDENCE_TREE_SHA256=$_P2_EV_TREE"
    fi
  fi
  [ -f "$TC_PATH" ] && echo "CONSTRAINTS_SHA256=$(tc_sha256 "$TC_PATH")"
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN total=$TOTAL complete=$COMPLETE coverage=${COVERAGE_RATE}%"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt"
echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
# v3.9.5: mirror receipt into docs/ (version-controlled evidence; .devflow/ was missing in all 4 audited projects)
DOCS_MIRROR="docs/${EFF_FEATURE}/gates/P2"
if [ "${EFF_FEATURE}" != "default" ]; then
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"
fi

[ "$FAIL" -gt 0 ] && { echo ""; echo "P2 GATE: FAIL (blocking)"; exit 1; }
echo ""
echo "P2 GATE: PASS"
exit 0
