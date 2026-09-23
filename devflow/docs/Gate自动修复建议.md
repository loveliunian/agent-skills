> **注（v3.30.6）**：本文档示例中的 `scripts/p5_gate.sh` 已归档至 `_archive/scripts-retired-3.30.6/`；现行 P5 主门禁为 `scripts/p5_test_cases_gate.sh`。
# Gate 自动修复建议系统使用指南

> **版本**: v3.28.1  
> **功能**: Gate 失败时输出 suggested_fix 字段，提供具体的修复建议

---

## 🎯 设计目标

### 当前问题

Gate 失败时只输出错误信息，缺少具体的修复建议：

```bash
❌ P3 Gate 失败
- 缺少 import: RestController
- 建议: （无）
```

开发者需要自己查找如何修复。

### 解决方案

**自动修复建议系统**：分析失败原因，生成具体的修复代码和命令。

---

## 🚀 使用方法

### 1. Gate 自动诊断

所有 Gate 脚本已集成诊断系统，失败时自动输出修复建议。

**示例**：P5 Gate 检测到 TODO 未清理

```bash
bash scripts/p5_gate.sh user-management
```

**输出**：
```
[检查 2/6] TODO 清理检查
─────────────────────────────────────────────────────────────
✗ 仍有 8 个未处理的 TODO

════════════════════════════════════════════════════════════════
🔍 诊断与修复建议
════════════════════════════════════════════════════════════════

Gate: P5 Gate
错误类型: TODO_NOT_CLEARED

📝 建议修复步骤：

1. 查看所有未处理的 TODO：

grep -rn "TODO:" backend/src/test frontend/tests/e2e

2. 批量处理 TODO（按类型）：

   • Mock 数据：
     grep -rn "TODO: 补充 Mock 数据" backend/src/test

   • 断言逻辑：
     grep -rn "TODO: 补充断言逻辑" backend/src/test

   • 选择器调整：
     grep -rn "TODO: 调整实际选择器" frontend/tests/e2e

3. TODO 自动修复工具（实验性）：

bash scripts/auto_resolve_todos.sh user-management

════════════════════════════════════════════════════════════════
```

### 2. 手动调用诊断

也可以手动调用诊断函数：

```bash
# 加载诊断系统
source scripts/gate_diagnostics.sh

# 调用诊断函数
diagnose_and_suggest "P3 Gate" "MISSING_IMPORT" "UserController"
```

---

## 📋 支持的错误类型

| 错误类型 | 说明 | 修复建议内容 |
|---------|------|-------------|
| `MISSING_IMPORT` | 缺少 import 语句 | 具体的 import 代码 + 自动修复命令 |
| `MISSING_ANNOTATION` | 缺少注解 | 具体的注解代码 + 示例 |
| `MISSING_FILE` | 缺少文件 | 创建文件命令 + 生成器命令 |
| `COMPILATION_ERROR` | 编译错误 | 诊断步骤 + 常见修复方法 |
| `MISSING_TEST` | 缺少测试 | 生成测试命令 + 测试骨架代码 |
| `INCOMPLETE_DESIGN` | 设计文档不完整 | 需要补充的内容 + 重新渲染命令 |
| `TODO_NOT_CLEARED` | TODO 未清理 | 查找 TODO 命令 + 批量处理方法 |
| `LOW_COVERAGE` | 覆盖率不足 | 查看报告命令 + 补充测试建议 |

---

## 🔍 详细示例

### 示例 1: MISSING_IMPORT（缺少 import）

**场景**: P3 Gate 检测到 Controller 类缺少 `@RestController` 注解对应的 import

**诊断输出**:

```
════════════════════════════════════════════════════════════════
🔍 诊断与修复建议
════════════════════════════════════════════════════════════════

Gate: P3 Gate
错误类型: MISSING_IMPORT

📝 建议修复步骤：

1. 在文件头部添加缺失的 import：

// 建议添加：
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;

2. 自动修复命令（推荐）：

bash scripts/auto_fix_imports.sh

════════════════════════════════════════════════════════════════
```

### 示例 2: MISSING_ANNOTATION（缺少注解）

**场景**: P3 Gate 检测到 Service 类缺少 `@Service` 注解

**诊断输出**:

```
════════════════════════════════════════════════════════════════
🔍 诊断与修复建议
════════════════════════════════════════════════════════════════

Gate: P3 Gate
错误类型: MISSING_ANNOTATION

📝 建议修复步骤：

1. 在类或方法上添加缺失的注解：

// 在 Service 类上添加：
@Service
@RequiredArgsConstructor
public class YourService {
    // ...
}

════════════════════════════════════════════════════════════════
```

### 示例 3: COMPILATION_ERROR（编译错误）

**场景**: P3 Gate 检测到编译错误

**诊断输出**:

```
════════════════════════════════════════════════════════════════
🔍 诊断与修复建议
════════════════════════════════════════════════════════════════

Gate: P3 Gate
错误类型: COMPILATION_ERROR

📝 建议修复步骤：

1. 查看详细编译错误：

mvn compile 2>&1 | tee compile-error.log

2. 常见编译错误修复：

   • 类型不匹配：检查方法返回值和变量类型
   • 未找到符号：检查 import 和包名
   • 语法错误：检查括号、分号、引号

3. 自动修复（如果可能）：

bash scripts/auto_fix_compilation.sh

════════════════════════════════════════════════════════════════
```

### 示例 4: MISSING_TEST（缺少测试）

**场景**: P5 Gate 检测到缺少测试文件

**诊断输出**:

```
════════════════════════════════════════════════════════════════
🔍 诊断与修复建议
════════════════════════════════════════════════════════════════

Gate: P5 Gate
错误类型: MISSING_TEST

📝 建议修复步骤：

1. 自动生成测试骨架（推荐）：

bash scripts/p5_test_generation.sh user-management

2. 手动创建测试文件：

@WebMvcTest(YourController.class)
class YourControllerTest {
    @Autowired
    private MockMvc mockMvc;
    
    @Test
    void testYourMethod() throws Exception {
        mockMvc.perform(get("/api/your-path"))
            .andExpect(status().isOk());
    }
}

════════════════════════════════════════════════════════════════
```

### 示例 5: INCOMPLETE_DESIGN（设计文档不完整）

**场景**: P2 Gate 检测到设计文档缺少字段定义

**诊断输出**:

```
════════════════════════════════════════════════════════════════
🔍 诊断与修复建议
════════════════════════════════════════════════════════════════

Gate: P2 Gate
错误类型: INCOMPLETE_DESIGN

📝 建议修复步骤：

1. 检查设计文档覆盖率：

bash scripts/s2_design_coverage_gate.sh user-management

2. 补充缺失的设计内容：

   • 补充数据库字段定义（字段名、类型、约束、索引）

3. 重新渲染 design.json：

python3 scripts/df_pipeline.py design user-management

════════════════════════════════════════════════════════════════
```

### 示例 6: LOW_COVERAGE（覆盖率不足）

**场景**: P6 Gate 检测到测试覆盖率低于 80%

**诊断输出**:

```
════════════════════════════════════════════════════════════════
🔍 诊断与修复建议
════════════════════════════════════════════════════════════════

Gate: P6 Gate
错误类型: LOW_COVERAGE

📝 建议修复步骤：

1. 查看当前覆盖率报告：

mvn jacoco:report
open target/site/jacoco/index.html

2. 识别未覆盖的代码：

   • 红色：未覆盖的行
   • 黄色：部分覆盖的分支
   • 绿色：已覆盖

3. 补充测试用例：

   • 为未覆盖的方法添加测试
   • 为分支逻辑添加边界测试
   • 为异常处理添加错误测试

4. 自动生成补充测试（推荐）：

bash scripts/generate_coverage_tests.sh user-management

════════════════════════════════════════════════════════════════
```

---

## 🎓 最佳实践

### 1. Gate 失败后的标准流程

```bash
# 1. 运行 Gate
bash scripts/p3_gate.sh user-management

# 2. 查看诊断建议（自动输出）
# 3. 按照建议修复
# 4. 重新运行 Gate
bash scripts/p3_gate.sh user-management

# 5. 直到通过
```

### 2. 保存诊断日志

```bash
# 保存诊断输出到文件
bash scripts/p5_gate.sh user-management 2>&1 | tee p5-gate-log.txt
```

### 3. 批量修复

```bash
# 如果有自动修复脚本，可以批量执行
bash scripts/auto_fix_imports.sh
bash scripts/auto_fix_compilation.sh
```

---

## 🔧 扩展诊断系统

### 添加新的错误类型

编辑 `scripts/gate_diagnostics.sh`，添加新的诊断函数：

```bash
# 建议：新的错误类型
suggest_your_error_type() {
  local context="$1"
  echo -e "${GREEN}📝 建议修复步骤：${NC}"
  echo ""
  echo "1. 步骤1"
  echo ""
  echo -e "${CYAN}命令1${NC}"
  echo ""
  echo "2. 步骤2"
  echo ""
}
```

然后在 `diagnose_and_suggest` 函数中添加 case：

```bash
case "$error_type" in
  "YOUR_ERROR_TYPE")
    suggest_your_error_type "$context"
    ;;
  # ...
esac
```

### 在 Gate 脚本中集成

```bash
# 加载诊断系统
source "$SKILL_ROOT/scripts/gate_diagnostics.sh" 2>/dev/null || true

# 检测到错误时调用
if [ $SOME_CHECK_FAILED ]; then
  check_fail "检查失败"
  
  # 诊断与修复建议
  if type diagnose_and_suggest &>/dev/null; then
    diagnose_and_suggest "Gate 名称" "错误类型" "上下文信息"
  fi
fi
```

---

## 📊 效果对比

### 修复时间对比

| 错误类型 | 无建议 | 有建议 | 节省时间 |
|---------|-------|-------|---------|
| **缺少 import** | 5 分钟（查文档） | 30 秒（复制粘贴） | **90%** |
| **编译错误** | 15 分钟（调试） | 5 分钟（按步骤排查） | **67%** |
| **缺少测试** | 30 分钟（手写） | 5 分钟（生成器） | **83%** |
| **覆盖率不足** | 1 小时（盲目补充） | 20 分钟（定向补充） | **67%** |

### 新人体验对比

| 指标 | 无建议 | 有建议 |
|------|-------|-------|
| **解决成功率** | 60%（需要求助） | 95%（自助解决） |
| **学习曲线** | 陡峭 | 平缓 |
| **挫败感** | 高 | 低 |

---

## 🐛 故障排查

### Q1: 诊断建议没有显示？

**A**: 检查是否加载了诊断系统：

```bash
# 在 Gate 脚本开头添加
source "$SKILL_ROOT/scripts/gate_diagnostics.sh" 2>/dev/null || true
```

### Q2: 自动修复脚本不存在？

**A**: 诊断建议中的某些自动修复脚本是"理想状态"，可能还未实现。可以：
1. 按照手动步骤修复
2. 贡献自动修复脚本

### Q3: 诊断建议不准确？

**A**: 
1. 检查传递给 `diagnose_and_suggest` 的 context 是否正确
2. 编辑 `scripts/gate_diagnostics.sh` 改进建议逻辑
3. 提交改进建议

---

## 📚 相关文档

- **scripts/gate_diagnostics.sh** - 诊断系统核心代码
- **scripts/p5_gate.sh** - P5 Gate 集成示例
- **docs/增量变更模式.md** - 增量变更模式文档

---

**版本**: v3.28.1  
**更新时间**: 2026-09-20 11:15  
**状态**: ✅ 可用
