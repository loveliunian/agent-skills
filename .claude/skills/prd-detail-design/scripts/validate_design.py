# -*- coding: utf-8 -*-
"""详设 JSON 校验器：用 schema.json 约束校验 AI 精读 PRD 产出的 detail_design.json。

为什么需要它：
  详设 JSON 是下游（sdd 解析详设 → 生成规范 → 实现）的输入，缺 sourceSection、
  规则编号跳号、验收引用悬空、总分不一致这类错误会被下游静默消费（AI 读到什么
  就实现什么），不会自己报错。本脚本在交付前用 schema 的 required/enum/type
  真实验证一次，并叠加 13 条跨字段闭环检查，缺一返回非 0 退出码堵住「带病交付」。

不依赖第三方库（不 import jsonschema），只实现本 schema 用到的 JSON Schema 子集：
type/required/enum/minLength/minItems/properties/$ref/items/additionalProperties。
改 schema.json 后无需改本脚本。

12 条跨字段检查（全部翻自 SKILL.md 填写规则）：

  check_chunk_numbering       chunkId 必须 C01..CN 按数组顺序连续
  check_chunk_content         六类要素数组全空的 chunk = 空壳切片，拦截
  check_rule_numbering        ruleId 必须为 {chunkId}-R{NN} 且按数组顺序连续、全局不重复
  check_ref_closure           acceptances.ruleRefs 闭环比对 sourceRuleId（双向：
                              引用不存在的规则 ✗；规则从未被任何验收引用 ✗ 孤儿）；
                              误引 ruleId（而非 sourceRuleId）也拦
  check_acceptance_total      acceptance.designedComplete == 各 chunk acceptances 总数；
                              declared < designedComplete 拦截；declared > 总数的差额
                              是合法形态(未裁决问题挂起的条目),解释在问题清单中
  check_source_coverage       语义条目的 sourceSection 必须能挂到某个 chunk 的
                              sourceSection/contextFrom 上（按 §N 章节号前缀匹配，
                              拦凭空编造的章节引用）
  check_status_openissue      详设只收 COMPLETE 验收;PARTIAL/MISSING 不得进入本文件
                              (未闭环条目留在问题清单,裁决后以 COMPLETE 回填)
  check_placeholders          占位话术与模板变量残留（待补充/待验证/需确认/TODO/{MODULE}
                              等，全文递归扫描）
  check_ids_unique            acceptanceId 全局唯一
  check_no_problem_content    详设零问题残留：全文递归扫描「待确认/二选一/未决/Q-xx/PI-xx/
                              openIssues」等标记，出现即拦——问题内容的唯一载体是独立
                              交付的 prd_issues.json，本文件只写裁决后的定稿口径
  check_api_contract          HTTP 动词接口必须带非空 requestFields/responseFields 与
                              请求/响应示例（拦只有一行 purpose 的假接口设计；UI:xxx 豁免）
  check_table_fields          同一张表内字段名不得重复（字段级结构是建表 DDL 直接输入）
  check_decisions_landed      meta.decisions 的落地锚点必须在详设中真实存在

用法：
  python validate_design.py --input detail_design.json
  python validate_design.py --input detail_design.json --schema <skill>/schema.json --max-errors 50
"""
import argparse
import json
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_HERE = Path(__file__).resolve().parent
_DEFAULT_SCHEMA = _HERE.parent / "schema.json"


class SchemaError(Exception):
    pass


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
    return None  # 未知类型名：跳过（文档用途）


def validate(instance, schema, root, path="", errors=None):
    """按 schema 递归校验 instance，把错误追加进 errors，返回 errors 列表。"""
    if errors is None:
        errors = []

    if isinstance(schema, bool):
        return errors

    if "$ref" in schema:
        validate(instance, _deref(schema["$ref"], root), root, path, errors)
        return errors

    t = schema.get("type")
    if t is not None:
        types = t if isinstance(t, list) else [t]
        results = [_type_ok(tt, instance) for tt in types]
        if None not in results and not any(results):
            errors.append(f"{path or '$'}: 类型应 {t}，实际 {type(instance).__name__}")
            return errors

    if "enum" in schema:
        if instance not in schema["enum"]:
            errors.append(f"{path or '$'}: 值 {instance!r} 不在枚举 {schema['enum']} 中")

    if "minLength" in schema and isinstance(instance, str):
        if len(instance) < schema["minLength"]:
            errors.append(f"{path or '$'}: 字符串长度应 ≥ {schema['minLength']}，实际 {len(instance)}")

    if "minItems" in schema and isinstance(instance, list):
        if len(instance) < schema["minItems"]:
            errors.append(f"{path or '$'}: 数组长度应 ≥ {schema['minItems']}，实际 {len(instance)}")

    if isinstance(instance, dict):
        if schema.get("type") in ("object", None) or "properties" in schema:
            for k in schema.get("required", []):
                if k not in instance:
                    errors.append(f"{path or '$'}: 缺少必需字段 {k!r}（required）")
            props = schema.get("properties", {})
            if schema.get("additionalProperties") is False and props:
                for k in instance:
                    if k not in props:
                        errors.append(f"{path or '$'}: 多余字段 {k!r}（additionalProperties=false）")
            for k, v in instance.items():
                sub = props.get(k)
                if sub is None:
                    continue
                validate(v, sub, root, f"{path}.{k}" if path else k, errors)

    if isinstance(instance, list):
        item_schema = schema.get("items")
        if item_schema is not None:
            for i, item in enumerate(instance):
                validate(item, item_schema, root, f"{path}[{i}]", errors)

    return errors


_CONTENT_KEYS = ("modules", "rules", "apis", "tables", "nfrs", "acceptances")


# —— 自定义检查 1：chunk 编号 ——


def check_chunk_numbering(data, errors):
    """chunkId 必须 C01..CN 按数组顺序连续（编号是跨 chunk 引用的锚点）。"""
    for i, c in enumerate(data.get("chunks", []), start=1):
        expect = f"C{i:02d}"
        if c.get("chunkId") != expect:
            errors.append(
                f"chunks[{i - 1}].chunkId 应为 {expect}（按数组顺序连续编号），实际 {c.get('chunkId')!r}"
            )


# —— 自定义检查 2：chunk 内容非空 ——


def check_chunk_content(data, errors):
    """六类要素数组全空的 chunk 是切分出的空壳，要么补内容要么删掉。"""
    for c in data.get("chunks", []):
        if not any(c.get(k) for k in _CONTENT_KEYS):
            errors.append(
                f"chunk {c.get('chunkId')}({c.get('chapter')}): 六类要素全部为空"
                f"（空壳切片：补内容或删除该 chunk）"
            )


# —— 自定义检查 3：规则编号 ——


def check_rule_numbering(data, errors):
    """ruleId 必须为 {chunkId}-R{NN}，chunk 内按数组顺序连续，全局不重复。"""
    seen = {}
    for c in data.get("chunks", []):
        cid = c.get("chunkId")
        for j, r in enumerate(c.get("rules", []), start=1):
            expect = f"{cid}-R{j:02d}"
            rid = r.get("ruleId")
            if rid in seen:
                errors.append(f"ruleId {rid!r} 重复（首次出现于 chunk {seen[rid]}）")
            seen[rid] = cid
            if rid != expect:
                errors.append(
                    f"chunk {cid}.rules[{j - 1}].ruleId 应为 {expect}（按数组顺序连续），实际 {rid!r}"
                )


# —— 自定义检查 4：引用闭环 ——


def check_ref_closure(data, errors):
    """acceptances.ruleRefs 引用 sourceRuleId：
    - 引用不存在的规则 ✗；
    - 误引 ruleId（如 C02-R01 而非源编号）✗（提示改引 sourceRuleId）；
    - 规则从未被任何验收引用 ✗（孤儿规则：要么漏回填引用，要么不该收录）。"""
    source_ids, rule_ids = set(), set()
    for c in data.get("chunks", []):
        for r in c.get("rules", []):
            if r.get("sourceRuleId"):
                source_ids.add(r["sourceRuleId"])
            if r.get("ruleId"):
                rule_ids.add(r["ruleId"])

    refs = {}  # ref -> 首个引用位置
    for c in data.get("chunks", []):
        cid = c.get("chunkId")
        for ai, a in enumerate(c.get("acceptances", [])):
            for ref in a.get("ruleRefs", []) or []:
                refs.setdefault(ref, f"chunk {cid}.acceptances[{ai}]({a.get('acceptanceId')})")

    for ref, where in refs.items():
        if ref in rule_ids and ref not in source_ids:
            errors.append(
                f"{where}: ruleRefs 引用了 ruleId {ref!r}——应引用 PRD 源编号 sourceRuleId"
                f"（验收与规则的对接口径是 PRD 原始编号，不是详设内部编号）"
            )
        elif ref not in source_ids:
            errors.append(f"{where}: ruleRefs 引用的规则源编号 {ref!r} 在任何 chunk 的 rules 中不存在")

    for c in data.get("chunks", []):
        for r in c.get("rules", []):
            if r.get("sourceRuleId") and r["sourceRuleId"] not in refs:
                errors.append(
                    f"chunk {c.get('chunkId')}.rules: 规则 {r['sourceRuleId']!r}（{r.get('ruleId')}）"
                    f"未被任何验收标准引用（孤儿规则：要么漏回填 ruleRefs，要么不该收录）"
                )


# —— 自定义检查 5：验收总分 ——


def check_acceptance_total(data, errors):
    """acceptance.designedComplete == 各 chunk acceptances 总数；
    declared < designedComplete 拦截（设计数不能超过声明数）。
    declared > 总数的差额是合法形态（blocking 问题未裁决的验收不进详设），
    差额解释在问题清单 prd_issues.json 中，此处不再强查。"""
    total = sum(len(c.get("acceptances", [])) for c in data.get("chunks", []))
    acc = data.get("acceptance", {})
    declared, designed = acc.get("declared"), acc.get("designedComplete")
    if isinstance(designed, int) and designed != total:
        errors.append(
            f"acceptance.designedComplete={designed} 与各 chunk acceptances 总数 {total} 不一致"
            f"（填完所有验收条目后回填总分）"
        )
    if isinstance(declared, int) and isinstance(designed, int) and declared < designed:
        errors.append(f"acceptance.declared={declared} < designedComplete={designed}（逻辑矛盾）")


# —— 自定义检查 6：溯源覆盖 ——


def _section_tokens(s):
    """提取字符串里的章节号 token（§7.1 / §3 / 7.1 等形态统一为 §N(.M)*）。"""
    return re.findall(r"§?\s*(\d+(?:\.\d+)*)", s or "")


def check_source_coverage(data, errors):
    """每个语义条目的 sourceSection 必须能挂到某个 chunk 的 sourceSection/contextFrom 上：
    按 §N 章节号前缀匹配（条目引用 §7.1.3 而 chunk 登记了 §7.1 即可命中）。
    注意保护边界：比对基准是 chunk 自己登记的章节（非 PRD 原文），只能拦
    「条目章节号游离于所有 chunk 登记范围之外」，拦不住 chunk 级的整体编造——
    后者靠生成侧溯源纪律与人工评审兜底。"""
    declared_tokens = set()
    for c in data.get("chunks", []):
        for s in [c.get("sourceSection", "")] + list(c.get("contextFrom", []) or []):
            for tok in _section_tokens(s):
                declared_tokens.add(tok)
                parts = tok.split(".")
                for i in range(1, len(parts)):
                    declared_tokens.add(".".join(parts[:i]))

    if not declared_tokens:
        return

    items = []  # (where, sourceSection)
    for c in data.get("chunks", []):
        cid = c.get("chunkId")
        for mi, m in enumerate(c.get("modules", [])):
            items.append((f"chunk {cid}.modules[{mi}]({m.get('name')})", m.get("sourceSection")))
        for ri, r in enumerate(c.get("rules", [])):
            items.append((f"chunk {cid}.rules[{ri}]({r.get('ruleId')})", r.get("sourceSection")))
        for oi, a in enumerate(c.get("apis", [])):
            items.append((f"chunk {cid}.apis[{oi}]({a.get('path')})", a.get("sourceSection")))
        for ti, t in enumerate(c.get("tables", [])):
            items.append((f"chunk {cid}.tables[{ti}]({t.get('name')})", t.get("sourceSection")))
        for ni, n in enumerate(c.get("nfrs", [])):
            items.append((f"chunk {cid}.nfrs[{ni}]", n.get("sourceSection")))
        for ai, a in enumerate(c.get("acceptances", [])):
            items.append((f"chunk {cid}.acceptances[{ai}]({a.get('acceptanceId')})", a.get("sourceSection")))

    for where, sec in items:
        toks = _section_tokens(sec)
        if not toks:
            continue  # 无章节号形态（如自由文本）不在此拦，语义判断留给 AI
        if not any(t in declared_tokens or any(t.startswith(d + ".") for d in declared_tokens) for t in toks):
            errors.append(
                f"{where}: sourceSection {sec!r} 无法挂到任何 chunk 登记的章节"
                f"（已登记章节号：{sorted(declared_tokens)}；请核对 PRD 章节号是否凭空编造）"
            )


# —— 自定义检查 7：验收必须全部定稿 ——


def check_status_openissue(data, errors):
    """详设是确认件：status=PARTIAL/MISSING 的验收不得进入本文件
    （未闭环验收属于问题清单管辖，裁决后以 COMPLETE 形态回填）。"""
    for c in data.get("chunks", []):
        for a in c.get("acceptances", []):
            if a.get("status") != "COMPLETE":
                errors.append(
                    f"chunk {c.get('chunkId')}.acceptances({a.get('acceptanceId')}): "
                    f"status={a.get('status')}——详设只收 COMPLETE 验收，未闭环条目留在问题清单待裁决回填"
                )


# —— 自定义检查 8：占位话术与模板变量 ——


_PLACEHOLDER_RE = re.compile(
    r"待补充|待验证|需确认|取决于数据|待分析|此处略|占位|TODO|TBD"
)
_TEMPLATE_VAR_RE = re.compile(r"\{(?:MODULE|MODULE_CODE|MODULE_NAME|SECTION|X|N|TABLE|API|R_XX)\}")


def _walk_strings(obj, path, hits):
    if isinstance(obj, str):
        m = _PLACEHOLDER_RE.search(obj)
        if m:
            hits.append((path, f"占位话术「{m.group(0)}」", obj[:50]))
        m = _TEMPLATE_VAR_RE.search(obj)
        if m:
            hits.append((path, f"模板变量残留「{m.group(0)}」", obj[:50]))
    elif isinstance(obj, dict):
        for k, v in obj.items():
            _walk_strings(v, f"{path}.{k}" if path else k, hits)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            _walk_strings(v, f"{path}[{i}]", hits)


def check_placeholders(data, errors):
    """全文递归扫描字符串：占位话术 / 模板变量残留直接拦截（必然是漏填）。"""
    hits = []
    _walk_strings(data, "", hits)
    for path, kind, preview in hits:
        errors.append(f"{path}: {kind}（…{preview}…）")


# —— 自定义检查 9：acceptanceId 全局唯一 ——


def check_ids_unique(data, errors):
    seen = {}
    for c in data.get("chunks", []):
        for a in c.get("acceptances", []):
            aid = a.get("acceptanceId")
            if aid in seen:
                errors.append(f"acceptanceId {aid!r} 重复（首次出现于 chunk {seen[aid]}，须全局唯一）")
            seen[aid] = c.get("chunkId")



# —— 自定义检查 10：详设零问题残留 ——


_PROBLEM_RE = re.compile(
    r"待确认|待定稿|待裁决|未裁决|未决|口径冲突|二选一|占位不展开|不展开|WAITING_DECISION"
    r"|openIssues|prdIssues"
    r"|(?:Q|PI)-\d+(?![^。；;]{0,12}(?:已裁决|已确认|已定稿|裁决|[=＝]))"
)


def check_no_problem_content(data, errors):
    """详设是给下游实现的确认件，问题内容（未决/矛盾/缺口）的唯一载体是独立交付的
    prd_issues.json——本文件出现任何问题标记都意味着「把疑问当设计交给下游」，拦截。
    豁免：meta.decisions 是裁决落地台账，issueId（PI-xx）是合法的回指编号。"""
    hits = []
    _walk_strings(data, "", hits)
    # _walk_strings 只报占位话术；这里单独按问题标记扫
    def walk(obj, path):
        if isinstance(obj, str):
            m = _PROBLEM_RE.search(obj)
            if m and not path.startswith("meta.decisions"):
                errors.append(f"{path}: 出现问题类标记「{m.group(0)}」（详设零问题残留："
                              f"该内容属于 prd_issues.json，详设只写裁决后的定稿口径）")
        elif isinstance(obj, dict):
            for k, v in obj.items():
                walk(v, f"{path}.{k}" if path else k)
        elif isinstance(obj, list):
            for i, v in enumerate(obj):
                walk(v, f"{path}[{i}]")
    walk(data, "")


# —— 自定义检查：接口契约完整性 ——


_HTTP_VERBS = ("GET", "POST", "PUT", "PATCH", "DELETE")


def check_api_contract(data, errors):
    """method 为 HTTP 动词的接口 = 完整契约：必须带非空 responseFields 与
    requestExample/responseExample；requestFields 仅 GET 豁免（无 query 入参是常态，
    写空数组即可），其余动词必须非空；UI:xxx 语义操作豁免（REST 契约未定稿的场景，
    缺口应登记在问题清单）。拦「只有一行 purpose 的假接口设计」。"""
    for c in data.get("chunks", []):
        for oi, a in enumerate(c.get("apis", [])):
            method = (a.get("method") or "").strip().upper()
            if method not in _HTTP_VERBS:
                continue
            where = f"chunk {c.get('chunkId')}.apis[{oi}]({a.get('method')} {a.get('path')})"
            if not a.get("requestFields") and method != "GET":
                errors.append(f"{where}: {method} 接口缺 requestFields（请求字段表；GET 无 query 入参才可空）")
            if not a.get("responseFields"):
                errors.append(f"{where}: HTTP 接口缺 responseFields（响应字段表）")
            if not (a.get("requestExample") or "").strip():
                errors.append(f"{where}: HTTP 接口缺 requestExample（请求示例）")
            if not (a.get("responseExample") or "").strip():
                errors.append(f"{where}: HTTP 接口缺 responseExample（响应示例）")


# —— 自定义检查：表字段唯一性 ——


def check_table_fields(data, errors):
    """同一张表内字段名不得重复（字段级结构是建表 DDL 的直接输入）。"""
    for c in data.get("chunks", []):
        for ti, t in enumerate(c.get("tables", [])):
            seen = set()
            for f in t.get("fields", []):
                name = (f.get("name") or "").strip()
                if name in seen:
                    errors.append(
                        f"chunk {c.get('chunkId')}.tables[{ti}]({t.get('name')}): 字段 {name!r} 重复定义"
                    )
                seen.add(name)


# —— 自定义检查 13：裁决落地锚点真实存在 ——


def check_decisions_landed(data, errors):
    """meta.decisions 登记的每个锚点必须能在本文件找到：
    ruleId（C01-R03 形态，详设内部编号）/ acceptanceId / 接口锚点（METHOD path）。
    拦"裁决台账写错锚点"——台账与正文对不上等于没登记。
    注意：只校验已登记锚点的真实性；"resolved 且 blocking 的问题是否都有台账"
    需要问题清单参与，由 run_design.py 3.5 段对账（本脚本不读 issues 文件）。"""
    rule_ids, acc_ids, api_anchors = set(), set(), set()
    for c in data.get("chunks", []):
        for r in c.get("rules", []):
            if r.get("ruleId"):
                rule_ids.add(r["ruleId"])
        for a in c.get("acceptances", []):
            if a.get("acceptanceId"):
                acc_ids.add(a["acceptanceId"])
        for a in c.get("apis", []):
            m = (a.get("method") or "").strip()
            p = (a.get("path") or "").strip()
            if m and p:
                api_anchors.add(f"{m.upper()} {p}")

    for d in data.get("meta", {}).get("decisions", []) or []:
        pid = d.get("issueId")
        for anchor in d.get("landedAt", []) or []:
            a = (anchor or "").strip()
            if not a:
                continue
            if a in rule_ids or a in acc_ids or a in api_anchors:
                continue
            errors.append(
                f"meta.decisions[{pid}]: 锚点 {a!r} 在详设中不存在"
                f"（合法形态：ruleId 如 C01-R03 / acceptanceId 如 A4 / 接口锚点如 POST /api/users；"
                f"请核对编号或接口是否真的落地）"
            )


def main():
    ap = argparse.ArgumentParser(description="用 schema.json 校验 AI 精读 PRD 产出的详设 JSON")
    ap.add_argument("--input", required=True, help="待校验的 detail_design.json 路径")
    ap.add_argument("--schema", default=str(_DEFAULT_SCHEMA), help="schema.json 路径")
    ap.add_argument("--max-errors", type=int, default=100, help="最多输出的错误条数")
    args = ap.parse_args()

    schema = json.loads(Path(args.schema).read_text(encoding="utf-8"))
    data = json.loads(Path(args.input).read_text(encoding="utf-8"))

    errors = validate(data, schema, schema)
    check_chunk_numbering(data, errors)
    check_chunk_content(data, errors)
    check_rule_numbering(data, errors)
    check_ref_closure(data, errors)
    check_acceptance_total(data, errors)
    check_source_coverage(data, errors)
    check_status_openissue(data, errors)
    check_placeholders(data, errors)
    check_ids_unique(data, errors)
    check_no_problem_content(data, errors)
    check_api_contract(data, errors)
    check_table_fields(data, errors)
    check_decisions_landed(data, errors)

    if errors:
        n = len(errors)
        shown = errors[: args.max_errors]
        for e in shown:
            print("  ✗", e)
        if n > len(shown):
            print(f"  … 另有 {n - len(shown)} 处错误未显示")
        print(f"\n校验失败：共 {n} 处不合规。")
        print("  详设 JSON 是下游实现的输入，这些缺口会被静默消费，请先修复再交付。")
        sys.exit(1)

    print("校验通过：detail_design.json 符合 schema 约束与 13 条跨字段闭环检查。")
    sys.exit(0)


if __name__ == "__main__":
    main()
