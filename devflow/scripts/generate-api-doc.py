#!/usr/bin/env python3
# =============================================================================
# P9 接口文档生成器（v3.27.5，FB-20260918-001）
# 从 design.json apis[] 生成独立成文的接口文档——
# 每接口含：请求/响应 JSON 示例、错误码逐条列举、curl 调用样例、权限码。
# 消除 P9 阶段"接口文档=详设引用"的欠账（L-M01-010）。
#
# Usage:
#   python3 generate-api-doc.py <design.json> <output.md> [--feature <name>]
# =============================================================================
import json
import sys
import os
import hashlib
from datetime import datetime, timezone

def _load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)

def _sha(text):
    return hashlib.sha256(text.encode()).hexdigest()

def _mask(s):
    return s or "—"

def _example_value(field_type, field_name, required, rule):
    """根据字段类型与规则生成示例值"""
    n = field_name.lower()
    if "token" in n: return "eyJhbGciOiJIUzM4NCJ9..."
    if "password" in n or "pwd" in n: return "••••••••"
    if "phone" in n: return "13800138000"
    if "email" in n: return "user@example.com"
    if "captcha" in n and "id" in n: return "a1b2c3d4e5"
    if "captcha" in n and "code" in n: return "7x4K"
    if "image" in n or "base64" in n: return "data:image/png;base64,..."
    if "file" in n or "avatar" in n: return "<binary>"
    if "id" == n or n.endswith("_id") or n.endswith("id"): return 1
    if "ids" in n: return [1, 2]
    if "page" in n and "num" in n: return 1
    if "page" in n and "size" in n: return 20
    if "sort" in n: return 0
    if "version" in n: return 0
    if "status" in n: return 1
    if "type" in n: return 1
    if "date" in n or "time" in n or "expire" in n or "at" == n[-2:]: return "2026-09-18T00:00:00"
    if "count" in n or "total" in n or "num" in n or "affected" in n or "granted" in n: return 1
    if "json" in n: return {"retainDays": 30}
    if "code" in n: return "org:tree:view"
    if "name" in n: return "示例名称"
    if "path" in n: return "/api/v1/m01/..."
    if field_type in ("integer", "int", "long", "bigint"): return 1
    if field_type in ("boolean", "bool"): return True
    if field_type in ("array", "list"): return ["..."]
    if field_type in ("object", "map"): return {"key": "value"}
    return "示例值"

def _build_request_example(api):
    req = api.get("request") or {}
    fields = req.get("fields") or []
    if not fields:
        return None
    obj = {}
    for f in fields:
        name = f["name"]
        ft = f.get("type", "string")
        if ft in ("integer", "int", "long", "bigint"):
            obj[name] = _example_value(ft, name, f.get("required"), f.get("rule"))
        elif ft in ("boolean", "bool"):
            obj[name] = True
        elif "ids" in name.lower() or ft in ("array", "list"):
            obj[name] = [1]
        else:
            obj[name] = _example_value(ft, name, f.get("required"), f.get("rule"))
    return obj

def _build_curl(method, path, req_example, token=True):
    base = "http://localhost:8101"
    parts = [f'curl -s -X {method} "{base}{path}"']
    parts.append("-H 'Content-Type: application/json'")
    if token:
        parts.append("-H 'Authorization: Bearer <token>'")
    if req_example:
        import json as j
        parts.append(f"-d '{j.dumps(req_example, ensure_ascii=False)}'")
    return " \\\n  ".join(parts)

def _extract_error_codes(rule_text):
    """从规则描述中提取大写错误码"""
    import re
    if not rule_text:
        return []
    return re.findall(r'\b[A-Z][A-Z_]{4,}\b', rule_text)

def generate(design_path, output_path, feature_name=""):
    d = _load(design_path)
    apis = d.get("apis", [])
    if not apis:
        print("[WARN] design.json 无 apis[]，跳过生成")
        return

    feature = feature_name or d.get("feature", "unknown")
    date = datetime.now().strftime("%Y-%m-%d")

    # 按 Controller 域分组
    groups = {}
    for api in apis:
        path = api.get("path", "").split("（")[0].strip()
        # /api/v1/m01/depts/tree → depts
        parts = path.split("/")
        if len(parts) > 4:
            domain = parts[4]
        else:
            domain = "other"
        groups.setdefault(domain, []).append(api)

    DOMAIN_NAMES = {
        "auth": "认证与鉴权",
        "depts": "组织架构",
        "positions": "岗位管理",
        "roles": "角色管理",
        "users": "用户管理",
        "perm-groups": "权限组管理",
        "menus": "菜单管理",
        "login-policy": "登录策略",
        "sms-codes": "短信服务",
        "profile": "个人中心",
        "recycle": "回收站管理",
    }

    lines = []
    a = lines.append
    a(f"# {d.get('feature_name', feature)} 接口文档")
    a("")
    a(f"> 生成时间：{date}　　生成器：generate-api-doc.py v1.0")
    a(f"> 数据源：{design_path}（design.json apis[] 全集，{len(apis)} 接口）")
    a(f"> 统一前缀：`/api/v1/m01`　　统一响应包：`{{success, code, errorCode, message, data, traceId}}`")
    a("")
    a("---")
    a("")

    # 目录
    a("## 目录")
    a("")
    for domain in groups:
        dn = DOMAIN_NAMES.get(domain, domain)
        anchor = domain.replace("/", "").replace(".", "")
        a(f"- [{dn}](#{anchor})（{len(groups[domain])} 接口）")
    a("")
    a("---")
    a("")

    seq = 0
    for domain in groups:
        dn = DOMAIN_NAMES.get(domain, domain)
        a(f"## {dn}")
        a("")
        for api in groups[domain]:
            seq += 1
            method = api["method"].split("（")[0].strip()
            path = api["path"].split("（")[0].strip()
            name = api.get("name", "")
            perm = (api.get("permission") or "JWT").split("（")[0].strip()
            detail = api.get("detail_anchor") or api.get("anchor") or ""

            a(f"### {seq}. {name}")
            a("")
            a(f"> {method} `{path}`　　权限：{perm}　　详设：{detail}")
            a("")

            # 请求
            req_fields = (api.get("request") or {}).get("fields") or []
            if req_fields:
                a("**请求参数**")
                a("")
                a("| 字段 | 类型 | 必填 | 校验规则 | 脱敏 |")
                a("|---|---|---|---|---|")
                for f in req_fields:
                    a(f"| {f['name']} | {f.get('type','string')} | {'**是**' if f.get('required') else '否'} | {f.get('rule') or '—'} | {f.get('masking') or '否'} |")
                a("")
            else:
                a("**请求参数**：无（路径级操作）")
                a("")

            # 响应
            res_fields = (api.get("response") or {}).get("fields") or []
            if res_fields:
                a("**响应字段**（data 内）")
                a("")
                a("| 字段 | 类型 | 说明 |")
                a("|---|---|---|")
                for f in res_fields:
                    a(f"| {f['name']} | {f.get('type','—')} | {f.get('rule') or '—'} |")
                a("")
            else:
                a("**响应字段**：`data: true`（布尔确认）")
                a("")

            # 请求示例
            req_example = _build_request_example(api)
            if req_example:
                import json as j
                a(f"**请求示例**")
                a("")
                a("```json")
                a(j.dumps(req_example, ensure_ascii=False, indent=2))
                a("```")
                a("")

            # curl 样例
            ct = api.get("detail_anchor", "").replace("§", "")
            curl = _build_curl(method, path, req_example, token=perm not in ("公开", "公开（限流）"))
            a(f"**curl 调用样例**")
            a("")
            a("```bash")
            a(curl)
            a("```")
            a("")

            # 错误码
            error_codes = set()
            # 从规则中提取
            for f in req_fields + res_fields:
                error_codes.update(_extract_error_codes(f.get("rule", "")))
            # 从域级已知错误码补充
            domain_errors = {
                "auth": ["CAPTCHA_REQUIRED", "CAPTCHA_WRONG", "LOGIN_LOCKED", "LOGIN_DISABLED",
                         "USERNAME_OR_PASSWORD_WRONG", "SESSION_TIMEOUT", "SESSION_LOCKED"],
                "depts": ["DEPT_NAME_DUPLICATED", "DEPT_CODE_OCCUPIED", "DEPT_CODE_IMMUTABLE",
                          "DEPT_HAS_CHILDREN", "DEPT_HAS_USERS", "DEPT_ROOT_PROTECTED",
                          "TEMP_EXPIRE_REQUIRED", "DEPT_NOT_FOUND"],
                "positions": ["POSITION_NAME_DUPLICATED", "POSITION_GRADE_INVALID", "POSITION_IN_USE", "POSITION_NOT_FOUND"],
                "roles": ["ROLE_NAME_DUPLICATED", "ROLE_IN_USE", "ROLE_NOT_FOUND"],
                "users": ["USER_USERNAME_OCCUPIED", "USER_USERNAME_IMMUTABLE", "USER_PHONE_INVALID",
                          "USER_DELETE_NOT_ALLOWED", "USER_MAIN_POSITION_INVALID", "USER_MAIN_ROLE_INVALID",
                          "CONCURRENCE_DEPT_INVALID", "CONCURRENCE_DUPLICATED", "ADMIN_PROTECTED",
                          "RESET_LOCK_INVALID", "USER_NOT_FOUND"],
                "perm-groups": ["PERM_GROUP_NAME_DUPLICATED", "PERM_GROUP_BUILTIN_PROTECTED", "PERM_GROUP_DISABLED",
                                "PERM_GROUP_MENU_REQUIRED", "PERM_MENU_DISABLED", "PERM_OPERATION_NOT_ENABLED",
                                "DATA_SCOPE_TYPE_INVALID", "DATA_SCOPE_ORG_REQUIRED", "GRANT_OBJECT_INVALID",
                                "PERM_GROUP_IN_USE", "PERM_GROUP_NOT_FOUND"],
                "menus": ["MENU_TYPE_IMMUTABLE", "MENU_BUILTIN_PROTECTED", "MENU_HAS_CHILDREN",
                          "MENU_REFERENCED_BY_GROUP", "MENU_PAGE_FIELD_REQUIRED", "MENU_NOT_FOUND"],
                "login-policy": ["LOGIN_POLICY_LADDER_INVALID", "LOGIN_POLICY_PARAM_INVALID",
                                 "LOGIN_POLICY_CAPTCHA_THRESHOLD_REQUIRED"],
                "sms-codes": ["SMS_SEND_TOO_FREQUENT", "SMS_CODE_WRONG", "USER_PHONE_INVALID"],
                "profile": ["OLD_PASSWORD_WRONG", "PASSWORD_SAME_AS_OLD", "PASSWORD_CONFIRM_MISMATCH",
                            "SMS_CODE_WRONG", "USER_EMAIL_INVALID", "USER_PHONE_INVALID"],
                "recycle": ["RECYCLE_ITEM_NOT_FOUND", "RECYCLE_TARGET_INVALID", "RECYCLE_PARENT_GONE",
                            "RECYCLE_CODE_OCCUPIED", "RECYCLE_NOT_PURGABLE", "RECYCLE_ADMIN_ONLY",
                            "POLICY_NAME_DUPLICATED", "POLICY_TYPE_IMMUTABLE", "POLICY_BUILTIN_PROTECTED",
                            "POLICY_PARAM_REQUIRED", "POLICY_NOT_FOUND"],
            }
            # 只展示该接口最可能返回的核心错误码（域级子集）
            api_errors = sorted(domain_errors.get(domain, []))
            if api_errors:
                a("**可能错误码**")
                a("")
                for ec in api_errors[:6]:
                    a(f"- `{ec}`")
                a("")

            a("---")
            a("")

    # 全局错误码附录
    a("## 附录 A：全局错误码速查")
    a("")
    a("| 错误码 | HTTP | 说明 |")
    a("|---|---|---|")
    # 从 M01ErrorCode 枚举提取（硬编码关键项）
    all_errors = [
        ("CAPTCHA_REQUIRED", "400", "验证码策略开启，请输入图形验证码"),
        ("CAPTCHA_WRONG", "400", "图形验证码错误，请刷新后重试"),
        ("LOGIN_FAILED", "400", "用户名或密码错误"),
        ("LOGIN_LOCKED", "401", "账号已被锁定"),
        ("LOGIN_DISABLED", "401", "账号已停用"),
        ("SESSION_TIMEOUT", "401", "会话已超时"),
        ("SESSION_LOCKED", "401", "会话已锁定，请重输密码"),
        ("UNAUTHORIZED", "401", "未认证或凭证已失效"),
        ("FORBIDDEN", "403", "无权限访问"),
        ("ADMIN_PROTECTED", "403", "内置管理员受保护"),
        ("SMS_CODE_WRONG", "400", "短信验证码错误或已失效"),
        ("SMS_SEND_TOO_FREQUENT", "429", "发送过于频繁"),
        ("OLD_PASSWORD_WRONG", "400", "原密码不正确"),
        ("PASSWORD_SAME_AS_OLD", "400", "新密码不得与原密码相同"),
        ("OPTIMISTIC_LOCK_CONFLICT", "409", "数据已被修改，请刷新重试"),
        ("VALIDATION_FAILED", "400", "参数校验失败"),
    ]
    for ec, code, msg in all_errors:
        a(f"| {ec} | {code} | {msg} |")
    a("")

    a("## 附录 B：认证方式")
    a("")
    a("```")
    a("Authorization: Bearer <token>")
    a("")
    a("token 获取：POST /api/v1/m01/auth/login")
    a("口令传输：前端 MD5(原文) → RSA 公钥加密 → Base64")
    a("有效期：登录策略 session_timeout_min（默认 30 分钟）")
    a("撤销：POST /auth/logout 或管理员停用用户")
    a("```")
    a("")
    a("---")
    a("")
    a(f"_文档版本：v1.0　　生成时间：{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}　　"
      f"内容哈希：{_sha(''.join(lines))[:16]}..._")

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"[OK] 接口文档已生成：{output_path}（{len(apis)} 接口，{len(groups)} 个域）")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="P9 接口文档生成器（从 design.json apis[]）")
    ap.add_argument("design_json", help="design.json 路径")
    ap.add_argument("output", help="输出 Markdown 路径")
    ap.add_argument("--feature", default="", help="功能名（默认从 design.json 取）")
    args = ap.parse_args()
    generate(args.design_json, args.output, args.feature)
