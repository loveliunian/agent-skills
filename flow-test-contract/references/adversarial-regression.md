# adversarial-regression —— 负向回归清单与 fail-closed 规则总表（对齐 2026-09-08 第二十三轮·自检卫生轮）

> 读者：需要理解每条防御规则"防什么攻击、此前漏洞形态是什么"的审计者/维护者。
> 主 Skill 只保留「运行 selftest」入口；本文件是规则与攻击样例的完整展开。
> 修改 scripts/ 或 templates/ 下任何脚本后**必须**重跑 selftest 全绿（项数以 selftest 输出为准）。

## 1. selftest.py 负向回归分类清单

| 族 | 攻击向量 → 此前漏洞 → 现口径 |
|----|------------------------------|
| 证据类型伪装 | gate passed 非布尔（truthy 字符串）、observe optional 非字面 True、observe 非对象条目、对拍 status 非字符串/不可哈希形态（list/dict）、coverage/diffs/exempted 非列表或含非对象条目、重复用例 id → 此前 truthy/畸形被当合法 → 一律 BLOCKED |
| fixture_pairs 畸形 | dict 键集合化可被误读为有效配对 → 假配对→假 MATCH→假 PASS → 必须字符串列表，否则 BLOCKED |
| 规则侧字符串集合化族 | must_not_contain/expect_hidden/expect_visible/candidates_legacy 为字符串 → `set(map(str,…))` 字符集合化后**禁含/隐藏/可见断言静默失效**（must_not_contain="02" 而候选集实含 "02" 也过）→ 必须列表；立契期 validate 同步拒绝 |
| buttons 规则 | 非对象条目 / 声明非空但无任何带 node 的可比条目 → 此前静默过滤=声明维度被跳过 → BLOCKED（无 node 的对象注记条目允许，不得替代断言）；采集值非列表=证据损坏 BLOCKED |
| post_flow.registered | 非布尔（truthy 字符串双端同值此前记 diff 冒用 FAIL(1)）→ 只认字面布尔 |
| case_id | int 等畸形形态双端同值不再视为有效配对 → 必须非空字符串 |
| 值级类型畸形族（第八轮） | field/formula/post_flow.inherits/resources 采集值为 dict/list（同构垃圾经 str()/归一化记假 MATCH）；非空不可数值化值（"待定"/True）——norm_number 折 None 后 null_policy 把双端垃圾判"双空相等"记假 MATCH、单边记假 diff 冒用 FAIL(1) → 一律 BLOCKED |
| 非有限数值形态族（第九轮） | `float()` 对 "nan"/"inf"/"Infinity"/"1e999"（溢出折 inf）解析"成功"产出非有限值，绕过 ValueError raise：双端 inf==inf 假 MATCH（"inf" vs "1e999" 不同原始串互判一致）、nan 恒不等冒用 FAIL(1) → norm_number 数值化成功后 isfinite 检查，非有限一律 BLOCKED（合法有限大数 1e308 与全角数字不误伤） |
| 原生非有限浮点族（第十轮） | json.loads 默认接受非标准 JSON 字面量 Infinity/NaN/-Infinity（RFC 8259 不允许），原生 float inf/nan 走 exact/trim 路径**不经 norm_number**：双端 inf==inf 假 MATCH（可推假 PASS）、nan 恒不等冒用 FAIL(1) → 采集与 rules 加载 parse_constant 解析期拒绝（=采集损坏/rules 不可读）；validate 立契期拒 .inf/.nan、gen 零写入拒绝且 rules.json allow_nan=False（**三端同口径**） |
| tolerance 非法 | abs:inf / abs:1e999 / abs:nan / 负数 / 不可解析 → BLOCKED（绝不变相容忍差异）；立契期同拒 |
| 配对完整性 | 同名采集文件双端 case_id 必须一致且非空，否则 BLOCKED（防错拿他例采集）；单边缺失（六维一律，含 routing）= BLOCKED 不判 MATCH |
| 豁免滥用 | exemptions 须 id/reason/approved_by 齐全才生效（不可审计=不生效）；`scope:'*'+match:'*'` 全量豁免与 `match:'*'`（即使 scope 具体=整维度全免）→ BLOCKED；match 剥采集文件名前缀**只剥一次**（短键如 "00" 不跨维度误杀） |
| 豁免取证链族（1.3.0/1.3.1·P1→P0） | 真实 run 绑定此前只保护"生成器入口"——绕过 exempt **手写精确 match 豁免**（旧五字段）仍可被契约采信并吞差异 → 三重强制：①schema/validate TEST_READY 豁免**八字段必填**（+approval_ref/source_run_id/source_compare_sha256_16，sha 须 `^[0-9a-f]{16}$`）；②validate 对 source_run_id 经共享模块 `run_evidence.py` 全链核验；③比较器对无链/格式非法豁免**不生效**（invalid_exemptions，差异保留）→ 手写豁免在任何入口都不可采信；历史手工豁免须补链迁移或降 DRAFT |
| 伪造八字段取证链族（1.3.1·P0；1.3.4 结论复算加固） | 1.3.0 的 validator 核验是**简化版**（目录存在 + fc 现算 sha + summary 自述）——实测"无 run-manifest + 手写 summary=FAIL + 凭空 match + 手算 sha"两个自制 JSON 即可通过契约门 → ①核验抽为共享模块 `scripts/run_evidence.py`（生成器/validator 唯一实现，禁另写简化版）：五件齐全（+gates/case-results）、run-id 三方一致、config_snapshot **全部条目**（含契约）sha 现算、toolchain 指纹；②**1.3.4 起 `conclude_core.py` 纯评估器全量复算结论**（conclude/run_evidence/gen-final-report 三入口同一逻辑）：历史 BLOCKED 被手改 FAIL、契约事后修改/删除一律拒绝；③**scope/match 绑定源 fc.diffs 真实条目**（scope=dim 或 *，match 稳定键命中）——凭空精确键拒绝、OK run 豁免全非法；④回归矩阵：缺 manifest/未入账/sha 不符/run-id 错配/缺 toolchain/凭空 match/scope 不符/summary 与底层矛盾/缺 gates/fc 自洽/结论改写/契约改删/完全自洽不误伤 |
| 最终报告伪造族（1.3.4·P1） | 此前 gen-final-report 只要求 summary.json 含 conclusion——单个手写 summary 即可生成带"✅ PASS/证据同源"的正式报告 → 生成前强制证据链核验（五件齐全 + config_snapshot 全量 sha + conclude_core 结论复算与 summary 一致），失败 exit 2；`--allow-unverified` 仅产出醒目标注"未核验/不构成正式结论"的草稿；人工产品级发现拆独立 `人工发现.md`（机器永不覆盖），已有机器报告默认拒绝静默覆盖（--overwrite）；报告版本号读 SKILL.md frontmatter、run-id 不叠加双 `run-` 前缀 |
| 凭据空值语义族（1.3.4·P1） | Python 用 `if not os.environ.get(k)`——用户显式 `export K=''` 表达"禁止用保存凭据"时仍从 env 文件恢复；Bash 按变量是否存在判断 → Python 改 `if k not in os.environ`，两侧统一为"存在即存在（含空值）"；Bash 补齐文件属主检查（镜像 Python 0600+当前用户所有）；quick 新增真正的 Python/Bash 交叉检查（此前 quick 只测 Python） |
| 反向分支结论冒充族（1.3.0/1.3.1·P1→P2） | 取证源 23 支、反向 3 支仅 drill 探索、skipped=0 时 generate complete=true、conclude 只阻断 skipped——20/20 正向 PASS 被表述为"全分支 PASS" → 双态完成度：`branch_coverage.accounted_complete`（分支全分类）≠ `formal_complete`（反向也为 0）；generate 落双态字段（validator 强制必填+自洽，旧契约缺字段=拒绝重生成）；**1.3.1 收紧：reverse_explore>0 且正向全 PASS → 顶层 conclusion=BLOCKED**（1.3.0 仅写限定字段仍会被只读 conclusion 的 CI/报表误判全量成功）+ `forward_conclusion=PASS`（信息性字段，blocked_reasons 明示非正式结论）+ summary.md/final report 显著标注；正向有真实差异维持 FAIL；契约自称 formal_complete=true 却有反向分支 → 自相矛盾 BLOCKED；反向正式结论须另立正式契约单独 run 绑定 |
| selftest 分级（1.3.0·P2） | 每会话强制全量回归成本高（分钟级）→ `selftest.py --quick`：MANIFEST 资产/全部脚本语法/关键门禁抽样（实例 test_ready、空白模板拒绝、豁免取证链、反向分支结论限定、runtime env 安全）秒级前置；缺省/--full 仍为全量（**条数以 selftest 实跑输出为准**；版本发布与深度审计唯一口径，quick 不可替代） |
| operations 配置前置校验族（1.3.6·P0） | 此前 `api.operations` 只在 submit 命中时才校验，且 `_submit_operation` 在发出退回/作废写请求**之后**才干验 backTarget/refetch——实测缺 refetch 配置时老系统已完成退回才报 MISSING_REFETCH，本地账本还提前删了原任务；命中键但条目非对象时静默回退统一 commitWorkflow（v1.3.5 声称已消除的错误路径）；`ledger: reftch` 拼写错被当 finish；backTarget 命中行缺 idField 会发送字符串 "None"。修复：抽取共享 `scripts/ftc_ops_config.py`（api-capture 启动即校验 + legacy-config-check 结构完整性共用）——**任何登录/发起/提交前**全量校验 path/ledger/refetch/backTarget/successStatus/body，命中非法即拒不回退；标量守卫拒 'None'；refetch 有限轮询（pollSeconds）避免异步未现即 BLOCKED；selftest 覆盖（配置前置 die 且零请求 / 拼写错 / 缺 refetch / 缺 idField / 轮询 0→1 / legacy-config-check 不再报"可启动"） |
| reuse 消歧族（1.3.6·P0） | 此前 `find_task` 在未知实例号（instancePolicy=reuse）时只校验节点+流程编码即返回**第一个**同流程同节点待办——实测两个同流程同节点任务时任取真实生产单据。修复：收集全部候选后**必须恰一命中**，多候选一律 BLOCKED；支持 instanceNo/businessKey/fixtureSelector 消歧（后二者待办字段路径由 `todo.selectorPaths` 指认，缺失 fail-closed）——selftest 覆盖多候选 BLOCKED/选择器消歧/无路径拒绝 |
| 预保存失败族（1.3.6·P0） | 此前 `save_with_form_data` 调用 `_post(pre_body)` 完全忽略返回状态与 success=false——实测 SAVE_FORM→HTTP 500 仍继续 SUBMIT→HTTP 200，最终 RETURNED_SUCCESS，场景输入未落库却形成假 PASS。修复：预保存复用正式提交的 HTTP 状态/业务状态校验，失败即 die 且禁止发送 SUBMIT |
| 豁免来源最小键族（1.3.6·P1） | 此前 `run_evidence` 只在 contract 条目存在时校验，删掉 `config_snapshot.contract` / `evidence_paths` 的手改 manifest 仍被接受；`toolchain.manifest_sha256` 仅非空即通过。修复：强制契约模式账本固定最小键集合（contract/rules/scenarios）+ 非空 evidence_paths；manifest_sha256 须 `^[0-9a-f]{64}$`——selftest 覆盖删除登记/清空 evidence_paths/伪造 SHA 三态 |
| 报告统计防伪造族（1.3.6·P1） | 此前 gen-final-report 只比对 conclusion，随后又从 summary 读取 P0/P1/用例数——保持真实 conclusion=FAIL、只改统计即可生成"已核验"报告（SAME_CONCLUSION_MUTATED_SUMMARY_EXIT=0）。修复：报告数值一律取自 conclude_core 重算结果；summary 中出现的 canonical 统计字段（p0/p1/required_cases/差异条数/branch_scope）与重算不一致即核验失败；`--allow-unverified` 改写入 `对比测试报告-未核验草稿.md`（机器字段 UNVERIFIED，PASS 仅标"summary 自述"） |
| runs-dir 解析族（1.3.1·P1） | 全分支契约生成在 `自动化测试/生成件/`，pipeline 固定 `--runs-dir "$(dirname "$CONTRACT")/对比测试"` 解析到不存在的 `生成件/对比测试`——合法历史豁免被误 BLOCKED 且无覆盖入口 → pipeline 新增可选 `--runs-dir`（argv 转发）；缺省由 validate-contract 智能解析：契约同目录/对比测试 → 上一级/对比测试（覆盖 生成件/ 布局） |
| 探索器写门槛族（1.4.0） | 自由探索（explore-channel）能发起实例+逐环节提交（老系统=生产环境）——若默认可写/门槛在登录后才生效，误触发即生产写操作 → 三层防线：①默认只读（--observe-only：登录+待办结构观察，零实例零表单）；②写探索显式 `--apply` 且**门槛检查前置到任何登录/网络动作之前**（fail-closed 的顺序也必须 fail-closed）；③公式探针再显式 `--fill`（且需 systems 配置 save_with_form_data——不猜测保存端点，未配置如实记录跳过）；launch-first 实例隔离复用 api-capture 同一实现（decoy 不被触碰）；merge 双端不齐/流程编码不一致 → 拒（单端不成经验、不许跨流程拼经验）；经验库只产建议不改契约（契约是受保护事实源）；探索永不产出 PASS/FAIL |
| 凭据防泄漏 | accounts 只认 env 引用；validate 文本扫描覆盖中文邻接值（密码：/口令=，含全角冒号）——自由文本位夹带明文立契期与产物密扫双端拒绝；mask 短值（<8）全遮 `***` |
| 账本防篡改 | **write-manifest/conclude 均无 --force（第十一轮）——账本与结论永不覆盖**；write-manifest 拒覆盖/并发（单赢家原子硬链接占位）；conclude sha256 复算、条目剥离 hash、abs_path/sha256_16 非字符串、abs_path 指向诱饵副本（非报告目录同名文件）=BLOCKED；PASS 需三件证据全入账；**PASS 须绑定真实 versions.source/target/flow（unrecorded→BLOCKED，第十一轮）** |
| 强制重写面（第十一轮） | 此前 `--force` 可重写账本与结论（违背"不可篡改/run-id 不复用"）→ 参数已移除：传 `--force` 即 argparse exit 2；同 run-id 二写一律 exit 3；pipeline 同 run-id 目录已存在即拒绝（dry-run 同校验） |
| 采集冒领面（第十一轮） | 此前 runner"CLI 退出码 0 + 双端采集文件存在"即 PASS——预置/遗留采集可被本次运行冒领 → 三重校验：执行前清空 field-captures/ 残留；mtime ≥ 本次执行开始；采集须 JSON 对象且 run_id==本 run-id、case_id==本用例（缺身份/错配→BLOCKED） |
| gate 自由文本证据面（第十一轮） | 此前自写 {"passed":true,"evidence":"任意文本"} 即放行部署/账号/数据/画布 gate → gate-evidence-check.py 结构化校验：type ∈ file\|url；file 须 path+sha256_16 现算一致；url 须现场 HTTP 200；generated_at 须 ISO8601、不未来（>5min 容差=伪造）、不过期（默认 24h，GATE_EVIDENCE_MAX_AGE_SEC 可调）；target_env 非空且与 TARGET_VERSION 一致；证据自报 passed=false=未通过——任何不符 → gate passed=false |
| 完整账本面（第十一轮） | 此前置 gate 失败时 manifest 写失败被忽略仍出 summary（BLOCKED 但无 run-manifest=不完整 EXECUTED 账本）→ conclude 对账本缺失/损坏/run_id 错配**不产出 summary.json/md**（有 summary 必有完整账本）；finish_block 账本写失败 → 跳过 conclude；pipeline 兜底：summary 缺失 → exit 2 |
| 通道自持族（第十二轮） | 外部 FlowTrace CLI 依赖（未检出=全链 BLOCKED、接口不可控）→ 移除：默认 `FLOWTRACE_RUNNER=api`（内置 api-capture.py，端点全配置化，五原语 login/todo/launch/form/submit）；cli 仅显式 FLOWTRACE_CLI（不再盲探 PATH/默认路径，BB5）；api 采集失败（不可达/凭据 env 缺失/配置缺失/找不到待办）一律 BLOCKED 不落 capture（半执行采集绝不让下游误判 PASS，BB2-BB4）；api capture 与浏览器通道同构（身份三要素+steps.fields，直供对拍器 OK，BB1/BB6）；凭据仍零明文（actorMap→env，缺即拒）；日志零请求体（错误只报 status+path） |
| 实例隔离族（第十三轮审计） | api 采集此前"首步按 node 从当前用户全部待办盲取"——他流程同 node 真实任务会被采集并提交（误操作+错标 capture）→ 默认 **launch-first**：每 run 先发起本流程新实例（元素 ID 解析 `LAUNCH_ELEMENT_ID_<FLOW_CODE>` env → elementIdEnv，缺即拒不猜测），此后每步**强制绑定 instance_no** 且 todo 条目按 flowCodePath 验服务端流程编码==场景 flow_code（BB1：他流程 decoy 不被触碰；BB1b：缺元素 ID → BLOCKED）；复用待办须契约 `meta.instance_policy: reuse` 显式声明且 todo.flowCodePath 必配，reuse 只采本流程待办不碰 decoy（BB7/BB7b） |
| 证据语义族（第十三轮审计） | gate 证据此前只验格式/哈希/时效/env——任意新建文件+哈希即可过 GATE-CANVAS/DEPLOY（证据证明不了 gate）→ 契约 `gates[].evidence_schema`（validate-contract 立契期强制）：kind=report 须 file_format 解析 + required_fields（eq/contains/regex/gte/lte）断言 + flow_field 绑定契约 flow_code；kind=http 须 url 命中 allowed_urls 白名单且现场 200；type 与 kind 不符/无 schema/任意文件 → passed=false（AA13-AA17b 正负全链） |
| 健康契约族（第十三轮审计·P1） | 健康检查此前硬编码三个 localhost 端点（不可移植）→ health-check.py 按契约 `environments.health_checks`（curl 描述串：url + # expect N）执行；固定 curl 参数重发不 eval 契约串（任意命令串 → exit 2）；契约缺 health_checks → exit 2（BB8 正负） |
| 空值语义族（第二十二轮·李雅庄公路重跑实测） | 老系统空串 ''/新系统 null 属同一"无值"的表示层差异，此前 exact/abs 容差路径记伪 diff（60+ 条假差异）→ `tol_ok` 双空判等（一空一非空仍 diff，不放过真实差异） |
| 自检卫生族（第二十三轮） | ①selftest 进程内 importlib 动态加载被测脚本时 Python 落 `scripts/__pycache__/*.pyc`——污染 skill 目录，违反"零副作用"自身承诺 → `sys.dont_write_bytecode=True`（对齐 T7 的 dry-run 零字节码口径）；②正向用例硬编码 `generated_at`（2026-09-07T10:00）次日超过 24h 证据时效窗 → 合规证据"过期"→ 正向用例假失败（时间炸弹）→ 正向用例时间戳一律运行时现生成，负向用例才允许写死过期/未来时间 |
| 标量守卫族（第十四轮·P0-1） | gate-evidence required_fields 断言此前对 dict/list 实际值 str() 后 contains 可被 `{"any":"DEPLOYED"}` 绕过 → eq/contains/regex 前加标量守卫（dict/list/None 一律拒绝；DD1） |
| 计数口径族（第十四轮·P1-8） | finish_block 占位 GATE-PIPELINE（severity=P99/synthetic）此前被 conclude 计为 P0/P1 → synthetic:true 的 gate 跳过计数但仍以 passed=false 阻断 PASS（DD2）；conclude evidence_paths 指向不存在目录 → BLOCKED（DD3，追溯断链） |
| 配置自检族（第十四轮·P1-3/P1-6） | legacy-config-check 增加结构完整性检查（api 五块/flowCodePath/actorMap 缺件即报，DD5）与 --progress-file 进度快照对比（DD6）；health-check 并发探活（P1-2） |
| 配置检查 fail-closed 族（第二十三轮） | legacy-config-check 目标文件不存在此前只"⚠ 跳过"仍 exit 0——路径打错得到假绿（占位检查器对"无物可查"放行）→ exit 2（与配置不可读同类，CC5） |
| 产物自省族（第十四轮·P0-2/P2-4） | gen_scenario 直接 emit flow_code（场景不再依赖 id rsplit 反推，DD4）；dry-run 场景批量 YAML 解析（单解释器替代逐文件 python） |
| 补齐占位防御族（第十三轮·补齐轮） | 老系统（legacy）端点待人工 F12 录——`systems/api/*.yaml` 用 `__F12_RECORD__` 显式占位；api-capture 启动时检测任意残留即拒（绝不假跑）；legacy-config-check.py 输出可粘贴到 issue 的待录清单；占位全清 + mock legacy 端到端 PASS（CC1-CC4） |
| 交叉核对 | 契约必测用例缺失/未登记 id、重复 YAML 键、run-id 错配 → BLOCKED |
| 同源复算 | pipeline 的 --rules/--scenario-dir 必须与契约确定性重生成**逐字节**一致（含 rules 侧字节比对）——手改规则塞豁免/改容差在入口拦截 |
| 提交漏洞闭环族（1.4.5·P0） | ①operations **数字/布尔键**此前被 validate `str(button)` 强转过 schema，运行时按字符串命中永不命中 → 静默回退统一 submit（退回/作废被编码成普通提交）→ 键须原始字符串类型，否则入口即拒；②ledger=refetch 的定位键（BACK_NODE/INSTANCE_NO/task_id）此前在 /backWorkflow **写出之后**才校验（生产已退回本地才报错）→ 任何写请求前全量验证；③retryOn 前置按钮的响应（_st/_ob）此前被丢弃——前置 SAVE 500、重试 SUBMIT 200 仍报成功 → 前置复用 _resp_bad，失败即 die 禁止重试；④业务失败判定此前只认 `success is False`——success:0/"false"/""/None 等 falsy 变体被当成功 → 严格谓词 `_business_failed`（success 键存在但值 ∉ successValues[默认仅 True] 即失败；systems submit.successValues 可配置） |
| 探索器安全面（1.4.5） | ①空办理人提交：无候选办理人时此前仍自动提交空值（生产默认分派=非预期流转）→ 拒绝空办理人，submit 前中断；--apply 默认 advance=none（要推进显式 --advance first）+ 显式 --actor 必填 + --route 须在实时候选内 + --assignee 显式兜底；②敏感值泄露：探索产物默认把表单原值写进 docs 共享面 → 默认脱敏 #sha16:长度（merge 同值判定在脱敏串上仍成立），--include-values 才落原值且产物标记 includes_sensitive_values；③公式探针读回此前缺实例上下文（WorkflowFlag 系统读回失败/读错）→ 与标准执行路径同参；④产物防静默覆盖：同侧实录/经验库已存在即拒（--overwrite 放行）；⑤reuse 消歧选择器此前 schema/生成链均缺（文档承诺无法经正式链使用）→ 契约 cases 增 instanceNo/businessKey/fixtureSelector（标量或 {legacy,current} 分侧），gen 确定性透传场景（仅 reuse 策略），api-capture 按本侧 id 解析、缺侧即拒 |
| 路径与用法 | 路径穿越、非法 run-id 变体（含尾随换行/引号空格/`..`）→ pipeline 入口即拒（exit 2，不与 FAIL(1) 混淆）；用法错误 exit 2 |
| 落账/结论器健壮 | write-manifest 内部异常 exit 2 兜底；conclude 内部异常一律 exit 2（绝不 crash 伪装 FAIL）；对拍器顶层异常 BLOCKED(2)（outdir 被占用/父目录只读等） |
| dry-run 零副作用 | 只校验+打印计划；不建目录、不 curl、不写文件（含 `__pycache__`——复算解释器以 -B 运行） |
| 路由门禁放宽族（1.0.1·发布后 P0） | pipeline.sh `DRILL=false` 为非空字符串，`${DRILL:+--allow-route-drift}` 非空判断恒真——不带 --drill 的正式运行也向 validate 传放宽 flag，"用例路由 ∉ nodes.next"被降级 WARN 绕过 fail-closed（此前 233 条回归仅覆盖 validator 直调双态，未覆盖 pipeline 正式反例）→ 参数解析后显式布尔派生 `DRILL_ROUTE_FLAG`/`DRILL_NOTE`（规约：布尔旗标一律 `= true` 判断，`:+` 仅限空串初始化变量）+ pipeline 级正反两向回归 G7b（正式 dry-run+矛盾→拒绝(2) 失败点=路由门）/G7c（--drill+矛盾→WARN 放行 失败点=同源复算） |
| 其他 | 脱敏（mask len<8 全遮 / 带盐 sha256 盐随机记录于 redact_salt；原文零出现）；exact 与 abs 容差下布尔与非布尔（True vs 1）不判等（abs 分支原始值回退同样防 bool 陷阱）；field-compare.md 动态值转义换行/ESC（防采集侧注入伪造标题行）；summary.md 注入转义；meta.draft 对拍拒绝 |

## 2. conclude.py v3.9 三态硬校验（摘要）

| 结论 | 关键条件 | exit |
|---|---|---|
| PASS | 四类证据齐全非空且类型合法 + gates 全过（布尔真）+ required 全 PASS + 无未豁免差异 + 无非 optional OBSERVE + 契约交叉核对一致 + 三件证据全部入账、sha256 复算一致且登记路径即报告目录同名文件 + versions.source/target/flow 全部已记录（第十一轮）+ **branch_coverage 存在时须 formal_complete=true（reverse_explore>0 → BLOCKED + forward_conclusion=PASS 信息性字段，1.3.1）** | 0 |
| FAIL | 存在未豁免语义差异或用例 FAIL | 1 |
| BLOCKED | 无完整可信账本（缺失/损坏/run_id 错配→**且不产出 summary**，第十一轮）；任一必要证据缺失/为空/损坏/类型非法；gate 失败；required 非 PASS；0 必测；对拍 BLOCKED；非 optional OBSERVE；run-id 错配；账本任何不符；versions unrecorded；结论器内部异常一律 exit 2（绝不 crash 伪装 FAIL） | 2 |

## 3. 快速入口

```bash
python3 ~/.agents/skills/flow-test-contract/templates/selftest.py          # 全量负向回归（发布/深度审计；项目部署布局：docs/自动化测试模板/selftest.py）
python3 ~/.agents/skills/flow-test-contract/templates/selftest.py --quick  # 会话前置快检（秒级：资产/语法/关键门禁；不可替代全量）
```

细节实现：`scripts/field-level-compare.py`（v2.9 修复注释头部含各轮修复清单）、`conclude.py`、`pipeline.sh`、`validate-contract.py`（均在 skill `scripts/`+`templates/`；项目部署副本位于 `.flowtrace/scripts/` 与 `docs/自动化测试模板/`）。
