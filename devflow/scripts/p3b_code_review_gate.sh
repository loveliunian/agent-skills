#!/usr/bin/env bash
# =============================================================================
# P3b 代码审查 Gate (版本随 SKILL.md)
# =============================================================================
# 功能：
#   1. 代码审查报告存在
#   2. 角色分离：审查者 ≠ 开发者
#   3. P0 问题 = 0
#   4. P1 问题 ≤ 5
#   5. §9 验收点覆盖率 = 100%（详设中每个验收点在代码中有对应实现）
#   6. 无 TODO/FIXME 残留
#   7. 架构陷阱 = 0（调用 check-arch-pitfalls.sh）
# =============================================================================
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

FAIL=0; PASS=0; WARN=0
P3B_STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

FEATURE="${1:-}"
SERVICE="${2:-}"
[ -z "$FEATURE" ] && { echo "Usage: $0 <feature> [service]"; exit 2; }
# v3.15.5: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 写穿项目外）与 grep -E 正则注入
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
devflow_feature_validate "$FEATURE" || exit 2
# v3.16.0: 统一收据契约共享库（complete/reconcile/audit-receipts 共用校验函数）
source "$(cd "$(dirname "$0")" && pwd)/devflow_receipt.sh"

# v3.16.0（P0-2）: SERVICE 不再依赖可省略的位置参数静默跳过 TODO 检查——
# 省略时从 backend/*/src/main/java 目录推导：唯一服务 → 用之；0 个或多个 → P0 阻断
if [ -z "$SERVICE" ]; then
  _svc_count=0
  for _main in backend/*/src/main/java; do
    [ -d "$_main" ] && _svc_count=$((_svc_count + 1))
  done
  if [ "$_svc_count" -eq 1 ]; then
    for _main in backend/*/src/main/java; do
      if [ -d "$_main" ]; then SERVICE=$(basename "${_main%/src/main/java}"); break; fi
    done
    pass "service auto-derived from single backend service: $SERVICE"
  elif [ "$_svc_count" -eq 0 ]; then
    p0 "service 未指定且 backend/ 下无 *\/src/main/java 目录——TODO/FIXME 扫描范围无法确定（拒绝静默跳过）"
  else
    p0 "service 未指定且 backend/ 下有 $_svc_count 个服务目录——多服务必须显式传入 <service>（拒绝静默跳过）"
  fi
fi

# v3.22.0: 文档层中文化（中文优先、英文回退）
source "$(cd "$(dirname "$0")" && pwd)/devflow_paths.sh"
REPORT_PATH="$(df_resolve_doc "$FEATURE" code_review_report .md review)"
[ -n "$REPORT_PATH" ] || REPORT_PATH="docs/review/${FEATURE}-code-review-report.md"
DESIGN_PATH="$(df_resolve_doc "$FEATURE" design .md design)"
[ -n "$DESIGN_PATH" ] || DESIGN_PATH="docs/detailed-design/${FEATURE}-design.md"
CRITERIA_PATH="$(df_resolve_doc "$FEATURE" acceptance .md requirements)"
[ -n "$CRITERIA_PATH" ] || CRITERIA_PATH="docs/requirements/${FEATURE}-acceptance-criteria.md"
# v3.16.11（P1-4）: SERVICE 白名单 = backend 真实服务目录名集合——封堵
# 路径穿越（PoC：传入 ../clean → 扫描 backend/../clean/src/main/java，
# 真实服务的 TODO 被绕过，P3B_EXIT=0）。SERVICE 必须是 backend/*/src/main/java
# 的真实目录名（无 /、无 ..、词法归一后落在 backend/ 内）
_ALL_SVCS=$(for _main in backend/*/src/main/java; do
  [ -d "$_main" ] || continue
  basename "${_main%/src/main/java}"
done | LC_ALL=C sort -u)
if [ -n "$SERVICE" ]; then
  case "$SERVICE" in
    */*|*..*|.*|"")
      p0 "service 含路径成分（穿越/隐藏目录）: ${SERVICE}——service 须为 backend 下真实服务目录名"
      ;;
    *)
      if printf '%s\n' "$_ALL_SVCS" | grep -qxF "$SERVICE"; then
        pass "service 在 backend 白名单内: $SERVICE"
      else
        p0 "service 不在 backend 真实服务集合内: ${SERVICE}（实测集合: $(printf '%s ' $_ALL_SVCS)）"
      fi
      ;;
  esac
fi

# ---------- §0 基础存在性 ----------
echo ""
echo "=== §0 基础产物存在性 ==="
[ -f "$REPORT_PATH" ] && pass "code review report exists: $REPORT_PATH" || p0 "code review report missing"
[ -f "$DESIGN_PATH" ] && pass "design exists: $DESIGN_PATH" || p0 "design missing"

if [ "$FAIL" -gt 0 ]; then exit 1; fi

# ---------- §1 角色分离检查（v3.16.0 结构化字段） ----------
echo ""
echo "=== §1 角色分离（结构化字段：DEVELOPER_ID ≠ REVIEWER_ID）==="
# v3.16.0（P0-2）: 旧实现比较两条完整文本行——"开发者: alice" ≠ "审查者: alice" 恒成立，
# 同人自签 PoC 直接 PASS。改为解析结构化身份字段：
#   DEVELOPER_ID=<id> / REVIEWER_ID=<id> / REVIEW_SESSION_ID=<id>
# 缺失或相等必须阻断（缺失不再 WARN 放行——防"报告不写角色字段即可绕过隔离"）。
DEVELOPER_ID=$(sed -n 's/^[[:space:]]*DEVELOPER_ID[[:space:]]*[:=][[:space:]]*//p' "$REPORT_PATH" 2>/dev/null | head -1 | tr -d '[:space:]')
REVIEWER_ID=$(sed -n 's/^[[:space:]]*REVIEWER_ID[[:space:]]*[:=][[:space:]]*//p' "$REPORT_PATH" 2>/dev/null | head -1 | tr -d '[:space:]')
REVIEW_SESSION_ID=$(sed -n 's/^[[:space:]]*REVIEW_SESSION_ID[[:space:]]*[:=][[:space:]]*//p' "$REPORT_PATH" 2>/dev/null | head -1 | tr -d '[:space:]')

if [ -z "$DEVELOPER_ID" ] || [ -z "$REVIEWER_ID" ]; then
  p0 "role isolation fields missing: DEVELOPER_ID/REVIEWER_ID must be declared in report（v3.16.0 起缺失即阻断，不再 WARN 放行）"
elif [ "$(printf '%s' "$DEVELOPER_ID" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$REVIEWER_ID" | tr '[:upper:]' '[:lower:]')" ]; then
  p0 "role conflict: DEVELOPER_ID = REVIEWER_ID = ${DEVELOPER_ID}（同人自签）"
elif [ -z "$REVIEW_SESSION_ID" ]; then
  p0 "REVIEW_SESSION_ID missing（审查会话不可追溯）"
else
  pass "role separation OK: developer=$DEVELOPER_ID reviewer=$REVIEWER_ID (session=$REVIEW_SESSION_ID)"
fi

# ---------- §2 P0 问题 = 0 ----------
echo ""
echo "=== §2 P0 问题 = 0 ==="
# v3.16.21（P0）：只把结构化 FINDING 行或带编号的旧格式 finding 当作问题。
# 标题、统计、结论和说明文字不再参与计数；旧格式若未带 STATUS 仍 fail-closed。
P0_FINDING_LINES=$(grep -E '^[[:space:]]*FINDING[[:space:]]*\|[[:space:]]*P0[[:space:]]*\||(^|[^A-Za-z0-9])P0-[0-9]+([^0-9]|$)' "$REPORT_PATH" 2>/dev/null || true)
P0_COUNT=$(printf '%s\n' "$P0_FINDING_LINES" | grep -c . || true)
P0_OPEN_LINES=0; P0_CLOSED_LINES=0; P0_BAD_STATUS=0
while IFS= read -r _p0_line; do
  [ -n "$_p0_line" ] || continue
  if printf '%s' "$_p0_line" | grep -qiE '(^|[^A-Za-z])STATUS[=:][[:space:]]*CLOSED([^A-Za-z]|$)'; then
    P0_CLOSED_LINES=$((P0_CLOSED_LINES + 1))
  elif printf '%s' "$_p0_line" | grep -qiE '(^|[^A-Za-z])STATUS[=:][[:space:]]*OPEN([^A-Za-z]|$)'; then
    P0_OPEN_LINES=$((P0_OPEN_LINES + 1))
  else
    P0_BAD_STATUS=$((P0_BAD_STATUS + 1))
  fi
done <<EOF
$P0_FINDING_LINES
EOF
P0_FORMAT_BAD=$(awk -F'|' '
  tolower($1) ~ /^[[:space:]]*finding[[:space:]]*$/ && tolower($2) ~ /^[[:space:]]*p0[[:space:]]*$/ {
    if ($1 !~ /^[[:space:]]*FINDING[[:space:]]*$/ || $2 !~ /^[[:space:]]*P0[[:space:]]*$/ ||
        NF < 5 || $3 !~ /^[[:space:]]*P0-[0-9]+[[:space:]]*$/ ||
        $4 !~ /^[[:space:]]*STATUS=(OPEN|CLOSED)[[:space:]]*$/ ||
        $5 ~ /^[[:space:]]*$/) print
  }
' "$REPORT_PATH" 2>/dev/null || true)
P0_DUP_IDS=$(awk -F'|' '
  tolower($1) ~ /^[[:space:]]*finding[[:space:]]*$/ && tolower($2) ~ /^[[:space:]]*p0[[:space:]]*$/ { id=$3; gsub(/[[:space:]]/, "", id); n[id]++ }
  END { for (id in n) if (n[id] > 1) print id }
' "$REPORT_PATH" 2>/dev/null | LC_ALL=C sort || true)
P0_FORMAT_BAD_COUNT=$(printf '%s\n' "$P0_FORMAT_BAD" | grep -c . || true)
P0_DUP_COUNT=$(printf '%s\n' "$P0_DUP_IDS" | grep -c . || true)
[ "$P0_FORMAT_BAD_COUNT" -eq 0 ] || p0 "P0 structured finding format invalid: $P0_FORMAT_BAD_COUNT row(s)"
[ "$P0_DUP_COUNT" -eq 0 ] || p0 "duplicate P0 finding IDs: $P0_DUP_IDS"
if [ "$P0_COUNT" -eq 0 ]; then
  pass "P0 issues closed: 0/0"
elif [ "$P0_OPEN_LINES" -eq 0 ] && [ "$P0_BAD_STATUS" -eq 0 ] && [ "$P0_CLOSED_LINES" -eq "$P0_COUNT" ]; then
  pass "P0 issues closed: $P0_CLOSED_LINES/$P0_COUNT"
else
  p0 "P0 issues unclosed or missing structured CLOSED status: open=$P0_OPEN_LINES bad_status=$P0_BAD_STATUS total=$P0_COUNT"
fi

# ---------- §3 P1 问题 ≤ 5 ----------
echo ""
echo "=== §3 P1 问题 ≤ 5 ==="
# v3.14.11-fix(jmmp2): P1 同样需要排除否定/计数语境行——"P1 问题 | 4（均已闭环）"与"≤5（共 4 项）"
# 此前仅对 P0 做过否定排除（v3.9.6），P1 行级计数把表格统计行/结论行一并计入导致误报超限
P1_COUNT=$(grep -iE 'P1.*问题|P1-[0-9]' "$REPORT_PATH" 2>/dev/null \
  | grep -civE '无|没有|zero|≤[[:space:]]*5|(\||：|:)[[:space:]]*[0-9]|共[[:space:]]*[0-9]+[[:space:]]*项|问题[：:][[:space:]]*0' || true)
if [ "$P1_COUNT" -le 5 ]; then
  pass "P1 issues ≤ 5: $P1_COUNT"
else
  p0 "P1 issues > 5: $P1_COUNT"
fi

# ---------- §4 §9 验收点覆盖率 = 100% ----------
echo ""
echo "=== §4 §9 验收点覆盖率 = 100% ==="
if [ -f "$CRITERIA_PATH" ] && [ -f "$DESIGN_PATH" ]; then
  CRITERIA_ID_LIST=$(grep -oE 'M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$CRITERIA_PATH" 2>/dev/null | LC_ALL=C sort -u || true)
  REPORT_ID_LIST=$(grep -oE 'M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$REPORT_PATH" 2>/dev/null | LC_ALL=C sort -u || true)
  P0_IDS=$(printf '%s\n' "$CRITERIA_ID_LIST" | grep -c . || true)
  REPORT_IDS=$(printf '%s\n' "$REPORT_ID_LIST" | grep -c . || true)
  ID_MISSING=$(comm -23 <(printf '%s\n' "$CRITERIA_ID_LIST") <(printf '%s\n' "$REPORT_ID_LIST") | grep -c . || true)
  ID_EXTRA=$(comm -13 <(printf '%s\n' "$CRITERIA_ID_LIST") <(printf '%s\n' "$REPORT_ID_LIST") | grep -c . || true)
  if [ "$P0_IDS" -gt 0 ] && [ "$ID_MISSING" -eq 0 ] && [ "$ID_EXTRA" -eq 0 ]; then
    pass "acceptance coverage set: $REPORT_IDS / $P0_IDS (100%)"
  elif [ "$P0_IDS" -gt 0 ]; then
    p0 "acceptance coverage set mismatch: missing=$ID_MISSING extra=$ID_EXTRA (criteria=$P0_IDS report=$REPORT_IDS)"
  else
    p0 "no acceptance IDs in criteria: $CRITERIA_PATH"
  fi
else
  warn "criteria or design missing, skip coverage check"
fi

# ---------- §5 无 TODO/FIXME ----------
echo ""
echo "=== §5 无 TODO/FIXME 残留 ==="
# v3.16.11（P1-4）: 扫描范围 = backend 下全部真实服务——此前只扫调用方指定的
# 单个 service（PoC：真实服务含 TODO，传 ../clean 只扫外部干净目录 → 0 → PASS）。
# 全量扫描消除"指定一个干净服务绕过"的攻击面；SERVICE 参数仅用于收据记录。
if [ -z "$_ALL_SVCS" ]; then
  p0 "backend 下无 *\/src/main/java 服务目录——TODO/FIXME 扫描范围无法确定（拒绝静默跳过）"
else
  _SVC_N=$(printf '%s\n' "$_ALL_SVCS" | grep -c . || true)
  TODO_COUNT=0
  for _s in $_ALL_SVCS; do
    _c=$(grep -rnE 'TODO|FIXME' "backend/$_s/src/main/java" 2>/dev/null | wc -l | tr -d ' ' || true)
    TODO_COUNT=$((TODO_COUNT + _c))
  done
  if [ "$TODO_COUNT" -eq 0 ]; then
    pass "TODO/FIXME = 0（backend 全部 $_SVC_N 个服务已扫描）"
  else
    p0 "TODO/FIXME found: ${TODO_COUNT}（backend 全部 ${_SVC_N} 个服务聚合——单一干净服务不能掩盖其余服务的残留）"
  fi
fi

# ---------- §6 架构陷阱 = 0 ----------
echo ""
echo "=== §6 架构陷阱 = 0 ==="
# v3.16.3（N-P2-1）: §6 改 --all --receipt 组合——架构陷阱检查同时产出
# ARCH-PITFALLS 收据（含证据绑定），供 complete P3b / audit-receipts 消费
#（旧口径：p3b 内联跑 --all 无收据，"每次 Phase 切换必跑"承诺可写但无人读）
if bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --all --receipt "$FEATURE" 2>&1; then
  pass "arch pitfalls = 0（ARCH-PITFALLS 收据已产出）"
else
  p0 "arch pitfalls 检查失败（收据 EXIT_CODE 非 0——详见 gates/ARCH-PITFALLS/）"
fi

# ---------- 收据 ----------
# v3.15.5: STATE_DIR 同口径——此前写死 .devflow/，隔离部署下收据落错目录（audit 误报"state 标记完成但无收据"）
RECEIPT_DIR="${STATE_DIR:-.devflow}/${FEATURE}/gates/P3b"
mkdir -p "$RECEIPT_DIR"
P3B_EXIT=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
GATE_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$(cd "$(dirname "$0")/.." && pwd)/SKILL.md" 2>/dev/null | head -1)
[ -n "$GATE_VER" ] || { echo "[FATAL] 版本源读取失败，拒绝产出收据"; exit 2; }
# v3.16.0（P0-3）: 统一收据契约——收据绑定原始证据（EVIDENCE_TREE_SHA256），
# 证据删除/篡改后 audit-receipts 重验即阻断（旧契约仅路径无哈希，PoC：删报告仍 AUDIT PASS）
EV_REPORT="$REPORT_PATH"
EV_DESIGN="$DESIGN_PATH"
# v3.16.11（P1-4 附）: criteria 纳入证据树——验收标准是 P3b 覆盖检查的对账源
#（此前只绑 report+design，删 criteria 后收据重验无感知）
# v3.26.0: 复用已解析的 CRITERIA_PATH——旧版硬编码英文回退路径，中文路径项目
#（v3.22.0 起默认命名）证据文件不存在 → receipt_evidence_tree 失败 → P3b 永远
# 产不出收据（test-chinese-paths 未覆盖 p3b，故未被发现）。
EV_CRITERIA="$CRITERIA_PATH"
command -v jq >/dev/null 2>&1 || { echo "[FATAL] jq 不可用——收据契约无法生成，拒绝产出无绑定收据" >&2; exit 2; }
EVIDENCE_PATHS_JSON=$(jq -cn --arg a "$EV_REPORT" --arg b "$EV_DESIGN" --arg c "$EV_CRITERIA" '[$a, $b, $c]')
# v3.16.2: 结果守卫——jq 损坏时 JSON 为空同样拒绝
[ -n "$EVIDENCE_PATHS_JSON" ] || { echo "[FATAL] EVIDENCE_PATHS_JSON 生成失败（jq 损坏）" >&2; exit 2; }
EVIDENCE_TREE=$(receipt_evidence_tree "$EV_REPORT" "$EV_DESIGN" "$EV_CRITERIA")
[ -n "$EVIDENCE_TREE" ] || { echo "[FATAL] 证据树哈希计算失败，拒绝产出无绑定收据"; exit 2; }
cat > "$RECEIPT_DIR/receipt.txt" <<EOF
COMMAND=p3b_code_review_gate.sh $FEATURE $SERVICE
EXIT_CODE=$P3B_EXIT
EVIDENCE_PATHS_JSON=$EVIDENCE_PATHS_JSON
EVIDENCE_TREE_SHA256=$EVIDENCE_TREE
PRODUCER_ROLE=code-reviewer
SESSION_ID=${REVIEW_SESSION_ID:-unknown}
STARTED_AT=${P3B_STARTED_AT:-unknown}
FINISHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ENVIRONMENT=${ENVIRONMENT:-dev}
VERSION=p3b@$GATE_VER
SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)
PHASE=P3b
PASS=$PASS FAIL=$FAIL WARN=$WARN
feature: $FEATURE
service: $SERVICE
report: $REPORT_PATH
timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
# v3.9.5: mirror receipt into docs/ (version-controlled evidence; .devflow/ was missing in all 4 audited projects)
DOCS_MIRROR="docs/${FEATURE}/gates/P3b"
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"

# ---------- 总结 ----------
echo ""
echo "════════════════════════════════════════════════════════════"
echo " P3b 代码审查 Gate · 总结"
echo "════════════════════════════════════════════════════════════"
echo " PASS: $PASS"
echo " WARN: $WARN"
echo " FAIL: $FAIL"
echo "════════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
