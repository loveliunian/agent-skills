# -*- coding: utf-8 -*-
"""prd-lite 阶段一:按域切片 + 提取 FUN 清单。纯脚本零 LLM。
用法: python split.py <PRD.md> [--workdir .prd-lite]
配置: <workdir>/config.json(先于运行写好),示例见 skill 文档:
{
  "source": "PRD.md",
  "anchors": [                                  // 有序锚点,切片从本锚点 start 命中行起,到下一锚点命中行止
    {"file": "00-front.md",    "start": null},              // null = 从文件头
    {"file": "01-ch7-notes.md","start": "^## 7\\. "},
    {"file": "F{k:02d}.md",    "start": "^#### F0\\d ", "repeat": true},  // repeat: 每次命中开一片,name 可用 {k}
    {"file": "99-appendix.md", "start": "^## 8\\. "}
  ],
  "funs": "^###### (FUN-\\d+)[:：\\s]"          // FUN 标题行正则,group(1) 为编号
}
输出:<workdir>/slices/*.md 与 <workdir>/manifest.json;自检:行数守恒 + FUN 总数守恒。
"""
import io, json, os, re, sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")


def main():
    if len(sys.argv) < 2:
        sys.exit("用法: python split.py <PRD.md> [--workdir .prd-lite]")
    src = sys.argv[1]
    wd = sys.argv[sys.argv.index("--workdir") + 1] if "--workdir" in sys.argv else ".prd-lite"
    cfg = json.load(open(os.path.join(wd, "config.json"), encoding="utf-8"))
    if "source" not in cfg:
        cfg["source"] = os.path.basename(src)
    lines = open(src, encoding="utf-8").read().splitlines()
    n = len(lines)

    # 展开锚点 → (行号, 切片名) 有序表
    marks, cursor, k = [], 0, 0
    for a in cfg["anchors"]:
        pat = re.compile(a["start"]) if a.get("start") else None
        hits = []
        if pat is None:
            hits = [0]
        elif a.get("repeat"):
            hits = [i for i in range(cursor, n) if pat.search(lines[i])]
            if not hits:
                sys.exit(f"!! 锚点 {a['file']} 的重复正则未命中: {a['start']}")
        else:
            i = next((i for i in range(cursor, n) if pat.search(lines[i])), None)
            if i is None:
                sys.exit(f"!! 锚点 {a['file']} 的起始正则未命中: {a['start']}")
            hits = [i]
        for h in hits:
            k += 1 if a.get("repeat") else 0
            name = a["file"].format(k=k)
            marks.append((h, name))
        cursor = hits[-1] + 1
    marks.sort()

    sdir = os.path.join(wd, "slices")
    os.makedirs(sdir, exist_ok=True)
    fun_pat = re.compile(cfg.get("funs", r"^#{2,4} (FUN-\d+)[:：\s]"))

    manifest = {"source": cfg["source"], "total_lines": n, "slices": []}
    for idx, (s, name) in enumerate(marks):
        e = marks[idx + 1][0] if idx + 1 < len(marks) else n
        block = "\n".join(lines[s:e])
        open(os.path.join(sdir, name), "w", encoding="utf-8", newline="\n").write(block)
        funs = []
        for l in lines[s:e]:
            m = fun_pat.match(l)
            if m:
                funs.append((m.group(1) + "：" + l[m.end(1):].lstrip("：: ").strip()).strip("："))
        manifest["slices"].append({"file": name, "start_line": s + 1, "end_line": e,
                                   "lines": e - s, "chars": len(block), "funs": funs})
        print(f"{name:24s} 行 {s+1:5d}~{e:5d}({e-s:5d} 行) FUN {len(funs)}")

    json.dump(manifest, open(os.path.join(wd, "manifest.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)

    # 自检:行数守恒 + FUN 总数守恒
    total_fun = sum(len(x["funs"]) for x in manifest["slices"])
    all_fun = len([l for l in lines if fun_pat.match(l)])
    assert sum(x["lines"] for x in manifest["slices"]) == n, "切分不守恒!"
    assert total_fun == all_fun, f"FUN 丢失!表中 {total_fun} vs 原文 {all_fun}"
    print(f"\n守恒校验通过:{n} 行、{all_fun} 个 FUN 全部覆盖")


if __name__ == "__main__":
    main()
