#!/usr/bin/env python3
"""write-manifest.py —— 不可篡改运行账本（run-manifest.json）。

每次执行由 pipeline.sh 调用，落账到 run 目录（docs/<流程>/自动化测试/对比测试/<run-id>/）run-manifest.json：
  源/目标发布版本、流程版本、配置快照 hash、测试数据指纹、实例号对、
  执行者、证据路径、比较器版本。

用法:
  python3 $SKILL/scripts/write-manifest.py --run-id <ts> \
    --reports-dir <runtime>/reports --project-root . \
    [--contract docs/<流程>/自动化测试/test-contract.yaml] \
    [--flow-def .flowtrace/flow-defs/<流程>.yaml]  # 旧流水线资产（可选） \
    [--source-version ...] [--target-version ...] [--flow-version ...] \
    [--instance-pairs path.json] [--evidence-dir path]

设计: 账本一经写入**永不覆盖**（第十一轮 2026-09-07 移除 --force——
  可被强制重写的账本没有采信价值；重跑只能用新 run-id）；
  hash 用 sha256；同 run-id 重写/并发写入以原子硬链接占位拒绝——只有一个首写者成功
  （其余 exit 3）；run-id 只允许 [A-Za-z0-9._-] 且不得含 ..（防路径穿越）；
  顶层异常一律 exit 2（crash 不引入未定义退出码）。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

COMPARATOR_VERSION = "field-level-compare.py v2.11"
# 注意：用 fullmatch 而非 match+'$'——Python '$' 允许尾随换行（"abc\n" 可匹配 ^…$），
# 第五轮审计实测 "abc\n" 可建出带换行的目录名（bash 侧 ERE 会拒、python 侧漏）——口径必须一致
RUN_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def hash_entry(f: Path) -> str:
    """文件→sha256[:16]；目录→按 (相对路径+内容) 串联哈希（与 conclude 复算保持同算法）。"""
    if f.is_dir():
        h = hashlib.sha256()
        for x in sorted(f.rglob("*")):
            if x.is_file():
                h.update(str(x.relative_to(f)).encode())
                h.update(x.read_bytes())
        return h.hexdigest()[:16]
    return hashlib.sha256(f.read_bytes()).hexdigest()[:16]


def sha256_dir(d: Path) -> str:
    h = hashlib.sha256()
    for f in sorted(d.rglob("*")):
        if f.is_file():
            h.update(str(f.relative_to(d)).encode())
            h.update(f.read_bytes())
    return h.hexdigest()[:16]


def git_rev(root: Path) -> str:
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=root,
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return "unknown"


def toolchain_fingerprint() -> dict:
    """工具链指纹（1.1.0 可复现性）：skill 版本 + MANIFEST sha + 逐脚本哈希 + 运行时版本。

    背景：账本此前只记系统三元版本与比较器串——同一 run 用的 skill 代码/依赖/浏览器 CLI
    版本无从追溯，正式 PASS 无法复现。此处全部现算落账（探测失败记 unknown，不阻断落账；
    正式 PASS 的强制性由 conclude/pipeline 侧门禁承担）。
    """
    skill_root = Path(__file__).resolve().parent.parent
    fp: dict = {"skill_root": str(skill_root)}
    # 1) skill 版本（SKILL.md frontmatter version）
    try:
        head = (skill_root / "SKILL.md").read_text(encoding="utf-8").split("---")[1]
        m = re.search(r"^version:\s*(\S+)", head, re.M)
        fp["skill_version"] = m.group(1) if m else "unrecorded"
    except Exception:
        fp["skill_version"] = "unrecorded"
    # 2) MANIFEST.txt 全文 sha256（分发清单指纹）
    try:
        fp["manifest_sha256"] = hashlib.sha256((skill_root / "MANIFEST.txt").read_bytes()).hexdigest()
    except Exception:
        fp["manifest_sha256"] = "unrecorded"
    # 3) 参与本次执行的脚本逐文件 sha256[:16]（清单驱动，不手写第二套列表）
    scripts: dict[str, str] = {}
    try:
        for line in (skill_root / "MANIFEST.txt").read_text(encoding="utf-8").splitlines():
            rel = line.split("\t")[0].strip()
            if not rel or rel.startswith("#"):
                continue
            if not (rel.endswith(".py") or rel.endswith(".sh")):
                continue
            p = skill_root / rel
            if p.is_file():
                scripts[rel] = hashlib.sha256(p.read_bytes()).hexdigest()[:16]
    except Exception:
        pass
    fp["script_sha256_16"] = scripts or "unrecorded"
    # 4) 运行时与依赖版本
    fp["python"] = sys.version.split()[0]
    deps: dict[str, str] = {}
    for mod in ("yaml", "jsonschema"):
        try:
            deps[mod] = __import__('importlib.metadata', fromlist=['version']).version(mod)
        except Exception:
            deps[mod] = "unavailable"
    fp["python_deps"] = deps
    # 5) 浏览器 CLI（仅 browser 通道有意义；未配置=not-configured）
    cli = os.environ.get("PLAYWRIGHT_CLI", "").strip()
    if cli:
        try:
            out = subprocess.run([cli, "--version"], capture_output=True, text=True, timeout=20)
            fp["playwright_cli"] = f"{cli} :: {((out.stdout or out.stderr).strip().splitlines() or ['unknown'])[0]}"
        except Exception as e:
            fp["playwright_cli"] = f"{cli} :: probe-failed({type(e).__name__})"
    else:
        fp["playwright_cli"] = "not-configured"
    fp["runner"] = os.environ.get("FLOWTEST_RUNNER") or os.environ.get("FLOWTRACE_RUNNER") or "api"
    return fp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--reports-dir", required=True)
    ap.add_argument("--project-root", default=".")
    ap.add_argument("--contract")
    ap.add_argument("--flow-def")
    ap.add_argument("--source-version", default=os.environ.get("SOURCE_VERSION", "unrecorded"))
    ap.add_argument("--target-version", default=os.environ.get("TARGET_VERSION", "unrecorded"))
    ap.add_argument("--flow-version", default=os.environ.get("FLOW_VERSION", "unrecorded"))
    ap.add_argument("--rules")
    ap.add_argument("--scenarios")
    ap.add_argument("--case-results")
    ap.add_argument("--gates-file")
    ap.add_argument("--field-compare")
    ap.add_argument("--allow-unrecorded-versions", action="store_true")
    ap.add_argument("--instance-pairs")
    ap.add_argument("--extra-file", action="append", default=[],
                    help="补充证据登记 NAME=PATH（可多次，如 data_ledger=<run>/test-data-ledger.json）"
                         "——sha256 入 config_snapshot，防清理痕迹游离于证据链外（v1.6.0）")
    ap.add_argument("--evidence-dir")
    args = ap.parse_args()

    # run-id 消毒：防路径穿越/隐藏字符（conclude 还会复验 run_id==目录名）
    if not RUN_ID_RE.fullmatch(args.run_id or "") or ".." in args.run_id:
        print(f"[manifest] ⛔ 非法 run-id: {args.run_id!r}（只允许 [A-Za-z0-9._-] 且不含 ..）", file=sys.stderr)
        raise SystemExit(2)

    root = Path(args.project_root)
    out = Path(args.reports_dir) / args.run_id / "run-manifest.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        # 第十一轮：--force 已移除——账本彻底不可覆盖（可重写的账本不可采信）
        print(f"[manifest] ⛔ 已存在，拒绝覆盖：{out}（账本不可篡改；重跑请用新 run-id）", file=sys.stderr)
        raise SystemExit(3)

    versions = {"source": args.source_version, "target": args.target_version, "flow": args.flow_version}
    unrecorded = [k for k, v in versions.items() if not v or v == "unrecorded"]
    if unrecorded and not args.allow_unrecorded_versions:
        print(f"[manifest] ⛔ 版本未记录: {unrecorded}（--source/--target/--flow-version 或 --allow-unrecorded-versions）", file=sys.stderr)
        raise SystemExit(2)

    snapshot = {}
    missing = []
    for key, p in [("contract", args.contract), ("flow_def", args.flow_def),
                   ("rules", args.rules), ("scenarios", args.scenarios),
                   ("case_results", args.case_results), ("gates", args.gates_file),
                   ("field_compare", args.field_compare)]:
        if p:
            f = root / p if not Path(p).is_absolute() else Path(p)
            if f.exists():
                snapshot[key] = {"path": p, "abs_path": str(f.resolve()), "sha256_16": hash_entry(f)}
            else:
                snapshot[key] = {"path": p, "missing": True}
                missing.append(f"{key}={p}")
    for kv in getattr(args, "extra_file", []) or []:
        name, _, ep = kv.partition("=")
        name = name.strip()
        if not name or not ep.strip() or "=" in ep:
            print(f"[manifest] ⛔ --extra-file 形态非法（须 NAME=PATH 且 NAME 不含=）: {kv!r}", file=sys.stderr)
            raise SystemExit(2)
        f = Path(ep)
        if not f.is_file():
            snapshot[name] = {"path": ep, "missing": True}
            missing.append(f"{name}={ep}")
        else:
            snapshot[name] = {"path": ep, "abs_path": str(f.resolve()), "sha256_16": hash_entry(f)}
    if missing:
        # 账本完整性 fail-closed：显式传入的证据文件必须存在，否则账本不可信
        print(f"[manifest] ⛔ 登记文件缺失: {missing}——账本不完整，拒绝落账", file=sys.stderr)
        raise SystemExit(4)
    ev = Path(args.evidence_dir) if args.evidence_dir else out.parent / "evidence"
    manifest = {
        "run_id": args.run_id,
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "actor": os.environ.get("USER", "unknown"),
        "git_rev": git_rev(root),
        "versions": {"source": args.source_version, "target": args.target_version, "flow": args.flow_version},
        "config_snapshot": snapshot,
        "test_data_fingerprint": {"fixtures": "see contract.fixtures + evidence captures",
                                  "evidence_dir_sha256_16": sha256_dir(ev) if ev.exists() else None},
        "instance_pairs": args.instance_pairs or "record into run 目录 instance-pairs.json",
        "evidence_paths": [str(ev)],
        "comparator_version": COMPARATOR_VERSION,
        "toolchain": toolchain_fingerprint(),
        "conclusion_lock": "结论由 conclude.py 写入 summary.json（同样不可重写）；本账本永不改写——重跑必须新 run-id",
    }
    # 原子独占落账：先写临时文件再硬链接占位——同 run-id 并发只有一个成功（防 TOCTOU 双写）
    tmp = out.with_name(f"run-manifest.json.tmp-{os.getpid()}")
    tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    try:
        os.link(tmp, out)
    except FileExistsError:
        print(f"[manifest] ⛔ 已存在（并发首写者已占位），拒绝覆盖：{out}（账本不可篡改；重跑请用新 run-id）", file=sys.stderr)
        tmp.unlink(missing_ok=True)
        raise SystemExit(3)
    else:
        tmp.unlink(missing_ok=True)
    print(f"[manifest] 写入 {out}")


if __name__ == "__main__":
    # 第七轮审计：落账器任何未预期异常（登记文件不可读等）折为 exit 2——
    # 不得以未定义的 crash exit 1 混淆退出码语义（pipeline 侧虽有兜底，直用也须干净拒绝）
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        import traceback

        traceback.print_exc()
        print(f"[manifest] ⛔ 落账失败（内部异常，fail-closed，账本未写）: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
