# 详设文档 JSON 模板 —— 填写规则

配套示例 `detail-design.example.json`(内含真实项目取值,仅演示填写形态,禁止照抄)。模板字段与 `schemas/chunk-extract.schema.json` 同构,目的是让解析步(step1)零推断:分片边界、规则编号、验收分母全部写在文档里,子代理只做搬运与去重。

## 1. 为什么按这个结构写

总控规则第 2 条:实现只读 spec,**禁止翻详设**。所以详设里凡是落不进 `rules / apis / tables / nfrs / acceptances` 的内容,无论写得多好,SDD 都吸收不到。写详设时就按能被吸收的粒度写。

## 2. 顶层字段

| 字段 | 对应 step1 产物 | 口径 |
|---|---|---|
| `meta` | `parse-report.source` / `docs` | `docs[]` 列全部参与文件;总分结构必填全 |
| `architecture` | `parse-report.architecture` | `style` 只认技术栈/部署章正面陈述;`evidence` 必须引用章节+原文关键词。正文写「无跨服务依赖」时不得因标题含「跨服务调用」判微服务 |
| `techStack` | `extract.techStack` | 键值对 + `sourceSection` |
| `acceptance.declared` | `parse-report.acceptance.declared` | **验收分母**,详设自述的总数 + 出处。脚本据此核对是否全抽到、是否全落到 feature。分母写错 = 全流程对账错 |
| `chunks[]` | 一片一个 `extract-<chunkId>.json` | 见下 |

## 3. chunks[] 填写规则

- `chunkId`:`C01` 起顺延,`^C\d{2,3}$`。**一份文档内终身不变**
- `chapter` / `sourceSection`:章名与 `§x.y` 定位符,供人回溯原文
- `contextFrom[]`:本片抽不全会漏的关键信息所在的其他章节。典型:接口详情的 method+path 在另一节的概览表里
- 单片 150~400 行;不足 80 行并入邻片;**规则表、验收矩阵例外,再短也独立成片**(它们是台账与验收分母的唯一来源)
- 「清单在一节、详情在另一节」的章优先合并成一片

### 3.1 ruleId 纪律(最重要)

- 格式 `{chunkId}-R{两位序号}`,即 C02-R01。它是 `_work/rule-ledger.json` 的对账键
- **只允许追加,禁止插序、禁止重排**。中间插一条就往后顺延,不要为了连续而重编号 —— 重编号会让台账错位
- `sourceRuleId` 原样照抄详设原有编号(R1/GR02/T2),用户靠它对着原文核。**不可改写、不可丢弃**
- `category` 填原文分类列(新建/编辑/删除/回收站)。它是拆 feature 的天然依据 —— 一个 category 往往就是一个 feature
- `errorCase` 填原文「约束/错误处理」列。**有则必填**:漏了它,写接口契约时就得回头翻详设,而翻详设是违规的
- `vague: true` 只能配一条 `openIssues`;含糊处不许自行补全

### 3.2 其余内容字段

- `apis[]`:`method` + `path` 必填。取不到时 `unresolved: true` + `method: "UNKNOWN"` + 一条 openIssue,**禁止编路径**。`permission` 填鉴权码,免登录写 `无`
- `tables[]`:字段原样抄,**字符字段必带长度**(`varchar(50)`);没有长度就登记 Q。超 20 列的大表可只登记关键列,但 `indexes[]` 要补表级约束,并写 openIssue 说明「建表回读原文」——静默截断算漏抽
- `nfrs[]`:`dimension` 从枚举选(performance/security/idempotency/compatibility/quality/capacity/reliability/observability/operability/maintainability/scalability/compliance),装不下的填 `other` + `subDimension`,**禁止丢条目**。`target` 要可度量
- `acceptances[]`:**本节有内容却不抽,等于把验收分母弄丢**。`acceptanceId` 原样照抄原文编号,无编号才用 `{chunkId}-A{序号}`;矩阵各列进 `ruleRefs/apiRefs/tableRefs/testCases`。归进 rules 或删掉都算漏抽
- `openIssues[]`:疑点/缺失/跨片矛盾。跨片矛盾标 `conflictWith` 填对方 chunkId。**不要自己合并矛盾**

## 4. 与当前解析流程的衔接(待办)

现有 step1 假定详设是 **markdown**,`chunk-plan.json` 靠 `startLine/endLine` 定位,子代理按行范围抽取。
改用 JSON 详设后:

- `chunk-plan` 的 `startLine/endLine` 失去意义,替代方案是 `{"chunkId":"C01","doc":"xxx.json","source":"xxx.json#chunks[C01]"}` —— 但 `approxLines` 仍是必填项(schema 要求),填该章 markdown 原稿的大致行数或估算值
- `source` 字段格式需与脚本约定一致,建议先跑一次 `--stage parse` 确认脚本不红
- 若沿用**总文档 markdown + 本 JSON 作为结构化附件**的混合写法,则把 JSON 纳入 `parse-report.docs[]`,由子代理读 JSON 分片、markdown 作 `contextFrom` —— 这条不需要改脚本,是当前唯一开箱可用的接法