# -*- coding: utf-8 -*-
"""详设 JSON → Markdown 渲染器。

把 validate_design.py 校验通过的 detail_design.json 渲染成可读的《模块详细设计》
Markdown 文档，供人工评审与归档。与校验器的分工：脚本出确定性层（章节编号、
统计计数、表格行列、空值占位话术），AI 出语义层（JSON 里的内容本身已由 AI 填好）。

设计取舍：不依赖 Jinja2 等第三方模板库（保持 skill 自包含），直接用 f-string
拼装——章节结构固定，模板引擎收益不大。

用法：
  python render_design.py --input detail_design.json --out 详细设计.md
  python render_design.py --input detail_design.json --out 详细设计.md --max-rules 20
    （单 chunk 规则/接口过多时截断展示并注明总数，防表格爆炸；默认不截断）
"""
import argparse
import json
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_KIND_LABEL = {"unresolved": "未决", "conflict": "矛盾", "gap": "缺口"}


def _esc(s):
    """Markdown 表格单元格转义：竖线会破坏表格结构。"""
    return (s or "").replace("|", "\\|").replace("\n", " ")


def _status_badge(status):
    # 详设只收 COMPLETE（校验器强制）；其余值仅为防御性透传
    return "✅ COMPLETE" if status == "COMPLETE" else status


def render(data, max_rows=None):
    L = []
    w = L.append

    meta = data["meta"]
    w(f"# {meta['moduleName']} 详细设计")
    w("")
    w(f"> 模板 {meta['templateId']} v{meta['templateVersion']} ｜ 状态：{meta['status']} ｜ 生成日期：{meta['generatedAt']}")
    w(f">")
    w(f"> 依据基线：{meta['baseline']} ｜ 源文档：{meta.get('sourceDoc', '—')}")
    w("")

    # —— 0. 元信息 ——
    w("## 0. 文档元信息")
    w("")
    w("| 项 | 值 |")
    w("| --- | --- |")
    for k, label in [("moduleCode", "模块编码"), ("moduleName", "模块名称"), ("ownerService", "归属服务"),
                     ("scope", "覆盖范围"), ("status", "状态"), ("docs", "产出文件")]:
        v = meta[k]
        v = "、".join(v) if isinstance(v, list) else v
        w(f"| {label} | {_esc(v)} |")
    w("")

    # —— 1. 架构与技术栈 ——
    arch = data["architecture"]
    w("## 1. 架构与技术栈")
    w("")
    style_label = {"monolith": "单体", "microservice": "微服务", "frontend-only": "纯前端", "unknown": "未声明(见未决问题)"}
    w(f"- **架构形态**：{style_label.get(arch['style'], arch['style'])}"
      + (f"（服务：{'、'.join(arch['services'])}）" if arch.get("services") else ""))
    w(f"- **模块划分**：{'、'.join(arch['modules'])}")
    w(f"- **溯源**：{_esc(arch['evidence'])}")
    w("")
    w("| 技术项 | 选型 | 溯源 |")
    w("| --- | --- | --- |")
    for t in data["techStack"]:
        w(f"| {_esc(t['item'])} | {_esc(t['value'])} | {_esc(t['sourceSection'])} |")
    w("")

    # —— 3. 验收总分 ——
    acc = data["acceptance"]
    total = sum(len(c.get("acceptances", [])) for c in data["chunks"])
    w("## 2. 验收覆盖总览")
    w("")
    w(f"- PRD 声明验收条目：**{acc['declared']}**（{_esc(acc['evidence'])}）")
    w(f"- 已设计条目：**{total}**（全部 COMPLETE）")
    if acc["declared"] > total:
        w(f"- 差额：**{acc['declared'] - total}** 条（未展开原因见 prd_issues.json 问题清单）")
    w("")

    # —— 4. 前端页面设计 ——
    fe = data.get("frontend") or {}
    if fe.get("pages"):
        w("## 3. 前端页面设计")
        w("")
        w("### 3.1 页面清单")
        w("")
        w("| 页面 | 模块 | 路由 | 组件 | 类型 | 权限 |")
        w("| --- | --- | --- | --- | --- | --- |")
        for p in fe["pages"]:
            w(f"| {_esc(p['name'])} | {_esc(p.get('module', '—'))} | {_esc(p['route'])} | {_esc(p['component'])} | {_esc(p['type'])} | {_esc(p['permission'])} |")
        w("")
        if fe.get("interactions"):
            w("### 3.2 关键页面交互设计")
            w("")
            for it in fe["interactions"]:
                topic = f"（{it['topic']}）" if it.get("topic") else ""
                src_s = f" ｜ 溯源：{_esc(it['sourceSection'])}" if it.get("sourceSection") else ""
                w(f"- **{it['page']}{topic}**{src_s}")
                for seg in it["content"].split("；"):
                    seg = seg.strip()
                    if seg:
                        w(f"  - {seg}")
                if it.get("columns"):
                    w("")
                    w(f"  **表格列（{it['page']}）：**")
                    w("")
                    w("  | 字段 | 列标题 | 渲染说明 |")
                    w("  | --- | --- | --- |")
                    for cdef in it["columns"]:
                        w(f"  | {_esc(cdef['field'])} | {_esc(cdef['label'])} | {_esc(cdef['note'])} |")
                if it.get("formFields"):
                    w("")
                    w(f"  **表单控件（{it['page']}）：**")
                    w("")
                    w("  | 字段 | 标签 | 控件 | 校验与提示 | 候选来源 |")
                    w("  | --- | --- | --- | --- | --- |")
                    for f in it["formFields"]:
                        w(f"  | {_esc(f['field'])} | {_esc(f['label'])} | {_esc(f['control'])} | {_esc(f['rule'])} | {_esc(f['source'])} |")
            w("")
        if fe.get("dialogs"):
            w("### 3.3 弹窗/抽屉映射表")
            w("")
            w("| 页面·交互 | 组件 | 接口 | 关键状态/确认流 |")
            w("| --- | --- | --- | --- |")
            for d in fe["dialogs"]:
                w(f"| {_esc(d['scene'])} | {_esc(d['component'])} | {_esc(d['apiRef'])} | {_esc(d['notes'])} |")
            w("")

    if fe.get("contracts"):
        ct = fe["contracts"]
        w("### 3.4 全局前端契约")
        w("")
        for label, key in [("路由与守卫", "routing"), ("状态管理(Pinia)", "state"), ("API 封装", "apiClient"),
                           ("错误映射(bizCode→行为)", "errorMapping"), ("权限控制", "permission"), ("复用与公共抽取", "reusedComponents")]:
            w(f"- **{label}**：{_esc(ct[key])}")
        w("")

    # —— 5+. 各 chunk ——
    for c in data["chunks"]:
        cid, ch = c["chunkId"], c["chapter"]
        ctx = f"（支撑：{'；'.join(c['contextFrom'])}）" if c.get("contextFrom") else ""
        w(f"## {cid} {ch}")
        w("")
        w(f"> 溯源：{_esc(c['sourceSection'])}{_esc(ctx)}")
        w("")

        if c.get("modules"):
            w(f"### {cid}.1 模块")
            w("")
            w("| 模块 | 职责 | 溯源 |")
            w("| --- | --- | --- |")
            for m in c["modules"]:
                w(f"| {_esc(m['name'])} | {_esc(m['summary'])} | {_esc(m['sourceSection'])} |")
            w("")

        if c.get("rules"):
            rules = c["rules"]
            w(f"### {cid}.2 业务规则（{len(rules)} 条）")
            w("")
            w("| 规则编号 | 源编号 | 规则内容 | 分类 | 失败面 | 溯源 |")
            w("| --- | --- | --- | --- | --- | --- |")
            shown = rules if max_rows is None else rules[:max_rows]
            for r in shown:
                w(f"| {r['ruleId']} | {_esc(r['sourceRuleId'])} | {_esc(r['text'])} | {_esc(r.get('category', '—'))} | {_esc(r['errorCase'])} | {_esc(r['sourceSection'])} |")
            if len(shown) < len(rules):
                w(f"| … | | 其余 {len(rules) - len(shown)} 条见 JSON（展示截断） | | | |")
            w("")

        if c.get("apis"):
            apis = c["apis"]
            http_apis = [a for a in apis if a.get("method", "").strip().upper() in ("GET", "POST", "PUT", "PATCH", "DELETE")]
            w(f"### {cid}.3 接口/操作（{len(apis)} 条）")
            w("")
            w("| 方式 | 标识/路径 | 用途 | 权限 | 溯源 |")
            w("| --- | --- | --- | --- | --- |")
            shown = apis if max_rows is None else apis[:max_rows]
            for a in shown:
                w(f"| {_esc(a['method'])} | {_esc(a['path'])} | {_esc(a['purpose'])} | {_esc(a.get('permission', '—'))} | {_esc(a['sourceSection'])} |")
            if len(shown) < len(apis):
                w(f"| … | 其余 {len(apis) - len(shown)} 条见 JSON（展示截断） | | | |")
            w("")
            # HTTP 接口展开完整契约（请求/响应字段表 + 示例 + 错误 + 断言）
            for n, a in enumerate([a for a in shown if a in http_apis], start=1):
                w(f"#### {cid}.3.{n} {a['method']} {a['path']} — {_esc(a['purpose'])}")
                w("")
                for label, key, cols in [
                    ("请求字段", "requestFields", ("字段", "类型", "必填", "校验规则", "数据来源", "脱敏")),
                    ("响应字段", "responseFields", ("字段", "类型", "恒出性", "取值规则", "数据来源", "脱敏")),
                ]:
                    fields = a.get(key, [])
                    w(f"**{label}：**")
                    w("")
                    if fields:
                        w("| " + " | ".join(cols) + " |")
                        w("| " + " | ".join([" --- "] * len(cols)) + " |")
                        for f in fields:
                            w(f"| {_esc(f['field'])} | {_esc(f['type'])} | {_esc(f['required'])} | {_esc(f['rule'])} | {_esc(f['source'])} | {_esc(f['masked'])} |")
                    else:
                        w("无。")
                    w("")
                if a.get("requestExample"):
                    w("**请求：**")
                    w("")
                    w("```http")
                    w(a["requestExample"])
                    w("```")
                    w("")
                if a.get("responseExample"):
                    w("**响应：**")
                    w("")
                    w("```json")
                    w(a["responseExample"])
                    w("```")
                    w("")
                if a.get("errors"):
                    w(f"**错误响应：** {'；'.join(a['errors'])}")
                    w("")
                if a.get("assertions"):
                    w(f"断言：{_esc(a['assertions'])}")
                    w("")

        if c.get("tables"):
            w(f"### {cid}.4 表结构（{len(c['tables'])} 张）")
            w("")
            for t in c["tables"]:
                w(f"#### {t['name']}（{_esc(t['purpose'])}）")
                w("")
                w("| 字段名 | 类型 | 约束 | 默认值 | 口径说明 |")
                w("| --- | --- | --- | --- | --- |")
                for f in t["fields"]:
                    w(f"| {_esc(f['name'])} | {_esc(f['type'])} | {_esc(f['constraint'])} | {_esc(f['default'])} | {_esc(f['note'])} |")
                w("")
                if t.get("indexes"):
                    w(f"**索引：** {'、'.join('`' + i + '`' for i in t['indexes'])}")
                    w("")
                w(f"> 溯源：{_esc(t['sourceSection'])}")
                w("")

        if c.get("nfrs"):
            w(f"### {cid}.5 非功能设计（{len(c['nfrs'])} 条）")
            w("")
            w("| 维度 | 要求 | 目标 | 溯源 |")
            w("| --- | --- | --- | --- |")
            for n in c["nfrs"]:
                w(f"| {n['dimension']} | {_esc(n['requirement'])} | {_esc(n['target'])} | {_esc(n['sourceSection'])} |")
            w("")

        if c.get("acceptances"):
            accs = c["acceptances"]
            w(f"### {cid}.6 验收标准（{len(accs)} 条）")
            w("")
            w("| 编号 | 验收内容 | 规则引用 | 关联 | 状态 | 溯源 |")
            w("| --- | --- | --- | --- | --- | --- |")
            shown = accs if max_rows is None else accs[:max_rows]
            for a in shown:
                rule_refs = "、".join(a.get("ruleRefs", [])) or "—"
                other = "；".join(
                    ["、".join(a.get("apiRefs", [])), "、".join(a.get("tableRefs", []))]
                ).strip("；") or "—"
                w(f"| {a['acceptanceId']} | {_esc(a['text'])} | {rule_refs} | {_esc(other)} | {_status_badge(a['status'])} | {_esc(a['sourceSection'])} |")
            if len(shown) < len(accs):
                w(f"| … | 其余 {len(accs) - len(shown)} 条见 JSON（展示截断） | | | | |")
            w("")

    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description="详设 JSON → Markdown 渲染器")
    ap.add_argument("--input", required=True, help="已通过校验的 detail_design.json 路径")
    ap.add_argument("--out", required=True, help="输出的 Markdown 路径")
    ap.add_argument("--max-rows", type=int, default=None, help="每个表格最多展示行数（默认不截断）")
    args = ap.parse_args()

    data = json.loads(Path(args.input).read_text(encoding="utf-8"))
    md = render(data, max_rows=args.max_rows)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(md, encoding="utf-8")
    print(f"渲染完成：{out}（{len(md.splitlines())} 行）")
    sys.exit(0)


if __name__ == "__main__":
    main()
