# contract-howto —— test-contract.yaml 填写指南与取证坑

> 读者：正在为新流程立契的执行者。三件套：空白模板 `~/.agents/skills/flow-test-contract/templates/test-contract.template.yaml`（项目部署布局为 `docs/自动化测试模板/test-contract.template.yaml`）、机器 Schema `test-contract.schema.json`、完整实例 `examples/liyazhuang-railway.yaml`（勿复制实例起稿——易遗留他流程编码/账号/公式；从空白模板开始）。

## 各段速查

| 段 | 必填度 | 要点 |
|---|---|---|
| meta | 必填 | flow_code/shape(S1/S2/S3)/contract_version（变更即 +1）/**status（DRAFT→TEST_READY，test_ready 校验只放行 TEST_READY——越级封死）**/sources（≥1 条，可追溯） |
| environments | 必填 | legacy/current 双端 base_url 按实际填写；health_checks 须覆盖每侧 base_url 主机各≥1 条（按 netloc 匹配，缺侧=校验拒） |
| accounts | 必填 | **只写 env 引用**（CURRENT_<账号大写>_PWD）；同人不同号（changkun1/2）在 role 注明 |
| nodes | 必填 | handlers=步骤表办理账号；pool=老 OPER_USER **去重**池（=BPMN candidateUsers 迁移源）；unreachable 孤立节点必须标 |
| forms/fields | 必填 | 只读必填（按钮带入）/手工必填/公式写入/默认值四分类；scale=小数位；dict_ref 挂字典 |
| field_mappings | **核心** | 见下"语义合同" |
| fixtures | 有双端选数则必填 | fixture_pair_id + pairing_rule（比"回填口径"不比业务主键） |
| formulas | 有公式则必填 | inputs/expected_legacy/tolerance/nodes_applied；current_note 记新系统已知缺口 |
| routing | S3/S1 必填 | candidates_legacy；must_not_contain（孤立节点出现=FAIL 级） |
| buttons/resources/post_flow | 按流程 | resources 写 occupy_on/release_on（**逐流程确认，勿跨流程套用**：公路退回不释放 vs 铁路 95306 退回经 19 释放/磅房懒释放） |
| cases | 必填 | C-xx 与 kb 一一对应；required:false = 观察口径（C-05/C-07 类） |
| gates | 必填 | 部署/健康/账号/数据/画布；on_fail: BLOCKED；无自动检查器的 gate 必须带 evidence_schema（report 字段断言或 http 白名单） |
| exemptions | 按需 | 八字段（五字段 + approval_ref/source_run_id/source_compare_sha256_16）齐全才生效；只可能由 exempt 子命令产出；`*/*` 全量豁免禁止（见下） |
| conclusions | 保留默认 | 三态规则由 conclude.py 执行，人工不得越过 |

## 语义合同（field_mappings）字段说明

- `normalize`: trim / number / number_2dp / date_iso / none
- `tolerance`: `exact` 或 `abs:0.01`（**只允许有限非负数**：`abs:inf`/`abs:1e999`/`abs:nan`/负数会被 validate 拒绝、对拍端 BLOCKED——无限容差=容忍一切数值差异）
- `null_policy`: both_null_equal（默认）/ null_is_diff / *_null_expected；exact/abs 容差下双端 `''`/None 视为同一"无值"判等（表示层差异不记伪 diff），一空一非空仍 diff
- `dict_map_ref` → dict_maps 段登记双端值→标准码（首轮双开回填 map: {}）
- `redact`: none/mask/hash —— 报告呈现脱敏（执行单号类敏感字段用 mask）
- `fixture_pair_required: true` —— 依赖双端各自选业务数据（磅房/95306 类）；采集层要求**双端声明同一 fixture_pair_id**（交集），未配对只记 **非 optional OBSERVE → 整体 BLOCKED**
- `fixture_pair_id: FP-XXX` —— 显式绑定到某个配对（更严：该字段只认这个 fixture；未在 fixtures 登记会被 validate 拒）
- `optional: true` —— 契约明示的可观察项：OBSERVE 不阻断结论（默认 false）

## 豁免（exemptions）规则

- 每条豁免必须八字段齐全且非空（1.3.0 起）：`id` / `scope`（维度名或 `*`）/ `match`（精确 key 或**去采集文件名前缀一次**的稳定键，如 `s1/CS->CS`、`formula/A.1`；前缀只剥一次——`00` 这类短键不会跨维度误杀）/ `reason` / `approved_by` / **`approval_ref`（审批工单号）/ `source_run_id`（源 run）/ `source_compare_sha256_16`（源 run field-compare sha 前 16 位，`^[0-9a-f]{16}$`）**——缺任一=不可审计，validate 拒绝 TEST_READY、对拍时**不生效**（差异保留）
- **取证链三重强制（1.3.0；1.3.1 共享模块化）**：真实 run 绑定同时保护三个入口——①生成器入口（exempt 子命令核验账本链）；②契约入口（validate-contract 经共享模块 `scripts/run_evidence.py` 全链核验：五件齐全（账本/结论/对拍/门禁/用例，拒符号链接）、run-id 三方一致、fc 已登记账本且 sha256[:16] 现算一致、toolchain 指纹、**底层证据轻量重算**（gates 全过/必测全 PASS/fc 状态自洽——手写 summary 骗不过）、**scope/match 绑定源 diffs 真实条目**；run 证据库缺省智能解析 契约同目录/对比测试 → 上一级/对比测试，`--runs-dir` 可显式指定）；③对拍入口（比较器对无链/格式非法豁免不生效）。**禁止在任何消费方另写简化版核验（1.3.1 P0 教训：简化版放过自制两个 JSON 的伪造链）**；绕过 exempt 手写精确 match 的豁免不可采信；历史手工五字段豁免须补链迁移（对源 run 重跑 exempt 生成）或把契约降 DRAFT
- `match: "*"` **通配禁止**（即使 scope 为具体维度也等于整维度全免=绕过结论）：validate 拒绝契约、compare 直接 BLOCKED；`scope: "*" + match: "*"` 全量豁免同样**禁止**
- 豁免命中进 `exempted`（带 exempted_by 审计溯源），不进 `diffs`；不可审计条目计入 `invalid_exemptions` 供报告呈现

## 取证坑（历史实锤，勿再踩）

1. **STEP_USER 冗余**：按组织冗余 23×（铁路 323 行→去重 13 组）——一律 DISTINCT OPER_USER
2. **SELECT_* 值域**：AUTOFORM_MAIM 选择器开关是 `'是'`/空，不是 '1'/'0'（判空踩过）
3. **实例前缀**：必须全量 DISTINCT 统计；首 N 位采样只能得弱结论（铁路 FI* 教训）
4. **双表族并存**：SETTLE_* 与 AUTOFLOW_* 同构（港口分支用老族）——以流程逻辑分析结论判定
5. **SYS_USER 反查**：新老 ID 同源，优先查新库 sys_user（死 ID 判定即出自新库）；老库用户表名待复测
6. **后置流程两路**：AUTOFLOW_EXT_SEL_NEXT_CONFIG=0 条时回退 `SETTLE_WORKFLOW.NEXT_FLOW_CODE`；注意"待启动登记"（铁路）vs"直接发起"（公路）口径不同
7. **老库中断兜底**：SOURCE_ORACLE_* 不可达（VPN 波动）→ Excel/流程逻辑分析路径 + 稍后重试，勿阻断立契
8. **凭据结构化扫描**：validate 递归遍历 YAML 键，按**子串**匹配禁止 password/passwd/pwd/secret/token/credential/api_key/密码/口令/凭据 等键——**含前后缀与引号变体**（db_password / pwd2 / access_token / my_api_key 一律拦截；accounts[].env=CURRENT_*_PWD 引用除外）；叠加**文本正则兜底**（password/pwd/secret/token 等拉丁关键词与**中文邻接值形式"密码：xxx"/"口令=xxx"（含全角冒号）**后的独立值——自由文本位 meta.notes 等夹带明文也在立契期拒绝，第七轮补中文变体）；生成器对产物再密扫一次（同口径），命中即清空产物失败
9. **候选池漂移**：老库去重值 vs 手工用例注记可能不一致（铁路 12/13 池 4 ID vs 注 3 ID）——以 DB 去重为准，漂移写进用例观察项
10. **字段码复合键后缀**（铁路）：值集迁移防冲突把 field_code 改写为 `FYDW_<hash12>` 复合键——
    立契字段码**一律以引擎校验实录为准**（FORM_FIELD_* 错误消息 / render API），勿假设=老系统裸键
11. **formData 通道与账本节点码**（铁路）：新系统提交必带 formData（服务端必填校验依赖；契约
    `step.form` → 场景 formData → execute-button 载荷）；服务端多候选声明串（"01,02,03"）不得直接
    作账本节点码——用场景显式路由值登记
12. **声明缺口 EXPECTED GAP**（铁路 C-03/04/06/07）：退回/作废/保存草稿/盖章链等非路由按钮流
    API 未实现 → 契约 notes 登记 `EXPECTED GAP`，执行前声明；跑出 BLOCKED 属预期内，不算意外失败
13. **必填输入与通道前置以引擎/门禁报错为准回填**（港口煤 2026-09-09 全链贯通迭代）：
    ① 场景步漏填必填（如质量鉴定单采样日期 CYRQ——浏览器 SOP 有「采样日期填当日」但契约
    steps 漏了）→ 引擎 400 报错消息直接给字段码清单（「请完成: [QSF, FYDW, ...]」），按清单
    回填契约 `steps[].form` 后**重新生成场景**（生成件受保护，勿手改场景 YAML）；
    ② 新流程 API 首跑六项预检：runtime env 凭据键齐（$RUNTIME_DIR/env；缺=从代码 seed/浏览器轮次配置找映射，禁盲猜；或显式设 FLOWTEST_ALLOW_DEFAULT_PWD=1 + FLOWTEST_DEFAULT_PWD 统一默认密码兜底）、
    双端 actorMap 本流程分组、LAUNCH_ELEMENT_ID_<FLOW_CODE> env、新系统 todo.map stepCode
    映射（从引擎库部署 BPMN 实查，勿用本地 BPMN 文件——与运行时不一致）、gate 证据 24h 时效、
    数据池未使用行双端充足；
    ③ 契约 gates[] 的证据=只读探针报告（launchable API/源库 SELECT 计数）按 evidence_schema
    填真值 + sha256_16 清单（target_env/generated_at 必填），先例
    `docs/李雅庄铁路流程/自动化测试/执行记录/gate-evidence-live/`
    ④ **正式 PASS 的版本绑定（第十一轮 conclude 强制）**：经 env 传入
    `SOURCE_VERSION`/`TARGET_VERSION`/`FLOW_VERSION`（缺省 unrecorded → PASS 被 BLOCKED）。
    ⚠ 设了 TARGET_VERSION 即与 gate 证据 target_env 有同一性校验——统一 `local-dual-run`；
    被测代码版本由 manifest.git_rev 自动记录；流程版本实查治理库部署回执
    （gov_process_publish_deployment_receipt，如 PRI_PROCESS_000000001:12）。
14. **API 通道必填全量补齐三定律**（港口煤 run-141848/145913 实锤，L41）：
    ① 引擎按「已保存 revision + formPatch 合并」校验必填，**workbench 回显 formData=已保存
    单据数据，继承/公式值不在其中**（渲染层才有）——必填字段须在 `steps[].form` 一次性全量
    补齐（值=同实例 00 步同源；req+readonly 字段提交不被拒）；② **form 键一旦存在即走
    SAVE_FORM 路径，echo_form_patch 不再生效**——只补缺字段会让其余必填裸奔；③ 勿逐字段盲试
    （引擎一次只报一个）——用该任务 workbench 的 `formViewSnapshot.fields` 实查
    required/readonly/fieldCode 全集一次补齐。表单回显继承时点差异（老系统不回显继承值 vs
    新系统回显）→ 首跑对拍后用 `gen-multibranch-contract.py exempt` 按真实 diffs 批量生成
    八字段豁免（禁止无 run 证据预生成；1.3.0 起契约/对拍入口同样强制取证链）。
15. **多分支流程全量立契（数据驱动，分支数不写死）**：`scripts/gen-multibranch-contract.py gen`
    从分支定义串（ast 解析零执行）+ 已 PASS 基准契约 + `--node-map-extra`（环节名→码实查补充，
    如港口煤 运销科盖章=05/货运明细表制单=30/铁路到港运费流程=41~47）生成全正移分支契约：
    cases/steps 按分支链自动构造、accounts 按 env 键推导扩量、nodes.next=全分支并集拓扑
    （单分支实际路由由服务端 DMN 按发起人收窄，notes 声明）。反向分支（RETURN:/WITHDRAW:/VOID@）
    自动分流出 explore 契约（守护规则 6，仅 --drill）；未知环节名分支跳过进待核实清单（绝不猜码）。
    分支覆盖双态（1.3.0）：`meta.branch_coverage` 记 accounted_complete（分支全分类）与
    formal_complete（反向也为 0）——reverse_explore>0 时该契约只覆盖正向分支，conclude
    拒绝全量 PASS：顶层 conclusion=BLOCKED + summary.forward_conclusion=PASS（信息性
    字段，1.3.1）；反向要出正式结论须另立正式契约
    （cases[].notes 显式声明特殊流转）单独 run 绑定。
    豁免不预生成；新账号 actorMap 增量与 runtime env 凭据键缺口由生成器输出清单。
