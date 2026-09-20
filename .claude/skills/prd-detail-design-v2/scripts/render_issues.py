# -*- coding: utf-8 -*-
"""PRD 问题清单 JSON → Markdown 渲染器（裁决评审版）。

产出《PRD 问题裁决清单》：裁决进度总览 + 未决/矛盾/缺口分组表 + 逐条裁决栏。
问题内容只出现在这里，详设（detail_design.md）零问题残留——两份产物分工：
本文件给"人裁决"，详设给"机器实现"。

用法：
  python render_issues.py --input prd_issues.json --out prd_issues.md
"""
import argparse
import json
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_KIND_LABEL = {"unresolved": "未决", "conflict": "矛盾", "gap": "缺口"}
_STATUS_LABEL = {"open": "🔴 待裁决", "resolved": "✅ 已裁决", "wontfix": "⚪ 不处理"}


def _esc(s):
    return (s or "").replace("|", "\\|").replace("\n", " ")


def render(data):
    L = []
    w = L.append
    meta = data["meta"]
    issues = data["issues"]

    w(f"# PRD 问题裁决清单 — {meta['module']}")
    w("")
    w(f"> 源文档：{meta['sourceDoc']} ｜ 登记日期：{meta['generatedAt']}")
    w("")

    n_open = sum(1 for p in issues if p["status"] == "open")
    n_resolved = sum(1 for p in issues if p["status"] == "resolved")
    n_wontfix = sum(1 for p in issues if p["status"] == "wontfix")
    blocking_open = [p["issueId"] for p in issues if p.get("blocking") and p["status"] == "open"]

    w("## 裁决进度")
    w("")
    w(f"- 共 **{len(issues)}** 条：未决 {sum(1 for p in issues if p['kind']=='unresolved')} ｜ "
      f"矛盾 {sum(1 for p in issues if p['kind']=='conflict')} ｜ 缺口 {sum(1 for p in issues if p['kind']=='gap')}")
    w(f"- 状态：🔴 待裁决 {n_open} ｜ ✅ 已裁决 {n_resolved} ｜ ⚪ 不处理 {n_wontfix}")
    w(f"- **阻塞详设生成的 blocking 问题：{len(blocking_open)} 条**"
      + (f"（{'、'.join(blocking_open)}）" if blocking_open else "——全部已裁决，可生成/更新详设"))
    w("")

    for kind, title in [("conflict", "矛盾（必须裁决，两处口径并列）"),
                        ("unresolved", "未决（PRD 明示待确认）"),
                        ("gap", "缺口（设计维度缺失）")]:
        group = [p for p in issues if p["kind"] == kind]
        if not group:
            continue
        w(f"## {title}（{len(group)} 条）")
        w("")
        w("| 编号 | 问题 | 溯源 | 阻塞 | 影响范围 | 状态 | 裁决口径 |")
        w("| --- | --- | --- | --- | --- | --- | --- |")
        for p in group:
            w(f"| {p['issueId']} | {_esc(p['text'])} | {_esc(p['sourceSection'])} "
              f"| {'⛔' if p.get('blocking') else '—'} | {_esc('、'.join(p.get('affects', [])) or '—')} "
              f"| {_STATUS_LABEL[p['status']]} | {_esc(p.get('resolution', '—') or '—')}"
              + (f"（{_esc(p['decidedBy'])}）" if p.get('decidedBy') else "") + " |")
        w("")

    w("## 裁决说明")
    w("")
    w("- 每条 blocking 问题裁决（status=resolved + resolution 写明口径）后，按 `affects` 列定位详设改动点回填；")
    w("- 裁决全部完成后运行 `run_design.py --issues prd_issues.json …` 生成/更新详设（硬门校验 blocking 全部已裁决）；")
    w("- 本清单是问题内容的唯一载体，详设文档中不出现任何未决/矛盾表述。")
    w("")
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description="PRD 问题清单 JSON → Markdown")
    ap.add_argument("--input", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    data = json.loads(Path(args.input).read_text(encoding="utf-8"))
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render(data), encoding="utf-8")
    print(f"渲染完成：{out}（{len(out.read_text(encoding='utf-8').splitlines())} 行）")
    sys.exit(0)


if __name__ == "__main__":
    main()
