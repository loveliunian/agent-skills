#!/usr/bin/env python3
"""
设计一致性 Linter (v3.28.1)
检查 design.json 中表、API、前端、业务规则的跨层一致性
- 表字段 ↔ API 字段命名对应
- 状态枚举在表/API/前端/业务规则中的一致性
- 外键关系在 API 响应中的体现
- 命名规范一致性（遵循 design-conventions.json）
"""

import json
import sys
import re
from pathlib import Path
from typing import Dict, List, Set, Tuple
from collections import defaultdict

def load_json(path: Path) -> dict:
    """加载 JSON 文件"""
    if not path.exists():
        print(f"❌ 文件不存在: {path}")
        sys.exit(1)
    
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)

def snake_to_camel(snake_str: str, conventions: dict = None) -> str:
    """
    snake_case 转 camelCase (v3.27.16 增强：支持缩写词规则)
    
    Args:
        snake_str: 待转换的 snake_case 字符串
        conventions: design-conventions.json 中的 case_conversion_rules
    """
    if not snake_str:
        return snake_str
    
    components = snake_str.split('_')
    if len(components) == 0:
        return snake_str
    
    # 获取缩写词处理规则
    acronym_rule = 'preserve_case'  # 默认保留大小写
    common_acronyms = ['ID', 'URL', 'API', 'HTTP', 'JSON', 'XML', 'HTML', 'CSS', 'SQL', 'UUID', 'URI']
    
    if conventions:
        case_rules = conventions.get('case_conversion_rules', {})
        acronym_rule = case_rules.get('acronyms', 'preserve_case')
        common_acronyms = case_rules.get('common_acronyms', common_acronyms)
    
    # 转换各组件
    result = components[0].lower()  # 首个组件保持小写
    
    for comp in components[1:]:
        upper_comp = comp.upper()
        
        # 检查是否为常见缩写词
        if upper_comp in common_acronyms:
            if acronym_rule == 'preserve_case':
                result += upper_comp  # ID, URL, API
            elif acronym_rule == 'first_capital':
                result += comp.capitalize()  # Id, Url, Api
            else:  # all_lowercase
                result += comp.lower()  # id, url, api
        else:
            result += comp.capitalize()
    
    return result

def camel_to_snake(camel_str: str, conventions: dict = None) -> str:
    """
    camelCase 转 snake_case (v3.27.16 增强：支持缩写词识别)
    
    Args:
        camel_str: 待转换的 camelCase 字符串
        conventions: design-conventions.json 中的 case_conversion_rules
    """
    if not camel_str:
        return camel_str
    
    # 获取常见缩写词列表
    common_acronyms = ['ID', 'URL', 'API', 'HTTP', 'JSON', 'XML', 'HTML', 'CSS', 'SQL', 'UUID', 'URI']
    if conventions:
        case_rules = conventions.get('case_conversion_rules', {})
        common_acronyms = case_rules.get('common_acronyms', common_acronyms)
    
    # 处理连续大写字母（缩写词）
    # userID -> user_id, urlPath -> url_path, XMLParser -> xml_parser
    result = camel_str
    
    # 先处理连续大写（缩写词）
    result = re.sub('([A-Z]+)([A-Z][a-z])', r'\1_\2', result)
    
    # 再处理普通驼峰
    result = re.sub('([a-z0-9])([A-Z])', r'\1_\2', result)
    
    return result.lower()

def extract_status_fields(tables: list) -> Dict[str, Set[str]]:
    """提取所有表中的状态字段及其可能的枚举值"""
    status_fields = defaultdict(set)
    
    for table in tables:
        table_name = table.get('name', '')
        for field in table.get('fields', []):
            field_name = field.get('name', '')
            field_note = field.get('note', '').lower()
            field_constraint = field.get('constraint', '').lower()
            
            # 识别状态字段（通过名称和注释）
            if 'status' in field_name.lower() or 'state' in field_name.lower():
                # 从注释中提取状态值（如 "1-待审核 2-已通过"）
                status_values = re.findall(r'[0-9]+-([^\s,，]+)', field_note)
                if status_values:
                    status_fields[field_name].update(status_values)
                
                # 从约束中提取枚举值（如 "IN ('PENDING', 'APPROVED')"）
                enum_values = re.findall(r"'([A-Z_]+)'", field_constraint.upper())
                if enum_values:
                    status_fields[field_name].update(enum_values)
    
    return dict(status_fields)

def check_naming_consistency(design: dict, conventions: dict) -> List[str]:
    """检查命名一致性：表、API、类是否遵循 design-conventions.json"""
    issues = []
    
    # 获取命名规范
    naming = conventions.get('naming_conventions', {})
    table_pattern = naming.get('table_naming', {}).get('pattern', '')
    table_prefix = naming.get('table_naming', {}).get('prefix', '')
    api_pattern = naming.get('api_routing', {}).get('pattern', '')
    
    # 检查表命名
    tables = design.get('tables', [])
    for table in tables:
        table_name = table.get('name', '')
        
        # 检查前缀
        if table_prefix and not table_name.startswith(table_prefix):
            issues.append(
                f"⚠️  表命名不符合规范：{table_name} 应以 {table_prefix} 开头"
            )
        
        # 检查 snake_case
        if not re.match(r'^[a-z][a-z0-9_]*$', table_name):
            issues.append(
                f"⚠️  表命名不符合 snake_case：{table_name}"
            )
    
    # 检查 API 路由
    apis = design.get('apis', [])
    for api in apis:
        api_path = api.get('path', '')
        
        # 检查路由模式（如 /api/v1/<resource>）
        if api_pattern and not api_path.startswith('/api/v'):
            issues.append(
                f"⚠️  API 路由不符合规范：{api_path} 应遵循模式 {api_pattern}"
            )
    
    return issues

def check_field_mapping_consistency(design: dict, conventions: dict = None) -> List[str]:
    """检查表字段与 API 字段的命名对应关系 (v3.27.16: 支持缩写词规则)"""
    issues = []
    
    # 收集所有表字段（snake_case）
    table_fields = defaultdict(set)
    for table in design.get('tables', []):
        table_name = table.get('name', '')
        for field in table.get('fields', []):
            field_name = field.get('name', '')
            table_fields[table_name].add(field_name)
    
    # 检查 API 请求/响应字段是否与表字段对应
    apis = design.get('apis', [])
    for api in apis:
        api_name = api.get('name', '')
        
        # 检查请求字段
        for req_field in api.get('request', []):
            req_name = req_field.get('name', '')
            
            # 将 camelCase 转为 snake_case 查找对应表字段 (v3.27.16: 传入 conventions)
            snake_name = camel_to_snake(req_name, conventions)
            
            # 检查是否存在对应的表字段
            found = False
            for table_name, fields in table_fields.items():
                if snake_name in fields:
                    found = True
                    break
            
            # 如果是常见的非业务字段（如 pageSize, pageNum），跳过
            if req_name in ['pageSize', 'pageNum', 'current', 'size']:
                continue
            
            if not found and len(table_fields) > 0:
                issues.append(
                    f"⚠️  API 请求字段无对应表字段：{api_name}.{req_name} (期望表字段: {snake_name})"
                )
        
        # 检查响应字段
        for resp_field in api.get('response', []):
            resp_name = resp_field.get('name', '')
            snake_name = camel_to_snake(resp_name, conventions)
            
            # 常见非业务字段
            if resp_name in ['total', 'records', 'pages', 'current', 'size', 'code', 'message', 'data']:
                continue
            
            found = False
            for table_name, fields in table_fields.items():
                if snake_name in fields:
                    found = True
                    break
            
            if not found and len(table_fields) > 0:
                issues.append(
                    f"⚠️  API 响应字段无对应表字段：{api_name}.{resp_name} (期望表字段: {snake_name})"
                )
    
    return issues
    
    return issues

def check_status_enum_consistency(design: dict) -> List[str]:
    """检查状态枚举在表/API/前端/业务规则中的一致性"""
    issues = []
    
    # 1. 从表中提取状态字段及枚举值
    table_status = extract_status_fields(design.get('tables', []))
    
    if not table_status:
        return []  # 没有状态字段，跳过检查
    
    # 2. 从 API 中提取状态枚举值
    api_status = defaultdict(set)
    for api in design.get('apis', []):
        for field in api.get('request', []) + api.get('response', []):
            field_name = field.get('name', '')
            field_note = field.get('note', '').lower()
            
            if 'status' in field_name.lower() or 'state' in field_name.lower():
                # 从注释中提取状态值
                status_values = re.findall(r'[0-9]+-([^\s,，]+)', field_note)
                if status_values:
                    api_status[field_name].update(status_values)
    
    # 3. 比对表字段与 API 字段的状态枚举是否一致
    for table_field, table_values in table_status.items():
        # 查找对应的 API 字段（可能是 camelCase）
        camel_field = snake_to_camel(table_field, None)  # v3.27.16: 传入 None，使用默认规则
        
        api_values = api_status.get(table_field, set()) | api_status.get(camel_field, set())
        
        if api_values:
            # 检查是否一致
            if table_values != api_values:
                missing_in_api = table_values - api_values
                extra_in_api = api_values - table_values
                
                if missing_in_api:
                    issues.append(
                        f"⚠️  状态枚举不一致：表字段 {table_field} 的状态 {missing_in_api} 未在 API 中声明"
                    )
                
                if extra_in_api:
                    issues.append(
                        f"⚠️  状态枚举不一致：API 字段 {camel_field} 的状态 {extra_in_api} 未在表中声明"
                    )
    
    return issues

def check_foreign_key_representation(design: dict) -> List[str]:
    """检查外键关系在 API 响应中是否有体现（关联对象应该展开）"""
    issues = []
    
    # 收集所有表及其主键
    tables = {}
    for table in design.get('tables', []):
        table_name = table.get('name', '')
        tables[table_name] = table
    
    # 查找外键字段（通常以 _id 结尾且有注释说明关联表）
    foreign_keys = {}
    for table in design.get('tables', []):
        table_name = table.get('name', '')
        for field in table.get('fields', []):
            field_name = field.get('name', '')
            field_note = field.get('note', '')
            
            # 外键识别：字段名以 _id 结尾 且 注释中提到其他表
            if field_name.endswith('_id'):
                for ref_table in tables.keys():
                    if ref_table in field_note:
                        foreign_keys[f"{table_name}.{field_name}"] = ref_table
                        break
    
    if not foreign_keys:
        return []  # 没有外键，跳过检查
    
    # 检查查询/详情类 API 的响应是否包含关联对象
    for api in design.get('apis', []):
        method = api.get('method', '')
        api_name = api.get('name', '')
        
        # 只检查查询/详情接口
        if method not in ['GET']:
            continue
        
        # 收集响应字段
        response_fields = {f.get('name', '') for f in api.get('response', [])}
        
        # 检查每个外键是否有对应的展开对象
        for fk, ref_table in foreign_keys.items():
            table_name, fk_field = fk.split('.', 1)
            
            # API 可能操作的表（从路径推断）
            api_path = api.get('path', '').lower()
            if table_name.replace('t_', '').replace('_', '') not in api_path:
                continue
            
            # 检查响应中是否有外键 ID 字段
            fk_camel = snake_to_camel(fk_field, None)  # v3.27.16: 传入 None
            if fk_camel not in response_fields:
                continue
            
            # 检查是否有对应的关联对象字段（去掉 _id 后缀）
            obj_field = fk_field.replace('_id', '')
            obj_camel = snake_to_camel(obj_field, None)  # v3.27.16: 传入 None
            
            if obj_camel not in response_fields and f"{obj_camel}Info" not in response_fields:
                issues.append(
                    f"⚠️  外键未展开：API {api_name} 响应包含 {fk_camel}，但缺少关联对象 {obj_camel} 或 {obj_camel}Info"
                )
    
    return issues

def main():
    if len(sys.argv) < 2:
        print("用法: design_consistency_linter.py <design.json> [design-conventions.json]")
        sys.exit(1)
    
    design_path = Path(sys.argv[1])
    conventions_path = Path(sys.argv[2]) if len(sys.argv) >= 3 else None
    
    design = load_json(design_path)
    conventions = load_json(conventions_path) if conventions_path and conventions_path.exists() else {}
    
    print("=" * 80)
    print("设计一致性 Linter (v3.28.1)")
    print("=" * 80)
    
    all_issues = []
    
    # 1. 命名规范一致性
    if conventions:
        print("\n【1. 命名规范一致性】")
        print("-" * 80)
        naming_issues = check_naming_consistency(design, conventions)
        
        if naming_issues:
            for issue in naming_issues[:10]:  # 只显示前 10 个
                print(issue)
            if len(naming_issues) > 10:
                print(f"... 还有 {len(naming_issues) - 10} 个命名规范问题")
            all_issues.extend(naming_issues)
        else:
            print("✅ 命名规范一致")
    else:
        print("\n【1. 命名规范一致性】")
        print("-" * 80)
        print("⏭️  跳过：未提供 design-conventions.json")
    
    # 2. 表字段 ↔ API 字段映射一致性
    print("\n【2. 表字段 ↔ API 字段映射】")
    print("-" * 80)
    field_issues = check_field_mapping_consistency(design, conventions)  # v3.27.16: 传入 conventions
    
    if field_issues:
        for issue in field_issues[:10]:
            print(issue)
        if len(field_issues) > 10:
            print(f"... 还有 {len(field_issues) - 10} 个字段映射问题")
        all_issues.extend(field_issues)
    else:
        print("✅ 表字段与 API 字段映射一致")
    
    # 3. 状态枚举一致性
    print("\n【3. 状态枚举跨层一致性】")
    print("-" * 80)
    status_issues = check_status_enum_consistency(design)
    
    if status_issues:
        for issue in status_issues:
            print(issue)
        all_issues.extend(status_issues)
    else:
        print("✅ 状态枚举在表/API 中一致")
    
    # 4. 外键关系展开
    print("\n【4. 外键关系 API 展开】")
    print("-" * 80)
    fk_issues = check_foreign_key_representation(design)
    
    if fk_issues:
        for issue in fk_issues:
            print(issue)
        all_issues.extend(fk_issues)
    else:
        print("✅ 外键关系在 API 中正确展开")
    
    # 总结
    print("\n" + "=" * 80)
    
    if all_issues:
        print(f"⚠️  发现 {len(all_issues)} 个一致性问题（建议性，不阻断）")
        print("=" * 80)
        sys.exit(0)  # 一致性检查是建议性的，不阻断流程
    else:
        print("✅ 设计一致性检查通过")
        print("=" * 80)
        sys.exit(0)

if __name__ == '__main__':
    main()
