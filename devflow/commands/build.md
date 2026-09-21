---
name: build
version: "3.28.10"
description: >-
  Use when implementing backend APIs, frontend pages, or migrations for a new feature after /plan,
  mentions "/build", "build it", "编码实现", "实现这个功能", "写代码", "全栈开发", or "start implementation".
  Resolves the frozen runtime profile first; the java-spring-flyway profile adds the 23-item completion gate
  (4-dialect Flyway + menu-seed 4-table + @PreAuthorize + Maven + frontend build).
  Runs sql-dev + backend-dev + frontend-dev subagents. Must pass the profile gate before issuing the P3b ticket.
paths:
  - "backend/**/*.java"
  - "frontend/src/**"
  - "backend/**/db/migration/**"
disable-model-invocation: false
allowed-tools:
  - read
  - write
  - exec
  - glob
  - grep
  - task
---

# /build - 全栈编码（P3）

> **技术栈解析（P3 前置）**：先读 `references/runtime-profile.md` 解析 `PROFILE_ID` 并冻结能力位（BUILD/TEST/COVERAGE/AUTHORIZATION/MIGRATION/CLIENT/SECURITY_ADAPTER）。`java-spring-flyway` 是内置参考 Profile（`references/profiles/java-spring-flyway.md`）；其他技术栈使用项目 Profile，不得把 Maven、`@PreAuthorize` 或四方言检查误当作其已验证证据。能力位缺失：`STATUS=BLOCKED` + `MISSING_CAPABILITY=<capability>`。

> **前置依赖**：P0-P2与`/plan`全部通过；首轮baseline必须在任何代码修改前冻结。
> **完成度自检**：先跑 `scripts/build-watchdog.sh gate <feature>` 产出 P3-build 收据，再以 `scripts/p3_completion_gate.sh` 非零/零退出码为最终 P3 判定。
> **施工顺序（P2 → Plan → Build 边界）**：详设 = WHAT + CONTRACT；实现交接文档（`<feature>-实现交接.md`，`anchor: implementation-handoff`）= 施工图；`/plan` = WHERE + HOW TO VERIFY（exact target / action / invariants / verify）；`/build` = MINIMAL PATCH——先 READ EXISTING CODE 对账实现交接 → 最小补丁 → 目标测试 → 相关回归 → DIFF scope review（子 Agent 细则见 `subagents/backend-dev.md`）。

## 使用方式

```
/build <feature>
/build <feature> --slice=1   # 仅执行第 1 切片
/build <feature> --service=<service>  # 指定服务
```

## 示例

```
/build m-03-basic-library
/build m-03-basic-library --service=governance-service
/build payment-system --slice=1
```

## 命名约定

- 后端路径：`backend/<service>/src/main/java/...`
- 前端路径：`frontend/src/...`
- SQL 迁移：`backend/<service>/src/main/resources/db/migration/{h2,oracle,postgresql,kingbase}/V*.sql`
- 单测路径：`backend/<service>/src/test/java/...`

## 执行步骤

### 1. 加载任务清单

```bash
PLAN_F="任务/执行契约.md"; [ -f "$PLAN_F" ] || PLAN_F="tasks/plan.md"
test -f "$PLAN_F" || { echo "BLOCKED: 任务清单缺失（任务/执行契约.md），请先 /plan"; exit 1; }
test -f docs/详细设计/<feature>-详细设计.md || { echo "BLOCKED: 详设缺失，请先 /spec"; exit 1; }
bash "$SKILL_ROOT/scripts/s0_acceptance_gate.sh" <feature>
bash "$SKILL_ROOT/scripts/s1_fact_sources_gate.sh" docs/详细设计
bash "$SKILL_ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/<feature>-详细设计.md docs/需求/<feature>-验收点.md
# v3.24.0(A12)：与 /plan 消费同一份设计批准收据——P2a 未通过不得开工
test -f ".devflow/<feature>/gates/P2a/receipt.txt" && grep -q '^EXIT_CODE=0$' ".devflow/<feature>/gates/P2a/receipt.txt" \
  || { echo "BLOCKED: P2a 设计评审未通过——设计完成 = P2 + P2a（同一批准收据）"; exit 1; }
bash "$SKILL_ROOT/scripts/s3_migration_mapping_gate.sh" <A|B|C> docs/数据映射/<feature>-映射.md <source-count>
bash "$SKILL_ROOT/scripts/s4_first_pass_snapshot.sh" freeze <feature> docs/需求/<feature>-验收点.md docs/详细设计/<feature>-详细设计.md
```

加载`phases/03-规范实现.md`。任一命令非零立即阻断，不得只打印告警继续。

开工前先读实现交接文档 `docs/详细设计/<feature>-实现交接.md`（`anchor: implementation-handoff`）：Target 与实际代码不符、或未给出基线，
`STATUS=BLOCKED` 回 P2 补齐——禁止编码 Agent 自行重新研究实现方案。

开始实现前读取`references/git-branch-strategy.md`；涉及前端时同时读取`references/frontend-tech-stack.md`。用户明确要求在当前分支工作时以用户指令为准，但必须记录分支和检查点。

### 2. 并行调度子 Agent（按垂直切片）

| 子 Agent | 职责 | 输入 |
|----------|------|------|
| `sql-dev` | 当前垂直切片的 Flyway 多 DB 迁移脚本 + 菜单/权限 seed | 数据模型、数据实施清单、验收ID |
| `backend-dev` | 当前垂直切片的 Entity / Repository / Service / Controller / DTO | 接口语义锚点、规则/伪代码、验收ID |
| `frontend-dev` | 当前垂直切片的页面 + API 调用 + 表单 + router 注册 | 页面/任务语义锚点、接口、权限、验收ID |

只有不同 Agent 的文件集合和契约没有重叠时才并行。若平台无法提供独立开发角色，主Agent可按切片串行实现；独立 Review 和完成度审计仍不可自签，缺少独立会话时报告 `BLOCKED`。

### 3. 按垂直切片执行（不要按层级）

每个切片 = 一组表 + 后端端点 + 前端组件 + 单测 + 客户端可达性证据（PC Web 为**菜单 seed**）。

### 3.5 Stack-neutral 能力位（核心不变量）

P3 不直接要求任何框架特有实现；先解析冻结的 Runtime Profile，由 Profile 提供适用能力位：

- `BUILD_ADAPTER`、`TEST_ADAPTER`、`COVERAGE_ADAPTER`
- `AUTHORIZATION_ADAPTER`（存在权限模型时）
- `MIGRATION_ADAPTER`（存在持久化时）
- `CLIENT_BUILD_ADAPTER`、`CLIENT_JOURNEY_ADAPTER`
- `SECURITY_ADAPTER`

Java/Spring/Flyway 特有规则仅在 `PROFILE_ID=java-spring-flyway` 时加载（见 `references/profiles/java-spring-flyway.md`）。

### 4. 编码范围

通用（所有 Profile）：按冻结详设实现当前垂直切片，最小完整改动，不做未授权重构。

以下为 `PROFILE_ID=java-spring-flyway` 的规则：

- **后端**：按详设实现 API / Service / Repository，**所有 Controller 必须加 `@PreAuthorize`**
- **前端**：按 API 契约实现页面、组件、API 调用 + **router 注册**
- **SQL**：4 个 DB 都写 Flyway 脚本（h2 + oracle + postgresql + kingbase）
- **菜单 seed**：新增前端页面 = 新增菜单项，必须自动生成 `V*__seed_<feature>_menus.sql`（4 方言），含：
  1. `sys_menu` 插入（CATALOG + 各页面 MENU，含 `route_path` + `component_path` + `perm_code`）
  2. `sys_menu_operation` 插入（每菜单至少 VIEW 操作）
  3. `sys_permission_group` 插入（与 `perm_code` 对齐）
  4. `sys_user_effective_perm` 插入（admin 用户 user_id=1 自动授予全部）
  5. **postgresql 方言**：末尾追加 `setval` 同步序列（关键！否则下次 INSERT id 冲突）
- **测试**：单测覆盖率 ≥ 80%（核心业务）

> ⚠️ **注意**：
>
> 新增前端页面但没新增菜单 seed = **前端不可达**（路由存在但侧边栏不显示）= 视为功能未完成。
> 详见 `references/severity-tiers.md` §"新功能交付物不完整（菜单/权限缺失）" — P0 阻断。

### 5. 完成度自检（权威入口）

```bash
bash "$SKILL_ROOT/scripts/build-watchdog.sh" gate <feature>          # P3-build 收据
bash "$SKILL_ROOT/scripts/p3_completion_gate.sh" <service> <feature>   # 最终判定
```

两步退出码均为0才可进入P3b；编译、测试、覆盖率、四方言或Seed失败均阻断。
纯后端/无持久化/无接口模块可由冻结详设显式设置 `FRONTEND_REQUIRED=0`、`PERSISTENCE_REQUIRED=0`、`API_REQUIRED=0`；不得为绕过失败临时修改这些值。

### 6. 自检结果

`bash "$SKILL_ROOT/scripts/p3_completion_gate.sh" <service> <feature>`退出码=0才签发P3b入场券；任一FAIL、WARN型编译/测试失败或脚本异常都阻断。

Gate（`PROFILE_ID=java-spring-flyway` 时的能力位；其他 Profile 由冻结的等价 adapter 提供同名能力位）

| 项 | 强制条件 |
|----|----------|
| TODO 残留 | = 0 |
| `@PreAuthorize` 覆盖 | 所有 Controller ≥1 个 |
| Mapper = 实体 | 一一对应 |
| Flyway 多 DB | h2 + oracle + postgresql + kingbase 4 个目录 |
| **菜单 seed** | **4 方言 × 4 表（sys_menu + sys_menu_operation + sys_permission_group + sys_user_effective_perm）齐全；admin 自动授权** |
| **前端 router 注册** | **新增 .vue 页面对应 route 在 router/*.ts 中注册** |
| 单测覆盖率 | ≥ 80%（JaCoCo） |
| Maven | compile + test 全 PASS |
| 前端 | build + type-check 全 PASS |
| 详设交叉对照 | 接口 + 表名 + **菜单** 100% 命中 |

## 输出

> 说明：glob `**/*` 仅为"该目录下全部文件"的简略说法，**不用于 shell 命令**。Agent 必须用 `find ... -name "*.java"` 等替代。

- 后端代码：`backend/<service>/src/main/java/`
- 前端代码：`frontend/src/`
- **菜单 seed**：`backend/<menu-service>/src/main/resources/db/migration/{h2,postgresql,oracle,kingbase}/<module>/V*__seed_<feature>_menus.sql`（4 方言；服务与模块从项目事实源解析）
- SQL 迁移：`backend/<service>/src/main/resources/db/migration/{h2,oracle,postgresql,kingbase}/V*.sql`
- 前端 router 注册：`frontend/src/router/*.ts`（新增 .vue 须有对应 route）
- 单测：`backend/<service>/src/test/java/`

## 角色约束

- **开发 Agent**（sql-dev / backend-dev / frontend-dev）并行执行
- **不得**由 code-reviewer / security-auditor / performance-auditor 执行开发
- **不得**自我执行完成度自检 —— 自检必须由独立 session 的 `completeness-auditor` 角色执行

## 与其他命令关系

- 完成后**强制**运行 `/audit-completeness P3 <feature>`
- `/audit-completeness P3` PASS 后才能进 `/review` (P3b)

## 自检命令

```bash
bash "$SKILL_ROOT/scripts/p3_completion_gate.sh" <service> <feature>
```

完整stdout和退出码写入审计报告。

---

## Acceptance Test

> **Gather → Act → Verify** 模式：用实际命令验证 skill 是否生效。

```bash
# 准备：使用调用方冻结的服务与功能，不猜项目名
SERVICE="<service>"
FEATURE="<feature>"
test -d "backend/$SERVICE/src/main/java" || { echo "BLOCKED: 服务目录不存在"; exit 1; }

# Gather：从实施证据表读取本次切片文件，不绑定包名
EVIDENCE="docs/测试/${FEATURE}-implementation-evidence.tsv"
test -f "$EVIDENCE" || { echo "BLOCKED: 缺少实施证据表"; exit 1; }

# Act：运行 P3 一键 gate
bash "$SKILL_ROOT/scripts/p3_completion_gate.sh" "$SERVICE" "$FEATURE"

# Verify：核心指标
echo "=== 关键指标 ==="
find "backend/$SERVICE/src/main/java" -name "*Controller.java" -type f -exec grep -l "@PreAuthorize" {} + | wc -l | tr -d ' '
find "backend/$SERVICE/src/main/resources/db/migration" -name "V*.sql" -type f | wc -l | tr -d ' '
```

**通过标准**：脚本输出 "P3 GATE: PASS"（FAIL = 0）

---

## 状态机口径（单命令模式 · P1-6）

- 本命令运行于**单命令模式**：豁免状态机——不调用 `devflow-state.sh complete`，不推进阶段状态、不产出阶段收据链。
- 执行时必须在输出首部显式携带降级声明：`MODE=single-command STATE_MACHINE=exempt（阶段状态不推进；完整门禁链走 /devflow 编排）`。
- 需要完整门禁、收据链、checkpoint 恢复与"不可跳过阶段"约束时，改走 `/devflow` 编排路径（commands/devflow.md）。
