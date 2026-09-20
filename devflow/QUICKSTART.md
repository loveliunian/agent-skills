# devflow v3.28 快速开始

## 1 分钟快速验证

### 步骤 1：验证安装

```bash
cd /Users/huymac/.cursor/skills/devflow

# 检查 Python 版本（需要 >= 3.8）
python3 --version

# 检查生成器脚本
ls -l scripts/generate_junit_tests.py
ls -l scripts/generate_playwright_tests.py

# 检查 Runtime Profile
ls -l runtime-profiles/*.json
```

### 步骤 2：运行 Demo

```bash
# 运行测试生成器 Demo（30 秒）
bash scripts/demo_test_generator.sh
```

**预期输出**：
```
[SUCCESS] JUnit 测试生成完成
[SUCCESS] Playwright E2E 测试生成完成
生成的文件位置: /tmp/devflow-test-generator-demo
```

### 步骤 3：查看生成的代码

```bash
# 查看 JUnit 测试
cat /tmp/devflow-test-generator-demo/backend/src/test/java/controller/UserControllerTest.java

# 查看 Playwright 测试
cat /tmp/devflow-test-generator-demo/frontend/tests/e2e/demo-feature-M-01-F01.spec.ts

# 查看 Page Object
cat /tmp/devflow-test-generator-demo/frontend/tests/e2e/pages/DemoFeatureListPage.ts
```

---

## 在实际项目中使用

### 前提条件

1. ✅ 已完成 P2 详设，生成了 `.devflow/<feature>/design.json`
2. ✅ 已完成 P0 验收点冻结，生成了 `.devflow/<feature>/acceptance.json`
3. ✅ 项目目录结构符合约定：
   - 后端：`backend/<service>/src/test/java/`
   - 前端：`frontend/tests/e2e/`

### 使用方法

#### 方式 1：一键生成所有测试

```bash
bash scripts/generate_tests.sh <feature-name>
```

示例：
```bash
bash scripts/generate_tests.sh user-mgmt
```

#### 方式 2：只生成 JUnit 测试

```bash
bash scripts/generate_tests.sh <feature-name> --junit-only
```

#### 方式 3：只生成 Playwright 测试

```bash
bash scripts/generate_tests.sh <feature-name> --playwright-only
```

#### 方式 4：手动调用生成器

```bash
# JUnit
python3 scripts/generate_junit_tests.py \
  .devflow/user-mgmt/design.json \
  backend/user-service/src/test/java

# Playwright
python3 scripts/generate_playwright_tests.py \
  .devflow/user-mgmt/acceptance.json \
  frontend/tests/e2e
```

---

## 生成后的工作流

### 1. 查看生成的测试

```bash
# 查看生成的文件列表
find backend/*/src/test/java -name "*Test.java" -mmin -5
find frontend/tests/e2e -name "*.spec.ts" -mmin -5
```

### 2. 补充测试逻辑

生成的测试包含 `// TODO` 标记，需要补充：

**JUnit 测试**：
- Mock 服务的返回值
- 断言的具体值
- 复杂的业务逻辑测试

**Playwright 测试**：
- 调整选择器（根据实际 DOM 结构）
- 补充断言逻辑
- 添加等待条件

### 3. 运行测试

```bash
# JUnit 测试
cd backend/user-service
mvn test

# Playwright 测试
cd frontend
npx playwright test
```

### 4. TDD 循环

```
补充测试逻辑 → 运行测试（红灯）→ 实现功能 → 运行测试（绿灯）→ 重构
```

---

## Runtime Profile 使用

### 自动选择 Profile

devflow 在 P1 阶段会自动检测项目类型：

| 检测到的文件 | 选择的 Profile |
|-------------|---------------|
| `pom.xml` | java-spring-flyway |
| `package.json` + `express` | node-express-prisma |
| `requirements.txt` + `fastapi` | python-fastapi-sqlalchemy |

### 手动指定 Profile

```bash
bash scripts/devflow-state.sh init \
  --feature=user-mgmt \
  --profile=java-spring-flyway
```

### 查看当前 Profile

```bash
cat .devflow/<feature>/runtime-profile.json
```

### 自定义 Profile

1. 复制现有 Profile：
```bash
cp runtime-profiles/java-spring-flyway.json \
   runtime-profiles/my-custom-profile.json
```

2. 修改配置：
```json
{
  "profile_id": "my-custom-profile",
  "backend": {
    "build_adapter": {
      "command": "your-build-command"
    }
  }
}
```

3. 使用自定义 Profile：
```bash
bash scripts/devflow-state.sh init --profile=my-custom-profile
```

---

## 文档导航

| 文档 | 内容 | 长度 |
|-----|------|------|
| **QUICKSTART.md** | 快速开始（本文档） | 简短 |
| **runtime-profiles/README.md** | 入门指南 | 235 行 |
| **references/test-generators.md** | 完整文档（API、故障排查、扩展） | 577 行 |
| **v3.28-update-summary.md** | 更新总结 | 330 行 |
| **v3.28-demo-guide.md** | 功能演示 | 573 行 |

### 推荐阅读顺序

1. **新手**：QUICKSTART.md → runtime-profiles/README.md
2. **深入使用**：references/test-generators.md
3. **了解原理**：v3.28-demo-guide.md
4. **查看更新**：v3.28-update-summary.md

---

## 常见问题速查

### Q: 生成器报错 "找不到 design.json"
**A**: 确保已完成 P2 详设，并生成了结构化产物：
```bash
ls -la .devflow/<feature>/design.json
```

### Q: 生成的测试有语法错误
**A**: 
1. 检查 design.json 格式是否正确
2. 检查 Python 版本（需要 >= 3.8）
3. 查看生成器日志，找到具体错误

### Q: 如何跳过已存在的测试文件？
**A**: 生成器会自动跳过已存在的文件。如果需要重新生成，先删除旧文件：
```bash
rm backend/*/src/test/java/**/*Test.java
```

### Q: Playwright 生成的选择器不准确
**A**: 这是正常的。生成器使用通用选择器，需要根据实际 DOM 结构调整：
```typescript
// 生成的选择器
this.addButton = page.locator('button:has-text("新增")');

// 调整为更精确的选择器
this.addButton = page.locator('[data-testid="add-user-button"]');
```

### Q: 如何为小程序或 APP 生成测试？
**A**: 当前版本只支持 Web 的 Playwright 测试。小程序/APP 的 E2E 测试需要：
- 小程序：微信开发者工具的自动化接口
- APP：Appium + Playwright for Mobile

这些将在后续版本支持。

---

## 下一步

### 立即行动

- [ ] 运行 Demo：`bash scripts/demo_test_generator.sh`
- [ ] 查看生成的代码
- [ ] 在实际项目中试用

### 深入学习

- [ ] 阅读完整文档：`cat references/test-generators.md`
- [ ] 理解 Runtime Profile：`cat runtime-profiles/README.md`
- [ ] 查看功能演示：`cat v3.28-demo-guide.md`

### 贡献反馈

- [ ] 试用后提供反馈
- [ ] 报告 bug 或不合理的地方
- [ ] 为其他技术栈贡献 Profile

---

## 获取帮助

### 查看日志

```bash
# 生成器运行日志
bash scripts/generate_tests.sh user-mgmt 2>&1 | tee generate.log
```

### 验证环境

```bash
# 运行验证脚本
bash scripts/verify_test_generators.sh
```

### 联系维护者

如果遇到问题，请提供：
1. 错误信息（完整的 stack trace）
2. design.json 或 acceptance.json 内容
3. 项目的技术栈（Java/Node/Python）
4. 期望的输出

---

**版本**：v3.28.0  
**最后更新**：2026-09-20  
**维护者**：devflow team
