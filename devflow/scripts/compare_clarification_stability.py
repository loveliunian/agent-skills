#!/usr/bin/env python3
"""
实体/操作提取稳定性对比工具 (v3.27.16)

用途：对比两次 clarification.json 的实体/操作提取结果
      评估提取稳定性，识别波动项（新增/删除/重命名）

用法：
  compare_clarification_stability.py <clarification-v1.json> <clarification-v2.json>
  compare_clarification_stability.py --auto <feature-name>  # 自动查找最近两次

输出：
  - 实体稳定性分数（0-100）
  - 操作稳定性分数（0-100）
  - 约束稳定性分数（0-100）
  - 波动项详细对比

退出码：
  0 - 对比完成
  1 - 文件不存在或JSON格式错误
"""

import json
import sys
from pathlib import Path
from typing import Dict, List, Set, Tuple
from datetime import datetime

def load_json(path: Path) -> dict:
    """加载 JSON 文件"""
    if not path.exists():
        print(f"❌ 文件不存在: {path}")
        sys.exit(1)
    
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        print(f"❌ JSON 解析失败: {e}")
        sys.exit(1)

def extract_entity_ids(data: dict) -> Set[str]:
    """提取所有实体 ID"""
    entities = data.get('entities', [])
    return {e['id'] for e in entities if 'id' in e}

def extract_entity_names(data: dict) -> Dict[str, str]:
    """提取实体 ID -> name 映射"""
    entities = data.get('entities', [])
    return {e['id']: e['name'] for e in entities if 'id' in e and 'name' in e}

def extract_operation_ids(data: dict) -> Set[str]:
    """提取所有操作 ID"""
    operations = data.get('operations', [])
    return {op['id'] for op in operations if 'id' in op}

def extract_operation_names(data: dict) -> Dict[str, str]:
    """提取操作 ID -> name 映射"""
    operations = data.get('operations', [])
    return {op['id']: op['name'] for op in operations if 'id' in op and 'name' in op}

def extract_constraint_ids(data: dict) -> Set[str]:
    """提取所有约束 ID"""
    constraints = data.get('constraints', [])
    return {c['id'] for c in constraints if 'id' in c}

def extract_constraint_names(data: dict) -> Dict[str, str]:
    """提取约束 ID -> description 映射"""
    constraints = data.get('constraints', [])
    return {c['id']: c['description'] for c in constraints if 'id' in c and 'description' in c}

def calculate_stability_score(
    v1_ids: Set[str],
    v2_ids: Set[str]
) -> Tuple[float, Set[str], Set[str], Set[str]]:
    """
    计算稳定性分数
    
    Returns:
        (score, added, removed, stable)
    """
    stable = v1_ids & v2_ids
    added = v2_ids - v1_ids
    removed = v1_ids - v2_ids
    
    if not v1_ids:
        # v1 为空，无法计算稳定性
        return 0.0, added, removed, stable
    
    # 稳定性 = 保留的项 / v1 总项数
    score = (len(stable) / len(v1_ids)) * 100 if v1_ids else 0.0
    
    return round(score, 2), added, removed, stable

def detect_renames(
    v1_names: Dict[str, str],
    v2_names: Dict[str, str],
    added: Set[str],
    removed: Set[str]
) -> List[Tuple[str, str, str, str]]:
    """
    检测可能的重命名
    
    Returns:
        [(v1_id, v1_name, v2_id, v2_name)]
    """
    renames = []
    
    # 只对比被删除的 v1 项和新增的 v2 项
    for v1_id in removed:
        v1_name = v1_names.get(v1_id, '')
        for v2_id in added:
            v2_name = v2_names.get(v2_id, '')
            
            # 简单相似度：名称包含关系 或 Levenshtein 距离 < 3
            if v1_name and v2_name:
                if v1_name in v2_name or v2_name in v1_name:
                    renames.append((v1_id, v1_name, v2_id, v2_name))
                elif levenshtein_distance(v1_name, v2_name) < 3:
                    renames.append((v1_id, v1_name, v2_id, v2_name))
    
    return renames

def levenshtein_distance(s1: str, s2: str) -> int:
    """计算 Levenshtein 距离"""
    if len(s1) < len(s2):
        return levenshtein_distance(s2, s1)
    
    if len(s2) == 0:
        return len(s1)
    
    previous_row = range(len(s2) + 1)
    for i, c1 in enumerate(s1):
        current_row = [i + 1]
        for j, c2 in enumerate(s2):
            insertions = previous_row[j + 1] + 1
            deletions = current_row[j] + 1
            substitutions = previous_row[j] + (c1 != c2)
            current_row.append(min(insertions, deletions, substitutions))
        previous_row = current_row
    
    return previous_row[-1]

def auto_find_latest_two(feature_name: str) -> Tuple[Path, Path]:
    """
    自动查找最近两次 clarification.json
    
    Returns:
        (v1_path, v2_path)  # v1 = 较早，v2 = 较新
    """
    docs_dir = Path('docs/requirements')
    if not docs_dir.exists():
        print(f"❌ 目录不存在: {docs_dir}")
        sys.exit(1)
    
    pattern = f"{feature_name}-clarification*.json"
    candidates = sorted(docs_dir.glob(pattern), key=lambda p: p.stat().st_mtime)
    
    if len(candidates) < 2:
        print(f"❌ 找不到足够的文件: {pattern}")
        print(f"   当前仅有 {len(candidates)} 个文件")
        sys.exit(1)
    
    return candidates[-2], candidates[-1]

def format_timestamp(path: Path) -> str:
    """格式化文件修改时间"""
    mtime = path.stat().st_mtime
    dt = datetime.fromtimestamp(mtime)
    return dt.strftime('%Y-%m-%d %H:%M:%S')

def main():
    if len(sys.argv) < 2:
        print("用法:")
        print("  compare_clarification_stability.py <v1.json> <v2.json>")
        print("  compare_clarification_stability.py --auto <feature-name>")
        sys.exit(1)
    
    # 自动模式
    if sys.argv[1] == '--auto':
        if len(sys.argv) < 3:
            print("❌ 缺少 feature-name")
            sys.exit(1)
        
        feature_name = sys.argv[2]
        v1_path, v2_path = auto_find_latest_two(feature_name)
    else:
        v1_path = Path(sys.argv[1])
        v2_path = Path(sys.argv[2])
    
    v1_data = load_json(v1_path)
    v2_data = load_json(v2_path)
    
    print("=" * 80)
    print("实体/操作提取稳定性对比 (v3.27.16)")
    print("=" * 80)
    print(f"V1: {v1_path} ({format_timestamp(v1_path)})")
    print(f"V2: {v2_path} ({format_timestamp(v2_path)})")
    print()
    
    # 1. 实体稳定性
    v1_entity_ids = extract_entity_ids(v1_data)
    v2_entity_ids = extract_entity_ids(v2_data)
    v1_entity_names = extract_entity_names(v1_data)
    v2_entity_names = extract_entity_names(v2_data)
    
    entity_score, entity_added, entity_removed, entity_stable = calculate_stability_score(
        v1_entity_ids, v2_entity_ids
    )
    
    print("【实体稳定性】")
    print(f"  分数: {entity_score}/100")
    print(f"  V1 总数: {len(v1_entity_ids)}")
    print(f"  V2 总数: {len(v2_entity_ids)}")
    print(f"  保留: {len(entity_stable)}")
    print(f"  新增: {len(entity_added)}")
    print(f"  删除: {len(entity_removed)}")
    
    if entity_added:
        print(f"\n  新增实体:")
        for eid in sorted(entity_added):
            name = v2_entity_names.get(eid, '(无名称)')
            print(f"    + {eid}: {name}")
    
    if entity_removed:
        print(f"\n  删除实体:")
        for eid in sorted(entity_removed):
            name = v1_entity_names.get(eid, '(无名称)')
            print(f"    - {eid}: {name}")
    
    # 检测可能的重命名
    entity_renames = detect_renames(v1_entity_names, v2_entity_names, entity_added, entity_removed)
    if entity_renames:
        print(f"\n  可能的重命名:")
        for v1_id, v1_name, v2_id, v2_name in entity_renames:
            print(f"    ? {v1_id}({v1_name}) → {v2_id}({v2_name})")
    
    print()
    
    # 2. 操作稳定性
    v1_op_ids = extract_operation_ids(v1_data)
    v2_op_ids = extract_operation_ids(v2_data)
    v1_op_names = extract_operation_names(v1_data)
    v2_op_names = extract_operation_names(v2_data)
    
    op_score, op_added, op_removed, op_stable = calculate_stability_score(
        v1_op_ids, v2_op_ids
    )
    
    print("【操作稳定性】")
    print(f"  分数: {op_score}/100")
    print(f"  V1 总数: {len(v1_op_ids)}")
    print(f"  V2 总数: {len(v2_op_ids)}")
    print(f"  保留: {len(op_stable)}")
    print(f"  新增: {len(op_added)}")
    print(f"  删除: {len(op_removed)}")
    
    if op_added:
        print(f"\n  新增操作:")
        for op_id in sorted(op_added):
            name = v2_op_names.get(op_id, '(无名称)')
            print(f"    + {op_id}: {name}")
    
    if op_removed:
        print(f"\n  删除操作:")
        for op_id in sorted(op_removed):
            name = v1_op_names.get(op_id, '(无名称)')
            print(f"    - {op_id}: {name}")
    
    op_renames = detect_renames(v1_op_names, v2_op_names, op_added, op_removed)
    if op_renames:
        print(f"\n  可能的重命名:")
        for v1_id, v1_name, v2_id, v2_name in op_renames:
            print(f"    ? {v1_id}({v1_name}) → {v2_id}({v2_name})")
    
    print()
    
    # 3. 约束稳定性
    v1_cst_ids = extract_constraint_ids(v1_data)
    v2_cst_ids = extract_constraint_ids(v2_data)
    v1_cst_names = extract_constraint_names(v1_data)
    v2_cst_names = extract_constraint_names(v2_data)
    
    cst_score, cst_added, cst_removed, cst_stable = calculate_stability_score(
        v1_cst_ids, v2_cst_ids
    )
    
    print("【约束稳定性】")
    print(f"  分数: {cst_score}/100")
    print(f"  V1 总数: {len(v1_cst_ids)}")
    print(f"  V2 总数: {len(v2_cst_ids)}")
    print(f"  保留: {len(cst_stable)}")
    print(f"  新增: {len(cst_added)}")
    print(f"  删除: {len(cst_removed)}")
    
    if cst_added:
        print(f"\n  新增约束:")
        for cid in sorted(cst_added):
            desc = v2_cst_names.get(cid, '(无描述)')
            print(f"    + {cid}: {desc}")
    
    if cst_removed:
        print(f"\n  删除约束:")
        for cid in sorted(cst_removed):
            desc = v1_cst_names.get(cid, '(无描述)')
            print(f"    - {cid}: {desc}")
    
    print()
    
    # 综合评估
    avg_score = round((entity_score + op_score + cst_score) / 3, 2)
    
    print("=" * 80)
    print(f"综合稳定性分数: {avg_score}/100")
    
    if avg_score >= 90:
        print("评估: ✅ 提取非常稳定，波动极小")
    elif avg_score >= 75:
        print("评估: ⚠️  提取较稳定，有少量波动")
    elif avg_score >= 50:
        print("评估: ⚠️  提取不够稳定，波动较大")
    else:
        print("评估: ❌ 提取不稳定，波动严重")
    
    print("=" * 80)
    
    # 给出建议
    if avg_score < 90:
        print()
        print("改进建议:")
        if entity_score < 90:
            print("  - 实体提取波动较大，检查 PRD 理解是否一致")
        if op_score < 90:
            print("  - 操作提取波动较大，检查业务流程理解是否一致")
        if cst_score < 90:
            print("  - 约束提取波动较大，检查业务规则理解是否一致")
        if entity_renames or op_renames:
            print("  - 检测到可能的重命名，确认是否为同一概念")
    
    sys.exit(0)

if __name__ == '__main__':
    main()
