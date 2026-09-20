---
name: devflow-routing
version: "3.29.0"
description: devflow 命令、阶段、Gate 与人工资源注册表。
---

# devflow 路由索引（v3.29.0）

本文件只负责路由。执行规则以 `SKILL.md`、对应 command/phase 和 `concepts/core.md` 为准。

## 命令路由

| 命令 | 阶段 | 加载文件 | 主要 Gate |
|---|---|---|---|
| `/devflow` | P0-P10 | `commands/devflow.md` | 全链 Gate |
| `/small-change` | 现有项目小需求/小改动 | `commands/small-change.md` | `SMALL-CHANGE`：`small-change-gate.sh classify/verify` |
| `/spec` | P0-P2 | `commands/spec.md` | `s0_acceptance_gate.sh`、`s1_fact_sources_gate.sh`、`s2_design_coverage_gate.sh` |
| `/design-review` | P2a | `commands/design-review.md` | `gen-domain-checklist.sh`、`p2a_design_review_gate.sh` |
| `/plan` | P2.5 | `commands/plan.md` | 计划审查 |
| `/build` | P3 | `commands/build.md` | `build-watchdog.sh gate`（P3-build）、`p3_completion_gate.sh` |
| `/review` | P3b | `commands/review.md` | `p3b_code_review_gate.sh` |
| `/security` | P3c | `commands/security.md` | `p3_security_perf_gate.sh` |
| `/performance` | P3d | `commands/performance.md` | `p3_security_perf_gate.sh` |
| `/prd-vs-code` | P4b | `commands/prd-vs-code.md` | `p4_prd_vs_code.sh` |
| `/test` | P5-P6 | `commands/test.md` | `p5_test_cases_gate.sh`、`s5_migration_gate.sh`（B/C，P5-migration）、`s6_first_pass_accuracy.sh`、`p6_credential_gate.sh`、`s6_final_verification_gate.sh` |
| `/audit-completeness` | 任意 | `commands/audit-completeness.md` | 对应阶段 Gate |
| `/deploy` | P7 | `commands/deploy.md` | `artifact_gate.sh P7` |
| `/monitor` | P8 | `commands/monitor.md` | `artifact_gate.sh P8` |
| `/docs` | P9 | `commands/docs.md` | `artifact_gate.sh P9` |
| `/retro` | P10 | `commands/retro.md` | `p10_feedback_gate.sh` |
| `/postmortem` | P11 事件级 | `commands/postmortem.md` | 独立事故验收 |
| `/arch-review` | P1.5 | `commands/arch-review.md` | 架构评分卡 |
| `/audit-pitfalls` | P3+ | `commands/audit-pitfalls.md` | `check-arch-pitfalls.sh` |
| `/qa-check` | P5+ | `commands/qa-check.md` | 质量检查 |
| `/init-fact-sources` | P1 | `commands/init-fact-sources.md` | `s1_fact_sources_gate.sh` |
| `/devflow-state` | 任意 | `commands/devflow-state.md` | 状态一致性 |

## 阶段、产物与 Gate

| 阶段 | 关键产物 | Gate |
|---|---|---|
| P0 | `docs/需求/<feature>-验收点.md` + `<feature>-技术约束.md` | `s0_acceptance_gate.sh` |
| P0b | `docs/需求/<feature>-PRD评审.md` | `artifact_gate.sh P0b` |
| P1 | 技术选型与工程事实源 | `s1_fact_sources_gate.sh` |
| P2 | `docs/详细设计/<feature>-详细设计.md` | `s2_design_coverage_gate.sh` |
| P2a | 详设评审报告，5 角色（范围、架构、可行性、技术、DBA） | `p2a_design_review_gate.sh` |
| P2b | 原型 Demo 证据 | `p2b_demo_gate.sh` |
| P3 | 服务端、客户端、迁移、单测 | `build-watchdog.sh gate`（P3-build）+ `p3_completion_gate.sh` |
| P3b | 代码审查报告 | `p3b_code_review_gate.sh` |
| P3c/P3d | 安全与性能报告 | `p3_security_perf_gate.sh` |
| P4 | PRD 验证报告 | `p4_validation_gate.sh` |
| P4b | PRD-vs-Code 报告 | `p4_prd_vs_code.sh` |
| P5 | 测试用例主证据；B/C 迁移辅助证据 | `p5_test_cases_gate.sh` + `s5_migration_gate.sh`（B/C，P5-migration） |
| P6 | 单元、集成、客户端旅程、凭证、首轮准确率；P6-final 部署前终验（验收点 FAIL=0，Gate 实际执行五类命令并绑定报告/日志/真实退出码） | `s6_first_pass_accuracy.sh` + `p6_credential_gate.sh` + `s6_final_verification_gate.sh`（收据 `gates/P6-final/`） |
| P7 | 部署记录与真实发布证据 | `artifact_gate.sh P7` |
| P8 | 指标、日志、告警证据 | `artifact_gate.sh P8` |
| P9 | 用户、开发、API、运维文档 | `artifact_gate.sh P9` |
| P10 | 复盘与项目反馈闭环 | `p10_feedback_gate.sh` |

客户端动作统一通过 `scripts/client-adapter.sh` 和冻结的 `devflow-client.json` 路由；PC Web 使用浏览器旅程，小程序使用开发者工具/模拟器旅程，APP 使用模拟器或真机旅程。

## 人工资源注册

资源权威注册表见 [`references/RESOURCE-REGISTRY.md`](../references/RESOURCE-REGISTRY.md)。未登记的 phase、subagent、template 会阻断发布。

| 阶段/用途 | 模板 |
|---|---|
| P0 需求澄清 | `templates/需求澄清-模板.md` |
| P0 验收点 | `templates/验收点-模板.md` |
| P0b PRD 评审 | `templates/PRD评审-模板.md` |
| P1 技术选型 | `templates/设计决策记录-模板.md` |
| P2 详细设计 | `templates/详细设计-模板.md` / `templates/详细设计-完整版-模板.md` |
| P2a 设计评审 | `templates/详细设计评审报告-模板.md` |
| P3b 代码审查 | `templates/代码审查报告-模板.md` |
| P4 PRD 验证 | `templates/PRD验证报告-模板.md` |
| P5 测试设计 | `templates/测试用例-模板.md` |
| P7 部署 | `templates/部署记录-模板.md` |
| P8 监控 | `templates/监控配置-模板.md` |
| P9 文档索引 | `templates/文档索引-模板.md` |
| P10 复盘 | `templates/复盘报告-模板.md` |
| 小需求/小改动 | `templates/小需求变更-模板.md` |
| 独立完成度审计 | `templates/完成度自检报告-模板.md` |

## 路由约束

- Gate 非零即停；不得用文档存在、静态构建或 H2 结果替代真实运行证据。
- P3、P4b、P6、P7-P10 不可隐式跳过；任何合法跳过都需用户明确授权并写入 `skip-log.txt`。
- 开发者不能签署自己的审查或完成度 Gate；独立审计条件缺失时状态为 `BLOCKED`。
