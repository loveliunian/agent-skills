#!/usr/bin/env bash

# : 推导 feature，避免写入 default 目录
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# =============================================================================
# P0 验收点冻结 Gate (v3.9.1 · 含模板-产物对齐检查)
# =============================================================================
# 功能：
#   1. (v3.8/v3.22.0) 检查 docs/需求/*-需求澄清.md（中文优先，英文历史路径回退）
#   2. (v3.8) 检查原子验收点格式 Mxx-Fyy-Azz
#   3. (v3.8) 检查 P0 歧义数量 = 0
#   4. (v3.8) 检查无 "待补充" 字样
#   5. (v3.8) 检查验收点分母已冻结
#   6. (v3.8) 生成 Gate 收据到 .devflow/<feature>/gates/P0/receipt.txt
#   7. **(v3.9.1 NEW)** 检查 clarification.md / acceptance-criteria.md 的 H2 章节
#      与 templates/需求澄清-模板.md 的 H2 章节对齐
# =============================================================================
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEMPLATES_DIR="$SKILL_ROOT/templates"
# v3.22.0: 文档层产物中文化（中文优先、英文回退）
source "$SCRIPT_DIR/devflow_paths.sh"

# ---------- 全局计数 ----------
FAIL=0; PASS=0; WARN=0

p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }
# v3.25.2: 收据证据绑定用 SHA-256（与 artifact_gate/P7 同口径）
hash_file() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

# ---------- 参数解析 ----------
FEATURE=""
CRITERIA_PATH=""
CLARIFICATION_PATH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    # v3.15.8: 带值 flag 缺值前置检查（裸 $2 在 set -u 下 unbound 崩溃，报错不友好）
    --criteria) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --criteria requires a non-flag value" >&2; exit 2; }; CRITERIA_PATH="$2"; shift 2 ;;
    --matrix) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --matrix requires a non-flag value" >&2; exit 2; }; CLARIFICATION_PATH="$2"; shift 2 ;;
    --check-only) shift ;;
    --legacy) shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) [ -z "$FEATURE" ] && FEATURE="$1"; shift ;;
  esac
done

if [ -n "$CRITERIA_PATH" ] || [ -n "$CLARIFICATION_PATH" ]; then
  [ -z "$CRITERIA_PATH" ] || [ -z "$CLARIFICATION_PATH" ] && { echo "--criteria and --matrix must be used together" >&2; exit 2; }
else
  [ -z "$FEATURE" ] && { echo "Usage: $0 <feature> | --criteria <p> --matrix <p>"; exit 2; }
fi
EFF_FEATURE="$(devflow_feature "${FEATURE:-}")" || { echo "[FATAL] feature 推导失败，拒绝继续"; exit 2; }
[ -n "$EFF_FEATURE" ] || { echo "[FATAL] feature 为空，拒绝继续"; exit 2; }
# v3.22.0: 未显式传参时解析实际产物（中文优先 docs/需求，回退英文 docs/requirements）
if [ -z "$CLARIFICATION_PATH" ] && [ -z "$CRITERIA_PATH" ]; then
  CLARIFICATION_PATH="$(df_resolve_doc "$EFF_FEATURE" clarification .md requirements)"
  CRITERIA_PATH="$(df_resolve_doc "$EFF_FEATURE" acceptance .md requirements)"
  [ -n "$CLARIFICATION_PATH" ] || CLARIFICATION_PATH="$(df_default_doc "$EFF_FEATURE" clarification .md requirements)"
  [ -n "$CRITERIA_PATH" ] || CRITERIA_PATH="$(df_default_doc "$EFF_FEATURE" acceptance .md requirements)"
fi

# ---------- §0 基础存在性 ----------
echo ""
echo "=== §0 基础产物存在性 ==="
[ -f "$CLARIFICATION_PATH" ] && pass "clarification exists: $CLARIFICATION_PATH" || p0 "clarification missing"
[ -f "$CRITERIA_PATH" ] && pass "acceptance criteria exists: $CRITERIA_PATH" || p0 "acceptance criteria missing"

# ---------- §1 验收点格式 ----------
echo ""
echo "=== §1 原子验收点格式 (Mxx-Fyy-Azz) ==="
TOTAL=0
if [ ! -f "$CRITERIA_PATH" ]; then
  p0 "acceptance criteria file missing, skipping format check"
else
  TOTAL=$(grep -cE 'M-[0-9]+-F[0-9]+-A[0-9]+' "$CRITERIA_PATH" || true)
  if [ "$TOTAL" -eq 0 ]; then
    p0 "no acceptance criteria found (pattern: Mxx-Fyy-Azz)"
  else
    pass "found $TOTAL acceptance criteria"
  fi
fi

# ---------- §1b P0 结构化提取检查 (v3.28.1 新增) ----------
echo ""
echo "=== §1b P0 结构化提取 (entities/operations/constraints) ==="
CLARIFICATION_JSON=".devflow/$EFF_FEATURE/clarification.json"
if [ ! -f "$CLARIFICATION_JSON" ]; then
  p0 "clarification.json missing: $CLARIFICATION_JSON (P0 强制结构化提取)"
else
  pass "clarification.json exists: $CLARIFICATION_JSON"
  
  if command -v python3 >/dev/null 2>&1; then
    # 检查实体数 ≥ 1
    ENTITY_COUNT=$(python3 -c "import json; d=json.load(open('$CLARIFICATION_JSON')); print(len(d.get('entities', [])))" 2>/dev/null || echo "0")
    if [ "$ENTITY_COUNT" -ge 1 ]; then
      pass "entities count = $ENTITY_COUNT (≥ 1)"
    else
      p0 "entities count = $ENTITY_COUNT (must ≥ 1)"
    fi
    
    # 检查操作数 ≥ 1
    OPERATION_COUNT=$(python3 -c "import json; d=json.load(open('$CLARIFICATION_JSON')); print(len(d.get('operations', [])))" 2>/dev/null || echo "0")
    if [ "$OPERATION_COUNT" -ge 1 ]; then
      pass "operations count = $OPERATION_COUNT (≥ 1)"
    else
      p0 "operations count = $OPERATION_COUNT (must ≥ 1)"
    fi
    
    # 检查约束（可为空，但必须显式声明）
    CONSTRAINT_COUNT=$(python3 -c "import json; d=json.load(open('$CLARIFICATION_JSON')); print(len(d.get('constraints', [])))" 2>/dev/null || echo "0")
    pass "constraints count = $CONSTRAINT_COUNT"
    
    # 检查 JSON schema 有效性
    SCHEMA_FILE="$SKILL_ROOT/schemas/clarification.schema.json"
    if [ -f "$SCHEMA_FILE" ]; then
      VALIDATE_SCRIPT="$SCRIPT_DIR/validate_json_schema.py"
      if [ -f "$VALIDATE_SCRIPT" ]; then
        if python3 "$VALIDATE_SCRIPT" "$CLARIFICATION_JSON" "$SCHEMA_FILE" 2>/dev/null; then
          pass "clarification.json schema validation passed"
        else
          p0 "clarification.json schema validation failed (check feature_name, prd_path, entities≥1, operations≥1)"
        fi
      else
        # 回退到内联验证
        VALIDATION_RESULT=$(python3 -c "
import json, sys
from pathlib import Path
try:
    import jsonschema
except ImportError:
    print('jsonschema not installed, skipping validation')
    sys.exit(0)

schema = json.load(open('$SCHEMA_FILE'))
data = json.load(open('$CLARIFICATION_JSON'))
try:
    jsonschema.validate(data, schema)
    print('validation passed')
    sys.exit(0)
except jsonschema.ValidationError as e:
    print(f'validation failed: {e.message}')
    sys.exit(1)
" 2>&1 || true)
        
        if echo "$VALIDATION_RESULT" | grep -q "validation passed"; then
          pass "clarification.json schema validation passed"
        elif echo "$VALIDATION_RESULT" | grep -q "jsonschema not installed"; then
          warn "jsonschema not installed, skipping schema validation"
        else
          p0 "clarification.json schema validation failed"
          echo "$VALIDATION_RESULT" | head -10
        fi
      fi
    fi
  else
    warn "python3 not found, skipping structured extraction check"
  fi
fi

# ---------- §2 歧义检查 ----------
if [ ! -f "$CRITERIA_PATH" ]; then
  warn "skip format check: criteria missing"
else
  ATOMIC_IDS=$(grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$CRITERIA_PATH" 2>/dev/null | sort -u)
  TOTAL=$(printf '%s\n' "$ATOMIC_IDS" | grep -c . || true)
  UNIQUE=$(printf '%s\n' "$ATOMIC_IDS" | sort -u | grep -c . || true)
  if [ "$TOTAL" -gt 0 ]; then
    pass "atomic acceptance points: $TOTAL"
    INVALID=$(grep -oE 'M-?[0-9]{1,2}-F[0-9]{1,2}-A[0-9]{1,2}' "$CRITERIA_PATH" 2>/dev/null \
      | grep -vE '^M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}$' | grep -c . || true)
    [ "$INVALID" -gt 0 ] && p0 "invalid acceptance format found: $INVALID" || pass "all acceptance IDs match Mxx-Fyy-Azz"
    [ "$TOTAL" -eq "$UNIQUE" ] && pass "acceptance IDs are unique: $UNIQUE/$TOTAL" || p0 "duplicates: $((TOTAL-UNIQUE))"
  else
    p0 "no atomic acceptance points found"
  fi
fi

# ---------- §1b 结构化产物层 acceptance.json（v3.25.2 · 失败关闭） ----------
# SKILL.md「全阶段结构化产物」契约的 P0 落地：JSON 缺失/校验失败/与 Markdown 分母
# 不一致，任一即 P0——Markdown 与 JSON 互为双正本的矛盾在进 Gate 前拦截（A03 同款）。
echo ""
echo "=== §1b 结构化产物层 (acceptance.json + clarification.json) ==="
STATE_DIR_EARLY="${STATE_DIR:-.devflow}"
ACCEPTANCE_JSON="${STATE_DIR_EARLY}/${EFF_FEATURE}/acceptance.json"
CLARIFICATION_JSON="${STATE_DIR_EARLY}/${EFF_FEATURE}/clarification.json"

# ---------- §1b-1 实体/操作提取稳定性检查（v3.27.16 新增） ----------
if [ -f "$CLARIFICATION_JSON" ]; then
  # 检查是否存在历史版本（用于稳定性对比）
  CLARIFICATION_BASELINE="${STATE_DIR_EARLY}/${EFF_FEATURE}/clarification.baseline.json"
  
  if [ -f "$CLARIFICATION_BASELINE" ]; then
    echo ""
    echo "--- 实体/操作提取稳定性对比 ---"
    if [ -x "$SCRIPT_DIR/compare_entity_extraction.py" ]; then
      if python3 "$SCRIPT_DIR/compare_entity_extraction.py" "$CLARIFICATION_BASELINE" "$CLARIFICATION_JSON" 2>/dev/null; then
        pass "实体/操作提取稳定（差异 < 10%）"
      else
        warn "实体/操作提取稳定性低（差异 >= 10%），建议人工 Review"
        # 不阻断，仅警告
      fi
    fi
  else
    # 首次提取，创建 baseline
    if [ -w "$(dirname "$CLARIFICATION_BASELINE")" ]; then
      cp "$CLARIFICATION_JSON" "$CLARIFICATION_BASELINE" 2>/dev/null || true
      pass "首次提取，已创建 baseline: clarification.baseline.json"
    fi
  fi
fi

if [ ! -f "$ACCEPTANCE_JSON" ]; then
  p0 "acceptance.json 缺失: ${ACCEPTANCE_JSON}——P0 必须产出结构化验收点（契约 schemas/acceptance.schema.json，管线 df_pipeline.py acceptance，见 phases/00-需求澄清.md §结构化产物层）"
elif ! command -v python3 >/dev/null 2>&1; then
  p0 "acceptance.json 存在但 python3 不可用——结构化校验无法执行（失败关闭）: $ACCEPTANCE_JSON"
else
  if (unset LC_ALL; python3 "$SKILL_ROOT/scripts/df_validate.py" --kind acceptance \
      --input "$ACCEPTANCE_JSON" --workspace . >/dev/null 2>&1); then
    pass "acceptance.json 校验通过（schema + 全部 FROZEN + PRD 来源）"
  else
    (unset LC_ALL; python3 "$SKILL_ROOT/scripts/df_validate.py" --kind acceptance \
      --input "$ACCEPTANCE_JSON" --workspace . 2>&1 | head -5 | sed 's/^/    /')
    p0 "acceptance.json 校验失败——修复后重跑 df_pipeline.py acceptance 再过 Gate"
  fi
  # JSON ↔ Markdown 冻结分母集合全等（双正本对账）
  SET_OUT=$(mktemp -t s0set.XXXXXX)
  if (unset LC_ALL; python3 - "$ACCEPTANCE_JSON" "$CRITERIA_PATH" >"$SET_OUT" 2>&1 <<'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
jids = sorted({p.get("id") for p in d.get("points", [])})
mids = sorted(set(re.findall(r"M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}", open(sys.argv[2], encoding="utf-8", errors="replace").read())))
if jids != mids:
    print(f"JSON={jids[:5]}… Markdown={mids[:5]}…")
    sys.exit(1)
PYEOF
  ); then
    pass "acceptance.json 与 Markdown 冻结分母集合全等"
  else
    p0 "acceptance.json 验收点集合与 Markdown 冻结分母不一致（双正本必须全等）:"
    sed 's/^/    /' "$SET_OUT"
  fi
  rm -f "$SET_OUT"
fi

# ---------- §2 P0 歧义数 (v3.9.1: regex 收紧到表格行) ----------
echo ""
echo "=== §2 P0 歧义数 ==="
P0_AMBIG=0
if [ -f "$CLARIFICATION_PATH" ]; then
  # v3.9.1: 只匹配表格行 `| P0 | ... | 待澄清|未澄清|延后`
  P0_AMBIG=$(grep -E '^\|[[:space:]]*P0[[:space:]]*\|[[:space:]]*[^|]*[[:space:]]*\|' "$CLARIFICATION_PATH" 2>/dev/null \
    | grep -ciE '待澄清|未澄清|延后|TBD|待补充' || true)
  # v3.9.1: 同样扫描 P1/P2 中提到的 P0 状态
  P0_STATUS_BAD=$(grep -E '^\|[[:space:]]*P0[[:space:]]*\|' "$CLARIFICATION_PATH" 2>/dev/null \
    | grep -cvE '已澄清|✅|已解决' || true)
  EFFECTIVE_P0_AMBIG=$((P0_AMBIG + P0_STATUS_BAD))
  if [ "$EFFECTIVE_P0_AMBIG" -gt 0 ]; then
    p0 "P0 未澄清数 = $EFFECTIVE_P0_AMBIG (must be 0)"
    grep -E '^\|[[:space:]]*P0[[:space:]]*\|' "$CLARIFICATION_PATH" 2>/dev/null | head -5 | sed 's/^/    /'
  else
    pass "P0 未澄清数 = 0"
  fi
fi

# ---------- §3 占位符 ----------
echo ""
echo "=== §3 占位符 ==="
PLACEHOLDERS=0
for f in "$CLARIFICATION_PATH" "$CRITERIA_PATH"; do
  [ -f "$f" ] || continue
  COUNT=$(grep -iE '待补充|TODO|FIXME|TBD|REPLACE_WITH|暂定' "$f" 2>/dev/null | grep -c . || true)
  if [ "$COUNT" -gt 0 ]; then
    p0 "placeholder found in $(basename "$f"): $COUNT"
    grep -inE '待补充|TODO|FIXME|TBD|REPLACE_WITH' "$f" 2>/dev/null | head -3 | sed 's/^/    /'
    PLACEHOLDERS=$((PLACEHOLDERS + COUNT))
  fi
done
[ "$PLACEHOLDERS" -eq 0 ] && pass "no placeholders"

# ---------- §4 分母冻结 ----------
echo ""
echo "=== §4 验收点分母冻结 ==="
if [ -f "$CRITERIA_PATH" ]; then
  TOTAL_LINE=$(grep -iE '总计|分母|合计.*验收点|验收点.*合计|分母已冻结|冻结分母' "$CRITERIA_PATH" 2>/dev/null | tail -1)
  if [ -n "$TOTAL_LINE" ]; then
    DENOM=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+' | tail -1)
    if [ -n "$DENOM" ] && [ "$DENOM" -gt 0 ]; then
      pass "denominator frozen: $DENOM"
    else
      p0 "denominator not frozen: $TOTAL_LINE"
    fi
  else
    p0 "no denominator line found"
  fi
fi

# ---------- §5 (v3.9.1 NEW) 模板-产物对齐检查 ----------
echo ""
echo "=== §5 (v3.9.1 NEW) 模板-产物章节对齐 ==="

TEMPLATE_FILE="$TEMPLATES_DIR/需求澄清-模板.md"
if [ ! -f "$TEMPLATE_FILE" ]; then
  warn "skip template alignment: template not found at $TEMPLATE_FILE"
else
  TEMPLATE_H2=$(grep -E '^## ' "$TEMPLATE_FILE" 2>/dev/null | sed 's/^## //' | sort)
  PRODUCT_H2=$(cat "$CLARIFICATION_PATH" 2>/dev/null | grep -E '^## ' | sed 's/^## //' | sort)

  # v3.9.1: 整行比较 + 别名映射（中文 substr 多字节 bug 规避）
  TEMPLATE_H2_NORMALIZED=$(printf '%s\n' "$TEMPLATE_H2" \
    | sed 's/^[^a-zA-Z§0-9]*[0-9]\+\. //' \
    | LC_ALL=C sort)
  PRODUCT_H2_NORMALIZED=$(printf '%s\n' "$PRODUCT_H2" \
    | sed 's/^歧义说明/模糊点/' \
    | sed 's/^歧义$/模糊点/' \
    | LC_ALL=C sort)

  MISSING_IN_PRODUCT=$(comm -23 <(printf '%s\n' "$TEMPLATE_H2_NORMALIZED") <(printf '%s\n' "$PRODUCT_H2_NORMALIZED") | grep -v '^$' | head -5)
  MISSING_COUNT=$(echo "$MISSING_IN_PRODUCT" | grep -c . || true)

  if [ "$MISSING_COUNT" -gt 0 ]; then
    p0 "产物 $CLARIFICATION_PATH 缺少模板章节 ($MISSING_COUNT 个):"
    echo "$MISSING_IN_PRODUCT" | sed 's/^/    - /'
    echo "    参考模板: $TEMPLATE_FILE"
  else
    pass "clarification.md 章节与模板对齐"
  fi

  # acceptance-criteria.md 最小必需章节
  PRODUCT_CRITERIA_H2=$(cat "$CRITERIA_PATH" 2>/dev/null | grep -E '^## ' | sed 's/^## //' | sort)
  # v3.9.1: OR 逻辑 — 验收点分母 / 验收清单 / 基本信息 任一即可
  if echo "$PRODUCT_CRITERIA_H2" | grep -qE '基本|验|用例'; then
    pass "acceptance-criteria.md 含验收相关章节"
  else
    p0 "acceptance-criteria.md 缺少验收相关章节（必须含'基本'/'验'/'用例'之一）"
  fi
fi

# ---------- §6 技术硬约束冻结 (v3.16.26) ----------
echo ""
echo "=== §6 技术硬约束冻结 ==="
if [ -n "${TECH_CONSTRAINTS_FILE:-}" ]; then
  TC_PATH="$TECH_CONSTRAINTS_FILE"
else
  TC_PATH="$(df_resolve_doc "$EFF_FEATURE" constraints .md requirements)"
  [ -n "$TC_PATH" ] || TC_PATH="$(df_default_doc "$EFF_FEATURE" constraints .md requirements)"
fi
source "$SCRIPT_DIR/tech_constraints_lib.sh"
if [ ! -f "$TC_PATH" ]; then
  p0 "technology constraints missing: $TC_PATH (P0 必须冻结硬约束；无约束也须写 constraint_set=NONE 契约块)"
else
  pass "technology constraints exists: $TC_PATH"
  TC_INVALID=$(mktemp -t s0-tc-inv.XXXXXX)
  if ! tc_validate_constraints "$TC_PATH" 2> "$TC_INVALID" >/dev/null; then
    while IFS= read -r line; do p0 "$line"; done < "$TC_INVALID"
  else
    pass "technology constraints machine contract valid (FROZEN + confirmed)"
  fi
  rm -f "$TC_INVALID"
  TC_SHA=$(tc_sha256 "$TC_PATH")
  echo "  constraints_sha256=$TC_SHA"
fi

# ---------- §7 权限码三方对账 (v3.21.0 · L-P0-001 · perm_reconcile_lib) ----------
echo ""
echo "=== §7 权限码三方对账 (Lesson L-P0-001) ==="
# v3.21.0: 抽取 perm_reconcile_lib 共享库（与 artifact_gate P0b 同库同口径，机检前移）——
# (1) 双格式归一：此前仅认 perm: 前缀，真实矩阵（generate-permission-matrix.sh）为
#     反引号三段式，提取恒空 → 对账空转（治理服务复盘发现）；
# (2) 缺矩阵 warn → P0（声明式豁免：澄清文档声明 权限矩阵=not-applicable）；
# (3) 可选第三方菜单 Seed 索引（seed ⊆ matrix）。
# `|| true`：p0() 计数已入 FAIL，返回码仅防未来 set -e 误传播。
source "$SCRIPT_DIR/perm_reconcile_lib.sh"
# v3.22.0: 事实源目录双语（docs/详细设计 优先，回退 docs/detailed-design）；文件名是机器 grep 契约不翻译
PERM_MATRIX="docs/详细设计/_权限矩阵.md"; [ -f "$PERM_MATRIX" ] || PERM_MATRIX="docs/detailed-design/_权限矩阵.md"
MENU_SEED="docs/详细设计/_菜单Seed索引.md"; [ -f "$MENU_SEED" ] || MENU_SEED="docs/detailed-design/_菜单Seed索引.md"
perm_reconcile_three_way "$PERM_MATRIX" "$CLARIFICATION_PATH" "$MENU_SEED" || true

# ---------- §7b 排除条款对账 (v3.21.0 · 排除条款一等需求) ----------
echo ""
echo "=== §7b 排除条款对账 ==="
# PRD 的「排除条款」（不走/除外/手动输入…）与包含条款同为一级需求：必须落为排除性
# 验收点（治理服务事故：PRD M-02 F03 明确三类不走命名规则，生成链仍强制命名配置
# → ENTITY_CONFIG_NOT_FOUND）。豁免：验收点已覆盖排除场景，或澄清文档显式声明
# 「无排除条款」。误报降噪阀门：p0 → warn 一行降级（当前保持 P0 强制）。
EXCL_PAT='不走|除外|手动输入|不通过|无需|不在范围内'
EXCL_HITS=$(grep -cE "$EXCL_PAT" "$CLARIFICATION_PATH" 2>/dev/null || true)
case "${EXCL_HITS:-0}" in ''|*[!0-9]*) EXCL_HITS=0 ;; esac
if [ "$EXCL_HITS" -gt 0 ]; then
  if [ -f "$CRITERIA_PATH" ] && grep -qE "$EXCL_PAT" "$CRITERIA_PATH" 2>/dev/null; then
    pass "排除类表述 ${EXCL_HITS} 处，验收点已有排除场景覆盖"
  elif grep -q '无排除条款' "$CLARIFICATION_PATH" 2>/dev/null; then
    pass "explicit 无排除条款 declaration"
  else
    p0 "PRD/澄清出现排除类表述 ${EXCL_HITS} 处，但验收点无排除场景覆盖且无「无排除条款」声明——排除条款是一等需求，必须落为验收点或显式豁免"
  fi
else
  pass "未出现排除类语言（无需排除条款对账）"
fi

# ---------- FINAL ----------
echo ""
echo "========================================"
echo "P0 RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"

STATE_DIR="${STATE_DIR:-.devflow}"
RECEIPT_DIR="$STATE_DIR/${EFF_FEATURE}/gates/P0"
mkdir -p "$RECEIPT_DIR"
EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "VERSION=p0@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "PHASE=P0"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "ARTIFACTS=$CRITERIA_PATH,$CLARIFICATION_PATH,$ACCEPTANCE_JSON"
  # v3.25.2(P1-a): 结构化正本绑定——篡改 acceptance.json 后 audit 证据重验即 FAIL
  if [ -f "$ACCEPTANCE_JSON" ]; then
    echo "ACCEPTANCE_JSON=$ACCEPTANCE_JSON"
    echo "ACCEPTANCE_JSON_SHA256=$(hash_file "$ACCEPTANCE_JSON")"
  else
    echo "ACCEPTANCE_JSON=missing"
  fi
  echo "CONSTRAINTS_PATH=$TC_PATH"
  [ -f "$TC_PATH" ] && echo "CONSTRAINTS_SHA256=$(tc_sha256 "$TC_PATH")" || echo "CONSTRAINTS_SHA256=missing"
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN total=${TOTAL:-0}"
  echo "EXCL_HITS=${EXCL_HITS:-0}"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt"
echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
# v3.9.5: mirror receipt into docs/ (version-controlled evidence; .devflow/ was missing in all 4 audited projects)
DOCS_MIRROR="docs/${EFF_FEATURE}/gates/P0"
if [ "${EFF_FEATURE}" != "default" ]; then
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"
fi

[ "$FAIL" -gt 0 ] && { echo ""; echo "P0 GATE: FAIL (blocking)"; exit 1; }
echo ""
echo "P0 GATE: PASS"
exit 0
