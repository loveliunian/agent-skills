# devflow changelog archive — v3.9.0 to v3.9.5

> Archived from the active migration guide in v3.13.2.

## v3.9.5 (2026-08-21) — 四项目对比复盘驱动的执行引擎修复（P0-P10 单轨 + 反哺硬闭环）

> **背景**：对 code0817/0819/0820/0821 四个同 PRD、同提示词项目做产出对比审计（详见各项目 docs/ 与对比报告），暴露 4 类系统性漏洞：
> 1. **P3 断崖**：4 个项目中 3 个在 P3 编码后集体跳过 P3b-P9（审查/验证/测试/部署/监控/文档）。根因：`commands/devflow.md` 头部声明"废弃 S0-S8、采用 P0-P11 单轨"，但唯一可执行引擎 `main()` 仍迭代 `S0...S8`——P2a/P2b/P3b/P3cd/P4b/P6 凭证 gate 全是不被任何入口调用的孤儿脚本
> 2. **P2b 原型 Demo 执行率 0%**：`p2b_demo_gate.sh` 全 skill 零引用（grep 确认）
> 3. **反哺闭环率 1/4**：仅 code0819 把教训写回 CHANGELOG；code0821 复盘列 5 条教训标注"待写入"但从未落盘；`after-gate-fail-hook.sh` L5 自述"手动调用"，从未被自动触发
> 4. **Gate 收据取证断链**：4 个项目 `.devflow/` 目录全部缺失，VERIFICATION 引用的 receipt.txt 无法复核
>
> 另有 2 类次级问题：code0817 型"PRD→直接编码"无前置拦截；`check_skip_authorization()` 用 `read -p` 交互输入，agent 会话中挂死。

### 修复 1：devflow.md 执行引擎改 P0→P10 单轨（根治 P3 断崖）
- `main()` 循环由 `for stage in S0...S8` 改为 `for phase in P0 P0b P1 P2 P2a P2b P3 P3b P3cd P4 P4b P5 P6 P7 P8 P9 P10`
- 新增 `get_gate_script()` 完整映射：P2a→p2a_design_review_gate.sh、P2b→p2b_demo_gate.sh、P3b→p3b_code_review_gate.sh、P3cd→p3_security_perf_gate.sh、P4b→p4_prd_vs_code.sh、P6→s6+p6_credential_gate.sh、P10→s8b_feedback_gate.sh
- Orchestration 章节两张表（S 轨 + P 轨并存）合并为《P0-P10 单轨执行顺序（唯一执行轨）》17 项
- Gate 失败分支接通 `after-gate-fail-hook.sh`（即时反哺，此前从未被调用）
- `check_skip_authorization()` 去交互化：`read -p` → skip-log 文件 + `DEVFLOW_SKIP_AUTH` 环境变量 + `--skip=` 参数三通道
- Gate 失败自动 `checkpoint-state.sh save` 保存断点

### 修复 2：/retro 反哺硬闭环（根治"知道但没做"）
- `commands/retro.md` 新增执行步骤 4《反哺写回 CHANGELOG（v3.9.5 强制 · 硬闭环）》：教训当场追加 CHANGELOG + grep 当日日期 ≥ 1 作为 Gate 收尾
- Gate 表新增 2 行：CHANGELOG 当日写回 ≥ 1；`s8b_feedback_gate.sh` 退出码 = 0
- 复盘模板新增《反哺写回记录》段（含 grep 证据）
- SKILL.md 新增第 12 条核心原则《反哺硬闭环》

### 修复 3：spec.md Phase File Map 补 P2a/P2b
- `p2b_demo_gate.sh` 此前零引用（4 项目原型 Demo 执行率 0%），现进入 Phase File Map
- `/spec --design-only` 也必须过 P2a；P2b 在改动 < 1 人日或纯后端场景可用户显式授权跳过（写 skip-log）

### 修复 4：Gate 收据双写 docs/（根治取证断链）
- s0/s1/s2/s5/p2a/p3b 六个 gate 脚本收据镜像到 `docs/<feature>/gates/<Phase>/`（进版本管理；`.devflow/` 在 4 个实测项目中全部缺失）
- `check-skill-usage.sh` §2 收据搜索范围扩展到 `docs/**/gates/`

### 修复 5：编码触发前置拦截（根治 code0817 型失败）
- SKILL.md + natural-language-triggers.md：`开始实施/编码/M-01` 触发从"直接 build-watchdog check"改为"先验证 acceptance-criteria + design 存在且 s0/s2 gate PASS，缺失即 BLOCKED"
- 消除 §二（进入 /build）与 §三（直接跑 watchdog）的映射矛盾
- 反例新增 2 条：PRD→直接编码、编码完成直接宣布完成

### 破坏性变更
- `--skip=S*` 参数改为 `--skip=P*`（S0→P0 等映射见 devflow.md 命名体系说明）
- `devflow-state.sh complete-stage <feature> S*` 改为 `complete <feature> P*`
- SKILL.md Phase 验收门控表由 S0-S8 改为 P0-P10 单轨 17 项

---

## v3.9.5 实战教训（四项目对比审计 · 2026-08-21）

| 时间 | Stage | feature | 失败原因 | 修复动作 |
|------|-------|---------|----------|----------|
| 2026-08-21 | 全链 | code0817 | PRD→直接编码，docs 仅 1 份 PRD，零测试零复盘，流程执行率 5% | SKILL.md 编码触发加前置拦截（s0/s2 gate + 产物存在性） |
| 2026-08-21 | P3-P9 | code0820/0821 | P3 编码后集体跳过 P3b-P9（3/4 项目同犯） | devflow.md main() 改 P0→P10 单轨遍历，孤儿 gate 全部挂接 |
| 2026-08-21 | P2b | 全部 4 项目 | p2b_demo_gate.sh 零引用，原型 Demo 执行率 0% | spec.md Phase File Map 补 P2a/P2b 行 |
| 2026-08-21 | P10 | code0821 | 复盘列 5 条教训标注"待写入 CHANGELOG"，实际从未落盘 | /retro 步骤 4 硬闭环 + SKILL.md 原则 12 |
| 2026-08-21 | P10 | code0820 | 改进写入 ~/.cursor/rules/（运行时规则孤岛）而非 skill 本体 | 反哺唯一权威入口 = references/CHANGELOG.md（三副本同步） |
| 2026-08-21 | S1 | code0820/0821 | 工程事实源 7 份被跳过（P1 阶段无 S1 Gate 强制感知） | P1 = s1_fact_sources_gate.sh 已在单轨 Order 3，主循环必跑 |
| 2026-08-21 | 取证 | 全部 4 项目 | `.devflow/` 收据目录全部缺失，证据链不可复核 | gate 脚本收据双写 docs/<feature>/gates/ |
| 2026-08-21 | 引擎 | devflow.md | 头部声明废弃 S0-S8，main() 却仍迭代 S0-S8（声明与引擎矛盾） | 引擎改 P0→P10，与声明一致 |

---

## v3.9.4 (2026-08-20) — 自然语言触发表 + build-watchdog 多类型编译 + check-skill-usage 升级

> **背景**：用户问"这些指令是否可以通过自然语言触发？"——暴露出：
> 1. agent 不知道"用户说 X 我应该跑 Y 脚本"——缺映射表
> 2. build-watchdog 只支持 mvn，不支持 npm run build / tsc——前端项目跑不了
> 3. check-skill-usage.sh 只查 v3.9.1 的指标，v3.9.2/3 的 checkpoint + build-watchdog 收据都没审计
>
> 本版本针对 3 类漏洞做修复。

### 修复 1：build-watchdog.sh v3.9.4（多类型编译）
- 探测 backend (mvn) + frontend (npm) + tsc/vue-tsc
- 写 `detect` 子命令，自动判断项目类型
- 修 watch 模式：line-buffered stdout + trap EXIT 自动重启 + 排除 node_modules/target/dist
- `PROJECT_ROOT` 自动向上找 backend/frontend/pom.xml

### 修复 2：check-skill-usage.sh v3.9.4（新增 §5-§8）
- §5: 验证 state.json 存在 + blocker 暴露
- §6: 验证 build-watchdog gate 收据
- §7: 验证 watch 守护进程
- §8: 修 templates 使用率算法（用 python 避开中文匹配 bug）

### 修复 3：audit-completeness 集成 build-watchdog
- `commands/audit-completeness.md` v3.8.1 → v3.9.4
- P3 出口审计加 `bash scripts/build-watchdog.sh gate <feature>`

### 修复 4：SKILL.md 自然语言触发表
- "自然语言 → 脚本"映射表，明确 agent 在用户说"开始实施/卡住了/恢复"时必须调哪个脚本
- 列出反例（agent 不该做的）
- version: 3.9.3 → 3.9.4，tag 加 `natural-language-trigger`

### 实战验收（M-01 跑 v3.9.4 真实结果）
- `build-watchdog.sh detect` 探测到 `backend/`，自动 mvn compile
- `build-watchdog.sh check` 暴露真实 blocker: `XylsSystemApplication.java:[19,2] 找不到符号` + `MenuService 类重复` + `lombok 缺失`
- `check-skill-usage.sh` 8 章节输出：4 PASS + 4 WARN，**全部暴露** v3.9.2/3 的 checkpoint 和 gate 证据

### 破坏性变更
- 无（仅新增 + 文档）

---

## v3.9.4 实战教训

| 时间 | Stage | feature | 失败原因 | 修复动作 |
|------|-------|---------|----------|----------|
| 2026-08-20T02:08:00Z | 自然语言触发 | M-01 | 用户问"这些指令是否可以通过自然语言触发"——暴露 agent 缺映射表 | SKILL.md 加自然语言触发表 |
| 2026-08-20T02:08:30Z | build-watchdog 多类型 | M-01 | 只有 mvn，缺 npm / tsc | build-watchdog.sh 加 npm_build + tsc_check |
| 2026-08-20T02:09:00Z | check-skill-usage 升级 | M-01 | 只查 v3.9.1 指标，v3.9.2/3 无审计 | 加 §5/§6/§7/§8 |

---

## v3.9.3 (2026-08-20) — Build-Watchdog 即时校验

> **背景**：v3.9.2 修了"中断遗忘"，但没修"agent 写完代码不自觉编译"。
> agent 写 .java 后不跑 `mvn compile`，于是编译错误被埋着，直到下次跑 Phase 出口 gate 才被发现。
>
> 本版本用 `scripts/build-watchdog.sh` 把"build 失败即捕获"提前到 agent 每次写完代码后立即触发。

### 修复 1：build-watchdog.sh（NEW）
- `check <feature>` — on-demand 模式：agent 写完代码立即调用，跑 mvn compile + 自动 checkpoint blocker
- `gate <feature>` — Phase 出口模式：写 `.devflow/<feature>/gates/P3-build/receipt.txt`，EXIT_CODE 0=PASS
- `watch` — 后台 fswatch 模式（自动编译）

### 修复 2：SKILL.md 原则 11
- "Build-Watchdog 即时校验"：写完 .java/.xml/.sql/.vue/.ts 后立即 `check`，Phase 切换前 `gate`
- "10 条核心原则" → "11 条核心原则"

### 修复 3：自然语言触发
- `/build` / "开始实施" / "编码" / "M-01" / "补代码" — 全部会**显式触发** build-watchdog
- agent 必须按 SKILL.md 原则 11 在每次代码产物后调 check

### 真实 blocker 暴露（2026-08-20 跑 M-01）
build-watchdog 跑出来后，M-01 真实 blocker 比之前更复杂：
- `MenuService.java:[23,8] 类重复` (f05 与 f04 重名)
- `程序包 lombok 不存在` (pom 缺 lombok 依赖)
- `MenuController.java` 引用 MenuService 失败（连锁）

之前 assistant 只报"缺 jsqlparser"，**漏了**这 3 类更早的 blocker。这就是"build-watchdog 自动捕获"的价值。

### 破坏性变更
- 无（仅新增 + 文档）

---

## v3.9.3 实战教训

| 时间 | Stage | feature | 失败原因 | 修复动作 |
|------|-------|---------|----------|----------|
| 2026-08-20T02:05:04Z | P3-build | M-01 | MenuService 类重复 + lombok 缺失 | 加 lombok 依赖 + 改 package 命名 |

---

## v3.9.2 (2026-08-20) — 中断恢复机制（防"卡死后遗忘"）

> **背景**：v3.9.1 修完 skill 后再追问"为啥预定步骤没做全"，发现 P3 (mvn compile) 因 `PaginationInnerInterceptor` 编译失败卡住 → 用户切换话题改 skill → assistant 没建立 checkpoint → M-01 永远停在 P3 → P4/P5/P6a-6f 全未做。
>
> 本版本针对"中断遗忘"做 3 处修复。

### 修复 1：checkpoint-state.sh（NEW · 中断 checkpoint）
- `scripts/checkpoint-state.sh` 新增 4 个子命令：
  - `save <feature> <phase> <subphase> <exit> <blocker> <next>` — 任何 phase/sub-phase/失败时立即保存到 `.devflow/<feature>/state.json`
  - `resume <feature>` — 打印当前 phase/sub-phase/blocker/next-action/失败历史
  - `list <feature>` — 列出所有 checkpoint + 失败原因
  - `orphans <feature>` — 检查"上次中断留下未关联的产物"（Java>0 但 Test=0 / 后端有但前端 0）

### 修复 2：build 失败自动 hook（agent-side）
- SKILL.md 新增铁律 10：**Build-Error-First 循环** — 任何 `mvn compile` / `npm run build` 失败时，agent 必须先跑 `checkpoint-state.sh save ...` 记录 blocker，再尝试修复，禁止"skip 失败、继续往下"。

### 修复 3：下次重跑验证清单
- `docs/retrospectives/devflow-v3.9.2-no-more-stall.md` 写出"如何验证下次不会复发"。

### 破坏性变更
- 无（仅新增 + 文档）

---

## v3.9.2 实战教训（接续 v3.9.1 表）

| 时间 | Stage | feature | 失败原因 | 修复动作 |
|------|-------|---------|----------|----------|
| 2026-08-20T01:55:37Z | P3/mvn_compile | M-01 | PaginationInnerInterceptor not found in MybatisPlusConfig.java | 加 mybatis-plus-jsqlparser 依赖 |
| 2026-08-20T01:55:00Z | agent pivot | M-01 | 用户切换话题"改 skill"，assistant 没 checkpoint 状态就转去改 skill | 加 checkpoint-state.sh 强制中断保存 |

---

## v3.9.1 (2026-08-20) — 模板-产物对齐 + 即时反哺

> **背景**：v3.9 跑 M-01 项目实战暴露 3 类系统性失败——
> 1. agent 没 Read 任何 `templates/*.md` 就直接写产物
> 2. gate 脚本有但 agent 没强制跑，直接写代码
> 3. 自学习（S8b）只在项目跑完后才反哺，发现错误时已晚
>
> 本版本针对 3 类失败做 5 处修复。

### 修复 1：SKILL.md 加载顺序强制 templates
- 原加载顺序漏列 `templates/`，导致 agent 走"最少阻力路径"绕过模板手写产物
- v3.9.1 起 templates 列为必读
- 新增 7/8/9 三条核心原则：
  - **模板-产物对齐（Template-Artifact Alignment）**：每个阶段产物的章节标题必须与 templates/* 对齐
  - **Gate-First 纪律**：每个 Phase 产物写入文件后必须先跑 gate 取得 EXIT_CODE=0
  - **即时反哺（Just-in-Time Feedback）**：任何 gate 失败立即追加到本 changelog

### 修复 2：s0/s1/s2 gate 加模板-产物章节对齐检查
- `s0_acceptance_gate.sh` 新增 §5：clarification.md H2 vs templates/需求澄清-模板.md
- `s1_fact_sources_gate.sh` 新增 §2：7 份事实源 H2 数 vs 对应模板（比例 ≥ 60%）
- `s2_design_coverage_gate.sh` 新增 §8：design.md H2 vs 详细设计-完整版-模板.md + 10 个必含章节

### 修复 3：加 after-gate-fail-hook + check-skill-usage
- `scripts/hooks/after-gate-fail-hook.sh`（NEW）：任何 gate 失败立即追加到本 changelog
- `scripts/check-skill-usage.sh`（NEW）：4 项审计 — templates 使用率 / gate 执行率 / acceptance 独立性 / 详设格式

### 修复 4：gate 脚本 bug 修复
- `sort: Illegal byte sequence` → 加 `LC_ALL=C`
- `declare -A` BSD bash 不支持 `.md` 作 key → 改普通数组
- `awk substr` 中文多字节 bug → 改 `comm` 整行比较 + 别名 sed
- `head -1c` BSD 不支持 → `head -c 1`
- `P0` 误判 → regex 收紧到表格行 + 排除"已澄清/✅"
- `acceptance-criteria.md` OR 逻辑：必须含"基本"/"验"/"用例"之一

### 修复 5：验证清单（下次复现验证）
- 在 M-01 项目目录跑以下 4 个 gate，全部应 PASS：
  ```bash
  bash ~/.claude/skills/devflow/scripts/s0_acceptance_gate.sh M-01
  bash ~/.claude/skills/devflow/scripts/s1_fact_sources_gate.sh docs/detailed-design
  bash ~/.claude/skills/devflow/scripts/s2_design_coverage_gate.sh \
    docs/detailed-design/M-01-design.md docs/requirements/M-01-acceptance-criteria.md
  bash ~/.claude/skills/devflow/scripts/check-skill-usage.sh
  ```
- 若任何 FAIL=1，对照本 changelog v3.9.1 章节排查

### 破坏性变更
- 无（仅新增检查 + bug 修复）

---

## v3.9.1 实战教训（Just-in-Time Feedback）

> 本章节由 `scripts/hooks/after-gate-fail-hook.sh` 自动维护。
> 任何 gate 失败、P0 阻断、模板-产物不对齐事件，立即追加一行，禁止等到 S8b 才统一反哺。

| 时间 | Stage | feature | 失败原因 | 修复动作 |
|------|-------|---------|----------|----------|
| 2026-08-20T09:32:00Z | v3.9.1 init | M-01 | agent 未 Read templates/ 就手写产物 | 加载顺序加 templates 强制项 |
| 2026-08-20T09:33:00Z | S0 | M-01 | "歧义说明清单" vs 模板"模糊点清单"别名冲突 | s0 加别名 sed 映射 |
| 2026-08-20T09:33:00Z | S1 | M-01 | declare -A 含 `.md` key 在 BSD bash 下 invalid arithmetic | 改普通数组 |
| 2026-08-20T09:33:00Z | S2 | M-01 | awk substr 中文多字节切错（4字节实得1字） | 改 comm 整行比较 |

---

## v3.9.0 (2026-08-19) — 结构精简与单点真相

**问题**:v3.8 已运行 1 天,发现 4 类结构性冗余:
1. phases/ 同时存在 P 编号(00-11)和 S 编号(S0-S8b)两套,内容重复
2. 5 个文件都自称"权威入口"(SKILL.md / README.md / QUICK.md / QUICK-REFERENCE.md / agents/devflow.md)
3. completeness-auditor 与 completeness-reviewer 角色边界模糊
4. devflow-state.sh 34KB monolith 状态机比流程还复杂

**变更**:
- **双轨合并**:9 个 P 编号 phases 文件归档到 `phases/_archive/`,归档目录有 README 解释
- **保留 14 个 P 文件**:00b/02b/03b/06a-f/07/08/09 均为独立能力域,frontmatter 加 `number-scheme: legacy-P-retained`
- **SKILL.md 唯一权威入口**:顶部加红色 banner;README/QUICK/agents-devflow.md 顶部加废弃警告
- **completeness-auditor/reviewer 区分**:两个 subagent 加对照表
- **devflow-state.sh 拆分**:34KB → 4.9KB dispatcher + 3 个 ~5KB 子脚本(core/complete/template)
- **sync-to-codex.sh 升级**:加 `--diff-only` 和 `--no-confirm` 选项
- **新增 check-skill-coherence.sh**:6 项一致性自动检查
- **L-GEVITY / S.U.P.E.R 抽离**:从 concepts/SKILL.md §13-14 移到独立 `concepts/architecture-scorecard.md`(skill 瘦身 ~30%)
- **S 轨文件 frontmatter**:加 `supersedes:` 字段指向已归档文件

**迁移路径**:
- ❌ `phases/00-需求澄清.md` → ✅ `phases/S0-需求基线与原子验收点.md`
- ❌ `phases/02-详细设计.md` → ✅ `phases/S2-模块详设字段级标准.md`
- ❌ `phases/03-规范实现.md` → ✅ `phases/S4-试点模块实施.md`
- ❌ `phases/04-05-06-*.md` → ✅ `phases/S5-两类测试门控.md`
- ❌ `phases/10-知识沉淀.md` → ✅ `phases/S6-S8-修正推广图谱.md`
- ❌ `phases/11-Postmortem.md` → ✅ `phases/S8b-经验反哺.md`
- ❌ 旧 34KB devflow-state.sh → ✅ dispatcher + 3 子脚本(API 不变)
- ⚠️ 11-Postmortem/04b 等已归档文件**不删除**,仍在 `_archive/` 供历史查询

**破坏性变更**:
- `devflow-state.sh` 子脚本拆分,但对外 API(命令行)100% 兼容
- 任何 `cd phases/00-*.md` 的引用改为 `S0-*.md` 或在 `_archive/` 查阅

**验证命令**:
```bash
bash ~/.claude/skills/devflow/scripts/check-skill-coherence.sh
# 期望:FAIL=0  WARN=0
```

## Legacy releases through v3.8.1

Historical release notes were moved to `_archive/changelog-v1-v3.8.md`.
