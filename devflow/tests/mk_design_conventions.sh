#!/usr/bin/env bash
# mk_design_conventions.sh — 生成 s1 合规的 design-conventions.json
# 用法: bash tests/mk_design_conventions.sh <feature> <workspace>
set -u
FEATURE="${1:?feature}"
WS="${2:?workspace}"
DEV_DIR="$WS/.devflow/$FEATURE"
mkdir -p "$DEV_DIR"

# design-conventions.json（s1 P1 新增；字段对齐 schemas/design-conventions.schema.json）
python3 - "$FEATURE" "$DEV_DIR" <<'DCEOF'
import json, sys
feature, dev_dir = sys.argv[1], sys.argv[2]
d = {
    "feature_name": feature,
    "frozen_at": "2026-01-01T00:00:00Z",
    "naming_conventions": {
        "table_naming": {"case": "snake_case", "prefix": "t_", "pattern": "^t_[a-z][a-z0-9_]*$", "examples": ["t_user", "t_order_item"]},
        "column_naming": {"case": "snake_case", "reserved_fields": ["id", "created_at", "updated_at", "deleted_at"], "audit_fields": ["created_by", "updated_by"]},
        "class_naming": {"case": "PascalCase", "suffixes": {"controller": "Controller", "service": "Service", "repository": "Repository", "dto": "DTO"}},
        "method_naming": {"case": "camelCase", "verb_prefixes": ["get", "list", "create", "update", "delete", "query"]}
    },
    "api_conventions": {
        "routing_pattern": "/api/v1/{resource}",
        "versioning": "path",
        "http_methods": {"create": "POST", "query": "GET", "update": "PUT", "delete": "DELETE"},
        "response_wrapper": {"enabled": True, "structure": {"code": "int", "message": "string", "data": "object"}}
    },
    "data_conventions": {
        "date_format": "yyyy-MM-dd HH:mm:ss",
        "timezone": "Asia/Shanghai",
        "decimal_precision": {"money": "DECIMAL(19,2)", "percentage": "DECIMAL(5,2)"},
        "soft_delete": {"enabled": True, "field_name": "deleted_at", "delete_value": "timestamp"}
    },
    "state_machine_conventions": {
        "storage_strategy": "enum",
        "dict_table_pattern": "^t_dict_[a-z_]+$",
        "transition_logging": True,
        "transition_table_pattern": "^t_state_transition_log$"
    },
    "error_handling_conventions": {
        "exception_wrapper": "GlobalExceptionHandler",
        "error_code_pattern": "^[A-Z][A-Z0-9_]+$",
        "error_code_examples": ["USER_NOT_FOUND", "PARAM_INVALID", "ORDER_STATUS_CONFLICT"],
        "logging_strategy": {"exception_logging": "全量", "request_logging": "全量"}
    },
    "security_conventions": {
        "authentication": "JWT Bearer (Authorization header)",
        "authorization": "RBAC（角色-权限码）",
        "sensitive_data_masking": ["phone", "id_card", "bank_account"],
        "external_integrations": []
    },
    "performance_conventions": {
        "pagination": {"default_size": 20, "max_size": 200},
        "caching_strategy": "Redis cache-aside (TTL 5min) for hot queries",
        "batch_size_limits": {"write_batch": 500, "export_batch": 1000},
        "high_concurrency": False,
        "large_dataset": False
    },
    "case_conversion_rules": {
        "acronyms": "pascal",
        "examples": [
            {"snake_case": "user_id", "camelCase": "userId"},
            {"snake_case": "api_key", "camelCase": "apiKey"},
            {"snake_case": "http_url", "camelCase": "httpUrl"},
            {"snake_case": "json_data", "camelCase": "jsonData"},
            {"snake_case": "order_item_id", "camelCase": "orderItemId"},
            {"snake_case": "created_at", "camelCase": "createdAt"}
        ],
        "db_to_api": "snake_case → camelCase",
        "api_to_db": "camelCase → snake_case"
    },
    "notes": "fixture 设计规范基线"
}
json.dump(d, open(dev_dir + "/design-conventions.json", "w"), ensure_ascii=False, indent=2)
DCEOF



echo "[mk_design_conventions] done for $FEATURE in $WS"
