# execution-gate —— 执行、账本与三态结论（2026-09-08 第二十三轮对齐；含第二十/二十一轮参数）

> 读者：跑流水线与解读结论的执行者。脚本均在 skill 自持路径 `~/.agents/skills/flow-test-contract/scripts/`（项目部署布局：`.flow-test-contract/scripts/`）。
> 通道层（api 采集五原语/capture 契约/双布局）另见 [capture-channels.md](capture-channels.md)。

## pipeline.sh（契约模式参数化 + legacy 兼容 + 双布局）

```bash
# 契约模式（推荐；凭据自动从 $RUNTIME_DIR/env 加载——v1.3.3 去 .env 化）：
bash $SKILL/scripts/pipeline.sh \
  --contract docs/<流程>/自动化测试/test-contract.yaml \
  --scenario-dir docs/<流程>/自动化测试/生成件/flowtrace-scenarios \
  --rules docs/<流程>/自动化测试/生成件/compare-rules.json \
  [--run-id run-xxx] [--dry-run] \
  [--cases C-01,C-02] [--drill] [--gate-evidence <file>]
# legacy 模式（港口煤发运旧链路，不传 --contract）：
bash $SKILL/scripts/pipeline.sh [--skip-parse] [--plants a,b]   # 旧流水线资产在 .flowtrace/
```

可选参数（第二十/二十一轮）：

- `--cases C-01,C-02`：场景子集过滤——runner/账本/同源复算同步只算选中用例（未选中场景留在
  场景目录不参与同源比对）；**正式结论必须全量场景**（不带 --cases）；
- `--drill`：演练模式——全账本（执行/对拍/落账照常）但不出正式三态结论，summary.conclusion=DRILL；
  健康检查失败仅记录不阻断。用于生产保护（如老系统办结会触发后置流程自动发起时的截断演练）
  与试点验证；正式 PASS/FAIL/BLOCKED 必须不带 --drill 全量重跑；
- `--gate-evidence <file>`：门禁证据文件，pipeline 预校验（结构 + sha256_16 现算一致，只读零副作用）
  后在 run 目录创建时原子拷入 run 目录根 `gate-evidence.json`（对比测试/<run-id>/，单 run 单目录）；dry-run 同步预校验。

步骤（契约模式）：
```
0 run-id 计划   run-id 已存在（exec/report 目录任一非空）→ 拒绝 exit 2（dry-run 同样校验；
               第十一轮：run-id 不可复用——预置/遗留/碰撞目录一律拒绝，重跑必须新 run-id）
1 契约校验   validate-contract --level test_ready（DRAFT 契约在此被拦——越级执行封死）；
             tolerance 只认 exact / abs:<有限非负数>（abs:inf/1e999/nan/负数=可容忍或扭曲
             一切数值差异，立契期拒绝）；随后**同源复算**：--rules 与 --scenario-dir 必须
             与"由契约确定性重生成"的**字节**完全一致（rules 侧同样逐字节比对——重排/重缩进
             即拒；手改规则塞豁免/改容差、改场景内容，在入口拦截——契约是唯一事实源）。
             用法错误（未知参数/缺值）exit 2，不与 FAIL(1) 结论码混淆
2 前置门禁   健康检查按契约 environments.health_checks 执行（health-check.py v1，
             第十三轮·P1：不再硬编码端点——curl 描述串只贡献 url+expect，固定参数重发不 eval；
             契约缺 health_checks → exit 2）。契约 gates 合并：无自动检查器的 gate 必须由
             run 目录根 gate-evidence.json（对比测试/<run-id>/）提供证据，且证据须**能证明该 gate**
             （gate-evidence-check.py v2，第十三轮·P0：通用 file|url 不再放行）——
             每个 gate 在契约声明 evidence_schema（validate-contract 立契期强制）：
               kind=report：证据为报告文件（file_format json/csv/txt），sha256_16 现场复算，
                           required_fields[{path, op: eq|contains|regex|gte|lte, value}] 逐项断言，
                           flow_field（若有）须 == 契约 meta.flow_code（证据绑定本流程）
               kind=http：  证据 URL 须命中 evidence_schema.allowed_urls 白名单且现场探活 200
             证据条目通用字段：generated_at（ISO8601 时限内）、target_env（设 TARGET_VERSION
             时须一致）、显式 passed:false=自报未通过。缺 schema/任意文件/type 与 kind 不符
             → passed=false → fail-closed BLOCKED
3 场景执行   run-contract-scenarios.py v2.0（第十二轮·通道自持）+ api-capture.py v2.0
             （第十三轮·实例隔离）：
             后端 FLOWTRACE_RUNNER=api（默认）→ 内置 api-capture.py 纯 HTTP 采集
             （systems api 五原语 login/todo/launch/form/submit，端点全配置化——不依赖
             外部 FlowTrace CLI/浏览器）；=cli 仅显式 FLOWTRACE_CLI 兼容（不再盲探
             PATH/默认路径）；=none → 全部 BLOCKED(runner-unavailable)，不伪造。
             执行策略：默认 **launch-first**——每 run 先发起本流程新实例（元素 ID 解析
             env LAUNCH_ELEMENT_ID_<FLOW_CODE> → systems launch.elementIdEnv，缺即拒不猜测），
             此后每步待办**强制绑定 instance_no** 且按 todo.flowCodePath 验服务端流程编码
             == 场景 flow_code（防采/提交他流程同 node 真实任务）；复用待办须契约
             meta.instance_policy: reuse 显式声明 + todo.flowCodePath 必配；v1.3.6 起
             复用首步同流程同节点**必须恰一命中**（多候选=BLOCKED；instanceNo/businessKey/
             fixtureSelector 可消歧，后二者路径由 todo.selectorPaths 指认）。
             api.operations 按钮原语在**任何登录/发起/提交前**经 ftc_ops_config 全量校验
             （命中键但非法即拒、不回退统一 submit）；表单预保存失败（save_with_form_data）
             即 die 且不发 SUBMIT。
             无论后端，PASS 铁律：退出码 0 **且**双端 capture 过三重采信校验
             （①执行前清空 field-captures/ 残留 ②mtime ≥ 本次执行开始 ③capture 为
             JSON 对象且 run_id==本 run-id、case_id==本用例）——裸退出码/预置遗留
             文件不采信（缺任一=BLOCKED）
             产物 case-results.json 落 run 目录（对比测试/<run-id>/——exec/report 自
             第三十轮起合并为单 run 单目录，不再分 executions/、reports/ 子目录；结论器读取处，
             已接通）；结果 id=场景 case_id（契约用例号 C-xx）
4 语义对拍   field-level-compare.py v2.10（见下）
5 落账+结论  write-manifest（**--allow-unrecorded-versions 固定传入**：账本诚实记录 unrecorded，
             正式 PASS 的版本绑定由 conclude 强制；同 run-id 重写/并发=exit 3
             单赢家（原子硬链接占位）；登记文件缺失=exit 4；**内部异常（登记文件不可读等）
             一律 exit 2 兜底（第七轮——不引入未定义 crash 码）**；run-id 只允许
             [A-Za-z0-9][A-Za-z0-9._-]* 且不含 ..（pipeline 与 write-manifest 同一口径，
             引号/空格 run-id 在 pipeline 入口即拒——防内插注入）；目录登记（scenarios/）
             按目录哈希；记录 contract/rules/scenarios/case-results/gates/field-compare
             的 sha256+abs_path）→ conclude（自动带 --contract 做交叉核对）；
             **summary.json 未产出（账本断裂）→ pipeline exit 2 兜底，绝不冒充结论**（第十一轮）
```

finish_block（前置失败路径，第十一轮）：先补三件占位证据 → write-manifest（--allow-unrecorded-versions）
**写入成功且 run-manifest.json 落盘后**才调 conclude 产出 summary；账本写入失败 → 不产出结论件，
log 后 exit 2——"BLOCKED 但无 run-manifest"的不完整账本面已封死。

**dry-run 零副作用**：只校验（契约 test_ready 级 + compare-rules 可解析 JSON + 场景 YAML 可解析 + **同源复算**）+ 打印计划；不建目录、不 curl、不写文件（含 `__pycache__` 字节码——复算解释器以 `-B` 运行）。

## field-level-compare.py v2.10 语义要点

- **双端空值等价（第二十二轮）**：exact/abs 容差下双端 `''`/None 视为同一"无值"判等
  （表示层差异不记伪 diff）；一空一非空仍 diff
- 维度：field / formula / routing / buttons / resources / post_flow（规则声明而采集缺失 → BLOCKED）
- 粒度：case 文件 × step × 字段，绝不跨步骤折叠；current 侧按 **target_field** 读取
- **顶层异常兜底 exit 2**：outdir 被普通文件占用/父目录只读等内部异常一律 BLOCKED(2)——绝不 crash 以 exit 1 冒用 FAIL 结论码
- **buttons 采集值非列表（字符串等）= 证据损坏 → BLOCKED**（第六轮：此前字符集合化可记假 MATCH；与 routing 非列表检查同口径）
- **规则侧字符串集合化族（第七轮）**：routing.candidates_legacy / must_not_contain 与 buttons.expect_visible / expect_hidden 非列表 → BLOCKED——字符串被 set(map(str,…)) 字符集合化后，**禁含/隐藏/可见断言静默失效记假 OK**（must_not_contain="02" 而候选集实含 "02" 也可过）；立契期 validate 同步拒绝
- **fixture_pairs 非字符串列表（dict/字符串）= 证据损坏 → BLOCKED**（第七轮：dict 键集合化可与 fixture_pair_id 巧合被误读为有效配对——假配对→假 MATCH→全链假 PASS）
- **buttons 规则非对象条目 / 声明非空但无任何带 node 的可比条目 → BLOCKED**（第七轮：此前静默过滤=声明维度被跳过；无 node 的对象注记条目允许，但不得替代断言——实例契约的 `- rule:` 注记形态不受影响）
- **post_flow.registered 非布尔 → BLOCKED**（第七轮：truthy 字符串双端同值此前记 diff 冒用 FAIL(1)；只认字面布尔，与 gates passed 同口径）
- **配对 case_id 必须非空字符串**（第七轮：int 等畸形形态双端同值不再视为有效配对）
- **值级类型畸形族（第八轮）**：field/formula/post_flow.inherits/resources 的采集值为 dict/list（非标量）→ BLOCKED——同构垃圾经 str()/归一化后可记**假 MATCH**；非空但不可数值化的值（"待定"/True 等）在 number 归一化与 abs 容差路径一律 BLOCKED——此前 norm_number 折 None，null_policy 把双端垃圾判"双空相等"记假 MATCH、单边记假 diff **冒用 FAIL(1)**（第七轮封的是容器级——fixture_pairs/断言列表/registered/case_id；值级为本轮补面）
- **非有限数值形态族（第九轮）**：`float()` 对 `"nan"/"inf"/"Infinity"/"1e999"`（溢出折 inf）解析**成功**但产出非有限值——绕过第八轮的 ValueError raise：双端 inf==inf 记**假 MATCH**（`"inf"` vs `"1e999"` 两个不同原始串也互判一致，掩盖真差异）、nan 与任何值比较恒 False 记假 diff **冒用 FAIL(1)**；norm_number 在数值化成功后加 `math.isfinite` 检查，非有限一律 raise → BLOCKED（合法有限大数如 1e308 与全角数字不受影响——`float()` 经 unicode_todecimal 接受全角，数值语义一致照常 MATCH）
- **原生非有限浮点族（第十轮）**：json.loads 默认接受非标准 JSON 字面量 `Infinity/NaN/-Infinity`（RFC 8259 不允许），原生 float inf/nan 走 exact/trim 路径**不经 norm_number**——双端 inf==inf 假 MATCH（可推假 PASS）、nan 恒不等冒用 FAIL(1)；采集与 rules 加载 parse_constant 解析期拒绝（=采集损坏/rules 不可读）；validate 立契期拒 .inf/.nan、gen 零写入拒绝且 rules.json allow_nan=False（三端同口径）
- **tolerance 非法=证据损坏**：`abs:inf`/`abs:1e999`/`abs:nan`/负数/不可解析 → BLOCKED（绝不变相容忍差异）
- **配对完整性**：同名采集文件双端 case_id 必须一致且非空，否则 BLOCKED（防错拿他例采集）
- fixture：双端声明**交集**；field_mappings 可显式 `fixture_pair_id` 绑定（未在 fixtures 登记会被 validate 拒）
- **单边缺失（六维一律，含 routing）= BLOCKED**，不判 MATCH；采集/规则结构畸形（非对象/非列表/缺键）= BLOCKED（exit 2），绝不变 crash 假 FAIL
- compare-rules 带 `meta.draft: true`（--allow-draft 产物）→ 拒绝对拍
- observe 条目带 `optional` 标记：契约 `field_mappings[].optional: true` 才 optional；其余非 optional
- 脱敏：mask（**len<8 全遮 `***`，≥8 才保留首尾 2 字符**）或带盐 sha256（盐随机、记录于输出 redact_salt；原文零出现）；exact 容差下布尔与非布尔（True vs 1）不判等
- 豁免：规则 `exemptions[]`（来自契约）按 dim+key 扣减进 exempted；**1.3.0 起须八字段齐全才生效**（id/reason/approved_by + approval_ref/source_run_id/source_compare_sha256_16，sha 须 16 位小写 hex；不可审计/无取证链=不生效，差异保留；格式非法计入 invalid_exemptions）——生成器入口（exempt 核验账本）、契约入口（validate-contract 经共享模块 `run_evidence.py` 全链核验：五件齐全/run-id 三方一致/账本 sha 现算/toolchain/底层证据重算/scope-match 绑定源 diffs——1.3.1）、对拍入口（本比较器）三重强制；`scope:'*'+match:'*'` 全量豁免与 **`match:'*'`（即使 scope 为具体维度=整维度全免）→ BLOCKED**——豁免只作用于本维度本键；match 支持**去采集文件名前缀一次**的稳定键（如 `s1/CS->CS`、`formula/A.1`）——只剥一次前缀，短键（如 `00`）不再跨维度误杀
- exact 与 abs 容差下布尔与非布尔（True vs 1）均不判等（abs 分支原始值回退同样防 bool 陷阱）
- field-compare.md 动态值转义换行/ESC（防采集侧注入伪造标题行；结论只认 json）

## 三态判定（conclude.py v3.9，fail-closed）

| 结论 | 条件 | exit |
|---|---|---|
| PASS | 四类证据齐全非空且**类型合法** + gates 全过（passed 必须布尔真）+ required 全 PASS + 无未豁免差异 + **无非 optional OBSERVE** + 契约交叉核对一致 + **gates/case_results/field_compare 三件证据全部入账、sha256 复算一致且登记路径即报告目录同名文件（防诱饵副本）** + **账本 versions.source/target/flow 全部已记录（非 unrecorded——第十一轮）** + **branch_coverage 存在时须 formal_complete=true（1.3.1：reverse_explore>0 的正向全 PASS 一律不产顶层 PASS → BLOCKED + forward_conclusion=PASS 信息性字段）** | 0 |
| FAIL | 存在未豁免语义差异或用例 FAIL（reverse_explore>0 时维持 FAIL——FAIL 无"成功"误读面，不做范围降级） | 1 |
| BLOCKED | **无完整可信账本（run-manifest 缺失/损坏/非对象/run_id 缺失或与目录错配→且不产出 summary.json/md——第十一轮"有 summary 必有完整账本"）**；任一必要证据缺失/为空/损坏/**类型非法**（gates 非列表、passed 非布尔、observe optional 非字面 True（'yes'/'false'/1 等 truthy 伪装按非 optional 处理）、**observe 含非对象条目（第六轮）**、对拍非对象或 status 非 OK/FAIL/BLOCKED（**含不可哈希形态 list/dict——第七轮结构化 BLOCKED 不 crash**）、coverage/diffs/exempted 非列表或含非对象条目、observe/diffs 非列表、case id 重复/缺失/状态非字符串）；gate 失败；required 非 PASS（含 SKIP/ERROR/未知）；0 必测；对拍 BLOCKED；**非 optional OBSERVE**；契约必测用例缺失或出现契约未登记 id；账本登记文件 hash 不符/丢失/**条目被剥离 hash**/**abs_path/sha256_16 非字符串（第七轮）**/**三件证据未全入账**/**abs_path 指向诱饵副本（非报告目录同名文件）**；契约含重复 YAML 键；summary 已存在（**--force 已移除——第十一轮**）；**reverse_explore>0 且正向全 PASS（1.3.1 分支范围限定——结论降为 BLOCKED，forward_conclusion=PASS 仅为信息性字段）**；契约自称 formal_complete=true 却有反向分支（自相矛盾）；**结论器内部异常一律 exit 2（绝不 crash 伪装 FAIL）** | 2 |

必要证据：`run-manifest.json` / `gates.json` / `field-compare.json` / `case-results.json`（runner 产物已自动复制到报告目录）。

## 常见处置

| 现象 | 处置 |
|---|---|
| 契约校验拒 DRAFT | 取证补齐后把 meta.status 改 TEST_READY 再过校验 |
| gate passed:false（无自动检查器） | 在 run 目录根 `gate-evidence.json`（对比测试/<run-id>/）提供**结构化证据**（file+sha256_16 现算一致 / url+HTTP 200 / generated_at 时限内 / target_env 绑定）后**新 run-id** 重跑 |
| runner BLOCKED"systems api 配置缺失" | 建 `<runtime>/systems/api/{legacy,current}.yaml`（runtime=$SKILL/runtime/<项目键>；示例：skill `assets/systems-api/`；填法见 capture-channels.md §5） |
| runner BLOCKED"api 采集失败"（不可达/登录失败/找不到任务/缺元素 ID） | 按 reason 排查：服务可达性（health 门禁）、actorMap 凭据 env、`LAUNCH_ELEMENT_ID_<FLOW_CODE>` 或 launch.elementIdEnv、todo.nodePath/flowCodePath 与场景对齐、submit.defaultButton 按钮编码 |
| runner BLOCKED"找不到本实例待办任务" | launch 后实例任务未达该节点/办理人——检查场景 step.node 与办理人、taskWaitSeconds、该流程实例当前真实位置（实例隔离保证不会误取他流程任务，正常按流程推进修复） |
| gate evidence passed=false"无 schema/断言失败/白名单外" | 契约补 gates[].evidence_schema（report 报告字段断言 或 http allowed_urls），证据按 schema 生成后**新 run-id** 重跑——任意文件/URL 不再能证明 gate；report 类报告骨架可用 `scripts/gen-gate-report.py`（按契约 evidence_schema 自动生成 flow_field 绑定与 required_fields 占位 + gate-evidence 条目骨架；占位 `__FILL_*` 全部回填真值后才有效——骨架本身喂给 checker 必是 passed=false，防假通过） |
| runner BLOCKED"采集不可采信" | capture 须落 `field-captures/{legacy,current}/<case_id>.json`、JSON 对象带 `run_id`/`case_id` 身份、mtime 不早于本 run 开始——检查通道产物是否满足 capture 契约（capture-channels.md §3/§4） |
| 想用旧外部 FlowTrace CLI | `FLOWTRACE_RUNNER=cli FLOWTRACE_CLI=<path>`（显式；采集仍过三重校验；不再盲探 PATH/默认路径） |
| 非 optional OBSERVE（fixture 未配对等） | 补双端 fixture 声明与采集，或契约标 optional: true（有理由） |
| manifest exit 2/3/4 | 版本缺失→传 SOURCE/TARGET/FLOW_VERSION（pipeline 已固定 --allow-unrecorded-versions 落账，unrecorded 只挡 PASS 不挡 BLOCKED）；run-id 碰撞/并发→新 run-id（**--force 已移除，不存在强制覆盖**；并发只有一个写者成功）；登记文件缺失→先补齐执行件；run-id 含 `/`、`..` → 换合法 id（只允许 [A-Za-z0-9._-]） |
| run-id 已存在（pipeline 拒绝） | 换新 run-id——账本/结论不可覆盖，同 run-id 重跑永不允许 |
| summary.json 未产出 | 账本断裂（write-manifest 失败或 conclude 判无完整可信账本）——修复后**新 run-id** 重跑；不存在"无账本的 summary" |
| 历史结论想沿用 | 不允许——新 run-id 全量重跑 |

## 5. 完成判定标准（港口 B-02 实锤）

实例办结**只认发起人「已办结流程」列表中查得流程编号**；待办清零 / 进行中为 0 均不算办结
（JMFXZXK001882 曾待办清零仍停 35 进行中，补办后才入已办结）。browser/api 采集的"最后一步提交
成功"只证流转发生，不证办结——结论引用须附已办结列表证据。

## 6. 执行前预检与残留清理（公路 R5/R6）

1. 数据池占用预检：claim key / 95306 行 / 磅房行 data_status / 合同有效期——上轮遗留实例先经
   发起账号「进行中流程」作废（CANCELLED）再跑，或新用例数据避行；
2. 95306 行选中即被其他实例标"已被使用"（港口 B-11 唯一记录被占用=直接阻塞）——配对行多备几行；
3. 轮次收尾"测试实例与数据清理归零"（R6 口径），残留登记到执行记录；
4. **老系统合同电子文件预检**（李雅庄 09-09 实锤）：老系统提交有「合同文件已注册」前置校验——
   立契时确认拟用合同在老系统的电子文件可注册（identification API 静默成功 ≠ 注册完整，须以
   一次真实提交验证）；缺失=治理侧 BLOCKED（L31），先找业务补合同再排期，勿空跑。

## 7. 假阳性防时序（公路 R4→R5 教训）

浏览器/自动化脚本**先选人后提交**（R4 的 auto-approve 时序错序曾产假阳性 PASS）；关键路径在
脚本中标注正确时序；断言"提交成功"必须回读下一节点任务存在性，不认退出码。

## 8. 执行记录规范（公路 R5/R6、铁路 09-09）

- 轮次文件 `YYYY-MM-DD-主题.md`，编号单调不覆盖历史（同日已有 R5 → 新一轮以 R6 独立回归定性）；
- 修复验证型回归在头部声明定性 + 列验证点 + 复验上轮遗留；
- 环境级阻塞与产品缺陷分开表述（铁路 09-09 拉运日期停滞=环境级；D-19=产品级）；对拍之外顺带
  发现的产品缺陷单独编号（D-xx/O-xx）独立跟踪；
- 跨 run 证据引用 run-id（账本只增不改，不复制文件）；姊妹记录显式互链。
