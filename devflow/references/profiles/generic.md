---
name: profile-generic
version: "3.26.6"
description: 无技术栈假设的 Runtime Profile 模板——所有 adapter 必须从项目事实源解析。
---

# Profile: generic

适用于任意语言/框架的新项目或未内置 Profile 的技术栈。本 Profile 不提供任何默认实现，所有能力位必须在 P1 冻结时由项目事实源解析并登记。

## 能力位清单

| 能力位 | 是否必需 | 解析来源示例 |
|---|---|---|
| `BUILD_ADAPTER` | 必需 | CI 配置 / 构建脚本 / 项目 README |
| `TEST_ADAPTER` | 必需 | 测试框架配置、`run-tests` 脚本 |
| `LINT_ADAPTER` | 建议 | linter/formatter 配置 |
| `COVERAGE_ADAPTER` | 声明规模后必需 | 覆盖率工具配置；阈值随 Profile 冻结 |
| `AUTHORIZATION_ADAPTER` | 存在权限模型时必需 | 中间件/守卫/策略测试命令 |
| `MIGRATION_ADAPTER` | 存在持久化时必需 | migration 工具 + 方言清单 |
| `CLIENT_BUILD_ADAPTER` | 客户端 scope 非 `not-applicable` 时必需 | 客户端构建命令 |
| `CLIENT_JOURNEY_ADAPTER` | 同上 | 浏览器/模拟器自动化入口 |
| `SECURITY_ADAPTER` | 必需 | 依赖/密钥/静态扫描命令 |

## 冻结规则

1. 每个能力位写入 P1 技术选型报告与 `docs/详细设计/_commons.md`，含真实命令与版本。
2. 命令必须实际可执行；只声明不执行的命令不算 adapter。
3. 能力缺失或不可执行：`STATUS=BLOCKED` + `MISSING_CAPABILITY=<capability>`，不得跳过 Gate。
4. 核心流程与阶段文档不得写入任何本 Profile 未声明的技术栈断言。
