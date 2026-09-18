#!/usr/bin/env bash
# =============================================================================
# P3 编码完成度门控脚本
# =============================================================================
# 功能:
#   1. 架构陷阱检查 (check-arch-pitfalls.sh)
#   2. TODO/FIXME 零容忍
#   3. Controller 权限注解 (@PreAuthorize)
#   4. Mapper/Entity 数量一致性
#   5. Flyway 4 方言目录 (h2/oracle/postgresql/kingbase)
#   6. Maven 编译 + 测试
#   7. JaCoCo 行覆盖率 >= 阈值
#   8. 菜单 seed 检查：sys_menu/sys_menu_operation/sys_permission_group/sys_user_effective_perm 4 表 + postgresql setval 序列同步 (v3.8.0)
# =============================================================================
set -euo pipefail

SERVICE="${1:-}"
FEATURE="${2:-}"

# ---------- 依赖检查 (v3.8.0) ----------
command -v jq >/dev/null 2>&1 || { echo "[FAIL] jq is required but not installed"; exit 1; }
# v3.15.5: feature 白名单共享校验（devflow_feature.sh；为空时由后续 state/产物读取失败兜底）
if [ -n "$FEATURE" ]; then
  source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
  devflow_feature_validate "$FEATURE" || exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# v3.27.15: 详设正文解析共用库（渲染块 + 旧版手写两类版式）
source "$SCRIPT_DIR/design_parse_lib.sh"
# v3.22.0: 文档层中文化（中文优先、英文回退）
source "$SCRIPT_DIR/devflow_paths.sh"
if [ -n "${DESIGN_FILE:-}" ]; then
  DESIGN="$DESIGN_FILE"
elif [ -n "$FEATURE" ]; then
  DESIGN="$(df_resolve_doc "$FEATURE" design .md design)"
  [ -n "$DESIGN" ] || DESIGN="docs/详细设计/${FEATURE}-详细设计.md"
else
  DESIGN="docs/详细设计/${FEATURE}-详细设计.md"
fi
STATE_DIR="${STATE_DIR:-.devflow}"
API_REQUIRED="${API_REQUIRED:-1}"
PERSISTENCE_REQUIRED="${PERSISTENCE_REQUIRED:-1}"
COVERAGE_THRESHOLD="${COVERAGE_THRESHOLD:-80}"
# v3.27.1: Runtime Profile 能力门禁（SKILL.md 原则 13）——build/test/coverage/
# flyway/orm-mapping 命令位当前仅 java-spring-flyway 实现；其他 profile 在此
# BLOCKED(MISSING_CAPABILITY)，不得静默运行错误技术栈的命令。
source "$SCRIPT_DIR/devflow_profile.sh"
if ! devflow_profile_require_impl "$FEATURE" "p3_completion"; then
  exit 1
fi
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
p1()  { echo "[P1]  $1"; }   # v3.8.0: non-blocking warning for setval
run_gate() {
  local label="$1"; shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

[ -n "$SERVICE" ] && [ -n "$FEATURE" ] || { echo "Usage: $0 <service> <feature>"; exit 2; }
[ -d "backend/$SERVICE" ] || { echo "[FAIL] backend/$SERVICE missing"; exit 1; }
[ -f "$DESIGN" ] || { echo "[FAIL] design missing: $DESIGN"; exit 1; }

# The state file is authoritative once it exists; environment variables may
# provide a default only before initialization and must never bypass a freeze.
STATE_FILE="$STATE_DIR/${FEATURE}.state.json"
if [ -f "$STATE_FILE" ]; then
  FROZEN_SCOPE=$(jq -r '.scope.frontend // "pc-web"' "$STATE_FILE" 2>/dev/null || echo "pc-web")
  REQUESTED_SCOPE="${FRONTEND_SCOPE:-}"
  case "$REQUESTED_SCOPE" in
    required|web) REQUESTED_SCOPE="pc-web" ;;
  esac
  if [ -n "$REQUESTED_SCOPE" ] && [ "$REQUESTED_SCOPE" != "$FROZEN_SCOPE" ]; then
    echo "[FAIL] FRONTEND_SCOPE conflicts with frozen state: $REQUESTED_SCOPE != $FROZEN_SCOPE"
    exit 2
  fi
  FRONTEND_SCOPE="$FROZEN_SCOPE"
  CLIENT_DIR=$(jq -r '.scope.frontend_dir // empty' "$STATE_FILE" 2>/dev/null || true)
  FROZEN_MANIFEST_SHA=$(jq -r '.scope.client_manifest_sha256 // empty' "$STATE_FILE" 2>/dev/null || true)
else
  FRONTEND_SCOPE="${FRONTEND_SCOPE:-pc-web}"
  CLIENT_DIR=""
  FROZEN_MANIFEST_SHA=""
fi
case "$FRONTEND_SCOPE" in
  required|web) FRONTEND_SCOPE="pc-web" ;;
esac

verify_client_manifest() {
  case "$FRONTEND_SCOPE" in
    mini-program|app)
      if [ -z "$FROZEN_MANIFEST_SHA" ] || [ "$FROZEN_MANIFEST_SHA" = "null" ]; then
        fail "client manifest is not frozen; run devflow-state.sh client-freeze $FEATURE after P2"
        return 1
      fi
      bash "$SCRIPT_DIR/client-adapter.sh" validate "$FRONTEND_SCOPE" "$CLIENT_DIR" --strict --expected-manifest-sha "$FROZEN_MANIFEST_SHA" || {
        fail "client manifest verification"
        return 1
      }
      ;;
  esac
  return 0
}
case "$FRONTEND_SCOPE" in
  pc-web) CLIENT_DIR="${CLIENT_DIR:-frontend}" ;;
  mini-program) CLIENT_DIR="${CLIENT_DIR:-miniprogram}" ;;
  app) CLIENT_DIR="${CLIENT_DIR:-app}" ;;
  not-applicable) CLIENT_DIR="" ;;
  *) echo "[FAIL] invalid frontend scope: $FRONTEND_SCOPE"; exit 2 ;;
esac

if bash "$SCRIPT_DIR/../checks/check-arch-pitfalls.sh" --all; then pass "architecture pitfalls"; else fail "architecture pitfalls"; fi

# ---------- 技术选型↔依赖/config 对账 (v3.16.26 NEW) ----------
# 每条 FROZEN 硬约束必须落到代码：MUST_USE 须出现在 pom.xml 或 resources 配置；
# MUST_NOT_USE 的禁用产品禁止出现在 pom.xml / resources 配置中。
if [ -n "${TECH_CONSTRAINTS_FILE:-}" ]; then
  TC_FILE="$TECH_CONSTRAINTS_FILE"
else
  TC_FILE="$(df_resolve_doc "$FEATURE" constraints .md requirements)"
  [ -n "$TC_FILE" ] || TC_FILE="docs/需求/${FEATURE}-技术约束.md"
fi
if [ -f "$TC_FILE" ]; then
  source "$SCRIPT_DIR/tech_constraints_lib.sh"
  if tc_check_dependencies "$TC_FILE" "backend/$SERVICE"; then
    pass "tech constraints ↔ dependencies/config consistent"
  else
    fail "tech constraints ↔ dependencies/config NOT consistent:"
    tc_check_dependencies "$TC_FILE" "backend/$SERVICE" | sed 's/^/    /'
  fi
else
  fail "technology constraints missing: $TC_FILE (P0 冻结产物必须存在)"
fi

# ---------- 详设声明表 ↔ Flyway 实建表对账（原 p3_detail_diff.sh 并入 v3.16.26） ----------
if [ -f "$DESIGN" ] && [ -d "backend/$SERVICE/src/main/resources/db/migration" ]; then
  DIFF_TMP=$(mktemp -d)
  # v3.27.15: 优先解析 table-index 渲染块，回退旧版 CREATE TABLE 字面量（design_parse_lib.sh）
  design_tables_from_doc "$DESIGN" | tr '[:upper:]' '[:lower:]' | sort -u > "$DIFF_TMP/design-tables.txt" || true
  find "backend/$SERVICE/src/main/resources/db/migration" -type f -name 'V*.sql' -exec grep -hiE '^[[:space:]]*CREATE[[:space:]]+TABLE' {} + 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/^[[:space:]]*create[[:space:]]+table[[:space:]]+(if[[:space:]]+not[[:space:]]+exists[[:space:]]+)?([a-z_][a-z0-9_]*).*/\2/' \
    | sort -u > "$DIFF_TMP/flyway-tables.txt" || true
  MISSING_TABLES=$(comm -23 "$DIFF_TMP/design-tables.txt" "$DIFF_TMP/flyway-tables.txt" || true)
  if [ -n "$MISSING_TABLES" ]; then
    fail "design declares tables missing in Flyway:"
    printf '%s\n' "$MISSING_TABLES" | sed 's/^/    - /'
  else
    pass "design tables ↔ Flyway CREATE TABLE consistent"
  fi
  rm -rf "$DIFF_TMP"
fi

TODO_COUNT=$({ grep -rnE 'TODO|FIXME' "backend/$SERVICE/src/main/java" 2>/dev/null || true; } | wc -l | tr -d ' ')
[ "$TODO_COUNT" -eq 0 ] && pass "TODO/FIXME=0" || fail "TODO/FIXME=$TODO_COUNT"

CONTROLLERS=$(find "backend/$SERVICE/src/main/java" -name '*Controller.java' -type f 2>/dev/null || true)
if [ -n "$CONTROLLERS" ]; then
  PREAUTH_MISS=$(printf '%s\n' "$CONTROLLERS" | while IFS= read -r f; do grep -q '@PreAuthorize' "$f" 2>/dev/null || echo "$f"; done)
  [ -z "$PREAUTH_MISS" ] && pass "Controller permission annotations" || { echo "$PREAUTH_MISS"; fail "Controller permission annotations"; }
elif [ "$API_REQUIRED" = "1" ]; then
  fail "no Controller found"
else
  pass "Controller not required"
fi

MAPPER_COUNT=$(find "backend/$SERVICE/src/main/java" -name '*Mapper.java' -type f 2>/dev/null | wc -l | tr -d ' ' || true)
ENTITY_COUNT=$(find "backend/$SERVICE/src/main/java" -name '*.java' -type f 2>/dev/null | grep '/entity/' | wc -l | tr -d ' ' || true)
if [ "$PERSISTENCE_REQUIRED" = "1" ]; then
  [ "$MAPPER_COUNT" -eq "$ENTITY_COUNT" ] && pass "Mapper=Entity ($MAPPER_COUNT)" || fail "Mapper=$MAPPER_COUNT Entity=$ENTITY_COUNT"
else
  pass "persistence not required"
fi

if [ "$PERSISTENCE_REQUIRED" = "1" ]; then
  for vendor in h2 oracle postgresql kingbase; do
    if [ -d "backend/$SERVICE/src/main/resources/db/migration/$vendor" ]; then pass "Flyway $vendor"; else fail "Flyway $vendor missing"; fi
  done
fi

if (cd backend && mvn -pl "$SERVICE" -q compile); then pass "Maven compile"; else fail "Maven compile"; fi
if (cd backend && mvn -pl "$SERVICE" -q test); then pass "Maven test"; else fail "Maven test"; fi

JACOCO="backend/$SERVICE/target/site/jacoco/jacoco.xml"
if [ -f "$JACOCO" ]; then
  coverage=$(grep -oE '<counter type="LINE" missed="[0-9]+" covered="[0-9]+"/>' "$JACOCO" 2>/dev/null | tail -1 | sed -E 's/.*missed="([0-9]+)" covered="([0-9]+)".*/\1 \2/' | awk '{t=$1+$2; if(t==0) print 0; else printf "%.2f", $2*100/t}' || true)
  coverage="${coverage:-0}"
  if awk -v c="${coverage}" -v t="$COVERAGE_THRESHOLD" 'BEGIN{exit !(c+0 >= t+0)}'; then
    pass "JaCoCo line coverage=$coverage%"
  else
    fail "JaCoCo line coverage=${coverage}% < $COVERAGE_THRESHOLD%"
  fi
else
  fail "JaCoCo XML missing"
fi

case "$FRONTEND_SCOPE" in
  pc-web)
    [ -f "$CLIENT_DIR/package.json" ] || fail "$CLIENT_DIR/package.json missing"
    if [ -f "$CLIENT_DIR/pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
      (cd "$CLIENT_DIR" && pnpm run build) && pass "PC Web build" || fail "PC Web build"
      (cd "$CLIENT_DIR" && pnpm run type-check) && pass "PC Web type-check" || fail "PC Web type-check"
    else
      (cd "$CLIENT_DIR" && npm run build) && pass "PC Web build" || fail "PC Web build"
      (cd "$CLIENT_DIR" && npm run type-check) && pass "PC Web type-check" || fail "PC Web type-check"
    fi
    # v3.26.1: 前端 TODO/FIXME 可见化——旧版只扫 backend Java，前端残留无任何 gate 覆盖；
    # 非阻塞 p1（与后端 TODO=0 的阻塞口径分开，纳入 P3b 评审）。
    FE_TODO_COUNT=$(grep -rnE 'TODO|FIXME' "$CLIENT_DIR/src" 2>/dev/null | wc -l | tr -d ' ' || true)
    [ "$FE_TODO_COUNT" -eq 0 ] || p1 "frontend TODO/FIXME=${FE_TODO_COUNT}（非阻塞，P3b 评审须核对）"
    if bash "$SCRIPT_DIR/client-adapter.sh" validate pc-web "$CLIENT_DIR" --strict; then pass "PC Web standards"; else fail "PC Web standards"; fi
    ;;
  mini-program|app)
    verify_client_manifest || true
    if [ "$FAIL" -eq 0 ] && bash "$SCRIPT_DIR/client-adapter.sh" build "$FRONTEND_SCOPE" "$CLIENT_DIR" --strict --expected-manifest-sha "$FROZEN_MANIFEST_SHA"; then pass "$FRONTEND_SCOPE build"; else fail "$FRONTEND_SCOPE build"; fi
    if [ "$FAIL" -eq 0 ] && bash "$SCRIPT_DIR/client-adapter.sh" test "$FRONTEND_SCOPE" "$CLIENT_DIR" --strict --expected-manifest-sha "$FROZEN_MANIFEST_SHA"; then pass "$FRONTEND_SCOPE test"; else fail "$FRONTEND_SCOPE test"; fi
    ;;
  not-applicable) pass "client not applicable (frozen scope)" ;;
esac

NEW_PAGES=0
if [ "$FRONTEND_SCOPE" = "pc-web" ]; then
  NEW_PAGES=$(find "$CLIENT_DIR/src/views/$FEATURE" -name 'index.vue' -type f 2>/dev/null | wc -l | tr -d ' ' || true)
  # v3.27.15: 页面不落在 src/views/<feature>/ 约定路径时，回退按施工图基线判定——
  # design.json baseline 里 ADD/MODIFY 的前端页面目标即新增/变更页。
  if [ "$NEW_PAGES" -eq 0 ] && [ -f "$STATE_DIR/$FEATURE/design.json" ]; then
    NEW_PAGES=$(jq -r '[.baseline.entries[]? | select((.decision=="ADD" or .decision=="MODIFY") and ((.target // "") | test("(^|/)(views|pages)/")))] | length' \
      "$STATE_DIR/$FEATURE/design.json" 2>/dev/null || echo 0)
  fi
fi
# v3.26.1: menu-seed 静默跳过可见化——页面目录约定不匹配（NEW_PAGES=0）时旧版
# 无声跳过 seed 校验（目录改名即可绕过）；现显式 p1 提示，人工确认可达性。
if [ "$FRONTEND_SCOPE" = "pc-web" ] && [ "$NEW_PAGES" -eq 0 ] && [ -d "$CLIENT_DIR/src/views" ]; then
  p1 "menu-seed 检查跳过：未发现 $CLIENT_DIR/src/views/$FEATURE/index.vue 且基线无前端页面变更——若页面在非约定路径，须人工核对菜单可达性"
fi
if [ "$NEW_PAGES" -gt 0 ]; then
  for vendor in h2 postgresql oracle kingbase; do
    SEED=$(find "backend/$SERVICE/src/main/resources/db/migration/$vendor" -type f \
      \( -name "*seed_${FEATURE}_menus*.sql" -o -name "*${FEATURE}*menu*.sql" \) 2>/dev/null | head -1 || true)
    if [ -z "$SEED" ]; then
      # v3.27.15: 历史项目按 module 命名（文件名不含 feature）——兜底命中但提示规范名
      SEED=$(find "backend/$SERVICE/src/main/resources/db/migration/$vendor" -type f \
        -name "*seed_*_menus*.sql" 2>/dev/null | head -1 || true)
      if [ -n "$SEED" ]; then
        p1 "$vendor menu seed 文件名不含 feature（建议改名 *seed_${FEATURE}_menus*.sql）: $SEED"
      fi
    fi
    if [ -z "$SEED" ]; then fail "$vendor menu seed missing"; continue; fi
    missing=0
    for table in sys_menu sys_menu_operation sys_permission_group sys_user_effective_perm; do
      grep -qiE "INSERT[[:space:]]+INTO[[:space:]]+$table" "$SEED" 2>/dev/null || missing=$((missing + 1))
    done
    # v3.8.0: postgresql 方言必须包含 setval 序列同步
    if [ "$vendor" = "postgresql" ]; then
      if grep -qiE "SELECT[[:space:]]+setval|setval\(" "$SEED" 2>/dev/null; then
        pass "$vendor menu seed (setval included)"
      else
        p1 "$vendor menu seed missing setval sequence sync"
      fi
    fi
    [ "$missing" -eq 0 ] && pass "$vendor menu seed" || fail "$vendor menu seed missing $missing tables"
  done
fi

echo "P3 RESULT: PASS=$PASS FAIL=$FAIL"
# ---------- 收据双写（v3.9.6：与其他 gate 对齐） ----------
RECEIPT_DIR="$STATE_DIR/${FEATURE:?FEATURE is required for receipt (default fallback removed v3.14.0)}/gates/P3"
mkdir -p "$RECEIPT_DIR" 2>/dev/null
{
  echo "EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)"
  echo "VERSION=p3@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "PHASE=P3"
  echo "PASS=$PASS FAIL=$FAIL"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt" 2>/dev/null
[ -s "$RECEIPT_DIR/receipt.txt" ] || { echo "[RECEIPT] WRITE FAILED: $RECEIPT_DIR/receipt.txt" >&2; exit 1; }
echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
DOCS_MIRROR="docs/${FEATURE:?FEATURE is required for receipt (default fallback removed v3.14.0)}/gates/P3"
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"
if [ "$FAIL" -eq 0 ]; then
  echo "P3 GATE: PASS"
  exit 0
fi
echo "P3 GATE: FAIL"
exit 1
