# 自然语言触发表（v3.9.5 · devflow）

> **目的**：用户说自然语言时，agent 必须知道调什么 skill 脚本。
> **来源**：从 `SKILL.md` 抽出，保持主入口精简。
> **规范口径（v3.24.0 修正）**：Agent Skills 官方建议主文件 < 500 行、完整指令约 < 5000 tokens；本 skill 另有 SKILL.md ≤ 500 词的自律门禁（见 `check-skill-version.sh` / `test-contracts.sh`），二者不冲突。
> **v3.9.5 修复**：§二/§三 原存在"进入 /build"vs"直接跑 build-watchdog check"映射矛盾，且编码触发缺前置产物拦截（实测 code0817 型失败：PRD→直接编码，流程执行率 5%）。现编码类触发统一为"前置拦截 → /build"。

当请求同时命中“字段级设计”和“小需求/小改动”时：现有项目内局部 UI、配置、修复、字段或可追加接口修改优先 `/small-change`；要求系统性设计、批量变更或新模块时进入 `/spec`。最终以项目扫描和风险矩阵为准。

---

## 一、强触发（命令）

| 触发词 | agent 必做 | 入口 |
|--------|-----------|------|
| `/devflow` | 走完整生命周期 | `commands/devflow.md` |
| `/small-change` | 现有项目小需求/小改动的项目事实分类与聚焦验证 | `commands/small-change.md` |
| `/spec` | 出详细设计 | `commands/spec.md` |
| `/build` | 全栈编码 | `commands/build.md` |
| `/test` | 业务测试 + 迁移测试 | `commands/test.md` |
| `/review` | Code Review | `commands/review.md` |
| `/security` | 安全审计 | `commands/security.md` |
| `/performance` | 性能审计 | `commands/performance.md` |
| `/arch-review` | 架构审查 | `commands/arch-review.md` |
| `/deploy` | 发布部署 | `commands/deploy.md` |
| `/monitor` | 监控配置 | `commands/monitor.md` |
| `/docs` | 文档更新 | `commands/docs.md` |
| `/retro` | 复盘 | `commands/retro.md` |
| `/postmortem` | 事故复盘 | `commands/postmortem.md` |
| `/audit-completeness` | 完成度自检 | `commands/audit-completeness.md` |
| `/audit-pitfalls` | 架构陷阱 | `commands/audit-pitfalls.md` |
| `/qa-check` | 代码质量 | `commands/qa-check.md` |
| `/prd-vs-code` | PRD vs 代码对比 | `commands/prd-vs-code.md` |
| `/init-fact-sources` | 初始化事实源 | `commands/init-fact-sources.md` |
| `/devflow-state` | 工作流状态管理 | `commands/devflow-state.md` |

---

## 二、关键词触发（中文强触发器）

| 关键词 | agent 必做 |
|--------|-----------|
| `PRD`、`详细设计`、`字段级`、`100%覆盖` | 进入 `/spec` |
| `小需求`、`小改动`、`修复一下`、`局部改一下`、`改一个字段`、`修改字段`、`增加字段`、`字段展示名`、`调整默认值`、`修改校验规则` | 先进入 `/small-change`；扫描当前项目后由风险矩阵决定 MICRO 或完整 `change` |
| `老系统迁移`、`M-01`（或任意 M-NN） | 进入 `/devflow` |
| `基础能力`、`搭建前后端`、`代码实施`、`编码`、`写代码` | **前置拦截**：先验证 P0/P2 产物（见 §三第一行），缺失即 BLOCKED；通过才进入 `/build` |
| `code review`、`代码审查` | 进入 `/review` |
| `安全审计`、`权限矩阵` | 进入 `/security` |
| `压测`、`性能`、`N+1` | 进入 `/performance` |
| `上线`、`部署`、`发布` | 进入 `/deploy` |
| `监控`、`告警`、`SLA` | 进入 `/monitor` |
| `补文档`、`文档更新` | 进入 `/docs` |
| `复盘`、`上次遗漏了什么` | 进入 `/retro`（含 v3.9.5 反哺硬闭环） |
| `事故复盘`、`postmortem` | 进入 `/postmortem` |

---

## 三、软触发（口语化，需 agent 自觉响应）

| 用户说 | agent 必做 | 脚本 |
|--------|-----------|------|
| `开始实施`、`编码`、`搭建前后端`、`补代码`、`M-01` | **前置拦截（v3.9.5）**：① `docs/需求/<feature>-验收点.md` 存在且 `s0_acceptance_gate.sh` PASS；② `docs/详细设计/<feature>-详细设计.md` 存在且 `s2_design_coverage_gate.sh` PASS。任一缺失 → 输出 BLOCKED 状态卡片并建议先走 `/spec`。全部通过 → 进入 P3 编码，每次写完代码立即校验 | 拦截：`bash scripts/s0_acceptance_gate.sh <feature>` + `bash scripts/s2_design_coverage_gate.sh ...`；编码期：`bash scripts/build-watchdog.sh check <feature>` |
| `修复一个现有问题`、`改一个页面行为`、`调整一个配置`、`把某字段改成…`、`给表单加一个字段`、`字段校验调整` | 加载 `/small-change`，搜索 DB/领域/API/客户端/配置/测试/权限/流程/跨服务/历史数据并生成 project-scan；MICRO 才聚焦修改，FULL 自动转完整流程 | `bash scripts/small-change-gate.sh classify <change-id>` |
| `编译不过`、`build 失败`、`卡住了` | 自动捕获 blocker + checkpoint | `bash scripts/build-watchdog.sh check <feature>` → 失败时 `bash scripts/checkpoint-state.sh save ...` |
| `上次做到哪`、`恢复`、`继续`、`接着改` | 从 state.json 恢复 | `bash scripts/checkpoint-state.sh resume <feature>` |
| `现在的项目卡在哪`、`还有多少没做` | 检测残留产物 | `bash scripts/checkpoint-state.sh orphans <feature>` |
| `审计`、`完成度自检`、`跑完整性`、`切换前检查` | Phase 出口 gate | `bash scripts/build-watchdog.sh gate <feature>` |
| `测试`、`补测试`、`跑测试` | 走 `/test` | `commands/test.md` |
| `审查`、`code review`、`代码审查` | 走 `/review` | `commands/review.md` |
| `上线`、`部署`、`发布` | 走 `/deploy` | `commands/deploy.md` |

---

## 四、反例（agent 不该做的）

- ❌ 用户说"继续写" → agent 直接写代码不调 build-watchdog → 编译错误被埋
- ❌ 用户说"开始实施" → agent 收到 PRD 就直接编码、不查 `docs/需求/` 产物 → code0817 型失败（零文档零测试，流程执行率 5%）
- ❌ 用户说"刚才卡住" → agent 直接尝试修复不跑 `checkpoint-state.sh resume` → 不知道上次做到哪
- ❌ 用户说"检查完没" → agent 直接说"OK"不跑 build-watchdog gate → 没 P3-build 收据
- ❌ 用户说"补一下" → agent 直接生成 .md 不跑对应 gate → 失败无证据
- ❌ 用户说"小改一下" → agent 因需求字数少直接判定 MICRO、不扫描当前项目影响面 → 跨层漏改
- ❌ 用户说"接着改" → agent 跳过 audit-completeness 直接进下一 Phase → P10 反哺错位
- ❌ 编码完成后 agent 直接宣布"全部完成"、跳过 P3b-P9 → 4 项目实测 3 个栽在这（v3.9.5 起 main() 强制 P0→P10 遍历，见 `commands/devflow.md`）

---

## 五、自然语言触发 ≠ agent 自觉

**关键事实**：自然语言触发是"agent 应该响应"，但不是"agent 自动响应"。这中间差一层：
- `check-skill-usage.sh` §6 检查 build-watchdog 是否跑过（暴露没跑的项目）
- `check-skill-usage.sh` §5 检查 state.json 是否落盘（暴露没 checkpoint 的项目）
- `check-skill-usage.sh` §7 检查 watch 守护（暴露后台监听缺失）

**agent 任何时候忘了调，本表会暴露**。

---

## 六、自检命令

跑下面 3 个 gate 验证本表是否生效：

```bash
bash ~/.<tool>/skills/devflow/scripts/check-skill-usage.sh
bash ~/.<tool>/skills/devflow/scripts/checkpoint-state.sh resume <feature>
bash ~/.<tool>/skills/devflow/scripts/build-watchdog.sh detect <feature>
```

任何 FAIL/WARN 都意味着：
- agent 没按本表执行 → 用户应要求补跑对应脚本
- 或 skill 自身问题 → 修 SKILL.md / scripts/
