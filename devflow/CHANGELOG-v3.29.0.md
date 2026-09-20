# devflow v3.29.0 更新总结

**发布日期**: 2026-09-20
**版本**: v3.29.0
**类型**: Feature Release（P2 详设前端测试锚点冻结）

---

## 🎯 核心变更：前端交互控件测试锚点（test_anchor / data-testid）

### 问题背景

P2 详设对前端只冻结了「长什么样、调什么接口」（页面清单/表单控件/弹窗/操作表），
但**没有冻结测试定位信息**：下游 P5 测试用例与 P6e E2E（`generate_playwright_tests.py`）
只能从验收点描述"猜"选择器（placeholder/文本/CSS 层级），实现随手写、测试随手改，
自动化用例天然脆弱且无法对账。

### 变更内容（五处）

1. **`schemas/design.schema.json`**：
   - `pages[].form_controls[]` 增加 `test_anchor`（**required**，pattern
     `^[a-z][a-z0-9]*(-[a-z0-9]+)+$`）；
   - `pages[].dialogs[]` 增加 `test_anchor`（**required**）；
   - `pages[]` 新增 `actions[]` 数组——页面/工具栏/行操作/批量**操作按钮正本**
     （required: name/type/test_anchor；可选 permission/api/dialog）；
2. **`scripts/df_validate.py`**：
   - test_anchor **全文档唯一**机检（跨 form_controls/dialogs/actions）；
   - `actions[].api` 锚点闭环到 `apis[]`（悬空即 FAIL）、`actions[].dialog`
     必须存在于同页 `dialogs[].name`；
   - `--doc` 对账：§7.2 表单控件规格表 / 弹窗·抽屉表 / 操作表的「测试锚点」列
     与 JSON 同源（缺列/漂移即 FAIL）；
3. **模板（完整版 + 总分分文档）**：§7.2 操作表 / 弹窗·抽屉表 / 表单控件规格表
   增「测试锚点」列；节首备注冻结命名公式
   `<feature缩写>-p<页面序号>-<类型>-<名称slug>`（类型枚举
   input/select/date/switch/btn/dialog/row，如 `orgm-p1-input-name`）；
4. **阶段文档**：`phases/02-详细设计.md` 前端契约写明测试锚点必填与唯一性机检；
   `phases/05-测试用例.md` E2E 选择器规范改为"只允许引用详设冻结锚点
   （`[data-testid=…]`），禁止从描述猜测"；
5. **`scripts/generate_playwright_tests.py`**：优先消费同目录 `design.json` 的
   `pages[].form_controls/dialogs/actions[].test_anchor`，在 Page Object 生成
   `ANCHORS` 常量 + `anchor(key)` 定位方法（`getByTestId`）；design.json 缺失时
   回退原描述推断路径（不破坏既有行为）。

### 机检口径（fail-closed）

| 违规 | 拦截点 |
|------|--------|
| form_controls/dialogs 缺 `test_anchor` | schema required |
| `test_anchor` 命名非法（大写/下划线/单词） | schema pattern |
| `test_anchor` 全文档重复 | df_validate `check_page_specs` |
| `actions[].api` 悬空 / `actions[].dialog` 不在同页 dialogs | df_validate `check_page_specs` |
| §7.2 表格「测试锚点」列缺失或与 JSON 漂移 | df_validate `check_page_specs_doc` |

### 回归验证

- `examples/structured/design.sample.json`（含 test_anchor + actions）全量校验 exit=0；
- 人为删除 test_anchor / 重复 / 命名非法 / api·dialog 悬空 / 文档缺列：全部被拦截；
- `generate_playwright_tests.py` 冒烟：8 个冻结锚点生成 `ANCHORS` + `anchor()`。
- 顺带修复：`design.skeleton.md` 补 `### 2.2`/`### 3.2`/`### 7.2` 三个缺失父级标题
  （v3.28.3 L-HIER-1 自测样例自身不合规）。

### 兼容性

**破坏性**：存量 design.json 的 form_controls/dialogs 若无 `test_anchor` 将 Gate FAIL——
按迁移说明补齐锚点即可（模板版本对账机制会强制升级）。实现侧 `data-testid` 与详设的
一致性检查（P3b/P6c）留待下一版本。
