---
name: runtime-profile
version: "3.29.7"
description: 技术栈无关的 Runtime Profile 契约——P3 前必须解析并冻结，核心流程不得假设具体框架。
---

# Runtime Profile Contract（运行时配置契约）

任何实现流程（`/devflow`、`/build`、`/small-change` 持久化改动）在进入 P3 前**必须**解析并冻结一个 Runtime Profile。Profile 是"核心流程"与"技术栈"之间的唯一适配层：

```text
Core Workflow（阶段/Gate/收据，技术栈无关）
      ↓
Capability Contract（本文件定义的 adapter 能力位）
      ↓
Selected Profile（references/profiles/*.md）
      ↓
Stack Adapter（项目级真实命令/脚本）
```

## 1. 解析顺序（fail-closed）

1. 已冻结的 Runtime Profile（P1 技术选型 / 项目事实源中显式声明）。
2. 仓库原生命令（从 `package.json`、`pom.xml`、`Makefile`、CI 配置等项目事实源提取）。
3. 项目事实源（`docs/详细设计/_commons.md` 等登记的命令）。

禁止仅凭"存在某个熟悉文件"推断 adapter（例如看到 `pom.xml` 不等于可以使用 Maven 命令，必须确认可执行且属于冻结选型）。

无法解析的能力位：`STATUS=BLOCKED`，`MISSING_CAPABILITY=<capability>`，不得猜测或用其他技术栈命令顶替。

## 2. Profile 字段

```yaml
profile_id: generic            # generic | java-spring-flyway | <project-defined>

backend:
  language: "{{language}}"
  framework: "{{framework}}"
  build_adapter: "{{command_or_script}}"        # BUILD_ADAPTER
  test_adapter: "{{command_or_script}}"         # TEST_ADAPTER
  lint_adapter: "{{command_or_script}}"         # LINT_ADAPTER
  coverage_adapter: "{{command_or_script}}"     # COVERAGE_ADAPTER

authorization:
  required: "{{true|false}}"
  verification_adapter: "{{command_or_script}}" # AUTHORIZATION_ADAPTER

persistence:
  required: "{{true|false}}"
  migration_system: "{{flyway|liquibase|prisma|alembic|other|none}}"
  dialects: []                                  # 为空表示单方言或由 migration_system 决定

client:
  scope: "{{pc-web|mini-program|app|not-applicable}}"
  build_adapter: "{{command_or_script}}"        # CLIENT_BUILD_ADAPTER
  journey_adapter: "{{command_or_script}}"      # CLIENT_JOURNEY_ADAPTER

security:
  adapter: "{{command_or_script}}"              # SECURITY_ADAPTER
```

## 3. Capability Contract（核心不变量）

选定 Profile 后，P3 Core 只要求以下能力位与其 Gate 结果，不知道也不需要知道框架细节：

```text
BUILD_GATE = PASS
TEST_GATE = PASS
COVERAGE_GATE = PASS            # 阈值由 Profile 声明，核心不写死 80%
AUTHORIZATION_GATE = PASS       # 若 authorization.required
MIGRATION_GATE = PASS           # 若 persistence.required
CLIENT_REACHABILITY_GATE = PASS # 客户端 scope 对应旅程证据
SECURITY_GATE = PASS
```

- 任一能力位为 `N/A` 时，必须在冻结设计中写明理由；不得为绕过失败临时改 `N/A`。
- Core 的任何规则**禁止**直接假设 Maven、Spring、`@PreAuthorize`、Flyway 四方言、JaCoCo、Vue 或某数据库方言——这些只能在 `PROFILE_ID=java-spring-flyway` 等具体 Profile 中成立。
- 各阶段 Gate 仍按 `commands/devflow.md` 参数矩阵执行；Profile 只决定命令与等价物。

## 4. 内置参考 Profile

| PROFILE_ID | 文件 | 说明 |
|---|---|---|
| `java-spring-flyway` | `references/profiles/java-spring-flyway.md` | Java/Spring/Flyway 四方言参考实现 |
| `generic` | `references/profiles/generic.md` | 无栈假设模板，全部 adapter 需项目解析 |

新增技术栈时按本契约新增 `references/profiles/<id>.md`，并在 P1 设计决策记录中登记 `PROFILE_ID` 与能力位命令；不得修改 Core 流程去适配单一技术栈。

## 5. 实现状态（v3.27.1）

- `PROFILE_ID` 经 `devflow-state.sh init --profile=<id>` 冻结到
  `state.scope.profile_id`（须存在 `references/profiles/<id>.md`；未指定的历史
  项目按参考实现 `java-spring-flyway` 处理）。
- **命令位 Gate 化尚未完成**：P3 完成度（`p3_completion_gate.sh`）、P3-build
  （`build-watchdog.sh`）、P4b（`p4_prd_vs_code.sh`）的 build/test/coverage/
  flyway/orm-mapping 命令位当前只有 `java-spring-flyway` 实现。其他 profile 在
  这三个 Gate 上 `BLOCKED(MISSING_CAPABILITY)`（`scripts/devflow_profile.sh`），
  不会静默运行错误技术栈的命令；P1/P2 的选型描述层与 P5/P6 的运行器白名单
  本身是栈无关的。
- 长期路线：把上述 Gate 的字面命令抽为 Profile 声明的命令位
  （`BUILD_CMD`/`TEST_CMD`/`COVERAGE_CMD`/…），由 Gate 读取冻结 PROFILE_ID
  解析执行——完成后本节相应收缩。
