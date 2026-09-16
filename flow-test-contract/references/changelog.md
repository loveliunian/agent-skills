# changelog —— flow-test-contract 各轮演进史

> 本文件只做历史记录，不含操作性指令；现行规则以 SKILL.md 与各 references 为准。
> 各脚本头部注释含对应轮次的实现细节（如 pipeline.sh v2.x、field-level-compare.py v2.9 修复清单）。
>
> **版本规则（x.y.z，2026-09-09 定）**：skill 版本号在 SKILL.md frontmatter `version`。
> **默认只升 z**（修订：bug 修复、门禁加固、文档/回归补齐——绝大多数改动属此类）；
> **仅重大升级升 y**（新增子命令/新通道/新执行模式等能力面变化，且 z 归零）；
> **x 仅在使用者特殊指定时升**（不得自行升主版本）。
> 历史：0.x 为 EXPERIMENTAL 期（格式 `0.<轮次>.<轮内修订>`），1.0.0 起脱离实验状态。
> 升版同时必须重跑 `sync-to-tools.sh`（发布门禁 `--check` 全绿），并在本文件登记条目。

## 1.7.3（2026-09-13·审计第 12~14 轮收尾：租约冲突 e2e/库存反向完整性/相对路径统一，负向回归 410→415）

- **P0 租约冲突分支真正生效**：第 14 轮后复查发现 init/claim 钩子整体落在 pipeline
  if/else 之后（死代码）+ finish_block 定义后置（claim 调用报 command not found 后继续）——
  审计实锤后整体重建：finish_block 定义/mkdir/init/claim 恢复到契约模式之前的正确位置
  （claim 冲突 → finish_block 先于 runner，双端流程不再启动）+ selftest 新增 **e2e 回归**：
  沙箱预置冲突租约 → pipeline exit 2 + summary=BLOCKED + field-captures 不存在（runner 未启动实证）；
- **P0 库存反向完整性**：validate 新增反向校验——每个库存条目须有 ≥1 个覆盖要素挂靠
  （source_ref 指向它），否则"来源全量"仍是假象；import-inventory 补齐后通过（正反双向回归）；
- **P1 相对 source_inventory 路径统一**：validator 与 conclude_core 深度校验均传入
  manifest_path（按账本目录解析）——CWD 无关（回归：同目录摆放从项目根校验通过）；
- **P1 init 缺 --contract**：_hosts 恒初始化（此前 UnboundLocalError exit 2）。

## 1.7.5（2026-09-13·审计第 17 轮：1.7.4 七项验证 7✅ + 覆盖评估 except 分支防御纵深，负向回归 417→418）

第 17 轮子代理逐项实证 1.7.4 全部落地（fail-open 封堵三分支/租约 e2e runner 未启动/库存反向/
相对路径/init 缺参/黄金回归/两类 PASS 语义保持），唯一 P2 收尾：

- **P2-1** conclude_core 覆盖评估 except 分支形态 fail-open（只 append reasons 不降级——
  与 declared_missing/invalid 两分支显式降级模式不一致；当前无自然触发路径，属防御纵深）
  → except 分支补 `conclusion=BLOCKED` 降级 + coverage_info 补 declared/scope 字段；
  selftest X2d 钉扎（monkeypatch validate 抛异常 → BLOCKED + 原因在场）。

## 1.7.4（2026-09-13·审计第 12/16 轮收尾：结论期 fail-open 封堵 + 租约 e2e + 库存反向，负向回归 410→417）

三处审计发现全量落地：

- **P0 结论期覆盖门禁 fail-open 封堵（审计第 16 轮）**：declared_missing 与"账本结构
  非法/库存反向完整缺口"两分支此前只 append reasons 不降级 conclusion（全绿证据链 +
  坏账本 → PASS 照出）→ 两分支显式 `conclusion=BLOCKED`（scope=partial）；同时把
  结论期 validate 收敛为**单一全量校验**（结构+深度绑定+库存挂靠+反向完整性），
  inventory 按声明路径加载（相对账本目录，与 validator 一致）；run_evidence/gen-final-report
  共用同一评估器自动继承。
- **P0 租约冲突分支真正生效（审计第 12/14 轮）**：pipeline init/claim 钩子此前落在
  if/else 之后（死代码）+ finish_block 定义后置（claim 调用 command not found 后继续）→
  整体重建区域顺序（mkdir→init→gate-evidence→finish_block→claim→契约模式）；
  selftest 新增 **e2e**：预置冲突租约 → pipeline exit 2 + summary=BLOCKED +
  field-captures 不存在（runner 未启动实证）。
- **P0 库存反向完整性**：validate 新增反向校验——每个库存条目须有 ≥1 个覆盖要素挂靠，
  缺失即拒；conclude 结论期同源拒绝（selftest X2/X2b/X2c 三态：孤儿拒/导入补齐/闭环恢复 PASS）。
- **P1×3**：相对 source_inventory 路径统一按账本目录解析（validator/conclude_core 传
  manifest_path，CWD 无关）；test-data-ledger init 缺 --contract 的 UnboundLocalError
  修复（_hosts 恒初始化）；readiness 两处死循环清理。
- selftest 410→**417**（租约 e2e/库存反向三态/相对路径/init 缺参等新钉扎）。

## 1.7.2（2026-09-13·覆盖结论期闭环 + 租约排他阻断 + 资源 URL 白名单，负向回归 405→410）

外部审计 P0×2 + P1×3 + P2×1 全量落地（第 14 轮独立验证 8/8 ✅）：

- **P0-1a 结论期深度校验**：conclude_core 覆盖门禁补 load_contract_full →
  validate(cm, contract)——伪造 contract_key 的 covered 在最终结论阶段现形 BLOCKED
  （此前只 validate(cm) 可绕过 field/formula/button 深度绑定）；
- **P0-1b 覆盖账本随 run 快照**：pipeline 解析契约 meta.coverage_manifest.path →
  write-manifest --extra-file coverage_manifest=<绝对路径> 入账；conclude_core 结论期
  复核快照哈希——运行后修改账本在结论（BLOCKED）与报告（拒绝/草稿）两处现形；
- **P0-2 租约排他阻断**：pipeline claim 冲突此前仅告警仍继续执行（两 run 并发污染同一
  fixture/resource 可能各自 PASS）——正式 run 一律 finish_block（--drill 降级告警）；
  claim 回执经账本 events + --extra-file 入证据链；
- **P1-1 库存指纹严格比对**：source_hash 必须与库存登记相等（此前只查非空——伪造
  FORGED-HASH 可过），不等即拒（"指纹伪造/过期"）；
- **P1-2 浏览器探索去重改 id 唯一键**：此前按 (kind,name) 去重——不同页面同名按钮互吞；
  改按要素 id（含页面 label+序号），跨页同名全保留（实测 3 元素全入）；
- **P1-3 资源 http check 白名单**：主机必须 ∈ 契约 environments 声明（init 登记
  allowed_hosts）——未声明地址（含 loopback/私网）一律 unknown；禁重定向
  （HTTPRedirectHandler 拒绝——重定向=白名单绕过面）；
- **P2 VERSION 溯源**：六个 v1.5/v1.7 期脚本 VERSION 串统一刷至当前版本；
- selftest 405→**410**（结论期深度绑定/运行后账本篡改拦截/库存指纹伪造/白名单外主机/
  pipeline 租约阻断声明/跨页同名去重等新钉扎；落地中引入的 2 处 UnboundLocalError 被
  selftest 即时拦截修正）。

## 1.7.1（2026-09-13·审计第 11 轮：v1.7.0 七项验证 7✅ + F11-1~F11-3 修复）

第 11 轮子代理逐项 mock 实证：深度绑定 7/7 拒/过正确、promote 全链核验五重、check 白名单
（自由文本零执行哨兵实证）、库存 reconcile/挂靠、租约四态、readiness 四探针、黄金链全通——
主体全 ✅。修复 3 项收尾：

- **F11-1/P1** coverage_manifest.py / test-data-ledger.py 缺 `sys.dont_write_bytecode`
  （promote/claim 动态加载 conclude_core/run-contract-scenarios 在唯一事实源落 __pycache__）
  → 两入口补齐（实证直跑零残留）；
- **F11-2/P2** readiness browser 探针死代码行 + runtime 根解析失败时 `_rt=None` TypeError
  （traceback exit 2 而非产出缺口报告）→ 删死行 + `_bfiles` 空守卫；
- **F11-3/P2** promote ③ 此前信任 summary.json 的 coverage_scope（单文件篡改面）→ 改
  **重算口径**（对真实契约二次 evaluate 取 coverage_info.declared/scope；summary 自述不作数；
  partial run 本就是合法晋升对象——重算语义下伪装 full/BLOCKED 均无任何额外效力；
  1.7.1 复审确认落地 + selftest G4b 钉扎）。

## 1.7.0（2026-09-13·覆盖证据闭环：深度绑定/来源库存/promote 全链核验/资源治理白名单，负向回归 397→405）

外部审计 P0×3 + P1×3 全量落地（能力语义变化 → 升 y）：

- **P0-1 covered↔契约对象深度绑定**：covered 元素按 kind 绑定到契约真实对象——
  field→field_mappings（contract_key 必须命中 legacy/target 字段）、formula→公式 id、
  button→node ∈ buttons 断言、branch→node ∈ routing、resource→resources id、
  post_flow→post_flow.code；scaffold 自动产出 contract_key/node。"契约无该维度合同却标
  covered"从此不可能通过校验——covered 只证明挂到某一步的时代结束。
- **P0-2 promote 全链核验**：任意"summary=PASS 的无关目录"不再能关闭覆盖缺口——五重校验：
  ①中性化重算（去除覆盖门禁后执行面必须全 PASS——解决"run 必然 BLOCKED 才有缺口"的
  鸡生蛋）；②run 账本契约哈希与本契约一致（不许跨契约）；③coverage_scope 必须 declared
  partial/full；④contract_ref 的 case 在 case-results PASS 集合；⑤双端 capture 存在且
  channel 与要素一致（浏览器要素必须浏览器通道 run）。promote 按钮类要素 node 自动从
  目标步骤派生。
- **P0-3 资源 check 白名单适配器**：移除 shell=True + 自由文本命令（此前 touch 等任意命令
  可执行）——check 改结构化 `{kind: sql|http, adapter, params, expected}`；sql 走内置模板
  （标识符白名单 + env FLOWTEST_SQL_DSN_<ADAPTER> + uv oracledb）；http 只读 GET + expected
  子串；自由文本/未知 kind/非法标识符一律 unknown 不执行。
- **P1 来源库存（source inventory）**：`load_inventory`（items 必带 source_hash 指纹）+
  `import-inventory` 子命令（reconcile：缺项补 uncovered must-cover 含 source_ref/source_hash；
  dimension 按 kind 派生）+ 校验（账本声明 meta.source_inventory 后，全部 must-cover 逐条
  挂靠 source_ref∈库存 且 source_hash 非空）——"人工列出的集合已闭环"升级为"真实流程
  集合已闭环"的证据形态（Excel/BPMN/flow-tables 导出器按 inventory schema 接入即可）。
- **P1 租约 registry（跨 run 排他）**：`claim`/`release` 子命令 + 项目级 runtime/leases.json
  （O_EXCL 锁 + 原子替换）：同 id 活跃租约且 owner 不同 → 冲突拒绝；readiness 新增租约
  冲突探针（data 域 task 缺口）；pipeline claim 钩子（advisory）。
- **P1 readiness 浏览器/租约探针**：browser 承载需要时校验配置存在与 __UI_RECORD__ 残留；
  租约冲突入 task_items。
- selftest 397→**405**（深度绑定正反/库存 reconcile+挂靠/租约四态/http verify 实测/
  写命令守卫/黄金链两类 PASS 端到端）。

## 1.6.1（2026-09-13·审计第 9 轮：1.6.0 十项验证 9✅1⚠ + F9-1~F9-3 修复，负向回归 396→397）

第 9 轮子代理对 1.6.0 逐项 mock 实证：P0-1 两类 PASS 语义/P0-2 深度校验/P1-1 相对路径/
P1-3 浏览器队列/P1-4 数据治理/黄金链全部 ✅；修复 3 项收尾：

- **F9-1/P1** readiness `--live-readonly` 恒 NameError（ftc_env 未导入）→ 补共享模块导入 +
  selftest 新增活体回归（mock 计数：login/todo 各 2、launch/submit=0——只读承诺钉扎）；
- **F9-2/P2** explore-browser md 文案"must_cover=false"与实际 true 矛盾 → 修正；
- **F9-3/P2** write-manifest jsonschema 版本读取改 importlib.metadata（Py3.13 弃用警告）。

## 1.6.0（2026-09-13·任务完成门收紧：两类 PASS 语义/深度校验/资源治理三态，负向回归 387→396）

外部审计 P0×2 + P1×4 + 黄金链验收 全量落地（能力语义变化 → 升 y）：

- **P0-1 两类 PASS 语义**：conclude_core 对**未声明覆盖账本**的契约输出
  `coverage_scope={declared: false, conclusion_scope: contract_scope_only}`——PASS 合法但
  仅代表"已声明契约范围"，报告显式标注"不构成全流程双端 PASS"；声明且全闭环才是
  full（全流程）。validate-contract 新增 `--require-coverage`（新契约立契口径：TEST_READY
  强制 meta.coverage_manifest；存量迁移期默认告警不拒）。**始终输出 coverage_scope**
  （未声明不再是 None 静默），summary.coverage_scope 进防篡改面。
- **P0-2 covered 深度校验**：contract_ref 解析为 `case[/s<序号>]` 结构化引用——case 存在、
  step 存在且不越界、元素 node 与步骤节点一致、kind↔dimension 映射一致、**covered 必填
  evidence（run-id/探索 id）**、**not_applicable 必填 reason+evidence（来源依据/审批引用）**；
  validate/readiness/coverage check 全部带契约深度校验——账本不能再"挂在任意合法 case 上"。
- **P1-1 相对路径统一解析**：coverage_manifest.resolve_path（唯一实现）——validator/
  conclude_core/readiness/draft 产出一律按**契约所在目录**解析相对账本路径（此前按 CWD，
  文档推荐的相对写法实际不可用并会阻断 draft 骨架）。
- **P1-2 readiness 任务级判定**：两级输出 static_ready（配置/环境）/task_ready（+覆盖账本
  闭环/gate 证据需求（契约 gates 带 evidence_schema 即需要）/浏览器承载（配置缺失或
  __UI_RECORD__ 残留=缺口）/--live-readonly 活体检查（api 登录+待办 GET，不发起实例））；
  exit 0=两级就绪 / 1=静态缺口 / 3=仅任务级缺口；与 conclude 的 coverage blocker 同源一致。
- **P1-3 浏览器完成队列闭环**：explore-browser 登录候选改用**登录前快照**（业务页输入框
  不再可能充当 userRef/passRef）；coverage_elements 升格 ready_for_browser_run/must_cover=true；
  新子命令 `coverage_manifest.py import-browser-explore`（去重导入完成队列）与 `promote`
  （浏览器正式 run **PASS** 后 → covered，evidence=run-id，深度校验在场）。
- **P1-4 数据账本资源治理**：claim 带**租约**（owner/expires_at/exclusive）；close 三态
  released/residual/**unknown** 严格分开——**未 --verify 确认资源真实释放的 PASS 实例只标
  unknown 不标 released**；--verify 执行契约 resources[].check 只读查询（写关键词守卫拒绝）；
  账本 sha 经 write-manifest 新参数 `--extra-file` 入 run manifest 证据链（pipeline close
  前置到落账前），清理痕迹不再游离于证据链外。
- **黄金链回归**（selftest 387→396）：相对路径正反向/幽灵 step/两类 PASS/conclude 与
  readiness blocker 同源/import 去重+未 run 保持 partial/promote evidence/资源写守卫/
  --verify 三态等 9 条新钉扎。

## 1.5.0（2026-09-13·任务完成门六件套：覆盖账本/浏览器探索/readiness/数据账本/DRAFT 骨架/重跑计划）

能力面升级（新子命令×5 + 结论门禁一处 → 升 y）。核心转向：从"单点防护"到"任务完成门"——

1. **覆盖账本（coverage-manifest.yaml，门禁接入结论链）**：`scripts/coverage_manifest.py`
   （scaffold/check 唯一实现）逐项登记 来源→契约 contract_ref→比较维度→通道→状态
   （covered/expected_gap/ready_for_browser_run/uncovered/not_applicable，must_cover 布尔）。
   契约 `meta.coverage_manifest` 声明后 conclude_core 自动启用：存在未闭环 must-cover →
   PASS 降 BLOCKED（coverage_scope=partial，blocking_ids 入 reasons）——契约遗漏不再能伪装
   "全流程双端 PASS"；summary.coverage_scope 进防篡改面（gen-final-report 与 conclude_core
   重算比对），最终报告 §2 渲染覆盖摘要与未闭环清单；validate-contract 联动校验（账本存在/
   结构合法/covered 的 contract_ref 指向真实用例）。未声明账本的契约行为不变（向后兼容）。
2. **浏览器只读探索**：`explore-channel.py explore-browser`——登录→a11y 快照解析（可见按钮/
   输入框/下拉/链接/标题）→截图；**零点击零填写**（登录除外）；产出 探索发现-browser-*.md +
   `ui-record-candidates-*.yaml`（__UI_RECORD__ 候选，人工核对后才可入正式配置）+
   coverage_elements 草稿——按钮流从"已知 BLOCKED"变有截图/ref/账本要素的显式完成队列
   （expected_gap → ready_for_browser_run → covered）。
3. **live readiness**：`scripts/readiness.py`（只读零副作用）按用例体检：双端 actor 凭据 env、
   发起要素 env、systems 配置结构（复用 legacy-config-check）、reuse 选择器、step.button 的
   operations 承载、gate 证据时效——未就绪给精确原因+责任域（env/config/contract/data/
   evidence），不再等跑完整条链才发现缺按钮/账号/数据。
4. **测试数据账本**：`scripts/test-data-ledger.py`（init/record/close/show）+ pipeline 自动
   挂钩（best-effort 不阻断）：run 前 fixtures/resources claim → 采集后从 field-captures
   实读双端实例号 → 结论后逐 case released/residual + safe_to_clean 清单（仅列本 run launch
   的实例与建议动作，**绝不自动执行破坏性清理**）。
5. **DRAFT 骨架**：`scripts/draft-contract.py`——experience.yaml → 受控 DRAFT 契约
   （同名/归一化建议进 field_mappings；未覆盖字段/按钮/公式/分支全进 risk_seeds TODO；
   status 恒 DRAFT 永不越权 TEST_READY）+ coverage-manifest-draft.yaml（探索未覆盖字段一并
   列 uncovered must-cover——骨架即诚实，不允许默认 covered）。
6. **重跑计划**：`scripts/rerun-plan.py`——BLOCKED/FAIL run → 逐项（阻塞原因/失败用例/语义
   差异/未过 gate）→ 责任域（env/config/data/contract/evidence/product）→ 修复动作 → 验证
   命令；rerun_of 绑定源 run-id、new_run_id_required 恒 true；只读预检清单可复用，
   **绝不拼接不同 run 的执行 PASS 形成正式结论**。

## 1.4.6（2026-09-12·审计第 5 轮验证 10/10 ✅ + P2×3 收尾，负向回归 370→373）

第 5 轮子代理对 1.4.5 全部 9 项修复逐一 mock 实证验证通过（数字键拒/refetch 先拒后写/
retryOn 阻断/严格谓词/空办理人 submit 前中断/脱敏/探针上下文/选择器链 live 命中/防覆盖），
无 P0/P1；3 项 P2 当轮收尾：

- **P2-1** `_business_failed` 未配置 successValues 时改**恒等判定**（`is not True`）——
  此前 `not in [True]` 受 `1 == True` Python 陷阱影响会默认放行 success:1/1.0，
  与"默认仅布尔 True"口径不符；
- **P2-2** selftest 补 successValues 可配置两态（[true,1] 时 success:1 成功、success:"false"
  仍失败）；
- **P2-3** submit.successValues 配置非列表/空列表 → 启动即拒（fail-closed 配置纪律，
  不静默回退默认口径）。

## 1.4.5（2026-09-12·外部审计 P0×2 + P1×3 + 改进×4 全量修复，负向回归 360→370）

外部深度审计（本地 mock 实证）逐条修复：

**P0-1 既有 API 提交漏洞闭环（四子项）**：
- `ftc_ops_config.validate_operations` 此前 `str(button)` 强转——YAML 数字键过 schema、运行时
  字符串命中永不命中 → 静默回退统一 submit。现键须**原始字符串类型**，否则入口即拒；
- `_submit_operation` 此前 ledger=refetch 且 BACK_NODE 为空时**先发 /backWorkflow 再拒绝**
  （生产已退回本地才报错）→ 定位键（BACK_NODE/INSTANCE_NO/task_id）在任何写请求前全量验证；
- retryOn 前置按钮响应（_st/_ob）此前被丢弃——前置 SAVE 失败、重试 SUBMIT 200 仍报成功 →
  前置复用 `_resp_bad`，失败即 die 禁止重试 SUBMIT；
- 业务失败判定此前只认 `success is False`——success:0/"false"/""/None 等 falsy 变体被当成功 →
  严格谓词 `Api._business_failed`（success 键存在但值 ∉ successValues 即失败；默认仅 True，
  systems `api.submit.successValues` 可配置兼容 1/"true" 型系统）。全文件 5 处判定统一收口。

**P0-2 探索器空办理人自动提交**：无候选办理人时此前仍提交空值（生产默认分派=非预期流转）→
拒绝空办理人并在 api.submit 前中断；`--apply` 默认 `--advance none`（只采集不推进）；`--apply`
必须显式 `--actor`（写操作可追溯）；新增 `--route`（须在系统实时候选内，不探索性猜路由）与
`--assignee`（显式兜底）。

**P1×3**：
- 探索产物敏感值泄露：默认脱敏 `#sha16:长度`（空值 ∅ 锚点使 merge 同值判定在脱敏串上仍成立；
  探针 outputs 同步脱敏）；`--include-values` 才保留原值且产物标记 `includes_sensitive_values`+
  醒目警示（放私有 runtime 勿提交/同步）；
- 公式探针读回缺实例上下文（WorkflowFlag 系统读回失败/读错）→ form_fields 读回与标准执行
  路径同参（INSTANCE_NO/FLOW_CODE）；
- reuse 消歧选择器生成链补全：契约 schema cases 增 instanceNo/businessKey/fixtureSelector
  （标量或 {legacy,current} 分侧映射）+ 模板说明 + gen 确定性透传场景（仅 reuse 策略；非法
  分侧值生成期即拒）+ api-capture 按 systems id 取本侧值（缺侧=诚实拒绝，不跨侧借用）。

**改进×4**：探索产物防静默覆盖（本侧实录/经验库/立契建议已存在即拒，`--overwrite` 放行）；
adversarial-regression "342 条"改动态口径并补提交漏洞闭环族/探索器安全族两条；项目 AGENTS.md
版本口径更新；SKILL.md v1.3.6 加固段压缩下沉（防伪造关键口径保留）。

selftest 360→**370**（新增：数字键拒/success:0 拒/retryOn 前置阻断/apply 缺 --actor/默认脱敏/
防覆盖/空办理人 submit 前中断/选择器生成链正反向 ×2 等回归；mock 修复：_start5 ensure_ascii）。

## 1.4.4（2026-09-12·独立审计第 3 轮：第 2 轮 8 项全到位 + R3-1~R3-3 修复）

第 3 轮收敛验证（新会话）：第 2 轮 8 项修复逐项实测全部到位（含 F1 降级不误伤三种正常场景、
F3 过滤器对分隔行变体健壮、experience.yaml round-trip 保真）；新发现 3 项当轮修复：

- **R3-1/P1 字节码防护同类漏网第三/四入口**：api-capture.py 与 legacy-config-check.py 在
  sys.path.insert 后直接 import 兄弟模块（ftc_env/ftc_ops_config），实跑即落 scripts/
  __pycache__——第 1 轮 P1-3、第 2 轮 F2 的同类缺口（selftest 的 PYTHONDONTWRITEBYTECODE+
  atexit 清理掩盖了直跑面）→ 两入口各补 `sys.dont_write_bytecode = True`；
- **R3-2/P2 exit 130 未进文档口径**（F5 修复引入的文档漂移）→ explore-channel docstring 与
  exploration.md §2 各补一行"Ctrl+C → 落盘后 exit 130"；
- **R3-3/P2 system_field_changes 未进手册**（F7 修复引入的文档漂移）→ exploration.md §1
  补半句"系统维护字段单列，不算公式候选"。

## 1.4.3（2026-09-12·独立审计第 2 轮：上轮 13 项复核全到位 + 新发现 P1×2/P2×6 修复）

第 2 轮子代理复审（新会话）：上轮 13 项修复逐项复核全部到位；新发现 8 项当轮修复：

- **F1/P1 merge 跨环节对齐降级**：双端同 seq 但环节不同（一端中断/路由分歧为探索常态）时，
  同名字段可能属不同环节——该节点映射建议一律降级 suggest=false（仅提示），experience.yaml
  落 node_mismatch 标记，立契建议.md 显著警示"禁止直接纳入契约"；
- **F2/P1 browser-capture.py 缺 dont_write_bytecode**（P1-3 同类第四入口漏网，实跑即落
  scripts/__pycache__）→ 入口补齐；
- **F3/P2 报告 §8 人工发现行过滤**用"编号"全文子串匹配——正文含"编号"二字的合法人工行被
  静默丢弃 → 改精确跳表头/分隔行；
- **F4/P2 探索 md 表格转义**（竖线/换行破表，P2-13 同类最后死角）→ _esc_md 统一转义；
- **F5/P2 探索循环不覆盖 KeyboardInterrupt**（Ctrl+C 丢已采集经验）→ 转 interrupted 落盘后
  exit 130；
- **F6/P2 exploration.md §3 命令块不自含**（缺 RUNTIME_DIR/FTC_PY）→ 补齐；
- **F7/P2 公式探针 outputs_candidates 未滤系统字段**（更新时间/修改人类保存副作用被误列为
  公式候选）→ 复用排除启发式分流出 system_field_changes（保持透明）；
- **F8/P2 MANIFEST 不覆盖 references/**（前置检查对引用文档缺失零覆盖）→ 10 个 references
  以空目标行列入清单。

## 1.4.2（2026-09-12·独立审计第 1 轮：P1×6 + P2×7 全量修复，负向回归 358→360）

子代理独立审计（只读+实跑）逐条修复，无 P0：

- **P1-1** api-capture.py 残缺的重复 `class Api` 定义（被第二个定义整体遮蔽的死代码/误编辑
  地雷）→ 删除；
- **P1-2** gen-final-report 未核验草稿（--allow-unverified）也渲染自信的"一句话结论"，为伪造
  summary 背书 → `verified` 为假不渲染；
- **P1-3** explore-channel/field-level-compare/gen-final-report 动态加载共享库时向 skill
  scripts/ 落 `__pycache__`（违反零副作用承诺）→ 三脚本入口 `sys.dont_write_bytecode = True`；
- **P1-4** 探索器中途 die()/网络异常 → exit 2 零产物，已采集经验全部丢弃（与 docstring/
  exploration.md"探索可中断 exit 0"口径不符）→ 循环体整体包裹：SystemExit/Exception 一律转为
  `interrupted` 如实记录后照常落 explore-<side>.json + md（exit 2 保留给配置/凭据/launch 失败）；
- **P1-5** `_PROBE_EXCLUDE_RE` 的 `| remark` 带前导空格 → 英文备注字段（REMARK/mail_remark）
  排除失效，--fill 会向业务备注写探针脏值 → 修正正则；
- **P1-6** resolve_assignee→assignee_candidates 重构（1.4.0）无负向回归钉扎 → selftest 新增
  2 条 mock 回归：orgrole 同名双候选 prefer_ids 指认/无指认透传 + next-assignees
  routeCode→taskElementId 编码回退（查询序列精确断言）——产品行为验证等价，测试夹具修正后全绿；
- **P2-7/8** README 过期数字（342 条回归/速查 24 条/全文 40 条）→ 动态口径 + 27/54；
- **P2-9** SKILL.md 工作流 0.5 块缺 FTC_PY 定义（违反"命令块自含变量"自约定）→ 补齐；
- **P2-10** 差异分组用例名混入采集文件名 .json 后缀（"### 用例 C-01.json"）→
  fc_readability.diff_case 统一剥后缀；
- **P2-11** 立契建议.md 块引用两行被隐式字符串拼接 → markdown 引用失效 → 拆分；
- **P2-12** `--fill --observe-only` 组合静默忽略 --fill → 互斥即拒；
- **P2-13** 表格转义缺口：_md 不转义 `|`（值含竖线破表）、gen-final-report 维度/原因翻译输出
  未过 esc → 双侧补齐。

## 1.4.1（2026-09-12·实战经验补齐：公路 API 演练 / 港口煤 R27·R28 → lessons-learned §6e）

文档/经验补齐（z 升版）：把 2026-09-10~12 三份执行记录中尚未入册的实战经验抽取为
lessons-learned **§6e（L48~L54）**，速查 24→27 条、全文 40→54 条：
L48 引擎库整库重置=元素ID/流程码/环节码三连过期（跑前必重查）；L49 按钮流必填字段纯 API
无来源（边界再确认，一通一阻先按边界归因）；L50 退回/作废用例 notes 特殊流转声明会悄悄
丢失（执行前必复核）；L51 测试残留实例当轮清点当轮清（生产遗留逐条登记）；L52 迁移库
sys_user.id 全新空间→prefer_ids/DMN 白名单一切 ID 引用全量失效（当库实查）；L53 白名单
"优先覆盖"下候选收敛与办理人正确性不可兼得（RESUME_FOLLOW_ASSIGNEE=按 DB 实际 assignee
续跑）；L54 页面模式取姓名 DB-first + 迁移生成器人工修正须固化覆盖表（MANUAL_HANDLER_
OVERRIDES），改库不进版本=下次必丢。

## 1.4.0（2026-09-12·对比结果人话化 + 首次对比自由探索）

能力面升级（新增子命令/新产物 → 升 y）：

- **对比结果人话化（给人读）**：最终报告 `对比测试报告.md` 新增「一句话结论」（三态事实的
  人话陈述，数值仍全部取自 conclude_core 重算）；FAIL 时结论速览附最多 3 条差异人话摘要；
  §3 用例总表加状态徽标；§4 语义对拍明细**按用例分组**、维度中文化、原因人话翻译
  （null_policy→空值不一致 / tolerance→数值超容差 / 新老计算值不一致→同公式双端结果不同…）。
  `field-compare.md` 同步重排（BLOCKED 最前 + 按用例分组）。翻译唯一实现为新共享库
  `scripts/fc_readability.py`（gen-final-report 与 field-level-compare 共用，禁止两套）；
  **机器证据字段（json）零改动**——人话只改"说法"，事实仍以 json 与 conclude_core 重算为准；
  field-level-compare VERSION 与 write-manifest COMPARATOR_VERSION 同步 v2.11
  （此前文档头 v2.11/常量 v2.10 漂移一并修复）。
- **首次对比自由探索（冷启动）**：新脚本 `scripts/explore-channel.py`（explore/merge 两子命令）。
  新流程初次对比前双端各探一次：采集**点击（配置已知按钮面）/选择（workbench nextNodes +
  form.nextStepPath 路由候选 + 办理人候选名单）/填写（每节点全部表单字段与值）/公式计算
  （探针法：数值字段填探针值→预保存→读回→变化字段=公式输出候选）**四类过程经验；
  merge 把双端实录按 step 对齐成经验库 `experience.yaml`（field_mapping_candidates：
  同名/归一化同名自动纳为建议、同值巧合仅提示、其余列 needs_human + contract_suggestions）
  与人读 `立契建议.md`。铁律：经验库是**第四取证源（参考物）**，不是契约更不是结论——
  正式对比仍走既有立契→校验→生成→pipeline；探索默认只读（--observe-only），
  写探索显式 `--apply`（写门槛前置到任何登录/网络动作之前），公式探针再显式 `--fill`；
  launch-first 实例隔离复用 api-capture 同一实现（新提取 `Api.assignee_candidates` 共享方法，
  resolve_assignee 行为不变）；探索可中断且中断原因如实记录（exit 0），
  配置/凭据/launch 失败才 exit 2。手册：references/exploration.md。

## 1.3.6（2026-09-10·operations 配置前置校验 / reuse 消歧 / 预保存失败 / 证据链与报告加固）

外部对抗审计六项发现逐条封死（P0×3 / P1×2 / P2×1）：

- **P0 operations 配置在写请求之后才验证**：`api-capture._submit_operation` 先调用操作端点、
  第 822 行才检查 ledger/refetch。实测缺 refetch 配置时老系统已完成退回（`/backWorkflow`）才报
  `MISSING_REFETCH_AFTER_MUTATION`，本地账本还提前删了原任务；同一入口另有三个漏洞：命中键
  条目非对象时 `submit()` 静默回退统一 commitWorkflow、`ledger: reftch` 拼写错被当 finish、
  backTarget 命中行缺 idField 会发送字符串 `"None"`。修复：
  ① 抽取共享模块 `scripts/ftc_ops_config.py`——`validate_operations`/`validate_operation_entry`
  在任何登录/发起/提交**之前**全量校验 path/ledger(仅 finish|refetch)/refetch/backTarget/
  successStatus/body，命中键但非法即 die 且**禁止回退统一 submit**；
  ② `legacy-config-check.py` 并入同一份校验（此前完全不校验 operations，坏配置仍报"结构完整，
  可启动 api-capture"）；
  ③ 标量守卫：解析出的 BACK_NODE/BACK_TARGET/taskId 必须为非空有效标量，拒 None/''/'None'；
  ④ `refetch.pollSeconds` 有限轮询——操作成功但退回后任务异步未现时不立即 BLOCKED。
- **P0 instancePolicy=reuse 任取第一个同流程待办**：`find_task` 在未知实例号时只校验节点+流程
  编码即返回首个匹配——实测两个同流程同节点任务（REAL-PROD-TASK/FI-PROD）会被采集并提交。
  修复：收集全部候选后**必须恰一命中**，多候选一律 BLOCKED；场景可声明 instanceNo/
  businessKey/fixtureSelector 消歧（后二者的待办字段路径由 systems `todo.selectorPaths` 指认，
  缺失即 fail-closed）。
- **P0 表单预保存失败仍返回提交成功**：`save_with_form_data` 调用 `_post(pre_body)` 却忽略
  返回状态——实测 SAVE_FORM→HTTP 500、SUBMIT→HTTP 200，最终 RETURNED_SUCCESS（场景输入未落库
  却假 PASS）。修复：预保存复用正式提交的 HTTP 状态/业务状态校验，失败即 die 且禁止发送 SUBMIT。
- **P1 删除账本中的契约登记仍被接受**：`run_evidence.verify_run_dir` 只在 contract 条目存在时
  校验，删掉 `config_snapshot.contract`/`evidence_paths` 的手改 manifest 仍通过；`manifest_sha256`
  仅检查非空。修复：强制契约模式账本固定最小键集合（contract/rules/scenarios）+ 非空
  evidence_paths；`toolchain.manifest_sha256` 须匹配 `^[0-9a-f]{64}$`。
- **P1 正式报告只比对 conclusion，其余 summary 统计可伪造**：保持真实 conclusion=FAIL、只改
  P0/P1/用例数即可生成"已核验"报告。修复：报告数值一律取自 `conclude_core.evaluate()` 重算结果；
  summary 中出现的 canonical 统计字段与重算不一致即核验失败（exit 2）；`--allow-unverified` 只写
  `对比测试报告-未核验草稿.md`，机器字段 UNVERIFIED，PASS 仅标"summary 自述"。
- **P2 版本与文档漂移**：README/项目内使用说明仍写 v1.3.4；adversarial-regression 回归计数
  305 陈旧；SKILL.md 顶部堆叠四版发布历史（~1482 词）——收敛为"当前能力 + v1.3.6 加固 +
  威胁模型边界 + 遗留边界"，历史全部下沉本 changelog；版本号统一 v1.3.6。
- **回归**：新增 P0/P1 负向回归（配置前置 die 且零请求 / 拼写错 / 缺 refetch / 缺 idField /
  refetch 轮询 0→1 / 多候选 BLOCKED / 选择器消歧 / 无 selectorPaths 拒绝 / 预保存失败不发
  SUBMIT / 删除契约登记 / evidence_paths 清空 / 伪造 manifest_sha256 / 伪造 summary 统计），
  全量 selftest 327→342。

## 1.3.5（2026-09-10·按钮语义原语：api.operations 退回/作废配置驱动）

- **根因（铁路 C-03/04/06/07 两轮 BLOCKED）**：老系统退回（G5）/作废（G6）是独立端点与载荷
  （`backWorkflow` / `cancelWorkflow`），把按钮语义编码成 commitWorkflow 的 next_step 提交被
  服务端拒「所选环节并不可用范围」——取证=前端 JS 包 1757 个端点字面量全量扫描 + 调用点
  上下文 + 真实探针双源互证（f12-record §10）。
- **api-capture.py**：`api.operations[<BUTTON>]` 命中 `step.button` 时改发该按钮专属端点；
  `backTarget` 解析器（getWorkflowInstanceRecordsBack2 → `data.stepInfo` 按 stepCode
  **恰一命中**，列表非时间序，多候选=die）；`ledger: finish|refetch`（refetch=
  getCurrentUserProcessList 按实例+环节重登记退回后新任务；todo 行无姓名字段 → 空 owner
  通配、实例+环节绑定保隔离）；守卫前置（subst 会把未知占位符替换为空串——`${BACK_TARGET}`
  缺解析器的守卫必须在 subst 前查模板）。形状缺项/refetch 失配一律 fail-closed。
- **回归**：selftest G7a~G7f 六态（缺 path / backTarget 缺键 / body 引用 BACK_TARGET 无解析器 /
  恰一命中三对 / 多候选 die / refetch 命中与失配 / 空 owner 通配+非 owner 隔离 / 顶部分发两态）。
- **边界收紧（诚实保留）**：G5 退回/G6 作废可经 operations 表达；G5b 退回至矿点（跨实例
  语义）/选择合同/磅房/执行单/盖章链仍浏览器兜底。
- 实测配型（李雅庄铁路 runtime）：REJECT→backWorkflow、CANCEL→cancelWorkflow；场景 GAP 步
  按钮码沿用新系统原生码（21 节点 workbench 实查 REJECT 在列、00 节点 CANCEL 在列）。

## 1.3.4（2026-09-10·证据链对抗加固：结论复算 / 报告防伪造 / 人工内容保护 / 凭据空值统一）

- **P0 历史 BLOCKED 可被改成 FAIL 继续作豁免依据**：`run_evidence.py` 此前只复验
  gates/case-results/field-compare 三件 sha 并做轻量规则检查，没有精确复算 conclude 的完整结论——
  因版本 unrecorded 等原因正式判 BLOCKED 的 run，手工把 summary.conclusion 改成 FAIL 后会被豁免
  取证链接受。修复：① 抽取 `scripts/conclude_core.py` 纯评估器（不写任何文件），conclude.py
  只负责 IO，结论生成与豁免核验**同一份逻辑**；② run_evidence 调用该评估器重算完整结论，
  复算结论必须 ∈ {PASS,FAIL} 且与 summary.conclusion 严格一致，否则拒绝。
- **P0 契约快照保护失效**：run_evidence 此前读"当前契约"且不核验账本中的契约 SHA，契约不存在
  时直接跳过——契约被修改/删除后，旧 run 差异仍可作豁免依据。修复：`config_snapshot` **全部条目**
  现均纳入 sha 复算；登记的 contract 文件必须在账本位置存在且 sha 一致，否则拒绝。
- **P1 最终报告可由单个手写 summary 伪造**：`gen-final-report.py` 此前只要求 summary.json
  含 conclusion——放一个手写 summary 即可生成带"✅ PASS/证据同源"的正式报告。修复：生成正式
  PASS/FAIL/BLOCKED 报告前必须五件证据齐全、账本 config_snapshot 全量 sha 复算一致、结论经
  conclude_core 复算与 summary 一致；核验失败 exit 2。`--allow-unverified` 仅产出醒目标注
  "未核验/不构成正式结论"的草稿。
- **P1 人工回填被覆盖**：原报告声明"人工区机器不覆盖"却无条件重写整份报告。修复：人工产品级
  发现拆到独立 `人工发现.md`（首次自动建模板，机器永不覆盖；报告 §8 引用并渲染其中行）；
  已有机器报告默认拒绝静默覆盖，需显式 `--overwrite`。
- **P1 Python/Bash 凭据空值语义不一致**：Python 此前 `if not os.environ.get(k)`，显式导出的空值
  被当作"未设置"从而从 env 文件恢复凭据；改为 `if k not in os.environ`，与 Bash
  `env | grep '^K='` 的"存在即存在（含空值）"语义一致——显式空值=禁止使用保存凭据。
  Bash 侧补齐文件属主检查（镜像 Python `_check_env_file` 的 0600 + 当前用户所有）。
- **P2 报告元数据修正**：版本号不再硬编码（改读 SKILL.md frontmatter，与 write-manifest
  toolchain 同口径）；标题 run-id 已含 `run-` 前缀时不再叠加（修 run-run-<id>）。
- **文档纠偏**：quick 实际 10 条（SKILL.md/changelog 误写 9）；项目内使用说明版本号同步；
  "五件全部账本哈希复验"表述更正为"config_snapshot 全量条目 + 结论复算"；
  明确"不可篡改"=防工具误覆盖/防单文件篡改，不防御拥有目录写权限的本地攻击者（需外部只增
  账本/签名），避免过度承诺。
- **回归**：新增针对上述六个发现的负向回归（结论改写/契约改删/手写 summary 报告/人工标记保留/
  空导出语义/元数据），全量 selftest 305→316，quick 10→11（quick 新增真正的 Python/Bash
  交叉空值检查——此前 quick 只测了 Python）。

## 1.3.3（2026-09-10·账本哈希全量复验 + runtime env 安全门禁 + selftest 零副作用）

- **证据账本加固**：`run_evidence.py` 现对 field-compare、gates、case-results 三类登记证据
  全部复算 SHA，并交叉核对契约 required cases；事后改写门禁/用例结果不得继续作为豁免依据。
- **runtime env 安全**：凭据文件必须是当前用户所有的 0600 实体文件，拒绝符号链接；Bash
  镜像解析统一 trim 空白/引号口径，解析失败 fail-closed。
- **默认密码安全**：`FLOWTEST_DEFAULT_PWD` 只有在显式 `FLOWTEST_ALLOW_DEFAULT_PWD=1` 时生效，
  防止生产环境缺键时静默批量尝试统一密码。
- **回归/副作用**：增加账本失配与 runtime env 安全回归；selftest 子进程禁止生成字节码，
  退出时清理源目录 `__pycache__`；全量回归由 304 增至 305，quick 由 7 增至 10。

## 1.3.2（2026-09-10·去 .env 化：凭据统一落 $RUNTIME_DIR/env + FLOWTEST_DEFAULT_PWD 统一默认密码兜底）

- **依赖面收窄**：skill 不再依赖项目根 `.env`——此前执行命令要求 `source .env`（100+ 账号
  手工维护），现凭据统一落 `$RUNTIME_DIR/env`（私有运行态，与 systems/ 同级；绝不入库/
  同步），pipeline.sh 启动自动加载（setdefault：进程环境优先），`source .env` 从全部
  文档命令移除。
- **统一默认密码兜底**：新增 `scripts/ftc_env.py` 唯一实现（登记 MANIFEST；api-capture /
  browser-capture / check-config 三处共享）：凭据解析优先级 = 进程环境 → `$RUNTIME_DIR/env`
  → 密码回退 `FLOWTEST_DEFAULT_PWD`、用户名回退 actor 本名 → 仍缺=CredentialError 诚实
  BLOCKED（绝不伪造）。兜底发生时 WARN 提示，可审计。
- **镜像规则**：bash 侧 pipeline.sh `ftc_load_runtime_env` 与 python 侧 ftc_env.py 同一
  解析语义（KEY=VALUE / export 前缀 / 成对引号 / # 注释；setdefault）。
- **fail-closed 保持**：browser-capture 内置自检在"env 文件与默认密码兜底均不在场"下仍
  拒绝凭据缺失（BB3 同纪律）；check-config 有兜底时降级 WARN、无兜底保持拒跑。
- 模板/资产同步：`assets/env.flowtest.example` 重写为 `$RUNTIME_DIR/env` 模板
  （install.sh 部署目标改为 `.flow-test-contract/runtime/env.example`）。

## 1.3.1（2026-09-09·P0 伪造八字段豁免封堵 + P1 runs-dir 智能解析 + P2 只读 conclusion 误判面收紧）

- **P0 伪造八字段豁免仍可通过契约门**：1.3.0 的 validator 豁免核验是简化版——只看
  source_run_id 目录存在 + fc 现算 sha + summary 自述结论，未核 run-manifest 存在、账本
  登记与 sha、run-id 三方一致、toolchain 指纹、scope/match 是否对应源 diffs——实测"无
  manifest + 手写 summary=FAIL + 凭空 match + 手算 sha"的两个自制 JSON 即可通过 TEST_READY。
  修复（**不在 validator 另写简化版，抽共享模块**）：
  ① 新增 `scripts/run_evidence.py` 唯一实现（登记 MANIFEST）：五件证据齐全（账本/结论/
     对拍/门禁/用例，实体文件拒符号链接——与 conclude 必要证据同口径）→ JSON 可解析 →
     run-id 三方一致 → fc 已以本 run 目录内路径登记账本且 sha256[:16] 现算一致（恰一条，
     拒诱饵/歧义）→ 结论 ∈ PASS/FAIL → toolchain 指纹完整 → **底层证据轻量重算**
     （gates 全过布尔真/case-results 必测全 PASS 且 id 合法/fc 状态自洽：OK⇒diffs 空，
     FAIL⇒diffs 非空——手写 summary 与底层矛盾在此暴露）；
  ② **scope/match 绑定源 diffs**：exemption 的 scope 必须等于 diff.dim（或 '*'）、match
     必须经与比较器同口径的"剥一次前缀"稳定键命中源 fc.diffs 真实条目——凭空精确键拒绝，
     OK run（无 diffs）任何豁免都非法（reason 为人工审计描述，经 approval_ref 追溯，
     不做机械绑定）；
  ③ 生成器 exempt 与 validator 共用同一实现（gen 委托 `_verify_run_dir` → 共享模块；
     validator 动态加载，双布局候选解析，`sys.dont_write_bytecode` 保零字节码）；
     exempt 证据面随之收紧为五件（真实 run 本就五件齐全）。
- **P1 生成件契约的默认 runs-dir 算错**：全分支契约生成在 `自动化测试/生成件/`，pipeline
  固定传 `--runs-dir "$(dirname "$CONTRACT")/对比测试"` 解析到不存在的 `生成件/对比测试`
  → 合法历史豁免被误 BLOCKED 且无覆盖入口。修复：pipeline 新增可选 `--runs-dir` 参数
  （argv 转发，无注入面；--help 已登记），缺省由 validate-contract 智能解析——
  契约同目录/对比测试 → 上一级/对比测试（覆盖 生成件/ 布局）。
- **P2 范围限定仍易被只读 conclusion 的系统误判**：1.3.0 对 reverse_explore>0 的正向全
  PASS 只写 conclusion_scope 限定字段，顶层 conclusion 仍=PASS——只读顶层 conclusion 的
  CI/报表/外部调用方仍会报告全量成功。修复：**顶层 conclusion=BLOCKED**（正式三态不越界）
  + `summary.forward_conclusion=PASS`（信息性字段，blocked_reasons 明示"非正式三态结论"）
  + branch_scope.conclusion_scope=forward_branches_only；正向存在真实差异时维持 FAIL
  （FAIL 无"成功"误读面）。gen-final-report 如实呈现两者。
- **回归 290→304**（+14）：伪造矩阵 11（缺 manifest/未入账/账本 sha 不符/run-id 错配/
  缺 toolchain/凭空 match/scope 维度不符/summary 与底层矛盾/缺 gates/fc 状态自洽/
  完全自洽不误伤）+ 生成件 runs-dir 解析 1 + conclude BLOCKED 降级 2（顶层不得 PASS +
  降级原因入账；FAIL 维持不降级）。

## 1.3.0（2026-09-09·P1 双修：豁免取证链入契约门 + 反向分支结论限定；P2 selftest 分级）

- **P1-1 真实 run 绑定只保护"生成器入口"，没保护"最终契约入口"**：exempt 子命令产出的豁免
  自带 approval_ref/source_run_id/source_compare_sha256_16，但 schema 只要求旧五字段、
  validator 同、比较器只查 id/reason/approved_by——绕过 exempt **手写一条精确 match 的豁免**
  仍可被正式对拍采信并吞掉差异。三入口封堵：
  ① **schema**：exemptions 条目必填升级为八字段（source_compare_sha256_16 限
     `^[0-9a-f]{16}$`）；
  ② **validate-contract**：八字段逐项非空校验 + 新增 `verify_exemption_provenance` 豁免账本
     核验——source_run_id 须在 run 证据库（默认 `<契约同目录>/对比测试/`，`--runs-dir` 可
     显式指定）定位到真实 run 目录（拒符号链接），field-compare.json **sha256[:16] 现算复验**，
     源 run 结论 ∈ PASS/FAIL（BLOCKED/DRILL 未过完整门禁不可作豁免依据）；同一源 run 多条
     豁免只核验一次；
  ③ **field-level-compare**：豁免生效门槛升级为完整取证链（缺任一字段或 sha16 格式非法 →
     invalid_exemptions 不生效，差异保留）。
  pipeline 契约模式（dry-run 与正式）validate 调用显式传 `--runs-dir`。
  **历史手工五字段豁免迁移口径**：对源 run 重跑 exempt 生成补链条目（显式迁移），或把契约
  降 DRAFT——直接沿用会在 TEST_READY 校验/对拍入口被拒。
- **P1-2 反向分支未正式执行却计为 complete=true**：生成器 complete 只判 skipped==0、
  conclude 只阻断 skipped——"取证源 23 支、正向正式 20 支、反向仅 drill 3 支、skipped=0"
  会被表述为"全分支 PASS"。双态完成度拆分：
  ① **生成器**：`meta.branch_coverage` 新增 `accounted_complete`（分支全分类）与
     `formal_complete`（且反向为 0），`complete` 保留为 accounted 兼容语义；反向分支>0 时
     生成报告显式警示结论将被限定；
  ② **validator**：双态字段必填（旧 1.2.x 契约缺字段=拒绝，重新生成）且与计数自洽
     （formal_complete ≠ (skipped==0 ∧ reverse==0) → 拒绝）；
  ③ **conclude**：reverse_explore>0 的 run，summary 新增 `branch_scope`
     {accounted_complete, formal_complete, conclusion_scope}——PASS 时
     `conclusion_scope=forward_branches_only`，summary.md 显著标注『正向分支 PASS /
     反向未正式验证』+ stderr 警告；契约自称 formal_complete=true 却有反向分支 → 自相矛盾
     BLOCKED；**gen-final-report** 在报告 §2 渲染分支范围限定（禁止升格为全量 PASS）；
  ④ 反向分支要出正式结论的出路：为 RETURN/WITHDRAW/VOID 另立正式契约（cases[].notes 显式
     声明特殊流转）并单独 run 绑定结果。
- **P2 selftest 分级**：每会话强制全量负向回归成本高（分钟级）→ `selftest.py --quick`
  （秒级 7 条：MANIFEST 资产/全部脚本语法/铁路实例 test_ready/空白模板拒绝/豁免取证链门禁/
  比较器无链不吞差异/反向分支结论限定）作为会话前置；SKILL.md 前置检查改用 --quick；
  缺省（=--full）290 条仍是版本发布与深度审计唯一口径。
- **回归 278→290**（+12）：validate 取证链 5（缺链拒绝/伪造 run/篡改 sha/BLOCKED 源/完整链
  不误伤）+ compare 取证链 2（手写精确豁免不生效/sha16 格式非法）+ 双态完成度 5（生成器
  双态落盘/旧契约缺字段拒绝/formal_complete 撒谎拒绝/conclude forward_branches_only/
  conclude 自相矛盾 BLOCKED）。

## 1.2.3（2026-09-09·P0 分母不得静默缩小 + P1 取证源指纹执行期复算）

- **P0 不完整分支集获得"全量 PASS"**：生成器遇未知环节名只把分支记入 skipped，仍产出
  `status=TEST_READY` 并 exit 0；validator 又只校验 sources 非空、不解析 skipped——取证源
  23 支、跳过 2 支时正式契约只剩 21 cases，跑完 21/21 即被当作"全分支 PASS"（分母被静默
  缩小）。四层封堵：
  ① **生成器**：`skipped>0` + TEST_READY → exit 2 零正式产物，提示"补 --node-map-extra
     重新生成"或"降级 DRAFT"；DRAFT 时产物名强制带 `.partial.`、notes 标 PARTIAL；
  ② **结构化字段**：新增 `meta.branch_coverage`（total/formal/reverse/skipped/complete/
     skipped_detail/source_fingerprints），取代塞进 `sources[].detail` 的自由文本；
  ③ **validator**：解析 branch_coverage，校验恒等式 `total == formal + reverse + skipped`、
     formal 与实际 cases 数一致、TEST_READY 要求 `skipped=0`；
  ④ **conclude**：正式结论同样交叉核验恒等式与 skipped=0，并比对 formal 与实际执行用例数
     （防执行期分母漂移）。
- **P1 取证源指纹只是"曾声明"**：契约里的 sha256 无法证明执行时源文件仍与生成时一致。
  pipeline 契约模式在 validate 后**逐条现算比对** `branch_coverage.source_fingerprints`
  （分支源/模板/node-map-extra/branch-values/user-names）；不一致或源文件消失 → BLOCKED，
  drill 降级为告警。`supplied=false` 的可选源跳过比对。
- **附带修复**：含字母分支号（B-9X）生成的 `C-9X` 违反 schema `^C-[0-9]+$`，此前要到
  validate 才暴露——现生成期即拒并提示改用纯数字分支号；selftest 测试模板补齐 current 侧
  health_checks 与双端 login_path（既有夹具缺陷）。
- **回归 271→278**（+7）：TEST_READY 拒绝 / DRAFT partial 产物 / partial 结构化字段 /
  validator 拒 partial / 补码后完整生成 / 计数不自洽拒绝 / 源指纹复算不一致拒绝，
  另加 case id 合规 1 条。

## 1.2.2（2026-09-09·生成件目录中文化 + README）

- **生成件目录中文化**：`docs/<流程>/自动化测试/generated/` → `.../生成件/`，全库 24 处默认值
  与文档示例同步（SKILL.md ×6、pipeline.sh ×4、references ×5、templates ×6、selftest ×3）。
  `generated_at`（gate 证据时效字段）不受影响；内层 `flowtrace-scenarios/`、
  `compare-rules.json` 保持不变（gen_from_contract 硬编码，改名会联动同源复算/runner/账本）。
  存量项目目录不做迁移——历史 run 账本登记的是旧路径，下次重新生成时自然采用新名。
- **新增 README.md**：面向人的 skill 介绍（解决什么问题/生命周期/五分钟上手/三层产物口径/
  两条通道/八条不可突破门禁/目录导航/维护约定）；SKILL.md 仍是 agent 主入口，两者分工不重叠。

## 1.2.1（2026-09-09·对抗审计加固：豁免 YAML 注入 / 诱饵路径 / 作用域越界 / 退出码逃逸）

子 agent 对抗审计 13 项发现全数修复（含 2 个 P0）：

- **P0 豁免 YAML 注入**：`cmd_exempt` 曾用 f-string 拼 YAML，`diffs[].key` 与
  `--approved-by`/`--approval-ref`/`--reason-desc` 均为可控自由文本——含 `"`+换行即可注入
  `scope: all` / `match: "*"` 的**全局豁免**（解析合法、语义被伪造，且自带取证链字段骗过
  人工核阅）。双保险修复：① key 白名单 `case/step/field[->field]`，违规 exit 2；
  ② 输出全部改 `yaml.safe_dump` 序列化（引号/反斜杠/冒号的正常人名工单也不再产坏 YAML）。
- **P0 诱饵路径**：账本 field-compare 登记此前只比 basename 且 `next()` 取首个命中——塞一条
  path 指向别处、sha 填篡改值的条目即可放行伪造对拍。改为登记路径 `resolve()` 必须等于本
  run 目录内的 fc 实体文件，命中 >1 条歧义拒绝。
- **P1 符号链接绕过**：`is_file()` 跟随链接使 fc 可外链到 run 目录外任意文件——现 `is_symlink()`
  即拒（三件证据同此纪律）。
- **P1 退出码逃逸**：4 处 `SystemExit(<str>)`（P1-2 新增的核心 fail-closed 分支）以 rc=1 退出，
  与"用法错误/一般异常"混淆；另有 `--template` 不存在、坏 JSON、单层 key、key 类型混淆等
  以 traceback rc=1 逃逸。现全部经 `_die()` → exit 2，并加 `__main__` 顶层兜底 + 输入前置校验。
- **P2 作用域越界**：`ast.walk` 使类体内赋值被当模块级、嵌套函数内 dict 被当外层函数体——
  现模块级仅扫 `tree.body`，函数体扫描遇 `FunctionDef/ClassDef/Lambda` 剪枝不下钻。
- **P2 分支静默丢弃**：分支值为变量引用/拼接（非字符串常量）时被静默丢弃且不计入
  `branch_counts`，契约自称"总数=1"——现 fail-closed exit 2（零执行无法求值，不猜）。
- **P2 run-id 剥离歧义**：`replace("run-","",1)` 是全串首次替换而非前缀剥离
  （`20260909-run-77` ↔ `20260909-77` 被误判一致）——改真前缀剥离。
- **P2 假工具链指纹**：`toolchain: {}` 曾通过校验（产出豁免打印 `skill=None`）——现要求
  `skill_version` + `manifest_sha256` 非空且非 unrecorded。
- **P2 sources 自证缺口**：可选源未提供时不登记，读者无法区分"没用过"与"被省略"——现三个
  可选源恒登记 `supplied=false` + 生效口径说明；已提供源的 sha256 由 16 位改**全长**（机器可重算）。
- **P2 悬空引用**：6 处"守护规则 7"（实际只有 1-6）统一为守护规则 6。
- **回归 259→271**（+12）：注入 ×2、诱饵/符号链接/空指纹/单层 key ×4、作用域 ×3、
  输入校验 ×2、sources 自证 ×1。

## 1.2.0（2026-09-09·P1 门禁双修：豁免取证链强制 + 分支源解析收窄 + 全量源头 SHA 登记）

- **P1-1**：批量豁免 `cmd_exempt` 此前只读任意 field-compare.json 的 diffs，未验证 run 目
  录/账本/结论/对拍 sha 一致性，手写 JSON 即可骗过并吞掉正式差异。改为 `--run-dir` 必填，
  内部核验链：① run-manifest/summary/field-compare 三件齐全；② run-id 三方一致；③ fc 已登
  记进账本 config_snapshot 且现算 sha256[:16] 与账本一致（手写/篡改对拍在此拒绝）；④ 结论
  ∈ PASS/FAIL（BLOCKED/DRILL 未过完整门禁，其差异不可采信）；⑤ 账本含 toolchain 指纹
  （1.1.0 起强制）。每条豁免输出 `source_run_id`/`source_compare_sha256_16`/`approval_ref`。
- **P1-2**：分支源解析 `parse_branches_source` 此前 ast.walk 遍历文件内所有 dict 字面量，
  只要键像 B-XX 就纳入，样例/缓存/无关字典静默改变分支集合（"全量"无法自证）。收紧为受控
  作用域——仅解析 `--branches-var` 指定变量名/同名函数体内的分支 dict（零候选或多候选一律
  拒绝，拒绝全文件扫描）。同时修复 `B-\d+` 静默丢弃含字母分支号（B-9X 等）的同类缺口。
  `meta.sources.multibranch_generation` 新增登记每个取证源的路径+SHA256 全长与分支计数
  （总数/正移/反向/跳过），正式契约据此自证"取证源全量"。
- **回归 239→259**（+20 条）：exempt 负向×5（sha 错配/BLOCKED 结论/run-id 错配/缺 toolchain/
  缺三件）、exempt 正向×1（真实 run 带全豁免字段）、旧 --compare 入口移除×1、源收紧×4
  （污染/零候选/歧义/--branches-var 指定）、meta.sources 指纹×1。
- **小修**：SKILL.md 4.5 块命令 `python3` 统一为 `$FTC_PY`（含 `--branches-var` 参数）；
  `gen-multibranch-contract.py` 全部 `SystemExit` 退出码 2（1 曾与用法错误混淆，门禁语义
  不可区分）；selftest 计数 239→259。

## 1.1.0（2026-09-09·可复现性正式门禁：浏览器 npx 锁版 + 工具链指纹落账）

- **P2**：浏览器正式结论不可完全复现——`_resolve_cli()` 在无配置时走 `npx --yes --package
  @playwright/cli playwright-cli`（联网下载 + 版本漂移，同一契约不同日期跑出不同浏览器行为，
  正式 PASS 不可复现）。修复：`FLOWTEST_FORMAL_RUN=1`（pipeline 正式执行时注入，非 drill
  非 dry-run 即导出）下禁用 npx 回退，fail-closed 报错要求配 `PLAYWRIGHT_CLI` 锁版本；
  演练/探针不受限；selftest BB9c2/BB9c3/BB9c4 三层正反回归覆盖。
- **P2**：账本此前只记系统三元版本与比较器串，同一 run 使用的 skill 版本/脚本代码/依赖/
  浏览器 CLI 版本无从追溯。`write-manifest.py` 新增 `toolchain_fingerprint()`，自动落账：
  skill 版本（SKILL.md frontmatter）、MANIFEST.txt 全文 SHA256、MANIFEST 内全部脚本逐文件
  sha256[:16]、Python 版本、python deps（yaml/jsonschema）版本、Playwright CLI 版本/
  `FLOWTEST_RUNNER`。探测失败记 `unavailable`/`not-configured` 不阻断落账。
- **P3 收尾**：gen-final-report.py 用法行 `<reports>/<run-id>` → docs 口径（下划线变体漏网）；
  write-manifest.py 模块 docstring 与 instance_pairs 默认值同步统一。

## 1.0.3（2026-09-09·脚本内旧结构路径残留扫尾）

- **P2-2 收尾**：第三十四轮/1.0.2 的产物路径口径统一涉及 SKILL.md/references 后，脚本内
  （gen-gate-report.py:99 用户可见 print、gen-final-report.py:5 模块 docstring、
  gate-evidence-check.py:17 docstring、pipeline.sh:48:488 注释、conclude.py:210 注释）
  仍残留 `executions/<run-id>/`、`reports/<run-id>/` 旧结构表述。全部统一为
  `docs/<流程>/自动化测试/对比测试/<run-id>/`（run 目录根）或简写"run 目录"。
- **验证**：全库 `reports/<run-id>` | `executions/<run-id>` **零残留**（仅合法 2 处：
  \(1\) 无契约 legacy 回退 `RUNTIME_DIR/reports`；\(2\) run-id 冲突历史兼容检查
  `RUN_OUTPUT_BASE/reports|executions`，均保留不变）。

## 1.0.2（2026-09-09·文档可用性双修：FTC_PY 统一/产物路径口径收敛）

- **P2-1**：SKILL.md 步骤 4 浏览器通道命令 `python3 browser-capture.py` → `$FTC_PY`（该块已
  自含 FTC_PY 解析——纯 uv 依赖的机器上 api 命令可用而浏览器命令会败的口径分裂消除）。
- **P2-2**：产物路径口径收敛（第三十四轮 P2-1 的收尾）：SKILL.md 结论段、f12-record、
  execution-gate（×4 处）残留的 `reports/<run-id>/`、`executions/<run-id>/` 旧结构表述
  全部统一为对用户唯一可见路径 `docs/<流程>/自动化测试/对比测试/<run-id>/`（单 run 单目录，
  summary.json/gate-evidence.json/case-results.json 等同放一层；`reports/executions` 仅
  保留两处合法语义：无契约 legacy 回退 `$RUNTIME_DIR/reports/` 与 run-id 冲突历史兼容检查）。

## 1.0.1（2026-09-09·发布后 P0 修复：正式运行误放宽路由门禁）

- **P0**：pipeline.sh `DRILL=false` 为非空字符串，`${DRILL:+--allow-route-drift}` 非空判断恒真
  ——不带 --drill 的正式运行也向 validate 传 `--allow-route-drift`，"用例路由 ∉ nodes.next"
  被降级 WARN，违背正式 fail-closed（shell 实测复现）。修复：参数解析后显式布尔派生
  `DRILL_ROUTE_FLAG`/`DRILL_NOTE`，三处 `:+` 消费点（dry-run 校验/真实校验/健康检查日志文案）
  全部改用。
- **回归补齐（233→235）**：G7b 正式 dry-run + 路由矛盾 → 拒绝(2) 且失败点=路由门（非同源）；
  G7c 同一矛盾 + --drill → 路由 WARN 放行（失败点=同源复算）——pipeline 级正反两向锁定
  （此前 233 条仅覆盖 validator 直调行为，未覆盖 pipeline 正式反例）。
- **P2**：SKILL.md 步骤 4 命令块补 FTC_PY 自含定义（单块复制即可执行 F12 检查）；发布状态块
  遗留边界措辞收窄——按钮流在双端 UI 录制与真实验证完成前诚实 BLOCKED，不得产出该部分
  正式 PASS 结论（泛称"不影响正式结论"不成立）。

## 1.0.0 发布（2026-09-09·脱离 EXPERIMENTAL：发布前六面审计 loop 修复后全绿）

- **发布审计 loop**：6 个独立子 agent 并行审计（资产清单/MANIFEST 双向、代码静态、凭据
  安全、发布门禁 sync --check、文档语义一致、契约实例正负向）→ 修复 → 独立复验 → 清零：
  - api-capture.py body_snippet 脱敏正则子串化 + 连字符变体（access_token/db_password/
    x-api-key/Api-Key 均覆盖，与 validate 子串口径对齐）；
  - selftest 新增 G6a/G6b 键名变体脱敏回归（231→233 全绿）；
  - gen_from_contract.py summary 模板 comparator_version 占位 v2 → v2.10；
  - SKILL.md lessons-learned 计数措辞修正（速查 24 条/全文 40 条）；
  - changelog 补记第三十五轮（内容与代码痕迹互证属实）。
- **发布验证**：selftest 233/233、sync-to-tools.sh --check 门禁退出码 0（14 副本 +
  opencode 符号链接全一致）、validate-contract 实例 test_ready 通过、legacy-config-check
  api 通道就绪。
- **语义变化**：解除"不得作为正式 PASS/FAIL 结论来源"限制；演练（--drill）产出仍不作为
  正式结论。**遗留边界（诚实保留）**：按钮流（选择合同/磅房/执行单、盖章链）API 自动化
  尚未实现——由浏览器通道兜底（老系统四支全链办结实证）；browser 通道 __UI_RECORD__
  待录制。
- **版本规则变更**：0.x 轮次格式退役，1.0.0 起语义化版本。

## 第三十五轮 → version 0.35.0（2026-09-09·工程化审计收尾：安装器 E2E/清单 fail-closed/同步器口径/--help）

- **P2 安装器 E2E 回归**（selftest 新增 5 条，226→231）：临时项目 install（含历史漏复制
  4 文件必须到位）→ systems api 种子落位 → `install --check` 通过 → 篡改部署副本必须被
  `--check` 抓到(1) → **已安装布局**（docs/自动化测试模板 + .flow-test-contract）pipeline
  --dry-run 计划可行(0)。install.sh/MANIFEST.txt 只随 skill 源存在 → 本节仅 skill 布局可测。
- **P2 前置检查对 MANIFEST.txt 本身 fail-closed**：清单缺失时内联 while 重定向会静默零校验
  （假绿）——现显式 ⛔ 并 ok=0。
- **P3 同步器口径**：sync-to-tools.sh 头部与 SKILL.md 明确"本脚本不分发到任何副本——只能从
  .agents 源目录执行"；**opencode 符号链接纳入检查**（--check 只读：正确 ✅ / stale ⛔ 门禁失败
  / 缺失 ⚠；同步模式自动建链/修复，实体目录不误伤）。
- **P3 frontmatter 只写适用场景**（description 去除工作流复述）+ pipeline.sh 新增
  `--help|-h`（用法/退出码口径；未知参数提示 --help）。
- **附带修复（bash 3.2 全角邻接陷阱）**：`$VAR（/$VAR）` 会被 macOS 自带 bash 3.2 当作超长
  变量名 → set -u 下 unbound crash。全库扫描修复 4 处（sync-to-tools.sh×3、install.sh×1、
  pipeline.sh×2——含既有代码 2 处潜伏点）；规约：变量后紧跟全角字符必须加 `${VAR}` 花括号。

## 第三十四轮 → version 0.34.0（2026-09-09·skill 工程化审计修复：清单化/副本门禁/依赖统一/路由收紧）

- **P0 分发清单化**：新增 [MANIFEST.txt](../MANIFEST.txt) 唯一清单（scripts 13 + templates 7 +
  assets 5 逐文件登记）——install.sh 改为清单驱动（复制+字节校验+`--check` 零写入校验模式），
  修复旧安装器漏 ftc-runtime.sh/gen-final-report.py/browser-capture.py/gen_flow_tables.py
  导致干净 clone 直接坏的问题；删除"手写两套 10 件列表"模式（前置检查资产齐全校验同走清单）。
- **P0 副本漂移消灭 + 发布门禁**：指定 `~/.agents/skills/flow-test-contract` 为唯一事实源，
  sync-to-tools.sh 增加 `--check`（只校验全副本字节一致，退出码门禁）、排除 runtime/（私有
  运行态不同步）、跳过未安装工具目录；修复 .codex/.cursor 等副本长期缺文件/缺 references 的漂移。
- **P1 依赖统一**：pipeline.sh 新增 PYRUN 单点解析（系统 python3 带 PyYAML 即用 → uv
  `run --with pyyaml,jsonschema` 回退 → 两者皆无明确阻断 exit 2），修复"uv 仅警告但标准命令
  全依赖 uv / 强制全局 PyYAML 又建议 uv / jsonschema 不预检"的自相矛盾；SKILL.md 前置检查与
  全部命令块统一 FTC_PY 策略。
- **P1 命令块自含**：SKILL.md 工作流各命令块自含 SKILL/RUNTIME_DIR/FTC_PY，`$RUNTIME_DIR`
  一律经 `ftc-runtime.sh resolve` 现算——修复文档命令分段复制执行时变量为空。
- **P2 产物路径口径统一**：唯一面向用户的最终产物路径 =
  `<项目>/docs/<流程名>/自动化测试/对比测试/<run-id>/`；runtime 明确为"私有配置目录（通道
  配置与 gate 证据库），非交付物"；修正 SKILL.md/pipeline.sh/ftc-runtime.sh 中过期的
  "reports/executions 落 runtime" 表述。
- **P2 SKILL.md 重写**：frontmatter description 改为 Use when 触发条件；正文裁剪为决策树+
  最小命令+不可突破门禁，细节留 references；件数表述改由 MANIFEST 承担（不再随实际文件数漂移）。
- **P2 路由矛盾默认拒绝（fail-closed）**：validate-contract.py 对"用例路由 ∉ nodes.next"
  从 WARN 收紧为 FAIL（cases[].notes 显式声明特殊流转可豁免）；新增 `--allow-route-drift`
  仅由 pipeline `--drill` 自动传入（探索性路径限演练）；selftest G3 拆为 3 条负向/正向用例。
- 验证：selftest 226/226 全绿（224+2）；install.sh --check / sync-to-tools.sh --check 门禁全绿。

## 第三十三轮（2026-09-09·港口煤 API 全链贯通 + 老系统浏览器四支办结经验反哺）

- 港口煤 WFA_RY_JM_126001 契约 API 通道首次正式执行，**6 处通道修复**（api-capture.py，
  selftest 214 全绿）反哺 **8 条新经验 L33~L40**（lessons-learned §6c，速查表 16→24 条）：
  - **L33 同名多候选 prefer_ids**：3 个「侯丽娟」实锤——盲取首个=派错人 500；whoami 探针
    实值指认 + fail-closed；姓名归一化剥内部空格（「高 鹏」）；
  - **L34 编码空间不对称**：DMN 流程 submit.nextStep 认 routeCode 而 next-assignees.nodeCode
    认 taskElementId——workbench nextNodes 回退翻译，此类流程不配 route_map；
  - **L35 SUBMIT 不落业务表单**：save_with_form_data / echo_form_patch / formData(Map) 载体
    三层修法（勿发明 formPatch 顶层键——DTO 静默丢弃）；
  - **L36 必填输入以引擎 400 字段码清单为准回填契约**（CYRQ 案例）再重新生成；
  - **L37 gate 证据=只读探针报告+sha256 清单**（24h 时效），先例 gate-evidence-live；
  - **L38 新流程 API 首跑六项预检清单**；
  - **L39 老系统提交确认弹窗时序**（2~5s 慢渲染→连续 3 轮无弹窗才收尾；业务告警弹窗立即中止
    ——乱点确定 40 次循环污染页面状态实锤）+ 每步回读「当前环节」验证静默失败；
  - **L40 显示名≠账号**（张冲≠张泽）+ agent-browser open() 杀 SPA 登录态（页内用 hash）；
- capture-channels §5 新增「选人与提交载体实战规则」块（prefer_ids/编码不对称/SUBMIT 载体/
  todo.map 从引擎库部署 BPMN 实查——本地 BPMN 文件 elementId 与运行时不一致实锤）；
- browser-channel §4 新增 G3.7（确认弹窗时序/告警中止/静默失败判定）、G3.7a（95306 弹窗
  toggleRowSelection 可靠路径 + wrapper offsetParent 恒 null 用 style.display 过滤 +
  数据行按「未使用」过滤——旧轮次已消费）、G3.7b（显示名≠账号/页内导航纪律）；
- contract-howto 取证坑 +13（必填输入回填/六项预检/gate 证据制作）；
- 实证背书：legacy API 通道 12 节点全链采集跑通（run-20260908204212 起）；老系统可见浏览器
  B-02/B-03/B-04/B-05 四支全链办结（JMFXZXK001901/JMFXJXX007269/JMFXSLK002520/实例 000001，
  95306 回填 25182.00/27111.40/18591.20 与历史实测一致）；B-06 推进至 10（01 渲染 TypeError
  缺陷本轮未复现——非必现缺陷，记录口径更新）。

## 第二十九轮（2026-09-09·李雅庄深夜双端对比轮经验反哺）

- 09-08/09 深夜并行双轮（姊妹记录互链）反哺 **6 条新经验 L27~L32**（lessons-learned §6b，
  速查表 12→16 条）：
  - **L27 老系统对话框选数=Vue 组件注入**：合成事件勾选不回写组件状态——must 写
    `_data.multipleTableVal` 再 `sure()`，行对象必须带过滤器字段（磅房 STATUS/合同 qzzt/执行单 id）；
  - **L28 表单日期=Vue 模型直写**：DOM 键入不进模型，服务端按旧值做合同有效期窗口校验；
  - **L29 多 agent 并行浏览器串扰守卫**：eval 内嵌宿主守卫+mega-eval 压缩窗口，实测零实例互染；
  - **L30 公式写入顺序分叉**（老=归类值覆盖、新=首笔原值）：行为差异非缺陷，提请产品确认口径；
  - **L31 老系统提交合同文件注册前置**：生产合同电子文件缺失=治理侧 BLOCKED，重试不可解；
  - **L32 老系统发起/提交操作序**：勾行+启动流程按钮、提交三件套（选人→identification→
    容器内找确定）、保存未提交 reload 即孤儿；
- browser-channel §4 SOP 同步固化（G3.5 Vue 注入 / G3.6 发起提交序 / 宿主守卫行 / 日期模型行 /
  一气呵成纪律行）+ §8 边界声明（Vue 注入路径尚未编码进 browser-capture.py，暂为手工 SOP）；
- 实证背书：老系统 00 节点全语义取证成功（O-2 合同带入实锤=双端一致关闭风险种子）+
  新系统公路 C-01 独立全链办结（FI1788885970818B5D8A65A）。

## 第二十八轮（2026-09-09·执行产物按流程归档）

- **执行产物落项目 docs**：截图/采集/账本/结论/最终 md 报告统一落
  `<项目>/docs/<流程名>/自动化测试/对比测试/<run-id>/`（流程名=契约路径 docs/ 下首段；
  exec 与 report 合并为单 run 单目录；`FLOWTEST_OUTPUT_DIR` 整体覆盖；legacy 兼容模式回退 runtime）；
- browser 通道**逐环节截图**：`screenshots/<side>/s<seq>_<node>_{form,submitted}.png`；
  最终报告 §7 自动呈现截图数；
- 存量迁移：runtime 内 52 个 report run + 54 个 executions 按契约路径归位三条流程
  （港口煤 10 / 铁路 28 / 公路 1 / 未归类 16）；runtime 只留 systems 配置与 gate 证据库；
- selftest +3（BB9g 输出根解析），221→224。

## 第二十七轮（2026-09-09·最终交付单 md 化）

- 新增 `scripts/gen-final-report.py`：把 run 目录机器证据（run-manifest/case-results/
  field-compare×N/gates/summary）汇总为**一份 `对比测试报告.md`**（9 节，含产品级发现人工回填区
  与复跑指引）——pipeline 在 conclude 后自动调用；缺 summary.json fail-closed 拒绝（无结论不产报告）；
- selftest +2（BB9f-1 全节校验 / BB9f-2 缺结论拒绝），219→221；
- 呼应 lessons-learned L22/L23：机器部分零手工拼接，人工内容（D-xx/O-xx）进预置区。

## 第二十六轮（2026-09-09·三流程实战经验提炼）

- 新增 `references/lessons-learned.md`：港口煤发运（23 分支浏览器对比）/ 李雅庄公路（V1.3→R6）/
  李雅庄铁路（API 双边+浏览器对比）三流程全过程记录提炼 **26 条经验**（取证立契/通道选择/执行操作/
  环境治理/结论账本/记录规范六类，每条现象→根因→固化位置）；
- 定点补强：contract-howto 取证坑 10~12（字段码复合键后缀/formData 通道与账本节点码/EXPECTED GAP）、
  execution-gate §5~§8（完成判定标准/预检清理/假阳性防时序/执行记录规范）、browser-channel §1/§4
  （客户端公式字段禁 api/默认处理人陷阱/生产环境纪律）、capture-channels §5 通道适配性警示；
- 高警示入册：老系统=生产环境（L15）、环境级阻塞≠产品缺陷（L16）、待办清零≠办结（L20）。

## 第二十五轮（2026-09-09·skill 自持分离 + 浏览器通道）

- **运行态分离**：systems api/browser 配置、executions/、reports/ 全部迁出项目 `.flowtrace/`，
  落 skill 自持目录 `$SKILL/runtime/<项目键>/`（项目键=名称-hash8，多项目互不串扰；
  `FLOWTEST_RUNTIME_DIR` 整体覆盖）。`.flowtrace/` 从此只属于旧 FlowTrace 流水线
  （flow-defs/scenarios/run-all-plants.js），ftc 与 FlowTrace 资产零混杂。
- **env 前缀更名**：`FLOWTRACE_*` → `FLOWTEST_*`（RUNNER/SYSTEMS_API_DIR/SYSTEMS_BROWSER_DIR/
  CASES/CLI/RUN_TS），脚本内旧名回退兼容一个过渡期。
- **新增浏览器通道**：`scripts/browser-capture.py`（playwright-cli 驱动，双系统同构 capture）+
  `assets/systems-browser/{legacy,current}.yaml`（legacy 全量实测：G3.1 弹窗选数/G3.3 补选/
  G3.4 无菜单入口/JWT 切号/00 日期面板点选；current 待 UI 录制）+
  `references/browser-channel.md`；runner 增加 `FLOWTEST_RUNNER=browser` 后端。
- 项目部署布局（install.sh）目标迁至 `<root>/.flow-test-contract/`；selftest 项目布局候选同步。

## 第二十三轮（2026-09-08·自检卫生轮）

- s
## 2026-09-08 · 环节表生成器并入（gen_flow_tables）

- 新增 `templates/gen_flow_tables.py`：流程环节表生成（多分支总览 multi / 单分支明细 single），
  数据源双后端——`legacy-oracle`（老系统 Oracle SETTLE_WORKFLOW_SUB/STEP 直取，探列不符即 BLOCKED）与
  `snapshot`（Excel 转档《23分支节点对应信息.md》同构解析，起草回退）；
- 主线规则=沿每环节首个下一候选（WORKFLOW_SUB_ID 序）；41~47 运费节点按跳转结束型处理；
- `--selftest` 无 DB 自检；对比报告 §3 结构列（环节/办理人/候选）可由本生成器产出后并入执行证据列。
elftest 进程内 importlib 动态加载被测脚本时不再写字节码（`sys.dont_write_bytecode=True`）——
  此前运行前置检查会在 skill `scripts/` 下落 `__pycache__`，违反"零副作用"自身承诺；
- 修正向用例时间炸弹：AA17 合规证据的 `generated_at` 由硬编码日期改为运行时现生成——
  硬编码日期超过 24h 证据时效窗后合规证据"过期"，正向用例假失败（2026-09-08 实锤 210/211）；
- SKILL.md 瘦身重构：两大段"实验状态"变更史外移至本文件；修复悬空引用"附录 Z"、
  过期计数（"7 件"/"191 项"/"200 项"/写死的回归项数）、前置检查资产清单漏 gen-gate-report.py、
  命令块 $SKILL 未定义即引用等文档债；前置检查 api 配置分支接入 legacy-config-check 实检、
  git 根检查放行 FLOWTEST_PROJECT_ROOT 布局；execution-gate.md 补齐 --cases/--drill/--gate-evidence
  参数文档；空白模板补 evidence_schema 示例、health_checks 双侧覆盖示例（netloc 匹配口径）、
  合法 env 占位与证据链指引；SKILL.md/contract-howto 的 health_checks 与 gates 铁律口径对齐
  validate 实际强制；field-level-compare.py 头部补 v2.10 条目、VERSION 与 write-manifest
  COMPARATOR_VERSION 两处常量同步 v2.10（版本串进不可篡改账本，必须与语义一致）；
  legacy-config-check 目标文件不存在 exit 2（fail-closed，CC5）。

## 第二十二轮（2026-09-08·李雅庄公路重跑实测：双端空值语义等价）

- 老系统空串 `''` vs 新系统 `null`——同一"无值"的表示层差异，此前 field-level-compare
  记为大量伪 diff；修复：`tol_ok` exact/abs 分支双空 → True（一空一非空仍 diff，
  不放过真实差异）；selftest 正负两向回归覆盖。

## 第二十一轮（2026-09-08·李雅庄公路双端试点反哺）

**api 通道适配原生化**——系统形态差异不再需要手写适配器，全部下沉为 systems 配置：

1. `login.chain` 多步登录链（步骤保存中间值 saveAs/savePath；值变换管道
   `${PASSWORD|md5_upper|rsa_pkcs1|uri}`；`noFollow`+`tokenFromRedirectQuery` 从 302 Location 取 token；
   配套 `rsaPubB64`/`whoami`）
2. `todo.mode: ledger` 账本待办（待办列表不暴露未保存实例的系统，由 launch/submit/getStepForm
   响应组装，任务/环节/实例码全为服务端返回值，零编造）
3. `todo.map` 待办键值实录映射（如 BPMN elementId→环节码）
4. `form.body` 采集请求体模板（GET/POST 皆可，`${TASK_ID}/${INSTANCE_NO}/${FLOW_CODE}` 占位）
5. `submit.retryOn` 引擎明确报错时先补前置按钮再重试一次（典型：新系统「尚无已保存单据」→ SAVE_FORM）
6. `assignee.resolver: next-assignees|orgrole` 办理人姓名→ID 服务端候选实时解析
   （含『(xx)』注记归一化；gen 的 expectAssignee 同步归一化）
7. `api.headers` 附加头（`${UUID}`）

pipeline 新增 `--cases C-01,C-02` 场景子集过滤（同源复算同步过滤）与 `--drill` 演练模式
（全账本但 summary.conclusion=DRILL，不出正式三态结论——生产保护/试点验证专用）。
legacy-config-check 识别 chain/ledger 新形态。

首个真实双端试点（李雅庄公路 WFA_HY_HZ_0150）已跑通老系统全链（00→04 五节点×27 字段采集提交）
并产出 00 节点双端对拍（字段集/默认值/约束三分类全量一致）；新系统链式推进仍 BLOCKED 于
必填校验——**按钮流（选择合同/磅房/执行单、盖章链）的 API 自动化尚未实现**，为当前最大边界。

## 第二十轮（2026-09-07·双跑实测反哺）

- `--gate-evidence <path>`：gate 证据由 pipeline 在 run 目录创建时原子拷入并预校验（结构 +
  sha256_16 现算一致），替代此前"文件监视器抢窗口拷入"的竞态注入 hack；
- gen_scenario 直接 emit flow_code；路由映射 route_map（按流程嵌套/扁平回退）；业务失败穿透。

## 第十四轮（2026-09-07·全量修复 + 第十三轮审计 + 补齐轮）

核心链 fail-closed，负向回归全绿。本轮起**全部命令改为 skill 自持路径直跑**
（`$SKILL/scripts` + `$SKILL/templates`）——项目内 `docs/自动化测试模板/` 与 `.flowtrace/scripts/`
副本仅为 install.sh 可选部署（CI/干净 clone 用），**不再是运行前提**。双端执行不依赖外部
FlowTrace CLI——默认 `FLOWTRACE_RUNNER=api`（内置 api-capture.py 纯 HTTP 采集，端点配置于
`.flowtrace/systems/api/`）；cli 仅作显式兼容后端。采信链（清残留+时间窗+身份绑定 / 账本不可覆盖
/ gate 结构化证据 / 三态结论）与通道无关。

第十三轮审计修复：

1. api 采集**默认 launch-first + 实例隔离**（每 run 发起本流程新实例、每步强制绑定 instance_no +
   服务端流程编码 todo.flowCodePath；复用待办须契约 `meta.instance_policy: reuse` 显式声明）
2. gate 证据**须能证明该 gate**（契约 `gates[].evidence_schema`：kind=report 报告字段断言 +
   flow_field 绑定 / kind=http 白名单 URL），无 schema/任意文件一律拒
3. 健康检查改由契约 `environments.health_checks` 驱动（health-check.py），不再硬编码端点

补齐轮：老系统（legacy）API 端点待按 F12 录端点——`legacy-config-check.py` 校验占位残留，
api-capture 检测到 `__F12_RECORD__` 立即拒跑（绝不假跑）。

第十四轮·全量修复：gate 证据断言加标量守卫（dict/list 值不再能绕过 contains/eq）；synthetic
占位 gate 不污染 P0/P1 计数；conclude evidence_paths 断链检测；gen 场景直接 emit flow_code；
health 并发探活；legacy-config-check 结构自检+进度对比；dry-run 批量场景解析。

## 第十二轮（2026-09-07·通道自持）

移除对外部 FlowTrace CLI 的默认依赖：`FLOWTRACE_RUNNER=api` 默认内置纯 HTTP 采集
（systems api 五原语 login/todo/launch/form/submit 全配置化）；`cli` 仅显式 `FLOWTRACE_CLI`
兼容（不再盲探 PATH）；`none` 全部诚实 BLOCKED。同一套脚本支持项目部署布局与 skill 自持布局。

## 第十一轮（2026-09-06·独立审计 P0 修复）

- `--force` 移除：账本与结论永不覆盖，同 run-id 重跑永久拒绝（重跑必须新 run-id）；
- 采集冒领防御三重校验：执行前清残留 + mtime 时间窗 + run_id/case_id 身份绑定；
- gate 证据结构化（type=file|url、sha256 现算、generated_at 时限、target_env 绑定）；
- "有 summary 必有完整账本"：账本写失败不产出结论件；pipeline 对 summary 缺失 exit 2 兜底；
- PASS 须绑定真实 versions.source/target/flow（unrecorded → 不予 PASS）。

## 第二~十轮（2026-09-05 ~ 09-07·逐轮对抗审计收敛）

依次封堵：test_ready 越级执行、凭据明文（含中文邻接值变体）、同源复算逐字节比对、
规则侧字符串集合化假断言、值级类型畸形假 MATCH、非有限数值（nan/inf/1e999）绕过、
原生 JSON 非有限字面量、tolerance 非法值、配对完整性、豁免通配滥用等——
完整"攻击向量→此前漏洞→现口径"对照表见 [adversarial-regression.md](adversarial-regression.md)。

## 当前已知边界（截至 2026-09-08）

- 老系统（legacy）api 端点待按 [f12-record.md](f12-record.md) F12 实录补齐（配置 schema 与
  占位防御已就位）+ 首个真实 run 三态产出；
- 按钮流（选择合同/磅房/执行单、盖章链）的 API 自动化尚未实现；
- 在此之前可用于**取证/立契/草稿生成/演练**，**不得作为正式 PASS/FAIL 结论来源**。
