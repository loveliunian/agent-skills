# -*- coding: utf-8 -*-
"""模板层预检引擎：按「模板画像 profile」对 PRD 原文（Markdown）做模板符合性检查，产出问题候选。

本脚本的定位（2026-09-18 分层改造后）：

  这是**模板层**——回答"这份 PRD 和某个声明的模板比，少了什么"。它**不自带任何
  模板**：必须用 --profile 显式指向一个模板画像（见 ../templates/），否则拒跑
  （exit 2）。不打算声明模板时请用通用层 scan_prd.py——零配置、不查符合性，只查
  文档自身是否自洽。

    通用层  scan_prd.py     任何有标题层级的文档都能跑，不假设模板
    模板层  validate_prd.py 必须声明模板，查"符合性"（本脚本）

  模板画像的用法：把 templates/{模板}.profile.json 复制到 design/{PRD}/prd_profile.json，
  补上该 PRD 的 expectedFuns，再用 --profile 指过去。**复制而非直接引用**，是为了让每个
  运行目录自带完整配置——脚本里的规则将来若改动，旧运行仍可原样复现。

设计原则（结构画像方案，2026-09-18 定）：
  **检查逻辑固定，结构识别可生成。** P1~P7 检查项本身是格式无关的（结构缺项/
  规则双定义/悬空引用/未决标记），依赖模板的只是"怎么找到功能小节/规则表/验收
  表"。因此：
    - 引擎（本脚本）是已测试的固定代码，禁止为单份 PRD 改引擎逻辑；
    - 结构识别由 AI 扫描 PRD 后生成 profile JSON 注入（--profile）；
    - AI 必须在 profile 里声明 expectedFuns（它数到的小节清单），引擎拿实际匹
      配结果与之对账，不一致即 FAIL——防止画像生成错误导致的静默漏检/误报。
    - expectedFuns 为**全路径强制项**（含模板 PRD 走默认画像的场景）：未声明
      即 exit 2，不存在"跳过对账"的容忍路径；
    - 匹配到 0 个小节即 exit 3——本引擎只支持有功能小节结构的 PRD，无结构
      文档直接拒跑，不再"跳过结构类检查继续分析"。

检查项（全部为确定性文本/结构规则）：

  P1 结构完整性      每个 FUN 小节缺少必需的模板项（由 profile 的 requiredItems 定义）
  P2 规则双定义      同一 R-xxx 在多个 FUN 的规则表中以权威口径出现——判定条件不同
                     即矛盾候选，附两处文本供 AI 比对
  P3 规则悬空引用    引用的 R-xxx 全文无权威定义——规则链断裂
  P4 FUN 悬空引用    引用的其他 FUN 小节不存在——功能依赖断裂
  P5 未决标记扫描    profile.unresolvedMarkers 命中的行——unresolved 候选
  P6 验收表缺失      验收项存在但表体为空——验收无法逐行转入详设
  P7 Q 引用登记      引用的 Q-xxx 未在本文件出现裁决结论（信息级）

用法：
  # 标准流程：复制模板画像到运行目录，补上该 PRD 的 expectedFuns，再指过去
  cp templates/fun-17item.profile.json design/ch-07/prd_profile.json
  #   ↑ 然后在 prd_profile.json 里补 "expectedFuns": ["FUN-ORG-001", ...]
  python validate_prd.py --input ch-07.md --profile design/ch-07/prd_profile.json \
      --out design/ch-07/prd_candidates.json

退出码：0 正常；1 画像不可读/顶层非对象/含未知字段/正则编译失败；2 未指定
--profile，或画像未声明 expectedFuns（禁止带病分析——补齐后重跑）；3 未匹配到
任何功能小节（无结构 PRD，本 skill 不支持，拒跑）。
"""
import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# ── 画像字段契约 ──
# 本脚本**不自带模板**：模板定义全部来自 --profile 指向的画像文件（见 ../templates/）。
# 下划线开头的键是给人看的元信息（_name/_appliesTo/_source 等），引擎忽略不放行也不报错。
PROFILE_KEYS = {
    "profileVersion", "funSection", "templateItem", "requiredItems",
    "acceptanceItemNumber", "ruleDef", "ruleRefPattern", "funRefPattern",
    "qRefPattern", "unresolvedMarkers", "emptyTableRowPattern",
    "acceptanceHeaderKeywords", "expectedFuns",
}
# 缺任一即拒跑：画像必须是完整的模板定义——不再有"脚本内置规则兜底"这回事，
# 否则一次运行的一半配置在文件里、一半在脚本版本里，旧运行无法复现。
REQUIRED_PROFILE_KEYS = PROFILE_KEYS - {"profileVersion", "expectedFuns"}


def load_profile(path):
    """读模板画像并做结构校验/编译。任何字段错误都显式报错退出，不静默回退默认值。
    本脚本不携带内置模板：未指定 path 即拒跑，并指路通用层。"""
    if not path:
        print("[FAIL] 未指定模板画像（--profile）——本脚本是模板层，必须显式声明模板。")
        print("       若本来就不打算声明模板，请改用通用层：")
        print("         python scripts/scan_prd.py --input <PRD> --out design/{PRD}/prd_scan.json")
        sys.exit(2)
    try:
        user = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"[FAIL] 画像文件不可读或非法 JSON: {path} ({e})")
        sys.exit(1)
    if not isinstance(user, dict):
        print(f"[FAIL] 画像顶层必须是 JSON 对象: {path}")
        sys.exit(1)
    prof = {}
    for k, v in user.items():
        if k.startswith("_"):
            continue          # 下划线开头 = 给人看的元信息，引擎忽略
        if k not in PROFILE_KEYS:
            print(f"[FAIL] 画像含未知字段: {k}（合法字段 {sorted(PROFILE_KEYS)}；"
                  f"以 _ 开头的字段视为元信息，会被忽略）")
            sys.exit(1)
        prof[k] = v
    missing = sorted(REQUIRED_PROFILE_KEYS - set(prof))
    if missing:
        print(f"[FAIL] 画像缺少必需字段: {missing}")
        print("       ——画像必须是完整的模板定义：请从 ../templates/ 复制一份再改。")
        print("       只写 expectedFuns（依赖脚本内置规则）的做法已废弃——那样一次运行的")
        print("       配置一半在文件里、一半在脚本版本里，旧运行无法复现。")
        sys.exit(1)
    prof["_profilePath"] = path
    prof["_templateName"] = user.get("_name") or Path(path).name   # 报告用：模板叫什么
    # 编译全部正则——写错立刻暴露
    try:
        prof["_fun_re"] = re.compile(prof["funSection"]["pattern"])
        prof["_item_re"] = re.compile(prof["templateItem"]["pattern"])
        prof["_rule_re"] = re.compile(prof["ruleDef"]["pattern"])
        prof["_rule_ref_re"] = re.compile(prof["ruleRefPattern"])
        prof["_fun_ref_re"] = re.compile(prof["funRefPattern"])
        prof["_q_ref_re"] = re.compile(prof["qRefPattern"])
        prof["_unresolved_re"] = re.compile("|".join(map(re.escape, prof["unresolvedMarkers"])))
        prof["_empty_row_re"] = re.compile(prof["emptyTableRowPattern"])
        prof["_acc_header_re"] = re.compile("|".join(map(re.escape, prof["acceptanceHeaderKeywords"])))
    except (KeyError, re.error, TypeError) as e:
        print(f"[FAIL] 画像正则编译失败: {e}（检查 pattern 字段）")
        sys.exit(1)
    # 命名组存在性检查：id/num/rid 是引擎必需的
    for regex, need, label in [(prof["_fun_re"], "id", "funSection"),
                               (prof["_item_re"], "num", "templateItem"),
                               (prof["_rule_re"], "rid", "ruleDef")]:
        if need not in regex.groupindex:
            print(f"[FAIL] 画像 {label}.pattern 缺少命名组 ?P<{need}>")
            sys.exit(1)
    return prof


def parse_prd(text, prof):
    """把 PRD 切成 FUN 小节：每节收集行区间、模板项集合、规则权威定义、表格行。"""
    lines = text.splitlines()
    non_auth = set(prof["ruleDef"].get("nonAuthoritativeQualifiers", []))
    funs, order, cur = {}, [], None
    for i, line in enumerate(lines, start=1):
        m = prof["_fun_re"].match(line)
        if m:
            cur = m.group("id").strip()
            funs[cur] = {"name": (m.groupdict().get("name") or "").strip(),
                         "start": i, "items": set(), "rule_defs": {}, "table_rows": []}
            order.append(cur)
            continue
        if cur is None:
            continue
        f = funs[cur]
        im = prof["_item_re"].match(line)
        if im:
            f["items"].add(int(im.group("num")))
        if line.startswith("|"):
            f["table_rows"].append((i, line))
            rm = prof["_rule_re"].match(line)
            if rm:
                rid = rm.group("rid").strip()
                qual = (rm.groupdict().get("qual") or "").strip()
                qual = qual.strip("（）()").strip()   # （引用）/ (引用) → 引用
                if qual not in non_auth:             # 非权威标注 = 仅消费，不作定义
                    cond = line.split("|")[3].strip() if line.count("|") >= 3 else ""
                    f["rule_defs"].setdefault(rid, (i, qual, cond))
    for idx, fid in enumerate(order):
        funs[fid]["end"] = funs[order[idx + 1]]["start"] - 1 if idx + 1 < len(order) else len(lines)
    return lines, funs, order


def check(funs, order, lines, prof):
    issues = []

    def add(pid, kind, fun, text, line=None, detail=None):
        issues.append({"id": f"P{pid}", "kind": kind, "fun": fun,
                       "text": text, "line": line, "detail": detail or {}})

    item_names = prof["templateItem"].get("names", {})
    acc_no = prof["acceptanceItemNumber"]

    # P1 结构完整性
    for fid in order:
        missing = [f"{n}.{item_names.get(str(n), '')}".rstrip('.') for n in prof["requiredItems"]
                   if n not in funs[fid]["items"]]
        if missing:
            add(1, "structure_gap", fid, f"缺少必需模板项：{'、'.join(missing)}", line=funs[fid]["start"])

    # P2 规则双定义（跨 FUN 权威口径重复）
    def_sites = defaultdict(list)
    for fid in order:
        for rid, (ln, qual, cond) in funs[fid]["rule_defs"].items():
            def_sites[rid].append((fid, ln, qual, cond))
    for rid, sites in sorted(def_sites.items()):
        if len(sites) > 1:
            conds = {s[3] for s in sites}
            add(2, "conflict_hint", rid,
                f"规则 {rid} 在 {len(sites)} 处出现权威定义（非引用标注）："
                f"{'；'.join(f'{s[0]} L{s[1]}' for s in sites)}",
                line=sites[0][1],
                detail={"sites": [f"{s[0]} L{s[1]}" for s in sites],
                        "conds_differ": len(conds) > 1, "conds": list(conds)})

    # P3 规则悬空引用 / P4 FUN 悬空引用
    defined = set(def_sites)
    for fid in order:
        seg = "\n".join(lines[funs[fid]["start"] - 1: funs[fid]["end"]])
        for rid in sorted(set(prof["_rule_ref_re"].findall(seg))):
            if rid not in defined:
                add(3, "dangling_ref", fid, f"规则 {rid} 被引用但全文无权威定义（规则链断裂）",
                    line=funs[fid]["start"])
        for ref in sorted(set(prof["_fun_ref_re"].findall(seg))):
            if ref not in funs:
                add(4, "dangling_ref", fid, f"引用的 {ref} 在本文件无对应小节（外部依赖或断链）")

    # P5 未决标记扫描（逐行定位）
    for i, line in enumerate(lines, start=1):
        if prof["_unresolved_re"].search(line):
            add(5, "unresolved_hint", None, f"未决标记：{line.strip()[:80]}", line=i)

    # P6 验收表缺失/空表
    for fid in order:
        seg = lines[funs[fid]["start"] - 1: funs[fid]["end"]]
        in_acc, data_rows = False, 0
        for line in seg:
            im = prof["_item_re"].match(line)
            if im:
                in_acc = im.group("num").strip() == str(acc_no)
                continue
            if in_acc and line.startswith("|"):
                if prof["_empty_row_re"].match(line) or prof["_acc_header_re"].search(line):
                    continue
                data_rows += 1
        if acc_no not in funs[fid]["items"]:
            continue  # P1 已报缺项，不重复报
        if data_rows == 0:
            add(6, "acceptance_gap", fid, "验收标准项存在但表格无数据行（无法逐行转入 acceptance）")

    # P7 Q 引用登记（信息级）
    all_q = sorted(set(prof["_q_ref_re"].findall("\n".join(lines))))
    add(7, "info", None,
        f"文中引用 {len(all_q)} 个未决问题编号：{'、'.join(all_q) or '无'}"
        f"（均须在问题清单 prd_issues.json 中登记为 unresolved 或外部依赖）",
        detail={"q_ids": all_q})
    return issues


def reconcile(order, prof, profile_path):
    """画像对账：AI 声明的 expectedFuns 必须与引擎实际匹配一致，否则带病分析。
    expectedFuns 为全路径强制项——未声明即拒跑，不存在跳过对账的容忍路径。"""
    exp = prof.get("expectedFuns")
    if exp is None:
        print("[FAIL] 画像未声明 expectedFuns（AI 亲自数到的小节 id 清单）——")
        print("       无对账不分析。模板 PRD 走默认画像时同样必须声明：")
        print('       生成最小画像文件，如 {"expectedFuns": ["FUN-ORG-001", ...]}，')
        print("       用 --profile 传入后重跑。")
        sys.exit(2)
    exp_ids = sorted(str(x).strip() for x in exp)
    act_ids = sorted(order)
    if exp_ids != act_ids:
        only_exp = [x for x in exp_ids if x not in act_ids]
        only_act = [x for x in act_ids if x not in exp_ids]
        print("[FAIL] 画像对账失败：AI 声明的小节与引擎实际匹配不一致——")
        print(f"       AI 声明 {len(exp_ids)} 个，实际匹配 {len(act_ids)} 个")
        if only_exp:
            print(f"       声明了但没匹配到（画像 pattern 太窄或 PRD 有该节）: {only_exp}")
        if only_act:
            print(f"       匹配到但 AI 没数到（pattern 太宽，误把别的东西当小节）: {only_act}")
        print(f"       修正画像 {profile_path or '（默认画像不可对账，请显式生成画像）'} 后重跑，禁止带病分析。")
        sys.exit(2)


def main():
    ap = argparse.ArgumentParser(description="PRD 预检引擎：按结构画像做确定性规则扫描")
    ap.add_argument("--input", required=True, help="PRD Markdown 路径")
    # 故意不设 required=True：缺省时由 load_profile 给出"改用通用层"的指路提示，
    # 比 argparse 的默认报错有用（required=True 会让那段提示永远走不到）。
    ap.add_argument("--profile",
                    help="模板画像 JSON（必须显式指定，见 ../templates/）——本脚本不携带"
                         "内置模板，不指定即拒跑；不想声明模板请用通用层 scan_prd.py")
    ap.add_argument("--out", help="候选清单 JSON 输出路径（AI 预检逐条表态的输入）")
    ap.add_argument("--require", help="覆盖 P1 必需项编号，逗号分隔（默认取画像 requiredItems）")
    args = ap.parse_args()

    prof = load_profile(args.profile)
    text = Path(args.input).read_text(encoding="utf-8")
    lines, funs, order = parse_prd(text, prof)
    if args.require:
        prof["requiredItems"] = [int(x) for x in args.require.split(",") if x.strip()]

    reconcile(order, prof, args.profile)   # 对账不过 exit 2，后续检查不执行

    # 无结构 PRD 拒跑：本 skill 只支持有功能小节结构的文档。对账在前，走到这里
    # 且 order 为空，说明 AI 声明与实际匹配一致地得出"无小节"（含空清单互相
    # 印证）——一律视为不支持，不再降级为"只跑全文级检查"。
    if not order:
        print("[FAIL] 未匹配到任何功能小节——本 skill 只支持有功能小节结构的 PRD。")
        print("       无结构/叙述性文档不支持：请先将 PRD 结构化为功能小节，或明确该文档不适用本流程。")
        sys.exit(3)

    issues = check(funs, order, lines, prof)

    by_kind = defaultdict(int)
    for it in issues:
        by_kind[it["kind"]] += 1

    print(f"PRD 预检：{args.input}（模板: {prof.get('_templateName')}；画像: {args.profile}）")
    print(f"  结构识别: {len(order)} 个功能小节")
    print(f"  问题候选 {len(issues)} 条："
          + " ".join(f"{k}={v}" for k, v in sorted(by_kind.items())))
    print()
    cur_fun = object()
    for it in issues:
        if it["fun"] != cur_fun:
            cur_fun = it["fun"]
            print(f"── {cur_fun or '（全文）'} ──")
        loc = f" L{it['line']}" if it["line"] else ""
        print(f"  [{it['id']}][{it['kind']}]{loc} {it['text']}")
        if it["detail"].get("conds_differ"):
            for c in it["detail"]["conds"]:
                print(f"        口径: {c[:80]}")

    if args.out:
        Path(args.out).write_text(
            json.dumps({"source": args.input, "profile": args.profile,
                        "templateMatched": True,   # 0 小节已在上方 exit 3 拒跑
                        "funs": order,
                        "candidates": issues},
                       ensure_ascii=False, indent=2),
            encoding="utf-8")
        print(f"\n候选清单已输出：{args.out}（AI 预检须逐条表态：确认→PI / 误报→说明）")
    sys.exit(0)


if __name__ == "__main__":
    main()
