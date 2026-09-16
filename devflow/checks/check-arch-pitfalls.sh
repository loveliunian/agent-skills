#!/usr/bin/env bash
# 历史（引入于 早期版本，详见 CHANGELOG）: --receipt <feature> —— 每次 Phase 切换必跑架构
# 陷阱检查"，但此前仅 P3b 调用、无独立收据。该模式写 ARCH-PITFALLS 收据（含证据
# 绑定），供状态机/审计消费。
# ============================================================
# check-arch-pitfalls.sh (v3.4.0)
# ------------------------------------------------------------
# 用途：架构陷阱自动检查（合并并扩展 6 个 check 脚本）
# 来源：concepts/architecture-pitfalls.md（54 D-XX / 21 G / 44 B）
# 用法：
#   bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --all
#   bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category config
#   bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category api
#   bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category security
#   bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category code
#   bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category perf
#   bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category obs
#   bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category deploy
#   bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category test
# ============================================================

set -e
# v3.16.3: SCRIPT_DIR 定义（v3.16.1 changelog 曾声称修复但未落码——N+1 子检查
# 在 cwd 非 skill 根时整体跳过、恰在根时空展开恒 127 却报 PASS 的双重死路）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

CATEGORY="${1:-all}"
WORKSPACE="${WORKSPACE:-$(pwd)}"
BACKEND="${BACKEND:-$WORKSPACE/backend}"
FRONTEND="${FRONTEND:-$WORKSPACE/frontend}"
DEPLOY="${DEPLOY:-$WORKSPACE/deploy}"

CRITICAL_COUNT=0
WARN_COUNT=0
PASS_COUNT=0

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'
critical() { echo -e "${RED}[CRITICAL]${NC} $1"; CRITICAL_COUNT=$((CRITICAL_COUNT+1)); }
warn()     { echo -e "${YELLOW}[WARN]${NC} $1"; WARN_COUNT=$((WARN_COUNT+1)); }
pass()     { echo -e "${GREEN}[PASS]${NC} $1"; PASS_COUNT=$((PASS_COUNT+1)); }
section()  { echo -e "\n${GREEN}=== $* ===${NC}"; }

# ---------- §2 配置分散 ----------
check_config_env_vars() {
  section "§2 配置分散（环境变量命名分裂）"
  # 扫描 application*.yml 中重复的环境变量前缀
  for svc_dir in "$BACKEND"/*/; do
    [ -d "$svc_dir" ] || continue
    svc=$(basename "$svc_dir")
    for yml in "$svc_dir"/src/main/resources/application*.yml "$svc_dir"/src/main/resources/application*.properties; do
      [ -f "$yml" ] || continue
      # 检测 POSTGRES_* 和 SPRING_DATASOURCE_* 同时存在
      if grep -q "POSTGRES_" "$yml" && grep -q "SPRING_DATASOURCE_" "$yml"; then
        critical "D-37 ❌ 环境变量命名分裂：$svc 同时存在 POSTGRES_* 和 SPRING_DATASOURCE_*"
      fi
    done
  done
  pass "D-37 环境变量命名检查完成"
}

check_config_duplicate() {
  section "§2 配置分散（配置类重复定义）"
  # 检查 common 模块是否定义了 MyBatisPlusConfig/RedisConfig/JacksonConfig
  for cls in "MyBatisPlusConfig" "RedisConfig" "JacksonConfig" "RedissonConfig" "MinIOConfig"; do
    count=$(find "$BACKEND"/*/src/main/java -name "$cls.java" 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "$count" -gt 1 ]; then
      warn "D-26 ⚠️ 多服务定义 $cls ($count 个)，建议统一进 common"
    fi
  done
  pass "D-26 配置类重复检查完成"
}

check_config_hardcoded_url() {
  section "§2 配置分散（硬编码 URL/IP）"
  while IFS= read -r yml; do
    # 检测 192.168.0 网段或 10.0.0 网段硬编码
    if grep -E "(192\.168\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+)" "$yml" 2>/dev/null; then
      critical "D-37 ❌ 硬编码 IP：$yml"
    fi
done < <(find "$BACKEND" -name "application*.yml" 2>/dev/null)
  pass "D-37 硬编码 URL 检查完成"
}

check_config_default_secret() {
  section "§2 配置分散（密钥默认值）"
  while IFS= read -r yml; do
    # 找出 :${VAR:default} 形式且 default 包含密钥相关字样
    awk -v f="$yml" '
      /\$\{[A-Z_]+:.*\}/ {
        if ($0 ~ /(password|secret|key|token)/i && $0 ~ /:.*[a-zA-Z0-9]{8,}/) {
          # 排除显然是默认占位符的（如 not-set）
          if ($0 !~ /:\?/) {
            print "  " f ":" NR ": " $0
          }
        }
      }
    ' "$yml"
done < <(find "$BACKEND" -name "application*.yml" 2>/dev/null)
  pass "D-17 密钥默认值检查完成"
}

# ---------- §3 API/接口契约 ----------
check_api_declarative() {
  section "§3 API（声明式接口绕过）"
  # 扫描 Service 层是否有 RestTemplate / WebClient / RestClient.builder
  while IFS= read -r f; do
    # 排除 client/ 和 config/ 目录
    case "$f" in
      */client/*|*/config/*) continue ;;
    esac
    if grep -E "RestTemplate|WebClient|RestClient\.builder" "$f" >/dev/null 2>&1; then
      grep -nE "RestTemplate|WebClient|RestClient\.builder" "$f" | head -3 | while IFS=: read -r line _; do
        critical "D-01/D-33 ❌ 跨服务调用绕过声明式：$f:$line"
      done
    fi
done < <(find "$BACKEND"/*/src/main/java -name "*.java" -type f 2>/dev/null | grep '/service/')
  pass "D-01/D-33 声明式接口检查完成"
}

check_api_openapi() {
  section "§3 API（OpenAPI 缺失）"
  missing=0
  for svc_dir in "$BACKEND"/*/; do
    [ -d "$svc_dir" ] || continue
    has_controller=$(find "$svc_dir/src/main/java" -name "*Controller.java" 2>/dev/null | head -1 || true)
    if [ -n "$has_controller" ]; then
      pom="$svc_dir/pom.xml"
      if [ -f "$pom" ] && ! grep -q "springdoc-openapi" "$pom"; then
        warn "D-10 ⚠️ $svc 有 Controller 但缺 springdoc-openapi"
        missing=$((missing+1))
      fi
    fi
  done
  pass "D-10 OpenAPI 集成检查完成（缺 $missing 个）"
}

# ---------- §4 安全/密钥 ----------
check_security_jwt_default() {
  section "§4 安全（JWT_SECRET 默认值）"
  while IFS= read -r yml; do
    if grep -E "JWT_SECRET.*:-" "$yml" >/dev/null 2>&1; then
      critical "D-17 ❌ JWT_SECRET 含默认值：$yml"
    fi
done < <(find "$BACKEND" -name "application*.yml" 2>/dev/null)
  pass "D-17 JWT_SECRET 默认值检查完成"
}

check_security_hardcoded_password() {
  section "§4 安全（部署脚本硬编码密码）"
  for sh in "$DEPLOY"/*.sh; do
    [ -f "$sh" ] || continue
    if grep -E "(Liucl157|password123|admin123|secret123)" "$sh" >/dev/null 2>&1; then
      critical "D-29 ❌ 部署脚本硬编码密码：$sh"
    fi
    # 检查密钥类变量是否含默认值
    if grep -E "(JWT_SECRET|.*_PASSWORD|.*_SECRET_KEY|.*_ACCESS_KEY):-.*[a-zA-Z0-9]{6,}" "$sh" >/dev/null 2>&1; then
      critical "D-29 ❌ 部署脚本密钥默认值：$sh"
    fi
  done
  pass "D-29 部署脚本密码检查完成"
}

check_security_csrf_consistency() {
  section "§4 安全（CSRF 策略一致性）"
  # 跨服务扫描 SecurityConfig
  csrf_on=0
  csrf_off=0
  while IFS= read -r f; do
    if grep -q "csrf.disable" "$f"; then
      csrf_off=$((csrf_off+1))
    elif grep -q "ignoringRequestMatchers" "$f"; then
      csrf_on=$((csrf_on+1))
    fi
done < <(find "$BACKEND"/*/src/main/java -name "*SecurityConfig.java" 2>/dev/null)
  if [ "$csrf_on" -gt 0 ] && [ "$csrf_off" -gt 0 ]; then
    warn "D-18 ⚠️ CSRF 策略不一致：$csrf_off 个禁用，$csrf_on 个白名单"
  fi
  pass "D-18 CSRF 策略一致性检查完成"
}

# ---------- §5 依赖/版本 ----------
check_deploy_image_tag() {
  section "§5 依赖（镜像 tag 锁定）"
  while IFS= read -r yml; do
    if grep -E "image:.*:latest" "$yml" >/dev/null 2>&1; then
      critical "D-52 ❌ 镜像使用 :latest：$yml"
    fi
done < <(find "$DEPLOY" -name "docker-compose*.yml" 2>/dev/null)
  pass "D-52 镜像 tag 检查完成"
}

check_deploy_dual_lockfile() {
  section "§5 依赖（前端双锁文件）"
  pkg_lock=$(find "$FRONTEND" -maxdepth 2 -name "package-lock.json" 2>/dev/null | head -1 || true)
  pnpm_lock=$(find "$FRONTEND" -maxdepth 2 -name "pnpm-lock.yaml" 2>/dev/null | head -1)
  if [ -n "$pkg_lock" ] && [ -n "$pnpm_lock" ]; then
    critical "D-52 ❌ 同时存在 package-lock.json 和 pnpm-lock.yaml"
  fi
  pass "D-52 双锁文件检查完成"
}

# ---------- §6 代码规范 ----------
check_code_huge_service() {
  section "§6 代码（巨型 Service）"
  warn_threshold=500
  critical_threshold=1000
  while IFS= read -r f; do
    lines=$(wc -l < "$f" | tr -d ' ')
    if [ "$lines" -gt "$critical_threshold" ]; then
      critical "D-35 ❌ 巨型 Service $f: $lines 行（阈值 ${critical_threshold}）"
    elif [ "$lines" -gt "$warn_threshold" ]; then
      warn "D-35 ⚠️ 巨型 Service $f: $lines 行（阈值 ${warn_threshold}）"
    fi
done < <(find "$BACKEND"/*/src/main/java -name "*ServiceImpl.java" -type f 2>/dev/null | grep '/service/')
  pass "D-35 巨型 Service 检查完成"
}

check_code_dto_duplicate() {
  section "§6 代码（DTO 重复定义）"
  for cls in "ApiResponse" "PageRequest" "PageResponse" "ErrorCode"; do
    count=$(find "$BACKEND"/*/src/main/java -name "$cls.java" 2>/dev/null | wc -l | tr -d ' ' || true)
    # common 模板本来就有 1 个
    if [ "$count" -gt 1 ]; then
      critical "D-21 ❌ $cls 被定义 $count 次（应在 common 唯一）"
    fi
  done
  pass "D-21 DTO 重复定义检查完成"
}

check_code_objectmapper() {
  section "§6 代码（new ObjectMapper 绕过）"
  while IFS= read -r f; do
    if grep -nE "new ObjectMapper\(\)" "$f" >/dev/null 2>&1; then
      grep -nE "new ObjectMapper\(\)" "$f" | head -2 | while IFS=: read -r line _; do
        critical "D-22 ❌ 业务代码 new ObjectMapper()：$f:$line"
      done
    fi
done < <(find "$BACKEND"/*/src/main/java -name "*.java" -type f 2>/dev/null | grep '/service/')
  pass "D-22 ObjectMapper 业务代码检查完成"
}

# ---------- §8 性能 ----------
check_perf_n_plus_one() {
  section "§8 性能（N+1 查询）"
  # v3.16.4（N25-P3-1）: 存在性判断同样用 $SCRIPT_DIR——cwd 相对路径在项目根
  # 恒不存在 → N+1 检查静默跳过仍报 PASS（假绿）
  if [ -f "$SCRIPT_DIR/detect-n-plus-one.sh" ]; then
    if bash "$SCRIPT_DIR/detect-n-plus-one.sh" "$BACKEND" 2>&1 | grep -q "N+1"; then
      warn "D-?? ⚠️ 检测到 N+1 候选（详见 detect-n-plus-one.sh 输出）"
    fi
  fi
  pass "D-?? N+1 检查完成"
}

# ---------- §9 可观测性 ----------
check_obs_actuator() {
  section "§9 可观测性（Actuator 端点）"
  while IFS= read -r yml; do
    if grep -q "management.endpoints.web.exposure.include" "$yml"; then
      endpoints=$(grep "management.endpoints.web.exposure.include" "$yml" | head -1)
      if [[ "$endpoints" != *"prometheus"* ]]; then
        warn "D-15 ⚠️ $yml 缺 prometheus 端点"
      fi
    fi
done < <(find "$BACKEND"/*/src/main/resources -name "application*.yml" 2>/dev/null)
  pass "D-15 Actuator 端点检查完成"
}

check_obs_log_format() {
  section "§9 可观测性（日志格式）"
  while IFS= read -r xml; do
    if ! grep -q "LogstashEncoder" "$xml"; then
      warn "D-14 ⚠️ $xml prod profile 未用 LogstashEncoder（JSON）"
    fi
done < <(find "$BACKEND" -name "logback-spring.xml" 2>/dev/null)
  pass "D-14 日志格式检查完成"
}

# ---------- §10 部署 ----------
check_deploy_resources() {
  section "§10 部署（资源约束）"
  while IFS= read -r yml; do
    if ! grep -q "resources:" "$yml" && ! grep -q "deploy:" "$yml"; then
      warn "D-53 ⚠️ $yml 缺 deploy.resources 资源约束"
    fi
done < <(find "$DEPLOY" -name "docker-compose*.yml" 2>/dev/null)
  pass "D-53 资源约束检查完成"
}

# ---------- §11 测试 ----------
check_test_any_count() {
  section "§11 测试（前端 any 数量）"
  if [ -f "$FRONTEND/scripts/check-any.mjs" ]; then
    cd "$FRONTEND" && node scripts/check-any.mjs 2>&1 | tail -3 && cd - >/dev/null
  fi
  pass "D-27 any 数量检查完成"
}

# ---------- v3.16.1: --receipt 入口级处理（组合口径） ----------
# 文档/收据声明 "check-arch-pitfalls.sh --all --receipt <feature>"，旧实现 case
# $CATEGORY 分发时 --all 吞掉后续 --receipt（不写收据 rc=0 假绿，PoC F1）。
# 任意位置出现 --receipt <feature> 即走收据模式（--all 逻辑仍执行并写入 evidence）。
_RC_FEATURE=""
_rc_prev=""
for _a in "$@"; do
  if [ "$_rc_prev" = "--receipt" ] || [ "$_rc_prev" = "receipt" ]; then _RC_FEATURE="$_a"; break; fi
  _rc_prev="$_a"
done
_RC_STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [ -n "$_RC_FEATURE" ]; then
  # v3.16.3（N-P1-1）: feature 白名单共享校验——全树 26 个 feature 入口的第 27 个
  # 漏网（PoC：--receipt '../../../../../tmp/escaped' 曾在项目外写收据+证据）
  source "$SCRIPT_DIR/../scripts/devflow_feature.sh" 2>/dev/null \
    || { echo "[FAIL] devflow_feature.sh 加载失败" >&2; exit 2; }
  devflow_feature_validate "$_RC_FEATURE" || exit 2
  # v3.16.3: 统一收据契约库——EVIDENCE_TREE_SHA256 必须用 receipt_evidence_tree
  # 构造（此前误用单文件哈希，与 verify_receipt_evidence 的树哈希口径不一致，
  # 收据从产出起即被审计判"证据树哈希不匹配"）
  source "$SCRIPT_DIR/../scripts/devflow_receipt.sh" 2>/dev/null \
    || { echo "[FAIL] devflow_receipt.sh 加载失败" >&2; exit 2; }
  _RC_DIR="${STATE_DIR:-.devflow}/$_RC_FEATURE/gates/ARCH-PITFALLS"
  _RC_MIRROR="docs/$_RC_FEATURE/gates/ARCH-PITFALLS"
  mkdir -p "$_RC_DIR" "$_RC_MIRROR" 2>/dev/null
  _RC_EV="$_RC_DIR/evidence.txt"
  set +e
  bash "$0" --all > "$_RC_EV" 2>&1
  _RC_CODE=$?
  set -e
  # v3.16.4: || true——set -e 下树哈希计算失败会先于守卫触发 exit 1（守卫口径统一 exit 2）
  _RC_TREE=$(receipt_evidence_tree "$_RC_EV" || true)
  _RC_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$SCRIPT_DIR/../SKILL.md" 2>/dev/null | head -1)
  # v3.16.2: jq 双守卫（存在性+结果）——缺失或损坏时 EVIDENCE_PATHS_JSON 为空会使收据降级 legacy 无绑定
  command -v jq >/dev/null 2>&1 || { echo "[FATAL] jq 不可用——收据契约（EVIDENCE_PATHS_JSON）无法生成，拒绝产出无绑定收据" >&2; exit 2; }
  _RC_JSON=$(jq -cn --arg a "$_RC_EV" '[$a]' || true)
  [ -n "$_RC_JSON" ] || { echo "[FATAL] EVIDENCE_PATHS_JSON 生成失败（jq 损坏）" >&2; exit 2; }
  # v3.16.3（N-P3-2）: 树哈希非空守卫（对齐 p3b/s6-final）——空值会使收据静默
  # 降级 legacy 无绑定（审计 WARN 放行）
  [ -n "$_RC_TREE" ] || { echo "[FATAL] 证据树哈希计算失败，拒绝产出无绑定收据" >&2; exit 2; }
  {
    echo "COMMAND=check-arch-pitfalls.sh --all --receipt $_RC_FEATURE"
    echo "EXIT_CODE=$_RC_CODE"
    echo "EVIDENCE_PATHS_JSON=$_RC_JSON"
    echo "EVIDENCE_TREE_SHA256=$_RC_TREE"
    echo "PRODUCER_ROLE=arch-pitfall-checker"
    echo "SESSION_ID=${SESSION_ID:-unknown}"
    echo "STARTED_AT=${_RC_STARTED_AT:-unknown}"
    echo "ENVIRONMENT=${ENVIRONMENT:-dev}"
    echo "VERSION=arch-pitfalls@${_RC_VER:-unknown}"
    echo "SKILL_TREE=$(bash "$SCRIPT_DIR/../scripts/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
    echo "PHASE=ARCH-PITFALLS"
    echo "FINISHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } > "$_RC_DIR/receipt.txt"
  cp "$_RC_DIR/receipt.txt" "$_RC_MIRROR/receipt.txt" 2>/dev/null
  echo "[RECEIPT] ARCH-PITFALLS written: $_RC_DIR/receipt.txt (exit=$_RC_CODE)"
  exit "$_RC_CODE"
fi

# ---------- 主入口 ----------
case "$CATEGORY" in
  --all|all)
    check_config_env_vars
    check_config_duplicate
    check_config_hardcoded_url
    check_config_default_secret
    check_api_declarative
    check_api_openapi
    check_security_jwt_default
    check_security_hardcoded_password
    check_security_csrf_consistency
    check_deploy_image_tag
    check_deploy_dual_lockfile
    check_code_huge_service
    check_code_dto_duplicate
    check_code_objectmapper
    check_perf_n_plus_one
    check_obs_actuator
    check_obs_log_format
    check_deploy_resources
    check_test_any_count
    ;;
  --category|category)
    cat_arg="${2:-all}"
    case "$cat_arg" in
      config) check_config_env_vars; check_config_duplicate; check_config_hardcoded_url; check_config_default_secret ;;
      api) check_api_declarative; check_api_openapi ;;
      security) check_security_jwt_default; check_security_hardcoded_password; check_security_csrf_consistency ;;
      code) check_code_huge_service; check_code_dto_duplicate; check_code_objectmapper ;;
      perf) check_perf_n_plus_one ;;
      obs) check_obs_actuator; check_obs_log_format ;;
      deploy) check_deploy_image_tag; check_deploy_dual_lockfile; check_deploy_resources ;;
      test) check_test_any_count ;;
      *) echo "未知类别: $cat_arg"; exit 1 ;;
    esac
    ;;
  *) echo "用法: $0 --all | --category <config|api|security|code|perf|obs|deploy|test>"; exit 1 ;;
esac

# 总结
echo
echo "============================================="
echo -e "  ${RED}CRITICAL: $CRITICAL_COUNT${NC} | ${YELLOW}WARN: $WARN_COUNT${NC} | ${GREEN}PASS: $PASS_COUNT${NC}"
echo "============================================="
if [ "$CRITICAL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
