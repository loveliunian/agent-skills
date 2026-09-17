#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_design_doc_quality.py · 详设正文质量 lint（local-patch:design-quality v1）。

项目内容充分性检查——规则来源 phases/02-详细设计.md「local-patch:design-quality」：
  ① 交叉引用闭环：正文数字引用（§5.3.N）必须指向真实小节（重编号须全文同步）；
  ② 规则引用闭环：§3 每条 R 规则必须被至少一个流程的 `[Rn]` 标注引用
     （确属横切约束的须在规则文件显式登记例外）；
  ③ 接口消费闭环：§7.2 页面映射须消费全部接口详细定义节
     （纯内部端点在项目 lint 规则白名单登记）。

用法：
  python3 check_design_doc_quality.py docs/详细设计/<feature>-详细设计.md \
      [--rules docs/design-quality-rules.json] [--root .]

规则文件（可选，缺省用全部默认口径）：
  {
    "allow_unresolved_refs": ["§9.9.9"],
    "rules_without_flow_ref": ["R7"],
    "internal_endpoints": ["3.2.6"],
    "api_detail_parent": "3.2",
    "page_mapping_anchor": "7.2"
  }

退出码：0=通过；1=存在违规（〔DQ-nnn〕逐条列出）；2=用法错误。
项目侧挂载约定：存在本脚本时，P2/P2a 与其链式执行，任一非零即 BLOCKED。
"""
import argparse
import json
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_HEADING_RE = re.compile(r"^#{1,6}\s+(?:\*\*)?\s*§?([0-9]+(?:\.[0-9]+)*)(?!\.?[0-9])")
_SECTION_REF_RE = re.compile(r"§([0-9]+(?:\.[0-9]+)+)")
_RULE_DEF_TABLE_RE = re.compile(r"^\|\s*(R[0-9]+)\s*\|")
_RULE_DEF_BARE_RE = re.compile(r"^(R[0-9]+)[\.：:]")


def load_doc(path):
    lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    body, fenced = [], []
    in_fence, marker = False, ""
    for ln in lines:
        s = ln.strip()
        if s.startswith("```") or s.startswith("~~~"):
            if not in_fence:
                in_fence, marker = True, s[:3]
            elif s.startswith(marker):
                in_fence = False
            continue
        fenced.append(not in_fence)
        body.append(ln)
    return body, fenced


def headings_and_sections(body, keep):
    """返回 {编号: 标题行} 与 {编号: 小节正文（含围栏，至下一编号标题）}。"""
    heads, sections = {}, {}
    cur, cur_lines = None, []
    for ln, keep_ln in zip(body, keep):
        s = ln.strip()
        m = _HEADING_RE.match(s)
        if m:
            if cur is not None:
                sections[cur] = "\n".join(cur_lines)
            cur = m.group(1)
            heads[cur] = s
            cur_lines = []
            continue
        if cur is not None:
            cur_lines.append(ln)
    if cur is not None:
        sections[cur] = "\n".join(cur_lines)
    return heads, sections


def main():
    ap = argparse.ArgumentParser(description="详设正文质量 lint（交叉引用/规则引用/接口消费闭环）")
    ap.add_argument("design", help="详设 Markdown 路径")
    ap.add_argument("--rules", default="docs/design-quality-rules.json",
                    help="项目 lint 规则文件（缺省 docs/design-quality-rules.json，不存在即用默认口径）")
    ap.add_argument("--root", default=".", help="规则文件的解析根")
    args = ap.parse_args()

    doc = Path(args.design)
    if not doc.is_file():
        print(f"〔DQ-000〕设计文档不存在: {args.design}")
        sys.exit(1)

    rules = {}
    rp = Path(args.root) / args.rules if not Path(args.rules).is_absolute() else Path(args.rules)
    if rp.is_file():
        try:
            rules = json.loads(rp.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            print(f"〔DQ-000〕规则文件解析失败: {rp}: {e}")
            sys.exit(1)

    allow_refs = set(rules.get("allow_unresolved_refs", []))
    no_flow = set(rules.get("rules_without_flow_ref", []))
    internal_eps = set(rules.get("internal_endpoints", []))
    api_parent = rules.get("api_detail_parent", "3.2")
    mapping_anchor = rules.get("page_mapping_anchor", "7.2")

    body, keep = load_doc(doc)
    heads, sections = headings_and_sections(body, keep)

    violations = []

    # ① 交叉引用闭环：正文 §N.N 引用必须解析到真实标题
    for ln, keep_ln in zip(body, keep):
        if not keep_ln or _HEADING_RE.match(ln.strip()):
            continue
        for m in _SECTION_REF_RE.finditer(ln):
            ref = m.group(1)
            if ref in heads or f"§{ref}" in allow_refs or ref in allow_refs:
                continue
            violations.append(f"〔DQ-001〕交叉引用 §{ref} 不存在（正文: {ln.strip()[:60]}）——重编号须全文同步，或在规则 allow_unresolved_refs 登记例外")

    # ② 规则引用闭环：定义的 Rn 必须被 [Rn] 流程标注引用
    # 定义形态：表格行 | R1 | …，或裸行 R1. …（不含 [Rn] 标注的行才算定义）
    defined, flow_refs = [], set()
    for ln, keep_ln in zip(body, keep):
        if not keep_ln:
            continue
        s = ln.strip()
        m = _RULE_DEF_TABLE_RE.match(s)
        if m:
            defined.append(m.group(1))
        elif m is None:
            m2 = _RULE_DEF_BARE_RE.match(s)
            if m2 and "[" not in s:
                defined.append(m2.group(1))
        for r in re.finditer(r"\[(R[0-9]+)\]", ln):
            flow_refs.add(r.group(1))
    for r in sorted(set(defined)):
        if r in flow_refs or r in no_flow:
            continue
        violations.append(f"〔DQ-002〕规则 {r} 未被任何流程 [Rn] 标注引用——补流程标注，或在规则 rules_without_flow_ref 登记横切例外")

    # ③ 接口消费闭环：接口详细定义节必须被页面映射节消费
    detail_nums = [h for h in heads
                   if h.startswith(api_parent + ".") and len(h.split(".")) > len(api_parent.split("."))]
    mapping_text = sections.get(mapping_anchor, "")
    if detail_nums and not mapping_text:
        violations.append(f"〔DQ-003〕未找到页面映射节 §{mapping_anchor}——无法核对接口消费闭环")
    else:
        for n in detail_nums:
            if n in internal_eps:
                continue
            title = heads.get(n, "")
            if n not in mapping_text and title not in mapping_text:
                violations.append(
                    f"〔DQ-003〕接口详细定义 §{n}（{title[:40]}）未被 §{mapping_anchor} 页面映射消费"
                    f"——补映射，或在规则 internal_endpoints 登记纯内部端点"
                )

    if violations:
        for v in violations:
            print(v)
        print(f"\n设计正文质量 lint 失败：共 {len(violations)} 处。")
        sys.exit(1)
    print(f"设计正文质量 lint 通过（交叉引用/规则引用/接口消费闭环；规则文件: {'项目' if rules else '默认口径'}）。")
    sys.exit(0)


if __name__ == "__main__":
    main()
