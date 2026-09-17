#!/usr/bin/env python3
# rule_operation_closure.py · P2 规则前置操作可达性检查（s2 Gate 通用防线）
# =============================================================================
# 事故来源：治理服务 P2a——R6 要求"先停用（DISABLED）才可删除"、错误码
# ELEMENT_NOT_DISABLED 依赖停用操作，但 toggle 端点只有接口概览行、无字段级契约；
# 五角色两轮评审 + s2/df_validate 全部门禁漏过（正向追溯覆盖不到"规则→接口"反向可达性）。
#
# 检查原理（领域无关、保守触发，避免名词性提及误报）：
#   1. 从业务规则表（| Rn | 分类 | 规则描述 | 错误处理 |）与"错误码→行为"文本中，
#      仅按明确的"前置依赖句式"提取操作词（先X/需X/X才可/未X返回/X后才…），
#      并绑定规则句中的业务对象（v3.26.7：「要素需先停用」不得被「停用字典」满足）；
#   2. 在接口章收集操作清单（METHOD + 路径 + 操作名，含 design.json apis[].name）；
#   3. 每个前置操作必须命中操作名或路径片段（内置常见 REST 动作映射）且满足
#      业务对象绑定，或规则行显式声明"复用 §x.y / 无独立端点（…）"豁免；缺失即 FAIL。
#
# 用法: rule_operation_closure.py --design <design.md> [--design-json <design.json>]
# 退出码: 0=PASS  1=FAIL（打印缺失操作与规则行号）
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# 前置依赖句式 → 捕获操作词（1~6 个中文字符）。保守：只认明确依赖措辞。
# v3.26.9: 模式 2 去掉"未 前必须是中文字符"的守卫——"要素未停用时拒绝删除"这类
# 带对象前缀的常见句式曾被整体漏抽（守卫本意防跨词误配，但误杀远多于收益）；
# CN 改惰性捕获（防"停用时"被吞成操作词），尾部补全 时/则/先 + 返回/拒绝 变体。
CN = r"[\u4e00-\u9fa5]{1,6}"
DEP_PATTERNS = [
    re.compile(rf"(?:^|[^\u4e00-\u9fa5])(?:需(?:要)?先|先)({CN})(?:才(?:可|能)|后(?:才|可|能)|再)"),
    re.compile(r"未([\u4e00-\u9fa5]{1,6}?)(?:先?返回|先?拒绝|时返回|则返回|时拒绝|则拒绝|时拒|则拒)"),
    re.compile(rf"(?:^|[^\u4e00-\u9fa5])({CN})才可(?:删除|修改|发布|提交|编辑|执行|操作)"),
    re.compile(rf"(?:前置|前提)[^。；|]{{0,12}}(?:调|执行|完成)({CN})"),
]
# 常见中文操作词 → REST 路径片段（小写子串匹配，任一命中即可达）
REST_HINTS = {
    "停用": ["toggle", "disable", "status"],
    "启用": ["toggle", "enable", "status"],
    "恢复": ["restore"],
    "重放": ["replay"],
    "作废": ["deprecate"],
    "二次鉴权": ["challenge"],
    "鉴权": ["challenge", "auth"],
    "审批": ["approve"],
    "确认": ["confirm"],
    "撤销": ["revoke", "cancel", "undo"],
    "回滚": ["rollback", "new-version"],
    "补录": ["reference", "backfill"],
    "重试": ["retry", "replay"],
    "上传": ["upload"],
    "下载": ["download"],
    "导入": ["import"],
    "导出": ["export"],
}
# 不作操作用词（依赖句式误捕获的虚词/状态词）
STOP_WORDS = {"其", "该", "此", "本", "对", "被", "将", "把", "时", "后", "前", "中",
              "成功", "失败", "异常", "完成", "处理", "操作", "校验", "检查", "确认状态"}

RULE_ROW = re.compile(r"^\|\s*R?(\d{1,2})\s*\|")
EXEMPT = re.compile(r"(?:复用|见|参见|无独立端点|同 §|同§|不单独(?:提供|设计))")


def extract_rules(text: str):
    """返回 [(line_no, rule_id_or'', raw_line)]：规则表行 + 含错误码前置语义的散文行。"""
    out = []
    for i, ln in enumerate(text.splitlines(), 1):
        if RULE_ROW.match(ln):
            # v3.26.5: 标签双写修复——单元格已是 R6 时不再输出 RR6
            rid = ln.split("|")[1].strip()
            out.append((i, rid if rid.startswith("R") else f"R{rid}", ln))
        elif re.search(r"未[\u4e00-\u9fa5]{1,6}(?:返回|时拒)", ln) and ("|" in ln or "错误" in ln):
            out.append((i, "", ln))
    return out


# 业务对象提取辅助（v3.26.7）：尾随引导/时间/虚词与动词需剥离，只留对象名词。
# 保守优先——剥完不足 2 字即放弃绑定（宁漏绑不误绑）。
_FILLER_TAIL = "需要先时后前中"
_FILLER_HEAD = "其该此本对被将把"
_VERB_WORDS = ("删除", "修改", "编辑", "发布", "提交", "执行", "操作", "停用", "启用",
               "恢复", "导出", "导入", "上传", "下载", "审批", "撤销", "回滚", "重放",
               "作废", "补录", "重试", "确认", "校验", "检查", "鉴权", "调整", "变更",
               "迁移", "同步")


def _clean_object(raw: str) -> str:
    obj = raw
    while obj and obj[-1] in _FILLER_TAIL:
        obj = obj[:-1]
    changed = True
    while changed and obj:
        changed = False
        for v in _VERB_WORDS:
            if obj.endswith(v) and len(obj) > len(v):
                obj = obj[: -len(v)]
                changed = True
                break
    changed = True
    while changed and obj:  # v3.26.8: 前导动词剥离（"删除要素"→"要素"）
        changed = False
        for v in _VERB_WORDS:
            if obj.startswith(v) and len(obj) > len(v):
                obj = obj[len(v):]
                changed = True
                break
    while len(obj) > 1 and obj and obj[0] in _FILLER_HEAD:
        obj = obj[1:]
    if len(obj) < 2 or obj in STOP_WORDS:
        return ""
    return obj


# 条件/引导标记：主语提取在遇到它们时截断（"要素在草稿状态时需先停用" → 主语"要素"）。
# 注意不含"要"——"要素"本身以"要"开头；"需要"由"需"覆盖。
_SUBJECT_BREAK = "在当需先才未时后前"


def _line_subjects(line: str) -> set[str]:
    """v3.26.8: 句子级业务对象提取——按分隔符切段后取段首中文主语，
    在条件/引导标记处截断并清洗。修复"对象仅从命中局部句式取值"导致的
    状态条件隔断（"要素在草稿状态时需先停用"的"要素"先于条件词，局部
    before-context 取不到；错误码分支"未停用返回"更无对象可继承）。"""
    subs: set[str] = set()
    for seg in re.split(r"[|；;。，,]", line):
        m = re.match(r"[\s（）()\[\]]*([\u4e00-\u9fa5]{1,6})", seg)
        if not m:
            continue
        run = m.group(1)
        idx = len(run)
        for i, ch in enumerate(run):
            if ch in _SUBJECT_BREAK:
                idx = i
                break
        obj = _clean_object(run[:idx])
        # v3.26.8: 纯动词段丢弃——表格"分类"列（| R6 | 删除 | …）与动词性段首
        # （"导出/删除"）不得当作业务对象被继承（2 字动词与词表等长，清洗剥不掉）。
        if obj and obj not in _VERB_WORDS:
            subs.add(obj)
    return subs


def extract_operations(rule_line: str):
    """返回 {op: {"strong": bool, "objects": set[str]}}。
    strong=「未X返回错误码」式硬前置（必须有字段级契约）；
    objects=规则句中与该操作绑定的业务对象（v3.26.7 局部捕获前缀 + v3.26.8 句子级
    主语继承，防"要素停用"被"停用字典"满足）。"""
    ops: dict[str, dict] = {}
    line_objects = _line_subjects(rule_line)

    def _add(op: str, strong: bool, objects: set[str]) -> None:
        ent = ops.setdefault(op, {"strong": False, "objects": None})
        ent["strong"] = ent["strong"] or strong
        if ent["objects"] is None:
            ent["objects"] = set()
        ent["objects"] |= {o for o in objects if o}

    for idx, pat in enumerate(DEP_PATTERNS):
        for m in pat.finditer(rule_line):
            raw = m.group(1)
            w = raw[:-1] if raw.endswith("先") else raw  # "未停用先返回"→停用
            objects: set[str] = set()
            # 对象来源 ①：捕获内部前缀（模式 3「要素需先停用」整句）
            for kw in ("需要先", "需先", "需要", "需", "先"):
                if kw in w:
                    obj = _clean_object(w.split(kw)[0])
                    if obj:
                        objects.add(obj)
                    w = w.split(kw)[-1]
                    break
            # v3.26.6: 条件句式收敛——"X通过/完成才可Y"类条件不是操作，剥离状态后缀；
            # 校验类条件规范化为 skip 词"校验"（reachable 内置放行，防假 FAIL）。
            for suf in ("通过", "完成", "成功", "失败", "有效", "正常"):
                if w.endswith(suf) and len(w) > len(suf):
                    w = w[: -len(suf)]
                    break
            if w.endswith(("校验", "检查")):
                w = "校验"
            # v3.26.9: 纯条件词丢弃——"未通过返回"/"未完成返回"的"通过/完成"是条件
            # 不是操作（后缀剥离管不到等长词）。
            if w in ("通过", "完成", "成功", "失败", "有效", "正常"):
                continue
            # 剥离前导虚词/指代词
            while len(w) > 2 and w[0] in "其该此本对被将把时后中":
                w = w[1:]
            if w in STOP_WORDS or len(w) < 2:
                continue
            strong = idx == 1  # 模式 2：未X返回/拒绝
            objects.discard(w)
            _add(w, strong, objects)
    # v3.26.8: 局部无对象的操作继承句子级主语（错误码分支"未停用返回"的"停用"
    # 继承首句"要素在草稿状态时…"的主语"要素"）
    for op, ent in ops.items():
        if not ent["objects"] and line_objects:
            ent["objects"] = {o for o in line_objects if o != op}
    return ops


def collect_api_surface(text: str, design_json: dict | None) -> tuple[str, list[tuple[str, str, str]]]:
    """返回 (接口章文本, [(method,path,name)…])——可达性只认真实端点，不认散文含字。"""
    m = re.search(r"^##\s*§?5\b.*$", text, re.M)
    n = re.search(r"^##\s*§?6\b.*$", text, re.M)
    if m:
        api_text = text[m.start():n.start()] if n else text[m.start():]
    else:
        api_text = text
    ops: list[tuple[str, str, str]] = []
    seen = set()
    if design_json:
        for a in design_json.get("apis", []):
            key = (str(a.get("method", "")), str(a.get("path", "")), str(a.get("name", "")))
            if key not in seen:
                seen.add(key); ops.append(key)
    # | 子域 | METHOD | /path | 操作名 | 权限 | 风格的概览表
    for ln in api_text.splitlines():
        cells = [c.strip() for c in ln.split("|")]
        if len(cells) >= 6 and re.search(r"\b(GET|POST|PUT|DELETE|PATCH)\b", ln):
            mm = re.search(r"\b(GET|POST|PUT|DELETE|PATCH)\b", ln)
            method = mm.group(1) if mm else ""
            path, name = cells[3], cells[4]
            key = (method, path, name)
            if path.startswith("/") and key not in seen:
                seen.add(key); ops.append(key)
    return api_text, ops


def reachable(op: str, api_text: str, ops: list[tuple[str, str, str]],
              design_json: dict | None, strong: bool,
              objects: set[str] | None = None) -> tuple[bool, str]:
    """返回 (可达, 级别)。strong=True 时必须命中详定义/design.json，仅概览行不够。
    v3.26.7: objects 非空时端点必须绑定同一业务对象（防"要素停用"被"停用字典"满足）。"""
    if op in ("校验", "检查"):
        return True, ""
    objects = objects or set()

    def obj_ok(name: str, path: str) -> bool:
        if not objects:
            return True
        return any(o in name or o in path for o in objects)

    hints = REST_HINTS.get(op, [])
    in_overview = False
    for method, path, name in ops:
        low = (path + " " + name).lower()
        if (op in name or any(h in low for h in hints)) and obj_ok(name, path):
            in_overview = True
            break
    if op in ("停用", "启用") and any(
        "启停" in name and obj_ok(name, path) for _, path, name in ops
    ):
        in_overview = True
    if not in_overview:
        if objects:
            return False, f"无同业务对象端点（对象：{'、'.join(sorted(objects))}）"
        return False, "无端点"
    if not strong:
        return True, ""
    # 强前置：必须有字段级契约（design.json apis 来自详定义节）。
    # 排除跨域误匹配：要素的"停用"不能被"启停相似规则/启停策略/启停渠道"满足——
    # 命中名含他域对象词而规则行本身不含该词时，不算可达。
    OTHER_DOMAIN = ("相似", "策略", "规则", "渠道", "流程", "任务")
    if design_json:
        for a in design_json.get("apis", []):
            name = str(a.get("name", ""))
            path = str(a.get("path", ""))
            hit = (op in name) or (op in ("停用", "启用") and "启停" in name)
            if not hit or not obj_ok(name, path):
                continue
            cross = [d for d in OTHER_DOMAIN if d in name]
            if cross:  # 端点属他域；规则上下文（错误码/路径）须显式同域才算
                continue
            return True, ""
    return False, "仅概览行，无字段级契约"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--design", required=True)
    ap.add_argument("--design-json", default=None)
    args = ap.parse_args()

    text = Path(args.design).read_text(encoding="utf-8", errors="replace")
    dj = None
    if args.design_json and Path(args.design_json).exists():
        try:
            dj = json.loads(Path(args.design_json).read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            dj = None
    api_text, api_ops = collect_api_surface(text, dj)

    missing: list[str] = []
    for line_no, rid, line in extract_rules(text):
        if EXEMPT.search(line):
            continue
        for op, meta in extract_operations(line).items():
            ok, why = reachable(op, api_text, api_ops, dj, meta["strong"], meta["objects"])
            if not ok:
                tag = "强前置" if meta["strong"] else "前置"
                missing.append(f"L{line_no} {rid}: {tag}操作「{op}」{why}（规则：{line[:90]}）")

    if missing:
        print(f"[FAIL] rule_operation_closure: {len(missing)} 个规则前置操作无契约落点")
        for m in missing:
            print("  - " + m)
        print("  修复：补接口字段级契约，或在规则行显式声明复用（复用 §x.y / 无独立端点（理由））")
        return 1
    print("[PASS] rule_operation_closure: 规则前置操作在接口章均可达")
    return 0


if __name__ == "__main__":
    sys.exit(main())
