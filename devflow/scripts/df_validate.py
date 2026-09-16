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
_DEFAULT_SCHEMAS = {
    "design": _HERE.parent / "schemas" / "design.schema.json",
    "verification": _HERE.parent / "schemas" / "verification.schema.json",
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

_PLACEHOLDER_RE = re.compile(
    r"TODO|TBD|FIXME|待补充|待定|待确认|需确认|待验证|取决于数据|REPLACE_WITH|占位|暂定|XXX"
)


def _walk_strings(obj, path, hits):
    if isinstance(obj, str):
        m = _PLACEHOLDER_RE.search(obj)
        if m:
            hits.append((path, f"占位话术「{m.group(0)}」", obj[:50]))
    elif isinstance(obj, dict):
        for k, v in obj.items():
            _walk_strings(v, f"{path}.{k}" if path else k, hits)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            _walk_strings(v, f"{path}[{i}]", hits)


def check_placeholders(data, errors):
    """全文递归扫描字符串：占位话术直接拦截（必然是漏填的语义层）。"""
    hits = []
    _walk_strings(data, "", hits)
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
    ]
    for items, label, zh in checks:
        for i, it in enumerate(items):
            a = _norm_anchor(it.get("anchor"))
            if a and a not in headings:
                errors.append(
                    f"{label}[{i}](§{a}): §锚点在文档中不存在"
                    f"（{zh}「{it.get('name', '')}」须在详设中有对应章节标题）"
                )


def check_design(data, errors, criteria_path=None, doc_path=None, workspace=""):
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
    for i, a in enumerate(acceptance):
        where = f"acceptance[{i}]({a.get('id')})"
        for field, coll, items in (("page", "pages", pages), ("api", "apis", apis), ("data", "tables", tables)):
            if a.get(field) in items:
                continue
            if coll in declared_empty:
                if a.get(field) not in ("—", ""):
                    errors.append(
                        f"{where}.{field}: 集合 {coll} 已声明为空，但验收行仍写锚点 {a.get(field)!r}"
                        f"（陈旧引用——写 — 占位或从声明中移除空集合）"
                    )
                continue
            errors.append(f"{where}.{field}: §锚点 {a.get(field)!r} 不在 {coll}[].anchor 中（引用断链）")
        if a.get("rule") not in rules:
            errors.append(f"{where}.rule: 规则 {a.get('rule')!r} 不在 rules[].id 中（引用断链）")

    # 4. 孤儿条目（收录了却无人引用——要么漏回填引用，要么显式声明理由）
    def _orphan(items, item_key, acc_key, label):
        referenced = {a.get(acc_key) for a in acceptance}
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
        dl = mig.get("dialects", [])
        if len(set(dl)) != len(dl):
            errors.append(f"migrations.dialects 存在重复: {dl}")
        if set(dl) != {"h2", "postgresql", "oracle", "kingbase"} and not mig.get("dialect_exception"):
            errors.append(
                f"migrations.dialects={sorted(set(dl))} 非四方言齐全且缺少 dialect_exception"
                f"（铁律 5：偏离四方言必须冻结设计说明）"
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

    # 8. DDR ↔ 字段一一对应
    check_ddr_closure(data, errors)

    # 9. 接口概览 ↔ 详细定义闭环（含文档双向对账）
    check_api_detail_closure(data, errors, doc_path=doc_path)

    # 9b. 全锚点文档对账（v3.19.0 P1-4）："锚点是证据"不只适用于接口详细定义——
    # pages/tables/apis/rules 声明的每个 § 锚点都必须在文档中以标题真实存在。
    if doc_path:
        check_doc_anchors(data, errors, doc_path)

    # 10. 占位话术
    check_placeholders(data, errors)


# ---------- verification 跨字段检查 ----------


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


def main():
    ap = argparse.ArgumentParser(description="校验 devflow 结构化业务产物（design.json / verification.json）")
    ap.add_argument("--kind", required=True, choices=["design", "verification"])
    ap.add_argument("--input", required=True, help="待校验的 JSON 路径")
    ap.add_argument("--schema", default=None, help="schema.json 路径（缺省用 skill 内置）")
    ap.add_argument("--criteria", default=None, help="design: P0 验收点文件（启用集合全等对账）")
    ap.add_argument("--doc", default=None, help="design: 详设文档路径（启用接口概览↔详细定义双向对账）")
    ap.add_argument("--baseline", default=None, help="verification: first-pass-baseline.tsv（启用冻结集合对账）")
    ap.add_argument("--exec-record", default=None, help="verification: test-execution-results.env（启用实际退出码对账）")
    ap.add_argument("--workspace", default=None, help="相对路径解析根（默认当前目录；design 全仓反查仅在显式传入时启用）")
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
    if args.kind == "design":
        check_design(data, errors, criteria_path=args.criteria, doc_path=args.doc, workspace=args.workspace or "")
    else:
        check_verification(data, errors, baseline_path=args.baseline,
                           exec_record_path=args.exec_record, workspace=args.workspace or ".",
                           frontend_scope=args.frontend_scope)

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

    print(f"校验通过：{args.kind} JSON 符合 schema 约束与全部跨字段检查。")
    sys.exit(0)


if __name__ == "__main__":
    main()
