# lessons-learned —— 三流程实战经验总表（港口煤发运 / 李雅庄公路 / 李雅庄铁路）

> 来源：项目内已执行的三条流程全过程记录（2026-08-30 ~ 2026-09-09）——
> **港口煤发运** WFA_RY_JM_126001（23 分支，多轮浏览器对比，执行记录/23分支自动化测试报告）、
> **李雅庄公路** WFA_HY_HZ_0150（V1.3 首轮 → R6 独立全量回归 → 09-08/09 深夜双端对比双轮，9 份执行记录）、
> **李雅庄铁路** WFA_RY_HZ_0162（V1.0 首轮 → API 通道双边 → 浏览器对比，8 份执行记录）。
> 每条经验：**现象 → 根因 → 固化位置**（已落进脚本/配置/文档的注明 §；未固化的标注"执行者自查"）。
> 本文件是"为什么这么规定"的依据库；操作性规则仍以 SKILL.md 与各 references 为准。

## 速查：27 条最高价值教训

| # | 一句话 | 固化位置 |
|---|---|---|
| 1 | 字段码可能是 `FIELD_<hash12>` 复合键——以引擎校验实录为准 | contract-howto §取证坑 10 |
| 2 | 新系统提交必带 formData（服务端必填校验依赖），字段码同上 | contract-howto §取证坑 11 |
| 3 | 客户端公式字段（只读+必填）API 通道不可满足 → 走浏览器通道 | capture-channels §1 决策表 |
| 4 | "共 0 条"假象 = 弹窗默认日期过滤 + 查询慢 8~10s | browser-channel §4 G3.1 |
| 5 | 待办清零 ≠ 办结——完成判定只认发起人"已办结流程"列表 | execution-gate §5 完成判定 |
| 6 | 环境级阻塞 ≠ 产品缺陷——结论表述必须区分（铁路拉运日期案例） | lessons §4 L18 |
| 7 | 执行前预检数据池占用（claim/95306 行/磅房行），遗留实例先作废 | execution-gate §6 预检清理 |
| 8 | 默认处理人=首组织首用户，可落别家人员——提交前回读核对 | browser-channel §4 + 契约 risk_seeds |
| 9 | 自动化脚本时序（先选人后提交）错序会产假阳性 PASS | execution-gate §7 假阳性 |
| 10 | 老系统是**生产环境**——只读优先，真实数据占用有业务后果 | lessons §3 L17 |
| 11 | 声明缺口（EXPECTED GAP）跑前登记，不算意外失败 | contract-howto §取证坑 12 |
| 12 | 轮次记录不覆盖历史、编号单调、姊妹记录互链 | lessons §6 L25 |
| 13 | 老系统对话框选数=Vue 组件注入 multipleTableVal，行必须带过滤字段 | browser-channel §4 G3.5 |
| 14 | 老系统提交三件套：先选人→identification 注册→容器内找确定按钮 | browser-channel §4 G3.6 |
| 15 | 老系统表单日期写 Vue 模型（DOM 键入不进模型，服务端按旧值校验） | browser-channel §4 + lessons L28 |
| 16 | 多 agent 并行必互抢浏览器——eval 内嵌宿主守卫+mega-eval 压缩窗口 | browser-channel §4 + lessons L29 |
| 17 | 同名多候选选人必须 prefer_ids 指认（whoami 实值），否则 fail-closed | api-capture resolve_assignee + lessons L33 |
| 18 | submit.nextStep 与 next-assignees.nodeCode 编码空间不对称（DMN 流程） | api-capture 回退翻译 + lessons L34 |
| 19 | SUBMIT 不落业务表单：填单步 SAVE_FORM 前置 + 空步整体回显 formData | api-capture submit + lessons L35 |
| 20 | 必填输入以引擎 400 报错字段码清单为准回填契约再重新生成 | contract-howto §取证坑 13 + lessons L36 |
| 21 | 契约 gates[] 的证据=只读探针报告+sha256（24h 时效），先例 gate-evidence-live | execution-gate + lessons L37 |
| 22 | 新流程 API 首跑六项预检（env 键/actorMap/元素ID/todo.map/gate 时效/数据池） | contract-howto §取证坑 13 + lessons L38 |
| 23 | 提交确认弹窗渲染慢 2~5s：点击→连续 3 轮无弹窗才收尾；业务告警弹窗立即中止 | browser-channel §4 G3.7 + lessons L39 |
| 24 | 显示名≠账号（张冲≠张泽）；agent-browser open() 杀 SPA 登录态，页内用 hash | browser-channel §4 G3.7 + lessons L40 |
| 25 | 引擎库整库重置=元素ID/流程码/环节码三连过期——404 第一反应重查三处再跑 | lessons §6e L48 |
| 26 | 迁移后 sys_user.id 全新空间——prefer_ids/DMN 白名单等一切 ID 引用全量失效，一律当库实查 | lessons §6e L52/L53 |
| 27 | 退回/作废用例的 cases[].notes 特殊流转声明会悄悄丢失——每次执行前复核 | lessons §6e L50 |

---

## 1. 取证与立契

- **L1 字段码复合键后缀**（铁路）：值集迁移器为防跨流程枚举冲突把 field_code 改写为 `FYDW_<hash12>`
  复合键；布局转换器按老系统裸键匹配失配 → 字段平铺/下拉空。**立契时字段码一律以引擎校验实录为准**
  （FORM_FIELD_* 错误消息/render API），勿假设=老系统裸键。→ 已在 qianyi 修复（归一化裸键回退），
  契约侧固化进 contract-howto §取证坑 10。
- **L2 formData 业务数据通道**（铁路）：新系统 execute-button 的必填校验依赖请求体 formData；
  契约 `step.form` → 场景 formData → 提交载荷。老系统表单字段在 getStepForm `data.form_data`。
  → contract-howto §取证坑 11。
- **L3 账本节点码**（铁路）：服务端多候选声明串（"01,02,03"）不得直接作账本节点码——用场景显式
  路由值登记。→ contract-howto §取证坑 11 附注。
- **L4 契约声明的实测校准**（公路 O-2）：A.2 合同带入契约声明挂载 01~05，实测老系统 00 发起页
  即生效 → 按"双端 00 均带入"校准声明并关闭风险种子。**口径张力以双端实测为准修正契约，不硬撑原声明**。
  → 执行者自查（契约 meta.risk_seeds 记录校准轨迹）。
- **L5 路由机制差异单独归类**（港口）：老系统按登录人矿厂服务端固定计算，新系统 BPMN 网关按表单
  KC 终判——机制不同类差异不与"值不一致"混判，单独条目 + 机制说明。→ 执行者自查（对拍结论表述规范）。

## 2. 通道选择

- **L6 客户端公式字段**（铁路 D-19，P1 产品级发现）：ZJ（总计）"只读+必填"由前端公式引擎聚合计算，
  服务端不执行该公式 → API 通道含此类字段的表单**结构性走不通**（提交带 ZJ=只读禁止改，不带=必填）。
  建议①服务端 SAVE_FORM 时执行只读公式回填（推荐）或②对"只读+公式挂载"字段豁免校验。
  → capture-channels §1 决策表已加该行；遇到同类字段直接选浏览器通道。
- **L7 HTTP 超时可调**（铁路）：老系统阵发超时（首页 200 但 startWorkflow/getStepForm/commitWorkflow
  超时）→ `FLOWTEST_HTTP_TIMEOUT=60`。→ env.flowtest.example 已注释。
- **L8 按钮流边界 = 声明缺口**（铁路 C-03/04/06/07）：退回/作废/保存草稿/盖章链非路由语义，
  API 通道未实现 → 契约 notes 登记 **EXPECTED GAP**，执行前声明，跑出来 BLOCKED 不算意外失败。
  → contract-howto §取证坑 12。
- **L9 浏览器工具可替换，capture 契约不变**（公路/铁路用 agent-browser 0.27，港口用 playwright-cli）：
  skill 固化的是 browser-capture.py（playwright-cli 驱动），但通道契约（§capture 契约+采信铁律）
  与工具解耦——换执行器必须满足同一 capture 契约。→ capture-channels §1 已声明。

## 3. 执行操作（老系统浏览器）

- **L10 弹窗"共 0 条"假象**（港口，12/13 分支解锁）：95306 弹窗默认预填日期过滤 + 查询响应慢
  8~10s → SOP：重置→清日期→查询→等待→选"未使用"白色复选框行→确定。→ browser-channel §4 G3.1
  （已编码进 browser-capture.py popups 配置）。
- **L11 默认处理人陷阱**（港口 B-12 实锤、B-05 观察）：选择处理人弹窗按首组织首用户预选，
  **可落别家人员**（水峪发起默认=沙曲张冲）；多候选时默认为空、提交静默失败。→ 提交前回读办理人；
  browser-channel §4 G3.3 + 契约 risk_seeds 必记。
- **L12 同人续办差异**（港口）：新系统同人续办弹"继续办理"确认框，老系统新任务表单自动打开——
  browser 后端 autoConfirmPopups 只覆盖新系统形态；老系统自动打开无需确认。→ browser-channel §4。
- **L13 无菜单账号**（港口 dlf/陈威/张林森/庄文斗等）：走「结算处理→港口待处理结算」第二入口；
  发起无 fallback（发起人必须有菜单）。→ browser-channel §4 G3.4（已编码）。
- **L14 日期必须面板点选**（港口/公路双端同坑）：键入不进模型（FYRQ undefined → 提交恒置灰）。
  → browser-channel §4（已编码 datePanel）。
- **L15 老系统=生产环境**（三流程通用，最高警示）：<legacy-prod-host> 是生产库——对比执行产生的实例、
  占用的 95306/磅房/合同数据都有业务后果；只读探针优先；真实数据选取遵循"最小占用、用后释放、
  残留登记"。→ 执行者自查（无技术护栏，靠本条纪律）。

## 4. 环境与数据治理

- **L16 环境级阻塞 vs 产品缺陷**（铁路 09-09：拉运日期不在合同有效期——老库 IO 同步停滞于
  2026-06-01，33.7 万行"未使用"磅单日期全部超期；换行/换合同/改日期均无效）：**结论表述必须
  区分"环境级 BLOCKED"与"被测系统缺陷"**，否则误导排障方向。判定线索：多数据行同因失败、
  跨端（新老库）数据时间戳停滞、与被测系统版本变更无关。→ 执行者自查（结论速览表单独列因）。
- **L17 数据池占用与避行**（公路 R5/R6）：R4 遗留实例占 6 个 claim key → 后续轮次避行或先作废
  （发起账号"进行中流程"逐一作废 CANCELLED）；R6 实现"测试实例与数据全部清理归零"。
  95306 行选中即被其他实例标记"已被使用"（港口 B-11 唯一记录被占用直接阻塞）。
  → execution-gate §6 预检清理。
- **L18 资源同步滞后三态**（铁路 O-95306）：库内数据脱敏/缺行（consignee 全 masked、无攀钢行）→
  **补种夹具**（LYZTC-FP95306-01/02/03）；选择器输出列漂移（缺 yhsje/yhsse）→ 修选择器定义；
  公式源字段老系统缺失（港口对应到港/品种）→ 契约 formulas 标记单端声明。三类不同修法，勿混。
  → 执行者自查（夹具种入机制见 contract-howto fixtures）。
- **L19 字典候选未随迁移落地**（铁路 P-2）：下拉打开无选项 ≠ 前端 bug——先查 FlowOverrideConfig
  dict_candidates 是否注册、值集内容是否随迁移落地。→ 执行者自查（迁移侧责任，测试侧先定位再报）。

## 5. 结论与账本

- **L20 完成判定标准**（港口 B-02 实锤）：实例 001882 待办清零仍停 35 进行中——**完成判定只认
  发起人「已办结流程」列表查得流程编号**；待办清零/进行中为 0 都不算。→ execution-gate §5。
- **L21 路由异常归类**（港口 B-19/B-22 预选直跳 35 跳过中段；B-15 35 提交后实例消失疑似自动收口）：
  与标准链不符的异常不判 FAIL，判 BLOCKED + 待配置核对清单（SETTLE_WORKFLOW_SUB 路由核对），
  避免把配置漂移误报成代码缺陷。→ 执行者自查。
- **L22 对拍之外的产品级发现独立登记**（公路 R6-1 P2：办结后迟到 claim 绕过终态拒绝且补偿未兜底；
  铁路 D-19）：对拍结论只管双端一致性，**顺带发现的产品缺陷单独编号（D-xx/O-xx）独立跟踪**，
  不挤进 case 判定。→ 执行者自查（执行记录"产品级发现"节）。

## 6. 过程记录规范

- **L23 轮次记录不覆盖历史**（公路 R6 定性）：同日已存在 R5 时，新一轮以 **R6 独立全量回归**执行并
  记录，编号单调不重排；文件命名 `YYYY-MM-DD-主题.md`；姊妹记录（同夜并行会话）显式互链互补。
  → execution-gate §8。
- **L24 修复验证型回归定性**（公路 R5）：修复落地后的全量回归要在记录头部声明"修复验证型"，
  列明验证点（launch 选人 3 修复、投影回写），并复验上轮遗留（R4 假阳性脚本时序）。
  → execution-gate §8。
- **L25 假阳性防时序**（公路 R4→R5 教训）：自动化脚本"自动同意"时序错序（未选人先提交）造成
  假阳性 PASS——浏览器操作脚本必须"先选人后提交"，且关键路径用 ✦ 标注正确时序。
  → execution-gate §7。
- **L26 证据跨 run 引用**（铁路 API 记录）：被环境抖动截断的链路证据固化在历史 run 的
  field-captures（run-20260907202225 等），复跑记录显式引用 run-id——账本只增不改，跨 run 引用
  靠 run-id 而非复制文件。→ execution-gate §8。

## 6b. 老系统浏览器通道深度（李雅庄 09-08/09 深夜互补双轮新增）

- **L27 老系统对话框选数=组件状态注入，不是点 DOM**（公路 O-2/A.1 轮）：老系统「选择合同/磅房/
  执行单」弹窗的确定按钮校验的是 Vue 组件 `_data.multipleTableVal`（部分还校验 `clickVal` 协议态），
  合成事件勾选复选框**不回写组件状态**（勾上点确定仍报「请选择一条合同！」）。可靠路径：
  `wrap.__vue__.$parent` 链找业务组件（contractDialog/customDialog/sheetDialog），取
  `.el-table.__vue__.data` 的行对象赋 `multipleTableVal` 后调 `sure()`。**且行对象必须带
  sure() 过滤器的判定字段**：磅房 `STATUS==='未使用'`（查询返回行无此字段时全部被静默过滤=
  「请选择一条数据！」）、合同 `qzzt`（双签态）、执行单 `id`（写 DATA_CN_IDS；2026 年合同是
  稀疏行无 id → 选择后「缺少必要参数」且清空 DATA_CN_IDS）。→ browser-channel §4 G3.5。
- **L28 老系统表单日期=Vue 模型直写**（公路同轮）：el-datepicker 键入/合成事件改的只是 DOM，
  `form_data.TBRQ/KSFYSJ/JSFYSJ` 仍是旧值，服务端按**模型旧值**做合同有效期窗口强校验
  （「拉运日期不在合同有效日期请修改」——当时模型停在 2023-06-15 而非页面显示的 2026-09）。
  可靠修法=找 `pendingSettlementHandle` 实例写 `_data.form_data.<FIELD>`；日期必须落在已选
  合同签约期内（2023 合同=2023-03 类日期）。→ browser-channel §4。
- **L29 多 agent 并行浏览器串扰守卫**（09-09 凌晨实锤三连）：两个 agent 会话共用一台机器时，
  对方会把你的 tab **导航走**（老系统页两次被导到新系统）+ daemon 抢用（EAGAIN）——每次 eval
  内嵌宿主守卫 `if (location.host !== 期望) return 'WRONG_HOST'`，操作打包单块 mega-eval
  压缩抢屏窗口；被抢后重导航即可（老系统登录态在 localStorage 存活）。发现多 sock
  （`~/.agent-browser/*.sock`）即启用。实测两轮并行**零实例互染**（不动对方发起的实例，
  记录中显式登记对方实例号）。→ browser-channel §4。
- **L30 公式写入顺序分叉的归类**（公路 A.1×A.5 联动）：同输入序列双端 PZ 不同（老=归类值
  覆盖首笔煤种，新=保持首笔原值）——**行为差异非缺陷**，对拍按"可归因差异"表述 + 提请产品
  确认公式优先级口径，不判 FAIL 也不静默豁免（区别于 L5 的机制差异：那类单列机制说明，
  这类是同机制内写入顺序问题）。→ browser-channel §8。
- **L31 老系统提交前合同文件注册前置**（公路 00→01 阻断实锤）：commitWorkflow 校验「合同文件
  已注册」（identification → updateStepHtwjSaveResult）；唯一全字段生产合同（2023）的电子文件
  在服务端注册不完整 → 提交恒拒，前端重试/换选择/换 viewModel 均不可解——**治理侧缺口判
  BLOCKED**，勿反复重试（每次全链重选成本高且结论不变）。备用合同缺 id 反而更糟（L27）。
  老系统全链对比的前置条件=业务侧提供带电子文件的合同。→ browser-channel §4 + lessons §4。
- **L32 老系统发起与提交的操作序**（公路同轮 SOP 固化）：发起列表**点行/点流程名不触发**——
  勾选行复选框+点页面级「启动流程」；提交三件套：①工具栏「选择处理人」（跳过=toast
  「请选择处理人」，它不是弹窗标题而是错误 toast）；②保存成功后调 `identification()`；
  ③「未生成文件，确定要提交流程?」确认框的确定按钮**按特征文本先定位 dialog 容器再取按钮**
  （僵尸弹窗堆积时全局找"确定"会点错对象）。保存未提交的发起句柄 **reload 即永久丢失**
  （暂存孤儿：任何列表都不可见，但服务端暂存数据已产生）。→ browser-channel §4 G3.6。

## 6c. 港口煤 API 通道全链贯通（2026-09-09 会话新增：6 处通道修复 + 对比执行序）

> 背景：港口煤 WFA_RY_JM_126001 契约（单用例 C-01）首次 API 通道正式执行，从 BLOCKED 到
> legacy 侧 12 节点全链跑通；同会话老系统可见浏览器（pcm_legacy.py）完成 B-02/B-03/B-04/B-05
> 四支全链办结。以下每条都有 run-id 或截图证据。

- **L33 显示名选人必须 prefer_ids 指认**（run-20260908201728 实锤）：老系统同名多候选真实存在
  （3 个「侯丽娟」user_id 3599/3600/3601），盲取首个=派错人 → 后继办理人 500「当前登录人没有
  权限处理该环节实例」。修法=systems `assignee.prefer_ids: {姓名: 实值ID}`（来源=被测系统
  whoami 探针，非猜测）；无指认 **fail-closed 返回 None**，绝不盲选。另：候选名含排版空格
  （「高 鹏」）——姓名归一化必须剥全部内部空白再比对。
  → api-capture.py resolve_assignee（第三十三轮实现）。
- **L34 提交路由码与选人节点码是两个空间**（run-20260908202257 实锤）：DMN 路由流程（港口煤）
  submit.nextStep 只认 **routeCode（环节码 01）**，而 next-assignees.nodeCode 只认
  **taskElementId（task_3118）**——两接口编码空间不对称。修法=resolve_assignee 候选为空时用
  workbench `nextNodes` 做 routeCode→taskElementId 回退翻译（翻译源全来自服务端声明，非猜测）；
  此类流程**不配 route_map**（映射会把环节码错换成元素 id 被 DMN 拒）。
  → api-capture.py resolve_assignee 回退块 + capture-channels §5。
- **L35 SUBMIT 不落业务表单，空 patch 一律阻断**（run-20260908203629/204212 实锤）：新系统
  execute-button 的 SUBMIT **不落** formData，引擎按「已保存 revision + 本次 formPatch 合并结果」
  做必填校验，patch 为空一律「表单存在必填字段未填写」。浏览器同构行为=工作台整体回显。
  修法三层：①场景填单步 `save_with_form_data: SAVE_FORM`（提交前先落 revision，同构浏览器
  「保存单据→提交流程」）；②无填单步 `echo_form_patch: true`（把 workbench 采集到的当前表单
  数据原样作为 formData 回显提交）；③载体=formData(Map)（请求层经 BuiltinButtonDispatcher
  转 command formPatch）——**不要发明 formPatch 顶层字段**（DTO 无此键，静默丢弃）。
  → api-capture.py submit（第三十三轮实现）+ capture-channels §5。
- **L36 场景必填输入以引擎报错为准回填契约**（run-20260908204212→210208 迭代）：老表单步骤
  即使契约没写 form，引擎也可能要求必填（质量鉴定单 采样日期 CYRQ——浏览器 SOP 有「采样日期
  填当日」但契约 steps 漏了）。修法=跑一次拿引擎 400 报错清单（「请完成: [...]」直接给字段码），
  回填契约 `steps[].form` 后**重新生成场景**（生成件受保护，勿手改场景）。
  → contract-howto §取证坑 13。
- **L37 gate 证据=真实探针报告**（run-20260908194751 实锤）：契约声明 gates[]（如 GATE-DEPLOY/
  GATE-95306-DATA）时，pipeline 门禁要 `--gate-evidence` 结构化证据，缺=BLOCKED。证据制作：
  只读探针（launchable-processes API + 源库 SELECT 计数）→ 按 evidence_schema required_fields
  填真值 → sha256_16 回填 gate-evidence.json（target_env/generated_at 必填，24h 时效）。
  先例：docs/李雅庄铁路流程/自动化测试/执行记录/gate-evidence-live/。
  → execution-gate §gate 证据 + gen-gate-report.py。
- **L38 对比执行前置清单**（本次会话沉淀，新流程 API 通道首跑必查）：①契约 4 件套账号的 env 键
  在 .env 是否齐（缺=从代码 seed/浏览器轮次配置找映射，禁盲猜）；②双端 actorMap 是否含本流程
  分组；③launch 元素 ID env（LAUNCH_ELEMENT_ID_<FLOW_CODE>）是否已设；④新系统 todo.map 是否
  有本流程 BPMN stepCode 映射（从引擎库 act_ge_bytearray 部署 BPMN 实查，勿用本地 BPMN 文件——
  与运行时不一致）；⑤gate 证据是否在 24h 时效内；⑥95306/磅房类数据池是否有未使用行（双端）。
  → contract-howto §取证坑 13 + execution-gate 预检。
- **L39 老系统浏览器逐支跑链的操作序**（pcm_legacy.py 沉淀，B-02~B-05 四支验证）：待办定位用
  **流程编号匹配行**（勿按行序——候选组待办多人可见易错行）；「未生成文件，确定要提交流程?」
  确认弹窗渲染慢（2~5s），确认循环须「点击→连续 3 轮无弹窗才收尾」且**先检测业务告警弹窗**
  （「请选择一条数据/此记录已被使用」→ 立即中止，自动乱点确定会 40 次循环污染页面状态）；
  每步提交后回读「当前环节」文本验证流转，静默失败（无弹窗无 toast、环节不变）=未提交。
  → browser-channel §4 G3.7。
- **L40 同名显示名≠账号（浏览器通道选人）**（B-05 实锤）：picknext 抓到的处理人是**显示名**
  （张冲），与分支表账号（张泽 hmzhangze）不同人——切号前必须按显示名核对实际账号
  （pcm_run.py 分支定义串即「显示名:环节」格式）； B-05 另复现 00「发运单位+矿厂不带出」
  老缺陷（文档记载⚠️），补填后可过。agent-browser `open()` 是真导航会杀 SPA 登录态（白屏），
  页内切换一律用 `location.hash`，跨页导航后须重登。
- **L40 同名显示名≠账号（浏览器通道选人）**（B-05 实锤）：picknext 抓到的处理人是**显示名**
  （张冲），与分支表账号（张泽 hmzhangze）不同人——切号前必须按显示名核对实际账号
  （pcm_run.py 分支定义串即「显示名:环节」格式）； B-05 另复现 00「发运单位+矿厂不带出」
  老缺陷（文档记载⚠️），补填后可过。agent-browser `open()` 是真导航会杀 SPA 登录态（白屏），
  页内切换一律用 `location.hash`，跨页导航后须重登。
  → browser-channel §4 G3.7 + lessons §3。

## 6d. 港口煤 API 通道正式 PASS（2026-09-09 会话：6 轮 run 修复链 + 全分支契约生成器）

> 背景：B-02 契约（C-01）api 通道自 BLOCKED 迭代至正式 PASS（run-20260909152211，P0/P1=0，
> 必测 1/1，对拍 OK diff=0+93 可审计豁免，版本绑定 PRI_PROCESS_000000001:12）。每轮 run-id
> 均落账（账本不可覆盖，重跑必新 run-id）。以下教训直接可复用于其余分支扩量。

- **L41 引擎必填校验三定律（api 通道表单提交）**（run-141848/145913 实锤）：
  ① 校验口径=「已保存 revision + 本次 formPatch 合并结果」——SUBMIT 不落业务表单（L35 的强化：
  即使先 SAVE_FORM 也只落场景给的 formData）；② **workbench 回显 formData=已保存单据数据，
  继承/公式值不在其中**（渲染层才有）——节点 10 必填 10 字段（FYDW/SHDW/FZ/DZ/KC/CYRQ/CS/
  GHZL/HCBZ/FYRQ）须在契约 steps[].form **一次性全量补齐**（值=同实例 00 步同源）；③
  **form 键一旦存在即走 SAVE_FORM 路径，echo_form_patch 不再生效**（run-145913：只补 ZJ 一字段
  → SAVE_FORM 只落 ZJ → 其余必填全裸奔报「发运日期为必填」）。引擎报错一次一个字段，勿逐字段
  盲试——用 workbench 的 formViewSnapshot.fields 实查 required/readonly/fieldCode 全集一次补齐
  （req+ro 字段提交不被拒，B-02 已验）。
  → contract-howto §取证坑 14 + gen-multibranch-contract.py _form_10/_form_35。
- **L42 表单回显继承时点差异=系统级表示层差异，豁免按稳定键批量**（run-150223 实锤 93 处）：
  老系统 getStepForm 不回显继承值（空）vs 新系统 workbench 回显已保存单据数据（含继承）——
  方向性 86 vs 7 两类。业务值同实例同源一致（00 环节原始值对拍不受影响）。处置=契约
  exemptions[] 可审计豁免（match=剥文件名前缀一次的稳定键 s1/QSF->QSF；1.3.0 起为八字段，
  含 approval_ref/source_run_id/source_compare_sha256_16 取证链），批量生成用
  `gen-multibranch-contract.py exempt --run-dir <run目录>`（旧 --compare 手写入口已移除）；
  **禁止预生成豁免**
  （无 run 证据=不可审计）。
- **L43 api 通道只采 fields 段**：契约声明 formulas/routing/buttons 维度 → compare-rules 带出 →
  采集无该段 → coverage BLOCKED（fail-closed 正确）。api 通道下三维度语义承载：A.6 公式结果由
  ZSJL 字段比对（tolerance abs:0.01）承载；路径一致性由 runner expectNext 逐环节验证承载；
  按钮可见集属浏览器通道边界（capture-channels §5）。立契时从契约移除该三段 + notes 声明承载关系。
- **L44 正式 PASS 的版本绑定**：conclude 强制 versions.source/target/flow 全部已记录（非
  unrecorded）——经 env `SOURCE_VERSION`/`TARGET_VERSION`/`FLOW_VERSION` 传入（write-manifest
  落账）。⚠ TARGET_VERSION 与 gate 证据 target_env 有同一性校验（设了 TARGET_VERSION 就必须
  与证据 target_env 一致）——统一用 `local-dual-run`；被测代码版本由 manifest.git_rev 自动记录，
  流程版本实查治理库部署回执（如 PRI_PROCESS_000000001:12）。
- **L45 迁移用户 API 权限点回填**（run-141217 实锤 403 workflow:task:view）：qianyi 迁移只迁
  组织/用户不迁角色权限——网关按权限码拦截 `/engine/flow/task/**`。修复=跑 qianyi 官方脚本
  `src/migrator/scripts/backfill_flow_participant.py --all`（BACKFILL_CONNINFO 显式注入；4549
  用户绑 FLOW_PARTICIPANT + 物化 sys_user_effective_perm，幂等可重跑）。新环境批量测试前置项。
- **L46 全分支契约生成器（数据驱动，分支数不写死）**：`scripts/gen-multibranch-contract.py`——
  从分支定义串（ast 解析，不执行目标文件）+ 已 PASS 基准契约 + 节点码补充映射（--node-map-extra，
  执行者实查后传）生成全正移分支契约（cases/steps/账号扩量/nodes 并集拓扑）；反向分支
  （RETURN:/WITHDRAW:/VOID@）自动分流出 explore 契约（守护规则 6）；未知环节名分支跳过进待核实
  清单（绝不猜码）；exempt 子命令批量生成可审计豁免。港口煤实查：18 正移 case 一次生成
  validate test_ready 全过 + 18 场景同源生成成功；5 反向分支待专项立契（--drill 演练）。
  → SKILL.md §工作流「多分支全量模式」。

## 7. 与 skill 资产的对应关系（执行者导航）

| 阶段 | 先读 | 实战依据 |
|---|---|---|
| 取证立契 | contract-howto.md（含 §取证坑 10~12 新增） | 铁路 D-19/P-1/P-2、公路 O-2 |
| 通道选择 | capture-channels.md §1 | 铁路 D-19、老系统抖动 |
| 浏览器执行 | browser-channel.md §4 SOP（G3.1~G3.6 + 宿主守卫 + 日期模型直写） | 港口 G3.1~G3.4、公路磅房弹窗、李雅庄 09-08/09 深夜轮（L27~L32） |
| 执行与结论 | execution-gate.md §5~§8（新增） | 港口完成判定、公路 R5/R6、铁路 09-09 |
| 环境排障 | 本文件 §4 + §6b | 铁路拉运日期、O-95306、铁路 P-2、老系统合同文件注册缺口 |

- **L47 按钮语义≠路由语义（api 通道退回/作废原语）**（run-20260910143759/145317 + 前端 JS 全量
  扫描实锤）：老系统退回（G5=backWorkflow）/作废（G6=cancelWorkflow）是独立端点+独立载荷，
  把退回编码成 commitWorkflow 的 next_step 提交会被拒「所选环节并不可用范围」——铁路 C-03/04/06/07
  两轮 BLOCKED 的共同根因。v1.3.5 落 `api.operations` 配置驱动原语：step.button 命中键 →
  改发专属端点；BACK 按钮配 backTarget 解析器（getWorkflowInstanceRecordsBack2 →
  data.stepInfo 按 stepCode 恰一命中，**列表非时间序**）+ ledger refetch
  （getCurrentUserProcessList 行无姓名字段 → 空 owner 通配，实例+环节绑定保隔离）。
  WorkflowFlag 的 FlowInsCode=FI 风格实例码（待办行 instCode 字段），非单据号 instanceNo。
  G5b 退回至矿点/盖章链仍浏览器兜底（跨实例语义，operations v1 不覆盖）。
  → capture-channels §5 operations 行 + f12-record §10 + assets/systems-api/legacy.yaml 注释。

## 6e. 引擎库重置再取证 + 迁移库选人体系（2026-09-10~12：公路 API 演练 / 港口煤 R27·R28）

> 来源三份执行记录：`docs/李雅庄公路流程/自动化测试/执行记录/2026-09-10-本地新系统API通道演练执行.md`
> （run-20260910140428/140909）、`docs/港口煤发运流程/自动化测试/执行记录/23分支自动化测试报告/
> 2026-09-11-…第27轮.md`、`2026-09-12-…第28轮.md`（浏览器 23 分支端到端，23/23 COMPLETED）。

- **L48 引擎库整库重置=通道配置三连过期，跑前必须重查回填**（公路 09-10 演练实锤）：本地库重置
  重部署后，发起 404「流程要素不存在」——实查发现 **LAUNCH_ELEMENT_ID（3249→174）、
  引擎流程码（PRI_PROCESS_…→PRI-PROCESS-…，todo 连字符/BPMN 下划线两形态不同源）、
  BPMN 环节码（task_3242 系→task_168 系）全部过期**，修复散落 `.env` LAUNCH_ELEMENT_ID_*
  与 runtime `todo.map.flowCode/stepCode` + `route_map`。且重置是**全流程性**的——铁路/港口
  映射同为重置前值，跑前不重查=诚实 BLOCKED。API 通道首跑 404/找不到流程类错误，第一反应
  查这三处是否还与部署 BPMN/可发起列表一致（→ contract-howto §取证坑 13 预检③④的极端形态）。
- **L49 按钮流必填字段在纯 API 通道无来源（边界再确认）**（公路 09-10 演练）：00 步必填
  HTH/LYL/JSL 等由**选择合同/磅房按钮流**带入，手填字段（FYDW/KC/MZ/日期等）API 可补齐
  但按钮流字段无 API 来源——current 侧 00 SUBMIT 400「必填字段未填写」10 项=诚实 BLOCKED，
  属 skill 发布说明明示的按钮流边界（浏览器通道兜底），不是通道缺陷；同 run legacy 侧全链
  6 步走通 → 双端一通一阻时先按边界归因，勿误判环境事故。
- **L50 契约特殊流转声明会"悄悄丢失"，执行前必复核**（公路 09-10 演练）：C-03/04/06/07 的
  `cases[].notes` 特殊流转声明（05→04 退回、00 作废→none）此前版本曾有、本轮执行时已丢
  （疑似手改契约回退）——路由一致性门禁（守护规则 6）FAIL→OK 的修复就是把声明补回。
  教训：退回/作废类用例每次 gen/validate 前先核对 notes 声明在场；门禁 FAIL 的修复方向
  是补声明而不是改路由。
- **L51 测试残留实例=生产/共享环境债务，当轮清点当轮清**（公路 09-10 + 港口 R27 双实锤）：
  演练/run 产生的孤儿实例（发起后中断在首节点）与中止重跑的废弃实例会滞留「进行中」列表
  （公路 2 条已作废；港口约 33 条待管理员批量作废）；老系统中断产生的**生产遗留单据**
  （@00 重办态/@05）须逐条登记去向。每个 run 收尾做一次实例清点（发起人+当日+流程编码过滤），
  该作废作废、该记录记录——否则污染待办复用（instancePolicy=reuse 恰一命中）与生产数据。
- **L52 迁移库 sys_user.id 空间整体变化 → 一切按 ID 引用办理人的配置全量失效**（港口 R27
  实锤 0/200 命中）：迁移后 `sys_user.id` 全新空间（如 hmliming1=8994），分支选人白名单
  DMN 246 条规则引用的 119 个旧 ID 全部成幽灵 ID——命中后返回幽灵 ID，前端候选回落全量池
  （按矿厂收敛的 1~4 人→几十人）。修复=从「当前 sys_user + 治理库当前 BPMN + 分支配置
  Excel」自动重制 DMN 并随迁移主管线收编发布（qianyi `branch-assignee-dmn` 阶段）。
  同理推及 skill 侧：`assignee.prefer_ids`、`actorMap` 姓名↔ID 一切经 whoami/实查取**当库**
  值，迁移后历史 prefer_ids 全部重验。
- **L53 候选收敛与办理人正确性可能不可兼得——白名单"优先覆盖"是双刃**（港口 R28 实锤）：
  DMN v2 修好候选收敛（G18/G19 恢复基线）的同时，BranchAssigneeRuleService「白名单优先」
  设计**强制覆盖**提交时的 nextAssigneeId——规则行错配/缺失（跨分支用户串行、整行缺失回落
  全量池）→ 页面选人被无视 → 办理人错配 ROW_NF。执行侧适配
  `RESUME_FOLLOW_ASSIGNEE=1`：每步执行前从 DB 读当前 PENDING 任务**实际 assignee** 作为
  办理账号（解改派后预期办理人不可见的死锁，7 分支以此办结）。映射到契约体系即：
  expectAssignee 断言失败时先分清「选人逻辑错」vs「服务端改派」，后者以 DB 实际 assignee
  为准修正场景而非硬改服务端。
- **L54 页面模式取姓名要 DB-first，Excel 对账要固化人工修正**（港口 R28 双教训）：
  ① `PAGE_ONLY=1` 下 `user_display_name` 恒空 → `select_assignee` 姓名匹配恒落空、每步
  兜底选面板首项——单人白名单碰巧对、多人白名单**随机落人**（水峪 01=[雷勇,杨帆,姚勇]，
  忠实来自 Excel，随机选中即错链）；修复=始终查 sys_user 取姓名（与 node_alive/flow_status
  同口径 DB-first）。② 迁移生成器（qianyi）重跑会**冲掉历史人工修正**（R29 对镇城底 12/15 的
  人工改派不在 Excel/BPMN candidateUsers，指派即不可办理死任务）——修正必须固化成生成器
  内的显式覆盖表（`MANUAL_HANDLER_OVERRIDES`，单测护住）再重制发布，"改库"不进版本=下次
  必丢。
