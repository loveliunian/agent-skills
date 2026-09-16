#!/usr/bin/env python3
"""fc_readability.py —— 对比结果人话化共享库（v1.4.0 新增）。

field-level-compare.py（field-compare.md）与 gen-final-report.py（对比测试报告.md）
共用这一份"机器差异 → 人话"翻译实现，禁止两处各写一套（必然漂移）。

职责（纯函数、零 IO、零依赖）：
  - dim_cn(dim)                  维度机器名 → 中文名（字段值/公式计算/环节路由/按钮/资源占用/流程后置）
  - human_reason(dim, reason)    机器 reason → 人话说明（未收录原样透传，绝不编造）
  - diff_case(key) / diff_where(key)
                                 从差异键解析（用例, 位置）——键形态两类：
                                   field:  "<case>/<step>/<legacy字段>-><target字段>"
                                   其他:   "<case>:<维度>/<定位>"（formula/routing/buttons/resource/post_flow）
  - group_by_case(diffs)         差异列表按用例分组（保持原顺序）
  - one_line_conclusion(...)     三态结论 → 一句话人话结论（供报告头部）

设计约束：翻译只改"说法"，不改事实——legacy/current 原值永远原样呈现；
翻译函数对未知输入一律透传/中性描述，绝不猜结论（与 skill fail-closed 哲学一致）。
"""
from __future__ import annotations

DIM_CN = {
    "field": "字段值",
    "formula": "公式计算",
    "routing": "环节路由",
    "buttons": "按钮",
    "resource": "资源占用",
    "post_flow": "流程后置",
    # 容错：field-level-compare 历史上 resources 维度写过 "resources"
    "resources": "资源占用",
}

# 机器 reason → 人话（精确匹配优先，前缀匹配兜底；未命中透传原文）
_REASON_EXACT = {
    "null_policy": "空值不一致（一端为空、另一端有值）",
    "tolerance": "数值不一致（超出允许容差）",
    "新老计算值不一致": "同一个公式，老系统与新系统算出的结果不同",
    "新老候选集不一致": "这一步能流向的下一环节，新老系统不一样",
    "新老可见按钮集不一致": "这一步界面上可点的按钮，新老系统不一样",
    "新老登记状态不一致": "流程办结后的自动发起登记，新老系统状态不一致",
    "占用/释放状态不一致": "同一资源（车辆/磅房等）的占用/释放状态，新老系统不一致",
    "继承值不一致": "流程后置发起的继承字段取值，新老系统不一致",
    "legacy 与期望不符（老系统基线漂移）": "老系统当前算出的值与契约记录的历史基线不符（老系统侧可能发生变化）",
    "老系统未登记待启动（配置应为真）": "老系统办结后没有登记自动发起下一流程（契约认为应该登记）",
}

_REASON_PREFIX = [
    ("expect_visible 缺失", "新系统缺少界面应有的按钮"),
    ("expect_hidden 出现", "新系统出现了本不该出现的按钮"),
    ("出现禁含候选", "出现了契约禁止的路由候选"),
    ("legacy 候选与契约不符", "老系统这一步的路由候选与契约记录不符（老系统侧可能发生变化）"),
]


def dim_cn(dim) -> str:
    return DIM_CN.get(str(dim or ""), str(dim or "未知维度"))


def human_reason(dim, reason) -> str:
    r = str(reason or "")
    if r in _REASON_EXACT:
        return _REASON_EXACT[r]
    for prefix, cn in _REASON_PREFIX:
        if r.startswith(prefix):
            return f"{cn}（{r}）"
    return r


def diff_case(key) -> str:
    """差异键 → 用例名（首段；剥采集文件名 .json 后缀——审计第 1 轮 P2-10）。
    field 键以 '/' 分隔，其余以 ':' 分隔。"""
    k = str(key or "")
    for sep in (":", "/"):
        if sep in k:
            k = k.split(sep, 1)[0]
            break
    return k[:-5] if k.endswith(".json") else k


def diff_where(key) -> str:
    """差异键 → 人话位置（剥用例前缀后的定位段）。"""
    k = str(key or "")
    for sep in (":", "/"):
        if sep in k:
            return k.split(sep, 1)[1]
    return k


def group_by_case(diffs: list) -> dict:
    """差异列表按用例分组（保持原顺序；非 dict 条目忽略）。"""
    out: dict = {}
    for d in diffs or []:
        if isinstance(d, dict):
            out.setdefault(diff_case(d.get("key")), []).append(d)
    return out


def fmt_value(v, limit: int = 60) -> str:
    """差异值 → 人读短串（None→（空）；容器→JSON 短串；超长截断）。"""
    if v is None:
        return "（空）"
    if isinstance(v, (dict, list)):
        try:
            import json as _json
            s = _json.dumps(v, ensure_ascii=False)
        except Exception:
            s = str(v)
    else:
        s = str(v)
    if s == "":
        return "（空）"
    return s if len(s) <= limit else s[: limit - 1] + "…"


def one_line_conclusion(conclusion: str, *, req_done: int = 0, req_total: int = 0,
                        n_diff: int = 0, n_exempted: int = 0, n_failed: int = 0,
                        blocked_reasons: list | None = None,
                        top_diffs: list | None = None) -> str:
    """三态结论 + 统计 → 一句话人话结论（供报告头部；只陈述重算事实，不加观点）。"""
    c = str(conclusion or "").upper()
    if c == "PASS":
        s = f"全部必测用例（{req_done}/{req_total}）双端执行通过，未发现新老系统行为差异"
        if n_exempted:
            s += f"；另有 {n_exempted} 处差异已按契约豁免（有审批记录）"
        return s + "。"
    if c == "FAIL":
        s = f"发现 {n_diff} 处新老系统行为不一致"
        cases = sorted({diff_case(d.get("key")) for d in (top_diffs or []) if isinstance(d, dict)})
        if cases:
            s += f"，集中在用例 {'、'.join(cases[:5])}" + ("等" if len(cases) > 5 else "")
        if n_failed:
            s += f"；另有 {n_failed} 个用例执行失败"
        if n_exempted:
            s += f"（另有 {n_exempted} 处已豁免）"
        return s + "，未达到一致，需要逐条核对下方差异明细。"
    if c == "BLOCKED":
        rs = [str(x) for x in (blocked_reasons or []) if str(x).strip()]
        if rs:
            return f"本次对比未能完成判定：{rs[0][:120]}" + ("等" if len(rs) > 1 else "") + "（环境/数据/证据不足，修复后须换新 run-id 重跑）。"
        return "本次对比未能完成判定（环境/数据/证据不足，fail-closed 不下结论；修复后须换新 run-id 重跑）。"
    return f"结论={conclusion or '未知'}（非三态正式结论，不构成 PASS/FAIL 证据）。"


def diff_digest(d: dict, limit: int = 120) -> str:
    """单条差异 → 一句人话摘要（维度+位置+双端值+原因），供结论速览/一句话结论引用。"""
    dim = d.get("dim")
    return (f"{dim_cn(dim)}【{fmt_value(diff_where(d.get('key')), 40)}】"
            f"老系统={fmt_value(d.get('legacy'), 40)} 新系统={fmt_value(d.get('current'), 40)}"
            f"（{human_reason(dim, d.get('reason'))}）")[:limit]
