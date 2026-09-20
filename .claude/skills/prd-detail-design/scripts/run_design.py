# -*- coding: utf-8 -*-
"""一键编排（copy 版四段流水）：问题清单校验 → blocking 裁决门 → 详设校验 → 双渲染。

产物分工（问题内容与设计内容彻底分离）：
  prd_issues.json / prd_issues.md —— 问题内容的唯一载体，给人裁决
  detail_design.json / detail_design.md —— 只含裁决后定稿内容，给机器实现

用法：
  python run_design.py --input detail_design.json --issues prd_issues.json \
      --design-out 详细设计.md --issues-out prd_issues.md

流水（任一环退出码非 0 即终止）：
  1. validate_issues.py --input prd_issues.json            问题清单自身合规
  2. validate_issues.py --input prd_issues.json --gate     blocking 全部裁决（硬门：
                                                           未裁决则详设禁止生成/更新）
  3. validate_design.py --input detail_design.json         详设合规（含零问题残留扫描）
  4. render_design.py + render_issues.py                   渲染双 MD
"""
import argparse
import subprocess
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def _run(cmd):
    return subprocess.run(cmd).returncode


def _reconcile(design_path, issues_path):
    """declared - designedComplete 差额与问题清单对账（警告级，不拦截）：
    差额 > 0 时，问题清单中应存在未 resolved（open/wontfix）且 affects/relatedAcceptances
    挂着 A 编号的问题作为解释；若一个问题都对不上号，提示差额无人认领。"""
    import json
    import re
    design = json.loads(Path(design_path).read_text(encoding="utf-8"))
    issues = json.loads(Path(issues_path).read_text(encoding="utf-8"))
    acc = design.get("acceptance", {})
    declared, designed = acc.get("declared"), acc.get("designedComplete")
    if not (isinstance(declared, int) and isinstance(designed, int)):
        return
    gap = declared - designed
    if gap <= 0:
        return
    hanging = [p.get("issueId") for p in issues.get("issues", [])
               if p.get("status") != "resolved"
               and any(re.search(r"A-?\d+", s) for s in
                       (p.get("affects", []) + (p.get("relatedAcceptances") or [])))]
    if hanging:
        print(f"  ⚠ declared={declared} > designedComplete={designed}，差额 {gap} 条；"
              f"可由未闭环问题解释：{'、'.join(hanging)}")
    else:
        print(f"  ⚠ declared={declared} > designedComplete={designed}，差额 {gap} 条，"
              f"但问题清单中没有挂着 A 编号的未闭环问题——差额无人认领，"
              f"请核对 declared 是否虚高或验收是否漏收。")


def _reconcile_decisions(design_path, issues_path):
    """裁决落地对账（硬拦）：问题清单中所有 resolved 且 blocking 的问题，
    必须在详设 meta.decisions 中登记落点——拦"裁决了但漏回填详设"。
    详设侧锚点真实性由 validate_design.py 的 check_decisions_landed 负责。"""
    import json
    design = json.loads(Path(design_path).read_text(encoding="utf-8"))
    issues = json.loads(Path(issues_path).read_text(encoding="utf-8"))
    resolved_blocking = [p.get("issueId") for p in issues.get("issues", [])
                         if p.get("status") == "resolved" and p.get("blocking")]
    if not resolved_blocking:
        return 0
    landed = {d.get("issueId") for d in design.get("meta", {}).get("decisions", []) or []}
    missing = [pid for pid in resolved_blocking if pid not in landed]
    if missing:
        print(f"  ✗ 问题清单中已裁决的 blocking 问题 {'、'.join(missing)} "
              f"未在详设 meta.decisions 登记落地锚点——裁决口径可能没回填进详设，"
              f"须补 decisions（issueId + landedAt 锚点）后重跑。")
        return 1
    print(f"  ✓ 裁决落地对账通过：{len(resolved_blocking)} 条已裁决 blocking 问题均有台账。")
    return 0


def _digest(path):
    import hashlib
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _freshness(design_path, issues_path):
    """新鲜度（警告级）：详设 meta.issuesDigest 记录生成时的 issues 内容哈希；
    issues 已变而 digest 还是旧值 → 详设可能是旧版。跑通后回写新 digest。"""
    import json
    design = json.loads(Path(design_path).read_text(encoding="utf-8"))
    current = _digest(issues_path)
    recorded = design.get("meta", {}).get("issuesDigest")
    if recorded and recorded != current:
        print("  ⚠ 问题清单自上次生成详设后已更新（issuesDigest 过期）——"
              "请确认本轮裁决口径已回填详设；本流水通过后将回写新 digest。")
    # 回写（无论是否告警，都刷新到当前状态）
    design.setdefault("meta", {})["issuesDigest"] = current
    Path(design_path).write_text(
        json.dumps(design, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")



def main():
    ap = argparse.ArgumentParser(description="问题清单校验→裁决门→详设校验→双渲染")
    ap.add_argument("--input", required=True, help="detail_design.json 路径")
    ap.add_argument("--issues", required=True, help="prd_issues.json 路径")
    ap.add_argument("--design-out", required=True, help="详设 Markdown 输出路径")
    ap.add_argument("--issues-out", required=True, help="问题清单 Markdown 输出路径")
    ap.add_argument("--max-rows", type=int, default=None, help="详设表格截断行数（默认不截断）")
    ap.add_argument("--scan", default=None,
                    help="prd_scan.json 路径：透传 validate_issues 的 I7 深扫覆盖对账（推荐提供）")
    args = ap.parse_args()

    def _issues_check(extra=()):
        cmd = [sys.executable, str(_HERE / "validate_issues.py"), "--input", args.issues, *extra]
        if args.scan:
            cmd += ["--scan", args.scan]
        return _run(cmd)

    print("── 阶段 1/4：问题清单校验 ──")
    if _issues_check():
        sys.exit(1)

    print("\n── 阶段 2/4：blocking 裁决门 ──")
    if _issues_check(["--gate"]):
        print("先完成裁决并回填 prd_issues.json（status=resolved + resolution），再生成详设。")
        sys.exit(1)

    print("\n── 阶段 3/4：详设校验（含零问题残留） ──")
    if _run([sys.executable, str(_HERE / "validate_design.py"), "--input", args.input]):
        sys.exit(1)

    print("\n── 阶段 3.5/4：对账（差额警告级 + 裁决落地硬拦 + 新鲜度哈希） ──")
    _reconcile(args.input, args.issues)
    if _reconcile_decisions(args.input, args.issues):
        sys.exit(1)
    _freshness(args.input, args.issues)

    print("\n── 阶段 4/4：双渲染 ──")
    cmd = [sys.executable, str(_HERE / "render_design.py"), "--input", args.input, "--out", args.design_out]
    if args.max_rows:
        cmd += ["--max-rows", str(args.max_rows)]
    if _run(cmd):
        sys.exit(1)
    if _run([sys.executable, str(_HERE / "render_issues.py"), "--input", args.issues, "--out", args.issues_out]):
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
