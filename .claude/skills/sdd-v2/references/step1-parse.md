# 第①步 解析:详设分片 → feature 清单

输入详设文档,产出可开工的 feature 清单。门口检查两道:`--stage parse`(解析对账)与 `--stage list`(清单确认,建议带 `--strict`)。

## 1. 盘点详设文件

枚举**全部**详设文件(总分结构:总文档+分文档都要,漏总文档会整批漏抽全局接口/错误码)。产出 `specs/_work/chunk-plan.json`:

- 分片单位是模块/章,项为 `{"chunkId":"C01","doc":"路径","source":"路径#§x.y","startLine":736,"endLine":823,"approxLines":88,"module":"接口"}`
- 能定行号就定行号(标题文本定位在重名/无编号章节会错位)
- 单片 150~400 行;超 400 必须按小节再切(表结构、接口清单最易吃细节)
- 不足 80 行并入邻片;**规则表、验收标准/追溯矩阵例外,再短也独立成片**(它们是台账与验收分母唯一来源),且不得与流水账合成一片
- 每片自包含;"清单在一节、详情在另一节"的章优先合并,合不下的在 `contextFrom` 列出辅助章节

## 2. 并行抽取

每片派一个只读子代理:给文件+行范围+contextFrom+`schemas/chunk-extract.schema.json`,输出符合 Schema 的 JSON,存 `specs/_work/extract-<chunkId>.json`。硬要求:

- 规则显式填 `ruleId`(`Cxx-Rnn`,台账对账键,漏填/改序都对不上账)
- 原文已有编号原样抄进 `sourceRuleId`(R1/GR02/T2/AR01…),否则用户无法对着详设核
- 「分类」列进 `category`(拆 feature 的依据),「约束/错误处理」列进 `errorCase`(错误码不抽,写契约时回读原文)
- 验收点抽进 `acceptances`,原文 ID 照抄 `acceptanceId`,矩阵各列进 `ruleRefs/apiRefs/tableRefs/testCases`;归入 rules 或删除算漏抽
- 非功能维度从枚举选,没有的填 `other`+`subDimension`,禁止丢条目
- 接口必须带 `method`/`path`;实在取不到标 `unresolved:true`+`UNKNOWN`+openIssue,禁止编路径
- 表结构 `fields` 原样抄含类型约束;**字符字段必须带长度**,原文没有登记 Q;超 20 列的大表可只登记关键列,但 `indexes` 补表级约束且 openIssues 写明"建表回读原文"——静默截断算漏抽

## 3. 合并与解析报告

合并去重(接口按 path、表按表名、规则按语义);跨片矛盾不合并、登记 Q。写 `specs/_work/parse-report.json`:

- `docs`:全部参与文件;`rawCounts` 七项(modules/apis/tables/rules/nfrs/acceptances/openIssues)= 各片实际条数(脚本逐片核对)
- `counts` ≤ rawCounts;`acceptance.declared` = 详设自述验收点总数+`evidence`
- `architecture`:`monolith`(填 `modules`)或 `microservices`(`services`≥2),只认技术栈/部署章正面陈述,"跨服务调用"标题但正文"单进程"不构成证据;附 evidence

## 4. 整体判读

基于抽取件计数与 Q 回答:有无空洞章(章不小但 rules/apis/tables/acceptances 全 0)?Q 分布是否异常?结论三选一(可开工/带条件/不可开工)写入呈报;不可开工则停,用户坚持才继续并标"详设带病开工"。某片抽取件已存在则跳过,重入安全。

## 5. 三表对账(必跑)

spec 生成前,对每个 feature 涉及的表跑一遍「接口出入参 ↔ 表结构 ↔ 规则 R」差集,结果写进 parse-report.notes。四项检查逐项打勾:

1. **枚举长度**:每个枚举/状态字段,最长枚举值的字符数 ≤ varchar 宽度(先例 Q011,详见 casebook#枚举超宽)
2. **字段差集**:接口出入参字段集 ↔ 表列集逐条比对,缺列/多列逐条登记(先例 Q013,详见 casebook#字段差集漏列)
3. **唯一索引 × 逻辑删除互斥**:扫描"唯一索引列组合 ∩ 逻辑删除表",命中即预警(先例 Q017/Q018,详见 casebook#唯一索引逻辑删除互斥)
4. **冲突必落账**:上述任何冲突一律落 parse-report.conflicts 并接 Q 机制,**禁止 conflicts=[] 直接放行**;conflicts 非空时每条须关联 Q 才能进 step2(守门引擎检查)
5. **UI 交叉对账——菜单项↔页面清单**(复盘 2026-09-20,先例:"用户管理"菜单有项无页):详设含内置菜单清单/菜单树示例时,逐个菜单项核对能否映射到页面清单的某个页面——**以名称/语义对齐,不依赖 route_path**(技术性字段与 SPA 路由键不同,机械对不上属正常);映射不上的菜单项登记 Q(blocking=low 起步,写明"点击后去哪"缺裁决)。菜单清单与页面清单是详设的两个独立视角,各自完整不等于互相闭环

方法论定位:这是「接口出入参 ↔ 表结构 ↔ 规则」三个真源的交叉验证,详设的组合性矛盾(Q011/Q013/Q017 全族)在该步全部可静态暴露,不必等实现期编译或首跑红。

## 6. 拆 feature

- feature = 用户可感知、边界明确、可独立交付;1~5 人日(`estimateDays` 必填,>5 红,<1 提示合并)
- 横切能力(登录/权限/字典/公共组件)独立成 feature 排最前
- 已有能力列入清单标 `"done": true`,首批可依赖;依赖无环
- 残缺到无法定义验收的登记高阻塞 Q,不进首批;首批 = 无依赖或依赖全在首批内/done,数量 2~4

## 7. 规则对账台账(硬要求)

`_work/rule-ledger.json`:抽取件里**每条规则**必须有去向,五选一:

- `assigned`:分派到某 F 编号(其 spec 须以 `sourceRules` 追溯,否则算"分派后丢失")
- `deferred`:暂缓,给 `feature`+`note`
- `pending`:待裁决,挂 `qRef`+`note`;开工放行要求清零
- `out-of-scope`:给 `note`,且章程"领域边界"有对应排除项
- `constitution`:全局横切规则(统一响应、时间格式、审计字段、事务边界、命名分层、分页收敛),给 `note`(归章程哪节)+`strength`(测试/评审/约定)

`chunkId`/`ruleId` 原样照抄抽取件。

## 8. 清单确认

呈报附台账余量(非 assigned 清单)+架构形态判定+`sourceRuleId` 原文编号,供逐条核对。确认后:

```
python scripts/sdd_state.py <specs> approve-list --by <确认人>
python scripts/sdd.py <specs> --stage list --strict   # 必须绿才算闭环
```
