#!/usr/bin/env python3
"""
PRD-to-Design 映射完备性检查器 (v3.28.1)
检查 P0 clarification.json 中的实体、操作、约束是否完整映射到 P2 design.json
确保设计不遗漏 PRD 需求，也不过度设计
"""

import json
import sys
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

def check_entity_mapping(clarification: dict, design: dict) -> Tuple[List[str], List[str]]:
    """检查实体映射：每个 PRD 实体必须至少对应一张表"""
    issues = []
    unmapped_entities = []
    
    entities = clarification.get('entities', [])
    tables = design.get('tables', [])
    
    if not entities:
        return [], []
    
    # 收集所有表的实体引用
    table_entity_refs = set()
    for table in tables:
        entity_ref = table.get('prd_entity_ref', '')
        if entity_ref:
            table_entity_refs.add(entity_ref)
    
    # 检查每个实体是否有对应的表
    for entity in entities:
        entity_id = entity.get('id', '')
        entity_name = entity.get('name', '')
        
        if not entity_id:
            continue
        
        if entity_id not in table_entity_refs:
            unmapped_entities.append(entity_id)
            issues.append(
                f"❌ 实体 {entity_id} ({entity_name}) 无对应表 (期望表中有 prd_entity_ref: {entity_id})"
            )
    
    return issues, unmapped_entities

def check_operation_mapping(clarification: dict, design: dict) -> Tuple[List[str], List[str]]:
    """检查操作映射：每个 PRD 操作必须至少对应一个 API"""
    issues = []
    unmapped_operations = []
    
    operations = clarification.get('operations', [])
    apis = design.get('apis', [])
    
    if not operations:
        return [], []
    
    # 收集所有 API 的操作引用
    api_operation_refs = set()
    for api in apis:
        operation_ref = api.get('prd_operation_ref', '')
        if operation_ref:
            api_operation_refs.add(operation_ref)
    
    # 检查每个操作是否有对应的 API
    for operation in operations:
        operation_id = operation.get('id', '')
        operation_name = operation.get('name', '')
        
        if not operation_id:
            continue
        
        if operation_id not in api_operation_refs:
            unmapped_operations.append(operation_id)
            issues.append(
                f"❌ 操作 {operation_id} ({operation_name}) 无对应 API (期望 API 中有 prd_operation_ref: {operation_id})"
            )
    
    return issues, unmapped_operations

def check_constraint_mapping(clarification: dict, design: dict) -> Tuple[List[str], List[str]]:
    """检查约束映射：每个 PRD 约束必须在表/API/规则层实现"""
    issues = []
    unmapped_constraints = []
    
    constraints = clarification.get('constraints', [])
    tables = design.get('tables', [])
    apis = design.get('apis', [])
    rules = design.get('rules', [])
    
    if not constraints:
        return [], []
    
    # 收集所有约束引用
    constraint_refs = set()
    
    # 从表字段中收集约束引用
    for table in tables:
        for field in table.get('fields', []):
            constraint_ref = field.get('prd_constraint_ref', '')
            if constraint_ref:
                constraint_refs.add(constraint_ref)
    
    # 从 API 字段中收集约束引用（v3.28.2 兼容：request 为 {anchor, fields} 对象或旧版列表均可）
    for api in apis:
        _req = api.get('request', [])
        if isinstance(_req, dict):
            _req = _req.get('fields', [])
        for req_field in _req:
            if not isinstance(req_field, dict):
                continue
            constraint_ref = req_field.get('prd_constraint_ref', '')
            if constraint_ref:
                constraint_refs.add(constraint_ref)
    
    # 从业务规则中收集约束引用（如果有 constraint_refs 字段）
    for rule in rules:
        for constraint_ref in rule.get('constraint_refs', []):
            if constraint_ref:
                constraint_refs.add(constraint_ref)
    
    # 检查每个约束是否有实现
    for constraint in constraints:
        constraint_id = constraint.get('id', '')
        constraint_type = constraint.get('type', '')
        constraint_target = constraint.get('target', '')
        
        if not constraint_id:
            continue
        
        if constraint_id not in constraint_refs:
            unmapped_constraints.append(constraint_id)
            issues.append(
                f"❌ 约束 {constraint_id} ({constraint_type}: {constraint_target}) 未在设计中实现 (期望表字段/API/规则中引用)"
            )
    
    return issues, unmapped_constraints

def check_orphan_tables(clarification: dict, design: dict) -> List[str]:
    """检查孤儿表：表没有 prd_entity_ref 且没有 unreferenced_reason"""
    issues = []
    
    tables = design.get('tables', [])
    entities = clarification.get('entities', [])
    
    if not entities:
        return []
    
    entity_ids = {e.get('id', '') for e in entities if e.get('id')}
    
    for table in tables:
        table_name = table.get('name', '')
        entity_ref = table.get('prd_entity_ref', '')
        unreferenced_reason = table.get('unreferenced_reason', '')
        
        # 没有实体引用
        if not entity_ref:
            # 也没有说明为什么不引用
            if not unreferenced_reason:
                issues.append(
                    f"⚠️  孤儿表 {table_name}：无 prd_entity_ref 且无 unreferenced_reason (基础设施表应说明原因)"
                )
        else:
            # 引用了不存在的实体
            if entity_ref not in entity_ids:
                issues.append(
                    f"❌ 表 {table_name} 引用了不存在的实体 {entity_ref}"
                )
    
    return issues

def check_orphan_apis(clarification: dict, design: dict) -> List[str]:
    """检查孤儿 API：API 没有 prd_operation_ref 且没有 unreferenced_reason"""
    issues = []
    
    apis = design.get('apis', [])
    operations = clarification.get('operations', [])
    
    if not operations:
        return []
    
    operation_ids = {op.get('id', '') for op in operations if op.get('id')}
    
    for api in apis:
        api_name = api.get('name', '')
        operation_ref = api.get('prd_operation_ref', '')
        unreferenced_reason = api.get('unreferenced_reason', '')
        
        # 没有操作引用
        if not operation_ref:
            # 也没有说明为什么不引用
            if not unreferenced_reason:
                issues.append(
                    f"⚠️  孤儿 API {api_name}：无 prd_operation_ref 且无 unreferenced_reason (健康检查等内部接口应说明原因)"
                )
        else:
            # 引用了不存在的操作
            if operation_ref not in operation_ids:
                issues.append(
                    f"❌ API {api_name} 引用了不存在的操作 {operation_ref}"
                )
    
    return issues

def main():
    if len(sys.argv) < 3:
        print("用法: check_prd_design_mapping.py <clarification.json> <design.json>")
        sys.exit(1)
    
    clarification_path = Path(sys.argv[1])
    design_path = Path(sys.argv[2])
    
    clarification = load_json(clarification_path)
    design = load_json(design_path)
    
    print("=" * 80)
    print("PRD-to-Design 映射完备性检查 (v3.28.1)")
    print("=" * 80)
    
    all_issues = []
    has_critical = False
    
    # 1. 实体映射检查
    print("\n【1. 实体 → 表映射】")
    print("-" * 80)
    entity_issues, unmapped_entities = check_entity_mapping(clarification, design)
    
    if entity_issues:
        has_critical = True
        for issue in entity_issues:
            print(issue)
        all_issues.extend(entity_issues)
    else:
        entities_count = len(clarification.get('entities', []))
        print(f"✅ 所有 {entities_count} 个 PRD 实体已映射到表")
    
    # 2. 操作映射检查
    print("\n【2. 操作 → API 映射】")
    print("-" * 80)
    operation_issues, unmapped_operations = check_operation_mapping(clarification, design)
    
    if operation_issues:
        has_critical = True
        for issue in operation_issues:
            print(issue)
        all_issues.extend(operation_issues)
    else:
        operations_count = len(clarification.get('operations', []))
        print(f"✅ 所有 {operations_count} 个 PRD 操作已映射到 API")
    
    # 3. 约束映射检查
    print("\n【3. 约束 → 表/API/规则映射】")
    print("-" * 80)
    constraint_issues, unmapped_constraints = check_constraint_mapping(clarification, design)
    
    if constraint_issues:
        has_critical = True
        for issue in constraint_issues:
            print(issue)
        all_issues.extend(constraint_issues)
    else:
        constraints_count = len(clarification.get('constraints', []))
        print(f"✅ 所有 {constraints_count} 个 PRD 约束已在设计中实现")
    
    # 4. 孤儿表检查
    print("\n【4. 孤儿表检查】")
    print("-" * 80)
    orphan_table_issues = check_orphan_tables(clarification, design)
    
    if orphan_table_issues:
        for issue in orphan_table_issues:
            print(issue)
            if issue.startswith("❌"):
                has_critical = True
        all_issues.extend(orphan_table_issues)
    else:
        tables_count = len(design.get('tables', []))
        print(f"✅ 所有 {tables_count} 张表均有 PRD 追溯或说明")
    
    # 5. 孤儿 API 检查
    print("\n【5. 孤儿 API 检查】")
    print("-" * 80)
    orphan_api_issues = check_orphan_apis(clarification, design)
    
    if orphan_api_issues:
        for issue in orphan_api_issues:
            print(issue)
            if issue.startswith("❌"):
                has_critical = True
        all_issues.extend(orphan_api_issues)
    else:
        apis_count = len(design.get('apis', []))
        print(f"✅ 所有 {apis_count} 个 API 均有 PRD 追溯或说明")
    
    # 总结
    print("\n" + "=" * 80)
    
    if has_critical:
        print(f"❌ PRD-to-Design 映射不完备：{len(all_issues)} 个问题（含关键问题）")
        print("=" * 80)
        
        # 输出修复建议
        if unmapped_entities:
            print("\n修复建议（实体）：")
            for entity_id in unmapped_entities:
                print(f"  在 design.json 的对应表中添加: \"prd_entity_ref\": \"{entity_id}\"")
        
        if unmapped_operations:
            print("\n修复建议（操作）：")
            for operation_id in unmapped_operations:
                print(f"  在 design.json 的对应 API 中添加: \"prd_operation_ref\": \"{operation_id}\"")
        
        if unmapped_constraints:
            print("\n修复建议（约束）：")
            for constraint_id in unmapped_constraints:
                print(f"  在 design.json 的表字段/API 中添加: \"prd_constraint_ref\": \"{constraint_id}\"")
        
        sys.exit(1)
    elif all_issues:
        print(f"⚠️  PRD-to-Design 映射存在 {len(all_issues)} 个警告（非关键，已说明原因）")
        print("=" * 80)
        sys.exit(0)
    else:
        print("✅ PRD-to-Design 映射完备：所有实体、操作、约束均已正确映射")
        print("=" * 80)
        sys.exit(0)

if __name__ == '__main__':
    main()
