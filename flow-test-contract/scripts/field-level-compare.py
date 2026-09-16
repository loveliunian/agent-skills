#!/usr/bin/env python3
"""field-level-compare.py v2 —— 多维语义对拍执行器（fail-closed，复刻结论唯一来源）。

v2.11（v1.4.0，2026-09-12）：VERSION 常量对齐文档头（此前文档 v2.11 / 常量 v2.10 漂移）；
  field-compare.md 人话化重排（BLOCKED 最前 + 差异按用例分组 + 维度中文 + 原因人话，
  共享 fc_readability 唯一实现）——**json 结论字段零改动**，比较语义与 v2.10 完全一致；
v2.11a（1.3.0，对齐 2026-09-09 P1 豁免取证链双修）：
  - 豁免生效前提升级为完整取证链：id/reason/approved_by + approval_ref/source_run_id/
    source_compare_sha256_16（16 位小写 hex）任一缺失/格式非法 → 不生效（计入
    invalid_exemptions，差异保留）——真实 run 绑定同时保护"生成器入口"（exempt 子命令）
    与"最终对拍入口"（本比较器），绕过 exempt 手写精确 match 的豁免不再吞差异
v2.10 修复（对齐 2026-09-08 第二十二轮·李雅庄公路重跑实测）：
  - 双端空值语义等价：老系统空串 ''/新系统 null 属同一"无值"的表示层差异，
    此前 exact/abs 容差路径记伪 diff（公路 00 节点实测 60+ 条假差异）——
    tol_ok exact/abs 分支双空 → 判等（一空一非空仍 diff，不放过真实差异；
    trim/number 归一化路径语义不变）
v2.9 修复（对齐 2026-09-06 第十轮独立审计·零发现判定轮）：
  - 原生非有限浮点形态（第九轮封的是字符串经 float() 解析路径，原生 float 漏网）：
    Python json.loads 默认接受**非标准 JSON 字面量** Infinity/NaN/-Infinity（RFC 8259 不允许）
    ——解析为原生 float inf/nan 后走 exact/trim 路径**不经 norm_number**：双端 inf==inf
    记假 MATCH（可推全链假 PASS）、nan==nan 恒 False 冒用 FAIL(1)；
    rules 侧同理（YAML .inf/.nan 经 gen 的 json.dumps 默认写出 Infinity）。
    采集与 rules 加载一律 parse_constant 拒绝 → "采集损坏"/"rules 不可读" → BLOCKED
v2.8 修复（对齐 2026-09-06 第九轮独立审计·收敛复核轮）：
  - 非有限数值形态族（第八轮 raise 只挡 ValueError，float() 解析成功的畸形漏网）：
    "nan"/"inf"/"infinity"/"1e999"（溢出折 inf）等数值化"成功"但产出非有限值——
    双端 inf==inf 记假 MATCH（"inf" vs "1e999" 不同原始串也互判一致）、
    nan 恒不等记假 diff 冒用 FAIL(1)；norm_number 加 isfinite 检查一律 raise → BLOCKED
v2.7 修复（对齐 2026-09-06 第八轮独立审计·收敛复核轮）：
  - 值级类型畸形族（第七轮封的是容器级，值级仍有假 MATCH/假 FAIL）：
    * norm_number 对非空但不可数值化的值（"待定"/True 等）此前折为 None——
      双端垃圾被 null_policy 判"双空相等"记假 MATCH、单边记假 diff 冒用 FAIL(1)；
      一律 raise → 外层 BLOCKED
    * field/formula/post_flow.inherits/resources 采集值为 dict/list（非标量）→ BLOCKED——
      同构垃圾 str()/norm 化后可记假 MATCH（如 {"a":1} 双端"一致"）
v2.6 修复（对齐 2026-09-06 第七轮独立对抗审计·零发现判定轮）：
  - fixture_pairs 非字符串列表（字符串→字符集合化 / dict→键集）→ BLOCKED——
    dict 形态与 fixture_pair_id 键巧合时被误读为有效配对，假配对→假 MATCH→全链假 PASS
  - 规则侧字符串集合化族：routing.candidates_legacy / must_not_contain 与
    buttons.expect_visible / expect_hidden 非列表 → BLOCKED——字符串会被
    set(map(str,…)) 字符集合化，禁含/隐藏/可见断言静默失效记假 OK（或假 FAIL）
  - 规则 buttons 非对象条目 / 声明非空但无任何带 node 的可比条目 → BLOCKED——
    此前静默过滤=声明维度被跳过（注记条目允许，但不得替代断言）
  - post_flow.registered 非布尔 → BLOCKED（truthy 字符串双端同值此前记 diff 冒用 FAIL(1)）
  - 配对 case_id 必须非空字符串（int 等畸形形态不再视为同例配对）
v2.5 修复（对齐 2026-09-06 第六轮独立对抗审计）：
  - buttons 采集值非列表（字符串等）→ BLOCKED——此前 set(map(str,…)) 把字符串字符集合化，
    双端同字符串可记假 MATCH（类型畸形证据，与 routing 非列表检查同口径）
v2.4 修复（对齐 2026-09-06 第五轮独立对抗审计）：
  - 顶层异常兜底 exit 2：outdir 被普通文件占用/父目录只读等此前直接 traceback
    exit 1——crash 冒用 FAIL(1) 结论码（与用法错误混淆），一律折为 BLOCKED(2)
  - mask 脱敏收紧：len<8 的短值全遮 "***"（此前首尾各露 2 字符，len=5 时泄露 80%）
  - field-compare.md 动态值转义换行/回车/ESC（防采集侧注入伪造标题行）
v2.3 修复（对齐 2026-09-06 第四轮独立对抗审计）：
  - 豁免 match='*' 通配禁止：即使 scope 为具体维度也等于整维度全免（可审计外形的绕过）→ BLOCKED；
    稳定键匹配不再接受 '*' 候选
  - abs 容差分支的原始值回退同样防 bool 陷阱（True vs 1 不判等，与 exact 同口径）
v2.1 修复（对齐 2026-09-06 第二轮独立审计）：
  - 豁免收紧：scope='*'+match='*' 全量豁免 → BLOCKED；缺 id/reason/approved_by 的
    不可审计豁免不生效（计入 invalid_exemptions）；match 支持去文件名前缀的稳定键
  - 配对完整性：同名采集文件双端 case_id 必须一致且非空，否则 BLOCKED（防错拿他例采集）
  - tolerance exact：布尔/非布尔（True vs 1）不判等（Python bool==int 陷阱）
v2 修复（对齐 2026-09-05 审计）：
  - 按 文件(case)×step×field 维度比较，绝不跨步骤折叠取首个非空值
  - current 侧按 target_field 读取（此前误用 legacy_field——字段改名即假 FAIL）
  - fixture 必须**双端都声明**同一 fixture_pair_id（此前并集放行→单边声明即假 OK）
  - 合同字段在 legacy 侧从未采集 → coverage_gap → BLOCKED（此前静默跳过）
  - 除字段外，比较 formulas / routing / buttons / resources / post_flow（规则声明而采集缺失 → BLOCKED）
  - redact: hash 实现为带盐摘要（盐随机生成并记录于输出；此前原值直出泄露）
  - 规则 flow_code 与采集 flow_code 不一致 → BLOCKED（防串流程规则）

消费:
  --captures-dir <dir>/legacy/*.json 与 current/*.json（同名配对；一个文件=一个 case 采集）
  采集文件结构:
    { "flow_code": "WFA_..", "case_id": "C-01",
      "fixture_pairs": ["FP-.."],                # 本 case 实际使用的配对（双端须一致）
      "steps": { "<step_id>": { "fields": { "<legacy侧字段名>": 值 } } },   # current 侧同结构但键为 target 侧字段名
      "formulas": {"A.2": 978.26}, "routing": {"00": ["01","02"]},
      "buttons": {"00": ["保存草稿"]}, "resources": {"railway-weight": "已使用"},
      "post_flow": {"registered": true, "inherits": {"KC": "李雅庄矿"}} }
  --rules compare-rules.json（gen_from_contract.py 产出）
产出: <outdir>/field-compare.{json,md}；exit 0=无未豁免差异 / 1=有差异 / 2=BLOCKED
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import secrets
import sys
from pathlib import Path

sys.dont_write_bytecode = True   # 审计 P1-3：动态加载共享库时零字节码（skill 目录零副作用）


VERSION = "field-level-compare.py v2.11"
OK, FAIL, BLOCKED = "OK", "FAIL", "BLOCKED"


def _reject_nonfinite_constant(x):
    """第十轮审计：json.loads 默认接受非标准 JSON 字面量 Infinity/NaN/-Infinity（RFC 8259
    不允许）并解析为原生 float inf/nan——exact/trim 路径不经 norm_number 的 isfinite 检查：
    双端 inf==inf 记假 MATCH（可推假 PASS）、nan 恒不等冒用 FAIL(1)。解析期即拒=证据损坏
    → 外层既有 "采集损坏"/"rules 不可读" 路径 → BLOCKED（与 norm_number isfinite 同口径）。"""
    raise ValueError(f"非标准 JSON 常量 {x}（Infinity/NaN=原生非有限数值，证据损坏）")


def nonscalar(v) -> bool:
    """第八轮审计：dict/list 形态的采集值=类型畸形证据——str()/归一化后同构垃圾可记假 MATCH。"""
    return isinstance(v, (dict, list))


def norm_number(v, nd=None):
    if v in (None, ""):
        return None
    s = str(v).replace(",", "").strip()
    if not s:
        return None
    try:
        f = float(s)
    except (TypeError, ValueError):
        # 第八轮审计：非空值不可数值化（"待定"/True 等）此前折为 None——null_policy 会把
        # 双端垃圾判"双空相等"记假 MATCH、单边记假 diff 冒用 FAIL(1)。raise 由外层
        # per-case/coverage 的 except 捕获 → BLOCKED（类型畸形证据绝不变相放行/冒用 FAIL）
        raise ValueError(f"字段值不可数值化（证据损坏/类型畸形）: {v!r}")
    # 第九轮审计：float() 对 "nan"/"inf"/"infinity"/"1e999"（溢出折 inf）解析**成功**但产出
    # 非有限值——绕过上述 raise：双端 inf==inf 记假 MATCH（"inf" vs "1e999" 两个不同原始串
    # 也互判一致，掩盖真差异）；nan 与任何值比较恒 False 记假 diff 冒用 FAIL(1)。
    # 非有限浮点=不可有意义比对的值级畸形，与不可数值化同口径 raise → BLOCKED
    if not math.isfinite(f):
        raise ValueError(f"字段值数值化为非有限值 nan/inf（证据损坏/类型畸形）: {v!r}")
    return round(f, nd) if nd is not None else f


def normalize(v, rule):
    if v in (None, ""):
        return v
    n = rule.get("normalize", "none")
    if n in ("number", "number_2dp"):
        return norm_number(v, 2 if n == "number_2dp" else None)
    if n == "trim":
        return str(v).strip()
    if n == "date_iso":
        return str(v).strip().replace("/", "-").replace(".", "-")[:10]
    return v


def apply_dict_map(v, rule, dict_maps):
    ref = rule.get("dict_map_ref")
    if not ref:
        return v
    m = (dict_maps.get(ref) or {}).get("map") or {}
    return m.get(v, v)


def tol_ok(a, b, tol):
    if tol in (None, "exact"):
        # 第二十二轮：双端空值（''/None）语义等价——表示层差异不构成值差异（与 null_policy_ok 同口径）
        if (a in (None, "")) and (b in (None, "")):
            return True
        if isinstance(a, bool) != isinstance(b, bool):  # True==1 的 Python 陷阱：布尔与非布尔不判等
            return False
        return a == b
    if isinstance(tol, str) and tol.startswith("abs:"):
        t = float(tol.split(":", 1)[1])
        # 第三轮审计：abs:inf / abs:1e999 / abs:nan / 负数 → 规则非法（inf 会容忍一切数值差异=假 OK）。
        # raise 由外层 per-case/coverage 的 except 捕获 → BLOCKED（畸形规则=证据损坏，绝不变相放行）
        if not math.isfinite(t) or t < 0:
            raise ValueError(f"tolerance {tol!r} 非法（须为有限非负数；abs:inf 可容忍一切差异）")
        na, nb = norm_number(a), norm_number(b)
        if na is None or nb is None:
            # 第二十二轮（李雅庄公路重跑实测）：双端空值（''/None）语义等价——老系统空串、
            # 新系统 null 是同一"无值"的表示层差异，不得记 tolerance diff（60 条伪差根源）。
            if na is None and nb is None:
                return True
            # 第四轮审计：abs 分支的原始值回退同样受 bool 陷阱影响（True==1）——布尔与非布尔不判等
            if isinstance(a, bool) != isinstance(b, bool):
                return False
            return a == b
        return abs(na - nb) <= t
    return a == b


def null_policy_ok(lv, cv, policy):
    ln, cn = lv in (None, ""), cv in (None, "")
    if policy == "legacy_null_expected":
        return ln
    if policy == "current_null_expected":
        return cn
    if policy == "null_is_diff":
        return not (ln or cn) or (ln and cn)
    return not (ln ^ cn) or (not ln and not cn)  # both_null_equal：均空相等，一空一非空差异


def _md(s) -> str:
    """field-compare.md 动态值转义：换行/回车/ESC 会伪造标题行/终端控制序列（结论仍只认 json）。"""
    return (str(s).replace("\\", "\\\\").replace("|", "\\|").replace("\n", "\\n")
            .replace("\r", "\\r").replace("\x1b", "^["))


class Ctx:
    def __init__(self, rules, salt):
        self.rules = rules
        self.salt = salt
        self.diffs, self.exempted, self.matches = [], [], []
        self.observe, self.coverage = [], []
        self.status = OK
        self.exemptions = rules.get("exemptions") or []
        self.valid_exemptions: list[dict] = []
        self.invalid_exemptions: list[dict] = []
        self._exemptions_checked = False

    def check_exemptions(self):
        """豁免合法性（只跑一次）：必须可审计（id/reason/approved_by）且带完整取证链
        （approval_ref/source_run_id/source_compare_sha256_16，1.3.0 起——真实 run 绑定不只
        保护生成器入口，也保护最终对拍入口；无源 run 绑定的豁免不生效，差异保留）；
        scope='*'+match='*' 全量豁免 → BLOCKED（差异全免=绕过结论，禁止）。"""
        if self._exemptions_checked:
            return
        self._exemptions_checked = True
        for e in self.exemptions:
            if not isinstance(e, dict):
                self.invalid_exemptions.append({"entry": str(e), "why": "非对象条目"})
                continue
            auditable = all(str(e.get(k) or "").strip() for k in
                            ("id", "reason", "approved_by",
                             "approval_ref", "source_run_id", "source_compare_sha256_16"))
            if not auditable:
                self.invalid_exemptions.append(
                    {"id": e.get("id"), "why": "缺 id/reason/approved_by/approval_ref/source_run_id/"
                                               "source_compare_sha256_16——豁免必须可审计且绑定真实 run，不生效"})
                continue
            if not re.fullmatch(r"[0-9a-f]{16}", str(e.get("source_compare_sha256_16"))):
                self.invalid_exemptions.append(
                    {"id": e.get("id"), "why": "source_compare_sha256_16 非 16 位小写 hex——取证链字段格式非法，不生效"})
                continue
            if e.get("scope") == "*" and e.get("match") == "*":
                self.block(f"豁免 {e.get('id')} scope='*'+match='*' 全量豁免禁止——豁免必须精确到 dim/key（见契约 exemptions.match）")
                continue
            # 第四轮审计：match='*' 即使 scope 为具体维度也等于"整维度全免"——一条可审计外形的
            # 豁免即可吞掉该维度全部差异推假 OK/假 PASS。通配 match 一律 BLOCKED（豁免只作用于本维度本键）。
            if e.get("match") == "*":
                self.block(f"豁免 {e.get('id')} match='*' 通配禁止（scope={e.get('scope')!r} 时等于整维度全免）——豁免必须精确到本维度本 key")
                continue
            self.valid_exemptions.append(e)

    def is_exempt(self, dim, key):
        self.check_exemptions()
        # 稳定键候选：完整 key / 去掉采集文件名前缀后的键（跨 run 文件名可能变化）。
        # 第三轮审计：只剥**一次**前缀（":" 优先，否则首个 "/"）——此前 ":" 与 "/" 各剥一次，
        # "c0:routing/00" 会额外产生候选 "00"，一条 match="00" 的豁免可跨维度误杀 buttons/00 等差异
        cands = {key}
        if ":" in key:
            cands.add(key.split(":", 1)[1])
        elif "/" in key:
            cands.add(key.split("/", 1)[1])
        for e in self.valid_exemptions:
            # 第四轮审计：match 不再接受 '*'（通配在上游 check_exemptions 已 BLOCKED，此处仅精确/稳定键）
            if e.get("scope") in (dim, "*") and e.get("match") in cands:
                return e.get("id", "EX")
        return None

    def diff(self, dim, key, legacy, current, reason):
        item = {"dim": dim, "key": key, "legacy": legacy, "current": current, "reason": reason}
        if xid := self.is_exempt(dim, key):
            item["exempted_by"] = xid
            self.exempted.append(item)
        else:
            self.diffs.append(item)

    def block(self, reason):
        self.status = BLOCKED
        self.coverage.append(reason)


def redact(v, rule, salt):
    if v in (None, ""):
        return v
    mode = rule.get("redact", "none")
    if mode == "mask":
        s = str(v)
        # 第五轮审计：短值首尾各露 2 字符≈全泄露（len=5 泄露 4/5 字符）——len<8 一律全遮
        return s[:2] + "***" + s[-2:] if len(s) >= 8 else "***"
    if mode == "hash":
        return "sha256$" + hashlib.sha256((salt + str(v)).encode()).hexdigest()[:16]
    return v


def load_caps(d: Path, side: str):
    if not d.exists():
        return None, f"{side} 采集目录不存在: {d}"
    files = sorted(d.glob("*.json"))
    if not files:
        return None, f"{side} 采集为空（场景需开启 capture: form-fields）: {d}"
    out = {}
    for f in files:
        try:
            # 第十轮审计：parse_constant 拒非标准 JSON 常量（Infinity/NaN）——原生非有限
            # float 会绕过 norm_number 的 isfinite（exact/trim 路径），解析期即视为采集损坏
            out[f.name] = json.loads(f.read_text(encoding="utf-8"), parse_constant=_reject_nonfinite_constant)
        except Exception as e:
            return None, f"{side} 采集损坏 {f.name}: {e}"
    return out, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--captures-dir", required=True)
    ap.add_argument("--rules", required=True)
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()

    salt = secrets.token_hex(8)
    fatal: str | None = None
    try:
        # 第十轮审计：rules 同口径拒绝非标准 JSON 常量（YAML .inf/.nan 经 json.dumps 默认
        # 写出 Infinity——expected_legacy 等规则值不得携原生非有限 float 进比较）
        rules = json.loads(Path(args.rules).read_text(encoding="utf-8"), parse_constant=_reject_nonfinite_constant)
    except Exception as e:
        rules, fatal = {}, f"rules 不可读/损坏: {e}"
    if not fatal and not isinstance(rules, dict):
        fatal = f"rules 根节点必须是对象（拿到 {type(rules).__name__}）"
    ctx = Ctx(rules if isinstance(rules, dict) else {}, salt)
    if fatal:
        ctx.block(fatal)
    ctx.check_exemptions()  # 豁免合法性前置：全量豁免/不可审计豁免在此定性
    rules_meta = rules.get("meta") if isinstance(rules, dict) else None
    if isinstance(rules_meta, dict) and rules_meta.get("draft"):
        ctx.block("compare-rules 为 DRAFT 草稿（meta.draft=true）——草稿规则不得进入正式对拍/结论")
    cap = Path(args.captures_dir)
    lg, e1 = load_caps(cap / "legacy", "legacy")
    cg, e2 = load_caps(cap / "current", "current")
    if e1 or e2:
        ctx.block(e1 or e2)
    rules_flow = rules_meta.get("flow_code") if isinstance(rules_meta, dict) else None
    if lg and cg and not fatal:
        names_l, names_c = set(lg), set(cg)
        if names_l != names_c:
            ctx.block(f"case 采集文件不配对: 仅legacy={sorted(names_l-names_c)} 仅current={sorted(names_c-names_l)}")
        for name in sorted(names_l & names_c):
            l, c = lg[name], cg[name]
            for k, side in ((l, "legacy"), (c, "current")):
                fc = k.get("flow_code") if isinstance(k, dict) else None
                if fc and rules_flow and fc != rules_flow:
                    ctx.block(f"{name}: {side} flow_code={fc} 与规则 flow_code={rules_flow} 不一致（规则错配/串流程）")
            # 配对完整性：同名文件双端必须是同一用例的采集（防错拿他例采集对拍）
            # 第七轮审计：case_id 必须是非空字符串——int 等畸形形态双端同值不得视为有效配对
            lid = l.get("case_id") if isinstance(l, dict) else None
            cid_ = c.get("case_id") if isinstance(c, dict) else None
            if not isinstance(lid, str) or not lid or not isinstance(cid_, str) or lid != cid_:
                ctx.block(f"{name}: 配对采集 case_id 不一致/缺失/非字符串（legacy={lid!r} current={cid_!r}）——双端须声明同一非空字符串 case_id")
            try:
                compare_case(ctx, name, l, c)
            except Exception as e:  # 采集/规则结构畸形 → BLOCKED，绝不让异常变成 exit 1 的假 FAIL
                ctx.block(f"case {name} 采集/规则结构非法（{type(e).__name__}: {e}）——证据损坏")

    # —— 规则声明了但无任何采集覆盖的维度 → BLOCKED（不能静默当一致）——
    if lg and cg and ctx.status != BLOCKED and not fatal:
        try:
            check_dimension_coverage(ctx, rules, lg, cg)
        except Exception as e:
            ctx.block(f"多维对拍执行异常（采集/规则结构非法）: {type(e).__name__}: {e}——证据损坏")

    out = {
        "version": VERSION, "status": ctx.status,
        "stats": {"match": len(ctx.matches), "diff": len(ctx.diffs), "exempted": len(ctx.exempted),
                  "observe": len(ctx.observe), "coverage_blockers": len(ctx.coverage)},
        "redact_salt": salt,
        "diffs": ctx.diffs, "exempted": ctx.exempted, "observe": ctx.observe,
        "invalid_exemptions": ctx.invalid_exemptions,
        "coverage": ctx.coverage, "aux_evidence": "pixel diff 不在本工具范围（auxiliary）",
    }
    if ctx.diffs and ctx.status == OK:
        out["status"] = FAIL
    Path(args.outdir).mkdir(parents=True, exist_ok=True)
    (Path(args.outdir) / "field-compare.json").write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    # v1.4.0：md 面向人读——BLOCKED 原因最前 + 差异按用例分组 + 维度中文化 + 原因人话化
    # （与 gen-final-report 共享 fc_readability 唯一实现；json 结论字段一字不改）
    try:
        import fc_readability as _fr
    except Exception:
        _fr = None
    md = ["# 字段级语义对拍 v2（结论来源）", "",
          f"- status: **{out['status']}**；一致 {len(ctx.matches)} / 差异 {len(ctx.diffs)} / 豁免 {len(ctx.exempted)} / OBSERVE {len(ctx.observe)} / 覆盖阻断 {len(ctx.coverage)}", ""]
    if _fr is not None:
        if out["status"] == OK:
            _one = "全部比对项一致，未发现语义差异（豁免/OBSERVE 项如另有列出则仅供参考）。"
        else:
            _one = _fr.one_line_conclusion(
                out["status"], req_done=len(ctx.matches), req_total=len(ctx.matches),
                n_diff=len(ctx.diffs), n_exempted=len(ctx.exempted), n_failed=0,
                blocked_reasons=ctx.coverage, top_diffs=ctx.diffs)
        md += [f"- 一句话：{_one}", ""]
    if ctx.coverage:
        md += ["## BLOCKED 原因（证据不足，禁止下结论）"] + [f"- {_md(r)}" for r in ctx.coverage] + [""]
    if ctx.diffs:
        if _fr is not None:
            _by_case = _fr.group_by_case(ctx.diffs)
            md += [f"## 语义差异（未豁免）——共 {len(ctx.diffs)} 处，分布在 {len(_by_case)} 个用例", ""]
            for _case, _items in _by_case.items():
                md += [f"### 用例 {_case}（{len(_items)} 处）", "",
                       "| 维度 | 位置 | 老系统 | 新系统 | 说明 |", "|---|---|---|---|---|"]
                md += [f"| {_md(_fr.dim_cn(d['dim']))} | {_md(_fr.diff_where(d['key']))} "
                       f"| {_md(_fr.fmt_value(d['legacy']))} | {_md(_fr.fmt_value(d['current']))} "
                       f"| {_md(_fr.human_reason(d['dim'], d['reason']))} |" for d in _items]
                md += [""]
        else:
            md += ["## 语义差异（未豁免）", "", "| 维度 | 键 | legacy | current | 原因 |", "|---|---|---|---|---|"]
            md += [f"| {_md(d['dim'])} | {_md(d['key'])} | {_md(d['legacy'])} | {_md(d['current'])} | {_md(d['reason'])} |" for d in ctx.diffs]
    if ctx.exempted:
        md += ["## 豁免差异（有审批记录，不进结论）", ""]
        if _fr is not None:
            md += ["| 维度 | 位置 | 老系统 | 新系统 | 说明 | 豁免编号 |", "|---|---|---|---|---|---|"]
            md += [f"| {_md(_fr.dim_cn(d.get('dim')))} | {_md(_fr.diff_where(d.get('key')))} "
                   f"| {_md(_fr.fmt_value(d.get('legacy')))} | {_md(_fr.fmt_value(d.get('current')))} "
                   f"| {_md(_fr.human_reason(d.get('dim'), d.get('reason')))} | {_md(d.get('exempted_by'))} |"
                   for d in ctx.exempted]
        else:
            md += ["| 键 | 原因 |", "|---|---|"]
            md += [f"| {_md(d.get('key'))} | {_md(d.get('reason'))} |" for d in ctx.exempted]
        md += [""]
    (Path(args.outdir) / "field-compare.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print(f"[field-compare] {out['status']}（diff={len(ctx.diffs)}, blocked={len(ctx.coverage)}）→ {args.outdir}")
    raise SystemExit({OK: 0, FAIL: 1, BLOCKED: 2}[out["status"]])


def compare_case(ctx: Ctx, name, l, c):
    fms = ctx.rules.get("field_mappings") or []
    dict_maps = ctx.rules.get("dict_maps") or {}
    declared_fx = {f.get("fixture_pair_id") for f in (ctx.rules.get("fixtures") or [])}
    # 第七轮审计：fixture_pairs 必须是字符串列表——字符串会被 set() 字符集合化、dict 被键集合化，
    # 与 fixture_pair_id 巧合时（如 {"FP-X": ..} 的键）被误读为有效配对 → 假 MATCH → 假 PASS
    for _side, _src in (("legacy", l), ("current", c)):
        _fxp = _src.get("fixture_pairs") if isinstance(_src, dict) else None
        if _fxp is not None and not (isinstance(_fxp, list) and all(isinstance(x, str) and x for x in _fxp)):
            ctx.block(f"{name}: {_side} fixture_pairs 非字符串列表（{type(_fxp).__name__}）——证据损坏")
    fx_l = set(l.get("fixture_pairs") or [])
    fx_c = set(c.get("fixture_pairs") or [])
    fx_both = fx_l & fx_c & declared_fx  # 双端一致且在契约登记
    if (fx_l or fx_c) and not fx_both:
        ctx.observe.append({"key": f"{name}:fixture", "optional": False,
                            "note": f"fixture 未双端一致配对 legacy={sorted(fx_l)} current={sorted(fx_c)}——相关字段降级 OBSERVE（非 optional：整体须 BLOCKED）"})

    l_steps, c_steps = l.get("steps") or {}, c.get("steps") or {}
    seen_legacy_fields = set()
    for step in sorted(set(l_steps) | set(c_steps)):
        lf = (l_steps.get(step) or {}).get("fields") or {}
        cf = (c_steps.get(step) or {}).get("fields") or {}
        seen_legacy_fields |= set(lf)
        for fm in fms:
            lw, tw = fm["legacy_field"], fm["target_field"]
            lv, cv = lf.get(lw), cf.get(tw)
            if lv is None and cv is None:
                continue
            key = f"{name}/{step}/{lw}->{tw}"
            # 第八轮审计：字段值非标量（dict/list）=类型畸形证据——exact/trim 路径不经
            # norm_number，同构垃圾会 str 相等记假 MATCH（与 fixture_pairs 非列表同族）
            if nonscalar(lv) or nonscalar(cv):
                ctx.block(f"{key}: 字段采集值非标量（legacy={type(lv).__name__} current={type(cv).__name__}）——证据损坏")
                continue
            explicit_fx = fm.get("fixture_pair_id")
            if explicit_fx:
                if explicit_fx not in fx_both:
                    ctx.observe.append({"key": key, "optional": bool(fm.get("optional")),
                                        "note": f"显式绑定 fixture {explicit_fx} 未双端配对——只记 OBSERVE"})
                    continue
            elif fm.get("fixture_pair_required") and not fx_both:
                ctx.observe.append({"key": key, "optional": bool(fm.get("optional")),
                                    "note": "fixture 未配对（双端）——只记 OBSERVE"})
                continue
            ln = normalize(apply_dict_map(lv, fm, dict_maps), fm)
            cn = normalize(apply_dict_map(cv, fm, dict_maps), fm)
            rl = fm  # redact 规则按字段
            if not null_policy_ok(ln, cn, fm.get("null_policy")):
                ctx.diff("field", key, redact(ln, rl, ctx.salt), redact(cn, rl, ctx.salt), "null_policy")
            elif not tol_ok(ln, cn, fm.get("tolerance")):
                ctx.diff("field", key, redact(ln, rl, ctx.salt), redact(cn, rl, ctx.salt), "tolerance")
            else:
                ctx.matches.append({"dim": "field", "key": key})
    # 覆盖率：合同字段在 legacy 侧从未出现 → 证据不足
    for fm in fms:
        if fm["legacy_field"] not in seen_legacy_fields:
            ctx.block(f"合同字段 {fm['legacy_field']} 在 legacy 采集从未出现（capture 缺字段或合同写错）——case {name}")


def check_dimension_coverage(ctx: Ctx, rules, lg, cg):
    def has(dim):
        return any((x.get(dim)) for x in lg.values()) or any((x.get(dim)) for x in cg.values())

    if rules.get("formulas"):
        if not has("formulas"):
            ctx.block("规则声明 formulas 但双端采集无 formulas 段——公式对拍证据缺失")
        else:
            for name in sorted(set(lg) & set(cg)):
                compare_formulas(ctx, name, lg[name], cg[name])
    if rules.get("routing"):
        if not has("routing"):
            ctx.block("规则声明 routing 但采集无 routing 段")
        else:
            for name in sorted(set(lg) & set(cg)):
                compare_routing(ctx, name, lg[name], cg[name])
    if rules.get("buttons"):
        # 第七轮审计：声明 buttons 就必须有可比条目——非对象条目=证据损坏（不再静默过滤）；
        # 全部为无 node 的注记条目=声明维度被跳过（注记允许，但不得替代断言）
        raw_btn = rules.get("buttons")
        btn_rules: list[dict] = []
        if not isinstance(raw_btn, list):
            ctx.block(f"规则 buttons 非列表（{type(raw_btn).__name__}）——证据损坏")
        else:
            for b in raw_btn:
                if not isinstance(b, dict):
                    ctx.block(f"规则 buttons 存在非对象条目: {b!r}——证据损坏")
                elif b.get("node"):
                    btn_rules.append(b)
            if not btn_rules:
                ctx.block("规则声明 buttons 但无任何带 node 的可比条目——注记条目不得替代断言（声明即须可比）")
        if not has("buttons"):
            ctx.block("规则声明 buttons 但采集无 buttons 段")
        elif btn_rules:
            for name in sorted(set(lg) & set(cg)):
                compare_buttons(ctx, name, lg[name], cg[name], btn_rules)
    if rules.get("resources"):
        if not has("resources"):
            ctx.block("规则声明 resources 但采集无 resources 段")
        else:
            for name in sorted(set(lg) & set(cg)):
                compare_resources(ctx, name, lg[name], cg[name])
    if (rules.get("post_flow") or {}).get("code"):
        if not has("post_flow"):
            ctx.block("规则声明 post_flow 但采集无 post_flow 段")
        else:
            for name in sorted(set(lg) & set(cg)):
                compare_post_flow(ctx, name, lg[name], cg[name])


def compare_formulas(ctx, name, l, c):
    lf, cf = l.get("formulas") or {}, c.get("formulas") or {}
    for f in ctx.rules.get("formulas") or []:
        fid = f["id"]
        lv, cv = lf.get(fid), cf.get(fid)
        key = f"{name}:formula/{fid}"
        if lv is None and cv is None:
            ctx.block(f"公式 {fid} 双端均未采集计算值——证据缺失")
            continue
        if (lv is None) != (cv is None):
            ctx.block(f"公式 {fid} 仅单端采集（legacy={lv} current={cv}）——证据不完整")
            continue
        # 第八轮审计：公式计算值非标量（dict/list）→ BLOCKED——同构垃圾 abs 回退可记假 MATCH
        if nonscalar(lv) or nonscalar(cv):
            ctx.block(f"公式 {fid} 采集值非标量（legacy={type(lv).__name__} current={type(cv).__name__}）——证据损坏")
            continue
        exp = f.get("expected_legacy")
        if exp is not None and lv is not None and not tol_ok(lv, exp, f.get("tolerance")):
            ctx.diff("formula", key, lv, exp, "legacy 与期望不符（老系统基线漂移）")
        if lv is not None and cv is not None:
            if not tol_ok(lv, cv, f.get("tolerance")):
                ctx.diff("formula", key, lv, cv, "新老计算值不一致")
            else:
                ctx.matches.append({"dim": "formula", "key": key})


def compare_routing(ctx, name, l, c):
    lr, cr = l.get("routing") or {}, c.get("routing") or {}
    for r in ctx.rules.get("routing") or []:
        node = str(r["node"])
        lv, cv = lr.get(node), cr.get(node)
        key = f"{name}:routing/{node}"
        if lv is None and cv is None:
            ctx.block(f"路由 {node} 双端未采集")
            continue
        if (lv is None) != (cv is None):  # 单边缺失=证据不完整（与其他维度同口径）
            ctx.block(f"路由 {node} 仅单端采集（legacy={lv} current={cv}）——证据不完整")
            continue
        if not isinstance(lv, list) or not isinstance(cv, list):
            ctx.block(f"路由 {node} 采集值非列表（legacy={type(lv).__name__} current={type(cv).__name__}）——证据损坏")
            continue
        want = r.get("candidates_legacy")
        # 第七轮审计：规则侧字符串会被 sorted(map(str,…)) 字符集合化——候选比对失真（假 FAIL/假 MATCH），规则损坏一律 BLOCKED
        if want is not None and not isinstance(want, list):
            ctx.block(f"路由 {node} candidates_legacy 非列表（{type(want).__name__}）——规则损坏")
            continue
        banned_raw = r.get("must_not_contain")
        if banned_raw is not None and not isinstance(banned_raw, list):
            ctx.block(f"路由 {node} must_not_contain 非列表（{type(banned_raw).__name__}）——字符串被字符集合化=禁含断言静默失效，规则损坏")
            continue
        banned = set(map(str, banned_raw or []))
        if want is not None and sorted(map(str, lv)) != sorted(map(str, want)):
            ctx.diff("routing", key, lv, want, "legacy 候选与契约不符")
        if sorted(map(str, lv)) != sorted(map(str, cv)):
            ctx.diff("routing", key, lv, cv, "新老候选集不一致")
        if banned and banned & set(map(str, cv)):
            ctx.diff("routing", key, lv, cv, f"出现禁含候选 {sorted(banned & set(map(str, cv)))}")
        else:
            ctx.matches.append({"dim": "routing", "key": key})


def compare_buttons(ctx, name, l, c, btn_rules):
    lb, cb = l.get("buttons") or {}, c.get("buttons") or {}
    for r in btn_rules:
        node, key = str(r["node"]), f"{name}:buttons/{r['node']}"
        raw_l, raw_c = lb.get(node), cb.get(node)
        # 第六轮审计：可见按钮集必须是列表——字符串等非列表值会被 set(map(str,…)) 字符集合化，
        # 双端同字符串可产出假 MATCH（类型畸形证据，与 routing 非列表检查同口径 → BLOCKED）
        if (raw_l is not None and not isinstance(raw_l, list)) or (raw_c is not None and not isinstance(raw_c, list)):
            ctx.block(f"按钮 {node} 采集值非列表（legacy={type(raw_l).__name__} current={type(raw_c).__name__}）——证据损坏")
            continue
        lset, cset = set(map(str, raw_l or [])), set(map(str, raw_c or []))
        if not lset and not cset:
            ctx.block(f"按钮 {node} 双端未采集可见集")
            continue
        if not lset or not cset:
            ctx.block(f"按钮 {node} 仅单端采集（legacy={sorted(lset)} current={sorted(cset)}）")
            continue
        # 第七轮审计：expect_visible/expect_hidden 非列表（字符串等）会被字符集合化——
        # 禁含/可见断言静默失效记假 MATCH（与 must_not_contain 同族），规则损坏一律 BLOCKED
        vis_raw, hid_raw = r.get("expect_visible"), r.get("expect_hidden")
        if (vis_raw is not None and not isinstance(vis_raw, list)) or (hid_raw is not None and not isinstance(hid_raw, list)):
            ctx.block(f"按钮 {node} expect_visible/expect_hidden 非列表（legacy={type(vis_raw).__name__} hidden={type(hid_raw).__name__}）——规则损坏")
            continue
        vis, hid = set(map(str, vis_raw or [])), set(map(str, hid_raw or []))
        if vis and not vis <= cset:
            ctx.diff("buttons", key, sorted(lset), sorted(cset), f"expect_visible 缺失: {sorted(vis - cset)}")
        if hid & cset:
            ctx.diff("buttons", key, sorted(lset), sorted(cset), f"expect_hidden 出现: {sorted(hid & cset)}")
        if lset != cset:
            ctx.diff("buttons", key, sorted(lset), sorted(cset), "新老可见按钮集不一致")
        else:
            ctx.matches.append({"dim": "buttons", "key": key})


def compare_post_flow(ctx, name, l, c):
    lp, cp = l.get("post_flow") or {}, c.get("post_flow") or {}
    key = f"{name}:post_flow"
    reg_l, reg_c = lp.get("registered"), cp.get("registered")
    if reg_l is None and reg_c is None:
        ctx.block("post_flow 双端未采集 registered")
        return
    if reg_l is None or reg_c is None:
        ctx.block(f"post_flow 仅单端采集 registered（legacy={reg_l} current={reg_c}）")
        return
    # 第七轮审计：registered 必须布尔——truthy 字符串双端同值此前记 diff"未登记"冒用 FAIL(1)，
    # 类型畸形证据一律 BLOCKED（与 gates passed 只认布尔同口径）
    if not isinstance(reg_l, bool) or not isinstance(reg_c, bool):
        ctx.block(f"post_flow registered 非布尔（legacy={reg_l!r} current={reg_c!r}）——证据损坏（truthy 伪装不判真）")
        return
    if reg_l is not True:
        ctx.diff("post_flow", key, reg_l, reg_c, "老系统未登记待启动（配置应为真）")
    elif reg_l != reg_c:
        ctx.diff("post_flow", key, reg_l, reg_c, "新老登记状态不一致")
    else:
        ctx.matches.append({"dim": "post_flow", "key": key})
    ih_l, ih_c = lp.get("inherits") or {}, cp.get("inherits") or {}
    for k in sorted(set(ih_l) | set(ih_c)):
        if k not in ih_l or k not in ih_c:
            ctx.block(f"post_flow 继承字段 {k} 仅单端采集——证据不完整")
        elif nonscalar(ih_l[k]) or nonscalar(ih_c[k]):
            # 第八轮审计：继承值非标量=类型畸形证据——str() 化后同构垃圾可记假 MATCH
            ctx.block(f"post_flow 继承字段 {k} 采集值非标量（legacy={type(ih_l[k]).__name__}）——证据损坏")
        elif str(ih_l[k]) != str(ih_c[k]):
            ctx.diff("post_flow", f"{key}/{k}", ih_l[k], ih_c[k], "继承值不一致")


def compare_resources(ctx, name, l, c):
    lres, cres = l.get("resources") or {}, c.get("resources") or {}
    for r in ctx.rules.get("resources") or []:
        rid, key = r["id"], f"{name}:resource/{r['id']}"
        lv, cv = lres.get(rid), cres.get(rid)
        if lv is None or cv is None:
            ctx.block(f"资源 {rid} 未双端采集（legacy={lv} current={cv}）——证据不完整")
            continue
        # 第八轮审计：资源状态值非标量=类型畸形证据——str() 化后同构垃圾可记假 MATCH
        if nonscalar(lv) or nonscalar(cv):
            ctx.block(f"资源 {rid} 采集值非标量（legacy={type(lv).__name__} current={type(cv).__name__}）——证据损坏")
            continue
        if str(lv) != str(cv):
            ctx.diff("resource", key, lv, cv, "占用/释放状态不一致")
        else:
            ctx.matches.append({"dim": "resource", "key": key})


if __name__ == "__main__":
    # 第五轮审计：对拍器任何未预期异常（outdir 被占/只读等）一律折为 BLOCKED(2)——
    # 绝不允许 crash 以 exit 1 冒用 FAIL 结论码（与用法错误/结论码严格区分）
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        import traceback

        traceback.print_exc()
        print(f"[field-compare] BLOCKED: 对拍器内部异常（fail-closed，不产出结论）: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
