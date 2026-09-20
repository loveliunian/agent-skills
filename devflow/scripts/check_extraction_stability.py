#!/usr/bin/env python3
"""
实体/操作提取稳定性检查工具 (v3.27.16)

对比两次 P0 澄清产物（clarification.json），检测：
1. 实体 ID 漂移：实体内容相同但 ID 变化（ENT-01 → ENT-02）
2. 操作 ID 漂移：操作内容相同但 ID 变化（OPS-01 → OPS-03）
3. 约束 ID 漂移：约束内容相同但 ID 变化（CST-01 → CST-04）
4. 新增/删除实体/操作/约束
5. 实体/操作描述变化（语义相同但表述不同）

用法：
  check_extraction_stability.py <old_clarification.json> <new_clarification.json>
  
  或者自动对比 .devflow/<feature>/ 下的历史版本：
  check_extraction_stability.py --auto <feature>
"""

import json
import sys
import difflib
from pathlib import Path
from typing import Dict, List, Tuple, Set
from dataclasses import dataclass
from collections import defaultdict

@dataclass
class Entity:
    """业务实体"""
    id: str
    name: str
    description: str
    
    def fingerprint(self) -> str:
        """生成实体指纹（基于名称+描述的归一化表示）"""
        return f"{self.name.strip().lower()}:{self.description[:50].strip().lower()}"

@dataclass
class Operation:
    """业务操作"""
    id: str
    name: str
    description: str
    
    def fingerprint(self) -> str:
        return f"{self.name.strip().lower()}:{self.description[:50].strip().lower()}"

@dataclass
class Constraint:
    """业务约束"""
    id: str
    description: str
    
    def fingerprint(self) -> str:
        return self.description[:100].strip().lower()

def load_clarification(path: Path) -> dict:
    """加载 clarification.json"""
    if not path.exists():
        print(f"❌ 文件不存在: {path}")
        sys.exit(1)
    
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)

def parse_entities(data: dict) -> List[Entity]:
    """解析实体列表"""
    entities = []
    for item in data.get('entities', []):
        entities.append(Entity(
            id=item.get('id', ''),
            name=item.get('name', ''),
            description=item.get('description', '')
        ))
    return entities

def parse_operations(data: dict) -> List[Operation]:
    """解析操作列表"""
    operations = []
    for item in data.get('operations', []):
        operations.append(Operation(
            id=item.get('id', ''),
            name=item.get('name', ''),
            description=item.get('description', '')
        ))
    return operations

def parse_constraints(data: dict) -> List[Constraint]:
    """解析约束列表"""
    constraints = []
    for item in data.get('constraints', []):
        constraints.append(Constraint(
            id=item.get('id', ''),
            description=item.get('description', '')
        ))
    return constraints

def detect_id_drift(old_items: List, new_items: List, item_type: str) -> List[str]:
    """
    检测 ID 漂移：内容相同但 ID 不同
    
    返回问题列表，格式：
      - "ID 漂移: ENT-01 (用户) → ENT-03 (用户) [内容未变]"
    """
    issues = []
    
    # 构建指纹 → ID 映射
    old_fp_to_id = {item.fingerprint(): item.id for item in old_items}
    new_fp_to_id = {item.fingerprint(): item.id for item in new_items}
    old_id_to_fp = {item.id: item.fingerprint() for item in old_items}
    
    # 检测：指纹相同但 ID 不同
    for fp in old_fp_to_id:
        if fp in new_fp_to_id:
            old_id = old_fp_to_id[fp]
            new_id = new_fp_to_id[fp]
            
            if old_id != new_id:
                # 找到对应的 item
                old_item = next((x for x in old_items if x.id == old_id), None)
                new_item = next((x for x in new_items if x.id == new_id), None)
                
                if old_item and new_item:
                    name = getattr(old_item, 'name', old_item.description[:20])
                    issues.append(
                        f"⚠️  ID 漂移 ({item_type}): {old_id} → {new_id} [{name}] (内容未变)"
                    )
    
    return issues

def detect_additions_deletions(old_items: List, new_items: List, item_type: str) -> Tuple[List[str], List[str]]:
    """
    检测新增和删除
    
    返回：(additions, deletions)
    """
    old_fps = {item.fingerprint() for item in old_items}
    new_fps = {item.fingerprint() for item in new_items}
    
    added_fps = new_fps - old_fps
    deleted_fps = old_fps - new_fps
    
    additions = []
    for fp in added_fps:
        item = next((x for x in new_items if x.fingerprint() == fp), None)
        if item:
            name = getattr(item, 'name', item.description[:20])
            additions.append(f"➕ 新增 ({item_type}): {item.id} [{name}]")
    
    deletions = []
    for fp in deleted_fps:
        item = next((x for x in old_items if x.fingerprint() == fp), None)
        if item:
            name = getattr(item, 'name', item.description[:20])
            deletions.append(f"➖ 删除 ({item_type}): {item.id} [{name}]")
    
    return additions, deletions

def detect_description_changes(old_items: List, new_items: List, item_type: str) -> List[str]:
    """
    检测描述变化：ID 相同但描述不同（可能是语义相同但表述不同）
    """
    issues = []
    
    old_by_id = {item.id: item for item in old_items}
    new_by_id = {item.id: item for item in new_items}
    
    for item_id in old_by_id:
        if item_id in new_by_id:
            old_item = old_by_id[item_id]
            new_item = new_by_id[item_id]
            
            # 检查名称变化
            if hasattr(old_item, 'name') and hasattr(new_item, 'name'):
                if old_item.name != new_item.name:
                    issues.append(
                        f"🔄 名称变化 ({item_type}): {item_id} [{old_item.name}] → [{new_item.name}]"
                    )
            
            # 检查描述变化（相似度 < 0.8）
            old_desc = old_item.description
            new_desc = new_item.description
            
            if old_desc != new_desc:
                similarity = difflib.SequenceMatcher(None, old_desc, new_desc).ratio()
                
                if similarity < 0.8:
                    issues.append(
                        f"🔄 描述变化 ({item_type}): {item_id} [相似度 {similarity:.1%}]"
                    )
                    issues.append(f"    旧: {old_desc[:80]}...")
                    issues.append(f"    新: {new_desc[:80]}...")
    
    return issues

def main():
    if len(sys.argv) < 3:
        print("用法: check_extraction_stability.py <old_clarification.json> <new_clarification.json>")
        print("  或: check_extraction_stability.py --auto <feature>")
        sys.exit(1)
    
    if sys.argv[1] == '--auto':
        feature = sys.argv[2]
        devflow_dir = Path(f".devflow/{feature}")
        
        if not devflow_dir.exists():
            print(f"❌ .devflow/{feature}/ 目录不存在")
            sys.exit(1)
        
        # 查找历史版本（按修改时间排序）
        clarification_files = sorted(
            devflow_dir.glob("clarification*.json"),
            key=lambda p: p.stat().st_mtime
        )
        
        if len(clarification_files) < 2:
            print(f"❌ .devflow/{feature}/ 下少于 2 个 clarification.json 历史版本")
            sys.exit(1)
        
        old_path = clarification_files[-2]
        new_path = clarification_files[-1]
        
        print(f"📁 自动对比最近两个版本：")
        print(f"   旧: {old_path}")
        print(f"   新: {new_path}")
        print()
    else:
        old_path = Path(sys.argv[1])
        new_path = Path(sys.argv[2])
    
    # 加载两个版本
    old_data = load_clarification(old_path)
    new_data = load_clarification(new_path)
    
    old_entities = parse_entities(old_data)
    new_entities = parse_entities(new_data)
    
    old_operations = parse_operations(old_data)
    new_operations = parse_operations(new_data)
    
    old_constraints = parse_constraints(old_data)
    new_constraints = parse_constraints(new_data)
    
    print("=" * 80)
    print("实体/操作提取稳定性检查 (v3.27.16)")
    print("=" * 80)
    
    total_issues = 0
    
    # 1. 检测实体 ID 漂移
    print("\n【1. 实体 ID 漂移检查】")
    print("-" * 80)
    entity_drift = detect_id_drift(old_entities, new_entities, "实体")
    if entity_drift:
        for issue in entity_drift:
            print(issue)
        total_issues += len(entity_drift)
    else:
        print("✅ 无实体 ID 漂移")
    
    # 2. 检测操作 ID 漂移
    print("\n【2. 操作 ID 漂移检查】")
    print("-" * 80)
    operation_drift = detect_id_drift(old_operations, new_operations, "操作")
    if operation_drift:
        for issue in operation_drift:
            print(issue)
        total_issues += len(operation_drift)
    else:
        print("✅ 无操作 ID 漂移")
    
    # 3. 检测约束 ID 漂移
    print("\n【3. 约束 ID 漂移检查】")
    print("-" * 80)
    constraint_drift = detect_id_drift(old_constraints, new_constraints, "约束")
    if constraint_drift:
        for issue in constraint_drift:
            print(issue)
        total_issues += len(constraint_drift)
    else:
        print("✅ 无约束 ID 漂移")
    
    # 4. 检测新增/删除
    print("\n【4. 新增/删除检查】")
    print("-" * 80)
    
    entity_add, entity_del = detect_additions_deletions(old_entities, new_entities, "实体")
    operation_add, operation_del = detect_additions_deletions(old_operations, new_operations, "操作")
    constraint_add, constraint_del = detect_additions_deletions(old_constraints, new_constraints, "约束")
    
    all_changes = entity_add + entity_del + operation_add + operation_del + constraint_add + constraint_del
    
    if all_changes:
        for change in all_changes:
            print(change)
    else:
        print("✅ 无新增/删除")
    
    # 5. 检测描述变化
    print("\n【5. 描述变化检查】")
    print("-" * 80)
    
    entity_desc_changes = detect_description_changes(old_entities, new_entities, "实体")
    operation_desc_changes = detect_description_changes(old_operations, new_operations, "操作")
    constraint_desc_changes = detect_description_changes(old_constraints, new_constraints, "约束")
    
    all_desc_changes = entity_desc_changes + operation_desc_changes + constraint_desc_changes
    
    if all_desc_changes:
        for change in all_desc_changes:
            print(change)
    else:
        print("✅ 无描述变化")
    
    # 总结
    print("\n" + "=" * 80)
    print("总结")
    print("=" * 80)
    print(f"实体: {len(old_entities)} → {len(new_entities)}")
    print(f"操作: {len(old_operations)} → {len(new_operations)}")
    print(f"约束: {len(old_constraints)} → {len(new_constraints)}")
    print(f"\nID 漂移: {len(entity_drift) + len(operation_drift) + len(constraint_drift)} 个")
    print(f"新增/删除: {len(all_changes)} 个")
    print(f"描述变化: {len(all_desc_changes)} 个")
    
    if total_issues > 0 or all_changes or all_desc_changes:
        print("\n⚠️  检测到提取不稳定，建议：")
        print("  1. 修正 ID 漂移（手工对齐或重新生成）")
        print("  2. 确认新增/删除是否符合预期")
        print("  3. 审查描述变化是否改变了语义")
        sys.exit(1)
    else:
        print("\n✅ 提取稳定，无问题")
        sys.exit(0)

if __name__ == '__main__':
    main()
