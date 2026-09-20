---
name: "prd-detail-design"
description: "读一份 PRD/需求文档（如 ch-07.md），两阶段产出：先做 PRD 预检并单独生成问题清单（prd_issues.json + issues.md，交付裁决）；blocking 问题全部裁决回填后，才生成详设（detail_design.json + 详细设计.md，只含定稿内容，机器强制零问题残留）。内置系统架构基线（技术栈/接口规范/全局规则，详设直接继承）；大 PRD 支持主会话+多 subagent 按 chunk 并行，输出过大时按 part 分片产出+merge_chunks.py 机器合并。触发词：PRD转详设、生成详设、问题清单、裁决回填。"
---

# PRD → 问题清单 → 详细设计（两阶段，问题与设计分离）

读一份 PRD/功能设计文档，产出**两套独立产物**：

| 产物 | 载体 | 读者 | 内容 |
|---|---|---|---|
| **问题清单** | `prd_issues.json` + `prd_issues.md` | 人（裁决） | PRD 的未决项/矛盾项/缺口全量登记 + 裁决状态机（open → resolved/wontfix） |
| **详细设计** | `detail_design.json` + `详细设计.md` | 机器（下游实现） | **只含裁决后确认的设计内容，零问题残留**（校验器全文扫描强制） |

## 运行目录约定（产物隔离，禁止散落仓库根目录）

一次 PRD→详设运行的全部产物（`prd_scan.json`、`prd_profile.json`、`prd_candidates.json`、`prd_issues.json`、`prd_issues.md`、`detail_design.json`、`详细设计.md`、裁决记录 `USER-DECISIONS-*.md`）**必须落在同一个运行目录**：`design/{PRD 文件名去扩展名}/`（如 `ch-07.md` → `design/ch-07/`）。先建目录再产出，后续校验/渲染/重跑流水一律以该目录内文件为输入输出；多 PRD 各自独立目录，互不污染。

## 核心问题的答案：是否必须先解决疑问才能生成详设？

**是的，但只对 blocking 问题成立。** 详设是给下游实现的确认件，出现"二选一待裁决"等于让下游掷硬币。规则：

- **blocking 问题**（矛盾、影响方案分支的未决）：**必须先裁决**。`run_design.py --gate` 硬门校验：存在 `status=open` 的 blocking 问题 → 拒绝生成详设（退出码 1）。裁决后按 `affects` 列定位改动点回填详设，对应验收以 COMPLETE 形态写入；
- **非 blocking 问题**（外部依赖声明、错误码命名、待后端补全的维度）：不阻塞，相关设计照常生成，问题在清单中留档（`wontfix` 或 `open` 均可）；
- 未闭环的验收条目（原 PARTIAL/MISSING）**不写入详设**——留在问题清单，裁决后以 COMPLETE 回填。因此详设的 `acceptance.declared` 可以大于已设计总数，差额语义 = "受未裁决问题影响暂不出现的条目"。

## 目录结构（自包含）

```
.claude/skills/prd-detail-design/
├── SKILL.md                    本说明 + 两阶段方法论
├── schema.json                 detail_design.json 契约（无问题类字段：问题只存在于 issues.schema.json）
├── issues.schema.json          prd_issues.json 契约（问题内容唯一载体）
├── references/
│   └── system-baseline.md      内置系统架构基线（生成详设前必读）
├── templates/                  模板库：一个 *.profile.json = 一套具名模板（文件名即模板名）
│   └── fun-17item.profile.json 17 项功能详设模板（文件头 _name/_appliesTo/_source 自述用途与出处）
├── scripts/
│   ├── scan_prd.py             通用预检引擎（零配置：标题树切分 + 编号家族三层分类 + G1~G6，产出 G 编号候选）
│   ├── validate_prd.py         模板层预检引擎（按结构画像跑 7 类模板符合性检查，产出 P 编号候选；默认关）
│   ├── validate_issues.py      问题清单校验（编号/裁决完整性/矛盾双口径/I5 blocking 凭据/--gate 裁决门）
│   ├── validate_design.py      详设校验（13 条闭环 + 零问题残留全文扫描 + decisions 锚点核对）
│   ├── render_issues.py        问题清单 → issues.md（裁决评审版）
│   ├── render_design.py        详设 JSON → 详细设计.md
│   ├── run_design.py           四段流水编排（校验→裁决门→详设校验→对账→双渲染）
│   └── merge_chunks.py         详设分片 part 文件 → 完整 detail_design.json（同主键内容不同即 FAIL；见「大文档分片产出」）
└── examples/
    ├── sample.json             详设样例（零问题内容）
    └── sample_issues.json      问题清单样例（含 resolved/open 两态）
```

运行期零外部依赖（纯 Python 标准库），整目录拷贝独立使用。

## 内置系统基线（生成前必读）

[references/system-baseline.md](references/system-baseline.md) 是 skill 的**内置技术上下文**（提炼自系统详细设计总文档）：技术栈（Vue3+TS+Element Plus / Java17+SpringBoot3+MyBatis-Plus+Flyway+H2 单体免登录）、全局接口规范（/api/** 路由动词语义、统一响应结构、全局 bizCode 错误码表、DTO 命名）、全局规则底座（GR02 时间口径/GR03 逻辑删除/AR 审计等）、Flyway 迁移与公共列约定。约束：

- **meta.techStack 从基线继承**，禁止再写"PRD 未指定技术栈"；
- **REST 契约与表结构是详设的本职工作，不是 PRD 的**：PRD 没有时，按 PRD 数据字段表推导建表（补公共列、索引、外键），按操作语义+基线规范设计完整 REST 契约（method/path/入参/出参/http+json 示例/errors）——这是设计产出，不是登记 gap；
- 基线只解决"系统怎么建"，PRD 的缺口里**业务口径类**未决（如到期处置二选一）仍是 blocking 问题走裁决；纯推导性设计（推导的表结构/接口命名）登记**非 blocking** 的 `unresolved`（text 写明"推导设计，待评审确认"），不阻塞生成；
- 模块设计与系统基线冲突时登记 conflict 交裁决，禁止静默二选一。

## 大 PRD / 复杂系统：多 agent 并行

PRD 内容多（FUN 数 >8 或行数 >1500）时，单上下文容易顾此失彼，按 chunk 并行：

1. **主会话做编排**（不自己填内容）：阶段一预检 + 章节 map + 切 chunk（每个 chunk 附：PRD 章节区间、验收行号区间、涉及的 R 编号）——chunk 边界按 FUN 分组，跨 chunk 的共享规则（多处出现的 R-xxx）归属唯一 chunk，其他 chunk 用 sourceRuleId 引用；
2. **每 chunk 派一个 general-purpose subagent**，prompt 给四样东西：本 skill 路径（让它读 SKILL.md + schema.json + system-baseline.md）、PRD 章节区间、本 chunk 的 chunkId/规则编号起止、全局验收编号区间（如 A20~A34，由主会话预分配**避免编号冲突**）；
3. **主会话合并**：chunks 按序拼装 → 跨 chunk 闭环检查（ruleRefs 引用的规则在别的 chunk、acceptanceId 全局唯一、规则孤儿判定）→ `run_design.py` 四段流水；
4. 问题清单（prd_issues.json）由主会话统一编号合并各 agent 上报的候选——PI 编号全局分配，同样不留给 subagent。

原则：**编号与合并权在主会话，内容生产在 subagent**；每个 subagent 只看自己的 PRD 区间，防上下文互相污染。

## 大文档分片产出（生成过大的固定解法，发生即启用，不必等重试失败）

**故障模式（已实际发生）**：`detail_design.json` 内容多到超出单次写入上限，整文件一次生成中途截断/失败，前面的工作全部作废。输入侧有多 agent 并行（上一节），但**输出侧单文件过大是另一类问题**，解法是**分片产出、机器合并**：

1. **触发判据（skill 自判，无需人工或外部记忆）**：PRD 行数 >1500 或 FUN 数 >8（与「多 agent 并行」同一量化门槛）时，**必须**按分片模式产出详设；生成中途截断（JSON 解析失败/写入报体积错/输出被截）也立即切换到本模式重做，禁止在残缺文件上打补丁；
2. **分片规则**：按 chunk 切 `detail_design.part-NN.json`（NN 两位序号，连续无缺口）：
   - `part-01`：`meta` + `architecture` + `techStack` + `frontend`（全局骨架，只写一次）；
   - `part-02…`：每片一个或多个 chunk（`chunks` 数组的元素）；
   - **每片必须独立完整合法 JSON**（Write 一次一片，片小不会超限）；片内不做跨片闭环（rules 引用等留给最终校验）；
   - **每片产出前必须对照 schema.json**（含 part-01 骨架——2026-09-18 首跑教训：主会话凭记忆手写骨架产生 177 处字段名违规，而读了 schema 的 chunk 分片零违规；schema 校验在合并后才跑，分片作者不对照契约 = 错误延迟集中暴露）。分片落盘后立即跑 `python scripts/validate_design.py --input <part 文件>` 做片级 schema 自检——**只允许剩三类预期差异**（2026-09-18 实测归纳）：①顶层骨架字段缺失（chunk 分片缺 meta/architecture/techStack/acceptance/frontend，part-01 缺 chunks/acceptance，合并后补齐）及其连带的验收总数对账告警；②跨片 ruleRefs 悬空（权威定义在别的 chunk，闭环检查需全量文件）；③chunkId 顺序编号告警（每个 chunk 在自己片内都排数组第 0 位，编号连续性只对合并后文件成立）。**除此之外的字段名/必填/多余字段违规必须当场修**，全片通过才进合并（注入测试验证：多余字段/错误键名当场必拦；api.method 契约故意不设枚举以容纳 UI: 语义登记，非违规）；
3. **机器合并（禁止手拼 JSON）**：
   ```bash
   python scripts/merge_chunks.py --parts "design/ch-07/detail_design.part-*.json" --out design/ch-07/detail_design.json
   ```
   脚本按字典序合并：dict 递归合并、列表按主键（chunkId/acceptanceId/route…）去重拼接、标量冲突打 WARN；**part 编号不连续直接 FAIL**（缺片=有分片未产出，禁止带洞拼装）；合并后立即跑 `run_design.py` 四段流水做全量校验，schema/闭环问题回对应 part 修复后重合并；
4. 问题清单同理：单文件过大时按 chunk 拆 `prd_issues.part-NN.json`（数组分片），用任意脚本/jq 级拼接即可（issues 顶层就是数组），PI 编号仍由主会话预分配。

**不变的红线**：`详细设计.md` 永远不手写——由 `render_design.py` 从合并后的 JSON 渲染，大文档场景下尤其如此；裁决门、零问题残留校验在合并后的完整文件上照常生效，分片不降低任何校验强度。

## 执行流程（两阶段，不可跳步）

### 阶段一：预检 + 问题清单（先审）

1. 建运行目录（见上方「运行目录约定」），读完 PRD，先跑**通用层预检（必跑、零配置）**：`python scripts/scan_prd.py --input ch-07.md --out design/ch-07/prd_scan.json`
   - 通用层**不假设任何模板**，只依赖"文档有标题层级"与"编号形如 `PREFIX-数字`"两个事实——**栈式解析标题树**（任意跳级都支持）→ 推断**检查单位**级别（取"节点最多"级，与"最深且节点数≥2"级交叉验证；分歧时报告并取前者，可用 `--unit-level` 覆盖）→ 自动发现**编号家族**并分三层处置：**内部定义族**（本文件有定义位）跑悬空引用/重复定义、**外部依赖族**（本文件无定义位）只登记不判悬空、**噪音族**（成员<2，文件名类碎片）抑制。检查项：G1 悬空引用 / G2 重复定义 / G3 空表 / G4 关键词命中 / G5 外部依赖族清点 / G6 结构报告（层级直方图 + 选中级别 + 推断依据，供人工核对引擎有没有看错结构）；
   - **三层分类是可信度的关键**：不分层会对"定义在别的文档"的编号族刷出上百条假警报（ch-07 实测约 168 条：REL/Q/CG/REQ/FP/COM），引擎随即失去可信度，G6 结构报告就是让你核对引擎有没有看错文档；
   - 通用层**不检查模板符合性**——产物中如实标注"未检查"，不假装查过。
2. **模板层预检（默认关，仅当显式声明"本文遵守某模板"时才跑）**——确定模板并落一份**完整模板画像**：
   - **模板库在 `templates/`**：每个 `*.profile.json` 就是一个具名模板，**文件名即模板名**；文件头 `_name` / `_appliesTo` / `_source` 自述它是什么模板、适用什么场景、出自哪份规范（下划线开头的键是给人看的元信息，引擎忽略）。要新增模板就往这里加文件，不需要改任何代码；
   - **落地方式是复制**：`cp templates/{模板}.profile.json design/{PRD}/prd_profile.json`，再补上该 PRD 的 `expectedFuns`（AI 亲自数到的小节 id 清单）。**必须复制而非直接引用**——运行目录自带完整配置，脚本或模板将来若改动，旧运行仍能原样复现；
   - **画像必须是完整的模板定义**：缺任一必需字段即拒跑（exit 1）。"只写 expectedFuns、识别规则靠脚本内置兜底"的旧做法已废弃——那样一次运行的配置一半在文件里、一半在脚本版本里；
   - 不打算声明模板时**不要跑这一步**：模板层不指定 `--profile` 会直接拒跑并指路通用层，此时只用第 1 步的通用能力即可。声明了模板的，画像字段如下（照 `templates/` 里的样板改，别从零写）：
   - 画像是**纯结构识别配置**，不含检查逻辑——字段：`funSection.pattern`（功能小节标题，须含 `?P<id>` 命名组）、`templateItem.pattern`（模板项，须含 `?P<num>`）+ `requiredItems`（P1 必需项编号）、`acceptanceItemNumber`、`ruleDef.pattern`（规则表行，须含 `?P<rid>`）+ `nonAuthoritativeQualifiers`（非权威括注）、`ruleRefPattern`/`funRefPattern`/`qRefPattern`（悬空引用扫描；**某类引用不存在时写永假式如 `(?!x)x`**）、`unresolvedMarkers`（未决标记词表）、`emptyTableRowPattern`/`acceptanceHeaderKeywords`（P6 表格识别）、`expectedFuns`（**AI 亲自数到的小节 id 清单，对账用**）；
   - **铁律——检查逻辑固定，结构识别可生成**：画像只许换"怎么找到小节/规则表/验收表"，禁止为单份 PRD 改引擎检查项；引擎与 AI 的独立兜底关系因此保住（AI 写画像错 → 被对账暴露，不会静默漏检）；
   - **对账硬门（全路径强制，无容忍通道）**：`expectedFuns` 未声明 → 引擎 exit 2 拒跑（它与模板规则是两回事：**规则是模板给的、全 PRD 通用；这一条是这份 PRD 特有的**——AI 亲数一遍再让引擎对账，才拦得住"模板正则写窄了静默漏小节"）；`expectedFuns` 与引擎实际匹配不一致 → exit 2 拒绝分析并列出差集（提示 pattern 太窄/太宽），必须修正画像重跑；匹配到 **0 个小节 → exit 3 拒跑**（无结构/叙述性 PRD 不支持，只支持有功能小节结构的文档，禁止降级为"只跑全文级检查"）。
3. **模板层**跑确定性预检（仅第 2 步声明了模板时）：`python scripts/validate_prd.py --input ch-07.md --profile design/ch-07/prd_profile.json --out design/ch-07/prd_candidates.json`（`--profile` **必须显式指定**，指向第 2 步复制落地的完整画像；不指定则拒跑并指路通用层）（P1 结构缺项 / P2 规则双定义矛盾 / P3·P4 悬空引用 / P5 未决标记 / P6 验收空表 / P7 Q 编号登记）；
4. **对两层候选逐条表态**（通用层 `prd_scan.json` + 模板层 `prd_candidates.json`）：确认 → PI；误报 → 给理由（禁止静默忽略）；
5. AI 语义预检补充，合并为 `prd_issues.json`（issues.schema.json 契约）：
   - `kind`：unresolved（PRD 明示待确认）/ conflict（同物两口径，text 必须并列两处出处）/ gap（维度缺失：无表结构/无接口契约/无量化 NFR/外部依赖未定义）；
   - `blocking`：是否阻塞相关设计的定稿——判据：该问题是否存在"多个候选方案且选择影响接口/数据/流程设计"（裁决门是**分叉检测器**，不是完备性检查器：拦"有岔路没选"，不拦"单行道走完留备注"）；
   - **blocking 凭据（I5 硬校验）**：`blocking=true` 且 `kind=unresolved` 的问题必须带 `candidates`（≥2 项，每项 `{option, impact}`——候选一句话、选它对接口/数据/流程的影响差异）。写不出两个候选就不是分叉，应改 `blocking=false`。conflict 型双口径已是凭据、免填；gap 型（零方案）允许为空（校验器提示确认）。目的：把"AI 声称 blocking"从空口断言变成带凭据的登记，裁决人看着选而不是先查再断；
   - **非 blocking 条目的自说明**：`blocking=false` 的问题填写 `nonBlockingReason`（为什么不影响详设生成，如"基线规范唯一确定推导结果，无候选分叉""仅声明外部文档依赖，不进入本模块设计"）与 `confirmPoint`（读者只需核对什么）两个字段。目的：读者一眼看明白该条不拦详设、只需确认。两字段皆空时校验器警告（I6，软）不拦截；
   - **本职产出不是 gap**：表结构/REST 接口契约是详设的本职工作（基线 §2/§4 已给定规范，推导结果唯一），"PRD 没有"不登记 gap；只有拿不准的个别推导口径才登记非 blocking unresolved（text 按上条格式写明"推导设计，仅确认推导口径"）；
   - `affects`：受影响范围（功能名/R 编号/A 编号），裁决回填时的定位锚点；
6. 跑 `validate_issues.py --input design/ch-07/prd_issues.json` 自检，渲染 `render_issues.py` 出 `design/ch-07/prd_issues.md`，**交付裁决**。

### 阶段二：裁决回填 → 生成详设（后转）

1. 裁决人在 `prd_issues.json` 逐条落 `status=resolved`（`resolution` 写明口径：按哪个候选、明确什么）或 `wontfix`（理由）；非 blocking 的 open 问题可保留；
1.5 **裁决记录保留（每轮裁决后必做）**：将本轮新增裁决结论追加到**运行目录**下的 `USER-DECISIONS-{YYYY-MM-DD}.md`（与详设同目录，如 `design/ch-07/USER-DECISIONS-20260917.md`；当日已有则追加，无则创建）。文件按表组织：编号/事项、裁决结论、裁决人与日期，并逐条标注 PRD 溯源位置（章节或行号）。PRD 引用的历史裁决文件缺失时，可经用户授权从 PRD 正文内联结论**重建转录版**（文件头注明「转录版，逐条标注溯源」，不改动任何口径）；此后每轮新裁决持续追加于该文件，保证裁决历史可独立溯源（详设与问题清单之外的第三件留档）；同时在详设 `meta.baseline` 中引用该记录文件路径，使详设可反查裁决出处。
2. 按 `affects` 把裁决口径写进设计（规则定稿口径、接口契约、验收条目），生成 `detail_design.json`（schema.json 契约；**先读 references/system-baseline.md 继承技术栈与规范**；表结构字段级五列按 PRD 数据字段表推导、HTTP 接口完整契约按操作语义+基线规范设计、frontend 页面/交互/弹窗三段）；
3. 一键硬门流水：

   ```bash
   python scripts/run_design.py --input design/ch-07/detail_design.json --issues design/ch-07/prd_issues.json \
       --design-out design/ch-07/详细设计.md --issues-out design/ch-07/prd_issues.md
   ```

   四段：问题清单校验 → **blocking 裁决门**（有 open 的 blocking 问题则详设拒绝生成）→ 详设校验（13 条闭环 + **零问题残留**：全文扫「待确认/二选一/未决/Q-xx/PI-xx」等标记，出现即拦；非 COMPLETE 验收禁止入内；meta.decisions 落地锚点必须真实存在）→ 双渲染；渲染前附**三项对账**：验收差额对账（declared > designedComplete 时核对差额能否由问题清单中挂 A 编号的未闭环问题解释，对不上号即警告）、**裁决落地对账（硬拦）**（问题清单所有 resolved 且 blocking 的问题必须在详设 meta.decisions 登记落点锚点——issueId + landedAt，锚点形态 ruleId / acceptanceId / `METHOD path`，拦"裁决了但漏回填"）、**新鲜度哈希**（流水通过后把 issues 内容 sha256 写入 meta.issuesDigest，下轮比对——issues 变了而 digest 未刷新即提示详设可能是旧版）。

后续问题裁决后重跑流水即增量更新详设（裁决一条，回填一条，`declared` 差额随之收敛）。

## 填写指南（易错点）

1. **详设零问题残留是硬纪律**：溯源标注写「按 2026-09-17 裁决：候选一」是合法的（含"已裁决/裁决/[=]"标记），写「见 Q-002」或「待确认」是违规的；
2. **问题清单是问题内容的唯一载体**：不要在详设里"顺便"登记问题；预检候选必须逐条表态，静默丢弃被 validate_issues/闭环检查拦截于详设侧之外；
3. **tables 字段级五列（详设的本职产出）**（name/type/constraint/default/note）+ indexes；同表字段名唯一。PRD 只有业务口径字段表时**由详设推导为建表设计**：补公共列（id/审计四字段/逻辑删除标记，基线 §3，可一行说明"含公共列(基线 §3)"）、索引、模块表前缀（基线 §4）；**禁止以"PRD 无数据库设计"为由留空 tables**；个别拿不准的推导口径登记非 blocking unresolved；
4. **apis 契约深度（详设的本职产出）**：按基线 §2 规范把操作语义设计为 REST 契约——HTTP 动词接口必须带 requestFields/responseFields（字段/类型/必填/校验/来源/脱敏）与 http/json 示例（响应用基线统一结构）、errors（引用基线全局 bizCode + 模块专属 bizCode）、assertions；**GET 无 query 入参时 requestFields 可写空数组（校验器豁免），其余动词必须非空**；`UI:xxx` 语义登记仅限纯展示交互（无数据变更）；
5. **frontend 四段**：pages（页面/模块/路由/组件/类型/权限）、interactions（布局→行操作→三态→并发/错误约定，逐条溯源；**有表格的页带 columns 明细**（字段/列标题/渲染说明），**有表单的页带 formFields 明细**（字段/标签/控件类型/校验提示语/候选来源））、dialogs（场景→组件→接口→确认流）、**contracts 全局前端契约**（路由守卫/Pinia 划分/API 封装与 bizCode→行为映射/权限方式/复用组件清单，bizCode 优先引用基线通用码；**必含「客户端状态持久化口径」小节**——登录令牌的存储位置（localStorage/内存/cookie）、页面刷新与重开浏览器后的登录态行为、多标签页同步、有效期判定方（前端时钟/服务端 401 惰性）；含登录/会话/锁定类模块的，验收点必须成对出现「刷新保持登录态」+「过期/销毁后失效」各至少一条）；要能指导前端直接开工。
   **红线——前端内容不得超出 PRD 对页面的描述**：
   - **交互语义以 PRD 为准**：显隐/置灰/级联/分流/提示文案/确认流，必须溯源到 PRD 第 4 项（界面结构）第 9 项（业务分支）第 10 项（异常处理），PRD 怎么写就怎么落，不做扩展；
   - **控件选型是实现细节，允许补充但禁止反向加约束**：PRD 写"日期选择"→可落 `el-date-picker`；但 PRD 没写的视觉与行为增强（Tag 颜色、动画、布局美化、未提及的默认排序/分页尺寸）不得写入——写了就是对产品的越权决定；
   - **PRD 未描述的页面区域/操作不得出现**：页面清单与弹窗映射的每一行都要能在 PRD 找到对应小节；找不到的要么删掉，要么登记非 blocking unresolved（"建议增加 X，待产品确认"）；
   - 拿不准"是实现细节还是业务约束"时，按业务约束处理：登记问题清单，不自行决定。
6. **验收总分**：declared 可 > designedComplete（差额 = 未裁决问题挂起的条目，裁决回填后收敛），designedComplete 必须等于各 chunk acceptances 实际总数，详设内所有验收必须 COMPLETE。

## 与旧版（prd-detail-design-v1）skill 的差异

| | 原版 | 本版（copy） |
|---|---|---|
| 问题内容 | 嵌在详设的 prdIssues/openIssues | 独立 prd_issues.json/md，裁决状态机 |
| 详设定位 | 草稿可含 PARTIAL 与未决 | 定稿确认件，零问题残留（机器强制） |
| 生成时机 | 预检后即可生成 | blocking 全部裁决后才允许生成（--gate） |
| 流水 | 校验→渲染 | 问题校验→裁决门→详设校验→双渲染 |
