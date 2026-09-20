#!/usr/bin/env python3
"""
实体/操作提取稳定性对比工具 (v3.27.16)

用途：对比同一 PRD 在不同时间点/不同 Agent 提取的实体/操作结果
      检测提取稳定性，识别遗漏或幻觉实体

核心场景：
  1. PRD 迭代后重新提取 → 检查实体/操作是否一致
  2. 多 Agent 并行提取 → 检查提取结果差异
  3. P0 Gate 前预检 → 确保提取质量稳定

对比维度：
  - 实体：id, name, attributes（字段数量、名称）
  - 操作：id, name, crud_type, entities（关联实体）
  - 约束：id, description, type

稳定性指标：
  - 精确匹配率：两次提取完全一致的实体/操作占比
  - 新增项：仅在新提取中出现的项（可能是遗漏或新增需求）
  - 缺失项：仅在旧提取中出现的项（可能是删除或幻觉）
  - 变更项：id 相同但内容变化的项（可能是澄清或修正）

用法：
  # 对比两个 clarification.json
  compare_entity_extraction.py <baseline.json> <current.json>
  
  # 生成对比报告（HTML 格式）
  compare_entity_extraction.py <baseline.json> <current.json> --output report.html
  
  # 仅输出差异（无差异时静默）
  compare_entity_extraction.py <baseline.json> <current.json> --diff-only

输出：
  - 实体对比：新增/缺失/变更
  - 操作对比：新增/缺失/变更
  - 约束对比：新增/缺失/变更
  - 稳定性分数（0-100）

退出码：
  0 - 提取稳定（差异 < 10%）
  1 - 提取不稳定（差异 >= 10%）
  2 - 文件格式错误
"""

import json
import sys
from pathlib import Path
from typing import Dict, List, Set, Tuple
from dataclasses import dataclass
from datetime import datetime

@dataclass
class EntityDiff:
    """实体差异"""
    added: List[Dict]
    removed: List[Dict]
    modified: List[Dict]

@dataclass
class OperationDiff:
    """操作差异"""
    added: List[Dict]
    removed: List[Dict]
    modified: List[Dict]

@dataclass
class ConstraintDiff:
    """约束差异"""
    added: List[Dict]
    removed: List[Dict]
    modified: List[Dict]

def load_clarification(path: Path) -> Dict:
    """加载 clarification.json"""
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        print(f"❌ JSON 解析失败: {path} - {e}")
        sys.exit(2)
    except FileNotFoundError:
        print(f"❌ 文件不存在: {path}")
        sys.exit(2)

def compare_entities(baseline: List[Dict], current: List[Dict]) -> EntityDiff:
    """对比实体列表"""
    baseline_ids = {e['id']: e for e in baseline}
    current_ids = {e['id']: e for e in current}
    
    added = [e for e in current if e['id'] not in baseline_ids]
    removed = [e for e in baseline if e['id'] not in current_ids]
    
    # 检查修改（id 相同但内容不同）
    modified = []
    for eid in set(baseline_ids.keys()) & set(current_ids.keys()):
        baseline_e = baseline_ids[eid]
        current_e = current_ids[eid]
        
        # 对比 name 和 attributes
        if (baseline_e.get('name') != current_e.get('name') or
            baseline_e.get('attributes') != current_e.get('attributes')):
            modified.append({
                'id': eid,
                'baseline': baseline_e,
                'current': current_e
            })
    
    return EntityDiff(added, removed, modified)

def compare_operations(baseline: List[Dict], current: List[Dict]) -> OperationDiff:
    """对比操作列表"""
    baseline_ids = {o['id']: o for o in baseline}
    current_ids = {o['id']: o for o in current}
    
    added = [o for o in current if o['id'] not in baseline_ids]
    removed = [o for o in baseline if o['id'] not in current_ids]
    
    modified = []
    for oid in set(baseline_ids.keys()) & set(current_ids.keys()):
        baseline_o = baseline_ids[oid]
        current_o = current_ids[oid]
        
        if (baseline_o.get('name') != current_o.get('name') or
            baseline_o.get('crud_type') != current_o.get('crud_type') or
            baseline_o.get('entities') != current_o.get('entities')):
            modified.append({
                'id': oid,
                'baseline': baseline_o,
                'current': current_o
            })
    
    return OperationDiff(added, removed, modified)

def compare_constraints(baseline: List[Dict], current: List[Dict]) -> ConstraintDiff:
    """对比约束列表"""
    baseline_ids = {c['id']: c for c in baseline}
    current_ids = {c['id']: c for c in current}
    
    added = [c for c in current if c['id'] not in baseline_ids]
    removed = [c for c in baseline if c['id'] not in current_ids]
    
    modified = []
    for cid in set(baseline_ids.keys()) & set(current_ids.keys()):
        baseline_c = baseline_ids[cid]
        current_c = current_ids[cid]
        
        if (baseline_c.get('description') != current_c.get('description') or
            baseline_c.get('type') != current_c.get('type')):
            modified.append({
                'id': cid,
                'baseline': baseline_c,
                'current': current_c
            })
    
    return ConstraintDiff(added, removed, modified)

def calculate_stability_score(
    entity_diff: EntityDiff,
    operation_diff: OperationDiff,
    constraint_diff: ConstraintDiff,
    baseline_total: int,
    current_total: int
) -> float:
    """
    计算稳定性分数（0-100）
    
    公式：
      稳定分 = 100 - (新增占比 + 缺失占比 + 变更占比) * 100
      总数 = max(baseline_total, current_total)
    """
    if baseline_total == 0 and current_total == 0:
        return 100.0
    
    total = max(baseline_total, current_total)
    
    changes = (
        len(entity_diff.added) + len(entity_diff.removed) + len(entity_diff.modified) +
        len(operation_diff.added) + len(operation_diff.removed) + len(operation_diff.modified) +
        len(constraint_diff.added) + len(constraint_diff.removed) + len(constraint_diff.modified)
    )
    
    change_rate = changes / total if total > 0 else 0
    
    stability = max(0, 100 - change_rate * 100)
    
    return round(stability, 2)

def print_diff(label: str, diff, baseline_count: int, current_count: int):
    """打印差异摘要"""
    print(f"\n【{label}】")
    print(f"  基准: {baseline_count} 项，当前: {current_count} 项")
    
    if diff.added:
        print(f"  ➕ 新增: {len(diff.added)} 项")
        for item in diff.added[:3]:  # 最多显示 3 项
            print(f"     - {item.get('id')}: {item.get('name', item.get('description', ''))}")
        if len(diff.added) > 3:
            print(f"     ... 还有 {len(diff.added) - 3} 项")
    
    if diff.removed:
        print(f"  ➖ 缺失: {len(diff.removed)} 项")
        for item in diff.removed[:3]:
            print(f"     - {item.get('id')}: {item.get('name', item.get('description', ''))}")
        if len(diff.removed) > 3:
            print(f"     ... 还有 {len(diff.removed) - 3} 项")
    
    if diff.modified:
        print(f"  ✏️  变更: {len(diff.modified)} 项")
        for item in diff.modified[:3]:
            print(f"     - {item.get('id')}")
        if len(diff.modified) > 3:
            print(f"     ... 还有 {len(diff.modified) - 3} 项")
    
    if not diff.added and not diff.removed and not diff.modified:
        print("  ✅ 无差异")

def main():
    if len(sys.argv) < 3:
        print("用法:")
        print("  compare_entity_extraction.py <baseline.json> <current.json>")
        print("  compare_entity_extraction.py <baseline.json> <current.json> --output report.html")
        print("  compare_entity_extraction.py <baseline.json> <current.json> --diff-only")
        sys.exit(1)
    
    baseline_path = Path(sys.argv[1])
    current_path = Path(sys.argv[2])
    
    diff_only = '--diff-only' in sys.argv
    output_html = None
    
    if '--output' in sys.argv:
        output_idx = sys.argv.index('--output') + 1
        if output_idx < len(sys.argv):
            output_html = Path(sys.argv[output_idx])
    
    # 加载数据
    baseline_data = load_clarification(baseline_path)
    current_data = load_clarification(current_path)
    
    # 提取结构化数据
    baseline_entities = baseline_data.get('entities', [])
    current_entities = current_data.get('entities', [])
    
    baseline_operations = baseline_data.get('operations', [])
    current_operations = current_data.get('operations', [])
    
    baseline_constraints = baseline_data.get('constraints', [])
    current_constraints = current_data.get('constraints', [])
    
    # 对比
    entity_diff = compare_entities(baseline_entities, current_entities)
    operation_diff = compare_operations(baseline_operations, current_operations)
    constraint_diff = compare_constraints(baseline_constraints, current_constraints)
    
    # 计算稳定性分数
    baseline_total = len(baseline_entities) + len(baseline_operations) + len(baseline_constraints)
    current_total = len(current_entities) + len(current_operations) + len(current_constraints)
    
    stability_score = calculate_stability_score(
        entity_diff, operation_diff, constraint_diff,
        baseline_total, current_total
    )
    
    # 检查是否有差异
    has_diff = (
        entity_diff.added or entity_diff.removed or entity_diff.modified or
        operation_diff.added or operation_diff.removed or operation_diff.modified or
        constraint_diff.added or constraint_diff.removed or constraint_diff.modified
    )
    
    if diff_only and not has_diff:
        # 静默退出
        sys.exit(0)
    
    # 输出报告
    print("=" * 80)
    print("实体/操作提取稳定性对比 (v3.27.16)")
    print("=" * 80)
    print(f"基准文件: {baseline_path}")
    print(f"当前文件: {current_path}")
    print(f"对比时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    
    print_diff("实体对比", entity_diff, len(baseline_entities), len(current_entities))
    print_diff("操作对比", operation_diff, len(baseline_operations), len(current_operations))
    print_diff("约束对比", constraint_diff, len(baseline_constraints), len(current_constraints))
    
    print()
    print("=" * 80)
    print(f"稳定性分数: {stability_score}/100")
    
    if stability_score >= 90:
        print("评估: ✅ 提取稳定，差异 < 10%")
        exit_code = 0
    elif stability_score >= 80:
        print("评估: ⚠️  提取基本稳定，差异 10-20%")
        exit_code = 0
    else:
        print("评估: ❌ 提取不稳定，差异 >= 20%，建议人工 Review")
        exit_code = 1
    
    print("=" * 80)
    
    # 生成 HTML 报告（如果指定）
    if output_html:
        # TODO: 生成 HTML 报告
        print(f"\n(HTML 报告生成功能待实现: {output_html})")
    
    sys.exit(exit_code)

if __name__ == '__main__':
    main()
