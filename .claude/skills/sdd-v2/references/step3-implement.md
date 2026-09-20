# 第③步 实现:逐 feature 开工 → 实现 → 自查 → 评审 → 交付确认

吃 spec 套件生成代码,循环直到全部已交付。每轮开工前跑 `sdd_state.py state` 选下一个可开工 feature。

## 事件驱动派发(默认启用)

派发节奏从「批量同步」改为「单 feature 就绪即派发」,消除等批量凑齐与串行空转:

- **探测器**:`python scripts/sdd_state.py <specs> ready`——单 feature 粒度报 `readyForSpec`(依赖全交付且无 spec)/`readyForImplement`(依赖全交付+spec 已确认+无高阻塞 Q)/`waiting`(带原因)。**每收到一个「已交付/已确认」事件就跑一次**,有输出即派发,无输出即等待;取代"凑齐一批再动"的旧节奏
- **派发循环**(主会话编排,事件源=子代理完成通知,框架自带):收到通知 → ready → 生成 spec/派发实现 → 该 feature 交付判据(deliver 闸+独立评审)一寸不让
- **并行冲突控制**(两个及以上实现代理在途时,主会话派发前必须生成 `specs/_work/pipeline.json`,模板 `templates/pipeline.template.json`):
  1. 迁移号独占分配:查 `db/migration` 最大版本顺延,写在派发表,禁止代理自选
  2. 文件所有权:每个在途 feature 列 owns(独占可写)与 forbidden(禁触);共享文件(如 `frontend/src/api/index.ts`)约定"只许末尾追加自己的段落"
  3. 测试环境隔离:并行代理各用独立 H2 数据目录与端口(如 `--server.port=8081 --spring.datasource.url=jdbc:h2:file:./data/f011`)
  4. Q 编号锁:并行批次开工前生成 `specs/_work/q-range-lock.json`(模板 `templates/q-range-lock.template.json`),各在途 feature 认领 open-questions 编号区间,防止并行撞号(守门引擎按它对账)
  5. 有 git 仓库时,冲突高风险对优先 worktree 真隔离(见 `references/parallel-worktrees.md`),完工 merge;同目录软隔离只用于文件面不相交的对
6. **共享/跨域触碰登记与强制回归**(复盘 2026-09-19):受限改动触碰共享域或他 feature 交付文件的,逐处登记该 feature 的 `touches` 数组;收口时必须复跑受影响前任的 L3(断言过期/契约漂移即红),模块新边出现即红(窄端口破环先例)
- **边界**:共享同一张核心表或同一渲染视图的 feature 仍串行——这是数据依赖,不硬并行

## 开工登记

1. 候选 = ready 探测器的 `readyForImplement`(依赖全已交付 + spec 已确认 + 无高阻塞 Q),就绪即派发,不凑批;`readyForSpec` 非空时按第②步补批生成 spec(需委托配置 `batchAutoAdvance==true`,见 step2 §4)
2. 生成/沿用 `specs/impl-config.json`(searchDirs、fileExts、buildCommands、testCommands;命令不登记不得计入判据)
3. 状态回写用命令:`python scripts/sdd.py <specs> --stage set-status <F编号> --status 实现中 --by <谁>`
4. 判据:`--stage begin <F编号>` 全绿(含 DDL 字段口径比对:迁移 DDL 字符列长度与详设 twin 终态不一致且无 `[Q编号]` 留痕即红)

## 实现

- 优先派 spec-implementer 类子代理:给 spec 目录、impl-config、实现规则(`references/implementation-rules.md`)、"只实现这个 feature"
- **装依赖纪律**:联网命令(npm install/playwright install 等)一律带镜像源 `--registry=https://registry.npmmirror.com --loglevel info` 并设超时上限(≤5 分钟);超时即停,申请非受限执行重试**至多一次**,仍失败呈报用户(三选一:提权重跑/加白名单/手动预装),禁止原地无限等——agent shell 无外网时 npm 表现为长时间静默假死,不是权限错
- **环境预检复用**:`--stage env` 在主检出跑一次即结论全局有效;worktree 副本不重复探测(同机同环境),仅当副本内编译报环境类错误时回主检出复查
- 按 spec.tasks 顺序实现;每条 R 完成即在对应代码旁留 `F<xxx>-R<n>` 标注(贴真实现处,不许堆文件头);每条验收 A 有自动化测试或 impl 日志人工走查记录
- 守卫挡路:先疑实现再疑守卫,裁决不了停(红线)
- `[Q编号]` 占位:Q 已关闭按答复实现;未关闭保留占位登记待办
- 干完自查:`grep -rn "\[Q" <改动目录>` 与 open-questions 逐一对账,未登记立即登记
- **产出 L3 接口用例**(guard-tests §6.3):从 spec.json `apis[]` 搬运生成,落 `specs/_work/api-tests/<F编号>/`,每接口正常路径+每条 errorCodes 反向用例;不自动化测的逐条登记 _exempt.md——deliver 闸按 apis 全集对账,缺一即红
- 跑 build+test+L3 用例,命令/退出码/关键输出写 `specs/_work/impl-logs/<F编号>.md`

判据:编译绿、测试绿、L3 接口对账无缺口、R 标注全落、impl 日志完整。

## 自查补充:前端入口链路走查

- **首屏初始态出发**:前端类验收走查必须从「首屏初始数据态」(如库里仅根组织/预置行)出发,逐步点入口链路(选中节点→按钮可用→弹窗→提交),禁止只验后端接口可过(案例:casebook#首屏链路断裂)
- **边界实体能力矩阵**:涉及边界实体(ROOT/admin/系统预置行)的 spec,规则里必须显式成对写「能做什么/不能做什么」(如 A19 只写根无停启,漏了根必须有新建入口);走查时正反两个方向各走一遍
- **单边状态对称**:凡「X 方向做了处理」的状态类逻辑(启停/开关/正反向),自查时必须检查反方向是否同规则(案例:casebook#单边状态对称)
- **按钮级验收禁纯走查**(复盘 2026-09-19):涉及"提交控件/入口按钮存在性与可用性"的前端交互类验收,不得仅以代码走查承接——必须有 Playwright 触达,或显式声明"归 L5 并登记 debt-register"(案例:强制改密页无提交控件,走查三轮未觉)

## 自查过关

1. `--stage deliver <F编号>` 全绿
2. 对照 acceptances 逐条走查补进 impl 日志
3. `--stage set-status <F编号> --status 已交付 --by <谁>`

## 独立评审

1. 派 spec-reviewer 类子代理(与实现者不同上下文):spec 目录、改动文件清单(git diff 范围)、impl 日志路径
2. 问题清单发回实现代理修(续同一上下文);动了源码重跑自查
3. 修完请评审复核原清单,全解决才过;同一问题 3 轮仍报→停,呈用户(红线)
4. 记录落 `_work/review-logs/<F编号>.md`

## 交付确认

### 遗留申报销账(强制,复盘 2026-09-19)

交付呈报时,实现方申报的每一条"归收尾/归后续/遗留问题"**必须当场登记**到 `specs/_work/debt-register.md`(列:来源 F 编号/内容/销账条件/目标 feature 或阶段);未登记的遗留视同未申报。step4 开口第一步即汇总本表成核对清单,done 前逐条核销——**禁止让债务散落在 impl 日志里**。

### 共享/跨域文件触碰登记(强制,复盘 2026-09-19)

受限改动触碰共享域或他 feature 交付文件时,pipeline.json 该 feature 条目必须增 `touches` 数组逐处登记(文件+缘由)。任一 feature 收口时,凡 `touches` 覆盖共享域的,**必须复跑受影响前任 feature 的 L3**(断言过期/契约漂移即红,发回该 feature 修复);发现模块新边即红(沿窄端口先例破环,守卫同步)。

### 占位钩子追踪(轻量,复盘 2026-09-19)

交付时以占位实现承接的钩子(Default*Checker 之类)必须在 G3 呈报显式声明"收口目标 feature";目标 feature 交付闸时把替换该钩子列为验收走查项。

呈报材料由脚本生成,不走手工组装:

```
python scripts/sdd.py <specs> --stage report <F编号>
# 产出 specs/_work/g3-reports/<F编号>.md:改动文件、R→落点对照、验收走查、Q 占位、日志路径
```

核对脚本产出无红、补评审结论一句话。委托模式按 gate-delegation.json 自裁/呈报,结论落 `specs/_work/gate-decisions.md`。然后回到开工登记(state 重新报数),直到全部已交付 → 转 `step4-test.md`。
