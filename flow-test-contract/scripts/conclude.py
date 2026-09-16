#!/usr/bin/env python3
"""conclude.py v4 —— 结论 Gate（PASS / FAIL / BLOCKED 三态，fail-closed）。

v4（1.3.4 P0）：纯评估器提取至 scripts/conclude_core.py，本脚本仅负责 IO
（读取证据、调用 evaluate、写入 summary.json/md）——评估逻辑与 run_evidence 共享。
"""
from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path

# 插入同级目录以 import conclude_core
_SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_SCRIPT_DIR))
sys.dont_write_bytecode = True
import conclude_core  # noqa: E402


def _md(s) -> str:
    return (str(s).replace("\\", "\\\\").replace("\n", "\\n")
            .replace("\r", "\\r").replace("\x1b", "^["))


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--report-dir", required=True)
    ap.add_argument("--contract", help="契约路径（提供则与 case-results 交叉核对）")
    args = ap.parse_args()
    d = Path(args.report_dir)

    summary_path = d / "summary.json"
    if summary_path.exists():
        print(f"[conclude] BLOCKED: summary.json 已存在（run 结论不可重写；重跑请用新 run-id）", file=sys.stderr)
        raise SystemExit(2)

    ev = conclude_core.evaluate(d, args.contract)

    if not ev["ledger_binding"]:
        print("[conclude] BLOCKED: 无完整可信账本（run-manifest.json 缺失/损坏/run_id 缺失或与目录错配）"
              "——不产出 summary.json/md（无账本不得有结论件）", file=sys.stderr)
        for rsn in ev["reasons"]:
            print(f"  - {rsn}", file=sys.stderr)
        raise SystemExit(2)

    manifest = ev["manifest"]
    summary = {
        "run_id": manifest.get("run_id", d.name),
        "conclusion": ev["conclusion"],
        "p0_count": ev["p0_count"],
        "p1_count": ev["p1_count"],
        "required_cases": {"total": ev["required_total"], "done": ev["required_done"]},
        "semantic_diffs": ev["semantic_diffs"],
        "exempted_diffs": ev["exempted_diffs"],
        "failed_cases": ev["failed_cases"],
        "blocked_reasons": ev["blocked_reasons"],
        "aux_evidence": {"pixel_diff": "auxiliary only（dual-run-diff.js evidenceTier=auxiliary，不进入结论）"},
        "evidence_paths": manifest.get("evidence_paths", []),
        "comparator_version": (ev.get("fc") or {}).get("version", "n/a"),
        "conclusion_lock": "结论仅绑定本 run-id；重跑必须新 run-id 全量执行",
    }
    if ev["bc_info"] is not None:
        summary["branch_scope"] = {**ev["bc_info"], "conclusion_scope": ev["conclusion_scope"]}
    if ev["forward_conclusion"] is not None:
        summary["forward_conclusion"] = ev["forward_conclusion"]
    if ev.get("coverage_info") is not None:
        summary["coverage_scope"] = ev["coverage_info"]

    d.mkdir(parents=True, exist_ok=True)
    _tmp = d / "summary.json.tmp"
    _tmp.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    _tmp.replace(summary_path)

    md_lines = [f"# 执行结论 · {summary['run_id']}", "",
                f"## conclusion: **{ev['conclusion']}**", "",
                f"- P0={ev['p0_count']} P1={ev['p1_count']}；必测用例 {ev['required_done']}/{ev['required_total']}（仅 PASS 计完成）",
                f"- 语义差异（未豁免）: {len(ev['semantic_diffs'])}；豁免: {len(ev['exempted_diffs'])}；失败用例: {ev['failed_cases'] or '无'}"]
    if ev["conclusion_scope"] == "forward_branches_only":
        if ev["forward_conclusion"] == "PASS":
            md_lines += ["", f"**⚠ 分支范围限定（不构成全量 PASS）**：{ev['forward_note']}。"
                           f"正向分支全部通过（forward_conclusion=PASS，信息性字段）；"
                           f"正式三态结论为 **BLOCKED**。"]
        else:
            md_lines += ["", f"**⚠ 分支范围限定**：{ev['forward_note']}。"]
    if ev["reasons"]:
        md_lines += ["", "## BLOCKED 原因"] + [f"- {_md(r)}" for r in ev["reasons"]]
    if ev["semantic_diffs"]:
        md_lines += ["", "## 语义差异明细"] + [
            f"- [{_md(x.get('dim'))}] {_md(x.get('key'))}: legacy={_md(x.get('legacy'))} current={_md(x.get('current'))} ({_md(x.get('reason'))})"
            for x in ev["semantic_diffs"]]
    md_lines += ["", "> 像素 diff 仅为辅助证据；缺任一必要证据=BLOCKED（fail-closed）。", ""]
    _tmp_md = d / "summary.md.tmp"
    _tmp_md.write_text("\n".join(md_lines), encoding="utf-8")
    _tmp_md.replace(d / "summary.md")
    print(f"[conclude] {ev['conclusion']} → {summary_path}")
    raise SystemExit({"PASS": 0, "FAIL": 1, "BLOCKED": 2}[ev["conclusion"]])


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[conclude] BLOCKED: 结论器内部异常（fail-closed，不产出结论）: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)