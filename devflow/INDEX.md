# devflow v3.28 文档索引

## 🚀 快速开始（1 分钟）

```bash
# 1. 运行 Demo
bash scripts/demo_test_generator.sh

# 2. 查看生成的测试
cat /tmp/devflow-test-generator-demo/backend/src/test/java/controller/UserControllerTest.java

# 3. 阅读快速开始
cat QUICKSTART.md
```

---

## 📚 文档导航

### 新手入门（推荐阅读顺序）

| 顺序 | 文档 | 用途 | 阅读时间 |
|-----|------|------|---------|
| 1️⃣ | **[QUICKSTART.md](./QUICKSTART.md)** | 1 分钟快速验证 + 实际使用 | 5 分钟 |
| 2️⃣ | **[runtime-profiles/README.md](./runtime-profiles/README.md)** | Profile 入门 + 技术栈选择 | 10 分钟 |
| 3️⃣ | **[v3.28-demo-guide.md](./v3.28-demo-guide.md)** | 功能演示 + 完整工作流 | 15 分钟 |

### 深入使用

| 文档 | 内容 | 适合人群 |
|-----|------|---------|
| **[docs/P5-自动生成测试.md](./docs/P5-自动生成测试.md)** | P5 自动测试生成完整指南 | P5 阶段开发者 |
| **[references/test-generators.md](./references/test-generators.md)** | 完整 API、故障排查、扩展指南 | 深度用户、扩展开发者 |
| **[v3.28-update-summary.md](./v3.28-update-summary.md)** | 更新总结、完成度对照、后续建议 | 了解技术细节 |
| **[DELIVERY-CHECKLIST.md](./DELIVERY-CHECKLIST.md)** | 交付清单、验收标准、设计决策 | 项目验收、质量把关 |

### 管理文档

| 文档 | 内容 | 适合人群 |
|-----|------|---------|
| **[v3.28-COMPLETION-REPORT.md](./v3.28-COMPLETION-REPORT.md)** | 完成报告、统计数据、总结 | 项目管理、汇报 |
| **[INDEX.md](./INDEX.md)** | 本文档，导航索引 | 所有人 |

---

## 🎯 按需求查找

### 我想要...

| 需求 | 查看文档 | 操作 |
|-----|---------|------|
| **快速验证功能** | QUICKSTART.md § 1 | `bash scripts/demo_test_generator.sh` |
| **在项目中使用** | QUICKSTART.md § 2 | `bash scripts/generate_tests.sh <feature>` |
| **了解 P5 自动生成** | docs/P5-自动生成测试.md | 阅读完整指南 |
| **理解 Runtime Profile** | runtime-profiles/README.md | 阅读"什么是 Profile" |
| **自定义 Profile** | runtime-profiles/README.md § 4 | 复制并修改 JSON |
| **扩展生成器** | references/test-generators.md § 7 | 阅读扩展指南 |
| **故障排查** | references/test-generators.md § 6 | 查找错误信息 |
| **查看 API** | references/test-generators.md § 3 | 阅读 API 文档 |
| **了解设计理念** | v3.28-demo-guide.md § 4 | 阅读对比分析 |
| **查看统计数据** | v3.28-COMPLETION-REPORT.md § 3 | 查看统计表 |

---

## 📦 核心组件

### 1. Runtime Profile（技术栈适配器）

```
runtime-profiles/
├── java-spring-flyway.json          # Java + Spring Boot + Flyway
├── node-express-prisma.json         # Node.js + Express + Prisma
├── python-fastapi-sqlalchemy.json   # Python + FastAPI + SQLAlchemy
└── README.md                        # 使用文档
```

**用途**: 定义如何执行构建、测试、迁移等操作  
**文档**: [runtime-profiles/README.md](./runtime-profiles/README.md)

### 2. 测试生成器

```
scripts/
├── generate_junit_tests.py          # design.json → JUnit 测试
├── generate_playwright_tests.py     # acceptance.json → Playwright E2E
├── generate_tests.sh                # 一键生成（集成脚本）
├── demo_test_generator.sh           # Demo 演示
└── verify_test_generators.sh        # 验证脚本
```

**用途**: 从结构化产物自动生成测试骨架  
**文档**: [references/test-generators.md](./references/test-generators.md)

---

## 🔧 常用命令

### 生成测试

```bash
# 一键生成所有测试
bash scripts/generate_tests.sh <feature-name>

# 只生成 JUnit
bash scripts/generate_tests.sh <feature-name> --junit-only

# 只生成 Playwright
bash scripts/generate_tests.sh <feature-name> --playwright-only
```

### 验证环境

```bash
# 运行验证脚本
bash scripts/verify_test_generators.sh

# 检查 Profile JSON 格式
python3 -m json.tool runtime-profiles/java-spring-flyway.json
```

### 运行 Demo

```bash
# 快速体验
bash scripts/demo_test_generator.sh

# 查看生成结果
ls -lh /tmp/devflow-test-generator-demo
```

---

## ❓ 常见问题

### Q1: 如何快速验证功能？
**A**: 运行 `bash scripts/demo_test_generator.sh`，30 秒看到效果。

### Q2: 生成的测试能直接运行吗？
**A**: 不能。需要补充 Mock 返回值、调整选择器、添加断言。设计理念是"减少重复劳动，不替代思考"。

### Q3: 如何选择 Runtime Profile？
**A**: devflow 会在 P1 阶段自动检测（pom.xml → java-spring-flyway）。也可手动指定 `--profile=<id>`。

### Q4: 如何为其他技术栈添加支持？
**A**: 复制现有 Profile，修改命令和路径。详见 [references/test-generators.md](./references/test-generators.md) § 7。

### Q5: 生成器报错怎么办？
**A**: 查看 [references/test-generators.md](./references/test-generators.md) § 6 故障排查章节。

---

## 📊 统计数据

| 类别 | 数量 | 总大小 |
|-----|------|--------|
| **Runtime Profiles** | 3 个 | 16K |
| **生成器脚本** | 5 个 | 48K |
| **文档** | 6 个 | 61K |
| **总计** | 14 个文件 | **125K** |

---

## 🎯 设计理念

> **"减少重复劳动，不替代思考"**

- ❌ 不做黑盒全自动生成
- ✅ 做人机协作的辅助工具
- ✅ 生成骨架，人补充逻辑
- ✅ 保持控制权和灵活性

---

## 🔗 外部链接

- **devflow 主文档**: [SKILL.md](./SKILL.md)
- **变更日志**: [references/CHANGELOG.md](./references/CHANGELOG.md)
- **核心概念**: [concepts/core.md](./concepts/core.md)

---

## 📝 版本信息

- **当前版本**: v3.28.0
- **发布日期**: 2026-09-20
- **维护者**: devflow team
- **状态**: ✅ 稳定版

---

## 🤝 反馈与贡献

### 如何提供反馈

1. **Bug 报告**: 描述问题 + 提供 JSON + 错误日志
2. **改进建议**: 描述不便 + 期望行为 + 使用场景
3. **贡献代码**: Fork + 修改 + 测试 + PR

### 联系方式

- 查看 [DELIVERY-CHECKLIST.md](./DELIVERY-CHECKLIST.md) § 反馈机制
- 阅读 [references/test-generators.md](./references/test-generators.md) § 扩展指南

---

**最后更新**: 2026-09-20  
**文档维护**: devflow team
