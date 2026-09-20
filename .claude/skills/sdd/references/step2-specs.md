# 第②步 规范:章程 → spec → 守卫方案 → 开工放行

门口检查两道:`--stage spec`(spec 确认,建议 `--strict`)与 `--stage start`(开工放行)。状态值流转:草案 → 已确认。

## 1. 章程

模板 `templates/constitution.template.md`,按解析步判定的架构形态取舍(单体留模块边界条款删 Feign;微服务反之):

- 每条规则标 `[测试]/[评审]/[约定]`;`[测试]` 必须能在守卫方案里找到落点
- `架构形态:` 行填死,与 feature-list.json 一致(脚本比对)
- 待定项登记 Q;模板占位未填充即红

## 2. 写 spec

模板 `templates/spec.template.md` + `schemas/spec.schema.json`;接口多时契约外置 `openapi.yaml`。质量红线(生成自查+脚本检查):

- **「删了重插」对账**:spec 的 tables 登记了 UNIQUE 约束、且规则/断言含「重建/删旧插新/删除后可重X」语义时,必须显式裁决唯一索引与 GR03 逻辑删除的互斥关系,三选一写进解释性决定清单并挂 Q 编号:①该表走物理删除特例(先例:Q017/Q018);②唯一键纳入 deleted 列;③业务上不允许删除后重建。三者缺一,实现期必撞 DuplicateKeyException 500(先例 Q018,详见 casebook#唯一索引逻辑删除互斥)
- **页面交互要点回读**:spec 生成时必须逐条回读其 coversAcceptances 对应详设页的「关键页面交互设计/表格列/表单控件/可操作控件」节,每条交互要点(如"默认展开根节点""入口仅在 X 时可用")要么落进本 spec 的规则或验收步骤,要么在解释性决定清单显式声明归属 feature——禁止把页面交互章节当"前端实现细节"整片跳过(案例:casebook#首屏链路断裂)
- **测试锚点透传**(复盘 2026-09-20):详设 formFields/controls 登记的 testId 是测试定位契约——spec 的前端规则/验收步骤里涉及具体控件的,必须原样带上 testId(如"输入框 testId=login-username-input 校验…"),实现期照抄为 `data-testid`,禁止改写、缩写或漏带;涉前端交付的 spec 缺锚点来源(详设无 testId)时,按 Q 登记回详设补,不自行造名
- **隐含场景清单**(固定步骤,复盘 2026-09-20):逐条问本 feature 是否涉及以下隐含常识场景,涉及的**必须落成验收点**(它们不在详设原文里,不问就没有,而全链路的评审/测试分母都来自验收点)——
  ①刷新/重开浏览器后的登录态与页面状态保持;②浏览器回退/前进;③多标签页同账号;④断网/请求超时后的重试与状态一致;⑤并发双开同记录提交(乐观锁/后写覆盖);⑥会话过期瞬间的在途操作。
  判定依据:详设原文无口径的,按最小可用实现起草验收并在 interpretiveDecisions 登记(禁止留空);纯后端规则(无会话/无前端)可整条声明不适用
- 规则文本禁兜底词(黑名单以守门引擎 `BANNED` 表为唯一真源,含"等"收尾检查);命中为 WARN 启发式,人工复核
- 每条 R 至少一条验收用例;接口字段有类型和示例(或 `noRequest: true`)
- `[Q编号]` 必须已登记,文本占位与 `qRefs` 数组一致(红线,不一致即 ERROR)
- `sourceRules` 追溯:台账 assigned 到本 feature 的每条规则必须被本 spec 某条 R 引用;新增(推断)规则填"新增"并进解释性决定清单
- `coversAcceptances`:分派到本 feature 的规则所属验收点必须全在覆盖声明里,与 `acceptances[].covers` 并集一致
- 表结构:建表/改表的 spec 在 `tables[].fields` 抄录字段定义,与详设 twin 逐列比对;缺列/新增/改定义必须挂 `[Q编号]`。注意:fields 一旦非空就整表对账,要么抄全表要么留空(空只 WARN)

引用既有 Q 前回读其语义核冲突(期数口径/枚举范围/"不做 X"限定),冲突登记新 Q 呈裁,不得照旧引用。

## 3. spec 确认

呈报必须附"解释性决定清单"(所有非详设原文、由你推断的点:位置+理解+依据)。确认后:

```
python scripts/sdd.py <specs> --set-status <F编号> --status 已确认 --by <确认人>
python scripts/sdd.py <specs> --stage spec --strict   # 必须绿
```

## 4. 补批(实现期回本步)

实现中 ready 探测器报出 `readyForSpec`(依赖全已交付而 spec 未生成)时回本步补批。门槛:委托配置 `gate-delegation.json` 的 `batchAutoAdvance==true`(守门引擎据此放行非首批 spec);未开启时补批需用户逐批同意。生成节奏与派发一致——**逐 feature 就绪即生成,不凑批**。**每个 spec 生成前必须回读前序 feature 的 spec 状态与未决 Q 的增量裁决**,把实现反馈回填后续 spec——不得为省事跳过。每个照走本步红线+确认。

## 5. 守卫方案

按 `references/guard-tests.md` + `templates/guard-tests-setup.template.md` 生成 `specs/guard-tests-setup.md`:

- 按架构形态选隔离守卫:单体→ModuleIsolationGuardTest(模块清单取 parse-report.modules);微服务→ServiceIsolationGuardTest(服务对矩阵);分层与 common 守卫通用;契约绑定可选,启用前标"暂缓"
- 仓库已有守卫:填"规则↔守卫对照"+补测清单;没有:出完整搭建方案(依赖、测试类、ESLint、命令落点、CI 接线)
- 默认不落地源码树,落地需用户同意
- 验证四步(正向全绿、反向造违规确认变红、假绿体检、结果回写)必须写进文档;没跑就写"未实跑"+原因,禁止写"已验证"

## 6. 开工放行

先 `--stage env` 环境预检(**无 MISS 才继续**;网络 MISS 按其输出三选一处置:申请非受限执行重试/加权限白名单/用户手动预装依赖,禁止原地无限重试),再 `--stage start --strict` 全绿,再输出:specs 根目录、架构形态、首个 feature 编号+spec 路径、建议实现指令(引用守卫方案"命令落点"表)、开工前待办(影响首批的高阻塞 Q 未关必须明示,禁止带阻默开工;需联网的依赖安装是否已完成/已授权)。收尾自检:

1. feature 清单字段全、依赖无环、首批闭环
2. 每条 R 无兜底词且对应验收;assigned 规则可追溯,台账无 pending
3. spec 所有 `[Q编号]` 已登记且与 qRefs 一致
4. constitution 章节齐、形态一致、待定项有 Q
5. 守卫方案有验证记录(或明确未实跑)、形态选型正确
6. 验收分母闭合:声明的验收点全抽到,首批相关的均在某 spec `coversAcceptances` 且有用例支撑
7. 引用的路径真实存在
8. specs/ 之外未新增/修改文件(除已同意的守卫落地)
9. 环境预检无 MISS;详设 techStack 声明的工具链与实机版本已逐项核对(env 输出 [INFO] 段)

放行后转 `step3-implement.md`,之后每轮工作仍以 `sdd_state.py state` 报数为准。
