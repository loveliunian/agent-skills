#!/usr/bin/env bash
# =============================================================================
# perm_reconcile_lib.sh · 权限码对账共享库（s0 §7 与 artifact_gate P0b 同库同口径）
# =============================================================================
# v3.21.0: 三方对账（权限矩阵 ↔ 澄清文档 ↔ 菜单 Seed 索引）。此前 s0 §7 仅用
# `perm:` 前缀提取——真实矩阵由 generate-permission-matrix.sh 产出反引号三段式
# `mod:ent:act`，提取恒空 → 对账空转（治理服务 detailed-design-v2 复盘发现）。
# 本库双格式归一后 comm 对账。
#
# 口径约定：
# - 调用方须先定义 p0()/pass()/warn() 助手（declare -F 防静默 no-op，防口径分裂）；
# - 本库不设 set 选项、无顶层副作用（source 库惯例，devflow_receipt.sh 同型）；
# - 豁免：澄清文档显式声明 `权限矩阵=not-applicable`（声明式豁免，与 artifact_gate
#   「无歧义术语」同型；矩阵缺失由 warn 升级为 P0，豁免是唯一跳过路径）；
# - 菜单 Seed 为可选第三方（仅菜单驱动项目存在）：缺失跳过；存在则要求
#   seed ⊆ matrix——seed-only 码 = 种子菜单挂了矩阵中不存在的 perm_code，P0。
# =============================================================================

_perm_lib_require_reporters() {
  local f
  for f in p0 pass warn; do
    declare -F "$f" >/dev/null || { echo "[FATAL] perm_reconcile_lib 依赖调用方 $f() 助手" >&2; return 1; }
  done
}

# 归一化提取权限码：澄清/PRD 用 perm:xxx 前缀；矩阵/Seed 用反引号三段式（与
# generate-permission-matrix.sh rx_perm、checks/check-permission-consistency.sh 同源）
perm_extract_codes() { # <file> -> stdout 每行一个
  [ -f "$1" ] || return 0
  grep -oE 'perm:[a-zA-Z0-9_:.-]+' "$1" 2>/dev/null | sed 's/^perm://' || true
  grep -oE '`[a-zA-Z][a-zA-Z0-9_-]*:[a-zA-Z][a-zA-Z0-9_-]*:[a-zA-Z][a-zA-Z0-9_-]*`' "$1" 2>/dev/null | tr -d '`' || true
  # v3.27.1(L-EFF-001): 两段式反引号码也纳入对账——此前静默忽略导致"澄清有码/矩阵无码"
  # 类漂移只剩单侧可见，排查多轮。两段/三段各自闭合匹配，互不误吞。
  grep -oE '`[a-zA-Z][a-zA-Z0-9_-]*:[a-zA-Z][a-zA-Z0-9_-]*`' "$1" 2>/dev/null | tr -d '`' || true
}

perm_matrix_declared_not_applicable() { # <clarify> -> rc0 当且仅当显式声明
  grep -qE '权限矩阵[[:space:]]*[=：:][[:space:]]*(NOT-APPLICABLE|not-applicable|不适用)' "$1" 2>/dev/null
}

perm_reconcile_three_way() { # <matrix> <clarify> <menu_seed>
  _perm_lib_require_reporters || return 2
  local matrix="$1" clarify="$2" seed="$3"

  if perm_matrix_declared_not_applicable "$clarify"; then
    pass "permission matrix declared not-applicable（声明式豁免）"
    return 0
  fi

  if [ ! -f "$matrix" ]; then
    p0 "permission matrix missing: $matrix — 权限码对账为 P0 强制项（L-P0-001）；确认不适用请在澄清文档声明：权限矩阵=not-applicable"
    return 1
  fi

  local matrix_codes clarify_codes m_count c_count
  matrix_codes=$(perm_extract_codes "$matrix" | sed '/^$/d' | sort -u)
  clarify_codes=$(perm_extract_codes "$clarify" | sed '/^$/d' | sort -u)
  m_count=$(printf '%s\n' "$matrix_codes" | sed '/^$/d' | grep -c . || true)
  c_count=$(printf '%s\n' "$clarify_codes" | sed '/^$/d' | grep -c . || true)

  if [ "${m_count:-0}" -eq 0 ]; then
    warn "permission matrix exists but contains no recognizable permission codes"
    return 0
  fi
  if [ "${c_count:-0}" -eq 0 ]; then
    warn "no permission codes found in clarification, but permission matrix exists ($m_count codes)"
    return 0
  fi

  # 双向一致（空行过滤后再 comm，防空行参与集合运算）
  local matrix_only clarify_only
  matrix_only=$(comm -23 <(printf '%s\n' "$matrix_codes" | sed '/^$/d') <(printf '%s\n' "$clarify_codes" | sed '/^$/d') || true)
  clarify_only=$(comm -13 <(printf '%s\n' "$matrix_codes" | sed '/^$/d') <(printf '%s\n' "$clarify_codes" | sed '/^$/d') || true)
  [ -n "$matrix_only" ] && p0 "permission codes in matrix but not in clarification: $(printf '%s' "$matrix_only" | tr '\n' ' ')"
  [ -n "$clarify_only" ] && p0 "permission codes in clarification but not in matrix: $(printf '%s' "$clarify_only" | tr '\n' ' ')"
  if [ -z "$matrix_only" ] && [ -z "$clarify_only" ]; then
    pass "permission codes aligned: matrix ($m_count) = clarification ($c_count)"
  fi

  # 三方：菜单 Seed ⊆ 矩阵（可选第三方，缺失不算失败）
  if [ -f "$seed" ]; then
    local seed_codes seed_only s_count
    seed_codes=$(perm_extract_codes "$seed" | sed '/^$/d' | sort -u)
    s_count=$(printf '%s\n' "$seed_codes" | sed '/^$/d' | grep -c . || true)
    if [ "${s_count:-0}" -gt 0 ]; then
      seed_only=$(comm -23 <(printf '%s\n' "$seed_codes" | sed '/^$/d') <(printf '%s\n' "$matrix_codes" | sed '/^$/d') || true)
      if [ -n "$seed_only" ]; then
        p0 "menu-seed permission codes missing from matrix: $(printf '%s' "$seed_only" | tr '\n' ' ') — 种子菜单必须对应矩阵中已登记的权限码"
      else
        pass "menu-seed ⊆ matrix ($s_count codes verified)"
      fi
    else
      warn "menu-seed index exists but contains no permission codes"
    fi
  else
    pass "menu-seed index absent, two-way reconciliation only（可选第三方）"
  fi
  return 0
}
