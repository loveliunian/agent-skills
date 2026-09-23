#!/usr/bin/env bash

# : 推导 feature，避免写入 default 目录
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/py_runtime.sh"
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# v3.14.1: 一次性推导；失败（多 state/无 state）即拒绝执行，杜绝 default 目录
EFF_FEATURE="$(devflow_feature "${FEATURE:-}")" || { echo "[FATAL] feature 推导失败，拒绝继续"; exit 2; }
[ -n "$EFF_FEATURE" ] || { echo "[FATAL] feature 为空，拒绝继续"; exit 2; }
# =============================================================================
# P1 工程事实源 Gate (v3.9.1 · 含模板-产物对齐检查)
# =============================================================================
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# v3.30.0: Gate JSON 强制（tech-selection/clarification/constraints 三正本）
source "$SCRIPT_DIR/gate_json_lib.sh"
# shellcheck disable=SC2034  # GJ_SKILL 由 gate_json_lib 函数消费
GJ_SKILL="$SKILL_ROOT"
TEMPLATES_DIR="$SKILL_ROOT/templates"

FAIL=0; PASS=0; WARN=0
p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

# v3.22.0: 文档层中文化——默认 docs/详细设计，存在历史英文目录则回退；显式传参仍优先
source "$SCRIPT_DIR/devflow_paths.sh"
if [ "$#" -ge 1 ] && [ -n "$1" ]; then
  DOC_DIR="$1"
elif [ -d "docs/详细设计" ]; then
  DOC_DIR="docs/详细设计"
elif [ -d "docs/detailed-design" ]; then
  DOC_DIR="docs/detailed-design"
else
  DOC_DIR="docs/详细设计"
fi
DOC_DIR="${DOC_DIR%/}"
# 事实源双语：主目录缺失时到另一历史目录取证（文件名机器契约不翻译）
ALT_DOC_DIR=""
if [ "$DOC_DIR" = "docs/详细设计" ]; then ALT_DOC_DIR="docs/detailed-design"
elif [ "$DOC_DIR" = "docs/detailed-design" ]; then ALT_DOC_DIR="docs/详细设计"; fi

# v3.16.25: P1 必须验证 P0 技术硬约束与设计决策记录，不能只验证事实源。
if [ -n "${TECH_SELECTION_FILE:-}" ]; then
  TECH_REPORT="$TECH_SELECTION_FILE"
else
  TECH_REPORT="$(df_resolve_doc "$EFF_FEATURE" tech_selection .md design)"
  [ -n "$TECH_REPORT" ] || TECH_REPORT="$DOC_DIR/${EFF_FEATURE}-技术选型.md"
fi
if [ -n "${TECH_CONSTRAINTS_FILE:-}" ]; then
  TECH_CONSTRAINTS="$TECH_CONSTRAINTS_FILE"
else
  TECH_CONSTRAINTS="$(df_resolve_doc "$EFF_FEATURE" constraints .md requirements)"
  [ -n "$TECH_CONSTRAINTS" ] || TECH_CONSTRAINTS="docs/需求/${EFF_FEATURE}-技术约束.md"
fi

# BSD bash 不支持 declare -A key 含 . — 用普通数组
FACT_FILES="_commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md"

echo ""
echo "=== §1 7 份事实源存在性 ==="
for fname in $FACT_FILES; do
  f="$DOC_DIR/$fname"
  # v3.22.0: 主目录缺失则查历史目录
  if [ ! -f "$f" ] && [ -n "$ALT_DOC_DIR" ] && [ -f "$ALT_DOC_DIR/$fname" ]; then f="$ALT_DOC_DIR/$fname"; fi
  if [ -f "$f" ]; then
    LINES=$(wc -l < "$f" 2>/dev/null || echo 0)
    if [ "$LINES" -gt 5 ]; then
      pass "$f exists ($LINES lines)"
    else
      p0 "$f too short ($LINES lines)"
    fi
  else
    p0 "$f missing"
  fi
done

# ---------- §1b P1 设计规范基线检查 (v3.27.16 新增) ----------
echo ""
echo "=== §1b P1 设计规范基线 (design-conventions.json) ==="
CONVENTIONS_JSON=".devflow/$EFF_FEATURE/design-conventions.json"

# 检查 design-conventions.json 存在性
if [ -f "$CONVENTIONS_JSON" ]; then
  pass "design-conventions.json exists"
  
  # 验证关键必填字段
  if command -v jq >/dev/null 2>&1; then
    HAS_NAMING=$(jq -e '.naming_conventions' "$CONVENTIONS_JSON" >/dev/null 2>&1 && echo 1 || echo 0)
    HAS_API=$(jq -e '.api_conventions' "$CONVENTIONS_JSON" >/dev/null 2>&1 && echo 1 || echo 0)
    HAS_DATA=$(jq -e '.data_conventions' "$CONVENTIONS_JSON" >/dev/null 2>&1 && echo 1 || echo 0)
    HAS_STATE=$(jq -e '.state_machine_conventions' "$CONVENTIONS_JSON" >/dev/null 2>&1 && echo 1 || echo 0)
    HAS_ERROR=$(jq -e '.error_handling_conventions' "$CONVENTIONS_JSON" >/dev/null 2>&1 && echo 1 || echo 0)

    [ "$HAS_NAMING" = "1" ] && pass "naming_conventions 已定义" || p0 "naming_conventions 缺失"
    [ "$HAS_API" = "1" ] && pass "api_conventions 已定义" || p0 "api_conventions 缺失"
    [ "$HAS_DATA" = "1" ] && pass "data_conventions 已定义" || p0 "data_conventions 缺失"
    [ "$HAS_STATE" = "1" ] && pass "state_machine_conventions 已定义" || p0 "state_machine_conventions 缺失"
    [ "$HAS_ERROR" = "1" ] && pass "error_handling_conventions 已定义" || p0 "error_handling_conventions 缺失"
  else
    warn "jq 未安装，跳过 JSON 结构验证"
  fi
  
  # 运行关键可选字段检查器（建议性，不阻断）
  if [ -x "$SCRIPT_DIR/validate_design_conventions.py" ]; then
    echo ""
    echo "--- 关键可选字段检查（建议性） ---"
    "${DEVFLOW_PY[@]}" "$SCRIPT_DIR/validate_design_conventions.py" "$CONVENTIONS_JSON" || true
  fi
  
  # 运行命名转换规则验证器（如果定义了 case_conversion_rules）
  if [ -x "$SCRIPT_DIR/verify_case_conversion_rules.py" ]; then
    if command -v jq >/dev/null 2>&1 && jq -e '.case_conversion_rules' "$CONVENTIONS_JSON" >/dev/null 2>&1; then
      echo ""
      echo "--- 命名转换规则验证 ---"
      if "${DEVFLOW_PY[@]}" "$SCRIPT_DIR/verify_case_conversion_rules.py" "$CONVENTIONS_JSON"; then
        pass "命名转换规则稳定性验证通过"
      else
        warn "命名转换规则稳定性低，建议检查"
      fi
    fi
  fi
else
  p0 "design-conventions.json missing (应在 P1 阶段产出)"
fi

if [ ! -f "$CONVENTIONS_JSON" ]; then
  p0 "design-conventions.json missing: $CONVENTIONS_JSON (P1 强制冻结设计规范基线)"
else
  pass "design-conventions.json exists: $CONVENTIONS_JSON"
  
  if devflow_py_ok; then
    # 检查必需字段
    REQUIRED_FIELDS="feature_name frozen_at naming_conventions api_conventions data_conventions state_machine_conventions error_handling_conventions"
    for field in $REQUIRED_FIELDS; do
      HAS_FIELD=$("${DEVFLOW_PY[@]}" -c "import json; d=json.load(open('$CONVENTIONS_JSON')); print('$field' in d)" 2>/dev/null || echo "False")
      if [ "$HAS_FIELD" = "True" ]; then
        pass "design-conventions.json has field: $field"
      else
        p0 "design-conventions.json missing required field: $field"
      fi
    done
    
    # 检查 JSON schema 有效性
    SCHEMA_FILE="$SKILL_ROOT/schemas/design-conventions.schema.json"
    if [ -f "$SCHEMA_FILE" ]; then
      VALIDATION_RESULT=$("${DEVFLOW_PY[@]}" -c "
import json, sys
from pathlib import Path
try:
    import jsonschema
except ImportError:
    print('jsonschema not installed, skipping validation')
    sys.exit(0)

schema = json.load(open('$SCHEMA_FILE'))
data = json.load(open('$CONVENTIONS_JSON'))
try:
    jsonschema.validate(data, schema)
    print('validation passed')
    sys.exit(0)
except jsonschema.ValidationError as e:
    print(f'validation failed: {e.message}')
    sys.exit(1)
" 2>&1 || true)
      
      if echo "$VALIDATION_RESULT" | grep -q "validation passed"; then
        pass "design-conventions.json schema validation passed"
      elif echo "$VALIDATION_RESULT" | grep -q "jsonschema not installed"; then
        warn "jsonschema not installed, skipping schema validation"
      else
        p0 "design-conventions.json schema validation failed"
        echo "$VALIDATION_RESULT" | head -10
      fi
    fi
    
    # 检查规范内容完整性
    echo ""
    echo "=== §1c 设计规范内容完整性 ==="
    
    # 表命名规则
    TABLE_PATTERN=$("${DEVFLOW_PY[@]}" -c "import json; d=json.load(open('$CONVENTIONS_JSON')); print(d.get('naming_conventions', {}).get('table_naming', {}).get('pattern', ''))" 2>/dev/null || echo "")
    if [ -n "$TABLE_PATTERN" ]; then
      pass "table naming pattern defined: $TABLE_PATTERN"
    else
      p0 "table naming pattern not defined"
    fi
    
    # API 路由规则
    API_PATTERN=$("${DEVFLOW_PY[@]}" -c "import json; d=json.load(open('$CONVENTIONS_JSON')); print(d.get('api_conventions', {}).get('routing_pattern', ''))" 2>/dev/null || echo "")
    if [ -n "$API_PATTERN" ]; then
      pass "API routing pattern defined: $API_PATTERN"
    else
      p0 "API routing pattern not defined"
    fi
    
    # 状态机处理策略
    STATE_STRATEGY=$("${DEVFLOW_PY[@]}" -c "import json; d=json.load(open('$CONVENTIONS_JSON')); print(d.get('state_machine_conventions', {}).get('storage_strategy', ''))" 2>/dev/null || echo "")
    if [ -n "$STATE_STRATEGY" ]; then
      pass "state machine strategy defined: $STATE_STRATEGY"
    else
      p0 "state machine strategy not defined"
    fi
    
    # 错误处理策略
    ERROR_STRATEGY=$("${DEVFLOW_PY[@]}" -c "import json; d=json.load(open('$CONVENTIONS_JSON')); print(d.get('error_handling_conventions', {}).get('exception_wrapper', ''))" 2>/dev/null || echo "")
    if [ -n "$ERROR_STRATEGY" ]; then
      pass "error handling strategy defined: $ERROR_STRATEGY"
    else
      p0 "error handling strategy not defined"
    fi
    
    # v3.27.16: 关键可选字段检查（使用独立脚本）
    echo ""
    echo "=== §1d 关键可选字段检查 (v3.27.16) ==="
    
    VALIDATE_CONVENTIONS_SCRIPT="$SCRIPT_DIR/validate_design_conventions.py"
    if [ -f "$VALIDATE_CONVENTIONS_SCRIPT" ]; then
      VALIDATE_OUTPUT=$(mktemp -t s1-validate-conv.XXXXXX)
      if "${DEVFLOW_PY[@]}" "$VALIDATE_CONVENTIONS_SCRIPT" "$CONVENTIONS_JSON" > "$VALIDATE_OUTPUT" 2>&1; then
        pass "关键可选字段检查通过"
        # 显示检查摘要
        grep -E '(✅|⚠️|ℹ️)' "$VALIDATE_OUTPUT" | head -5 || true
      else
        warn "关键可选字段检查发现需要补充的字段（不阻断，仅为建议）"
        grep -E '(⚠️)' "$VALIDATE_OUTPUT" | head -10 || true
      fi
      rm -f "$VALIDATE_OUTPUT"
    else
      warn "validate_design_conventions.py not found, skipping optional fields check"
    fi
    
    # v3.27.16: 命名转换规则形式化检查
    echo ""
    echo "=== §1e 命名转换规则形式化验证 (v3.27.16) ==="
    
    VERIFY_CASE_SCRIPT="$SCRIPT_DIR/verify_case_conversion_rules.py"
    if [ -f "$VERIFY_CASE_SCRIPT" ]; then
      HAS_CASE_RULES=$("${DEVFLOW_PY[@]}" -c "import json; d=json.load(open('$CONVENTIONS_JSON')); print('yes' if 'case_conversion_rules' in d else 'no')" 2>/dev/null || echo "no")
      
      if [ "$HAS_CASE_RULES" = "yes" ]; then
        VERIFY_OUTPUT=$(mktemp -t s1-verify-case.XXXXXX)
        if "${DEVFLOW_PY[@]}" "$VERIFY_CASE_SCRIPT" "$CONVENTIONS_JSON" > "$VERIFY_OUTPUT" 2>&1; then
          pass "命名转换规则形式化验证通过"
          grep '稳定性分数' "$VERIFY_OUTPUT" || true
        else
          p0 "命名转换规则验证失败（转换示例不符合 acronyms 策略）"
          grep -E '(❌|错误)' "$VERIFY_OUTPUT" | head -5 || true
          echo "    建议：${DEVFLOW_PY[0]} $VERIFY_CASE_SCRIPT --generate-examples <strategy>"
        fi
        rm -f "$VERIFY_OUTPUT"
      else
        warn "case_conversion_rules not defined - recommend adding for consistent naming conversion"
        echo "    生成示例: ${DEVFLOW_PY[0]} $VERIFY_CASE_SCRIPT --generate-examples uppercase > case_rules.json"
      fi
    fi
    
  else
    warn "python3 not found, skipping design conventions validation"
  fi
fi

if [ ! -f "$CONVENTIONS_JSON" ]; then
  p0 "design-conventions.json missing: $CONVENTIONS_JSON (P1 强制冻结设计规范)"
else
  pass "design-conventions.json exists: $CONVENTIONS_JSON"
  
  # 检查 JSON schema 有效性
  if devflow_py_ok; then
    SCHEMA_FILE="$SKILL_ROOT/schemas/design-conventions.schema.json"
    if [ -f "$SCHEMA_FILE" ]; then
      if "${DEVFLOW_PY[@]}" "$SCRIPT_DIR/validate_json_schema.py" "$CONVENTIONS_JSON" "$SCHEMA_FILE" 2>/dev/null; then
        pass "design-conventions.json schema validation passed"
      else
        p0 "design-conventions.json schema validation failed (check required fields: naming, api_conventions, state_management, error_handling, data_conventions)"
      fi
    else
      warn "design-conventions schema not found: $SCHEMA_FILE"
    fi
  fi
fi

# ---------- §1a 事实源元数据：来源/时点/适用范围（v3.24.0/A14） ----------
# 报告 A14：「事实文件存在不等于调查完成」——每份事实源应声明证据来源、调查时点
# 与适用范围。机器块格式（init-fact-sources.sh 生成的模板已内嵌）：
#   <!-- DEVFLOW:FACT-SOURCE
#   source=<代码走查/DDL/现网查询/人工登记>
#   as_of=<YYYY-MM-DD>
#   scope=<适用模块或全局>
#   -->
# v3.24.0 起为 WARN（存量事实源兼容），P1 输出提示补登记；新项目经 init-fact-sources 生成即自带。
echo ""
echo "=== §1a 事实源元数据（来源/时点/适用范围） ==="
META_MISS=0
for fname in $FACT_FILES; do
  f="$DOC_DIR/$fname"
  if [ ! -f "$f" ] && [ -n "$ALT_DOC_DIR" ] && [ -f "$ALT_DOC_DIR/$fname" ]; then f="$ALT_DOC_DIR/$fname"; fi
  [ -f "$f" ] || continue
  if ! grep -q "DEVFLOW:FACT-SOURCE" "$f" 2>/dev/null; then
    warn "$f 缺事实源元数据块（source/as_of/scope）——事实文件存在不等于调查完成，建议运行 init-fact-sources 或补登记"
    META_MISS=$((META_MISS + 1))
  fi
done
[ "$META_MISS" -eq 0 ] && pass "all fact sources carry source/as_of/scope metadata" || true

# ---------- §1b 技术选型与硬约束契约 ----------
echo ""
echo "=== §1b 设计决策记录与硬约束契约 ==="
for f in "$TECH_CONSTRAINTS" "$TECH_REPORT"; do
  if [ ! -f "$f" ]; then
    p0 "$f missing"
  elif [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -le 5 ]; then
    p0 "$f too short"
  else
    pass "$f exists"
  fi
done

source "$SCRIPT_DIR/tech_constraints_lib.sh"

if [ -f "$TECH_CONSTRAINTS" ]; then
  # 展示层结构（人读表格）仍须存在
  grep -qE 'MUST_USE|MUST_NOT_USE|NONE' "$TECH_CONSTRAINTS" || p0 "technology constraints must declare MUST_USE/MUST_NOT_USE or explicit NONE"
  # NONE 契约（constraint_set=NONE）没有逐条约束表，同样合法
  grep -qE '约束清单|constraint_id|constraint_set' "$TECH_CONSTRAINTS" || p0 "technology constraints table missing"

  # v3.16.26: 机器契约是唯一判定源——缺失即阻断，不从自然语言推断合规
  TC_INVALID=$(mktemp -t s1-tc-inv.XXXXXX)
  if ! tc_validate_constraints "$TECH_CONSTRAINTS" 2> "$TC_INVALID" >/dev/null; then
    while IFS= read -r line; do p0 "$line"; done < "$TC_INVALID"
  else
    pass "technology constraints machine contract valid (all FROZEN + confirmed)"
  fi
  rm -f "$TC_INVALID"

  # v3.16.26: 约束文件 SHA 必须先经 devflow-state.sh constraints-freeze 冻结进 state
  STATE_FILE="${STATE_DIR:-.devflow}/${EFF_FEATURE}.state.json"
  if [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
    FROZEN_TC_SHA=$(jq -r '.scope.tech_constraints_sha256 // empty' "$STATE_FILE" 2>/dev/null || true)
    ACTUAL_TC_SHA=$(tc_sha256 "$TECH_CONSTRAINTS")
    if [ -z "$FROZEN_TC_SHA" ]; then
      p0 "technology constraints not frozen in state — run: devflow-state.sh constraints-freeze $EFF_FEATURE"
    elif [ "$FROZEN_TC_SHA" != "$ACTUAL_TC_SHA" ]; then
      p0 "technology constraints file changed after freeze (state=$FROZEN_TC_SHA actual=$ACTUAL_TC_SHA) — re-freeze via constraints-freeze"
    else
      pass "technology constraints SHA matches state freeze"
    fi
  else
    p0 "state file missing or jq unavailable — cannot verify constraints freeze"
  fi
fi
if [ -f "$TECH_REPORT" ]; then
  grep -qE '决策矩阵' "$TECH_REPORT" || p0 "technology selection report missing decision matrix"
  grep -qE '决策结论' "$TECH_REPORT" || p0 "technology selection report missing decision conclusion"
  grep -qE 'constraint_id|constraint_set' "$TECH_REPORT" || p0 "technology selection report missing constraint bindings"

  # v3.27.7: 详设文档结构（单文档/总分）决策从 P2 上移至 P1——P2 只按冻结结果选模板。
  # 机检行为 df_pipeline 渲染产物；缺机检行的存量手写报告 WARN（限期补登），有行但值非法 FAIL。
  if grep -qE 'design_doc_structure_mode=(monolith|total)' "$TECH_REPORT"; then
    pass "technology selection record carries frozen design doc structure decision (P2 不再重复决策)"
  elif grep -qE '详设文档结构决策' "$TECH_REPORT"; then
    p0 "technology selection report has 详设文档结构决策 section but missing machine line design_doc_structure_mode=monolith|total"
  else
    warn "technology selection report missing 详设文档结构决策（design_doc_structure_mode=monolith|total）——v3.27.7 起文档结构须在 P1 决策，P2 不再做总分/单文档决策；请重跑 tech-selection 管线补登"
  fi

  # v3.27.14：脚手架重合度审计（铁律 18）——tech-selection.json 登记 scaffold_audit 时，
  # 渲染报告必须含《脚手架重合度审计》章节与清单表（防手写/陈旧渲染覆盖结构化产物）。
  TS_JSON="${STATE_DIR:-.devflow}/${EFF_FEATURE}/tech-selection.json"
  if [ -f "$TS_JSON" ] && command -v jq >/dev/null 2>&1 \
     && jq -e '(.scaffold_audit // []) | length > 0' "$TS_JSON" >/dev/null 2>&1; then
    if grep -qF '脚手架重合度审计' "$TECH_REPORT" \
       && grep -qE '\|[[:space:]]*判定（裁剪/复用/新建）[[:space:]]*\|' "$TECH_REPORT"; then
      pass "scaffold overlap audit section rendered (铁律 18)"
    else
      p0 "tech-selection.json 登记了 scaffold_audit，但报告缺《脚手架重合度审计》章节或判定清单表——重跑 df_pipeline.py tech-selection 渲染"
    fi
  fi

  # v3.28.1：规范遵循结构化——tech-selection.json 登记 standards 时，报告必须含《规范遵循》章节
  # （详设 §13 已删除，规范基线唯一正本在设计决策记录）。
  if [ -f "$TS_JSON" ] && command -v jq >/dev/null 2>&1 \
     && jq -e '(.standards // []) | length > 0' "$TS_JSON" >/dev/null 2>&1; then
    if grep -qF '规范遵循' "$TECH_REPORT"; then
      pass "standards section rendered (v3.28.1)"
    else
      p0 "tech-selection.json 登记了 standards，但报告缺《规范遵循》章节——重跑 df_pipeline.py tech-selection 渲染"
    fi
  fi

  # v3.16.26: 用户确认正则修复——LC_ALL=C 下 [^[:alnum:]] 会吞掉多字节汉字，
  # 旧正则曾把"用户确认: 未确认"误判为已确认。现在：正向匹配必须在冒号后直接出现
  # 肯定词；并显式拒绝否定词。
  if grep -qE '用户确认[：:][[:space:]]*(YES|已确认|CONFIRMED|true)' "$TECH_REPORT"; then
    if grep -qE '用户确认[：:][[:space:]]*(未确认|待确认|尚未确认|NOT_CONFIRMED|NO$)' "$TECH_REPORT"; then
      p0 "technology selection report contains negative user confirmation (未确认/待确认)"
    else
      pass "technology selection report has explicit user confirmation"
    fi
  else
    p0 "technology selection report missing explicit user confirmation (用户确认: YES|已确认)"
  fi

  # v3.16.26: 每条 FROZEN 硬约束必须在 P1 报告中有唯一机读绑定且合规（含版本）；
  # MUST_NOT_USE 的 selected_product 含禁用产品即阻断——"未引入 FlowCore"这类描述不再参与判定。
  if [ -f "$TECH_CONSTRAINTS" ]; then
    TC_VIOLATIONS=$(mktemp -t s1-tc-viol.XXXXXX)
    if ! tc_check_compliance "$TECH_CONSTRAINTS" "$TECH_REPORT" > "$TC_VIOLATIONS"; then
      while IFS= read -r line; do [ -n "$line" ] && p0 "$line"; done < "$TC_VIOLATIONS"
    else
      pass "all hard constraints bound and compliant in tech selection report"
    fi
    rm -f "$TC_VIOLATIONS"
  fi
fi

# ---------- §2 (v3.9.1 NEW) 模板-产物对齐检查 ----------
echo ""
echo "=== §2 (v3.9.1 NEW) 模板-产物章节对齐 ==="

# 用文件列表替代 declare -A（兼容 BSD bash）
TMPL_FILES="_commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md"

for tpl in $TMPL_FILES; do
  TPL="$TEMPLATES_DIR/$tpl"
  PROD="$DOC_DIR/$tpl"
  if [ ! -f "$PROD" ] && [ -n "$ALT_DOC_DIR" ] && [ -f "$ALT_DOC_DIR/$tpl" ]; then PROD="$ALT_DOC_DIR/$tpl"; fi

  if [ ! -f "$TPL" ]; then
    warn "template missing: $TPL (skip alignment for $PROD)"
    continue
  fi
  if [ ! -f "$PROD" ]; then
    continue
  fi

  TPL_H2=$(grep -E '^## ' "$TPL" 2>/dev/null | sed 's/^## //' | LC_ALL=C sort)
  PROD_H2=$(cat "$PROD" 2>/dev/null | grep -E '^## ' | sed 's/^## //' | LC_ALL=C sort)

  # v3.9.1: 比例检查（容忍"按功能模块组织"vs"按元数据章节组织"）
  # 规则：产物 H2 数 ≥ 模板 H2 数 × 60%，视为对齐
  TPL_COUNT=$(echo "$TPL_H2" | grep -c . || true)
  PROD_COUNT=$(echo "$PROD_H2" | grep -c . || true)
  if [ "$TPL_COUNT" -gt 0 ] && [ "$PROD_COUNT" -gt 0 ]; then
    RATIO=$(awk -v p="$PROD_COUNT" -v t="$TPL_COUNT" 'BEGIN {printf "%.0f", (p/t)*100}')
    if [ "$PROD_COUNT" -ge "$TPL_COUNT" ]; then
      pass "$PROD 章节数对齐 (tpl=$TPL_COUNT, prod=$PROD_COUNT)"
    elif [ "$RATIO" -ge 60 ]; then
      pass "$PROD 章节数 ≥60% 模板 (tpl=$TPL_COUNT, prod=$PROD_COUNT, ratio=${RATIO}%)"
    else
      p0 "$PROD 章节数不足 (tpl=$TPL_COUNT, prod=$PROD_COUNT, ratio=${RATIO}% < 60%)"
      echo "    参考模板: $TPL"
    fi
  fi
done

# ---------- §3 菜单种子通配符 ----------
echo ""
echo "=== §3 _菜单Seed索引 通配符检查 ==="
MENU_SEED_F="$DOC_DIR/_菜单Seed索引.md"; [ -f "$MENU_SEED_F" ] || MENU_SEED_F="$ALT_DOC_DIR/_菜单Seed索引.md"
if [ -f "$MENU_SEED_F" ]; then
  if grep -E '/\*' "$MENU_SEED_F" >/dev/null 2>&1; then
    p0 "_菜单Seed索引.md 含通配符路径，可能误触发"
  else
    pass "菜单种子无通配符路径冲突"
  fi
fi

echo ""
echo "========================================"
echo "P1 RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"

STATE_DIR="${STATE_DIR:-.devflow}"
# v3.30.0: 三 JSON 正本强制（tech-selection 的 --constraints 对账；缺一阻断）
FEATURE="$EFF_FEATURE"
gj_enforce tech-selection || { echo "[P0] tech-selection JSON 正本未通过"; exit 1; }
gj_enforce clarification || { echo "[P0] clarification JSON 正本未通过"; exit 1; }
gj_enforce constraints || { echo "[P0] constraints JSON 正本未通过"; exit 1; }
RECEIPT_DIR="$STATE_DIR/${EFF_FEATURE}/gates/P1"
mkdir -p "$RECEIPT_DIR"
EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "VERSION=p1@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "PHASE=P1"
  printf '%s' "$GJ_BIND"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "ARTIFACTS=$DOC_DIR/_commons.md,$DOC_DIR/_权限矩阵.md,$DOC_DIR/_环境与账号.md,$DOC_DIR/_菜单Seed索引.md,$DOC_DIR/INDEX-章节锚点.md,$DOC_DIR/INDEX-表.md,$DOC_DIR/INDEX-接口.md,$TECH_CONSTRAINTS,$TECH_REPORT"
  if [ -f "$TECH_CONSTRAINTS" ]; then
    echo "CONSTRAINTS_PATH=$TECH_CONSTRAINTS"
    echo "CONSTRAINTS_SHA256=$(tc_sha256 "$TECH_CONSTRAINTS")"
  fi
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt"
echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
# v3.9.5: mirror receipt into docs/ (version-controlled evidence; .devflow/ was missing in all 4 audited projects)
DOCS_MIRROR="docs/${EFF_FEATURE}/gates/P1"
if [ "${EFF_FEATURE}" != "default" ]; then
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"
fi

[ "$FAIL" -gt 0 ] && { echo ""; echo "P1 GATE: FAIL (blocking)"; exit 1; }
echo ""
echo "P1 GATE: PASS"
exit 0
