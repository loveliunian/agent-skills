#!/usr/bin/env bash
# ============================================================
# devflow-state.sh 
# ------------------------------------------------------------
# 用途：devflow 工作流状态管理（checkpoint / resume / status）
# 用法：
#   bash "$SKILL_ROOT/scripts/devflow-state.sh" init <feature>          # 初始化工作流
#   bash "$SKILL_ROOT/scripts/devflow-state.sh" checkpoint <feature> [note] # 保存检查点
#   bash "$SKILL_ROOT/scripts/devflow-state.sh" resume <feature>        # 从检查点恢复
#   bash "$SKILL_ROOT/scripts/devflow-state.sh" status <feature>       # 查看状态
#   bash "$SKILL_ROOT/scripts/devflow-state.sh" complete <feature> <phase>  # 标记阶段完成
#   bash "$SKILL_ROOT/scripts/devflow-state.sh" complete-s <feature> <P0..P10> # 标记方法论阶段完成
#   bash "$SKILL_ROOT/scripts/devflow-state.sh" list                    # 列出所有工作流
# ============================================================

set -eo pipefail

# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/py_runtime.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="${SKILL_ROOT:-$SCRIPT_DIR/..}"
WORKSPACE="${WORKSPACE:-$(pwd)}"
STATE_DIR="${STATE_DIR:-$WORKSPACE/.devflow}"
mkdir -p "$STATE_DIR"
# v3.15.13: generate_from_template 直调纵深防御依赖（白名单共享校验，见函数内注释）
source "$SCRIPT_DIR/devflow_feature.sh"
# v3.16.7（N28-P1-1）: 统一收据契约库（_receipt_ws_base/_receipt_norm_file 物理归一
# 助手）——verify_evidence_receipt 边界判定复用同口径；幂等 source（重复加载仅重定义函数）
source "$SCRIPT_DIR/devflow_receipt.sh"

# 颜色定义
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; NC='\033[0m'
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
success(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
# ─────────────────────────────────────────────────────────────────────────────
# 模板路径函数 ()
# ─────────────────────────────────────────────────────────────────────────────
get_template_path() {
  local template_name="$1"
  echo "$SKILL_ROOT/templates/$template_name"
}

# 列出所有可用模板（排除 INDEX 和 _ 开头文件）
list_templates() {
  echo "可用模板:"
  for f in "$SKILL_ROOT/templates/"*.md; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    case "$name" in
      INDEX*|_*) continue ;;
    esac
    echo "  - $name"
  done
}

# Phase → 模板名 映射表
get_template_for_phase() {
  local phase="$1"
  case "$phase" in
    P0)       echo "需求澄清-模板.md" ;;
    P0b)      echo "PRD评审-模板.md" ;;
    P1)       echo "设计决策记录-模板.md" ;;
    P2)       echo "详细设计-完整版-模板.md" ;;
    P3b)      echo "代码审查报告-模板.md" ;;
    P4|P4b)   echo "PRD验证报告-模板.md" ;;
    P5)       echo "测试用例-模板.md" ;;
    P7)       echo "部署记录-模板.md" ;;
    P8)       echo "监控配置-模板.md" ;;
    P10)      echo "复盘报告-模板.md" ;;
    *)        echo "" ;;
  esac
}

# 从模板生成产物（替换多种占位符）
generate_from_template() {
  local feature="$1"
  local phase="$2"
  local output_path="$3"

  # v3.15.13（P1 修复）: 直调子脚本纵深防御——devflow-state-template.sh 可绕过
  # dispatcher 直达此函数，feature/output_path 零信任校验：
  #   a) feature 白名单（防 ../evil 路径穿越/正则注入）；
  #   b) output_path 经 python3 realpath 物理归一化后必须落在 workspace 内
  #      （PoC: generate "../evil" P0 /tmp/x.md 曾可越界写穿 .devflow 之外；
  #      字符串前缀匹配可被 ../ 绕过，故必须归一化后判定）。
  devflow_feature_validate "$feature" || { error "feature 名称不合法: $feature"; return 2; }
  local norm_ws norm_out
  norm_ws=$(cd "$WORKSPACE" 2>/dev/null && pwd -P) || { error "workspace 不可达: $WORKSPACE"; return 1; }
  case "$output_path" in
    /*) norm_out=$("${DEVFLOW_PY[@]}" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$output_path" 2>/dev/null) ;;
    *) norm_out=$("${DEVFLOW_PY[@]}" -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1], sys.argv[2])))' "$norm_ws" "$output_path" 2>/dev/null) ;;
  esac
  [ -n "$norm_out" ] || { error "输出路径归一化失败: $output_path"; return 1; }
  case "$norm_out" in
    "$norm_ws"/*) : ;;
    *) error "输出路径越出 workspace: $output_path → $norm_out"; return 1 ;;
  esac
  
  local template_name
  template_name="$(get_template_for_phase "$phase")"
  if [ -z "$template_name" ]; then
    error "未知 Phase: $phase"
    return 1
  fi
  
  local template_path
  template_path="$(get_template_path "$template_name")"
  if [ ! -f "$template_path" ]; then
    error "模板不存在: $template_path"
    return 1
  fi
  
  # 创建输出目录
  mkdir -p "$(dirname "$output_path")"
  
  # 替换多种占位符模式
  # v3.26.2: FEATURE 采用词边界替换——旧 s/FEATURE/x/g 曾会误伤 FEATURED/FEATURE_TABLE
  # 等英文词（潜在数据损坏）。
  # v3.29.8（Linux 实证修复）: v3.26.2 声称 [[:<:]]/[[:>:]] 双平台支持是错的——GNU sed
  # 直接报 "Invalid character class name"（Linux 全量测试抓到的首个跨平台缺陷）。
  # 改为双方都支持的可移植写法：非词字符捕获 + 行首/行尾分支（词字符类 [:alnum:] 双平台
  # 一致）。feature 经白名单校验（[A-Za-z0-9._-]），替换侧无 &\/ 转义风险。
  local temp_file
  temp_file=$(mktemp)
  sed -e "s/{FeatureName}/${feature}/g" \
      -e "s/FEATURE\([^A-Za-z0-9_]\)/${feature}\1/g" \
      -e "s/FEATURE\$/${feature}/" \
      -e "s/\([^A-Za-z0-9_]\)FEATURE/\1${feature}/g" \
      "$template_path" > "$temp_file"
  
  mv "$temp_file" "$output_path"
  success "从模板生成: $output_path"
}

# 阶段名称查询函数
get_phase_name() {
  case "$1" in
    P0) echo "需求澄清" ;;
    P0b) echo "PRD评审" ;;
    P1) echo "技术选型" ;;
    P2) echo "详细设计" ;;
    P2a) echo "详细设计评审" ;;
    P2b) echo "原型Demo" ;;
    P3) echo "规范实现" ;;
    P3b) echo "代码审查" ;;
    P3c) echo "安全审计" ;;
    P3d) echo "性能审计" ;;
    P3cd) echo "安全与性能审计" ;;
    P4) echo "PRD验证" ;;
    P4b) echo "PRD-vs-Code" ;;
    P5) echo "测试用例" ;;
    P6) echo "测试执行" ;;
    P7) echo "发布部署" ;;
    P8) echo "监控配置" ;;
    P9) echo "文档更新" ;;
    P10) echo "知识沉淀" ;;
    *) echo "$1" ;;
  esac
}

get_stage_name() {
  case "$1" in
    P0) echo "需求基线与原子验收点" ;;
    P1) echo "概设定纲与工程事实源" ;;
    P2) echo "模块详设字段级标准与迁移映射" ;;
    P3) echo "试点模块实施" ;;
    P5) echo "两类测试门控" ;;
    P6) echo "图谱构建与全量执行" ;;
    GRAPH_HEALTH) echo "图谱健康" ;;
    P10) echo "经验反哺" ;;
    *) echo "$1" ;;
  esac
}

# 状态文件路径
get_state_file() {
  local feature="$1"
  echo "$STATE_DIR/${feature}.state.json"
}

# Gate 收据路径 (P0-6 修复: 状态机绕过 Gate)
get_stage_gate_receipt() {
  local feature="$1"
  local stage="$2"
  # 收据目录: .devflow/<feature>/gates/<stage>/
  echo "$STATE_DIR/${feature}/gates/${stage}/receipt.txt"
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# v3.14.0: 版本单一事实源 = SKILL.md frontmatter；运行时校验动态派生，杜绝多处硬编码漂移
devflow_version() {
  local ver
  ver=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$SCRIPT_DIR/../SKILL.md" 2>/dev/null | head -1)
  printf '%s' "${ver:-unknown}"
}

verify_evidence_receipt() {
  local receipt_file="$1" phase="$2" evidence_path expected actual resolved_path declared_phase version expected_ver
  declared_phase=$(sed -n 's/^PHASE=//p' "$receipt_file" | head -1)
  version=$(sed -n 's/^VERSION=//p' "$receipt_file" | head -1)
  [ "$declared_phase" = "$phase" ] || { error "Gate 收据阶段不匹配: $declared_phase != $phase"; return 1; }
  expected_ver=$(devflow_version)
  printf '%s' "$version" | grep -qE "@${expected_ver//./\\.}$" || { error "Gate 收据版本不匹配: $version (expected @$expected_ver)"; return 1; }
  evidence_path=$(sed -n 's/^EVIDENCE_PATH=//p' "$receipt_file" | head -1)
  expected=$(sed -n 's/^EVIDENCE_SHA256=//p' "$receipt_file" | head -1)
  [ -n "$evidence_path" ] && [ -n "$expected" ] || {
    error "Gate 收据缺少 EVIDENCE_PATH/EVIDENCE_SHA256: $receipt_file"
    return 1
  }
  # v3.16.7（N28-P1-1）: 词法前缀匹配 → cd -P 物理归一 + 归一后边界判定。
  # 双缺陷：① 词法前缀可被 $WS/../外部 与符号链接逃逸（cd -P 展开后即真身）；
  # ② 相对路径分支此前完全无边界检查（PoC：EVIDENCE_PATH=../workspace-外稳定文件
  # 绑定哈希一致即可过 complete——本函数是 P3cd/P4/P5/P7-P10 七类阶段的主校验器）。
  local _ws_base
  _ws_base=$(_receipt_ws_base)
  [ -n "$_ws_base" ] || { error "workspace 不可解析（物理归一失败）: $WORKSPACE"; return 1; }
  case "$evidence_path" in
    /*) resolved_path="$evidence_path" ;;
    *) resolved_path="$WORKSPACE/$evidence_path" ;;
  esac
  resolved_path=$(_receipt_norm_file "$resolved_path") \
    || { error "Gate 证据路径不可解析（父目录缺失）: $evidence_path"; return 1; }
  [ -n "$resolved_path" ] || { error "Gate 证据路径不可解析: $evidence_path"; return 1; }
  case "$resolved_path" in
    "$_ws_base"|"$_ws_base"/*) ;;
    *) error "Gate 证据路径越出 workspace: $evidence_path"; return 1 ;;
  esac
  [ -f "$resolved_path" ] || { error "Gate 证据文件不存在: $evidence_path"; return 1; }
  actual=$(hash_file "$resolved_path")
  [ "$actual" = "$expected" ] || {
    error "Gate 证据哈希不匹配: $evidence_path"
    echo "  期望: $expected"
    echo "  实际: $actual"
    return 1
  }
  local report_path report_expected report_resolved report_actual
  report_path=$(sed -n 's/^REPORT_PATH=//p' "$receipt_file" | head -1)
  report_expected=$(sed -n 's/^REPORT_SHA256=//p' "$receipt_file" | head -1)
  if [ -n "$report_path" ]; then
    # v3.16.7（N28-P1-1）: 报告路径同型物理归一 + 边界（与证据路径同口径）
    case "$report_path" in
      /*) report_resolved="$report_path" ;;
      *) report_resolved="$WORKSPACE/$report_path" ;;
    esac
    report_resolved=$(_receipt_norm_file "$report_resolved") \
      || { error "Gate 报告路径不可解析（父目录缺失）: $report_path"; return 1; }
    [ -n "$report_resolved" ] || { error "Gate 报告路径不可解析: $report_path"; return 1; }
    case "$report_resolved" in
      "$_ws_base"|"$_ws_base"/*) ;;
      *) error "Gate 报告路径越出 workspace: $report_path"; return 1 ;;
    esac
    [ -n "$report_expected" ] && [ -f "$report_resolved" ] || { error "Gate 收据报告哈希缺失或文件不存在: $report_path"; return 1; }
    report_actual=$(hash_file "$report_resolved")
    [ "$report_actual" = "$report_expected" ] || { error "Gate 报告哈希不匹配: $report_path"; return 1; }
  fi
}

# v3.15.1: 收据 SKILL_TREE 硬门禁——收据必须携带 SKILL_TREE 且等于 state 冻结树。
# 不一致时唯一放行路径：存在有效 SKILL-TREE-MIGRATION 迁移收据
# （EXIT_CODE=0、PHASE=SKILL-TREE-MIGRATION、FROM_TREE=收据树、TO_TREE=state 冻结树）。
# 返回 0=通过；1=阻断（错误信息已打印）。
verify_skill_tree_receipt() {
  local receipt_file="$1" state_file="$2"
  local rc_tree state_tree feature mig_receipt mig_exit mig_phase mig_from mig_to
  rc_tree=$(sed -n 's/^SKILL_TREE=//p' "$receipt_file" | head -1)
  if [ -z "$rc_tree" ] || ! printf '%s' "$rc_tree" | grep -qE '^[0-9a-f]{64}$'; then
    error "Gate 收据缺少合法 SKILL_TREE（64 位十六进制）: $receipt_file"
    return 1
  fi
  state_tree=$(jq -r '.scope.skill_tree_sha256 // empty' "$state_file" 2>/dev/null)
  if [ -z "$state_tree" ]; then
    error "state 缺少冻结 skill 树锚点（scope.skill_tree_sha256）——运行 'devflow-state.sh migrate-tree <feature>' 显式建立"
    return 1
  fi
  if [ "$rc_tree" = "$state_tree" ]; then
    return 0
  fi
  # 不一致：唯一放行路径 = 显式迁移收据（旧树收据凭 FROM_TREE 对账放行）
  feature=$(jq -r '.feature // empty' "$state_file" 2>/dev/null)
  mig_receipt="$STATE_DIR/${feature}/gates/SKILL-TREE-MIGRATION/receipt.txt"
  if [ -f "$mig_receipt" ]; then
    mig_exit=$(grep '^EXIT_CODE=' "$mig_receipt" | head -1 | cut -d= -f2)
    mig_phase=$(sed -n 's/^PHASE=//p' "$mig_receipt" | head -1)
    mig_from=$(sed -n 's/^FROM_TREE=//p' "$mig_receipt" | head -1)
    mig_to=$(sed -n 's/^TO_TREE=//p' "$mig_receipt" | head -1)
    if [ "$mig_exit" = "0" ] && [ "$mig_phase" = "SKILL-TREE-MIGRATION" ] \
       && [ "$mig_from" = "$rc_tree" ] && [ "$mig_to" = "$state_tree" ]; then
      warn "收据树 hash 属迁移前旧树（${mig_from} → ${mig_to}），经 SKILL-TREE-MIGRATION 迁移收据放行"
      return 0
    fi
  fi
  error "SKILL_TREE 硬门禁阻断: 收据树 $rc_tree != state 冻结树 $state_tree"
  echo "  若确系 skill 升级导致，运行 'devflow-state.sh migrate-tree ${feature:-<feature>}' 显式迁移并留痕"
  return 1
}

# 计算产物哈希 (P0-6 修复)
compute_artifact_hash() {
  local feature="$1"
  local stage="$2"
  local -a artifact_dirs=()
  local client_dir=""
  local state_file
  state_file=$(get_state_file "$feature")
  if [ -f "$state_file" ] && command -v jq >/dev/null 2>&1; then
    client_dir=$(jq -r '.scope.frontend_dir // empty' "$state_file" 2>/dev/null || true)
  fi

  # v3.22.0: 文档层中文化——docs 产物目录中英双语都纳入哈希（存在才计，下方 [ -d ] 判定）
  case "$stage" in
    P0|P0b)    artifact_dirs=("docs/需求" "docs/requirements") ;;
    P1|P2)     artifact_dirs=("docs/详细设计" "docs/detailed-design") ;;
    P3)        artifact_dirs=("backend"); [ -n "$client_dir" ] && artifact_dirs+=("$client_dir") ;;
    P3b|P3c|P3d) artifact_dirs=("docs/评审" "docs/review") ;;
    P4|P4b)    artifact_dirs=("docs/测试" "docs/test") ;;
    P5)        artifact_dirs=("docs/测试用例" "docs/test-cases") ;;
    P6*)       artifact_dirs=("docs/测试" "docs/test" "docs/测试报告" "docs/tests"); [ -n "$client_dir" ] && artifact_dirs+=("$client_dir") ;;
    P7)        artifact_dirs=("deploy") ;;
    P8)        artifact_dirs=("docs/发布" "docs/deploy") ;;
    P9|GRAPH_HEALTH) artifact_dirs=("docs") ;;
    P10)       artifact_dirs=("docs/复盘" "docs/retrospectives" "docs/知识沉淀" "docs/knowledge") ;;
    *)         artifact_dirs=(".") ;;
  esac

  local found=0
  for dir in "${artifact_dirs[@]}"; do [ -d "$dir" ] && found=1; done
  [ "$found" -eq 1 ] || { echo "no-artifacts"; return; }

  {
    for dir in "${artifact_dirs[@]}"; do
      [ -d "$dir" ] || continue
      find "$dir" -type f \( -name "*.md" -o -name "*.java" -o -name "*.ts" -o -name "*.tsx" -o -name "*.jsx" -o -name "*.vue" -o -name "*.wxml" -o -name "*.wxss" -o -name "*.json" -o -name "*.dart" -o -name "*.swift" -o -name "*.kt" -o -name "*.xml" -o -name "*.sql" \) -print 2>/dev/null
    done
  } | sort | while IFS= read -r file; do
    printf '%s\n' "$file"
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$file"; else sha256sum "$file"; fi
  done | {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
  }
}

# 更新阶段状态
update_stage_status() {
  local feature="$1"
  local stage="$2"
  local status="$3"  # in_progress | completed | blocked
  local state_file
  state_file=$(get_state_file "$feature")

  [ ! -f "$state_file" ] && return 1

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # 判断是 P-Phase 还是方法论轨阶段
  # v3.28.9: 新 state 不再生成 methodology_stages（死轨——m01-base 实测从未推进、
  # 与 current_phase 永久矛盾）；历史 state 里残留的该轨仅在已存在时可写。
  if echo "$stage" | grep -qE '^P[0-9]'; then
    jq --arg phase "$stage" --arg status "$status" --arg now "$now" \
       '.phases[$phase].status = $status | .updated_at = $now' \
       "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  elif jq -e 'has("methodology_stages")' "$state_file" >/dev/null 2>&1; then
    jq --arg stage "$stage" --arg status "$status" --arg now "$now" \
       '.methodology_stages[$stage].status = $status | .updated_at = $now' \
       "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  else
    warn "methodology_stages 已于 v3.28.9 移除（死轨）——忽略对 '$stage' 的状态写入；P-Phase 状态机为准"
  fi
}

# === Lifecycle commands (init/checkpoint/resume/status) ===
cmd_init() {
  local feature="${1:-}"
  # v3.14.0: 禁止空名/default/路径符 feature，防止收据混入 default 目录（code02/code03 教训）
  case "$feature" in
    ""|default)
      error "init 需要明确的 feature 名称（禁止为空或 'default'）"
      return 2 ;;
    */*|.*)
      error "feature 名称不能包含 '/' 或以 '.' 开头: $feature"
      return 2 ;;
  esac
  shift
  local frontend_scope="pc-web"
  local frontend_dir="frontend"
  # v3.27.1: Runtime Profile 冻结（未指定时缺省参考实现 java-spring-flyway，
  # 向后兼容历史项目；须存在 references/profiles/<id>.md，fail-closed）
  local profile_id="java-spring-flyway"
  for arg in "$@"; do
    case "$arg" in
      --frontend=required|--frontend=web|--frontend=pc-web) frontend_scope="pc-web" ;;
      --frontend=mini-program) frontend_scope="mini-program"; frontend_dir="miniprogram" ;;
      --frontend=app) frontend_scope="app"; frontend_dir="app" ;;
      --frontend=not-applicable) frontend_scope="not-applicable"; frontend_dir="" ;;
      --frontend-dir=*) frontend_dir="${arg#--frontend-dir=}" ;;
      --profile=*)
        profile_id="${arg#--profile=}"
        case "$profile_id" in
          ''|*[!A-Za-z0-9._-]*) error "init 参数无效: --profile=<id>（id 须为 [A-Za-z0-9._-]）"; return 2 ;;
        esac
        if [ ! -f "$SKILL_ROOT/references/profiles/${profile_id}.md" ]; then
          error "--profile=$profile_id 不存在对应 Profile 文件（references/profiles/${profile_id}.md）；可用: $(cd "$SKILL_ROOT/references/profiles" 2>/dev/null && ls *.md 2>/dev/null | sed 's/\.md$//' | tr '\n' ' ')"
          return 2
        fi
        ;;
      *) error "init 参数无效: ${arg}（--frontend=pc-web|mini-program|app|not-applicable；可选 --frontend-dir=<path>、--profile=<id>）"; return 2 ;;
    esac
  done
  if [ "$frontend_scope" = "not-applicable" ] && [ -n "$frontend_dir" ]; then
    error "not-applicable 不能指定 --frontend-dir"
    return 2
  fi
  local state_file
  state_file=$(get_state_file "$feature")
  
  if [ -f "$state_file" ]; then
    warn "工作流 '$feature' 已存在，使用 resume 继续"
    return 1
  fi
  
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$state_file" <<'JEOF'
{
  "version": "DEVFLOW_VERSION_PLACEHOLDER",
  "feature": "FEATURE_PLACEHOLDER",
  "created_at": "NOW_PLACEHOLDER",
  "updated_at": "NOW_PLACEHOLDER",
  
  "current_phase": "P0",

  "phases": {
    "P0":  {"name": "需求澄清",    "status": "in_progress", "started_at": "NOW_PLACEHOLDER", "completed_at": null},
    "P0b": {"name": "PRD评审",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P1":  {"name": "技术选型",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P2":  {"name": "详细设计",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P2a": {"name": "详细设计评审", "status": "pending",    "started_at": null,  "completed_at": null},
    "P2b": {"name": "原型Demo",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P3":  {"name": "规范实现",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P3b": {"name": "代码审查",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P3c": {"name": "安全审计",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P3d": {"name": "性能审计",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P4":  {"name": "PRD验证",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P4b": {"name": "PRD-vs-Code","status": "pending",    "started_at": null,  "completed_at": null},
    "P5":  {"name": "测试用例",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P6":  {"name": "测试执行",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P7":  {"name": "发布部署",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P8":  {"name": "监控配置",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P9":  {"name": "文档更新",    "status": "pending",    "started_at": null,  "completed_at": null},
    "P10": {"name": "知识沉淀",    "status": "pending",    "started_at": null,  "completed_at": null}
  },

  "acceptance_criteria": {
    "count": 0,
    "frozen": 0,
    "complete": 0
  },

  "scope": {
    "frontend": "FRONTEND_SCOPE_PLACEHOLDER",
    "frontend_dir": "FRONTEND_DIR_PLACEHOLDER",
    "profile_id": "PROFILE_PLACEHOLDER",
    "client_manifest_sha256": null
  },
  
  "first_pass_snapshot": {
    "path": null,
    "accuracy": null,
    "created_at": null
  },
  
  "graph_index": {
    "status": "unknown",
    "index_path": null,
    "health_score": null
  },
  
  "checkpoints": [],
  "blocks": [],
  "notes": ""
}

JEOF

  # 替换占位符 (jq 方式,跨平台兼容,无 .bak 残留)
  # 注:链式 | 后 . 会变为子元素;采用"重新赋值子结构"方式,避免路径变更
  jq --arg feature "$feature" --arg now "$now" --arg frontend_scope "$frontend_scope" --arg frontend_dir "$frontend_dir" --arg ver "$(devflow_version)" --arg profile "$profile_id" \
     '.version = $ver | .feature = $feature
     | .created_at = $now
     | .updated_at = $now
     | .scope.frontend = $frontend_scope
     | .scope.frontend_dir = $frontend_dir
     | .scope.profile_id = $profile
     | .phases = (.phases | to_entries
         | map(.value.started_at = (if .value.started_at == "NOW_PLACEHOLDER" then $now else .value.started_at end))
         | from_entries)' \
    "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
  rm -f "${state_file}.bak"

  # v3.15.1: init fail-closed——树哈希无法计算时拒绝初始化（complete/audit 均依赖该锚点）
  local skill_tree_hash
  skill_tree_hash=$(bash "$SCRIPT_DIR/gate-skill-tree.sh" 2>/dev/null)
  if ! printf '%s' "$skill_tree_hash" | grep -qE '^[0-9a-f]{64}$'; then
    error "无法计算 skill 树哈希——拒绝初始化（fail-closed）"
    return 1
  fi

  # 创建 gates 目录结构 + P0 初始收据 (init = P0 通过基线)；收据与 docs 镜像双写
  mkdir -p "$STATE_DIR/${feature}/gates/P0" "$WORKSPACE/docs/${feature}/gates/P0"
  printf "EXIT_CODE=0\nVERSION=state-init@$(devflow_version)\nPHASE=P0\nSKILL_TREE=%s\nARTIFACT_HASH=no-artifacts\nOUTPUT=P0 baseline initialized\n" "$skill_tree_hash" > "$STATE_DIR/${feature}/gates/P0/receipt.txt"
  cp "$STATE_DIR/${feature}/gates/P0/receipt.txt" "$WORKSPACE/docs/${feature}/gates/P0/receipt.txt"

  # v3.14.0: 反哺闭环可见性——init 时列出历史项目未处置的 PROPOSED feedback，
  # 防止教训停留在队列层（code02/code03 教训：9 条 PROPOSED 悬置导致同类问题复发）
  local fb_file pending_fb=0
  for fb_file in "$STATE_DIR"/*/feedback/feedback.md; do
    [ -f "$fb_file" ] || continue
    [ "$(dirname "$(dirname "$fb_file")")" = "$STATE_DIR/${feature}" ] && continue
    if grep -qE '^STATUS=PROPOSED$' "$fb_file"; then
      if [ "$pending_fb" -eq 0 ]; then
        echo "  ⚠ 发现未处置的历史 feedback（PROPOSED），请在 P0 澄清时一并请用户批准或显式 defer："
        pending_fb=1
      fi
      echo "    - $fb_file ($(grep -c '^STATUS=PROPOSED$' "$fb_file" 2>/dev/null || echo '?') 条待处置)"
    fi
  done

  # v3.15.0/v3.15.1: 冻结生成该 state 的 skill 树 hash——收据/审计可据此区分同名版本的不同内容树
  # （skill_tree_hash 已在上方 fail-closed 计算并校验为 64 位十六进制）
  jq --arg tree "$skill_tree_hash" --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '.scope.skill_tree_sha256 = $tree | .updated_at = $now' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  echo "  Skill 树: $skill_tree_hash"
  success "工作流 $feature 已初始化 ($(devflow_version))"
  echo "  当前阶段: P0 ($(get_phase_name P0))"
  echo "  阶段判定唯一来源: current_phase / phases（methodology_stages 已于 v3.28.9 移除）"
  echo "  状态文件: $state_file"
  echo "  Gate 目录: $STATE_DIR/${feature}/gates/"
  echo "  前端范围: $frontend_scope"
  echo "  Runtime Profile: $profile_id"
  [ -n "$frontend_dir" ] && echo "  客户端目录: $frontend_dir"
  return 0
}

cmd_client_freeze() {
  local feature="$1"
  local state_file
  state_file=$(get_state_file "$feature")
  [ -f "$state_file" ] || { error "工作流 '$feature' 不存在"; return 1; }
  command -v jq >/dev/null 2>&1 || { error "client-freeze 需要 jq"; return 1; }

  local platform client_dir manifest_hash now
  platform=$(jq -r '.scope.frontend // "pc-web"' "$state_file")
  client_dir=$(jq -r '.scope.frontend_dir // empty' "$state_file")
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  case "$platform" in
    pc-web|mini-program|app)
      [ -n "$client_dir" ] || { error "客户端目录未冻结"; return 1; }
      manifest_hash=$(bash "$SCRIPT_DIR/client-adapter.sh" hash "$platform" "$client_dir" 2>/dev/null) || { error "无法冻结客户端 manifest"; return 1; }
      case "$manifest_hash" in
        [0-9a-f][0-9a-f]*) ;;
        *) error "manifest 哈希无效"; return 1 ;;
      esac
      ;;
    not-applicable) manifest_hash="not-applicable" ;;
    *) error "未知客户端平台: $platform"; return 2 ;;
  esac
  jq --arg hash "$manifest_hash" --arg now "$now" \
    '.scope.client_manifest_sha256 = $hash | .updated_at = $now' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  success "客户端契约已冻结: $platform ($manifest_hash)"
  return 0
}

# v3.16.26: 冻结技术硬约束契约文件 SHA——P1 及之后的 Gate 以此校验约束文件未被
# 静默改写。前置条件：机器契约块合法（全部 FROZEN + confirmed）。
# 用法: devflow-state.sh constraints-freeze <feature>
cmd_constraints_freeze() {
  local feature="$1"
  local state_file
  state_file=$(get_state_file "$feature")
  [ -f "$state_file" ] || { error "工作流 '$feature' 不存在"; return 1; }
  command -v jq >/dev/null 2>&1 || { error "constraints-freeze 需要 jq"; return 1; }
  source "$SCRIPT_DIR/tech_constraints_lib.sh"

  # v3.22.0: 技术约束文件中英双语解析
  local tc_file=""
  if [ -n "${TECH_CONSTRAINTS_FILE:-}" ]; then
    tc_file="$TECH_CONSTRAINTS_FILE"
  else
    source "$SCRIPT_DIR/devflow_paths.sh"
    tc_file="$(df_resolve_doc "$feature" constraints .md requirements)"
    [ -n "$tc_file" ] || tc_file="docs/需求/${feature}-技术约束.md"
  fi
  [ -f "$tc_file" ] || { error "技术约束文件不存在: ${tc_file}（P0 必须产出；无约束也要写 constraint_set=NONE 契约块）"; return 1; }
  if ! tc_validate_constraints "$tc_file" >/dev/null 2>&1; then
    error "技术约束机器契约不合法（status 须全 FROZEN、confirmed 须 true）——拒绝冻结: $tc_file"
    tc_validate_constraints "$tc_file" >/dev/null
    return 1
  fi
  local sha now
  sha=$(tc_sha256 "$tc_file")
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq --arg sha "$sha" --arg path "$tc_file" --arg now "$now" \
    '.scope.tech_constraints_sha256 = $sha | .scope.tech_constraints_path = $path | .updated_at = $now' \
    "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  success "技术约束契约已冻结: $tc_file"
  echo "  SHA256: $sha"
  return 0
}

# v3.28.13: 项目级约束继承——同项目后续 feature 从既有 feature 继承技术约束
# 机器块（P0 只澄清 delta；m01-base 复盘 #4：P0 固定开销 ~36min 的压缩点）。
# 继承不改变任何 Gate 契约：目标 feature 照常跑 s0 门禁 + constraints-freeze，
# 冻结的仍是目标文件自身 SHA。
# 用法: devflow-state.sh constraints-inherit <feature> [--from <source>|@latest]
cmd_constraints_inherit() {
  local feature="$1"; shift || true
  local src="@latest"
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) src="${2:?--from 需要参数}"; shift 2 ;;
      *) error "constraints-inherit 未知参数: $1"; return 1 ;;
    esac
  done
  local state_file
  state_file=$(get_state_file "$feature")
  [ -f "$state_file" ] || { error "工作流 '$feature' 不存在（先 init）"; return 1; }
  command -v jq >/dev/null 2>&1 || { error "constraints-inherit 需要 jq"; return 1; }
  source "$SCRIPT_DIR/tech_constraints_lib.sh"

  # 解析来源 feature：@latest = updated_at 最新且已冻结约束的其他 feature
  local src_state src_feature
  if [ "$src" = "@latest" ]; then
    src_feature=$(for s in "$STATE_DIR"/*.state.json; do
      jq -r 'select(.scope.tech_constraints_sha256 != null) | "\(.updated_at) \(.feature)"' "$s" 2>/dev/null
    done | awk -v me="$feature" '$2 != me' | sort -r | head -1 | awk '{print $2}')
    [ -n "$src_feature" ] || { error "无已冻结技术约束的来源 feature（@latest 为空）——首个 feature 用 --from 指定或手写约束"; return 1; }
  else
    src_feature="$src"
    src_state="$STATE_DIR/${src_feature}.state.json"
    [ -f "$src_state" ] || { error "来源 feature 不存在: $src_feature"; return 1; }
    jq -e '.scope.tech_constraints_sha256 != null' "$src_state" >/dev/null 2>&1 \
      || { error "来源 feature 未冻结技术约束（无 tech_constraints_sha256）: $src_feature"; return 1; }
  fi
  src_state="$STATE_DIR/${src_feature}.state.json"

  # 来源约束文件必须仍在冻结 SHA 上——不继承已漂移的约束（fail-closed）
  local src_path src_sha src_frozen
  src_path=$(jq -r '.scope.tech_constraints_path // empty' "$src_state")
  src_frozen=$(jq -r '.scope.tech_constraints_sha256 // empty' "$src_state")
  [ -n "$src_path" ] && [ -f "$src_path" ] || { error "来源约束文件缺失: ${src_path:-<未记录>}"; return 1; }
  src_sha=$(tc_sha256 "$src_path")
  [ "$src_sha" = "$src_frozen" ] \
    || { error "来源约束文件已偏离冻结 SHA（${src_feature} 的约束在其 freeze 后被改写）——先修复来源再继承"; return 1; }

  # 目标文件：已有约束块则拒绝（不静默覆盖）
  source "$SCRIPT_DIR/devflow_paths.sh"
  local dst_file
  dst_file=$(df_resolve_doc "$feature" constraints .md requirements)
  [ -n "$dst_file" ] || dst_file="$WORKSPACE/docs/需求/${feature}-技术约束.md"
  if [ -f "$dst_file" ] && grep -q 'DEVFLOW:CONSTRAINTS' "$dst_file"; then
    error "目标约束文件已存在且含机器契约块，拒绝覆盖: ${dst_file}（增删请直接编辑既有文件）"
    return 1
  fi

  # 写目标：说明头 + 来源机器块逐字拷贝；随后自校验（继承块本已合法，失败即 fail-closed）
  local block
  block=$(tc_extract_block "$src_path" "DEVFLOW:CONSTRAINTS")
  [ -n "$block" ] || { error "来源文件无法提取 DEVFLOW:CONSTRAINTS 块: $src_path"; return 1; }
  mkdir -p "$(dirname "$dst_file")"
  {
    echo "# ${feature} 技术约束（继承稿）"
    echo
    echo "> 继承自 \`${src_feature}\`（冻结 SHA ${src_frozen:0:12}…，$(date -u +%Y-%m-%dT%H:%M:%SZ) 继承）。"
    echo "> **继承稿不是冻结态**：P0 只需澄清 delta——增删/改写本 feature 特有约束后，"
    echo "> 正常走 s0 门禁 + constraints-freeze（冻结的是本文件自身 SHA）。"
    echo
    echo "<!-- DEVFLOW:CONSTRAINTS"
    printf '%s\n' "$block"
    echo "DEVFLOW:END -->"
  } > "$dst_file"
  tc_validate_constraints "$dst_file" >/dev/null 2>&1 \
    || { error "继承产物机器契约不合法（不应发生——来源已验证合法）: $dst_file"; return 1; }
  success "已从 ${src_feature} 继承技术约束 → ${dst_file}"
  echo "  继承约束 SHA: ${src_frozen}"
  echo "  下一步: 澄清 delta（本 feature 特有约束增删）→ s0_acceptance_gate → constraints-freeze"
  return 0
}

# v3.15.1: 显式 skill 树迁移——唯一允许变更 scope.skill_tree_sha256 的入口。
# 背景：skill 升级后 state 冻结树与收据树不一致会阻断 complete/audit（硬门禁）；
# 迁移必须显式执行并留痕（FROM_TREE/TO_TREE 双向记录 + 收据双写），绝不静默覆盖。
# 用法: devflow-state.sh migrate-tree <feature>
cmd_migrate_tree() {
  local feature="$1"
  local state_file
  state_file=$(get_state_file "$feature")
  [ -f "$state_file" ] || { error "工作流 '$feature' 不存在"; return 1; }
  command -v jq >/dev/null 2>&1 || { error "migrate-tree 需要 jq"; return 1; }

  local cur_tree old_tree now
  cur_tree=$(bash "$SCRIPT_DIR/gate-skill-tree.sh" 2>/dev/null)
  if ! printf '%s' "$cur_tree" | grep -qE '^[0-9a-f]{64}$'; then
    error "无法计算当前 skill 树哈希（fail-closed）——拒绝迁移"
    return 1
  fi
  old_tree=$(jq -r '.scope.skill_tree_sha256 // empty' "$state_file")
  if [ "$old_tree" = "$cur_tree" ]; then
    success "state 冻结树与当前 skill 树一致，无需迁移"
    return 0
  fi
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local mig_dir="$STATE_DIR/${feature}/gates/SKILL-TREE-MIGRATION"
  local mig_mirror="$WORKSPACE/docs/${feature}/gates/SKILL-TREE-MIGRATION"
  mkdir -p "$mig_dir" "$mig_mirror"
  {
    echo "EXIT_CODE=0"
    echo "VERSION=state-migrate-tree@$(devflow_version)"
    echo "PHASE=SKILL-TREE-MIGRATION"
    echo "FROM_TREE=${old_tree:-legacy-none}"
    echo "TO_TREE=$cur_tree"
    echo "MIGRATED_AT=$now"
    echo "OPERATION=explicit-skill-tree-migration"
  } > "$mig_dir/receipt.txt"
  cp "$mig_dir/receipt.txt" "$mig_mirror/receipt.txt"
  jq --arg tree "$cur_tree" --arg from "${old_tree:-legacy-none}" --arg now "$now" \
    '.scope.skill_tree_sha256 = $tree | .scope.skill_tree_migrated_from = $from | .scope.skill_tree_migrated_at = $now | .updated_at = $now' \
    "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  success "SKILL_TREE 迁移完成: ${old_tree:-legacy-none} -> $cur_tree"
  echo "  迁移收据: $mig_dir/receipt.txt（旧树收据凭 FROM_TREE 对账放行）"
  echo "  前提确认: 请人工确认旧树→新树的变更是经批准的 skill 升级"
  return 0
}

# 修复 v3.9.8 之前 P3cd 复合阶段写入的空 phase 键。只删除可被收据和
# 两个原子阶段共同证明的历史残留；其余状态拒绝修改，避免误修正常数据。
cmd_repair() {
  local feature="$1"
  shift
  local state_file
  state_file=$(get_state_file "$feature")
  [ -f "$state_file" ] || { error "工作流 '$feature' 不存在"; return 1; }
  command -v jq >/dev/null 2>&1 || { error "repair 需要 jq"; return 1; }

  local frontend_scope="" frontend_dir=""
  for arg in "$@"; do
    case "$arg" in
      --frontend=required|--frontend=web|--frontend=pc-web) frontend_scope="pc-web"; frontend_dir="frontend" ;;
      --frontend=mini-program) frontend_scope="mini-program"; frontend_dir="miniprogram" ;;
      --frontend=app) frontend_scope="app"; frontend_dir="app" ;;
      --frontend=not-applicable) frontend_scope="not-applicable"; frontend_dir="" ;;
      --frontend-dir=*) frontend_dir="${arg#--frontend-dir=}" ;;
      *) error "repair 参数无效: ${arg}（--frontend=pc-web|mini-program|app|not-applicable；可选 --frontend-dir=<path>）"; return 2 ;;
    esac
  done

  command -v jq >/dev/null 2>&1 || { error "repair 需要 jq"; return 1; }
  # v3.13.8: migrate legacy states that predate P2a/P2b and used P6a-P6f.
  # Missing review evidence is never fabricated: the state rewinds to P2a.
  local reconcile_p6="false"
  if jq -e '.phases.P6.status? == "completed" and ([.phases.P6a,.phases.P6b,.phases.P6c,.phases.P6d,.phases.P6e,.phases.P6f] | any(. != null))' "$state_file" >/dev/null 2>&1; then
    local p6_receipt="$STATE_DIR/${feature}/gates/P6/receipt.txt"
    if [ ! -f "$p6_receipt" ] || ! grep -q '^EXIT_CODE=0$' "$p6_receipt"; then reconcile_p6="true"; fi
  fi
  jq --argjson reconcile_p6 "$reconcile_p6" '
    def legacy_status:
      if (length > 0 and all(. == "completed")) then "completed"
      elif any(. == "completed" or . == "in_progress") then "in_progress"
      else "pending" end;
    ([.phases.P6a.status?,.phases.P6b.status?,.phases.P6c.status?,.phases.P6d.status?,.phases.P6e.status?,.phases.P6f.status?] | map(. // "pending")) as $legacy |
    (.phases | has("P2a")) as $had_p2a |
    (.phases | has("P2b")) as $had_p2b |
    .phases.P2a //= {"name":"详细设计评审","status":"pending","started_at":null,"completed_at":null} |
    .phases.P2b //= {"name":"原型Demo","status":"pending","started_at":null,"completed_at":null} |
    if (.phases | has("P6")) then
      if (($legacy | length) > 0 and ($reconcile_p6 or .phases.P6.status != "completed")) then .phases.P6.status = ($legacy | legacy_status) else . end
    else
      .phases.P6 = {
        "name":"测试执行",
        "status": ($legacy | legacy_status),
        "started_at": null,
        "completed_at": null
      }
    end |
    del(.phases.P6a,.phases.P6b,.phases.P6c,.phases.P6d,.phases.P6e,.phases.P6f) |
    if (.current_phase | test("^P6[a-f]$")) then .current_phase = "P6" else . end |
    if (.phases.P2.status == "completed" and (($had_p2a | not) or ($had_p2b | not))) then
      .current_phase = "P2a" |
      .phases.P2a.status = "in_progress" |
      .phases.P2a.started_at = null |
      .phases.P2b.status = "pending"
    else . end |
    .version = $ver
  ' --arg ver "$(devflow_version)" "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file" || { error "状态迁移失败"; return 1; }

  if ! jq -e '.phases[""]? != null' "$state_file" >/dev/null; then
    if [ -n "$frontend_scope" ]; then
      jq --arg scope "$frontend_scope" --arg dir "$frontend_dir" --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '.scope.frontend = $scope | .scope.frontend_dir = $dir | .updated_at = $now' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
      success "前端范围已更新: $frontend_scope"
    else
      success "无需修复：未发现空 phase 键"
    fi
    # v3.15.1: repair 不得覆盖 state 冻结树 hash（原始溯源锚点不可变）。
    # skill 升级后的树迁移必须走显式命令：devflow-state.sh migrate-tree <feature>
    # （写入 SKILL-TREE-MIGRATION 收据后才允许变更 scope.skill_tree_sha256）。
    return 0
  fi

  local receipt="$STATE_DIR/${feature}/gates/P3cd/receipt.txt"
  if [ ! -f "$receipt" ] || ! grep -q '^EXIT_CODE=0$' "$receipt" || \
     ! jq -e '.phases.P3c.status == "completed" and .phases.P3d.status == "completed"' "$state_file" >/dev/null; then
    error "拒绝修复：空 phase 未同时具备 P3cd 成功收据与 P3c/P3d 完成证据"
    return 1
  fi

  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq --arg now "$now" --arg scope "$frontend_scope" --arg dir "$frontend_dir" \
    'del(.phases[""]) | if $scope == "" then . else .scope.frontend = $scope | .scope.frontend_dir = $dir end | .updated_at = $now' \
    "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  success "已修复历史空 phase 键"
  [ -n "$frontend_scope" ] && echo "  前端范围: $frontend_scope"
  return 0
}

# 保存检查点
cmd_checkpoint() {
  local feature="$1"
  local state_file
  state_file=$(get_state_file "$feature")
  local note="${2:-}"
  
  if [ ! -f "$state_file" ]; then
    error "工作流 '$feature' 不存在，先运行 init"
    return 1
  fi
  
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # 读取当前状态
  local current_phase
  current_phase=$(grep -oE '"current_phase": "[^"]+"' "$state_file" | cut -d'"' -f4 || true)
  local current_stage
  current_stage=$(grep -oE '"current_stage": "[^"]+"' "$state_file" | cut -d'"' -f4 || true)
  local completed_count
  completed_count=$(grep -oE '"status": "completed"' "$state_file" | wc -l | tr -d ' ' || true)
  
  # 添加检查点记录
  local checkpoint_id
  checkpoint_id="cp_$(date +%Y%m%d_%H%M%S)"
  
  command -v jq >/dev/null 2>&1 || {
    error "checkpoint 需要 jq；拒绝写入不完整检查点"
    return 1
  }
  jq --arg now "$now" \
     --arg cp_id "$checkpoint_id" \
     --arg note "$note" \
     --arg phase "$current_phase" \
     --arg stage "$current_stage" \
     '.checkpoints += [{"id": $cp_id, "created_at": $now, "phase": $phase, "stage": $stage, "note": $note}] | .updated_at = $now' \
     "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  
  success "检查点已保存: $checkpoint_id"
  echo "  阶段: $current_phase ($(get_phase_name "$current_phase"))"
  echo "  兼容字段 current_stage: ${current_stage}（不参与阶段完成判定）"
  echo "  完成项数: $completed_count"
  if [ -n "$note" ]; then echo "  备注: $note"; fi
  return 0
}

# 恢复工作流
cmd_resume() {
  local feature="$1"
  local state_file
  state_file=$(get_state_file "$feature")
  
  if [ ! -f "$state_file" ]; then
    error "工作流 '$feature' 不存在，先运行 init"
    return 1
  fi
  
  local current_phase
  current_phase=$(grep -oE '"current_phase": "[^"]+"' "$state_file" | cut -d'"' -f4 || true)
  local current_stage
  current_stage=$(grep -oE '"current_stage": "[^"]+"' "$state_file" | cut -d'"' -f4 || true)
  local updated_at
  updated_at=$(grep -oE '"updated_at": "[^"]+"' "$state_file" | cut -d'"' -f4 || true)
  
  success "工作流 '$feature' 已恢复"
  echo ""
  echo "  最后更新: $updated_at"
  echo "  当前阶段: $current_phase ($(get_phase_name "$current_phase"))"
  echo "  兼容字段 current_stage: ${current_stage}（不参与阶段完成判定）"
  echo ""
  
  # 显示待完成阶段
  echo "  待完成阶段:"
  local pending
  pending=$(grep -E '"status": "(pending|in_progress)"' "$state_file" | grep -oE '"P[0-9]+[a-z]?"' | tr -d '"' | tr '\n' ' ' || true)
  echo "    P-Phases: $pending"
  
  echo "  方法论轨：仅历史兼容，不作为待办清单或完成依据"
  
  # 显示验收点进度
  if command -v jq &>/dev/null; then
    local acc_count
    acc_count=$(jq -r '.acceptance_criteria.count' "$state_file" 2>/dev/null || echo "0")
    local acc_frozen
    acc_frozen=$(jq -r '.acceptance_criteria.frozen' "$state_file" 2>/dev/null || echo "0")
    local acc_complete
    acc_complete=$(jq -r '.acceptance_criteria.complete' "$state_file" 2>/dev/null || echo "0")
    if [[ "$acc_count" != "null" ]] && [[ "$acc_count" != "0" ]]; then
      echo ""
      echo "  验收点进度: $acc_complete/$acc_frozen/$acc_count (完成/冻结/总数)"
    fi
  fi
  
  # 显示阻塞项
  local blocks
  blocks=$(grep -oE '"message": "[^"]+"' "$state_file" 2>/dev/null | head -3 | cut -d'"' -f4 || true)
  if [ -n "$blocks" ]; then
    echo ""
    echo "  阻塞项:"
    for block in $blocks; do
      echo "    - $block"
    done
  fi
  
  echo ""
  info "运行 /devflow 继续执行"
}

# 查看状态
cmd_status() {
  local feature="$1"
  local state_file
  state_file=$(get_state_file "$feature")
  
  if [ ! -f "$state_file" ]; then
    error "工作流 '$feature' 不存在"
    return 1
  fi
  
  echo "============================================="
  echo "  DevFlow 状态: $feature"
  echo "============================================="
  
  # 解析状态
  if command -v jq &>/dev/null; then
    echo ""
    echo "【P-Phases 阶段进度】"
    jq -r '.phases | to_entries[] | "  \(.key) [\(if .value.status == "completed" then "✓" else if .value.status == "in_progress" then "→" else "○" end end)] \(.value.name // "")"' "$state_file"
    
    echo ""
    echo "【阶段进度唯一来源】"
    echo "  current_phase=$(jq -r '.current_phase' "$state_file")；methodology_stages 仅保留作历史兼容，不参与完成判定"
    
    echo ""
    echo "【验收点追踪】"
    jq -r '.acceptance_criteria | "  总数: \(.count), 冻结: \(.frozen), 完成: \(.complete)"' "$state_file"
    
    echo ""
    echo "【首轮快照】"
    jq -r '.first_pass_snapshot | "  路径: \(.path // "无")\n  准确率: \(.accuracy // "无")\n  创建: \(.created_at // "无")"' "$state_file"
    
    echo ""
    echo "【图谱状态】"
    jq -r '.graph_index | "  状态: \(.status)\n  健康分: \(.health_score // "无")"' "$state_file"
    
    echo ""
    echo "【检查点】"
    jq -r '.checkpoints[] | "  \(.id) - \(.phase) - \(.stage) - \(.created_at)"' "$state_file" 2>/dev/null || echo "  (无)"
  else
    # 简单 fallback
    echo ""
    grep -E '"(P[0-9]+[a-z]?":' "$state_file" 2>/dev/null | head -15 || true
    grep -E '"(P[0-9]+|GRAPH_HEALTH)":' "$state_file" 2>/dev/null | head -10 || true
  fi
}

# === List command ===
cmd_list() {
  echo "============================================="
  echo "  DevFlow 工作流列表"
  echo "============================================="
  
  local count=0
  for state_file in "$STATE_DIR"/*.state.json; do
    [ -f "$state_file" ] || continue
    count=$((count + 1))
    local feature
    feature=$(basename "$state_file" .state.json)
    local phase
    phase=$(grep -oE '"current_phase": "[^"]+"' "$state_file" | cut -d'"' -f4 || true)
    local stage
    stage=$(grep -oE '"current_stage": "[^"]+"' "$state_file" | cut -d'"' -f4 || true)
    local updated
    updated=$(grep -oE '"updated_at": "[^"]+"' "$state_file" | cut -d'"' -f4 || true)
    
    echo ""
    echo "  [$count] $feature"
    echo "      阶段: $phase ($(get_phase_name "$phase"))"
    # v3.28.9: methodology_stages 已从新 state 移除；历史残留仅在存在时展示
    [ -n "$stage" ] && echo "      方法论轨(遗留): $stage ($(get_stage_name "$stage"))"
    echo "      更新: $updated"
  done
  
  if [ "$count" -eq 0 ]; then
    echo ""
    echo "  (无运行中的工作流)"
    echo ""
    info "运行 'devflow-state.sh init <feature>' 开始新工作流"
  else
    echo ""
    echo "  共 $count 个工作流"
  fi
}

# ===== 入口分发（v3.9.6 修复：此前仅有函数定义无入口，全部命令静默 no-op exit 0）=====
# 调用方 devflow-state.sh 转发时 $@ 含子命令本身，故先 shift
# 守卫：被 complete/template source 时（BASH_SOURCE≠$0）跳过入口，只加载函数库
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-help}" in
    init)            shift; cmd_init "$@" ;;
    checkpoint)      shift; cmd_checkpoint "$@" ;;
    resume)          shift; cmd_resume "$@" ;;
    status)          shift; cmd_status "$@" ;;
    list)            shift; cmd_list "$@" ;;
    repair)          shift; cmd_repair "$@" ;;
    migrate-tree)    shift; cmd_migrate_tree "$@" ;;
    client-freeze)   shift; cmd_client_freeze "$@" ;;
    constraints-freeze) shift; cmd_constraints_freeze "$@" ;;
    constraints-inherit) shift; cmd_constraints_inherit "$@" ;;
    help|--help|-h)
      echo "用法: devflow-state.sh {init|checkpoint|resume|status|list|repair|migrate-tree|client-freeze|constraints-freeze|constraints-inherit} <feature> [options]"
      ;;
    *)
      echo "ERROR: 未知命令: $1" >&2
      exit 2
      ;;
  esac
fi
