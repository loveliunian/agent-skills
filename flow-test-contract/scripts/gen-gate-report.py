#!/usr/bin/env python3
"""gen-gate-report.py —— 按契约 evidence_schema 生成 gate 证据报告骨架。

解决"报告格式手写易错"：读取契约 gates[].evidence_schema（kind=report），为每个声明
gate 产出一份 JSON 报告骨架：
  - flow_field 自动填契约 meta.flow_code（证据绑定目标流程）
  - required_fields 每项生成占位值：op=eq → "__FILL_<op>_<path>"；gte/lte → 0；
    contains/regex → "__FILL__"（填完后 api-capture/gate-evidence-check 会按断言真值判定——
    骨架本身不会"假通过"，必须人工/检查命令填真实结果）
  - 同时输出配套的 gate-evidence.json 条目骨架（path/sha256_16/generated_at/target_env 占位）

用法:
  python3 gen-gate-report.py --contract <test-contract.yaml> --outdir <dir> [--gate GATE-CANVAS ...]
产出:
  <outdir>/gate-reports/<GATE-ID>.json          # 证据报告骨架（填真值）
  <outdir>/gate-evidence.entries.json           # 拼装好的 gate-evidence.json 条目（含 sha 占位提示）

注意：sha256_16 无法预知（文件未定稿）——条目里 sha 置 __FILL_AFTER_REPORT_DONE__，
填完报告后运行自带的 sha 提示命令（或 sha256sum | cut -c1-16）回填。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：uv run --with pyyaml python3 gen-gate-report.py …")


def _placeholder_for(op: str):
    if op in ("gte", "lte"):
        return 0
    return f"__FILL_{op}__"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--contract", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--gate", action="append", default=[], help="只生成指定 gate（可多次）；缺省=全部 report 类")
    args = ap.parse_args()
    c = yaml.safe_load(Path(args.contract).read_text(encoding="utf-8")) or {}
    flow_code = str((c.get("meta") or {}).get("flow_code") or "")
    if not flow_code:
        sys.exit("⛔ 契约缺 meta.flow_code")
    only = set(args.gate)
    out_reports = Path(args.outdir) / "gate-reports"
    out_reports.mkdir(parents=True, exist_ok=True)
    entries, made, skipped = [], 0, []
    for g in c.get("gates") or []:
        if not isinstance(g, dict):
            continue
        gid = g.get("id")
        if gid == "GATE-HEALTH":
            skipped.append(f"{gid}（自动健康门禁，不需证据报告）")
            continue
        es = g.get("evidence_schema") or {}
        if es.get("kind") != "report":
            skipped.append(f"{gid}（kind={es.get('kind') or '未声明'}——仅生成 report 类骨架）")
            continue
        if only and gid not in only:
            continue
        report: dict = {}
        if es.get("flow_field"):
            # flow_field 形如 data.flow_code——按路径建嵌套并填真值（绑定目标流程）
            cur = report
            parts = str(es["flow_field"]).split(".")
            for p in parts[:-1]:
                cur = cur.setdefault(p, {})
            cur[parts[-1]] = flow_code
        for rf in es.get("required_fields") or []:
            path, op = str(rf.get("path")), str(rf.get("op"))
            cur = report
            parts = path.split(".")
            for p in parts[:-1]:
                cur = cur.setdefault(p, {})
            cur[parts[-1]] = _placeholder_for(op)
        rp = out_reports / f"{gid}.json"
        rp.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        entries.append({
            "id": gid, "type": "file",
            "path": str(rp.relative_to(Path(args.outdir))) if rp.is_relative_to(Path(args.outdir)) else str(rp),
            "sha256_16": "__FILL_AFTER_REPORT_DONE__（填完报告后：shasum -a 256 <file> | cut -c1-16）",
            "generated_at": "__FILL_ISO8601__（如 2026-09-07T10:00:00+08:00）",
            "target_env": "__FILL_TARGET_VERSION__",
        })
        made += 1
    (Path(args.outdir) / "gate-evidence.entries.json").write_text(
        json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[gen-gate-report] 生成 {made} 份报告骨架 → {out_reports}")
    print(f"[gen-gate-report] gate-evidence 条目骨架 → {Path(args.outdir) / 'gate-evidence.entries.json'}")
    for s in skipped:
        print(f"  - 跳过 {s}")
    print("下一步：逐份填真实检查结果（占位 __FILL_* 全部替换）→ 算 sha256_16 回填 →")
    print("      拼装进 run 目录 gate-evidence.json（docs/<流程>/自动化测试/对比测试/<run-id>/；generated_at/target_env 必填）")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"⛔ 内部异常: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
