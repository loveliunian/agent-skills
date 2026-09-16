---
name: devflow-changelog-archive
description: Historical devflow release notes through v3.8.1.
metadata:
  archived: 2026-08-24
---

## v3.8.1 (2026-08-18)

- SKILL.md 命令表补齐（11 个缺失命令：/arch-review /audit-pitfalls /deploy /docs /monitor /performance /plan /postmortem /qa-check /retro /security）
- 修复 `phases/11-Postmortem.md` 和 S0-S8 的中文 `name` 为英文 slug
- 补齐 9 个缺失 frontmatter `name` 字段的文件
- 删除 4 个废弃命令（validate/test-run/test-gen/tech-select）和 4 个废弃 phases 文件
- 删除 1 个无引用脚本（i18n-a11y-check.sh）
- 统一所有 frontmatter 版本号为 3.8.1
- 修复 README.md 缺失的版本号和 P11 Postmortem Phase 条目

## 当前版本
- 
- 
- 
- v3.8.0 — 2026-08-18 SKILL.md 全面升级
- v3.4 — 2026-08-12 Architecture Pitfalls（架构陷阱清单 + 自动检查）
- v3.3 — 2026-08-12 P11 Postmortem 阶段 + 跨服务 S.U.P.E.R 落地
- v3.2 — 2026-08-12 三项 P1 借鉴（S.U.P.E.R / Demo gate / Socratic dial）
- v3.1 — 2026-08-12 同类 skill 借鉴（6 新增 + 3 review + 同步多 runtime）
- v3.0.1 — 2026-08-11 Skill 全面优化（6 脚本 + 2 模板 + 13 处去重 + 编号修复）
- v3.0 — 2026-08-11 工程事实源体系
- v2.5 — PRD-vs-Code 机器可验证 gate
- v2.4 — 完成度门控 + credential gate

> 每个版本的破坏性变更和迁移步骤。

— 2026-08-18 流程自动化增强 + 详设总分架构决策

### 新增

- **自动 Gate 执行循环**：`commands/devflow.md` 新增 `execute_gate()` 函数和 `while true` 执行循环
- **跳过授权机制**：添加 `check_skip_authorization()` 函数，跳过阶段需用户显式授权
- **进度可视化**：新增 ASCII 进度条和阶段状态符号（✓→○❌⏭️）
- **总分架构决策机制**：AI 自主决定采用总分还是单体结构编写详设

### 增强

- **双维度正交模型文档**：`commands/devflow.md` 新增章节明确说明 S0-S8（内省循环）和 P0-P11（业务闭环）的本质区别和进入方式
- **执行层产物规范**：`commands/devflow.md` 新增 P0-P11 产物映射表，明确每个阶段的产物模板、输出路径和 Gate 要求
- **强制评审循环机制**：
  - **P0b PRD评审 + 澄清循环**：必须经过业务/技术/测试/安全专家多 Agent 讨论评审，遗留问题 = 0 才能通过
  - **P2 详细设计评审 + 澄清循环**：必须经过架构/后端/前端/测试多 Agent 讨论评审，无遗留问题才能通过
  - 评审流程图、Gate 标准、多 Agent 角色职责已文档化
  - **用户召唤机制**：评审中无法解答的问题召唤用户参与决策
  - **评审后模板改进 Hook**：
    - 新增 `scripts/hooks/after-prd-review-hook.sh`：分析 PRD 评审问题，改进 `需求澄清-模板.md`、`PRD评审-模板.md`、`测试用例-模板.md`
    - 新增 `scripts/hooks/after-design-review-hook.sh`：分析设计评审问题，改进 `详细设计-模板.md`
    - 改进建议存储在 `.template-improvements/` 目录
- **模板跨项目复用**：
  - 模板统一放入 `.cursor/skills/devflow/templates/` 目录
  - `scripts/devflow-state.sh` 命令：`list-templates`（列出可用模板）、`generate`（从模板生成产物）
  - 支持多种占位符模式：`{FeatureName}`、`FEATURE`
- **详细设计模板优化**：
  - 新增 §0 总分架构决策章节，AI 自主决策总分或单体结构
  - 决策矩阵明确：模块数≥5/跨服务→总分；简单CRUD→单体
  - 分文档章节指引：模块内数据模型/接口/规则/流程/前端
  - `commands/spec.md` 新增 S2.1 架构决策指引
- **版本标识清理**：清理所有文档中的历史版本标记
- **Gate 脚本产物存在性检查**：s1/s2/s5 gate 脚本增强内容非空验证
- **Gate 收据生成**：s1/s2/s5 gate 脚本生成标准收据到 `.devflow/<stage>-gates/` 目录

### Gate 收据格式

```bash
EXIT_CODE=0
ARTIFACTS=<file1>,<file2>
OUTPUT=PASS=7 FAIL=1 WARN=2 ...
CHECKED_AT=2026-08-18T14:00:00Z
```

### 进度可视化示例

```
╔═══════════════════════════════════════════════════════════════╗
║  DevFlow 进度 [████████████░░░░░░░░░░░░░░░░░░░░] 50%       ║
║  当前: S5 测试门控                                          ║
║  已完成: S0 ✓ S1 ✓ S2 ✓ S3 ✓ S4 ✓                         ║
║  待完成: S6 ○ S7 ○ S8 ○                                    ║
╠═══════════════════════════════════════════════════════════════╣
║  阻塞: 无                                                   ║
╚═══════════════════════════════════════════════════════════════╝
```

---

— 2026-08-18 漏洞修复

### 新增

- S0-S8正式接入`/devflow`、`/spec`、`/build`、`/test`、`/audit-completeness`
- 原子验收点、工程事实源、100%设计覆盖、迁移映射、首轮快照/准确率和图谱证据Gate
- `tests/run-tests.sh`与三个压力场景回归基线

### 修复

- P3编译/测试失败不再记PASS，FAIL必返回非零
- P4从全仓数量比较改为冻结验收ID逐项代码/测试证据
- 保留P7部署、P8监控、P9文档、P10复盘，不再映射为S6-S8替代阶段
- 动态端口、项目内状态、全局/项目Skill同步和版本检查

### 破坏性

- P4要求`implementation-evidence.tsv`
- S0-S3缺少机器证据时不能进入P3
- 试点首轮准确率低于80%不能进入全量推广

---

— 2026-08-17 入口精简与渐进披露

### 修复

- SKILL.md frontmatter description 精简到 200 字以内（原混入会话）
- SKILL.md 入口文件从 3261 词精简到约 800 词
- 详细流程说明移至对应 commands 和 phases 文件

### 变更

- SKILL.md 保留：核心原则（6条）、Phase 验收门控表、快捷命令表格、Phase 文件索引
- 铁律、Overview、Great Skill 5要素移至 `concepts/SKILL.md`
- version 从 3.6.0 更新至 3.7.0
- S0-S6 phase 文件 version 统一更新为 3.7.0
- CHANGELOG 新增 v3.7.0 条目

### 破坏性

- SKILL.md 内容大幅精简，原有详细说明已迁移到 concepts/SKILL.md

---

— 2026-08-18 漏洞修复与优化

### 修复

- **CHANGELOG.md 版本同步**：frontmatter version 从 3.4.1 更新至 3.8.0
- **废弃命令清理**：test-run.md、test-gen.md、validate.md 确认 DEPRECATED 状态
- **tests/run-tests.sh**：修复 v3.8.0 CHANGELOG 检查（实际文件已有 v3.8.0 章节）

### 新增

- **Gate 收据生成**：s0-s3 gate 脚本增强，生成标准格式收据（EXIT_CODE/ARTIFACT_HASH/ARTIFACTS/OUTPUT）
- **p3_completion_gate.sh 增强**：菜单 seed 检查增加 setval 序列验证
- **s8_graph_health_gate.sh**：GIT_RANGE 环境变量支持

### 优化

- **Graph 图谱语义澄清**：S6-S8 阶段命名与 devflow-state.sh 一致
- **依赖检查增强**：p3_completion_gate.sh 增加 jq 存在性检查

---

— 2026-08-17 字段级设计与首轮代码准确率闭环

### 新增

- **description frontmatter** 改为「PRD → 字段级详细设计 → 100%设计覆盖 → 老系统迁移 → 首轮代码准确率达标」
- **触发词** 新增：字段级、100%覆盖、老系统迁移

### 变更

- SKILL.md 头部描述（description）由 v3.7.0 的"全生命周期开发流程"改写为本版触发词摘要
- CHANGELOG 新增 v3.8.0 条目
- version 从 3.7.0 更新至 3.8.0

### 测试

- `tests/run-tests.sh` 版本断言同步更新到 3.8.0

---

## v2.5.0（2026-07-28）— PRD vs Code 机器可验证对比

### 新增（核心）

- **`scripts/p4_prd_vs_code.sh`** — P4 子阶段自检脚本，11 项 grep 驱动：
  1. PRD/详设文件存在 + §3/§6/§7
  2. 详设接口 vs Controller endpoint
  3. 详设表 vs Flyway 4 库（h2/postgresql/oracle/kingbase）
  4. 详设字段 vs DDL 列名
  5. 写操作 Controller 全部 `@PreAuthorize`
  6. 前端 `views/<feature>/index.vue` 存在
  7. 前端 `api/*.ts` 封装存在
  8. 单测 `*Test.java` 存在
  9. 详设关键字命中率（前 20 采样）
  10. `TODO`/`FIXME` 残留 = 0
  11. 跨服务调用契约落地
- **`phases/04b-PRD-实现对比.md`** — P4 子阶段文档
- **`commands/prd-vs-code.md`** — 新命令入口（`/prd-vs-code <feature>`）

### 变更

- `SKILL.md` v2.4.0 → v2.5.0：新增 12→13 强制命令清单（含 7b `/prd-vs-code`），Phase 4 验收 Gate 加硬约束
- `phases/04-PRD验证.md`：新增"v2.5 子阶段：PRD-实现对比"段，Checklist 加脚本退出码项
- `commands/validate.md`：升级为 v2.5，强制先跑 `p4_prd_vs_code.sh` 后写 `*-prd-vs-code-report.md`
- `QUICK.md`：P4 行新增硬 Gate 提示，新增 Phase 4b 行，新增命令条目

### 迁移步骤（从 v2.4.0）

```bash
# 1. 安装新脚本（仓库内文件，无需安装）
chmod +x .cursor/skills/devflow/scripts/p4_prd_vs_code.sh

# 2. 在 Phase 4 入口跑一次
bash "$SKILL_ROOT/scripts/p4_prd_vs_code.sh" <feature>
# 退出码 0 = PASS；非 0 = FAIL（P0>0），阻塞 P5

# 3. 输出报告追加到 <feature>-prd-vs-code-report.md
```

### 破坏性

| v2.4 习惯 | v2.5 强制 |
|-----------|-----------|
| P4 人工逐条对照 | `scripts/p4_prd_vs_code.sh` 11 项 grep |
| "P0 阻断=0" 软约束 | **退出码 = 0 的硬 Gate**，CI 嵌入失败即红 |
| `docs/test/<feature>-validation-report.md` 单一产出 | **+ `docs/test/<feature>-prd-vs-code-report.md`**（双产出） |

### 历史教训对应

- 2026-07-24 M-03：v1.7 跑出"接口 95.7% / 字段 100% / 权限 0%" 失衡 → v2.0 加 P3 grep
- 2026-07-28：仅有 P3 grep 仍可能漏 PRD 维度 → v2.5 在 P4 加机器可验证对比

---

## v2.4.0（2026-07-24）

### 新增

- `concepts/SKILL.md` — true north，10 条不可违背的铁律（所有 phase skill 必须与本文对齐）
- `agents/devflow.md` — Phase 编排器，定义 P0→P10 加载链和 gate 跳转表
- `scripts/p3_completion_gate.sh` — P3 23 项自检（一键执行，bash 源码不进 context）
- `scripts/p6_credential_gate.sh` — P6 凭证可追溯性 gate（盲猜密码 P0 阻断）
- `scripts/p3_detail_diff.sh` — P3 详设 vs Flyway 表差异 diff
- `paths:` frontmatter — 20 个 commands/subagents 加了 glob scope 限定
- `trigger phrases` — 21 个 commands/subagents 换了 trigger 描述（自动路由更准）

### 迁移步骤（从 v2.3.0）

无破坏性变更，**直接升级**。

---

→ v2.3.1（2026-07-24）

### 新增（安全修复）

- `references/severity-tiers.md` 新增"P0：新功能交付物不完整（菜单/权限缺失）"
- `commands/build.md` 新增 P3 自检项 12-15（菜单 seed 4 表 + admin 授权 + setval + router 注册）
- `commands/audit-completeness.md` P3 变成 23 项（11 + 4 菜单 seed + 8 治理专项）

### 迁移步骤

```
# 重新跑一次 /audit-completeness P3 <feature>
# 会自动检测菜单 seed 是否完整
```

### 破坏性：无

---

→ v2.3.0（2026-07-16）

### 新增

- **强制 Phase Gate**：每个 Phase 必须通过完成度自检才能进入下个 Phase
- **P3b/P7/P8/P9/P10 独立强制**：这 6 个 Phase 从"自动跳过"变成"必须显式执行"
- **11 项机器可执行自检**：TODO = 0、`@PreAuthorize` 覆盖、4 方言 Flyway、JaCoCo ≥ 80%、Maven + 前端 build
- **垂直切片优先**：每个切片 = 表 + API + 前端页面 + 单测 + 菜单 seed
- **角色分离**：`backend-dev` ≠ `completeness-auditor` ≠ `code-reviewer`

### 迁移步骤（从 v1.7）

```
# 1. 不再接受"文档产出"作为完成依据
#    必须在 commands/audit-completeness.md 中运行实际 grep 命令

# 2. 重新跑 P3 自检（M-03 示例）
/audit-completeness P3 m-03-basic-library

# 3. 重新跑 P3b Code Review
/audit-completeness P3b m-03-basic-library

# 4. 重新跑 P7/P8/P9/P10
/audit-completeness P7 m-03-basic-library
/audit-completeness P8 m-03-basic-library
/audit-completeness P9 m-03-basic-library
/audit-completeness P10 m-03-basic-library
```

### 破坏性

| v1.7 习惯 | v2.0+ 强制 |
|-----------|-----------|
| "代码写完 → 下一 Phase" | "自检 11 项全绿 → 才能下一 Phase" |
| "部署文档存在即可" | "必须 curl /actuator/health 输出" |
| "测试报告" | "E2E 通过率 ≥ 95%，禁 48/48 SKIP" |
| "admin/admin123"（盲猜） | "从 seed 找实际凭证，禁猜密码" |

---

→ v2.0（2026-07-10）

### 新增

- 完整的 P0–P10 Phase 系统
- `subagents/` 目录：8 个专业化子 Agent
- `references/` 目录：severity-tiers、windows-compatibility、completeness-gate

### 破坏性

| v1.0 | v2.0 |
|-------|-------|
| 手动 Phase 切换 | 自动 gate 门控 |
| 单 Agent 完成所有 | 多 Agent 并行 + 编排 |
| 中文文档为主 | 中英双语 + 前端路由 |

---

— 工程事实源体系（2026-08-11）

### 新增

- **`scripts/init-fact-sources.sh`** — 一键初始化 5+2 份事实源
- **`scripts/generate-er-index.sh`** — 自动扫 Flyway 4 方言，生成 `_ER图索引.md`
- **`scripts/generate-schema-changelog.sh`** — 自动扫 Flyway 版本，生成 `_Schema变更日志.md`
- **`scripts/generate-permission-matrix.sh`** — **重写为 v3.0 skill-grade**（参数化路径 + 自动生成 + 占位符剔除）
- **`scripts/check-permission-consistency.sh`** — **参数化为 v3.0 skill-grade**（CI 友好检查）
- **`templates/` 目录** — 5 份事实源空模板：
  - `_commons.md` — 工程公约
  - `_权限矩阵.md` — 权限矩阵骨架
  - `_环境与账号.md` — 环境账号
  - `_菜单Seed索引.md` — 菜单 seed
  - `INDEX-章节锚点.md` — skill 自动化契约
- **`commands/init-fact-sources.md`** — 新命令文档
- **`phases/02-详细设计.md` §工程事实源** — P2 阶段必产 5+2 份事实源
- **`SKILL.md`** — 第 7a 项命令：`/init-fact-sources`
- **`rules/devflow-commands.mdc`** — 命令路由表新增 `/init-fact-sources`

### 通用化

- 4 个生成脚本**全部参数化**：`CONTROLLER_GLOB` / `DOC_DIR` / `OUTPUT_FILE` / `SKILL_DIR` 均可环境变量覆盖
- 默认值改为通用约定（如 `backend/*/src/main/java/**/*.java`），不再硬编码本项目结构
- 跨平台兼容：保留 macOS BSD grep + Linux GNU grep 双兼容

### 工程事实源架构

```
<project>/docs/<DOC_DIR>/
├── _commons.md            # 手维护：公共字段/错误码/缓存/幂等/2FA/审计
├── _权限矩阵.md            # 自动+手维护：接口×权限码×角色
├── _环境与账号.md          # 手维护：服务端口/数据库/中间件/2FA/账号
├── _菜单Seed索引.md        # 手维护：前端菜单↔后端 seed
├── INDEX-章节锚点.md       # 手维护：详设 ↔ skill 契约
├── INDEX-表.md            # 自动（手编辑种子）：详设期望逻辑表
├── INDEX-接口.md          # 自动（手编辑种子）：详设期望接口
├── _ER图索引.md           # 自动：表结构×跨服务外键×跨方言
└── _Schema变更日志.md     # 自动：Flyway 版本×服务×方言
```

### Gate 强制

- `scripts/p4_prd_vs_code.sh` item 12 强制 **5 份事实源齐备** + **自动生成产物带 `auto-generated` 标记**

---

— Skill 全面优化（2026-08-11）

### 新增 5 个脚本（补齐缺失）

| 脚本 | 用途 | 修复 |
|------|------|------|
| `scripts/detect-n-plus-one.sh` | 扫 ServiceImpl 中 for/while 循环里的 mapper 单对象调用 | `subagents/performance-auditor.md` 引用但脚本缺失 |
| `scripts/check-code-standards.sh` | Service/Controller 行数 + System.out.println | `commands/qa-check.md` 引用但脚本缺失 |
| `scripts/check-entity-db-consistency.sh` | Java Entity 字段 ↔ DDL 字段一致性 + 4 方言覆盖 | 同上 |
| `scripts/check-frontend-standards.sh` | .vue 结构 + console.log + <script> 长度 | 同上 |
| `scripts/run-all-checks.sh` | 编排器：一键跑全部 5 个 check | 同上 |

### 新增 2 个生成器 + 2 个模板

| 新增 | 用途 |
|------|------|
| `scripts/generate-table-index.sh` | 扫 Flyway DDL → `INDEX-表-auto.md`（与人工 `INDEX-表.md` 并存） |
| `scripts/generate-interface-index.sh` | 扫 Controller 注解 → `INDEX-接口-auto.md`（656 个端点） |
| `templates/INDEX-表.md` | 表索引模板（与 auto 版配合） |
| `templates/INDEX-接口.md` | 接口索引模板 |

`scripts/init-fact-sources.sh` 已扩展为 **7 份模板 + 5 个生成器**。

### 消除 13 处重复

| 旧版 | 新版（权威） |
|------|--------------|
| `phases/规范-详细设计.md` | → `commands/spec.md`（加 DEPRECATED 横幅） |
| `phases/代码审查.md` | → `commands/review.md` + `phases/03b-代码审查.md` |
| `phases/安全.md` | → `commands/security.md` |
| `phases/性能.md` | → `commands/performance.md` |
| `phases/测试.md` | → `commands/test-run.md` + `phases/06-测试执行总览.md` |
| `commands/test-run.md` + `commands/test-gen.md` | → **合并为 `commands/test.md`** |
| `agents/devflow.md` | → 改为 alias，权威在 `commands/devflow.md` |

### 编号冲突修复

- `phases/07-测试执行.md` → 重命名为 `phases/06-测试执行总览.md`（P6 阶段，与 06a-f 并列）

### 死文件清理

- 删除 `phases/01-技术选型-快速.md`（零引用）
- 删除 `.cursor/skills/devflow/.bak/`（历史备份）
- `QUICK-REFERENCE.md` 加废弃横幅（仍 7 阶段视图）

### 版本号统一

- **38 个文件** `version:` frontmatter 从 1.0.0 / 2.4.0 / 2.5.0 统一为 **3.0.0**
- `concepts/SKILL.md` / `references/CHANGELOG.md` 保持 1.0.0（独立 invariant）

### Frontmatter bug 修复

- `commands/review.md` / `commands/performance.md` / `commands/retro.md`：typo `disable_model_invocation` → `disable-model-invocation`
- `commands/retro.md`：删除重复的 `disable-model-invocation: true`（保留 false）

### SKILL.md 增强

- 新增 **§Hooks** — 把 3 个孤立 hook 文档化
- 新增 **concepts §11 Engineering Fact Sources** — 工程事实源铁律
- 新增 **concepts §12 Skill Universalization** — skill 通用化铁律
- `devflow-commands.mdc` 重写为 v3.0 完整版（12 个命令 + v3.0 变更要点）

### 跨平台加固

- `scripts/init-fact-sources.sh`：去掉 `set -u` + 改用 while-read 数组展开（bash 5.0+ 在 `${arr[@]}` 上有兼容 bug）
- 所有脚本统一 macOS BSD grep / Linux GNU grep 双兼容

### 验证

| 项目 | 状态 |
|------|------|
| `scripts/*.sh` 总数 | 15 个 |
| `templates/*.md` 总数 | 7 份 |
| `commands/*.md` 总数 | 17 个（含 5 个 DEPRECATED） |
| `phases/*.md` 总数 | 22 个（含 5 个 DEPRECATED） |
| `version: "3.0.0"` 文件数 | 38 个 |
| `p4_prd_vs_code.sh` | 16 项 gate，本项目 15 PASS + 1 P1（项目侧 TODO 待清理） |

---

## 文件版本同步规则

每个 `.md` 文件的 `version:` 必须与主 `SKILL.md` 同步更新：

```
SKILL.md version: "2.4.0"
→ commands/*.md version: "2.4.0"   ← 同步更新
→ subagents/*.md version: "2.4.0"  ← 同步更新
→ concepts/SKILL.md version: "1.0.0" ← concepts 独立版本（true north）
→ references/CHANGELOG.md version: "1.0.0" ← changelog 独立版本
→ agents/devflow.md version: "1.0.0" ← agents 独立版本
```

破坏性变更（如删除命令、修改 gate 条件）必须：
1. 在本文加对应 section
2. 在 `SKILL.md` 的 `metadata.v2.N-changelog` 字段标注
3. 发 PR 给 teammate review

---

— 同类 Skill 借鉴（2026-08-12）

> **调研方法**：使用 agent-reach 调研 GitHub 上 7 个相关项目（spec_driven_develop 964⭐ / metaswarm 383⭐ / molyanov-ai-dev 245⭐ / genkovich/sdd 95⭐ / donnyclaude 8⭐ / Marlo-AI 2⭐ 等）
> **调研报告**：`docs/调研/agent-reach-同类-skill-2026-08-12.md`

### 新增 5 个脚本

| 脚本 | 用途 | 借鉴来源 |
|------|------|----------|
| `generate-master-index.sh` | 扫全项目生成 MASTER.md（项目单一索引） | spec_driven_develop 的 MASTER.md |
| `verification-template.sh` | 每个 Phase 必填 VERIFICATION-{P}.md 含 passed: true | DonnyClaude 的 VERIFICATION.md |
| `sync-to-codex.sh` | 把 `.cursor/skills/` 镜像到 `.codex/skills/` | molyanov-ai-dev 的 sync-to-codex.py |
| `detect-n-plus-one.sh` | N+1 自动检测 |
| `run-all-checks.sh` | 一键跑全部 5 个 check | 同上 |

### 新增 3 个 Subagent（Adversarial Review 3 评审）

| Subagent | 职责 | 借鉴 |
|----------|------|------|
| `feasibility-reviewer.md` | 评审 1/3：实现路径是否合理 | metaswarm Feasibility Reviewer |
| `completeness-reviewer.md` | 评审 2/3：详设/4 方言/菜单 seed 全量覆盖 | metaswarm Completeness Reviewer |
| `scope-reviewer.md` | 评审 3/3：PRD 对齐 + 架构边界 + 文档同步 | metaswarm Scope Reviewer |

`code-reviewer.md` 升级为 **3 评审并行调度器**（永远 fresh Task 实例）。

### 新增 1 条概念铁律（concepts §13 L-GEVITY）

借鉴 Marlo-AI 的 L-GEVITY 框架，4 维架构纪律：
- **Minimalism**（极简）
- **Modularity**（模块化）
- **Resilience**（韧性）
- **CI/CD Reliability**（持续集成可靠性）

每个 PR 必填 `docs/review/l-gevity-scorecard.md`，总分 ≥ 16/20 才 PASS。

### 跨平台入口（CLAUDE.md / AGENTS.md）

`init-fact-sources.sh` 现在自动生成：
- `CLAUDE.md`（Claude Code 入口）
- `AGENTS.md`（Codex / Trae 入口）

如已存在则跳过（避免覆盖 OpenSpec 等其它 AGENTS.md）。

### 关键决策

| 借鉴项 | 决策 |
|--------|------|
| S.U.P.E.R 健康评估（spec_driven_develop） | 📋 P1 排期 |
| Demo gate（Marlo-AI） | 📋 P1 排期 |
| Socratic 风格 + dial（genkovich/sdd） | 📋 P1 排期 |
| 结构 auto-discovery（genkovich/sdd） | ❌ 暂不做（复杂度高） |
| evals/ 框架（genkovich/sdd） | ❌ 暂不做 |
| npx CLI（DonnyClaude） | ❌ 暂不做 |

### 验证

| 项目 | 状态 |
|------|------|
| `scripts/*.sh` 总数 | 19 个 |
| `subagents/*.md` 总数 | 13 个 |
| `concepts/SKILL.md` 铁律 | 13 条 |
| `MASTER.md` 自动生成 | ✅ 277 文档 / 60 phases / 76 scripts |
| `VERIFICATION.md` 强制门控 | ✅ `verification-template.sh` 校验 |
| `CLAUDE.md` / `AGENTS.md` 入口 | ✅ 自动生成 |
| `sync-to-codex.sh` 测试 | ✅ 镜像 `.codex/skills/` 成功 |

---

— P1 三项借鉴（2026-08-12）

> **调研延续**：在 v3.1 调研基础上，从 P1 排期项中选 3 项落地
> **借鉴来源**：spec_driven_develop (S.U.P.E.R) / Marlo-AI (Demo gate) / genkovich/sdd (Socratic dial)

### P1-A：S.U.P.E.R 5 维架构健康评估

**新增**：
- `scripts/super-scorecard.sh` — 自动扫 Service/Controller 文件 + 跨服务接口 + 硬编码 + Fallback，5 维评分
- `concepts/SKILL.md` §14 S.U.P.E.R Iron Rule — 5 维原则（Single Purpose / Unidirectional / Ports / Environment-Agnostic / Replaceable）

**评分**：
- 每维 1-5 分，总分 ≥ 20/25 PASS
- ≥ 15/25 WARN；< 15 FAIL
- 自动输出 `docs/super-report.md`（含修复建议）

**验证**（本项目实测）：
```
S — Single Purpose       : 4.4 / 5
U — Unidirectional Flow  : 4 / 5
P — Ports over Impl      : 3 / 5
E — Environment-Agnostic : 1 / 5   ← 7 处硬编码
R — Replaceable Parts    : 4 / 5
TOTAL                    : 16.4 / 25 ⚠️ WARN
```

### P1-B：Demo Gate（P2b 阶段）

**新增**：
- `phases/02b-原型Demo.md` — 完整 P2b 阶段文档
- 借鉴 Marlo-AI "先 mockup 再写代码" 思想

**核心流程**：
```
P2 详细设计 → P2b Demo Gate → P3 全栈编码
                  ↓
            3-5 个 KUF walkthrough
            Demo sign-off 签字
            VERIFICATION-P2b.md passed
```

**跳过条件**：
- 改动 < 1 人日 / 纯 bug / 纯性能 / 纯重构
- 不涉及新前端页面、不涉及新 API
- **必须 Tech Lead 签字**

**Demo sign-off 必填**：
- 3-5 个 KUF 走查通过
- UI/UX 符合设计稿
- 异常路径（空状态 / 错误）已考虑
- PO + Tech Lead + UX 三方签字

### P1-C：Socratic 风格 + 深度 Dial

**新增**（commands/spec.md v3.2）：
- `--depth easy|medium|hard` 三档深度
- 每个 Socratic 步骤用三档模板（自动决定 vs 询问）

**深度控制矩阵**：

| 深度 | 适用场景 | 自动决定 | 询问用户 | 决策时间 |
|------|---------|---------|---------|---------|
| easy | 内部小工具 / 时间紧 | 80% | 20% | 30 min |
| medium | 默认 / 中型功能 | 50% | 50% | 2-4 hours |
| hard | 关键架构 / 跨团队 / 高风险 | 20% | 80% | 1-2 days |

**Socratic 提问模板**（P0/P1/P2 各 3 套）：
- P0：目标用户 / 业务场景 / 验收标准
- P1：选型动机 / 风险 / 团队能力
- P2：边界 / 数据一致性 / 失败模式

**借鉴**：genkovich/sdd 的 Socratic 风格——"不直接给方案，提问引导思考"

### 验证

| 项目 | v3.1 |  | 变化 |
|------|------|---------|------|
| `scripts/*.sh` 总数 | 19 | **20** | +1 (super-scorecard) |
| `phases/*.md` 总数 | 25 | **26** | +1 (02b-原型Demo) |
| `concepts/SKILL.md` 铁律 | 13 | **14** | +1 S.U.P.E.R |
| `commands/spec.md` 版本 | 3.0.0 | **3.2.0** | +Socratic dial |
| 本项目 S.U.P.E.R 评分 | — | **16.4/25** | 全维度可测 |

---

## v3.9.4 实战教训增补（M-01 基础能力模块实施 · 2026-08-21）

> 来源：M-01 全流程（P0b→P6）实跑。以下为 gate 失败/平台适配的即时反哺（项目 .cursor 副本已修复）。

### A. macOS（BSD 工具链）兼容性修复

| # | 脚本 | 问题 | 修复 |
|---|------|------|------|
| 1 | p2a_design_review_gate.sh | `grep -E` 模式中 `\|` 在 BSD grep 下是字面量（GNU 才作交替符），4 角色匹配必失败 | ERE 交替改裸 `|` |
| 2 | p2a/p3b/p3_security_perf 等 | `grep -c ... || echo 0`：grep -c 无匹配时先打印 0 再 exit 1，变量变 "0\n0" 导致整型比较必失败 | `|| echo 0` → `|| true` |
| 3 | p4_prd_vs_code.sh §4 | BSD sed 不支持 `\U` 大写转换 | snake→camel 改 awk 实现 |
| 4 | p6_credential_gate.sh | `set -euo pipefail` 下 find 不存在的目录（docs/test-cases、frontend/e2e）静默 exit 1 | 项目侧 mkdir 兜底（建议上游加 `-d` 判空） |

### B. p4_prd_vs_code.sh 项目适配（保意图、补短板）

| # | 点 | 原行为 | 适配 |
|---|----|--------|------|
| 1 | §2 接口解析 | 仅识别方法级 `value=/path=` 且不含类级前缀 | 组合类级 @RequestMapping 前缀 + 支持 `@GetMapping("/x")` 简写 |
| 2 | §4 字段解析 | 全文档表格首列误作字段（索引表/契约表误伤）；实体仅认 @Table/@Entity | 仅七列字典表内字段（awk 状态机）；实体认 @TableName 并纳入 BaseEntity；多服务模块按全模块实体并集比对 |
| 3 | §6 测试类 | `grep -v 'Impl$'` 永不命中（路径以 .java 结尾）；Mapper/Application 也被要求有 Test | 仅 `*Service.java` 接口要求同名测试（Mapper 经 Service 测试 + JaCoCo 行覆盖兜底） |

### C. 工程实施教训

| # | 教训 | 处置 |
|---|------|------|
| 1 | common 自动装配 @EnableFeignClients + 服务侧重复扫描 → BeanDefinitionOverrideException | 服务侧仅扫描本服务 client 包 |
| 2 | MyBatis-Plus 3.5.15 分页插件独立成 mybatis-plus-jsqlparser | 显式加该依赖 |
| 3 | MP updateById 忽略 null → 锁定到期自动解锁不落库 | LambdaUpdateWrapper.set() 显式置空 |
| 4 | 关联表逻辑删除残留与 uk 唯一索引冲突（解除后不可重授权） | 授权/配置类关联表物理删除（Mapper @Delete） |
| 5 | 审计表 PG 分区导致四方言表集合不一致（p4b §9 拦截） | 统一 audit_log + audit_log_archive 冷热分离方案 |
| 6 | 共享种子数据的契约测试有顺序依赖 | 测试自建独立数据 |
| 7 | H2 为 test scope，java -jar 直跑缺驱动；本机 8085 被外部应用占用致压测打到错误目标 | 显式 classpath 启动 + 换端口 + 健康响应体校验归属 |

### D. 验证口径约定（本项目）

- S6 首轮准确率：仅自动化断言直接覆盖的验收点计 PASS；纯 UI 呈现项计 SKIP（转 06e E2E），不删除验收点
- p3 菜单 seed 检查硬编码 org-service 路径：权威 seed 在 perm-service（4 表归属正确），org-service 方言根目录放 gate 约定镜像（Flyway 不执行）
| 2026-08-21T15:25:33Z | P4b | feature=m-01 | gate exit=1: user_id 字段无实体映射(需独立 SysUserAuthority 实体) + JpaUserDetailsServiceTest 缺失 + evidence TSV A05 行 tab 分隔错误 |


## 2026-08-21 实战教训（m-01 复盘写回）
- 详设格式须先对齐 gate 正则：追溯矩阵验收点 ID 不能用反引号包裹（`M-01-F01-A01` 导致 COMPLETE 行匹配失败、覆盖率 0%）；R 编号必须行首（列表式 `- **R1.**` 不识别）；"占位"一词在占位词黑名单（"不得返回成功占位响应"误伤）→ 写详设前先读 gate 脚本匹配逻辑，模板示例照抄。
- p2a 评审 gate 拒绝词统计未排除阴性声明：报告引用 "PASS=12 FAIL=0" 被计为 2 次 rejection → gate 应像 p3b 一样排除 FAIL=0/0 项失败等否定语境（GATE-FALSE-POS）。
- p3_completion_gate 纯后端场景 set -e 中断：find 不存在的 frontend/src/views/<feature> 路径退出码 1，经命令替换+pipefail 触发 set -e，所有已执行项 PASS 仍 exit 1 且无 P3 RESULT 输出 → find 加 "|| true" 或预建前端预留目录（GATE-FALSE-POS）。
- p4_prd_vs_code 接口解析用 \s（BSD sed 不支持）：macOS 上 parse_design_apis 恒为空（WARN skip），应改用 [[:space:]]（GATE-FALSE-NEG，POSIX 铁律 §7 违例点）。
- 七列数据字典的表必须实体化：@ElementCollection 隐式集合表的 user_id 字段在 P4b 字段逐项对比中"无实现"→ 详设字段字典 = @Entity 清单一一对应（DOMAIN 规则）。
- TSV 证据列错位：手写 tab 误为空格导致 status 列读取失败 → 结构化证据一律脚本生成并校验列数。
| 2026-08-21T18:29:52Z | P3 | feature=m-01 | p3_completion_gate.sh 在 set -euo pipefail 下 find 不存在目录导致静默退出（NEW_PAGES 赋值行退出码 1 中断），已加 || true 修复并同步三份副本 |
