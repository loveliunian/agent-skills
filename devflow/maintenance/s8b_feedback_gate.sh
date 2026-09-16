#!/usr/bin/env bash
# =============================================================================
# P10 经验反哺 Gate（核心引擎；版本随 SKILL.md 单一事实源）
# =============================================================================
# 功能：
#   1. Collect   : 收集 P0-P10 所有产出中的失败模式
#   2. Attribute : 归因到 TPL/PRMT/GATE/FLOW/DOMAIN 五类
#   3. Categorize: 按 P0-P10 分类
#   4. Diff      : 生成 skill 文件的修改建议
#   5. Apply     : 安全写入目标文件（含 .bak）
#   6. Verify    : 验证 Gate 仍然通过
#
# 使用：
#   bash maintenance/s8b_feedback_gate.sh <feature> [--collect|--attribute|--diff|--verify]
#   bash maintenance/s8b_feedback_gate.sh <feature> --apply --authorize-apply --write
#
# 环境变量：
#   SKILL_ROOT    skill 根目录
#   CLAUDE_API_KEY Claude API Key（Step 2 attribution 需要）
#   CLAUDE_MODEL  Claude 模型（默认 claude-sonnet-4-20250514）
#   DRY_RUN=1     干跑（默认，不实际写入）
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="${SKILL_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# v3.15.9: WORK_DIR 跟随 STATE_DIR 取默认——隔离部署（STATE_DIR 自定义）下报告不再回退
# .devflow 读宿主项目数据（跨工作区污染）；显式 WORK_DIR 仍可覆盖
WORK_DIR="${WORK_DIR:-${STATE_DIR:-.devflow}}"

# ---------- 全局状态 ----------
FAIL=0; PASS=0; SKIP=0; WARN=0
applied=0; failed=0   # v3.14.3: 全局初始化——--verify 单独运行时也可用
FEATURE=""
MODE="collect"
DRY_RUN="${DRY_RUN:-1}"
APPLY_AUTHORIZED=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; WARN=$((WARN+1)); }
err()    { echo -e "${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }

usage() {
  cat <<'EOF'
Usage: s8b_feedback_gate.sh <feature> [OPTIONS]

P10 经验反哺 Gate
每次 P0-P10 完成后，提取失败模式，归因到 skill，归类到 P0-P10。

步骤（默认 --collect，只写项目 .devflow 证据）：
  --collect    Step1: 收集 P0-P10 产出中的失败模式
  --attribute  Step2: 归因到 5 类（TPL/PRMT/GATE/FLOW/DOMAIN）
  --categorize Step3: 按 P0-P10 分类
  --diff       Step4: 生成 skill 文件的 diff
  --apply      Step5: 申请应用 diff；必须同时给出 --authorize-apply --write
  --verify     Step6: 验证 Gate 仍通过
  --all        执行 collect/attribute/categorize/diff/verify，不应用全局 skill 修改

其他：
  --dry-run    干跑（默认）
  --write      允许实际写入；仅与 --apply --authorize-apply 一起有效
  --authorize-apply  确认本次用户已批准修改已安装 skill
  -h, --help   帮助

环境变量：
  CLAUDE_API_KEY=<key>  Step2 需要
  DRY_RUN=1             等效 --dry-run

示例：
  s8b_feedback_gate.sh m-03 --all
  s8b_feedback_gate.sh m-03 --apply --authorize-apply --write
EOF
  # v3.9.6 修复：原 exit 0 —— 无参调用 P10 gate 会被误判 PASS，反哺闭环可被空跑绕过
  exit 2
}

# ---------- 参数解析 ----------
[ $# -eq 0 ] && usage
FEATURE="$1"; shift
# v3.15.4→v3.15.5: feature 名白名单升级为共享函数（devflow_feature.sh）——路径穿越与 grep -E 正则注入（.* 改变收集范围）封堵
source "$(cd "$(dirname "$0")" && pwd)/../scripts/devflow_feature.sh"
devflow_feature_validate "$FEATURE" || exit 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --collect|--attribute|--categorize|--diff|--apply|--verify|--all)
      MODE="${1#--}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --write) DRY_RUN=0; shift ;;
    --authorize-apply) APPLY_AUTHORIZED=1; shift ;;
    -h|--help) usage ;;
    *) echo "[ERR] unknown: $1"; exit 2 ;;
  esac
done

if [ "$MODE" = "apply" ] && { [ "$APPLY_AUTHORIZED" -ne 1 ] || [ "$DRY_RUN" = "1" ]; }; then
  echo "[ERR] apply requires explicit --authorize-apply --write"
  exit 2
fi

OUTPUT_DIR="${WORK_DIR}/${FEATURE}/s8b"
DIFF_DIR="${OUTPUT_DIR}/diff"
mkdir -p "$OUTPUT_DIR" "$DIFF_DIR" "${SKILL_ROOT}/.backups/s8b"
# v3.15.7: DIFF_DIR 绝对化——patch 子 shell `(cd "$SKILL_ROOT" && patch -p1 < "$pf")` 的输入
# 重定向在 cd 之后打开，相对路径 pf 在 SKILL_ROOT 下不存在 → patch 恒失败（applied=0，
# verify 闭环不可达，apply_status 直落 FAILED）。T15 回归。
DIFF_DIR="$(cd "$DIFF_DIR" && pwd -P)"

[ "$DRY_RUN" = "1" ] && info "DRY RUN — 不实际写入文件"

# =============================================================================
# STEP 1: Collect
# =============================================================================
step_collect() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Step 1: Collect — 收集失败模式"
  echo "═══════════════════════════════════════════════════════════════"

  local yaml="${OUTPUT_DIR}/s8b-collected.yaml"
  local collected=0

  {
    echo "# P10 Collected Evidence"
    echo "# Feature: $FEATURE | Collected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "feature: $FEATURE"
    echo "collected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "evidence:"
  } > "$yaml"

  # v3.22.0: 返回该证据类型的【全部候选 basename】（英文历史名 + 中文新名），find -name 逐个匹配
  get_source_names() {
    case "$1" in
      E2E)           printf '%s\n' "${FEATURE}-e2e-report.md" "${FEATURE}-端到端报告.md" ;;
      UNIT)          printf '%s\n' "${FEATURE}-unit-coverage.html" ;;
      PRD_VS_CODE)   printf '%s\n' "${FEATURE}-prd-vs-code-report.md" "${FEATURE}-PRD实现对比.md" ;;
      CODE_REVIEW)   printf '%s\n' "${FEATURE}-code-review-report.md" "${FEATURE}-代码审查报告.md" ;;
      RETRO)         printf '%s\n' "${FEATURE}-retro.md" "${FEATURE}-复盘.md" ;;
      P6_ACCURACY)   printf '%s\n' "p6-accuracy.env" ;;
      PRD_REVIEW)    printf '%s\n' "${FEATURE}-prd-review.md" "${FEATURE}-PRD评审.md" ;;
      CLARIFICATION) printf '%s\n' "${FEATURE}-clarification.md" "${FEATURE}-需求澄清.md" ;;
      DESIGN)        printf '%s\n' "${FEATURE}-design.md" "${FEATURE}-详细设计.md" ;;
      TECH_SELECTION) printf '%s\n' "${FEATURE}-tech-selection.md" "${FEATURE}-技术选型.md" ;;
      DEPLOY)        printf '%s\n' "${FEATURE}-deploy-record.md" "${FEATURE}-部署记录.md" ;;
      MONITOR)       printf '%s\n' "${FEATURE}-monitor-config.md" "${FEATURE}-监控配置.md" ;;
      INTEGRATION)   printf '%s\n' "${FEATURE}-integration-report.md" "${FEATURE}-集成测试报告.md" ;;
      PERF_AUDIT)    printf '%s\n' "${FEATURE}-performance-audit-report.md" "${FEATURE}-性能审计报告.md" ;;
      SEC_AUDIT)     printf '%s\n' "${FEATURE}-security-audit-report.md" "${FEATURE}-安全审计报告.md" ;;
      *)             echo "" ;;
    esac
  }

  for src_type in E2E UNIT PRD_VS_CODE CODE_REVIEW RETRO P6_ACCURACY PRD_REVIEW CLARIFICATION DESIGN TECH_SELECTION DEPLOY MONITOR INTEGRATION PERF_AUDIT SEC_AUDIT; do
    local found=""
    # v3.22.0: 中英双 basename 都探测（P6_ACCURACY 为 .devflow 机器文件，直接按固定相对路径）
    if [ "$src_type" = "P6_ACCURACY" ]; then
      [ -f ".devflow/${FEATURE}/p6-accuracy.env" ] && found="./.devflow/${FEATURE}/p6-accuracy.env"
    else
      local _bn
      while IFS= read -r _bn; do
        [ -z "$_bn" ] && continue
        found="$found$(find . -type f -name "$_bn" 2>/dev/null | grep -v '/.git/' | grep -E "${FEATURE}" | head -3)"$'\n'
      done < <(get_source_names "$src_type")
      found=$(printf '%s' "$found" | sed '/^$/d' | sort -u | head -3)
    fi
    [ -z "$found" ] && continue

    if [ -n "$found" ]; then
      while IFS= read -r f; do
        [ -z "$f" ] || [ ! -f "$f" ] && continue
        collected=$((collected+1))

        local lines
        lines=$(wc -l < "$f" 2>/dev/null || true)

        echo "  - source: $src_type" >> "$yaml"
        echo "    file: $f" >> "$yaml"
        echo "    lines: $lines" >> "$yaml"

        local findings
        findings=$(grep -n -E "P0|FATAL|FAIL|ERROR|BLOCK|遗漏|缺失|未覆盖|偏差|问题|不一致|不符合|漏|gap|miss|wrong|incorrect" "$f" 2>/dev/null | head -20 || true)
        if [ -n "$findings" ]; then
          echo "    findings:" >> "$yaml"
          echo "$findings" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            local ln
            ln=$(echo "$line" | cut -d: -f1)
            local txt
            txt=$(echo "$line" | cut -d: -f2- | sed 's/^[[:space:]]*//' | head -c 180)
            echo "      - line: $ln" >> "$yaml"
            echo "        text: \"${txt}\"" >> "$yaml"
          done
        fi
      done <<< "$found"
    fi
  done

  echo "" >> "$yaml"
  echo "summary:" >> "$yaml"
  echo "  files_found: $collected" >> "$yaml"

  if [ "$collected" -gt 0 ]; then
    ok "收集完成：$collected 个文件 → $yaml"
  else
    warn "未找到任何产出文件，请确认 docs/ 目录有对应产物"
    SKIP=$((SKIP+1))
  fi
}

# =============================================================================
# STEP 2: Attribute（LLM 或 Agent 引导）
# =============================================================================
step_attribute() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Step 2: Attribute — 归因分析"
  echo "═══════════════════════════════════════════════════════════════"

  local collected="${OUTPUT_DIR}/s8b-collected.yaml"
  [ ! -f "$collected" ] && { err "缺少 s8b-collected.yaml，先跑 --collect"; return 1; }

  if [ -n "${CLAUDE_API_KEY:-}" ]; then
    step_attribute_llm
  else
    step_attribute_template
  fi
}

step_attribute_llm() {
  command -v jq >/dev/null 2>&1 || { warn "jq 缺失，无法构造 LLM 请求体，回退模板归因"; step_attribute_template; return; }
  local model="${CLAUDE_MODEL:-claude-sonnet-4-20250514}"
  local api_url="https://api.anthropic.com/v1/messages"
  local attributed="${OUTPUT_DIR}/s8b-attributed.yaml"
  local raw
  raw=$(cat "$collected" 2>/dev/null | head -300)

  info "调用 Claude $model 进行归因..."

  local system_prompt="你是 P10 经验反哺系统的归因引擎。
从收集的证据中提取失败模式，归因到以下 5 类之一：
- TPL (Template): 模板缺少字段/章节/示例/检查点
- PRMT (Prompt): prompt 歧义/缺少约束/顺序不对
- GATE (Gate 脚本): 误报/漏报/缺少/阈值不当
- FLOW (流程): 冗余/缺少/顺序不对
- DOMAIN (领域): 概念混淆/术语不一致/业务规则遗漏

对每条 findings 输出 YAML 格式的 feedback 条目：
feedback_id: FB-<P>-<YYYYMMDD>-<SEQ>
failure_type: <TPL/PRMT/GATE/FLOW/DOMAIN>
sub_type: <子类型>
original: <原始问题文本>
attribution: <归因理由>
target_file: <目标 skill 文件>
target_section: <目标章节>
priority: <P0/P1/P2>
verified: false

只输出 YAML，不要解释。"

  local response
  response=$(curl -s -X POST "$api_url" \
    --connect-timeout 10 --max-time 120 \
    -H "x-api-key: $CLAUDE_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{
      \"model\": \"$model\",
      \"max_tokens\": 4096,
      \"system\": $(echo "$system_prompt" | jq -Rs .),
      \"messages\": [{\"role\": \"user\", \"content\": $(echo "$raw" | jq -Rs .)}]
    }" 2>/dev/null) || true

  local content
  content=$(echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null || true)

  if [ -n "$content" ]; then
    {
      echo "# P10 Attributed Feedback"
      echo "# Feature: $FEATURE"
      echo "# Method: LLM ($model)"
      echo "# Attributed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo ""
      echo "$content"
    } > "$attributed"
    local fb_count
    fb_count=$(echo "$content" | grep -c "^feedback_id:" || true)
    ok "归因完成：$fb_count 条 feedback → $attributed"
  else
    err "LLM 调用失败"
    step_attribute_template
  fi
}

step_attribute_template() {
  local tmpl="${OUTPUT_DIR}/s8b-attribution-template.md"
  cat > "$tmpl" << 'TPL_EOF'
# P10 归因引导

由 agent 读取 `s8b-collected.yaml`，对每条 finding 归因并输出到 `s8b-attributed.yaml`。

## 归因决策树

```
发现问题？
├── 模板导致？ → TPL + [TPL-FIELD|TPL-STRUCT|TPL-EXAMPLE|TPL-CHECK]
├── prompt 导致？ → PRMT + [PRMT-AMBIGUOUS|PRMT-INCOMPLETE|PRMT-ORDER]
├── Gate 脚本导致？ → GATE + [GATE-FALSE-POS|GATE-FALSE-NEG|GATE-MISSING|GATE-THRESHOLD]
├── 流程导致？ → FLOW + [FLOW-REDUNDANT|FLOW-MISSING|FLOW-ORDER]
└── 领域知识导致？ → DOMAIN + [DOMAIN-CONCEPT|DOMAIN-TERM|DOMAIN-RULE]
```

## 输出格式（写入 s8b-attributed.yaml）

```yaml
feedbacks:
  - feedback_id: FB-P0-YYYYMMDD-001
    feature: <feature>
    phase: <P0/P1/.../P10>
    source_file: <原始文件>
    failure_type: TPL
    sub_type: TPL-FIELD
    original: |
      <原始问题文本>
    attribution: |
      <为什么判断为 TPL>
    target_file: templates/详细设计-模板.md
    target_section: §3 数据模型
    priority: P0
    verified: false
```

## Agent 填写清单

请逐条填写以下清单（共 N 条，N=collected.yaml 中的 findings 数量）：

| # | source | file | failure_type | sub_type | target_file | priority |
|---|--------|------|-------------|----------|-------------|----------|
| 1 |        |      |             |          |             |          |
TPL_EOF

  ok "Agent 引导模板：$tmpl"
  ok "设置 CLAUDE_API_KEY 环境变量可自动归因"
  SKIP=$((SKIP+1))
}

# =============================================================================
# STEP 3: Categorize
# =============================================================================
step_categorize() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Step 3: Categorize — P0-P10 分类"
  echo "═══════════════════════════════════════════════════════════════"

  local attributed="${OUTPUT_DIR}/s8b-attributed.yaml"
  [ ! -f "$attributed" ] && { err "缺少 s8b-attributed.yaml"; return 1; }

  local categorized="${OUTPUT_DIR}/s8b-categorized.yaml"
  {
    echo "# P10 Categorized by Phase"
    echo "# Feature: $FEATURE | $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
  } > "$categorized"

  get_targets() {
    case "$1" in
      P0)  echo "phases/00-需求澄清.md|concepts/PRD实施方法论.md" ;;
      P1)  echo "templates/技术选型报告-模板.md|scripts/s1_fact_sources_gate.sh" ;;
      P2)  echo "templates/详细设计-模板.md|templates/_commons.md|scripts/s2_design_coverage_gate.sh|scripts/s3_migration_mapping_gate.sh" ;;
      P3)  echo "templates/详细设计-模板.md|scripts/p3_completion_gate.sh" ;;
      P5)  echo "scripts/p5_test_cases_gate.sh|scripts/s5_migration_gate.sh|scripts/p4_prd_vs_code.sh" ;;
      P6)  echo "phases/05-测试用例.md|phases/06a-单元测试.md" ;;
      GRAPH_HEALTH) echo "maintenance/s8_graph_health_gate.sh" ;;
      P10) echo "phases/10-知识沉淀.md|commands/retro.md" ;;
      *)  echo "" ;;
    esac
  }

  for s in P0 P1 P2 P3 P5 P6 GRAPH_HEALTH P10; do
    echo "$s:" >> "$categorized"
    echo "  targets: \"$(get_targets "$s")\"" >> "$categorized"
    echo "  feedbacks: []" >> "$categorized"
  done

  # 尝试从 attributed 提取 phase
  local fb_count
  fb_count=$(grep -c "^feedback_id:" "$attributed" 2>/dev/null || true)
  ok "分类结构已生成（基于 P_TARGETS 映射）"
  ok "实际分类依赖 Step 2 的 LLM 归因结果"
  ok "→ $categorized"
}

# =============================================================================
# STEP 4: Diff
# =============================================================================
step_diff() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Step 4: Diff — 生成 skill 文件修改建议"
  echo "═══════════════════════════════════════════════════════════════"

  local attributed="${OUTPUT_DIR}/s8b-attributed.yaml"
  [ ! -f "$attributed" ] && { err "缺少 s8b-attributed.yaml"; return 1; }

  mkdir -p "${DIFF_DIR}"/{templates,phases,scripts,concepts,commands}

  get_sub_target() {
    case "$1" in
      DOMAIN-CONCEPT) echo "concepts/PRD实施方法论.md" ;;
      DOMAIN-RULE) echo "concepts/PRD实施方法论.md" ;;
      DOMAIN-TERM) echo "concepts/PRD实施方法论.md" ;;
      FLOW-MISSING) echo "phases/05-测试用例.md" ;;
      FLOW-ORDER) echo "phases/05-测试用例.md" ;;
      FLOW-REDUNDANT) echo "phases/05-测试用例.md" ;;
      GATE-FALSE-NEG) echo "scripts/s2_design_coverage_gate.sh" ;;
      GATE-FALSE-POS) echo "scripts/s1_fact_sources_gate.sh" ;;
      GATE-MISSING) echo "scripts/s5_migration_gate.sh" ;;
      GATE-THRESHOLD) echo "scripts/s6_first_pass_accuracy.sh" ;;
      PRMT-AMBIGUOUS) echo "phases/00-需求澄清.md" ;;
      PRMT-INCOMPLETE) echo "phases/00-需求澄清.md" ;;
      PRMT-ORDER) echo "phases/00-需求澄清.md" ;;
      TPL-CHECK) echo "templates/详细设计-完整版-模板.md" ;;
      TPL-EXAMPLE) echo "templates/详细设计-模板.md" ;;
      TPL-FIELD) echo "templates/详细设计-模板.md" ;;
      TPL-STRUCT) echo "templates/详细设计-模板.md" ;;
      *) echo "templates/详细设计-模板.md" ;;
    esac
  }

  local diff_count=0
  local in_fb=false
  local fb_id="" failure_type="" sub_type=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue

    echo "$line" | grep -q "^feedbacks:" && { in_fb=true; continue; }
    $in_fb || continue

    echo "$line" | grep -q "^  - feedback_id:" && {
      fb_id=$(echo "$line" | sed 's/.*feedback_id:[[:space:]]*//')
      failure_type=""; sub_type=""
    }

    [[ "$line" =~ ^[[:space:]]+failure_type:[[:space:]]*(.+) ]] && failure_type="${BASH_REMATCH[1]}"
    [[ "$line" =~ ^[[:space:]]+sub_type:[[:space:]]*(.+) ]] && sub_type="${BASH_REMATCH[1]}"

    if [ -n "$sub_type" ] && [ -n "$failure_type" ]; then
      local t
      t="$(get_sub_target "$sub_type")"
      local dir
      dir=$(echo "$t" | cut -d/ -f1)
      local base
      base=$(basename "$t")
      local patch="${DIFF_DIR}/${dir}/${base}.patch"

      {
        echo ""
        echo "# ============================================="
        echo "# FB: $fb_id"
        echo "# Type: $failure_type / $sub_type"
        echo "# Target: $t"
        echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# ============================================="
        echo ""
        echo "## 归因"
        echo "- failure_type: $failure_type"
        echo "- sub_type: $sub_type"
        echo "- target_file: $t"
        echo ""
        echo "## 建议修改内容"
        echo "<!-- 请填写具体的修改内容 -->"
        echo ""
      } >> "$patch"
      diff_count=$((diff_count+1))
      failure_type=""; sub_type=""
    fi
  done < "$attributed"

  # 生成 Agent 引导 diff
  local agent_md="${DIFF_DIR}/agent-guided-diff.md"
  cat > "$agent_md" << AGENT_EOF
# P10 Agent 引导 Diff

feature: $FEATURE
attributed: $attributed

## 任务

读取 `s8b-attributed.yaml`，对每条 feedback 生成具体的 skill 文件 diff。

## 输出格式

对每条 priority=P0 的 feedback：

### feedback_id: FB-xxx
**Target**: \`\$SKILL_ROOT/<target_file>\`
**Section**: \`§<target_section>\`

\`\`\`diff
--- a/<target_file>
+++ b/<target_file>
@@ -N,N +N,N @@
 原文
+新增内容（P10 经验）
+说明：为什么这样改
\`\`\`\`

## Feedback 清单

| feedback_id | failure_type | sub_type | target_file | priority |
|-------------|-------------|----------|-------------|----------|
AGENT_EOF

  ok "生成 $diff_count 个 patch → ${DIFF_DIR}/"
  ok "Agent 引导 diff 模板 → $agent_md"
}

# =============================================================================
# STEP 5: Apply
# =============================================================================
step_apply() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Step 5: Apply — 应用 diff 到 skill 文件"
  echo "═══════════════════════════════════════════════════════════════"

  # v3.15.4: 目录名加 PID——同秒两次 apply 的备份互相覆盖，回滚会恢复到错误基线
  BACKUP_DIR="${SKILL_ROOT}/.backups/s8b/$(date +%Y%m%d-%H%M%S)-$$"
  APPLIED_MANIFEST="${OUTPUT_DIR}/s8b-applied-manifest.tsv"
  # v3.15.4: 旧 manifest 非空先转存——无条件截断会丢失上一轮未 VERIFIED 应用的回滚记录
  if [ -s "$APPLIED_MANIFEST" ]; then
    cp "$APPLIED_MANIFEST" "${APPLIED_MANIFEST}.$(date +%Y%m%d%H%M%S).prev" 2>/dev/null || true
  fi
  : > "${APPLIED_MANIFEST}"
  [ "$DRY_RUN" != "1" ] && mkdir -p "$BACKUP_DIR"

  local report="${OUTPUT_DIR}/s8b-applied-report.md"
  {
    echo "# P10 Apply Report"
    echo "## Feature: $FEATURE | $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "## Dry Run: ${DRY_RUN:-false}"
    echo ""
    echo "| # | Feedback | Target | Status | Backup |"
    echo "|--|----------|--------|--------|--------|"
  } > "$report"

  # applied/failed 需跨步骤可见（step_verify 据此决定是否跑全量验证），故不用 local
  applied=0; skipped=0; failed=0; idx=1

  for subdir in templates phases scripts concepts commands; do
    [ ! -d "${DIFF_DIR}/${subdir}" ] && continue
    for pf in "${DIFF_DIR}/${subdir}"/*.patch; do
      [ -f "$pf" ] || continue
      local base
      base=$(basename "$pf" .patch)
      local target="${SKILL_ROOT}/${subdir}/${base}"

      if [ ! -f "$target" ]; then
        warn "[$idx] 目标不存在：${subdir}/${base}，跳过"
        echo "| $idx | $(basename "$pf") | ${subdir}/${base} | SKIP | — |" >> "$report"
        skipped=$((skipped+1)); idx=$((idx+1)); continue
      fi

      local has_content
      # v3.14.4: BSD grep 对 ^\+\+\+ 报 repetition-operator 错误（exit 2 被吞）→ 恒判空、真实 diff 全被跳过。
      # 改单 awk，模式用字符类 [+] 规避转义问题。
      has_content=$(awk '
        /^<!--/ {next}
        /^#/ {next}
        /^---([[:space:]]|$)/ {next}
        /^[+][+][+]/ {next}
        /^@@/ {next}
        /^## / {next}
        NF > 0 {c++}
        END {print c+0}' "$pf" 2>/dev/null || echo 0)
      if [ "${has_content:-0}" -eq 0 ]; then
        warn "[$idx] patch 空：${subdir}/${base}，跳过"
        echo "| $idx | $(basename "$pf") | ${subdir}/${base} | SKIP | — |" >> "$report"
        skipped=$((skipped+1)); idx=$((idx+1)); continue
      fi

      if [ "$DRY_RUN" = "1" ]; then
        ok "[$idx] DRY RUN：会修改 ${subdir}/${base}"
        echo "| $idx | $(basename "$pf") | ${subdir}/${base} | DRY-RUN | — |" >> "$report"
      else
        if ! grep -qE '^(diff --git|--- )' "$pf" 2>/dev/null; then
          warn "[$idx] 不是 unified diff：${subdir}/${base}，只生成建议，不自动修改"
          echo "| $idx | $(basename "$pf") | ${subdir}/${base} | SKIP-NON-DIFF | — |" >> "$report"
          skipped=$((skipped+1)); idx=$((idx+1)); continue
        fi
        command -v patch >/dev/null 2>&1 || {
          err "patch 命令不可用，拒绝直接修改 ${subdir}/${base}"
          echo "| $idx | $(basename "$pf") | ${subdir}/${base} | FAIL-NO-PATCH | — |" >> "$report"
          FAIL=$((FAIL+1)); idx=$((idx+1)); continue
        }
        local bak
        bak="${BACKUP_DIR}/${subdir}-${base}-$(date +%H%M%S)-$$.bak"
        cp "$target" "$bak"
        if (cd "$SKILL_ROOT" && patch --dry-run -p1 < "$pf" >/dev/null 2>&1) && \
           (cd "$SKILL_ROOT" && patch -p1 < "$pf" >/dev/null 2>&1); then
          # v3.15.4: fuzz 应用可能遗留 .orig——清理防止树哈希漂移（SKILL_TREE mismatch）并经 sync 进副本
          rm -f "${target}.rej" "${target}.orig"
          ok "[$idx] 应用 unified diff：${subdir}/${base}（备份：$(basename "$bak")）"
          echo "| $idx | $(basename "$pf") | ${subdir}/${base} | APPLIED | $(basename "$bak") |" >> "$report"
          printf '%s\t%s\n' "${SKILL_ROOT}/${subdir}/${base}" "$bak" >> "${APPLIED_MANIFEST:-${OUTPUT_DIR}/s8b-applied-manifest.tsv}"
          applied=$((applied+1))
        else
          cp "$bak" "$target"
          # v3.15.4: 清理 patch 失败遗留的 .rej/.orig——否则污染树哈希并经 sync 进全部副本
          rm -f "${target}.rej" "${target}.orig"
          err "[$idx] unified diff 校验失败，已恢复 ${subdir}/${base}"
          echo "| $idx | $(basename "$pf") | ${subdir}/${base} | FAIL-PATCH | $(basename "$bak") |" >> "$report"
          failed=$((failed+1)); FAIL=$((FAIL+1))
        fi
      fi
      idx=$((idx+1))
    done
  done

  echo "" >> "$report"
  echo "## Summary" >> "$report"
  echo "- Applied: $applied | Skipped: $skipped" >> "$report"
  [ "$DRY_RUN" != "1" ] && echo "- Backup: $BACKUP_DIR" >> "$report"

  ok "应用报告 → $report"
  [ "$DRY_RUN" != "1" ] && ok "备份目录 → $BACKUP_DIR"

  # 将“建议已生成 / 已获授权应用 / 仍待副本同步”写成机器可读证据，
  # 防止项目 feedback 状态和实际 skill/copy 状态再次脱节。
  local apply_receipt="${OUTPUT_DIR}/s8b-apply-receipt.env"
  local apply_status="NOTHING_TO_APPLY"
  if [ "$DRY_RUN" = "1" ]; then apply_status="DRY_RUN"
  elif [ "$failed" -gt 0 ]; then apply_status="FAILED"
  elif [ "$applied" -gt 0 ]; then apply_status="APPLIED"; fi
  {
    echo "FEATURE=$FEATURE"
    echo "VERSION=s8b-feedback@$(bash "$(dirname "$0")/../scripts/gate-version.sh")"
    echo "SKILL_TREE=$(bash "$(dirname "$0")/../scripts/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
    echo "STATUS=$apply_status"
    echo "APPLIED_COUNT=$applied"
    echo "SKIPPED_COUNT=$skipped"
    echo "REPORT_PATH=$report"
    if command -v shasum >/dev/null 2>&1; then echo "REPORT_SHA256=$(shasum -a 256 "$report" | awk '{print $1}')"; else echo "REPORT_SHA256=$(sha256sum "$report" | awk '{print $1}')"; fi
    echo "COPY_VERIFY_REQUIRED=$([ "$DRY_RUN" != "1" ] && echo 1 || echo 0)"
    echo "COPY_CHECK_COMMAND=bash \"$SKILL_ROOT/scripts/check-copies.sh\""
    echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$apply_receipt"
  ok "应用状态收据 → $apply_receipt"
}

# =============================================================================
# STEP 6: Verify
# =============================================================================
step_verify() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Step 6: Verify — 验证 Gate 通过"
  echo "═══════════════════════════════════════════════════════════════"

  local report="${OUTPUT_DIR}/s8b-verified-report.md"
  {
    echo "# P10 Verify Report"
    echo "## Feature: $FEATURE | $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "## Gate Script Integrity"
    echo "| Script | Syntax |"
    echo "|--------|--------|"
  } > "$report"

  local gates=(
    "scripts/s0_acceptance_gate.sh"
    "scripts/s1_fact_sources_gate.sh"
    "scripts/s2_design_coverage_gate.sh"
    "scripts/s3_migration_mapping_gate.sh"
    "scripts/p5_test_cases_gate.sh"
    "scripts/s5_migration_gate.sh"
    "scripts/s6_first_pass_accuracy.sh"
    "maintenance/s8_graph_health_gate.sh"
    "scripts/preflight-port.sh"
  )

  for g in "${gates[@]}"; do
    local gp="${SKILL_ROOT}/${g}"
    if [ ! -f "$gp" ]; then
      err "缺失：$g"
      echo "| \`$g\` | ✗ MISSING |" >> "$report"
      FAIL=$((FAIL+1))
    elif bash -n "$gp" 2>/dev/null; then
      ok "语法 OK：$g"
      echo "| \`$g\` | ✓ |" >> "$report"
    else
      err "语法错误：$g"
      echo "| \`$g\` | ✗ SYNTAX |" >> "$report"
      FAIL=$((FAIL+1))
    fi
  done

  echo "" >> "$report"
  echo "## Skill File Integrity" >> "$report"
  echo "| File | Status |" >> "$report"
  echo "|------|--------|" >> "$report"

  for f in SKILL.md commands/devflow.md commands/retro.md phases/10-知识沉淀.md concepts/SKILL.md concepts/PRD实施方法论.md; do
    if [ -f "${SKILL_ROOT}/${f}" ]; then
      ok "存在：$f"
      echo "| \`$f\` | ✓ |" >> "$report"
    else
      err "缺失：$f"
      echo "| \`$f\` | ✗ |" >> "$report"
      FAIL=$((FAIL+1))
    fi
  done

  # v3.14.1: verify 升级——真实应用后必须跑完整测试、发布审计与副本对账（此前仅 bash -n + 存在性）
  if [ "$DRY_RUN" != "1" ] && [ "$applied" -gt 0 ]; then
    echo "" >> "$report"
    echo "## Full Verification" >> "$report"

    local verify_failed=0
    if bash "$SKILL_ROOT/tests/run-tests.sh" >> "${OUTPUT_DIR}/s8b-verify-tests.log" 2>&1; then
      ok "全量测试套件 PASS"
      echo "- 全量测试套件: ✅" >> "$report"
    else
      err "全量测试套件 FAIL — 自动回滚本次应用的修改"
      echo "- 全量测试套件: ❌（日志 ${OUTPUT_DIR}/s8b-verify-tests.log）" >> "$report"
      FAIL=$((FAIL+1)); verify_failed=1
    fi

    if [ "$verify_failed" = "0" ] && bash "$SKILL_ROOT/scripts/release-audit.sh" >> "${OUTPUT_DIR}/s8b-verify-release.log" 2>&1; then
      ok "Release Audit PASS"
      echo "- Release Audit: ✅" >> "$report"
    elif [ "$verify_failed" = "0" ]; then
      err "Release Audit FAIL — 自动回滚本次应用的修改"
      echo "- Release Audit: ❌" >> "$report"
      FAIL=$((FAIL+1)); verify_failed=1
    fi

    # v3.23.0 瘦身：副本为直连软链（不再是 rsync 实体副本）——无需 apply，只做直连校验
    if [ "$verify_failed" = "0" ]; then
      if bash "$SKILL_ROOT/scripts/check-copies.sh" >> "${OUTPUT_DIR}/s8b-verify-copies.log" 2>&1; then
        ok "副本直连校验通过（check-copies）"
        echo "- 副本校验: ✅" >> "$report"
      else
        err "副本直连校验失败（check-copies）"
        echo "- 副本校验: ❌" >> "$report"
        FAIL=$((FAIL+1)); verify_failed=1
      fi
    fi

    if [ "$verify_failed" = "0" ]; then
      sed -i.bak 's/^STATUS=APPLIED$/STATUS=VERIFIED/' "${OUTPUT_DIR}/s8b-apply-receipt.env" 2>/dev/null && rm -f "${OUTPUT_DIR}/s8b-apply-receipt.env.bak"
      ok "VERIFIED：应用、测试、Release Audit、副本直连校验全部通过"
    fi

    # v3.14.6: 验证失败自动从备份恢复全部已应用文件，并把收据状态改写为 VERIFY_FAILED
    if [ "$verify_failed" = "1" ]; then
      local restored=0
      while IFS=$'\t' read -r tgt bak; do
        [ -f "$bak" ] || continue
        mkdir -p "$(dirname "$tgt")"; cp "$bak" "$tgt" && restored=$((restored+1))
      done < "${OUTPUT_DIR}/s8b-applied-manifest.tsv" 2>/dev/null
      err "VERIFY_FAILED：已回滚 $restored 个文件；备份保留于 ${BACKUP_DIR:-<unknown>}"
      # v3.15.4 (P0) → v3.23.0：源回滚后副本为直连软链、自动跟随内容；
      # 此处只做直连校验并留存证据（不再需要 apply 重同步）
      if bash "$SKILL_ROOT/scripts/check-copies.sh" >> "${OUTPUT_DIR}/s8b-verify-rollback-check.log" 2>&1; then
        warn "副本随回滚自动一致（直连软链，check-copies 通过）"
        echo "- 副本回滚校验: ✅" >> "$report"
      else
        err "回滚后副本直连校验失败——需跑仓库级 sync.sh 修复"
        echo "- 副本回滚校验: ❌（日志 ${OUTPUT_DIR}/s8b-verify-rollback-check.log）" >> "$report"
        FAIL=$((FAIL+1))
      fi
      # v3.15.4: FAILED 状态同样改写——applied>0 且 failed>0 时 STATUS=FAILED，旧 sed 匹配不到（状态语义丢失）
      sed -i.bak -E 's/^STATUS=(APPLIED|FAILED)$/STATUS=VERIFY_FAILED/' "${OUTPUT_DIR}/s8b-apply-receipt.env" 2>/dev/null && rm -f "${OUTPUT_DIR}/s8b-apply-receipt.env.bak"
    fi
  fi

  ok "验证报告 → $report"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  P10 经验反哺 Gate"
  echo "  Feature : $FEATURE"
  echo "  Mode    : $MODE"
  echo "  Skill   : $SKILL_ROOT"
  echo "  Output  : $OUTPUT_DIR"
  echo "═══════════════════════════════════════════════════════════════"

  case "$MODE" in
    collect)    step_collect ;;
    attribute)  step_attribute ;;
    categorize) step_categorize ;;
    diff)       step_diff ;;
    apply)      step_apply
                # v3.14.3: 应用后必须执行完整验证（全量测试/Release Audit/副本对账），否则 verify 声称不可达
                step_verify ;;
    verify)     step_verify ;;
    all)
      step_collect
      step_attribute
      step_categorize
      step_diff
      # v3.14.6: --all 按帮助语义永不应用——应用必须显式单独执行 `--apply --authorize-apply --write`
      if [ "$MODE" = "apply" ]; then step_apply; fi
      step_verify
      ;;
  esac

  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  P10 RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN SKIP=$SKIP"
  echo "═══════════════════════════════════════════════════════════════"

  [ "$FAIL" -gt 0 ] && exit 1
  [ "$WARN" -gt 0 ] && exit 0
  exit 0
}

main
