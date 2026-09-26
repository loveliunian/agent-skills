#!/usr/bin/env bash
# =============================================================================
# build-watchdog.sh · P3-build 出口 Gate（仅保留 gate 模式）
# (v3.16.26 起收敛为仅 gate 模式)
# =============================================================================
# v3.9.3 修复了：
#   - gate <feature>      Phase 出口 (写 receipt.txt)——正式流程唯一入口
#   (v3.16.26: check/watch/detect 模式已移除——正式流程只需要 gate；
#    后台 watch 属开发工具，不进入交付链路)
#
# v3.9.4 修复：
#   - watch 模式 fs 检测只盯 java，不盯 xml/sql/vue/ts → 改为递归监听全部产物
#   - 缺少 npm run build / tsc / vue-tsc 支持 → 加 FRONTEND_DIR 多模式编译
#   - watch 模式 stdout 输出会被 fswatch pipe 吞掉 → 加 line-buffered tee
#   - watch 模式没有"watch 死亡"自动重启 → 加 trap EXIT 重启
#
# 用法：
#   bash build-watchdog.sh gate <feature>            # Phase 出口收据（唯一模式）
#
# 状态文件：.devflow/<feature>/state.json (复用 checkpoint-state.sh)
# 收据文件：.devflow/<feature>/gates/P3-build/receipt.txt
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
STATE_DIR="${STATE_DIR:-.devflow}"
PROJECT_ROOT="${PROJECT_ROOT:-}"
# v3.9.4 FIX: auto-detect backend/frontend
detect_project_root() {
  local cwd="$1"
  # 向上找最近的 backend/ 或 frontend/ 或 pom.xml
  while [ "$cwd" != "/" ]; do
    if [ -d "$cwd/backend" ] || [ -d "$cwd/frontend" ] || [ -f "$cwd/pom.xml" ] || [ -f "$cwd/package.json" ]; then
      echo "$cwd"
      return 0
    fi
    cwd="$(dirname "$cwd")"
  done
  echo "$1"  # fallback to current
  return 0
}
[ -n "$PROJECT_ROOT" ] || PROJECT_ROOT="$(detect_project_root "$(pwd)")"
BACKEND_DIR="${BACKEND_DIR:-$PROJECT_ROOT/backend}"
FRONTEND_DIR="${FRONTEND_DIR:-$PROJECT_ROOT/frontend}"
WATCH_DIRS="${WATCH_DIRS:-$BACKEND_DIR:$FRONTEND_DIR}"

MODE="${1:-help}"
FEATURE="${2:-}"
# v3.15.10: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 在
# 项目外建目录写收据/镜像）与 grep -E 正则注入；v3.15.5 曾给 10+ gate 加固，此处为漏网实例
if [ -n "$FEATURE" ]; then
  source "$SCRIPT_DIR/devflow_feature.sh"
  devflow_feature_validate "$FEATURE" || exit 2
fi

resolve_client_scope() {
  CLIENT_SCOPE="pc-web"
  CLIENT_ROOT="$FRONTEND_DIR"
  CLIENT_MANIFEST_SHA=""
  local state_file="$STATE_DIR/${FEATURE}.state.json"
  if [ -f "$state_file" ] && command -v jq >/dev/null 2>&1; then
    CLIENT_SCOPE=$(jq -r '.scope.frontend // "pc-web"' "$state_file" 2>/dev/null || echo "pc-web")
    CLIENT_ROOT=$(jq -r '.scope.frontend_dir // "frontend"' "$state_file" 2>/dev/null || echo "frontend")
    CLIENT_MANIFEST_SHA=$(jq -r '.scope.client_manifest_sha256 // empty' "$state_file" 2>/dev/null || true)
  fi
  case "$CLIENT_SCOPE" in
    required|web) CLIENT_SCOPE="pc-web" ;;
  esac
}

# ────────────────────────────────────────────
# 编译函数集（按项目类型自动选择）
# ────────────────────────────────────────────
mvn_compile() {
  [ ! -d "$BACKEND_DIR" ] && { echo "no-backend-dir"; return 0; }
  [ ! -f "$BACKEND_DIR/pom.xml" ] && { echo "no-pom-xml"; return 0; }
  cd "$BACKEND_DIR" || return 1
  local LOG
  LOG=$(mktemp)
  mvn compile -q -B -DskipTests > "$LOG" 2>&1
  local EXIT=$?
  if [ $EXIT -ne 0 ]; then
    local BLAME
    BLAME=$(grep -E "^\[ERROR\] /.*\.java|error: cannot find symbol|package .* does not exist|cannot access|class file .* not found" "$LOG" | head -3 | tr '\n' ';' | sed 's|/.*/||g;s|\[ERROR\] ||g')
    if [ -z "$BLAME" ]; then
      BLAME=$(grep -E "ERROR" "$LOG" | head -3 | tr '\n' ';' | sed 's|/.*/||g;s|\[ERROR\] ||g' | head -c 200)
    fi
    if [ -z "$BLAME" ]; then
      BLAME="unknown mvn compile error"
    fi
    rm -f "$LOG"
    echo "$BLAME"
    return 1
  fi
  rm -f "$LOG"
  return 0
}

npm_build() {
  [ ! -d "$FRONTEND_DIR" ] && { echo "no-frontend-dir"; return 0; }
  [ ! -f "$FRONTEND_DIR/package.json" ] && { echo "no-package-json"; return 0; }
  cd "$FRONTEND_DIR" || return 1
  local LOG
  LOG=$(mktemp)
  npm run build --silent > "$LOG" 2>&1 || { cat "$LOG" | head -20; rm -f "$LOG"; return 1; }
  rm -f "$LOG"
  return 0
}

tsc_check() {
  # 适用于 vue-tsc / tsc --noEmit
  [ ! -d "$FRONTEND_DIR" ] && { echo "no-frontend-dir"; return 0; }
  [ ! -f "$FRONTEND_DIR/tsconfig.json" ] && { echo "no-tsconfig"; return 0; }
  cd "$FRONTEND_DIR" || return 1
  local LOG
  LOG=$(mktemp)
  if [ -f "$FRONTEND_DIR/node_modules/.bin/vue-tsc" ]; then
    npx vue-tsc --noEmit > "$LOG" 2>&1
  else
    npx tsc --noEmit > "$LOG" 2>&1
  fi
  local EXIT=$?
  if [ $EXIT -ne 0 ]; then
    local BLAME
    BLAME=$(grep -E "error TS|error: " "$LOG" | head -3 | tr '\n' ';' | head -c 200)
    [ -z "$BLAME" ] && BLAME="tsc check failed"
    rm -f "$LOG"
    echo "$BLAME"
    return 1
  fi
  rm -f "$LOG"
  return 0
}

run_all_checks() {
  local FAIL=0
  BLOCKER_DETAIL=""   # v3.9.6: 收集具体失败原因，供 checkpoint blocker 记录（中断恢复时无需翻 stdout）
  echo "[BUILD-WATCHDOG] backend mvn compile..."
  if BLAME=$(mvn_compile); then
    if [ "$BLAME" = "no-backend-dir" ] || [ "$BLAME" = "no-pom-xml" ]; then
      echo "[BUILD-WATCHDOG] ⊝ backend skipped: $BLAME"
    else
      echo "[BUILD-WATCHDOG] ✓ mvn compile PASS"
    fi
  else
    echo "[BUILD-WATCHDOG] ✗ mvn compile FAIL: $BLAME"
    BLOCKER_DETAIL="${BLOCKER_DETAIL:+$BLOCKER_DETAIL; }mvn: $BLAME"
    FAIL=1
  fi

  # v3.28.9（m01-base 复盘·双方言前置）：MySQL-only 语法在 Flyway 迁移运行才暴露
  # （实测 AUTO_INCREMENT/TINYINT 在 H2 PG 模式失败，P3 返工一轮）——写完 SQL 即静态拦截。
  echo "[BUILD-WATCHDOG] sql dialect lint..."
  if [ -x "$SCRIPT_DIR/sql_dialect_lint.sh" ] || [ -f "$SCRIPT_DIR/sql_dialect_lint.sh" ]; then
    if SQL_LINT=$(bash "$SCRIPT_DIR/sql_dialect_lint.sh" 2>&1); then
      echo "[BUILD-WATCHDOG] ✓ sql dialect lint PASS"
    else
      echo "[BUILD-WATCHDOG] ✗ sql dialect lint FAIL"
      printf '%s\n' "$SQL_LINT" | head -8 | sed 's/^/    /'
      BLOCKER_DETAIL="${BLOCKER_DETAIL:+$BLOCKER_DETAIL; }sql-dialect lint"
      FAIL=1
    fi
  else
    echo "[BUILD-WATCHDOG] ⊝ sql dialect lint skipped: sql_dialect_lint.sh missing"
  fi

  resolve_client_scope
  case "$CLIENT_SCOPE" in
    mini-program|app)
      echo "[BUILD-WATCHDOG] $CLIENT_SCOPE client build..."
      if [ -n "$CLIENT_MANIFEST_SHA" ] && [ "$CLIENT_MANIFEST_SHA" != "null" ] && \
         bash "$SCRIPT_DIR/client-adapter.sh" build "$CLIENT_SCOPE" "$CLIENT_ROOT" --strict --expected-manifest-sha "$CLIENT_MANIFEST_SHA"; then
        echo "[BUILD-WATCHDOG] ✓ $CLIENT_SCOPE build PASS"
      else
        echo "[BUILD-WATCHDOG] ✗ $CLIENT_SCOPE build FAIL"
        BLOCKER_DETAIL="${BLOCKER_DETAIL:+$BLOCKER_DETAIL; }$CLIENT_SCOPE build"
        FAIL=1
      fi
      ;;
    not-applicable)
      echo "[BUILD-WATCHDOG] ⊝ client build skipped: not-applicable"
      ;;
    pc-web)
      echo "[BUILD-WATCHDOG] frontend npm run build..."
      if BLAME=$(npm_build); then
        if [ "$BLAME" = "no-frontend-dir" ] || [ "$BLAME" = "no-package-json" ]; then
          echo "[BUILD-WATCHDOG] ⊝ frontend skipped: $BLAME"
        else
          echo "[BUILD-WATCHDOG] ✓ npm build PASS"
        fi
      else
        echo "[BUILD-WATCHDOG] ✗ npm build FAIL: $BLAME"
        BLOCKER_DETAIL="${BLOCKER_DETAIL:+$BLOCKER_DETAIL; }npm: $BLAME"
        FAIL=1
      fi

      echo "[BUILD-WATCHDOG] frontend tsc check..."
      if BLAME=$(tsc_check); then
        if [ "$BLAME" = "no-frontend-dir" ] || [ "$BLAME" = "no-tsconfig" ]; then
          echo "[BUILD-WATCHDOG] ⊝ tsc skipped: $BLAME"
        else
          echo "[BUILD-WATCHDOG] ✓ tsc PASS"
        fi
      else
        echo "[BUILD-WATCHDOG] ✗ tsc FAIL: $BLAME"
        BLOCKER_DETAIL="${BLOCKER_DETAIL:+$BLOCKER_DETAIL; }tsc: $BLAME"
        FAIL=1
      fi
      ;;
    *)
      echo "[BUILD-WATCHDOG] ✗ invalid client platform: $CLIENT_SCOPE"
      FAIL=1
      ;;
  esac

  return $FAIL
}

# ────────────────────────────────────────────
# 主入口（v3.16.26：仅保留 gate 模式）
# ────────────────────────────────────────────
case "$MODE" in
  gate)
    [ -z "$FEATURE" ] && { echo "Usage: $0 gate <feature>"; exit 2; }
    mkdir -p "$STATE_DIR/$FEATURE/gates/P3-build"
    RECEIPT="$STATE_DIR/$FEATURE/gates/P3-build/receipt.txt"
    # v3.26.3: L-MON-001 入检——watchdog 输出留痕（.devflow/<feature>/build-watchdog.log），
    # "写完即编译"的持续验证可追溯（教训：事后无法补救——执行日志已丢失）。
    WATCH_LOG="$STATE_DIR/$FEATURE/build-watchdog.log"
    GATE_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$(cd "$SCRIPT_DIR/.." && pwd)/SKILL.md" 2>/dev/null | head -1)
    [ -n "$GATE_VER" ] || { echo "[FATAL] 版本源读取失败，拒绝产出收据"; exit 2; }
    # v3.27.1: Runtime Profile 能力门禁——非 java-spring-flyway profile 在此
    # BLOCKED(MISSING_CAPABILITY) 并出 BLOCKED 收据（供 checkpoint/audit 消费）。
    source "$SCRIPT_DIR/devflow_profile.sh"
    PROFILE_BLOCK_MSG=""
    if ! devflow_profile_require_impl_v2 "$FEATURE" "P3-build"; then
      PROFILE_BLOCK_MSG="MISSING_CAPABILITY (PROFILE_ID=$(devflow_profile_of "$FEATURE"))"
    fi
    if [ -n "$PROFILE_BLOCK_MSG" ]; then
      cat > "$RECEIPT" <<EOF
VERSION=p3-build@$GATE_VER
SKILL_TREE=$(bash "$SCRIPT_DIR/gate-skill-tree.sh" 2>/dev/null || echo unknown)
PHASE=P3-build
GATE=P3-build
FEATURE=$FEATURE
AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EXIT_CODE=1
PASS=
WARN=
FAIL=$PROFILE_BLOCK_MSG
EOF
      echo "[BUILD-WATCHDOG-GATE] ⛔ P3-build BLOCKED — $RECEIPT"
      mkdir -p "docs/$FEATURE/gates/P3-build" 2>/dev/null && cp "$RECEIPT" "docs/$FEATURE/gates/P3-build/" 2>/dev/null
      exit 1
    fi
    run_all_checks 2>&1 | tee "$WATCH_LOG"
    WATCH_RC=${PIPESTATUS[0]}
    {
      echo "[gate] feature=$FEATURE version=$GATE_VER at=$(date -u +%Y-%m-%dT%H:%M:%SZ) exit=$WATCH_RC"
    } >> "$WATCH_LOG"
    if [ "$WATCH_RC" -eq 0 ]; then
      # v3.31.4: 收据按实执行情况描述（第9轮质量#2：node 项目 backend skipped 仍写
      # "clean"——零验证 PASS 收据是证据质量倒退；skip 项显式记 SKIPPED 清单）
      _SKIPPED=$(grep -oE '⊝ [a-z ]+ skipped[^ ]*' "$WATCH_LOG" | sed 's/⊝ //;s/ skipped.*//' | sort -u | tr '\n' ',' | sed 's/,$//')
      cat > "$RECEIPT" <<EOF
VERSION=p3-build@$GATE_VER
SKILL_TREE=$(bash "$SCRIPT_DIR/gate-skill-tree.sh" 2>/dev/null || echo unknown)
PHASE=P3-build
GATE=P3-build
FEATURE=$FEATURE
AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EXIT_CODE=0
PASS=executed checks clean
$([ -n "$_SKIPPED" ] && echo "SKIPPED=$_SKIPPED" )
WARN=
FAIL=
EOF
      echo "[BUILD-WATCHDOG-GATE] ✓ P3-build PASS — $RECEIPT"
      mkdir -p "docs/$FEATURE/gates/P3-build" 2>/dev/null && cp "$RECEIPT" "docs/$FEATURE/gates/P3-build/" 2>/dev/null && echo "[RECEIPT] Mirrored: docs/$FEATURE/gates/P3-build/receipt.txt"
      exit 0
    else
      cat > "$RECEIPT" <<EOF
VERSION=p3-build@$GATE_VER
SKILL_TREE=$(bash "$SCRIPT_DIR/gate-skill-tree.sh" 2>/dev/null || echo unknown)
PHASE=P3-build
GATE=P3-build
FEATURE=$FEATURE
AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EXIT_CODE=1
PASS=
WARN=
FAIL=${BLOCKER_DETAIL:-see bash output above}
EOF
      echo "[BUILD-WATCHDOG-GATE] ✗ P3-build FAIL — $RECEIPT"
      mkdir -p "docs/$FEATURE/gates/P3-build" 2>/dev/null && cp "$RECEIPT" "docs/$FEATURE/gates/P3-build/" 2>/dev/null && echo "[RECEIPT] Mirrored: docs/$FEATURE/gates/P3-build/receipt.txt"
      exit 1
    fi
    ;;

  *)
    echo "Usage: $0 gate <feature>   # Phase 出口 gate (收据入 .devflow/)；check/watch/detect 已于 v3.16.26 移除"
    exit 2
    ;;
esac
