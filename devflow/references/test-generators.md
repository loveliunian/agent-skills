---
name: test-generators
version: "3.29.1"
description: 测试生成器使用指南——从 design.json 和 acceptance.json 自动生成 JUnit 和 Playwright 测试代码
---

# 测试生成器使用指南

## 概述

测试生成器是 devflow 的配套工具，用于从结构化产物自动生成测试代码骨架，减少测试编写的重复劳动。

### 生成能力

| 生成器 | 输入 | 输出 | 覆盖范围 |
|---|---|---|---|
| **JUnit Generator** | `design.json` | Java 单元测试 | Controller / Service / Mapper |
| **Playwright Generator** | `acceptance.json` | TypeScript E2E 测试 | UI 旅程 / API 测试 |

### 定位

- ✅ **生成测试骨架**：类结构、方法签名、基础断言
- ✅ **推断测试场景**：正常 / 边界 / 异常三类
- ✅ **生成 Page Objects**：从验收点推断页面对象
- ❌ **不生成完整测试逻辑**：复杂业务逻辑需人工补充
- ❌ **不生成测试数据**：seed 数据和 fixtures 需单独准备

## 1. Runtime Profile 集成

### 1.1 Profile 实例

已创建三个 Runtime Profile 实例：

```bash
runtime-profiles/
├── java-spring-flyway.json          # Java + Spring Boot + Flyway
├── node-express-prisma.json         # Node.js + Express + Prisma
└── python-fastapi-sqlalchemy.json   # Python + FastAPI + SQLAlchemy
```

### 1.2 Profile 字段说明

每个 Profile 定义以下能力位：

```json
{
  "profile_id": "java-spring-flyway",
  "backend": {
    "build_adapter": { "command": "mvn -q compile", ... },
    "test_adapter": { "command": "mvn test", ... },
    "coverage_adapter": {
      "command": "mvn jacoco:report",
      "threshold": { "core_business": 0.80 }
    }
  },
  "gate_bindings": {
    "P3-build": "backend.build_adapter",
    "P6-coverage": "backend.coverage_adapter"
  }
}
```

### 1.3 使用 Profile

在 P1 阶段冻结 Profile：

```bash
# 方式 1: 显式指定
bash scripts/devflow-state.sh init --feature=user-mgmt --profile=java-spring-flyway

# 方式 2: 从项目推断
# devflow 会读取 pom.xml / package.json 等事实源自动选择
```

## 2. JUnit 测试生成器

### 2.1 基本用法

```bash
# 生成所有测试
python3 scripts/generate_junit_tests.py \
  .devflow/user-mgmt/design.json \
  backend/user-service/src/test/java

# 通过集成脚本
bash scripts/generate_tests.sh user-mgmt --junit-only
```

### 2.2 生成内容

#### Controller 测试

**输入**（design.json）：
```json
{
  "apis": [
    {
      "endpoint": "/api/users",
      "method": "POST",
      "description": "创建用户",
      "request_fields": [
        { "name": "username", "type": "String", "required": true },
        { "name": "email", "type": "String", "required": true }
      ],
      "response_fields": [
        { "name": "id", "type": "Long" },
        { "name": "username", "type": "String" }
      ]
    }
  ]
}
```

**输出**（UserControllerTest.java）：
```java
@WebMvcTest(UserController.class)
class UserControllerTest {
    @Autowired
    private MockMvc mockMvc;
    
    @Test
    @WithMockUser(authorities = {"ROLE_ADMIN"})
    void testCreateUser_Success() throws Exception {
        mockMvc.perform(post("/api/users")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"username\":\"test\",\"email\":\"test@example.com\"}"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.id").exists())
            .andExpect(jsonPath("$.username").exists());
    }
    
    @Test
    @WithMockUser(authorities = {"ROLE_ADMIN"})
    void testValidation_MissingUsername() throws Exception {
        mockMvc.perform(post("/api/users")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"invalid\":\"data\"}"))
            .andExpect(status().isBadRequest());
    }
    
    @Test
    void testAuthorization_Unauthorized() throws Exception {
        mockMvc.perform(post("/api/users")
                .contentType(MediaType.APPLICATION_JSON))
            .andExpect(status().isUnauthorized());
    }
}
```

#### Service 测试

从 `rules[]` 生成业务规则测试：

```java
@ExtendWith(MockitoExtension.class)
class UserServiceTest {
    @InjectMocks
    private UserService userService;
    
    @Mock
    private UserMapper userMapper;
    
    @Test
    void testBusinessRule_R_001_NormalCase() {
        // Given
        // When
        // Then
        fail("测试用例待实现: 用户名唯一性校验");
    }
}
```

#### Mapper 测试

从 `tables[]` 生成数据访问层测试：

```java
@SpringBootTest
@Transactional
class UserMapperTest {
    @Autowired
    private UserMapper userMapper;
    
    @Test
    void testInsert() {
        User entity = new User();
        // TODO: 设置字段值
        
        int result = userMapper.insert(entity);
        
        assertEquals(1, result);
        assertNotNull(entity.getId());
    }
}
```

### 2.3 人工补充清单

生成后需要补充：

- [ ] Mock Service 的返回值
- [ ] 复杂业务规则的测试逻辑
- [ ] 实际的测试数据
- [ ] 更精确的断言

## 3. Playwright 测试生成器

### 3.1 基本用法

```bash
# 生成所有测试
python3 scripts/generate_playwright_tests.py \
  .devflow/user-mgmt/acceptance.json \
  frontend/tests/e2e

# 通过集成脚本
bash scripts/generate_tests.sh user-mgmt --playwright-only
```

### 3.2 生成内容

#### Page Object

**输入**（acceptance.json）：
```json
{
  "points": [
    {
      "id": "M-01-F01-A01",
      "description": "用户列表页面展示所有用户",
      "verify_method": "UI"
    },
    {
      "id": "M-01-F01-A02",
      "description": "点击新增按钮跳转到创建页面",
      "verify_method": "UI"
    }
  ]
}
```

**输出**（UserMgmtListPage.ts）：
```typescript
export class UserMgmtListPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly addButton: Locator;
  readonly table: Locator;
  
  constructor(page: Page) {
    this.page = page;
    this.heading = page.locator('h1').first();
    this.addButton = page.locator('button:has-text("新增")');
    this.table = page.locator('table');
  }
  
  async goto(path: string = '/user-mgmt') {
    await this.page.goto(path);
    await this.page.waitForLoadState('networkidle');
  }
  
  async clickAdd() {
    await this.addButton.click();
  }
  
  async getTableRowCount(): Promise<number> {
    return await this.table.locator('tbody tr').count();
  }
}
```

#### UI 测试规格

**输出**（user-mgmt-M-01-F01.spec.ts）：
```typescript
import { test, expect } from '@playwright/test';
import { UserMgmtListPage } from './pages/UserMgmtListPage';

test.describe('user-mgmt - M-01-F01', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/login');
    await page.fill('[name="username"]', 'test_user');
    await page.fill('[name="password"]', 'test_password');
    await page.click('button[type="submit"]');
    await page.waitForURL('**/');
  });

  test('M-01-F01-A01: 用户列表页面展示所有用户', async ({ page }) => {
    // Given
    const listPage = new UserMgmtListPage(page);
    await listPage.goto();
    await listPage.waitForPageLoad();
    
    // When
    // TODO: 根据验收点实现具体操作
    
    // Then
    // TODO: 添加断言
  });
  
  test('M-01-F01-A02: 点击新增按钮跳转到创建页面', async ({ page }) => {
    const listPage = new UserMgmtListPage(page);
    await listPage.goto();
    
    await listPage.clickAdd();
    
    await expect(page).toHaveURL(/.*\/create/);
  });
});
```

#### API 测试规格

从 `verify_method: "API"` 的验收点生成：

```typescript
test.describe('user-mgmt API Tests', () => {
  let authToken: string;

  test.beforeAll(async ({ request }) => {
    const response = await request.post('/api/auth/login', {
      data: { username: 'test_user', password: 'test_password' }
    });
    const body = await response.json();
    authToken = body.token;
  });

  test('M-01-F02-A03: API 创建用户返回 201', async ({ request }) => {
    const testData = {
      username: 'newuser',
      email: 'newuser@example.com'
    };
    
    const response = await request.post('/api/users', {
      data: testData
    });
    
    expect(response.ok()).toBeTruthy();
    const body = await response.json();
    expect(body.id).toBeDefined();
  });
});
```

### 3.3 人工补充清单

生成后需要补充：

- [ ] 调整 Page Object 的选择器（根据实际 UI）
- [ ] 实现具体的用户操作步骤
- [ ] 添加业务断言
- [ ] 处理异步等待和加载状态

## 4. 集成脚本用法

### 4.1 一键生成

```bash
# 同时生成 JUnit 和 Playwright
bash scripts/generate_tests.sh user-mgmt

# 只生成 JUnit
bash scripts/generate_tests.sh user-mgmt --junit-only

# 只生成 Playwright
bash scripts/generate_tests.sh user-mgmt --playwright-only
```

### 4.2 自定义输出路径

```bash
# 自定义后端输出
bash scripts/generate_tests.sh user-mgmt \
  --output-backend backend/user-service/src/test/java

# 自定义前端输出
bash scripts/generate_tests.sh user-mgmt \
  --output-frontend frontend/e2e-tests

# 指定 Profile
bash scripts/generate_tests.sh user-mgmt \
  --profile node-express-prisma
```

### 4.3 完整工作流

```bash
# 1. P2 详设完成后，生成单元测试骨架
bash scripts/generate_tests.sh user-mgmt --junit-only

# 2. P0 验收点冻结后，生成 E2E 测试骨架
bash scripts/generate_tests.sh user-mgmt --playwright-only

# 3. 补充测试逻辑
# - 编辑生成的 *Test.java 文件
# - 编辑生成的 *.spec.ts 文件

# 4. 运行测试
mvn test                          # JUnit
cd frontend && npx playwright test  # Playwright
```

## 5. Gate 集成

测试生成器与 devflow Gate 的集成点：

| Gate | 检查项 | 生成器作用 |
|---|---|---|
| **P5** | 测试用例数 ≥ 详设 | 生成足够的测试骨架 |
| **P6** | 单元测试覆盖率 ≥ 80% | 提供测试结构，加速达标 |
| **P6** | E2E 旅程覆盖 ≥ 95% | 生成验收点对应的 E2E 测试 |

生成器**不绕过** Gate 检查，只是提供初始代码框架。

## 6. 扩展指南

### 6.1 添加新 Profile

创建 `runtime-profiles/<your-profile>.json`：

```json
{
  "profile_id": "go-gin-gorm",
  "backend": {
    "language": "go",
    "framework": "gin",
    "test_adapter": {
      "command": "go test ./...",
      "working_dir": "backend"
    }
  }
}
```

### 6.2 自定义测试模板

修改生成器代码中的模板方法：

```python
# scripts/generate_junit_tests.py
def _build_controller_test_code(self, ...):
    # 修改此处的模板字符串
    return f"""package {package_name};
    // 你的自定义模板
    """
```

### 6.3 添加其他测试框架

参考现有生成器，创建新的生成器脚本：

```bash
scripts/
├── generate_junit_tests.py       # 已有
├── generate_playwright_tests.py  # 已有
├── generate_pytest_tests.py      # 可扩展
└── generate_go_tests.py          # 可扩展
```

## 7. 故障排查

### 7.1 生成器找不到输入文件

```
[ERROR] design.json 不存在: .devflow/user-mgmt/design.json
```

**解决**：确保已完成 P2 详设并生成了结构化产物：

```bash
# 检查文件是否存在
ls -la .devflow/user-mgmt/

# 重新生成产物
python3 scripts/df_pipeline.py design --feature=user-mgmt
```

### 7.2 生成的测试编译失败

**原因**：生成器使用的包名或类名与实际项目不符。

**解决**：修改生成器中的 `_infer_package_name()` 方法，或手工调整生成的代码。

### 7.3 Page Object 选择器不准确

**原因**：生成器从验收点描述推断选择器，可能与实际 UI 不符。

**解决**：这是正常的，生成器只提供骨架。需要：
1. 打开浏览器开发者工具
2. 复制实际元素的选择器
3. 替换 Page Object 中的选择器

## 8. 最佳实践

### 8.1 分层生成

不要一次性生成所有测试，按阶段分批：

```bash
# P3 开始时：生成 Mapper 层测试
# P3 中期：生成 Service 层测试
# P3 后期：生成 Controller 层测试
# P5 开始：生成 E2E 测试
```

### 8.2 渐进式补充

生成后立即补充一个测试，验证框架可用：

```bash
# 1. 生成测试
bash scripts/generate_tests.sh user-mgmt --junit-only

# 2. 补充一个最简单的测试
# 编辑 UserMapperTest.java 的 testInsert()

# 3. 立即运行验证
mvn test -Dtest=UserMapperTest#testInsert
```

### 8.3 与 TDD 结合

生成器可用于 TDD 的初始化阶段：

```bash
# 1. P2 详设冻结
# 2. 生成测试骨架
bash scripts/generate_tests.sh user-mgmt

# 3. 补充测试逻辑（先写测试）
# 4. 运行测试（红灯）
mvn test

# 5. 实现代码（绿灯）
# 6. 重构
```

## 9. 限制与已知问题

### 当前限制

1. **JUnit 生成器**
   - 只支持 JUnit 5 + Spring Boot
   - 不生成 @SpringBootTest 集成测试
   - Mock 配置需要手工调整

2. **Playwright 生成器**
   - 选择器推断基于关键词，准确率有限
   - 不支持复杂的用户交互流程
   - 测试数据需要手工准备

3. **通用问题**
   - 不处理测试数据的生命周期管理
   - 不生成测试 fixtures
   - 不处理测试间的依赖关系

### 路线图

- [ ] 支持更多测试框架（pytest、Go testing）
- [ ] 智能选择器推断（基于实际 DOM）
- [ ] 测试数据工厂生成器
- [ ] 与 seed.sql 集成
- [ ] 测试覆盖率可视化

## 10. 相关文档

- `references/runtime-profile.md` - Runtime Profile 契约
- `schemas/design.schema.json` - design.json 规范
- `schemas/acceptance.schema.json` - acceptance.json 规范
- `concepts/core.md` - devflow 核心原则

---

**版本**: 1.0.0  
**最后更新**: 2026-09-20  
**维护者**: devflow team
