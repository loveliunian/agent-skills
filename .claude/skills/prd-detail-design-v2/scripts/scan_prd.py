# -*- coding: utf-8 -*-
"""通用 PRD 预检引擎：零配置扫描任何有标题层级的 Markdown 文档，产出问题候选。

与 validate_prd.py 的分工（2026-09-18 分层改造）：

  scan_prd.py      通用层——永远跑，不需要任何配置。只依赖"文档有标题层级"和
                   "编号形如 PREFIX-数字"两个事实，不假设任何模板。
  validate_prd.py  模板层——默认关，只在显式声明"本文遵守 XX 模板"时才跑
                   （查必需模板项、验收项、模板专属编号体系）。未声明时模板
                   符合性即"未检查"，须如实告知，不假装查过。

通用层为什么需要"编号家族三层分类"：

  一份真实 PRD 会引用大量**定义不在本文件**的编号。ch-07 实测：REL/ Q/ CG/
  REQ/ FP/ COM 六族共 168 处引用，其定义在 ch-06 或外部裁决文件里。若不加
  区分地对所有编号判"悬空引用"，会刷出上百条假警报，引擎立刻失去可信度。
  因此按"有没有定义位"分三层：

    内部定义族  members>=2 且定义覆盖率>=50%  → 跑悬空引用 + 重复定义
    外部依赖族  members>=2 且覆盖率<50%       → 只登记一次，不判悬空。含两种：
                                              "完全无定义位"；以及"仅个别编号有定义位"
                                              ——后者是主体定义在别处、少数落单的定义位
                                              （如行首粗体段落）把整族带偏的情况
    噪音族      members<2                     → 抑制（杀 CH-07 / QUICK-VALIDATION-001
                                                 / USER-DECISIONS-20260917 这类
                                                 文件名与标题碎片）

  "定义位"的判据是位置而非内容：编号出现在表格行首、标题、列表项首之一。

检查项：

  G1 悬空引用    内部定义族中，正文引用的编号无定义位——引用链断裂
  G2 重复定义    同一编号出现>=2 个定义位；带「引用/参见/见/同」括注的定义位
                 是"只消费不定义"的声明，降级为引用式重复而非矛盾。**按族汇总输出**
                 （一族一条 + 定义位类型分布）——总览表/明细表这类正常结构会让逐条
                 报告刷到读不动（实测一份 PRD 的 171 条可塌缩成 5 条）
  G3 空表        markdown 表格剥掉表头与分隔行后无数据行——无法逐行转入下游
  G4 关键词命中  可配词表（默认沿用未决标记词）命中行
  G5 外部依赖族  信息级：清点定义不在本文件的编号族
  G6 结构报告    信息级：标题层级直方图 + 选中的检查单位级别 + 推断依据
                 （用于人工核对"引擎有没有看错文档结构"，也是排查误报的依据）

检查单位级别的推断：取"节点最多"的级别，与"最深且节点数>=2"交叉验证；两法
一致则高置信，不一致则在报告中标出分歧并取前者。可用 --unit-level 显式覆盖。
实测 ch-07→L6(12节点)、归档/06→L2、归档/07→L3，三份文档两法均一致。

用法：
  python scan_prd.py --input ch-07.md --out design/ch-07/prd_scan.json
  python scan_prd.py --input ch-07.md --unit-level 6
  python scan_prd.py --input ch-07.md --markers "待确认,待裁决"

退出码：0 正常产出候选（候选可为空）；1 输入不可读或脚本异常；2 未匹配到任何
标题（无结构文档，本引擎不支持）；3 --unit-level 指定的级别不存在或节点数<2。
"""
import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# ── 结构识别（通用，与任何模板无关）──

HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
FENCE_RE = re.compile(r"^\s*(?:```|~~~)")

# 编号：支持多段前缀（FUN-ORG-001 / FUN-L-ORD-001 / R-001 / REQ-001）
ID_RE = re.compile(r"(?<![A-Za-z0-9-])([A-Z][A-Z0-9]*(?:-[A-Z][A-Z0-9]*)*)-(\d+)(?![0-9])")

# 定义位前缀：标题 / 表格首列 / 列表项首，三选一。判定**只看位置不看内容**，
# 因此会把"总览表登记行"也一并算作定义位——这是有意的取舍：宁可多算，因为漏算会让
# 一个编号族失去"内部定义族"身份，连带它的悬空引用检查一起消失（实测：只认标题会让
# ch-07 的 R 族整族消失、新 PRD 从 10 族掉到 1 族——规则绝大多数写在表格里）。
# 多算的代价用"按族汇总 + 带类型分布"在报告层消化，见 g2 的注释。
DEF_HEADING_RE = re.compile(r"^#{1,6}\s*$")
DEF_TABLE_RE = re.compile(r"^\|\s*$")
DEF_LIST_RE = re.compile(r"^[-*]\s*\**$")


def def_site_kind(head):
    """定义位类型（标题/表格首列/列表项首）；非定义位返回 None。"""
    for kind, rx in (("标题", DEF_HEADING_RE), ("表格首列", DEF_TABLE_RE),
                     ("列表项首", DEF_LIST_RE)):
        if rx.match(head):
            return kind
    return None

# 非权威定义标注（"只消费不定义"）
QUALIFIER_RE = re.compile(r"[（(]\s*(引用|参见|见|同)\s*[）)]")

# 表格分隔行 |---|---|
SEPARATOR_RE = re.compile(r"^\|[\s:|-]+\|?\s*$")

DEFAULT_MARKERS = [
    "待确认", "待定稿", "待裁决", "待产品", "待 Q-", "二选一",
    "占位不展开", "不展开", "WAITING_DECISION", "口径未定", "未决",
]

# 内部定义族的最低定义覆盖率（有定义位的编号数 / 该族编号总数）。
# 只有个别编号在本文件有定义位 = 主体定义在别处，不该按"内部族"逐条判悬空。
# 实测分离度极大（某 PRD：9 个真内部族 94%~100%，误判进来的 Q 族仅 5.9%），
# 阈值取中间即可，不需要调参。
MIN_COVERAGE = 0.5


def mark_code_fences(lines):
    """标记每行是否处于代码块内（含围栏行本身）——mermaid / text 块里的 # 与编号
    不是文档结构，参与解析会产生假候选。"""
    inside, flags = False, []
    for line in lines:
        if FENCE_RE.match(line):
            flags.append(True)
            inside = not inside
            continue
        flags.append(inside)
    return flags


def parse_headings(lines, in_code):
    """解析标题为节点序列（含级别、文本、行号）。栈式层级：任意跳级天然支持。"""
    nodes = []
    for i, line in enumerate(lines):
        if in_code[i]:
            continue
        m = HEADING_RE.match(line)
        if m:
            nodes.append({"level": len(m.group(1)), "text": m.group(2).strip(),
                          "line": i + 1})
    return nodes


def infer_unit_level(nodes, override=None):
    """推断"检查单位"所在级别，返回 (level, basis, divergence)。"""
    hist = Counter(n["level"] for n in nodes)
    multi = {lv: c for lv, c in hist.items() if c >= 2}
    if override is not None:
        return override, f"由 --unit-level 显式指定", None
    if not multi:
        return None, "无任何级别拥有 2 个以上节点", None
    by_count = max(multi.items(), key=lambda kv: (kv[1], kv[0]))[0]
    deepest = max(multi)
    if by_count == deepest:
        return by_count, f"最深且节点>=2(L{deepest}) 与 节点最多(L{by_count}) 两法一致", None
    return by_count, f"两法分歧(最深L{deepest} / 最多L{by_count})，取节点最多者", "divergent"


def build_units(lines, nodes, unit_level):
    """切出检查单位：同级别的相邻标题之间为一个单位。"""
    if unit_level is None:
        return []
    tops = [n for n in nodes if n["level"] == unit_level]
    units = []
    for idx, n in enumerate(tops):
        end = len(lines)
        for later in nodes:
            if later["line"] > n["line"] and later["level"] <= n["level"]:
                end = later["line"] - 1
                break
        uid_m = ID_RE.search(n["text"])
        units.append({
            "id": uid_m.group(0) if uid_m else n["text"],
            "name": n["text"],
            "level": n["level"],
            "start": n["line"],
            "end": end,
        })
    return units


def unit_of(units, line):
    """行号落在哪个检查单位内（用于候选溯源）。"""
    for u in units:
        if u["start"] <= line <= u["end"]:
            return u["id"]
    return None


def discover_families(lines, in_code, min_members):
    """编号家族自动发现 + 三层分类。返回按出现次数降序的家族列表。"""
    fams = defaultdict(lambda: {"ids": set(), "occurrences": 0, "defs": defaultdict(list)})
    for i, line in enumerate(lines):
        if in_code[i]:
            continue
        for m in ID_RE.finditer(line):
            prefix, num = m.group(1), m.group(2)
            full = f"{prefix}-{num}"
            fam = fams[prefix]
            fam["ids"].add(full)
            fam["occurrences"] += 1
            kind = def_site_kind(line[:m.start()])
            if kind:
                qual = QUALIFIER_RE.search(line)
                fam["defs"][full].append({
                    "line": i + 1,
                    "kind": kind,
                    "authoritative": qual is None,
                    "qualifier": qual.group(1) if qual else None,
                    "text": line.strip()[:120],
                })

    out = []
    for prefix, fam in fams.items():
        members = len(fam["ids"])
        def_ids = set(fam["defs"])
        coverage = (len(def_ids) / members) if members else 0.0
        sparse = False
        if members < min_members:
            tier, note = "noise", f"成员数 {members} < {min_members}，抑制（疑似文件名/标题碎片）"
        elif not def_ids:
            tier, note = "external", "本文件无定义位，登记为外部依赖，不判悬空引用"
        elif coverage < MIN_COVERAGE:
            # 只有个别编号在本文件有定义位 = 主体定义在别处。实测：某 PRD 的 Q 族 17 个
            # 编号仅 1 个有定义位（那一处是行首粗体段落，样子像定义），若按内部族处理，
            # 其余 16 个会被逐条误报成悬空引用（该文档自己写明 Q-* 定义在 intake.md 第 4 节）。
            tier, note = "external", (
                f"仅 {len(def_ids)}/{members} 个编号在本文件有定义位"
                f"（覆盖率 {coverage:.1%} < {MIN_COVERAGE:.0%}）——主体定义在别处，"
                f"登记为外部依赖，不逐条判悬空")
            sparse = True
        else:
            tier, note = "internal", (
                f"本文件内有定义位（覆盖率 {coverage:.0%}），参与悬空引用与重复定义检查")
        out.append({
            "prefix": prefix,
            "members": members,
            "occurrences": fam["occurrences"],
            "defSites": sum(len(v) for v in fam["defs"].values()),
            "definedIds": len(def_ids),
            "coverage": round(coverage, 4),
            "tier": tier,
            "sparse": sparse,
            "note": note,
            "ids": sorted(fam["ids"]),
            "defs": {k: v for k, v in sorted(fam["defs"].items())},
        })
    return sorted(out, key=lambda f: (-f["occurrences"], f["prefix"]))


def find_empty_tables(lines, in_code):
    """连续的 | 行构成一张表。剥掉表头与分隔行后无数据行 → 空表。"""
    out, i, n = [], 0, len(lines)
    while i < n:
        if in_code[i] or not lines[i].lstrip().startswith("|"):
            i += 1
            continue
        start = i
        while i < n and not in_code[i] and lines[i].lstrip().startswith("|"):
            i += 1
        block = list(range(start, i))
        if len(block) < 2:
            continue
        non_sep = [b for b in block if not SEPARATOR_RE.match(lines[b].strip())]
        if len(non_sep) <= 1:          # 只有表头，无数据行
            out.append({"line": start + 1, "rows": len(block)})
    return out


def check(lines, in_code, units, families, markers, min_members):
    """通用检查 G1~G6，产出候选清单。"""
    cands = []

    def add(cid, kind, text, line=None, detail=None):
        cands.append({"id": cid, "kind": kind, "unit": unit_of(units, line) if line else None,
                      "line": line, "text": text, "detail": detail or {}})

    # ── G1 悬空引用（仅内部定义族）──
    for fam in families:
        if fam["tier"] != "internal":
            continue
        defined = set(fam["defs"])
        refd = set(fam["ids"])
        missing = sorted(refd - defined)
        for mid in missing:
            first = next((i + 1 for i, l in enumerate(lines)
                          if not in_code[i] and mid in l), None)
            add("G1", "dangling_ref",
                f"{mid} 被引用但本文件无权威定义位（族 {fam['prefix']} 有 {len(defined)} 个定义位）"
                f"——若该编号定义在外部文档，应登记为外部依赖族",
                line=first, detail={"family": fam["prefix"], "id": mid})

    # ── G2 重复定义（按族汇总）──
    # 为什么不"一个编号一条"：同一编号出现在多张表的首列是常态（总览表 + 明细表），
    # 逐条报会把这类正常结构刷成上百条——读到第 60 条才知道"整个 FP 族是总览+明细"。
    # 一族一条 + 类型分布，读一条就能关掉整个族；具体编号与行号留在 detail 里。
    for fam in families:
        if fam["tier"] != "internal":
            continue
        dup_ids = {rid: sites for rid, sites in fam["defs"].items() if len(sites) > 1}
        if not dup_ids:
            continue
        hard, soft = {}, {}          # 多处权威定义 / 仅引用式重复（另一处已声明只消费）
        for rid, sites in dup_ids.items():
            auth = [s for s in sites if s["authoritative"]]
            (hard if len(auth) >= 2 else soft)[rid] = sites
        kinds = Counter(s["kind"] for sites in hard.values() for s in sites)

        seg = []
        if hard:
            ids = "、".join(sorted(hard)[:5]) + ("…" if len(hard) > 5 else "")
            seg.append(f"{len(hard)} 个编号出现多处权威定义（{ids}）")
        if soft:
            ids = "、".join(sorted(soft)[:5]) + ("…" if len(soft) > 5 else "")
            seg.append(f"{len(soft)} 个编号为引用式重复（{ids}）——非矛盾，"
                       f"另一处已标注「只消费不定义」")
        text = f"{fam['prefix']} 族：{'；'.join(seg)}"
        if hard:
            text += ("。权威定义位类型分布："
                     + "、".join(f"{k}×{v}" for k, v in kinds.most_common()))
            if set(kinds) == {"表格首列"}:
                text += "——若为总览表+明细表的两层结构则属正常，请确认不存在两个互相冲突的权威源"
        add("G2", "dup_def", text,
            line=min(s["line"] for sites in dup_ids.values() for s in sites),
            detail={"family": fam["prefix"], "hardCount": len(hard), "softCount": len(soft),
                    "kindDistribution": dict(kinds),
                    "ids": {rid: sites for rid, sites in sorted(dup_ids.items())}})

    # ── G3 空表 ──
    for t in find_empty_tables(lines, in_code):
        add("G3", "empty_table",
            f"L{t['line']} 处的表格只有表头（共 {t['rows']} 行）无数据行——下游无法逐行转入",
            line=t["line"], detail={"rows": t["rows"]})

    # ── G4 关键词命中 ──
    mre = re.compile("|".join(map(re.escape, markers))) if markers else None
    if mre:
        for i, line in enumerate(lines):
            if in_code[i]:
                continue
            m = mre.search(line)
            if m:
                add("G4", "marker_hit", f"未决标记「{m.group(0)}」：{line.strip()[:80]}",
                    line=i + 1, detail={"marker": m.group(0)})

    # ── G5 外部依赖族（信息级）──
    for fam in families:
        if fam["tier"] != "external":
            continue
        if fam.get("sparse"):
            text = (f"编号族 {fam['prefix']}（{fam['members']} 个编号、{fam['occurrences']} 处引用）"
                    f"仅 {fam['definedIds']} 个在本文件有定义位（覆盖率 {fam['coverage']:.1%}）"
                    f"——判为主体定义在别处，已按外部依赖处理、不逐条判悬空；"
                    f"请确认其余编号的定义来源文档存在（若有编号确实漏了定义，那是真缺口）")
        else:
            text = (f"编号族 {fam['prefix']}（{fam['members']} 个编号、{fam['occurrences']} 处引用）"
                    f"的定义不在本文件——视为外部依赖，不判悬空；确认其定义来源文档已存在")
        add("G5", "external_family", text,
            detail={"family": fam["prefix"], "members": fam["members"],
                    "occurrences": fam["occurrences"], "coverage": fam.get("coverage"),
                    "sparse": fam.get("sparse", False), "ids": fam["ids"]})

    return cands


def main():
    ap = argparse.ArgumentParser(description="通用 PRD 预检引擎：按标题层级与编号家族做零配置扫描")
    ap.add_argument("--input", required=True, help="PRD Markdown 路径")
    ap.add_argument("--out", help="候选清单 JSON 输出路径（AI 逐条表态的输入）")
    ap.add_argument("--unit-level", type=int, help="显式指定检查单位所在的标题级别")
    ap.add_argument("--markers", help="未决标记词表，逗号分隔（默认沿用内置词表）")
    ap.add_argument("--min-members", type=int, default=2,
                    help="编号家族的最少成员数，低于此数判为噪音族（默认 2）")
    args = ap.parse_args()

    try:
        lines = Path(args.input).read_text(encoding="utf-8").splitlines()
    except OSError as e:
        print(f"[FAIL] 输入不可读: {args.input} ({e})")
        sys.exit(1)

    markers = ([m.strip() for m in args.markers.split(",") if m.strip()]
               if args.markers else DEFAULT_MARKERS)

    in_code = mark_code_fences(lines)
    nodes = parse_headings(lines, in_code)
    if not nodes:
        print("[FAIL] 未匹配到任何标题——本引擎只支持有标题层级结构的文档。")
        print("       无结构/叙述性文档不支持：请先将文档结构化为标题层级。")
        sys.exit(2)

    hist = Counter(n["level"] for n in nodes)
    unit_level, basis, divergence = infer_unit_level(nodes, args.unit_level)

    if args.unit_level is not None:
        cnt = hist.get(args.unit_level, 0)
        if cnt < 2:
            print(f"[FAIL] --unit-level {args.unit_level} 无效：该级别只有 {cnt} 个节点（需 >=2）。")
            print(f"       实测层级分布：{dict(sorted(hist.items()))}")
            sys.exit(3)

    units = build_units(lines, nodes, unit_level)
    families = discover_families(lines, in_code, args.min_members)
    cands = check(lines, in_code, units, families, markers, args.min_members)

    cands.insert(0, {
        "id": "G6", "kind": "structure", "unit": None, "line": None,
        "text": f"结构识别：{len(nodes)} 个标题、层级分布 {dict(sorted(hist.items()))}；"
                f"检查单位级别 L{unit_level}（{len(units)} 个单位）——{basis}",
        "detail": {"levels": {str(k): v for k, v in sorted(hist.items())},
                   "unitLevel": unit_level, "unitCount": len(units),
                   "basis": basis, "divergence": divergence,
                   "units": units},
    })

    by_kind = Counter(c["kind"] for c in cands)
    print(f"通用预检：{args.input}")
    print(f"  结构识别: {len(nodes)} 个标题，层级分布 {dict(sorted(hist.items()))}")
    print(f"  检查单位: L{unit_level}，{len(units)} 个单位（{basis}）")
    if divergence:
        print(f"  [注意] 级别推断存在分歧，建议用 --unit-level 显式指定后复核")
    internal = [f["prefix"] for f in families if f["tier"] == "internal"]
    external = [f["prefix"] for f in families if f["tier"] == "external"]
    noise = [f["prefix"] for f in families if f["tier"] == "noise"]
    print(f"  编号家族: 内部定义族 {'、'.join(internal) or '无'}"
          f" | 外部依赖族 {'、'.join(external) or '无'}"
          f" | 噪音族 {'、'.join(noise) or '无'}")
    print(f"  问题候选 {len(cands)} 条："
          + " ".join(f"{k}={v}" for k, v in sorted(by_kind.items())))
    print()
    for c in cands:
        loc = f" L{c['line']}" if c["line"] else ""
        who = f" [{c['unit']}]" if c["unit"] else ""
        print(f"  [{c['id']}][{c['kind']}]{loc}{who} {c['text']}")

    if args.out:
        Path(args.out).write_text(
            json.dumps({
                "source": args.input,
                "engine": "scan_prd@1",
                "templateConformanceChecked": False,
                "templateConformanceNote": "通用层不检查模板符合性；如需检查，显式声明模板后另跑 validate_prd.py",
                "markers": markers,
                "structure": {"levels": {str(k): v for k, v in sorted(hist.items())},
                              "unitLevel": unit_level, "unitLevelBasis": basis,
                              "divergence": divergence, "units": units},
                "families": families,
                "candidates": cands,
            }, ensure_ascii=False, indent=2),
            encoding="utf-8")
        print(f"\n候选清单已输出：{args.out}（AI 预检须逐条表态：确认→PI / 误报→说明）")
    sys.exit(0)


if __name__ == "__main__":
    main()