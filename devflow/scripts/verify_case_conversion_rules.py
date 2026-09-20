#!/usr/bin/env python3
"""
命名转换规则形式化验证工具 (v3.27.16)

用途：验证 case_conversion_rules 中的转换示例是否符合 acronyms_strategy
      确保 snake_case ↔ camelCase 转换规则稳定且一致

支持的策略（4种）：
  - uppercase: 缩写词全大写（user_id → userID, api_key → apiKey）
  - lowercase: 缩写词全小写（user_id → userid, api_key → apikey）
  - capitalize: 缩写词首字母大写（user_id → UserId, api_key → ApiKey）
  - preserve: 缩写词保持原样（需要提供 acronyms 白名单）

验证逻辑：
  1. 检查 acronyms_strategy 是否定义
  2. 检查 examples 是否至少包含 5 个转换对（建议值）
  3. 验证每个转换对是否符合 acronyms_strategy
  4. 计算稳定性分数（符合规则的转换对占比）

用法：
  # 验证规则文件
  verify_case_conversion_rules.py <design-conventions.json>
  
  # 生成示例规则
  verify_case_conversion_rules.py --generate-examples <strategy>
  verify_case_conversion_rules.py --generate-examples uppercase
  
退出码：
  0 - 验证通过（稳定性分数 >= 90）
  1 - 验证失败（稳定性分数 < 90 或规则缺失）
"""

import json
import sys
import re
from pathlib import Path
from typing import Dict, List, Tuple, Optional

# 常见缩写词白名单（70+ 个）
COMMON_ACRONYMS = {
    # 通用
    'ID', 'API', 'URL', 'URI', 'HTTP', 'HTTPS', 'FTP', 'IP', 'TCP', 'UDP',
    'SQL', 'DB', 'HTML', 'CSS', 'JS', 'JSON', 'XML', 'CSV', 'PDF',
    'IO', 'UI', 'UX', 'SMS', 'MMS', 'GPS', 'CPU', 'GPU', 'RAM', 'ROM',
    'OS', 'DNS', 'SSL', 'TLS', 'JWT', 'OAuth', 'SAML', 'LDAP',
    
    # Web/API
    'REST', 'SOAP', 'RPC', 'MQTT', 'WebSocket', 'GraphQL',
    'UUID', 'GUID', 'SHA', 'MD5', 'AES', 'RSA',
    
    # 架构/设计
    'CRUD', 'ACID', 'BASE', 'CAP', 'SOLID',
    'MVC', 'MVP', 'MVVM', 'DTO', 'DAO', 'VO', 'PO',
    
    # 硬件/设备
    'QR', 'OCR', 'NFC', 'RFID', 'BLE', 'SDK', 'CDN', 'VPN', 'VM',
    
    # 数据库
    'ORM', 'JDBC', 'ODBC', 'NoSQL',
    
    # 云/DevOps
    'AWS', 'GCP', 'CI', 'CD', 'K8s', 'Docker'
}

def snake_to_camel(snake: str, strategy: str, acronyms: Optional[List[str]] = None) -> str:
    """
    将 snake_case 转换为 camelCase
    
    Args:
        snake: snake_case 字符串
        strategy: 缩写词策略（uppercase/lowercase/capitalize/preserve）
        acronyms: 自定义缩写词列表（仅 preserve 策略需要）
    """
    if not snake:
        return ""
    
    parts = snake.split('_')
    
    if strategy == 'pascal':
        strategy = 'capitalize'
    if strategy == 'uppercase':
        # 缩写词全大写：user_id → userID
        result_parts = []
        for i, part in enumerate(parts):
            if i == 0:
                # 首部分保持小写
                result_parts.append(part.lower())
            elif part.upper() in COMMON_ACRONYMS:
                # 是缩写词，全大写
                result_parts.append(part.upper())
            else:
                # 普通词，首字母大写
                result_parts.append(part.capitalize())
        return ''.join(result_parts)
    
    elif strategy == 'lowercase':
        # 缩写词全小写：user_id → userid
        result_parts = [parts[0].lower()]
        for part in parts[1:]:
            result_parts.append(part.lower())
        return ''.join(result_parts)
    
    elif strategy == 'capitalize':
        # 缩写词首字母大写：user_id → UserId
        result_parts = [parts[0].lower()]
        for part in parts[1:]:
            result_parts.append(part.capitalize())
        return ''.join(result_parts)
    
    elif strategy == 'preserve':
        # 保持原样（需要白名单）
        if not acronyms:
            acronyms = []
        
        acronym_set = set(a.upper() for a in acronyms)
        result_parts = [parts[0].lower()]
        
        for part in parts[1:]:
            if part.upper() in acronym_set:
                result_parts.append(part.upper())
            else:
                result_parts.append(part.capitalize())
        return ''.join(result_parts)
    
    else:
        raise ValueError(f"Unknown strategy: {strategy}")

def verify_conversion(snake: str, camel: str, strategy: str, acronyms: Optional[List[str]] = None) -> bool:
    """
    验证一个转换对是否符合策略
    
    Returns:
        True - 符合策略
        False - 不符合策略
    """
    expected_camel = snake_to_camel(snake, strategy, acronyms)
    return camel == expected_camel

def analyze_case_conversion_rules(data: Dict) -> Dict:
    """
    分析 case_conversion_rules
    
    Returns:
        {
            'has_rules': bool,
            'strategy': str,
            'examples_count': int,
            'valid_examples': int,
            'invalid_examples': List[Dict],
            'stability_score': float
        }
    """
    result = {
        'has_rules': False,
        'strategy': None,
        'examples_count': 0,
        'valid_examples': 0,
        'invalid_examples': [],
        'stability_score': 0.0
    }
    
    rules = data.get('case_conversion_rules')
    if not rules:
        return result
    
    result['has_rules'] = True
    # v3.28.1 schema：case_conversion_rules.acronyms 为策略枚举字符串；
    # 兼容旧字段 acronyms_strategy
    _strategy = rules.get('acronyms_strategy')
    if not _strategy:
        _acr = rules.get('acronyms')
        _strategy = _acr if isinstance(_acr, str) else None
    result['strategy'] = _strategy
    
    examples = rules.get('examples', [])
    result['examples_count'] = len(examples)
    
    if result['strategy'] == 'pascal':
        result['strategy'] = 'capitalize'
    if not result['strategy']:
        return result
    
    acronyms = rules.get('acronym_whitelist', [])
    if not acronyms and isinstance(rules.get('acronyms'), list):
        acronyms = rules.get('acronyms')
    
    for example in examples:
        snake = example.get('snake_case', '')
        camel = example.get('camelCase', '')
        
        if verify_conversion(snake, camel, result['strategy'], acronyms):
            result['valid_examples'] += 1
        else:
            expected = snake_to_camel(snake, result['strategy'], acronyms)
            result['invalid_examples'].append({
                'snake_case': snake,
                'actual_camelCase': camel,
                'expected_camelCase': expected
            })
    
    if result['examples_count'] > 0:
        result['stability_score'] = round(
            (result['valid_examples'] / result['examples_count']) * 100, 1
        )
    
    return result

def generate_examples(strategy: str, count: int = 10) -> List[Dict]:
    """生成示例转换对"""
    snake_examples = [
        'user_id', 'api_key', 'http_url', 'json_data', 'db_connection',
        'sql_query', 'html_content', 'css_style', 'js_function', 'xml_parser',
        'pdf_file', 'csv_data', 'io_stream', 'ui_component', 'rest_api',
        'oauth_token', 'jwt_payload', 'uuid_generator', 'guid_value', 'ip_address',
        'tcp_port', 'udp_socket', 'dns_resolver', 'ssl_certificate', 'tls_version'
    ]
    
    examples = []
    for snake in snake_examples[:count]:
        camel = snake_to_camel(snake, strategy)
        examples.append({
            'snake_case': snake,
            'camelCase': camel
        })
    
    return examples

def main():
    # --generate-examples 模式
    if len(sys.argv) >= 2 and sys.argv[1] == '--generate-examples':
        if len(sys.argv) < 3:
            print("用法: verify_case_conversion_rules.py --generate-examples <strategy>")
            print("策略: uppercase, lowercase, capitalize, preserve")
            sys.exit(1)
        
        strategy = sys.argv[2]
        if strategy not in ['uppercase', 'lowercase', 'capitalize', 'preserve', 'pascal']:
            print(f"❌ 未知策略: {strategy}")
            print("支持的策略: uppercase, lowercase, capitalize, preserve")
            sys.exit(1)
        
        examples = generate_examples(strategy)
        
        print(f"\n=== {strategy} 策略示例（共 {len(examples)} 个）===")
        print(json.dumps({
            'case_conversion_rules': {
                'acronyms_strategy': strategy,
                'examples': examples
            }
        }, indent=2, ensure_ascii=False))
        
        sys.exit(0)
    
    # 验证模式
    if len(sys.argv) < 2:
        print("用法:")
        print("  验证: verify_case_conversion_rules.py <design-conventions.json>")
        print("  生成: verify_case_conversion_rules.py --generate-examples <strategy>")
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
    
    # 分析规则
    analysis = analyze_case_conversion_rules(data)
    
    if not analysis['has_rules']:
        print("\n⚠️  未定义 case_conversion_rules")
        print("建议: 使用 --generate-examples 生成示例规则")
        sys.exit(1)
    
    if not analysis['strategy']:
        print("\n❌ 缺少 acronyms_strategy 定义")
        print("支持的策略: uppercase, lowercase, capitalize, preserve")
        sys.exit(1)
    
    # 输出报告
    print("\n=== 命名转换规则验证 ===")
    print(f"文件: {conventions_path}")
    print(f"策略: {analysis['strategy']}")
    print(f"示例数量: {analysis['examples_count']}")
    
    if analysis['examples_count'] < 5:
        print(f"⚠️  示例数量较少，建议至少提供 5 个转换对")
    
    print(f"\n符合规则: {analysis['valid_examples']}/{analysis['examples_count']}")
    print(f"稳定性分数: {analysis['stability_score']}/100")
    
    if analysis['invalid_examples']:
        print(f"\n❌ 不符合规则的示例 ({len(analysis['invalid_examples'])}):")
        for i, example in enumerate(analysis['invalid_examples'][:5], 1):
            print(f"  {i}. {example['snake_case']}")
            print(f"     实际: {example['actual_camelCase']}")
            print(f"     期望: {example['expected_camelCase']}")
        
        if len(analysis['invalid_examples']) > 5:
            print(f"     ... 还有 {len(analysis['invalid_examples']) - 5} 个")
    
    # 评估
    score = analysis['stability_score']
    if score >= 90:
        print(f"\n评估: ✅ 命名转换规则稳定")
        sys.exit(0)
    elif score >= 70:
        print(f"\n评估: ⚠️  命名转换规则基本稳定，建议修正部分示例")
        sys.exit(1)
    else:
        print(f"\n评估: ❌ 命名转换规则不稳定，建议全面检查")
        sys.exit(1)

if __name__ == '__main__':
    main()
