# -*- coding: utf-8 -*-
"""devflow 结构化业务产物校验器（structured business artifact validator）。

为什么需要它：
  devflow 的 Gate（s2/s6 等）校验最终 Markdown/TSV 产物，但 AI 组装结构化
  中间产物（design.json / verification.json）时，缺字段、锚点断链、孤儿条目、
  静默空集合、手写假 SHA 等错误若不在渲染前拦截，就会带病进入文档与收据。
  本脚本在渲染前用 schema 约束 + 跨字段检查真实验证一次，失败返回非 0 退出码。

设计原则（自 flow-node-panorama 吸收、按 devflow 身份裁剪）：
  1. 确定性层与语义层分离——编号/计数/覆盖率/矩阵由渲染器计算，AI 只填业务判断；
  2. 定位器不是证据——锚点必须指向当前产物章节，引用必须闭环；
  3. 零结果也是证据——合法为空的集合必须在 zero_results 显式声明，静默省略即拦截；
  4. 失败关闭——任何检查失败即非 0 退出，调用方（df_pipeline.py）不得继续渲染。

不依赖第三方库（不 import jsonschema），只实现本库 schema 用到的 JSON Schema 子集：
type(object/array/string/integer/boolean/类型联合)、required、enum、minLength、
minItems、pattern、properties、additionalProperties:false、items + $ref。
改 schemas/*.json 后无需改本脚本。

用法：
  python3 df_validate.py --kind design --input design.json [--criteria acceptance.md]
  python3 df_validate.py --kind verification --input verification.json \
      --baseline first-pass-baseline.tsv [--exec-record test-execution-results.env]

v3.25.0 起支持全阶段产物（每个环节的 md 产物都有对应 JSON 契约）：
  clarification / acceptance / constraints / prd-review / tech-selection /
  design-review / self-check / code-review / prd-validation / test-cases /
  deployment / monitoring / docs-index / retrospective / small-change
  ——schema 的 x-unique/x-refs/x-zeroable/x-min-count 注解由通用引擎统一执行，
  各 kind 的深度规则在 check_<kind> 专项函数中，失败一律非 0 退出。
"""
import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_HERE = Path(__file__).resolve().parent
_SCHEMA_DIR = _HERE.parent / "schemas"
# v3.25.0：全阶段结构化产物注册表——每个环节的 md 产物都有对应 schema（机器可读
# 的「要填哪些内容」清单），AI 填 JSON → 本脚本校验 → df_render 确定性渲染 → Gate。
# kind 名即 df_pipeline.py 的子命令名，与 .devflow/<feature>/<kind>.json 落盘名一致。
_DEFAULT_SCHEMAS = {
    "design": _SCHEMA_DIR / "design.schema.json",
    "verification": _SCHEMA_DIR / "verification.schema.json",
    # P0 / P0b
    "clarification": _SCHEMA_DIR / "clarification.schema.json",
    "acceptance": _SCHEMA_DIR / "acceptance.schema.json",
    "constraints": _SCHEMA_DIR / "constraints.schema.json",
    "prd-review": _SCHEMA_DIR / "prd-review.schema.json",
    # P1 / P2a
    "tech-selection": _SCHEMA_DIR / "tech-selection.schema.json",
    "design-review": _SCHEMA_DIR / "design-review.schema.json",
    # P3 / P3b / P3c / P3d / P4 / P5
    "self-check": _SCHEMA_DIR / "self-check.schema.json",
    "code-review": _SCHEMA_DIR / "code-review.schema.json",
    "security": _SCHEMA_DIR / "security.schema.json",
    "performance": _SCHEMA_DIR / "performance.schema.json",
    "prd-validation": _SCHEMA_DIR / "prd-validation.schema.json",
    "test-cases": _SCHEMA_DIR / "test-cases.schema.json",
    # P7 / P8 / P9 / P10 / P2b / SMALL-CHANGE
    "deployment": _SCHEMA_DIR / "deployment.schema.json",
    "monitoring": _SCHEMA_DIR / "monitoring.schema.json",
    "docs-index": _SCHEMA_DIR / "docs-index.schema.json",
    "retrospective": _SCHEMA_DIR / "retrospective.schema.json",
    "sharing": _SCHEMA_DIR / "sharing.schema.json",
    "demo-signoff": _SCHEMA_DIR / "demo-signoff.schema.json",
    "small-change": _SCHEMA_DIR / "small-change.schema.json",
    "execution-plan": _SCHEMA_DIR / "execution-plan.schema.json",
}


class SchemaError(Exception):
    pass


# ---------- JSON Schema 子集 ----------


def _deref(ref, root):
    if not ref.startswith("#/"):
        raise SchemaError(f"仅支持内部 $ref，收到: {ref}")
    node = root
    for part in ref[2:].split("/"):
        if part not in node:
            raise SchemaError(f"$ref 解析失败: {ref} (缺 {part})")
        node = node[part]
    return node


def _type_ok(t, x):
    checks = {
        "object": lambda v: isinstance(v, dict),
        "array": lambda v: isinstance(v, list),
        "string": lambda v: isinstance(v, str),
        "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
        "boolean": lambda v: isinstance(v, bool),
    }
    if t in checks:
        return checks[t](x)
    raise SchemaError(f"schema 使用了本实现不支持且未声明的类型: {t!r}（拒绝静默跳过类型检查）")


def validate(instance, schema, root, path="", errors=None):
    if errors is None:
        errors = []
    if isinstance(schema, bool):
        if schema is False:
            errors.append(f"{path or '$'}: schema 为 false（拒绝一切值）")
        return errors
    if "$ref" in schema:
        validate(instance, _deref(schema["$ref"], root), root, path, errors)
        return errors

    # v3.24.0: anyOf 组合（acceptance page/api/data 多对象引用 string|array）
    if "anyOf" in schema:
        matched = False
        for opt in schema["anyOf"]:
            if not validate(instance, opt, root, path, []):
                matched = True
                break
        if not matched:
            errors.append(f"{path or '$'}: 不匹配 anyOf 任一分支（{len(schema['anyOf'])} 个候选）")
        return errors

    t = schema.get("type")
    if t is not None:
        types = t if isinstance(t, list) else [t]
        results = [_type_ok(tt, instance) for tt in types]
        if not any(results):
            errors.append(f"{path or '$'}: 类型应 {t}，实际 {type(instance).__name__}")
            return errors

    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path or '$'}: 值 {instance!r} 不在枚举 {schema['enum']} 中")

    if "minLength" in schema and isinstance(instance, str):
        if len(instance) < schema["minLength"]:
            errors.append(f"{path or '$'}: 字符串长度应 ≥ {schema['minLength']}，实际 {len(instance)}")

    if "minItems" in schema and isinstance(instance, list):
        if len(instance) < schema["minItems"]:
            errors.append(f"{path or '$'}: 数组长度应 ≥ {schema['minItems']}，实际 {len(instance)}")

    # v3.17.2(L1): fullmatch——Python 的 $ 容忍尾部换行，"R1\n" 曾通过 ^R[0-9]+$；
    # 本库 schema 的 pattern 全部全锚定，fullmatch 与 JSON Schema 语义在此等价且更严。
    if "pattern" in schema and isinstance(instance, str):
        if not re.fullmatch(schema["pattern"], instance):
            errors.append(f"{path or '$'}: 值 {instance!r} 不匹配 pattern {schema['pattern']}")

    if isinstance(instance, dict):
        if schema.get("type") in ("object", None) or "properties" in schema:
            for k in schema.get("required", []):
                if k not in instance:
                    errors.append(f"{path or '$'}: 缺少必需字段 {k!r}（required）")
            props = schema.get("properties", {})
            if schema.get("additionalProperties") is False:
                for k in instance:
                    if k not in props:
                        errors.append(f"{path or '$'}: 多余字段 {k!r}（additionalProperties=false，疑为拼写错误）")
            for k, v in instance.items():
                sub = props.get(k)
                if sub is not None:
                    validate(v, sub, root, f"{path}.{k}" if path else k, errors)

    if isinstance(instance, list):
        item_schema = schema.get("items")
        if item_schema is not None:
            for i, item in enumerate(instance):
                validate(item, item_schema, root, f"{path}[{i}]", errors)

    return errors


# ---------- 通用工具 ----------

# v3.27.1(L-EFF-001)：占位话术误伤收敛——「移除授权需确认」「TBD-07 文档引用」「占位符」等
# 合法中文/编号不再命中；保留明确占位语义（TODO/TBD/待补充/【待确认】/占位非符/暂定…）
_PLACEHOLDER_RE = re.compile(
    r"TODO(?![-0-9A-Za-z])|TBD(?![-0-9A-Za-z])|FIXME(?![-0-9A-Za-z])"
    r"|待补充|REPLACE_WITH|占位(?!符|图)|暂定"
    r"|【待确认|待确认】|待确认：|【待定|待定】|待定：|【需确认|需确认】|需确认："
    r"|【待验证|待验证】|待验证：|XXX(?![-0-9A-Za-z])"
)


def _walk_strings(obj, path, hits, ignore_re=None):
    def _hit(p):
        return ignore_re is not None and ignore_re.search(p or "")
    if isinstance(obj, str):
        if not _hit(path):
            m = _PLACEHOLDER_RE.search(obj)
            if m:
                hits.append((path, f"占位话术「{m.group(0)}」", obj[:50]))
    elif isinstance(obj, dict):
        for k, v in obj.items():
            _walk_strings(v, f"{path}.{k}" if path else k, hits, ignore_re)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            _walk_strings(v, f"{path}[{i}]", hits, ignore_re)


def check_placeholders(data, errors, ignore_re=None):
    """全文递归扫描字符串：占位话术直接拦截（必然是漏填的语义层）。

    ignore_re：路径豁免（v3.25.0）——部分产物的字段本身就是「检查占位符的命令/
    检查项名」（如完成度自检 grep TODO 的 cmd），对这些路径扫描会误伤合法内容。"""
    hits = []
    _walk_strings(data, "", hits, ignore_re)
    for path, kind, preview in hits:
        errors.append(f"{path}: {kind}（…{preview}…）")


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _safe_sha256(path):
    try:
        return _sha256(path)
    except (IsADirectoryError, PermissionError, OSError):
        return None


def _zero_declared(data, path):
    return any(z.get("path") == path for z in data.get("zero_results", []))


_PLACEHOLDER_CMDS = {"true", ":", "false", "pwd", "ls", "touch", "cat", "tee", "echo", "printf", "exit"}
_SHELL_WRAPPERS = {"bash", "sh", "zsh", "env", "command", "exec"}


_WRAPPER_TOKEN_RE = re.compile(r"(?:^|[\s;|&()])(?:[^\s;|&()]*/)?(bash|sh|zsh|env|command|exec)(?:[\s;|&()]|$)")


def _cmd_is_placeholder(cmd):
    """占位命令与 shell 转包检测——口径移植自 s6_final_verification_gate.sh：
    ① 首个非变量赋值 token ∈ 黑名单即占位（覆盖 true && echo / : > file / false --help /
    ls -la; cat 等变体）；② 全命令扫描 bash/sh/zsh/env/command/exec 转包（含
    `pytest && bash -c '自造报告'`），与 s6 _is_shell_wrapper 同口径。"""
    if _WRAPPER_TOKEN_RE.search(cmd):
        return "shell 包装命令（禁止 bash/sh/env 转包自造报告）"
    first = ""
    for tok in cmd.split():
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.", tok):
            first = tok
            break
    if first == "":
        return "纯变量赋值命令（非测试执行）"
    if first in _PLACEHOLDER_CMDS or first.endswith(("/true", "/false", "/pwd", "/ls", "/touch", "/cat", "/tee", "/echo", "/printf")):
        return "占位命令（非测试执行）"
    return None


# ---------- design 跨字段检查 ----------

# 标题锚点提取（v3.17.2/M3 宽容化；v3.19.0 P1-4 放宽到任意深度）：
# ① 编号后断言「非数字且非 .数字」——兼容 `#### 3.2.1用户登录`、`#### 3.2.1. 字段`、`#### **3.2.1** x`；
# ② 深度 ≥1 段（§7 页面 / §2.1 表 / §3.2.1 详细定义共用同一收集器）；
# ③ 解析时跳过 ``` 围栏内伪标题（防反向误报与正向伪装）。
_API_DETAIL_HEADING_RE = re.compile(r"^#{1,6}\s+(?:\*\*)?\s*§?([0-9]+(?:\.[0-9]+)*)(?!\.?[0-9])")


def _doc_detail_headings(doc):
    headings = {}
    in_fence = False
    _fence_marker = ""
    for ln in doc.read_text(encoding="utf-8", errors="replace").splitlines():
        _stripped = ln.strip()
        # v3.20.2(P1-5): ``` 与 ~~~ 均为围栏，但只有同标记才能闭合——
        # 混用（``` 内含 ~~~ 行）曾导致围栏误闭合，真标题被吞/伪标题外泄
        if _stripped.startswith("```") or _stripped.startswith("~~~"):
            if not in_fence:
                in_fence = True
                _fence_marker = _stripped[:3]
            elif _stripped.startswith(_fence_marker):
                in_fence = False
            continue
        if in_fence:
            continue
        m = _API_DETAIL_HEADING_RE.match(ln.strip())
        if m:
            headings.setdefault(_norm_anchor(m.group(1)), ln.strip()[:60])
    return headings


def _norm_anchor(a):
    return (a or "").strip().lstrip("§").strip()


def check_api_detail_closure(data, errors, doc_path=None):
    """接口概览 ↔ 详细接口定义 一一对应（双向闭环）：
    (a) 每个 apis[].detail_anchor 唯一；
    (b) 给出 --doc 时：概览声明的每个详细定义小节必须在文档中以标题真实存在——
        拦「概览列了 N 个、详细定义只写了 M<N 个」；标题兼容 `#### 3.2.1 x` 与
        `#### §3.2.1 x` 两种写法（JSON 侧统一 § 规范形）；
    (c) 给出 --doc 时：文档中位于详细定义层级的 §N.N.K 标题若不在 apis[].detail_anchor
        中 → 多余小节（详设写了概览却没有收录的接口），同样拦截。"""
    apis = data.get("apis", [])
    anchors = [_norm_anchor(a.get("detail_anchor")) for a in apis]
    dups = sorted({x for x in anchors if anchors.count(x) > 1})
    if dups:
        errors.append(f"apis[].detail_anchor 存在重复: {dups}（概览与详细定义必须一一对应）")

    if not doc_path:
        return
    doc = Path(doc_path)
    if not doc.exists():
        errors.append(f"--doc 文件不存在: {doc_path}（接口概览↔详细定义闭环无法对账）")
        return
    headings = _doc_detail_headings(doc)

    # 正向：概览声明的详细定义小节必须存在
    for i, a in enumerate(apis):
        da = _norm_anchor(a.get("detail_anchor"))
        if da not in headings:
            errors.append(
                f"apis[{i}]({a.get('method')} {a.get('path')}): 详细定义小节 {a.get('detail_anchor')} 在文档中不存在"
                f"（概览已列出但详细接口定义缺失——补详细定义小节或删概览行）"
            )
    # 反向：详细定义层级的标题必须被概览收录
    # v3.17.3(B-2): 仅当全部 detail_anchor ≥3 段时才做反向检查——两级锚点（§3.2）无法区分
    # 「§3 下的其他兄弟章节」（如 §3.1 接口概览）与多余详定义小节，反向检测对两级不可靠。
    if anchors and all(len(x.split(".")) >= 3 for x in anchors):
        detail_prefixes = {".".join(x.split(".")[:-1]) for x in anchors if x}
        for h, src in sorted(headings.items()):
            if h in set(anchors):
                continue
            prefix = ".".join(h.split(".")[:-1])
            if prefix in detail_prefixes:
                errors.append(
                    f"文档详细定义小节 {h} 未被接口概览收录（{src}）"
                    f"——在 apis[] 补录该接口或删除该小节（概览↔详细定义必须一一对应）"
                )


def check_ddr_closure(data, errors):
    """DDR ↔ 表设计字段 一一对应（双向闭环，§2.3）：
    (a) 每个表字段必须引用 ≥1 条 decisions[]（schema 已强制 minItems）；
    (b) 字段引用的 DDR 编号必须存在于 decisions[]——拦悬空引用；
    (c) 每条 decisions[] 必须被 ≥1 字段引用，全局决策须显式 unreferenced_reason——拦孤儿决策。"""
    decisions = data.get("decisions", [])
    dec_ids = [d.get("id") for d in decisions]
    dup = sorted({x for x in dec_ids if dec_ids.count(x) > 1})
    if dup:
        errors.append(f"decisions[].id 存在重复: {dup}")
    dec_set = set(dec_ids)

    cited = {}
    for ti, t in enumerate(data.get("tables", [])):
        for fi, f in enumerate(t.get("fields", [])):
            for ref in f.get("ddr", []):
                cited.setdefault(ref, f"tables[{ti}].{t.get('name')}.{f.get('name')}")
                if ref not in dec_set:
                    errors.append(
                        f"{cited[ref]}: 字段引用的 DDR {ref!r} 在 decisions[] 中不存在（悬空引用）"
                    )
    for i, d in enumerate(decisions):
        if d.get("id") not in cited and not d.get("unreferenced_reason"):
            errors.append(
                f"decisions[{i}]({d.get('id')}: {d.get('topic')!r}) 未被任何表字段引用且无 unreferenced_reason"
                f"（孤儿决策：与表设计失去一一对应——在字段 ddr 中回填引用，或声明为全局决策并给出理由）"
            )


def check_compensation_chain(data, errors):
    """正向副作用 × 反向操作 补偿链闭环（v3.20.0，借鉴数据恢复矩阵）：
    resources 声明的每个被占用资源，必须在每个反向操作（cancel/rollback/timeout/retry）
    的 resource_closure 中逐一表态（on_operation/on_next_submit/never/not_applicable）；
    never/not_applicable 必须写理由；沉默即补偿链缺失——数据一致性缺陷的直接来源。"""
    resources = data.get("resources", [])
    operations = data.get("operations", [])
    res_ids = [r.get("id") for r in resources]
    dups = sorted({x for x in res_ids if res_ids.count(x) > 1})
    if dups:
        errors.append(f"resources[].id 存在重复: {dups}")
    op_ids = [o.get("id") for o in operations]
    dups = sorted({x for x in op_ids if op_ids.count(x) > 1})
    if dups:
        errors.append(f"operations[].id 存在重复: {dups}")
    if resources and not operations:
        errors.append(
            f"resources 声明了 {len(resources)} 个正向占用资源，但 operations 为空"
            f"（补偿链缺失——cancel/rollback/timeout/retry 必须逐一表态资源释放）"
        )
        return
    res_set = set(res_ids)
    reverse_types = {"cancel", "rollback", "timeout", "retry"}
    # v3.20.2(P1-6a): 有资源、operations 非空但全是 create/update——没有任何反向操作
    # 即没有任何释放路径，changelog 承诺的「有资源无反向操作即阻断」在此收口
    if resources and operations and not any(op.get("type") in reverse_types for op in operations):
        errors.append(
            f"resources 声明了 {len(resources)} 个正向占用资源、operations {len(operations)} 个，"
            f"但无任何 cancel/rollback/timeout/retry 反向操作（补偿链缺失——只有占用没有释放路径）"
        )
    for oi, op in enumerate(operations):
        if op.get("type") not in reverse_types:
            continue
        where = f"operations[{oi}]({op.get('id')}:{op.get('name')})"
        covered_list = {}
        for ci, c in enumerate(op.get("resource_closure", [])):
            rid = c.get("resource")
            covered_list.setdefault(rid, []).append(c)
            if rid not in res_set:
                errors.append(f"{where}.resource_closure[{ci}]: 资源 {rid!r} 不在 resources[] 中（悬空表态）")
            if not (c.get("evidence") or "").strip():
                errors.append(
                    f"{where}.resource_closure[{ci}]({rid}): 缺少 evidence"
                    f"（每一表态都要有代码证据或理由——释放调用/永不释放的原因）"
                )
        missing = [r for r in res_ids if r not in covered_list]
        if missing:
            errors.append(
                f"{where}.resource_closure: 缺少对资源 {missing} 的释放表态"
                f"（反向操作必须对每个正向占用资源逐一表态："
                f"on_operation/on_next_submit/never+理由/not_applicable+理由）"
            )
        # v3.20.2(P1-6b): 同一反向操作对同一资源的 release_timing 必须唯一——
        # 「立即释放」与「永不释放」并存 = 表态自相矛盾（曾静默通过）
        for _rid, _cs in covered_list.items():
            _timings = sorted({c.get("release_timing") for c in _cs if c.get("release_timing")})
            if len(_timings) > 1:
                errors.append(
                    f"{where}.resource_closure({_rid}): 同一资源给出互斥 release_timing {_timings}"
                    f"（立即释放/下次提交/永不释放/不涉及 只能择一）"
                )


def check_integrations_configs(data, errors, workspace=""):
    """外部集成 + 配置消费规格（v3.20.0，借鉴外部推送验证链与配置消费规格卡）：
    集成必须有端点/超时/幂等/失败路径；配置键必须有值格式/消费点/失败路径，
    死配置（全部消费点均死代码）拦截，低置信必须给原因。"""
    integrations = data.get("integrations", [])
    iids = [i.get("id") for i in integrations]
    dups = sorted({x for x in iids if iids.count(x) > 1})
    if dups:
        errors.append(f"integrations[].id 存在重复: {dups}")
    for i, it in enumerate(integrations):
        if not (it.get("endpoint") or "").strip():
            errors.append(f"integrations[{i}]({it.get('id')}): 缺 endpoint（端点/MQ 主题/回调路径）")
        if it.get("fallback") and len(it["fallback"]) < 4:
            errors.append(f"integrations[{i}]({it.get('id')}): fallback 描述过短（{it['fallback']!r}）")

    configs = data.get("configs", [])
    keys = [c.get("key") for c in configs]
    dups = sorted({x for x in keys if keys.count(x) > 1})
    if dups:
        errors.append(f"configs[].key 存在重复: {dups}")
    for i, c in enumerate(configs):
        where = f"configs[{i}]({c.get('key')})"
        if c.get("confidence") in ("low", "medium") and not (c.get("confidence_reason") or "").strip():
            errors.append(f"{where}: confidence={c.get('confidence')} 但缺 confidence_reason")
        points = c.get("consumption_points", [])
        active = [pt for pt in points if pt.get("status") == "active"]
        for j, pt in enumerate(points):
            if pt.get("status") in ("dead_code", "commented_out") and not (pt.get("note") or "").strip():
                errors.append(
                    f"{where}.consumption_points[{j}]: 死代码/注释点必须标注依据"
                    f"（如方法首行 if(true) return——死消费点不实现，漏标会多做无用功）"
                )
        if points and not active:
            errors.append(f"{where}: 全部消费点均为死代码/注释（死配置不应引入或消费）")
        # v3.20.2(P1-6c): active 消费点 location 占位值无条件拒绝；真实路径反查
        # 仅在提供 --workspace 时执行（全仓反查需要仓库根，无 workspace 的调用保持旧语义）
        _ws = str(workspace or "").strip()
        # 反查生效条件：workspace 非 "." 默认值，或 cwd 具备工程标志（避免对
        # df_pipeline 的 --workspace . 例行调用在非仓库目录误报）
        _ws_effective = ""
        if _ws and _ws != ".":
            _ws_effective = _ws
        else:
            for _marker in ("pom.xml", "package.json", "go.mod", "Cargo.toml", "Makefile", "pyproject.toml", "build.gradle"):
                if Path(_marker).is_file():
                    _ws_effective = _ws or "."
                    break
        for j, pt in enumerate(points):
            if pt.get("status") != "active":
                continue
            _loc = (pt.get("location") or "").strip()
            # file#symbol 引用格式：反查取 # 前的文件部分
            _loc_path = _loc.split("#", 1)[0].strip()
            if not _loc or _loc in ("x", "X", "test", "TODO", "todo", "-", "location"):
                errors.append(
                    f"{where}.consumption_points[{j}]: active 消费点 location 必须是仓内真实文件路径（得到 {_loc!r}）"
                )
            elif _ws_effective:
                _base = Path(_ws_effective)
                _target = (_base / _loc_path) if not Path(_loc_path).is_absolute() else Path(_loc_path)
                if not _target.is_file():
                    errors.append(
                        f"{where}.consumption_points[{j}]: active 消费点 location 文件不存在: {_loc_path}（消费点全仓反查失败）"
                    )
                elif c.get("key") and c["key"] not in _target.read_text(encoding="utf-8", errors="replace"):
                    errors.append(
                        f"{where}.consumption_points[{j}]: 消费点文件 {_loc} 中未检索到配置键 {c.get('key')!r}（全仓反查）"
                    )


def check_doc_anchors(data, errors, doc_path):
    """pages/tables/apis/rules 声明的每个 § 锚点必须在文档中以标题真实存在（v3.19.0 P1-4）。
    锚点是证据位：JSON 内互相引用闭环只证明"自洽"，不证明"文档真的写了该章节"。"""
    doc = Path(doc_path)
    if not doc.exists():
        errors.append(f"--doc 文件不存在: {doc_path}（锚点对账无法执行）")
        return
    headings = _doc_detail_headings(doc)
    checks = [
        (data.get("pages", []), "pages", "页面"),
        (data.get("tables", []), "tables", "数据表"),
        (data.get("apis", []), "apis", "接口"),
        (data.get("rules", []), "rules", "规则"),
        (data.get("resources", []), "resources", "资源"),
        (data.get("operations", []), "operations", "操作"),
        (data.get("integrations", []), "integrations", "集成"),
        (data.get("configs", []), "configs", "配置键"),
        # v3.24.0(A01)：业务操作锚点同样必须落盘为真实章节
        (data.get("business_operations", []), "business_operations", "业务操作"),
    ]
    for items, label, zh in checks:
        for i, it in enumerate(items):
            a = _norm_anchor(it.get("anchor"))
            if a and a not in headings:
                errors.append(
                    f"{label}[{i}](§{a}): §锚点在文档中不存在"
                    f"（{zh}「{it.get('name', '')}」须在详设中有对应章节标题）"
                )


def _doc_sections(doc):
    """v3.24.0(A03)：按标题切分文档——{锚点编号: 剥离围栏的小节正文} 与 {锚点编号: 原文}。

    小节边界 = 下一个任意编号标题（父/兄弟/子均截断——锚点小节以编号标题为界，
    每个编号标题开启自己的小节）；未编号标题视为小节内内容；剥离围栏版供表格
    对账（防围栏内伪表格污染），原文版供实质内容检查（围栏内伪代码/时序图同
    样是实质内容）。"""
    sections = {}
    sections_raw = {}
    current_key = None
    current_lines = []
    current_raw = []
    in_fence = False
    fence_marker = ""

    def _flush():
        if current_key is not None:
            sections[current_key] = "\n".join(current_lines)
            sections_raw[current_key] = "\n".join(current_raw)

    for ln in doc.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = ln.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            if not in_fence:
                in_fence, fence_marker = True, stripped[:3]
            elif stripped.startswith(fence_marker):
                in_fence = False
            if current_key is not None:
                current_raw.append(ln)
            continue
        if in_fence:
            if current_key is not None:
                current_raw.append(ln)
            continue
        m = _API_DETAIL_HEADING_RE.match(stripped)
        if m:
            _flush()
            current_key = _norm_anchor(m.group(1))
            current_lines = []
            current_raw = []
            continue
        if current_key is not None:
            current_lines.append(ln)
            current_raw.append(ln)
    _flush()
    return sections, sections_raw


def _section_table_rows(text):
    """v3.24.0(A03)：提取小节内所有 Markdown 表格数据行（跳过分隔行）→ [[单元格…]]。"""
    rows = []
    for ln in (text or "").splitlines():
        s = ln.strip()
        if not s.startswith("|"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
            continue
        if cells and not any(c for c in cells):
            continue
        rows.append(cells)
    return rows


def _norm_type(v):
    return re.sub(r"[^a-z0-9]", "", str(v or "").lower())


def _norm_constraint(v):
    return re.sub(r"[^a-z0-9]", "", str(v or "").lower())


def check_doc_content_agreement(data, errors, doc_path):
    """v3.24.0(A03)：JSON ↔ 正文事实对账——同字段清单/类型不得双正本互相冲突。

    (a) 表结构：table.fields 的每个字段名必须出现在该表锚点小节表格首列；
        小节含表格时，JSON 类型与正文第二列类型归一化后必须一致；
    (b) 接口：request/response 字段必须出现在 detail_anchor 小节表格首列且类型一致
        （小节无表格时不比字段——由 (c) 实质内容检查兜底，兼容骨架态）；
    (c) 实质内容：所有被引用锚点的小节不得是空壳（只剩标题/注释——曾以
        仅标题正文通过 df_validate --doc）。"""
    doc = Path(doc_path)
    if not doc.exists():
        return
    sections, sections_raw = _doc_sections(doc)

    def _substantive(text):
        for ln in (text or "").splitlines():
            s = ln.strip()
            if not s or s.startswith("#") or s.startswith("<!--") or s.startswith(">"):
                continue
            if len(re.sub(r"\s", "", s)) >= 8:
                return True
        return False

    anchored = []
    for t in data.get("tables", []):
        anchored.append((_norm_anchor(t.get("anchor")), f"tables「{t.get('name')}」"))
    for a in data.get("apis", []):
        anchored.append((_norm_anchor(a.get("detail_anchor")), f"apis「{a.get('name')}」详细定义"))
        anchored.append((_norm_anchor(a.get("anchor")), f"apis「{a.get('name')}」概览"))
    for p in data.get("pages", []):
        anchored.append((_norm_anchor(p.get("anchor")), f"pages「{p.get('name')}」"))
    for r in data.get("rules", []):
        anchored.append((_norm_anchor(r.get("anchor")), f"rules「{r.get('id')}」"))
    for o in data.get("business_operations", []):
        anchored.append((_norm_anchor(o.get("anchor")), f"business_operations「{o.get('name')}」"))
    for key, label in anchored:
        if key and key in sections and not _substantive(sections_raw.get(key, "")):
            errors.append(
                f"{label}(§{key}): 小节为空壳（仅标题无实质内容）"
                f"——正文与 JSON 不得一实一空"
            )

    for ti, t in enumerate(data.get("tables", [])):
        key = _norm_anchor(t.get("anchor"))
        sec = sections.get(key)
        if sec is None:
            continue  # 锚点缺失已由 check_doc_anchors 报告
        rows = _section_table_rows(sec)
        if not rows:
            continue
        index = {}
        for r in rows:
            if r and r[0]:
                index.setdefault(r[0], []).append(r)
        for f in t.get("fields", []):
            name = f.get("name")
            if name and name not in index:
                errors.append(
                    f"tables[{ti}]({t.get('name')}) 字段 {name!r} 未出现在 §{key} 表格首列"
                    f"（JSON 与正文字段清单冲突——同字段双正本必须一致）"
                )
            elif name in index and len(index[name]) == 1:
                row = index[name][0]
                # v3.24.0(A03)：类型与约束列都比对（报告要求拒绝同字段类型/约束不一致）
                if len(row) >= 2 and _norm_type(f.get("type")) and _norm_type(row[1]) \
                   and _norm_type(f.get("type")) != _norm_type(row[1]):
                    errors.append(
                        f"tables[{ti}]({t.get('name')}) 字段 {name!r}: JSON 类型 {f.get('type')!r}"
                        f" 与正文 §{key} 表格类型 {row[1]!r} 冲突"
                    )
                if len(row) >= 3 and _norm_constraint(f.get("constraint")) and _norm_constraint(row[2]) \
                   and _norm_constraint(f.get("constraint")) != _norm_constraint(row[2]):
                    errors.append(
                        f"tables[{ti}]({t.get('name')}) 字段 {name!r}: JSON 约束 {f.get('constraint')!r}"
                        f" 与正文 §{key} 表格约束 {row[2]!r} 冲突"
                    )

    for ai, a in enumerate(data.get("apis", [])):
        key = _norm_anchor(a.get("detail_anchor"))
        sec = sections.get(key)
        if sec is None:
            continue
        rows = _section_table_rows(sec)
        if not rows:
            continue
        index = {}
        for r in rows:
            if r and r[0]:
                index.setdefault(r[0], []).append(r)
        for side in ("request", "response"):
            for f in (a.get(side) or {}).get("fields", []):
                name = f.get("name")
                if not name:
                    continue
                base = name.split("[].")[0]
                if name not in index and base not in index:
                    errors.append(
                        f"apis[{ai}]({a.get('name')}) {side} 字段 {name!r}"
                        f" 未出现在详细定义小节 §{key} 的表格首列（JSON 与正文契约冲突）"
                    )
                else:
                    # 同名字段在请求/响应两张表都出现时无法可靠归属——仅唯一出现时比对类型
                    row = (index.get(name) or index.get(base) or [None])[0]
                    if row is not None and len(index.get(name) or index.get(base)) == 1 and len(row) >= 2:
                        if _norm_type(f.get("type")) and _norm_type(row[1]) \
                           and _norm_type(f.get("type")) != _norm_type(row[1]):
                            errors.append(
                                f"apis[{ai}]({a.get('name')}) {side} 字段 {name!r}: "
                                f"JSON 类型 {f.get('type')!r} 与正文表格类型 {row[1]!r} 冲突"
                            )
                        # v3.27.11：响应「恒出性」JSON↔正文对账（此前为无消费者的空转字段）
                        if side == "response" and len(row) >= 3:
                            jv = str(f.get("always") or "").strip()
                            dv = str(row[2] or "").strip()
                            if jv and dv and jv != dv:
                                errors.append(
                                    f"apis[{ai}]({a.get('name')}) response 字段 {name!r}: "
                                    f"JSON 恒出性 {jv!r} 与正文表格恒出性 {dv!r} 冲突"
                                    f"（同字段双正本必须一致）"
                                )

    # v3.24.0(A03)：规则 WHEN 逐字契约——rules[].when_line 必须在该规则 §锚点小节
    # 原文（含围栏）中逐字出现；正文改写伪代码而 JSON 不同步即"规则不一致"。
    for ri, r in enumerate(data.get("rules", [])):
        when_line = (r.get("when_line") or "").strip()
        if not when_line:
            continue
        key = _norm_anchor(r.get("anchor"))
        sec_raw = sections_raw.get(key)
        if sec_raw is None:
            continue  # 锚点缺失已由 check_doc_anchors 报告
        if when_line not in sec_raw:
            errors.append(
                f"rules[{ri}]({r.get('id')}).when_line: 在 §{key} 小节中找不到逐字匹配的 WHEN 行"
                f"（{when_line!r}）——正文伪代码与 JSON 规则不一致，二者必须同源"
            )


def _load_reserved_word_tiers():
    """v3.28.1：保留字清单单一正本 = references/db-reserved-words.md 的
    DEVFLOW:RESERVED-TIERS 契约块。fail=真保留字（FAIL）；warn=高风险软关键字（WARN）。"""
    fail, warn = set(), set()
    ref = Path(__file__).resolve().parent.parent / "references" / "db-reserved-words.md"
    if not ref.is_file():
        return fail, warn
    m = re.search(r"<!--\s*DEVFLOW:RESERVED-TIERS(.*?)-->",
                  ref.read_text(encoding="utf-8", errors="replace"), re.S)
    if not m:
        return fail, warn
    for line in m.group(1).splitlines():
        line = line.strip()
        low = line.lower()
        if low.startswith("fail="):
            fail = {w.strip().lower() for w in line.split("=", 1)[1].split(",") if w.strip()}
        elif low.startswith("warn="):
            warn = {w.strip().lower() for w in line.split("=", 1)[1].split(",") if w.strip()}
    warn -= fail
    return fail, warn


def check_reserved_words(data, errors, warnings):
    """v3.28.1：表名/字段名数据库保留字扫描——fail 层记 errors，warn 层记 warnings。"""
    fail_words, warn_words = _load_reserved_word_tiers()
    if not (fail_words or warn_words):
        return
    for ti, t in enumerate(data.get("tables", [])):
        idents = [(t.get("name"), "表名")]
        idents += [(f.get("name"), "字段") for f in (t.get("fields") or [])]
        for ident, kind in idents:
            w = str(ident or "").strip().lower()
            if not w:
                continue
            if w in fail_words:
                errors.append(
                    f"tables[{ti}]({t.get('name')}) {kind} {ident!r} 命中数据库保留字（fail 层）"
                    f"——未加引号建表/查询会报错，按 references/db-reserved-words.md 改名后再校验"
                )
            elif w in warn_words:
                warnings.append(
                    f"tables[{ti}]({t.get('name')}) {kind} {ident!r} 是高风险软关键字（warn 层）"
                    f"——建议按 references/db-reserved-words.md 规避，或在口径说明中写明理由"
                )


def check_error_codes(data, errors, doc_path=None):
    """v3.28.1：rules[].error_codes[] 错误码契约——全局唯一 + 必须出现在详设正文。

    错误码此前只散落在规则「约束/错误处理」列与 §7.4 前端行为表（手写，易漂移）。
    登记即对账：重复码 FAIL；提供 --doc 时码必须出现在正文（规则列或行为表）。"""
    seen = {}
    for ri, r in enumerate(data.get("rules", [])):
        for ei, ec in enumerate(r.get("error_codes") or []):
            code = str(ec.get("code") or "").strip()
            if not code:
                continue
            where = f"rules[{ri}]({r.get('id')}).error_codes[{ei}]"
            if code in seen:
                errors.append(f"{where}: 错误码 {code} 与 {seen[code]} 重复（错误码全局唯一）")
            else:
                seen[code] = f"rules[{ri}]({r.get('id')})"
    if not seen or not doc_path:
        return
    p = Path(doc_path)
    if not p.is_file():
        return
    text = p.read_text(encoding="utf-8", errors="replace")
    for code, where in sorted(seen.items()):
        if code not in text:
            errors.append(
                f"{where}.error_codes: 错误码 {code} 未出现在详设正文"
                f"（须写入规则「约束/错误处理」列或 §7.4 前端行为表）"
            )


def check_heading_hierarchy(errors, warnings, doc_path):
    """v3.28.3(L-HIER-1)：标题层级闭环（提供 --doc 时）——N.M.K 子级标题必须有 N.M 父级标题。

    三层编号（§2.2.N 表 / §3.2.N 接口 / §6.2.N 业务操作 / §7.2.N 页组）隐含必须存在
    N.M 父级小节标题。ch07 详设曾出现 §6.1 直接跳 §6.2.1、§7.1 直接跳 §7.2.1（缺
    §6.2/§7.2 父级）却通过全部 Gate：锚点存在性校验只证明「§6.2.1 标题存在」，不证明
    「§6.2 父级章节存在」。本检查补上该缺口：
    - 父级锚点缺失 → FAIL（fail-closed）；
    - 父级存在但标题深度不是子级-1（如 #### §6.2.1 配了 #### §6.2）→ WARN（不阻断，
      与 v3.19.0 P1-4「锚点匹配放宽到任意深度」口径一致）。
    围栏内伪标题跳过（与 _doc_detail_headings 同一口径）。"""
    doc = Path(doc_path)
    if not doc.is_file():
        return  # 文件不存在已由 check_doc_anchors 报告，不重复报
    _heading_re = re.compile(r"^(#{1,6})\s+(?:\*\*)?\s*§?([0-9]+(?:\.[0-9]+)*)(?!\.?[0-9])")
    entries = []  # (深度, 规范化锚点, 截断标题行)
    in_fence = False
    _fence_marker = ""
    for ln in doc.read_text(encoding="utf-8", errors="replace").splitlines():
        _stripped = ln.strip()
        if _stripped.startswith("```") or _stripped.startswith("~~~"):
            if not in_fence:
                in_fence = True
                _fence_marker = _stripped[:3]
            elif _stripped.startswith(_fence_marker):
                in_fence = False
            continue
        if in_fence:
            continue
        m = _heading_re.match(_stripped)
        if m:
            entries.append((len(m.group(1)), _norm_anchor(m.group(2)), _stripped[:60]))
    anchor_depth = {}
    for depth, a, _disp in entries:
        anchor_depth.setdefault(a, depth)
    # 缺父级按父级锚点聚合——一个父级缺失只报一条（附波及子级数与首个示例），不逐子级刷屏
    _missing = {}  # parent -> {"count": int, "example": str, "depth": int}
    for depth, a, disp in entries:
        parts = a.split(".")
        if len(parts) < 2:
            continue
        parent = ".".join(parts[:-1])
        if parent not in anchor_depth:
            info = _missing.setdefault(parent, {"count": 0, "example": disp, "depth": depth})
            info["count"] += 1
        elif anchor_depth[parent] != depth - 1:
            warnings.append(
                f"--doc 标题层级不规范: 「{disp}」的父级 §{parent} 为 {anchor_depth[parent]} 级标题"
                f"（建议 {depth - 1} 级，即 {'#' * (depth - 1)}；不阻断）"
            )
    for parent in sorted(_missing, key=lambda p: [int(x) for x in p.split(".")]):
        info = _missing[parent]
        errors.append(
            f"--doc 标题层级断裂: {info['count']} 个 §{parent}.N 小节缺少父级标题 §{parent}"
            f"（首例「{info['example']}」；N.M.K 三层编号隐含 N.M 父级小节必须真实存在，"
            f"如 {'#' * (info['depth'] - 1)} §{parent} …）"
        )


def check_page_specs(data, errors):
    """v3.27.9(F2)：页面规格结构化——dialogs[].api 锚点闭环到 apis[]。

    弹窗/抽屉映射（§7.2 弹窗/抽屉表，v3.28.1 由原 §7.3 并入）是写操作交互的
    接口证据位：api 必须引用真实存在的 §3.2.N 详细定义（apis[].anchor/detail_anchor），
    或显式 — 声明无接口交互。

    链路闭环（v3.28.1）：table_columns[].api_field（`§x.y.z 字段`）/source（`表.字段`）、
    form_controls[].submit_api（`§x.y.z`）/target_field（`表.字段`）提供即对账——
    接口锚点必须存在、字段/落库列必须存在于 apis[] / tables[]（悬空即 FAIL）。

    测试锚点：form_controls/dialogs/actions 的 test_anchor 全文档唯一
    （格式 pattern 由 schema required+pattern 强制，此处管唯一性）；actions[].api
    锚点闭环到 apis[]，actions[].dialog 必须存在于同页 dialogs[].name。"""
    api_anchors = set()
    api_fields = {}  # 规范化 anchor -> {字段名}
    for a in data.get("apis", []):
        fields = set()
        for side in ("request", "response"):
            for f in (a.get(side) or {}).get("fields") or []:
                if f.get("name"):
                    fields.add(str(f.get("name")).strip())
        for k in ("anchor", "detail_anchor"):
            v = (a.get(k) or "").strip()
            if v:
                api_anchors.add(v)
                api_anchors.add(_norm_anchor(v))
                api_fields.setdefault(_norm_anchor(v), set()).update(fields)
    table_fields = set()
    for t in data.get("tables", []):
        tname = str(t.get("name") or "").strip()
        for f in t.get("fields") or []:
            fname = str(f.get("name") or "").strip()
            if tname and fname:
                table_fields.add(f"{tname}.{fname}")
    for pi, p in enumerate(data.get("pages", [])):
        where = f"pages[{pi}]({p.get('name')})"
        for ci, c in enumerate(p.get("table_columns") or []):
            af = str(c.get("api_field") or "").strip()
            if af:
                m = re.match(r"^§([0-9]+(?:\.[0-9]+)+)\s+(\S+)$", af)
                if not m:
                    errors.append(
                        f"{where}.table_columns[{ci}]({c.get('field')}).api_field={af!r} 格式非法"
                        f"（须为 `§x.y.z 字段名`，如 `§3.2.1 records[].recordNo`）"
                    )
                else:
                    anc, fld = m.group(1), m.group(2)
                    if anc not in api_fields:
                        errors.append(
                            f"{where}.table_columns[{ci}]({c.get('field')}).api_field 锚点 §{anc} "
                            f"不在 apis[] 中（链路断链——列→接口→表必须闭环）"
                        )
                    elif fld not in api_fields[anc]:
                        errors.append(
                            f"{where}.table_columns[{ci}]({c.get('field')}).api_field 字段 {fld!r} "
                            f"不在 §{anc} 的请求/响应字段中（链路断链）"
                        )
            src = str(c.get("source") or "").strip()
            if src and src != "—" and src not in table_fields:
                errors.append(
                    f"{where}.table_columns[{ci}]({c.get('field')}).source={src!r} "
                    f"不在 tables[].name/fields[] 中（链路断链——落库字段必须真实存在；无落表写 —）"
                )
        for ci, c in enumerate(p.get("form_controls") or []):
            sa = str(c.get("submit_api") or "").strip()
            if sa and sa != "—" and _norm_anchor(sa) not in api_fields:
                errors.append(
                    f"{where}.form_controls[{ci}]({c.get('field')}).submit_api={sa!r} "
                    f"不在 apis[].anchor/detail_anchor 中（链路断链——控件→接口必须闭环）"
                )
            tf = str(c.get("target_field") or "").strip()
            if tf and tf != "—" and tf not in table_fields:
                errors.append(
                    f"{where}.form_controls[{ci}]({c.get('field')}).target_field={tf!r} "
                    f"不在 tables[].name/fields[] 中（链路断链——落库字段必须真实存在；无落表写 —）"
                )
            # v3.28.1：required 与接口请求字段对齐
            req = c.get("required")
            sa = str(c.get("submit_api") or "").strip()
            fld = str(c.get("field") or "").strip()
            if req is not None and sa and sa != "—":
                anc = _norm_anchor(sa)
                api_fields = api_fields.get(anc, set())
                # 找对应请求字段（field 名或 field 的驼峰形式）
                import re as _re
                camel = _re.sub(r'_([a-z])', lambda m: m.group(1).upper(), fld)
                matched = None
                for af in api_fields:
                    if af == fld or af == camel or af.endswith("." + camel) or af.endswith("." + fld):
                        matched = af
                        break
                if matched:
                    # 在 apis 中找该字段的 required 值
                    for a in data.get("apis", []):
                        for k in ("anchor", "detail_anchor"):
                            if _norm_anchor(a.get(k) or "") == anc:
                                for rf in (a.get("request") or {}).get("fields") or []:
                                    if rf.get("name") == matched:
                                        api_req = rf.get("required")
                                        if api_req is not None and bool(api_req) != bool(req):
                                            errors.append(
                                                f"{where}.form_controls[{ci}]({fld}).required={req} "
                                                f"与接口 §{anc} 请求字段 {matched!r} 的 required={api_req} 不一致"
                                                f"（前后端必填口径必须同源）"
                                            )
                                        break
                                break
        for di, d in enumerate(p.get("dialogs") or []):
            name = (d.get("name") or "").strip()
            api = (d.get("api") or "").strip()
            if api == "—":
                continue
            refs = re.findall(r"§([0-9]+(?:\.[0-9]+)+)", api)
            if not refs:
                errors.append(
                    f"{where}.dialogs[{di}]({name}): api={api!r} 未包含 §x.y.z 接口锚点且非 —"
                    f"（弹窗/抽屉必须挂在接口证据位上；无接口交互显式写 —）"
                )
                continue
            for r in refs:
                if r not in api_anchors:
                    errors.append(
                        f"{where}.dialogs[{di}]({name}): api 锚点 §{r} 不在 apis[].anchor/detail_anchor 中"
                        f"（弹窗接口引用断链——§7.2 弹窗/抽屉表与 §3.2 接口定义必须闭环）"
                    )
    # 测试锚点全文档唯一 + 操作按钮（actions[]）闭环
    seen_anchors = {}
    for pi, p in enumerate(data.get("pages", [])):
        where = f"pages[{pi}]({p.get('name')})"

        def _reg(anchor, kind, label):
            a = str(anchor or "").strip()
            if not a:
                return
            prev = seen_anchors.get(a)
            if prev:
                errors.append(
                    f"测试锚点重复: {a!r} 同时出现在 {prev} 与 {where}.{kind}({label})"
                    f"（test_anchor 全文档必须唯一——实现层 data-testid 一对一定位）"
                )
            else:
                seen_anchors[a] = f"{where}.{kind}({label})"

        for c in p.get("form_controls") or []:
            _reg(c.get("test_anchor"), "form_controls", c.get("field"))
        for d in p.get("dialogs") or []:
            _reg(d.get("test_anchor"), "dialogs", d.get("name"))
        for ai, a in enumerate(p.get("actions") or []):
            _reg(a.get("test_anchor"), "actions", a.get("name"))
            aname = str(a.get("name") or "").strip()
            dlg = str(a.get("dialog") or "").strip()
            if dlg and dlg != "—":
                dlg_names = {
                    str((d.get("name") or "").strip()) for d in (p.get("dialogs") or [])
                }
                if dlg not in dlg_names:
                    errors.append(
                        f"{where}.actions[{ai}]({aname}): dialog={dlg!r} 不在同页 dialogs[].name 中"
                        f"（触发弹窗/抽屉断链——§7.2 操作表与弹窗/抽屉表必须闭环）"
                    )
            ap = str(a.get("api") or "").strip()
            if ap and ap != "—":
                refs = re.findall(r"§([0-9]+(?:\.[0-9]+)+)", ap)
                if not refs:
                    errors.append(
                        f"{where}.actions[{ai}]({aname}): api={ap!r} 未包含 §x.y.z 接口锚点且非 —"
                        f"（操作必须挂在接口证据位上；无接口交互显式写 —）"
                    )
                for r in refs:
                    if r not in api_anchors:
                        errors.append(
                            f"{where}.actions[{ai}]({aname}): api 锚点 §{r} 不在 apis[].anchor/detail_anchor 中"
                            f"（操作接口引用断链——§7.2 操作表与 §3.2 接口定义必须闭环）"
                        )


def _doc_table_blocks(text):
    """v3.27.9(F2)：把小节正文切成独立 Markdown 表格块（连续 | 行），返回
    [[行单元格…]] 列表——同一小节内多张表按块区分，供表头判型。"""
    blocks, cur = [], []
    for ln in (text or "").splitlines():
        s = ln.strip()
        if s.startswith("|"):
            cur.append(s)
        elif cur:
            blocks.append(cur)
            cur = []
    if cur:
        blocks.append(cur)
    out = []
    for b in blocks:
        rows = _section_table_rows("\n".join(b))
        if rows:
            out.append(rows)
    return out


def check_page_specs_doc(data, errors, doc_path):
    """v3.27.9(F2)；v3.28.1 合并 §7.3 + 链路列：pages[] 规格 ↔ §7.2 正文对账（提供即对账）。

    - table_columns 字段必须出现在 §7.2.* 「表格列规格」表（表头含「列标题」）首列；
      api_field/source 提供时须出现在同一行（链路列与 JSON 同源）；
    - form_controls 字段必须出现在 §7.2.* 「表单控件规格」表（表头含「控件」+「校验」）首列；
      submit_api/target_field 提供时须出现在同一行；
    - dialogs.name/component/api 必须落在 §7.2.* 「弹窗/抽屉」表（表头含「组件」）对应行
      （原 §7.3 映射表已并入 §7.2）；清单可见性由 check_page_list_doc 对账。
    测试锚点对账——form_controls/dialogs 的 test_anchor 必须出现在对应表行
    「测试锚点」列；actions[] 必须逐条落在 §7.2 「操作」表（表头含「操作」+「类型」）
    首列，api/dialog/test_anchor 提供时须出现在同一行。
    """
    doc = Path(doc_path)
    if not doc.exists():
        return
    sections, _raw = _doc_sections(doc)
    col_rows, form_rows, dialog_rows, action_rows = {}, {}, [], {}
    for key, text in sections.items():
        if key == "7.2" or key.startswith("7.2."):
            for rows in _doc_table_blocks(text):
                header = " ".join(rows[0])
                body = rows[1:]
                if "列标题" in header:
                    for r in body:
                        if r and r[0]:
                            col_rows.setdefault(r[0], " | ".join(r))
                elif "控件" in header and "校验" in header:
                    for r in body:
                        if r and r[0]:
                            form_rows.setdefault(r[0], " | ".join(r))
                elif "组件" in header and "交互" in header:
                    dialog_rows.extend(body)
                elif "操作" in header and "类型" in header:
                    for r in body:
                        if r and r[0]:
                            action_rows.setdefault(r[0], " | ".join(r))
    for pi, p in enumerate(data.get("pages", [])):
        missing = [
            c.get("field") for c in (p.get("table_columns") or [])
            if c.get("field") and c.get("field") not in col_rows
        ]
        if missing:
            errors.append(
                f"pages[{pi}]({p.get('name')}) 表格列字段未出现在 §7.2 表格列规格表首列: "
                f"{missing[:5]}（JSON 与正文冲突——同字段双正本必须一致）"
            )
        for ci, c in enumerate(p.get("table_columns") or []):
            row_text = col_rows.get(str(c.get("field") or "").strip(), "")
            for key, label in (("api_field", "接口字段"), ("source", "落库字段")):
                v = str(c.get(key) or "").strip()
                if v and v != "—" and row_text and v not in row_text:
                    errors.append(
                        f"pages[{pi}]({p.get('name')}).table_columns[{ci}]({c.get('field')}): "
                        f"{label} {v!r} 未出现在 §7.2 表格列规格表对应行（JSON 与正文冲突——链路列必须同源）"
                    )
        missing = [
            c.get("field") for c in (p.get("form_controls") or [])
            if c.get("field") and c.get("field") not in form_rows
        ]
        if missing:
            errors.append(
                f"pages[{pi}]({p.get('name')}) 表单控件字段未出现在 §7.2 表单控件规格表首列: "
                f"{missing[:5]}（JSON 与正文冲突——同字段双正本必须一致）"
            )
        for ci, c in enumerate(p.get("form_controls") or []):
            row_text = form_rows.get(str(c.get("field") or "").strip(), "")
            for key, label in (("submit_api", "提交接口"), ("target_field", "落库字段"), ("test_anchor", "测试锚点")):
                v = str(c.get(key) or "").strip()
                if v and v != "—" and row_text and v not in row_text:
                    errors.append(
                        f"pages[{pi}]({p.get('name')}).form_controls[{ci}]({c.get('field')}): "
                        f"{label} {v!r} 未出现在 §7.2 表单控件规格表对应行（JSON 与正文冲突——链路列必须同源）"
                    )
        for ai, a in enumerate(p.get("actions") or []):
            aname = str(a.get("name") or "").strip()
            row_text = action_rows.get(aname, "")
            if not row_text:
                errors.append(
                    f"pages[{pi}]({p.get('name')}).actions[{ai}]({aname}): "
                    f"§7.2 操作表首列（操作）未找到该操作——JSON 与正文冲突"
                )
                continue
            for key, label in (("api", "接口锚点"), ("test_anchor", "测试锚点")):
                v = str(a.get(key) or "").strip()
                if v and v != "—" and v not in row_text:
                    errors.append(
                        f"pages[{pi}]({p.get('name')}).actions[{ai}]({aname}): "
                        f"{label} {v!r} 未出现在 §7.2 操作表对应行（JSON 与正文冲突——操作列必须同源）"
                    )
        for di, d in enumerate(p.get("dialogs") or []):
            name = (d.get("name") or "").strip()
            comp = (d.get("component") or "").strip()
            hit = next((row for row in dialog_rows if row and name in row[0]), None)
            if hit is None:
                errors.append(
                    f"pages[{pi}]({p.get('name')}).dialogs[{di}]({name}): §7.2 弹窗/抽屉表"
                    f"首列（交互）未找到该交互——JSON 与正文冲突"
                )
                continue
            row_text = " | ".join(hit)
            if comp and comp != "—" and comp not in row_text:
                errors.append(
                    f"pages[{pi}]({p.get('name')}).dialogs[{di}]({name}): §7.2 弹窗/抽屉表对应行未包含"
                    f"组件路径 {comp!r}（JSON 与正文冲突——组件列必须同源）"
                )
            api = (d.get("api") or "").strip()
            if api and api != "—":
                for ref in re.findall(r"§([0-9]+(?:\.[0-9]+)+)", api):
                    if f"§{ref}" not in row_text:
                        errors.append(
                            f"pages[{pi}]({p.get('name')}).dialogs[{di}]({name}): §7.2 弹窗/抽屉表对应行未包含"
                            f"接口锚点 §{ref}（JSON 与正文冲突——接口列必须同源）"
                        )
            ta = str(d.get("test_anchor") or "").strip()
            if ta and ta not in row_text:
                errors.append(
                    f"pages[{pi}]({p.get('name')}).dialogs[{di}]({name}): §7.2 弹窗/抽屉表对应行未包含"
                    f"测试锚点 {ta!r}（JSON 与正文冲突——测试锚点列必须同源）"
                )


def check_page_list_doc(data, errors, doc_path):
    """v3.27.12：§7.1 页面清单表 ↔ pages[] 对账（pages 非空即要求清单表存在）。

    pages[].route/component/page_type 是 JSON 必填字段，但此前正文清单表可缺可漂移；
    本检查要求 §7.1 存在含「路径/组件」表头的页面清单表，且页面名/路由/组件/权限
    逐一出现在表中（— 占位豁免；纯任务页）。
    v3.28.1：**全部弹窗/抽屉进表**——pages[].dialogs 的每一项 name/component 也必须
    出现在 §7.1 清单表（§7.1 是全部 UI 面的唯一清单）。"""
    pages = data.get("pages") or []
    if not pages:
        return
    doc = Path(doc_path)
    if not doc.exists():
        return
    sections, _raw = _doc_sections(doc)
    text = sections.get("7.1")
    if text is None:
        errors.append(
            "§7.1 页面清单缺失（pages 非空时必须提供 §7.1 页面清单表：页面|路径|组件|类型|权限）"
        )
        return
    header_ok = False
    cells = set()
    for rows in _doc_table_blocks(text):
        header = " ".join(rows[0])
        if "路径" in header and "组件" in header:
            header_ok = True
            for r in rows[1:]:
                cells.update(c.strip() for c in r if c and c.strip())
    if not header_ok:
        errors.append("§7.1 页面清单表缺表头（须含「路径」「组件」列——页面清单唯一正本）")
        return
    for pi, p in enumerate(pages):
        for key, label in (("name", "页面名"), ("route", "路由"), ("component", "组件"), ("permission", "权限")):
            v = str(p.get(key) or "").strip()
            if v and v != "—" and v not in cells:
                errors.append(
                    f"pages[{pi}]({p.get('name')}): {label} {v!r} 未出现在 §7.1 页面清单表"
                    f"（JSON 与正文冲突——页面清单表必须与 pages[] 同源）"
                )
        for di, d in enumerate(p.get("dialogs") or []):
            for key, label in (("name", "交互名"), ("component", "组件")):
                v = str(d.get(key) or "").strip()
                if v and v != "—" and v not in cells:
                    errors.append(
                        f"pages[{pi}]({p.get('name')}).dialogs[{di}]({d.get('name')}): {label} {v!r} "
                        f"未出现在 §7.1 页面清单表（v3.28.1：全部弹窗/抽屉进 §7.1——"
                        f"§7.1 是全部 UI 面的唯一清单）"
                    )


def check_prd_sources(data, errors, criteria_path=None, workspace=""):
    """v3.24.0(A04)：验收行 prd_anchor 的来源文件必须真实存在。

    实证反例：PRD 路径替换为 does-not-exist.md#L99999 仍可通过 P2——锚点只查
    "非空含 #"，从未核验来源。解析基址依次尝试：criteria 目录、workspace、cwd。"""
    bases = []
    if criteria_path:
        bases.append(Path(criteria_path).resolve().parent)
    ws = (workspace or "").strip()
    if ws:
        bases.append(Path(ws).resolve())
    bases.append(Path(".").resolve())
    for i, a in enumerate(data.get("acceptance", [])):
        pa = (a.get("prd_anchor") or "").strip()
        if not pa or "#" not in pa:
            continue  # 形状由 schema 管
        path_part = pa.split("#", 1)[0].strip()
        if not path_part or re.match(r"^[a-z]+://", path_part):
            continue
        if not any((b / path_part).is_file() for b in bases):
            errors.append(
                f"acceptance[{i}]({a.get('id')}).prd_anchor: 来源文件不存在: {path_part}"
                f"（PRD 引用必须指向真实文档——找不到时核对路径或回 P0 修正锚点）"
            )


def check_nested_anchors(data, errors, doc_path):
    """v3.24.0(A04)：嵌套引用闭环——apis[].request/response.anchor 必须在文档中
    真实存在；client.journeys[].page 必须落在 pages[].anchor 且在文档中存在。"""
    if not doc_path:
        return
    doc = Path(doc_path)
    if not doc.exists():
        return
    headings = _doc_detail_headings(doc)
    for i, a in enumerate(data.get("apis", [])):
        where = f"apis[{i}]({a.get('name')})"
        for side in ("request", "response"):
            grp = a.get(side) or {}
            anc = _norm_anchor(grp.get("anchor"))
            if anc and anc not in headings:
                errors.append(
                    f"{where}.{side}.anchor: §锚点 {grp.get('anchor')!r} 在文档中不存在（嵌套引用断链）"
                )
    client = data.get("client") or {}
    page_anchors = {p.get("anchor") for p in data.get("pages", [])}
    for j, jrn in enumerate(client.get("journeys") or []):
        jp = (jrn.get("page") or "").strip()
        if not jp:
            continue
        if page_anchors and jp not in page_anchors:
            errors.append(
                f"client.journeys[{j}].page: {jp!r} 不在 pages[].anchor 中（旅程页面引用断链）"
            )
        anc = _norm_anchor(jp)
        if anc and anc not in headings:
            errors.append(
                f"client.journeys[{j}].page: §锚点 {jp!r} 在文档中不存在（嵌套引用断链）"
            )


def check_business_operations(data, errors):
    """v3.24.0(A01)：业务操作契约对账——冻结需求的每项操作必须有落点。

    (a) acceptance_refs 悬空引用拦截；
    (b) 并集必须覆盖全部验收点（缺恢复/彻底删除等操作即覆盖缺口）；
    (c) 有状态操作必须同时声明 source/target_state；stateless=true 不得再带状态；
    (d) 空集合必须 zero_results 显式声明。"""
    ops = data.get("business_operations", [])
    ids = [a.get("id") for a in data.get("acceptance", [])]
    id_set = set(ids)
    op_ids = [o.get("id") for o in ops]
    dup = sorted({x for x in op_ids if op_ids.count(x) > 1})
    if dup:
        errors.append(f"business_operations[].id 存在重复: {dup}")
    covered = set()
    for i, o in enumerate(ops):
        where = f"business_operations[{i}]({o.get('id')}:{o.get('name')})"
        for r in o.get("acceptance_refs", []):
            if r not in id_set:
                errors.append(f"{where}.acceptance_refs: 验收点 {r!r} 不在 acceptance[] 中（悬空引用）")
            else:
                covered.add(r)
        if o.get("stateless"):
            if o.get("source_state") or o.get("target_state"):
                errors.append(f"{where}: stateless=true 但仍声明 source/target_state（自相矛盾）")
        elif not o.get("source_state") or not o.get("target_state"):
            errors.append(
                f"{where}: 有状态操作必须同时声明 source_state 与 target_state"
                f"（无状态场景用 stateless=true 显式声明，不强制虚构状态机）"
            )
        # v3.27.11：测试场景至少 1 条非空（schema 必填但允许空数组——空场景等于无验证契约）
        ts = [x for x in (o.get("test_scenarios") or []) if str(x).strip()]
        if not ts:
            errors.append(
                f"{where}: test_scenarios 为空（每个业务操作至少 1 个可执行测试场景）"
            )
    missing = [i for i in ids if i not in covered]
    if ops and missing:
        errors.append(
            f"business_operations 覆盖缺口: 验收点 {missing[:5]}"
            f"（共 {len(missing)} 个）未被任何业务操作覆盖——冻结需求的每项操作必须有落点，"
            f"如删除→回收站→恢复→彻底删除须各自成操作"
        )
    if not ops and not _zero_declared(data, "business_operations"):
        errors.append(
            "business_operations 为空但 zero_results 未声明"
            "（业务操作契约是详设完整性分母——设计零操作须显式声明并给理由）"
        )


def _workspace_effective(workspace):
    """工作区反查生效判定（与 configs 消费点反查同口径）：显式非 . 传入，或 cwd
    具备工程标志。防止对 df_pipeline 例行 --workspace . 的非仓库目录误报。"""
    ws = str(workspace or "").strip()
    if ws and ws != ".":
        return ws
    for marker in ("pom.xml", "package.json", "go.mod", "Cargo.toml", "Makefile", "pyproject.toml", "build.gradle"):
        if Path(marker).is_file():
            return ws or "."
    return ""


def check_baseline(data, errors, workspace=""):
    """v3.24.0(A02)：真实代码基线反查——REUSE/MODIFY/DELETE 目标必须存在于仓库。

    实证反例：夹具无 FooController 源码却声明 MODIFY FooController#list 并通过 P2。
    ADD 不要求新文件已存在，但必须声明 target_module（所属模块与同类模式）。
    工作区反查仅在 --workspace 生效（显式传入或 cwd 有工程标志）时执行。"""
    base = data.get("baseline", {})
    entries = base.get("entries", [])
    ws = _workspace_effective(workspace)
    bop_ids = {o.get("id") for o in data.get("business_operations", [])}
    acc_ids = {a.get("id") for a in data.get("acceptance", [])}
    if not entries:
        if not _zero_declared(data, "baseline.entries"):
            errors.append(
                "baseline.entries 为空但 zero_results 未声明"
                "（实现交接的基线是机器契约——绿地项目也须登记 ADD 条目）"
            )
        return
    for i, e in enumerate(entries):
        where = f"baseline.entries[{i}]({e.get('id')})"
        decision = e.get("decision")
        target = (e.get("target") or "").strip()
        path_part = target.split("#", 1)[0].strip()
        if not (e.get("verify") or "").strip():
            errors.append(f"{where}: 缺 verify（每个基线条目必须有验证方式）")
        for rop in e.get("related_operations", []):
            if rop not in bop_ids:
                errors.append(
                    f"{where}.related_operations: 业务操作 {rop!r} 不在 business_operations[] 中（悬空引用）"
                )
        for rac in e.get("related_acceptance", []):
            if rac not in acc_ids:
                errors.append(
                    f"{where}.related_acceptance: 验收点 {rac!r} 不在 acceptance[].id 中（悬空引用）"
                )
        if decision in ("REUSE", "MODIFY", "DELETE"):
            if not (e.get("existing_contract") or "").strip():
                errors.append(
                    f"{where}: {decision} 条目缺 existing_contract（现有契约/符号说明）"
                )
            if ws and path_part and not (Path(ws) / path_part).is_file():
                errors.append(
                    f"{where}: {decision} 目标文件不存在: {path_part}"
                    f"（基线必须来自真实代码——先调查后设计，虚构目标直接拦截）"
                )
        elif decision == "ADD":
            if not (e.get("target_module") or "").strip():
                errors.append(
                    f"{where}: ADD 条目缺 target_module（新增文件不要求已存在，但须声明所属模块与同类模式）"
                )
        # v3.24.0(A02)：证据指纹——64 hex 视为文件 SHA-256，工作区反查生效时与实算比对
        fp = (e.get("fingerprint") or "").strip()
        if fp and re.fullmatch(r"[0-9a-f]{64}", fp) and ws and path_part:
            target_abs = Path(ws) / path_part
            if target_abs.is_file():
                actual_fp = _sha256(target_abs)
                if actual_fp != fp:
                    errors.append(
                        f"{where}.fingerprint: 声明 {fp[:12]}… 与目标文件实算 {actual_fp[:12]}… 不一致"
                        f"（基线在调查后被改写——回 P2 重新调查或更新指纹）"
                    )
    dbe = base.get("db_evidence") or {}
    if dbe.get("source") == "live_schema" and not (dbe.get("note") or "").strip():
        errors.append(
            "baseline.db_evidence.source=live_schema 但缺 note"
            "（运行库 schema 证据须记录来源库与时点；缺运行证据时用 migration_ddl，不得推断已部署）"
        )


def _ref_list(v):
    """v3.24.0(A04)：验收行引用值归一——单对象字符串或多对象数组统一为列表。"""
    if isinstance(v, list):
        return [x for x in v if isinstance(x, str)]
    if isinstance(v, str):
        return [v]
    return []


def check_design(data, errors, criteria_path=None, doc_path=None, workspace="", scope_ids=None, doc_mode=None):
    acceptance = data.get("acceptance", [])
    pages = {p.get("anchor") for p in data.get("pages", [])}
    apis = {a.get("anchor") for a in data.get("apis", [])}
    tables = {t.get("anchor") for t in data.get("tables", [])}
    rules = {r.get("id") for r in data.get("rules", [])}

    # 0. 顶层 anchor 唯一性（v3.20.2 P1-5）——同一 §锚点只允许对应一个对象，
    # 重复会让证据位多义（两张表共用一个 anchor 曾静默通过）
    for _coll, _items in (("pages", data.get("pages", [])), ("tables", data.get("tables", [])), ("apis", data.get("apis", []))):
        _pairs = [(x.get("anchor"), x.get("name")) for x in _items]
        _dups = sorted({(a, n) for a, n in _pairs if a and _pairs.count((a, n)) > 1})
        if _dups:
            errors.append(
                f"{_coll}[] 锚点+名称完全重复: {[(a, n) for a, n in _dups][:3]}"
                f"（同 § 下多表/多页并存合法，但同锚同名即同一对象被登记两次——证据位多义）"
            )

    # 0b. 锚点具体化（v3.26.10 · L-P2-004）：m01-foundation 项目七问题复盘——
    # 追溯矩阵页面/接口/数据列写通用锚点（§7.1/§3.1/§2.2）无法与上文具体条目对上；
    # 表/页/接口必须各自持有独立编号锚点（§2.2.N/§7.1.N/§3.2.N），接口 anchor 必须
    # 等于详细定义锚点（概览列已前置详细定义，不再有"概览锚点"位）。
    for _coll in ("pages", "tables"):
        _seen = {}
        for _x in data.get(_coll, []):
            _a = _x.get("anchor")
            if _a:
                _seen.setdefault(_a, []).append(_x.get("name") or _x.get("id") or "")
        for _a, _names in sorted(_seen.items()):
            if len(_names) > 1:
                errors.append(
                    f"{_coll}[] 锚点 {_a!r} 被 {len(_names)} 个条目共用: {sorted(_names)[:3]}…"
                    f"（L-P2-004：每个页面/表必须有独立编号锚点 §7.1.N/§2.2.N——"
                    f"追溯矩阵与表索引按锚点定位到具体条目，共用锚点即断链）"
                )
    for _i, _a in enumerate(data.get("apis", [])):
        if _a.get("anchor") and _a.get("detail_anchor") and _a["anchor"] != _a["detail_anchor"]:
            errors.append(
                f"apis[{_i}]({_a.get('name')}).anchor={_a['anchor']!r} != detail_anchor={_a['detail_anchor']!r}"
                f"（L-P2-004：接口概览已删除概览锚点列、详细定义前置——anchor 必须直接登记 §3.2.N，"
                f"不得再写概览级 §3.1）"
            )

    # 0c. constraints[]（P0 硬约束引用位）：同一硬约束只登记一次；与冻结集合的对账在 s2 §2b 完成
    _cids = [c.get("id") for c in data.get("constraints", [])]
    _cdup = sorted({x for x in _cids if x and _cids.count(x) > 1})
    if _cdup:
        errors.append(f"constraints[].id 存在重复: {_cdup}（同一硬约束只登记一次）")

    # 1. 验收点 ID 唯一
    ids = [a.get("id") for a in acceptance]
    dups = sorted({i for i in ids if ids.count(i) > 1})
    if dups:
        errors.append(f"acceptance[].id 存在重复: {dups}（每验收点恰好一行追溯）")

    # 2. 与 criteria 文件集合全等（可选：提供时双向对账）
    if criteria_path:
        text = Path(criteria_path).read_text(encoding="utf-8", errors="replace") if Path(criteria_path).exists() else ""
        crit = set(re.findall(r"M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}", text))
        missing, extra = crit - set(ids), set(ids) - crit
        if missing:
            errors.append(f"acceptance 缺失 criteria 冻结验收点 {len(missing)} 个: {sorted(missing)[:5]}…（集合必须全等）")
        if extra:
            errors.append(f"acceptance 含 criteria 之外的额外 ID: {sorted(extra)[:5]}…（不得超出冻结集合）")

    # 3. 锚点引用闭环（定位器必须是当前产物内真实存在的章节）
    # v3.17.2(M2): 已在 zero_results 声明为空的集合豁免引用校验——纯后端 feature
    # （pages/tables/apis 合法为空）的验收行不再必然断链。
    declared_empty = {z.get("path") for z in data.get("zero_results", [])}
    # v3.17.3(B-8): 豁免是集合级——但字段值不得残留旧锚点（声明为空后仍写 §7 即陈旧引用）
    # v3.24.0(A04): page/api/data 支持多对象数组——一条验收行为可关联多个页面/接口/表
    for i, a in enumerate(acceptance):
        where = f"acceptance[{i}]({a.get('id')})"
        for field, coll, items in (("page", "pages", pages), ("api", "apis", apis), ("data", "tables", tables)):
            refs = _ref_list(a.get(field))
            if refs and all(r in items for r in refs):
                continue
            if coll in declared_empty:
                stale = [r for r in refs if r not in ("—", "")]
                if stale:
                    errors.append(
                        f"{where}.{field}: 集合 {coll} 已声明为空，但验收行仍写锚点 {stale!r}"
                        f"（陈旧引用——写 — 占位或从声明中移除空集合）"
                    )
                continue
            errors.append(f"{where}.{field}: §锚点 {a.get(field)!r} 不在 {coll}[].anchor 中（引用断链）")
        if a.get("rule") not in rules:
            errors.append(f"{where}.rule: 规则 {a.get('rule')!r} 不在 rules[].id 中（引用断链）")

    # 4. 孤儿条目（收录了却无人引用——要么漏回填引用，要么显式声明理由）
    # v3.24.0(A04)：多对象引用数组的每个元素都计入引用集合
    def _orphan(items, item_key, acc_key, label):
        referenced = set()
        for a in acceptance:
            referenced.update(_ref_list(a.get(acc_key)))
        for i, it in enumerate(items):
            if it.get(item_key) not in referenced and not it.get("unreferenced_reason"):
                errors.append(
                    f"{label}[{i}]({it.get(item_key)!r}) 未被任何验收点引用且无 unreferenced_reason"
                    f"（孤儿条目：要么在 acceptance 中回填引用，要么显式声明理由）"
                )

    _orphan(data.get("tables", []), "anchor", "data", "tables")
    _orphan(data.get("apis", []), "anchor", "api", "apis")
    _orphan(data.get("pages", []), "anchor", "page", "pages")
    _orphan(data.get("rules", []), "id", "rule", "rules")

    # 5. 客户端范围声明自洽
    client = data.get("client", {})
    scope = client.get("scope")
    if scope == "not-applicable":
        if not client.get("not_applicable_reason"):
            errors.append("client.scope=not-applicable 但缺少 not_applicable_reason（不适用必须显式说明）")
        if client.get("journeys"):
            errors.append("client.scope=not-applicable 但仍声明了 journeys（自相矛盾）")
    else:
        if not client.get("journeys"):
            if not _zero_declared(data, "client.journeys"):
                errors.append("client.journeys 为空但 zero_results 未声明（有前端的 feature 必须给出旅程或声明为空的理由）")
        pg_zero = _zero_declared(data, "pages")
        if not data.get("pages") and not pg_zero:
            errors.append("pages 为空但 zero_results 未声明 pages（须显式声明无前端页面及理由）")

    # 6. 迁移声明自洽（铁律 5：不适用需在冻结设计说明）
    mig = data.get("migrations", {})
    if not mig.get("applicable"):
        if not mig.get("not_applicable_reason"):
            errors.append("migrations.applicable=false 但缺少 not_applicable_reason（铁律 5：不适用须冻结设计说明）")
    else:
        _strat = mig.get("strategy")
        if _strat not in ("A", "B", "C"):
            errors.append(
                "migrations.applicable=true 但缺少冻结 strategy（须 A|B|C：A=仅新建表免迁移收据，"
                "B/C=数据迁移互斥策略——收据刷新与命令行 --migration 以本字段为唯一事实源）"
            )
        dl = mig.get("dialects", [])
        if len(set(dl)) != len(dl):
            errors.append(f"migrations.dialects 存在重复: {dl}")
        if set(dl) != {"h2", "postgresql", "oracle", "kingbase"} and not mig.get("dialect_exception"):
            errors.append(
                f"migrations.dialects={sorted(set(dl))} 非四方言齐全且缺少 dialect_exception"
                f"（铁律 5：偏离四方言必须冻结设计说明）"
            )

    # 6b. 测试隔离策略自洽（v3.28.14，m01-base 教训：跨类登录态污染 → P3 集成测试三轮返工，
    # 隔离必须在 P2 冻结而非 P3 才发现）
    ti = data.get("test_isolation")
    if ti is None:
        errors.append(
            "缺少 test_isolation（测试隔离策略必须在 P2 冻结——"
            "m01-base 教训：隔离留到 P3 发现即三轮返工）"
        )
    elif ti.get("applicable"):
        if not str(ti.get("strategy") or "").strip():
            errors.append("test_isolation.applicable=true 但缺少 strategy（隔离手段必须在 P2 冻结：独立库/事务回滚/@Order/自清理登录态等）")
    else:
        if not str(ti.get("not_applicable_reason") or "").strip():
            errors.append("test_isolation.applicable=false 但缺少 not_applicable_reason（不适用必须显式说明为何无任何共享状态）")

    # 6c. 图表体系登记自洽（v3.30.0 机器闭环：七类结构图登记 + 归位锚格式）
    dg = data.get("diagrams") or {}
    _CHART_TYPES = ("状态机", "机制模型", "决策链", "对象生命周期", "页面导航", "ER")
    _seen_chart = set()
    for i, ch in enumerate(dg.get("structure_charts") or []):
        t = str(ch.get("type") or "")
        sec = str(ch.get("section") or "")
        if t not in _CHART_TYPES:
            errors.append(
                f"diagrams.structure_charts[{i}].type 非法: {t or '空'}"
                f"（须为 {'/'.join(_CHART_TYPES)}——总清单声明是 §6.0 文档行为，不作 type 登记）"
            )
        if t in _seen_chart:
            errors.append(f"diagrams.structure_charts[{i}].type 重复登记: {t}（一类一处，图随内容走）")
        _seen_chart.add(t)
        if not re.match(r"^§?\d+(\.\d+)*$", sec):
            errors.append(
                f"diagrams.structure_charts[{i}].section 归位锚非法: {sec or '空'}"
                f"（须为 §x.y 章节锚，如 §2.3/§4/§7.1）"
            )

    # 7. 零结果声明闭环（双向：空集合必须声明；声明必须指向真实空集合）
    empty_collections = []
    if not data.get("tables"):
        empty_collections.append("tables")
    for i, t in enumerate(data.get("tables", [])):
        if not t.get("fields"):
            empty_collections.append(f"tables[{i}].fields")
    if not data.get("apis"):
        empty_collections.append("apis")
    for i, a in enumerate(data.get("apis", [])):
        if not (a.get("request") or {}).get("fields"):
            empty_collections.append(f"apis[{i}].request.fields")
        if not (a.get("response") or {}).get("fields"):
            empty_collections.append(f"apis[{i}].response.fields")
    if not data.get("pages"):
        empty_collections.append("pages")
    # v3.20.0: 可选集合为零也须登记（零结果也是证据）
    if not data.get("resources"):
        empty_collections.append("resources")
    if not data.get("integrations"):
        empty_collections.append("integrations")
    if not data.get("configs"):
        empty_collections.append("configs")
    if not data.get("operations"):
        empty_collections.append("operations")
    # v3.24.0(A01/A02)：业务操作与代码基线也是必须显式声名的可空集合
    if not data.get("business_operations"):
        empty_collections.append("business_operations")
    if not (data.get("baseline") or {}).get("entries"):
        empty_collections.append("baseline.entries")
    if not client.get("journeys") and scope != "not-applicable":
        empty_collections.append("client.journeys")
    declared_paths = [z.get("path") for z in data.get("zero_results", [])]
    # v3.17.2(L7): 重复声明拦截
    dup_paths = sorted({p for p in declared_paths if declared_paths.count(p) > 1})
    if dup_paths:
        errors.append(f"zero_results.path 存在重复声明: {dup_paths}")
    for path in empty_collections:
        if path not in declared_paths:
            errors.append(f"{path} 为空但 zero_results 未声明（静默省略即违规——零结果也是证据）")
    # v3.17.2(M1): 白名单仅保留 not-applicable 场景下的 client.journeys（此时 journeys
    # 恒空属声明语义而非空集合）——非空集合的伪造零结果声明一律拦截。
    valid_targets = set(empty_collections)
    if scope == "not-applicable":
        valid_targets.add("client.journeys")
    for z in data.get("zero_results", []):
        p = z.get("path")
        if p not in valid_targets:
            errors.append(f"zero_results.path={p!r} 指向的集合非空或不存在（过时/伪造的空声明——闭环失配）")

    # 7b. 补偿链闭环 + 集成/配置规格（v3.20.0）
    check_compensation_chain(data, errors)
    check_integrations_configs(data, errors, workspace=workspace)

    # 7c. 业务操作契约对账（v3.24.0 A01）
    check_business_operations(data, errors)

    # 7d. 真实代码基线反查（v3.24.0 A02）
    check_baseline(data, errors, workspace=workspace)

    # 8. DDR ↔ 字段一一对应
    check_ddr_closure(data, errors)

    # 9. 接口概览 ↔ 详细定义闭环（含文档双向对账）
    check_api_detail_closure(data, errors, doc_path=doc_path)

    # 9a. 页面规格闭环（v3.27.9 F2）：弹窗接口锚点必须闭环到 apis[]
    check_page_specs(data, errors)

    # 9b. 全锚点文档对账（v3.19.0 P1-4）+ v3.24.0(A05) 设计包范围过滤：
    # 总分模式一份 feature 级 JSON 对应多份分/总文档——提供 --scope-ids（该文档的
    # 验收子集，来自设计包清单）时，文档对账只针对本子集引用到的对象；
    # 未提供（单文档承载全部）则全量对账。
    if doc_path:
        doc_view = data
        if scope_ids:
            scope_set = set(scope_ids)

            def _acc_refs(field):
                out = set()
                for a in acceptance:
                    if a.get("id") in scope_set:
                        out.update(_ref_list(a.get(field)))
                return out

            doc_view = dict(data)
            doc_view["acceptance"] = [a for a in acceptance if a.get("id") in scope_set]
            doc_view["pages"] = [p for p in data.get("pages", []) if p.get("anchor") in _acc_refs("page")]
            doc_view["tables"] = [t for t in data.get("tables", []) if t.get("anchor") in _acc_refs("data")]
            doc_view["apis"] = [x for x in data.get("apis", []) if x.get("anchor") in _acc_refs("api")]
            doc_view["rules"] = [r for r in data.get("rules", []) if r.get("id") in _acc_refs("rule")]
            doc_view["business_operations"] = [
                o for o in data.get("business_operations", []) if scope_set & set(o.get("acceptance_refs", []))
            ]
            # 跨切面集合（资源/操作/集成/配置）不按子集强绑文档——只登记零结果，不参与本文档锚点对账
            doc_view["resources"] = []
            doc_view["operations"] = []
            doc_view["integrations"] = []
            doc_view["configs"] = []
        if doc_mode == "total":
            # v3.27.10(H1)：总文档只做全局口径校验——页面/表/接口/规则/业务操作/旅途等
            # 模块级对象的锚点与正文明细由分文档承担（总文档模板不含这些章节；此前
            # 总文档校验会把模块级锚点当缺失拦截，导致 total+前端项目无法通过）。
            doc_view = dict(doc_view)
            for _k in ("pages", "tables", "apis", "rules", "business_operations",
                       "resources", "operations", "integrations", "configs"):
                doc_view[_k] = []
            _client = dict(doc_view.get("client") or {})
            _client.pop("journeys", None)
            doc_view["client"] = _client
        check_doc_anchors(doc_view, errors, doc_path)
        # v3.24.0(A03/A04)：嵌套锚点闭环 + JSON↔正文事实对账（字段/类型/约束冲突、空壳小节、WHEN 逐字契约）
        check_nested_anchors(doc_view, errors, doc_path)
        check_doc_content_agreement(doc_view, errors, doc_path)
        # v3.27.9(F2)：页面规格（表格列/表单控件/弹窗映射）与 §7.2 正文对账
        check_page_specs_doc(doc_view, errors, doc_path)
        # v3.27.12：§7.1 页面清单表 ↔ pages[] 对账
        check_page_list_doc(doc_view, errors, doc_path)
        # v3.27.1(L-P2-004 续)：三处模板引导升级为硬校验
        check_design_doc_specificity(doc_view, errors, doc_path)

    # 9c. PRD 来源存在性（v3.24.0 A04）
    check_prd_sources(data, errors, criteria_path=criteria_path, workspace=workspace)

    # 10. 占位话术
    check_placeholders(data, errors)


# ---------- verification 跨字段检查 ----------


_SEMANTIC_ANCHORS = {
    "data-model", "api-contracts", "business-rules", "business-operations",
    "acceptance-traceability", "implementation-handoff", "design-decisions",
    "component-reuse", "common-extraction", "standards-compliance",
}


def check_execution_plan(data, errors):
    """v3.27.11：执行契约切片完整性——task_ids 必须闭环到 tasks[]，components 不得空串。

    v3.28.1：design_refs 锚点闭环——格式 `anchor: <语义锚点>[ §x.y|R{n}]`，
    锚点名必须在语义锚点集合内（悬空锚点 = 设计→任务追溯断链）。此前为零校验字段。"""
    task_ids = {t.get("task_id") for t in data.get("tasks", [])}
    for i, sl in enumerate(data.get("slices", []) or []):
        where = f"slices[{i}]({sl.get('slice_id')})"
        for j, tid in enumerate(sl.get("task_ids") or []):
            if tid not in task_ids:
                errors.append(
                    f"{where}.task_ids[{j}]: 任务 {tid!r} 不在 tasks[].task_id 中（悬空引用）"
                )
        for j, c in enumerate(sl.get("components") or []):
            if not str(c).strip():
                errors.append(f"{where}.components[{j}]: 组件名不得为空")
    ref_re = re.compile(r"^anchor:\s*([a-z][a-z0-9-]*)(?:\s+\S+)?$")
    for i, t in enumerate(data.get("tasks", [])):
        where = f"tasks[{i}]({t.get('task_id')})"
        for j, ref in enumerate(t.get("design_refs") or []):
            m = ref_re.match(str(ref).strip())
            if not m:
                errors.append(
                    f"{where}.design_refs[{j}]: {ref!r} 格式非法"
                    f"（须为 `anchor: <语义锚点>[ §x.y|R{{n}}]`，如 `anchor: api-contracts §3.2.1`）"
                )
            elif m.group(1) not in _SEMANTIC_ANCHORS:
                errors.append(
                    f"{where}.design_refs[{j}]: 锚点 {m.group(1)!r} 不在语义锚点集合"
                    f"（{', '.join(sorted(_SEMANTIC_ANCHORS))}）——设计→任务追溯断链"
                )


def check_verification(data, errors, baseline_path=None, exec_record_path=None, workspace=".", frontend_scope=None):
    results = data.get("acceptance_results", [])
    ids = [r.get("id") for r in results]

    # 1. ID 唯一
    dups = sorted({i for i in ids if ids.count(i) > 1})
    if dups:
        errors.append(f"acceptance_results[].id 存在重复: {dups}（每冻结验收点恰好一行终态）")

    # 2. FAIL=0（终验放行硬条件）
    failed = [r.get("id") for r in results if r.get("status") != "PASS"]
    if failed:
        errors.append(
            f"acceptance_results 存在非 PASS 终态 {len(failed)} 个: {failed[:5]}…"
            f"（部署前必须 FAIL=0；首轮准确率仅是指标，终验放行要求全 PASS）"
        )

    # 3. 与 P4 冻结 baseline 集合全等
    if baseline_path:
        bp = Path(baseline_path)
        if not bp.exists():
            errors.append(f"baseline 文件不存在: {baseline_path}（P4 freeze 是终验前置）")
        else:
            lines = bp.read_text(encoding="utf-8", errors="replace").splitlines()
            base_ids = [ln.split("\t")[0] for ln in lines[1:] if ln.strip()]
            base_dups = sorted({i for i in base_ids if base_ids.count(i) > 1})
            if base_dups:
                errors.append(f"baseline 存在重复 ID: {base_dups}")
            missing, extra = set(base_ids) - set(ids), set(ids) - set(base_ids)
            if missing:
                errors.append(f"终验缺失冻结验收点 {len(missing)} 个: {sorted(missing)[:5]}…（冻结集合 ≠ 终验集合）")
            if extra:
                errors.append(f"终验含未冻结的额外 ID: {sorted(extra)[:5]}…（终验集合不得超出冻结集合）")

    # 4. 五类证据绑定
    evidence = data.get("evidence", {})
    cna = data.get("client_not_applicable", {})
    kinds = ["unit", "integration", "load", "staging"]
    if cna.get("declared"):
        if cna.get("frontend_scope") != "not-applicable":
            errors.append(
                f"client_not_applicable.declared=true 但 frontend_scope={cna.get('frontend_scope')!r}"
                f"（只有 not-applicable 允许免客户端证据）"
            )
        if not cna.get("reason"):
            errors.append("client_not_applicable.declared=true 但缺少 reason（不适用必须显式说明）")
        if evidence.get("client"):
            errors.append("client_not_applicable.declared=true 但 evidence.client 仍存在（自相矛盾）")
    else:
        if not evidence.get("client"):
            errors.append("evidence.client 缺失且 client_not_applicable 未声明（客户端证据不可静默省略）")
        if cna.get("frontend_scope") == "not-applicable":
            errors.append("frontend_scope=not-applicable 但 client_not_applicable.declared=false（声明自洽）")

    # v3.20.2(P0-1): 平台精确匹配的强制点在 s6（--frontend-scope 传入冻结值后
    # P6_SCOPE_MISMATCH/P6_SCOPE_UNDECLARED 硬失败）。此处仅做**已声明时**的
    # 不等比对——夹具/无冻结调用（frontend_scope 为空）不触发，避免误伤。
    _declared_scope = cna.get("frontend_scope") or (data.get("client") or {}).get("scope")
    if frontend_scope and _declared_scope and _declared_scope != frontend_scope:
        errors.append(
            f"frontend_scope 声明 {_declared_scope!r} ≠ 冻结值 {frontend_scope!r}"
            f"（P6_SCOPE_MISMATCH——平台不可偷换）"
        )

    report_paths = []
    for kind in kinds + ["client"]:
        ev = evidence.get(kind)
        if not ev:
            continue
        where = f"evidence.{kind}"
        cmd = ev.get("cmd", "")
        bad = _cmd_is_placeholder(cmd)
        if bad:
            errors.append(f"{where}.cmd: {bad}: {cmd}——终验不接受手写 EXIT=0 的间接证据")
        if ev.get("exit_code") != 0:
            errors.append(f"{where}.exit_code={ev.get('exit_code')} 非 0（退出码非零不得进入终验报告）")
        rp = ev.get("report_path", "")
        # v3.17.2(L3): 空串路径显式报错（Path(workspace)/"" 即目录本身，曾把目录当报告）
        if not rp:
            errors.append(f"{where}.report_path 为空（报告文件路径必填）")
            continue
        resolved = Path(workspace) / rp if not os.path.isabs(rp) else Path(rp)
        if not resolved.exists():
            errors.append(f"{where}.report_path 不存在: {rp}（报告必须由本轮命令真实生成）")
        elif resolved.is_dir():
            errors.append(f"{where}.report_path 是目录而非文件: {rp}")
        else:
            report_paths.append((str(resolved.resolve()), where))
            declared_sha = ev.get("report_sha256")
            if declared_sha:
                actual = _safe_sha256(resolved)
                if actual is None:
                    errors.append(f"{where}.report_sha256 无法计算（文件不可读）: {rp}")
                elif actual != declared_sha:
                    errors.append(f"{where}.report_sha256 不匹配: 声明 {declared_sha[:12]}…，实算 {actual[:12]}…（{rp}）")
        lp = ev.get("log_path")
        if lp:
            lres = Path(workspace) / lp if not os.path.isabs(lp) else Path(lp)
            if not lres.exists():
                errors.append(f"{where}.log_path 不存在: {lp}")

    # 5. 报告互异（五类共用同一份文件不构成五类证据）
    seen = {}
    for p, where in report_paths:
        seen.setdefault(p, []).append(where)
    for p, wheres in seen.items():
        if len(wheres) > 1:
            errors.append(f"多类测试共用同一报告文件 {p}: {wheres}（五类证据须各自独立）")

    # 5b. 报告实质内容（口径移植自 s6 §2：空文件/占位词报告不构成证据——v3.19.0 P0-2）
    for p, where in report_paths:
        try:
            raw = Path(p).read_bytes()
        except OSError as e:
            errors.append(f"{where}: 报告不可读: {p}（{e}）")
            continue
        if len(raw) < 32:
            errors.append(f"{where}: 报告疑似占位（{len(raw)} 字节 < 32）: {p}——真实测试报告须含实质内容")
            continue
        first = (raw.decode("utf-8", errors="replace").strip().splitlines() or [""])[0].strip().lower()
        if first in ("ok", "pass", "success", "done", ""):
            errors.append(f"{where}: 报告首行为占位词（{first or '空'}）: {p}")

    # 5c. verification 零结果声明语义（v3.19.0 P1-6）：此前该字段无任何校验，
    # 可伪造 {"path":"evidence.unit","reason":"伪造空结果"} 通过。
    known_kinds = ("unit", "integration", "client", "load", "staging")
    vr_paths = [z.get("path") for z in data.get("zero_results", [])]
    vr_dups = sorted({x for x in vr_paths if vr_paths.count(x) > 1})
    if vr_dups:
        errors.append(f"zero_results.path 存在重复声明: {vr_dups}")
    for z in data.get("zero_results", []):
        path = z.get("path", "")
        if not re.fullmatch(r"evidence\.(unit|integration|client|load|staging)|acceptance_results", path):
            errors.append(
                f"zero_results.path={path!r} 不在合法词汇表内"
                f"（evidence.unit/integration/client/load/staging 或 acceptance_results）"
            )
            continue
        if path.startswith("evidence."):
            kind = path.split(".", 1)[1]
            if evidence.get(kind):
                errors.append(
                    f"zero_results 声明 {path} 为空，但 evidence.{kind} 仍存在（伪造空声明——二者只能择一）"
                )
        elif path == "acceptance_results" and results:
            errors.append("zero_results 声明 acceptance_results 为空，但验收结果非空（伪造空声明）")

    # 5d. 冻结前端范围对账（v3.19.0 P0-1）：声明与 CLIENT_EXEMPT 都不可覆盖 P0 冻结值
    if frontend_scope and frontend_scope != "not-applicable":
        if cna.get("declared"):
            errors.append(
                f"冻结前端范围={frontend_scope}，但 client_not_applicable.declared=true"
                f"（冻结值以 P0 init 为准，声明不可覆盖；如范围确已变化须回到 P0 重冻结）"
            )
        if exec_record_path:
            er = Path(exec_record_path)
            if er.exists() and re.search(
                r"^CLIENT_EXEMPT=(1|true|yes)\s*$", er.read_text(encoding="utf-8", errors="replace"), re.M
            ):
                errors.append(
                    f"冻结前端范围={frontend_scope}，但执行记录声明 CLIENT_EXEMPT——"
                    f"只有 not-applicable 可免客户端证据"
                )

    # 6. 与 Gate 实际执行记录对账（声明退出码与命令，均须等于 Gate 真实执行值）
    if exec_record_path:
        er = Path(exec_record_path)
        if not er.exists():
            errors.append(f"exec-record 不存在: {exec_record_path}")
        else:
            record = {}
            for ln in er.read_text(encoding="utf-8", errors="replace").splitlines():
                m = re.match(r"^([A-Z_]+)=(.*)$", ln)
                if m:
                    record[m.group(1)] = m.group(2)
            # v3.17.2: CLIENT_EXEMPT=1 时——JSON 必须同步声明免客户端，且不得携带 client 证据
            # v3.17.3(B-1/B-3): 取值归一 + 双向核对——记录无 CLIENT_EXEMPT 且实际执行了 CLIENT，
            # 而 JSON 却声明免客户端，同样拦截（两层声明必须一致）。
            rec_exempt = record.get("CLIENT_EXEMPT", "").strip().lower() in ("1", "true", "yes")
            rec_client_ran = "CLIENT_ACTUAL_EXIT" in record
            if rec_exempt and (not cna.get("declared") or evidence.get("client")):
                errors.append(
                    "Gate 执行记录声明 CLIENT_EXEMPT=1，但 verification.json 未同步声明免客户端"
                    "或仍携带 evidence.client（两层免客户端声明必须一致）"
                )
            if not rec_exempt and rec_client_ran and cna.get("declared"):
                errors.append(
                    "verification.json 声明 client_not_applicable，但 Gate 执行记录包含 CLIENT 实际执行"
                    "且无 CLIENT_EXEMPT 标记（两层免客户端声明必须一致）"
                )
            for kind in kinds + ["client"]:
                ev = evidence.get(kind)
                if not ev:
                    continue
                actual = record.get(f"{kind.upper()}_ACTUAL_EXIT")
                if actual is None:
                    errors.append(
                        f"evidence.{kind}: Gate 执行记录缺少 {kind.upper()}_ACTUAL_EXIT"
                        f"（先跑 s6_final_verification_gate.sh 生成执行记录，再对账）"
                    )
                elif str(ev.get("exit_code")) != actual:
                    errors.append(
                        f"evidence.{kind}: 声明 exit_code={ev.get('exit_code')} 与 Gate 实际执行 exit={actual} 不一致"
                        f"（不得信任手写退出码）"
                    )
                # v3.17.2(H1): 命令单源对账——JSON 声明的命令必须与 Gate 实际执行的命令逐字一致
                gate_cmd = record.get(f"{kind.upper()}_CMD")
                if gate_cmd is None:
                    errors.append(
                        f"evidence.{kind}: Gate 执行记录缺少 {kind.upper()}_CMD"
                        f"（终验报告命令列不接受无执行记录背书的声明）"
                    )
                elif ev.get("cmd") != gate_cmd:
                    errors.append(
                        f"evidence.{kind}: 声明 cmd 与 Gate 实际执行命令不一致"
                        f"（声明: {ev.get('cmd')!r} / 实际: {gate_cmd!r}）"
                    )

    # 7. 占位话术
    check_placeholders(data, errors)


# ---------- v3.25.0 全阶段产物：schema 注解驱动的通用检查引擎 ----------
#
# schema 顶层注解（x-* 扩展字段）声明跨字段规则，本引擎统一执行，避免每个
# 产物各写一套重复逻辑：
#   "x-unique":     ["cases[].id", ...]              数组字段值全数组唯一
#   "x-refs":       [{"from": "cases[].acceptance_refs", "to": "acceptance.id",
#                     "label": "用例→验收点"}, ...]     引用闭环（from 值可为 string|array）
#   "x-zeroable":   ["defects", "evidence.client"]    可空集合：空必须 zero_results 声明，
#                                                     声明必须真为空（零结果也是证据）
#   "x-min-count":  [{"path": "aw", "min": 2, "why": "对抗走查 ≥2 条"}]
#
# design/verification 不走本引擎（已有更严的专项检查）。


def _split_array_path(p):
    """'cases[].acceptance_refs' → ('cases', 'acceptance_refs')；非数组路径返回 None。"""
    if "[]" not in p:
        return None
    arr, _, rest = p.partition("[]")
    return arr.strip(), rest.strip(".")


def _get_path(data, dotted):
    cur = data
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def check_generic(data, errors, schema):
    for spec in schema.get("x-unique", []):
        parts = _split_array_path(spec)
        if not parts:
            continue
        arr_name, field = parts
        arr = data.get(arr_name) or []
        vals = [it.get(field) for it in arr if isinstance(it, dict)]
        dups = sorted({v for v in vals if vals.count(v) > 1 and v is not None})
        if dups:
            errors.append(f"{arr_name}[].{field} 存在重复: {dups[:5]}（每条目唯一标识不得重复）")

    for spec in schema.get("x-refs", []):
        fparts = _split_array_path(spec.get("from", ""))
        tparts = _split_array_path(spec.get("to", ""))
        if not fparts or not tparts:
            continue
        farr, ffield = fparts
        tarr, tfield = tparts
        label = spec.get("label", f"{farr}[].{ffield} → {tarr}[].{tfield}")
        targets = {it.get(tfield) for it in (data.get(tarr) or []) if isinstance(it, dict)}
        for i, it in enumerate(data.get(farr) or []):
            for ref in _ref_list(it.get(ffield)):
                if not ref or ref == "—":
                    continue  # 空引用=显式「无关联」（如边界枚举已定义行为 df_ref 留空）
                if ref not in targets:
                    errors.append(
                        f"{farr}[{i}].{ffield}: 引用 {ref!r} 不在 {tarr}[].{tfield} 中"
                        f"（{label} 悬空引用）"
                    )

    zeroable = set(schema.get("x-zeroable", []))
    declared_paths = [z.get("path") for z in data.get("zero_results", [])]
    dup_paths = sorted({p for p in declared_paths if declared_paths.count(p) > 1})
    if dup_paths:
        errors.append(f"zero_results.path 存在重复声明: {dup_paths}")
    for path in sorted(zeroable):
        val = _get_path(data, path)
        if not val and path not in declared_paths:
            errors.append(
                f"{path} 为空但 zero_results 未声明"
                f"（静默省略即违规——零结果也是证据，须声明 path + reason）"
            )
    for z in data.get("zero_results", []):
        p = z.get("path")
        if p not in zeroable:
            errors.append(
                f"zero_results.path={p!r} 不在本产物的可空集合词汇表内（{sorted(zeroable)}）"
                f"（过时/伪造的空声明）"
            )
        elif _get_path(data, p):
            errors.append(f"zero_results 声明 {p} 为空，但该集合非空（伪造空声明——二者只能择一）")

    for spec in schema.get("x-min-count", []):
        val = _get_path(data, spec.get("path", "")) or []
        need = int(spec.get("min", 0))
        if len(val) < need:
            errors.append(
                f"{spec.get('path')} 共 {len(val)} 条，少于下限 {need}"
                f"（{spec.get('why', '数量下限未达标')}）"
            )


# ---------- v3.25.0 各产物专项检查 ----------


def check_clarification(data, errors):
    """P0 需求澄清：P0 级模糊点必须全部澄清（带结论与验收点关联）才能进详设。"""
    for i, a in enumerate(data.get("ambiguities", [])):
        where = f"ambiguities[{i}]({a.get('id')})"
        if a.get("priority") == "P0":
            if a.get("status") != "resolved":
                errors.append(
                    f"{where}: P0 模糊点未澄清（status={a.get('status')!r}）"
                    f"——阻塞开发的模糊点必须清零后才能进入详细设计"
                )
            if not (a.get("conclusion") or "").strip():
                errors.append(f"{where}: P0 模糊点缺澄清结论（结论是唯一的澄清产出）")
            if not _ref_list(a.get("acceptance_refs")):
                errors.append(f"{where}: P0 模糊点未关联验收点（澄清必须落到可验证行为上）")
        elif a.get("status") == "resolved" and not (a.get("conclusion") or "").strip():
            errors.append(f"{where}: 已声明 resolved 但结论为空（自相矛盾）")
    if data.get("exclusions") and not data.get("exclusions_covered"):
        errors.append(
            "exclusions 非空但 exclusions_covered=false"
            "（排除条款是一等需求——必须落为排除性验收点后再声明覆盖，或确无排除条款时清空 exclusions）"
        )
    if data.get("permission_scope") == "declared" and not data.get("permissions"):
        errors.append("permission_scope=declared 但 permissions 为空（权限码清单不得为空）")
    summaries = data.get("conclusion", {})
    for sec in ("boundaries", "data_rules", "business_rules", "exceptions"):
        if not (summaries.get(sec) or "").strip():
            errors.append(
                f"conclusion.{sec} 为空（澄清结论汇总四节必须逐节填写；确无内容写「无」并说明）"
            )


def check_acceptance(data, errors, workspace=""):
    """P0 验收点清单：全部 FROZEN + PRD 来源真实存在（冻结后才能进 P2）。"""
    pts = data.get("points", [])
    draft = [p.get("id") for p in pts if p.get("status") != "FROZEN"]
    if draft:
        errors.append(
            f"points 存在非 FROZEN 验收点 {len(draft)} 个: {draft[:5]}…"
            f"（验收点清单必须在 P2 详设前冻结——先评审后冻结，或回到草稿态不要走管线）"
        )
    check_prd_sources(
        {"acceptance": [{"id": p.get("id"), "prd_anchor": p.get("prd_anchor")} for p in pts]},
        errors, workspace=workspace,
    )


def check_constraints(data, errors):
    """P0 技术约束契约：FROZEN + 用户确认；空约束必须 constraint_set=NONE。"""
    items = data.get("constraints", [])
    if not items:
        if not data.get("no_constraints") or not data.get("confirmed"):
            errors.append(
                "constraints 为空时必须显式声明 no_constraints=true 且 confirmed=true"
                "（constraint_set=NONE 也是一个冻结决定，不得省略）"
            )
        return
    if not data.get("confirmed"):
        errors.append(
            "constraints.confirmed=false（硬约束必须经用户明确批准后才能冻结；"
            "confirmed=false 会被所有下游 Gate 阻断）"
        )
    for i, c in enumerate(items):
        where = f"constraints[{i}]({c.get('constraint_id')})"
        if c.get("status") != "FROZEN":
            errors.append(f"{where}: status={c.get('status')!r} 非 FROZEN（DRAFT 会被所有 Gate 阻断）")
        if not c.get("confirmed"):
            errors.append(f"{where}: 该约束未经用户确认（confirmed 必须逐条为 true）")
        if c.get("type") == "MUST_USE" and not (c.get("required_product") or "").strip():
            errors.append(f"{where}: MUST_USE 必须声明 required_product（必须采用的产品）")
        if not (c.get("source_anchor") or "").strip():
            errors.append(f"{where}: 缺 source_anchor（每条约束必须能追溯到 PRD/用户原话）")


def check_review(data, errors, kind):
    """P0b PRD 评审 / P2a 详设评审 共用深度契约检查。

    差异由参数驱动：角色集合、AW 下限、探针清单、DF 处置要求。
    口径与 artifact_gate.sh P0b / p2a_design_review_gate.sh 一致。"""
    is_design = kind == "design-review"
    roles = (["架构师", "后端专家", "前端专家", "测试开发", "DBA"] if is_design
             else ["业务", "后端", "前端", "测试", "安全"])
    aw_min = 3 if is_design else 2
    df_items = data.get("df", [])
    df_ids = {d.get("id") for d in df_items}

    # 1. DF 五字段（触发场景/影响链/完善建议/验证方式 + §位置）由 schema minLength 保证，
    #    此处查结构性规则：归属角色合法、OPEN 的 P0/P1（详设评审）阻断。
    for i, d in enumerate(df_items):
        where = f"df[{i}]({d.get('id')})"
        if d.get("role") not in roles:
            errors.append(f"{where}.role={d.get('role')!r} 不在评审角色集合 {roles} 中")
        if is_design and d.get("severity") in ("P0", "P1") and d.get("status") != "CLOSED":
            errors.append(
                f"{where}: P0/P1 级 DF 处于 OPEN（详设评审通过前必须全部 CLOSED——"
                f"MINOR 接受须有理由、边界与批准记录，不得靠改严重性绕过）"
            )

    # 2. 每角色必须有 DF 或 ZERO-DF 核查证据
    df_roles = {d.get("role") for d in df_items}
    zero_roles = {z.get("role") for z in data.get("zero_df_roles", [])}
    for r in roles:
        if r not in df_roles and r not in zero_roles:
            errors.append(
                f"角色 {r} 既无 DF 也无 ZERO-DF 核查证据"
                f"（按实际发现允许零发现，但零发现必须附核查范围/证据锚点/验证方式）"
            )
    for i, z in enumerate(data.get("zero_df_roles", [])):
        where = f"zero_df_roles[{i}]({z.get('role')})"
        if z.get("role") not in roles:
            errors.append(f"{where} 不在评审角色集合中")
        for f in ("scope", "evidence_anchor", "verify"):
            if not (z.get(f) or "").strip():
                errors.append(f"{where}: ZERO-DF 块缺 {f}（空壳核查记录不构成零发现证据）")

    # 3. AW 对抗走查：数量下限由 x-min-count 声明；每条结果必须收尾（发现 DF-xx 或 §锚点）
    for i, a in enumerate(data.get("aw", [])):
        where = f"aw[{i}]({a.get('id')})"
        refs_df = _ref_list(a.get("df_refs"))
        has_anchor = bool((a.get("evidence_anchor") or "").strip())
        if refs_df and all(r in df_ids for r in refs_df):
            continue
        if refs_df and not all(r in df_ids for r in refs_df):
            errors.append(f"{where}.df_refs 引用了不存在的 DF 编号（走查结果必须指向本报告真实 DF）")
            continue
        if not has_anchor and not refs_df:
            errors.append(
                f"{where}: 走查结果必须以「发现 DF-xx」或「证据 §锚点」收尾（无收尾的走查不构成对抗证据）"
            )

    # 4. 探针执行记录：全部已执行（CODE-BASELINE 仅详设评审且可用 not_applicable+理由豁免）
    for i, p in enumerate(data.get("probes", [])):
        where = f"probes[{i}]({p.get('id')})"
        if p.get("executed"):
            if not (p.get("output") or "").strip():
                errors.append(f"{where}: 已执行但缺产出位置/结论（留痕 = 产出可查）")
            continue
        if is_design and p.get("id") == "CODE-BASELINE" and (p.get("not_applicable_reason") or "").strip():
            continue
        errors.append(f"{where}: 探针未执行（未执行探针不得下评审结论）")

    # 5. 歧义术语：逐条决议；整表为空必须显式声明无歧义 + 核查证据
    #    （歧义术语决议表是 P0b PRD 评审的必做项；P2a 详设评审无此节，不检查）
    if not is_design:
        terms = data.get("ambiguity_terms", [])
        if not terms:
            if not (data.get("no_ambiguity_evidence") or "").strip():
                errors.append(
                    "ambiguity_terms 为空但 no_ambiguity_evidence 未声明"
                    "（确无歧义须写「无歧义术语」核查证据；PRD 评审不允许静默跳过）"
                )
        else:
            for i, t in enumerate(terms):
                where = f"ambiguity_terms[{i}]({t.get('id')})"
                if not t.get("resolved"):
                    errors.append(f"{where}: 术语未决议（歧义术语必须逐条形成决议口径）")
                if not (t.get("resolution") or "").strip():
                    errors.append(f"{where}: 缺决议口径")

    # 6. 边界条件枚举：P2 探针产出必须留痕
    if not data.get("boundary_enums"):
        errors.append(
            "boundary_enums 为空（边界与极端值枚举是必做探针——未定义行为应登记为 DF，"
            "确无边界可枚举时在 zero_results 声明 boundary_enums 并给理由）"
        )

    if is_design:
        # 7. 评审委员会独立性：5 角色收据、session 与报告头一致、reviewer 唯一
        run_id = (data.get("run_id") or "").strip()
        if not run_id:
            errors.append("run_id 缺失（REVIEW_RUN_ID 是独立评审可追溯的唯一凭据）")
        receipts = data.get("receipts", [])
        got_roles = [r.get("role") for r in receipts]
        for r in roles:
            if r not in got_roles:
                errors.append(f"receipts 缺角色 {r} 的独立性收据（5 角色各一条）")
        rids = [r.get("reviewer_id") for r in receipts]
        dups = sorted({x for x in rids if x and rids.count(x) > 1})
        if dups:
            errors.append(f"receipts[].reviewer_id 存在重复: {dups}（每角色唯一评委）")
        for i, r in enumerate(receipts):
            if run_id and r.get("session_id") and r.get("session_id") != run_id:
                errors.append(
                    f"receipts[{i}]({r.get('role')}).session_id 与报告头 run_id 不一致"
                    f"（报告一套、收据一套 = 独立性造假）"
                )
        # 8. 严重性修订纪律：改轻必须给理由 + 确认评委
        for i, rev in enumerate(data.get("severity_revisions", [])):
            where = f"severity_revisions[{i}]({rev.get('df_id')})"
            if rev.get("df_id") not in df_ids:
                errors.append(f"{where}: 引用的 DF 编号不存在（悬空修订记录）")
            if rev.get("from") != rev.get("to"):
                if not (rev.get("reason") or "").strip() or not (rev.get("confirmor") or "").strip():
                    errors.append(
                        f"{where}: 严重性 {rev.get('from')}→{rev.get('to')} 但缺修订理由或确认评委"
                        f"（无理由改轻视为绕过关闭义务）"
                    )


def check_design_doc_specificity(data, errors, doc_path):
    """v3.27.1(L-P2-004 续)：三处模板引导升级为硬校验——
    ① §7.2 页组小节数 ≥ 页面数（关键页面交互必须覆盖 §7.1 全部页面，并逐组列出调用接口）；
    ② 规则锚点禁止单一化（全部规则堆在同一 § 锚点即失去导航价值）；
    ③ §3.2 每个详细定义小节标题下首行含 '> 说明：方法 路径｜权限：'（标题只写编号+名称）。"""
    p = Path(doc_path)
    if not p.is_file():
        return
    lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
    heads = set()
    infence = False
    for ln in lines:
        st = ln.strip()
        if st.startswith("```") or st.startswith("~~~"):
            infence = not infence
            continue
        if infence:
            continue
        m = _API_DETAIL_HEADING_RE.match(st)
        if m:
            heads.add(m.group(1))
    pages = data.get("pages", [])
    if pages:
        n_groups = sum(1 for h in heads if re.match(r"^7\.2\.\d+$", h))
        if n_groups < len(pages):
            errors.append(
                f"§7.2 页组小节 {n_groups} 个 < 页面数 {len(pages)}"
                f"（L-P2-004：§7.2 关键页面交互设计必须覆盖 §7.1 全部页面，每页一组 7.2.N 并在组内列出调用接口；"
                f"确无独立交互的页面可合并说明但须逐页点名）")
    rules = data.get("rules", [])
    if len(rules) >= 5:
        r_anchors = {r.get("anchor") for r in rules if r.get("anchor")}
        if len(r_anchors) == 1:
            _only = next(iter(r_anchors))
            # v3.28.1：页面规则按页组聚合（多条规则同锚 §7.2.N）是设计口径——
            # 仅当共同锚点是通用级（<3 段，如 §5）才视为"全堆一处"失去导航价值。
            if len(_norm_anchor(_only).split(".")) < 3:
                errors.append(
                    f"rules[] 锚点单一化：{len(rules)} 条规则全部落在 {_only!r}"
                    f"（L-P2-004：规则锚点应落到所属小节 §2.2.N/§3.2.N/§6.2.N/§7.2.N…，"
                    f"并把 WHEN 行逐字注入锚点小节——全堆在同一通用锚点即失去导航价值）")
    apis = data.get("apis", [])
    if apis:
        sections_raw = _doc_sections(p)[1]
        for i, a in enumerate(apis):
            key = (a.get("detail_anchor") or "").lstrip("§")
            sec = sections_raw.get(key)
            if sec is None:
                continue  # 缺小节已由 check_api_detail_closure 报告
            method = (a.get("method") or "").strip()
            path = (a.get("path") or "").split("（")[0].strip()
            if ("> 说明：" not in sec) or (method and method not in sec) or (path and path not in sec):
                errors.append(
                    f"apis[{i}]({a.get('name')}) 详细定义小节 §{key} 缺 '> 说明：方法 路径｜权限：' 首行"
                    f"（L-P2-004：§3.2 标题只写编号+名称，方法/路径/权限必须放标题下说明行）")


def check_tech_selection(data, errors, constraints_path=None, workspace=""):
    """P1 技术选型：先淘汰后评分；矩阵/权重/证据完备；绑定块与约束契约对账。"""
    candidates = data.get("candidates", [])
    dims = data.get("dimensions", [])
    cand_ids = {c.get("id") for c in candidates}
    if len(candidates) < 2:
        errors.append(f"candidates 仅 {len(candidates)} 个（Gate 要求至少评估 2 个候选方案）")
    if len(dims) < 3:
        errors.append(f"dimensions 仅 {len(dims)} 个（Gate 要求决策矩阵 ≥ 3 个评估维度）")
    weight_total = sum(int(d.get("weight", 0)) for d in dims)
    if weight_total != 100:
        errors.append(f"dimensions 权重合计 {weight_total}% ≠ 100%（评分矩阵权重必须归一）")
    for i, d in enumerate(dims):
        for s in d.get("scores") or []:
            cid = s.get("candidate")
            if cid not in cand_ids:
                errors.append(f"dimensions[{i}]({d.get('name')}).scores 引用未知候选 {cid!r}")
            elif not (s.get("evidence") or "").strip():
                errors.append(
                    f"dimensions[{i}]({d.get('name')}) 候选 {cid} 评分无证据"
                    f"（无证据的评分无效——须附基准/引用）"
                )
    decision = data.get("decision", {})
    if decision.get("chosen") not in cand_ids:
        errors.append(
            f"decision.chosen={decision.get('chosen')!r} 不在候选方案中"
            f"（选定方案必须来自 Step 2 淘汰后的候选集合）"
        )
    # 详设文档结构决策（v3.27.7：从 P2 上移至 P1 记录，P2 只按冻结结果选模板）
    dds = data.get("design_doc_structure") or {}
    dds_mode = dds.get("mode")
    if dds_mode not in ("monolith", "total"):
        errors.append(
            f"design_doc_structure.mode={dds_mode!r} 非法"
            f"（详设文档结构必须在 P1 选型时决策：monolith=单文档 / total=总分文档）"
        )
    docs = dds.get("planned_docs") or []
    if dds_mode == "total":
        if not docs:
            errors.append(
                "design_doc_structure.mode=total 但 planned_docs 为空"
                "（总分模式必须登记总文档+分文档计划清单，P2 据此冻结 design-package.json）"
            )
        doc_ids, has_total = [], False
        for i, d in enumerate(docs):
            where = f"design_doc_structure.planned_docs[{i}]"
            if d.get("id") == "TOTAL":
                has_total = True
                if d.get("doc_mode") != "total":
                    errors.append(f"{where}: id=TOTAL 的文档 doc_mode 必须为 total")
            elif d.get("doc_mode") != "sub":
                errors.append(f"{where}({d.get('id')}): 分文档 doc_mode 必须为 sub")
            doc_ids.append(d.get("id"))
            if not (d.get("path") or "").strip():
                errors.append(f"{where}({d.get('id')}): 缺 path（计划文档必须给出相对仓库根路径）")
        dupes = {x for x in doc_ids if doc_ids.count(x) > 1}
        if dupes:
            errors.append(f"design_doc_structure.planned_docs id 重复: {sorted(dupes)}")
        if docs and not has_total:
            errors.append("design_doc_structure.planned_docs 缺少 id=TOTAL 的总文档登记")
    elif dds_mode == "monolith" and docs:
        errors.append(
            f"design_doc_structure.mode=monolith 但 planned_docs 登记了 {len(docs)} 项"
            f"（单文档模式无总分文档清单；如确为多模块应改 mode=total）"
        )
    # 脚手架重合度审计（v3.27.14 接线铁律 18）：逐功能域一行；裁剪项处置动作必须写明
    audit = data.get("scaffold_audit") or []
    domains = [a.get("domain") for a in audit]
    dup_domains = sorted({x for x in domains if x and domains.count(x) > 1})
    if dup_domains:
        errors.append(f"scaffold_audit[].domain 存在重复: {dup_domains}（每个功能域一行，二分裁决不留模糊态）")
    for i, a in enumerate(audit):
        if a.get("verdict") == "裁剪":
            action = (a.get("action") or "").strip()
            if not any(k in action for k in ("删", "下线", "移除", "清理")):
                errors.append(
                    f"scaffold_audit[{i}]({a.get('domain')}): verdict=裁剪 的处置动作未写明具体裁剪动作"
                    f"（须含 删除/下线/移除/清理 等落点——禁止只写「裁剪」二字）"
                )
    if data.get("user_confirmed") not in ("已确认", "YES"):
        errors.append(
            f"user_confirmed={data.get('user_confirmed')!r} 非用户批准值"
            f"（原则 12：选型结论必须由用户明确批准后填写「已确认」或「YES」）"
        )
    # 硬约束淘汰与绑定
    scans = {s.get("constraint_id"): s for s in data.get("constraints_scan", [])}
    bindings = {b.get("constraint_id"): b for b in data.get("bindings", [])}
    for cid, s in scans.items():
        if s.get("verdict") == "淘汰" and not (s.get("reason") or "").strip():
            errors.append(f"constraints_scan({cid}): 淘汰判定缺理由（加权评分不能覆盖硬约束，理由必须写明违反点）")
    for i, b in enumerate(data.get("bindings", [])):
        where = f"bindings[{i}]({b.get('constraint_id')})"
        if b.get("compliance") == "PASS" and not (b.get("evidence") or "").strip():
            errors.append(f"{where}: compliance=PASS 但缺 evidence（依赖坐标/POC/配置路径）")
        if (b.get("selected_product") or "").strip().lower().startswith(("未引入", "不使用", "没有")):
            errors.append(
                f"{where}: selected_product 写了否定描述（必须写实际选定的产品名——"
                f"「未引入 X」这类描述不参与 Gate 判定）"
            )
    # 与技术约束契约文件对账（可选提供 --constraints）
    if constraints_path:
        cp = Path(constraints_path)
        if not cp.exists():
            errors.append(f"--constraints 文件不存在: {constraints_path}")
        else:
            text = cp.read_text(encoding="utf-8", errors="replace")
            frozen_ids = set(re.findall(r"constraint_id=(TC-[A-Z]+-[0-9]{3})", text))
            for cid in frozen_ids:
                if cid not in bindings:
                    errors.append(
                        f"bindings 缺少冻结约束 {cid} 的选型绑定"
                        f"（P1 必须逐条回应技术约束契约；冲突即 BLOCKED）"
                    )


def check_self_check(data, errors, workspace=""):
    """P3 完成度自检：核心检查项必须全部 PASS（FAIL 即阻塞进入下个 Phase）。"""
    checks = data.get("checks", [])
    failed = [c.get("id") for c in checks if c.get("category") == "core" and c.get("status") != "PASS"]
    if failed:
        errors.append(
            f"核心检查项存在非 PASS {len(failed)} 个: {failed[:5]}…"
            f"（完成度自检是 Phase 切换凭据——先修复失败项再重跑，不得带 FAIL 进入下个阶段）"
        )
    for i, c in enumerate(checks):
        where = f"checks[{i}]({c.get('id')})"
        if c.get("status") == "PASS" and not (c.get("actual") or "").strip():
            errors.append(f"{where}: PASS 但 actual 为空（实测结果必须留痕，禁止只打勾）")
    for i, o in enumerate(data.get("outputs", [])):
        if len((o.get("output") or "")) < 8:
            errors.append(f"outputs[{i}]({o.get('check_id')}): 命令输出过短（粘贴实际输出，禁止只写「已验证」）")


def check_security(data, errors, workspace=""):
    """P3c 安全审计（v3.25.1/P1-b）：P0/P1 发现必须 CLOSED（WAIVED 须绑定豁免依据），
    覆盖率缺口须有发现兜底，报告路径必须真实存在。"""
    total = data.get("write_operations_total", 0)
    coverage = data.get("preauthorize_coverage", 0)
    waiver_file = (data.get("waiver_file") or "").strip()
    has_open_p01 = False
    for i, f in enumerate(data.get("findings", [])):
        where = f"findings[{i}]({f.get('id')})"
        sev = f.get("severity")
        status = f.get("status")
        if sev in ("P0", "P1") and status == "OPEN":
            has_open_p01 = True
            errors.append(
                f"{where}: P0/P1 级安全发现处于 OPEN（P3c 通过前必须 CLOSED，"
                f"或 WAIVED 且绑定 waiver_ref + waiver_file）"
            )
        if status == "WAIVED":
            if not (f.get("waiver_ref") or "").strip():
                errors.append(f"{where}: WAIVED 但缺 waiver_ref（豁免必须可追溯：工单/批准记录/文件:行）")
            if not waiver_file:
                errors.append(f"{where}: 存在 WAIVED 发现但顶层缺 waiver_file（豁免声明文件）")
    if waiver_file and not (Path(workspace) / waiver_file if workspace and not os.path.isabs(waiver_file) else Path(waiver_file)).is_file():
        errors.append(f"waiver_file 不存在: {waiver_file}")
    if total > 0 and coverage < 100 and not data.get("findings"):
        errors.append(
            f"写操作 {total} 个但 @PreAuthorize 覆盖率 {coverage}% 且 findings 为空"
            f"（覆盖缺口必须逐条登记发现并处置，不得静默）"
        )
    # v3.25.2：report_path 存在性由 p3 gate 强制（渲染前文件尚不存在属正常——
    # 管线顺序是 validate → render，报告是渲染产物）


def check_performance(data, errors, workspace=""):
    """P3d 性能审计（v3.25.1/P1-b）：场景 p95 超阈值不得标 PASS，全部场景须 PASS，
    报告路径必须真实存在。"""
    for i, s in enumerate(data.get("scenarios", [])):
        where = f"scenarios[{i}]({s.get('name')})"
        p95 = s.get("p95_ms")
        thr = s.get("threshold_ms")
        if isinstance(p95, int) and isinstance(thr, int) and p95 > thr and s.get("status") == "PASS":
            errors.append(
                f"{where}: p95={p95}ms 超过冻结阈值 {thr}ms 却标 PASS"
                f"（超阈值必须 FAIL 并给出优化/豁免决定，不得虚报）"
            )
        if s.get("status") == "FAIL":
            errors.append(f"{where}: 场景 FAIL（P3d 通过前所有场景必须 PASS 或移出范围并冻结说明）")
    # v3.25.2：report_path 存在性由 p3 gate 强制（同 security 口径）


def check_code_review(data, errors, workspace=""):
    """P3b 代码审查：角色分离 + P0 findings 全 CLOSED + 目标文件真实存在。"""
    dev = (data.get("developer_id") or "").strip()
    rev = (data.get("reviewer_id") or "").strip()
    ses = (data.get("session_id") or "").strip()
    if not dev or not rev:
        errors.append("DEVELOPER_ID/REVIEWER_ID 缺失（角色分离字段自 v3.16.0 起缺失即阻断）")
    elif dev.lower() == rev.lower():
        errors.append(f"role conflict: DEVELOPER_ID = REVIEWER_ID = {dev}（同人自签）")
    if not ses:
        errors.append("session_id 缺失（审查会话不可追溯）")
    findings = data.get("findings", [])
    open_p0 = [f.get("id") for f in findings if f.get("severity") == "P0" and f.get("status") != "CLOSED"]
    if open_p0:
        errors.append(
            f"存在未关闭的 P0 finding {len(open_p0)} 个: {open_p0[:5]}…"
            f"（P0 为阻断性问题，必须全部修复后才能进入下个 Phase）"
        )
    ws = _workspace_effective(workspace)
    for i, f in enumerate(findings):
        path_part = (f.get("file") or "").split("#", 1)[0].split(":", 1)[0].strip()
        if ws and path_part and not (Path(ws) / path_part).is_file():
            errors.append(
                f"findings[{i}]({f.get('id')}): 文件不存在: {path_part}"
                f"（finding 必须指向真实代码——虚构位置直接拦截）"
            )
    conclusion = data.get("conclusion")
    if conclusion == "APPROVE" and any(f.get("status") == "OPEN" and f.get("severity") in ("P0", "P1") for f in findings):
        errors.append("conclusion=APPROVE 但存在 OPEN 的 P0/P1 finding（结论与发现矛盾）")


def check_prd_validation(data, errors, workspace="."):
    """P4 PRD 验证：P0 阻断清零 + 机器字段与 Gate 契约一致 + 证据文件真实。"""
    blockers = data.get("p0_blockers", [])
    open_blockers = [b.get("id") for b in blockers if b.get("status") != "已修复"]
    machine = data.get("machine", {})
    declared = machine.get("p0_blockers")
    if declared is None:
        errors.append("machine.p0_blockers 缺失（P4 Gate 机器可读结论必须声明）")
    elif int(declared) != len(open_blockers):
        errors.append(
            f"machine.p0_blockers={declared} 与实际未修复阻断项 {len(open_blockers)} 不一致"
            f"（机器字段必须如实反映 P0 阻断清单）"
        )
    if open_blockers:
        errors.append(
            f"存在未修复 P0 阻断项 {len(open_blockers)} 个: {open_blockers[:5]}…"
            f"（P0 阻断项必须全部修复才能进入 P5）"
        )
    cmd = machine.get("p4_cmd", "")
    bad = _cmd_is_placeholder(cmd)
    if bad:
        errors.append(f"machine.p4_cmd: {bad}: {cmd}")
    for key, label in (("p4_results_path", "P4_RESULTS_PATH"), ("validation_evidence", "VALIDATION_EVIDENCE")):
        rp = (machine.get(key) or "").strip()
        if not rp:
            errors.append(f"machine.{key} 缺失（{label} 是 P4 Gate 必填机器字段）")
            continue
        resolved = Path(workspace) / rp if not os.path.isabs(rp) else Path(rp)
        if not resolved.exists():
            errors.append(f"machine.{key} 文件不存在: {rp}（证据必须由本轮验证真实生成）")
    for arr, label in (("features", "功能点"), ("fields", "数据字段"), ("apis", "接口")):
        for i, it in enumerate(data.get(arr, [])):
            if it.get("result") == "失败" and it.get("blocker_ref") is None:
                errors.append(
                    f"{arr}[{i}]: 验证结果失败但未关联 blocker_ref"
                    f"（失败项必须升级为 P0 阻断或显式登记 blocker_ref=null+理由）"
                )
    if data.get("conclusion") == "PASS" and open_blockers:
        errors.append("conclusion=PASS 但 P0 阻断清单未清零（结论与事实矛盾）")


def check_test_cases(data, errors, criteria_path=None):
    """P5 测试用例：TC-ID 唯一、每条 ≥1 步骤、验收点全覆盖、边界用例 ≥1、凭证可追溯。"""
    cases = data.get("cases", [])
    for i, c in enumerate(cases):
        where = f"cases[{i}]({c.get('id')})"
        if not c.get("steps"):
            errors.append(f"{where}: 缺测试步骤（无步骤的用例不可执行）")
        if not c.get("precondition"):
            errors.append(f"{where}: 缺前置条件")
    creds = data.get("credentials", [])
    for i, c in enumerate(creds):
        if not (c.get("source_file") or "").strip() or not (c.get("line") or "").strip():
            errors.append(
                f"credentials[{i}]({c.get('item')}): 缺代码来源（铁律 6：凭证只能从 seed/配置事实源追溯，禁止盲猜）"
            )
    covered = set()
    for c in cases:
        covered.update(_ref_list(c.get("acceptance_refs")))
    types = {c.get("type") for c in cases}
    if not types & {"边界", "异常"}:
        errors.append("缺少边界/异常类用例（至少 1 条：空输入/越界/失败路径等）")
    if criteria_path:
        cp = Path(criteria_path)
        if not cp.exists():
            errors.append(f"--criteria 验收点文件不存在: {criteria_path}（无法建立用例↔验收点对照）")
        else:
            frozen = set(re.findall(r"M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}",
                                    cp.read_text(encoding="utf-8", errors="replace")))
            not_covered = sorted(frozen - covered)
            illegal = sorted(covered - frozen)
            if not frozen:
                errors.append(f"验收点文件无任何 M-ID（{criteria_path}）——无法建立用例↔验收点对照")
            if not_covered:
                errors.append(f"验收点未被用例覆盖 {len(not_covered)} 个: {not_covered[:5]}…（全覆盖是 P5 放行条件）")
            if illegal:
                errors.append(f"用例引用了不存在的验收点 ID: {illegal[:5]}…（悬空引用）")


def check_deployment(data, errors, workspace="."):
    """P7 部署记录：制品指纹、健康检查、步骤退出码、证据文件与 Gate 同口径。"""
    art = data.get("artifact", {})
    sha = (art.get("sha256") or "").strip()
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        errors.append(f"artifact.sha256={sha[:16]!r}… 非 64 位 hex（制品指纹是部署证据锚点）")
    ws = _workspace_effective(workspace)
    ap = (art.get("path") or "").strip()
    if ap and ws:
        target = Path(ws) / ap if not Path(ap).is_absolute() else Path(ap)
        if not target.is_file():
            errors.append(f"artifact.path 不存在: {ap}（制品必须真实产出）")
        elif target.is_file() and re.fullmatch(r"[0-9a-f]{64}", sha):
            actual = _sha256(target)
            if actual != sha:
                errors.append(
                    f"artifact.sha256 声明 {sha[:12]}… 与实算 {actual[:12]}… 不一致"
                    f"（制品在记录后被替换——重新部署或更新指纹）"
                )
    health = data.get("health", {})
    url = (health.get("url") or "").strip()
    if not re.match(r"^https?://", url):
        errors.append(f"health.url 必须是 http(s): {url!r}（实时探测地址缺失不构成部署证据）")
    elif re.search(r"//169\.254\.|//[Ff][Ee]80:|//.*metadata", url):
        errors.append(f"health.url 指向 link-local/metadata 段: {url}")
    if health.get("status") != 200:
        errors.append(f"health.status={health.get('status')!r} 非 200（HEALTH_HTTP_STATUS=200 是 Gate 硬条件）")
    for i, s in enumerate(data.get("steps", [])):
        if s.get("exit_code") != 0:
            errors.append(f"steps[{i}]({s.get('name')}): exit_code={s.get('exit_code')} 非 0（失败步骤不得写成完成）")
    rp = (data.get("release_evidence_path") or "").strip()
    if rp:
        resolved = Path(workspace) / rp if not os.path.isabs(rp) else Path(rp)
        if not resolved.exists():
            errors.append(f"release_evidence_path 不存在: {rp}（部署运行输出必须落盘）")
    if not data.get("rollback_steps"):
        errors.append("rollback_steps 为空（回滚方案是部署记录的必备组成，不得省略）")
    if data.get("result") != "SUCCESS":
        errors.append(
            f"result={data.get('result')!r} 非 SUCCESS（失败的部署不是完成——先修复重部，"
            f"或在 zero_results 不可用时报 BLOCKED 停在 P7）"
        )


def check_monitoring(data, errors, workspace="."):
    """P8 监控配置：证据三件套与 artifact_gate.sh P8 同口径（文件真实 + 内容实质）。"""
    m = data.get("machine", {})
    ws = _workspace_effective(workspace) or "."
    ep = (m.get("metrics_endpoint") or "").strip()
    if not re.match(r"^https?://", ep):
        errors.append(f"machine.metrics_endpoint 必须是 http(s): {ep!r}")
    elif re.search(r"//169\.254\.|//[Ff][Ee]80:|//.*metadata", ep):
        errors.append(f"machine.metrics_endpoint 指向 link-local/metadata 段: {ep}")

    def _resolve(p):
        return Path(ws) / p if p and not os.path.isabs(p) else Path(p) if p else None

    lqe = _resolve((m.get("log_query_evidence") or "").strip())
    if lqe is None:
        errors.append("machine.log_query_evidence 缺失（日志查询必须附真实结果文件）")
    elif not lqe.is_file():
        errors.append(f"machine.log_query_evidence 不存在: {m.get('log_query_evidence')}")
    elif len(lqe.read_text(encoding="utf-8", errors="replace").splitlines()) < 2:
        errors.append(f"machine.log_query_evidence 行数 <2: {m.get('log_query_evidence')}（须含真实查询结果）")

    ar = _resolve((m.get("alert_rule") or "").strip())
    if ar is None:
        errors.append("machine.alert_rule 缺失（告警规则必须指向含 alert:/expr: 的规则文件）")
    elif not ar.is_file():
        errors.append(f"machine.alert_rule 不存在: {m.get('alert_rule')}")
    else:
        text = ar.read_text(encoding="utf-8", errors="replace")
        if "alert:" not in text or "expr:" not in text:
            errors.append(f"machine.alert_rule 文件缺 alert:/expr: 定义: {m.get('alert_rule')}")

    ato = _resolve((m.get("alert_test_output") or "").strip())
    if m.get("alert_tested") == "PASS":
        if ato is None:
            errors.append("machine.alert_tested=PASS 但 alert_test_output 缺失")
        elif not ato.is_file():
            errors.append(f"machine.alert_test_output 不存在: {m.get('alert_test_output')}")
        else:
            raw = ato.read_bytes()
            if len(raw) < 20:
                errors.append(f"machine.alert_test_output 疑似占位（{len(raw)}B < 20B）")
            else:
                text = raw.decode("utf-8", errors="replace")
                for marker in ("ALERT_TRIGGERED", "NOTIFICATION_CONFIRMED", "RECOVERY_RECORDED"):
                    if marker not in text:
                        errors.append(f"machine.alert_test_output 缺 {marker}= 记录（告警三要素不齐全）")
                if re.search(r"\bFAIL\b", text):
                    errors.append("machine.alert_test_output 含 FAIL 但声明 ALERT_TESTED=PASS（自相矛盾）")
    else:
        errors.append("machine.alert_tested 必须 PASS（告警未验证 = 监控三件套不齐全，P8 不放行）")
    for i, c in enumerate(data.get("checklist", [])):
        if c.get("status") != "PASS":
            errors.append(f"checklist[{i}]({c.get('item')}): 非 PASS（验证清单必须全过才能签发 P8 收据）")


def check_docs_index(data, errors, workspace="."):
    """P9 文档交付索引：路径存在 + SHA-256 实算一致 + substantive（口径同 artifact_gate P9）。"""
    ws = _workspace_effective(workspace) or "."
    kind_keywords = {
        "USER_DOC": "使用|快速开始|指南|入门|操作|FAQ",
        "DEVELOPER_DOC": "开发|构建|部署|接口|API",
        "API_DOC": "接口|API",
        "OPERATIONS_DOC": "运维|部署|监控",
        "RELEASE_NOTES": "变更|版本|发布|修复|新增|已知",
    }
    seen = set()
    for i, d in enumerate(data.get("docs", [])):
        where = f"docs[{i}]({d.get('kind')})"
        kind = d.get("kind")
        if kind in seen:
            errors.append(f"{where}: 文档类别重复（每类恰好一份）")
        seen.add(kind)
        p = (d.get("path") or "").strip()
        resolved = Path(ws) / p if p and not os.path.isabs(p) else Path(p) if p else None
        if resolved is None or not resolved.is_file():
            errors.append(f"{where}: 文件不存在: {p}")
            continue
        text = resolved.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        headings = [ln for ln in lines if ln.startswith("#")]
        body = [ln for ln in lines if ln.strip() and not ln.startswith("#")]
        if len(lines) < 10 or len(headings) < 2 or len(body) < 5:
            errors.append(
                f"{where}: 非 substantive 文档（{len(lines)} 行/{len(headings)} 标题/{len(body)} 正文行，"
                f"要求 ≥10/≥2/≥5）: {p}"
            )
        if not re.search(kind_keywords.get(kind, "."), text):
            errors.append(f"{where}: 文档缺类别语义章节（{kind} 须含关键词 {kind_keywords[kind]}）: {p}")
        declared_sha = (d.get("sha256") or "").strip()
        if not re.fullmatch(r"[0-9a-f]{64}", declared_sha):
            errors.append(f"{where}: sha256 非 64 位 hex")
        else:
            actual = _sha256(resolved)
            if actual != declared_sha:
                errors.append(f"{where}: sha256 声明 {declared_sha[:12]}… 与实算 {actual[:12]}… 不一致: {p}")


def check_retrospective(data, errors, workspace="."):
    """P10 复盘：每行阶段事实必须附真实收据；反馈队列字段完整。"""
    ws = _workspace_effective(workspace) or "."
    for i, pf in enumerate(data.get("phase_facts", [])):
        where = f"phase_facts[{i}]({pf.get('phase')})"
        rp = (pf.get("receipt_path") or "").strip()
        if not rp:
            errors.append(f"{where}: 缺收据路径（禁止无证据自评）")
            continue
        resolved = Path(ws) / rp if not os.path.isabs(rp) else Path(rp)
        if not resolved.is_file():
            errors.append(f"{where}: 收据文件不存在: {rp}")
        if pf.get("gate_result") == "SKIPPED" and not (pf.get("skip_note") or "").strip():
            errors.append(f"{where}: SKIPPED 须附 skip-log 授权记录说明")
    fb = data.get("feedback", {})
    if not re.fullmatch(r"FB-[0-9]{8}-[0-9]{3}", fb.get("feedback_id") or ""):
        errors.append(f"feedback.feedback_id={fb.get('feedback_id')!r} 不符合 FB-YYYYMMDD-NNN 格式")
    if fb.get("scope") != "project":
        errors.append("feedback.scope 必须 project（反馈队列保持项目本地，不外传）")
    if fb.get("status") not in ("PROPOSED", "ACCEPTED"):
        errors.append("feedback.status 必须 PROPOSED 或 ACCEPTED")
    if not (fb.get("root_cause") or "").strip():
        errors.append("feedback.root_cause 缺失（p10 Gate：根因必须记录）")
    if not fb.get("target_files"):
        errors.append("feedback.target_files 缺失（p10 Gate：整改目标文件必须列出）")
    if fb.get("decision") not in ("fix", "defer"):
        errors.append("feedback.decision 必须 fix 或 defer")
    elif fb.get("decision") == "defer" and not (fb.get("defer_reason") or "").strip():
        errors.append("feedback.decision=defer 但缺 defer_reason（p10 Gate：DEFER 必须给理由）")
    if not data.get("actions"):
        errors.append("actions 为空（复盘必须产出可执行改进项；确无改进项在 zero_results 声明并给理由）")
    out = (data.get("verify_output") or "").strip()
    if len(out) < 20:
        errors.append(
            "verify_output 过短（复核命令的实际输出必须粘贴——禁止只写「已验证」自评）"
        )


_SMALL_CHANGE_KINDS_MICRO = {"ui-copy", "ui-behavior", "bugfix", "additive-api",
                             "additive-persistence", "validation-default", "config"}
_SMALL_CHANGE_KINDS_FULL = {"breaking-api", "schema-breaking", "permission", "state-machine",
                            "cross-service", "new-module-service", "large-backfill", "multi-change"}
_SMALL_CHANGE_SCAN_KEYS = ["db", "domain", "api", "client", "config", "test",
                           "permission", "workflow", "cross_service", "history_data"]

# P2b PO 结论行禁止出现的消极词（与 p2b_demo_gate.sh 的 PO_SIGN 排除集同口径）
_DEMO_PO_BAD_RE = re.compile(r"不通过|驳回|❌|待确认|待定|未确认|进行中")


def check_demo_signoff(data, errors, workspace="."):
    """P2b 原型确认：KUF ≥3 且逐条有走查、原型文件实存、PO 明确结论、签字齐备。

    口径与 p2b_demo_gate.sh 一致（KUF 唯一编号、走查记录、原型引用实存检查）。"""
    kufs = data.get("kufs", [])
    ids = [k.get("id") for k in kufs]
    dups = sorted({x for x in ids if ids.count(x) > 1})
    if dups:
        errors.append(f"kufs[].id 存在重复: {dups}（重复编号不计入 KUF 数量——凑数即拦截）")
    for i, k in enumerate(kufs):
        if not (k.get("walkthrough") or "").strip():
            errors.append(f"kufs[{i}]({k.get('id')}): 缺 walkthrough 走查记录（无走查的旅程不构成原型确认）")
    ws = _workspace_effective(workspace)
    refs = data.get("prototype_refs", [])
    if not refs:
        errors.append("prototype_refs 为空（原型确认必须引用 docs/原型/ 下的真实原型文件）")
    for i, r in enumerate(refs):
        if not re.match(r"^docs/(原型|demo)/", r):
            errors.append(f"prototype_refs[{i}]: 原型引用必须在 docs/原型/（或历史 docs/demo/）下: {r}")
        elif ws:
            target = Path(ws) / r if not Path(r).is_absolute() else Path(r)
            if not target.is_file():
                errors.append(f"prototype_refs[{i}]: 原型文件不存在: {r}（Gate 逐一实存检查）")
    po = (data.get("po_conclusion") or "").strip()
    if not po:
        errors.append("po_conclusion 缺失（缺少 PO（产品负责人）明确结论 = P2b 不放行）")
    elif _DEMO_PO_BAD_RE.search(po):
        errors.append(f"po_conclusion 含未决/消极表述: {po!r}（PO 结论必须明确通过；迭代中的原型不得进入 P3）")
    if not data.get("conclusion_passed"):
        errors.append("conclusion_passed=false（原型确认未通过不得签发 P2b 收据）")


def check_sharing(data, errors):
    """P10 知识分享：≥3 条可复用 lesson（与 p10_feedback_gate.sh 的 lesson 计数同口径）。"""
    if len(data.get("lessons", [])) < 3:
        errors.append("lessons 少于 3 条（p10 Gate 要求知识分享 ≥3 条可复用教训）")
    for i, l in enumerate(data.get("lessons", [])):
        if not (l.get("content") or "").strip() or len(l.get("content", "")) < 8:
            errors.append(f"lessons[{i}]({l.get('topic')}): 内容过短或为空（一句话不算可复用教训）")


def check_small_change(data, errors, workspace="."):
    """SMALL-CHANGE：决策计算与 small-change-gate.sh 同口径（kind/风险命中 → FULL）。"""
    kind = data.get("kind") or (data.get("summary") or {}).get("kind")
    if kind not in _SMALL_CHANGE_KINDS_MICRO | _SMALL_CHANGE_KINDS_FULL:
        errors.append(f"kind={kind!r} 不受支持（{sorted(_SMALL_CHANGE_KINDS_MICRO | _SMALL_CHANGE_KINDS_FULL)}）")
    scan = data.get("scan", {})
    for k in _SMALL_CHANGE_SCAN_KEYS:
        if scan.get(k) not in ("HIT", "MISS", "NA"):
            errors.append(f"scan.{k}={scan.get(k)!r} 必须 HIT|MISS|NA")
    risky = any(scan.get(k) == "HIT" for k in ("permission", "workflow", "cross_service", "history_data"))
    count = data.get("logical_change_count", 1)
    computed = "FULL" if (kind in _SMALL_CHANGE_KINDS_FULL or risky or count != 1) else "MICRO"
    declared = data.get("decision")
    if declared != computed:
        errors.append(
            f"decision={declared!r} 与按证据计算值 {computed} 不一致"
            f"（kind={kind}, 风险扫描命中={risky}, 逻辑变更数={count}——决策必须可由证据复算）"
        )
    if not (data.get("decision_reason") or "").strip():
        errors.append("decision_reason 缺失（决策必须附基于项目证据的理由）")
    vc = (data.get("verify_cmd") or "").strip()
    bad = _cmd_is_placeholder(vc)
    if bad:
        errors.append(f"verify_cmd: {bad}: {vc}")
    target = data.get("target", "merge-ready")
    if target == "released":
        ws = _workspace_effective(workspace) or "."
        for key, label in (("deploy_receipt_path", "P7 收据"), ("monitor_receipt_path", "P8 收据")):
            rp = (data.get(key) or "").strip()
            resolved = Path(ws) / rp if rp and not os.path.isabs(rp) else Path(rp) if rp else None
            if resolved is None or not resolved.is_file():
                errors.append(f"{key} 缺失或不存在: {rp}（RELEASED 必须绑定成功的 {label}）")
    acceptance = data.get("acceptance", {})
    for sec in ("positive", "boundary", "failure"):
        if not (acceptance.get(sec) or "").strip():
            errors.append(f"acceptance.{sec} 缺失（正向/边界/失败三路验收条件必须逐条给出）")


# ---------- v3.25.0 各产物专项检查结束 ----------


def main():
    ap = argparse.ArgumentParser(description="校验 devflow 结构化业务产物（design.json / verification.json / 各阶段产物 JSON）")
    ap.add_argument("--kind", required=True, choices=sorted(_DEFAULT_SCHEMAS))
    ap.add_argument("--input", required=True, help="待校验的 JSON 路径")
    ap.add_argument("--schema", default=None, help="schema.json 路径（缺省用 skill 内置）")
    ap.add_argument("--criteria", default=None, help="design/test-cases: P0 验收点文件（集合对账/用例覆盖对照）")
    ap.add_argument("--doc", default=None, help="design: 详设文档路径（启用接口概览↔详细定义双向对账）")
    ap.add_argument("--constraints", default=None, help="tech-selection: P0 技术约束契约文件（绑定对账）")
    ap.add_argument("--baseline", default=None, help="verification: first-pass-baseline.tsv（启用冻结集合对账）")
    ap.add_argument("--exec-record", default=None, help="verification: test-execution-results.env（启用实际退出码对账）")
    ap.add_argument("--workspace", default=None, help="相对路径解析根（默认当前目录；design 全仓反查仅在显式传入时启用）")
    ap.add_argument("--scope-ids", dest="scope_ids", default=None,
                    help="design: 设计包验收子集（逗号分隔 M-ID）——提供时文档对账只针对本子集引用到的对象（总分多文档模式）")
    ap.add_argument("--doc-mode", dest="doc_mode", default=None, choices=("monolith", "total", "sub"),
                    help="design: 当前被校验文档的角色（v3.27.10）——mode=total 时模块级对象（页面/表/接口/规则/业务操作/旅途）不在总文档做锚点与正文明细对账，只保留全局口径（模块级对账由分文档承担）")
    ap.add_argument("--frontend-scope", default=None, dest="frontend_scope",
                    help="verification: P0 冻结的前端范围（对账声明与 CLIENT_EXEMPT 不可覆盖冻结值）")
    ap.add_argument("--max-errors", type=int, default=100, help="最多输出的错误条数")
    args = ap.parse_args()

    schema_path = Path(args.schema) if args.schema else _DEFAULT_SCHEMAS[args.kind]
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    try:
        data = json.loads(Path(args.input).read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"  ✗ {args.input}: JSON 解析失败: {e}")
        sys.exit(1)

    try:
        errors = validate(data, schema, schema)
    except SchemaError as e:
        # v3.17.3(B-6): schema 自身不合法时输出结构化错误而非裸 traceback
        print(f"  ✗ schema 不合法: {e}")
        sys.exit(2)
    warnings = []
    ws = args.workspace or ""
    if args.kind == "design":
        scope = [s.strip() for s in (args.scope_ids or "").replace("，", ",").split(",") if s.strip()] or None
        check_design(data, errors, criteria_path=args.criteria, doc_path=args.doc,
                     workspace=ws, scope_ids=scope, doc_mode=args.doc_mode)
        # v3.28.1：表名/字段名保留字分层扫描（fail→errors；warn→warnings）
        check_reserved_words(data, errors, warnings)
        # v3.28.1：规则错误码全局唯一 + 正文出现（提供 --doc 时）
        check_error_codes(data, errors, doc_path=args.doc)
        # v3.28.3(L-HIER-1)：标题层级闭环——N.M.K 子级标题必须有 N.M 父级标题（提供 --doc 时）
        if args.doc:
            check_heading_hierarchy(errors, warnings, args.doc)
    elif args.kind == "verification":
        check_verification(data, errors, baseline_path=args.baseline,
                           exec_record_path=args.exec_record, workspace=ws or ".",
                           frontend_scope=args.frontend_scope)
    else:
        # v3.25.0 全阶段产物：schema 注解通用引擎 + kind 专项检查
        check_generic(data, errors, schema)
        _KIND_CHECKS = {
            "clarification": lambda: check_clarification(data, errors),
            "execution-plan": lambda: check_execution_plan(data, errors),
            "acceptance": lambda: check_acceptance(data, errors, workspace=ws),
            "constraints": lambda: check_constraints(data, errors),
            "prd-review": lambda: check_review(data, errors, "prd-review"),
            "design-review": lambda: check_review(data, errors, "design-review"),
            "tech-selection": lambda: check_tech_selection(data, errors, constraints_path=args.constraints, workspace=ws),
            "self-check": lambda: check_self_check(data, errors, workspace=ws),
            "code-review": lambda: check_code_review(data, errors, workspace=ws),
            "security": lambda: check_security(data, errors, workspace=ws),
            "performance": lambda: check_performance(data, errors, workspace=ws),
            "prd-validation": lambda: check_prd_validation(data, errors, workspace=ws or "."),
            "test-cases": lambda: check_test_cases(data, errors, criteria_path=args.criteria),
            "deployment": lambda: check_deployment(data, errors, workspace=ws or "."),
            "monitoring": lambda: check_monitoring(data, errors, workspace=ws or "."),
            "docs-index": lambda: check_docs_index(data, errors, workspace=ws or "."),
            "retrospective": lambda: check_retrospective(data, errors, workspace=ws or "."),
            "sharing": lambda: check_sharing(data, errors),
            "demo-signoff": lambda: check_demo_signoff(data, errors, workspace=ws or "."),
            "small-change": lambda: check_small_change(data, errors, workspace=ws or "."),
        }
        if args.kind in _KIND_CHECKS:
            _KIND_CHECKS[args.kind]()
        # v3.25.0：占位话术扫描——完成度自检的 cmd/item 与输出附件本身是
        # 「检查占位符的命令」（grep TODO…），对这些路径豁免（否则合法内容误伤）
        _ph_ignore = None
        if args.kind == "self-check":
            _ph_ignore = re.compile(r"checks\[\d+\]\.(cmd|item)|outputs\[\d+\]\.output")
        check_placeholders(data, errors, ignore_re=_ph_ignore)

    if errors:
        n = len(errors)
        shown = errors[: args.max_errors]
        for e in shown:
            print("  ✗", e)
        if n > len(shown):
            print(f"  … 另有 {n - len(shown)} 处错误未显示")
        print(f"\n校验失败：共 {n} 处不合规。")
        print("  df_pipeline.py 已中止，不渲染文档——先修复 JSON 再重跑。")
        sys.exit(1)

    if warnings:
        for w in warnings[: args.max_errors]:
            print("  ⚠", w)
        print(f"  （{len(warnings)} 条警告：高风险软关键字建议规避，不阻断校验）")

    print(f"校验通过：{args.kind} JSON 符合 schema 约束与全部跨字段检查。")
    sys.exit(0)


if __name__ == "__main__":
    main()
