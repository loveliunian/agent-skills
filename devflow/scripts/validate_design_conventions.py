#!/usr/bin/env python3
"""
design-conventions.json 关键可选字段检查器 (v3.27.16)

用途：检查设计规范基线中的关键可选字段是否已填写
      帮助团队识别需要补充的规范内容

关键可选字段（8个）：
  1. case_conversion_rules - 命名转换规则（snake_case ↔ camelCase）
  2. api_conventions.versioning_strategy - API 版本策略
  3. api_conventions.pagination - API 分页规范
  4. architecture_patterns.state_machine_handling.transition_logging - 状态转移日志
  5. security_conventions - 安全规范
  6. component_reuse_patterns - 组件复用模式
  7. development_conventions - 开发规范
  8. adr_triggers - ADR 触发条件

使用率评估：
  - ≥80%: 设计规范基线完整度高
  - 60-80%: 完整度良好，建议补充部分字段
  - 40-60%: 完整度一般，建议补充关键字段
  - <40%: 完整度较低，建议补充多个关键字段

用法：
  validate_design_conventions.py <design-conventions.json>
  
退出码：0（不阻断，建议性检查）
"""

import json
import sys
from pathlib import Path
from typing import Dict, Any, List, Tuple

# 关键可选字段列表（路径表示法，用 . 分隔嵌套）
OPTIONAL_FIELDS = [
    "case_conversion_rules",
    "api_conventions.versioning_strategy",
    "api_conventions.pagination",
    "architecture_patterns.state_machine_handling.transition_logging",
    "security_conventions",
    "component_reuse_patterns",
    "development_conventions",
    "adr_triggers"
]

def get_nested_value(data: Dict, path: str) -> Any:
    """获取嵌套路径的值"""
    keys = path.split('.')
    current = data
    
    for key in keys:
        if isinstance(current, dict) and key in current:
            current = current[key]
        else:
            return None
    
    return current

def is_field_filled(data: Dict, path: str) -> bool:
    """
    判断字段是否已填写
    
    规则：
      - None / 不存在 → 未填写
      - 空字符串 / 空列表 / 空字典 → 未填写
      - 其他 → 已填写
    """
    value = get_nested_value(data, path)
    
    if value is None:
        return False
    
    if isinstance(value, str) and value.strip() == "":
        return False
    
    if isinstance(value, (list, dict)) and len(value) == 0:
        return False
    
    return True

def check_optional_fields(data: Dict) -> Tuple[List[str], List[str]]:
    """
    检查可选字段填写情况
    
    返回：(已填写字段列表, 未填写字段列表)
    """
    filled = []
    missing = []
    
    for field in OPTIONAL_FIELDS:
        if is_field_filled(data, field):
            filled.append(field)
        else:
            missing.append(field)
    
    return filled, missing

def calculate_completion_rate(filled_count: int, total_count: int) -> float:
    """计算完整度百分比"""
    if total_count == 0:
        return 0.0
    return round((filled_count / total_count) * 100, 1)

def get_completion_assessment(rate: float) -> str:
    """根据完整度评估等级"""
    if rate >= 80:
        return "✅ 设计规范基线完整度高"
    elif rate >= 60:
        return "ℹ️ 设计规范基线完整度良好，建议补充部分字段"
    elif rate >= 40:
        return "⚠️ 设计规范基线完整度一般，建议补充关键字段"
    else:
        return "⚠️ 设计规范基线完整度较低，建议补充多个关键字段"

def get_field_description(field: str) -> str:
    """获取字段说明"""
    descriptions = {
        "case_conversion_rules": "命名转换规则（snake_case ↔ camelCase 策略）",
        "api_conventions.versioning_strategy": "API 版本策略（路径/Header/Query）",
        "api_conventions.pagination": "API 分页规范（offset/cursor/page）",
        "architecture_patterns.state_machine_handling.transition_logging": "状态转移日志策略",
        "security_conventions": "安全规范（认证/授权/加密/审计）",
        "component_reuse_patterns": "组件复用模式（何时抽象通用组件）",
        "development_conventions": "开发规范（分支策略/PR 规范/代码评审）",
        "adr_triggers": "ADR 触发条件（何时需要记录架构决策）"
    }
    return descriptions.get(field, "")

def main():
    if len(sys.argv) < 2:
        print("用法: validate_design_conventions.py <design-conventions.json>")
        sys.exit(1)
    
    conventions_path = Path(sys.argv[1])
    
    if not conventions_path.exists():
        print(f"❌ 文件不存在: {conventions_path}")
        sys.exit(1)
    
    try:
        with open(conventions_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"❌ JSON 解析失败: {e}")
        sys.exit(1)
    
    # 检查可选字段
    filled, missing = check_optional_fields(data)
    
    total = len(OPTIONAL_FIELDS)
    filled_count = len(filled)
    completion_rate = calculate_completion_rate(filled_count, total)
    assessment = get_completion_assessment(completion_rate)
    
    # 输出报告
    print("\n=== design-conventions.json 关键可选字段检查 ===")
    print(f"文件: {conventions_path}")
    print(f"\n可选字段使用率: {filled_count}/{total} ({completion_rate}%)")
    print(f"评估: {assessment}")
    
    if filled:
        print(f"\n✅ 已填写字段 ({len(filled)}):")
        for field in filled:
            desc = get_field_description(field)
            print(f"  - {field}")
            if desc:
                print(f"    {desc}")
    
    if missing:
        print(f"\n⚠️  未填写字段 ({len(missing)}):")
        for field in missing:
            desc = get_field_description(field)
            print(f"  - {field}")
            if desc:
                print(f"    {desc}")
        
        print("\n建议:")
        if "case_conversion_rules" in missing:
            print("  • 添加 case_conversion_rules，明确缩写词处理策略（uppercase/lowercase/capitalize）")
        if "api_conventions.versioning_strategy" in missing:
            print("  • 添加 API 版本策略，避免后续接口演进时出现不一致")
        if "security_conventions" in missing:
            print("  • 添加安全规范，确保认证/授权/加密统一处理")
        if "adr_triggers" in missing:
            print("  • 添加 ADR 触发条件，明确何时需要记录架构决策")
    
    print()
    
    # 不阻断，始终返回 0
    sys.exit(0)

if __name__ == '__main__':
    main()
