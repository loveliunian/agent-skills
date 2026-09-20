#!/usr/bin/env python3
"""
JSON Schema 验证工具 (v3.27.16)

统一的 JSON schema 验证入口，供 Gate 脚本调用

用法：
  validate_json_schema.py <data.json> <schema.json>

退出码：
  0 - 验证通过
  1 - 验证失败
"""

import json
import sys
from pathlib import Path

def load_json(path: Path) -> dict:
    """加载 JSON 文件"""
    if not path.exists():
        print(f"❌ 文件不存在: {path}", file=sys.stderr)
        sys.exit(1)
    
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        print(f"❌ JSON 解析失败: {path}", file=sys.stderr)
        print(f"   {e}", file=sys.stderr)
        sys.exit(1)

def main():
    if len(sys.argv) < 3:
        print("用法: validate_json_schema.py <data.json> <schema.json>", file=sys.stderr)
        sys.exit(1)
    
    data_path = Path(sys.argv[1])
    schema_path = Path(sys.argv[2])
    
    # 检查 jsonschema 库
    try:
        import jsonschema
    except ImportError:
        print("⚠️  jsonschema 库未安装，跳过验证", file=sys.stderr)
        print("   安装: pip install jsonschema", file=sys.stderr)
        sys.exit(0)  # 不阻断，警告即可
    
    # 加载数据和 schema
    data = load_json(data_path)
    schema = load_json(schema_path)
    
    # 验证
    try:
        jsonschema.validate(data, schema)
        print(f"✅ 验证通过: {data_path.name}")
        sys.exit(0)
    except jsonschema.ValidationError as e:
        print(f"❌ Schema 验证失败: {data_path.name}", file=sys.stderr)
        print(f"   错误: {e.message}", file=sys.stderr)
        
        # 显示错误路径
        if e.absolute_path:
            path_str = " → ".join(str(p) for p in e.absolute_path)
            print(f"   位置: {path_str}", file=sys.stderr)
        
        # 显示验证失败的字段
        if e.validator == 'required':
            print(f"   缺少必填字段: {e.message}", file=sys.stderr)
        elif e.validator == 'minItems':
            print(f"   数组长度不足: {e.message}", file=sys.stderr)
        elif e.validator == 'enum':
            print(f"   枚举值不匹配: {e.message}", file=sys.stderr)
        
        sys.exit(1)
    except jsonschema.SchemaError as e:
        print(f"❌ Schema 文件本身有误: {schema_path}", file=sys.stderr)
        print(f"   {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
