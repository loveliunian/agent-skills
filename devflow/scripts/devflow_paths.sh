#!/usr/bin/env bash
# ============================================================
# devflow_paths.sh — 过程性产物路径映射库（中文默认写、英文历史回退）
# ------------------------------------------------------------
# 职责：
#   - 单一事实源：docs/ 下"给人看的"过程性文档的 中文新名 <-> 英文历史名
#   - 写侧默认产出中文名；读侧"中文优先、英文回退"，在途项目零断裂。
# 边界（本库不管，禁止翻译）：
#   - .devflow/ 机器层：receipt.txt、*.state.json、design.json、
#     verification.json、*.tsv、*.env、skip-log.txt、feedback/、review-sessions/
#   - stage 名（P0..P10、P6-final 等）、feature 标识（ASCII 白名单）
#   - gates/ 收据镜像目录、json/tsv/env/html 等被脚本按表头/键解析的文件
# 兼容：macOS 自带 bash 3.2（不使用关联数组）；幂等 source。
# 依赖：无外部 source；相对 WORKSPACE（默认当前目录）解析。
# ============================================================

# 逻辑目录键 -> 中文目录（新默认）
df_zh_dir() {
  case "$1" in
    requirements)  echo "docs/需求" ;;
    prd)            echo "docs/PRD" ;;
    design)         echo "docs/详细设计" ;;
    review)         echo "docs/评审" ;;
    demo)           echo "docs/原型" ;;
    test)           echo "docs/测试" ;;
    tests)          echo "docs/测试报告" ;;
    testcases)      echo "docs/测试用例" ;;
    deploy)         echo "docs/发布" ;;
    retro)          echo "docs/复盘" ;;
    knowledge)      echo "docs/知识沉淀" ;;
    postmortem)     echo "docs/事故复盘" ;;
    incidents)      echo "docs/事故" ;;
    changes)        echo "docs/小需求变更" ;;
    mapping)        echo "docs/数据映射" ;;
    api)            echo "docs/接口文档" ;;
    ops)            echo "docs/运维手册" ;;
    runbook)        echo "docs/运行手册" ;;
    faq)            echo "docs/常见问题" ;;
    data)           echo "docs/数据字典" ;;
    guides)         echo "docs/使用指南" ;;
    *)              echo "" ;;
  esac
}

# 逻辑目录键 -> 英文历史目录（回退用）
df_en_dir() {
  case "$1" in
    requirements)  echo "docs/requirements" ;;
    prd)            echo "docs/prd" ;;
    design)         echo "docs/detailed-design" ;;
    review)         echo "docs/review" ;;
    demo)           echo "docs/demo" ;;
    test)           echo "docs/test" ;;
    tests)          echo "docs/tests" ;;
    testcases)      echo "docs/test-cases" ;;
    deploy)         echo "docs/deploy" ;;
    retro)          echo "docs/retrospectives" ;;
    knowledge)      echo "docs/knowledge" ;;
    postmortem)     echo "docs/postmortems" ;;
    incidents)      echo "docs/incidents" ;;
    changes)        echo "docs/changes" ;;
    mapping)        echo "docs/migration" ;;
    api)            echo "docs/api" ;;
    ops)            echo "docs/ops" ;;
    runbook)        echo "docs/runbook" ;;
    faq)            echo "docs/faq" ;;
    data)           echo "docs/data" ;;
    guides)         echo "docs/guides" ;;
    *)              echo "" ;;
  esac
}

# 逻辑后缀键 -> 中文后缀（新默认，不含 feature 前缀与 .md）
df_zh_suffix() {
  case "$1" in
    clarification)          echo "需求澄清" ;;
    acceptance)             echo "验收点" ;;
    constraints)            echo "技术约束" ;;
    prd_review)             echo "PRD评审" ;;
    prd_domain_checklist)   echo "PRD领域清单" ;;
    tech_selection)         echo "技术选型" ;;
    design)                 echo "详细设计" ;;
    design_summary)         echo "设计摘要" ;;
    design_review_report)   echo "设计评审报告" ;;
    design_review)          echo "设计评审" ;;
    design_domain_checklist) echo "设计领域清单" ;;
    demo_signoff)           echo "原型确认" ;;
    api_flow)               echo "接口流程" ;;
    code_review_report)     echo "代码审查报告" ;;
    security_audit)         echo "安全审计报告" ;;
    performance_audit)      echo "性能审计报告" ;;
    load_test)              echo "压测报告" ;;
    n_plus_one)             echo "N加一报告" ;;
    feasibility)            echo "可行性评审" ;;
    completeness_review)    echo "完成度评审" ;;
    scope_review)           echo "范围评审" ;;
    architecture_report)    echo "架构评审报告" ;;
    qa_check)               echo "质量检查" ;;
    validation_report)      echo "PRD验证报告" ;;
    prd_vs_code)            echo "PRD实现对比" ;;
    prd_vs_code_warnings)   echo "PRD实现对比告警" ;;
    completeness_report)    echo "完成度自检" ;;
    test_cases)             echo "测试用例" ;;
    client_journeys)        echo "客户端旅程" ;;
    test_report)            echo "测试报告" ;;
    final_verification)     echo "终验报告" ;;
    final_verification_preview) echo "终验报告-预览" ;;
    first_pass_review)      echo "首轮准确率评审" ;;
    client_journey_report)  echo "客户端旅程报告" ;;
    e2e_report)             echo "端到端报告" ;;
    integration_report)     echo "集成测试报告" ;;
    deploy_record)          echo "部署记录" ;;
    monitor_config)         echo "监控配置" ;;
    docs_index)             echo "文档索引" ;;
    retro)                  echo "复盘" ;;
    sharing)                echo "知识分享" ;;
    postmortem)             echo "事故复盘" ;;
    small_change)           echo "小需求变更" ;;
    *)                      echo "" ;;
  esac
}

# 逻辑后缀键 -> 英文历史后缀（回退用）
df_en_suffix() {
  case "$1" in
    clarification)          echo "clarification" ;;
    acceptance)             echo "acceptance-criteria" ;;
    constraints)            echo "technology-constraints" ;;
    prd_review)             echo "prd-review" ;;
    prd_domain_checklist)   echo "prd-domain-checklist" ;;
    tech_selection)         echo "tech-selection" ;;
    design)                 echo "design" ;;
    design_summary)         echo "design-summary" ;;
    design_review_report)   echo "design-review-report" ;;
    design_review)          echo "design-review" ;;
    design_domain_checklist) echo "domain-checklist" ;;
    demo_signoff)           echo "demo-signoff" ;;
    api_flow)               echo "api-flow" ;;
    code_review_report)     echo "code-review-report" ;;
    security_audit)         echo "security-audit-report" ;;
    performance_audit)      echo "performance-audit-report" ;;
    load_test)              echo "load-test-report" ;;
    n_plus_one)             echo "n-plus-one-report" ;;
    feasibility)            echo "feasibility-review" ;;
    completeness_review)    echo "completeness-review" ;;
    scope_review)           echo "scope-review" ;;
    architecture_report)    echo "architecture-report" ;;
    qa_check)               echo "qa-check" ;;
    validation_report)      echo "validation-report" ;;
    prd_vs_code)            echo "prd-vs-code-report" ;;
    prd_vs_code_warnings)   echo "prd-vs-code-warnings" ;;
    completeness_report)    echo "completeness-report" ;;
    test_cases)             echo "test-cases" ;;
    client_journeys)        echo "client-journeys" ;;
    test_report)            echo "test-report" ;;
    final_verification)     echo "final-verification-report" ;;
    final_verification_preview) echo "final-verification-report-preview" ;;
    first_pass_review)      echo "first-pass-review-report" ;;
    client_journey_report)  echo "client-journey-report" ;;
    e2e_report)             echo "e2e-report" ;;
    integration_report)     echo "integration-report" ;;
    deploy_record)          echo "deploy-record" ;;
    monitor_config)         echo "monitor-config" ;;
    docs_index)             echo "docs-index" ;;
    retro)                  echo "retro" ;;
    sharing)                echo "knowledge-sharing" ;;
    postmortem)             echo "pm" ;;
    small_change)           echo "small-change" ;;
    *)                      echo "" ;;
  esac
}

# 输出给定逻辑目录键中【实际存在】的目录（中文优先，英文随后）；
# 若都不存在，输出中文默认路径（供写侧/报错）。参数：逻辑键...
df_doc_dirs() {
  local key zh en
  for key in "$@"; do
    zh="$(df_zh_dir "$key")"; en="$(df_en_dir "$key")"
    [ -n "$zh" ] && [ -d "$zh" ] && printf '%s\n' "$zh"
    [ -n "$en" ] && [ -d "$en" ] && printf '%s\n' "$en"
  done
}

# 写侧：某逻辑目录键的新产物目录（始终中文，自动建目录由调用方决定）
df_default_dir() { df_zh_dir "$1"; }

# 解析一份阶段文档的实际路径（中文优先、英文回退）。
# 用法：df_resolve_doc <feature> <后缀逻辑键> <扩展名> <目录逻辑键...>
# 命中规则（在已存在的中/英目录内）：
#   1) 精确中文名 <feature>-<中文后缀><ext>
#   2) 精确英文名 <feature>-<英文后缀><ext>
#   3) 中文宽松 glob *<feature>*<中文关键词>*（历史中文自由命名）
# 输出第一个命中；无命中输出空串。
df_resolve_doc() {
  local feature="$1" suffix_key="$2" ext="$3"; shift 3
  local zh_suf en_suf d f
  zh_suf="$(df_zh_suffix "$suffix_key")"; en_suf="$(df_en_suffix "$suffix_key")"
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    [ -n "$zh_suf" ] && { f="$d/${feature}-${zh_suf}${ext}"; [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }; }
    [ -n "$en_suf" ] && { f="$d/${feature}-${en_suf}${ext}"; [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }; }
  done < <(df_doc_dirs "$@")
  # 宽松 glob 兜底（中文目录/英文目录都找，中文关键词优先）
  local cand
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    if [ -n "$zh_suf" ]; then
      cand=$(find "$d" -maxdepth 1 -type f -name "*${feature}*${zh_suf}*${ext}" 2>/dev/null | sort | head -1 || true)
      [ -n "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    fi
  done < <(df_doc_dirs "$@")
  return 0
}

# 写侧：新产物的标准中文路径（不落盘）。
# 用法：df_default_doc <feature> <后缀逻辑键> <扩展名> <目录逻辑键>
df_default_doc() {
  local feature="$1" suffix_key="$2" ext="$3" dir_key="$4"
  printf '%s/%s-%s%s\n' "$(df_zh_dir "$dir_key")" "$feature" "$(df_zh_suffix "$suffix_key")" "$ext"
}

# 某阶段 compute_artifact_hash 应纳入的 docs 目录（中英都给，存在才哈希由调用方判定）。
# 输出每行一个目录路径（可能不存在）。
df_stage_hash_dirs() {
  case "$1" in
    P0|P0b) printf '%s\n%s\n' "docs/需求" "docs/requirements" ;;
    P1|P2)  printf '%s\n%s\n' "docs/详细设计" "docs/detailed-design" ;;
    P3b|P3c|P3d) printf '%s\n%s\n' "docs/评审" "docs/review" ;;
    P4|P4b) printf '%s\n%s\n' "docs/测试" "docs/test" ;;
    P5)     printf '%s\n%s\n' "docs/测试用例" "docs/test-cases" ;;
    P6*)    printf '%s\n%s\n%s\n%s\n' "docs/测试" "docs/test" "docs/测试报告" "docs/tests" ;;
    P8)     printf '%s\n%s\n' "docs/发布" "docs/deploy" ;;
    P10)    printf '%s\n%s\n%s\n%s\n' "docs/复盘" "docs/retrospectives" "docs/知识沉淀" "docs/knowledge" ;;
    *)      ;;
  esac
}
