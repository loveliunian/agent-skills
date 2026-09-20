# 测试生成器与 Runtime Profile（v3.28）

## 概览

本次更新为 devflow 补充了两个关键组件：

1. **Runtime Profile 实例**：定义技术栈的构建、测试、迁移等能力位
2. **测试生成器**：从结构化产物自动生成 JUnit / Playwright 测试骨架

这两个组件解决了 devflow 在编码和测试阶段的"如何执行"问题，使其从流程编排框架向可执行工具链迈进。

## 新增文件清单

```
devflow/
├── runtime-profiles/                        # Runtime Profile 实例
│   ├── java-spring-flyway.json             # Java + Spring Boot + Flyway
│   ├── node-express-prisma.json            # Node.js + Express + Prisma
│   └── python-fastapi-sqlalchemy.json      # Python + FastAPI + SQLAlchemy
│
├── schemas/
│   └── runtime-profile.schema.json         # Profile JSON Schema 契约
│
├── scripts/
│   ├── generate_junit_tests.py             # JUnit 测试生成器
│   ├── generate_playwright_tests.py        # Playwright 测试生成器
│   ├── generate_tests.sh                   # 集成脚本（一键生成）
│   └── demo_test_generator.sh              # 快速体验 Demo
│
└── references/
    └── test-generators.md                  # 完整使用文档（577 行）
```

## 快速开始

### 1. 运行 Demo

```bash
cd /Users/huymac/.cursor/skills/devflow
bash scripts/demo_test_generator.sh
```

这会创建示例 `design.json` 和 `acceptance.json`，然后生成对应的测试代码。

### 2. 在实际项目中使用

```bash
# 前提：已完成 P2 详设和 P0 验收点冻结

# 一键生成所有测试
bash scripts/generate_tests.sh user-mgmt

# 或分别生成
bash scripts/generate_tests.sh user-mgmt --junit-only
bash scripts/generate_tests.sh user-mgmt --playwright-only
```

### 3. 查看生成的代码

```bash
# JUnit 测试
ls -la backend/*/src/test/java/

# Playwright 测试
ls -la frontend/tests/e2e/
```

## Runtime Profile 说明

### 作用

Runtime Profile 定义了技术栈的"能力适配器"，告诉 devflow：

- ✅ 如何编译（`build_adapter.command: "mvn compile"`）
- ✅ 如何测试（`test_adapter.command: "mvn test"`）
- ✅ 如何迁移（`migration_adapter.command: "mvn flyway:migrate"`）
- ✅ 覆盖率阈值（`coverage_adapter.threshold.core_business: 0.80`）
- ✅ Gate 绑定（`gate_bindings.P3-build: "backend.build_adapter"`）

### 已支持的技术栈

| Profile | 语言 | 框架 | ORM | 前端 |
|---|---|---|---|---|
| **java-spring-flyway** | Java 11+ | Spring Boot | JPA | Vue3 / 小程序 / APP |
| **node-express-prisma** | Node.js 18+ | Express | Prisma | React |
| **python-fastapi-sqlalchemy** | Python 3.10+ | FastAPI | SQLAlchemy | Vue3 |

### 如何选择 Profile

devflow 在 P1 阶段会自动推断：

```bash
# 检测到 pom.xml → java-spring-flyway
# 检测到 package.json + express → node-express-prisma
# 检测到 requirements.txt + fastapi → python-fastapi-sqlalchemy
```

也可以显式指定：

```bash
bash scripts/devflow-state.sh init \
  --feature=user-mgmt \
  --profile=java-spring-flyway
```

## 测试生成器说明

### JUnit 生成器

**输入**：`.devflow/<feature>/design.json`

**输出**：
- `*ControllerTest.java`：每个 API 生成对应的 Controller 测试
- `*ServiceTest.java`：每个业务规则生成对应的 Service 测试
- `*MapperTest.java`：每个数据表生成对应的 Mapper 测试

**覆盖场景**：
- ✅ 正常场景（200 OK）
- ✅ 参数校验场景（400 Bad Request）
- ✅ 权限校验场景（401 Unauthorized）
- ✅ 资源不存在场景（404 Not Found）

### Playwright 生成器

**输入**：`.devflow/<feature>/acceptance.json`

**输出**：
- `pages/*Page.ts`：自动生成 Page Object 类
- `*-M-XX-FYY.spec.ts`：每个功能号生成一个测试规格
- `*-api.spec.ts`：API 验收点生成 API 测试

**智能推断**：
- 从验收点描述推断需要的页面对象
- 根据 `verify_method: "UI"|"API"` 生成不同类型的测试
- 自动分组相关的测试用例

## 与 devflow 流程集成

测试生成器在以下阶段发挥作用：

| 阶段 | 时机 | 操作 |
|---|---|---|
| **P2 详设完成** | `design.json` 冻结后 | 生成 JUnit 单元测试骨架 |
| **P0 验收冻结** | `acceptance.json` 签字后 | 生成 Playwright E2E 测试骨架 |
| **P3 编码阶段** | 实现功能同时 | 补充测试逻辑（TDD） |
| **P5 测试设计** | Gate 检查测试用例数 | 生成器提供的骨架计入基数 |
| **P6 测试执行** | Gate 检查覆盖率 | 补充后的测试用于覆盖率计算 |

**重要**：生成器**不绕过** Gate 检查，只是提供初始框架。

## 完整文档

详细用法、故障排查、扩展指南见：

```bash
cat references/test-generators.md
```

包括：
- 完整的 API 文档
- 10 个最佳实践
- 故障排查指南
- 自定义 Profile 教程
- 扩展其他测试框架的方法

## 架构决策

### 为什么先做生成器而不是模板？

问：为什么不先做"代码生成模板"（从 PRD 直接生成业务代码）？

答：因为测试生成器的 ROI 更高：

1. **测试代码重复度高**：CRUD 测试的结构高度一致，适合自动生成
2. **业务代码变化大**：每个项目的业务逻辑差异巨大，模板难以覆盖
3. **TDD 友好**：先生成测试，再实现功能，符合最佳实践
4. **与脚手架互补**：业务代码用脚手架初始化，测试代码用生成器补充

### 为什么生成"骨架"而不是"完整测试"？

问：为什么生成的测试里有 `// TODO`，不直接生成完整逻辑？

答：因为完整测试逻辑需要理解业务语义：

- ❌ **无法推断**：边界值、异常场景的具体条件
- ❌ **无法生成**：复杂的 Mock 配置
- ❌ **无法确定**：断言的精确值

生成器的定位是"减少 50% 的重复劳动"，不是"100% 自动化"。

## 已知限制

### 当前不支持

1. **测试数据工厂**：不生成 fixtures 和 seed 数据
2. **复杂交互流**：Playwright 只生成简单的页面操作
3. **多语言混合**：一个 feature 只能用一个 Profile
4. **自动修复**：Gate 失败时不能自动修复测试

### 路线图

优先级 P0（需要补充）：
- [ ] 测试数据工厂生成器（从 `tables[]` 生成 seed.sql）
- [ ] 智能选择器推断（基于实际 DOM 结构）
- [ ] Profile 自动推断逻辑（从项目文件推断技术栈）

优先级 P1（增强）：
- [ ] 支持更多框架（pytest、Go testing、RSpec）
- [ ] Mock 配置自动生成
- [ ] 测试覆盖率可视化

## 反馈与贡献

如果你发现：
- 生成的测试代码有语法错误
- Profile 中的命令不适用于你的项目
- 需要支持新的测试框架

请提交 Issue 或直接修改：
- Profile 文件：`runtime-profiles/*.json`
- 生成器脚本：`scripts/generate_*_tests.py`
- 文档：`references/test-generators.md`

## 版本历史

- **v3.28.0**（2026-09-20）：初次发布测试生成器和 Runtime Profile
- **v3.27.15**：devflow 核心流程稳定版
- **v3.27.0**：引入结构化产物（`design.json`、`acceptance.json`）

---

**维护者**：devflow team  
**许可证**：MIT  
**最后更新**：2026-09-20
