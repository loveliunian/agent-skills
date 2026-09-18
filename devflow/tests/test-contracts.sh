#!/usr/bin/env bash
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

echo "=== devflow contract tests ==="

frontmatter_chars=$(awk 'BEGIN{n=0;f=0} /^---$/{f++; if(f==2){print n; exit} next} f==1{n+=length($0)+1}' "$ROOT/SKILL.md")
words=$(wc -w < "$ROOT/SKILL.md" | tr -d ' ')
[ "${frontmatter_chars:-99999}" -le 1024 ] && ok "frontmatter <=1024 chars" || bad "frontmatter too large"
[ "${words:-99999}" -le 500 ] && ok "SKILL.md <=500 words" || bad "SKILL.md too large: $words words"

CURRENT_VER=$(sed -n 's/^  version: "\(.*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
expect_contains "SKILL.md" '^description: >-' "discovery description uses folded trigger block"
expect_contains "SKILL.md" '修复 a bug|修复 bug|fixing a bug|fix a bug' "discovery description covers natural-language bugfix"
expect_contains "SKILL.md" '^compatibility: ' "agent-skills compatibility is declared top-level"
expect_contains "SKILL.md" '^allowed-tools: read write exec glob grep task$' "allowed-tools uses spec space-separated form"
expect_file "references/runtime-profile.md"
expect_file "references/profiles/java-spring-flyway.md"
expect_file "references/sensitive-data-policy.md"
expect_file "tests/trigger-cases.yaml"
expect_file "scripts/install.sh"
expect_file "scripts/doctor.sh"
expect_contains "SKILL.md" 'PASS|BLOCKED|SKIPPED' "SKILL.md declares phase receipt contract"
expect_contains "references/CHANGELOG.md" "^## v${CURRENT_VER}" "changelog contains current release"
expect_contains "commands/devflow.md" 'execute_gate' "orchestrator defines gate execution"
expect_contains "commands/devflow.md" 'check_skip_authorization' "orchestrator defines skip authorization"
expect_contains "commands/devflow.md" '进度可视化' "orchestrator defines progress output"
expect_contains "commands/devflow.md" 'frontend=pc-web\|mini-program\|app\|not-applicable' "frontend scope is explicit"

for f in \
  scripts/s0_acceptance_gate.sh scripts/s1_fact_sources_gate.sh \
  scripts/s2_design_coverage_gate.sh scripts/s3_migration_mapping_gate.sh \
  scripts/s4_first_pass_snapshot.sh scripts/s5_migration_gate.sh \
  scripts/s6_first_pass_accuracy.sh maintenance/s8_graph_health_gate.sh \
  scripts/p2a_design_review_gate.sh scripts/p2b_demo_gate.sh \
  scripts/p3_completion_gate.sh scripts/p3b_code_review_gate.sh \
  scripts/p3_security_perf_gate.sh scripts/p4_prd_vs_code.sh \
  scripts/p4_validation_gate.sh scripts/p6_credential_gate.sh scripts/artifact_gate.sh \
  scripts/p5_test_cases_gate.sh scripts/preflight-port.sh \
  scripts/p10_feedback_gate.sh \
  scripts/client-adapter.sh scripts/release-audit.sh; do
  expect_file "$f"
done

expect_contains "commands/spec.md" 's2_design_coverage_gate\.sh' "spec runs P2 gate"
expect_contains "commands/spec.md" 's3_migration_mapping_gate\.sh' "spec runs migration gate"
expect_contains "commands/build.md" 's4_first_pass_snapshot\.sh' "build freezes first-pass baseline"
expect_contains "commands/test.md" 's5_migration_gate\.sh' "test runs migration gate"
expect_contains "commands/test.md" 'p5_test_cases_gate\.sh' "test runs primary P5 test-case gate"
expect_contains "commands/test.md" 's6_first_pass_accuracy\.sh' "test calculates first-pass accuracy"
expect_contains "commands/devflow.md" 'p4_validation_gate\.sh' "orchestrator routes P4 validation gate"
expect_contains "commands/devflow.md" '\-\-scaffold=<path>' "orchestrator registers --scaffold input material"
expect_contains "phases/01-技术选型.md" '脚手架重合度审计' "P1 documents scaffold overlap audit (铁律 18)"
expect_contains "concepts/core.md" 'Scaffold Overlap Audit' "core iron rule 18 registered"
expect_contains "concepts/core.md" 'Input-Material Precedence' "core iron rule 19 registered"
expect_contains "commands/devflow.md" 'p10_feedback_gate\.sh' "orchestrator routes P10 project feedback gate"
expect_contains "commands/audit-completeness.md" 'client-adapter\.sh' "completion audit uses client adapter"
expect_not_contains "commands/devflow.md" 'localhost:8086' "orchestrator has no fixed service port"

expect_contains "scripts/p2a_design_review_gate.sh" 'DBA' "P2a checks DBA role"
expect_contains "scripts/p2a_design_review_gate.sh" '设计质量四要素' "P2a checks design quality"
expect_contains "templates/详细设计-完整版-模板.md" '成熟组件复用清单' "design covers mature component reuse"
expect_contains "templates/详细设计-完整版-模板.md" '公共服务与公共组件抽取登记' "design covers public extraction"
expect_contains "schemas/tech-selection.schema.json" '"standards"' "tech selection carries standards baseline"
expect_contains "scripts/df_render.py" '规范遵循' "tech report renders standards section"
expect_contains "templates/数据库设计决策-模板.md" '设计决策记录（DDR）' "db design doc records rationale"

# v3.16.25: hard contracts and role/template routing must be machine-verifiable
expect_file "templates/技术约束-模板.md"
expect_contains "phases/00-需求澄清.md" 'MUST_USE|MUST_NOT_USE' "P0 freezes technology constraints"
expect_contains "phases/01-技术选型.md" '约束 ID|constraint_id' "P1 carries constraint IDs"
expect_contains "scripts/s1_fact_sources_gate.sh" 'tech-selection|技术选型报告' "P1 verifies technology selection artifact"
expect_contains "scripts/s1_fact_sources_gate.sh" 'MUST_USE|MUST_NOT_USE' "P1 enforces hard technology constraints"
expect_contains "scripts/p2a_design_review_gate.sh" 'REVIEW_SESSION_ID' "P2a verifies review independence receipt"
expect_contains "scripts/p2a_design_review_gate.sh" 'CLOSED' "P2a verifies finding closure"
expect_file "subagents/sql-dev.md"
expect_file "subagents/backend-dev.md"
expect_file "subagents/frontend-dev.md"
expect_contains "subagents/design-review-committee.md" '前端专家|测试开发' "P2a committee role names are canonical"
expect_contains "templates/详细设计-完整版-模板.md" 'template_id|模板 ID' "design template identity is frozen"
expect_contains "templates/详细设计-完整版-模板.md" 'anchor: acceptance-traceability' "design has semantic traceability anchor"
expect_contains "scripts/s2_design_coverage_gate.sh" '[-][-]mode' "P2 gate distinguishes monolith/total/sub templates"
expect_contains "scripts/tech_constraints_lib.sh" 'tc_check_compliance' "shared constraint compliance library"
expect_contains "scripts/review-receipt.sh" 'output_report_sha' "independent review receipts carry artifact SHA"
expect_contains "scripts/s2_design_coverage_gate.sh" 'comm -23|comm -13|set equality|集合一致' "P2 validates exact acceptance-ID set"
expect_not_contains "commands/review.md" 'v1.7 治理类专项' "generic review has no M-03-specific probes"

expect_not_contains "scripts/devflow-state.sh" 'sed -i\.bak' "state mutation is non-lossy"
expect_contains "scripts/devflow-state-core.sh" 'client-freeze' "state freezes client manifests"
expect_contains "scripts/p3_completion_gate.sh" 'verify_client_manifest' "P3 verifies client manifest"
expect_contains "scripts/p4_prd_vs_code.sh" 'grep -qxF "\$page"' "P4 compares complete client paths"
expect_contains "scripts/artifact_gate.sh" 'client-adapter.sh.*release' "P7 executes configured release command"
expect_contains "scripts/build-watchdog.sh" 'client-adapter.sh.*build' "watchdog routes client builds"

syntax_fail=0
for f in "$ROOT"/scripts/*.sh "$ROOT"/hooks/*.sh "$ROOT"/tests/*.sh; do
  bash -n "$f" || syntax_fail=$((syntax_fail + 1))
done
[ "$syntax_fail" -eq 0 ] && ok "all shell syntax" || bad "shell syntax failures=$syntax_fail"

finish CONTRACTS
