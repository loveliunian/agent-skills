#!/usr/bin/env python3

def _safe_pascal(v: str) -> str:
    """类名安全化（v3.30.10）"""
    import re as _re
    cleaned = _re.sub(r"[^A-Za-z0-9 ]", " ", str(v))
    words = [w for w in cleaned.split() if w]
    return "".join(w.capitalize() for w in words) or "Entity"



def java_doc(v: str) -> str:
    """Javadoc 块注释安全化（v3.30.9：*/ 闭注释注入收口）"""
    return java_str(v).replace("*/", "*\u2044")



def java_str(v: str) -> str:
    """Java 字符串字面量转义（v3.30.8）"""
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "")

def safe_ident(v: str) -> str:
    import re as _re
    m = _re.sub(r"[^A-Za-z0-9_]", "_", str(v))
    if m and m[0].isdigit(): m = "_" + m
    return m or "test"


"""
测试生成器：从 design.json 生成 JUnit 单元测试

输入：.devflow/<feature>/design.json
输出：backend/<service>/src/test/java/**/*Test.java

生成规则：
1. 每个 API 接口生成对应的 Controller 单元测试
2. 每个业务规则生成对应的 Service 单元测试
3. 每个数据表生成对应的 Mapper 单元测试
4. 覆盖正常、边界、异常三类场景
"""

import json
import sys
import os
from pathlib import Path
from typing import Dict, List, Any
from datetime import datetime


class JUnitTestGenerator:
    def __init__(self, design_json_path: str, output_base: str):
        self.design_json_path = design_json_path
        self.output_base = Path(output_base)
        self.design_data = None
        self.feature = None
        
    def load_design(self):
        """加载 design.json"""
        with open(self.design_json_path, 'r', encoding='utf-8') as f:
            self.design_data = json.load(f)
        self.feature = self.design_data.get('feature', 'unknown')
        
    def generate_all_tests(self):
        """生成所有测试类"""
        if not self.design_data:
            raise ValueError("design.json 未加载")
            
        print(f"[INFO] 开始生成 {self.feature} 的 JUnit 测试...")
        
        # 1. 生成 Controller 测试
        for api in self.design_data.get('apis', []):
            self._generate_controller_test(api)
            
        # 2. 生成 Service 测试
        for rule in self.design_data.get('rules', []):
            self._generate_service_test(rule)
            
        # 3. 生成 Mapper 测试
        for table in self.design_data.get('tables', []):
            self._generate_mapper_test(table)
            
        print(f"[INFO] 测试生成完成")
        
    def _generate_controller_test(self, api: Dict[str, Any]):
        """生成 Controller 单元测试"""
        endpoint = api.get('endpoint', '')
        method = api.get('method', 'GET')
        description = api.get('description', '')
        
        # 推断 Controller 名称
        # 例如：/api/users/{id} -> UserController
        parts = endpoint.strip('/').split('/')
        if len(parts) >= 2 and parts[0] == 'api':
            resource = parts[1].capitalize()
            if resource.endswith('s'):
                resource = resource[:-1]  # users -> user
        else:
            resource = "Unknown"
            
        controller_name = f"{resource}Controller"
        test_class_name = f"{controller_name}Test"
        
        # 生成测试代码
        test_code = self._build_controller_test_code(
            test_class_name=test_class_name,
            controller_name=controller_name,
            api=api,
            method=method,
            endpoint=endpoint,
            description=description
        )
        
        # 写入文件
        output_path = self.output_base / f"controller/{test_class_name}.java"
        self._write_test_file(output_path, test_code)
        
    def _build_controller_test_code(self, test_class_name: str, controller_name: str,
                                   api: Dict, method: str, endpoint: str, description: str) -> str:
        """构建 Controller 测试代码"""
        
        # 提取请求参数
        request_fields = api.get('request_fields', [])
        response_fields = api.get('response_fields', [])
        
        # 生成测试方法
        test_methods = []
        
        # 1. 正常场景
        test_methods.append(self._generate_success_test_method(
            method, endpoint, description, request_fields, response_fields
        ))
        
        # 2. 参数校验场景（如果有必填参数）
        required_fields = [f for f in request_fields if f.get('required', False)]
        if required_fields:
            test_methods.append(self._generate_validation_test_method(
                method, endpoint, required_fields
            ))
        
        # 3. 权限校验场景
        test_methods.append(self._generate_auth_test_method(method, endpoint))
        
        # 4. 异常场景
        if 'id' in endpoint or '{id}' in endpoint:
            test_methods.append(self._generate_not_found_test_method(method, endpoint))
        
        package_name = self._infer_package_name()
        
        return f"""package {package_name}.controller;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import static org.hamcrest.Matchers.*;

/**
 * {controller_name} 单元测试
 * 
 * 生成时间: {datetime.now().isoformat()}
 * 来源: design.json - {java_doc(description)}
 */
@WebMvcTest({controller_name}.class)
class {test_class_name} {{

    @Autowired
    private MockMvc mockMvc;
    
    // TODO: 根据实际依赖调整 MockBean
    // @MockBean
    // private YourService yourService;
    
    @BeforeEach
    void setUp() {{
        // 初始化测试数据
    }}
    
{chr(10).join(test_methods)}
}}
"""

    def _generate_success_test_method(self, method: str, endpoint: str, 
                                     description: str, request_fields: List, 
                                     response_fields: List) -> str:
        """生成正常场景测试方法"""
        
        # 构造请求 JSON
        request_json = self._build_sample_json(request_fields)
        
        # 构造断言
        assertions = []
        for field in response_fields[:3]:  # 只断言前3个字段
            field_name = field.get('name', 'unknown')
            assertions.append(f'            .andExpect(jsonPath("$.{safe_ident(field_name)}").exists())')
        
        method_lower = method.lower()
        
        return f"""    @Test
    @WithMockUser(authorities = {{"ROLE_ADMIN"}})
    void test{safe_ident(description)}_Success() throws Exception {{
        // Given: 准备测试数据
        // TODO: Mock service 返回值
        
        // When & Then: 执行请求并验证
        mockMvc.perform({method_lower}("{java_str(endpoint)}")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{request_json}"))
            .andExpect(status().isOk())
{chr(10).join(assertions) if assertions else '            // TODO: 添加响应断言'};
    }}
"""

    def _generate_validation_test_method(self, method: str, endpoint: str, 
                                        required_fields: List) -> str:
        """生成参数校验测试方法"""
        field_name = required_fields[0].get('name', 'field')
        
        return f"""    @Test
    @WithMockUser(authorities = {{"ROLE_ADMIN"}})
    void testValidation_Missing{_safe_pascal(field_name)}() throws Exception {{
        // Given: 缺少必填参数 {field_name}
        String invalidJson = "{{\\"invalid\\": \\"data\\"}}";
        
        // When & Then: 期望返回 400 Bad Request
        mockMvc.perform({method.lower()}("{java_str(endpoint)}")
                .contentType(MediaType.APPLICATION_JSON)
                .content(invalidJson))
            .andExpect(status().isBadRequest());
    }}
"""

    def _generate_auth_test_method(self, method: str, endpoint: str) -> str:
        """生成权限校验测试方法"""
        return f"""    @Test
    void testAuthorization_Unauthorized() throws Exception {{
        // Given: 未登录用户
        
        // When & Then: 期望返回 401 Unauthorized
        mockMvc.perform({method.lower()}("{java_str(endpoint)}")
                .contentType(MediaType.APPLICATION_JSON))
            .andExpect(status().isUnauthorized());
    }}
"""

    def _generate_not_found_test_method(self, method: str, endpoint: str) -> str:
        """生成资源不存在测试方法"""
        test_endpoint = endpoint.replace('{id}', '99999')
        
        return f"""    @Test
    @WithMockUser(authorities = {{"ROLE_ADMIN"}})
    void testNotFound_NonExistentResource() throws Exception {{
        // Given: 资源不存在
        // TODO: Mock service 抛出 NotFoundException
        
        // When & Then: 期望返回 404 Not Found
        mockMvc.perform({method.lower()}("{java_str(test_endpoint)}")
                .contentType(MediaType.APPLICATION_JSON))
            .andExpect(status().isNotFound());
    }}
"""

    def _generate_service_test(self, rule: Dict[str, Any]):
        """生成 Service 单元测试"""
        rule_id = rule.get('id', 'R-001')
        description = rule.get('description', '')
        
        service_name = f"{safe_ident(self.feature).capitalize()}Service"
        test_class_name = f"{service_name}Test"
        
        test_code = f"""package {self._infer_package_name()}.service;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * {service_name} 单元测试
 * 
 * 生成时间: {datetime.now().isoformat()}
 * 业务规则: {java_doc(rule_id)} - {java_doc(description)}
 */
@ExtendWith(MockitoExtension.class)
class {test_class_name} {{

    @InjectMocks
    private {service_name} {service_name.lower()[0] + service_name[1:]};
    
    // TODO: 根据实际依赖调整 Mock
    // @Mock
    // private YourMapper yourMapper;
    
    @BeforeEach
    void setUp() {{
        // 初始化测试数据
    }}
    
    @Test
    void testBusinessRule_{rule_id.replace('-', '_')}_NormalCase() {{
        // Given: 准备测试数据
        // TODO: 实现测试逻辑
        
        // When: 执行业务方法
        
        // Then: 验证结果
        fail("测试用例待实现: {java_str(description)}");
    }}
    
    @Test
    void testBusinessRule_{rule_id.replace('-', '_')}_EdgeCase() {{
        // Given: 边界条件
        // TODO: 实现边界测试
        
        // When: 执行业务方法
        
        // Then: 验证结果
        fail("边界测试待实现");
    }}
    
    @Test
    void testBusinessRule_{rule_id.replace('-', '_')}_ExceptionCase() {{
        // Given: 异常条件
        // TODO: 实现异常测试
        
        // When & Then: 期望抛出异常
        assertThrows(Exception.class, () -> {{
            // 执行业务方法
        }});
    }}
}}
"""
        
        output_path = self.output_base / f"service/{test_class_name}.java"
        self._write_test_file(output_path, test_code)
        
    def _generate_mapper_test(self, table: Dict[str, Any]):
        """生成 Mapper 单元测试"""
        table_name = table.get('name', 'unknown_table')
        entity_name = _safe_pascal(table_name)
        mapper_name = f"{entity_name}Mapper"
        test_class_name = f"{mapper_name}Test"
        
        test_code = f"""package {self._infer_package_name()}.mapper;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.transaction.annotation.Transactional;

import static org.junit.jupiter.api.Assertions.*;

/**
 * {mapper_name} 单元测试
 * 
 * 生成时间: {datetime.now().isoformat()}
 * 数据表: {java_doc(table_name)}
 */
@SpringBootTest
@Transactional
class {test_class_name} {{

    @Autowired
    private {mapper_name} {mapper_name.lower()[0] + mapper_name[1:]};
    
    @Test
    void testInsert() {{
        // Given: 准备实体数据
        {entity_name} entity = new {entity_name}();
        // TODO: 设置字段值
        
        // When: 插入数据
        int result = {mapper_name.lower()[0] + mapper_name[1:]}.insert(entity);
        
        // Then: 验证插入成功
        assertEquals(1, result);
        assertNotNull(entity.getId());
    }}
    
    @Test
    void testSelectById() {{
        // Given: 已存在的数据
        // TODO: 准备测试数据
        
        // When: 根据 ID 查询
        {entity_name} result = {mapper_name.lower()[0] + mapper_name[1:]}.selectById(1L);
        
        // Then: 验证查询结果
        assertNotNull(result);
    }}
    
    @Test
    void testUpdate() {{
        // Given: 已存在的数据
        // TODO: 准备测试数据
        
        // When: 更新数据
        int result = {mapper_name.lower()[0] + mapper_name[1:]}.updateById(/* entity */);
        
        // Then: 验证更新成功
        assertEquals(1, result);
    }}
    
    @Test
    void testDeleteById() {{
        // Given: 已存在的数据
        // TODO: 准备测试数据
        
        // When: 删除数据
        int result = {mapper_name.lower()[0] + mapper_name[1:]}.deleteById(1L);
        
        // Then: 验证删除成功
        assertEquals(1, result);
    }}
}}
"""
        
        output_path = self.output_base / f"mapper/{test_class_name}.java"
        self._write_test_file(output_path, test_code)
    
    def _write_test_file(self, output_path: Path, content: str):
        """写入测试文件"""
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"[GENERATED] {output_path}")
    
    def _build_sample_json(self, fields: List[Dict]) -> str:
        """构建示例 JSON（单行）"""
        if not fields:
            return "{}"
        
        pairs = []
        for field in fields[:3]:  # 只取前3个字段
            name = field.get('name', 'field')
            field_type = field.get('type', 'String')
            
            if 'int' in field_type.lower() or 'long' in field_type.lower():
                value = '1'
            elif 'bool' in field_type.lower():
                value = 'true'
            else:
                value = f'\\\"{name}_value\\\"'
            
            pairs.append(f'\\\"{java_str(name)}\\\":{value}')
        
        return "{" + ",".join(pairs) + "}"
    
    def _infer_package_name(self) -> str:
        """推断包名"""
        # 默认包名，实际使用时应从 design.json 或配置读取
        return "com.example.project"
    
    def _to_camel_case(self, text: str) -> str:
        """转换为驼峰命名"""
        words = text.replace('-', ' ').replace('_', ' ').split()
        return ''.join(word.capitalize() for word in words)
    
    def _to_pascal_case(self, text: str) -> str:
        """转换为帕斯卡命名"""
        return self._to_camel_case(text)


def main():
    if len(sys.argv) < 3:
        print("用法: python generate_junit_tests.py <design.json路径> <输出目录>")
        print("示例: python generate_junit_tests.py .devflow/user-mgmt/design.json backend/user-service/src/test/java")
        sys.exit(1)
    
    design_json_path = sys.argv[1]
    output_base = sys.argv[2]
    
    if not os.path.exists(design_json_path):
        print(f"[ERROR] design.json 不存在: {design_json_path}")
        sys.exit(1)
    
    generator = JUnitTestGenerator(design_json_path, output_base)
    generator.load_design()
    generator.generate_all_tests()
    
    print("\n[SUCCESS] JUnit 测试生成完成")
    print(f"[INFO] 下一步: 补充 TODO 部分的测试逻辑")


if __name__ == '__main__':
    main()
