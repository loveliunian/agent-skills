# devflow 经验与教训库（Lessons Learned）

> **版本**: v1.2.0  
> **最后更新**: 2026-09-17  
> **来源**: detailed-design-v2 与 governance（M-01/M-02 治理模块）实施复盘  
> **适用**: 所有使用 devflow 进行 PRD→生产交付的项目

---

## 使用说明

本文档记录 devflow 实施过程中积累的**可复现经验**与**已验证教训**。每条记录包含：
- **问题描述**：具体现象
- **影响范围**：哪些阶段/产物受影响
- **根因分析**：为什么会发生
- **解决方案**：如何修复或规避
- **预防措施**：如何在未来项目中提前避免

---

## 一、设计阶段（P0-P2）

### L-P0-001: 权限码双口径应在 P0b 拦截，不应等到 P2a

**问题描述**：
PRD 中定义的权限码与 `docs/详细设计/_权限矩阵.md` 事实源不一致，在 P2a 五角色评审（前端专家）才发现。

**影响范围**：
- P0 需求澄清未覆盖权限码对账
- P0b PRD 评审未检查权限事实源一致性
- P2a 前端评审发现 DF-19 (P1)

**根因分析**：
P0 `s0_acceptance_gate.sh` 和 P0b gate 未包含"权限码与权限矩阵对账"检查项。

**解决方案**：
P2a 评审后修订 PRD 与权限矩阵，确保双口径一致。

**预防措施**：
1. P0 阶段增加权限码对账检查项（添加到 `s0_acceptance_gate.sh`）
2. P0b PRD 评审增加"权限事实源一致性"探针
3. 项目模板增加 `_权限矩阵.md` 作为强制产物

**适用 Gate**: P0, P0b

---

### L-P2-001: 跨模板视图必须独立文件，禁止硬链接

**问题描述**：
详设 v2.1.1 使用硬链接别名，生成器写入聚合投影时覆盖了分文档详设，导致部分内容丢失。

**影响范围**：
- P2 详细设计文档完整性受损
- 需通过同源旧版 + 确定性修订重放重建

**根因分析**：
硬链接别名 + 自动生成器写入 = 双向覆盖。文件系统硬链接共享 inode，任何一侧写入都会影响另一侧。

**解决方案**：
强制隔离：分文档详设（`治理服务-详细设计-v2.md`）与聚合投影（`detailed-design-v2-design-mono.md`）必须是独立文件，禁止硬链接或符号链接。

**预防措施**：
1. P2 模板明确说明：跨模板视图必须独立文件
2. `s2_design_coverage_gate.sh` 增加硬链接检测（`stat -f "%i" file1 file2` 检查 inode）
3. 生成器脚本在写入前检查目标文件是否为硬链接

**适用 Gate**: P2

---

### L-P2-002: P2a 五角色评审是最高 ROI 阶段

**问题描述**：
P2a 五角色评审（架构/后端/前端/测试/DBA）在编码前拦截 43 个设计缺陷（2 P0 + 24 P1 + 17 P2）。

**关键发现**：
- DF-24 (P0)：相似度扫描无触发入口——状态机矛盾
- DF-33 (P0)：表结构对账发现 12 处实体字段无对应表列、13 处表列无对应 Mapper
- DF-01 (P1)：outbox_event 无订阅者维度，双消费者补拉语义缺失
- DF-09 (P1)：相似候选无处置接口，状态机矛盾

**影响范围**：
如果未在 P2a 拦截直接进入编码，将造成大量返工（估计返工成本 = P2a 评审成本 × 5-10 倍）。

**根因分析**：
独立评审 Agent 按角色专业视角穿透设计，能发现单一开发者视角的盲点。

**解决方案**：
P2a 是**必做阶段**，不可跳过或形式化。

**预防措施**：
1. P2a 评审必须使用独立 Agent（禁止开发者自评）
2. 五角色必须跑完主责探针（见 `review-depth-methodology.md`）
3. 每条 DF 必须由原评审人复核确认修复有效
4. P2a gate 检查"DF 闭环率 = 100%"

**适用 Gate**: P2a

---

### L-P2-003: 表结构对账必须在 P2 冻结前完成

**问题描述**：
表结构定义（Entity 字段）与 Flyway 迁移脚本（CREATE TABLE）双重脱节，P2a DBA 评审发现 12E+13W（12 处实体字段无对应表列、13 处表列无对应 Mapper）。

**影响范围**：
- P2 详设字段级覆盖率虚高（Entity 定义了但表没有）
- P3 编码后集成测试会报 SQL 错误

**根因分析**：
P2 `s2_design_coverage_gate.sh` 只检查章节完整性，未检查 Entity ↔ Flyway 一致性。

**解决方案**：
P2a DBA 评审手工对账并修复。

**预防措施**：
1. P2 gate 增加表结构对账检查（调用 `scripts/generate-er-index.sh` 自动对账）
2. P2 模板增加"Entity ↔ Flyway 一致性"自检清单
3. P3 编码前强制要求 Flyway 迁移脚本与 Entity 一一对应

**适用 Gate**: P2, P2a

---

### L-P2-004: 可空外键参与复合唯一索引存在 NULL 陷阱，必须用哨兵值

**问题描述**：
复合唯一索引 `uk_ref_active(source_version_id, target_element_id, relation_type, field_id)` 中 field_id 可空——PG/Oracle/H2 的 NULL 不参与唯一性判定，非字段级边（field_id 为 NULL）可重复插入 ACTIVE 边，绕过"同源同目标同关系唯一"规则。

**影响范围**：
- 重复 ACTIVE 逻辑边入库 → 台账与闭包遍历重复计数
- 删除保护与发布清单漂移

**根因分析**：
SQL 标准中 NULL 与任何值的比较为 UNKNOWN，不触发唯一约束冲突；四方言行为一致地"放行"重复行。

**解决方案**：
`field_id BIGINT NOT NULL DEFAULT 0` 哨兵（0=非字段级），四方言复合唯一语义一致（governance 项目 gov_reference.uk_ref_active，P2a DBA 评审 DF-05 发现并回写设计）。

**预防措施**：
1. P2/P2a DBA 探针必查"可空列是否参与复合唯一索引"
2. 设计语义上"无值"一律用确定性哨兵而非 NULL
3. 集成测试锁定：同键重复插入必须 409

**适用 Gate**: P2, P2a

---

### L-P2-005: 规则的前置操作必须反向可达——"先停用才可删除"却没有停用契约

**问题描述**：
治理服务详设 R6 规则要求"要素先停用（DISABLED）才可删除"、错误码 ELEMENT_NOT_DISABLED 与前端"提供停用快捷入口"均依赖要素停用操作，但 `PATCH /api/elements/{type}/{id}/toggle` 端点**只有接口概览表一行、无字段级契约**（无请求/响应表、无并发/审计语义）。同类的相似规则启停（§5.3.13）、回收策略启停（§5.3.42）都有完整契约，唯独最基础的要素启停是断的。开发到"删除被 409 拒绝→前端调停用"时只能猜。

**影响范围**：
- 规则前置操作无契约 → 实现靠猜，状态机/并发/权限行为各写各的
- 删除链路（最敏感操作）的闭环在设计评审后仍断裂

**根因分析**：
1. 全部 Gate（s2/df_validate/design.json）与五角色两轮评审都只做**正向追溯**：验收点→接口→响应表。27 个验收点里没有独立的"要素停用"行为，toggle 不在 §5.3 详定义节内，没有任何检查要求它存在。
2. 缺少**反向可达性**检查：从规则/错误码文本（"先 X 才可 Y""未 X 返回 409"）反推 X 操作必须有端点且有字段级契约。
3. 跨域对称盲区：评审看了相似规则启停，没回头比对要素启停。

**解决方案**：
1. 设计补契约：§5.3.3 扩为「删除与启停要素」，补 toggle 请求/响应表（targetStatus/expectedStatus CAS）与启停语义（不改版本、停用后不可被新引用/不参与扫描/不进合并、内置可启停不可删）；§4.7/§4.8 同步下沉停用过滤。
2. 机械防线：`scripts/rule_operation_closure.py`（s2 §6b 调用）——从规则表提取"先 X/未 X 返回"前置操作，有 design.json 时强校验必须命中详定义 api（仅概览行=FAIL），并排除跨域误匹配（要素停用≠启停相似规则）。
3. 评审方法论：review-depth-methodology 探针 P4b「前置操作反向可达性」列为必做。
4. 校验要点：依赖句式必须保守（避免名词性提及误报）；强前置与弱前置分级；负向验证（删契约必须 FAIL）。

**预防措施**：
1. P2a 评委（后端主责）逐条规则反问："这条规则引用的每个操作，在接口章有字段级契约吗？"
2. s2 §6b 作为 P2 硬 Gate（有 design.json 时 P0）
3. 补丁式新增端点时，同步检查规则/错误码引用的对称操作是否也有同密度契约

**适用 Gate**: P2, P2a

---

### L-P2-006: 详设重写会丢机制——旧设计/PRD 的机制与必填项必须做承接核对

**问题描述**：
治理服务详设从 v1（archive/M-02、M-03）重写为 v2 时，**序列号分配器整体丢失**：旧设计的 `generateSequence`（Redis 原子自增 `INCR gov:code-rule:seq:<type>:<date>`、TTL 24h、DB MAX 校准、`FOR UPDATE` 降级、9 位补零）在 v2 只剩"逐段解析"一句；多节点新建要素在 `uk_element_code` 下必然撞号。同类：PRD 明确"相似度阈值（必填 0~100）"而 v2 表结构与接口契约均无 threshold 字段（DF-58）、PRD"名称唯一"无落地（DF-65）。五角色两轮评审 + 全部机械门禁零拦截。

**影响范围**：
- 核心算法/并发安全机制静默消失 → 上线即撞码/整批导入失败
- PRD 必填项在验收矩阵外"蒸发" → 无法验收、实现各写各的

**根因分析**：
1. 全部门禁为"声明一致性"（design.json↔文档）与正向追溯（验收点→接口→响应表），**没有任何检查做"PRD/旧设计 ⊇ 新设计"的集合核对**；
2. 重写（v1→v2）是最容易丢东西的操作，但评审员默认"新文档自洽即可"，不主动翻 archive 对照（前两轮实证）。

**解决方案**：
`scripts/content_sufficiency_probes.py field-drift`（s2 §6c 调用）：
- 判据=**机制语义词**（序列号/幂等键/指数退避/FOR UPDATE 等，出现于设计文档自身引用的 archive）在新文档缺失即 FAIL；方法名仅作同域佐证；
- PRD 必填措辞差集仅 WARN（别名误报高，人工核对）；
- legacy 输入=设计文档自身 `archive/` 引用（精确到模块，防无关归档误报）。

**预防措施**：
1. 重写/大版本重构详设时，必跑 field-drift 并逐项登记"承接 / 移交 / 废弃（DDR）"；
2. 评审探针 P4c 加入"旧设计机制清单逐项核对"；
3. PRD 必填项在 §9 追溯矩阵的"数据字段/设计规则"列必须可指认。

**适用 Gate**: P2, P2a

---

### L-P2-007: 状态机交叉穷举——声明的每个状态值都必须有进入/退出路径

**问题描述**：
治理服务 §2.3 声明的状态枚举在 §3/§4 无转移语义（PARSED/INACTIVE 实测死状态）；更隐蔽的是**跨表状态组合**：候选终态（REJECTED/SKIPPED）被合并链路强制回写 MERGED（违反 R12 终态机，DF-61）；要素 DISABLED 删除→恢复后的启停态未定义（DF-64）；恢复与物理清除并发无 CAS（DF-63）。两轮评审仅在单表内推演状态机，未做跨表组合。

**影响范围**：
- 状态机不可信（终态被跳变）→ 候选/台账数据语义错误
- 测试无法写确定性断言（恢复后啥状态？）

**根因分析**：
探针 P3 只要求"列出所有状态转移+异常"，未要求：①每个枚举值都必须被引用（死状态检测）；②跨表状态组合（要素 status × 边 status × bin status）显式穷举合法/非法组合。

**解决方案**：
`content_sufficiency_probes.py state-matrix`（s2 §6c）：默认死状态 WARN、`--strict` 升 P0；提供 `design.json.state_machines`（fields + valid_combos）时做笛卡尔积缺口 P0。修复示例：R7 回写限 PENDING/APPROVED、恢复保持 DISABLED 并写明正交性。

**预防措施**：
1. P3 探针补"跨表状态组合矩阵"；每个 status 值 grep 出至少一条进入/退出描述；
2. 任何"链路回写状态"必须显式列出允许的源状态集合（防跨终态覆盖）。

**适用 Gate**: P2, P2a

---

### L-P2-008: 跨文档契约必须双边对账——jobKey/内部端点/权限码

**问题描述**：
治理服务 §5.4 声明 `gov_similarity_scan` 等 jobKey 与 `/internal/inspection/trigger` 端点，但运行管理分文档只登记了 2.5 个键（DF-60：扫描 jobKey 缺失、recycle 键无触发方法）；内部端点用 `/api` 前缀违反平台 `/internal/**` 网关约定（DF-67）；死信端点权限码文档内两处自相矛盾（DF-68）；deprecate 前置判定在对端无数据来源。同类问题在第一轮 DF-03（jobKey 单边声明）已出现过一次——**修复不彻底会复发**。

**影响范围**：
- 调度链路断（扫描永不触发）、网关鉴权错配（401 或暴露）
- 权限 seed 无法落地（两套码）

**根因分析**：
跨文档一致性靠人工自觉，无机械对账；且"修复一轮后"新契约仍在增加（如 SIMILARITY_SCAN 枚举），旧对账点未覆盖新键。

**解决方案**：
`content_sufficiency_probes.py cross-doc`（s2 §6c）：①作业上下文行内全部 `gov_*` 键必须在对端文档命中（本地调度键可显式豁免"不经 HTTP"）；②作业触发目标 `/internal/` 端点对端必须承接；③权限码与 `_权限矩阵.md` 差集=0（废弃行/DDR 新增登记码除外）。发现目录用 realpath 解析设计真身（防 symlink/陈旧副本污染）。

**预防措施**：
1. 任何跨服务声明（jobKey/内部端点/回调）合入时双边同 PR 登记；
2. 每个枚举值扩展（如新增 issueSource）必须同步检查对端作业表；
3. P4c 探针抽查跨文档对账清单。

**适用 Gate**: P2, P2a

---

## 二、实施阶段（P3-P4）

### L-P3-001: MockMvc 全绿 ≠ 真实容器可用

**问题描述**：
105 个 MockMvc 单元/集成测试全绿，但真实容器启动后发现：
1. Schema 漂移：`test-schema.sql` 与 Flyway 迁移不同步
2. 静态资源 404 被全局异常处理器转为 500
3. 探活接口 fail-open（未先探活直接扫描，服务未就绪时返回误导性成功）

**影响范围**：
- P4 阶段真实容器冒烟测试才暴露问题
- 增加了一轮修复成本（估计 +30min）

**根因分析**：
MockMvc 使用 H2 内存库 + Spring 测试上下文，绕过了真实容器的启动逻辑、资源加载、健康检查等。

**解决方案**：
P4 阶段强制要求真实容器 E2E 冒烟（19 项验证全通过）。

**预防措施**：
1. **P3 验证基线必须包含真实运行**（至少一次 `java -jar` 启动验证）
2. P3 gate 增加"真实容器启动 + health 200"检查项
3. 测试基建与生产 schema 同源（禁止维护独立的 `test-schema.sql`）
4. P4 冒烟测试清单必须包含：启动日志无 ERROR、health 端点、静态资源、业务 API

**适用 Gate**: P3, P4

---

### L-P3-002: P3b 代码审查必须独立角色

**问题描述**：
P3b 代码审查使用独立 `code-reviewer-agent-01`，发现 1 个 P0（回收站恢复未复活对象）+ 6 个 P1。

**关键发现**：
- P0-001：回收站恢复未清 `recycled_at`、无快照重建，恢复后要素仍 404（违反 M-01-F10-A01）
- P1-002：delete 检查非原子（检查与删除分两个事务）
- P1-003：分页 Oracle 不兼容（LIMIT/OFFSET 语法）
- P1-006：API 认证通道缺失（dev-privileged=true 绕过认证）

**影响范围**：
如果开发者自评，很可能漏过这些问题（尤其是 P0-001 的复活语义）。

**根因分析**：
开发者视角易受"功能实现了"的确认偏差影响，忽略边界情况与状态一致性。

**解决方案**：
P3b 必须使用独立 Agent 或独立开发者审查（禁止自评）。

**预防措施**：
1. P3b gate 检查 `DEVELOPER_ID ≠ REVIEWER_ID`
2. P3b 审查清单必须包含"恢复/删除/合并"等状态转移场景
3. P3b 必须逐一验证 27 验收点的实现语义正确性

**适用 Gate**: P3b

---

### L-P3-003: P3c/P3d 安全+性能审计不可省略

**问题描述**：
P3cd 合并执行（MODE=full），产出合并报告 `.devflow/detailed-design-v2/p3-security-perf-report.md`，但未分别产出独立的 `*-安全审计报告.md` 和 `*-性能审计报告.md`。

**影响范围**：
- 无法独立追溯安全审计过程
- 无法独立追溯性能审计过程（N+1 查询检测、慢查询分析等）

**根因分析**：
P3cd gate 设计为合并执行以减少重复扫描，但未强制分别产出独立报告。

**解决方案**：
虽然合并执行，但应分别产出两份独立报告文件。

**预防措施**：
1. P3cd gate 修改为：即使 MODE=full，也必须产出两份独立报告
2. P3c 报告必须包含：@PreAuthorize 覆盖率、SQL 注入检测、敏感信息泄露检测
3. P3d 报告必须包含：N+1 查询检测、慢查询分析、P95 响应时间实测

**适用 Gate**: P3c, P3d

**机检**: 已由结构化产物层覆盖——security.json / performance.json 各自绑定独立渲染报告（df_pipeline security/performance，v3.25.2），合并报告仅为 Gate 汇总。

---

### L-P3-004: JSON 禁止手工字符串拼接，统一 ObjectMapper/ObjectNode

**问题描述**：
`snapshotForRecycle` 用字符串拼接 elementName/elementCode 构造回收快照 JSON，要素名称含双引号或反斜杠时快照 JSON 非法，恢复时 `objectMapper.readTree` 抛 SNAPSHOT_INVALID（P3b 高优问题）。

**影响范围**：
- 回收站恢复路径（本轮有兜底：解析失败不删原件，可重试）

**根因分析**：
手工拼接把"值"当"语法"处理，未做转义——数据驱动注入的 JSON 版本。

**解决方案**：
统一注入 ObjectMapper，用 ObjectNode 构造（与 SnapshotCodec 一致）。本轮因输入侧已有符号/编码段白名单，处置为"风险接受 + SNAPSHOT_INVALID 兜底验证"并登记触发条件。

**预防措施**：
1. P3b 代码审查必查"字符串拼接 JSON/SQL"模式
2. 架构陷阱检查增加"手工 JSON 拼接"检测
3. 无法立即修复时必须验证兜底路径并登记触发条件（见 L-PROC-004）

**机检**: `checks/check-arch-pitfalls.sh` §6 `check_code_json_concat`（warn 启发式，v3.26.3）

**适用 Gate**: P3, P3b

---

### L-P3-005: 前端严格模式要求 0 个超长 SFC，长 script 抽 composable

**问题描述**：
5 个 >200 行 script 的 SFC 导致前端严格模式检查（0 WARN）不可达，P3b 一轮重构后才达标。

**影响范围**：
- P3 完成门槛与前端整洁度冲突，欠账后补成本高

**根因分析**：
页面级逻辑持续累积未抽取，检查项引入时已欠账。

**解决方案**：
抽 composable（如 elementLibraryPageState.ts 等 5 文件），严格模式 FAIL=0 WARN=0。

**预防措施**：
1. P3 编码期持续保持"0 个 >200 行 SFC"作为完成门槛的一部分，而非 P3b 补课
2. Element Plus 表格行类型显式 interface 标注（勿依赖 DefaultRow）
3. `client-adapter validate pc-web --strict` 纳入 P3-build Gate

**适用 Gate**: P3, P3b

---

### L-P4-001: PRD-vs-Code Gate 必须透传模板模式

**问题描述**：
`p4_prd_vs_code.sh` 内嵌调用 `s2_design_coverage_gate.sh` 时未透传 `--mode` 参数，导致 monolith 章节检查对分文档详设误报"缺少关键章节"。

**影响范围**：
项目被迫构建独立的完整版聚合投影文档 `detailed-design-v2-design-mono.md` (2390 行) 以满足跨模板 Gate。

**根因分析**：
devflow skill 脚本 `p4_prd_vs_code.sh` 在 v3.20.4 版本尚未支持 --mode 透传。

**解决方案**：
本轮以"聚合投影文档 + migrate-tree 重放收据"在项目侧收敛。

**预防措施**：
1. **skill 维护者**：p4_prd_vs_code.sh 增加 `--mode` 透传支持（v3.21+ 修复）
2. **项目侧**：如遇此问题，构建聚合投影文档作为临时解决方案
3. 在 FB-20260915-governance-p4b-monolith 中已记录为 defer 项

**适用 Gate**: P4b

**Feedback ID**: FB-20260915-governance-p4b-monolith

---

## 三、测试阶段（P5-P6）

### L-P6-001: 真实容器 E2E 必须在 P6 执行

**问题描述**：
P6 测试执行阶段强制要求真实容器 E2E（19 项验证全通过），拦截了 P3 MockMvc 无法发现的问题。

**影响范围**：
- Schema 漂移
- 静态资源 500
- 探活 fail-open

**根因分析**：
MockMvc 单测无法覆盖真实容器的启动逻辑、资源加载、健康检查等。

**解决方案**：
P6 gate 强制要求真实容器 E2E 冒烟证据（curl 日志 + 退出码）。

**预防措施**：
1. P6 gate 增加"真实容器 E2E 证据路径"检查项
2. E2E 冒烟清单必须包含：启动日志、health 端点、静态资源、业务 API、认证/授权
3. P6 不能只跑单元测试就声称"测试通过"

**适用 Gate**: P6

---

### L-P6-002: 终验证据必须由受信测试运行器现场产出

**问题描述**：
终验五类证据（unit/integration/client/load/staging）在 P6 临时拼装，verification.json 生成时间（03:40Z）早于真实执行（06:44Z），触发反陈旧校验；手写证据报告极易被 Gate 判为陈旧/占位证据。

**影响范围**：
- P6/P6-final 多轮返工
- 证据可信度存疑

**根因分析**：
证据骨架未随实现规划，事后补造与反自报三重校验（命令是受信运行器、报告本轮变化、报告非占位词）天然冲突。

**解决方案**：
新增 P6EvidenceTest，由 JUnit 在真实执行时写出三份含时间戳的证据报告——天然满足三重校验（governance 项目实践）。

**预防措施**：
1. P3 实现时就按终验证据结构规划报告生成方式（由测试运行器产出而非手写）
2. 双退出码（DECLARED vs ACTUAL）+ 可执行文件/日志/报告三级 SHA-256 指纹
3. 豁免显式声明（EXEMPT/declared 字段），杜绝静默跳过

**适用 Gate**: P3, P6, P6-final

**Feedback ID**: FB-GOV-20260916-02

---

## 四、工具与基础设施

### L-TOOL-001: Skill Tree 漂移需原子恢复

**问题描述**：
skill 目录被外部同步进程（iCloud/Dropbox/.cursor 自动更新）更新后，SKILL_TREE SHA256 校验会令全部历史 gate receipt 失配，需 migrate-tree + 全链重跑收据才能通过审计。

**影响范围**：
- P2a 阶段曾触发一次 SKILL_TREE 漂移
- 需执行 `gate-skill-tree.sh migrate` 并重跑 P0-P2a 所有 gate

**根因分析**：
devflow skill 版本管理机制要求严格一致性，但外部同步（如 iCloud/Dropbox/.cursor 自动更新）会破坏这一假设。

**解决方案**：
在同步稳定窗口内原子完成"migrate→gate→complete→audit"四步骤。

**预防措施**：
1. **skill 维护者**：提供批量收据刷新命令（自动化 migrate + 全链 gate 重跑）
2. **项目侧**：在 SKILL_TREE 漂移时，立即执行：
   ```bash
   scripts/gate-skill-tree.sh migrate
   # 重跑全部 gate
   scripts/devflow-state.sh audit
   ```
3. 将 `.cursor/skills/devflow` 加入 .gitignore，避免 Git 同步引发漂移
4. 使用 devflow 期间关闭 iCloud/Dropbox 自动同步

**适用场景**: 任何阶段的 SKILL_TREE 校验失败

---

### L-TOOL-002: macOS BSD awk 与 GNU awk 的 gsub 差异

**问题描述**：
macOS BSD awk 对被 `gsub` 修改的字段会触发 `$0` 重建（分隔符替换为 OFS），导致依赖 markdown 表格逐列提取的 gate 脚本解析失败。

**影响范围**：
- 任何使用 awk 解析 markdown 表格的 gate 脚本（如 `p4_prd_vs_code.sh`）

**根因分析**：
BSD awk 实现细节：`gsub($n, ...)` 会标记字段为 dirty，触发 `$0` 从各字段重建，此时使用 OFS（默认空格）而非原始分隔符。

**解决方案**：
以无空格表格行规避（markdown 表格 `|` 前后不留空格）。

**预防措施**：
1. Gate 脚本在解析 markdown 表格前先 `gsub(/[[:space:]]*\|[[:space:]]*/, "|")` 规范化
2. 或使用 Python/jq 代替 awk 解析复杂表格
3. 在 CI 环境安装 GNU awk (`brew install gawk`)

**适用场景**: 任何使用 awk 解析 markdown 的脚本

---

### L-TOOL-003: `set -u` 脚本中 echo 调试语句需后置

**问题描述**：
`set -u` 脚本中插入的 `echo $BASE` 会在 BASE 定义前触发 `unbound variable` 错误。

**影响范围**：
- 自动化注入日志行时可能触发脚本中断

**根因分析**：
`set -u` 使得任何未定义变量的引用都会报错并退出。

**解决方案**：
自动化注入日志行时需置于变量定义之后。

**预防措施**：
1. Gate 脚本模板在变量定义区域后增加 `# DEBUG LOG INJECTION POINT` 注释
2. 或使用 `${BASE:-}` 默认值语法规避
3. 日志注入工具检查插入位置是否在变量定义之后

**适用场景**: 所有 `set -u` 的 shell 脚本

---

### L-TOOL-004: 冻结副本必须验证物理独立性（符号链接陷阱）

**问题描述**：
`cp` 复制 skill 副本得到的是符号链接而非实体目录，收据树哈希随规范目录实时漂移，导致 6 轮 Gate 重跑（P2a 评审会话 02→07）；会话 02 还暴露无 attestation 的预制报告被哈希链识破。

**影响范围**：
- 全部哈希绑定类 Gate 无法对齐
- 流程时间被证据链问题消耗（评审内容本身一次通过）

**根因分析**：
复制工具在部分环境默认符号链接语义；并行进程可能实时改写规范目录，未做物理独立性与稳定性验证。

**解决方案**：
`cp -RL` 解引用复制物理副本；`ls -la` 确认非符号链接；对副本连续两次计算树哈希确认稳定后，统一从该副本跑全部 Gate。

**预防措施**：
1. 任何"副本/冻结"操作后立即验证：物理独立（非符号链接）+ 双采样哈希稳定
2. 评审收据两阶段签名（begin 于报告产出前、complete 绑定产物 SHA）强制化
3. Gate 重跑时先做根因分类（见 L-PROC-003），证据链失效不应通过改内容解决

**适用场景**: 任何涉及树哈希/收据绑定校验的 Gate

**Feedback ID**: FB-GOV-20260916-02

---

### L-TOOL-005: 评审收据必须双向绑定输入/输出 SHA

**问题描述**：
评审会话 04 中输入设计文档 SHA 已变更，但输出报告 SHA 与会话 03 相同——输出未随输入重新生成，输入/输出绑定失效。

**影响范围**：
- 评审结论可能基于旧版输入
- 收据无法证明"本报告对应本设计版本"

**根因分析**：
complete 收据未强制校验"输入 SHA 变化时输出必须变化"。

**预防措施**：
1. complete 收据绑定"输入产物 SHA + 输出报告 SHA"二元组；输入变化而输出未变即拒绝
2. attestation 两阶段签名（begin 于产出前、complete 于聚合报告冻结后）强制化
3. 复审每轮使用新 REVIEW_SESSION_ID

**适用 Gate**: P0b, P2a, P3b

---

## 五、监控与可观测性

### L-MON-001: build-watchdog 必须留痕

**问题描述**：
devflow 规范要求 P3 编码阶段每次写完代码自动触发 `build-watchdog.sh check`，但 detailed-design-v2 实施中未找到 build-watchdog 执行记录。

**影响范围**：
- 无法证明"写完即编译"的持续验证
- 无法追溯编译错误的修复历史

**根因分析**：
build-watchdog 可能未纳入 P3 gate 强制检查项。

**解决方案**：
事后无法补救（执行日志已丢失）。

**预防措施**：
1. **skill 维护者**：将 build-watchdog 纳入 P3 gate 强制检查项
2. **项目侧**：P3 编码时手动记录每次 `mvn compile` / `npm run build` 的退出码
3. build-watchdog 输出必须保存到 `.devflow/<feature>/build-watchdog.log`

**机检**: `scripts/build-watchdog.sh` gate 模式输出留痕 `.devflow/<feature>/build-watchdog.log`（v3.26.3）

**适用 Gate**: P3

---

### L-MON-002: checkpoint-state 必须记录中断恢复点

**问题描述**：
devflow 规范要求每次 Gate 跑完后 + 会话中断前执行 `checkpoint-state.sh`，但 detailed-design-v2 实施中只有 state.json 包含 6 个 checkpoint，缺少对应的 checkpoint-state.sh 执行日志。

**影响范围**：
- 无法追溯每个 checkpoint 的触发时机与保存内容
- 会话中断后恢复时缺少上下文

**根因分析**：
checkpoint-state.sh 可能未强制输出日志文件。

**解决方案**：
事后无法补救（执行日志已丢失）。

**预防措施**：
1. **skill 维护者**：checkpoint-state.sh 强制输出到 `.devflow/<feature>/checkpoints/<id>.log`
2. **项目侧**：每次手动 checkpoint 时记录当前阶段、待办事项、阻塞原因
3. Gate 完成后自动触发 checkpoint-state.sh

**机检**: `scripts/checkpoint-state.sh` save 落独立日志 `checkpoints/<id>.log`（v3.26.3）

**适用场景**: 任何阶段的 Gate 完成后

---

### L-MON-003: orphans-detector 必须定期执行

**问题描述**：
devflow 规范要求任何 P 阶段完成后执行 `checkpoint-state.sh orphans` 检测孤岛产物，但 detailed-design-v2 实施中未找到孤岛检测报告。

**影响范围**：
- 无法证明 docs/ 和代码之间没有孤岛产物
- 可能存在未被引用的文档或代码

**根因分析**：
orphans-detector 可能未纳入任何 gate 强制检查项。

**解决方案**：
事后可执行 `checkpoint-state.sh orphans` 补充检测。

**预防措施**：
1. **skill 维护者**：将 orphans-detector 纳入 P6/P10 gate 强制检查项
2. **项目侧**：P6 测试完成后、P10 复盘前各执行一次 orphans-detector
3. 孤岛检测报告必须保存到 `.devflow/<feature>/orphans-report.txt`

**机检**: `scripts/p10_feedback_gate.sh` 强制运行 orphans 检测并归档报告（关键产物缺失即 FAIL，v3.26.3）

**适用 Gate**: P6, P10

---

### L-MON-004: P7/P8 部署与监控证据必须来自真实容器

**问题描述**：
MockMvc/单测无法证明"在线实例即该制品"。governance P7/P8 以 build-info 回显制品 SHA 前缀 + 停服→000→重启→200 告警闭环演练（留时间戳）作为证据。

**影响范围**：
- 制品-实例一致性可验证
- 告警链路真实闭环

**根因分析**：
部署证据的本质是"运行中的实例 = 构建产物"，只有实例自证身份（回显制品标识）才能成立。

**预防措施**：
1. P3 即暴露 build-info 端点（含制品 SHA 前缀），P7 部署后 curl 回显比对
2. 告警规则必须做停服→000→重启→200 闭环演练并留存时间戳
3. 真实 Prometheus 采样，不用 Mock 指标

**适用 Gate**: P7, P8

---

### L-MON-005: standalone 交付的多实例化前置项必须登记发布说明

**问题描述**：
standalone 决议遗留的多实例障碍（进程内扫描锁、CORS 通配、巡检逐条校验）若不显式登记，多实例化时会以事故形式重现。

**影响范围**：
- 横向扩容前的改造清单缺失

**根因分析**：
边界决议的代价若无跟踪载体，会随项目结束丢失。

**预防措施**：
1. P0/P2 的 standalone 决议逐项列出"多实例化前必须完成"清单
2. 登记进发布说明并排期跟踪（触发条件：多实例化前）
3. P10 复盘核对该清单是否仍然有效

**适用 Gate**: P9, P10

---

## 六、流程与协作

### L-PROC-001: P2b Demo 签收不可形式化

**问题描述**：
P2b gate 耗时 0 秒（started_at = completed_at），Demo 签收单存在但无演示截图/视频/运行日志。

**影响范围**：
- 无法证明利益相关方真实看过并签收了 Demo
- 复杂交互（如流程引擎、动态表单）的可行性未验证

**根因分析**：
P2b 可能被视为可选阶段（详设已包含足够细节时跳过实际 Demo）。

**解决方案**：
对于复杂交互场景，P2b 应强制要求可运行 Demo + 利益相关方签收截图。

**预防措施**：
1. **skill 维护者**：P2b gate 增加"Demo 运行截图/视频"强制产物检查
2. **项目侧**：P2b 签收单必须包含：Demo 运行截图、利益相关方签名、关键交互流程演示
3. 对于 CRUD 类简单功能，P2b 可简化为"设计评审通过"即可

**适用 Gate**: P2b

---

### L-PROC-002: 修复→复审闭环必须严格执行

**问题描述**：
P2a 五角色评审发现 43 个 DF，修订后每条 DF 由原评审人复核确认修复有效，未出现"改了就算过"。

**影响范围**：
- 确保修复真正解决了问题（而非表面应付）
- 防止修复引入新问题

**根因分析**：
严格的修复→复审闭环是质量保证的核心。

**解决方案**：
P2a 修订后，每条 DF 必须由原评审人复核并签字确认。

**预防措施**：
1. P2a gate 检查"DF 闭环率 = 100%"
2. DF 修复必须包含：修复内容、测试证据、原评审人复核签字
3. 禁止批量关闭 DF（每条必须逐一复核）

**适用 Gate**: P2a, P3b

---

### L-PROC-003: Gate 重跑必须先做根因分类

**问题描述**：
governance 项目 P2a 评审 6 轮重跑（会话 02→07），评审结论（DF/AW/边界枚举/五角色结论）内容完全稳定——重跑根因 100% 是证据链工程问题（符号链接副本、attestation 缺失、终验证据临时拼装），不是内容不合格。

**影响范围**：
- 若误判为内容问题去改内容，只会浪费轮次并引入不必要变更

**根因分析**：
缺少"重跑原因分类"步骤：内容不合格（返工产物）与证据链失效（修复证据工程）处置路径完全不同。

**解决方案**：
先归因再行动：内容不合格→修订产物重跑；证据链失效→修复证据基础设施（物理副本、受信运行器、SHA 绑定）后重跑。

**预防措施**：
1. Gate 重跑前回答三问：这次 FAIL 的检查项是什么？内容变了吗？证据基础设施变了吗？
2. 把"Gate 重跑根因分类占比"纳入 P10 复盘指标
3. 证据链失效修复优先级：物理独立性 → 受信运行器 → 收据绑定

**适用 Gate**: 全部

---

### L-PROC-004: 风险接受必须带兜底验证与触发条件登记

**问题描述**：
governance P3b 高优-2（回收快照 JSON 拼接）选择"风险接受"，同时验证了恢复路径 SNAPSHOT_INVALID 兜底且不删除原件；P2 中优 4 项（多实例锁/CORS/巡检 N+1/模板外置）全部登记 Owner 与触发条件（"多实例化前/数据量达阈值时/下次迭代"）。

**影响范围**：
- 非阻断问题不丢失、不假装不存在
- 触发条件明确，避免"永远排不上"

**根因分析**：
灰色决策若不显式登记，事后无法追溯风险决策依据。

**预防措施**：
1. 风险接受三要素：兜底验证证据 + Owner + 触发条件（写进"未修复问题汇总"）
2. "设计如此"的误报关闭时补注释留痕，防后人误改
3. 多实例化前置项登记进发布说明并排期跟踪（见 L-MON-005）

**适用 Gate**: P3b, P4, P9

---

## 七、技术栈特定经验

### L-STACK-001: Oracle LIMIT 1 兼容性

**问题描述**：
10 处 `.last("LIMIT 1")` 在 Oracle 下不兼容，需改为 `FETCH FIRST 1 ROWS ONLY`。

**影响范围**：
- 四方言（h2/postgresql/oracle/kingbase）一致性破坏
- Oracle 环境下 SQL 报错

**根因分析**：
MyBatis-Plus `.last("LIMIT 1")` 直接拼接 SQL，不做方言转换。

**解决方案**：
使用 `MpPageUtils.resolveDialect()` 按 JDBC URL 推断方言，拼接对应语法。

**预防措施**：
1. P2 详设增加"四方言一致性"检查清单
2. P3 编码前封装方言适配工具类（如 `SqlDialectUtils.limit1()`）
3. P3b 代码审查必须检查 `.last()` 使用是否跨方言兼容

**机检**: `checks/check-arch-pitfalls.sh` §6 `check_code_last_limit`（critical，v3.26.3）

**适用场景**: 任何使用 MyBatis-Plus 的项目

---

### L-STACK-002: 认证通道必须在 P3 完成

**问题描述**：
P3 编码时使用 `dev-privileged=true` 绕过认证，P3b 代码审查才发现 API 认证通道缺失（P1-006）。

**影响范围**：
- 生产部署时无法使用（必须 `dev-privileged=false`）
- 认证/授权逻辑缺失

**根因分析**：
开发期为了快速验证功能，临时绕过认证，忘记回填真实认证逻辑。

**解决方案**：
P3b 修复后新增 `ApiHeaderAuthenticationFilter` 消费网关注入头，`dev-privileged` 缺省 true / 生产 false 匿名 403。

**预防措施**：
1. P2 详设必须包含"认证/授权方案"章节
2. P3 编码时即使使用 `dev-privileged=true`，也必须同时实现真实认证逻辑
3. P3b 代码审查必须检查"生产环境认证可用性"
4. P7 部署清单强制检查 `dev-privileged=false`

**机检**: `scripts/artifact_gate.sh` P7 `DEV_PRIVILEGED` 声明行（production=true 即 P0，v3.26.3）

**适用 Gate**: P3, P3b, P7

---

### L-STACK-003: Spring 同类自调用使 @Transactional 静默失效

**问题描述**：
OutboxDispatcher.dispatch() 同类内直接调用 tryDeliver()，Spring AOP 代理对自调用不生效，方法上的 @Transactional 被静默绕过——租约抢占与投递状态落库非原子。"注解看起来正确但事务从未开启"，P3b 才发现（P0 阻断）。

**影响范围**：
- 进程在两次 update 间崩溃时，事件停留在"已租约锁定但状态未推进"窗口
- audit.afterCommit 在无事务上下文下行为漂移

**根因分析**：
Spring 声明式事务基于代理实现，this 调用不经过代理。

**解决方案**：
注入 TransactionTemplate，以 executeWithoutResult 显式包裹每次投递，异常在调度层捕获记录；移除无效的方法级注解。修复后 mvn test 全量 82 用例回归通过。

**预防措施**：
1. P3b 审查必查"注解方法是否仅被 this 调用"
2. 修复优先 TransactionTemplate 显式边界或拆分为独立 Bean
3. Outbox/租约类"抢占+状态推进"必须同事务

**机检**: `checks/check-arch-pitfalls.sh` §6 `check_code_transactional_self_invoke`（critical，v3.26.3）

**适用 Gate**: P3, P3b

**Feedback ID**: FB-GOV-20260916-01

---

### L-STACK-004: 令牌/密钥比较必须常量化，安全清单覆盖"比较方式"

**问题描述**：
内部服务令牌使用 String.equals 短路比较，存在理论时序侧信道（P1）；此前安全审计清单未把"令牌比较方式"列为必查项。

**影响范围**：
- 服务间认证通道（InternalTokenFilter）

**解决方案**：
改用 `MessageDigest.isEqual(Utf8.encode(...))` 常量时间比较。

**预防措施**：
1. 安全清单必查项扩展：令牌/密钥比较常量化、JWT 密钥启动校验长度并 fail-fast、登录失败不区分账号是否存在（防用户枚举）
2. P3c 安全审计增加"比较方式"静态检查

**机检**: `scripts/p3_security_perf_gate.sh` §6 `check_token_comparison`（warn，v3.26.3）

**适用 Gate**: P3b, P3c

---

## 八、复盘与反馈

### L-RETRO-001: P10 教训必须写入项目本地 feedback queue

**问题描述**：
P10 复盘发现的工具改进建议（如 FB-20260915-governance-p4b-monolith）必须先写入项目本地 `.devflow/<feature>/feedback/`，不能直接修改已安装 skill。

**影响范围**：
- 铁律 9：修改已安装 skill 必须获得用户明确批准
- 跨项目经验沉淀

**根因分析**：
已安装 skill 是全局共享资源，单个项目不应擅自修改。

**解决方案**：
P10 复盘将工具改进建议记录为 FB（feedback），决策为 `defer`，建议随 skill 下版本交付。

**预防措施**：
1. P10 gate 检查 feedback queue 是否包含"上次遗漏了什么"
2. Skill 维护者定期从各项目 feedback queue 中提取共性问题
3. 项目侧遇到 skill 问题时，先记录 FB，再决定是 `defer` 还是 `escalate`

**适用 Gate**: P10

---

### L-RETRO-002: 复盘必须包含 Prior-Gap 与 New-Findings

**问题描述**：
P10 复盘必须包含两部分：
1. **Prior-Gap**：上次遗漏了什么（如果有上次项目经验）
2. **New-Findings**：本次新发现（下次项目应注意）

**影响范围**：
- 跨项目经验积累
- 防止重复踩坑

**根因分析**：
复盘不只是总结本次项目，更是为下次项目提供前车之鉴。

**解决方案**：
P10 复盘模板强制包含 Prior-Gap 与 New-Findings 章节。

**预防措施**：
1. P10 gate 检查复盘文档是否包含"上次遗漏了什么"章节
2. 每次项目启动前（P0 阶段）读取上次项目的 New-Findings
3. 建立项目间经验传递机制（如本文档）

**适用 Gate**: P10

---

## 九、使用本文档

### 9.0 新项目启动检查清单（每轮 Gate 前速查）

**启动前（P0 之前）**：
1. 工作目录与冻结副本物理独立性校验（L-TOOL-004）
2. 初始化项目本地 feedback queue（机器字段契约：FEEDBACK_ID/SCOPE/STATUS/ROOT_CAUSE/TARGET_FILES/DECISION）
3. 通读本教训库，将相关条目加入 P0 风险清单
4. 确认铁律 9：未经用户批准不改已安装 skill，教训先进项目本地队列

**验收点冻结（P0）**：
5. 验收点在 P0 冻结并机读化；first-pass 快照以 SHA 同时锚定 results/design/criteria 三方
6. 每条 DF 自带验证方式并锚定测试编号，形成 P0b→P2→P4/P6 闭环

**实现期（P3）**：
7. 终验证据骨架与实现同步规划：证据由测试运行器产出（L-P6-002）
8. 事务自调用审查、JSON 构造统一、比较常量化（L-STACK-003、L-STACK-004、L-P3-004）
9. 前端 0 个 >200 行 SFC（L-P3-005）

**每轮 Gate 前速查表**：

| 检查项 | 关联教训 |
|---|---|
| 副本是否符号链接？双采样哈希是否稳定？ | L-TOOL-004 |
| 证据文件时间戳是否晚于其声称的执行时间？ | L-P6-002 |
| 输入 SHA 变化后输出报告是否重新生成？ | L-TOOL-005 |
| 报告是否由受信运行器产出（非手写 Markdown）？ | L-P6-002 |
| @Transactional 是否存在同类自调用？ | L-STACK-003 |
| 可空列是否参与复合唯一索引？ | L-P2-004 |
| 遗留/豁免项是否全部显式登记触发条件？ | L-PROC-004 |

Gate 重跑时：先按 L-PROC-003 做根因分类（内容不合格 vs 证据链失效），再决定返工产物还是修复证据基础设施。

### 9.1 项目启动前（P0 阶段）

1. 读取本文档，识别与当前项目相关的教训
2. 将相关教训加入 P0 风险清单
3. 在 P0 澄清文档中增加对应检查项

### 9.2 各阶段 Gate 前

1. 读取本文档中对应 Gate 的教训
2. 执行对应的预防措施
3. 在 Gate 证据中附上"已应用教训"清单

### 9.3 P10 复盘后

1. 将本次项目的 New-Findings 追加到本文档
2. 更新版本号与最后更新时间
3. 提交 PR 到 devflow skill 仓库（如适用）

---

## 十、版本历史

| 版本 | 日期 | 变更 | 来源项目 |
|------|------|------|----------|
| v1.0.0 | 2026-09-15 | 初始版本，包含 detailed-design-v2 的 25 条经验教训 | detailed-design-v2 (治理服务) |
| v1.2.0 | 2026-09-17 | 8 条教训入检正式检查（L-STACK-001/002/003/004、L-P3-004、L-MON-001/002/003）+ L-P3-003 覆盖注记；全文加"机检"追溯行 | 本 skill 深检（v3.26.3） |
| v1.1.0 | 2026-09-16 | 追加 governance 项目复盘 12 条教训（L-P2-004、L-P3-004/005、L-P6-002、L-TOOL-004/005、L-MON-004/005、L-PROC-003/004、L-STACK-003/004）+ 启动检查清单 9.0 | governance (M-01 全局配置 / M-02 基础库治理) |

---

## 附录：快速查找索引

### 按阶段查找
- **P0**: L-P0-001
- **P0b**: L-P0-001, L-TOOL-005
- **P2**: L-P2-001, L-P2-002, L-P2-003, L-P2-004, L-P2-005, L-P2-006, L-P2-007, L-P2-008, L-STACK-001
- **P2a**: L-P2-005, L-P2-006, L-P2-007, L-P2-008, L-P0-001, L-P2-002, L-P2-003, L-P2-004, L-PROC-002, L-TOOL-005
- **P2b**: L-PROC-001
- **P3**: L-P3-001, L-P3-002, L-P3-003, L-P3-004, L-P3-005, L-P6-002, L-STACK-002, L-STACK-003, L-MON-001
- **P3b**: L-P3-002, L-P3-003, L-P3-004, L-P3-005, L-STACK-001, L-STACK-002, L-STACK-003, L-STACK-004, L-PROC-002, L-PROC-004, L-TOOL-005
- **P3c**: L-P3-003, L-STACK-004
- **P3d**: L-P3-003
- **P4**: L-P3-001, L-P4-001, L-PROC-004
- **P4b**: L-P4-001
- **P6**: L-P6-001, L-P6-002, L-MON-003
- **P7**: L-STACK-002, L-MON-004
- **P8**: L-MON-004
- **P9**: L-MON-005, L-PROC-004
- **P10**: L-RETRO-001, L-RETRO-002, L-MON-003, L-MON-005
- **全阶段**: L-PROC-003, L-TOOL-004

### 按类别查找
- **设计质量**: L-P0-001, L-P2-002, L-P2-003, L-P2-004, L-P2-005, L-P2-006, L-P2-007, L-P2-008
- **工具适配**: L-P4-001, L-TOOL-001, L-TOOL-002, L-TOOL-003, L-TOOL-004, L-TOOL-005
- **测试验证**: L-P3-001, L-P6-001, L-P6-002
- **代码审查**: L-P3-002, L-P3-003, L-P3-004, L-P3-005, L-STACK-003, L-STACK-004
- **监控可观测**: L-MON-001, L-MON-002, L-MON-003, L-MON-004, L-MON-005
- **流程协作**: L-PROC-001, L-PROC-002, L-PROC-003, L-PROC-004
- **技术栈**: L-STACK-001, L-STACK-002, L-STACK-003, L-STACK-004
- **复盘反馈**: L-RETRO-001, L-RETRO-002

### 按优先级查找
- **P0 级教训**（必须应用）: L-P2-002, L-P3-001, L-P3-002, L-STACK-002, L-STACK-003, L-P6-002, L-TOOL-004
- **P1 级教训**（强烈建议）: L-P0-001, L-P2-001, L-P2-003, L-P2-004, L-P2-005, L-P2-006, L-P2-007, L-P2-008, L-P3-003, L-P3-004, L-P4-001, L-P6-001, L-STACK-004, L-TOOL-005, L-MON-004, L-PROC-003, L-PROC-004
- **P2 级教训**（建议改进）: L-TOOL-001, L-MON-001, L-MON-002, L-MON-003, L-MON-005, L-PROC-001, L-P3-005

---

**维护者**: devflow 社区  
**反馈渠道**: 在项目 `.devflow/<feature>/feedback/` 中创建 FB，或提交 PR 到本 skill 仓库  
**许可证**: MIT
