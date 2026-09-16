#!/usr/bin/env bash
# doctor.sh · devflow 环境依赖体检（核心/可选分级 + 副本直连校验，只读）
# 用法: bash scripts/doctor.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FAIL=0
WARN=0

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

echo ""
echo "DOCTOR: FAIL=$FAIL WARN=$WARN"
[ "$FAIL" -eq 0 ] || exit 1
