# -*- coding: utf-8 -*-
"""prd-lite 阶段四:装配草稿 + 提取全局规则索引/未决问题汇总 + 守恒自检。
用法: python assemble.py <PRD-lite.md> [--workdir .prd-lite] [--drafts drafts]
依赖草稿契约(extraction-rules.md 第 4 节):
  - FUN 块标题 '## FUN-0xx ...',节标题 '### <骨架名>'
  - 规则节 '### 业务规则'(标准表格,首列为规则编号,如 R-xxx)
  - 域内未决问题节 '## 本域未决问题';front 为 '## 未决问题' 或 '## 本域未决问题'
  - 域末 '## 溯源附表'
守恒自检(不过禁止交付):FUN 标题数 == 原文 FUN 总数;规则编号覆盖 == slices 全集中出现过的编号;
未决问题域数 == 域草稿总数;溯源附表覆盖全部 FUN。
"""
import io, json, os, re, sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")


def main():
    argv = sys.argv[1:]
    out = argv[0] if argv else "PRD-lite.md"
    wd = argv[argv.index("--workdir") + 1] if "--workdir" in argv else ".prd-lite"
    ddir = os.path.join(wd, argv[argv.index("--drafts") + 1] if "--drafts" in argv else "drafts")
    cfg = json.load(open(os.path.join(wd, "config.json"), encoding="utf-8"))
    fun_pat = re.compile(cfg.get("funHeading", r"^## (FUN-\d+)"), re.M)
    rid_pat = re.compile(cfg.get("ruleId", r"R-\d{3}"))

    def read(p):
        return open(p, encoding="utf-8").read() if os.path.exists(p) else None

    # 基线:原文 slices 全集中的 FUN 总数与规则编号全集(slices 为原文层级,用宽匹配)
    sdir = os.path.join(wd, "slices")
    src_all = "\n".join(read(os.path.join(sdir, f)) or "" for f in os.listdir(sdir)) if os.path.isdir(sdir) else ""
    fun_token = (cfg.get("funHeading", r"^## (FUN-\d+)").split("(")[-1].rstrip(")"))
    src_funs = set(re.findall(fun_token + r"\b", src_all))
    src_rids = set(rid_pat.findall(src_all))

    order = cfg.get("order", [os.path.splitext(f)[0] for f in sorted(os.listdir(ddir)) if f.endswith(".md")
                              and not f.startswith("99-")])
    drafts = {}
    for name in order:
        md = read(os.path.join(ddir, name + ".md"))
        if md is None:
            print(f"!! 缺草稿: {name}.md")
        else:
            drafts[name] = md
    appendix = read(os.path.join(ddir, "99-appendix.md")) or ""

    def section(md, pat):
        m = re.search(rf"^{pat}\s*$", md, re.M)
        if not m:
            return None
        nxt = re.search(r"^#{1,2} ", md[m.end():], re.M)
        return md[m.end(): m.end() + nxt.start() if nxt else len(md)].strip()

    def tables_in(block):
        rows = [l.strip() for l in block.splitlines() if l.startswith("|")]
        return [r for r in rows if not re.fullmatch(r"\|(\s*:?-+:?\s*\|)+", r)]

    rule_index, open_items, trace_funs = [], {}, set()
    for name, md in drafts.items():
        if name == "00-front":
            txt = section(md, r"## 未决问题") or section(md, r"## 本域未决问题")
            if txt:
                open_items["前置章节"] = txt
            continue
        starts = [m.start() for m in fun_pat.finditer(md)]
        others = sorted(set(m.start() for m in re.finditer(r"^## (?!FUN-\d+)", md, re.M)) - set(starts))
        cuts = sorted(set(starts) | set(others)) + [len(md)]
        for s in starts:
            fun = fun_pat.match(md[s:]).group(1)
            trace_funs.add(fun)
            block = md[s:next(c for c in cuts if c > s)]
            sec = re.search(r"^### 业务规则\s*$", block, re.M)
            if sec:
                nxt = re.search(r"^### ", block[sec.end():], re.M)
                body = block[sec.end(): sec.end() + (nxt.start() if nxt else len(block))]
                for row in tables_in(body):
                    cells = [x.strip() for x in row.strip("|").split("|")]
                    rid = next((c for c in cells if re.fullmatch(cfg.get("ruleId", r"R-\d{3}"), c)), None)
                    if rid:
                        rest = [c for c in cells if c != rid]
                        rule_index.append((name, fun, rid, rest[0] if rest else ""))
        txt = section(md, r"## 本域未决问题")
        if txt:
            open_items[name] = txt

    # ---------- 装配 ----------
    parts = [f"# {cfg.get('title', 'PRD-Lite · 开发交接版')}\n\n"
             f"> 由 `{cfg['source']}` 降维重排:事实零改动,组织方式改为按开发阅读任务。"
             "正文删去全部溯源编号链(见各域文末附表);`⚠(见 U-xx)` = 未裁决问题,"
             "清单见未决问题汇总。目标读者:接手实现的开发。\n"]
    for name in order:
        if name in drafts:
            parts.append(drafts[name].strip() + "\n")
    parts.append("# 业务规则索引(全局)\n\n> 完整规则表在各 FUN「业务规则」节;本索引用于按编号定位。\n\n"
                 "| 规则 | 所属 FUN | 适用场景 |\n| --- | --- | --- |")
    for name, fun, rid, scene in sorted(set(rule_index), key=lambda r: r[2]):
        parts.append(f"| {rid} | {fun} | {scene} |")
    parts.append('\n<a id="未决问题汇总全局"></a>\n\n# 未决问题汇总(全局)\n')
    for dom in order:
        if dom in open_items:
            parts.append(f"## {dom}\n\n{open_items[dom]}\n")
    parts.append(appendix.strip() + "\n")
    open(out, "w", encoding="utf-8", newline="\n").write("\n".join(parts))

    # ---------- 守恒自检 ----------
    final = read(out)
    out_funs = set(fun_pat.findall(final))
    out_rids = set(rid_pat.findall(final))
    miss_fun = sorted(src_funs - out_funs)
    miss_rid = sorted(src_rids - out_rids)
    no_trace = sorted(src_funs - trace_funs)
    missing_domains = [n for n in order if n not in ("00-front",) and n not in open_items]
    ok = not (miss_fun or miss_rid or missing_domains or no_trace)
    print(f"输出 {out}: {len(final.splitlines())} 行")
    print(f"FUN: {len(out_funs)}/{len(src_funs)}  {'OK' if not miss_fun else 'FAIL 缺 ' + str(miss_fun)}")
    print(f"规则编号覆盖: {len(out_rids & src_rids)}/{len(src_rids)}  "
          f"{'OK' if not miss_rid else 'FAIL 缺 ' + str(miss_rid)}")
    print(f"未决问题域: {len(open_items)} 个;无未决节的域草稿: {missing_domains if missing_domains else '无'}")
    print(f"溯源附表未覆盖 FUN: {no_trace if no_trace else '无'}")
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
