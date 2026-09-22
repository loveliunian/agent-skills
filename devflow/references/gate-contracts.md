# Gate 契约卡（Machine-Readable Gate Contracts）

> 目的：把每个 gate 的**隐式验收契约显式化**，让 Agent/开发者在产出物写作前就知道
> 门禁会检查什么——消除「渲染 → 跑 gate → 失败 → 反查脚本 → 修复 → 重跑」的试错循环。
> 实测（ch07-org-user 全流程，363min）：约 35% 耗时来自门禁契约的试错发现，本卡预期削减 30%+。

## 通用规则（所有 gate 共享）

| 规则 | 说明 |
|---|---|
| 正文禁花括号 | s2/p4b 对渲染产物做 `\{[^{}[:space:]]{1,24}\}` 检查（剥除 ``` 围栏后）。接口路径占位符一律写 `:id`（Spring 注解用 `{id}`，另见 §路径桥接） |
| 禁用词 | TODO / TBD / 待补充 / REPLACE_WITH / 占位(非"占位符|占位图") / 暂定；`{xxx}` 未替换变量 |
| 结构化产物先行 | 先 `df_pipeline.py <kind>` 校验渲染，再跑 gate；「校验失败不渲染、不进 Gate」 |
| 收据链 | 完成阶段前 audit-receipts 必须通过；证据树含 receipt 内 EVIDENCE_PATHS_JSON 全部文件，任一变更即失效 |
| SKILL_TREE | 收据记录生成时 skill 树哈希；skill 仓库变更即漂移，需 migrate-tree + 受影响 gate 重跑 |
| 证据隔离 | 下游 gate（如 P6-final）会重跑测试改写 surefire 报告——上游 gate（P4）证据须绑定 `.devflow/<feature>/p4-evidence/` 下的快照副本，而非 target/ 活文件（gate 已自动快照） |
| 评审证明 | P2a 双阶段收据需 `export REVIEW_ATTESTATION_PUBKEY=<workspace>/.devflow/<feature>/review-keys/attest.pub.pem`；缺失时报 signature invalid |

### 字段级契约速查（JSON 正本写作前必读，m01-base 实测沉淀）

> 以下 pattern 来自各 schema + df_validate 跨字段检查——**违反任一即校验失败不渲染**。
> 通则：`zero_results[].path` 必须指向【真实为空】的集合并落在该 kind 的词汇表内；
> 集合非空却声明空 = 伪造空声明，同样拦截。

**ID / 命名 pattern（无连字符一律用下划线或紧写）**

| 字段 | pattern | 错误示例 → 正确示例 |
|---|---|---|
| design tables[].prd_entity_ref | `^ENT-[0-9]{2,}$` | `ENT-01`（非 `E-1`/`实体1`） |
| design 表字段 prd_constraint_ref | `^CST-[0-9]{2,}$` | `CST-01`（非 `C-01`） |
| design apis[].prd_operation_ref | `^OPS-[0-9]{2,}$` | `OPS-01`（非 `OP-01`；且须与 clarification.operations[].id 一致） |
| rules[].id / acceptance[].rule | `^R[0-9]+$` | `R001`（非 `R-001`） |
| rules[].error_codes[].code | `^[A-Z][A-Z0-9_]{2,}$` | `M01_ORG_004`（非 `M01-ORG-004`；全局限一，不得两条规则共用） |
| tech-selection candidates[].id | `^[A-E]$` | `A`（非 `SCHED-A`） |
| constraints_scan[].constraint_id | `^TC-[A-Z]+-[0-9]{3}$` | `TC-FE-901` |
| retrospective feedback_id | `^FB-[0-9]{8}-[0-9]{3}$` | `FB-20260921-001` |
| retrospective phase_facts[].phase | `^P[0-9]+[a-z]?(~P[0-9]+[a-z]?)?$` | `P3~P3b`（非 `P3/P3b/P3cd`） |

**易错的必填字段（schema required + 跨字段）**

| 位置 | 陷阱 |
|---|---|
| apis[].request.fields[] | `required`(bool)、`masking`、`rule`、`source` 全必填（无内容写 `-`）；response.fields[] 用 `always`(string 是/否/条件) 且**禁** `required` |
| apis[].anchor | 必须等于 `detail_anchor`（§3.2.N，不得写概览级 §3.1）；request/response.anchor 同样落到 §3.2.N |
| pages[].dialogs[].api | 必须含 `§3.2.x` 锚点或精确写 `—` |
| business_operations | 非 stateless 必须 source_state+target_state 成对；test_scenarios ≥1 |
| tables[].fields[].ddr | 每个字段必填且指向存在的 decisions[]；DDR↔字段双向无孤儿 |
| monitoring.machine.alert_test_output | 文件须含 `ALERT_TRIGGERED=`、`RECOVERY_RECORDED=`、`NOTIFICATION_CONFIRMED=` 三行 |
| retrospective.verify_output | string（报告路径），非 object |
| test-cases cases[].steps[] | 对象 `{action,expected}`；`result` 为对象 `{executed,status}` |
| P4 evidence TSV | 列序 `id,code_paths,test_paths,status`——**PASS 必须是末列**，路径逗号分隔且实存 |
| 前端 devflow-client release_evidence | `artifact=…;version=…;location=…` 且 artifact 路径相对 frontend/ 实存 |

**其它高频坑**

- 枚举字段（storage_strategy/versioning/http_methods/acronyms 等）用 schema 枚举值，说明文字放 notes。
- `additionalProperties:false` 是常态：多余字段（如把说明塞进对象）会整卡拒绝，说明进 `notes` 或对应文档。
- P4/P4b/P6-final 的命令型证据：禁止 `>` 重定向（Gate 捕获须非空）、禁止 bash/sh 包装、根目录须有对应工程清单（pom.xml/package.json/pyproject.toml）。


## 路径桥接（s2 × P4b 口径冲突）

design.json 的 api path 若含 `{id}`：渲染进详设 api-index 后触发 s2 花括号 P0；
若为纯文本不含变量则 P4b 的代码路径逐字对账又要求与 Spring 注解 `{id}` 一致。
**已冻结桥接口径**：

1. design.json / 详设文档：路径写 `:id` 风格（如 `/api/system/org/:id/detail`）。
2. Spring 控制器：注解用 `{id}`（Spring 语法），并在每个 @*Mapping 上方加一行
   `// design-form: @GetMapping("/org/:id/detail")` 供 p4b 解析器提取（解析器不区分注释）。

## 各 Gate 契约速查

### P0 需求澄清（s0_acceptance_gate.sh）
- 必产：`docs/需求/<f>-需求澄清.md`、`<f>-验收点.md`、`<f>-技术约束.md`（结构化渲染）。
- 验收点 ID：`M-NN-FNN-ANN` 带连字符正则形；状态全部 FROZEN；PRD 锚点真实存在。
- 禁「占位」（技术约束里"占位符"一词合法）；zero_results.path 仅限 `['exclusions','followups']`。
- 通过后必须 `devflow-state.sh constraints-freeze <feature>`（P1 强校验 SHA）。

### P0b PRD 评审（artifact_gate.sh P0b）
- 领域清单（gen-domain-checklist）每项 `- [x]` 且附 `（证据：…）` 或 `N-A <理由≥2字>`。
- DF 五字段（触发场景/影响链/完善建议/验证方式/文档位置§x.y）缺一无效；角色零发现须 ZERO-DF 核查块。
- AW 每条以「结果：发现 DF-xx 或 §x.y」收尾；禁浅层通过语（已阅/LGTM/无明显问题）。

### P1 技术选型（s1_fact_sources_gate.sh）
- 报告必须含字面：`决策矩阵`、`决策结论`、`constraint_id`、`design_doc_structure_mode=monolith|total`、`用户确认: 已确认|YES`。
- configs[].consumption_points 的 location 必须真实存在且**文件内能检索到配置键字面**。
- 7 份事实源（_commons/_权限矩阵/_环境与账号/_菜单Seed索引/INDEX-×3）各 >5 行且章节对齐 ≥60%。

### P2 详设（s2_design_coverage_gate.sh --mode=monolith）
- 必含语义锚点：data-model / api-contracts / business-rules / implementation-handoff；
  acceptance-traceability 在需求追溯文档（`<f>-需求追溯.md`，trace-matrix 块）。
- §3.2 每节标题 `#### 3.2.N 名称` + 首行 `> 说明：METHOD 路径｜权限：…｜功能：…`。
- apis[].detail_anchor 必须与正文小节一一对应（概览数=详定义数，双向）。
- tables/apis/pages/rules 孤儿条目须 unreferenced_reason；空集合须 zero_results 声明（path 精确匹配）。
- rules[].when_line 必须在锚点小节**逐字**出现；JSON 字段清单与正文表格首列一致。
- DDR ↔ 字段双向闭环；configs 消费点文件真实存在且文件内检索到配置键。
- 页组小节数 ≥ 页面清单数；dialogs 交互名必须出现在 §7.1 清单且接口列含全部 §3.2.x 锚点。

### P2a 设计评审（p2a_design_review_gate.sh）
- 双阶段收据：begin（报告不存在时）→ 渲染报告 → complete；环境变量
  `REVIEW_ATTESTATION_PUBKEY` 必须指向 review-keys/attest.pub.pem。
- 报告头须含 `| AUTHOR_ID | … |`、`| REVIEW_SESSION_ID | … |` 行；五角色行
  （架构师/后端专家/前端专家/测试开发/DBA）session 列与收据一致、结论列 ✅。
- DF OPEN=0（全部 CLOSED）；探针表 P1~P6 每行含「已执行/不适用 + 证据§锚点」。
- 领域清单（--stage design）34 项全答；P0/P1 级 DF=0。

### P2b 原型（p2b_demo_gate.sh）
- `docs/原型/<f>-原型确认.md`：≥3 个唯一 KUF、每个 KUF 同段含「walkthrough|走查」、
  引用 `docs/原型/...` 原型文件实存、PO 结论 + 签字 + 日期。
- 注意 `docs/原型/<f>-测试报告.md` 等其他 `${FEATURE}*.md` 会按字典序劫持部分 gate 的文件选择（P5 已修，其余 gate 注意）。

### P3 实现（p3_completion_gate.sh + build-watchdog）
- 设计表 ↔ Flyway CREATE TABLE 集合一致；Mapper 数=Entity 数；每个 Controller 含 @PreAuthorize。
- TODO/FIXME=0（含前端）；TC-TECH-* 依赖反查（前端约束写在 `backend/system/src/main/resources/constraints/constraint-bindings.md` 即可通过文本反查）。
- 菜单 seed 四方言齐全，文件名建议含 feature；postgresql 需 setval。
- JaCoCo 行覆盖 ≥80%（jacoco.xml；infra 探针可加 excludes）。
- P3 gate 重跑会改写 surefire 报告 → P4 收据若绑定 surefire txt 须在其后重跑（gate 已自动快照解耦）。

### P3b 代码审查（p3b_code_review_gate.sh）
- 报告名必须是 `docs/评审/<f>-代码审查报告.md`（df_resolve 后缀=代码审查报告，非「代码审查」）。
- findings[].id 格式 `^P[012]-\d{1,3}$`、severity ∈ P0/P1/P2、status ∈ OPEN/CLOSED；conclusion=APPROVE。
- files[].lines 为整数；报告正文须覆盖全部验收 ID（grep M-07-… 计数=82）。
- ARCH-PITFALLS 收据由 `check-arch-pitfalls.sh --all --receipt <feature>` 产出（P3b 前置）。

### P3cd 安全+性能（p3_security_perf_gate.sh）
- security.json findings[].status 可 WAIVED 但须 waiver_ref（指向豁免文件+条目）；顶层 waiver_file 必填（有 WAIVED 时）。
- performance.json scenarios[].p95_ms/threshold_ms 必填且须与渲染报告逐字一致（gate 反查报告文本）。
- report_path 指向 df_render 产物本身（渲染不一致 = 双正本漂移 P0）。

### P4/P4b 验证与对比（p4_validation_gate.sh / p4_prd_vs_code.sh）
- prd-validation.json machine 字段：p4_cmd（首词受信 runner；bash -c 执行，首词不可 cd/包装）、
  p4_results_path（表头 `ID<TAB>STATUS` 或 `acceptance_id\tcode_paths\ttest_paths\tstatus`）、
  validation_evidence（文件须真实存在——指向隔离副本或稳定文件，勿指 target/ 活文件）。
- features[].impl_status ∈ 已实现/未实现/部分实现；result ∈ 通过/失败/部分通过；conclusion ∈ PASS/FAIL。
- p4b：design api 路径（:id 形式）必须逐字出现于控制器 @*Mapping 行（含 design-form 注释行）。
- 顺序：P4b 之后跑 P4 validation、最后 s6-final（三者共享 surefire 证据，见「证据隔离」）。

### P5 测试用例（p5_test_cases_gate.sh）
- 优先读 `*<f>*测试用例*.md`；同目录的「测试报告」等 `${f}*.md` 会按字典序劫持选择（已修，但注意别把无关 md 拷进 docs/test-cases）。
- 用例须含 TC-* ID；预置/步骤/预期三列须具体（雷同/占位行=P0）；边界/异常用例 ≥1；覆盖全部验收 ID。

### P6 测试执行+终验（s6_first_pass_accuracy.sh / p6_credential_gate.sh / s6_final_verification_gate.sh）
- 顺序：s4 freeze → 跑测试 → s4 record（写 results_sha256 进 meta）→ s6 accuracy → credential → final。
- test-evidence.env 五类（UNIT/INTEGRATION/CLIENT/LOAD/STAGING）各须 *_CMD/*_EXIT/*_REPORT_PATH
  三件套；首词受信（mvn/npm/curl…）；**mvn/npm 须能在 CWD 找到 pom.xml/package.json**
  （gate 从仓库根执行；根级无 pom 时先 `ln -s backend/pom.xml pom.xml`、`ln -s frontend/package.json package.json`）。
- 五类 REPORT_PATH 必须互不相同且每轮命令后内容变化（防陈旧证据）。STAGING 须真实容器签名
  （java -jar / spring-boot:run / curl http）；pc-web 不可 STAGING_EXEMPT=1。
- verification.json（契约 verification.schema.json）：acceptance_results 与 baseline 全等；
  evidence.*.exit_code（非 exit）；client_not_applicable.declared=false + frontend_scope=pc-web；
  environment=dev|staging。**BUILD_INFO 回显**：/build-info 端点返回 deploymentId + 运行 jar SHA
  （gate 用 sha 前 12 位或 DEPLOYMENT_ID 在响应中 grep）。
- 凭证 gate：`docs/test-cases/<f>-端到端测试用例.md` 内须有 `| 用户名 |`、`| 密码 |` 表行与
  `代码来源|V*__seed|helpers.ts` 之一；注意不要把「测试报告」拷进 docs/test-cases（文件名劫持）。

### P7 部署（artifact_gate.sh P7）
- 部署记录 md 须含机检行：`ARTIFACT_PATH=`、`ARTIFACT_SHA256=`（64hex，与实际 jar 实算一致）、
  `HEALTH_URL=`、`BUILD_INFO_URL=`（http(s)、非 link-local）、`RELEASE_EVIDENCE_PATH=`、
  `DEV_PRIVILEGED=`（false 必填；staging 允许 true 但须显式）、`ENVIRONMENT=`、`DEPLOYMENT_ID=`。
- BUILD_INFO_URL 须回显 sha 前 12 位或 DEPLOYMENT_ID —— 建议 `/build-info` 自定义端点
  （ApplicationHome 定位运行 jar 并实算 SHA；/actuator/info 由 actuator 接管，业务字段回显不可靠）。
- pc-web release：manifest `release_evidence` 字段格式
  `artifact=dist/index.html;version=1.0.0;location=staging`（artifact 相对 CLIENT_DIR 存在）。
- P7 重跑死锁：gate 启动即清理旧收据；state 已标 completed 时 audit 报「无对应收据」死锁——
  已修复为自动回退 in_progress（v3.28.1）。

### P8 监控（artifact_gate.sh P8）
- monitoring.json machine：metrics_endpoint 须实测返回 Prometheus 文本（需 micrometer-registry-prometheus 依赖 + exposure include prometheus）。
- alert_test_output 须含 `ALERT_TRIGGERED=`、`NOTIFICATION_CONFIRMED=`、`RECOVERY_RECORDED=` 三行。

### P9 文档（artifact_gate.sh P9）
- 文档索引渲染到 `docs/<f>-docs-index.md`（gate 固定路径，勿放 docs/发布）。
- 五类（USER_DOC/DEVELOPER_DOC/API_DOC/OPERATIONS_DOC/RELEASE_NOTES）各一，
  substantive 门槛：≥10 行、≥2 标题、≥5 正文行；sha256 实算比对。

### P10 复盘（p10_feedback_gate.sh）
- 复盘 md 必含 `## 上次遗漏了什么`、`## 本次新发现` 章节。
- 知识分享 ≥3 条 `- ` 列表项；feedback.md 由 `--out-feedback` 渲染。
- phase 字段正则 `^P[0-9]+[a-z]?(~P[0-9]+[a-z]?)?$`：P3-build/P6-credential 等带连字符名
  不合法——改用 P3b/P6c/P6f 别名并在 skip_note 注明真实收据路径。

### 实测隐性契约速查（v3.29.1，m01-base 全链沉淀——写产物【前】逐条核对）
- **s2/P0b 渲染产物头**：`> 模板版本：\`x.y.z\`` 行必须与模板 frontmatter 逐字一致（升版后连带改 JSON template.version 与文档行，两处任一漂移即 P0）。
- **s2 §5 业务规则**：WHEN 行必须顶格（行首 WHEN，禁 `>` 引用前缀）；规则编号必须 `R1. 摘要` 形式；每个 WHEN 配一张 `sequenceDiagram`（数量 ≥ WHEN 数）。
- **s2 表格列**：五列表头首列必须 `字段名`；响应六列必须 `恒出性`（非 `恒出`）。
- **s2 模板身份**：文档头须有 `> 模板 ID：\`模板名\`` 与 `> 模板版本：\`x.y.z\`` 两个独立行。
- **P2a**：报告头须有 `AUTHOR_ID=`、`REVIEWER_ID=`、`REVIEW_SESSION_ID=` 三个**行首扁平键**（表格行不算）；角色行 4 列且结论列恰为 `✅`；DF 块内须有 `- 归属评委：<角色>` 行；REPORT 文件名按 df_resolve 字典序首选（勿让 `-r1` 归档版抢在正式版前）。
- **P2a 评审命令**：`npm --silent run test:e2e`（--silent 消除 npm 首行空行，报告首行非占位）；`| tee 报告路径` 直写且每轮内容必须变化。
- **P6 五类证据**：X_CMD 由 Gate 从仓库根 bash -c 重跑，stdout 捕获须非空（禁纯 `> 文件` 重定向）；用 `| tee 报告` 直写报告且每轮内容变化；REPORT 文件彼此互异且与终验报告本体不冲突；首行不得为空/纯 ok/pass；LOAD 首词仅受信 runner（curl 只属 STAGING），用 `npm run load` 包装探活循环；`ENVIRONMENT=dev|staging` 须写入 env 文件；CLIENT_CMD 在 env 中一行三件套齐全（漏行=执行记录 4≠5）。
- **P4b evidence TSV**：四列表头须 `acceptance_id`（非 `ID`）；路径用逗号分隔的真实文件；全部行 status=PASS。
- **P7**：授权收据 `authorized_at` 用 UTC `Z` 格式（`+08:00` 被判非法）；`DEV_PRIVILEGED=false` 须显式；artifact.path 须为真实文件（指向 target/*.jar 并实算 64hex SHA）；回滚 triggers/steps 为字符串数组。
- **P10**：`feedback` 为单个 dict（feedback_id/scope=project/status/skill_modify_approved/root_cause/target_files/decision），非数组；`rollback_triggers` 为字符串数组；phase 字段不含连字符（P3cd→归并、P3-build→skip_note 注明）。
- **s1 报告解析 glob 碰撞**：`tech_selection` 的中文后缀「设计决策」会松散匹配《数据库设计决策》——两文档并存时用 `TECH_SELECTION_FILE=<准确路径>` 显式覆盖。
