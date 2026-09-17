---
name: changelog
version: "3.26.9"
description: "Version migration guide for devflow. Read before upgrading between major versions."
paths: []
disable-model-invocation: false
---

# Changelog — devflow v1 → v3.26.9 Migration Guide

## v3.26.9 (2026-09-17) — 自然句式提取 + 组合字段面 + 发布树对齐

**发布树对齐说明**：v3.26.8 manifest 冻结于 17:0x，其后仓库作者的文档策略编辑
（SKILL.md 新增铁律 15「面向读者文档遵循中文文风规范，人工自检/抽查，不设自动
文风硬校验或 Gate 阻断」；commands/docs.md 与 concepts/中文文风规范.md 同步）于
17:20 随提交 d9fe55c 入库——manifest 与树漂移导致发布入口复跑在
test-v3140 manifest check 处失败。按"已发布 manifest 不可重写、漂移必须升版"规则，
本版将上述编辑与以下修复一并发布。

**P1 修复（用户侧实测反例）**：

- **rule_operation_closure 自然句式漏抽**：「要素未停用时拒绝删除」因模式 2 的
  "未 前必须是中文字符"守卫整体不提取（守卫本意防跨词，但带对象前缀的常见句式
  被误杀）。修复：去守卫 + CN 惰性捕获（防"停用时"吞成操作词）+ 尾部补全
  时/则/先 × 返回/拒绝 变体 + 纯条件词丢弃（"未通过返回"的"通过"不是操作）。
- **content_sufficiency 组合未声明字段**：fields=["status"] 但组合混入
  scope=UNKNOWN/ANY 时，旧版因查无枚举域直接跳过（保守路径被滥用）→ 未知字段
  静默放行。修复：组合字段必须先声明（fields 之外的字段即 FAIL，诊断给出
  "scope=(未声明字段)"）；已声明但枚举提取为空的字段仍保守跳过。

回归：test-dev-hardening 扩至 45 用例（新增 3 条：未X时拒绝 负/正、未声明字段
必 FAIL）；既有 42 用例无回归。

## v3.26.8 (2026-09-17) — 探针语义修复第二轮：条件隔断对象继承 + 组合合法性

用户侧复查实测反例（rc=0 误放行），两处 P1 语义缺口：

- **rule_operation_closure 状态条件隔断**：「要素在草稿状态时需先停用才可删除；
  未停用返回…」的业务对象"要素"先于条件词（在草稿状态时），局部 before-context
  取不到；错误码分支"未停用返回"更无对象可继承 → 退化为仅按"停用"匹配，「停用字典」
  被误认为可达。修复：句子级主语提取（按分隔符切段取段首中文主语、条件/引导标记
  处截断、前后动词与虚词清洗、纯动词段丢弃），局部无对象的操作继承句子级主语。
- **content_sufficiency 组合合法性**：旧版只校验数量——{DRAFT, UNKNOWN} 与
  {DRAFT, PUBLISHED} 同为 2 个，非法集合被当作完整矩阵放行。修复：逐组合校验取值
  必须来自该字段枚举域（枚举提取为空时保守跳过），数量完整性检查保留。

回归：test-dev-hardening 扩至 42 用例（新增 3 条反例钉：条件隔断负例/正向、
非法组合必 FAIL）；既有 39 用例无回归（含"需要X"句式与纯动词分类列不泄漏的
对象继承边界）。

## v3.26.7 (2026-09-17) — 探针语义修复：业务对象绑定 + 组合枚举数

用户侧复查实测反例（rc=0 误放行），两处 P1 语义缺口：

- **rule_operation_closure 业务对象绑定**：「要素需先停用」曾被无关的「停用字典」
  端点满足（同动词跨对象误认可达）。修复：从规则句提取业务对象（捕获前缀 +
  上下文双来源，剥离引导/时间/虚词与动词，保守优先），`reachable()` 要求端点名/
  路径绑定同一对象；诊断信息给出对象名（"无同业务对象端点（对象：要素）"）。
- **content_sufficiency 组合枚举数**：`seen_enums_keys_for` 旧正则要求值单元格后
  还有一列——常规 `| status | DRAFT | 草稿 |` 三列表无法提取 → 枚举数恒 0 →
  "两个状态仅声明一个合法组合"仍 PASS。修复：与 `_status_enums` 同口径的单元格
  解析（字段列精确匹配 + 值列大写枚举记号，下限 3 字符防噪声）。

回归：test-dev-hardening 扩至 39 用例（新增 3 条反例钉：停用字典不满足、三列表
1<2 必 FAIL、2/2 正常通过）；既有 36 用例无回归。

## v3.26.6 (2026-09-17) — v3.26.5 二次复查：收敛边界 + 结构崩溃

对 v3.26.5 的修复做边界复查（"再次检查"），再修 2 处探针边界缺口（均实测复现）：

- **rule_operation_closure「需要X才可Y」拆分缺口**：拆分词表缺 `需要` → 捕获
  「需要二次鉴权」收敛为 junk「要二次鉴权」→ 契约齐全仍误 FAIL。修复：拆分顺序
  补 `需要`（先长词后短词）；并新增条件句式收敛——「X通过/完成才可Y」剥离状态后缀，
  校验类条件规范化为内置放行词（"要素校验通过才可发布"不再捕获 junk）。
- **content_sufficiency_probes 组合结构崩溃**：`valid_combos` 条目含列表等不可哈希
  值（如 `{"status": ["A","B"]}`）时 set 推导抛 `TypeError`，traceback 直达 Gate 输出
  → 项目收到误导性"内容充分性缺口"。修复：try/except 降级 WARN 跳过组合穷举
  （与探针"缺输入降级"原则一致，rc=0 不误导）。

回归：test-dev-hardening 扩至 36 用例（新增 2 条边界钉：需要X收敛、组合结构降级）；
旧用例（需先X收敛、RR6、输出矛盾、双向负例）全部保持。

## v3.26.5 (2026-09-17) — v3.26.4 探针复查修复：误报阻断 + 输出矛盾

对 v3.26.4 并入的内容充分性探针做发布后复查，修复 2 个真问题 + 3 处瑕疵；
全部修复附回归钉（test-dev-hardening 扩至 34 用例，正/负双向验证）。

**P0 误报阻断修复**：

- `rule_operation_closure.py` 过度捕获——「要素需先停用才可删除」类规则行会把整句
  `要素需先停用` 当成前置操作（模式 CN 贪婪吞入宾语+引导词），该假操作永远无法命中
  端点名 → **契约齐全的项目被误 FAIL 卡在 P2**（实测复现）。修复：含引导词的捕获
  收敛到最后一个动词短语 + 前导虚词剥离；负向用例（真缺契约）保持 FAIL。
- `content_sufficiency_probes.py` 输出矛盾——非 strict 模式同一输入同时打印
  `[WARN] 死状态 N 个` 与 `[PASS] 无死状态`。修复：WARN 与组合检查结果分开表述；
  Gate 路径（恒 `--strict`）行为不变，`--strict` 死状态仍 P0。

**瑕疵清理**：

- `rule_operation_closure.py` 规则标签双写（单元格已是 `R6` 输出 `RR6`）；
- 死代码：`in_detail_section()`（从未调用）、`rule_text_ctx`、`LEGACY_MECH`、`domain`、
  冗余 `import re as _re`；
- `s2_design_coverage_gate.sh` §6c 头注释与实调用对齐（"死状态默认 WARN" → Gate 恒
  `--strict` P0 / 独立运行默认 WARN）。

## v3.26.4 (2026-09-17) — P2 内容充分性三防线（s2 §6c）

来源：治理服务 P2a 第三轮独立复核 DF-57~70——14 条发现中 11 条为机械门禁盲区；
新增 `scripts/content_sufficiency_probes.py` 并接线 s2 Gate §6c，三探针：

- **field-drift**（重写丢东西）：PRD 必填字段措辞 0 命中 WARN + 旧设计（archive）
  机制承接核对——机制语义词丢失即 FAIL（方法/常量/Redis 键/SQL 记号作同域佐证），
  重写版必须逐项承接或在 §13 DDR 登记"移交/废弃"决策。
- **state-matrix**（状态机交叉）：声明的状态值无转移语义、状态组合未定义（strict=P0）。
- **cross-doc**（跨文档契约）：jobKey/内部端点/权限码双边不一致（有 peer/矩阵输入才判）。

要点：发现目录按设计真身 realpath 解析（symlink/同目录旧副本不污染对端判定）；
legacy 仅取设计文档自身引用的 archive（精确到模块，防无关归档误报）；缺输入降级
SKIP；负面可验证（删掉对应契约必须 FAIL）。s2 §6c 的 `--prd` 传参已补全
（此前 CS_PRD 计算后未消费——死代码 + ShellCheck SC2034）。

本版同时收录 v3.26.3 全部内容（经验教训入检 8 条——未单独发布，并入本版）。

## v3.26.3 (2026-09-17) — 经验教训入检：8 条 lessons 升级为正式机检（并入 v3.26.4 发布）

P10"教训→检查"闭环首轮落地：对 lessons-learned 全量逐条核对机检覆盖，
8 条未入检教训升级为正式检查（`lessons-learned.md` v1.2.0 逐条附"机检"追溯行）；
L-P2-005（rule_operation_closure）/L-P2-001（硬链接）/L-P0-001（权限三方对账）/
L-P4-001（--mode 透传）等 12 条此前已入检，本轮核实确认。

**新增正式检查（fail-closed 优先）**：

- **L-STACK-003 @Transactional 同类自调用**（critical）：`check-arch-pitfalls` §6
  新增 `check_code_transactional_self_invoke`——@Transactional 方法在同一文件内被
  调用（AOP 代理被绕过、事务静默失效）即拦截；随 P3b 硬门禁（arch pitfalls=0）。
- **L-STACK-001 `.last("LIMIT")` 四方言破坏**（critical）：同上 §6
  `check_code_last_limit`——MyBatis-Plus `.last` 拼接 LIMIT/OFFSET 在 Oracle 报错。
- **L-P3-004 手工 JSON 拼接**（warn 启发式）：§6 `check_code_json_concat`——
  字符串拼接构造 JSON 未转义；误报可能，交 P3b 复核。
- **L-STACK-004 令牌比较常量化**（warn 启发式）：`p3_security_perf_gate` 新增 §6
  `check_token_comparison`——敏感凭据 `String.equals` 时序侧信道，改
  `MessageDigest.isEqual`；P3b 逐条复核。
- **L-STACK-002 认证通道**：`artifact_gate` P7 部署清单强制 `DEV_PRIVILEGED` 声明
  行（缺失即 P0；production=true 即 P0；staging=true WARN）。模板与 deploy.md 同步。
- **L-MON-003 孤岛产物检测**：`p10_feedback_gate` 强制运行
  `checkpoint-state.sh orphans`，报告归档 `orphans-report.txt`，关键产物缺失即 FAIL。
- **L-MON-001 build-watchdog 留痕**：gate 模式输出留痕
  `.devflow/<feature>/build-watchdog.log`。
- **L-MON-002 checkpoint 日志**：save 落独立日志
  `.devflow/<feature>/checkpoints/<id>.log`（与 state 条目可互溯）。
- **L-P3-003 独立安全/性能报告**：核实已由结构化产物层覆盖
  （security.json/performance.json 各自绑定独立渲染报告），不再重复实现。

回归：`tests/test-dev-hardening.sh` 扩至 28 用例（三查拦截、令牌 warn、checkpoint
日志）；既有 P7 正向夹具补 `DEV_PRIVILEGED=false`。

## v3.26.2 (2026-09-17) — 深检收尾：文档一致性 + 状态机输入校验 + doctor 项目自检

全部为小修（z 版），源自对编排契约/状态机/Gate 的第三轮深检（未再发现假绿/阻断级缺陷）。

**文档一致性**：

- `commands/devflow.md`：单轨顺序处注明 `P3cd` 是 P3c+P3d 共用 Gate 的收据别名
  （状态机保留两个原子阶段）；skip 支持面澄清——当前仅 p2b_demo_gate.sh 实现 skip
  分支，其余阶段写 SKIP_ 会按"已授权但 gate 未通过"处理为失败。
- `devflow-state-complete.sh`：文件头注释纠正为本文件真实职责
  （complete/reconcile/acceptance 等——旧头注释复制自 core.sh，误导排障）。

**状态机输入校验**：

- `accuracy` 增加 [0,100] 范围校验（旧版接受任意数字如 999，指标失真）；
- `acceptance complete/inc` 增加上界校验（完成数不得超过验收点总数）；
- `generate_from_template` 的 FEATURE 替换改为词边界（`[[:<:]]FEATURE[[:>:]]`，
  BSD/GNU sed 通用）——旧 `s/FEATURE/x/g` 会误伤 FEATURED 等英文词，并去除重复 `-e`。

**doctor 项目侧自检（`doctor.sh --project`，只读）**：

- 新增一键项目预检：逐 `*.state.json` 结构校验（JSON 可解析 + 关键字段齐备）
  + reconcile 只读漂移报告 + 逐 feature audit-receipts 收据对账——此前项目健康
  需分跑三个命令。

**P7 健康状态语义（声明=校验基准）**：

- `HEALTH_HTTP_STATUS` 改为声明 2xx 状态、Gate 实测必须与声明一致——旧版硬编码
  200，204 No Content 等合法 2xx 健康端点被误判失败；非 2xx 声明仍拒绝。
  模板与 deploy.md 同步更新（200 夹具全部兼容）。

**测试沙箱卫生**：

- 4 个测试的 `cp -R "$ROOT"` 沙箱复制后清理 tests/logs/.git/.backups/_archive/
  __pycache__——下游 manifest generate / release-audit 整树哈希不再吃进运行期垃圾。

**测试提速（并入本版）**：

- `gate-skill-tree.sh`：python3 单进程批量哈希快速路径（单次 4.6s→0.06s，与旧 shell
  实现逐字节等价；无 python3 回退原实现）；
- `run-tests.sh`：并发度 job pool（默认=物理核数，`RUN_TESTS_JOBS` 覆盖；兼容
  bash 3.2）——全量套件墙钟 628s→206s（23/23 全绿）。

## v3.26.1 (2026-09-17) — 核心规则瘦身与运行残留清理

- `concepts/core.md` 不再重复展开 Flyway 四方言、Java 权限和 Mapper/Entity 细则，
  改为按 Runtime Profile 生效的短指针；Profile 专属规则仍保留在对应参考文件。
- 清理本地测试产生的 `tests/logs/` 与 `scripts/__pycache__/` 运行残留（两者均被忽略，
  不进入发布树）。

## v3.26.0 (2026-09-17) — 开发面硬化：修复 4 处假绿/死检查 + P3b 中文路径阻断

本版全部修复项均来自对 skill 自身的深度评审（探针先行、逐项复现），并新增
`tests/test-dev-hardening.sh` 回归钉住。

**假绿（检查失效却报 PASS）修复**：

- **check-code-standards.sh**：文档声明的单服务目录用法扫 0 文件却报"全部 PASS"——
  服务根解析重写（base 是服务目录→单服务口径；多模块根→展开；皆无→fail-closed 拒绝
  零文件假绿）；`--strict` 单独用法不再被 `${1:-backend}` 吃成目录名。
- **detect-n-plus-one.sh**：同样的单服务用法假绿修复；检测模式补 JPA 风格
  （`findById`/`getReferenceById`，phases/03 模板即 JPA 栈）；删除从未消费的
  brace-matching 死代码，显式注明 30 行窗口启发式；零服务目录 fail-closed。
- **p3_security_perf_gate.sh §5**：默认目录 `backend/src/main/java` 在多模块布局下
  不存在 → 扫 0 文件报 PASS；现与 §1/§4 同口径在服务根/全树下递归扫描。
- **check-arch-pitfalls.sh CSRF**：`grep "csrf.disable"` 永不匹配 Spring 实际写法
  `csrf().disable()`（禁用侧永远不可见）→ 改为 `csrf\(\)\.disable` 正则。

**阻断性 bug 修复**：

- **p3_security_perf_gate.sh 收据矛盾**：收据块首即计算 `EXIT_CODE`，其后 jq 缺失/
  证据树失败的 p0 让 FAIL 增加，收据却已冻结 `EXIT_CODE=0`（"命令失败、收据成功"，
  审计重验即漂移）——移到块尾、全部 p0 之后计算。
- **p3b_code_review_gate.sh**：证据树绑定的 criteria 路径硬编码英文回退路径，而
  CRITERIA_PATH 已按中文优先解析 → 中文路径项目（v3.22.0 起默认命名）永远产不出
  P3b 收据；改为复用解析结果（test-chinese-paths 此前未覆盖 p3b，已由新回归补上）。
- **check-entity-db-consistency.sh 缩进回归**：单 SQL 文件多 CREATE TABLE 时 fields
  解析漂移到表循环外（每文件只记录最后一个表，多表项目报告失真）——恢复循环内
  解析；test-dev-hardening 新增多表用例钉住。
- **references 版本对齐 + 版本门禁扩域**：references/ 下 10 个带 frontmatter 的 md
  残留 v3.25.2（Release Audit FAIL=11 正确阻断，而 check-skill-version 轻门禁漏报）
  ——全部升版，且 check-skill-version 的 frontmatter 与标题扫描扩到 references/
  （两道门禁口径一致，同类漂移在轻门禁即拦截）。

**检测能力增强**：

- **p3_security_perf_gate.sh §4**：新增 MyBatis `${}` 拼接扫描（`*Mapper.xml` 任意
  `${}` + Java `@Select/@Update/@Insert/@Delete` 注解含 `${}`），fail-closed P0；
  正当用途行内标注 `mybatis-dollar: allow`。此前 MyBatis 项目第一大注入面零覆盖。
- **p3_security_perf_gate.sh §2**：N+1 检测委托 `checks/detect-n-plus-one.sh`
  （多行窗口 + JPA 模式）——旧单行 grep 对常规多行循环体全部漏检；>5 处 P0、1-5 处
  WARN（与检测器容忍口径一致）；检测范围无服务目录（backend 缺失或无服务）走
  NOT_APPLICABLE/waiver 判定，不误报超阈值。
- **check-arch-pitfalls.sh §8**：N+1 命中判定修复（旧 `grep -q "N+1"` 连 PASS 输出
  都命中→恒 warn 噪音）；`D-??` 占位符改文档编号 §8.1。
- **check-permission-consistency.sh**：文档侧正则补数字段（`order:v2:list` 此前
  永不匹配）；代码侧补 `hasAnyAuthority(...)` 全参量抽取；`TOLERANCE_NEW` 环境变量
  可覆盖（旧 40 硬编码）。
- **check-entity-db-consistency.sh**：补 JPA `@Table(name=...)` 支持（旧版只认
  MyBatis-Plus `@TableName`，JPA 实体全部跳过）；DDL 字段抽取过滤
  PRIMARY KEY/CONSTRAINT 等约束行（噪音）。

**契约统一与可观测性**：

- **`--service` 语义统一**（p3_security_perf_gate）：接受 `--service <v>` 与
  `--service=<v>` 两种形式；裸服务名在 `backend/<name>` 存在时自动归一化为路径
  （与 p3_completion 的服务名语义对齐）；commands/security.md 的 `--scope=` 幽灵
  参数文档已修正。
- **p3_completion_gate.sh**：menu-seed 检查在页面目录约定不匹配时不再无声跳过
  （显式 p1 提示人工核对可达性）；前端 TODO/FIXME 可见化（p1，非阻塞，P3b 评审核对）
  ——此前前端残留无任何 gate 覆盖。
- **check-arch-pitfalls.sh §4**：`/(…)/i` PCRE 语法改 `tolower()` 便携写法
  （gawk/Linux 语法错误 + set -e 中断）；移除部署脚本检查中的历史真实口令字面量，
  换通用 KEY=VALUE 明文模式。
- **secret-scan.sh**：`logs/`、`manifest/` 仅在扫描 skill 自身发布树时排除——扫用户
  项目时同名目录不再形成盲区（日志恰是泄密高发面）。
- **pre-commit-devflow.sh**：安装路径注释更新（旧 `.cursor/` 路径）；豁免提示与
  实际机制对齐（SKIP env 即显式豁免，`--no-verify` 并非必需）。
- **run-tests.sh**：并行模式默认开启（串行全量 ~45min；并行各组独立 mktemp 工作区，
  2026-09-17 全绿验证）；`RUN_TESTS_PARALLEL=0` 回串行。

## v3.25.2 (2026-09-17) — P3c/P3d 证据链加固 + 版本纪律

- **P3 Gate 证据树 fail-closed**：缺 jq 不再静默降级（降级即审计失去对 security/performance JSON 的保护）——直接 P0 阻断。
- **report_path 三重约束**：工作区内相对路径（拒绝绝对路径与 .. 越权）+ 真实落盘 + 与 `df_render` 从当前 JSON 的渲染产物逐字节一致（手工改动/双正本漂移即 P0）；实际报告路径纳入 EVIDENCE_PATHS_JSON 证据树，审计可重验。
- **版本纪律**：全局升版 v3.25.2（此前 security/performance 命令与源码注释残留 v3.25.2 字样而主版本仍为 v3.25.1）。

## v3.25.1 (2026-09-17) — 结构化正本接入 Gate + 正文质量 lint（评审问题修复）

- **P0 悬空引用修复**：phases/02 与分文档模板引用的 `scripts/check_design_doc_quality.py` 实现为真实工具（DQ-001 交叉引用 / DQ-002 规则引用 / DQ-003 接口消费三类闭环，支持项目规则文件白名单），prompt-refs 回到 3 PASS / 0 FAIL。
- **P0 Gate 接入 JSON 正本（失败关闭）**：`s0` §1b——acceptance.json 缺失/校验失败/与 Markdown 分母不一致即 P0，收据绑定 ACCEPTANCE_JSON_SHA256；phase-docs 新增不可绕过证明（112 → 116 PASS）。
- **P3c/P3d 结构化层**：新增 security/performance schema+样例+validator 专项检查，p3_security_perf_gate 失败关闭接入并绑定 JSON SHA。
- **P3c/P3d 闭环收口（评审二轮）**：df_render 新增 security/performance 渲染器（df_pipeline 两种 kind 端到端可用，P0）；/security、/performance 命令补「JSON 正本 → df_pipeline 渲染 → Gate」路线（P0）；P3cd 收据把报告与两种 JSON 纳入 EVIDENCE_PATHS_JSON 证据树，audit-receipts 重算树哈希——Gate 后替换 JSON 必 FAIL（P1，孤立 SHA 漏洞关闭）；check_response_time 重写为 performance.json 逐场景对账（实测 P95 必须出现在压测报告、阈值取自 JSON，废除固定 500ms 双事实源，P1）。

- **声称对齐**：SKILL.md 改为精确的 Gate 强制矩阵（P0/P2/P3c/P3d/P6 已强制；其余 kind 管线已强制、Gate 分批接入）。

## v3.25.0 (2026-09-17) — 全阶段结构化产物（每个环节的 md 产物都有 JSON 契约）

> 把 P2 design.json / P6 verification.json 的「JSON → 校验 → 渲染 → Gate」失败关闭模式推广到全部环节：
> 每个阶段的人读 Markdown 产物都有了机器可读的 JSON 正本（schema 声明「要填哪些内容」），
> 校验器与渲染器在渲染前拦截缺字段/断链/占位/伪造证据，Gate 仍按原格式解析渲染产物（逐字段兼容）。

- **15 个新结构化产物 kind**（`df_pipeline.py` 子命令 = JSON 落盘名）：clarification/acceptance/constraints（P0）、prd-review（P0b）、tech-selection（P1）、design-review（P2a）、self-check（P3）、code-review（P3b）、prd-validation（P4）、test-cases（P5）、deployment（P7）、monitoring（P8）、docs-index（P9）、retrospective/sharing（P10）、demo-signoff（P2b）、small-change（SMALL-CHANGE）。
- **P2b/P10 收口**：demo-signoff 渲染与 p2b_demo_gate.sh 逐字段兼容（KUF 唯一编号 ≥3 且每条带走查、原型文件 docs/原型/ 实存反查、PO 结论禁止未决表述、签字人+日期）；sharing 覆盖 p10 知识分享 ≥3 条 lesson；retrospective 补「本次新发现」强制章节（p10 gate H2 检查）。
- **产物路径对账修正**：phase 文档的渲染目标路径与 Gate 实际解析目录对齐——PRD评审→docs/需求、技术选型→docs/详细设计、监控配置→docs/发布（df_resolve_doc 目录键为准）。
- **schema 注解通用引擎**：`df_validate.py` 支持 schema 顶层 `x-unique`（数组唯一）/`x-refs`（引用闭环）/`x-zeroable`（空集合必须 zero_results 显式声明，声明必须真为空）/`x-min-count`（数量下限）四类注解，15 个产物的通用规则一次实现；各 kind 深度规则在 `check_<kind>` 专项函数（P0 模糊点清零、验收点全 FROZEN、DF 五字段+角色覆盖、权重合计 100%、收据 session 一致、核心检查全 PASS、同人自签、P0 finding 全 CLOSED、决策可复算…）。
- **整文档确定性渲染**：`df_render.py` 新增 14 个整文档渲染器 + small-change 三件套（报告 md + `small-change.env` + `project-scan.txt`）。渲染格式与各 Gate 的机器解析契约逐字段对齐：s0 的 P0 行扫描/分母冻结行/模板 H2 对齐、tc_constraints_lib 的 DEVFLOW:CONSTRAINTS 块、s1 的 CONSTRAINT-BINDINGS 块、p2a 的 REVIEW_RUN_ID/收据表/DF 块、p3b 的 `FINDING|P0|…|STATUS=…` 行（P0-ID 不在正文重复出现）、p4 的 `P0_BLOCKERS=0` 行、artifact_gate P7/P8/P9 的 KEY=VALUE 证据行。
- **验收点 ID 规范形收紧**：acceptance.json 的 ID 必须 `M-xx-Fyy-Azz` 带连字符（s0/p5 Gate 的 M-ID 正则只认此形态，无连字符形态实测被判 invalid）。
- **测试**：新增 `tests/test-structured-artifacts-phase-docs.sh`（97 断言：15 kind 正向校验、18 个代表性负向拦截、Gate 机器标记 grep、真实 s0 Gate 端到端、管线失败关闭）；原有 `test-structured-artifacts.sh` 72 断言回归通过。
- **工作方式变化**：写阶段产物 = 填 `.devflow/<feature>/<kind>.json` → 跑 `df_pipeline.py <kind>` → 渲染产物进 Gate。模板保留为语义参考；校验失败不渲染、不落盘、不进 Gate（失败关闭语义与 P2/P6 一致）。

## v3.24.0 (2026-09-17) — 详设体系体检报告修复（业务行为契约 + 机器证据闭环）

> 来源：`devflow 详设体系体检报告`（16 项发现，A01-A16）。按报告第 5 节修复顺序实施：
> 先修可执行性故障，再补业务行为与实现证据契约，然后统一事实源与适用性，最后收敛流程口径与回归。

### 修复顺序 1 · 可执行性故障

- **A08 P2a 角色表解析**：§2 对 awk `$2` 直接 gsub 会以 OFS 重建 `$0`，下游按 `|` 重拆恒得空字段——正常评审表被误拒（实测 FAIL=11）。§1b/§2 统一改局部变量（role_cell 等）输出原始行。
- **A07 渲染块注册表**：`df_render.py` 声明 10 块、实际写 12 块（resource-operations/integrations-configs 未列入）——按声明搭骨架触发 `ValueError` 崩溃。块注册表改为渲染块集合唯一正本（现 13 块，新增 biz-ops）；新增 `--init-doc` 初始化入口；三份详设模板内嵌全量锚点块，复制模板即可直接走管线。
- **A05 总分模式正文对账**：s2 仅 monolith 传 `--doc`——sub 分文档删掉接口详细定义标题仍 exit=0。现全模式对账；p2a 四要素定位从固定 §12.1/§12.2/§13/§2.3 编号改语义锚点（component-reuse/common-extraction/standards-compliance/design-decisions，三模板已补锚点）。
- **A10 收据协议对齐**：`phases/02a`/`design-review-committee`/`agent-runtime-adapter` 与真实运行协议统一——共享 REVIEW_SESSION_ID（AUTHOR+五角色同 session）、`--attestation` 平台证明必填（REVIEW_ATTESTATION_PUBKEY 环境）、begin 于 spawn 返回 agent_id 后/产出前、complete 于聚合报告冻结后统一执行、复审每轮新 session；不得用模型自签替代平台证明。
- **A16 占位与引用**：s2 新增围栏外 `{xxx}` 花括号变量检查（实测「{业务方填写}」曾通过 P2）；`design-review.md` 悬空引用 `concepts/design-review-process.md` 改指 `review-depth-methodology.md`；完整版模板 §7.2/§7.4 的 §5.x.x 接口引用修正为 §3.2.x。

### 修复顺序 2 · 业务行为与实现证据契约

- **A01 业务操作契约**：design.json 新增必填 `business_operations[]`——操作以业务命名（非 CRUD 枚举），逐项覆盖触发者/输入/前置校验/源目标状态（无状态显式 stateless）/执行顺序/事务并发/结果/失败/关联对象/副作用/测试场景；`acceptance_refs` 并集必须等于冻结验收集合（缺"恢复""彻底删除"等即覆盖缺口拦截）；渲染 `biz-ops` 块；s2 要求 WHEN 伪代码与 sequenceDiagram 成对。
- **A02 真实代码基线**：design.json 新增必填 `baseline.entries[]`——REUSE/MODIFY/DELETE 目标在仓库内反查存在（虚构 `MODIFY FooController#list` 直接拦截）、ADD 须声明 target_module、每条带验证方式；`baseline.db_evidence` 区分迁移 DDL 静态事实与目标库实际 schema（live_schema 须记来源与时点）。
- **A03 JSON↔正文对账**：df_validate 新增正文事实对账——JSON 字段必须出现在锚点小节表格首列、类型归一化后一致（同字段双正本冲突拦截）；锚点小节不得是空壳（实测仅标题正文曾通过 --doc 校验）。
- **A09 深度评审实质化**：ZERO-DF 必须含核查实质（空标题拦截）；AW 三段（场景/走查路径/结果）非空且结果的 §锚点解析到详设真实标题、DF 引用存在于报告；探针证据锚点同样解析（虚构 §99.99 不再放行）。

### 修复顺序 3 · 事实源与适用性统一

- **A04 引用闭环**：`prd_anchor` 来源文件必须真实存在（does-not-exist.md#L99999 拦截）；嵌套锚点（apis[].request/response.anchor、client.journeys[].page）逐一闭环。
- **A06 适用性**：s2 §4/§5 表头检查按 design.json 空集合声明豁免（合法纯计算设计不再被误拒）；§2d 新增冻结 frontend 与 design.json client.scope 对账（state 冻结 app 声明 not-applicable 拦截）。

### 修复顺序 4 · 流程口径与回归

- **A12 设计完成统一口径**：设计完成 = P2 内容校验 + P2a 实施可行性评审；`--design-only` 在 P2a 后停止；`/plan` 与 `/build` 消费同一份 P2a 批准收据（缺失 BLOCKED）。
- **A13 评审模板口径**：通过条件改"所有 DF CLOSED（OPEN=0）"（废除"P2 问题少于 10 条"）；P5 决策 Why 链主责改 DBA+架构师（业务专家不在 canonical roster）；AW 走查路径按「触发→输入→处理→依赖→结果」实例化为 Web/MQ/任务/批处理形态。
- **A14 P0b 深度口径**：DF 按实际发现（废除总数 ≥5/每角色 ≥1 凑数），每角色须有 DF 或含核查实质的 ZERO-DF 证据，与 review-depth-methodology 统一。
- **A11 模板示例冲突**：分文档 §5.3.1/§5.3.2 补全请求/响应双六列表；两模板删除时序改为"关联存在→回滚拒绝"分支先于写入（与伪代码一致）；完整版删除流程补并发口径说明（锁/复合约束二选一，"放进事务"不是并发安全证明）；审计失败回滚改为按审计策略显式决策。
- **A15 回归钉**：新增 `tests/test-design-contract-hardening.sh`（30 断言）——每条负向断言从合法样本变异单一因素：块注册表/管线正向、业务操作覆盖缺口、虚构基线、类型冲突、空壳正文、PRD 源缺失、嵌套断链、角色表解析、纯计算豁免、frontend 漂移、花括号占位；废除 v3140 回归中过时的"9<10 DF 阈值"断言，改钉五字段/引用解析契约。

### 第二轮补齐（2026-09-17，对照报告逐条收口）

- **A02 收口**：`baseline.entries[]` 新增 `fingerprint`（64-hex 文件 SHA-256，工作区反查时实算比对，基线漂移拦截）与 `related_operations`（关联业务操作，悬空引用拦截）；**P2 收据证据树绑定基线调查过的源码文件**——评审/实现期间源码被改写 → audit-receipts 重验 FAIL。
- **A03 收口**：五列表**约束列**与 JSON 比对（同字段约束不一致拦截）；`rules[].when_line` 逐字契约——正文伪代码改写而 JSON 不同步即"规则不一致"。
- **A04 收口**：`acceptance.page/api/data` 支持**多对象数组**（一条验收行为可关联多个页面/接口/表），孤儿判定与断链校验按元素粒度；渲染器以「、」连接。
- **A05 收口**：新增**设计包清单** `design-package.json`（`scripts/df_design_package.py`）——总分模式必填：子集并集=冻结分母（多/少即 FAIL）、登记文档必须存在（缺文档即失败）、当前文档按其验收子集做范围过滤的文档对账（`df_validate --scope-ids`）；三模板过时的"已知未决 total 逐点 COMPLETE"注记更新为设计包契约。
- **A06 收口**：纯 UI/消息消费者/小程序/APP 四类**正向夹具**入回归（`test-design-package-modes.sh`）。DB 适用性仍由 `migrations.not_applicable_reason`（铁律 5）承载——P0 无 `--no-db` 冻结参数，新增属 P0 协议扩展另行评审。
- **A07 收口**：sub/total 两模式完成「模板拷贝→最小合法填充→管线→Gate」**完整正向测试**（monolith 已有）；顺带修复模板自身两处缺陷——铁律注释块缺 `-->` 闭合、示例文本"成功占位"撞 Gate 占位词、总文档缺 acceptance-traceability 锚点。
- **A08 收口**：**完整 P2a 正向 fixture** 落地（`test-review-receipt-lifecycle.sh`）——真实测试密钥签发 12 份 attestation、六角色两阶段收据、报告满足全部深度契约 → 整道 Gate PASS。
- **A09 收口**：p2a § 锚点解析支持单级（§5 与 §2.3 同法），AW/探针引用解析覆盖全部真实章节。
- **A10 收口**：初审/复审（新 session 全流程）/缺平台证明清楚报错/错误密钥签名拒绝，四条生命周期测试齐备。
- **A13 收口**：**严重性修订纪律**机检（p2a §3h）——修订后严重性变化的行，修订理由与确认评委必填，无理由降级直接 P0。
- **A15 收口**：负向断言升级为**点名被变异对象**（缺失的验收 ID、虚构目标路径、冲突类型值）；评审正文/复审生命周期/三模式完整正向测试补齐。
- **A16 收口**：新增 `tests/test-prompt-refs.sh`——扫描活提示词（commands/phases/subagents/references/concepts/templates/SKILL.md）反引号与链接引用的 skill 内部路径（455 处）逐一验证存在；CHANGELOG 为历史迁移记录按设计豁免。
- **CODE-BASELINE 探针**（报告 §5 建议）：p2a 新增第七类探针——详设含 REUSE/MODIFY/DELETE 基线时必答（绿地可记不适用），证据锚点须解析详设真实章节；同步更新评审报告模板、committee、02a、Gate 与测试。
- **§4"业务对象与术语"**：由 data-model（tables[]/ER/孤儿与引用闭环）+ business_operations.related_objects 承载机器对账，语义判断归评审（报告原文："这些是必须作出决定的问题，不是预先规定的业务答案"）。

## v3.23.1 (2026-09-16) — 开源硬化（深度审阅报告修复）

> 来源：`devflow 开源仓库深度审阅与改进报告`。本轮只做协议边界与分发硬化，不动 P0-P10 流程语义。

- **消除第二 Skill 入口歧义**：`concepts/SKILL.md` 重命名为 `concepts/core.md`（`name: devflow-concepts-core`，不再是一个可被扫描发现的合法 Skill）；全部活跃引用同步更新。官方规范中"含 SKILL.md 的目录即 Skill"，避免辅助目录被误识别。
- **SKILL.md 输入/输出契约**：正文顶部新增 Receipt 契约——输入（PRD/交付模式/可选参数）与每阶段输出（`phase` / `status: PASS|BLOCKED|SKIPPED` / `artifacts[]` / `verification[]` / `blockers[]` / `next_phase`），Gate 失败不得推进、外部副作用先授权。
- **Codex 隐式触发关闭**：`agents/openai.yaml` 设 `policy.allow_implicit_invocation: false`——devflow 可写码、迁移、部署，Codex 侧必须显式调用；Claude Code / Cursor / Trae 按 description 触发不受影响。外部副作用仍由发布授权收据（原则 14）硬门禁。
- **触发文档口径修正**：`concepts/natural-language-triggers.md` 的"500 词限制"改为官方口径（主文件 < 500 行、完整指令约 < 5000 tokens），并注明本 skill 的 ≤500 词自律门禁。
- **安装体验**：新增 `scripts/install.sh`（软链安装器，覆盖 claude/codex/cursor/trae/trae-cn，幂等、不覆盖实体目录）与 `scripts/doctor.sh`（核心/可选依赖体检 + 副本直连校验）；`README.md` 增加 30 秒上手，并将 Codex 路径更正为 `$HOME/.agents/skills`（旧 `~/.codex/skills` 已过时）。
- **仓库级开源硬化**（skill 目录外）：根 `README.md` 安装指引修正；`.gitignore` 增加 secrets 忽略面；新增 `.github/workflows/devflow-ci.yml`（Linux/macOS 跑语法检查 + Python 编译 + 完整测试）、`SECURITY.md`、`CONTRIBUTING.md`、`THIRD_PARTY_NOTICES.md`（P3C Apache-2.0）与 Issue/PR 模板。
- **未采纳/延后**：历史 manifest 与 `CHANGELOG` 不瘦身（hash-chain 依赖历史 manifest 逐字节不可变）；demo GIF、多 Skill 拆分属 P2 展示与长期演进，另行排期。

- **剩余产物中文化收尾（任务契约/主索引/评分卡）**：`/plan` 输出改 `任务/执行契约.md` + `任务/待办.md`（历史 `tasks/plan.md`、`tasks/todo.md` 继续被 `/build`、自检命令识别，双语回退进 `devflow_paths.sh` 的 `df_resolve_task`）；`generate-master-index.sh` 默认输出改项目根 `主索引.md`（历史 MASTER.md 存在且无中文版时沿用，标题行随输出文件名）；`super-scorecard` 示例、`init-fact-sources` usage 的 `docs/design` 示例同步改中文；`test-chinese-paths.sh` 补任务/主索引三态断言并修复子 shell 计数失真（17 断言全量计入）。

## v3.23.0 (2026-09-16) — 通用化修复（Agent Skills 兼容 + Runtime Profile + 发布授权 + Secret scan）

- **Agent Skills 规范对齐**：`SKILL.md` frontmatter 改为顶层 `compatibility` 字符串、`metadata` 全字符串、`allowed-tools` 空格分隔字符串；`description` 覆盖自然语言开发触发（实现需求/加字段/改接口/修复 bug/上线部署），不再依赖用户提到 `/devflow`。`release-audit.sh` 同时接受空格分隔字符串与 YAML 列表两种 `allowed-tools`，未知工具名仍 fail-closed。
- **触发评测语料**：新增 `tests/trigger-cases.yaml`（正/负样例、期望路由与 precision/recall 目标）与 `tests/test-trigger-eval.sh` 结构校验，注册进完整测试套件。
- **Runtime Profile（技术栈解耦）**：新增 `references/runtime-profile.md` 能力位契约与 `references/profiles/{java-spring-flyway,generic}.md`；`commands/build.md` 将 `@PreAuthorize`/四方言/JaCoCo 等 Java 规则下沉到 profile，核心 P3 只要求 BUILD/TEST/COVERAGE/AUTHORIZATION/MIGRATION/CLIENT/SECURITY 能力位。
- **代码生成 Subagent I/O 契约**：`backend-dev`/`frontend-dev`/`sql-dev` 统一 Input/Scope/Output/Forbidden/Stop 契约（缺输入 BLOCKED、PLAN 先行、真实退出码）。
- **发布授权硬门禁**：P7 前必须存在 `.devflow/<feature>/authorizations/release.json` 显式人工授权；无收据最高 `READY_TO_RELEASE`，不得声明 `RELEASED`（`commands/devflow.md`、`commands/deploy.md`、`phases/07-发布部署.md`）。
- **敏感信息机器契约**：新增 `references/sensitive-data-policy.md` 与 `scripts/secret-scan.sh`（高置信度模式、脱敏输出、`secret-scan: allow` 例外）；接入 `release.sh` Phase A 与 `hooks/pre-commit-devflow.sh` 暂存文件扫描。
- **模板变量约定**：`templates/_commons.md` §12 统一 `{{variable_name}}`，未解析变量不得判定完成。
- **版本一致性修复**：修复 `ROUTING.md`/`prd-review-committee.md` 标题与 `release.sh`/`devflow_paths.sh` banner 的版本漂移。
- **P2 详设链路重构（语义锚点正本）**：
  - 三个详设模板新增/对齐五个语义锚点——`data-model`、`api-contracts`、`business-rules`、`acceptance-traceability`、`implementation-handoff`；章节编号降级为展示与 design.json 定位用途，`s2`/`p2a` Gate、`/plan`、`/build` 一律以锚点为机器契约（历史产物按同义 H2 标题回退兼容）。
  - **新增 §14 实现交接（Implementation Handoff）**：现有实现基线、预计代码变更（ADD/MODIFY/DELETE）、不变量清单；`s2` 必含校验，`/plan` 从其派生执行契约，`/build` 开工前对账，不符即 `BLOCKED`。
  - **模板版本硬冲突修复**：模板正文 `> 模板版本：` 改为 `{{template_version}}`（必须替换为 frontmatter version），并新增 `check-skill-version.sh` 正文版本字面量守卫；写作铁律中陈旧的 §9.1/§2.3/§5.3/§4/表头 H5 等级等引用全部修正为真实结构（追溯矩阵 §11.1、表 §2.2、接口 §3.2、流程 §6）。
  - **模板状态默认值收紧**：文档状态由「✅ 评审通过」改为 `⏳ DRAFT`、评审结论 `UNREVIEWED`——只有 P2a 通过后才更新为 ✅，消除"生成即已评审"的误导。
  - **`phases/02-详细设计.md` 瘦身**：删除与模板重复的示例骨架（架构图/users SQL/ERD/前后对比），改为"输入 → 现有代码基线调查 → 模板选择 → 必答设计问题 → Gate → 失败处理"；DB 关键字清单移至 `references/db-reserved-words.md`；删除"设计要支持未来扩展"，改为三条件演进约束与"现有能力 > 现有依赖 > 标准库 > 新依赖（需 Design Decision）> 自研"复用优先级。
  - **`/plan` 改执行契约**：任务矩阵列改为 Task/Acceptance/DesignRef/Target/Action/Invariants/Verify/Risk/依赖；垂直切片重定义为"独立验证的行为闭环"（组件可选，测试必需），移除文件数分级/ETA 等项目管理列。
  - **`/build` 与 backend-dev 施工纪律**：强制 `DISCOVER → PLAN PATCH → IMPLEMENT → VERIFY → DIFF REVIEW`；写码前定位入口/同类实现/公共组件/测试模式并与实现交接对账，新增"未搜索就新建工具类/未确认依赖就加库/为过测试放宽断言"等禁止项。

## v3.22.0 (2026-09-16) — 过程性产物文档层中文化（中英双语回退）

- **范围（仅人类文档层）**：`docs/` 下过程性文档默认改中文名——目录 `docs/需求`、`docs/PRD`、`docs/详细设计`、`docs/评审`、`docs/原型`、`docs/测试`、`docs/测试用例`、`docs/测试报告`、`docs/发布`、`docs/复盘`、`docs/知识沉淀`、`docs/事故复盘`、`docs/小需求变更`；文件后缀如 `<feature>-需求澄清.md`、`-验收点.md`、`-技术约束.md`、`-详细设计.md`、`-设计评审报告.md`、`-代码审查报告.md`、`-PRD验证报告.md`、`-终验报告.md`、`-部署记录.md`、`-监控配置.md`、`-文档索引.md`、`-复盘.md`。
- **中英双语回退（零迁移）**：新增 `scripts/devflow_paths.sh` 单一映射库（中文默认写、解析中文优先英文回退）；所有 Gate、索引生成器、hook、maintenance/s8、s8b 证据表经此解析。历史英文布局项目继续通过，无需改动。
- **哈希兼容**：`compute_artifact_hash` 同时纳入中英 docs 目录（存在才计），改名不引发 ARTIFACT_HASH 漂移。
- **事实源**：`_commons.md`、`_权限矩阵.md`、`_环境与账号.md`、`_菜单Seed索引.md`、`INDEX-*.md` 文件名是机器 grep 契约保持英文/原名，仅随目录迁移；`init-fact-sources.sh` 与 `generate-*` 默认写 `docs/详细设计/`，已存在英文目录且无中文目录时沿用英文目录。
- **不翻译的机器契约**：`.devflow/` 下 `receipt.txt`、`*.state.json`、`design.json`、`verification.json`、`*.tsv`、`*.env`、`skip-log.txt`、`feedback/`、`review-sessions/`、`gates/<PHASE>/`，stage 名（P0–P10 等）、ASCII feature 标识，以及 `-implementation-evidence.tsv`、`-p4-results.tsv`、`-unit-coverage.html`、`-migration-evidence.env` 等被表头/键解析的文件。
- **文档与测试**：phases/commands/subagents/concepts/templates 共 60+ 文档约定路径同步中文（机器键名不动）；新增 `tests/test-chinese-paths.sh`（中文布局通过 / 英文布局兼容 / 中文优先三态），并注册完整套件。

## v3.21.1 (2026-09-16) — P4 执行证据与发布树修复

- **P4 自报 PASS 收口（P0）**：`p4_validation_gate.sh` 现要求并亲自执行受信 `P4_CMD`，捕获非空日志，校验 `P4_RESULTS_PATH` 的 `ID<TAB>STATUS` 与冻结验收集全等且全部 PASS；报告、原始证据、结果表和执行捕获写入同一证据树收据。
- **P6 状态元数据收口（P1）**：`audit-receipts.sh` 在 P6 已完成时，强制验收计数等于 frozen baseline，并要求可解析的首轮快照与准确率。
- **P6 空捕获收口（P1）**：成功测试命令若没有任何 Gate 捕获输出，终验以 `P6_EXECUTION_LOG_EMPTY` 阻断；不得用重定向隐藏运行器 stdout/stderr。
- **发布卫生**：修复 active phase 版本与 allowed-tools 漂移、过时本地链接和 s2 未花括号多字节变量；新增 v3.21.1 证据门禁回归夹具并注册完整套件。

## v3.20.8 (2026-09-15) — 第 4 轮对抗复查 P3 收口（无 P0/P1/P2）

- **grep -c 双值缺陷**（s8，P3）：清单计数 0 时 `grep -c || echo 0` 产出 "0\n0" 触发 integer expression expected stderr 噪声——改为先捕获再判空。
- **已知限制记录**（第 4 轮评估，不改行为）：REPORT 参数无路径白名单（调用方同权级，非提权通道）；FALLBACK_FILE_LIST 仓内 symlink 可指仓外文件（清单 SHA 钉死目标内容，篡改即检出）；git log --name-only 对换行文件名 C-quote 后被静默排除出 KEY_FILES（覆盖率下降无假绿）；manifest 目录恶意文件名触发 fail-closed DoS（无注入）。
- 第 4 轮验证：v3.20.7 三项修复（status 净化/短路/剥 CR）全部有效，B1-B7 排查面干净。

## v3.20.7 (2026-09-15) — status 注入通道封堵（第 3 轮对抗复查 1P0+1P2+1P3 收口）

- **index_status 注入封堵**（s8，P0）：第 2 轮只封了 identity/path 的报告行注入，`.status` 字段同型通道仍开放并实证到"第 2 轮消费注入指针 WARN 放行"完整攻击链。现 status 同样 strip_crlf + 枚举白名单（非 known 状态按 unknown 处理阻断）。
- **归一化失败整体短路**（s8，P2）：任一身份候选归一化失败即整体 mismatch——此前"失败候选跳过、其余照常匹配"产生报告 index_identity_match=true 与 P0 并存的语义矛盾。
- **PREV 指针剥 CR**（s8，P3）：证据指针回写/消费链 tr -d '\r'（终端视觉残留）。
- test-v3203-hardening 25 项全绿。

## v3.20.6 (2026-09-15) — s8 身份对账重构（第 2 轮对抗复查 3P1+3P2 收口）

- **报告行注入封堵**（s8，P1）：索引身份字段提取后立即剥离 CR/LF——此前远端身份串含换行可向报告注入任意 key=value 行（含伪造 source_fallback_evidence 指针与 index_identity_match=true），第 2 轮被消费成功 WARN 假绿；同时两处 PREV/消费 grep 锚定行首（^）+取值改 f2-（含=值不截断）。
- **归一化 fail-closed**（s8，P1）：python3 缺失/损坏时含 `..` 段的身份串此前回退原始串匹配（与 v3.20.5 CHANGELOG 声明相反的 fail-open）——现归一化失败即拒绝该候选，整体不回退。
- **拼接重组封堵**（s8，P2）：identity 与 path 不再拼接对账（`re`+`po` 可重组仓名）——改为两字段各自归一化、逐字段对账。
- **空变更范围 crash**（s8，P2）：GIT_RANGE 内全部为删除时 KEY_FILES 为空，bash 3.2 set -u 下 unbound 崩溃——空数组安全展开，空范围按设计走 WARN。
- **段级 .. 约束**（s8，P2）：fallback 清单路径约束从"串内任意 .."收窄为路径段级 `..`——文件名中间含 `..` 的仓内合法文件不再误伤。
- **结构错误消息**（release.sh，P3）：副本对账 rc=2（symlink 异常等）不再提示"先运行 --apply"（无效操作），明确须人工处理。
- test-v3203-hardening 23 项全绿（新增注入/归一化/段级 .. 钉）。

## v3.20.5 (2026-09-15) — 图谱身份绑定第二轮加固（独立对抗复查发现收口）

- **仓名段边界匹配**（s8）：索引身份含本仓仓名"子串"不再命中（repo-backup/repo_x 不匹配仓名 repo）——此前 `/x/other/repo-backup` 在仓名 repo 的仓内被判 PASS。
- **未归一化路径段防护**（s8）：索引身份含 `/../`、`/./` 段时先做 normpath 归一化再对账——否则 `/a/repo/../other/repo-backup` 会让本仓真实路径作为子串命中。python3 归一化，缺失环境退化为剔除 `/./` 并对含 `..` 的串 fail-closed。
- **fallback 清单路径约束**（s8）：`FALLBACK_FILE_LIST` 行拒绝绝对路径与 `..` 逃逸段——SHA 对账不再能锚定仓外任意文件。
- **git-range 文件过滤**（s8）：范围内"先增后删"的路径（经其 add 提交出现在 ACMR 中、磁盘已不存在）不再计入 missing 噪音。
- **短 SHA 身份兼容**（s8）：索引以 HEAD 前 12 位短 SHA 报告提交身份时接受（12 位 hex 子串碰撞概率可忽略，语义仍是"索引串包含本仓锚点"）。
- 新增 4 项行为钉（test-v3203-hardening 19 项全绿）。

## v3.20.4 (2026-09-15) — v3.20.3 收口后的测试与卫生修复

- **tests/.gitignore 模式修正**：`tests/logs/` → `logs/`（模式相对 .gitignore 所在目录，旧写法不生效，运行日志可能入库）。
- **test-v3203-hardening 沙箱互踩修复**：源树已发布 manifest 后，hash-chain 沙箱演练须先移除当前版本 manifest 与台账（generate 拒绝同版本重写是正确行为，非缺陷）。
- **两脚本 banner 版本对齐** v3.20.4。

## v3.20.3 (2026-09-15) — 证据链防伪造与发布事务化（审计修复轮）

### P0
- **事实源收敛**：v3.20.2 曾在项目副本直接发布、唯一源停滞 3.20.1 的版本分裂已收口——唯一源（~/.codex/skills/devflow，~/.agents 为其符号链接）重新成为唯一事实源，3.20.2 manifest 历史原样保留。
- **评审收据两阶段化**（review-receipt.sh）：create 单阶段可由同一编排器在报告完成后整批补写（六份虚构 agent ID 全 PASS，实证）。改为 `begin`/`complete` 两阶段——begin 在评审产物尚不存在时登记 role/agent/input SHA 与 started_at 并锁定角色映射（session-manifest），complete 绑定输出 SHA；verify 要求角色集合恰等于 AUTHOR+5 角色（缺、重、多均 FAIL）、全部收据两阶段齐备、时间窗单调。feature/session/agent 全部白名单（`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`）+ realpath containment（`--feature ../escape` 不再能写出 STATE_DIR）。收据原子写（mktemp+mv）。
- **图谱 Gate 身份绑定**（s8_graph_health_gate.sh）：只记录 index identity、stale 仅 WARN 的假绿已收口—— Gate 现计算 repo 期望身份（realpath+HEAD+tracked 树 hash），索引身份不匹配即 P0；index stale 从 WARN 升级为阻断（stale 索引放行等于让审查基于过期图谱）。`--git-range` 从"只解析不使用"改为真实文件发现来源（变更文件集替代四个固定文档），git 不可用时降级并 WARN。fallback 证据重算所列文件 SHA（FALLBACK_FILE_LIST 逐行 `<sha> <path>`，FALLBACK_SHA256=清单文件自身 SHA）；FINDINGS 允许 0（完成审查零发现合法），完整性由文件清单 hash 绑定保证而非"发现数≥1"。
- **manifest 防历史篡改**（gen-skill-manifest.sh）：tree_hash 排除 manifest 目录导致历史 manifest 可被静默改写（篡改 tree_hash 后 check 仍 PASS，实证）。新增 hash-chain：每份 manifest 记录 parent/parent_tree_hash/chain_hash，CHAIN.json 台账绑定全部历史 manifest 的内容 SHA；check 现在同时校验当前 manifest + 全链历史 manifest 未被篡改。
### P1
- **发布原子事务化**（release.sh）：原第 5 步落不可变 manifest、第 6 步才查副本，中途失败留下"manifest 已占位"半发布态。改为：全量只读预检 → stage 临时 manifest → 副本/state 预检 → activate 原子落盘+台账更新 → 同步 → 复核；activate 后任一步失败自动回滚（删除本次 manifest + 还原台账）。
- **Codex 分发正规化**：项目仓副本迁移 `.codex/skill/devflow` → `.agents/skills/devflow`（官方 Codex 自动发现路径，原路径留兼容符号链接）；用户级副本（claude/cursor/trae-cn）改为指向唯一源的符号链接，sync-copies.sh 对 symlink 目标判 LINKED 而非内容 diff；新增 `agents/openai.yaml` 声明调用策略；allowed-tools 明确为跨平台元数据而非 Codex 权限边界。
### P2
- **发布测试提速/可观测**（run-tests.sh）：分组计时/独立日志/超时保护/汇总报告；skill 树 hash 每次测试进程只真实计算两次（首尾锚定），组间复用缓存；无共享状态测试组支持 RUN_TESTS_PARALLEL=1 并行。test-evidence-hardening.sh（1948 行）按领域拆分为 receipt/fallback/gate 三个文件。
- **concepts/SKILL.md 瘦身**：事实源清单、架构陷阱细则等移至按需 reference，启动必读面只保留铁律与路由。

## v3.20.2 (2026-09-15) — P6/P2 对抗加固（7 项审计发现收口）

### P0
- **平台精确匹配**（s6）：verification.json 声明的 frontend_scope 必须与冻结值全等（P6_SCOPE_MISMATCH/P6_SCOPE_UNDECLARED）——此前 mini-program 冻结 + 声明 pc-web 仍 PASS。
- **报告路径碰撞**（s6）：五类报告路径禁止与终验报告本体 docs/test/<feature>-final-verification-report.md 相同。
- **测试命令来源绑定**（s6）：`_validate_test_provenance`——受信运行器白名单 + 工程清单存在性 + 报表生成器（echo/awk/cat…）拒绝 + bash/sh 包装拒绝；官方 awk 正向夹具升级为 make 受信运行器。
### P1
- **P2 收据纳入统一证据树**（s2 绑定 design+criteria+design.json，audit-receipts 重验：篡改即 FAIL，此前 DESIGN_JSON_SHA256 无消费者）。
- **锚点加固**（df_validate）：~~~ 围栏同标记闭合；pages/tables/apis 按 anchor+name 二元组判重。
- **补偿链闭环**（df_validate）：零反向操作阻断；同资源互斥 release_timing 阻断；configs active 消费点 location 占位拒绝 + 全仓反查（工程标志/显式 --workspace 时）。
- **lib 级 LC_ALL 根治**（devflow_receipt realpath 剥离 LC_ALL）——修复 small-change 全套与 phase-gates P2 fixture/P4 exact-evidence 的环境性失败（phase-gates 28/2 → 30/0）。
### P2
- **免客户端文案条件化**（df_render）：declared=true 改述"四类测试已执行，客户端按声明豁免"。
### 回归
- 新增 tests/test-p6-hardening.sh（6 钉：P0-1/P0-2/P0-3a/P0-3b/P1-4 前置+篡改）注册 run-tests；evidence-hardening 124/0、structured 72/0、report-regressions 36/0、small-change 21/0、release-hardening 21/0、contracts 72/0。

## v3.20.2 (2026-09-14) — 详设模板演进（总分/单体/总文档三套）

- **§7 前端页面九段契约级结构**：页面清单（子域+组件真实路径+存量/新增标注）、页面-接口映射（含 API 封装列）、页组交互（状态矩阵五态+降级）、弹窗/抽屉映射表（页面+交互名锚定）、权限与数据范围前端契约（两级分层+按钮隐藏非安全控制）、异步与错误交互契约（errorCode→行为表/受理轮询退避/降级不写缓存）、路由状态与 API 封装约定、复用组件与技术栈、菜单 Seed（逐行清单指向事实源防漂移）。
- **§14 异常处理、安全与性能设计**（错误语义与事务边界/安全/性能三节，与 §3/§5/§7.6/§8.2 互引）。
- **§9.1 追溯矩阵升级 8 列 + 逐列落点**（页面 §7.1-{n} 页面名、数据 §2.3 表名）。
- **§0.3 同服务同框**画法约定；依赖明细表统一 §0.3。
- **写作铁律注释块**内嵌三套模板 H1 后（产物契约/写作规则/Gate 环境实操 12 条，随模板复制即读）。
- **总文档模板**：1.2/2.1 架构图与服务体系一一对应铁律；5.3 全局错误码语义+处理约定表；6.1 主业务流程先活动图后文字。
- **命名与组织规则**：详设按模块使命命名（一文一服务），PRD↔模块映射只在总文档登记；总详设 §2.2 唯一映射表、§0.3 三面分工、§5.3 错误码表、§6 活动图。

# Changelog — devflow v1 → v3.20.1 Migration Guide（历史）

## v3.20.1 (2026-09-13) — 夹具同步（zero_results 新集合声明）

- test-phase-gates 的 foo 夹具 design.json 补齐 resources/operations/integrations/configs 四个空集合声明——v3.20.0 的「零结果也是证据」对可选新集合生效后，夹具未同步导致 P2/P4 级联失败。


## v3.20.0 (2026-09-13) — 第二轮 panorama 借鉴：补偿链/集成/配置三大规格落地

### design.json 新增四个可选集合（零结果须声明，锚点入文档对账）

- **resources[] × operations[]（数据恢复矩阵的一般化）**：正向占用资源（锁/配额/占用标记/外部预占/缓存态）在每个反向操作（cancel/rollback/timeout/retry）的 resource_closure 中逐一表态（on_operation/on_next_submit/never/not_applicable）；「每表态必有证据/理由」；有资源无反向操作 = 补偿链缺失直接拦截。渲染器生成「资源×操作补偿矩阵」（未表态单元格显示 —未表态—）。
- **integrations[]（外部推送 6 步验证链的领域无关化）**：出向/入向集成的端点、超时、幂等、失败路径必填；降级/兜底建议声明（定时兜底与事件驱动须复用同一执行方法）。
- **configs[]（配置消费规格卡的一般化）**：值格式（分隔符逐 key 登记）、全仓消费点（active/dead_code/commented_out，死代码必须标依据）、失败路径、置信级（low/medium 须给原因）；全部消费点均为死代码的「死配置」拦截。

### 方法论接线

- **三层验证法**（phase2_method：路径→条件代入→落点）落为 phases/04b 验收证据深度口径：每验收点证据按三层组织，缺一层即证据不完整；P3b 复用同一口径。

### 明确不吸收（评估结论）

- Jinja2 模板化渲染（引入第三方依赖，违背零依赖原则）；trace_chain/find_*_closure/verify_external 等图谱与 SQL 工具（绑定 .codegraph/Oracle 领域数据）；基线+差异写法（需重构 design.json 作用域到多文档，收益/成本比不足，记录缓发）。

### 回归

- test-structured-artifacts 65 → 72 条：补偿链缺失/缺表态/never 无理由/集成缺端点/死配置+低置信/零集合未声明 6 项负向 + 补偿矩阵/集成配置块渲染断言。


## v3.19.0 (2026-09-13) — 独立审计 7 项修复：P6 因果序重构 + 冻结范围绑定

### P0（部署安全）

- **P0-1 CLIENT_EXEMPT 绕过冻结前端范围**：s6 此前只让 test-evidence.env 与 verification.json 互证（都可手写），实测 pc-web + CLIENT_EXEMPT=1 + JSON 声明 not-applicable 可直接 PASS。现在 Gate 读取 `.devflow/<feature>.state.json` 的 `.scope.frontend`（P0 init 冻结值）：CLIENT_EXEMPT 仅在冻结范围=not-applicable 时生效，否则 P0 拒绝——**冻结值不可被声明覆盖**。validator 同步新增 `--frontend-scope` 双向对账。
- **P0-2 无执行证据也能渲染「可以部署」**：df_pipeline 的 verification 模式把 --baseline/--exec-record 设为可选，5 个空文件实测仍渲染「结论：全部通过，可以部署」。根因是照搬 panorama 的 validate→render→gate 因果序——P6 的 Gate 才是执行权威。修正：①管线的 baseline/exec-record 改为**必填**（无执行记录即 exit 2）；②validator 新增报告实质内容检查（≥32 字节 + 首行占位词黑名单，口径同 s6）；③s6 Gate 在执行通过后**自行渲染正式终验报告**（§3.6，渲染失败拒绝产出收据）。正确因果序固化为：execute gate → validate evidence → render → bind receipt。
- **P0-3 结构化产物不入收据证据树**：s6 收据 EV_ARGS 补入 verification.json + 渲染报告（与 TSV/env 同生共死，audit 重验缺一即阻断）；verification.json 从「缺失仅告警」升级为**必填**（缺失即 P0）；P2 收据 ARTIFACTS 补绑 design.json + DESIGN_JSON_SHA256。

### P1

- **P1-4 锚点对账只覆盖接口详细定义**：新增 `check_doc_anchors`——pages/tables/apis/rules 声明的每个 § 锚点必须在文档中以标题真实存在（围栏感知、任意深度）；s2 Gate 追溯行 page/api/data 三列接受显式占位 `—`（纯后端 feature 的合法零结果，由 §2c 校验器把关），消除结构化正向用例与旧 Gate 的契约冲突。
- **P1-5 Java 手册与四方言铁律冲突**：手册「MySQL 数据库」章节（unsigned/IFNULL 等）与四方言契约不兼容——phases/03/03b、backend-dev、code-reviewer 统一修订适用范围：语言层条款全量强制；方言章节以四方言契约为准（冲突不判 FAIL，须记录方言适配说明）；check-code-standards.sh 诚实化口径（机检只覆盖可自动化子集，全量合规由 P3b 评审核对）。
- **P1-6 verification zero_results 无语义校验**：新增词汇表白名单（evidence.unit/integration/client/load/staging、acceptance_results）+ 重复拦截 + 「声明为空但对象存在」伪造拦截。

### 发布链

- 恢复源侧丢失的 `_archive/changelog-v1-v3.8.md` 与 `changelog-v3.9.0-v3.9.5.md`（CHANGELOG 两条断链，副本中尚存得以恢复）。
- 回归：test-structured-artifacts 57 → 65 条（无执行记录管线拒绝、空报告、伪造/重复零结果、冻结范围对账×2、文档锚点缺失、样例锚点全解析）；evidence-hardening 新增「CLIENT_EXEMPT 无法覆盖冻结 pc-web」钉，124 PASS。


## v3.18.3 (2026-09-12) — concepts 瘦身 + Java 开发手册强制接线

### concepts 目录审计（9 → 7 个活跃文件）

- **归档 `indexes.md`**：命令/Phase 索引与 `commands/ROUTING.md` 完全重复，且全树零引用——路由唯一入口回归 ROUTING.md。
- **归档 `design-review-process.md`**：539 行详设评审流程规范已被 phases/02a（评审 Gate + 检查表）+ `review-depth-methodology.md`（DF/AW 契约）+ `review-receipt.sh`（独立收据）取代，仅 CHANGELOG 历史提及。
- 保留：SKILL.md（铁律，111 处引用）、PRD实施方法论、architecture-pitfalls（Gate 在跑）、architecture-scorecard（concepts/SKILL.md §14 路由的评分表）、natural-language-triggers、principles-detailed、review-depth-methodology（9 处引用）、中文文风规范、Java开发手册。

### Java 开发手册强制接线（黄山版）

- `concepts/Java开发手册_黄山版.md` 成为 Java 代码生成与评审的**强制基准**：
  - phases/03：生成任何 Java 代码前必须对照手册相应章节，【强制】条款违反即 P3 Gate 不通过；
  - subagents/backend-dev：编码前置约束，提交物注明所依据章节；
  - subagents/code-reviewer + phases/03b：【强制】违反 = FAIL 并引用章节号，【推荐】违反须说明理由；
  - checks/check-code-standards.sh：规范基准声明；
  - concepts/SKILL.md 必读表登记。


## v3.18.2 (2026-09-12) — 第四轮确认审收尾（3 处轻微）

- verification.sample-output.md 审计指纹对齐当前 verification.sample.json 实算值（样例=可确定性复现的重渲结果）。
- 02a 第 11 项与 05-测试用例.md 各 1 处弯引号统一为直角引号「」（与文风规范体例一致）。
- 第四轮确认审结论：第三轮 24 项语言修复全部在位，design/verification 渲染文案终审通过，语言审查收敛。


## v3.18.1 (2026-09-12) — 语言审查 24 项闭环

- 渲染文案第二轮打磨（编辑视角独立审查发现）：终验报告头部数据来源人话化 + ISO 时间戳转可读格式（审计指纹移入 HTML 注释保留）；结论句按实际结果分支（修复失败报告会输出「全部通过」的假陈述缺陷）；「终验 Gate/P4/未对账/未通过校验」等内部术语全部转为读者口径；design 侧「全部完成设计→设计完成」「对象写 public→在该列标注 public」等语序与主语修正。
- 文风规范自身达标：弯引号统一为直角引号、内层引用用『』、「非平凡设计」等翻译腔自纠、断句补逗号、DDR 首次出现展开。
- 接线修正：phases/02 关键原则编号重排（说人话为第 2 条）、02a 中英文空格。


## v3.18.0 (2026-09-12) — 产出文档说人话：中文文风契约 + 渲染文案人话化

### 新契约

- 新增 `concepts/中文文风规范.md`——全部产出文档的中文写作契约：主谓宾完整一句话一个主张、主动语态、禁止空动词名词化（"对X进行了Y"）、结论自己站着（表格只做佐证）、数字给单位口径对照、同一事物全文一个名字、不把校验器/Gate/脚本名等实现细节写进读者正文、"为什么"比"是什么"重要、空与不适用显式说清。附评审核对三问（主语可辨？依据在哪？删了损失什么？）。
- 接线：phases/02 关键原则（说人话置顶）、phases/02a 评审表第 11 项（文风抽查，不合格按 DF 记录）、phases/09 语言总纲、concepts/SKILL.md 必读表。

### 渲染文案人话化（df_render.py）

- 详设 summary/覆盖率/权限/DDR/零结果/客户端范围脚注全部改写为完整中文句（例：「覆盖率：3/3 = 100%，全部验收点都完成了设计。」「全部 2 个字段都能追溯到决定它的设计决策。」「本需求没有客户端界面（不适用），原因：……」），不再出现"校验器双向闭环""冻结分母对账"等机器腔；客户端范围值译为「PC 网页端/微信小程序/手机 APP」。
- 终验报告新增「结论：全部通过，可以部署 / 存在 N 个未通过项，禁止部署」一句话结论；统计行、证据表表头（测试类别/实测退出码/报告指纹）、客户端说明、空项说明全部改为读者视角表述。
- 回归：test-structured-artifacts.sh 56 → 57 条（新增结论句断言，覆盖率/统计断言随新文案更新）。


## v3.17.4 (2026-09-12) — 第三轮终审收敛 + N-1 发布门健壮性

- 第三轮独立复审结论：v3.17.3 的 8+1 项修复全部在位且经实证，修复间无冲突，未发现新的放行/误杀路径——审计收敛。
- **N-1 发布门健壮性**：`gate-skill-tree.sh` / `gen-skill-manifest.sh` / `sync-copies.sh`（portable 清单、--check extra 扫描、rsync excludes 四处）统一排除 `__pycache__/` 与 `*.pyc`——此前任何一次 `import df_*.py`（工具集成/单测）都会产生字节码缓存，令 manifest check 与副本对账永久 FAIL（会话内实测踩坑两次：主 agent py_compile 与审计员单元测试各一次）。排除方向为误报方向（safe direction）。
- N-2/N-3（手写执行记录缺 CLIENT 键、四级锚点的三级小节反向检测）为规格保守方向的低危备忘，真实流程不可达/正向闭环兜底，记录在案不做代码改动。

## v3.17.3 (2026-09-12) — 第二轮独立复审闭环（B-1~B-8）

- **B-1【中】CLIENT_EXEMPT 对账补双向**：记录无 CLIENT_EXEMPT 且实际执行了 CLIENT，而 JSON 声明免客户端 → 拦截（原只有豁免→声明单向）；取值归一 .lower()（B-3，s6 接受 TRUE/YES 而 validator 曾只认小写）。
- **B-2【中】两级 detail_anchor 反向误报**：`§3.2` 两级锚点（schema 合法）无法区分 §3 下兄弟章节与多余详定义小节 → 反向检查仅在全部锚点 ≥3 段时启用。
- **B-4** s6 豁免路径 PASS 横幅按 CLIENT_EXEMPT 分支文案（不再宣称 client 证据齐备）。
- **B-5** 标题正则尾随点编号（`#### 3.2.1. 字段`）漏捕获 → lookahead 改 `(?!\.?[0-9])`。
- **B-6** schema 不合法（未知类型等）输出结构化错误 exit 2（不再裸 traceback）。
- **B-7** pipeline 空 `--gate` 判定改用解析结果（`args.gate is not None`），消除 sys.argv 字符串匹配的理论误触发。
- **B-8** 空集合豁免升级为「集合级豁免 + 值级约束」：已声明为空的集合，验收行残留旧锚点（非 — 占位）即拦截。
- **A10** 两份 schema description 补注：zero_results 双向闭环语义、cmd↔KIND_CMD 逐字对账、CLIENT_EXEMPT 两层一致性。
- 修复 v3.17.2 引入的一处静态扫描违规（s2 未花括号 `$DESIGN）`）。

## v3.17.2 (2026-09-12) — 双子代理独立审计修复：12 项缺陷闭环

### 高危（反自报口径补洞）

- **H1 占位命令绕过**：`df_validate.py` 黑名单缺 `true /false /pwd /ls /: ` 前缀变体（实测 `true && echo pwned`、`: > report` 放行）→ 首令牌黑名单 + 全命令 shell 转包扫描，口径与 s6 `_is_shell_wrapper` 逐字对齐；**命令单源对账**：`evidence.cmd` 必须与 Gate 执行记录 `${KIND}_CMD` 逐字一致（曾只对账退出码，伪造命令可渲染进正式终验报告）。
- **M4 无前端 feature 在 P6 结构性不可通过**：s6 无条件要求 CLIENT 证据，与 JSON 层 `client_not_applicable.declared=true` 免客户端路径矛盾 → `test-evidence.env` 新增 `CLIENT_EXEMPT=1`；标记时跳过 CLIENT 执行与日志（4/4 记录校验），EXEC_RECORD 落 `CLIENT_EXEMPT` 行，validator 双向核对（声明不一致即拦截）；未声明标记时行为与旧版完全一致。

### 中危（闭环破洞）

- **M1 伪造零结果声明**：`valid_targets` 无条件白名单使非空集合的 `zero_results` 声明逃过检测 → 白名单收窄为「已实际为空的集合 ∪ not-applicable 时的 client.journeys」；顶层空 tables/apis 纳入登记体系。
- **M2 纯后端 feature 不可表达**：acceptance 必填 page/api/data 引用 × pages/tables/apis 合法为空 ⇒ 必然断链 → 已在 zero_results 声明为空的集合豁免引用校验（零结果也是证据的合法形态）。
- **M3 标题正则三重误报**：编号后必须空白（中文无空格标题误报）、仅识别 ≥3 级编号（schema 允许 §3.2 两级）、不追踪代码围栏（伪标题误报/伪装）→ 边界断言宽容化 + 深度对齐 + 围栏状态跟踪。

### 低危 + 文档契约

- L1 pattern 改 `re.fullmatch`（`"R1\n"` 曾通过 `^R[0-9]+$`）；L2 bool-false schema 与未知类型名拒绝（不再静默跳过）；L3 report_path 空串/目录显式报错 + SHA 计算异常转校验错误；L4 锚点块 begin/end 不成对显式报错；L5 pipeline 空 `--gate` 报用法错误（曾静默 exit 0）；L6 s2 criteria 缺省推导坍缩（==design）即拒绝（冻结分母自证）；L7 zero_results 重复 path 拦截；L8 渲染表格单元格清理 `\r`。
- 总分分文档模板 §5.2 接口概览表头「方法」从第三列改回第一列（`p4_prd_vs_code.sh` 解析契约：首列非 HTTP 方法 → P4b §2 API 对比静默失效），并补概览↔详细定义一一对应约定。
- 回归：test-structured-artifacts.sh 44 → 56 条（占位变体×4、cmd 对账、CLIENT_EXEMPT×2、伪造/重复零结果、纯后端、M3 标题、空 --gate）。


## v3.17.1 (2026-09-12) — 详设输出物闭环：接口概览↔详细定义、DDR↔字段一一对应

### 修复的实测缺漏（详设输出物质量）

- **接口概览 ↔ 详细接口定义 一一对应**：`design.json` 的 `apis[]` 新增必填 `name` + `detail_anchor`（§3.2.N）；`df_validate.py --kind design --doc` 对文档**双向对账**——概览列了 N 个接口而详细定义只写了 M<N 个即 P0（实测缺漏形态），文档中存在概览未收录的详细定义小节同样拦截；标题兼容 `#### 3.2.1 x` 与 `#### §3.2.1 x` 两种写法。渲染器 `api-index` 增加「接口名称 + 详细定义」列。
- **DDR ↔ 表设计字段 一一对应**：新增顶层 `decisions[]`（DDR-N：决策点/备选方案/选定/理由），每个表字段必填 `ddr: [DDR-N]` 引用；双向闭环——字段引用的 DDR 不存在（悬空）拦截、DDR 未被任何字段引用且无 `unreferenced_reason`（孤儿决策）拦截；渲染器新增 `ddr-index`（DDR 表）+ `ddr-matrix`（字段×决策矩阵）两个确定性块（锚点块 8→10）。模板 §2.3 DDR 表增加「关联字段」列、§3.1 增加一一对应约定。

### Gate 升级（可选 → 必填）

- `s2_design_coverage_gate.sh` §2c：`design.json` 从「缺失仅告警」升级为**必填**（P0 阻断）——手写模式无跨字段保证，实测正是详设缺漏的根源；monolith 模式附 `--doc` 文档对账，总分模式（1 JSON : N 文档）仅做 JSON 内部闭环。


## v3.17.0 (2026-09-12) — 结构化业务产物层（design.json / verification.json）

### 新机制（借鉴 flow-node-panorama 的「结构化数据编译成文档」，按 devflow 身份裁剪）

- **结构化中间产物**：P2 `design.json`、P6 `verification.json` 先写机器可读 JSON，再由脚本渲染 Markdown。核心数据（验收追溯、API/数据模型/权限矩阵、五类测试证据绑定）不再靠手写表格。
- **确定性层与语义层分离**：AI 只填业务判断与锚点；计数、覆盖率、矩阵、零结果话术、证据绑定表由 `df_render.py` 派生，AI 不手填。
- **Schema + 跨字段校验**：`schemas/design.schema.json`、`schemas/verification.schema.json` + `df_validate.py`（零依赖 JSON Schema 子集 + 跨字段检查）：验收 ID 与 criteria/baseline 集合全等、锚点引用闭环、孤儿条目拦截（须 `unreferenced_reason` 显式表态）、客户端/迁移声明自洽（not-applicable 与四方言偏离必须说明）、零结果双向闭环（空集合必须声明、声明必须指向真实空集合）、报告 SHA-256 实算比对、声明退出码 vs Gate 实际执行退出码对账、占位话术全文递归拦截。
- **单一失败关闭入口**：`df_pipeline.py`（validate → render → gate），校验失败不渲染不进 Gate。P2：`s2_design_coverage_gate.sh` §2c 对 design.json 存在即强制校验；P6：`s6_final_verification_gate.sh` §3.5 对 verification.json 存在即强制对账（终验报告必须由已校验 JSON 渲染）。Gate 仍是执行权威与收据来源。
- **定位器不是证据**：锚点是证据位，必须指向当前产物真实章节；codegraph/历史文档只负责定位。
- **零结果也是证据**：查询/集合为空必须显式声明，静默省略即校验拦截（推广到 API 字段、页面、客户端旅程、Flyway 方言）。

### 版本门禁修复（展示层漂移）

- `check-skill-version.sh` 标题漂移扫描从 commands/ 扩到 SKILL.md 本体 + phases/ + subagents/——修复实测漂移：主入口标题 v3.16.25 落后元数据 3.16.26、`prd-review-committee.md` 标题停在 v3.14.0，旧扫描均未捕获。

### 明确不引入（评估结论）

- 不引入 flow-node-panorama 的领域硬编码（Oracle/WFA_*/固定目录）、"出现率≥70% 基线"、"校验通过率≥85%/人工抽检 2~3 节点"等弱放行标准；devflow 保持全量 Gate。运行数据仍一律在项目 `.devflow/`，不入 skill 目录。


## v3.16.26 (2026-09-12) — 技术硬约束贯穿 P0→P4b、机器契约与脚本瘦身

### 正确性修复（破坏性：机器契约取代自然语言判定）

- 技术约束改为机器契约块（`constraint_id/type/required_product/status/confirmed` key=value），Gate 只信机器字段，不再从自然语言推断合规。修复三个可复现缺陷：
  - "用户确认: 未确认"曾被正则误判为已确认（LC_ALL=C 下 `[^[:alnum:]]` 吞多字节汉字）；
  - DRAFT 状态的 MUST_USE 行曾被跳过而非阻断；
  - 合规选项写成"未引入 FlowCore"曾被 Gate 误拒（现在 selected_product 只写实际选定产品）。
- 技术硬约束贯穿全流程：P0 Gate 校验约束存在且 FROZEN；`devflow-state.sh constraints-freeze` 冻结文件 SHA；P1 校验 SHA 未被改写 + 机读绑定合规（含版本）；P2 详设必须逐条引用 constraint_id；P3 核对 Maven 依赖/config 符合选型；P4b 做"选型↔代码依赖"对账。
- 新增 `scripts/tech_constraints_lib.sh` 共享解析/校验库；新增 `scripts/review-receipt.sh` 独立评审收据（编排器 create、Gate verify，含 input/output SHA 与时间窗，评审者≠作者硬校验）。
- P2 Gate 追溯矩阵逐列验证（非空 + 锚点格式 + TC-/COMPLETE），空映射行不再能混过；模板身份精确匹配（模板 ID + 版本 + 模式 monolith/total/sub 对应 Gate）；需求追溯统一语义锚点 `acceptance-traceability`（章节号仅展示）。
- P2a 移除旧"DF≥10/每角色≥3"配额残留，统一为"按实际发现 + ZERO-DF 核查证据"。

### 模板瘦身（30 → 27）

- 删除 `详细设计-目录版-模板.md`、`详细设计-摘要版-模板.md`（移入 _archive）；`devflow-client.md` 移入 _archive（真正被消费的是 devflow-client.json）。
- `详细设计-模板.md` 缩为 ~40 行模板路由器；`技术选型报告-模板.md` 重写（先硬约束淘汰再评分，不预填分数/✓）；`复盘报告-模板.md` 330→~90 行；修复总分分文档重复的 `### 0.4`。

### 脚本瘦身（scripts/ 65 → 54）

- 删除 `quick_validate.sh`（仅测试要求存在）；`p3_detail_diff.sh` 并入 `p3_completion_gate.sh`；`field-change-gate.sh` 标记 deprecated（下一主版本删除）。
- 静态检查器外迁：`run-all-checks.sh` + 6 个 check-* / detect-* 移入 `checks/`；Skill 维护工具移入 `maintenance/`（`s8b_feedback_gate.sh`、`s8_graph_health_gate.sh`）。
- `build-watchdog.sh` 仅保留 gate 模式（check/watch/detect 移除）。

### 提示词修复

- `phases/01-技术选型.md` 移除团队人数/并发量直接决定架构的决策树与 ✓ 预填标记，改为"读仓库→硬约束淘汰→补事实→仅对剩余方案评分"。
- 删除 14 处 `echo "自检通过 → PASS"` 假 Acceptance Test，替换为真实 Gate/测试脚本与期望退出码。
- 清理通用提示词中的 XYLS/M-03 项目残留（迁至 examples/xyls/）；`phases/05-测试用例.md` 假密码改为 `env: TEST_USER_PASSWORD`。
- 新增 `references/agent-runtime-adapter.md`：spawn_fresh/wait_all/record_receipt 语义，核心提示词不再写死平台调用语法。
- 活跃命令/phase 移除历史叙事（v1.7 教训/借鉴 xx 等）；release.sh 版本改为动态读取；版本 Gate 增加脚本 banner 版本漂移扫描。

## v3.16.25 (2026-09-12) — 技术约束、独立评审与详设契约收口

- P0 冻结 `MUST_USE/MUST_NOT_USE` 技术约束，P1 选型报告逐条绑定并校验用户确认与合规证据。
- P2a 统一五角色、独立 reviewer/session 收据、探针证据和 finding 关闭状态，取消固定 DF 凑数。
- P2 详设改为单一模板身份与精确验收点集合校验；补齐 sql/backend/frontend 开发角色注册。
- 通用代码审查移除 M-03 专项硬编码，改由项目领域清单注入。

## v3.16.24 (2026-09-07) — 四方言示例注释收敛

- `phases/03-规范实现.md`："多数据库兼容"示例注释 `-- MySQL/PostgreSQL/H2` 改为四方言口径 H2/PostgreSQL/Oracle/Kingbase（R4 终审发现的最后 1 处 MySQL 契约矛盾残留）。

## v3.16.23 (2026-09-07) — 四方言契约示例修正

- `phases/03-规范实现.md`：目录树示例删除 `mysql/` 目录、验收 Checklist 删除 MySQL（列 5 个 vendor 却计 4，且 MySQL 不在 h2/postgresql/oracle/kingbase 权威四方言契约内，照做会产出 gate 不认可的第五方言目录）。

## v3.16.22 (2026-09-07) — 符号链接安装修复与文档一致性

- 修复符号链接安装（如 `.agents/skills/devflow → .codex/skills/devflow`）下 macOS BSD `find` 不跟随起始符号链接，导致 `gate-skill-tree.sh` / `gen-skill-manifest.sh` / `release-audit.sh` / `release.sh` / 测试枚举出空树、state 测试失败且完整测试套件与发布链路中断的问题：相关脚本 ROOT 一律解析物理路径（`pwd -P`）。
- 清理 9 个命令文档（build/plan/review/security/performance/deploy/monitor/docs/retro）中历史遗留的残缺引用块（`> （清单 #N）。`）及 `build.md` 两处残句。
- 修正 `references/severity-tiers.md` 对不存在的 `subagents/sql-dev.md` 的失效引用，改指 `commands/build.md` §2 与 `concepts/SKILL.md` §3（开发角色无独立 subagent 文件）。
- 修正 `commands/ROUTING.md` 命令路由表中错位的 P6-final 三列残行；P6-final 终验信息并入 `/test` 行与阶段表 P6 行。
- 补注册 `P3-build`、`P5-migration` 两个真实产收据 gate 进 `references/phase-registry.json`，并在各权威文档补齐阶段名；注册表 description 明确"无独立收据的辅助检查器不注册"的口径。
- `concepts/SKILL.md` §1 铁律阶段链补全 P0b/P2a/P2b/P3c/P3d/P4b，与单轨顺序一致；`subagents/code-reviewer.md`、`subagents/test-engineer.md`、`commands/devflow-state.md`、`commands/audit-completeness.md` 残缺引用块标签补全或清理。
- 防御性统一：`tests/test-release.sh`、`scripts/hooks/after-prd-review-hook.sh`、`scripts/check-skill-usage.sh` 的 ROOT/SKILL_ROOT 解析物理路径（`pwd -P`）。
- 新增回归钉：symlink 安装下 `gate-skill-tree.sh` 可枚举（test-maintainability）；活跃文档禁残缺引用块（test-maintainability）。
- P3 执行级文档与权威链对齐：`commands/build.md` 与 `phases/03-规范实现.md` 补 `build-watchdog.sh gate` P3-build 收据步骤，"唯一判定"措辞改为"先 P3-build 收据、再 `p3_completion_gate.sh` 最终判定"。
- 删除 `scripts/.template-improvements/` 运行期残留（旧布局测试产物，误入发布树与树哈希）。
- scripts/hooks/tests 全量统一 ROOT/SKILL_ROOT 物理路径（`pwd -P`），消除符号链接安装下的复制漂移隐患。
- manifest 记录口径：v3.16.21 因当时发布链被 symlink find 缺陷中断而无 manifest 留痕；自 v3.16.22 起由 `release.sh` 正常生成并保持不可变。

## v3.16.21 (2026-09-03) — 通用小需求 / 小改动通道

- FIELD-CHANGE 泛化为 SMALL-CHANGE：支持既有项目的局部 UI、配置、bugfix、兼容 API 增量、默认值/校验和可追加持久化改动。
- `/small-change` 是主入口，`/field-change` 和 field-change-gate 保留为兼容别名。
- 合同由 `CHANGE_SUBJECT`、`LOGICAL_CHANGE_COUNT` 和十个项目影响面驱动；权限、流程、跨服务、历史数据、多项逻辑改动及全部高风险标志自动升级 FULL。
- 新增 `tests/test-small-change.sh`，覆盖 UI、配置、bugfix、API、持久化、P7/P8、兼容别名和篡改阻断。

## v3.16.20 (2026-09-03) — 字段微变更发布语义收紧

- `TARGET=released` 必须同时绑定通过证据重验的 P7 部署收据与 P8 监控收据；只有部署没有监控时保持失败。
- FIELD-CHANGE 收据绑定项目扫描、合同、报告、受影响代码、聚焦日志、迁移日志及发布/监控收据。
- 字段微变更专项回归扩展为 27 项。

## v3.16.19 (2026-09-02) — 自然语言字段小变更通道

### 新增
- `/field-change` 与 `--mode=field-change`：自然语言触发后扫描当前项目十个影响表面，自动计算 MICRO/FULL。
- `field-change-gate.sh classify/verify`、字段小变更模板和分类矩阵；默认完成态为 `MERGE_READY`，部署收据有效时才是 `RELEASED`。

### 安全与证据
- 多逻辑字段、破坏性 API、类型/非空、权限、流程、跨服务、新表/服务和大回填自动升级完整 change。
- 项目扫描、合同、报告、受影响代码、聚焦测试和四方言迁移文件全部进入证据树；验证命令不得修改被冻结输入或代码。
- 路径越界、重复合同键、占位命令、FULL 合同误走 verify、缺方言文件和失败状态均有负向回归。

### 回归
- `tests/test-field-change.sh`：25 项自然语言路由、项目判定、升级、验证、路径和收据测试。
- 版本型测试文件稳定重命名为 `tests/test-release-hardening.sh`，避免后续升版产生名称漂移。

## v3.16.18 (2026-09-02) — P6 输入/执行证据最终收口

### P1 修复
- P6 现在隔离写入执行记录与日志，执行结束后强制固化五条实际退出记录和五份日志，测试命令无法抹除前序证据。
- P6 拒绝报告路径别名内部 manifest、快照、执行记录或日志。

### P2 增强
- P6 记录实际可执行文件路径及 SHA-256，明确命令语义仍需项目级受控 runner/allow-list 承担。

## v3.16.17 (2026-09-02) — allowed-tools 语义校验收口

### P1 修复
- Release Audit 现在拒绝 `allowed-tools: null`、错误缩进和非字符串列表项，避免 YAML 可解析但运行权限静默丢失。
- 相关 subagent 的权限声明统一为真实的 read/write/exec/grep/glob/task 能力集合。
- P6 在执行前冻结 `test-evidence.env` 并校验执行期间/结束后的输入哈希，阻断前一类命令篡改后续四类声明。
- P6 同时冻结 `final-verification.tsv`、`first-pass-baseline.tsv`、`first-pass-meta.env`，并在双哈希工具缺失时 fail-closed。
- P3b 对 finding 的大小写、ID 格式和重复 ID 做严格校验。

### P2 边界
- 角色 ID 仍需由宿主会话收据提供权威来源；报告内字段只表示声明，不单独证明跨会话身份。

### 回归
- 新增 `tests/test-release-hardening.sh` 与 malformed frontmatter fixture，验证权限字段语义失败时 Release Audit 必须非零退出。

## v3.16.16 (2026-09-02) — P3b/P6 证据契约与工具权限收口

### P0 修复
- P3b 只解析结构化 `FINDING|severity|id|STATUS=OPEN|CLOSED|summary` 行；模板章节、统计和结论不再被误计为 P0。
- P6 拒绝执行前已存在且内容未变化的报告，`REPORT_SHA256` 改为可选的结果断言，避免预制/陈旧报告假绿。

### P1 修复
- 主入口、`/review` 和 review coordinator 的 `allowed-tools` 覆盖实际的 exec/write/task 职责；三个并行 reviewer 可写出报告。
- 官方模板和 review 命令补齐身份字段、结构化 finding 契约。

### 回归
- `tests/test-release-hardening.sh`：官方模板误计数、P6 陈旧报告、工具权限三类负向/契约测试。

## v3.16.15 (2026-09-01) — P3b 语义、阶段注册表与路径解析收口

### P0 修复
- P3b P0 finding 改为逐条结构化 `STATUS=CLOSED|OPEN`，拒绝 `unresolved`、
  `not fixed` 及无关全文 `resolved` 计数凑过。
- P6-final shell wrapper 检测增加整条命令 token 扫描，覆盖带引号空格的环境变量
  前缀（如 `X='a b' bash -c ...`）。

### P1 修复
- phase registry 的 P0/P2/P2a/P3 script 映射改为真实存在的 Gate，并由回归测试校验
  每个注册脚本路径存在。
- release 外部 state 使用逐行临时清单解析，保留空格路径和 Windows 盘符。

### 回归
- T32a：quoted environment assignment wrapper 拒绝。
- T32b：unresolved P0 拒绝。
- T32c：registry 脚本存在性和实际 Gate 映射校验。

## v3.16.14 (2026-09-01) — shell wrapper 前缀绕过收口

### P0 修复
- P6-final 的 shell-wrapper 检测跳过前导 `VAR=value` 赋值后再识别首个实际 token；
  `X=1 bash/sh/env/command/exec ...` 不再绕过真实测试命令门禁。

### 回归
- T31：前置环境变量赋值包装命令必须被拒绝；hardening 全套保持通过。

## v3.16.13 (2026-09-01) — P6 真实命令边界与 P3b 语义收口

### P0 修复
- P6-final 拒绝 `bash/sh/env/command/exec` 包装命令，避免以 shell 自造测试报告；
  终验报告路径在 Gate 内先做 workspace 物理边界校验。
- P3b 验收点覆盖改为 criteria/report ID 集合全等；P0 仅按同一 finding 行的关闭状态
  判定，禁止用全文无关 `resolved/closed` 计数抵扣未闭环问题。

### 回归
- T30a：shell 包装命令被拒；T30b：workspace 外报告路径在 Gate 层被拒；
  T30c：ID 集合错位及 P0 全局计数凑过被拒。

## v3.16.12 (2026-09-01) — P6-final 实际执行与日志证据闭环

### P0 修复
- **P6-final 不再仅信任手写 `*_EXIT=0`**：Gate 现在在 workspace 根实际执行
  UNIT/INTEGRATION/CLIENT/LOAD/STAGING 五类 `*_CMD`，实际 exit 与声明不一致或
  非 0 均阻断；stdout/stderr 写入 `.devflow/<feature>/test-executions/`，实际结果
  写入 `test-execution-results.env`。
- **执行证据与收据同生共死**：五类执行日志和总执行记录加入
  `EVIDENCE_PATHS_JSON`/证据树；删除日志后 `audit-receipts` 与 state 重验均拒绝。

### P1 修复
- **新版本 manifest 的发布循环依赖消除**：完整回归不再要求“当前新版本 manifest
  已存在”；`release.sh` 仅在完整测试和前置门禁通过后首次生成 immutable manifest，
  已存在的 manifest 仍只读校验，漂移必须升版而不得重写。
- **R6 端口夹具去随机化**：测试改由内核分配端口并等待就绪；macOS Framework Python
  按真实 `ps` 命令名 `Python` 做 owner 断言，避免 `$RANDOM + sleep` 误红。

### 回归
- T29a：声明 `UNIT_EXIT=0`、实际 `UNIT_CMD` exit 7 必须拒绝。
- T29b：实际退出码记录和日志必须进入 P6-final 收据树；删除日志必须使 audit 失败。
- 新版本无 manifest 的全量测试可通过；首次 `release.sh` 生成后同一版本 manifest 只读校验。

## v3.16.11 (2026-08-31) — 用户压力夹具第三十二轮：终验冻结集合对账 / 反自报三层 / 完整 realpath / service 白名单 / 文档注册表

### P0 修复
- **P0-1 P6-final 未核对冻结验收点全集**：s6_final 只查"现有行全 PASS"，
  无 baseline 时 100 个冻结点只交 1 个 PASS 也过（用户 PoC：ONLY-ONE PASS
  无 baseline → GATE PASS/EXIT=0）。修复：§0.5 冻结对账——final ID 集合
  与 first-pass-baseline.tsv 全等（缺失/额外/重复 ID 三向差集 + M-XX-FXX-AXX
  格式校验）；baseline+meta（criteria/design 哈希）入收据证据树。
- **P0-2 五类测试证据可自报**：CMD=true/EXIT=0/同一份"ok"文件五类全过、
  删报告后 audit 仍 PASS（报告不在收据绑定）。修复三层：占位命令黑名单
  （true/:/echo/printf/exit/pwd/ls/touch/cat/tee）+ 报告互异（五类不共用
  同一文件）+ 实质内容（≥32 字节且首行非纯占位词）；五报告 + baseline +
  meta 全部入 EVIDENCE_PATHS_JSON（删报告 → audit/complete 重验即阻断）。
  JSON 逐项 jq 构造须非空（假 jq 空数组 "[]" 逃过非空守卫，T21 钉实证
  rc=1→2 修复）。

### P1 修复
- **P1-3 证据路径最终层 symlink 逃逸**：cd -P 只解析父目录——
  workspace/evidence-link → /tmp/外部/external.txt 词法界内物理在外
  （VERIFY_EXIT=0）。修复：python3 os.path.realpath 完整解析（无
  python3/readlink -f 时 symlink 文件 fail-closed 拒绝）。
- **P1-4 P3b service 参数路径穿越**：传 ../clean 扫描 backend/../clean
  → 真实服务 TODO 被绕过（P3B_EXIT=0/REAL_TODO=1）。修复：SERVICE 白名单
  = backend 真实服务目录名集合（含 /、..、隐藏目录拒绝）+ TODO 扫描范围
  恒为 backend 全部真实服务（调用方无法缩小范围）；criteria 入 P3b 证据树。
- **P1-5 权威文档链遗漏 P6-final**：仅 devflow.md 列出——SKILL.md/
  ROUTING.md/test.md 均缺（按 /test 执行的 Agent 不会生成 P6-final，最后
  被状态机意外阻断）。修复：三文档补齐 + 新增 references/phase-registry.json
  机器可读阶段注册表（20 gate）+ T28h 注册表一致性钉。

### P2 修复
- **架构陷阱口径收敛**：concepts/SKILL.md"任意 Phase 切换前必跑"→
  P3b 门禁（check-arch-pitfalls 以 --receipt 内嵌 p3b §6 产出收据，
  状态机消费——真实执行路径承载承诺）。
- **sync-copies _archive 排除**：rsync sync_args 漏 --exclude='_archive/'
  → apply 后目标出现 5 个 archive 文件。修复补齐。
- **展示层版本漂移**：ROUTING.md 标题 v3.15.1、release.sh 头注释 v3.15.1
  ——frontmatter Gate 只查 YAML 发现不了。修复：check-skill-version 新增
  命令文档标题扫描（全角括号紧贴版本同样命中）。
- 角色隔离文本自证（ID 同源报告）：架构级改造记为已知限制，本轮不做。

### 行为钉 +11（T28a-h）
正向基线（完整合法场景 gate PASS）/ ONLY-ONE 无 baseline 拒 / 缺失-额外-
重复 ID 三变体拒 / 五类自报（true+共用 ok）拒 / 删五报告 audit 阻断 /
最终层 symlink 拒 / service 穿越拒 + 全服务 TODO 检出 / 注册表文档一致。
变异自证 M22-M26 → 110/4、113/1、77/37、113/1、113/1 全红。

### 修复期间自踩坑（第 6 次）→ 扫描器升级
s6_final 新诊断行 `$rp——` 与 `${_R_BYTES:-0}` 同行——静态扫描器的
**行级 ${ 豁免**掩盖了同行其他未花括号变量（运行时 unbound 崩溃才暴露）。
扫描器升级：先删 `${...}` 再查（豁免只作用于变量本身）；tests 内两处
扫描同步升级。

## v3.16.10 (2026-08-30) — 第三十一轮审查：降级检测 state 门控（收敛收尾）

### P3 修复
- **N31-P3-1 辅助收据降级检测无 state 门控——失败轮误报"值降级篡改"**：
  v3.16.9 的"存在即须成功"与主收据检查的门控口径（state completed）自相
  矛盾——P3b/P6 迭代期间失败轮辅助收据（gate 合法产物）被误报（同文件
  rc=3 失败轮 WARN 与值降级 FAIL 双判定矛盾，"狼来了"同型；fail-closed
  方向无安全洞）。修复：ARCH-PITFALLS 门控 _ST_P3B_DONE、
  P6-credential/P6-final 门控 _ST_P6_DONE；主阶段未 completed → WARN。

### 行为钉 +1（T27）
P3b 未 completed + ARCH 失败轮收据 → audit rc=0 且 WARN（不误报值降级）。
T26c（completed 门控下的降级检测）继续守护正方向。

### 收敛
第三十一轮审查判定：0 新 P0/P1/P2。本轮为唯一 P3 收尾——**循环收敛**。
自第 25 轮起 7 轮审查（25-31）共修复 5 P0 级用户复审 + 8 P1 + 14 P2 +
15 P3；测试从 425 → 全套 8 组 0 FAIL（EVIDENCE_HARDENING 103）；连续
两轮零放行类缺陷。

## v3.16.9 (2026-08-30) — 第三十轮审查：链 VERSION 钉 / 失败轮 WARN / 辅助降级检测 / 映射下沉单一事实源

### P2 修复
- **N30-P2-1 P7+ 链收据版本自报绕过**：链循环此前不校验链收据 VERSION ==
  当前版本，而契约阈值判定恰以自报 VERSION 为输入——「剥离绑定行 + VERSION
  降级到阈值以下 + 删证据」双行攻击可绕过 v3.16.8 收口（PoC 双实证：P3b
  降 g@3.15.9 / P4 降 g@3.9.0 均 BYPASSED，complete P7-P10 四入口暴露）。
  修复：链循环对每张链收据补 VERSION == devflow_version() 钉（对齐
  _reconcile_receipt_ok 前置与 audit check_versions 口径）。

### P3 修复
- **N30-P3-1 audit 剥离检测误报合法失败轮**：rc=3（无绑定）分支不看
  _rc_exit——p4/p5 gate 失败轮真实产物（EVIDENCE_PATH 空行）被误报"被
  剥离"（与 rc=1 分支自己声明的失败轮语义矛盾；经 artifact_gate 内嵌
  audit 可阻塞合法迭代态 + "狼来了"效应）。修复：同前置 _rc_exit=0 才
  做剥离判定，失败轮 → WARN。
- **N30-P3-2 辅助收据存在性不查终态**：存在但被双份一致降级为
  EXIT_CODE=1（值降级类）时 audit 全绿。修复：存在性检查同时校验
  EXIT_CODE=0（与主阶段 completed 同理）。
- **N30-P3-3 映射表"单一事实源"实为两处**：audit 内联复制映射+awk 版本
  比较。修复：receipt_stage_contract/_stage_ver_ge 下沉 devflow_receipt.sh
  （complete 与 audit 共同 source——两处内联漂移归零）。
- **N30-P3-4 证据重验循环 stage_name 未归一化**：P3c/P3d 目录收据不进
  剥离检测 case。修复：过 normalize_stage。

### 行为钉 +3（T26a-c）
剥离+版本降级双行攻击被链钉拦截（基线+对照）/ 失败轮无绑定 WARN 放行
不误报 / 辅助收据双份一致降级 FAIL。变异自证 M18/M19/M20（链版本钉/
失败轮前置/降级检测删除）→ 101/1×3 全红。

### 修复期间自踩坑（第五次规则自证）
新写 T26b 断言 `rc=$_FR9_RC）` 未花括号+多字节——静态扫描器第五次当场
拦截同型新写代码；该规则已连续五轮自证有效（生成式代码必须过扫描）。

## v3.16.8 (2026-08-30) — 第二十九轮审查：映射表统一三处白名单 / audit 旧契约剥离收口 / 辅助收据存在性

### P2 修复
- **N29-P2-1 P4b 证据绑定三重洼地**：p4_prd_vs_code 自 v3.15.5 起给 P4b 收据
  写 EVIDENCE_PATH/SHA，但三处校验点（complete 主收据白名单/reconcile
  case/P7+ 链复查 case）全部漏掉 P4b——删 prd-vs-code-warnings.md 后
  complete P4b 照常推进。
- **N29-P2-2 P0b 证据绑定三重洼地**：artifact_gate 给 P0b 收据绑定
  prd-review.md，同样三处全漏——删 PRD 评审报告后 complete P0b/P7+ 链、
  reconcile 全部放行，仅 audit 事后可拦。
- **N29-P2-3 旧契约收据剥离绑定行绕过链复查（rc=3 口径分裂）**：complete
  P7+ 链复查对 verify_receipt_evidence 的 rc=3（无绑定）放行——剥离
  EVIDENCE 两行使收据降级 legacy，绕过刚修的删证据防线（叠加 N29-P3-1
  后 audit 也失明，旧契约阶段该防线仅剩 reconcile 一条）。

### 根治：stage→证据契约映射表（单一事实源）
三处校验点（complete 主收据 / reconcile _reconcile_receipt_ok / P7+ 链
复查）此前各自维护白名单（3 个 P2 中 2 个直接源于三处各自漏项）。本轮
合并为 receipt_stage_contract 映射 + verify_stage_evidence_contract 统一
函数：new（P3b/P6-final/ARCH-PITFALLS ≥3.16.0）/ old（P0b/P3cd/P4/P5/
P7-P10 ≥3.13.4）/ old4b（P4b ≥3.15.5）；低于阈值收据为合法 legacy 渐进
放行，阈值以上缺绑定 = 被剥离必拒（P3b 软硬口径分裂一并收口）。

### P3 修复
- **N29-P3-1 audit 旧契约 stage 剥离仅 WARN（fail-open）**：stage+版本
  判定扩展到旧契约 stage（对齐映射表阈值）——阈值以上缺 EVIDENCE_PATH
  绑定行 → FAIL。
- **N29-P3-2 audit 对辅助收据双份删除零感知**：state-scope 补辅助收据
  存在性（P3b=completed ⇒ ARCH-PITFALLS 在；P6=completed ⇒
  P6-credential+P6-final 在）——内部+镜像同删后三轮检查全部无感的
  失明面收口。
- **N29-P3-3 REPORT_PATH 边界零钉**：补 T24a 变体 C（REPORT_PATH 越界
  → complete P4 拒）。

### 行为钉 +7（T24a-C + T25a-e + T23f 基线）
删 P4b/P0b 证据 → complete 拒（基线+对照）/ 剥离 P4 绑定行 → complete P7
拒 / audit 旧契约剥离 FAIL / 辅助收据双删 FAIL / REPORT_PATH 越界拒 /
T23f 补正向基线（N29-P4-1）。变异自证 M15/M16/M17（映射降级/audit 旧
契约判定回退/辅助存在性删除）→ 97/2、98/1、98/1 全红。

### 修复期间自踩坑（第四次规则自证）
verify_stage_evidence_contract 初版吞掉底层诊断输出（>/dev/null）+ error
文案不兼容旧断言——统一函数不吞诊断（断言可定位拦截点）；夹具空哈希假
绑定（ev 文件建错目录 → EVIDENCE_SHA256 空 → rc=3 软放行）曾掩盖两处
夹具缺陷（$TMP/p7 目录错位 + L78 篡改报告未还原）——硬口径落地后这两
处历史污染立刻现形并被修复（旧软口径的"全绿"是夹具污染+软放行的合成
假象）。

## v3.16.7 (2026-08-30) — 第二十八轮审查：旧契约边界 / 前置链主链复验 / 空转钉重写

### P1 修复
- **N28-P1-1 旧契约证据校验器边界双缺陷**（N27-P1-1 同型漏网兄弟）：
  verify_evidence_receipt（devflow-state-core.sh）绝对路径分支的词法前缀匹配
  改 cd -P 物理归一 + 归一后边界判定（防 $WS/../外部 与符号链接词法逃逸）；
  相对路径分支补齐此前完全缺失的边界检查。该函数是 P3cd/P4/P5/P7-P10
  七类阶段主校验器——旧 PoC：EVIDENCE_PATH 绑定 workspace 外部稳定文件
  即可过 complete。core 顶部幂等 source devflow_receipt.sh 复用归一助手。

### P2 修复
- **N28-P2-1 complete P7+ 前置链主链证据复验**：P3b/P3cd/P4/P5 补
  verify_receipt_evidence 复查（对齐 reconcile 口径；rc=3 legacy 渐进放行、
  rc=1 证据缺失/篡改/越界必拒）——此前仅查存在+EXIT_CODE+SKILL_TREE，
  删 P4 绑定证据后 complete P7 照常推进。
- **N28-P2-2 T23f 空转钉重写**：init 基线 P0 收据（state-init@）使
  reconcile 在链完整性 P0 处提前死亡、从未到达 P3b 分支（断言空洞满足，
  M8 变异存活）；重写为 P0..P3 合法 g@ 收据 + 真实 P3b 收据，P3b 证据
  删除成为唯一判别变量（N26-P2-2 修复自 v3.16.5 起两轮零守护，本轮钉住）。

### P3 修复
- **N28-P3-1 reconcile P7+ 复查零钉**：补 T24b（删 P6-final →
  reconcile 不推进 P7；夹具按 reconcile 链完整性口径构造——P3b 真实
  gate 产物 + P3cd/P4/P5/P7 带 ev 收据）。
- **N28-P3-2 旧契约边界零钉**：补 T24a 三站点（devflow_receipt.sh 旧
  契约分支外部稳定文件绑定 + verify_evidence_receipt 词法前缀逃逸变体 A
  + 相对路径分支变体 B——双变体均 workspace 外文件）。

### 行为钉 +6（T23f 重写 + T24a 三站点 + T24b + T24c）
变异自证 M10/M11/M12（删 core 边界 / complete 主链复验 / reconcile
辅助复验）→ 91/2、92/1、92/1 全部变红。

### 修复期间自踩坑（第三次规则自证）
新写 T24a 断言消息含未定义 `$WS`（set -u 崩溃）+ 变体 A/B 外部文件误置
workspace 内（越界断言红才走到 bad 分支触发崩溃）——夹具变量须先核语义
（词法命中前缀 ≠ 物理越界）再写断言；孤儿测试进程（管道 writer 阻塞）
会伪装成"挂起"，排查先 ps 看双实例。

## v3.16.6 (2026-08-30) — 第二十七轮审查：证据边界 / 表头逃逸 / 前置链复查 / audit fail-closed

### P1 修复
- **N27-P1-1 证据绑定 workspace 边界**：verify_receipt_evidence 补边界校验——
  证据（新旧契约同口径）必须落在 ${WORKSPACE:-$PWD} 内（cd -P 物理归一，防
  ../ 词法逃逸与符号链接逃逸）。PoC：EVIDENCE_PATHS_JSON=["/etc/hosts"] 绑定
  外部稳定文件可过 complete——N25/N26 两轮构建的"删证据防线"整体失效。
- **N27-P1-2 s6-final 表头逃逸**：TSV 首行必须为 ID<TAB>STATUS 表头——此前
  tail -n +2 / NR>1 无条件跳过首行，无表头文件的数据行可藏入"表头位"绕过
  FAIL=0（PoC：首行 A01 FAIL → total=1 pass=1 fail=0 → gate exit 0）。
- **N27-P1-3 complete/reconcile P7+ 前置链复查辅助收据**：复用 _verify_*
  全契约复查 P6-credential/P6-final/ARCH-PITFALLS（此前仅查 P6-credential
  文件存在；complete P6 后删辅助收据或降级 EXIT_CODE，P7+ 照常推进且
  audit 零感知，与"删证据后不得推进"原则矛盾；reconcile 的 P6 分支只在
  推进 P6 本身时触发，P6 已 completed 后推进 P7 时不复检——同型洼地）。

### P2 修复
- **N27-P2-1 P6-credential 前置链只查存在不查内容**：并入 P1-3（复用
  _verify_p6_credential 全契约）。
- **N27-P2-2 audit jq 缺失静默跳过**：state-scope 检查前置 jq 存在性——
  缺失即 fail（PoC：无 jq 时"completed 无收据"从 17 FAIL 变 PASS）。
- **N27-P2-3 state JSON 损坏被 || true 吞掉**：解析失败（损坏/phases 非
  对象）fail-closed（state-scope + check_versions 树锚点两处；无 phases
  字段的精简 state 合法输出空不误伤）。
- **N27-P2-4 reconcile P3b 重验无行为钉**：补 T23f（删 P3b 证据 →
  reconcile --apply 停在 P3b）——v3.16.5 修复曾被 M6 变异证零守护。

### P3 修复
- **N27-P3-1 T22f 双重空转**：JSON 与树哈希统一相对口径（路径名掺哈希，
  口径分裂致基线恒败）+ 基线成功纳入断言 + 攻击前回滚 state（此前基线
  推进后二次 complete 被"阶段顺序"侧翼拦截——修复在否测试都绿）。
- **N27-P3-2 路径解析依赖调用方 cwd**：并入 P1-1（相对路径以 workspace
  归一；audit 侧注释口径对齐 rc=3 legacy）。
- **N27-P3-3 收据 ENVIRONMENT 行**：经核 s6-final L80 已以证据文件值覆盖
  进程变量（非缺陷，记录口径观察；p3b 的进程 env 注入面维持文档化默认）。
- **N27-P3-4 T22g 夹具不纯净**：补绑定行使值降级成为唯一 FAIL 变量。

### 行为钉 +6（T23a-f）
证据越界被拒（库级+状态机级）/ 无表头 TSV 阻断+对照组 / complete P7 缺
P6-final 拒+补齐对照过 / audit jq 缺失 fail-closed / state 损坏 fail-closed /
reconcile 停在 P3b。foo P10 夹具链补 ARCH+P6-final（前置链新增复查后必需）。

### 修复期间自踩坑（规则自证）
新写 devflow_receipt.sh 诊断行 `$ev_path（` 未花括号 + 多字节——bash 3.2
变量名解析吞入 `（` 字节致 unbound（P8 审计当场崩溃）；全树静态扫描器
（v3.15.23 扩域至 scripts+tests）即刻拦截同型新写测试代码——扫描规则
再证有效，新代码必须过该扫描。

## v3.16.5 (2026-08-30) — 第二十六轮审查：证据绑定拉平 / 值降级防御 / 夹具隔离

### P2 修复
- **N26-P2-1 P6-final 证据绑定重验**：_verify_p6_final 补 verify_receipt_evidence
  ——与 _verify_arch_pitfalls 同口径（此前删 P6-final 证据后 complete P6 仍可推进；
  N25 轮已修 ARCH-PITFALLS/P3b 同模式，本轮补齐最后一块）。
- **N26-P2-2 reconcile P3b 主收据重验**：reconcile 路径补 P3b 新契约收据的
  EVIDENCE_TREE 绑定校验（对齐 complete 路径，防删证据后 reconcile 仍放行）。

### P3 修复
- **N26-P3-1 变异夹具隔离化（T22c/d）**：主收据/ARCH-PITFALLS 夹具改用真实
  gate 产物（绑定+证据齐备）——此前共享夹具被上轮新契约判定先拒，断言空转
  风险（测的是契约判定而非目标分支）。
- **N26-P3-2 audit 值降级防御**：state 标记 completed 的阶段收据 EXIT_CODE
  必须=0——防「内部+镜像一致篡改为非 0」的值降级变体（一致篡改绕过镜像
  对账后，由状态一致性维度兜底）。

### 行为钉 +2（T22f/g）
删 P6-final 证据 → complete P6 拒绝 / EXIT_CODE 值降级+一致篡改 → audit
阻断。P6 fixture 链补 P6-final 证据绑定（拉平后必需）。

## v3.16.4 (2026-08-28) — 第二十五轮审查：收据剥离变体 / reconcile 洼地 / 契约拉平

### P1 修复
- **N25-P1-1 判定标记升级（剥 PRODUCER_ROLE 变体）**：新契约判定从可剥离的
  PRODUCER_ROLE 行改为「stage + 版本」组合——P3b/P6-final/ARCH-PITFALLS 且
  版本 ≥3.16.0 的收据缺绑定行即 FAIL（生成器 fail-closed 保证必然产出）；
  VERSION 行本身不可剥（check_versions 拒缺失）不可篡改（版本不匹配 FAIL）。
  旧版本同名 stage 收据 WARN 渐进迁移不误伤。
- **N25-P1-2 reconcile P3b 洼地**：reconcile --apply 推进 P3b 补校验
  ARCH-PITFALLS 收据（对齐 complete；与 v3.15.2 P6-credential 洼地同模式）。

### P2 修复
- **N25-P2-1 _verify_arch_pitfalls 契约拉平**：补 VERSION 戳校验、
  verify_skill_tree_receipt、证据绑定重验（verify_receipt_evidence）——此前两行
  伪造收据（EXIT_CODE=0 + PHASE）即可放行。
- **N25-P2-2 complete P3b 主收据证据绑定重验**：删绑定证据后状态机不得推进
  （此前 audit 事后 FAIL 但 reconcile 只进不退）。

### P3 修复
- **N25-P3-1 N+1 存在性判断改 $SCRIPT_DIR**（cwd 相对路径在项目根恒假 → 静默
  跳过仍报 PASS）；**N25-P3-2 树哈希守卫 || true**（set -e 下计算失败先于守卫
  触发 exit 1，口径统一 exit 2）。

### 行为钉 +5（T22a-e）
剥三行变体审计阻断 / reconcile 洼地 / 伪造收据 / 删证据 complete 拒绝 / 假
shasum → exit 2。P7 fixture 链 P3b 补证据绑定（新契约判定后必需）。

## v3.16.3 (2026-08-28) — 第二十四轮审查：收据契约闭环（穿越面/剥离面/接线面）

### P1 修复
- **N-P1-1 arch --receipt feature 白名单**：v3.16.0 新增收据写入口曾无校验（全树
  第 27 个 feature 入口漏网）——PoC `--receipt '../../..'` 在项目外写收据+证据。
  接 devflow_feature_validate。
- **N-P1-2 新契约收据缺绑定行 = 被剥离 → FAIL**：删证据+剥
  EVIDENCE_PATHS_JSON/EVIDENCE_TREE_SHA256 行曾落入 legacy WARN 放行（与已修的
  EXIT_CODE 行剥离同型）。以 PRODUCER_ROLE 行（仅新契约生成器产出）为标记——
  legacy 收据天然无此行不被误伤。

### P2 修复
- **N-P2-1 ARCH-PITFALLS 收据接线**：p3b §6 改 --all --receipt 组合（检查+收据
  一体产出）；complete P3b 强制校验（缺收据/非成功拒绝推进）；devflow.md 承诺
  从"每次 Phase 切换"收敛为真实接线的 P3b 门禁。

### P3 修复
- **N-P3-1 SCRIPT_DIR 真正落码**（v3.16.1 changelog 曾声称修复但未落码——N+1
  子检查双重死路）；**N-P3-2 _RC_TREE 非空守卫**；**arch 收据树哈希口径统一**
  （此前误用单文件哈希，与 verify_receipt_evidence 树哈希构造不一致——收据从
  产出起即被审计误判"证据树哈希不匹配"）；**N-P3-3 行为级负回归 +6**
  （T17-T21：M1/N-P1-1/N-P1-2/N-P2-1/假 jq ×2——v3.16.1/2 修复此前仅有工件钉）。

### 测试结构修复
- test-evidence-hardening.sh 中置 finish（T16 曾被追加在 finish 后——计数不含
  T16）重构为单一末置 finish。

## v3.16.2 (2026-08-28) — 收据契约 fail-closed 口径全树对齐

### 修复
- **s6-final 收据 fail-closed 对齐 p3b**（第 23 轮 P3-2）：版本源读取失败/证据树
  哈希计算失败/jq 缺失或损坏均拒绝产出收据 exit 2（旧口径：VER 空仍写
  VERSION=p6-final@、EV_TREE 空写 calc-failed 占位、jq 缺失 EVIDENCE_PATHS_JSON
  为空 → 收据降级 legacy 无绑定，审计 WARN 放行）。
- **jq 双守卫（存在性 + 结果非空）三处统一**（s6-final/p3b/arch-pitfalls）：
  PoC 实证"jq 损坏（exit 127 但可执行）"时 command -v 通过、输出为空——仅
  存在性守卫不拦截，收据仍降级 legacy。arch 侧 set -e 下 jq 替换失败先于
  守卫触发 127，需 `|| true` 后由结果守卫统一 exit 2。
- **arch-pitfalls case 内死代码 --receipt 分支清除**：入口级处理后残留重复块。
- **release-audit JSON 校验 `$?` 脆弱写法显式化**：jq 分支改显式 if（v3.15.19
  同型——其间插入命令即静默丢失判定）。

## v3.16.1 (2026-08-28) — 第二十三轮审查：接线收口（P6-final 消费/终态降级/组合收据）

### 修复
- **P0（N-P0-1）P6-final 终验收据接入状态机**：complete/reconcile 推进 P6 时强制校验
  gates/P6-final 收据（用户原始 PoC 状态机级复现——零终验证据曾可直入 P7）。
- **P1（N-P1-1）终态判定 fail-closed**：收据 EXIT_CODE 行被剥离时按终态处理（原
  剥离一行即降级"失败轮 WARN"，删证据后审计放行）。
- **P1（N-P1-2）arch-pitfalls 组合口径**：--all --receipt <feature> 入口级处理
  （原 case 分发吞掉 --receipt，rc=0 假绿不写收据）；失败轮收据死代码修复（set+e
  包裹）；补 SCRIPT_DIR 定义（N+1 子检查曾恒 127 却报 PASS）。
- **P3 顺带**：p3b 角色字段大小写归一（Alice/alice 同人绕过）；显式传假 SERVICE
  目录从 WARN 改 P0。

## v3.16.0 (2026-08-28) — 用户复审四连 P0/P1 + 次优先级全收口（收据契约大版本）

> 背景：用户复审报告 3 P0 + 1 P1 + 4 次优先级，逐项 PoC 实证成立后修复。

### P0 修复
- **P0-1 P6 拆分 first-pass 指标 vs final verification**：s6_first_pass_accuracy.sh
  定位澄清（首轮允许失败，仅指标）；新增 s6_final_verification_gate.sh——部署前
  终验：验收点 FAIL=0（SKIP 也阻断）+ unit/integration/client/load/staging 五类
  测试证据四要素（CMD/EXIT/REPORT_PATH/REPORT_SHA256 哈希对账）+ ENVIRONMENT
  边界。devflow.md P6 矩阵双 Gate 挂载。
- **P0-2 p3b 角色隔离结构化**：旧实现比较完整文本行（"开发者: alice"≠"审查者:
  alice" 恒成立，同人自签 PoC 直接 PASS）。改 DEVELOPER_ID/REVIEWER_ID/
  REVIEW_SESSION_ID 结构化字段——缺失或相等即 P0 阻断（不再 WARN 放行）。
  SERVICE 省略时从 backend/*/src/main/java 推导（唯一→用之；0/多→P0，拒绝
  静默跳过 TODO 扫描）。
- **P0-3 统一收据契约 + 证据绑定重验**：新共享库 devflow_receipt.sh
  （receipt_evidence_tree/verify_receipt_evidence）；p3b/s6-final/arch-pitfalls
  收据携带 COMMAND/EVIDENCE_PATHS_JSON/EVIDENCE_TREE_SHA256/PRODUCER_ROLE/
  SESSION_ID/STARTED_AT/FINISHED_AT/ENVIRONMENT；audit-receipts 逐收据重验
  证据（终态收据 EXIT_CODE=0 证据缺失/篡改即 FAIL——"删证据后审计仍通过"
  PoC 阻断；失败轮收据 WARN 放行——gate 迭代期证据合法变更）。artifact_gate
  audit 前清理本轮旧收据（迭代过时指纹不再误报）。legacy 收据 WARN 渐进迁移。

### P1 修复
- **P1-1 sync-copies 对账 SHA 化**：rsync -ani size+mtime 判定双缺陷（内容同
  mtime 异误红；同大小+恢复 mtime 篡改漏检）。check 统一 portable_diff
  （文件集合+SHA-256）；apply 加 --checksum 修复内容漂移。双变异测试钉住。
- **P1-2 ARCH-PITFALLS 收据门禁**：check-arch-pitfalls.sh --receipt <feature>
  写收据（含证据绑定）；devflow.md 矩阵声明每次 Phase 切换执行。

### 次优先级
- **P2-1** windows-compatibility.md 重写为 v3.15.x 事实（修正 Bash 3.2
  process substitution 错误声明；平台矩阵+待 CI 收据）。
- **P2-2** 发布审计去重：test-release.sh 默认跳过正跑（RELEASE_AUDIT_POSITIVE=1
  恢复），正式审计仅 release.sh 一次。
- **P3-1** _archive 三方统一排除（gate-skill-tree/gen-skill-manifest/
  sync-copies 与 release-audit 对齐；归档不进发布包）。

### 负回归
- PHASE_GATES +8（p3b 同人/缺字段/隔离通过/删证据阻断/证据齐备 + s6-final
  FAIL 阻断/证据缺失阻断/伪证据阻断）；EVIDENCE_HARDENING +3（sync 双变异）。
- 修复过程中三度自踩多字节吞噬（$f（/$stage_name（/$DEVELOPER_ID（），静态
  扫描当场拦截——规则自证。

## v3.15.24 (2026-08-28) — 第二十一轮独立审查：夹具缺口 / perl fail-open / §8 边角

> 背景：第 21 轮独立审查（子 agent，含 4 组变异测试）判定 0 新 P0/P1/P2，发现
> 2 项新 P3 + 1 项 P4 观察项；本轮全部收口。

### P3 修复
- **CKF 夹具补 _权限矩阵.md（P3-A）**：check-permission-consistency 曾走"文档
  不存在"早退 exit 2——CHK_RC 断言被 doc-missing 路径空洞满足（M1 变异删整个
  透传块后测试仍 36/36 全绿）。夹具补矩阵文档后死 python 实测 rc=1（真实到达
  python 段）。
- **静态扫描 perl 前置 fail-closed（P3-B）**：无 perl 环境（slim/alpine CI）时
  find -exec perl 2>/dev/null 输出空、退出码取自 sort → 断言假 PASS——与
  §5/§8 已修的管道空输出同型。补 command -v perl 守卫。

### P4 修复（顺带）
- **§8 FAIL 分支后不再打印矛盾 WARN（P4-1）**：死 python3 时 [FAIL] 输出异常
  后曾紧随 [WARN] 使用率仅 0% (/)——主信号 FAIL 后跟误导行。PASS/WARN 判定
  移入正常输出分支。

## v3.15.23 (2026-08-28) — 第二十轮独立审查：修复边角收口 / 扫描域扩展

> 背景：第 20 轮独立审查（子 agent，含 5 组变异测试）判定 0 新 P0/P1/P2，发现
> 7 项新 P3（4 项与 v3.15.22 修复直接相关、3 项为全树扫描新发现既有问题）；
> 本轮全部收口。

### P3 修复
- **测试代码多字节吞噬（P3-1）**：test-report-regressions.sh bad 行 `$CHKRC（假
  成功）` 裸变量+全角括号——bash 3.2 变量名解析吞入多字节字节致 unbound 崩溃，
  回归检出时套件截断丢失后续断言。花括号化 + 删调试残留死代码行。
- **permission-consistency rc=2 业务透传（P3-2）**：python sys.exit(2)（文档读取
  FATAL）曾与"环境故障"报文矛盾——无效 UTF-8 文档的 FATAL 后紧随"检查 python3
  可用性"误导排障。rc=2 同 rc=1 透传。
- **check 家族夹具补 backend/（P3-3）**：4/6 脚本曾走"目录不存在"早退从未到达
  python 段——M5 变异（删 CHK_RC 块）后测试仍全绿的夹具缺口。
- **业务侧语义断言（P3-4）**：fake python3 exit 1 模拟 sys.exit(1) 业务判定 →
  6 脚本必须静默透传 rc≠0 且不误报"环境故障"（M3a 变异曾无测试捕获）。
- **md 执行片段花括号化（P3-5）**：audit-completeness.md `（退出码 $rc）`（违反
  同文件铁律 1：真实退出码必须进入报告——bash 3.2 吞字节致丢失）+ devflow.md
  `（exit=$code）` 同型。
- **GEN_SCRIPT NameError（P3-6）**：permission-consistency python f-string 引用
  shell 变量未定义——建议行永不出现（rc 方向正确）。经环境变量传入。
- **两处环境故障误归因（P3-7）**：check-skill-usage §8 死 python3 假 WARN
  "使用率 0%"（补输出格式对账 fail-closed，§5 同口径）；release-audit python
  损坏误报 invalid JSON（消息区分）。

### 静态扫描扩域
- 未花括号 $var+多字节扫描从 scripts/ 扩至 scripts/ + tests/ + commands/*.md
  执行片段——第 20 轮实证扫描盲区让测试代码与 md 示例的同型缺陷存活。

### 负回归
- test-report-regressions.sh +6：业务侧语义断言 ×6（REPORT_REGRESSIONS
  RESULT 36/36 PASS）；test-v3140-regressions.sh +2：扩域扫描双用例。

## v3.15.22 (2026-08-28) — 第十九轮独立审查：CHK_RC 语义区分 / checkpoint 只读分支收口

> 背景：第 19 轮独立审查（子 agent，含 3 组变异测试）判定 0 新 P0/P1/P2，发现
> 2 项新 P3（低）——一项为 v3.15.21 修复引入的输出语义混淆，一项为历轮 P1 修复
> 的未收口只读分支；本轮全部收口。

### P3 修复
- **CHK_RC 语义区分（6 处）**：rc=1 是 python sys.exit(1) 业务判定 FAIL（真实
  原因已由 python 打印，静默透传阻断）；rc=127/126/2 等才是解释器/语法环境
  故障（报"Python 环境故障"）。旧版把业务违规（如权限码不一致）误报为
  "Python 检查失败"——排障者误查环境而非业务。
- **checkpoint-state.sh resume/list 兄弟分支 fail-closed**：save 分支 P1 修复
  （PYRC + 非空双验）的未收口兄弟分支——死 python3 时 resume 空输出 + rc=0
  （agent 误从 P0 重启）、list 空输出 + rc=0。补 RESUME_RC/LIST_RC 检查同口径。

### 负回归
- test-report-regressions.sh +7：check 家族 6 脚本死 python3 → fail-closed +
  环境故障消息语义断言（REPORT_REGRESSIONS RESULT 30/30 PASS）。
- test-state.sh +3：resume/list 死 python3 → fail-closed + 正常路径保持
  （STATE RESULT 12/12 PASS）。

## v3.15.21 (2026-08-28) — 第十八轮独立审查：check 家族终验收口 / 负回归区分度 / §5 假 PASS

> 背景：第 18 轮独立审查（子 agent，含变异测试）判定 0 新 P0/P1/P2，但发现
> 3 项新 P3——两项为 v3.15.19 修复同型脆弱性的未收口兄弟家族，一项为测试
> 钉住缺口；本轮全部收口。

### P3 修复
- **check 家族 6 脚本 GEN_RC 显式终验**（code-standards/entity-db/frontend/
  permission-consistency/detect-n-plus-one/super-scorecard）：全部以 python
  heredoc 为末命令隐式传播 rc——末尾追加一条 echo 即死 python3 → rc=0 假绿
  （第 18 轮 PoC 精确复现 v3.15.19 修复动机场景）。补 `CHK_RC` 终验与生成器
  家族同口径。注意：frontend-standards 无 frontend/ 目录走早期跳过分支（rc=0
  设计行为保持）；permission-consistency 先重生成矩阵，死 python 在生成器
  阶段即被 L36 exit 2 拦截（双重 fail-loud）。
- **check-skill-usage §5 python 失败假 PASS（fail-closed）**：`find -exec
  python3` 死亡时输出空 → grep -c 得 0 → 假 PASS "全部无 blocker"（PoC：state
  含 blocker + 死 python3 仍报 clean，中断恢复审计静默失效）。三重防御：
  python 改 try/except 输出 'E' 解析失败标记 / 行数对账（LINE_COUNT≠TOTAL 即
  FAIL）/ 空输出对账。正常场景 WARN/PASS 行为实测保持。
- **四生成器负回归补陈旧产物夹具**：变异实证（删 GEN_RC 块后测试仍 23/23
  PASS——rc=1 由非空检查歪打正着提供假区分度）。GFB fixture 预置四个陈旧
  OUTPUT_FILE（MASTER.md / INDEX-接口-auto.md / _权限矩阵.md /
  INDEX-表-auto.md），GEN_RC 成为唯一拦截者。

## v3.15.20 (2026-08-28) — 第十七轮独立审查：--section-only 终验误杀修复

> 背景：第 17 轮独立审查（子 agent）判定收敛（0 新 P0/P1/P2），但发现 v3.15.19
> 修复引入 1 个 P3 回归：permission-matrix `--section-only` 模式（第四模式，仅输出
> §2 到 stdout、不写产物）被非空终验误杀 rc=1（fail-closed 方向误红，非假绿）。

### P3 修复
- **permission-matrix 非空豁免补 SECTION_ONLY**：豁免条件由
  `DRY_RUN=0 && DIFF_MODE=0` 补齐 `[ "$SECTION_ONLY" -eq 0 ]`——四模式
  （default 写产物 / dry-run 仅统计 / diff 仅对比 / section-only 仅输出）全 rc=0
  实测保持，python3 死亡显式 rc=1 终验不受影响。

### 负回归
- test-report-regressions.sh +1：--section-only 无产物场景必须 rc=0
  （REPORT_REGRESSIONS RESULT 23/23 PASS）。

## v3.15.19 (2026-08-28) — 第十六轮独立审查：P3 三连收口

> 背景：第 16 轮独立审查（子 agent）确认 v3.15.18 三项修复全部落地（代码 + 测试 +
> 独立 PoC 三重验证）、六维度全树扫描 0 P0/P1/P2、历轮 10 版修复全部保持；
> 判定收敛，遗留 3 项 P3 观察项本轮全部收口。

### P3 修复
- **四生成器显式终验**（master/interface/permission/table）：此前以 python heredoc
  结尾隐式传播退出码（rc=127 实证 fail-loud，但末尾追加任何命令即静默破坏——
  第 14 轮 P3 观察项）。补 `GEN_RC` + 非空双终验与 er-index/schema-changelog 同
  口径；permission-matrix 的非空检查仅默认模式（--dry-run 仅统计/--diff 仅对比
  均不写产物；v3.15.20 勘误：另有 --section-only 仅输出 §2 到 stdout 同样不写
  产物，v3.15.19 豁免条件漏该模式致其误杀 rc=1——本轮补齐后四模式 rc=0）。
- **s8 options-only 用例 rc 维度补强**：输出断言（不含 invalid feature name）
  之外加 rc≠2 断言（rc=2 是参数/用法错误，rc=1 是无证据的合法 fail-closed）——
  防两类回归互相掩盖。
- **s8 FALLBACK_FILES 整数格式预校验**：非数值（如 abc）时 bash -ge 产生
  "integer expression expected" stderr 噪音后落入 else（行为正确但报错不友好），
  先 grep -E '^[0-9]+$' 再比较。

### 负回归
- test-report-regressions.sh +4：四生成器 python3 死亡 → 显式 rc=1
  （REPORT_REGRESSIONS RESULT 22/22 PASS）。

## v3.15.18 (2026-08-28) — 用户复审三连：s8 参数解析 / 伪 fallback 非幂等 / portable 同步写穿

> 背景：用户复审报告三项问题，逐项 PoC 实证成立后修复（全部为假绿/写穿类）。

### P1 修复
- **s8 options-only 解析错误（exit 2）**：`FEATURE="${1:-}"` 在 flag 解析循环之前
  从 $1 预赋值——首个 flag 被误存为 feature，白名单校验即拒。三类用法
  （--force-fallback / --report x / --git-range 3 foo）全部不可用，含 usage 自带
  示例。改 FEATURE=""，feature 统一由循环 *) 分支收集。
- **s8 伪 fallback 首跑假绿 + 重跑失败（非幂等）**：FINDINGS=0 / SHA256=not-a-hash
  以"非空即放行"通过五要素检查（首跑 WARN exit 0）；SECTION 5 报告覆盖重写丢弃
  source_fallback_evidence 指针 → 同一报告第二次运行 no fallback evidence FAIL。
  双修：FALLBACK_FINDINGS 必须 ≥1 整数（零发现=未真实评审）、FALLBACK_SHA256
  必须 64-hex；报告重写前快照并回写证据指针（幂等）。
- **sync-copies portable 分支三缺口**：① cp/mkdir 写穿目标树 symlink 到 skill
  目录外（PoC：dst/README.md → 外部文件被源内容覆盖）——新增
  portable_reject_symlinks 前置扫描（rsync 分支替换语义天然安全，仅 portable
  需要）；② 无 rsync 且无 shasum/sha256sum 时空哈希相等使篡改目标判 SYNCED
  ALL OK（假绿）——前置 fail-closed exit 2；③ portable_diff 空哈希防御（哈希
  失败≠相等，报 no-hash）。

### 负回归
- test-phase-gates.sh +3：options-only 解析 / 伪 fallback 首次即拒 / 双跑幂等
  （含证据指针保留断言）。
- test-evidence-hardening.sh +2：portable symlink 拒绝（外部文件不得被写穿）/
  无 SHA 工具 fail-closed（篡改目标不再假绿）。

## v3.15.17 (2026-08-28) — audit-completeness 图谱命令误传 feature 参数修复

> 背景：用户复审发现 audit-completeness.md 图谱健康命令组合传参（REPORT 环境变量
> + feature 位置参数并存）违背 s8 的二选一设计，且产生空目录副作用。

### 修复
- **commands/audit-completeness.md 图谱命令移除 `<feature>` 位置参数**：s8 的
  feature 位置参数唯一实际作用是构造默认报告路径
  `.devflow/<feature>/graph-health-report.env`；REPORT 已显式指定
  `docs/test/<feature>-graph-evidence.env`（feature 已嵌入路径）时再传位置参数
  仅剩 scope 标签冗余 + 触发 `.devflow/<feature>/` 空目录 mkdir 副作用
  （REPORT_FILE 被 REPORT 覆盖，目录白建）。实测对照：传参 → 创建空
  `.devflow/foo/`；不传 → 仅 `.devflow/`。与全树其他口径（编排方 s8b 的
  GRAPH_HEALTH 映射、concepts/PRD实施方法论.md、commands/spec.md 两处）对齐
  （均为无参数调用）。

## v3.15.16 (2026-08-28) — 第十五轮 P3 观察项收口

> 背景：第 15 轮收敛判定后遗留 4 项 P3 观察项（健壮性不一致/行文 nit，无假绿无
> 安全面），本轮全部收口。

### P3 修复
- **er-index / schema-changelog 输出目录自动创建**：与 permission-matrix/postmortem
  同惯例补 `mkdir -p "$(dirname "$OUTPUT_FILE")"`——直接调用且 docs/detailed-design
  缺失时不再报 Python Traceback（原 fail-loud 但提示不清）。
- **init-fact-sources 生成器失败判定显式化**：原 `| tail -3 || echo WARN` 依赖
  L32 `set -o pipefail` 隐式生效（实测 pipefail 下 || 可触发，第 15 轮"死分支"
  判断不成立——勘误；但隐式依赖脆弱，pipefail 一旦移除即变真死分支）。改
  PIPESTATUS 显式捕获 + WARN 带 rc。
- **pre-commit mktemp 失败 fail-closed**：原回退可预测文件名
  `/tmp/devflow_controllers_$$.txt`（可预测 → 符号链接竞争风险）。改 if 捕获 →
  计入 FAILED 阻塞 commit，不再产生可预测文件名。
- **CHANGELOG 行文勘误**：v3.15.15 条目"REPORT_RESULT"实为
  "REPORT_REGRESSIONS RESULT"。

### 修复过程中的自我捕获
- init-fact-sources WARN 行首版 `（rc=$GEN_RC）` 裸变量紧邻多字节字符——bash
  变量名解析吞入 `）` 字节致 unbound（PoC 即刻复现）。本树静态扫描规则
  （未花括号 $var+多字节）当场拦截，改 `${GEN_RC}`。规则自证有效。

## v3.15.15 (2026-08-28) — 第十四轮独立审查：er-index 正向 SyntaxError 修复 / 生成器正向盲区封堵

> 背景：第十四轮独立审查（子 agent）确认 v3.15.14 两项修复真实落地（时间机器反向
> 验证有效）；新发现 0 P0 / 1 P1 / 0 P2——er-index 正向路径存在长期潜伏 SyntaxError，
> 因全树生成器正向零覆盖而连续两轮修复未被察觉。

### P1 修复
- **generate-er-index.sh L367 Python SyntaxError（正向 100% 失败）**：维护说明章节
  `md.append("bash "$SKILL_ROOT/..."")` 外层双引号内嵌未转义双引号 → 第二段 python
  必然 SyntaxError，ER 索引文档从未生成成功（fail-loud 无假绿，故长期未暴露）。
  改单引号包裹（与 schema-changelog/master-index 同位置写法对齐）。

### 根因收口：生成器正向盲区
- 13 轮以来只对生成器测守卫（fakebin python 死亡）不测功能——负回归被 SyntaxError
  歪打正着满足。test-report-regressions.sh +7 正向 happy-path 用例
  （REPORT_REGRESSIONS RESULT 18/18 PASS）：er-index/schema-changelog 断言 rc=0 + 产物非空，其余 5 生成器断言
  rc=0（全部实测通过）。

## v3.15.14 (2026-08-28) — 第十三轮独立审查：生成器假成功清零 / 死守卫复活

> 背景：第十三轮独立审查（子 agent）确认 v3.15.13 四项修复全部落地（含 symlink
> 穿越等测试未覆盖向量）、六负回归真实钉住、全量 414 PASS 0 FAIL、树一致；
> 新发现 0 P0 / 0 P1 / 2 P2——均为 v3.15.13"假成功清零"主题的兄弟脚本漏网。

### P2 修复
- **generate-schema-changelog.sh 终验无 rc 检查（PoC 成立）**：`[ -f $OUTPUT ]` 遇
  陈旧产物恒放行，python 失败时 exit 0 假绿（与 v3.15.13 修复的 er-index 同型同构，
  该轮只修了一个未扫兄弟脚本）。改 rc + `[ -s ]` 双终验。
- **mktemp 预创建使 `[ ! -f ]` 成死守卫（两生成器）**：er-index/schema-changelog 第一段
  `TMP_JSON` 守卫恒假从未触发——v3.15.13 修复声明"第一段有校验"实为死代码。改
  `-s`（空文件=python 未写入=真实失败信号）。

### 负回归
- test-report-regressions.sh +2 用例：fakebin python3 死亡时 schema-changelog /
  er-index 必须 exit 1（REPORT_REGRESSIONS RESULT 11/11 PASS）。

## v3.15.13 (2026-08-28) — 第十二轮独立审查：直调子脚本纵深防御 / 假成功清零

> 背景：第十二轮独立审查（子 agent）确认 v3.15.12 三处修复全部落地、全量 407 PASS
> 0 FAIL、manifest 树一致、三平台副本同步；新发现 0 P0 / 2 P1 / 2 P2——均为
> "防护不一致/边界遗漏"型（非新增攻击面），攻击面持续收窄。

### P1 修复
- **generate_from_template 直调穿越（运行时 PoC 成立）**：devflow-state-template.sh 可
  绕过 dispatcher 直达落盘函数，feature/output_path 零校验即 mkdir -p + mv——
  `generate "../evil" P0 /tmp/x.md` 实测越界写穿 .devflow 之外。纵深防御：函数内
  devflow_feature_validate 白名单 + python3 realpath 物理归一化后必须落在 workspace
  内（字符串前缀匹配可被 ../ 绕过，归一化后判定才有效）。
- **checkpoint-state.sh python 失败假成功**：`set -uo pipefail`（无 -e）下 python3
  失败（缺失 rc=127/磁盘满/权限拒绝）后照常输出 "[CHECKPOINT] saved" 且 exit 0——
  中断恢复机制（v3.9.2 立身之本）静默失效。heredoc 后立即 rc + `[ -s state.json ]`
  终验，失败 exit 1 拒绝假成功。

### P2 修复
- **generate-er-index.sh 第二段 python 无产物校验**：第二段写 $OUTPUT 后直接
  ok——python3 失败时 ER 索引缺失但绿灯。补 rc + 产物终验。
  （v3.15.14 勘误：原文"第一段有 TMP_JSON 校验"不成立——该守卫为 `[ ! -f ]`，
  mktemp 预创建空文件使其恒假成死代码；v3.15.14 改 -s 后才真实生效。）
- **artifact_gate.sh METRICS_ENDPOINT 无 SSRF 防护**：HEALTH/BUILD_INFO 均有协议
  白名单 + link-local/metadata 黑名单，唯 METRICS_ENDPOINT 直接 curl——收据可注入
  file:// 或 169.254.169.254 云元数据探测。复用同口径两段 case 校验。

### 负回归
- test-state.sh +6 用例：feature 穿越 / 绝对路径越界 / ../ 相对穿越 / 正向生成 /
  python3 失败假成功 / python3 健康正向（STATE RESULT 9/9 PASS）。

## v3.15.12 (2026-08-28) — 第十轮独立审查收口：白名单/守卫政策全树清零

> 背景：第十轮独立审查（子 agent）确认 v3.15.11 五处修复全部落地、19/19 负回归真实钉住；
> 新发现 0 P0 / 0 P1 / 2 P2——白名单与守卫两大收口政策在全树的最后两处边缘漏网。

### P2 修复
- **after-gate-fail-hook `--latest` xargs 空输入陷阱**：无失败收据时三级 xargs 链以零参数
  执行 `ls -t` 列出当前目录——head -1 使 LATEST 恒非空，"no recent fail receipts" 优雅退出
  永不触发（cwd 首文件被误当收据）。改判空短路。
- **audit-receipts.sh 白名单全树最后漏网**：读侧 `../../evil` 对项目外目录 find/grep/
  shasum 信息探测 + 审计对象调包（无写盘；唯一调用方已校验，封手动调用）。
  补 devflow_feature_validate。
- **测试强度**：P4 flag-as-value 负回归归因精确化——原断言仅验 exit 非零（下游
  unknown-arg 兜底也能过），加守卫报错文本（"non-flag"）断言钉住守卫本身。

## v3.15.11 (2026-08-28) — 第九轮独立审查收口：hook 白名单 / 默认值 / 第 19 处守卫

> 背景：第九轮独立审查（子 agent）确认 v3.15.10 四处修复全部落地（守卫边界实测无
> SC2015/死循环/unbound 风险）；新发现 0 P0 / 1 P1 / 4 P2。

### P1 修复
- **after-gate-fail-hook.sh 白名单漏网**：manual 模式 `FEATURE="${1:-unknown}"` 直接拼接
  `mkdir -p "$STATE_DIR/$FEATURE/feedback"` 追加写——实测 `"../../evil"` 在项目外建目录写
  文件（与 build-watchdog v3.15.10 完全同型；三个 hook 中另两个各有 inline 白名单，唯此
  漏网）。manual/--latest 分支统一 devflow_feature_validate。

### P2 修复
- **s8 GRAPH_URL 默认值未实现**：usage 宣称默认 `http://localhost:8086`，代码
  `${GRAPH_URL:-}` 为空——curl 请求无 scheme 的 `/health` 恒失败，服务在跑也恒判
  unreachable。实现默认值。
- **run-all-checks `--only` 守卫第 19 处**：v3.15.10"全树 18 处"口径漏网——`--only
  --no-frontend` 吞 flag（下游 unknown-check 兜底，报错误导）。补 `[ "${2#-}" = "$2" ]`。
- **p2a grep `\b` 残留**：全树仅剩的 grep 级 `\b`（`\bTBD\b|\bFIXME\b`）——macOS
  grep 实测支持、无害，但与 v3.15.8 BSD/BusyBox 收口政策不一致，不支持的平台上
  LEFT_OVER 漏计（fail-open 方向）。改 `[^A-Za-z]` 词边界（s4 先例）。
- **修复无回归测试钉住**：v3.15.9-3.15.11 的关键修复（flag 吞参/路径穿越白名单/
  s6+s3 无参 fail-closed）在 tests/ 零断言——补 5 条负回归到 test-phase-gates.sh。

## v3.15.10 (2026-08-28) — 第八轮独立审查收口：白名单漏网 / BSD awk / flag 吞参

> 背景：第八轮独立审查（子 agent）确认 v3.15.9 六处修复全部落地，全树同类扫描无残留；
> 新发现 0 P0 / 1 P1 / 3 P2（两项经本机运行时实测验证）。

### P1 修复
- **build-watchdog.sh feature 白名单漏网**：check/gate/watch 模式直接
  `mkdir -p "$STATE_DIR/$FEATURE/..."` 写收据并镜像 `docs/$FEATURE/`——`../../evil` 形态
  可在项目外建目录写文件（v3.15.5 曾给 10+ gate 加 devflow_feature_validate，此处漏网）。
  FEATURE 非空即统一白名单校验。

### P2 修复
- **p4 awk `\s` BSD 失效**：`/^\|\s*[-:]+\s*\|/` 在 BSD awk 按字面 `s` 处理——带空格的
  markdown 分隔行不被跳过（实测复现；此前靠下游字段名过滤兜底，属静默脆弱）。改 `[ \t]*`。
- **`shift 2>/dev/null || true` 语义陷阱**：`2>` 是 fd-2 重定向，实为 shift-by-1——功能
  正确但极易被误读为 shift 2 而"修正"坏。p4×1 / s3×2 改显式 `shift || true`。
- **flag 吞参**：`$#` 守卫不拒绝"下一 token 是 flag"（`--prd --design x` 把 `--design`
  静默吞为值，报错误导）。全树 18 处带值守卫追加 `[ "${2#-}" = "$2" ]`（值不得以 `-`
  开头；各 flag 合法值——路径/prd-design/数字/sha——均不以 `-` 开头，无误伤）。

## v3.15.9 (2026-08-28) — 第七轮独立审查收口：参数解析健壮性全量收口

> 背景：第七轮独立审查（子 agent）确认 v3.15.8 五项修复全部落地无误，另发现 1 P0 / 4 P1 / 3 P2，
> 全部集中在"参数解析健壮性"主题，本批一次收口。

### P0 修复
- **gen-domain-checklist.sh `--stage` 缺值死循环**：旧 `STAGE="${2:-design}"` 掩护了赋值，但
  `shift 2` 失败且不改位置参数（bash 语义）→ while 永真挂死（CI/主循环永久阻塞；p3 v3.15.8
  同型漏网实例）。`--stage`/`--out` 前置 `$#` 检查 fail-closed。

### P1 修复
- **s6 无参 fail-open**：usage 内 `exit 0` + `[ -z "$FEATURE" ] && usage`——无参调用在 feature
  推导成功后仍 exit 0 → 上层误判 P6 准确率 gate PASS。usage 拆分：`--help` exit 0，缺参 exit 2。
- **s3 无参 fail-open**：同型（P2 迁移映射 gate 空跑放行）。同修法。
- **p4 七个带值 flag 裸 `$2`**：--prd/--design/--criteria/--evidence/--service/--expect-api/
  --expect-data 缺值时 set -u unbound 崩溃（fail-closed 但报错不可读），且 `--prd --design x`
  形态会把 flag 静默吞为值。前置 `$#` 检查。
- **s8 `--report`/`--git-range` 裸 `$2`**：同型收口（防未来去 -u 后退化为死循环）。

### P2 修复
- **s6 链式赋值陷阱**：`a && b || c && d` 左结合——`s6 "" 85` 形态把 THRESHOLD 清空且不再校验
  → 阈值 0 恒过。参数段重写：去 $1/$2 预取 + if/elif 显式填充（s2 v3.15.8 同模式），超位置参
  报错 exit 2。
- **WORK_DIR/STATE_DIR 双口径**：p3（报告）与 s8b（输出）的 WORK_DIR 独立默认 `.devflow`，
  隔离部署（STATE_DIR 自定义）下回退宿主目录读跨工作区数据。WORK_DIR 改为
  `${WORK_DIR:-${STATE_DIR:-.devflow}}`（显式 WORK_DIR 仍可覆盖）。

## v3.15.8 (2026-08-28) — 第六轮独立审查收口：参数死循环 / BSD 提取失效 / 假绿链

> 背景：第六轮独立审查（子 agent）发现 1 P0 / 3 P1 / 6 P2（其中 1 项经复核为误报：
> run-tests 编排质疑——test-integration.sh 实际已编排全部子套件）。

### P0 修复
- **p3 带值 flag 缺值死循环**：`--service` 为末参数时 `shift 2` 失败且不改位置参数（bash 语义），
  `set -uo pipefail` 无 `-e` 吞错 → while 永真（实测 3s 挂死需 kill -9）。--service/--mode/
  --waiver 三处前置 `$#` 检查 fail-closed exit 2。

### P1 修复
- **s4 record review 提取 BSD 全失效**：旧 grep+sed 管道 ①`[^\n]` 在 POSIX 括号表达式中反斜杠
  是字面字符（实为"非反斜杠且非字母 n"，ID 与结论间含 n 的行全漏）②BSD sed 不支持 `\b`——
  markdown 评审报告输入时 pass=0 fail=0 全丢、accuracy 失真 100%。改单 awk（match/RSTART POSIX
  标准）+ `[^A-Za-z]` 独立词边界。联动夹具：review 输入改 markdown 真实格式并新增提取断言
  （旧夹具直写目标 TSV 格式，输入原样落盘恰好合法，恒绿掩盖断裂）。
- **s2 单参数 CRITERIA 自证假绿**：`${1:-}` 预赋值 + `A && B || C && D` 左结合短路——单参数时
  $1 落到 CRITERIA（与 DESIGN 同文件），独立冻结分母校验被自证替代，覆盖率恒 100%。改
  if/elif 显式填充，单参数恢复默认路径推导。
- **s4 无参/未知命令 fail-open**：usage 内 exit 0 + unknown command 仅字面 echo（不计数）——
  错误调用被上层当 gate PASS。usage exit 2 + p0 计数 + exit 2。

### P2 修复
- s0/p2a `-h` 输出源码（sed 行范围越界到代码区）→ 修正为注释块范围。
- s0 `--criteria/--matrix` 裸 `$2` 缺值 unbound 崩溃 → 前置 `$#` 检查（exit 2 + 明确报错）。
- SKILL.md 正文标题版本残留 v3.15.4 → 对齐。
- 12 处 grep/sed 正则 `\s` → `[[:space:]]`（check-skill-usage/p3/p4/s2/s3；python re 内 `\s`
  合法不动）——非 macOS BSD/BusyBox 环境失效风险清零。

## v3.15.7 (2026-08-28) — 第六轮回归收口：T12/T13/T15 真 bug + 全树版本对齐

> 背景：v3.15.6 全量回归推进到 fail-fast 更深层，暴露 3 个真实 bug（此前被 PHASE_GATES 夹具
> 假绿逐层遮蔽）与 98 个文件的 frontmatter 版本残留。

### Bug 修复
- **devflow_feature.sh `$，` unbound 崩溃**：白名单失败消息里正则锚 `$` 后跟全角逗号——set -u
  调用方下被解析为多字节变量名，validate 崩溃 exit 1 而非拒绝 exit 2（T13 路径穿越拦截失效）。
  修 `\$` 转义。讽刺点：这正是本 skill 自立的"$var 后跟多字节必须花括号"规则，且静态扫描
  正则只查 `$[A-Za-z_]+多字节`，字面 `$锚+全角标点` 是扫描盲区。
- **s8b DIFF_DIR 相对路径 → patch 恒失败**：`(cd "$SKILL_ROOT" && patch -p1 < "$pf")` 的输入
  重定向在 cd 之后打开，相对路径 pf 在 SKILL_ROOT 下不存在 → applied 恒 0、verify 闭环不可达、
  apply_status 直落 FAILED（T15 期望 VERIFY_FAILED 拿到 FAILED）。修：DIFF_DIR 创建后立即
  绝对化 `$(cd ... && pwd)`。
- **sync-copies check 目录 mtime 误报 DIFF**：rsync `-a` 含 `-t`，目标根目录 mtime 因创建
  `.git/.devflow` 等排除目录必变，`.d..t.... ./` 时间戳噪音被当内容 DIFF（T12）。修：check 侧
  加 `--omit-dir-times`（目录 mtime 非发布内容）。
- **P4 夹具缺 @GetMapping**：FooController 夹具无 Mapping 注解，代码端接口提取恒 0；旧版靠
  BSD sed `\s` 零命中导致 §2 静默 skip 假绿掩盖。夹具补 `@GetMapping("/api/foo/list")`。

### 发布链完整性
- 全树 98 个 md（agents/commands/concepts/phases/references/subagents/templates）frontmatter
  `version: "3.15.4"` 残留——历次升版只改 SKILL.md/README/CHANGELOG，release-audit 版本一致性
  98 项 FAIL。统一对齐 3.15.7。
- 升版流程固化：全部版本引用改完 → generate → check → 全量测试；generate 之后严禁再改任何
  manifest 覆盖文件（v3.15.5/v3.15.6 均因此作废，未分发）。

## v3.15.6 (2026-08-28) — 发布链顺序修正

- README.md 版本号同步补漏：SKILL.md/CHANGELOG/README 三处版本必须同批升版（test-maintainability
  "README uses current version" 守卫）。
- v3.15.5 manifest 生成于 README 版本同步之前（树 hash 即刻漂移，未分发至任何副本，作废归档）；
  v3.15.6 为本批次首个可分发版本。教训固化：升版必须"全部版本引用改完 → generate → check →
  跑全量测试"，generate 之后严禁再改任何受 manifest 覆盖的文件。

## v3.15.5 (2026-08-28) — 第五轮审查收口：BSD sed 兼容 / P95 提取 / feature 白名单共享

> 背景：第五轮独立审查（子 agent）发现 2 P0 / 4 P1 / 3 P2，聚焦 macOS BSD 工具链兼容性、
> 阈值校验有效性、feature 名白名单统一与同步守卫。

### P0 修复
- **P0-1 p4_prd_vs_code.sh BSD sed `\s` 零命中**：sed 正则的 `\s` 全部改 `[[:space:]]`——
  BSD sed（macOS 默认）不支持 `\s`，旧写法替换零命中，design_apis_raw 恒空 → §2 API 逐项
  对比静默 skip（虚假通过）。联动修复：测试夹具 FooController 补 `@GetMapping("/api/foo/list")`
  （旧夹具无 Mapping 注解，靠 §2 静默 skip 假绿掩盖）。
- **P0-2 p3_security_perf P95 提取取到字面 95**：旧管道提取的第一个数字是 "P95" 字面里的
  95——`[ 95 -le 500 ]` 恒真，阈值校验形同虚设。改 sed 捕获 P95 标签后的首个数字
  （[[:space:]] 口径，BSD/GNU 通用）。

### P1 修复
- sync-copies `:-` 误判"已设置但为空"：`${SYNC_TARGETS:-$DEFAULT}` 改 `${SYNC_TARGETS-$DEFAULT}`，
  空目标 fail-closed（exit 2）守卫恢复生效。
- build-watchdog trap EXIT 无条件复活：kill(SIGTERM)/Ctrl-C(SIGINT) 也会 5 秒后重启。改用
  WATCHDOG_STOP 标志区分预期终止与意外死亡，仅意外死亡自动重启。
- feature 名白名单升级为共享函数 `devflow_feature_validate`（scripts/devflow_feature.sh），
  s8b/s8/p10/gen-domain-checklist 等统一 source——封堵路径穿越与 grep -E 正则注入。
- STATE_DIR 三处硬编码 `.devflow` 改 `${STATE_DIR:-.devflow}`（p4/p10/gen-domain-checklist）。

### P2 修复
- s0 分母为零、metrics 端点 SSRF（私网地址封堵）、audit-receipts 补 EVIDENCE_PATH/
  EVIDENCE_SHA256 语义校验。

### 测试
- 新增 T10-T17 负向回归（空目标 fail-closed、路径穿越拦截、apply 原子性、`.rej/.orig` 清理、
  pc-web manifest 冻结哈希等）；T11 修复 `$var` 后跟多字节字符必须花括号（unbound 崩溃）。

## v3.15.4 (2026-08-27) — 第四轮审查收口：apply 原子性 / sync 排除集 / 参数校验同口径

> 背景：第四轮独立审查（子 agent）发现 1 P0 / 8 P1 / 7 P2，聚焦 s8b 回滚、副本同步安全性与参数校验。

### P0 修复
- **P0-1 s8b 回滚不含副本（apply 原子性破坏）**：VERIFY_FAILED 回滚源文件后，已同步成功的
  副本保留新内容、源回滚为旧内容——副本永久漂移且下次 --check 必报 DIFF。修复：回滚后强制
  `sync-copies --apply` 重同步（失败则 FAIL 并留日志 s8b-verify-rollback-resync.log）。补 T15 端到端回归。

### P1 修复
- sync-copies `--target` 缺值 fail-closed（旧实现 shift 2 失败后位置参数不变 → 死循环）；
  空目标列表 fail-closed（bash>=4.4 零循环输出 ALL OK 假绿、bash 3.2 unbound 崩溃）。补 T10/T11。
- sync-copies 排除集与 gate-skill-tree 对齐（.git/.devflow/*.bak/*.bak-devflow）——旧
  rsync --delete 会删除目标副本的 .git 历史；portable 路径 check 对 .git 误报 extra、
  apply 直接删除 .git 文件；运行产物 .devflow/ 被同步进用户副本。补 T12。
- s8b/p10 feature 名白名单校验——路径穿越（`../evil` 写穿项目外）+ grep -E 正则注入封堵。补 T13。
- s8b patch 失败/成功均清理 `.rej/.orig`（fuzz 遗留会污染树哈希并经 sync 进全部副本）。补 T14。
- client-adapter pc-web validate/build/test 补 manifest 结构 + 冻结哈希校验（与 mini-program/app
  同口径；此前 P2 冻结的 --expected-manifest-sha 对 pc-web 在 P3-P6 生命周期不生效）。补 T17。
- p10 gate 校验 s8b 应用收据：拒绝悬挂 `STATUS=APPLIED`（apply 后未跑 verify 闭环）；
  commands/retro.md 收据状态值域与实现对齐（`PROPOSED` 从未存在——契约幻觉）。补 T16。

### P2 修复
- s8b applied-manifest 截断前转存（二次 apply 丢上一轮回滚记录）；备份目录/文件名加 PID（同秒冲突）；
  `STATUS=FAILED` 也改写 VERIFY_FAILED（旧 sed 匹配不到，状态语义丢失）；LLM curl 加超时
  （--connect-timeout 10 --max-time 120，网络异常不再挂死）。
- client-adapter hash 失败诊断走 stderr（不再静默空哈希无解释）。
- audit-receipts 当前树不可得时 fail-closed（哨兵值 `__UNAVAILABLE__`，无 state 场景
  树漂移校验不再被静默跳过）。

## v3.15.3 (2026-08-27) — 第二轮审查收口：形近版本绕过封堵 / 假保护测试修复 / 文档对齐

> 背景：第二轮独立审查（子 agent）发现 2 P0 / 3 P1 / 2 P2。

### P0 修复
- **P0-1 P6-credential 版本正则转义**：`_verify_p6_credential` 的版本点号未转义
  （`3.15.2` 中 `.` 是正则通配符），形近版本 `3x15y2` 可冒充通过凭证审计——
  全链路唯一的版本校验洼地（其余 5 处均已转义）。补 T9 负向回归。
- **P0-2 T4 假保护修复**：T4 夹具的 P3cd/P4/P5 收据缺 EVIDENCE，reconcile 在
  P3cd 提前 break，P6-credential 分支从未执行——删除修复代码后 T4 依然绿。
  夹具补 EVIDENCE_PATH/SHA256，断言真正走到 P6 检查点。

### P1 修复（文档-脚本一致性）
- phases/01-技术选型.md：s1 调用签名 `<feature>` → `docs/detailed-design`（第一个参数是文档目录）
- commands/qa-check.md：run-all-checks 手动示例改为 flags 协议（旧示例传位置参数会 exit 2）；
  check-frontend-standards 签名 `<feature>` → `frontend`（参数是源码目录）
- commands/qa-check.md：产物描述改为实际行为（终端输出+退出码，不落报告文件；留档用 tee）

### P2 修复
- gen-skill-manifest.sh：版本解析失败守卫（空版本会静默产出空名 .json）
- run-all-checks.sh --only：重复 check 名去重（`n+1,n+1` 不再执行两次）

## v3.15.2 (2026-08-27) — 收据契约对齐：Gate 端补 PHASE / 基线收据除权 / reconcile 同口径

> 背景：第一轮独立审查（子 agent）实证 5 个 P0 绕过。核心根因：v3.14.6 只在 complete 端建立
> "全阶段 PHASE 契约"，Gate 生成端（s0/s1/s2）、reconcile 端、审计端均未同步，形成
> "跑真 Gate 卡死、绕过路径畅通"的系统性倒置。

### P0 修复
- **P0-1 Gate 收据补 PHASE 行**：s0/s1/s2 收据新增 `PHASE=P0/P1/P2`——此前真 Gate 收据被
  complete 的 v3.14.6 全阶段契约拒绝，而绕过路径畅通（校验倒置）
- **P0-2 基线收据除权**：complete/reconcile 拒绝 `state-init@` 前缀收据——init 自带的
  P0 基线收据（含 PHASE/当前树）此前可直接 complete P0，整体跳过 s0 验收点检查
- **P0-3 reconcile 契约对齐**：_reconcile_receipt_ok 全阶段强制 PHASE（此前仅 7 个证据阶段）；
  P6 推进必须持有有效 P6-credential 收据（提取 _verify_p6_credential 共用函数，与 complete 同口径）
- **P0-4 版本口径单一化**：audit-receipts.sh 移除 DEVFLOW_VERSION 环境覆盖——
  被审计方可设 DEVFLOW_VERSION=<旧版> 让旧版收据通过版本审计
- **P0-5 run-all-checks --only 假绿修复**：旧逻辑先清空 CHECKS 再从空数组筛选（必然零执行，
  bash 4.4+ 下 "全部 PASS" exit 0 假绿）；重写为全量副本精确筛选 + 非法名/零匹配 exit 2；
  同时修复参数解析双重 shift（--only/--no-frontend 吞后续 flag）与 PIPESTATUS 时序脆弱

### P2 修复
- gen-skill-manifest generate：管道子 shell exit 陷阱 → 进程替换 + 临时文件原子发布；
  tree_files 路径剥离改 bash 参数展开（防 sed 特殊字符）；缺失/多出清单输出修复引号

### 测试
- 新增 8 个 v3.15.2 负向/正向回归（基线收据除权、真 Gate 收据闭环、reconcile credential、
  DEVFLOW_VERSION 篡改、--only fail-closed/精确执行/参数共存）
- test-state.sh / test-v3140-regressions.sh 夹具从"基线收据 complete P0"迁移到真 Gate 收据
  （旧夹具把绕过路径固化为正常预期，测试永远发现不了该问题）

## v3.15.1 (2026-08-27) — 信任根收口：SKILL_TREE 硬门禁 / manifest 不可变 / 运行证据实质化

### P0（用户负向夹具第五波实证修复）
- **SKILL_TREE 升级为硬门禁（原 WARN → FAIL）**：`complete`/`reconcile`/`audit-receipts` 强制校验收据
  `SKILL_TREE` == state 冻结树（`scope.skill_tree_sha256`）；缺失/非法/不一致一律 BLOCKED。
  P7-P10 前置链收据与 P6-credential 收据同样受约束。**唯一放行路径**：显式迁移命令
  `devflow-state.sh migrate-tree <feature>`（写入 `SKILL-TREE-MIGRATION` 收据 FROM_TREE/TO_TREE 双向留痕，
  内部+docs 镜像双写后才更新冻结值）。
- **repair 不再覆盖冻结树 hash**：v3.15.0 的 repair 会把原冻结值静默改写为当前树（抹掉溯源）——已移除；
  树锚点变更只能走 migrate-tree。
- **init fail-closed**：树哈希计算失败即拒绝初始化（不再落 `SKILL_TREE=unknown` 收据）。
- **manifest 不可变**：`gen-skill-manifest.sh generate` 在同版本 manifest 已存在时 exit 1（禁止覆盖重写）；
  内容变更必须升版本号。manifest 从"可重写的自校验清单"变为"不可变发布记录"。
- **Release Audit 解析全部 Markdown frontmatter**：PyYAML 可用时真实解析，否则受控子集结构校验
  （key/列表项/折叠块缩进归属）；completeness-auditor.md 的 `allowed-tools:`/`paths: []` 缩进冲突
  （YAML 解析 exit 1）已被修复并纳入常驻断言。
- **/audit-completeness 只调用权威 Gate 并传播退出码**：P7/P8/P9 改为 `artifact_gate.sh` 权威入口；
  废除 `set +e`/全局 `|| true` fail-open 指导（负向夹具：P9 五文件全 MISSING 仍 exit 0）；
  修复图谱命令误把报告路径当 feature 参数。
- **P7 运行证据绑定**：`BUILD_INFO_URL` 从可选 WARN 升级为强制项，且回显必须命中本制品
  `ARTIFACT_SHA256` 前 12 位 hex 或 `DEPLOYMENT_ID` 原值——任意静态 HTTP 200 不再能通过。
- **P8 证据实质化**：metrics 须含 ≥5 条真实采样行（仅 HELP/TYPE 头不算）；`LOG_QUERY_EVIDENCE`
  查询结果文件（≥2 行）；`ALERT_RULE` 须为含 `alert:`/`expr:` 的规则文件；`ALERT_TEST_OUTPUT`
  须非空（≥20B）且含 `ALERT_TRIGGERED`/`NOTIFICATION_CONFIRMED`/`RECOVERY_RECORDED` 三要素——
  空白输出文件不再能通过。
- **P9 语义章节 + 目标哈希**：docs-index 须固化五类文档各自 `_SHA256`；每份文档须 ≥10 行、
  ≥2 标题、≥5 正文行、含类别语义关键词（用户/开发/API/运维/发布）——"标题+line1~4"占位不再通过。
- **S8 图谱响应 schema 校验**：200 响应须为含 `status`/`service` 字段的 JSON 才判可达（任意 200
  页面不算图谱服务，判 p0）；索引状态未知不再进入 PASS（p0）；fallback 证据须记录
  `FALLBACK_COMMAND/SCOPE/FILES/FINDINGS/SHA256` 五要素（一行式占位不再认可）。

### P1
- **manifest check 全量明细校验**：逐文件 SHA-256 + 文件集合比对（缺文件/多文件/哈希篡改均 FAIL）；
  generate 后自校验（JSON 合法 + 与树一致），半成品自动删除。
- **gate-skill-tree 完全 fail-closed**：任一文件读取/哈希失败 exit 1 且不产出 hash；`LC_ALL=C`
  固定字节序；`sha256sum` 回退（Linux/Git Bash 确定性）。
- **发布树清污**：删除 `artifacts/`、`docs/`（d1/demo/deploy/foo/r17/r18 测试产物）——正式 manifest
  不再固化测试垃圾；release.sh 第 7 步硬门禁：发布树内发现任何 `*.state.json` 即 FAIL，
  外部 state 经 `DEVFLOW_RELEASE_STATES` 对照（冻结树须等于发布树，否则提示 migrate-tree）。
- **sync-copies 跨平台**：目标列表支持换行分隔（Windows 盘符 `C:/` 不再被冒号拆坏，兼容 CRLF）；
  rsync 缺失时回退 find+cp 可移植同步。
- **文档元数据**：SKILL.md `updated` 与 changelog 日期对齐（2026-08-27）。
- **新增负向回归**：树篡改/缺树字段拦截、migrate-tree 迁移链放行、repair 不覆盖冻结树、
  manifest 同版本拒绝重生成/明细篡改拦截、P7 无绑定回显拦截、P8 空白/缺要素告警输出拦截、
  P9 占位文档与哈希漂移拦截、S8 一行式 fallback 拦截、frontmatter 结构损坏拦截。

### 溯源模型（v3.15.1 起）
收据 `VERSION=@版本` + `SKILL_TREE=整树hash` 双标识；state 冻结树锚点唯一变更入口 =
`migrate-tree`（显式收据留痕）；发布 manifest 不可变（同版本禁止重写）。

## v3.15.0 (2026-08-27) — 不可变 Skill 树 manifest + 正式发布本地修复批次

### 发布级修复（R24 BLOCKED 判定）
- **版本纪律违规收口**：v3.14.11 下混入的"未发布本地修复"（5 项代码修复）正式并入本版并递增 minor——同一版本号不再可能承载不同内容树。
- **不可变 Skill 树哈希**：新增 `scripts/gate-skill-tree.sh`（整树 SHA-256，排除 .backups/.devflow/.git/manifest 自引用）；`scripts/gen-skill-manifest.sh` 生成 `references/manifest/<version>.json`（文件级 hash + tree_hash）并支持 `check` 漂移校验。
- **树 hash 冻结**：init 将 `scope.skill_tree_sha256` 写入 state；全部收据新增 `SKILL_TREE=` 行；p4b WARN 详情同样溯源。audit-receipts 对 SKILL_TREE 漂移给出 WARN（skill 升级提示，不锁死旧项目）。
- **发布入口补全**：release.sh 从 4 步扩为 7 步——新增显式 ShellCheck 门（shellcheck 缺失即 FAIL）与 Manifest 生成/自校验门，并对照本地 state 冻结树 hash。

### 并入的 5 项本地修复（原 v3.14.11 未发布批次，经用户批准正式发布）
p6_credential 否定语句误报；p3b P1 计数否定排除；artifact_gate P8 告警输出否定词误报；s4 record 自引用清空防呆（-ef）；playbook-miniprogram 实战经验节。

### R25 复审修复（发布门禁稳定性）
- manifest `generated_at` 确定性化（消除每次 release 重写文件导致的 mtime 抖动）；release.sh step5 只 check 不 generate（版本定型后人工 generate + sync）
- P0 基线收据补 `SKILL_TREE=` 行；init 冻结树 hash 与 P0 收据溯源对齐
- R19 永久断言：init 冻结 == 当前树 / P0 收据含 SKILL_TREE / manifest check 只读通过（测试不再改写发布树）
- release.sh 步骤重排与编号统一（7 步）、头部版本清理、空 state 时树对照改 WARN

### 溯源模型
收据 `VERSION=@版本` + `SKILL_TREE=整树hash` 双标识——版本号标识语义版本，树 hash 标识实际内容；state 冻结生成时树 hash，发布 manifest 固化发布时整树。

## v3.14.11 (2026-08-26) — 用户负向夹具第四波：P7 阻断恢复 / 完整前置链 / P6-credential 契约 / 统一发布入口

### P0
- **完整测试即发布门禁**：新增唯一发布入口 `scripts/release.sh`（完整测试 → 版本一致性 → Release Audit → 副本对账），任一失败禁止发布；SKILL.md 停止条件已指向它。
- **P7 实时健康探测恢复强制阻断**（不可达即 p0，运行未验证不得写成完成）；BUILD_INFO_URL 声明时必须回显制品绑定的版本/哈希标识。
- **P7-P10 完整前置链检查**：P0-P6 全部阶段收据存在且 EXIT_CODE=0 + P6-credential 在链（P5-migration 依赖 B/C 场景，state 未冻结前由 audit-receipts 对已存在收据审计，记为已知限制）。
- **P6-credential 契约完整化**：EXIT_CODE/VERSION/PHASE=P6-credential/PASS FAIL WARN 格式/docs 镜像一致（镜像路径显式基于 WORKSPACE，修复 CWD≠WORKSPACE 运行时缺陷）。
- **P2b 空授权禁止**：skip 行须同时满足 理由非空 | authorized-by 非空 | at 合法时间 | approval 审批证据非空；收据记录四要素。
- **s8b 事务顺序修正**：apply → tests/release PASS → sync --apply → sync --check → STATUS=VERIFIED；任一失败回滚并标 VERIFY_FAILED（消除"必然未同步→必然回滚"死锁）。

### P1/P2
p2b PO 排除"待确认/待定/未确认/进行中"；audit-receipts 增加 state-scope 完整性（state=completed 阶段必须存在对应收据）；EVIDENCE_HARDENING 夹具按新契约重建（mkrc 双写助手、P6 笔误修正、完整链+镜像）；R15/R16 永久负向断言。

### v3.14.11 本地修复（jmmp2 项目 P10 复盘反哺，2026-08-27，未发布）

- **p6_credential 否定语句误报**：阴性声明（如"无盲猜密码"）曾命中正向盲猜正则被 P0 阻断——补否定语境行排除（jmmp2 项目实证）。
- **p3b P1 计数缺否定排除**：v3.9.6 只对 P0 做过否定排除；"P1 问题 | 4（均已闭环）"等表格统计行计入 P1 总数造成误报超限——补齐同款否定/计数语境排除。
- **artifact_gate P8 告警输出否定词误报**："无 FAIL 项"命中 FAIL 词边界正则被 P0 阻断——补否定语境排除。
- **s4 record 自引用清空**：`cat $test_report > $results` 当二者为同一文件时先截断源文件导致首轮结果被清空——补 `-ef`（同 inode）防呆。
- **playbook-miniprogram.md 补实战经验节**：纯前端项目 P3 Gate 组合（API_REQUIRED=0 + 契约模块定位）/页面逻辑测试 harness/详设冻结前 Gate 解析口径预检。
- 回归：tests/run-tests.sh 全组通过（CONTRACTS 55 / STATE 3 / CLIENTS 8 / PHASE_GATES 12 / V3140 26 / MAINTAINABILITY 30 / EVIDENCE_HARDENING 23 / REPORT_REGRESSIONS 9 / RELEASE AUDIT）；按用户批准范围仅本地修复未递增版本号（避免已冻结项目收据链版本漂移），正式发布时经 scripts/release.sh 五道门禁并入下版。

## v3.14.10 (2026-08-26) — R20 复审收口：P5/P6-credential 强制绑定 + 测试卫生

### P0 补全
- complete + reconcile `_reconcile_receipt_ok` 白名单补入 **P5**——EVIDENCE_SHA256 篡改后 complete 不再放行至 P6
- complete **P6 绑定 P6-credential 收据**：缺失、EXIT_CODE≠0、版本不匹配均拒绝完成
- **P7+ 前置收据链检查**：完成 P7-P10 时校验 P0-P3b 收据存在且 EXIT_CODE=0（替代此前 artifact_gate 内嵌 audit-receipts 的方案，避免孤立单测级联失败）
- **artifact_gate P7 实时 HEALTH_URL 探测降为 WARN**：可达+200=pass；不可达=warn 不阻断 CI（测试环境无运行实例时合法）；RELEASE_EVIDENCE 实质化 ≥20B 且含数字保持 P0 阻断

### P1/P2
p2b skip 收据补 AUTHORIZED_BY；HPID 正确捕获；/tmp/v3140-pos-out.txt 调试残留移除；R14 静态扫描排除注释行误报。

## v3.14.9 (2026-08-26) — 用户负向夹具第三波：P2b 深度强化 / skip 授权字段 / P7 SSRF 防护

### P0/P1 修复
- **p2b KUF 唯一编号计数**：重复 KUF-1 不再凑数；每唯一 KUF 校验对应 walkthrough；PO 正则排除"不通过/驳回"；移除死变量与重复 RESULT 输出。
- **skip-log 授权字段**：SKIP_P2b 行须含 authorized-by=，收据记录 SKIP_REASON 与 authorized-by；execute_gate 编排伪代码接入 check_skip_authorization 分支。
- **artifact_gate P7**：实时 HEALTH_URL 探测 + RELEASE_EVIDENCE 实质化（≥20B 且含数字）+ SSRF 防护（拒 link-local/169.254/metadata/非 http(s)）；模板补 HEALTH_URL 字段。

### 其他
领域依赖检测收窄至本 feature 文件（防跨 feature 误触发）；not-applicable 纯后端清单为占位说明且 exit 0；check-skill-usage 路径参数化；init-fact-sources 工具目录探测泛化（.claude/.codex/.cursor/.trae-cn/.agents 顺序回退）；playbook 官方来源 URL 登记；p5 warn 计数断言放宽（criteria 缺失告警合法）；test-v3140 移除 fail-site 调试残留。

### 版本纪律
本版由用户负向夹具第三波直接驱动；z 位递增按 concepts/SKILL.md §9 执行。

## v3.14.8 (2026-08-26) — R18 复审：修正 v3.14.7 虚假完成声明

> R18 实测发现下述 p5 修复在 v3.14.7 中并未落地（python 批量编辑静默失败），现真实修复并补双重回归断言。

- p5 `$CRIT）` 多字节吞噬真实修复（${CRIT} 花括号化）；R14 断言：零 M-ID 行为夹具 + scripts 静态未花括号扫描
- complete 缺 PHASE 行从宽容改为拒绝

## v3.14.7 (2026-08-26) — R17/R18 复审：complete 全阶段契约 + 版本戳动态化收尾

### P0/P1
- **complete 全阶段统一收据契约**：非证据阶段此前只查 EXIT_CODE=0，旧版本/错 PHASE 收据可越权推进（负向夹具实证）。现全部阶段校验 VERSION@当前 + PHASE 一致；R12 断言常驻。
- **reconcile 链完整性守卫补全**：--apply 与报告循环对 completed 阶段同样校验收据（P3c/d 按 P3cd 归一），链断裂拒绝推进。
- **15 处 gate 收据戳收敛为动态派生**（scripts/gate-version.sh 单一实现），消除下次 z 递增时的定时炸弹；R13 静态扫描断言常驻。

### 修复
- audit-receipts 零收据改 FAIL；p2b 实质化五重校验与 skip-log 契约落地；execute_gate 编排接入 skip 分支。

### P2
CHANGELOG 非规范顶层标题降级；artifact_gate 健康探测双 000 显示去重；tests 端口随机化。

## v3.14.6 (2026-08-26) — 用户负向夹具第二轮：6 P0 / 8 P1 / 8 P2 闭环

### P0
1. complete 全阶段统一收据契约（VERSION@当前 + PHASE 一致），旧版本/错 PHASE 收据不再越权推进
2. reconcile 链完整性守卫（completed 阶段收据无效即拒绝推进；P3c/d 归一 P3cd 校验）
3. audit-receipts 零内部收据改 FAIL（init 必产基线，空目录=证据链被删）
4. p2b Demo Gate 实质化：KUF≥3/walkthrough/原型文件实存/PO 结论/签字日期五重校验
5. skip-log.txt 跳过契约落地（p2b 原生支持 SKIPPED 收据；execute_gate 编排接入）
6. P5 缺验收点文件/无 M-ID 从 WARN 升级为拒绝放行

### 精选修复
领域清单 N-A 须附理由、证据须非空；s8b --all 永不应用 + 验证失败自动回滚备份并标 VERIFY_FAILED；P7 实时 HEALTH_URL 探测与发布证据实质化；辅助收据不再归一掩盖主收据；playbook 官方来源 URL 版本化；孤儿脚本归档；路径参数化；concepts §12 渐进披露。


## v3.14.5 (2026-08-26) — R15 复审收口：p5 warn 落地 / R11 断言 / NA 标签 / banner

第十五轮复审发现前一批修复因脚本语法错误整批未执行（虚假完成声明），逐项重新落地并即时验证：

- p5_test_cases_gate 补 warn()（此前 stderr 泄漏 command not found 且 WARN 恒 0）
- test-v3140-regressions R11：s8b patch 内容判定 BSD grep 兼容性常驻断言（真实 diff 计数 ≥1）
- gen-domain-checklist not-applicable：标签"无前端平台"、平台剧本节跳过、纯后端无信号时占位清单 exit 0（gate 不要求）
- s8b banner 移除过时 v3.9 标注
- tests 目录多字节吞噬扫描纳入终局检查（本轮新增断言自身即中招一次，已修）

## v3.14.4 (2026-08-26) — R13/R14 复审：s8b BSD grep P0 + 版本动态化收尾

### P0
- **s8b --apply 在 macOS 静默 no-op**：has_content 管道中 BSD grep 对 `^\+\+\+` 报 repetition-operator 错误（exit 2 被 `|| true` 吞掉）→ has_content 恒 0 → 所有真实 unified diff 被判"空"跳过，授权后的 skill 自修改静默失效、step_verify 全量验证成死代码。改单 awk（`[+]` 字符类规避转义），R11 回归断言常驻。

### 修复
- p5 补 warn() 函数（此前 stderr 泄漏 command not found 且不计数）
- init 基线收据版本戳动态派生（state-init@$(devflow_version)）；init success 消息同
- gen-domain-checklist not-applicable 标签改为"无前端平台"，平台剧本节正确跳过
- s8b banner 移除过时 v3.9 标注；CHANGELOG 条目顺序修正（最新在最顶）

### v3.14.0 补充：领域专项评审清单 — 领域专项评审清单（按平台/外部依赖生成针对性问题）

用户指出：评审应有领域针对性——做微信小程序就按微信规则审，依赖外部系统数据就必须先要 API 文档与字段清单。

### 新增

- **references/playbooks/** 四份领域剧本：微信小程序（类目资质/登录链路/合法域名/包体积/隐私/基础库）、APP（商店审核/IAP/推送/深链/强更）、PC Web（兼容矩阵/CSP/SEO/部署）、外部数据依赖（API 文档存在性/字段字典/鉴权/限流/降级/责任边界）。
- **scripts/gen-domain-checklist.sh**：按 state 冻结平台选择剧本；扫描需求/详设中的对接信号自动追加外部数据剧本；`--stage prd|design` 输出到对应证据路径。
- **p2a §3f / artifact_gate P0b 强制校验**：平台非 not-applicable 或检测到对接信号时，清单缺失/存在未答项/为空均 P0 阻断；全答后放行。
- **tests/test-v3140-regressions.sh R8**：缺失拦截提示、生成可全答、全答后不拦截 三断言常驻。

### 修复（复审循环 R12-R13）

- `$DC（` 多字节吞噬致 P0b 缺清单场景 exit 127（F1/P0）；pc-web 平台错挂小程序剧本（F2）；空清单绕过两 gate（F3）；同款多字节模式 ×3 清零（F4）；LC_ALL=C 字节窗漂移统一 .{0,48}（F5）。



## v3.14.2 (2026-08-26) — 领域专项评审清单 + 用户负向夹具 6 P0 修复 + 十一轮子代理审计闭环

### 新增
- **references/playbooks/** 四份领域剧本（微信小程序/APP/PC Web/外部数据依赖）+ **scripts/gen-domain-checklist.sh** 生成器；P0b 与 P2a 强制校验清单存在且无未答项；test-v3140-regressions R8 常驻断言。
- preflight-port `--expect-listening` 双模式（监控阶段端口必须监听且 owner 匹配）；monitor.md 切换新模式。

### 修复（用户负向夹具报告）
- **6 P0**：client-adapter validate/hash 不再要求 P7 制品（生命周期拆分）；reconcile 收据升级为 VERSION@当前+证据阶段 PHASE/EVIDENCE 强校验（调用处补传 phase）；devflow_feature default 回退彻底移除（无/多 state 拒绝执行）；P6 凭证 gate 三处 fail-open 转 fail-closed；init-fact-sources --force 对已有文件改候选制/标记块幂等，不再覆盖用户内容；s1/s2/s5 收据文件名对齐 complete 契约（receipt.txt）。
- **5 P1**：p5 用例结构强度 ≥2 行；s4 record 落盘 first-pass-review.tsv 且 s6 缺失即 P0；p2a 遗留=0 硬门禁 + 批准按角色签字行统计；s8b APPLIED_COUNT 仅计真实应用、STATUS 反映 FAILED、verify 跑全量测试+release-audit+副本对账；review hooks 写项目本地 .devflow/ 且 SKILL_ROOT 修正。
- **8 P2**：文档漂移清理（README P4 标签、phases/02b VERIFICATION→gate 语义、spec.md 双 File Map 对齐 P0-P10）、CHANGELOG v3.14.0 标题去重、tests 改名 test-evidence-hardening.sh、头注诚实化 ×2。

### 版本纪律
- 自本版起：任何修复/升级合入后必须递增 z 位（x.y.z → x.y.z+1），由 check-skill-version 单一事实源强制。

### v3.14.0 审计轮 5 (2026-08-26) — 三轮子代理独立复审循环（1 P0 / 13 P1 / 17 P2 闭环）

按"修复→子代理复审→再修复→再复审"循环执行至收敛。关键发现与修复：

### P0
- **checkpoint-state.sh heredoc 直插 JSON**：blocker 含引号即产生非法 JSON，下次 save 静默清空全部历史检查点。统一走 python argv 路径；feature 字段经第 8 参数传入（嵌套布局 .devflow/<f>/state.json 下 basename 方案恒错，系首版修复引入的回归，已二次修正）。

### P1（代表性项）
- s4 meta 键名错位（写 design_sha256 读 design_sha）→ 未改文件也报篡改，P4 verify 永久 FAIL
- p2a/p3b 收据缺 EXIT_CODE/VERSION/PHASE → complete P2a/P3b 死锁 + 收据审计连锁阻断（版本戳动态派生自 SKILL.md）
- build-watchdog 把管道中 grep 命中当构建结果（失败报 OK、跳过报 FAIL）→ 改真实退出码判定；收据补 VERSION/PHASE 戳
- pre-commit check() 运算符优先级错误（上轮 SC2166 修复引入）→ 相等判定恒 FAIL；--self-test 系假自测（只打印 PASS）→ 重写为真实三支判定
- execute_gate 无条件 return 0 吞掉 complete 失败 → 编排层阶段门控失效，改向上传播
- 权限检查器与生成器正则漂移（单引号 vs 双引号风格、示例行误计）→ 对齐 + xx:/{} 占位过滤 + --fix 从承诺变实现
- generate-schema-changelog Python 引号语法错误 → **产物从未生成过却恒报成功**（假成功），修复并加产物存在性校验

### P2
grep -c 双输出全库清零（含两个 review hook 零命中崩溃）、python -c 注入面 ×2、固定 /tmp 路径 ×3、acceptance/accuracy/score 数字校验、block 同秒 ID、s1/s2 FEATURE 未定义变量（收据丢 feature 目录）、devflow-state list 静默死、s6 阈值校验、audit-receipts 镜像整体缺失盲区、skill 根 9 组 fixture 残渣清理、头注宣传≠实现诚实化（entity-db/code-standards/--fix/--check-only×3）。

### 方法论沉淀
- "修复引入回归"实证 2 起（SC2166 优先级、checkpoint feature 提取）——每轮子代理均需复测上一轮修复本身
- 假自测是缺陷逃逸主因；测试夹具畸形会让反向用例空洞通过
- 收据格式契约漂移是跨脚本断裂的根因类型；版本单一事实源（SKILL.md 动态派生）是根治手段


## v3.14.0 (2026-08-26) — 评审深度契约：DF/AW 强制深挖，终结"走过场评审"

来源：用户实证反馈——P0b/P2a 评审"提出的问题不够深入，都是比较浅的"。根因：Gate 只验形式（✅ 计数/遗留词），数量配额（每人 ≥15 条）激励 nitpick 凑数，问题条目无场景链契约。

### 新增

- **评审深度方法论** `concepts/review-depth-methodology.md`：六类深挖探针（对抗走查 AW/边界枚举/状态机矩阵/跨产物一致性/决策 Why 链/数据演化）、深层发现 DF 五字段契约（触发场景/影响链/根因类别/完善建议/验证方式，缺一无效；位置必须 §x.y 锚点）、表层发现 SF 分层（≤5 条/角色不计配额）、浅层信号黑名单。
- **分层配额替代"每人 ≥15 条"**：P2a 每角色 DF ≥3、全委员会 ≥10、AW ≥3、六类探针全留痕；P0b 每角色 DF ≥1、评审团 ≥5、AW ≥2、四类探针。零发现结论必须附已核查清单+证据锚点，否则不得给 ✅。
- **PRD 评审团 subagent** `subagents/prd-review-committee.md`：业务/技术负责人/前端交互/测试开发/安全合规 5 角色各带深挖问题库（产品经理为被评审方回避）；补齐 P0b 此前只有空表格模板、无角色定义的缺口。

### 强化

- **p2a_design_review_gate.sh §3b/§3c/§3d**：机械校验 DF 块计数与五字段完整性（剥离 ``` 围栏防模板示例干扰）、AW 结果收尾有效性、探针记录存在性、"已阅/LGTM/无明显问题"直接 FAIL、SF>DF WARN。
- **artifact_gate.sh P0b**：新增 DF/AW/探针记录/歧义术语决议表/边界条件枚举校验；修复 §5 追溯计数为 0 时 `|| echo 0` 产生 `0\n0` 破坏整数比较的存量 bug。
- **模板与角色定义同步**：两个评审模板改为 DF/SF 分层结构并增加探针执行记录、AW 清单、歧义术语决议表章节。

### 修复

- **macOS awk locale 双向陷阱**：LC_ALL=C 下多字节字面量在方括号/交替分支中按字节类误匹配（`[：:]`、`(：|:)`），UTF-8 下八进制转义失效——深度校验 awk 统一强制 `LC_ALL=C` 并改用八进制转义字节比较（`\357\274\232`=：、`\343\200\200`=全角空格、`\302\247`=§）与 ASCII 字符类（`-` 置于括号首位避免 `:-]` 被解析为区间），两种 locale 行为一致。
- **评审条件逻辑反转**：首版深度检查把"字段非空才清标志"写成"字段为空才清标志"，导致格式正确的报告全部误判不完整；冒烟测试夹具（浅层/深层/空字段/非法锚点/占位符 AW 各一）全部通过后合入。

## v3.13.9 (2026-08-25) — 八项目对比分析反哺：证据链强制与 bash 多字节修复

来源：《docs/devflow-八项目产出对比分析》（code01~code03 + code0817~0822 实证）。

### 修复

- **bash 3.2 UTF-8 变量名吞噬 bug**：`$var` 未加花括号且后紧跟多字节字符（如全角冒号/逗号）时，该字符首字节被并入变量名查找，变量值静默丢失。全库 8 处加花括号修复（devflow-state-complete/core、p3_security_perf_gate）。此 bug 只影响提示文案不影响判定，但会让错误信息失真误导排障。
- **P6 收据计数造假**：收据 `PASS=1 FAIL=0 WARN=0` 为硬编码，与 CHANGELOG v3.13.7"持久化计数"声明不符。改为真实 PASS/WARN 计数（gate_pass/gate_warn 计数器），用例文档缺失计入 WARN。
- **`${FEATURE:-default}` 静默回退移除**：9 个 gate 脚本在 FEATURE 为空时会把收据写入 `.devflow/default/`（code02/code03 各混入 default 收据的根因）。全部改为 `${FEATURE:?}` fail-closed。
- **init 防 default 误初始化**：feature 名为空、字面量 `default`、含 `/` 或以 `.` 开头时拒绝初始化。

### 新增

- **reconcile 对账命令**：`devflow-state.sh reconcile <feature> [--apply]`，对账状态机与收据链漂移（code03 state 停留 P1 而收据至 P10 的教训）。默认只读报告；`--apply` 仅自动推进连续前缀（前置全 completed 且收据 EXIT_CODE=0），绝不回退或伪造；state 领先项要求人工核销。
- **audit-receipts 挂接**：此前为孤儿工具无人调用（版本混用未被发现的原因）。现由 artifact_gate 在 P7/P8/P9 强制执行；缺 VERSION 行的收据从静默跳过改为 FAIL；init 的 P0 基线收据补 `VERSION=state-init@` 版本戳。
- **反哺闭环可见性**：init 时扫描其他 feature 的 `feedback.md`，列出未处置的 PROPOSED 项并提示在 P0 澄清时请用户批准或显式 defer（code02/code03 共 9 条悬置的机制性对策）。
- **P8 文档-实测交叉核对**：monitor-config 声明 `ALERT_TESTED=PASS` 但 ALERT_TEST_OUTPUT 文件含 FAIL 时阻断（code02 告警规则 3 文档失真教训）。

### 说明

- 已实证由 v3.13.7/8 落地且无需再改：p6 凭证扫描排除 node_modules/dist/build/coverage；preflight-port.sh 以阻断方式挂接 deploy/monitor 命令；P4b WARN 独立详情文件。
- 版本戳统一升级 `@3.14.0`（verify_evidence_receipt 正则同步），避免同链双版本收据。
- 基线债务：`shellcheck -S warning` 全库仍有 ~130 条警告（SC2155/SC2034 为主，遍布核心状态机脚本），v3.13.8 即存在，本轮消除 2 条 error 级且未新增警告；留待独立一轮集中修复，避免大改核心脚本引入回归。

### v3.14.0 审计轮 4 (2026-08-25) — 第四轮深度审计（算术崩溃 / 注入面 / 输入校验）

用户第三次要求复查缺陷。本轮覆盖前三轮未深入的区域：状态机剩余命令、精度计算、LLM 归因、模板使用率统计、四方言对照，修复 6 处：

### 修复

- **check-skill-usage.sh 除法零保护**：模板目录为空或 python3 缺失/出错时 `USED_NUM/TOT_NUM` 为空 → `$(( * 100 / 0))` 语法/除零错误直接杀死脚本。加 `[ -n ] && [ TOT_NUM -gt 0 ]` 守卫，失败时 USAGE_PCT=0。
- **check-skill-usage.sh python heredoc 注入面**：`tpl_dir = "$TPL_DIR"` 是 shell 字符串插值进 python 源码——路径含引号/反斜杠即破坏脚本。改为环境变量传入（`TPL_DIR=... python3 - <<'PY'` + `os.environ`），全库同类模式已一并核查清零（checkpoint-state.sh/super-scorecard 均为带引号 heredoc + 位置参数，安全）。
- **s8b LLM 归因 jq 守卫**：`step_attribute_llm` 无 `command -v jq` 检查——jq 缺失时 `$(... | jq -Rs .)` 静默产出空 payload，发出损坏的 API 请求。补守卫并回退 `step_attribute_template`。
- **acceptance set-count/complete 数字校验**：`set-count abc` 直接进 `jq --argjson` 报原始 JSON 错误。补 `^[0-9]+$` 校验并给出可读错误。
- **accuracy/health_score 数字校验**：同上，接受 `^[0-9]+(\.[0-9]+)?$`。
- **block 同秒 ID 冲突**：`block_$(date +%Y%m%d_%H%M%S)` 同秒多次调用产生重复 id。追加 `_$$`。
- **p4 四方言对照死代码清理**：第三轮删除 `missing_in_*` 死变量后残留空 `case` 臂（oracle/postgresql 空分支），已清理；token 级集合比较为铁律 #5 的有意严格性，保留。

### 复查为安全的项（记录留证）

- s6 准确率/覆盖率、s4 准确率、s2 覆盖率除法均有 `> 0` 守卫；s6 FROZEN_COUNT=0 显式 exit 1。
- cmd_repair/client-freeze/status 的 jq 存在性检查齐全；repair 不伪造缺失评审证据（回退 P2a）。
- client-adapter hash/manifest 校验、argv 数组执行无注入；detect-platform 纯检测无副作用。
- run-tests.sh 覆盖全部测试文件（integration 链 4 个子套件 + maintainability + v3136 + report-regressions + release）。
- 三个 hooks（design-review/prd-review/gate-fail）只写项目本地 feedback，不直接修改已安装 skill。
- s8b patch 应用有备份目录 + `--authorize-apply --write` 双门禁 + `command -v patch` 检查。
- s5 场景 A 豁免直接 exit 0 不写收据（v3.13.7 设计的 B/C 辅助收据语义一致）。

### v3.14.0 审计轮 3 (2026-08-25) — 第三轮安全审计（set -e 静默终止 / 钩子假自测 / 收据路径丢失）

用户要求"再次检查 skill 是否有其他漏洞或缺陷"，按 set -e 语义、未定义变量、收据路径、临时文件安全、钩子真实性五个维度复查，修复 8 处：

### 修复

- **s1/s2 `${FEATURE}` 未定义变量**：`set -u` 下 `"$FEATURE"` 展开失败 → devflow_feature 从未执行 → 收据写入 `.devflow/gates/P1`（**丢失 feature 目录**，收据链与 audit 全部失效）。改为 `${FEATURE:-}`。
- **`devflow-state.sh list` 静默死**：`stage=$(grep '"current_stage"' ...)` 缺 `|| true`——v3.9+ 状态文件无该兼容字段时 grep 返回 1，set -e 直接杀死 list 命令。
- **p3_completion 两处 pipefail 死**：`ENTITY_COUNT`（无 entity 目录时 grep 返回 1）与 `coverage`（JaCoCo 无 LINE 计数器时，本应触发"覆盖率 0"兜底的 awk 分支永远不可达）均补 `|| true`。
- **pre-commit 钩子每次干净提交误报 FAIL**：`TODO_COUNT` 管道 grep 无匹配返回 1，`set +e` 下不致死但变量为空串，check 比较 ""≠"0" → 无 TODO 的正常提交被误报并阻塞。补 `|| true`。
- **pre-commit check() 比较逻辑优先级错误**（上轮 SC2166 修复引入）：`A || B && C` 被解析为 `(A || B) && C`，导致"相等"判定恒 FAIL。改为 `A || { B && C; }`。
- **pre-commit `--self-test` 是假自测**：只打印 PASS 即退出、不执行任何真实逻辑——这正是 check() 损坏未被发现的原因。重写为真实自测（执行 check() 三支判定：相等/空值相等/空值不等，断言 PASS=2 FAIL=1）。
- **固定 `/tmp/*.log` 路径**（p2a/p3b/build-watchdog）：并发运行互相覆盖 + 符号链接攻击面。改 mktemp + 用后即删。
- **devflow_feature.sh 内部加固**：`ls`/`basename` 无 state 文件时的失败路径补 `|| true`（防调用方 pipefail 环境下函数内死）。

### 复查为安全的项（记录留证）

- client-adapter.sh：JSON 命令以 argv 数组直接执行（无 eval/字符串拼接），占位可执行文件已拒绝（true/:/echo/replace-with-*），无命令注入面。
- commands/phases/concepts 引用的 20+ 脚本全部存在，无悬空引用。
- 无硬编码密钥/令牌；无 eval 注入点（仅测试助手的合法 eval）。
- s8b apply 流程有备份目录 + `--authorize-apply --write` 双门禁。

### v3.14.0 审计轮 2 (2026-08-25) — shellcheck 全库清零 + 暴露的 3 个真实缺陷修复

承接 v3.14.0 主条目，集中清理 shellcheck 基线债务（原记 130 条警告全部归零），并在清理过程中发现并修复 3 个此前被掩盖的真实缺陷：

### 修复（shellcheck 清理暴露的真实缺陷）

- **`super-scorecard.sh` heredoc 从未闭合**：`<<'PYEOF'` 无终止符，python 逻辑全部被吞入 heredoc 从未执行（SC1044）。补 `PYEOF` 终止。
- **`verification-template.sh` 模板变量静默丢失**：heredoc 加引号后 `${PHASE}/${FEATURE}/${DATE}` 不再替换（模板输出字面量）。恢复未引号 heredoc，仅转义内容中反引号，变量恢复替换。
- **`check-permission-consistency.sh` `--strict` 参数失效**：python heredoc 内 `${STRICT:-0}` 为字面量恒等于 "1" 比较，strict 模式从不生效。改为 bash `export STRICT` + python `os.environ.get("STRICT")`。
- **`super-scorecard.sh` 其他错误**：SC1072/SC1073（同上 heredoc）。
- **SC2155 拆分暴露的 set -e 静默终止**：`local x=$(grep ...)` 拆分后，grep 无匹配返回 1 时 `set -e` 直接杀死脚本（如旧状态文件无 `current_stage` 字段时 checkpoint 静默失败）。全部补 `|| true`（devflow-state-core/complete、p6_credential、check-arch-pitfalls、p3_completion 共 17 处）。

### 清理（纯样式）

- SC2155（80 处）`local x=$(...)` → 拆两行；SC2034（32 处）删除真死变量（h2_tables/dialect_fail/json_fail/HEADER_CHECK/CHECK_ONLY 等死 CLI 标志）；SC2044（11 处）find 循环 → while read + 进程替换；SC2164/SC2038/SC2046/SC2064/SC2166/SC2211/SC2050 各 1-2 处；SC1087（4 处）`$var[[:space:]]` grep 模式加花括号防数组下标误解析。
- `s8_graph_health_gate.sh` 移除 `--check-only` 死选项（无外部调用）。

### 说明

- 清理后 `shellcheck -S warning`（scripts/hooks/tests 全库）= 0 警告 0 错误；`release-audit.sh` 全项 PASS。
- 测试套件全绿：CONTRACTS 55 / STATE 3 / CLIENTS 8 / PHASE_GATES 12 / MAINTAINABILITY 30 / V3136 23 / REPORT_REGRESSIONS 9。

## v3.13.8 (2026-08-25) — 补齐遗留 P6 状态迁移回归证据

- 增加“已有 completed P6 + 残留 P6a-f”精确回归夹具：无有效 P6 收据时重算为 `in_progress`，有有效当前 P6 收据时保留 `completed`。
- 同步更新当前 gate、测试、文档和资源版本，继续保持 v3.13.8 一致。

## v3.13.7 (2026-08-25) — 实测产出对比中的证据闭环与状态一致性

- P5 测试用例成为主 Gate 收据；迁移证据降为 B/C 辅助收据，避免覆盖 P5。
- P6 收据持久化 PASS/FAIL/WARN 计数；凭证扫描排除 `node_modules`、构建和覆盖率目录。
- P4b WARN 写入独立详情文件并在收据中记录路径与 SHA-256；内部收据与 docs 镜像逐文件校验内容哈希。
- 状态修复会根据有效 P6 收据重算遗留 P6a-P6f；状态输出明确 `current_phase/phases` 是唯一完成来源。
- 发布/监控前增加端口占用预检，降低启动失败后才发现端口冲突的概率。

## v3.13.6 (2026-08-24) — 独立复核后的证据语义与状态迁移修复

### 修复

- P8 不再接受任意 HTTP 200，必须返回 Prometheus `# HELP/# TYPE` 内容。
- P7 发布回执必须与部署制品分离；P4 同时绑定验证证据文件和验证报告哈希。
- receipt 继续限制在 workspace 内，旧 P6a-P6f 在已有统一 P6 时也会按旧子阶段重新归一。
- 状态和路由继续收紧，防止独立复核 agent 发现的遗留状态误导。

## v3.13.5 (2026-08-24) — 独立审查后的状态和证据二次加固

### 修复

- 完成阶段前强制验证全部前置 Phase 状态，禁止直接跳到 P10；P10 完成后状态进入 COMPLETED 终态。
- receipt 证据路径限制在当前 workspace 内，状态迁移校验阶段顺序和证据哈希；旧 P6 部分完成只迁移为 in_progress。
- P7 制品、P8 监控、P4 验证证据进一步绑定真实文件和执行结果。
- 安全扫描覆盖全部 Controller，并识别非 void 返回的 Spring 写接口。

### 验证

- 独立审查 agent 复核后追加状态跳跃、证据越界、旧 P6 迁移和 Spring 映射漏检回归。

## v3.13.4 (2026-08-24) — 证据哈希、真实执行与安全扫描收口

### 修复

- Gate receipt 强制绑定 `EVIDENCE_PATH` 与 `EVIDENCE_SHA256`；P4/P7/P8/P9/P10 状态完成前会校验证据文件和哈希，P10 完成后进入 `COMPLETED` 终态。
- 旧 P6a-P6f 迁移仅在全部子阶段完成时才归一为 P6 completed；部分旧状态保留为 in_progress。
- P7 校验实际制品路径和 SHA-256；P8 实际请求 metrics endpoint 并要求告警测试输出文件；P4 验证证据必须是存在文件。
- 客户端 release evidence 必须指向实际制品；禁止 `true`、`echo`、`:` 和模板占位命令。
- 安全 Gate 按 Spring 写映射注解识别 `ResponseEntity` 等非 `void` 写接口，避免漏检未授权方法。

### 验证

- 新增收据篡改、伪制品、虚假监控端点、无权限 ResponseEntity、P10 终态和部分旧 P6 迁移回归。

## v3.13.3 (2026-08-24) — 全链状态、证据与写入边界收口

### 修复

- 状态机补齐 P2a/P2b 与统一 P6，P2 不再直接跳 P3；完成命令拒绝乱序阶段，历史 P6a-P6f 状态在 repair 时归一化。
- 新增 `p4_validation_gate.sh`、`p10_feedback_gate.sh`，P4/P10 都生成可供状态机消费的 receipt；首轮 freeze/record 明确为 P3 前/P6 证据，不再冒充 P4 Gate。
- 修复 `/devflow` 示例在 Gate 失败后丢失退出码的问题。
- P3cd 缺少 Controller、Service 或 P95 证据时阻断；不适用必须有显式 waiver。P7/P8/P9 改为机器可读的部署、监控、文档索引证据，而非关键词或数量放行。
- 小程序 manifest 必须与 `app.json.pages` 一致；所有客户端命令拒绝 `true`、`echo` 和模板占位符，并要求 release evidence。
- `sync-copies.sh` 默认只读、完整树校验；写入必须 `--apply` 且目标必须为现有 `*/skills/devflow`。`sync-to-codex.sh` 收敛为安全兼容入口。
- P10 默认只收集项目反馈；应用到已安装 skill 必须 `--apply --authorize-apply --write`。Gate fail hook 只写项目 `.devflow`，不再修改全局 changelog。
- 发布审计增加 Markdown 围栏、显式资源注册表和 pre-commit hook self-test；修复性能命令围栏与 pre-commit 裸文本/eval。

### 验证

- 新增 v3.13.3 负向回归：状态阶段、P4/P10 receipt、空 P3cd、伪 P7、manifest 漂移、占位发布命令、非法同步目标、Hook 自检和模板一致性。

## v3.13.2 (2026-08-24) — 路由收口、三端通用化与发布审计强化

### 优化

- 将 `README.md` 缩为非权威导航页，将 `commands/devflow.md` 缩为参数、顺序、Gate、跳过和恢复编排，消除与入口及 phase 文档的重复。
- 重建 `commands/ROUTING.md`：补齐 P0b/P7/P8/P9/P10 Gate、P2a 五角色，并为人工 phase/subagent/template 增加显式资源注册。
- 将单体集成测试拆为 contracts、state、client-platforms、phase-gates、release、maintainability 六组；旧单体仅保留在历史归档。
- v3.9.0-v3.9.5 迁移记录移至 `_archive/changelog-v3.9.0-v3.9.5.md`，主 changelog 只保留仍影响当前升级的版本。
- 服务路径、菜单迁移、详设/部署模板、P3 差异脚本、ER/Schema 生成器改为项目参数化，不再绑定历史业务服务。
- P5/P6 完成度自检改为客户端适配器与平台旅程证据，统一覆盖 PC Web、微信小程序和 APP。
- 清除 active shell 中 `find -path/-not -path`，修复验收点模板表头和生成器重复 shebang/裸文本。
- `release-audit.sh` 增加全部 JSON、相对 Markdown 链接、坏表格、资源注册、README 版本及 Bash 语法校验，并支持隔离 fixture 根目录。

### 验证

- 新增维护性负向 fixture，证明坏 JSON、坏链接、坏表格和未注册资源均会阻断发布。

## v3.13.1 (2026-08-24) — 运行时瘦身与历史归档

### 精简

- 退役与当前 Gate 纪律冲突的 `hooks/detect-scale.sh`；历史副本移入外部可恢复目录。
- `devflow-state-template.sh` 缩为模板生成/列举职责，不再复制旧状态机和产物哈希实现。
- 测试入口拆为 `run-tests.sh` 聚合器、`test-integration.sh` 集成 fixture、`test-release.sh` 发布审计。
- v3.8.1 及更早 changelog 历史移至 `_archive/changelog-v1-v3.8.md`；主 changelog 保留当前迁移链。
- active tree 内 `.bak` 残留迁出到 skill 外可恢复目录，降低检索和同步噪声。

### 验证

- 新增退役 hook、状态模板去重、测试拆分、历史归档和同步清单回归。

## v3.13.0 (2026-08-24) — 全链三端执行与发布审计

### 修复

- 客户端平台冻结后，P3 拒绝冲突环境变量；`required` / `web` 保持 `pc-web` 兼容归一化。
- PC Web、小程序、APP 的 `devflow-client.json` 均使用安全 argv 命令；P2 冻结哈希，P3/P4/P6/P7 校验并实际执行 build/test/release。
- P4 改为 HTTP 方法 + 路径精确对比、完整客户端页面路径对比；小程序无扩展名路由与 APP 详设页面缺失均阻断。
- P6 对所有平台客户端源码扫描硬编码密码；Build Watchdog、概念规则、默认详设模板和 P7 发布门控按平台分流。
- release-audit 新增客户端 JSON 校验、全部 Shell `bash -n` 检查和 ShellCheck 可用时的静态检查。

### 迁移

- 所有 `pc-web`、`mini-program`、`app` 项目在 P2 后必须提交并冻结 `devflow-client.json`；PC Web 也必须声明 P7 release argv。

## v3.12.1 (2026-08-24) — 默认详设模板四项设计质量下沉

### 修复

- `详细设计-模板.md` 直接加入 §2.3 设计决策记录（DDR）、§12.1 成熟组件复用、§12.2 公共服务与公共组件抽取、§13 规范遵循。
- DDR 强制记录备选、选定和理由，含 varchar(20) / varchar(30) 示例；禁止“经验/习惯/常用”式理由。
- 默认规范基线显式覆盖命名、开发、注释、数据库和客户端规范；默认使用《阿里巴巴 Java 开发手册》，偏离项关联 DDR。

### 验证

- `tests/run-tests.sh` 新增默认模板四项章节回归，避免 P2 默认模板与 P2a gate 再次分叉。

## v3.12.0 (2026-08-24) — 三端门控可信闭环

### 修复

- `concepts/SKILL.md` 改为官方可校验的嵌套 skill frontmatter；release-audit 同时读取顶层或 metadata 中的版本。
- P3 以状态文件为客户端范围权威源，拒绝冲突的 `FRONTEND_SCOPE` 环境变量；菜单 seed 由实际 `SERVICE` 定位。
- `client-adapter.sh` 的 manifest 改为 `commands.build/test/release` argv 数组；新增 `hash` 与 `release` 动作，PC Web build/test 也会执行真实 npm 生命周期。
- `client-freeze` 在 P2 后冻结小程序/APP manifest 哈希；P3、P4、P6、P7 在执行前核验哈希。
- P4 API 对比改为 HTTP 方法 + 路径；客户端页面改为完整规范化路径，小程序支持无扩展名路由，APP 页面从详设而非实现 manifest 读取。
- Build Watchdog 按冻结平台执行 PC Web、小程序、APP 或纯后端路径；状态产物哈希包含客户端目录和 `.wxml/.wxss/.dart/.swift/.kt/.json` 等文件。
- 移除测试模板的硬编码密码，并将监控模板改为服务/端口参数化。

### 验证

- 新增对抗性回归：环境范围绕过、PC build 失败、manifest release、冻结哈希、P4 精确路径/方法、嵌套 skill 合规。

## v3.11.0 (2026-08-24) — 三端客户端平台适配

### 新增

- 客户端范围升级为 `pc-web`、`mini-program`、`app`、`not-applicable`；保留 `required` / `web` 作为 PC Web 兼容别名。
- `init` / `repair` 支持 `--frontend-dir=<path>`，将平台与客户端根目录冻结在状态文件中。
- 新增 `client-adapter.sh`：PC Web 复用 npm/Vue 规则；小程序校验 `app.json`、页面与 manifest；APP 从 manifest 校验构建、测试、页面和发布命令。
- 新增 `templates/devflow-client.md` 与 `devflow-client.json` 示例；小程序和 APP 的构建、测试、页面清单、发布命令必须显式声明。
- P3 按平台运行构建/测试；P4 按平台发现页面；P6/P7 文档增加模拟器/真机、预览上传、客户端版本产物等证据要求。

### 验证

- `tests/run-tests.sh` 增加 mini-program 与 APP fixture、平台范围状态、PC Web 兼容别名和同步清单回归。

## v3.10.0 (2026-08-24) — 六项目实测后的范围与迁移修复

### 修复

- 前端范围改为状态机显式契约：`init <feature> --frontend=required|not-applicable`；默认 `required`，纯后端必须显式声明 `not-applicable`，P3 门控据此执行或跳过前端检查。
- 新增 `devflow-state.sh repair <feature> [--frontend=...]`：仅当历史状态含空 phase、P3c/P3d 已完成且 P3cd 收据 `EXIT_CODE=0` 时移除空键；拒绝不充分证据下的状态写入。
- 新增 `audit-receipts.sh`：按规范化阶段和 `EXIT_CODE` 对比内部收据与文档镜像，不再以 `receipt.txt` 文件数量代替闭环判断。
- 新增 `release-audit.sh`：发布前检查 active tree 的 frontmatter 版本一致性及已废弃旧 skill 名称/路径残留。
- 将 active tree 的 frontmatter 统一到 v3.10.0，并清理已废弃路径引用。

### 验证

- `tests/run-tests.sh` 增加纯后端范围、初始化冻结范围、历史状态 repair、release audit 与收据审计入口的回归断言。

## v3.9.9 (2026-08-24) — 跨文件契约回归修复

### 修复

- `SKILL.md`：改为 Codex 可解析的 frontmatter；版本与兼容性移入 `metadata`，description 使用 `Use when` 触发语义。
- `devflow-state.sh complete P3cd`：保留 `P3c` / `P3d` 两个原子状态，复合 gate 成功时同时完成两者并推进到 `P4`，不再创建 `P3cd` 或空字符串状态键。
- `commands/test.md`：`record` 示例补齐必填的 per-ID 结果 TSV 与 review report 参数。
- `详细设计-模板.md`：接口表统一为 `方法 | 路径 | 接口名称 | ...`，与 `p4_prd_vs_code.sh` 解析器一致。
- `部署记录-模板.md`：以 `PORT` 动态解析服务端口，并增加本地启动前端口占用预检；去除固定 `8086`。
- `check-frontend-standards.sh`：前端存在时要求 `package.json` 的 `scripts.test` 与至少一个 `*.test.*` / `*.spec.*` 文件；P3 只校验契约，P6 执行实际测试。

### 回归

- `tests/run-tests.sh` 增加上述 frontmatter、P3cd 状态推进、record 参数、模板解析、动态端口和前端测试契约检查。

## v3.9.8 (2026-08-21) — 详设表结构删两列（七列 → 五列）

> **背景**：用户决定详设表结构不再包含"老系统来源"和"迁移转换规则"两列。
> 合理性：迁移场景 B/C 的字段级映射本就有专属载体——`docs/数据映射/<feature>-映射.md` 八列映射表
> （P2 迁移 Gate `s3_migration_mapping_gate.sh` 检查），详设里那两列是同一信息两处维护的冗余。
> 删列后职责分离：**详设专注新系统设计，映射文档承载迁移**。

### 变更清单
- `templates/详细设计-完整版-模板.md`：§2.2 两张示例表七列→五列（字段名/类型/约束/默认值/口径说明），加职责分离说明；其余详设模板（目录/摘要/总分分/总分总）本无此表，未动
- `scripts/s2_design_coverage_gate.sh`：§4 检查七列表头→五列表头；仍带旧七列表头的存量产物给 WARN（迁移信息移至 docs/数据映射/ 的升级提示）
- `scripts/p4_prd_vs_code.sh`：parse_design_fields 表头定位正则改五列（前五列位置不变，字段名解析兼容新旧两代表头）
- `scripts/check-skill-usage.sh`：§4 详设格式合规的表头正则同步五列
- 文档文字引用：spec.md 完成定义表、PRD实施方法论.md（阶段表+原则1）、design-review.md、phases/02a 角色职责——"七列"→"五列"，并注明迁移信息去向
- `tests/run-tests.sh`：两处 foo-design fixture 表改五列；**版本断言改为动态读 SKILL.md**（根治"升版本漏改测试断言"——v3.9.7 即漏改，本次 FAIL 暴露后修复）
- code0822 存量产物同步升级：3 张表 15 个数据行删两列

### 验证
- code0822 升级后全链复跑：s2 / p2a / p4b 全部 exit 0（p4b 字段解析 8 个字段正常）
- 回归 54/54 全绿

---

### 2026-08-22 实战教训（m-01 复盘写回）

> 来源：code01 M-01 基础能力模块 P0→P10 全链复盘（docs/retrospectives/m-01-retro.md）。
> 8 条教训中 5 条可归因 skill 本身（GATE/FLOW/TPL），3 条为工程基线沉淀。

| # | 教训 | 归因 | 处置状态 |
|---|------|------|----------|
| 1 | `p3_completion_gate.sh` 在 `set -euo pipefail` 下，`find` 不存在的 `views/<feature>` 目录使 NEW_PAGES 赋值行退出码=1 → 脚本静默中断（无 P3 RESULT 输出、exit=1，无任何 FAIL 提示，排查成本高） | GATE | ✅ 已修复：该行加 `\|\| true`；sync-copies 三副本同步 |
| 2 | s4 freeze 在详设未最终稳定时执行，后续修订详设导致 s6 design_sha256 完整性校验失败，只能删快照重 freeze | FLOW | 登记：建议 freeze 前检查详设 mtime 提示"详设近期有修改，确认冻结？" |
| 3 | s4 record 的 <test-report> 实参期望 per-ID TSV（id\tPASS），但 usage/文档未写明格式；传 Markdown 报告时解析 pass=0 → accuracy=0% | PRMT | ✅ 已修复：usage() 增补 `<test-report>` 为 per-ID TSV（列：acceptance_id<TAB>status，status ∈ {PASS,FAIL,SKIP}）格式说明 |
| 4 | p6_credential_gate 凭证表要求 `| 用户名` 列表头 + `V[0-9].*__seed.*user` 来源模式，未声明 → 首轮 FAIL | GATE | 登记：gate 失败时应输出期望格式样例 |
| 5 | p4_prd_vs_code §2 接口解析要求"HTTP 方法在行首"（`\| GET \| /path \|`），而详设模板 §3.1 示例是"序号/名称/方法/路径"——模板与 gate 不一致 | TPL | ✅ 已修复：模板 §3.1 接口表列序改为 `方法 \| 路径 \| 接口名称 \| 权限`（方法在第一列），并加表头约定注释 |
| 6 | `devflow-state.sh complete` 阶段名正则 `^P[0-9]+[a-z]?$` 不接受 "P3cd"，与主执行表中的 "P3cd" 命名不一致 | GATE | ✅ 已修复：正则放宽为 `^P[0-9]+[a-z]{0,2}$`，错误提示同步更新为"应为 P0, P3, P3b, P3cd 等" |
| 7 | Spring Boot 3.4/Spring 6.2 下 `@PathVariable` 无显式名时必须 `-parameters` 编译参数，否则运行期 500（编译期无感） | DOMAIN | ✅ 工程基线：父 pom 固定 `<parameters>true</parameters>` |
| 8 | 本地常用端口（8080/18080）被其他实例占用导致启动失败误判为应用缺陷 | FLOW | 登记：部署记录模板应含"端口占用预检"步骤 |

### 本批修复验证

- 教训 1 修复后 p3_completion_gate 复跑 exit=0（PASS=14）；`tests/run-tests.sh` 回归复跑确认无破坏。
- 教训 2/3 处理链路（删快照→重 freeze→record per-ID TSV）已验证 s6 exit=0（accuracy 100%）。
- 教训 3/5/6 补丁本轮应用：usage 增 TSV 格式说明、模板 §3.1 方法行首、state 正则放宽；待回归 + gate 复跑确认。

---

## v3.9.7 (2026-08-21) — P2a 加 DBA 角色 + 详设设计质量四要素

> **背景**：用户提出详设评审缺 DBA 视角，且详设普遍缺四类工程化内容：有成熟组件不用而自研、公共能力不抽取登记（同一工具类被写 N 遍）、规范无基线（命名/开发/注释各写各的）、设计只有结论没有理由（varchar(20) 还是 varchar(30) 说不出依据）。

### 变更 1：P2a 评审 4 角色 → 5 角色（+DBA）
- `scripts/p2a_design_review_gate.sh`：角色检查加 `DBA|数据库管理员`，approvals 门槛 4→5；新增 §2b 详设设计质量四要素检查（组件复用/公共抽取/规范遵循/DDR 关键词，缺任一 P0）
- `commands/devflow.md` / `commands/design-review.md` / `phases/02a-详细设计评审.md`：角色表 +DBA（职责：DDR 逐行核问、字段类型长度依据、索引策略、四方言一致性），通过条件表同步
- 注：`concepts/design-review-process.md` 的角色矩阵与评审报告模板旧统计表本就有 DBA 字样——但从未进入可执行链路（又一例"文档有、流程没有"），本次对齐

### 变更 2：详设模板加三章节 + DDR 子节
- `templates/详细设计-完整版-模板.md`：
  - **§2.3 设计决策记录（DDR）**：非平凡决策必须写"备选方案 + 选定 + 理由"；理由须有业务口径/规范引用/量化数据，"经验/习惯/常用"不通过（含 varchar(20) vs (30) 示例）
  - **§12 组件复用与公共抽取**：12.1 成熟组件复用清单（有轮子禁止自研，自研须附调研结论）；12.2 公共服务/组件抽取登记（≥2 消费方必须抽取，产出/消费双向登记）
  - **§13 规范遵循**：规范基线显性声明（默认《阿里巴巴 Java 开发手册》，可替换但禁止无规范）+ 本设计落点 + 偏离项
  - 原 §12 变更历史 → §14（s2 gate 前缀匹配兼容存量产物）
- `templates/详细设计评审报告-模板.md`：评审委员会统一为 5 角色（原为业务/架构/DBA/开发/BPM 另一套，与 gate 检查不一致——code0822 实验中 agent 自行补段才通过，本次根治）；新增四要素检查表 + DBA 对 DDR 的逐行核问表

### 验证
- 双向冒烟：code0822 存量产物跑新 p2a gate → FAIL（缺 DBA 段 + 四要素，符合预期拦截）；补齐后 → PASS（19 PASS / approvals=34 / exit 0）
- code0822 产物同步升级为规范示范：详设补 5 条真实 DDR（varchar(100) 依据 PRD 硬约束、text 四方言一致性、tinyint vs 状态机表等）、6 项组件复用清单（含 owasp-java-html-sanitizer 替代自写正则转义）、2 项公共抽取登记、阿里规范基线声明
- 回归 54/54 全绿（+5 条防回退断言：gate 检 DBA/四要素、模板含 §12/DDR/DBA）
- s2 模板对齐对 code0822 新结构 PASS（存量 §12 变更历史 与新 §14 前缀兼容验证通过）

---

## v3.9.6 (2026-08-21) — 死链清理 + S 编号残留全清

> **背景**：v3.9.5 完成执行引擎单轨化后，全 skill 仍残留 35 个文件中的旧 S0-S8 阶段描述（表格/流程图/脚本文案/收据路径），且存在一批无有效引用的死链文件。本次彻底清理。

### 清理 6：第三轮审计——空转阶段补齐 + 收据全覆盖 + 复盘模板收敛（同日）

- **空转自动 PASS 洞（严重 · v3.9.5 自引入）**：`execute_gate` 对无脚本阶段（P0b/P7/P8/P9）只 echo 一句就 `return 0`——主循环遍历时这 4 个阶段**必然自动放行**，而 P7/P8/P9 正是实测 4 项目中 3 个跳过的部署/监控/文档阶段（"孤儿脚本"问题的镜像：有脚本没人调 → 没脚本的自动过）。修复：新增 `scripts/artifact_gate.sh`（P0b 评审报告+遗留=0 / P7 部署记录+日期 / P8 监控三件套要素 / P9 五份用户文档，含收据双写），get_gate_script 17 项全覆盖映射，空映射改为报错。冒烟：空项目 4 阶段全 FAIL、补产物后全 PASS
- **收据覆盖缺口**：17 个 gate 中仅 7 个写收据。本轮补齐 p3_completion（P3）、p3_security_perf（P3cd）、p4_prd_vs_code（P4b）、p6_credential（P6-credential）、s6（P6，含 FAIL 路径）五个；build-watchdog gate 模式（P3-build）补 docs 镜像且 FAIL 收据带上 BLOCKER_DETAIL。至此 17 个 gate 全部落收据
- **复盘报告模板向实践收敛**（首轮分析遗留建议落地）：实测三份复盘（code0819/0820/0821）自发形成"阶段合规检查→教训→评分"结构且无人按旧模板写。新增三段：`P0-P10 阶段执行合规检查`（17 行收据路径表 + 执行率，禁止无证据 ✅）、`反哺写回记录`（grep 证据 + sync-copies 结果）、`复核命令输出`（防自评失真，针对 code0821 声称"模板已对齐"实未对齐的教训）
- 审计器 check-skill-usage 实跑验证可用（空项目 PASS=0 FAIL=2 WARN=6 合理）

### 清理 5：P3 编译链实测 + 测试掩盖效应消除 + 多副本同步闭环（同日 · 遗留项收尾）

- **build-watchdog 三模式首次实测**（最小 Maven 工程，正反双路径）：`check` 正确版 exit 0 + checkpoint 联动记录；错误版 exit 1 + 精确定位 `Foo.java:[3,35] 找不到符号`；`gate` FAIL/PASS 收据双态正确。顺手修复：blocker 此前只记 "see stdout above"，具体编译错误已捕获在 BLAME 却未传入——现在 checkpoint blocker 精确记录失败原因（中断恢复无需翻 stdout）
- **run-tests P6 fixture 改走真实链路**：删掉手工构造 baseline/results/meta 的段落，改为 `freeze → record → s6` 真实调用——正是手工 fixture 掩盖了 record 不写 results_sha256、格式与 s6 不对齐两个交接 bug（清理 4 项）。回归 49/49 全绿
- **新增 `scripts/sync-copies.sh` + retro 步骤 4 挂接**：反哺只写调用方副本、多副本靠手动同步的问题（code0820 规则孤岛教训）落地为自动化——rsync --delete（排除备份/归档）+ md5 校验，`--check` 只读模式；retro.md 步骤 4 现在是"写回 CHANGELOG → grep 验证 → sync-copies 同步"三连
- 实测：sync-copies 首跑即修复了此前手动 cp 的遗漏（--delete 清掉目标侧陈旧文件），6 个关键文件三副本 md5 一致

### 清理 4：第二轮实战走查发现的 6 个 bug（同日 · 全链模拟驱动）

> 在临时工程中按 main() 顺序真实走 P0→P10，逐 gate 补产物验证，暴露以下问题（均已修复并复测）：

- **P4→P6 交接断裂 ×2（严重）**：① `s4 record` 从不写 `results_sha256` 进 meta.env，而 `s6` 防篡改校验读它——首轮准确率 gate **永远报 "tampering detected"**；② record 写统计汇总格式、s6 读 per-ID 明细格式，格式从未对齐——"result IDs differ / accuracy 0%" 永远 FAIL。run-tests 的 P6 fixture 手工构造了正确数据，恰好掩盖了这两个 bug。修复：record 写 per-ID results.tsv + stats.env + meta 补 sha；实测 freeze→record→s6 全链 PASS（11 PASS / 0 P0 / exit 0）
- **bash 3.2 多字节炸点（7 处）**：macOS 自带 bash 3.2 在 `$var` 后紧跟全角标点（`；` `（`）时把 UTF-8 首字节吞进变量名 → set -u 报 unbound / 非 -u 时变量静默展开为空。p2b 实测炸、p2a 失败路径炸。修复：全部改 `${var}` 花括号形式（python 字节级批量替换，p2a/p2b/check-frontend-standards/init-fact-sources/p6_credential 5 个文件 7 处），复扫 0 残留
- **usage 退出码错误 ×2**：`p3_security_perf_gate.sh` 与 `s8b_feedback_gate.sh` 的 usage() 硬编码 `exit 0`——无参调用被 main() 误判为 gate PASS（s8b 即 P10 反哺 gate，空跑=反哺闭环被绕过）。修复：exit 2
- **retro 反哺检查形同虚设（逻辑漏洞）**：`grep -c 当日日期 ≥ 1` 会被当天已有的版本发布条目命中（实测当日已有 12 处），agent 什么都不写也 PASS。修复：检查收紧为 `grep -cE "^## 当日日期 实战教训（.*复盘写回）"`——必须匹配带标记的写回标题行；实测 0→写→1→删→0 精确检测
- **p3b 否定语句误报**："无 P0 级问题"被关键词启发式计为发现 1 个 P0 问题（agent 写阴性声明反而 FAIL）。修复：计数时排除含否定词的行
- 修复过程中曾引入 s4 `fi}` 语法笔误，当即修正

### 清理 3：实战走查发现的 5 个运行时 bug（同日 · 冒烟测试驱动）
- **state 链 no-op（严重）**：`devflow-state-{core,complete,template}.sh` 仅有函数定义无入口分发，`init/complete-stage/checkpoint/resume` 等全部命令静默空转 exit 0（state.json 永不落盘，原则 10 中断恢复实际失效）。修复：三个子脚本补入口 case（dispatch 转发含子命令故先 shift）；complete/template source core 复用公共函数（core 入口加 `BASH_SOURCE=$0` 守卫防 source 时误执行）；实测 init→complete-stage→checkpoint→list→generate 全链通过，且 complete 自带收据校验
- **p2b_demo_gate.sh 双 bug**：顶层 `local`（非法）+ `$local_count` 未定义（set -u 下炸）+ 无参无 usage + 无收据。重写：usage、正常校验、收据双写
- **s3_migration_mapping_gate.sh set -u 炸点**：`[ -n "$1" ]` 在 A 场景/省略 source-count 时报 unbound variable。改为 `${1:-}`
- **hook 注释误导**：after-gate-fail-hook 注释硬编码 ~/.cursor（实际是相对定位写调用方副本），已更正并注明多副本需手动同步
- **回归套件年久失修**：run-tests.sh 7 个 FAIL（版本断言硬编码 3.8.1、500 词限制、指向拆分前文件、fixture 未跟上 v3.9.1 模板对齐检查）。全部更新，**49/49 全绿**

### 清理 1：删除 11 个死链文件（引用分析确认）
| 已删除 | 原引用状态 |
|--------|------------|
| `QUICK.md` / `QUICK-REFERENCE.md` | 仅被 SKILL.md 废弃声明与孤儿脚本引用 |
| `scripts/check-skill-coherence.sh` | 仅被 CHANGELOG 历史条目引用 |
| `references/AUDIT-v3.9.4.md` | 仅被 README 引用（历史审计报告） |
| `references/best-practices.md` / `language-adapters.md` / `scale-modes.md` | 全 skill 零引用 |
| `phases/03c-安全审计.md` / `03d-性能审计.md` | 零引用（P3c/P3d 由 commands/security.md、performance.md 覆盖） |
| `phases/规范-详细设计.md` | 仅被 CHANGELOG 历史条目引用 |
| `tests/pressure-scenarios.md` | 零引用（run-tests.sh 未使用） |

### 清理 2：S 编号残留全清（约 30 个文件）
- **文档**：SKILL.md / devflow.md / spec.md / build.md / test.md / audit-completeness.md / audit-pitfalls.md / init-fact-sources.md / devflow-state.md / README.md / indexes.md / design-review-process.md / PRD实施方法论.md / natural-language-triggers.md / principles-detailed.md / phases 8 个文件，全部按单轨映射替换（S0→P0、S1→P1、S2→P2、S3→P2 迁移、S4→P3/P4、S5→P5、S6→P6、S7→P6 全量、S8→图谱健康、S8b→P10）
- **脚本文案**：s0-s8b 共 9 个 gate 脚本的标题/输出/收据路径（"S0 GATE: PASS"→"P0 GATE: PASS"；`.devflow/S1-gates`→`.devflow/<feature>/gates/P1`；`VERSION=s1@3.9.1`→`VERSION=p1@3.9.6`）+ devflow-state 系列 + p2a/p4 + hooks + checkpoint-state + tests/run-tests.sh
- **死链修正**：6 处 `phases/S*.md` 引用改为实际存在的数字编号文件；spec.md 的 `commands/demo.md` 坏引用改为 `phases/02b-原型Demo.md`；`p2_design_review_gate.sh` → `p2a_design_review_gate.sh`（3 处笔误）；`commands/test-run.md` → `commands/test.md`；`phases/11-Postmortem.md` → `commands/postmortem.md`；`check-arch-pitfalls.md` → `.sh`；删除对不存在的 `check-exchange-contract.sh`、`generate-review-report.sh`、`templates/问题追踪-模板.md` 的引用
- **保留**：脚本文件名（`s0_acceptance_gate.sh` 等历史标识符）、本 CHANGELOG 的历史条目、`.bak-*` 备份、SKILL.md 中的已删除文件声明列表

### 破坏性变更
- gate 输出前缀由 `S0-S8` 改为 `P0-P10`（外部若 grep "S0 GATE" 需改为 "P0 GATE"）
- 收据路径由 `.devflow/S1-gates` 等改为 `.devflow/<feature>/gates/P1` 等
- `complete-s <S-stage>` 命令统一为 `complete-stage <P-stage>`

---

更早历史：v3.9.0-v3.9.5 与 v1-v3.8 迁移记录已随 `_archive/` 移除（v3.23.0 瘦身），如需追溯见 git 历史。
