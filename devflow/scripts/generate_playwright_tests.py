#!/usr/bin/env python3

def _safe_pascal(v: str) -> str:
    """类名安全化（v3.30.10：_to_pascal_case 只切空白——引号/花括号直通[第5轮审计]）"""
    import re as _re
    cleaned = _re.sub(r"[^A-Za-z0-9 ]", " ", str(v))
    words = [w for w in cleaned.split() if w]
    out = "".join(w.capitalize() for w in words)
    return out or "Page"



def ts_doc(v: str) -> str:
    """TS 块注释安全化（v3.30.9：*/ 闭注释注入收口）"""
    return ts_str(v).replace("*/", "*\u2044")


def ts_str(v: str) -> str:
    """TS 双引号字符串字面量转义（v3.30.8：PRD 自由文本→生成代码的注入面收口）"""
    return str(v).replace("\\", "\\\\").replace("'", "\\'").replace('"', '\\"').replace("\n", "\\n").replace("\r", "").replace("`", "\\`")

def safe_feature(v: str) -> str:
    import re as _re
    m = _re.sub(r"[^A-Za-z0-9._-]", "_", str(v))
    return m or "feature"


"""
测试生成器：从 acceptance.json 生成 Playwright E2E 测试

输入：.devflow/<feature>/acceptance.json
输出：frontend/tests/e2e/<feature>/*.spec.ts

生成规则：
1. 每个验收点生成对应的 E2E 测试用例
2. 按验证方式分组：UI 验收点生成 Playwright 测试，API 验收点生成 API 测试
3. 覆盖用户旅程的关键路径
4. 自动生成 Page Object 模式的页面对象
"""

import json
import sys
import os
from pathlib import Path
from typing import Dict, List, Any
from datetime import datetime
from collections import defaultdict


class PlaywrightTestGenerator:
    def __init__(self, acceptance_json_path: str, output_base: str):
        self.acceptance_json_path = acceptance_json_path
        self.output_base = Path(output_base)
        self.acceptance_data = None
        self.feature = None
        self.ui_points = []
        self.api_points = []
        self.design_anchors: List[Dict[str, Any]] = []
        
    def load_acceptance(self):
        """加载 acceptance.json"""
        with open(self.acceptance_json_path, 'r', encoding='utf-8') as f:
            self.acceptance_data = json.load(f)
        self.feature = self.acceptance_data.get('feature', 'unknown')
        # 详设冻结测试锚点（design.json 同目录优先消费）
        self.design_anchors = self._load_design_anchors()
        
        # 按验证方式分组
        points = self.acceptance_data.get('points', [])
        for point in points:
            verify_method = point.get('verify_method', 'UI')
            if verify_method == 'UI':
                self.ui_points.append(point)
            elif verify_method == 'API':
                self.api_points.append(point)
        
    def generate_all_tests(self):
        """生成所有 E2E 测试"""
        if not self.acceptance_data:
            raise ValueError("acceptance.json 未加载")
            
        print(f"[INFO] 开始生成 {safe_feature(self.feature)} 的 Playwright E2E 测试...")
        
        # 1. 生成 Page Objects
        self._generate_page_objects()
        
        # 2. 生成 UI 测试
        if self.ui_points:
            self._generate_ui_tests()
        
        # 3. 生成 API 测试
        if self.api_points:
            self._generate_api_tests()
        
        # 4. 生成测试配置
        self._generate_test_config()
        
        print(f"[INFO] E2E 测试生成完成")
        
    def _generate_page_objects(self):
        """生成 Page Object 类"""
        # 根据验收点推断需要的页面对象
        pages = self._infer_pages_from_acceptance()
        
        for page_name, selectors in pages.items():
            self._generate_page_object(page_name, selectors)
    
    def _infer_pages_from_acceptance(self) -> Dict[str, List[str]]:
        """从验收点推断页面和选择器"""
        pages = defaultdict(list)
        
        for point in self.ui_points:
            description = point.get('description', '')
            point_id = point.get('id', '')
            
            # 简单推断：从描述中提取页面名称
            if '列表' in description or 'list' in description.lower():
                pages['ListPage'].append(f"// {ts_doc(point_id)}: {ts_doc(description)}")
            elif '新增' in description or '创建' in description or 'create' in description.lower():
                pages['CreatePage'].append(f"// {ts_doc(point_id)}: {ts_doc(description)}")
            elif '编辑' in description or '修改' in description or 'edit' in description.lower():
                pages['EditPage'].append(f"// {ts_doc(point_id)}: {ts_doc(description)}")
            elif '详情' in description or 'detail' in description.lower():
                pages['DetailPage'].append(f"// {ts_doc(point_id)}: {ts_doc(description)}")
            else:
                pages['CommonPage'].append(f"// {ts_doc(point_id)}: {ts_doc(description)}")
        
        return pages
    
    def _load_design_anchors(self) -> List[Dict[str, Any]]:
        """优先消费详设冻结的测试锚点（design.json pages[] 正本）。

        与 acceptance.json 同目录的 design.json 存在且含 pages[] 时，收集
        form_controls/dialogs/actions 的 test_anchor 作为 Page Object 定位符；
        读不到/解析失败回退到描述推断路径（不破坏现有行为）。"""
        try:
            design_path = Path(self.acceptance_json_path).parent / 'design.json'
            if not design_path.exists():
                return []
            with open(design_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            anchors: List[Dict[str, Any]] = []
            for p in data.get('pages') or []:
                for c in p.get('form_controls') or []:
                    anchors.append({'page': p.get('name', ''), 'kind': 'control',
                                    'label': c.get('label') or c.get('field', ''),
                                    'anchor': c.get('test_anchor')})
                for a in p.get('actions') or []:
                    anchors.append({'page': p.get('name', ''), 'kind': 'action',
                                    'label': a.get('name', ''),
                                    'anchor': a.get('test_anchor')})
                for d in p.get('dialogs') or []:
                    anchors.append({'page': p.get('name', ''), 'kind': 'dialog',
                                    'label': d.get('name', ''),
                                    'anchor': d.get('test_anchor')})
            anchors = [x for x in anchors if x.get('anchor')]
            if anchors:
                print(f"[INFO] 已从 design.json 加载 {len(anchors)} 个冻结测试锚点（data-testid）")
            return anchors
        except (OSError, ValueError) as e:
            print(f"[WARN] design.json 测试锚点加载失败，回退到推断选择器: {e}")
            return []

    def _anchor_members_block(self) -> str:
        """按冻结锚点生成 Page Object 追加成员（ANCHORS 常量 + anchor() 定位方法）。"""
        if not self.design_anchors:
            return ""
        entries = ",\n".join(
            f"    // {ts_doc(a['page'])} · {a['kind']} · {ts_doc(a['label'])}\n"
            f"    '{a['anchor']}': '{a['anchor']}'"
            for a in self.design_anchors
        )
        return f"""
  // ---- 详设冻结测试锚点（design.json 正本；测试定位一律走 anchor()，禁止改用猜测选择器）----
  static readonly ANCHORS = {{
{entries},
  }} as const;

  /** 按详设冻结锚点定位控件（data-testid，P2 详设冻结、P5/P6e 只读消费） */
  anchor(key: string): Locator {{
    const anchors = (this.constructor as unknown as {{ ANCHORS: Record<string, string> }}).ANCHORS;
    const testId = anchors[key];
    if (!testId) {{
      throw new Error(`未知测试锚点: ${{key}}（详设未冻结，禁止自造选择器）`);
    }}
    return this.page.getByTestId(testId);
  }}
"""

    def _generate_page_object(self, page_name: str, comments: List[str]):
        """生成单个 Page Object"""
        feature_pascal = _safe_pascal(self.feature)
        class_name = f"{feature_pascal}{page_name}"
        
        page_code = f"""import {{ Page, Locator }} from '@playwright/test';

/**
 * {class_name} - Page Object
 * 
 * 生成时间: {datetime.now().isoformat()}
 * 功能模块: {safe_feature(self.feature)}
 * 
 * 相关验收点:
{chr(10).join(' * ' + c for c in comments)}
 */
export class {class_name} {{
  readonly page: Page;
  
  // 页面元素选择器
  readonly heading: Locator;
  readonly searchInput: Locator;
  readonly searchButton: Locator;
  readonly addButton: Locator;
  readonly table: Locator;
  readonly firstRow: Locator;
  readonly editButton: Locator;
  readonly deleteButton: Locator;
  readonly saveButton: Locator;
  readonly cancelButton: Locator;
  readonly messageToast: Locator;

  constructor(page: Page) {{
    this.page = page;
    
    // 初始化选择器（根据实际页面调整）
    this.heading = page.locator('h1, h2').first();
    this.searchInput = page.locator('input[placeholder*="搜索"], input[placeholder*="查询"]');
    this.searchButton = page.locator('button:has-text("搜索"), button:has-text("查询")');
    this.addButton = page.locator('button:has-text("新增"), button:has-text("添加"), button:has-text("创建")');
    this.table = page.locator('table, .el-table, .ant-table');
    this.firstRow = this.table.locator('tbody tr').first();
    this.editButton = page.locator('button:has-text("编辑")').first();
    this.deleteButton = page.locator('button:has-text("删除")').first();
    this.saveButton = page.locator('button:has-text("保存"), button:has-text("确定")');
    this.cancelButton = page.locator('button:has-text("取消")');
    this.messageToast = page.locator('.el-message, .ant-message, [role="alert"]');
  }}

  /**
   * 导航到页面
   */
  async goto(path: string = '/{safe_feature(self.feature)}') {{
    await this.page.goto(path);
    await this.page.waitForLoadState('networkidle');
  }}

  /**
   * 等待页面加载完成
   */
  async waitForPageLoad() {{
    await this.heading.waitFor({{ state: 'visible' }});
  }}

  /**
   * 搜索
   */
  async search(keyword: string) {{
    await this.searchInput.fill(keyword);
    await this.searchButton.click();
    await this.page.waitForLoadState('networkidle');
  }}

  /**
   * 点击新增按钮
   */
  async clickAdd() {{
    await this.addButton.click();
  }}

  /**
   * 点击第一行的编辑按钮
   */
  async clickEditFirstRow() {{
    await this.firstRow.locator('button:has-text("编辑")').click();
  }}

  /**
   * 点击第一行的删除按钮
   */
  async clickDeleteFirstRow() {{
    await this.firstRow.locator('button:has-text("删除")').click();
  }}

  /**
   * 填写表单（通用）
   */
  async fillForm(data: Record<string, string>) {{
    for (const [field, value] of Object.entries(data)) {{
      const input = this.page.locator(`[name="${{field}}"], [placeholder*="${{field}}"]`);
      await input.fill(value);
    }}
  }}

  /**
   * 保存表单
   */
  async save() {{
    await this.saveButton.click();
    await this.page.waitForLoadState('networkidle');
  }}

  /**
   * 取消操作
   */
  async cancel() {{
    await this.cancelButton.click();
  }}

  /**
   * 获取成功提示消息
   */
  async getSuccessMessage(): Promise<string> {{
    await this.messageToast.waitFor({{ state: 'visible' }});
    return await this.messageToast.textContent() || '';
  }}

  /**
   * 验证表格行数
   */
  async getTableRowCount(): Promise<number> {{
    return await this.table.locator('tbody tr').count();
  }}

  /**
   * 验证表格中是否包含文本
   */
  async tableContainsText(text: string): Promise<boolean> {{
    const tableText = await this.table.textContent();
    return tableText?.includes(text) || false;
  }}
{self._anchor_members_block()}}}
"""
        
        output_path = self.output_base / "pages" / f"{class_name}.ts"
        self._write_file(output_path, page_code)
    
    def _generate_ui_tests(self):
        """生成 UI 测试规格"""
        feature_pascal = _safe_pascal(self.feature)
        
        # 按功能分组
        grouped = defaultdict(list)
        for point in self.ui_points:
            point_id = point.get('id', '')
            # 提取功能号 M-XX-FYY
            if point_id.startswith('M-'):
                parts = point_id.split('-')
                if len(parts) >= 3:
                    feature_num = f"{parts[0]}-{parts[1]}-{parts[2]}"
                    grouped[feature_num].append(point)
        
        for feature_num, points in grouped.items():
            self._generate_ui_test_spec(feature_num, points)
    
    def _generate_ui_test_spec(self, feature_num: str, points: List[Dict]):
        """生成单个 UI 测试规格文件"""
        feature_pascal = _safe_pascal(self.feature)
        
        # 生成测试用例
        test_cases = []
        for point in points:
            point_id = point.get('id', '')
            description = point.get('description', '')
            
            test_case = f"""  test('{ts_str(point_id)}: {ts_str(description)}', async ({{ page }}) => {{
    // Given: 准备测试环境
    const listPage = new {feature_pascal}ListPage(page);
    await listPage.goto();
    await listPage.waitForPageLoad();
    
    // When: 执行用户操作
    // TODO: 根据验收点实现具体操作
    
    // Then: 验证结果
    // TODO: 添加断言
    // await expect(page.locator('...')).toBeVisible();
  }});
"""
            test_cases.append(test_case)
        
        spec_code = f"""import {{ test, expect }} from '@playwright/test';
import {{ {feature_pascal}ListPage }} from './pages/{feature_pascal}ListPage';
import {{ {feature_pascal}CreatePage }} from './pages/{feature_pascal}CreatePage';
import {{ {feature_pascal}EditPage }} from './pages/{feature_pascal}EditPage';

/**
 * {safe_feature(self.feature)} E2E 测试 - {feature_num}
 * 
 * 生成时间: {datetime.now().isoformat()}
 * 验收点数量: {len(points)}
 */

test.describe('{safe_feature(self.feature)} - {feature_num}', () => {{
  test.beforeEach(async ({{ page }}) => {{
    // 登录并设置测试环境
    // TODO: 实现登录逻辑
    await page.goto('/login');
    await page.fill('[name="username"]', 'test_user');
    await page.fill('[name="password"]', 'test_password');
    await page.click('button[type="submit"]');
    await page.waitForURL('**/');
  }});

{chr(10).join(test_cases)}
}});
"""
        
        output_path = self.output_base / f"{safe_feature(self.feature)}-{feature_num}.spec.ts"
        self._write_file(output_path, spec_code)
    
    def _generate_api_tests(self):
        """生成 API 测试规格"""
        feature_pascal = _safe_pascal(self.feature)
        
        test_cases = []
        for point in self.api_points:
            point_id = point.get('id', '')
            description = point.get('description', '')
            
            test_case = f"""  test('{ts_str(point_id)}: {ts_str(description)}', async ({{ request }}) => {{
    // Given: 准备测试数据
    const testData = {{
      // TODO: 根据验收点填充数据
    }};
    
    // When: 调用 API
    const response = await request.post('/api/{safe_feature(self.feature)}', {{
      data: testData
    }});
    
    // Then: 验证响应
    expect(response.ok()).toBeTruthy();
    const body = await response.json();
    // TODO: 添加响应断言
  }});
"""
            test_cases.append(test_case)
        
        spec_code = f"""import {{ test, expect }} from '@playwright/test';

/**
 * {safe_feature(self.feature)} API 测试
 * 
 * 生成时间: {datetime.now().isoformat()}
 * 验收点数量: {len(self.api_points)}
 */

test.describe('{safe_feature(self.feature)} API Tests', () => {{
  let authToken: string;

  test.beforeAll(async ({{ request }}) => {{
    // 获取认证令牌
    const response = await request.post('/api/auth/login', {{
      data: {{
        username: 'test_user',
        password: 'test_password'
      }}
    }});
    const body = await response.json();
    authToken = body.token;
  }});

{chr(10).join(test_cases)}
}});
"""
        
        output_path = self.output_base / f"{safe_feature(self.feature)}-api.spec.ts"
        self._write_file(output_path, spec_code)
    
    def _generate_test_config(self):
        """生成 Playwright 配置文件"""
        config_code = f"""import {{ defineConfig, devices }} from '@playwright/test';

/**
 * Playwright 配置
 * 
 * 生成时间: {datetime.now().isoformat()}
 * 功能: {safe_feature(self.feature)}
 */
export default defineConfig({{
  testDir: './tests/e2e',
  
  /* 最大失败次数 */
  maxFailures: 5,
  
  /* 并行工作进程数 */
  workers: process.env.CI ? 1 : 4,
  
  /* Reporter */
  reporter: [
    ['html', {{ outputFolder: 'test-results/e2e-report' }}],
    ['json', {{ outputFile: 'test-results/e2e-results.json' }}],
    ['list']
  ],

  /* 全局设置 */
  use: {{
    /* 基础 URL */
    baseURL: process.env.BASE_URL || 'http://localhost:3000',
    
    /* 截图 */
    screenshot: 'only-on-failure',
    
    /* 视频 */
    video: 'retain-on-failure',
    
    /* 追踪 */
    trace: 'on-first-retry',
  }},

  /* 项目配置 */
  projects: [
    {{
      name: 'chromium',
      use: {{ ...devices['Desktop Chrome'] }},
    }},

    {{
      name: 'firefox',
      use: {{ ...devices['Desktop Firefox'] }},
    }},

    {{
      name: 'webkit',
      use: {{ ...devices['Desktop Safari'] }},
    }},

    /* 移动端 */
    {{
      name: 'Mobile Chrome',
      use: {{ ...devices['Pixel 5'] }},
    }},
  ],

  /* 本地开发服务器 */
  webServer: {{
    command: 'npm run dev',
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI,
  }},
}});
"""
        
        output_path = self.output_base.parent / "playwright.config.ts"
        if not output_path.exists():  # 只在不存在时创建
            self._write_file(output_path, config_code)
            print(f"[INFO] 配置文件已生成（如已存在则跳过）")
    
    def _write_file(self, output_path: Path, content: str):
        """写入文件"""
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"[GENERATED] {output_path}")
    
    def _to_pascal_case(self, text: str) -> str:
        """转换为帕斯卡命名"""
        words = text.replace('-', ' ').replace('_', ' ').split()
        return ''.join(word.capitalize() for word in words)


def main():
    if len(sys.argv) < 3:
        print("用法: python generate_playwright_tests.py <acceptance.json路径> <输出目录>")
        print("示例: python generate_playwright_tests.py .devflow/user-mgmt/acceptance.json frontend/tests/e2e")
        sys.exit(1)
    
    acceptance_json_path = sys.argv[1]
    output_base = sys.argv[2]
    
    if not os.path.exists(acceptance_json_path):
        print(f"[ERROR] acceptance.json 不存在: {acceptance_json_path}")
        sys.exit(1)
    
    generator = PlaywrightTestGenerator(acceptance_json_path, output_base)
    generator.load_acceptance()
    generator.generate_all_tests()
    
    print("\n[SUCCESS] Playwright E2E 测试生成完成")
    print(f"[INFO] 下一步:")
    print(f"  1. 调整 Page Object 中的选择器")
    print(f"  2. 补充测试用例的 TODO 部分")
    print(f"  3. 运行测试: npx playwright test")


if __name__ == '__main__':
    main()
