#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SDD 守门引擎(v2,自包含)。五步流程:①解析 ②规范 ③实现 ④测试 ⑤复盘。

用法(--stage 决定检查哪道门):
    python sdd.py <specs目录> --stage parse                    # ①解析 检查
    python sdd.py <specs目录> --stage list  [--strict]         # ①清单确认(建议 --strict)
    python sdd.py <specs目录> --stage spec  [--strict]         # ②spec 确认
    python sdd.py <specs目录> --stage start [--strict]         # ②开工放行
    python sdd.py <specs目录> --stage begin <F编号>            # ③单个功能 开工登记
    python sdd.py <specs目录> --stage deliver <F编号>          # ③单个功能 交付检查
    python sdd.py <specs目录> --stage report <F编号>           # ③交付确认呈报(自动生成)
    python sdd.py <specs目录> --stage done                     # ④收尾检查
    python sdd.py <specs目录> --stage set-status <F编号> --status 已确认|实现中|已交付 --by <谁>
    python sdd.py <specs目录> --set-status <F编号> --status 草案|已确认 --by <谁>
    python sdd_state.py <specs目录> state                      # 全局状态机报数

状态值:草案 → 已确认 → 实现中 → 已交付。
**改校验规则只改本文件**(及公共底座 sdd_common.py)。
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sdd_common import (F_ID, Q_ID, Q_IN_TEXT, ERRORS, WARNS,  # noqa: F401
                        err, warn, rel, load_json, find_spec_dir,
                        summarize, set_spec_status)
# 实现段 load_json 包装的底层别名(common 的原函数)
_load_json = load_json

try:
    import jsonschema
    HAS_JSONSCHEMA = True
except ImportError:
    jsonschema = None
    HAS_JSONSCHEMA = False


# ==========================================================================
# 规范段(解析/清单/spec/开工放行)
# ==========================================================================

SKILL_DIR = Path(__file__).resolve().parent.parent
SCHEMA_DIR = SKILL_DIR / "schemas"
TEMPLATE_DIR = SKILL_DIR / "templates"

STAGES = ["parse", "list", "spec", "start"]
STAGE_ORDER = {s: i for i, s in enumerate(STAGES)}
# spec 确认通过后可继续推进的状态(之后会进入实现中/已交付)
SPEC_APPROVED = {"已确认", "实现中", "已交付"}
ARCH_LABEL = {"monolith": "单体", "microservices": "微服务"}

R_ID = re.compile(r"^R\d+$")
SPEC_DIR_NAME = re.compile(r"^(F\d{3})(?:-.*)?$")  # F 编号统一三位,与 schema/F_ID 一致
RULE_ID_REF = re.compile(r"^C\d{2,3}-R\d{2,}$")

# 质量红线:规则文本禁止的兜底词(命中即 ERROR)
BANNED = ["合理", "适当", "参考现有", "见后文", "待补充", "待完善", "酌情", "视情况而定"]
# 兜底词的正当同形用法:如"合理性"=有效性校验,是被描述的业务动作而非敷衍措辞。
# 中文无词边界,黑名单用子串匹配会把"参数合理性校验"这类正经规则误杀,
# 故检查前先把这些多义词整体剔除,再查剩下的兜底词。有新增误杀词就往本表加。
BANNED_EXEMPT = ["合理性"]
# 以"等"收尾视为含糊;但"相等/等价"等实义双字词不是兜底,不能误杀
ETC_REAL_WORDS = {"相等", "不等", "对等", "同等", "等价", "等值", "等额", "等式", "等号",
                  "等待", "等量", "等长", "等高", "等宽", "等效", "等比", "等幂", "等边"}


# ---------------------------------------------------------------- Schema 校验

def schema_validate(name, data, where):
    """有 jsonschema 走正式 Schema;没有则走内置加强校验(覆盖 type/required/enum/
    pattern/minItems/minimum/additionalProperties),两种模式严格度对齐。"""
    schema_path = SCHEMA_DIR / f"{name}.schema.json"
    if not schema_path.exists():
        err(f"[{where}] 找不到 Schema 定义: {schema_path.name}")
        return
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        err(f"[{where}] Schema 文件本身解析失败: {e}")
        return
    if HAS_JSONSCHEMA:
        for e in jsonschema.Draft7Validator(schema).iter_errors(data):
            loc = "/".join(str(p) for p in e.absolute_path) or "(root)"
            err(f"[{where}] Schema 违规 {loc}: {e.message}")
        return
    _builtin_walk(data, schema, "", where)


_TYPES = {
    "object": dict, "array": list, "string": str,
    "boolean": bool, "null": type(None),
}


def _type_ok(value, tname):
    if tname == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if tname == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    exp = _TYPES.get(tname)
    return exp is not None and isinstance(value, exp)


def _builtin_walk(node, sch, loc, where):
    tname = sch.get("type")
    if tname:
        names = tname if isinstance(tname, list) else [tname]
        if not any(_type_ok(node, t) for t in names):
            err(f"[{where}] {loc} 类型应为 {names},实际 {type(node).__name__}")
            return
    if "enum" in sch and node not in sch["enum"]:
        err(f"[{where}] {loc} 取值不在枚举 {sch['enum']} 内: {node!r}")
    if isinstance(node, dict):
        for k in sch.get("required", []):
            if k not in node:
                err(f"[{where}] 缺少必填字段 {loc}/{k}")
        props = sch.get("properties", {})
        if sch.get("additionalProperties") is False:
            for k in node:
                if k not in props:
                    err(f"[{where}] {loc}/{k} 是 Schema 未定义字段(additionalProperties=false)")
        for k, v in node.items():
            sub = props.get(k)
            if sub:
                _builtin_walk(v, sub, f"{loc}/{k}", where)
    elif isinstance(node, list):
        if "minItems" in sch and len(node) < sch["minItems"]:
            err(f"[{where}] {loc} 条目数 {len(node)} 少于 minItems {sch['minItems']}")
        if "maxItems" in sch and len(node) > sch["maxItems"]:
            err(f"[{where}] {loc} 条目数 {len(node)} 超过 maxItems {sch['maxItems']}")
        item_sch = sch.get("items")
        if item_sch:
            for i, item in enumerate(node):
                _builtin_walk(item, item_sch, f"{loc}[{i}]", where)
    elif isinstance(node, str):
        if "pattern" in sch and not re.match(sch["pattern"], node):
            err(f"[{where}] {loc} 不匹配 {sch['pattern']}: {node!r}")
        if "minLength" in sch and len(node) < sch["minLength"]:
            err(f"[{where}] {loc} 长度不足 {sch['minLength']}: {node!r}")
    elif isinstance(node, (int, float)) and not isinstance(node, bool):
        if "minimum" in sch and node < sch["minimum"]:
            err(f"[{where}] {loc} 值 {node} 小于 minimum {sch['minimum']}")
        if "maximum" in sch and node > sch["maximum"]:
            err(f"[{where}] {loc} 值 {node} 超过 maximum {sch['maximum']}")


# ------------------------------------------------------------ 模板驱动章节校验

def template_titles(tpl_path):
    """抽取模板的二级标题(去编号),作为产物章节结构的唯一真源。"""
    if not tpl_path.exists():
        err(f"模板文件缺失: {rel(tpl_path)}")
        return []
    return _titles_of(tpl_path.read_text(encoding="utf-8"))


def _titles_of(text):
    out = []
    for line in text.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            out.append(re.sub(r"^\d+\.\s*", "", m.group(1)))
    return out


def check_sections_against_template(doc_path, tpl_path, label):
    """产物章节必须与模板一一对应——避免"模板 N 节 / 文档写 M 节 / 脚本查另一套"三处漂移。"""
    want = template_titles(tpl_path)
    got = _titles_of(doc_path.read_text(encoding="utf-8"))
    for t in want:
        if t not in got:
            err(f"{label} 缺少章节「{t}」(以 {tpl_path.name} 为准)")
    for t in got:
        if t not in want:
            warn(f"{label} 存在模板之外的章节「{t}」,确认是否应回写进模板")


# ---------------------------------------------------------------- 规则文本红线

def ends_with_etc(text):
    t = text.rstrip("。；;，,、 \t")
    if not t.endswith("等"):
        return False
    if len(t) < 2:
        return True
    return t[-2:] not in ETC_REAL_WORDS


def collect_rule_q_refs(rule):
    """一条规则声明的 Q:qRefs 数组 ∪ 规则文本里的 [Q编号] 占位。"""
    refs = set(r for r in rule.get("qRefs", []) if Q_ID.match(str(r)))
    refs |= set(Q_IN_TEXT.findall(rule.get("text", "")))
    return refs


def check_rules_text(rules, where):
    for r in rules:
        text = r.get("text", "")
        scan = text
        for ex in BANNED_EXEMPT:
            scan = scan.replace(ex, "")
        for w in BANNED:
            if w in scan:
                # 2026-09-17 降级 ERROR→WARN:子串匹配是启发式,误杀豁免表在打地鼠;
                # 兜底措辞该由人审把关,不再阻断关口。qRefs 一致性红线仍为 ERROR。
                warn(f"[{where}] {r.get('id')} 规则含兜底词「{w}」(启发式,人工复核): {text}")
        if ends_with_etc(text):
            warn(f"[{where}] {r.get('id')} 规则以「等」收尾且未用 [Q编号] 界定范围(启发式,人工复核): {text}")
        listed = set(r.get("qRefs", []))
        # 红线:文本里写了 [Q编号] 占位就必须同步登记进 qRefs,二者不一致即阻断关口(非仅提醒)
        for q in sorted(collect_rule_q_refs(r) - listed):
            err(f"[{where}] {r.get('id')} 文本占位 [{q}] 未同步登记到 qRefs(红线:占位与 qRefs 必须一致)")


# ---------------------------------------------------------------- feature 清单

def check_acyclic(features, stage):
    ids = {f.get("id") for f in features}
    done_ids = {f.get("id") for f in features if f.get("done")}
    for f in features:
        for d in f.get("deps", []):
            if d not in ids:
                err(f"feature {f.get('id')} 依赖不存在的 {d}")
            if d == f.get("id"):
                err(f"feature {f.get('id')} 依赖自身")
    state = {}

    def dfs(fid):
        if state.get(fid) == 1:
            err(f"feature 依赖存在环,经过 {fid}")
            return
        if state.get(fid) == 2:
            return
        state[fid] = 1
        for f in features:
            if f.get("id") == fid:
                for d in f.get("deps", []):
                    if d in ids:
                        dfs(d)
        state[fid] = 2

    for f in features:
        dfs(f.get("id"))

    first = [f for f in features if f.get("firstBatch")]
    if stage is None:
        return {f.get("id") for f in first}
    if not 2 <= len(first) <= 4:
        err(f"首批数量 {len(first)} 不在 2~4 范围(首批必须 2~4 个)")
    first_ids = {f.get("id") for f in first}
    for f in first:
        for d in f.get("deps", []):
            # 首批必须闭环:依赖要么在首批内,要么是开工前已交付的既有 feature
            if d not in first_ids and d not in done_ids:
                err(f"首批 {f.get('id')} 依赖 {d}:既不在首批也未标 done(首批必须闭环)")
    return first_ids


def check_feature_list(fl, specs, stage):
    feature_ids, first_ids, arch = set(), set(), None
    names = [f.get("name") for f in fl.get("features", [])]
    fids = [f.get("id") for f in fl.get("features", [])]
    if len(fids) != len(set(fids)):
        err("feature-list.json 存在重复 feature 编号")
    if len(names) != len(set(names)):
        err("feature-list.json 存在重复 feature 名称")
    arch = fl.get("architecture")
    if arch not in ARCH_LABEL:
        err(f"feature-list.json architecture 必须为 {sorted(ARCH_LABEL)} 之一,当前 {arch!r}")
    for f in fl.get("features", []):
        if f.get("done"):
            continue
        b = f.get("boundary", "")
        if b and "不" not in b and not re.search(r"\bnot\b", b, re.IGNORECASE):
            warn(f"feature {f.get('id')} 的 boundary 疑似只有「做什么」没有「不做什么」: {b}")
        est = f.get("estimateDays")
        if est is None:
            err(f"feature {f.get('id')} 缺 estimateDays,无法核对粒度(1~5 人日)")
        elif est > 5:
            err(f"feature {f.get('id')} 粒度 {est} 人日超上限,需再拆")
        elif est < 1:
            warn(f"feature {f.get('id')} 粒度 {est} 人日低于 1 人日,考虑与相邻 feature 合并")
    first_ids = check_acyclic(fl.get("features", []), stage)
    if fl.get("status") == "已确认":
        for k in ("approvedBy", "approvedAt"):
            if not fl.get(k):
                err(f"feature-list.status 已是已确认,但缺 {k}(清单确认缺凭据)")
    md = specs / "feature-list.md"
    if md.exists():
        check_md_ids(md, fids, "feature-list.md")
    else:
        err("缺少文件: feature-list.md(md/json 必须同源)")
    return feature_ids, first_ids, arch


def check_md_ids(md_path, ids, label):
    text = md_path.read_text(encoding="utf-8")
    for i in ids:
        if i and not re.search(rf"\b{re.escape(str(i))}\b", text):
            err(f"{label} 缺少 json 中登记的编号 {i},md/json 不同源")


# ---------------------------------------------------------------- open-questions

def check_q_range_lock(specs, questions):
    """B3 编号锁:并行批次开工前在 _work/q-range-lock.json 认领编号区间,
    open-questions 中归属单一 feature 的条目编号必须落在该 feature(或任一认领方)的区间内,
    且落在谁的区域谁必须是归属方之一;未认领区间内的条目出 WARNING(并行期人工核对)。"""
    lock_path = specs / "_work" / "q-range-lock.json"
    if not lock_path.exists():
        return
    lock = load_json(lock_path)
    if not lock or not isinstance(lock, dict):
        return
    claims = lock.get("claims", {})
    exempt = set(lock.get("exempt", []))
    ranges = []
    for fid, rng in claims.items():
        try:
            ranges.append((fid, int(rng.get("min", 0)), int(rng.get("max", 0))))
        except (TypeError, ValueError):
            err(f"q-range-lock.json: {fid} 的 min/max 非整数")
    floor = min((lo for _, lo, _ in ranges), default=0)  # 前锁时代(最小认领号之前)不检查
    for q in questions:
        try:
            num = int(re.sub(r"^Q", "", str(q.get("id", ""))))
        except ValueError:
            continue
        if num < floor or q.get("id") in exempt:
            continue
        feats = set(q.get("features", []))
        hit = [fid for fid, lo, hi in ranges if lo <= num <= hi]
        if not hit:
            if ranges:
                warn(f"{q.get('id')} 编号不在任何认领区间内(并行期人工核对归属)")
            continue
        if feats and not (feats & set(hit)):
            err(f"{q.get('id')} 编号落在 {hit} 的认领区间,但 features 归属 {sorted(feats)}——疑似并行撞号")


def check_open_questions(oq, feature_ids, stage, specs):
    qs = oq.get("questions", [])
    ids = [q.get("id") for q in qs]
    if len(ids) != len(set(ids)):
        err("open-questions.json 存在重复 Q 编号")
    for q in qs:
        for fid in q.get("features", []):
            if feature_ids and fid not in feature_ids:
                err(f"{q.get('id')} 影响不存在的 feature {fid}")
        if q.get("features") and not q.get("source"):
            err(f"{q.get('id')} 缺 source,无法追溯来源章节")
        if q.get("status") == "已关闭":
            for k, cn in (("answer", "答复"), ("answeredBy", "answeredBy(谁答的)"), ("answeredAt", "answeredAt(答复日期)")):
                if not q.get(k):
                    err(f"{q.get('id')} 状态 closed 但缺 {cn}")
        if not q.get("suggestion"):
            err(f"{q.get('id')} 缺 suggestion:不给建议答案的问题不许入表")
    md = specs / "open-questions.md"
    if md.exists():
        check_md_ids(md, ids, "open-questions.md")
    elif stage is not None:
        err("缺少文件: open-questions.md(md/json 必须同源)")
    return {q.get("id") for q in qs}, qs


# ---------------------------------------------------------------- 解析过程件

# ---- R-J 字段口径一致性----
# 字符类字段必须带长度;长度/列集合以详设为唯一真源,spec 偏离必须标注 [Q编号]。
CHAR_TYPES = {"varchar", "char", "character", "nvarchar", "character varying"}
Q_MARK = Q_IN_TEXT  # 全库唯一的 Q 占位正则(common 共享),不再各自编译


def _field_head(field_str):
    """拆字段定义串首部,返回 (列名, 类型小写, 是否带长度)。解析不了返回 (None, None, False)。"""
    body = str(field_str).split("--")[0].strip()
    m = re.match(r"^([A-Za-z_]\w*)\s+(.+)$", body)
    if not m:
        return None, None, False
    col, rest = m.group(1), m.group(2)
    mm = re.match(r"([A-Za-z][A-Za-z ]*?)\s*(\(\s*\d+\s*\))?(?:\s+|$)", rest)
    typ = (mm.group(1) or "").strip().lower() if mm else ""
    has_len = bool(mm and mm.group(2))
    return col, typ, has_len


def _norm_field(field_str):
    """字段定义规范化(去注释、去 Q 标注、压缩空白、大写)用于与详设 twin 比对。"""
    body = str(field_str).split("--")[0]
    body = Q_MARK.sub("", body)
    return re.sub(r"\s+", " ", body).strip().upper()


def check_spec_tables_fields(data, twin_tables, q_ids, where):
    """spec.json tables[].fields 与详设抽取件 twin 比对:列缺失/新增/定义变更都必须挂 [Q编号]。"""
    for t in data.get("tables", []) or []:
        tname = (t.get("name") or "").strip().lower()
        fields = t.get("fields") or []
        for f in fields:
            col, typ, has_len = _field_head(f)
            if col and typ in CHAR_TYPES and not has_len:
                err(f"[{where}] 表 {t.get('name')} 字段 {col} 为字符类型({typ})未带长度"
                    f"(R-J:长度以详设为真源,新表字段也须明确长度)")
        if not fields:
            if tname and twin_tables.get(tname):
                warn(f"[{where}] 表 {t.get('name')} 在详设抽取件中已有字段定义,建议在 spec.json "
                     f"tables[].fields 抄录字段以便机器比对(R-J 字段口径一致性)")
            continue
        twin_cols = twin_tables.get(tname) or {}
        spec_map = {}
        for f in fields:
            col, _, _ = _field_head(f)
            if col:
                spec_map[col.lower()] = f
        missing = sorted(set(twin_cols) - set(spec_map))
        added = sorted(c for c in spec_map if c not in twin_cols)
        changed = sorted(c for c in spec_map
                         if c in twin_cols and _norm_field(spec_map[c]) != _norm_field(twin_cols[c]))

        def need_q(cols, kind):
            for c in cols:
                fs = spec_map.get(c, "")
                m = Q_MARK.search(str(fs))
                if not m:
                    err(f"[{where}] 表 {t.get('name')} 字段与详设不一致({kind}: {c})但未标注 [Q编号]——"
                        f"偏离详设口径必须登记 Q 并显式引用")
                elif q_ids is not None and m.group(1) not in q_ids:
                    err(f"[{where}] 表 {t.get('name')} 字段 {c} 标注的 {m.group(1)} 未登记进 open-questions.json")

        need_q(missing, "详设有此列而 spec 未登记,若为有意裁剪请在 fields 补登该列并标注 [Q编号]")
        need_q(added, "新增列")
        need_q(changed, "类型/长度/约束变更")


def check_chunk_plan(specs, stage):
    work = specs / "_work"
    plan_path = work / "chunk-plan.json"
    plan = load_json(plan_path, required=stage == "parse")
    plan_ids = []
    if plan is not None:
        if not isinstance(plan, list):
            err("chunk-plan.json 顶层必须是数组 [{chunkId,source,approxLines},...],不是对象包装")
        else:
            schema_validate("chunk-plan", plan, "chunk-plan.json")
            plan_ids = [c.get("chunkId") for c in plan if isinstance(c, dict)]
            if len(plan_ids) != len(set(plan_ids)):
                err("chunk-plan.json 存在重复 chunkId")
            for c in plan:
                src = c.get("source", "") if isinstance(c, dict) else ""
                if src and "#" not in src and "§" not in src:
                    warn(f"chunk-plan {c.get('chunkId')} 的 source 未标到章节粒度: {src}")
    return plan_ids


def check_extracts(specs, plan_ids, stage):
    """逐片校验抽取件,并回原始抽取件统计七项 raw 计数。"""
    work = specs / "_work"
    extracts = sorted(work.glob("extract-*.json")) if work.is_dir() else []
    raw = {"modules": 0, "apis": 0, "tables": 0, "rules": 0,
           "nfrs": 0, "acceptances": 0, "openIssues": 0}
    detail = {}
    accs = []
    src_rule_ids = set()  # 全部片的原文规则编号,供追溯矩阵自洽比对
    sid_map = {}          # 原文编号 -> {Cxx-Rnn};必须全局建,因为追溯矩阵常与规则表不在同一片
    twin_tables = {}      # R-J:详设字段 twin {表名小写: {列名小写: 字段定义串}}
    if stage == "parse" and not extracts:
        err("p0 阶段必需: _work/ 下至少一个 extract-*.json")
    extract_ids = []
    for ex in extracts:
        data = load_json(ex, required=True)
        if not data:
            continue
        schema_validate("chunk-extract", data, ex.name)
        cid = data.get("chunkId", "")
        extract_ids.append(cid)
        if cid and ex.stem != f"extract-{cid}":
            err(f"{ex.name} 文件名与内容 chunkId({cid})不一致")
        for k in raw:
            raw[k] += len(data.get(k, []) or [])
        rules = data.get("rules", []) or []
        seen_rid = set()
        for i, r in enumerate(rules, 1):
            rid = r.get("ruleId") or f"{cid}-R{i:02d}"
            if not RULE_ID_REF.match(str(rid)):
                err(f"{ex.name} 规则 {rid!r} 编号格式应为 Cxx-Rnn(两位以上序号),否则台账对账会错位")
            if rid in seen_rid:
                err(f"{ex.name} 存在重复 ruleId: {rid}")
            seen_rid.add(rid)
            if r.get("vague") is True and not data.get("openIssues"):
                err(f"{ex.name} 规则 {rid} 标 vague=true 但本片没有对应 openIssue")
            detail.setdefault(cid, []).append(rid)
        no_src = sum(1 for r_ in (data.get("rules") or []) if not r_.get("sourceSection"))
        if no_src:
            warn(f"{ex.name} 有 {no_src} 条规则未标 sourceSection,拆分时无法回查原文出处")
        for nfr in data.get("nfrs", []) or []:
            if not nfr.get("sourceSection"):
                warn(f"{ex.name} 有 nfr 未标 sourceSection,无法追溯详设出处")
            if nfr.get("dimension") == "other" and not nfr.get("subDimension"):
                err(f"{ex.name} nfr 标 dimension=other 但未填 subDimension,等于没说是什么维度")
        for a in data.get("apis", []) or []:
            if not a.get("sourceSection"):
                warn(f"{ex.name} 接口 {a.get('path')} 未标 sourceSection,写契约时找不回原文字段表")
            if a.get("unresolved"):
                if a.get("method") != "UNKNOWN":
                    err(f"{ex.name} 接口 {a.get('path')} 标 unresolved 但 method 不是 UNKNOWN")
                if not data.get("openIssues"):
                    err(f"{ex.name} 接口 {a.get('path')} 标 unresolved 却本片无 openIssue:"
                        "method/path 取不到要显式挂待定,静默缺字段到写契约时才会变成编造")
        for r in rules:
            sid = r.get("sourceRuleId")
            if sid:
                sid = str(sid).strip()
                src_rule_ids.add(sid)
                sid_map.setdefault(sid, set()).add(r.get("ruleId"))
        for t in data.get("tables", []) or []:
            tname = (t.get("name") or "").strip().lower()
            cols = twin_tables.setdefault(tname, {})
            for f in t.get("fields", []) or []:
                col, typ, has_len = _field_head(f)
                if col and typ in CHAR_TYPES and not has_len:
                    # R-J:字符字段无长度,解析检查(新开工)即红;既有产物回跑只警告不追溯
                    msg = (f"{ex.name} 表 {t.get('name')} 字段 {col} 为字符类型({typ})未带长度"
                           f"——详设须明确长度或登记 Q 说明口径")
                    (err if stage == "parse" else warn)(msg)
                if col:
                    cols[col.lower()] = f
        for a in data.get("acceptances", []) or []:
            # bound 不在片内算:追溯矩阵与规则表常不在同一片,须等全部片读完后用全局 sid_map 解析
            accs.append((cid, a))
            if not a.get("sourceSection"):
                warn(f"{ex.name} 验收点 {a.get('acceptanceId')} 未标 sourceSection,无法回查原文")
    if stage == "parse":
        missing = [c for c in plan_ids if c not in extract_ids]
        if missing:
            err(f"chunk-plan 中 {missing} 缺少对应 extract 文件(分片未抽完,禁止拆分)")
        for c in extract_ids:
            if plan_ids and c not in plan_ids:
                warn(f"extract {c} 不在 chunk-plan 中,可能是废片")
    return raw, detail, accs, src_rule_ids, sid_map, twin_tables


def check_parse_report(specs, raw, stage):
    """解析报告七项计数与抽取件实际条数对账,防"漏抽/漏统计"。"""
    path = specs / "_work" / "parse-report.json"
    rep = load_json(path, required=stage == "parse")
    if rep is None:
        return None, None
    schema_validate("parse-report", rep, "parse-report.json")
    # 三表对账产物检查(先例 Q011/Q013/Q017,详设组合性矛盾须 parse 期暴露)
    conflicts = rep.get("conflicts") or []
    oq = load_json(specs / "open-questions.json") or {}
    q_ids = {q.get("id") for q in oq.get("questions", [])}
    for c in conflicts:
        ref = next((q for q in (q_ids or set()) if q in str(c)), None)
        if ref is None:
            err(f"parse-report.conflicts 含未关联 Q 的条目:{c}——冲突必须接 Q 机制,禁止直接放行")
    if not conflicts and stage == "parse":
        notes = str(rep.get("notes") or "")
        if "三表对账" not in notes and "机械校验" not in notes:
            warn("parse-report.conflicts 为空且 notes 未声明已跑「三表对账」机械校验——"
                 "请确认枚举长度/字段差集/唯一索引×逻辑删除互斥三项已逐表核对(step1 §5)")
    counts = rep.get("counts", {}) or {}
    raw_counts = rep.get("rawCounts", {}) or {}
    for k in raw:
        declared = raw_counts.get(k)
        if declared != raw[k]:
            err(f"parse-report.rawCounts.{k}={declared} 与抽取件实际 {raw[k]} 不符(有漏抽或漏统计)")
    for k in raw:
        merged = counts.get(k)
        if k in raw_counts and merged is not None and merged > raw_counts[k]:
            err(f"parse-report.counts.{k}={merged} 大于原始 {raw_counts[k]},去重不可能变多")
    if counts.get("rules", 0) == 0:
        err("parse-report.counts.rules=0:详设有业务规则却一条未抽取,解析未完成")
    arch = rep.get("architecture", {}) or {}
    style = arch.get("style")
    if style == "microservices" and len(arch.get("services", []) or []) < 2:
        err("architecture.style=microservices 但 services 不足 2 个(微服务形态需列出服务清单)")
    if style == "monolith" and arch.get("services"):
        warn("architecture.style=monolith 却填了 services:单体形态应填 modules,服务清单留空")
    if style == "monolith" and not arch.get("modules"):
        err("architecture.style=monolith 需填 modules(单体内部业务模块清单),供守卫方案生成模块隔离守卫")
    # 总分文档登记对账:每片的 doc 必须列进本次解析范围,否则只认一份文档就会漏拆整套
    docs = set(rep.get("docs") or [])
    if rep.get("source"):
        docs.add(rep["source"])
    plan = load_json(specs / "_work" / "chunk-plan.json")
    if isinstance(plan, list):
        for c in plan:
            if not isinstance(c, dict):
                continue
            if c.get("doc") and c["doc"] not in docs:
                err(f"chunk-plan {c.get('chunkId')} 的 doc「{c['doc']}」不在 parse-report 的 source/docs 清单里"
                    f"(总分结构详设要把每份文档都登记进 docs,不然没人发现漏了一整份)")
            s, e = c.get("startLine"), c.get("endLine")
            if s and e and e < s:
                err(f"chunk-plan {c.get('chunkId')} 的 startLine({s}) 大于 endLine({e})")
    return arch, rep


def check_arch_consistent(arch_rep, arch_fl, stage):
    if not arch_rep or not arch_fl or stage is None:
        return
    if arch_rep.get("style") != arch_fl:
        err(f"架构形态不一致:parse-report={arch_rep.get('style')} vs feature-list={arch_fl}(以详设为准,二选一改齐)")

def check_rule_ledger(specs, stage, feature_ids, q_ids, specs_by_fid):
    """规则→feature 对账:每条抽取规则必须有去向;assigned 的必须能追到 spec 规则(g2/p5)。"""
    ledger_path = specs / "_work" / "rule-ledger.json"
    ledger = load_json(ledger_path, required=stage in ("list", "spec", "start"))
    if ledger is None:
        return
    schema_validate("rule-ledger", ledger, "rule-ledger.json")
    extract_rules = []
    extract_keys = set()
    work_dir = specs / "_work"
    for ex in sorted(work_dir.glob("extract-*.json")):
        data = load_json(ex)
        if not data:
            continue
        cid = data.get("chunkId", "")
        for i, r in enumerate(data.get("rules", []) or [], 1):
            rid = r.get("ruleId") or f"{cid}-R{i:02d}"
            if (cid, rid) in extract_keys:
                err("抽取件 %s 存在重复 ruleId: %s" % (ex.name, rid))
            extract_keys.add((cid, rid))
            extract_rules.append((cid, rid))
    entries = ledger.get("entries", [])
    seen = {}
    assigned_map = {}  # ruleId -> featureId,验收点覆盖推导用
    for e in entries:
        key = (e.get("chunkId"), e.get("ruleId"))
        if key in seen:
            err(f"rule-ledger 重复条目: {key[0]}#{key[1]}")
        seen[key] = e
        disp = e.get("disposition")
        tag = f"rule-ledger {key[0]}#{key[1]}"
        if disp == "assigned":
            fid = e.get("feature")
            if not fid:
                err(f"{tag} disposition=assigned 但缺 feature")
            elif feature_ids and fid not in feature_ids:
                err(f"{tag} 分派到不存在的 feature {fid}")
            if fid:
                assigned_map[str(e.get("ruleId"))] = fid
        elif disp == "pending":
            qr = e.get("qRef")
            if not qr:
                err(f"{tag} disposition=pending 但缺 qRef")
            elif q_ids and qr not in q_ids:
                err(f"{tag} 引用不存在的 {qr}")
            if not e.get("note"):
                err(f"{tag} disposition=pending 缺 note")
        elif disp == "deferred":
            if not e.get("note"):
                err(f"{tag} disposition=deferred 缺 note")
            if not e.get("feature"):
                err(f"{tag} disposition=deferred 缺 feature(暂缓要写明随哪个 feature 细分)")
        elif disp == "out-of-scope":
            if not e.get("note"):
                err(f"{tag} disposition=out-of-scope 缺 note(必须写清为何不属本次范围)")
            if e.get("feature"):
                err(f"{tag} disposition=out-of-scope 不应再指向具体 feature")
        elif disp == "constitution":
            if not e.get("note"):
                err(f"{tag} disposition=constitution 缺 note:横切规则要写明归到章程哪一节,不然等于没人认领")
            elif "§" not in str(e.get("note")):
                warn(f"{tag} 标 constitution 但 note 未指向章程具体章节(写 §N),交付确认时无法核对条文已落地")
            if e.get("strength") not in ("测试", "评审", "约定"):
                err(f"{tag} disposition=constitution 需 strength 为 测试/评审/约定:"  # 与章程强度标记同源
                    "横切规则不标强度就没人知道它靠什么执行")
            if e.get("feature"):
                err(f"{tag} disposition=constitution 不应再指向具体 feature(横切规则不属单个交付物)")
        else:
            err(f"{tag} 非法 disposition: {disp!r}")
    for c, r in [k for k in extract_rules if k not in seen][:20]:
        err(f"rule-ledger 缺条目: {c}#{r}(抽取件规则悬空,必须分派/暂缓/待决)")
    missing_total = len([k for k in extract_rules if k not in seen])
    if missing_total > 20:
        err(f"rule-ledger 共缺 {missing_total} 条(仅列出前 20)")
    extract_set = set(extract_rules)
    for c, r in [k for k in seen if k not in extract_set][:10]:
        err(f"rule-ledger 条目 {c}#{r} 在抽取件中不存在(台账键必须原样取自抽取件)")
    # 正向落地下钻:已分派给"已展开 spec 的 feature"的规则,必须在该 spec 中可追溯
    for (c, r), e in seen.items():
        if e.get("disposition") != "assigned":
            continue
        fid = e.get("feature")
        info = specs_by_fid.get(fid)
        if not info:
            continue
        traced = info["traced"]
        if not traced:
            warn(f"{fid} 的 spec 规则未填 sourceRules 追溯抽取件规则,台账无法核对落地")
            continue
        if r not in traced:
            err(f"规则 {c}#{r} 台账标 assigned->{fid},但 {fid} 的 spec 无任何规则以 sourceRules 追溯到它(分派后丢失)")
    if stage == "start":
        for c, r in [k for k, e in seen.items() if e.get("disposition") == "pending"][:20]:
            err(f"开工放行要求无 pending: rule-ledger {c}#{r} 仍为待裁决")
    return assigned_map


# ---------------------------------------------------------------- 验收点对账

TOK_RULE = re.compile(r"^[A-Za-z]{0,4}\d{1,3}$")  # 原文规则编号形态(R1/GR02/T2)


def check_acceptance(rep, accs, src_rule_ids, sid_map, detail, assigned_map, specs_by_fid, stage):
    """验收点对账三件事:
    1) 详设声明的验收分母必须全抽到(漏抽即红);
    2) 追溯矩阵引用的规则编号必须真实存在(指向漏抽规则即红);
    3) 已分派给首批 feature 的规则,其所属验收点必须被该 feature 的 spec 声明覆盖。"""
    gate = (rep or {}).get("acceptance") or {}
    dec = gate.get("declared")
    if not accs:
        if isinstance(dec, int) and dec > 0:
            err(f"parse-report 声明应有 {dec} 个验收点,抽取件却一条 acceptances 未抽——验收分母完全缺失")
        return
    ids = [a.get("acceptanceId") for _, a in accs]
    uniq = {i for i in ids if i}
    if len(ids) != len(uniq):
        err(f"抽取件验收点编号跨片重复: {sorted({i for i in ids if ids.count(i) > 1})}(合并未去重)")
    if isinstance(dec, int):
        if len(uniq) < dec:
            err(f"详设声明 {dec} 个验收点({gate.get('evidence') or '未注出处'}),实际只抽到 {len(uniq)} 个,"
                f"漏 {dec - len(uniq)} 个——验收分母不能缺")
        elif len(uniq) > dec:
            warn(f"抽到 {len(uniq)} 个验收点多于详设声明的 {dec} 个:确认是否把测试用例逐条当验收点重复计数")
    else:
        warn("抽到了验收点但 parse-report.acceptance.declared 未填分母,无法判断是否漏抽;"
             "详设有验收章节/追溯矩阵时必须填")
    known = set(src_rule_ids)
    for rids in detail.values():
        known |= set(rids)
    for cid, a in accs:
        for ref in a.get("ruleRefs", []) or []:
            for tok in re.split(r"[、,;/\s()（）]+", str(ref)):
                if TOK_RULE.match(tok) and tok not in known:
                    err(f"验收点 {a.get('acceptanceId')}({cid}) 的追溯矩阵引用规则 {tok},"
                        f"但没有任何抽取件有此编号——该规则被漏抽或原文编号未原样照抄到 sourceRuleId")
    if stage not in ("spec", "start"):
        return
    all_covers = set()
    for info in specs_by_fid.values():
        all_covers |= info.get("covers", set())
    bogus = all_covers - uniq
    if bogus:
        err(f"spec 的 coversAcceptances 引用了抽取件中不存在的验收点: {sorted(bogus)[:10]}")
    for _cid, a in accs:
        bound = set()
        for ref in a.get("ruleRefs", []) or []:
            for tok in re.split(r"[、,;/\s()（）]+", str(ref)):
                if tok in sid_map:
                    bound |= sid_map[tok]
                elif RULE_ID_REF.match(tok):
                    bound.add(tok)
        aid = a.get("acceptanceId")
        fids = {assigned_map[r] for r in bound if r in assigned_map}
        for fid in sorted(fids):
            info = specs_by_fid.get(fid)
            if info and aid not in info.get("covers", set()):
                err(f"验收点 {aid} 关联的规则已分派给 {fid},但 {info['dir']} 的 spec 未在"
                    f" coversAcceptances 声明它——该 feature 做完也证明不了这条验收过")


# ---------------------------------------------------------------- spec

def check_spec_dir(spec_dir, data, feature_ids, q_ids, feature_deps, stage, q_info=None, twin_tables=None):
    where = spec_dir.name
    fid = data.get("id", "")
    # (WARN) 任务清单含前端交付但验收步骤全是接口/后端口径时,
    # 提示人工复核「首屏初始态入口链路走查」是否被遗漏(案例:casebook#首屏链路断裂,见 step3 自查补充)。
    _tasks_text = " ".join(t.get("desc", "") for t in data.get("tasks", []))
    _steps_text = " ".join(a.get("steps", "") for a in data.get("acceptances", []))
    if data.get("status") in ("草案", "已确认") and re.search(
            r"前端|页面|视图|vue|组件", _tasks_text, re.I) and not re.search(
            r"入口|选中|点击|首屏|页面|视图|抽屉|弹窗", _steps_text):
        warn(f"[{where}] 任务清单含前端交付,但验收步骤未见任何页面/入口/选中类操作描述——"
             f"请确认「首屏初始态入口链路走查」未被接口级验证替代(step3 自查补充)")
    # (WARN) tables 含 UNIQUE 约束且规则/任务含「重建/删旧插新」语义,
    # 但解释性决定清单未裁决唯一索引×逻辑删除互斥口径时提示(先例 Q018,见 casebook#唯一索引逻辑删除互斥)。
    _tables_text = " ".join(" ".join(t.get("fields", [])) + " " + " ".join(t.get("indexes", []))
                            for t in data.get("tables", []))
    _rules_text = " ".join(r.get("text", "") for r in data.get("rules", []))
    _decisions_text = " ".join(d.get("understanding", "") + d.get("basis", "")
                               for d in data.get("interpretiveDecisions", []))
    if (data.get("status") in ("草案", "已确认")
            and "UNIQUE" in _tables_text.upper()
            and re.search(r"重建|删旧插新|删除后可重|物理删除", _rules_text + _tasks_text)
            and not re.search(r"物理删除|唯一键|deleted 列|NO_LOGIC_DELETE", _decisions_text)):
        warn(f"[{where}] 表含 UNIQUE 约束且存在『重建/删旧插新』语义,但未裁决唯一索引×逻辑删除"
             f"互斥口径——请在解释性决定清单三选一(物理删除特例/唯一键纳入 deleted/不允许重建)"
             f"(step2『删了重插』对账,先例 Q017/Q018)")
    # (WARN,复盘 2026-09-19 建议#4)表含 UNIQUE 索引且字段含逻辑删除列,即使规则文本无
    # 「重建」语义也提示裁决——实现期并发 insert 撞唯一键是同型事故四连的根因,不依赖文本触发。
    _uniq_and_softdel = ("UNIQUE" in _tables_text.upper()
                         and re.search(r"\b(deleted|is_deleted|del_flag)\b", _tables_text, re.I))
    if (data.get("status") in ("草案", "已确认") and _uniq_and_softdel
            and not re.search(r"唯一|重插|互斥|NO_LOGIC_DELETE", _decisions_text)):
        warn(f"[{where}] 表含 UNIQUE 索引且含逻辑删除列(自动对账):请在解释性决定清单登记"
             f"唯一索引×逻辑删除三选一(物理删除特例/唯一键纳入 deleted/不允许重建)"
             f"(复盘建议#4,先例 Q017/Q018/Q092/Q127)")
    m = SPEC_DIR_NAME.match(spec_dir.name)
    if feature_deps is not None and fid in feature_deps:
        sp_deps, fl_deps = set(data.get("deps", [])), set(feature_deps[fid])
        if sp_deps != fl_deps:
            err(f"[{where}] spec.deps {sorted(sp_deps)} 与 feature-list.deps {sorted(fl_deps)} 不一致")
    if data.get("boundary") and not any(k in data["boundary"] for k in ("不", "not ")):
        warn(f"[{where}] boundary 疑似只写「做什么」")
    rules = data.get("rules", [])
    rule_ids = {r.get("id") for r in rules}
    fid_self = data.get("id") or (where.split("/")[0] if "/" in where else "")
    for r in rules:
        for q in sorted(collect_rule_q_refs(r)):
            if q_ids is not None and q not in q_ids:
                err(f"[{where}] {r.get('id')} 引用未登记的问题 {q}")
            elif q_info is not None:
                qf = q_info.get(q, {}).get("features") or []
                deps_of_fid = feature_deps.get(fid_self, set()) if feature_deps else set()
                if qf and fid_self not in qf and not (deps_of_fid & set(qf)):
                    warn(f"[{where}] {r.get('id')} 引用的 {q} 归属 {sorted(qf)},与本 feature {fid_self} 及其依赖无交集——"
                         f"回读该 Q 语义确认无冲突(Q 冲突扫描)")
        for sr in r.get("sourceRules", []):
            if not RULE_ID_REF.match(str(sr)):
                err(f"[{where}] {r.get('id')} 的 sourceRules「{sr}」格式应为 Cxx-Rnn")
    check_rules_text(rules, where)
    # (WARN,复盘 2026-09-19 建议#8)spec.md 与 spec.json 交叉同步检查:
    # json 里每条规则 id 与验收 id 必须在 md 出现(md 为人读派生视图,失手即漂移)。
    _md_path = spec_dir / "spec.md"
    if _md_path.exists():
        _md_text = _md_path.read_text(encoding="utf-8", errors="ignore")
        _missing_a = [a.get("id") for a in data.get("acceptances", [])
                      if a.get("id") and a["id"] not in _md_text]
        _missing_r = [r.get("id") for r in rules
                      if r.get("id") and r["id"] not in _md_text]
        if _missing_a:
            warn(f"[{where}] spec.md 验收表缺 {len(_missing_a)} 条: {','.join(_missing_a)}(md/json 不同源漂移)")
        if _missing_r:
            warn(f"[{where}] spec.md 规则表缺 {len(_missing_r)} 条: {','.join(_missing_r)}(md/json 不同源漂移)")
    for a in data.get("apis", []):
        for rr in a.get("ruleRefs", []):
            if rule_ids and rr not in rule_ids:
                err(f"[{where}] 接口 {a.get('method')} {a.get('path')} 引用不存在的规则 {rr}")
        if not a.get("ruleRefs"):
            warn(f"[{where}] 接口 {a.get('path')} 未关联任何规则,确认是纯查询还是漏标")
    check_api_fields(data, where)
    if twin_tables:
        check_spec_tables_fields(data, twin_tables, q_ids, where)
    acc_refs = set()
    local_covers = set()
    for n in data.get("nfrs", []) or []:
        if n.get("dimension") == "other" and not n.get("subDimension"):
            err(f"[{where}] nfr 标 dimension=other 但未填 subDimension,等于没说是什么维度")
        if not n.get("source"):
            warn(f"[{where}] nfr {n.get('dimension')} 未标 source 出处,无法追溯详设/推断依据")
    for a in data.get("acceptances", []):
        ref = a.get("ref", "")
        acc_refs.add(ref.split(":")[-1] if ref.startswith("API:") else ref)
        local_covers |= {str(x) for x in (a.get("covers") or [])}
        if ref.startswith("API:"):
            continue
        if rule_ids and ref not in rule_ids:
            err(f"[{where}] 验收 {a.get('id')} 引用不存在的规则 {ref}")
    declared_covers = {str(x) for x in (data.get("coversAcceptances") or [])}
    if declared_covers != local_covers:
        err(f"[{where}] coversAcceptances 与 acceptances[].covers 的并集不一致:"
            f"声明 {sorted(declared_covers)} vs 用例实际 {sorted(local_covers)}(覆盖不能口头声称)")
    uncovered = {r.get("id") for r in rules} - acc_refs
    if uncovered:
        err(f"[{where}] 规则无验收用例覆盖: {sorted(uncovered)}")
    task_ids = [t.get("id") for t in data.get("tasks", [])]
    if len(task_ids) != len(set(task_ids)):
        err(f"[{where}] 任务编号重复")
    status = data.get("status")
    if status in SPEC_APPROVED and status != "草案":
        for k in ("approvedBy", "approvedAt"):
            if not data.get(k):
                err(f"[{where}] status={status} 但缺 {k}(spec 确认缺凭据)")
    oa_checked = check_openapi_in_spec(spec_dir, data, where)
    md = spec_dir / "spec.md"
    if md.exists():
        check_md_json_sync(md, data, where, oa_checked)
    return {
        "traced": {sr for r in rules for sr in r.get("sourceRules", [])},
        "rule_ids": rule_ids,
        "covers": {str(x) for x in (data.get("coversAcceptances") or [])},  # 本 feature 覆盖的详设验收点 ID
        "status": status,
        "dir": spec_dir.name,
    }


def check_api_fields(data, where):
    """红线「接口字段有类型和示例」的机器化:字段清单在 json 里登记,或契约外置到 openapi.yaml。"""
    has_oa = bool(data.get("openApi"))
    for a in data.get("apis", []):
        label = f"{a.get('method')} {a.get('path')}"
        # 内联登记在 json 里的字段一律要 example,不受 openApi 影响(见 _check_field)
        for fld in a.get("requestFields", []) or []:
            _check_field(fld, where, label, "入参")
        for fld in a.get("responseFields", []) or []:
            _check_field(fld, where, label, "出参")
        if not a.get("responseFields") and not has_oa:
            err(f"[{where}] 接口 {label} 无 responseFields 也未挂 openapi.yaml:字段类型/示例无处落地")
        if not a.get("requestFields") and not a.get("noRequest") and not has_oa:
            err(f"[{where}] 接口 {label} 既无入参字段也未标 noRequest=true")
        for ec in a.get("errorCodes", []) or []:
            if not all([ec.get("code"), ec.get("message"), ec.get("when")]):
                err(f"[{where}] 接口 {label} 错误码条目需 code/message/when 三项齐全")


def _check_field(fld, where, label, kind):
    """内联登记在 spec.json 的 requestFields/responseFields 里的字段:只要写了这条字段,
    example 就必须有。openApi 外置契约只豁免「接口必须列字段数组」,不豁免「已列字段的示例」——
    否则挂了一份 openapi.yaml 就会把其余内联字段的示例检查一起免掉。"""
    missing = [k for k in ("name", "type") if not fld.get(k)]
    if missing:
        err(f"[{where}] 接口 {label} {kind}字段缺 {'/'.join(missing)}")
        return
    if fld.get("example") in (None, ""):
        err(f"[{where}] 接口 {label} {kind}字段 {fld.get('name')} 缺 example(红线:接口字段要有示例)")


def check_openapi_in_spec(spec_dir, data, where):
    oa = data.get("openApi")
    if not oa:
        return False
    oa_path = spec_dir / oa
    if not oa_path.exists():
        err(f"[{where}] 声明了 {oa} 但文件不存在")
        return True
    text = oa_path.read_text(encoding="utf-8")
    try:
        import yaml
        doc = yaml.safe_load(text)
    except ImportError:
        doc = None
    except Exception as e:
        err(f"[{where}] {oa} 解析失败: {e}")
        return True
    if doc is None:
        if "openapi: 3" not in text:
            err(f"[{where}] {oa} 缺少 openapi: 3.x 版本声明")
        warn(f"[{where}] 未装 pyyaml,{oa} 只做了版本声明检查")
        return True
    check_openapi(doc, where)
    return True


def check_openapi(doc, where):
    if not isinstance(doc, dict) or not str(doc.get("openapi", "")).startswith("3"):
        err(f"[{where}] openapi 文件版本必须为 3.x")
        return
    paths = doc.get("paths")
    if not paths:
        err(f"[{where}] openapi paths 为空")
        return
    for p, ops in paths.items():
        if not isinstance(ops, dict) or not ops:
            err(f"[{where}] openapi path {p} 没有任何操作")
            continue
        for m, op in ops.items():
            if m.startswith("x-") or m == "parameters":
                continue
            if not isinstance(op, dict) or "responses" not in op:
                err(f"[{where}] openapi {m.upper()} {p} 缺少 responses")


def check_md_json_sync(md_path, data, where, has_openapi):
    text = md_path.read_text(encoding="utf-8")
    name = data.get("name", "")
    if name and name not in text:
        err(f"[{where}] spec.md 未包含 json 中的 name「{name}」,md/json 可能不同源")
    for r in data.get("rules", []):
        rid = r.get("id", "")
        if rid and not re.search(rf"\b{re.escape(rid)}\b", text):
            err(f"[{where}] spec.md 缺少 json 中登记的规则 {rid}")
    for t in data.get("tables", []):
        tname = t.get("name", "")
        if tname and tname not in text:
            err(f"[{where}] spec.md 缺少 json 中登记的表 {tname}")
    for a in data.get("apis", []):
        p = a.get("path", "")
        if p and p not in text:
            msg = f"[{where}] spec.md 缺少 json 中登记的接口 {p}"
            err(msg + "(md/json 不同源)" if not has_openapi else msg + "(契约已外置 openapi.yaml,md 至少保留接口摘要表)")


# ---------------------------------------------------------------- 章程 / 守卫方案

def declared_arch(path):
    """从文档的「架构形态:」行读出形态;模板占位未消歧返回 AMBIGUOUS。"""
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.search(r"架构形态\s*[:：]\s*(.+)$", line)
        if not m:
            continue
        v = m.group(1)
        mono = ("单体" in v) or ("monolith" in v.lower())
        micro = ("微服务" in v) or ("microservices" in v.lower()) or ("cloud" in v.lower())
        if mono and micro:
            return "AMBIGUOUS"
        if mono:
            return "monolith"
        if micro:
            return "microservices"
    return None


def check_constitution(path, arch, stage):
    check_sections_against_template(path, TEMPLATE_DIR / "constitution.template.md", "constitution.md")
    text = path.read_text(encoding="utf-8")
    if "[测试]" not in text:
        warn("constitution.md 没有任何 [测试] 强度规则,请确认是否漏标")
    for line in text.splitlines():
        if "待定" in line and not re.search(r"Q\d{3}", line):
            err(f"constitution.md 待定项未登记 Q: {line.strip()[:60]}")
    declared = declared_arch(path)
    if declared == "AMBIGUOUS":
        err("constitution.md 的「架构形态:」行未消歧(单体/微服务只能留一个)")
    elif arch and declared and declared != arch:
        err(f"constitution.md 架构形态「{declared}」与 feature-list.architecture={arch} 不一致")
    if arch == "monolith" and "Feign" in text and "不适用" not in text:
        warn("constitution.md 含 Feign 条款但形态为单体:确认是否应改为进程内调用/模块边界表述")


def check_guard_setup(path, arch):
    check_sections_against_template(path, TEMPLATE_DIR / "guard-tests-setup.template.md", "guard-tests-setup.md")
    text = path.read_text(encoding="utf-8")
    if "未实跑" not in text and not ("正向" in text and "反向" in text):
        err("guard-tests-setup.md 缺少验证记录(需含 正向/反向 结果,或明确标注 未实跑)")
    if "已验证" in text and "未实跑" in text:
        err("guard-tests-setup.md 同时出现「已验证」与「未实跑」,验证结论自相矛盾")
    declared = declared_arch(path)
    if not declared:
        err("guard-tests-setup.md 必须标注「架构形态:单体」或「架构形态:微服务」(供守卫形态选型)")
    elif declared == "AMBIGUOUS":
        err("guard-tests-setup.md 的「架构形态:」行未消歧(单体/微服务只能留一个)")
    elif arch and declared != arch:
        err(f"guard-tests-setup.md 架构形态「{declared}」与 feature-list.architecture={arch} 不一致")
    if arch == "microservices" and "服务隔离" not in text:
        err("微服务形态的守卫方案缺「服务隔离」守卫(跨服务 internal 包禁止依赖)")
    if arch == "monolith" and "模块隔离" not in text:
        err("单体形态的守卫方案缺「模块隔离」守卫(跨业务模块 internal 包禁止依赖)")


# ---------------------------------------------------------------- 阶段必需文件

def required_files(stage):
    if stage is None:
        return []
    need = []
    if STAGE_ORDER[stage] >= STAGE_ORDER["parse"]:
        need += ["_work/chunk-plan.json", "_work/parse-report.json"]
    if STAGE_ORDER[stage] >= STAGE_ORDER["list"]:
        need += ["feature-list.json", "feature-list.md", "open-questions.json",
                 "open-questions.md", "_work/rule-ledger.json"]
    if STAGE_ORDER[stage] >= STAGE_ORDER["start"]:
        need += ["constitution.md", "guard-tests-setup.md"]
    return need


def check_required_files(specs, stage):
    for f in required_files(stage):
        if not (specs / f).exists():
            err(f"{stage} 阶段必需: {f}")


def check_first_batch_specs(specs, first_ids, stage, feature_ids, q_ids, feature_deps, q_info=None, twin_tables=None):
    """扫描 specs/ 下全部 F 编号目录;返回 {fid: spec 摘要}。台账落地对账靠它。"""
    # 关口委托批量模式(R-I):gate-delegation.json 存在且 batchAutoAdvance=true 时,
    # 允许非首批 spec 目录存在(仍逐个做结构与红线校验);文件不存在则维持原 R-D 报错。
    batch_mode = False
    deleg_path = specs / "_work" / "gate-delegation.json"
    if deleg_path.exists():
        try:
            with open(deleg_path, encoding="utf-8") as fh:
                batch_mode = bool((json.load(fh) or {}).get("batchAutoAdvance"))
        except (ValueError, OSError):
            pass
    by_fid = {}
    for d in sorted(specs.iterdir()):
        m = SPEC_DIR_NAME.match(d.name) if d.is_dir() else None
        if not m:
            continue
        fid = m.group(1)
        sp = load_json(d / "spec.json")
        if sp is None:
            if (d / "spec.md").exists():
                err(f"{d.name}/spec.md 存在但缺 spec.json(json twin 是校验唯一依据)")
            continue
        schema_validate("spec", sp, f"{d.name}/spec.json")
        by_fid[fid] = check_spec_dir(d, sp, feature_ids, q_ids, feature_deps, stage, q_info=q_info if isinstance(q_ids, set) else None, twin_tables=twin_tables)
        if stage in ("spec", "start") and fid not in first_ids:
            if batch_mode:
                print(f"[INFO] {d.name} 非首批已生成 spec(委托批量模式放行)")
            else:
                err(f"{d.name} 不是首批却已生成 spec(违反一次只展开首批)")
    if stage in ("spec", "start"):
        for fid in sorted(first_ids):
            if fid not in by_fid:
                err(f"{stage} 阶段必需: 首批 {fid} 的 spec.json/spec.md")
    return by_fid


def specs_main(argv=None):
    parser = argparse.ArgumentParser(
        prog="sdd.py", description="SDD 守门引擎(解析/清单/spec/开工放行)", add_help=True)
    parser.add_argument("specs", help="specs 目录路径")
    parser.add_argument("--stage", choices=STAGES, default=None,
                        help="当前关口阶段;不传则只校验已存在的文件")
    parser.add_argument("--strict", action="store_true", help="把 WARN 也视为失败")
    parser.add_argument("--set-status", metavar="F编号", default=None,
                        help="不跑校验,只回写该 spec 状态(配 --status/--by)"),
    parser.add_argument("--status", default=None, help="set-status 的目标状态")
    parser.add_argument("--by", default="user", help="set-status 的确认人(ai-delegated 等)")
    args = parser.parse_args(argv)

    specs = Path(args.specs)
    if not specs.is_dir():
        print(f"specs 目录不存在: {specs}")
        return 2
    if args.set_status:
        if args.status not in ("草案", "已确认"):
            print(f"--status 非法: {args.status!r},此处允许 草案/已确认")
            return 2
        if not F_ID.match(args.set_status):
            print(f"F编号格式应为 F+三位数字,收到: {args.set_status}")
            return 2
        return 0 if set_spec_status(specs, args.set_status, args.status, args.by) else 1
    stage = args.stage
    mode = "jsonschema" if HAS_JSONSCHEMA else "内置加强校验(未装 jsonschema)"
    check_required_files(specs, stage)

    # ---- feature-list ----
    feature_ids, first_ids, arch_fl, feature_deps = set(), set(), None, {}
    fl = load_json(specs / "feature-list.json")
    if fl is None:
        if (specs / "feature-list.json").exists():
            err("feature-list.json 无法解析,feature 关联检查已全部跳过")
    else:
        schema_validate("feature-list", fl, "feature-list.json")
        feature_ids, first_ids, arch_fl = check_feature_list(fl, specs, stage)
        feature_deps = {f.get("id"): set(f.get("deps", [])) for f in fl.get("features", [])}

    # ---- open-questions ----
    q_ids, questions = None, []
    oq = load_json(specs / "open-questions.json")
    if oq is None:
        if (specs / "open-questions.json").exists():
            err("open-questions.json 无法解析,Q 引用闭环检查已全部跳过")
    else:
        schema_validate("open-questions", oq, "open-questions.json")
        q_ids, questions = check_open_questions(oq, feature_ids, stage, specs)
        q_info = {q.get("id"): q for q in questions} if questions else {}
        check_q_range_lock(specs, questions)

    # ---- 解析过程件 ----
    plan_ids = check_chunk_plan(specs, stage)
    raw, extract_detail, accs, src_rule_ids, sid_map, twin_tables = check_extracts(specs, plan_ids, stage)
    arch_rep, rep = check_parse_report(specs, raw, stage)
    check_arch_consistent(arch_rep, arch_fl, stage)

    # ---- spec(需在台账之前拿到 sourceRules 做落地对账)----
    specs_by_fid = check_first_batch_specs(specs, first_ids, stage, feature_ids, q_ids, feature_deps, q_info=q_info, twin_tables=twin_tables)

    # ---- 规则台账 ----
    assigned_map = {}
    if stage in ("list", "spec", "start"):
        assigned_map = check_rule_ledger(specs, stage, feature_ids, q_ids, specs_by_fid) or {}

    # ---- 验收点对账(详设声明的验收分母 → 抽取 → feature 覆盖)----
    check_acceptance(rep, accs, src_rule_ids, sid_map, extract_detail, assigned_map, specs_by_fid, stage)

    # ---- 章程 / 守卫方案 ----
    arch = arch_fl or (arch_rep or {}).get("style")
    cpath = specs / "constitution.md"
    if cpath.exists():
        check_constitution(cpath, arch, stage)
    gpath = specs / "guard-tests-setup.md"
    if gpath.exists():
        check_guard_setup(gpath, arch)

    # ---- 关口状态联动 ----
    if stage == "spec" and fl is not None and fl.get("status") != "已确认":
        err(f"spec 确认阶段要求 feature-list.status 为 已确认,当前为 {fl.get('status')!r}(清单确认未通过?)")
    if stage == "start":
        if fl is not None and fl.get("status") != "已确认":
            err(f"开工放行阶段要求 feature-list.status 为 已确认,当前为 {fl.get('status')!r}")
        for fid in sorted(first_ids):
            info = specs_by_fid.get(fid)
            if info and info["status"] not in SPEC_APPROVED:
                err(f"开工放行要求首批 {info['dir']} 的 spec.status 已过 spec 确认,当前为 {info['status']!r}")
        for q in questions:
            if q.get("blocking") == "high" and q.get("status") != "已关闭" \
                    and first_ids & set(q.get("features", [])):
                err(f"{q.get('id')} 为高阻塞且影响首批,状态未 closed,禁止带阻开工")

    # ---- 汇总 ----
    if not HAS_JSONSCHEMA:
        warn("环境未装 jsonschema,走内置加强校验;结论与 Schema 模式可能有细微差异,正式关口建议 pip install jsonschema")
    return summarize(f"== SDD 产物校验 | specs={specs} | stage={stage or 'any'} | 模式={mode} ==",
                     strict=args.strict)

# ==========================================================================
# 实现段(开工/交付/呈报/收尾)
# ==========================================================================

VALID_STAGES = {"begin", "deliver", "report", "done", "set-status"}
ALLOWED_SPEC_STATUS = {"草案", "已确认", "实现中", "已交付"}


def _impl_load_json(path):
    """本脚本调用点均视缺失为 ERROR,统一 required=True 语义。"""
    return _load_json(path, required=True)


def load_spec(specs, fid):
    """返回 (spec_dir, spec数据 或 None)。"""
    spec_dir = find_spec_dir(specs, fid)
    if spec_dir is None:
        err(f"找不到 spec 目录: {fid}-*")
        return None, None
    return spec_dir, _impl_load_json(spec_dir / "spec.json")


def check_impl_config(specs):
    cfg = _impl_load_json(specs / "impl-config.json")
    if cfg is None:
        err("缺少 specs/impl-config.json(开工登记 阶段生成)")
        return None
    if not isinstance(cfg.get("searchDirs"), list) or not cfg["searchDirs"]:
        err("impl-config.searchDirs 必须是非空数组(相对仓库根,源码检索范围)")
    if not isinstance(cfg.get("fileExts"), list) or not cfg["fileExts"]:
        err("impl-config.fileExts 必须是非空数组(检索的文件扩展名)")
    for key in ("buildCommands", "testCommands"):
        cmds = cfg.get(key, [])
        if not isinstance(cmds, list):
            err(f"impl-config.{key} 必须是数组")
            continue
        if key == "buildCommands" and not cmds:
            err("impl-config.buildCommands 不能为空(至少一条编译命令)")
        for c in cmds:
            if not (isinstance(c, dict) and c.get("name") and c.get("cmd")):
                err(f"impl-config.{key} 中每条命令必须有 name 和 cmd: {c!r}")
    names = [c.get("name") for c in cfg.get("buildCommands", []) + cfg.get("testCommands", []) if isinstance(c, dict)]
    if len(names) != len(set(names)):
        err("impl-config 命令 name 重复")
    return cfg


def check_blocking_qs(specs, feature_ids):
    """返回未关闭的高阻塞 Q 中影响指定 feature 的清单。"""
    oq = _impl_load_json(specs / "open-questions.json")
    if oq is None:
        err("缺少 open-questions.json")
        return
    ids_seen = set()
    for q in oq.get("questions", []):
        qid = q.get("id")
        ids_seen.add(qid)
        blocking = q.get("blocking") == "high"
        open_ = q.get("status") != "已关闭"
        hits = feature_ids & set(q.get("features", []))
        if blocking and open_ and hits:
            err(f"{qid} 高阻塞未关闭,影响 {sorted(hits)},禁止开工/交付")
    if len(ids_seen) != len([q.get("id") for q in oq.get("questions", [])]):
        err("open-questions.json 存在重复 Q 编号")


def check_deps_delivered(specs, features, fid):
    fmap = {f.get("id"): f for f in features}
    if fid not in fmap:
        err(f"{fid} 不在 feature-list.json 中")
        return False
    for d in fmap[fid].get("deps", []):
        _, dspec = load_spec(specs, d)
        status = (dspec or {}).get("status")
        if status != "已交付":
            err(f"依赖 {d} 未 delivered(当前 status={status!r}),不可开工")
    return True


def scan_r_hits(specs, cfg, fid, rules):
    """扫 searchDirs,返回 {rid: [文件路径]}。check_r_annotations 与 report 共用。"""
    hits = {}
    if not cfg:
        return hits
    root = specs.parent
    exts = set(cfg.get("fileExts", []))
    for sd in cfg.get("searchDirs", []):
        base = root / sd
        if not base.is_dir():
            warn(f"searchDir 不存在,跳过: {base}")
            continue
        for p in base.rglob("*"):
            if not p.is_file() or p.suffix not in exts:
                continue
            # 跳过产物/构建目录,避免误报与拖慢
            parts = {seg.lower() for seg in p.parts}
            if parts & {"node_modules", "target", "dist", "build", ".git"}:
                continue
            try:
                text = p.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for rid in rules:
                tag = f"{fid}-{rid}"
                # 文档允许测试用例名用下划线形态(如 shouldX_F003_R2),两种写法都算落点
                if tag in text or tag.replace("-", "_") in text:
                    hits.setdefault(rid, []).append(p.relative_to(root).as_posix())
    return hits


def check_r_annotations(specs, cfg, fid, rules):
    """反查:每条 R 至少一处「F<xxx>-R<n>」标注落在 searchDirs 的源码文件里。"""
    if not cfg:
        return
    hits = scan_r_hits(specs, cfg, fid, rules)
    for rid in rules:
        if rid not in hits:
            err(f"规则 {fid}-{rid} 在源码中没有任何标注落点(需要至少一处「{fid}-{rid}」)")
        else:
            files = hits[rid]
            if len(files) > 5:
                warn(f"规则 {fid}-{rid} 标注出现在 {len(files)} 个文件,确认无凑数标注")
            print(f"  [R落点] {fid}-{rid} -> {files[0]}")


def check_impl_log(specs, fid, cfg):
    """impl 日志:必须登记 impl-config 全部命令名且退出码 0;每条验收 A 有记录。"""
    log_path = specs / "_work" / "impl-logs" / f"{fid}.md"
    if not log_path.exists():
        err(f"缺少实现日志: {log_path.relative_to(specs)}")
        return
    text = log_path.read_text(encoding="utf-8", errors="ignore")
    if cfg:
        for c in cfg.get("buildCommands", []) + cfg.get("testCommands", []):
            name = c.get("name", "")
            m = re.search(rf"{re.escape(name)}.*?(?:exit|退出码|code)\s*[:=]?\s*(\d+)", text, re.IGNORECASE)
            if m is None:
                err(f"impl 日志未登记命令 {name} 的退出码")
            elif m.group(1) != "0":
                err(f"impl 日志记录命令 {name} 退出码非 0: {m.group(1)}")
    # 验收记录:每条 A 编号至少出现一次
    return text


def check_q_placeholder_reconciliation(specs, fid):
    """C1 占位对账:改动目录中 [Qnn] 标注必须已在 open-questions.json 登记。
    扫描范围:impl 日志中登记的"改动文件清单"不总能解析,退化为扫描该 feature 的
    spec 目录引用与 impl 日志中出现的 [Qnn];源码级扫描由 实现 干完自查规则(R-C4)承担。"""
    q_path = specs / "open-questions.json"
    if not q_path.exists():
        return
    try:
        qd = json.loads(q_path.read_text(encoding="utf-8"))
        known = {q.get("id") for q in qd.get("questions", [])}
    except (ValueError, OSError):
        return
    spec_dir = specs / f"{fid}-*"
    candidates = list(specs.glob(f"{fid}-*/**/*")) if specs.is_dir() else []
    referenced = set()
    for f in candidates:
        if f.is_file() and f.suffix in (".md", ".json", ".yaml", ".yml"):
            for m in re.finditer(r"\[(Q\d{2,4})\]", f.read_text(encoding="utf-8", errors="ignore")):
                referenced.add(m.group(1))
    log_path = specs / "_work" / "impl-logs" / f"{fid}.md"
    if log_path.exists():
        for m in re.finditer(r"\[(Q\d{2,4})\]", log_path.read_text(encoding="utf-8", errors="ignore")):
            referenced.add(m.group(1))
    for q in sorted(referenced):
        if q not in known:
            err(f"[{fid}] 占位 {q} 未登记进 open-questions.json(占位对账失败)")


def check_acceptance_log(log_text, spec_dir, fid):
    acc_path = spec_dir / "spec.json"
    data = _impl_load_json(acc_path) if acc_path.exists() else None
    if data is None:
        return
    for a in data.get("acceptances", []):
        aid = a.get("id", "")
        if aid and log_text and aid not in log_text:
            err(f"impl 日志缺少验收用例 {aid}({a.get('ref')})的走查记录")


# ---- L3 接口全量测试对账(分母 = spec apis[] 全集)----
# 每个接口的 method+path 必须在 _work/api-tests/<F编号>/ 下的用例中出现过(文本含
# "METHOD /path" 即认),每条 errorCodes 的 code 必须有反向用例;确不自动化测的接口
# (纯查询被前端冒烟覆盖等)在 _work/api-tests/_exempt.md 逐行登记「METHOD /path 原因」。
# 缺口即红:接口列表都登记了,不允许"没被验收引用的接口"漏出测试体系。

def check_api_test_coverage(specs, fids, label="交付检查"):
    corpus_cache = {}

    def corpus_of(fid):
        if fid not in corpus_cache:
            d = specs / "_work" / "api-tests" / fid
            text = ""
            if d.is_dir():
                text = "\n".join(p.read_text(encoding="utf-8", errors="ignore")
                                 for p in sorted(d.rglob("*")) if p.is_file())
            corpus_cache[fid] = text
        return corpus_cache[fid]

    exempt = ""
    exempt_path = specs / "_work" / "api-tests" / "_exempt.md"
    if exempt_path.exists():
        exempt = exempt_path.read_text(encoding="utf-8", errors="ignore")

    red = False
    for fid in fids:
        spec_dir = find_spec_dir(specs, fid)
        sp = load_json(spec_dir / "spec.json") if spec_dir else None
        apis = (sp or {}).get("apis") or []
        if not apis:
            continue
        # 先剥离全部豁免的接口:全豁免(如存量批次)不要求建目录
        live = [a for a in apis if f"{a.get('method')} {a.get('path')}" not in exempt]
        if not live:
            continue
        base = specs / "_work" / "api-tests" / fid
        if not base.is_dir():
            err(f"[{fid}] 缺 L3 接口测试目录 specs/_work/api-tests/{fid}/"
                f"(待测接口 {len(live)} 个,豁免 {len(apis) - len(live)} 个)")
            red = True
            continue
        text = corpus_of(fid)
        for a in live:
            key = f"{a.get('method')} {a.get('path')}"
            if key not in text:
                err(f"[{fid}] 接口 {key} 无 L3 接口用例(正常路径或 _exempt.md 豁免登记,缺一不可)")
                red = True
            for ec in a.get("errorCodes") or []:
                code = str(ec.get("code", ""))
                if code and code not in exempt and code not in text:
                    err(f"[{fid}] 接口 {key} 错误码 {code} 无反向用例(L3 要求每条 errorCodes 至少一条)")
                    red = True
    return red


# ---- C3 字段口径比对(R-J)----
# 迁移 DDL 的字符列长度/定义与详设抽取件 twin 不一致,且全库 spec 未以 [Qnnn] 登记该偏离 → 红。
# 长度以详设为真源;实现要改口径必须登记 Q,禁止沉默改。
DDL_CHAR_TYPES = {"varchar", "char", "character", "nvarchar", "character varying"}


def _load_ddl_twin(specs):
    """从 _work/extract-*.json 建 {表名小写: {列名小写: 字段定义串}}。无抽取件返回 None。"""
    work = specs / "_work"
    if not work.is_dir():
        return None
    twin = {}
    for ex in sorted(work.glob("extract-*.json")):
        try:
            data = json.loads(ex.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            continue
        for t in data.get("tables", []) or []:
            cols = twin.setdefault((t.get("name") or "").strip().lower(), {})
            for f in t.get("fields", []) or []:
                m = re.match(r"^\s*([A-Za-z_]\w*)\s+", str(f).split("--")[0])
                if m:
                    cols[m.group(1).lower()] = f
    return twin or None


def _load_spec_q_markers(specs):
    """全库 spec.json tables[].fields 中带 [Qnnn] 标注的字段 → {(表名小写, 列名小写): {Q编号}}。"""
    marks = {}
    for sp in sorted(specs.glob("F*-*/spec.json")):
        try:
            data = json.loads(sp.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            continue
        for t in data.get("tables", []) or []:
            tname = (t.get("name") or "").strip().lower()
            for f in t.get("fields", []) or []:
                m = re.match(r"^\s*([A-Za-z_]\w*)\s+", str(f).split("--")[0])
                if not m:
                    continue
                qs = set(Q_MARK.findall(str(f)))
                if qs:
                    marks.setdefault((tname, m.group(1).lower()), set()).update(qs)
    return marks


def check_ddl_vs_twin(specs, cfg):
    """扫 searchDirs 下 db/migration/**/*.sql:按 V 序重放 CREATE TABLE + ALTER TABLE,
    取每列最终态字符长度,与详设 twin 比对。"""
    twin = _load_ddl_twin(specs)
    if twin is None:
        warn("缺少 _work/extract-*.json,跳过 DDL 字段口径比对")
        return
    q_marks = _load_spec_q_markers(specs)
    root = specs.parent
    sql_dirs = [root / sd for sd in (cfg.get("searchDirs", []) if cfg else [])]
    files = []
    seen = set()
    for base in sql_dirs:
        if not base.is_dir():
            continue
        for p in base.rglob("*.sql"):
            if "db" + os.sep + "migration" not in str(p) and "/db/migration/" not in p.as_posix():
                continue
            if p in seen:
                continue
            seen.add(p)
            vm = re.search(r"V(\d+)", p.name)
            files.append(((int(vm.group(1)) if vm else 0), p))
    # 终态表结构:{表: {列: (类型, 长度|None, 来源文件名)}},按 V 序重放
    ddl = {}

    def _set_col(tname, col, typ, dlen, fname):
        if typ.lower() in DDL_CHAR_TYPES:
            ddl.setdefault(tname, {})[col.lower()] = (typ.lower(), dlen, fname)

    for _vnum, p in sorted(files):
        text = p.read_text(encoding="utf-8", errors="ignore")
        for tm in re.finditer(r"CREATE TABLE\s+([A-Za-z_]\w*)\s*\((.*?)\)\s*(?:COMMENT|;|$)",
                              text, re.IGNORECASE | re.DOTALL):
            tname = tm.group(1).lower()
            for line in tm.group(2).splitlines():
                line = line.strip().rstrip(",")
                cm = re.match(r"^([A-Za-z_]\w*)\s+([A-Za-z]+)\s*(\(\s*(\d+)\s*\))?", line)
                if not cm or cm.group(1).upper() in (
                        "CONSTRAINT", "PRIMARY", "UNIQUE", "FOREIGN", "CHECK"):
                    continue
                _set_col(tname, cm.group(1), cm.group(2), cm.group(4), p.name)
        for am in re.finditer(
                r"ALTER TABLE\s+([A-Za-z_]\w*)\s+(?:(?:ADD|ALTER|MODIFY)(?:\s+COLUMN)?\s+)"
                r"([A-Za-z_]\w*)\s+([A-Za-z]+)\s*(\(\s*(\d+)\s*\))?", text, re.IGNORECASE):
            # ADD/ALTER/MODIFY [COLUMN] col TYPE(n);H2 的 ALTER COLUMN 语法同构
            tname, col, typ, dlen = am.group(1).lower(), am.group(2), am.group(3), am.group(5)
            _set_col(tname, col, typ, dlen, p.name)

    for tname, cols in sorted(ddl.items()):
        twin_cols = twin.get(tname)
        if twin_cols is None:
            continue  # 详设没有的表(如 gov_code_seq 新增表)不比对
        for col, (typ, dlen, fname) in sorted(cols.items()):
            tf = twin_cols.get(col)
            if tf is None:
                continue  # 详设没有的列(V6/V8/V9 加列型迁移)不比对
            tmm = re.match(r"^\s*[A-Za-z_]\w*\s+([A-Za-z]+)\s*(\(\s*(\d+)\s*\))?", str(tf))
            tlen = tmm.group(3) if tmm else None
            if tlen is None:
                continue  # 详设本身没定长度,无从比对
            if dlen == tlen:
                continue
            registered = q_marks.get((tname, col)) or set()
            if not any(_q_registered(specs, q) for q in sorted(registered)):
                err(f"DDL 字段口径与详设不一致: {fname} {tname}.{col} "
                    f"长度={dlen or '(未带长度)'} 详设={tlen} —— 且无已登记的 [Q编号] 留痕"
                    f"(R-J:偏离详设口径必须登记 Q 并在 spec 表结构标注)")


def _q_registered(specs, qid):
    oq = specs / "open-questions.json"
    if not oq.exists():
        return False
    try:
        data = json.loads(oq.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return False
    return any(q.get("id") == qid for q in data.get("questions", []))


# ---- 交付确认 呈报生成(--stage report)----
# 数据全部取自 spec.json / impl 日志 / 源码扫描,LLM 只核对签字,不再手工组装。

def build_report(specs, fid, cfg):
    spec_dir, sp = load_spec(specs, fid)
    if sp is None:
        return None
    rules = [r for r in sp.get("rules", []) if r.get("id")]
    rids = [r.get("id") for r in rules]
    hits = scan_r_hits(specs, cfg, fid, rids)

    log_path = specs / "_work" / "impl-logs" / f"{fid}.md"
    log_lines = []
    if log_path.exists():
        log_lines = log_path.read_text(encoding="utf-8", errors="ignore").splitlines()

    changed = []
    for line in log_lines:
        m = re.search(r"`([^`]+\.\w+)`", line)
        if m and ("改动" in line or "新增" in line or "修改" in line):
            changed.append(m.group(1))
    if not changed:
        # 从 R 落点文件推断改动面(impl 日志没写清单时的兜底)
        changed = sorted({f for files in hits.values() for f in files})

    lines = []
    lines.append(f"# 交付确认 呈报:{fid} {sp.get('name', '')}")
    lines.append("")
    lines.append(f"- spec:{spec_dir.name}/spec.json(status={sp.get('status')})")
    lines.append(f"- impl 日志:specs/_work/impl-logs/{fid}.md")
    review = specs / "_work" / "review-logs" / f"{fid}.md"
    lines.append(f"- 评审日志:{'specs/_work/review-logs/' + fid + '.md' if review.exists() else '(缺失,未过 独立评审)'}")
    lines.append("")
    lines.append("## 改动文件(推断,以 impl 日志为准)")
    for f in changed:
        lines.append(f"- {f}")
    lines.append("")
    lines.append("## R→落点对照")
    for r in rules:
        rid = r.get("id")
        title = (r.get("title") or r.get("text") or "").splitlines()[0][:60]
        files = hits.get(rid) or []
        if files:
            lines.append(f"- {fid}-{rid} {title} -> {', '.join(files[:5])}")
        else:
            lines.append(f"- {fid}-{rid} {title} -> **无落点(未过 i2)**")
    lines.append("")
    lines.append("## 验收走查")
    for a in sp.get("acceptances", []):
        aid = a.get("id", "")
        walked = [ln.strip() for ln in log_lines if aid and aid in ln]
        if walked:
            lines.append(f"- {aid}:impl 日志有走查记录")
        else:
            lines.append(f"- {aid}:**impl 日志无走查记录**")
    lines.append("")
    lines.append("## 涉及 Q 占位")
    qs = set()
    for f in (spec_dir.rglob("*") if spec_dir else []):
        if f.is_file() and f.suffix in (".md", ".json"):
            qs.update(Q_MARK.findall(f.read_text(encoding="utf-8", errors="ignore")))
    if qs:
        for q in sorted(qs):
            lines.append(f"- {q}")
    else:
        lines.append("- 无")
    return "\n".join(lines)


def run_report(specs, fid, cfg):
    text = build_report(specs, fid, cfg)
    if text is None:
        return
    out_dir = specs / "_work" / "g3-reports"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{fid}.md"
    out.write_text(text + "\n", encoding="utf-8")
    print(text)
    print(f"\n== 已写入 {out.relative_to(specs.parent) if specs.parent != specs else out} ==")


def impl_main():
    args = sys.argv[1:]
    stage = None
    fid = None
    if "--stage" in args:
        i = args.index("--stage")
        if i + 1 >= len(args):
            print("缺少 --stage 值")
            return 2
        stage = args[i + 1]
        rest = args[i + 2:]
        args = args[:i] + rest
    if stage not in VALID_STAGES:
        print(f"用法: python sdd.py <specs目录> --stage begin|deliver|report <F编号> | --stage done")
        return 2
    if not args:
        print("缺少 specs 目录")
        return 2
    specs = Path(args[0])
    if not specs.is_dir():
        print(f"specs 目录不存在: {specs}")
        return 2
    if stage in ("begin", "deliver", "report", "set-status"):
        if len(args) < 2:
            print(f"--stage {stage} 需要 F编号")
            return 2
        fid = args[1]
        if not F_ID.match(fid):
            print(f"F编号格式应为 F+三位数字,收到: {fid}")
            return 2

    # ---- 公共:feature-list ----
    fl = _impl_load_json(specs / "feature-list.json")
    features = (fl or {}).get("features", [])
    feature_ids = {f.get("id") for f in features}

    if stage == "report":
        cfg = check_impl_config(specs)
        run_report(specs, fid, cfg)
        return summarize(f"== SDD 呈报生成 | specs={specs} | {fid} ==")

    if stage == "set-status":
        # 用法:--stage set-status <F编号> --status 已确认|实现中|已交付 --by <谁>
        # 状态回写收敛为命令:json status/approvedBy/approvedAt + md「| 状态 |」行一次改齐
        def _val(flag, default=None):
            return args[args.index(flag) + 1] if flag in args and args.index(flag) + 1 < len(args) else default
        status = _val("--status")
        by = _val("--by", "user")
        if status not in ALLOWED_SPEC_STATUS:
            print(f"--status 非法: {status!r},允许 {'/'.join(sorted(ALLOWED_SPEC_STATUS))}")
            return 2
        ok = set_spec_status(specs, fid, status, by)
        return summarize(f"== SDD 状态回写 | specs={specs} | {fid} -> {status} ==") if ok else 1

    if stage in ("begin", "deliver"):
        if fl is not None and fid not in feature_ids:
            err(f"{fid} 不在 feature-list.json 中")
        check_blocking_qs(specs, {fid})
        check_deps_delivered(specs, features, fid)
        cfg = check_impl_config(specs)
        # C3 字段口径比对:i0 开工前就查,别等交付才发现口径漂了
        check_ddl_vs_twin(specs, cfg)
        spec_dir, sp = load_spec(specs, fid)
        status = (sp or {}).get("status")
        if sp is not None:
            if status not in ALLOWED_SPEC_STATUS:
                err(f"spec.status 非法: {status!r}")
            if stage == "begin" and status not in ("已确认", "实现中"):
                err(f"开工登记要求 spec.status 为 已确认(或已改 实现中),当前 {status!r}")
            if stage == "deliver" and status != "已交付":
                err(f"交付检查要求 spec.status 已回写 已交付,当前 {status!r}")
            rules = [r.get("id") for r in sp.get("rules", []) if r.get("id")]
            if stage == "deliver":
                if not rules:
                    err("spec 无规则,无法反查落点(spec 不合规,回规范步修)")
                else:
                    check_r_annotations(specs, cfg, fid, rules)
                log_text = check_impl_log(specs, fid, cfg)
                if spec_dir:
                    check_acceptance_log(log_text, spec_dir, fid)
                # C1 占位对账:spec 目录与 impl 日志中的 [Qnnn] 占位逐个对账登记簿
                check_q_placeholder_reconciliation(specs, fid)
                # impl 日志中的 [Q-Fxx-nn] 占位 token(历史格式,新占位统一 [Qnnn]) 逐个对账 open-questions.json,
                # 未登记即拒交付(先例:组 B 四例占位登记延迟,全靠评审人肉抓)
                oq = load_json(specs / "open-questions.json") or {}
                q_sources = " || ".join(
                    str(q.get("id", "")) + " " + str(q.get("source", "")) + " " + " ".join(q.get("features", []))
                    for q in oq.get("questions", []))
                for tok in sorted(set(re.findall(r"\[Q-F\d{3}-\d{2}\]", log_text or ""))):
                    fid_token = tok.strip("[]")
                    if fid_token not in q_sources:
                        err(f"impl 日志含未入档的 Q 占位 {tok}:open-questions.json 无同源条目"
                            f"(占位必须与登记簿同步,禁止只记 impl 日志;"
                            f"新占位统一用 [Qnnn] 三位编号,{tok} 属历史格式仅兼容放行)")
                # C2 前端三件套:登记了 frontend-lint 的 feature,
                # lint/build 必须有 exit 0 记录,且 local-tests 下必须有实机/API 场景产物
                if cfg and any(c.get("name") == "frontend-lint" for c in cfg.get("testCommands", [])):
                    fe_cmds = [c for c in cfg.get("testCommands", []) if c.get("name", "").startswith("frontend")]
                    for c in fe_cmds:
                        name = c.get("name", "")
                        m = re.search(rf"{re.escape(name)}.*?(?:exit|退出码|code)\s*[:=]?\s*(\d+)", log_text or "", re.IGNORECASE)
                        if m is None:
                            err(f"前端命令 {name} 未在 impl 日志登记退出码(前端三件套)")
                        elif m.group(1) != "0":
                            err(f"前端命令 {name} 退出码非 0: {m.group(1)}")
                    lt_dir = specs / "_work" / "local-tests"
                    if not lt_dir.is_dir() or not any(lt_dir.rglob("*")):
                        err("前端 feature 缺实机/API 场景产物(specs/_work/local-tests/ 为空,前端三件套)")
                # L3 接口全量对账(本 feature):apis[] 每个接口必须有 L3 用例或豁免登记
                check_api_test_coverage(specs, [fid])
    else:  # done
        for f in features:
            _, sp = load_spec(specs, f.get("id"))
            status = (sp or {}).get("status")
            if status != "已交付":
                err(f"{f.get('id')} 未 delivered(当前 status={status!r})")
        check_blocking_qs(specs, feature_ids)
        # impl 日志齐全
        if specs.exists():
            for f in features:
                p = specs / "_work" / "impl-logs" / f"{f.get('id')}.md"
                if not p.exists():
                    err(f"缺少实现日志: _work/impl-logs/{f.get('id')}.md")
        # 至少登记过一次守卫全绿
        if specs.exists():
            logs = list((specs / "_work" / "impl-logs").glob("*.md")) if (specs / "_work" / "impl-logs").is_dir() else []
            if not any("守卫" in p.read_text(encoding="utf-8", errors="ignore") for p in logs):
                warn("impl 日志中未检索到「守卫」记录,确认守卫测试全绿是否留痕")
        # L4 场景测试凭证对账(先例:casebook#场景测试只跑头一个——F001 实测留痕,
        # F002~F020 只生成了 run.sh 从未执行,done 闸当时查不到,缺口直通收尾):
        # 每 feature 必须有 _work/local-tests/<F>/report.md,且由 run.sh 落盘的
        # 实跑退出码记录(报告由脚本生成,AI 手写报告不算凭证)。
        _lt_root = specs / "_work" / "local-tests"
        _exit0_re = re.compile(r"(?:exit|退出码|ExitCode|code)\s*[:=：]?\s*0\b", re.IGNORECASE)
        if _lt_root.is_dir():
            for f in features:
                _fid = f.get("id")
                _rep = _lt_root / _fid / "report.md"
                if not _rep.exists():
                    err(f"{_fid} 缺 L4 场景测试报告: _work/local-tests/{_fid}/report.md"
                        f"(report 由 run.sh 执行时自动落盘;没跑就没有报告,禁止手写补)")
                elif not _exit0_re.search(_rep.read_text(encoding="utf-8", errors="ignore")):
                    err(f"{_fid} L4 报告无 exit 0 实跑记录(场景未全绿或报告未经脚本生成)")
        else:
            err("收尾检查:缺 _work/local-tests/ 目录(L4 场景测试未开展)")
        # L3 接口全量对账(全集):全部 spec apis[] ↔ 已执行接口用例
        check_api_test_coverage(specs, sorted(feature_ids), label="收尾检查")
        # (复盘 2026-09-20)debt-register 未核销条目对账:占位/Q 承接的债务不允许静默悬空
        _debt = specs / "_work" / "debt-register.md"
        if _debt.exists():
            _debt_lines = [ln.strip() for ln in _debt.read_text(encoding="utf-8", errors="ignore").splitlines()
                           if ln.strip() and not ln.startswith(("#", "|---", "| 来源", ">"))]
            _rows = [ln for ln in _debt_lines if ln.startswith("|")]
            _open = [ln for ln in _rows if not re.search(r"已核销|已关闭|✅", ln)]
            if _open:
                warn(f"debt-register 存在 {len(_open)} 条未核销债务(占位/承接类),逐条核销或经用户豁免:")
                for ln in _open[:10]:
                    warn("  " + ln[:120])
            elif _rows:
                pass
        # (复盘 2026-09-19 建议#6)done 期 L5 分母对账:前端项目必须有浏览器冒烟归档
        # 与 R 触达账本,且每个已交付 feature id 在账本中登记(触达或豁免二值,缺口即红)。
        _has_frontend = False
        try:
            _cfg_done = json.loads((specs / "impl-config.json").read_text(encoding="utf-8"))
            _has_frontend = any(c.get("name", "").startswith("frontend")
                                for c in _cfg_done.get("buildCommands", []))
        except Exception:
            pass
        if _has_frontend:
            _e2e = specs.parent / "tests" / "e2e"
            if not _e2e.is_dir() or not any(_e2e.rglob("*.mjs")):
                err("收尾检查:前端项目缺 L5 冒烟归档(tests/e2e/ 无 Playwright 用例)")
            _cov_candidates = list((specs / "_work").glob("l5*coverage*.md")) if (specs / "_work").is_dir() else []
            _cov_text = "".join(p.read_text(encoding="utf-8", errors="ignore") for p in _cov_candidates)
            if not _cov_candidates:
                err("收尾检查:缺 L5 前端 R 触达账本(约定路径 specs/_work/l5-r-coverage.md)")
            else:
                for f in features:
                    if f.get("done"):
                        continue
                    if f.get("id") not in _cov_text:
                        err(f"收尾检查:L5 R 触达账本未登记 {f.get('id')}(触达或豁免二值必填)")

    # ---- 汇总 ----
    return summarize(f"== SDD 实现校验 | specs={specs} | stage={stage}{' ' + fid if fid else ''} ==")


# ---------------------------------------------------------------- 环境预检(--stage env)

def env_main(specs):
    """开工前环境预检:探测工具链/网络/端口/可写性,对照详设 techStack 输出三档结论。
    [MISS]=缺失即红,挡开工放行;[WARN]=存疑呈报;[OK]=满足。探测均为秒级本地命令。"""
    import shutil
    import socket
    import subprocess
    import urllib.request

    def run(cmd, timeout=15):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=timeout, shell=(os.name == "nt"))
            out = ((r.stdout or "") + (r.stderr or "")).strip()
            return r.returncode, out.splitlines()[0][:100] if out else ""
        except (OSError, subprocess.TimeoutExpired):
            return None, ""

    def head(url, timeout=3):
        try:
            req = urllib.request.Request(url, method="HEAD")
            urllib.request.urlopen(req, timeout=timeout)
            return True
        except Exception:
            # 任意 HTTP 响应(含 403/405)都算"网络可达";只有连不上/超时才算断
            try:
                urllib.request.urlopen(url, timeout=timeout)
                return True
            except urllib.error.HTTPError:
                return True
            except Exception:
                return False

    # 工具链:开工最低要求(git/构建工具/前端运行时);版本号仅呈报,与 techStack 的
    # 对照由 AI 核对(详设版本写法太多样,不做正则强校验)
    for name, probe in [("git", ["git", "--version"]), ("java", ["java", "-version"]),
                        ("mvn", ["mvn", "-v"]), ("node", ["node", "-v"]), ("npm", ["npm", "-v"])]:
        if shutil.which(name if os.name != "nt" else name + ".exe") is None and shutil.which(name) is None:
            err(f"[MISS] 工具缺失: {name}")
        else:
            code, first = run(probe)
            print(f"[OK] {name}: {first if code == 0 else '存在(版本读取失败)'}")

    # 网络:agent shell 无网时 npm install 会假死,开工前必须显式探测
    mirrors = [("npmmirror(国内镜像)", "https://registry.npmmirror.com"),
               ("npmjs(默认源)", "https://registry.npmjs.org")]
    reachable = []
    for label, url in mirrors:
        ok = head(url)
        print(f"[{'OK' if ok else 'MISS'}] 网络可达: {label}")
        if ok:
            reachable.append(label)
    if not reachable:
        err("[MISS] agent shell 无外网:装依赖类命令(npm install/playwright install)会假死。"
            "三选一:①该命令申请非受限执行重试;②把 npm install* 加进项目权限白名单;"
            "③用户手动预装依赖,agent 只做离线操作。禁止原地无限重试")
    elif "npmmirror" not in reachable and "npmjs" in reachable:
        warn("仅默认源可达:国内网络下 npm install 可能极慢,建议命令带 "
             "--registry=https://registry.npmmirror.com --loglevel info,并设超时上限")
    code, reg = run(["npm", "config", "get", "registry"])
    if code == 0:
        print(f"[OK] npm registry 配置: {reg}")

    # 端口:默认服务端口被占会让首次启动健康检查误判
    for port in (8080,):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1)
        occupied = s.connect_ex(("127.0.0.1", port)) == 0
        s.close()
        if occupied:
            warn(f"端口 {port} 已被占用:并行/联调前先错开(杀残留 java 进程,见 parallel-worktrees Windows 注意)")
        else:
            print(f"[OK] 端口 {port} 空闲")

    # 可写性:specs/_work 与本地数据目录
    for d in [specs / "_work", Path("data").resolve()]:
        try:
            d.mkdir(parents=True, exist_ok=True)
            probe = d / ".env-probe"
            probe.write_text("ok", encoding="utf-8")
            probe.unlink()
            print(f"[OK] 可写: {d}")
        except OSError as e:
            err(f"[MISS] 不可写: {d} ({e})")

    # 详设要求对照材料:techStack 声明原样带出,供 AI 逐项核对版本
    for ex in sorted((specs / "_work").glob("extract-*.json")) if (specs / "_work").is_dir() else []:
        data = load_json(ex) or {}
        for item in data.get("techStack") or []:
            print(f"[INFO] techStack {item.get('item')}: {item.get('value')}({item.get('sourceSection', '')})")

    return summarize(f"== SDD 环境预检 | specs={specs} ==")


# ---------------------------------------------------------------- 入口路由

def main(argv=None):
    """按 --stage 路由到规范段或实现段。"""
    args = list(sys.argv[1:] if argv is None else argv)
    stage = None
    if "--stage" in args:
        k = args.index("--stage")
        if k + 1 < len(args):
            stage = args[k + 1]
    if stage in ("begin", "deliver", "report", "done", "set-status"):
        return impl_main()
    if stage == "env":
        pos = [a for i, a in enumerate(args)
               if not (a == "--stage" or (i > 0 and args[i - 1] == "--stage"))]
        if not pos or not Path(pos[0]).is_dir():
            print("用法: python sdd.py <specs目录> --stage env")
            return 2
        return env_main(Path(pos[0]))
    return specs_main(argv)


if __name__ == "__main__":
    sys.exit(main())
