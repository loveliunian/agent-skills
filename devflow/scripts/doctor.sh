#!/usr/bin/env bash
# doctor.sh · devflow 体检（环境依赖 + 可选项目侧自检，只读）
# 用法:
#   bash scripts/doctor.sh                 # 仅环境依赖体检
#   bash scripts/doctor.sh --project      # 环境体检 + 当前工作区 .devflow 项目自检
# 项目自检（只读，不推进不修复）：
#   - 每个 *.state.json：JSON 可解析 + 关键字段（version/feature/current_phase/phases/scope）齐备
#   - reconcile 只读漂移报告（state ↔ 收据链）
#   - audit-receipts 只读对账（收据证据绑定）
#   v3.26.2: 新增项目侧自检（此前 doctor 只查环境依赖，项目健康要分跑
#   reconcile/audit-receipts 两个命令；合并为 doctor 一键预检）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FAIL=0
WARN=0
PROJECT_MODE=0
for a in "$@"; do
  case "$a" in
    --project) PROJECT_MODE=1 ;;
    *) echo "[FAIL] 未知参数: ${a}（用法: doctor.sh [--project]）" >&2; exit 2 ;;
  esac
done

ok()   { echo "[OK]   $*"; }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

echo "=== devflow doctor: $ROOT ==="

# ---- 核心依赖（缺失即阻断本 skill 的 Gate/发布） ----
if [ "${BASH_VERSINFO[0]:-0}" -ge 3 ]; then
  ok "bash ${BASH_VERSION}"
else
  fail "bash 版本过低: ${BASH_VERSION:-unknown}（需 >= 3.2）"
fi
if command -v git >/dev/null 2>&1; then
  ok "git $(git --version | awk '{print $3}')"
else
  fail "git 缺失"
fi
if command -v python3 >/dev/null 2>&1; then
  ok "python3 可用（df_pipeline / release-audit YAML 校验）"
else
  fail "python3 缺失（df_pipeline / release-audit YAML 校验需要）"
fi
if command -v jq >/dev/null 2>&1; then
  ok "jq 可用（manifest hash-chain / state）"
else
  warn "jq 缺失（manifest hash-chain 与部分 Gate 需要，建议安装）"
fi
if command -v shellcheck >/dev/null 2>&1; then
  ok "shellcheck 可用（release.sh 硬门禁）"
else
  warn "shellcheck 缺失（release.sh 第 5 步硬门禁，发布前必须安装）"
fi
# v3.27.1: P2a 签名收据前置依赖指引（审查报告发现 2——隐藏高成本依赖应尽早可见）
if [ -n "${REVIEW_ATTESTATION_PUBKEY:-}" ] && [ -f "${REVIEW_ATTESTATION_PUBKEY}" ]; then
  ok "REVIEW_ATTESTATION_PUBKEY 已配置（P2a 评审签名收据可用）"
else
  warn "REVIEW_ATTESTATION_PUBKEY 未配置——P2a 评审将 BLOCKED；生成密钥对: bash scripts/gen-review-keypair.sh <目录>"
fi

# ---- 可选依赖（按 Runtime Profile 需要） ----
command -v java >/dev/null 2>&1 && ok "java 可用（java-spring-flyway profile）" || warn "java 缺失（仅 java-spring-flyway profile 需要）"
if command -v mvn >/dev/null 2>&1; then
  ok "mvn 可用（java-spring-flyway profile）"
elif command -v gradle >/dev/null 2>&1; then
  ok "gradle 可用（java-spring-flyway profile）"
else
  warn "mvn/gradle 缺失（仅 java 系 profile 需要）"
fi
command -v node >/dev/null 2>&1 && ok "node 可用（可选前端工具链）" || true

# ---- 副本直连校验（已安装副本必须直连本 skill） ----
if [ -f "$ROOT/scripts/check-copies.sh" ]; then
  if bash "$ROOT/scripts/check-copies.sh" >/dev/null 2>&1; then
    ok "副本直连校验通过"
  else
    warn "副本直连校验未通过（运行 scripts/install.sh 或仓库级 sync.sh 修复）"
  fi
fi

# ---- 项目侧自检（--project；只读） ----
if [ "$PROJECT_MODE" -eq 1 ]; then
  echo ""
  echo "=== 项目自检（$(pwd)/.devflow，只读） ==="
  STATE_DIR="${STATE_DIR:-$(pwd)/.devflow}"
  if [ ! -d "$STATE_DIR" ]; then
    warn "未发现 ${STATE_DIR}——当前目录无 devflow 项目（--project 仅环境体检生效）"
  else
    # ① 每个 state.json 结构预检
    shopt -s nullglob
    _sf_files=("$STATE_DIR"/*.state.json)
    shopt -u nullglob
    if [ "${#_sf_files[@]}" -eq 0 ]; then
      warn "无 *.state.json（尚未 init 任何工作流）"
    fi
    for sf in "${_sf_files[@]}"; do
      fname=$(basename "$sf")
      if ! jq -e . "$sf" >/dev/null 2>&1; then
        fail "state JSON 不可解析: $fname"; continue
      fi
      _missing=""
      for _k in version feature current_phase phases scope; do
        jq -e --arg k "$_k" 'has($k)' "$sf" >/dev/null 2>&1 || _missing="$_missing $_k"
      done
      if [ -n "$_missing" ]; then
        fail "state 缺少关键字段: ${fname}（${_missing}）"
      else
        ok "state 结构完整: $fname"
      fi
    done
    # ② reconcile 只读漂移报告（逐 feature 复用状态机对账）
    for sf in "${_sf_files[@]}"; do
      feature=$(basename "$sf" .state.json)
      if bash "$ROOT/scripts/devflow-state.sh" reconcile "$feature" >/dev/null 2>&1; then
        ok "reconcile 一致: $feature"
      else
        warn "reconcile 报告漂移: ${feature}（详情: devflow-state.sh reconcile ${feature}）"
      fi
    done
    # ③ audit-receipts 只读对账（逐 feature；存在收据时才调用）
    for sf in "${_sf_files[@]}"; do
      feature=$(basename "$sf" .state.json)
      if ! ls "$STATE_DIR/$feature/gates/"*/receipt.txt >/dev/null 2>&1; then
        continue
      fi
      if bash "$ROOT/scripts/audit-receipts.sh" "$feature" "$STATE_DIR" "$(pwd)/docs" >/dev/null 2>&1; then
        ok "audit-receipts 对账通过: $feature"
      else
        warn "audit-receipts 对账未通过: ${feature}（详情: audit-receipts.sh ${feature} ${STATE_DIR} docs）"
      fi
    done
  fi

  # ④ skill 树稳定性（L-EFF-001：瞬时写入会使两次采样不一致——收据树漂移前兆）
  T1="$(bash "$ROOT/scripts/gate-skill-tree.sh" 2>/dev/null || true)"
  T2="$(bash "$ROOT/scripts/gate-skill-tree.sh" 2>/dev/null || true)"
  if [ -n "$T1" ] && [ "$T1" = "$T2" ]; then
    ok "skill 树稳定: ${T1:0:12}…"
  else
    warn "skill 树两次采样不一致（skill 目录正被并发写入/同步——稍后重跑 migrate-tree + 受影响 Gate）"
  fi

  # ⑤ 管线格式预检（L-EFF-001：历史上靠试错对齐的格式雷区，跑 Gate 前先静态扫）
  _clar="$(ls docs/需求/*-需求澄清.md docs/requirements/*-clarification.md 2>/dev/null | head -1)"
  if [ -n "$_clar" ]; then
    _twoseg=$(grep -oE '`[a-zA-Z][a-zA-Z0-9_-]*:[a-zA-Z][a-zA-Z0-9_-]*`' "$_clar" 2>/dev/null | grep -cvE ':.*:' || true)
    [ "${_twoseg:-0}" -gt 0 ] && warn "澄清文档存在两段式权限码 ${_twoseg} 处（规范=三段式 module:resource:action，两段式不参与对账）"                              || ok "澄清权限码均为三段式口径"
  fi
  _tech="$(ls docs/详细设计/*-技术选型.md docs/detailed-design/*-tech-selection.md 2>/dev/null | head -1)"
  if [ -n "$_tech" ]; then
    grep -qE '用户确认[[:space:]]*:[[:space:]]*(YES|已确认|CONFIRMED|true)' "$_tech" 2>/dev/null \
      && ok "技术选型含机检确认行（半角冒号）" \
      || warn "技术选型缺半角「用户确认: …」机检行（LC_ALL=C 下全角冒号过不了 Gate）"
  fi
  for _rev in docs/评审/*-设计评审报告.md docs/需求/*-PRD评审.md; do
    [ -f "$_rev" ] || continue
    _bad=$(grep -oE '#### ZERO-DF（[^）]*）' "$_rev" 2>/dev/null | grep -cvE '业务专家|技术负责人|前端交互|测试开发|安全合规' || true)
    [ "${_bad:-0}" -gt 0 ] && warn "$_rev 存在 ${_bad} 个 Gate 不可识别的 ZERO-DF 标签（须为 业务专家/技术负责人/前端交互/测试开发/安全合规）"                            || ok "评审报告 ZERO-DF 标签可识别: $_rev"
  done
  _amb="$(ls docs/需求/*-PRD评审.md 2>/dev/null | head -1)"
  if [ -n "$_amb" ] && grep -q '歧义术语' "$_amb" && ! grep -q '无歧义术语' "$_amb"; then
    grep -qE '^\| *[0-9]' "$_amb" && ok "歧义术语表行首为数字（Gate 契约）"       || warn "歧义术语表行首非数字（Gate 按 |数字| 解析已决议行）"
  fi
fi

echo ""
echo "DOCTOR: FAIL=$FAIL WARN=$WARN"
[ "$FAIL" -eq 0 ] || exit 1
