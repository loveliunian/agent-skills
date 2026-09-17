---
name: devflow
description: >-
  Use this skill for repository-level software delivery: implementing a feature,
  changing existing behavior, fixing a bug, modifying an API/UI/config/schema,
  executing a PRD, reviewing an implementation, testing, deploying, or resuming
  interrupted work. Applies to small bounded changes and full-lifecycle delivery
  even when the user never says "devflow"; typical triggers include 开发这个功能,
  实现需求, 加一个字段, 修改接口, 修复 bug, 补测试, 上线部署. Do not use for
  conceptual Q&A that requires no repository changes.
license: MIT
compatibility: Requires a repository workspace and command execution; stack-specific build, test, and migration commands are resolved from a frozen runtime profile.
metadata:
  author: xingyunliushui
  version: "3.26.8"
  updated: "2026-09-17"
  tags: "prd,detailed-design,development,migration,phase-gate,checkpoint-recovery,agent-skills"
allowed-tools: read write exec glob grep task
---

# devflow — PRD to production（v3.26.8）

本文件是唯一权威入口。历史迁移只查 `references/CHANGELOG.md`；命令、阶段、角色和模板按需加载，不在入口重复。

## 输入 / 输出契约

- 输入（必需）：PRD 路径或等价需求文本；交付模式 `new` / `change` / `extend` / `small-change`。
- 输入（可选）：`--frontend=pc-web|mini-program|app|not-applicable`、service、迁移策略、`--design-only`。
- 每阶段输出 Receipt：`phase`、`status: PASS|BLOCKED|SKIPPED`、`artifacts[]`、`verification[]`、`blockers[]`、`next_phase`。
- Gate 失败不得推进；外部副作用先有授权收据（原则 14）。

## 适用范围

- 从零构建、存量系统新增、已有需求修改。
- 基于现有项目的小需求、小改动可由自然语言触发 `/small-change`；必须先扫描当前项目，风险扩大时自动升级完整 `change` 流程。
- 服务端先按 `references/runtime-profile.md` 解析 Runtime Profile；`java-spring-flyway` 是内置参考 Profile，其他技术栈在 P1 冻结等价 adapter（build/test/security/migration），核心流程不假设具体框架。
- 客户端覆盖 PC Web、微信小程序、APP 或明确的 `not-applicable` 前端范围。
- PRD 到详设、实现、测试、部署、监控、文档、复盘，或从 checkpoint 恢复。

仅回答概念、只做独立代码审查或没有交付生命周期诉求时，不启动全流程。

## 不可违背的原则

1. 每阶段 Gate 返回 0 后才能推进；文档存在、静态构建或 H2 结果不能替代真实运行证据。
2. 完成声明附命令、退出码、文件和环境边界；`运行未验证` 不得写成完成。
3. 开发、审查、完成度审计角色分离；不能自签。
4. 按“数据 + API + 客户端 + 测试 + 可达性”垂直切片。
5. 适用 Flyway 时保持 h2、postgresql、oracle、kingbase 四方言一致；不适用需在冻结设计说明。
6. 测试凭据只能从 seed 或配置事实源追溯，禁止猜测和记录明文秘密。
7. 写产物前读对应模板，写后跑对应 Gate；模板与产物标题和字段契约一致。
8. Gate 失败立即保存 checkpoint、记录证据并停止；修复后重跑同一 Gate。
9. P10 教训先写入项目本地 feedback queue；修改已安装 skill 必须获得用户明确批准。
10. 设计必须显式说明成熟组件复用、公共服务/组件抽取、命名/开发/注释规范及关键设计理由。
11. 评审必须先跑主责探针再下结论：深层发现（DF）按五字段场景链契约输出，零发现 ✅ 须附核查证据；规范见 `concepts/review-depth-methodology.md`。
12. 用户/PRD 明确指定的技术组件、版本、许可证或部署方式必须在 P0 冻结为硬约束；P1 只能在约束内评分，偏离必须 `BLOCKED` 并经用户批准后重冻。
13. P3 前必须解析 Runtime Profile；核心流程不得假设 Maven/Spring/Flyway/JaCoCo/Vue，只有 profile 声明的能力才能作为验证依据；能力缺失即 `BLOCKED`。
14. 部署、迁移、推送、发布等外部副作用必须有显式人工授权收据（`authorizations/release.json`）；无授权时最高只能声明 `READY_TO_RELEASE`，不得声明 `RELEASED`。
15. 面向读者文档必须遵循 `concepts/中文文风规范.md`；人工自检、抽查，不设自动文风硬校验或Gate阻断。

完整铁律与工程边界见 `concepts/core.md`；细节原则见 `concepts/principles-detailed.md`；经验教训库见 `concepts/lessons-learned.md`（33 条可复现教训 + 启动检查清单）。

## 启动与路由

1. 先读 `concepts/core.md`。
2. 读 `commands/ROUTING.md`，选择全流程或单阶段命令。
3. 只加载当前 command、phase、subagent、template 和 Gate 脚本。
4. 初始化时冻结 `--frontend=pc-web|mini-program|app|not-applicable`；小程序、APP 和配置化 PC Web 在 P2 后冻结 `devflow-client.json` 哈希。

“小需求/小改动、局部 UI、配置、修复、字段/默认值/校验”等先加载 `commands/small-change.md`；`SMALL-CHANGE` 默认只到 `MERGE_READY`，明确要求上线才绑定 P7+P8 收据并声明 `RELEASED`。

全流程编排、参数、Gate 调用、跳过与恢复见 `commands/devflow.md`。自然语言触发与反例见 `concepts/natural-language-triggers.md`。

### 过程性产物命名（v3.22.0 起）

- 给人看的过程性文档默认用**中文名**：目录如 `docs/需求`、`docs/详细设计`、`docs/评审`、`docs/测试`、`docs/测试用例`、`docs/发布`、`docs/复盘`；文件如 `<feature>-需求澄清.md`、`<feature>-验收点.md`、`<feature>-详细设计.md`、`<feature>-终验报告.md`、`<feature>-部署记录.md`。完整中英映射见 `scripts/devflow_paths.sh`。
- 所有 Gate **中文优先、英文回退**：历史英文路径（`docs/requirements/`、`<feature>-design.md` 等）继续被接受，在途项目无需迁移。
- 机器契约层**不翻译、不可改名**：`.devflow/` 下的 `receipt.txt`、`*.state.json`、`<kind>.json`（全阶段结构化产物，v3.25.2）、`*.tsv`、`*.env`、`skip-log.txt`、`feedback/`、`review-sessions/`、`gates/<PHASE>/`，以及 stage 名（P0–P10）与 ASCII feature 标识；证据型 `*-implementation-evidence.tsv`、`*-p4-results.tsv`、`*-unit-coverage.html`、`*-migration-evidence.env` 等同样保留英文。

### 全阶段结构化产物（v3.25.2）

每个环节的 md 产物有 JSON 正本，按 schema 契约填 `.devflow/<feature>/<kind>.json`，经 `df_pipeline.py <kind>` 校验渲染进 Gate，空集合须 `zero_results` 声明。kind↔阶段映射见上表。

Gate 强制矩阵（P0/P2/P3c/P3d/P6）见 `references/structured-artifacts.md`。

## P0-P10 单轨

| 阶段 | 目标 | Gate |
|---|---|---|
| P0/P0b | 澄清、原子验收点、PRD 评审（DF/AW 深度契约 + 领域专项清单） | `df_pipeline.py clarification/acceptance/constraints`、`s0_acceptance_gate.sh`、`df_pipeline.py prd-review`、`gen-domain-checklist.sh`、`artifact_gate.sh P0b` |
| P1 | 技术选型与工程事实源 | `df_pipeline.py tech-selection`、`s1_fact_sources_gate.sh` |
| P2/P2a/P2b | 字段级详设、5 角色评审（DF/AW 深度契约）、原型 | `df_pipeline.py design`（design.json 结构化产物层，失败关闭）、`s2_design_coverage_gate.sh`（§2c 对账）、`df_pipeline.py design-review`、`p2a_design_review_gate.sh`、`p2b_demo_gate.sh` |
| P3/P3b/P3c/P3d | 实现、代码审查、安全、性能 | `build-watchdog.sh gate`（P3-build）、`df_pipeline.py self-check`、`p3_completion_gate.sh`、`df_pipeline.py code-review`、`p3b_code_review_gate.sh`、`p3_security_perf_gate.sh` |
| P4/P4b | PRD 验证与精确 PRD-vs-Code | `df_pipeline.py prd-validation`、`p4_validation_gate.sh`、`p4_prd_vs_code.sh` |
| P5/P6 | 测试设计、执行、迁移、凭证、准确率 | `df_pipeline.py test-cases`、`p5_test_cases_gate.sh`(主)、`s5_migration_gate.sh`(B/C，P5-migration)、`s6_first_pass_accuracy.sh`、`p6_credential_gate.sh` |
| P6 终验 | 部署前强制：验收点集合与冻结 baseline 全等 + FAIL=0；Gate 实际执行五类测试命令并绑定报告、日志与真实退出码；verification.json 必填并对账冻结前端范围 | `s6_final_verification_gate.sh`（执行→校验→渲染报告→收据绑定 `gates/P6-final/`，缺失则 complete P6 拒绝） |
| P7/P8/P9 | 部署、监控、文档 | `df_pipeline.py deployment/monitoring/docs-index`、`artifact_gate.sh P7/P8/P9` |
| P10 | 复盘与项目反馈闭环 | `df_pipeline.py retrospective`、`p10_feedback_gate.sh` |

P11 只用于独立事故复盘，不计入正常交付链。

## 停止条件

- 输入、冻结哈希或证据漂移：回到最早受影响阶段。
- Gate 非零或独立审计不可用：报告 `BLOCKED`，不得继续或自签。
- 用户明确授权的合法跳过必须写入 `.devflow/<feature>/skip-log.txt`；P3、P4b、P6、P7-P10 不可跳过。

发布技能自身前必须运行唯一发布入口 `bash scripts/release.sh`（含完整测试、版本一致性、Release Audit、ShellCheck、Manifest、副本对账、树 hash 七道门禁，任一失败即禁止发布）。
