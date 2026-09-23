---
name: devflow-concepts-core
description: devflow 不可违背的铁律（true north）；规划、评审与全部 phase/command/subagent 的最高约束。
metadata:
  version: "3.30.8"
---

# Concepts — True North（不可违背的铁律）

> 源自 M-03 / M-05 实战教训。每次 Phase gate 失败、每个 P0 阻断项都可以追溯到本文件的某一条。
> 所有 phase skill / command skill / subagent 必须与本文对齐。冲突时以本文为准。

---

## 1. Phase Gate System（完成度门控）

**铁律**：每个 Phase 必须通过对应的验收 gate 才能进入下一个 Phase。

```
PRD → P0 需求澄清 → P0b PRD评审 → P1 技术选型 → P2 详细设计 → P2a 设计评审 → P2b 原型Demo
    → P3 编码 → P3b 代码审查 → P3c/P3d 安全与性能 → P4 PRD验证 → P4b PRD-vs-Code
    → P5 测试用例 → P6 测试执行（含 P6-final 部署前终验）→ P7 部署 → P8 监控 → P9 文档 → P10 复盘
（每阶段通过对应 Gate 后才能推进；各阶段 Gate 脚本对照以 commands/devflow.md Gate 参数矩阵为准）
```

**禁止**：
- 仅以"文档产出"判定为完成
- 仅以"代码骨架 / TODO"判定为完成
- 开发 Agent 自评（必须由独立角色 audit）

**必须**：
- 运行机器可执行的自检命令
- 凭据可追溯性（从代码 seed 找，不用猜）
- 产出文件实际存在

---

## 2. Vertical Slices（垂直切片优先）

**铁律**：按功能垂直切片执行，不要按层级（后端→前端）水平执行。

```
切片1 = 一组可独立验证的行为闭环（数据/服务/客户端/单测/可达性按 Runtime Profile 能力位组合，无客户端/持久化时可为纯逻辑切片）
切片2 = 下一组功能...
```

**禁止**：先写完全部后端 → 再写完全部前端（认知负荷高、不可独立交付）
**必须**：每个切片独立可运行、可测试、可部署

---

## 3. Agent Role Separation（角色隔离）

| 角色 | 做什么 | 不能做什么 |
|------|--------|-----------|
| `backend-dev` | 写 Entity / Service / Controller / 单测 | 自评代码 |
| `frontend-dev` | 写 PC Web、小程序或 APP 客户端与 API 调用 | 自评 |
| `sql-dev` | 写数据库迁移 DDL + 菜单 seed | 自评 |
| `completeness-auditor` | 运行 P3-P10 gate 自检 | 写代码 |
| `code-reviewer` | 找 P0 缺陷 | 自评 |
| `test-engineer` | 写测试用例 / 执行测试 | 自评 |

---

## 4. 技术栈规则按 Runtime Profile 生效

核心流程不预设 Flyway、Spring、Mapper 或具体数据库方言。项目在 P1 冻结的
`Runtime Profile` 声明了 `MIGRATION_ADAPTER`、`AUTHORIZATION_ADAPTER` 和客户端能力后，
必须遵守对应 Profile 的迁移、权限、菜单 seed 与可达性契约；内置 Java 规则见
`references/profiles/java-spring-flyway.md`。未声明的能力不得由本文件推断或套用。

---

## 5. 客户端可达性与持久化变更

**铁律**：每个冻结的客户端范围都必须有对应的可达性证据。PC Web、小程序和 APP 的
菜单/导航、路由和旅程分别按 Runtime Profile 与 `devflow-client.json` 验证；持久化变更
按 Profile 声明的 migration adapter 执行，禁止绕过迁移工具直接改库。

---

## 6. Credential Traceability（凭证可追溯性）

**铁律**：测试报告中的所有凭证必须从代码 seed 中找到实际值，禁止猜密码。

**禁止**：
- 测试报告写"尝试 admin/admin123 及多个常见密码"
- E2E 脚本硬编码 `admin123` / `admin888` / `12345678`

**必须**：
- 测试用例"前置条件"段含凭证三要素表：项 / 值 / 代码来源（行号定位）
- E2E 脚本用 `ADMIN_PASSWORD` 常量（来自 `frontend/tests/helpers.ts` 或后端 seed）
- 凭证阻塞时从 `init/BuiltinDataInitializer` / `V*__seed_sys_user.sql` / `helpers.ts` 找实际值

---

## 7. Cross-Platform POSIX Standard（跨平台 POSIX 标准）

**铁律**：所有 shell 自检命令必须在 macOS（BSD grep）+ Linux（GNU grep）+ Windows Git Bash 3.2 下通用。
正反例清单与兼容性细则见 `references/concepts-detail.md` §POSIX。

---

## 8. Red Flags（红旗，必须停止）

| 红旗 | 立即停止并汇报 |
|------|--------------|
| 绕过 Profile 声明的迁移 adapter 直接改 DB | 后端依赖不存在的表 |
| 前端页面写完但无菜单 seed | 用户看不到功能 |
| 测试报告含"盲猜密码" | 审计错误，P0 阻断 |
| Profile 要求的 admin 权限授予缺失 | admin 看不到菜单 |
| Profile 要求的序列/菜单 seed 缺失 | 部署或客户端不可达 |
| Profile 要求的 Controller 授权缺失 | 权限漏洞 |
| Profile 要求的持久化映射不一致 | 运行时数据访问错误 |
| 输入含脚手架却未做重合度审计直接开工 | 裁剪/复用边界不清，返工重做 |
| 脚手架重合功能新旧双实现并存（两套菜单/接口/写路径） | 数据与权限口径分裂，必须裁剪旧实现 |
| 输入的原型/设计规则/UI 规范被脚手架默认设计覆盖 | 物料硬约束被绕过，UI 返工 |

---

## 9. Version Discipline（版本纪律）

> **v3.14.2 起强制**：任何修复/升级合入后必须递增版本号 z 位（x.y.z → x.y.z+1）。
> 版本单一事实源 = SKILL.md frontmatter；gate 收据戳、audit-receipts、verify_evidence_receipt 均动态派生，
> 因此漏改任何一处硬编码都会在 check-skill-version / release-audit 立即暴露。

- 每个文件 `version:` frontmatter 与 SKILL.md 主版本同步
- 破坏性变更（删除命令 / 改变 gate 条件）必须更新 changelog
- `references/CHANGELOG.md` 记录从 v1 → v2 → v2.3 → v2.4 的迁移路径

---

## 10. Skill Loading Order（加载顺序）

```
规划 / 审查时：
  1. 先读 concepts/core.md（本文件）— true north
  2. 再读 commands/<phase>.md — 本阶段流程
  3. 再读 subagents/<role>.md — 本角色职责
  4. 按需读 references/*.md — 详细约定

执行 / 编码时：
  1. SKILL.md（主入口）
  2. commands/build.md（编码流程 + 自检）
  3. subagents/<role>.md（子 Agent 职责）
  4. scripts/*.sh（自检脚本，按需调用）
```

---

## 11. Engineering Fact Sources（工程事实源体系，铁律）

**铁律**：所有跨模块约定必须沉淀到 `docs/详细设计/_*.md` / `INDEX-*.md`，不允许在代码注释、wiki、对话中"口口相传"。

### 11.1 必须维护的事实源（7 份手维护 + 5 份 auto）

> 完整清单（文件/类型/维护方/触发时机表）、初始化命令、auto 索引差异审查、
> 跨项目复用原则已移至 `references/concepts-detail.md` §Fact-Sources。
> 核心不变量：跨模块约定只能沉淀在 `docs/详细设计/_*.md` / `INDEX-*.md`；
> 跳过事实源直接编码被 `s1_fact_sources_gate.sh` 阻断。

### 11.5 跨项目初始化

> 正文已抽离至 references/concepts-detail.md §跨项目初始化。
> 核心原则：新项目从模板仓库克隆而非复制粘贴；事实源随模板走。
## 12. Skill Universalization（skill 通用化，铁律）

> 正文已抽离至 references/concepts-detail.md §Skill-Universalization。
> 核心不变量：三层解耦（领域逻辑/平台胶水/工具编排）；参数化路径；平台无关。

## 13. 架构评分卡(指针)

> **v3.9 抽离**:本节原内容(§13 L-GEVITY + §14 S.U.P.E.R)已抽到独立文件
> [`architecture-scorecard.md`](./architecture-scorecard.md)。
> 该文件是权威定义,**任何 PR / Phase 切换的架构评分都按那份来。**

**为什么抽离**:`concepts/core.md` 是铁律入口,500+ 行太长,L-GEVITY/S.U.P.E.R 是参考评分表(非铁律)。
放在独立文件便于:
1. 单独被 `audit-pitfalls.sh` / `super-scorecard.sh` 直接引用
2. 单独维护(随 Marlo-AI / spec_driven_develop 上游更新)
3. 单独 review(架构评审组 PR 只动这一份)

**快速对照**:

| 框架 | 维度数 | 触发时机 | 通过阈值 | 脚本 |
|------|--------|----------|----------|------|
| L-GEVITY | 4 | Phase 切换 | ≥ 16/20 | (手填) |
| S.U.P.E.R | 5 | 每次 PR | ≥ 20/25 | `scripts/super-scorecard.sh` |

---

## 14. (已抽离)

> **v3.9 起 §14 S.U.P.E.R 已并入 [`architecture-scorecard.md`](./architecture-scorecard.md) §14。**
> 保留本占位节号以避免后续 PR 文档章节号偏移。

---

## 15. Architecture Pitfalls（架构陷阱自动检查 · 铁律）

> **问题根因**：v3.4 之前将"踩过的坑"散落在多个文档/Postmortem/复盘里，缺少统一事实源，导致同类问题在不同项目反复出现。
>
> **铁律**：本 skill 用户**必须在 P3b（代码审查 gate）推进前完成架构陷阱自检**——
> check-arch-pitfalls 以 `--receipt` 组合内嵌于 p3b gate（§6，产出 ARCH-PITFALLS
> 收据），是 P3b 的强制组成；缺收据则状态机拒绝推进 P3b（v3.16.3 起）。
> （历史口径"任意 Phase 切换前必跑"自 v3.16.11 起收敛为 P3b 门禁——
> 收据化与消费点唯一化后，"每阶段"承诺已由真实执行路径承载）

### 15.1 适用范围

- Java + Spring Boot 后端及 PC Web、小程序、APP 客户端组合项目；其他后端栈必须提供等价的项目级检查器
- P3b 推进前（经 p3b gate §6 内嵌执行并产出 ARCH-PITFALLS 收据；任意时点也可手动跑 `--all` 自检）
- Postmortem 后必须登记新坑

### 15.2 必读文档

| 文档 | 必读理由 |
|------|---------|
| `concepts/architecture-pitfalls.md` | 30+ 通用 Anti-Pattern + 11 类陷阱分类 |
| `concepts/中文文风规范.md` | 全部产出文档的中文写作契约（说人话、表达准确），P2/P2a/P9 评审按此核对 |
| `concepts/Java开发手册_黄山版.md` | Java 代码生成与评审的强制基准（P3 编码前对照章节、P3b 逐条核对，【强制】条款无豁免） |
| `docs/架构升级改造计划.md`（项目级） | 54 项 D-XX 偏差 + 21 项 G 守卫 |

### 15.3 必跑命令

```bash
# P3b 推进前必跑（critical > 0 阻塞；p3b gate 以 --receipt 组合自动执行）
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --all

# 或分类跑
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category config       # 配置分散
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category api          # API 契约
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category security     # 安全/密钥
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category code         # 代码规范
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category perf         # 性能
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category obs          # 可观测性
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category deploy       # 部署
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category test         # 测试
```

### 15.4 与其他铁律的协同

- 与铁律 1（Phase Gate）：Pitfalls 在 P3b Gate 内强制执行；P3/P7/P8 仅消费已绑定收据，不重复声称独立切换 Gate
- 与铁律 3（Role Separation）：Pitfalls 可由 `completeness-auditor` 或主Agent 跑，但失败修复由对应 dev 完成
- 与 §11（Engineering Fact Sources）：Pitfalls 反哺新坑进 `concepts/architecture-pitfalls.md` + `concepts/core.md`

### 15.5 Postmortem 反馈循环

```
P11 Postmortem → 新坑登记到 architecture-pitfalls.md
                → checks/check-arch-pitfalls.sh 新增检查
                → CHANGELOG.md 新增条目
                → 跨项目同步
```

## 16. Release Authorization（外部副作用授权，铁律）

**铁律**：任何外部副作用——staging/production 部署、数据库迁移、push/merge、对外通知——在执行前必须有显式人工授权收据 `.devflow/<feature>/authorizations/release.json`（字段见 `commands/devflow.md` §Release Authorization）。

- 无收据：不得执行外部副作用命令，最高只能声明 `READY_TO_RELEASE`，不得声明 `RELEASED`。
- 收据只能来自用户当前会话的明确指令；模型不得推断或代签。
- 不可逆操作（生产回填、破坏性 migration）一律要求人工批准。

## 17. Runtime Profile（技术栈解耦，铁律）

**铁律**：P3 前必须按 `references/runtime-profile.md` 解析并冻结 Runtime Profile 能力位（BUILD/TEST/COVERAGE/AUTHORIZATION/MIGRATION/CLIENT/SECURITY）。

- 核心流程（SKILL/commands/phases）不得假设 Maven、Spring、Flyway、JaCoCo、Vue 或具体数据库方言；这些断言只属于对应 Profile。
- `java-spring-flyway` 是内置参考 Profile；其他技术栈在 P1 冻结等价 adapter。
- 能力位缺失：`STATUS=BLOCKED` + `MISSING_CAPABILITY=<capability>`，不得猜测顶替。

---

## 18. Scaffold Overlap Audit（脚手架重合审计与裁剪，铁律）

**铁律**：输入包含脚手架/存量代码（`--scaffold` 或 PRD 指向存量仓库）时，P1 必须先做**功能重合度审计**——
逐功能域对照「本次交付的新功能」与「脚手架已有能力」，产出**裁剪/复用清单**后，才允许进入选型评分与详设。

判定与处置（二分法，不允许第三种模糊态）：

| 判定 | 动作 | 说明 |
|------|------|------|
| **重合** | **裁剪脚手架对应实现**，由本次设计重新实现 | 裁剪范围含：控制器/服务/实体/Mapper、菜单 seed、前端页面与路由、相关迁移脚本引用；重合域宜由**独立新模块**承载（如 `module-<feature>`），不得在脚手架原实现上"顺带扩展"冒充新设计 |
| **不重合** | **复用脚手架既有能力**（REUSE） | 成熟组件复用（原则 10 同源），不得重复造轮子；进入 P2 baseline `REUSE` 条目 |

硬性要求：

- 「裁剪」判定必须给出**裁剪动作清单**（删除/下线/迁移清理/页面移除）与**新实现承载位置**（模块/包）；
- 清单必须被 P2 详设 baseline（`DELETE`/`MODIFY`/`ADD`）承接，并与菜单 seed、路由、权限矩阵联动核验；
- **禁止双实现并存**：同一功能域不允许新旧两套菜单、接口或写路径同时存活；
- 裁剪动作属外部副作用时按原则 14 走授权收据；
- 审计输出写入 P1 设计决策记录「脚手架重合度审计」章节（模板节锚点为机器对账位）。

---

## 19. Input-Material Precedence（输入物料优先，铁律）

**铁律**：当用户/PRD 提供**原型图、设计规则、UI 规范、交互稿**等输入物料时，这些物料是设计硬约束（原则 12 同源），
P2 详设与 P3 实现必须**遵循物料**，不得照搬脚手架既有设计的样式、交互或信息架构覆盖输入物料。

优先级（冲突时高优先胜出，脚手架不参与视觉/交互口径竞争）：

```
用户/PRD 输入物料（原型/UI 规范/设计规则）  >  脚手架既有设计  >  团队默认习惯
```

- 脚手架 UI 与组件只作为**实现载体**（技术能力复用），不作为视觉与交互口径来源；
- 物料为图片/链接时，P2 须落为可执行规格（布局/组件选型/交互状态/文案口径）并锚定原物料路径；
- 物料与 PRD 冲突 → `STATUS=BLOCKED`，回用户裁决；不得自行降级或忽略；
- 未提供物料时才允许以脚手架设计为默认口径，并显式声明。

## 20. 机器契约四纪律（一次通过率与速度，2026-09-20 ch07-org-user 实战沉淀）

> 来源：P0→P2a 全链实测——80 分钟中约 40% 消耗在「写了→校验→改格式」循环。
> 四条纪律可把该开销压到接近零，且全部可被既有 Gate 机器执行。

| # | 纪律 | 根则 | 落点 |
|---|------|------|------|
| 1 | **契约先行**：写产物前先读对应 `df_validate.py` 跨字段检查与阶段 Gate 脚本的 grep/awk 契约（枚举值、字段类型、行首关键词、表头关键词、锚点正则） | 契约是可 grep 的，Gate 脚本就是规格书 | 各 phase 文档「结构化产物层」小节执行前 |
| 2 | **收据/证据时序后置**：凡绑哈希/签名的动作（begin/complete、EVIDENCE_TREE、evidence 快照），排在一切会改这些文件的动作之后；上游收据证据树内文件在收据后只读 | 证据不可变性排序 | P2a 双阶段收据、P4 证据快照、P6-final 重跑通知 |
| 3 | **生成器脚本化前置**：重复结构（验收映射、表字段、BOP 骨架、迁移/实体/测试骨架）由正本（design.json/验收点.json）脚本派生，禁止手写第二遍 | 单一正本 + 派生 | P2 design 层、P3 迁移/实体、P5 测试生成器 |
| 4 | **校验器一次跑全**：df_validate + 阶段 Gate + 下游 Gate 预检串成一条链一次执行，把格式缺陷收敛到一个修复批次 | 反馈批次最大化 | `df_pipeline.py --gate` 链式契约（REMAINDER 单命令） |

**跨阶段前置冻结链**（纪律 1/2 的特殊形态，最易漏）：
P0 过 → `constraints-freeze`；P2 过 → `client-freeze`（P7 反查）；P4 过 → 证据快照（P6 会改活文件）；任意 Gate 过 → 收据证据树内文件只读。

---

---

*本文是所有 devflow skills 的 invariant。任何 phase skill / command / subagent 不得以"方便"为由违背上述任何一条。*

---
