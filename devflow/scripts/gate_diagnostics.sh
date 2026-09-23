#!/usr/bin/env bash
# Gate 诊断与修复建议系统 v3.30.5
# 用途：为所有 Gate 失败提供具体的修复建议

set -euo pipefail

# 颜色定义
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/py_runtime.sh"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 诊断函数：分析失败原因并生成修复建议
diagnose_and_suggest() {
  local gate_name="$1"
  local error_type="$2"
  local context="$3"
  
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo -e "${CYAN}🔍 诊断与修复建议${NC}"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  echo -e "${YELLOW}Gate:${NC} $gate_name"
  echo -e "${YELLOW}错误类型:${NC} $error_type"
  echo ""
  
  case "$error_type" in
    "MISSING_IMPORT")
      suggest_missing_import "$context"
      ;;
    "MISSING_ANNOTATION")
      suggest_missing_annotation "$context"
      ;;
    "MISSING_FILE")
      suggest_missing_file "$context"
      ;;
    "COMPILATION_ERROR")
      suggest_compilation_fix "$context"
      ;;
    "MISSING_TEST")
      suggest_missing_test "$context"
      ;;
    "INCOMPLETE_DESIGN")
      suggest_design_fix "$context"
      ;;
    "TODO_NOT_CLEARED")
      suggest_todo_fix "$context"
      ;;
    "LOW_COVERAGE")
      suggest_coverage_fix "$context"
      ;;
    *)
      echo -e "${YELLOW}⚠️  未知错误类型，无法提供具体建议${NC}"
      ;;
  esac
  
  echo ""
  echo "════════════════════════════════════════════════════════════════"
}

# 建议：缺少 import
suggest_missing_import() {
  local context="$1"
  echo -e "${GREEN}📝 建议修复步骤：${NC}"
  echo ""
  echo "1. 在文件头部添加缺失的 import："
  echo ""
  echo -e "${CYAN}// 建议添加：${NC}"
  
  # 解析 context 提取缺失的类名
  if [[ "$context" =~ "RestController" ]]; then
    cat << 'JAVA'
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
JAVA
  fi
  
  if [[ "$context" =~ "Service" ]]; then
    cat << 'JAVA'
import org.springframework.stereotype.Service;
import lombok.RequiredArgsConstructor;
JAVA
  fi
  
  if [[ "$context" =~ "Repository" ]] || [[ "$context" =~ "Mapper" ]]; then
    cat << 'JAVA'
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Insert;
JAVA
  fi
  
  echo ""
  echo "2. 自动修复命令（推荐）："
  echo ""
  echo -e "${CYAN}bash scripts/auto_fix_imports.sh${NC}"
  echo ""
}

# 建议：缺少注解
suggest_missing_annotation() {
  local context="$1"
  echo -e "${GREEN}📝 建议修复步骤：${NC}"
  echo ""
  echo "1. 在类或方法上添加缺失的注解："
  echo ""
  
  if [[ "$context" =~ "Controller" ]]; then
    echo -e "${CYAN}// 在 Controller 类上添加：${NC}"
    cat << 'JAVA'
@RestController
@RequestMapping("/api/your-path")
@RequiredArgsConstructor
public class YourController {
    // ...
}
JAVA
  fi
  
  if [[ "$context" =~ "Service" ]]; then
    echo -e "${CYAN}// 在 Service 类上添加：${NC}"
    cat << 'JAVA'
@Service
@RequiredArgsConstructor
public class YourService {
    // ...
}
JAVA
  fi
  
  if [[ "$context" =~ "Mapper" ]]; then
    echo -e "${CYAN}// 在 Mapper 接口上添加：${NC}"
    cat << 'JAVA'
@Mapper
public interface YourMapper {
    // ...
}
JAVA
  fi
  
  echo ""
}

# 建议：缺少文件
suggest_missing_file() {
  local context="$1"
  echo -e "${GREEN}📝 建议修复步骤：${NC}"
  echo ""
  echo "1. 创建缺失的文件："
  echo ""
  echo -e "${CYAN}touch $context${NC}"
  echo ""
  echo "2. 或者使用生成器（推荐）："
  echo ""
  
  if [[ "$context" =~ "Controller" ]]; then
    echo -e "${CYAN}bash scripts/generate_controller.sh <feature-name>${NC}"
  elif [[ "$context" =~ "Service" ]]; then
    echo -e "${CYAN}bash scripts/generate_service.sh <feature-name>${NC}"
  elif [[ "$context" =~ "test" ]]; then
    echo -e "${CYAN}bash scripts/generate_tests.sh <feature-name>${NC}"
  fi
  
  echo ""
}

# 建议：编译错误
suggest_compilation_fix() {
  local context="$1"
  echo -e "${GREEN}📝 建议修复步骤：${NC}"
  echo ""
  echo "1. 查看详细编译错误："
  echo ""
  echo -e "${CYAN}mvn compile 2>&1 | tee compile-error.log${NC}"
  echo ""
  echo "2. 常见编译错误修复："
  echo ""
  echo "   • 类型不匹配：检查方法返回值和变量类型"
  echo "   • 未找到符号：检查 import 和包名"
  echo "   • 语法错误：检查括号、分号、引号"
  echo ""
  echo "3. 自动修复（如果可能）："
  echo ""
  echo -e "${CYAN}bash scripts/auto_fix_compilation.sh${NC}"
  echo ""
}

# 建议：缺少测试
suggest_missing_test() {
  local context="$1"
  echo -e "${GREEN}📝 建议修复步骤：${NC}"
  echo ""
  echo "1. 自动生成测试骨架（推荐）："
  echo ""
  echo -e "${CYAN}bash scripts/p5_test_generation.sh <feature-name>${NC}"
  echo ""
  echo "2. 手动创建测试文件："
  echo ""
  
  if [[ "$context" =~ "Controller" ]]; then
    cat << 'JAVA'
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
JAVA
  fi
  
  echo ""
}

# 建议：设计文档不完整
suggest_design_fix() {
  local context="$1"
  echo -e "${GREEN}📝 建议修复步骤：${NC}"
  echo ""
  echo "1. 检查设计文档覆盖率："
  echo ""
  echo -e "${CYAN}bash scripts/s2_design_coverage_gate.sh <feature-name>${NC}"
  echo ""
  echo "2. 补充缺失的设计内容："
  echo ""
  
  if [[ "$context" =~ "API" ]]; then
    echo "   • 补充 API 接口定义（路径、方法、参数、响应）"
  fi
  
  if [[ "$context" =~ "字段" ]]; then
    echo "   • 补充数据库字段定义（字段名、类型、约束、索引）"
  fi
  
  if [[ "$context" =~ "业务规则" ]]; then
    echo "   • 补充业务规则定义（规则编号、描述、触发条件）"
  fi
  
  echo ""
  echo "3. 重新渲染 design.json："
  echo ""
  echo -e "${CYAN}python3 scripts/df_pipeline.py design <feature-name>${NC}"
  echo ""
}

# 建议：TODO 未清理
suggest_todo_fix() {
  local context="$1"
  echo -e "${GREEN}📝 建议修复步骤：${NC}"
  echo ""
  echo "1. 查看所有未处理的 TODO："
  echo ""
  echo -e "${CYAN}grep -rn \"TODO:\" backend/src frontend/tests/e2e${NC}"
  echo ""
  echo "2. 批量处理 TODO（按类型）："
  echo ""
  echo "   • Mock 数据："
  echo -e "     ${CYAN}grep -rn \"TODO: 补充 Mock 数据\" backend/src/test${NC}"
  echo ""
  echo "   • 断言逻辑："
  echo -e "     ${CYAN}grep -rn \"TODO: 补充断言逻辑\" backend/src/test${NC}"
  echo ""
  echo "   • 选择器调整："
  echo -e "     ${CYAN}grep -rn \"TODO: 调整实际选择器\" frontend/tests/e2e${NC}"
  echo ""
  echo "3. TODO 自动修复工具（实验性）："
  echo ""
  echo -e "${CYAN}bash scripts/auto_resolve_todos.sh <feature-name>${NC}"
  echo ""
}

# 建议：覆盖率不足
suggest_coverage_fix() {
  local context="$1"
  echo -e "${GREEN}📝 建议修复步骤：${NC}"
  echo ""
  echo "1. 查看当前覆盖率报告："
  echo ""
  echo -e "${CYAN}mvn jacoco:report${NC}"
  echo -e "${CYAN}open target/site/jacoco/index.html${NC}"
  echo ""
  echo "2. 识别未覆盖的代码："
  echo ""
  echo "   • 红色：未覆盖的行"
  echo "   • 黄色：部分覆盖的分支"
  echo "   • 绿色：已覆盖"
  echo ""
  echo "3. 补充测试用例："
  echo ""
  echo "   • 为未覆盖的方法添加测试"
  echo "   • 为分支逻辑添加边界测试"
  echo "   • 为异常处理添加错误测试"
  echo ""
  echo "4. 自动生成补充测试（推荐）："
  echo ""
  echo -e "${CYAN}bash scripts/generate_coverage_tests.sh <feature-name>${NC}"
  echo ""
}

# 导出函数供其他脚本使用
export -f diagnose_and_suggest
export -f suggest_missing_import
export -f suggest_missing_annotation
export -f suggest_missing_file
export -f suggest_compilation_fix
export -f suggest_missing_test
export -f suggest_design_fix
export -f suggest_todo_fix
export -f suggest_coverage_fix

# 如果直接运行，显示用法
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "用法: source scripts/gate_diagnostics.sh"
  echo ""
  echo "然后在 Gate 脚本中调用："
  echo '  diagnose_and_suggest "P3 Gate" "MISSING_IMPORT" "UserController"'
fi
