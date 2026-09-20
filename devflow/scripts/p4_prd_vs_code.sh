#!/usr/bin/env bash
# =============================================================================
# P4b PRD vs Code — Exact Item-by-Item Gate
# =============================================================================
# 核心原则：
#   1. 逐项对比：详设中列出的每一项（接口/表/字段/页面），代码中必须有对应实现
#   2. FAIL > 0 → exit 1
#   3. 空集合（详设和代码都没有）→ 警告但不 FAIL
#   4. 禁止数量相等但内容不同的"宽松判断"
# =============================================================================
# v3.21.0: 新增 --mode <monolith|total|sub>（env P4B_MODE 回退）透传 s2 详设覆盖 Gate
#   ——总分/分文档设计此前被 monolith 章节契约误杀，项目侧被迫聚合投影（硬链接事故源头）；
#   收据新增 MODE= 行（读取方均为按 key 提取，兼容）。FB-20260915-governance-p4b-monolith。
# =============================================================================
set -u
set -o pipefail
# 错误处理模式（v3.27.2，见 references/script-conventions.md）：本脚本有意采用
# 显式 exit code 检查（不走 -e）——各检查项需聚合 PASS/FAIL 计数输出确定性报告；
# 迁移到 -euo 前须全量回归审计（存量清单见 script-conventions.md）。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# v3.28.1: 详设正文解析共用库（渲染块 + 旧版手写两类版式）
source "$SCRIPT_DIR/design_parse_lib.sh"

# ---------- 参数解析 ----------
FEATURE="${1:-}"
# v3.27.1: Runtime Profile 能力门禁——P4b 的 backend 路径/注解匹配/pom 检查当前
# 仅 java-spring-flyway 实现；其他 profile 在此 BLOCKED(MISSING_CAPABILITY)。
source "$SCRIPT_DIR/devflow_profile.sh"
source "$SCRIPT_DIR/perf-track.sh"
perf_start "P4b"
if ! STATE_DIR="${STATE_DIR:-.devflow}" devflow_profile_require_impl "$FEATURE" "P4b"; then
  exit 1
fi
# v3.15.10: 旧 `shift 2>/dev/null || true` 实为 shift-by-1（2> 是 fd-2 重定向）——功能正确
# 但极易被误读成 shift 2 而"修正"坏；改显式 shift
shift || true
PRD=""
DESIGN=""
CRITERIA=""
EVIDENCE=""
SERVICE=""
EXPECT_API="${EXPECT_API:-1}"
EXPECT_DATA="${EXPECT_DATA:-1}"
# v3.21.0: P2 详设模板模式（monolith|total|sub），透传 s2 --mode；
# 治理服务总分文档此前被迫做聚合投影（正是硬链接事故源头，FB-20260915-governance-p4b-monolith）
P4B_MODE="${P4B_MODE:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    # v3.15.9: 带值 flag 缺值前置检查（set -u 下裸 $2 unbound 崩溃报错不可读，且 flag 吞 flag）——p3/s0 v3.15.8 同型收口
    --prd)      [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --prd requires a non-flag value" >&2; exit 2; };      PRD="$2";      shift 2 ;;
    --design)   [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --design requires a non-flag value" >&2; exit 2; };   DESIGN="$2";   shift 2 ;;
    --criteria) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --criteria requires a non-flag value" >&2; exit 2; }; CRITERIA="$2"; shift 2 ;;
    --evidence) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --evidence requires a non-flag value" >&2; exit 2; }; EVIDENCE="$2"; shift 2 ;;
    --service)  [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --service requires a non-flag value" >&2; exit 2; };  SERVICE="$2";  shift 2 ;;
    --expect-api)  [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --expect-api requires a non-flag value" >&2; exit 2; };  EXPECT_API="$2";  shift 2 ;;
    --expect-data) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --expect-data requires a non-flag value" >&2; exit 2; }; EXPECT_DATA="$2"; shift 2 ;;
    --mode)     [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --mode requires a non-flag value" >&2; exit 2; };     P4B_MODE="$2"; shift 2 ;;
    *) echo "[P0] unknown argument: $1"; exit 2 ;;
  esac
done

# v3.21.0: mode 白名单校验——非法值 exit 2（与 s2 --mode 同口径），不静默降级 monolith
case "${P4B_MODE:-}" in
  ""|monolith|total|sub) ;;
  *) echo "[P0] invalid --mode: $P4B_MODE (monolith|total|sub)"; exit 2 ;;
esac

# ---------- 默认路径 ----------
[ -n "$FEATURE" ] || { echo "Usage: $0 <feature> [--prd path --design path --criteria path --evidence path --service name]"; exit 2; }
# v3.15.5: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 写穿项目外）与 grep -E 正则注入
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# v3.22.0: 文档层中文化（中文优先、英文回退）
source "$(cd "$(dirname "$0")" && pwd)/devflow_paths.sh"
devflow_feature_validate "$FEATURE" || exit 2
if [ -z "$PRD" ]; then
  PRD="docs/PRD/$FEATURE.md"; [ -f "$PRD" ] || PRD="docs/prd/$FEATURE.md"
fi
[ -n "$DESIGN" ]   || DESIGN="$(df_resolve_doc "$FEATURE" design .md design)"
[ -n "$DESIGN" ]   || DESIGN="docs/详细设计/$FEATURE-详细设计.md"
[ -n "$CRITERIA" ] || CRITERIA="$(df_resolve_doc "$FEATURE" acceptance .md requirements)"
[ -n "$CRITERIA" ] || CRITERIA="docs/需求/$FEATURE-验收点.md"
# implementation-evidence.tsv 为机器解析 TSV（表头契约），保留英文名，仅目录双语
if [ -z "$EVIDENCE" ]; then
  EVIDENCE="docs/测试/$FEATURE-implementation-evidence.tsv"; [ -f "$EVIDENCE" ] || EVIDENCE="docs/test/$FEATURE-implementation-evidence.tsv"
fi

# v3.15.5: STATE_DIR 同口径——此前写死 .devflow/，隔离部署（STATE_DIR 自定义）下
# 会读宿主项目 state（跨工作区污染）或错过冻结 manifest。
STATE_FILE="${STATE_DIR:-.devflow}/${FEATURE}.state.json"
FRONTEND_SCOPE="pc-web"
CLIENT_DIR="frontend"
if [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
  FRONTEND_SCOPE=$(jq -r '.scope.frontend // "pc-web"' "$STATE_FILE" 2>/dev/null || echo "pc-web")
  CLIENT_DIR=$(jq -r '.scope.frontend_dir // "frontend"' "$STATE_FILE" 2>/dev/null || echo "frontend")
fi
case "${FRONTEND_SCOPE:-}" in
  required|web) FRONTEND_SCOPE="pc-web" ;;
esac
case "$FRONTEND_SCOPE" in
  pc-web) CLIENT_DIR="${CLIENT_DIR:-frontend}" ;;
  required|web) FRONTEND_SCOPE="pc-web"; CLIENT_DIR="${CLIENT_DIR:-frontend}" ;;
  mini-program) CLIENT_DIR="${CLIENT_DIR:-miniprogram}" ;;
  app) CLIENT_DIR="${CLIENT_DIR:-app}" ;;
  not-applicable) CLIENT_DIR="" ;;
  *) echo "[P0] invalid frontend scope: $FRONTEND_SCOPE"; exit 2 ;;
esac

if { [ "$FRONTEND_SCOPE" = "pc-web" ] || [ "$FRONTEND_SCOPE" = "mini-program" ] || [ "$FRONTEND_SCOPE" = "app" ]; } && [ -f "$STATE_FILE" ]; then
  FROZEN_MANIFEST_SHA=$(jq -r '.scope.client_manifest_sha256 // empty' "$STATE_FILE" 2>/dev/null || true)
  if [ -z "$FROZEN_MANIFEST_SHA" ] || [ "$FROZEN_MANIFEST_SHA" = "null" ]; then
    echo "[P0] client manifest is not frozen; run devflow-state.sh client-freeze $FEATURE after P2"
    exit 1
  fi
  bash "$SCRIPT_DIR/client-adapter.sh" validate "$FRONTEND_SCOPE" "$CLIENT_DIR" --strict --expected-manifest-sha "$FROZEN_MANIFEST_SHA" >/dev/null || {
    echo "[P0] client manifest verification failed"
    exit 1
  }
fi

# ---------- 计数器与 WARN 详情证据 ----------
FAIL=0; PASS=0; WARN=0
p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
# v3.22.0: 告警详情改中文产物名（本 gate 自写证据，无外部消费者按旧名读取）
WARN_DETAILS="$(df_default_doc "$FEATURE" prd_vs_code_warnings .md test)"
mkdir -p "$(dirname "$WARN_DETAILS")" 2>/dev/null || true
{
  echo "# ${FEATURE} PRD-vs-Code WARN 详情"
  echo ""
  echo "VERSION=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$(cd "$(dirname "$0")/.." && pwd)/SKILL.md" 2>/dev/null | head -1)"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "WARN_DETAILS_SOURCE=p4_prd_vs_code.sh"
  echo ""
} > "$WARN_DETAILS" 2>/dev/null || true
warn() {
  echo "[WARN] $1"
  printf '%s\n' "- $1" >> "$WARN_DETAILS" 2>/dev/null || true
  WARN=$((WARN + 1))
}

# =============================================================================
# SECTION 0: 基础产物存在性检查
# =============================================================================
echo ""
echo "=== §0 基础产物存在性检查 ==="
for item in "$PRD" "$DESIGN" "$CRITERIA" "$EVIDENCE"; do
  if [ -f "$item" ]; then
    pass "artifact $item exists"
  else
    p0 "artifact missing: $item"
  fi
done

# =============================================================================
# SECTION 1: P2 详设覆盖率 Gate（调用外部脚本）
# =============================================================================
echo ""
echo "=== §1 P2 详设覆盖率 ==="
if [ -f "$DESIGN" ] && [ -f "$CRITERIA" ]; then
  # v3.21.0: --mode 透传 s2（P2_DESIGN_MODE 同型；空/monolith 不转发保持 s2 默认路径字节不变）
  S2_MODE_ARG=""
  case "${P4B_MODE:-}" in
    total|sub) S2_MODE_ARG="--mode=${P4B_MODE}" ;;
  esac
  if EXPECT_DATA="$EXPECT_DATA" EXPECT_API="$EXPECT_API" bash "$SCRIPT_DIR/s2_design_coverage_gate.sh" "$DESIGN" "$CRITERIA" $S2_MODE_ARG 2>/dev/null; then
    pass "P2 design coverage gate"
  else
    p0 "P2 design coverage gate FAILED"
  fi
else
  p0 "P2 skip: design or criteria missing"
fi

# =============================================================================
# SECTION 2: 逐项对比 — API 接口
# =============================================================================
echo ""
echo "=== §2 API 接口逐项对比 ==="

# 从详设中解析接口表（格式: | Method | Path | 描述 |）
parse_design_apis() {
  # v3.28.1: 统一走 design_parse_lib.sh——渲染块（详细定义|方法|路径）与
  # 手写方法首列概览表都能解析；此前只认方法首列，结构化项目会静默 skip。
  design_apis_from_doc "$1"
}

# 从代码中解析已实现的接口（Method + Path）
# v3.9.4-项目适配：组合类级 @RequestMapping 前缀 + 方法级路径；支持 @GetMapping("/x") 简写与 value=/path= 形式
parse_controller_methods() {
  local service="$1"
  local base_dir="backend/$service/src/main/java"
  [ -d "$base_dir" ] || return 0

  find "$base_dir" -name '*Controller.java' -type f 2>/dev/null | while read -r ctrl; do
    # 允许 @RequestMapping 在多行中书写，避免真实项目中的格式差异漏报接口前缀。
    prefix=$(grep -A2 -E '@RequestMapping' "$ctrl" 2>/dev/null | grep -oE '"[^"]*"' | head -1 | tr -d '"' || true)
    grep -E '@(Get|Post|Put|Delete|Patch)Mapping' "$ctrl" 2>/dev/null \
      | while read -r line; do
          method=$(echo "$line" | grep -oE 'Get|Post|Put|Delete|Patch' | head -1 || true)
          path=$(echo "$line" | grep -oE '(value|path)[[:space:]]*=[[:space:]]*"[^"]*"' | grep -oE '"[^"]*"' | head -1 | tr -d '"' || true)
          if [ -z "$path" ]; then
            path=$(echo "$line" | grep -oE '\([[:space:]]*"[^"]*"' | grep -oE '"[^"]*"' | head -1 | tr -d '"' || true)
          fi
          if [ -n "$method" ] && [ -n "$path" ]; then
            echo "${method}|${prefix}${path}"
          fi
        done
  done
}

if [ -f "$DESIGN" ]; then
  design_apis_raw=$(parse_design_apis "$DESIGN")
  design_api_count=$(printf '%s\n' "$design_apis_raw" | grep -c . || true)

  if [ -n "$SERVICE" ] && [ -d "backend/$SERVICE/src/main/java" ]; then
    code_apis_raw=$(parse_controller_methods "$SERVICE" 2>/dev/null)
    code_api_count=$(printf '%s\n' "$code_apis_raw" | grep -c . || true)

    if [ "$design_api_count" -eq 0 ]; then
      warn "详设中无接口定义，skip"
    else
      echo "  详设接口数: $design_api_count"
      echo "  代码接口数: $code_api_count"

      # 逐项检查详设接口
      missing_apis=0
      while IFS='|' read -r methods path; do
        [ -z "$methods" ] && continue
        [ -z "$path" ] && continue

        IFS='/' read -ra METHOD_ARRAY <<< "$methods"
        found=0
        for m in "${METHOD_ARRAY[@]}"; do
          m=$(echo "$m" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
          if printf '%s\n' "$code_apis_raw" | grep -qiF "$m|$path"; then
            found=1
            break
          fi
        done

        if [ "$found" -eq 0 ]; then
          p0 "API missing: $methods $path (详设有但代码未实现)"
          missing_apis=$((missing_apis + 1))
        fi
      done <<< "$design_apis_raw"

      if [ "$missing_apis" -eq 0 ]; then
        pass "所有详设接口已在代码中实现 ($design_api_count/$design_api_count)"
      fi
    fi
  else
    p0 "--service required for API verification"
  fi
else
  p0 "design file missing: $DESIGN"
fi

# =============================================================================
# SECTION 3: 逐项对比 — 数据库表（Flyway 四方言）
# =============================================================================
echo ""
echo "=== §3 数据库表逐项对比 ==="

parse_design_tables() {
  # v3.28.1: 优先解析 table-index 渲染块，回退旧版 CREATE TABLE 字面量（design_parse_lib.sh）
  design_tables_from_doc "$1"
}

parse_flyway_tables() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -name 'V*.sql' -type f -exec grep -hiE 'CREATE TABLE[[:space:]]+(IF NOT EXISTS[[:space:]]+)?[`"]?([a-z_][a-z0-9_]*)[`"]?' {} \; 2>/dev/null \
    | sed -E 's/.*CREATE TABLE[[:space:]]+(IF NOT EXISTS[[:space:]]+)?[`"]?([a-z_][a-z0-9_]*)[`"]?.*/\2/' \
    | sort -u || true
}

if [ -f "$DESIGN" ]; then
  design_tables=$(parse_design_tables "$DESIGN")
  design_table_count=$(printf '%s\n' "$design_tables" | grep -c . || true)

  if [ "$design_table_count" -eq 0 ]; then
    warn "详设中无 CREATE TABLE 定义，skip"
  else
    echo "  详设表数: $design_table_count"

    missing_table=0
    while IFS= read -r tbl; do
      [ -z "$tbl" ] && continue
      tbl=$(echo "$tbl" | tr '[:upper:]' '[:lower:]')

      for vendor in h2 postgresql oracle kingbase; do
        flyway_dir="backend/$SERVICE/src/main/resources/db/migration/$vendor"
        vendor_tables=$(parse_flyway_tables "$flyway_dir")
        if ! printf '%s\n' "$vendor_tables" | grep -qiF "$tbl"; then
          p0 "Table $tbl missing in Flyway $vendor"
          missing_table=$((missing_table + 1))
        fi
      done
    done <<< "$design_tables"

    if [ "$missing_table" -eq 0 ]; then
      pass "所有详设表的四方言 Flyway 脚本已生成 ($design_table_count 表 × 4 方言)"
    fi
  fi
fi

# =============================================================================
# SECTION 4: 逐项对比 — 字段（禁止宽松判断）
# =============================================================================
echo ""
echo "=== §4 字段逐项对比 ==="

parse_design_fields() {
  local design_file="$1"
  # v3.9.8：数据字典表改为五列（删'老系统来源/迁移转换规则'）；
  # 兼容存量七列表头（前五列一致，列位置不变，cols[2] 字段名解析不受影响）
  awk '
    /字段名.*类型.*约束.*默认值.*口径说明/ { in_dict=1; next }
    /^\|/ {
      if (!in_dict) next
      # v3.15.10: \s 在 BSD awk 按字面 s 处理（带空格分隔行不被跳过，原靠下游过滤兜底）——改 [ \t]*
      if ($0 ~ /^\|[ \t]*[-:]+[ \t]*\|/) next
      n = split($0, cols, "|")
      field = cols[2]
      gsub(/^[ \t]+|[ \t]+$/, "", field)
      if (field != "" && field ~ /^[a-z][a-z0-9_]*$/ && field ~ /_/) print field
      next
    }
    { in_dict=0 }
  ' "$design_file" 2>/dev/null | sort -u || true
}

parse_entity_fields() {
  local service="$1"
  # v3.9.4-项目适配：多服务模块按全模块实体并集比对（每服务持有独立表，并集精确）；
  # MyBatis-Plus 实体使用 @TableName 注解
  local base_dir="backend"
  [ -d "$base_dir" ] || return 0

  # 基类实体（BaseEntity 公共字段）一并纳入
  find "$base_dir"/*/src/main/java -name '*.java' -type f \( -exec grep -lE '@TableName|@Table[[:space:]]*\(|@Entity' {} \; -o -name 'BaseEntity.java' -print \) 2>/dev/null \
    | while read -r entity; do
        grep -oE 'private[[:space:]]+[_a-zA-Z][_a-zA-Z0-9$]*(<[^>]*>)?[[:space:]]+[_a-zA-Z][_a-zA-Z0-9$]*[[:space:]]*;' "$entity" 2>/dev/null \
          | sed -E 's/private[[:space:]]+[_a-zA-Z][_a-zA-Z0-9$]*(<[^>]*>)?[[:space:]]+([_a-zA-Z][_a-zA-Z0-9$]*)[[:space:]]*;/\2/' || true
      done | sort -u || true
}

if [ -f "$DESIGN" ] && [ -n "$SERVICE" ] && [ -d "backend/$SERVICE/src/main/java" ]; then
  design_fields=$(parse_design_fields "$DESIGN")
  design_field_count=$(printf '%s\n' "$design_fields" | grep -c . || true)

  if [ "$design_field_count" -eq 0 ]; then
    warn "详设中无字段定义，skip"
  else
    entity_fields=$(parse_entity_fields "$SERVICE")
    entity_field_count=$(printf '%s\n' "$entity_fields" | grep -c . || true)

    echo "  详设字段数: $design_field_count"
    echo "  代码字段数: $entity_field_count"

    # 禁止宽松判断：不允许缺字段（v3.9.4-项目适配：详设 snake_case 与实体 camelCase 归一化后比对）
    missing_field_count=0
    while IFS= read -r field; do
      [ -z "$field" ] && continue
      # v3.9.4-项目适配：BSD sed 不支持 \U，用 awk 做 snake_case→camelCase 归一化
      field_camel=$(printf '%s' "$field" | awk -F'_' '{out=$1; for(i=2;i<=NF;i++){out=out toupper(substr($i,1,1)) substr($i,2)}; print out}')
      if ! printf '%s\n' "$entity_fields" | grep -qiF "$field_camel"; then
        p0 "Field missing: $field (详设有但代码未实现)"
        missing_field_count=$((missing_field_count + 1))
      fi
    done <<< "$design_fields"

    if [ "$missing_field_count" -eq 0 ]; then
      pass "所有详设字段已在代码中实现 ($design_field_count/$design_field_count)"
    fi
  fi
fi

# =============================================================================
# SECTION 5: 逐项对比 — 前端页面
# =============================================================================
echo ""
echo "=== §5 前端页面逐项对比 ==="

parse_design_pages() {
  local design_file="$1"
  case "$FRONTEND_SCOPE" in
    pc-web)
      grep -E '(src/views|src/pages|views/|pages/)' "$design_file" 2>/dev/null \
        | grep -oE '(src/)?(views|pages)/[a-zA-Z0-9_/-]+\.(vue|tsx?|jsx?)' \
        | sed "s|^|$CLIENT_DIR/|" | sort -u || true
      ;;
    mini-program)
      # mini-program page route may be declared without a .wxml/.vue extension.
      grep -oE 'pages/[a-zA-Z0-9_/-]+(\.(wxml|vue))?' "$design_file" 2>/dev/null \
        | sed -E 's/\.(wxml|vue)$//' | sed "s|^|$CLIENT_DIR/|" | sort -u || true
      ;;
    app)
      grep -oE '(lib|src|ios|android)/[a-zA-Z0-9_./-]+\.(dart|tsx?|jsx?|swift|kt)' "$design_file" 2>/dev/null \
        | sed "s|^|$CLIENT_DIR/|" | sort -u || true
      ;;
  esac
}

parse_code_pages() {
  local base_dir="$CLIENT_DIR"
  [ -n "$base_dir" ] && [ -d "$base_dir" ] || return 0
  case "$FRONTEND_SCOPE" in
    pc-web) find "$base_dir/src" \( -name '*.vue' -o -name '*.tsx' -o -name '*.jsx' \) -type f 2>/dev/null | sort -u || true ;;
    mini-program) find "$base_dir/pages" \( -name '*.wxml' -o -name '*.vue' \) -type f 2>/dev/null | sed -E 's/\.(wxml|vue)$//' | sort -u || true ;;
    app) [ -f "$base_dir/devflow-client.json" ] && jq -r '.pages[]?' "$base_dir/devflow-client.json" 2>/dev/null | sed "s|^|$base_dir/|" | sort -u || true ;;
  esac
}

if [ -f "$DESIGN" ]; then
  design_pages=$(parse_design_pages "$DESIGN")
  design_page_count=$(printf '%s\n' "$design_pages" | grep -c . || true)

  if [ "$design_page_count" -eq 0 ]; then
    if [ "$FRONTEND_SCOPE" = "mini-program" ] || [ "$FRONTEND_SCOPE" = "app" ]; then
      p0 "详设缺少 $FRONTEND_SCOPE 页面契约"
    else
      warn "详设中无页面定义，skip"
    fi
  else
    code_pages=$(parse_code_pages)
    code_page_count=$(printf '%s\n' "$code_pages" | grep -c . || true)

    echo "  详设页面数: $design_page_count"
    echo "  代码页面数: $code_page_count"

    missing_page_count=0
    while IFS= read -r page; do
      [ -z "$page" ] && continue
      if ! printf '%s\n' "$code_pages" | grep -qxF "$page"; then
        p0 "Page missing: $page (详设有但代码未实现)"
        missing_page_count=$((missing_page_count + 1))
      fi
    done <<< "$design_pages"

    if [ "$missing_page_count" -eq 0 ]; then
      pass "所有详设页面已在代码中实现 ($design_page_count/$design_page_count)"
    fi
  fi
fi

# =============================================================================
# SECTION 6: 逐项对比 — 单元测试
# =============================================================================
echo ""
echo "=== §6 单元测试逐项对比 ==="

parse_service_classes() {
  local service="$1"
  local base_dir="backend/$service/src/main/java"
  [ -d "$base_dir" ] || return 0
  # v3.9.4-项目适配：仅 Service 接口要求同名测试类；Mapper/Repository 经 Service 测试覆盖（JaCoCo 强制行覆盖），
  # *ServiceImpl.java 不以 *Service.java 结尾故天然排除，Application 启动类同样排除
  find "$base_dir" -name '*Service.java' -type f -print0 2>/dev/null | xargs -0 -I{} basename {} .java || true
}

parse_test_classes() {
  local service="$1"
  local base_dir="backend/$service/src/test/java"
  [ -d "$base_dir" ] || return 0
  find "$base_dir" -name '*Test*.java' -type f -print0 2>/dev/null | xargs -0 -I{} basename {} .java || true
}

if [ -n "$SERVICE" ] && [ -d "backend/$SERVICE/src/main/java" ]; then
  svc_classes=$(parse_service_classes "$SERVICE")
  svc_class_count=$(printf '%s\n' "$svc_classes" | grep -c . || true)

  if [ "$svc_class_count" -eq 0 ]; then
    warn "无业务类，skip"
  else
    test_classes=$(parse_test_classes "$SERVICE")
    test_class_count=$(printf '%s\n' "$test_classes" | grep -c . || true)

    echo "  业务类数: $svc_class_count"
    echo "  测试类数: $test_class_count"

    missing_test_count=0
    while IFS= read -r cls; do
      [ -z "$cls" ] && continue
      test_name="${cls}Test"
      if ! printf '%s\n' "$test_classes" | grep -qi "^${test_name}$"; then
        p0 "Test missing: ${cls}Test (业务类有但测试类未实现)"
        missing_test_count=$((missing_test_count + 1))
      fi
    done <<< "$svc_classes"

    if [ "$missing_test_count" -eq 0 ]; then
      pass "所有业务类均有对应测试类 ($svc_class_count/$svc_class_count)"
    fi
  fi
fi

# =============================================================================
# SECTION 7: 服务级质量检查
# =============================================================================
echo ""
echo "=== §7 服务级质量检查 ==="

if [ -n "$SERVICE" ] && [ -d "backend/$SERVICE/src/main/java" ]; then
  echo "  --- @PreAuthorize 检查 ---"
  missing_perm=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if ! grep -q '@PreAuthorize' "$file" 2>/dev/null; then
      p0 "permission missing in: $file"
      missing_perm=$((missing_perm + 1))
    fi
  done <<< "$(find "backend/$SERVICE/src/main/java" -name '*Controller.java' -type f 2>/dev/null)"
  [ "$missing_perm" -eq 0 ] && pass "service permission coverage 100%" || true

  echo "  --- TODO/FIXME 检查 ---"
  todo_count=$(grep -rnE 'TODO|FIXME' "backend/$SERVICE/src/main/java" 2>/dev/null | grep -c . || true)
  if [ "$todo_count" -eq 0 ]; then
    pass "service TODO/FIXME=0"
  else
    p0 "service TODO/FIXME=$todo_count (必须清零才能进 P5)"
    grep -rnE 'TODO|FIXME' "backend/$SERVICE/src/main/java" 2>/dev/null | head -20 | sed 's/^/    /'
  fi

  echo "  --- 凭证可追溯性检查 ---"
  credential_issues=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    # v3.15.5: \x27 是 PCRE 十六进制转义，POSIX ERE 括号内退化为字面 { "\ x 2 7}——单引号凭证
    # （如 SQL 拼接 password='admin123'）恒漏检；改用 ["'] 字符类，[[:space:]] 口径与全脚本一致。
    if grep -qE "(password|secret|token)[[:space:]]*=[[:space:]]*[\"'][^\"']{1,20}[\"']" "$file" 2>/dev/null; then
      p0 "hardcoded credential in: $file"
      credential_issues=$((credential_issues + 1))
    fi
  done <<< "$(find "backend/$SERVICE/src/test" -name '*.java' -type f 2>/dev/null)"
  [ "$credential_issues" -eq 0 ] && pass "no hardcoded credentials in tests"
else
  p0 "--service required for quality checks"
fi

# =============================================================================
# SECTION 8: Acceptance Criteria vs Evidence 逐项对比
# =============================================================================
echo ""
echo "=== §8 Acceptance Criteria vs Evidence ==="

if [ -f "$CRITERIA" ] && [ -f "$EVIDENCE" ]; then
  criteria_ids=$(grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$CRITERIA" | sort -u)
  criteria_count=$(printf '%s\n' "$criteria_ids" | grep -c . || true)

  evidence_ids=$(tail -n +2 "$EVIDENCE" 2>/dev/null | cut -f1 | sort -u)
  evidence_count=$(printf '%s\n' "$evidence_ids" | grep -c . || true)

  echo "  Criteria IDs: $criteria_count"
  echo "  Evidence IDs: $evidence_count"

  if [ "$criteria_count" -gt 0 ]; then
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      if ! printf '%s\n' "$evidence_ids" | grep -qF "$id"; then
        p0 "acceptance ID $id missing evidence"
      fi
    done <<< "$criteria_ids"

    while IFS= read -r id; do
      [ -z "$id" ] && continue
      if ! printf '%s\n' "$criteria_ids" | grep -qF "$id"; then
        warn "unknown evidence ID: $id"
      fi
    done <<< "$evidence_ids"

    echo "  --- Evidence status 检查 ---"
    while IFS=$'\t' read -r id code_paths test_paths status; do
      [ -z "$id" ] && continue
      [ "$id" = "acceptance_id" ] && continue
      [ "$status" = "PASS" ] || { p0 "$id status=$status (必须为PASS)"; continue; }
      for group in "$code_paths" "$test_paths"; do
        [ -n "$group" ] && [ "$group" != "-" ] || { p0 "$id empty evidence path"; continue; }
        old_ifs="$IFS"; IFS=','
        for path in $group; do
          IFS="$old_ifs"
          [ -e "$path" ] || { p0 "$id missing path: $path"; }
          IFS=','
        done
        IFS="$old_ifs"
      done
    done < "$EVIDENCE"
  fi

  duplicate_count=$(tail -n +2 "$EVIDENCE" 2>/dev/null | cut -f1 | sort | uniq -d | grep -c . || true)
  [ "$duplicate_count" -gt 0 ] && p0 "duplicate evidence IDs=$duplicate_count"
fi

# =============================================================================
# SECTION 9: Flyway 四方言表集合一致性
# =============================================================================
echo ""
echo "=== §9 Flyway 四方言表集合一致性 ==="

if [ -n "$SERVICE" ]; then
  reference=""
  all_dialects_pass=1

  for vendor in h2 postgresql oracle kingbase; do
    flyway_dir="backend/$SERVICE/src/main/resources/db/migration/$vendor"
    if [ -d "$flyway_dir" ]; then
      _tmp_grep=$(mktemp)
      find "$flyway_dir" -name 'V*.sql' -type f -exec grep -hiE 'CREATE TABLE' {} \; 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -oE '[a-z_][a-z0-9_]*' | sort -u > "$_tmp_grep" 2>/dev/null || true
      tables=$(cat "$_tmp_grep")
      rm -f "$_tmp_grep"
      count=$(printf '%s\n' "$tables" | grep -c . || true)
      echo "  $vendor tables: $count"

      if [ -z "$reference" ]; then
        reference="$tables"
      else
        if [ "$reference" != "$tables" ]; then
          # 四方言 token 集合必须完全一致（铁律 #5）
          p0 "Flyway table set differs for $vendor"
          printf '%s\n' "$reference" | sed 's/^/    reference: /'
          printf '%s\n' "$tables" | sed "s/^/    $vendor: /"
          all_dialects_pass=0
        fi
      fi
    else
      p0 "Flyway $vendor directory missing"
      all_dialects_pass=0
    fi
  done

  if [ "$all_dialects_pass" -eq 1 ] && [ -n "$reference" ]; then
    ref_count=$(printf '%s\n' "$reference" | grep -c . || true)
    pass "四方言表集合完全一致 ($ref_count 表)"
  fi

  [ "${EXPECT_DATA:-1}" = "1" ] && [ -z "$reference" ] && p0 "no Flyway CREATE TABLE found"
fi

# =============================================================================
# SECTION 10: 技术选型 ↔ 代码依赖对账 (v3.16.26 NEW)
# 每条 FROZEN 硬约束必须能在代码中找到实现证据：
#   MUST_USE    → required_product 出现在 pom.xml 依赖或 resources 配置
#   MUST_NOT_USE → required_product 不得出现在 pom.xml / resources 配置
# =============================================================================
echo ""
echo "=== §10 技术选型 ↔ 代码依赖对账 ==="

if [ -n "${TECH_CONSTRAINTS_FILE:-}" ]; then
  TC_FILE="$TECH_CONSTRAINTS_FILE"
else
  TC_FILE="$(df_resolve_doc "$FEATURE" constraints .md requirements)"
  [ -n "$TC_FILE" ] || TC_FILE="docs/需求/${FEATURE}-技术约束.md"
fi
if [ -f "$TC_FILE" ]; then
  source "$SCRIPT_DIR/tech_constraints_lib.sh"
  DEP_ROOT="backend"
  [ -n "$SERVICE" ] && [ -d "backend/$SERVICE" ] && DEP_ROOT="backend/$SERVICE"
  if tc_check_dependencies "$TC_FILE" "$DEP_ROOT"; then
    pass "tech constraints ↔ code dependencies consistent ($DEP_ROOT)"
  else
    tc_check_dependencies "$TC_FILE" "$DEP_ROOT" | while IFS= read -r v; do p0 "$v"; done
  fi
else
  p0 "artifact missing: $TC_FILE (选型报告↔代码依赖对账无法执行)"
fi

# =============================================================================
# FINAL: 输出汇总
# =============================================================================
echo ""
echo "========================================"
echo "P4 RESULT: PASS=$PASS P0=$FAIL P1=0 WARN=$WARN"
echo "========================================"

# ---------- 收据双写：WARN 必须带可追溯详情 ----------
STATE_DIR="${STATE_DIR:-.devflow}"
RECEIPT_DIR="$STATE_DIR/${FEATURE:?FEATURE is required for receipt (default fallback removed v3.14.0)}/gates/P4b"
mkdir -p "$RECEIPT_DIR" 2>/dev/null
{
  echo "EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)"
  echo "VERSION=p4b@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "PHASE=P4b"
  echo "MODE=${P4B_MODE:-monolith}"
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
  echo "CONSTRAINTS_PATH=$TC_FILE"
  if [ -f "$TC_FILE" ]; then
    source "$SCRIPT_DIR/tech_constraints_lib.sh"
    echo "CONSTRAINTS_SHA256=$(tc_sha256 "$TC_FILE")"
  fi
  echo "WARN_DETAILS_PATH=$WARN_DETAILS"
  if [ -f "$WARN_DETAILS" ]; then
    if command -v shasum >/dev/null 2>&1; then echo "WARN_DETAILS_SHA256=$(shasum -a 256 "$WARN_DETAILS" | awk '{print $1}')"; else echo "WARN_DETAILS_SHA256=$(sha256sum "$WARN_DETAILS" | awk '{print $1}')"; fi
  else
    echo "WARN_DETAILS_SHA256=missing"
  fi
  # v3.15.5: 收据契约统一——EVIDENCE_PATH/EVIDENCE_SHA256 与其他 gate 同名（audit-receipts 统一校验口径）
  echo "EVIDENCE_PATH=$WARN_DETAILS"
  if [ -f "$WARN_DETAILS" ]; then
    if command -v shasum >/dev/null 2>&1; then echo "EVIDENCE_SHA256=$(shasum -a 256 "$WARN_DETAILS" | awk '{print $1}')"; else echo "EVIDENCE_SHA256=$(sha256sum "$WARN_DETAILS" | awk '{print $1}')"; fi
  else
    echo "EVIDENCE_SHA256=missing"
  fi
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt" 2>/dev/null
echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
DOCS_MIRROR="docs/${FEATURE:?FEATURE is required for receipt (default fallback removed v3.14.0)}/gates/P4b"
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"

if [ "$FAIL" -gt 0 ]; then
  echo "P4 GATE: FAIL (P0 > 0, blocking)"
  echo ""
  echo "阻塞原因:"
  echo "  - 详设有但代码未实现的接口/表/字段/页面"
  echo "  - TODO/FIXME 未清零"
  echo "  - 凭证硬编码"
  echo "  - Acceptance ID 缺失 evidence"
  echo "  - Evidence status != PASS"
  exit 1
fi

if [ "$PASS" -eq 0 ] && [ "$WARN" -gt 0 ]; then
  echo "P4 GATE: WARN (空实现，所有项均为 warn)"
  exit 0
fi

echo "P4 GATE: PASS"
perf_end "P4b"
exit 0
