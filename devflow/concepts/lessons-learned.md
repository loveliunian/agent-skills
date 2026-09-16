# devflow 经验与教训库（Lessons Learned）

> **版本**: v1.0.0  
> **最后更新**: 2026-09-15  
> **来源**: detailed-design-v2 (治理服务) 实施复盘  
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

**适用 Gate**: P6, P10

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

**适用 Gate**: P3, P3b, P7

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

---

## 附录：快速查找索引

### 按阶段查找
- **P0**: L-P0-001
- **P0b**: L-P0-001
- **P2**: L-P2-001, L-P2-002, L-P2-003, L-STACK-001
- **P2a**: L-P0-001, L-P2-002, L-P2-003, L-PROC-002
- **P2b**: L-PROC-001
- **P3**: L-P3-001, L-P3-002, L-P3-003, L-STACK-002, L-MON-001
- **P3b**: L-P3-002, L-P3-003, L-STACK-001, L-STACK-002, L-PROC-002
- **P3c**: L-P3-003
- **P3d**: L-P3-003
- **P4**: L-P3-001, L-P4-001
- **P4b**: L-P4-001
- **P6**: L-P6-001, L-MON-003
- **P7**: L-STACK-002
- **P10**: L-RETRO-001, L-RETRO-002, L-MON-003

### 按类别查找
- **设计质量**: L-P0-001, L-P2-002, L-P2-003
- **工具适配**: L-P4-001, L-TOOL-001, L-TOOL-002, L-TOOL-003
- **测试验证**: L-P3-001, L-P6-001
- **代码审查**: L-P3-002, L-P3-003
- **监控可观测**: L-MON-001, L-MON-002, L-MON-003
- **流程协作**: L-PROC-001, L-PROC-002
- **技术栈**: L-STACK-001, L-STACK-002
- **复盘反馈**: L-RETRO-001, L-RETRO-002

### 按优先级查找
- **P0 级教训**（必须应用）: L-P2-002, L-P3-001, L-P3-002, L-STACK-002
- **P1 级教训**（强烈建议）: L-P0-001, L-P2-001, L-P2-003, L-P3-003, L-P4-001, L-P6-001
- **P2 级教训**（建议改进）: L-TOOL-001, L-MON-001, L-MON-002, L-MON-003, L-PROC-001

---

**维护者**: devflow 社区  
**反馈渠道**: 在项目 `.devflow/<feature>/feedback/` 中创建 FB，或提交 PR 到本 skill 仓库  
**许可证**: MIT
