#!/usr/bin/env python3
"""gen-final-report.py —— 最终对比测试报告生成器（单一 md 交付物）。

把一个 run 目录的全部机器证据（账本/用例/对拍/门禁/三态结论）汇总为**一份**
`对比测试报告.md`，落在 run 目录（docs/<流程>/自动化测试/对比测试/<run-id>/）下——执行者零手工拼接。

v1.4.0 可读性改造（给人读）：
  - 报告头部新增「一句话结论」（one_line_conclusion，人话陈述三态事实）；
  - §2 结论速览新增 FAIL 时的差异摘要（最多 3 条人话摘要，取自 conclude_core 重算）；
  - §3 用例总表加状态徽标（✅ PASS / ❌ FAIL / ⛔ BLOCKED）；
  - §4 语义对拍明细按用例分组，维度中文化 + 原因人话化（共享 fc_readability，唯一实现），
    双端值并排呈现（（空）显式化、容器 JSON 短串）——机器字段（json）一字不改，
    人话只是"说法"，事实仍以 conclude_core 重算与 field-compare.json 为准。

v1.3.4 P1 修复：
  - **证据链强制核验**：正式 PASS/FAIL 报告必须五件证据齐全、账本登记 sha 复算一致，
    且由 conclude 同一纯评估器（conclude_core）重算结论与 summary.conclusion 一致——
    一个手写 summary.json 不再能伪造带 ✅ PASS 的正式报告。核验失败 exit 2，
    除非显式 --allow-unverified（报告将醒目标注"未核验"，且不写结论徽标）。
  - **人工内容拆分**：产品级发现（D-xx/O-xx）由执行者写入同目录 `人工发现.md`
    （首次自动建模板，机器永不覆盖）；机器报告重生成不吞人工内容。已有机器报告
    默认拒绝静默覆盖，需 --overwrite。

用法:
  python3 gen-final-report.py --run-dir docs/<流程>/自动化测试/对比测试/<run-id>
                              [--title ...] [--overwrite] [--allow-unverified]
  pipeline.sh 在 conclude 后自动调用（summary.json 存在才生成——fail-closed：无结论不产报告）。

数据源（全部只读）:
  summary.json（必需，缺失=exit 2）/ run-manifest.json / case-results.json /
  field-compare.json 或 field-compare-<CASE>*/（逐用例对拍）/ gates.json / instance-pairs.json
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
from datetime import datetime
from pathlib import Path

sys.dont_write_bytecode = True   # 审计 P1-3：动态加载共享库时零字节码（skill 目录零副作用）


_SCRIPT_DIR = Path(__file__).resolve().parent
HUMAN_FINDINGS_NAME = "人工发现.md"

# v1.4.0：人话化共享库（与 field-level-compare 同一实现，禁止两套）
sys.path.insert(0, str(_SCRIPT_DIR))
try:
    import fc_readability as _fr
except Exception:  # pragma: no cover - 缺库时报告仍可生成（退化为机器原文）
    _fr = None


def _dim_cn(dim) -> str:
    return _fr.dim_cn(dim) if _fr else str(dim or "")


def _human_reason(dim, reason) -> str:
    return _fr.human_reason(dim, reason) if _fr else str(reason or "")


def _case_of(key) -> str:
    return _fr.diff_case(key) if _fr else str(key or "").split(":")[0].split("/")[0]


def _where_of(key) -> str:
    return _fr.diff_where(key) if _fr else str(key or "")


def _val(v, limit: int = 60) -> str:
    return _fr.fmt_value(v, limit) if _fr else ("" if v is None else str(v))


def jload(p: Path):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def esc(v) -> str:
    if v is None:
        return "—"
    s = str(v).replace("|", "\\|").replace("\n", " ")
    return s if len(s) <= 120 else s[:117] + "…"


def _brief(v, limit: int = 80) -> str:
    try:
        s = json.dumps(v, ensure_ascii=False)
    except Exception:
        s = str(v)
    return s if len(s) <= limit else s[: limit - 1] + "…"


def _load_conclude_core():
    """加载纯评估器 conclude_core（与 conclude.py/run_evidence.py 同一结论口径）。"""
    for cand in (_SCRIPT_DIR / "conclude_core.py",
                 _SCRIPT_DIR.parent / "scripts" / "conclude_core.py",
                 _SCRIPT_DIR.parent.parent / ".flow-test-contract" / "scripts" / "conclude_core.py"):
        if cand.is_file():
            spec = importlib.util.spec_from_file_location("ftc_conclude_core_gfr", cand)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    return None


def verify_run_evidence(run_dir: Path, summary: dict):
    """核验证据链：五件齐全 + 账本 sha 全量复算 + **结论/统计重算与 summary 逐字段一致**。
    返回 (ok: bool, problems: list[str], ev: dict|None)。

    v1.3.6 P1：此前只比对 conclusion，随后又从 summary 读取 P0/P1/用例数等统计——保持真实
    conclusion=FAIL、只把统计字段改假即可生成"已核验"报告。现报告数值一律取自 conclude_core
    重算结果（canonical），summary 仅作对照；summary 中存在的 canonical 字段不一致即核验失败。"""
    problems: list[str] = []
    for name in ("run-manifest.json", "case-results.json", "gates.json", "field-compare.json"):
        if (run_dir / name).is_symlink() or not (run_dir / name).is_file():
            problems.append(f"缺正式证据: {name}")
    manifest = jload(run_dir / "run-manifest.json")
    if not isinstance(manifest, dict):
        problems.append("run-manifest.json 缺失/不可解析（无账本不得出正式报告）")
        return False, problems, None

    rid_dir = run_dir.name
    rid_bare = rid_dir[4:] if rid_dir.startswith("run-") else rid_dir
    rid_mf = str(manifest.get("run_id") or "")
    rid_sm = str(summary.get("run_id") or rid_mf)
    if not rid_mf or rid_mf != rid_sm or rid_mf not in (rid_dir, rid_bare):
        problems.append(f"run-id 错配: 目录={rid_dir} 账本={rid_mf!r} 结论={rid_sm!r}")

    # 账本 config_snapshot 全量复算（含五件核心证据路径须在本 run 目录内）
    snap = manifest.get("config_snapshot")
    cc = _load_conclude_core()
    if cc is None:
        problems.append("找不到 conclude_core.py——无法复算账本/结论")
        snap = snap if isinstance(snap, dict) else {}
    if not isinstance(snap, dict) or not snap:
        problems.append("账本 config_snapshot 为空——正式报告必须基于已落账且 sha 复算一致的证据")
    else:
        in_run = {"gates": "gates.json", "case_results": "case-results.json",
                  "field_compare": "field-compare.json"}
        for key, fname in in_run.items():
            ent = snap.get(key)
            if not isinstance(ent, dict):
                problems.append(f"{fname} 未登记进账本（正式证据必须全部入账）")
                continue
            declared = str(ent.get("abs_path") or ent.get("path") or "")
            p = run_dir / fname
            if not declared or Path(declared).resolve() != p.resolve():
                problems.append(f"{fname} 账本登记路径不是本 run 内实体文件（诱饵/异地证据）")
                continue
            actual = hashlib.sha256(p.read_bytes()).hexdigest()[:16]
            if str(ent.get("sha256_16") or "") != actual:
                problems.append(f"{fname} 与账本登记 sha 不一致（证据被改动）")
        # 其余登记项（contract/rules/scenarios 目录等）也必须复算一致——缺文件/被改写即断链
        for key, ent in snap.items():
            if key in in_run or not isinstance(ent, dict) or cc is None:
                continue
            declared = str(ent.get("abs_path") or ent.get("path") or "")
            want = str(ent.get("sha256_16") or "")
            if not declared or not want:
                continue  # 非证据登记（无 sha/path 的元信息）不参与
            f = Path(declared)
            if not f.exists():
                problems.append(f"账本登记文件丢失: {key}（证据链断裂）")
                continue
            try:
                h = cc.entry_hash(f)   # 与 write-manifest/conclude 同算法（文件/目录一致）
            except Exception as e:
                problems.append(f"账本登记文件不可读: {key}（{type(e).__name__}: {e}）")
                continue
            if h != want:
                problems.append(f"账本登记文件 hash 不符（被修改）: {key}")

    # 结论/统计全量复算（与 conclude.py 同一评估器）
    ev = None
    if cc is None:
        pass  # 已记账本/结论不可复算问题
    else:
        # 审计第 7 轮 P2-2：手工混合调用（conclude 显式 --contract 但账本未登记 contract 条目）
        # 时覆盖/契约门禁不可复算——补一条直白原因，避免只剩间接的"结论复算不一致"
        cs_contract_pre = snap.get("contract") if isinstance(snap, dict) else None
        if not cs_contract_pre and (summary.get("coverage_scope") or summary.get("branch_scope")) \
                and not any("账本未登记 contract" in x for x in problems):
            problems.append("账本 config_snapshot 未登记 contract 条目——覆盖账本/契约门禁无法复算；"
                            "请走 pipeline 正式落账后重生成报告")
        cs_contract = snap.get("contract") if isinstance(snap, dict) else None
        cp = None
        if isinstance(cs_contract, dict):
            _c = Path(str(cs_contract.get("abs_path") or cs_contract.get("path") or ""))
            if _c.is_file():
                cp = str(_c)
        ev = cc.evaluate(run_dir, cp, allowed_run_ids={rid_dir, rid_bare})
        recorded = str(summary.get("conclusion") or "")
        if recorded not in ("PASS", "FAIL", "BLOCKED"):
            problems.append(f"summary.conclusion={recorded!r} 非法（只认 PASS/FAIL/BLOCKED）")
        if ev["conclusion"] != recorded:
            problems.append(f"结论复算不一致: 重算={ev['conclusion']} ≠ summary={recorded}"
                            f"（手写/篡改的结论不得出正式报告；重算原因: {'; '.join(ev['reasons'][:3])}）")
        # v1.3.6 P1：summary 中出现的 canonical 统计字段必须与重算一致（报告数值一律用重算值）
        for _k, _want in (("p0_count", ev["p0_count"]),
                          ("p1_count", ev["p1_count"]),
                          ("required_cases", {"total": ev["required_total"], "done": ev["required_done"]})):
            if _k in summary and summary[_k] != _want:
                problems.append(f"summary 与重算不一致（{_k}）: summary={_brief(summary[_k])} "
                                f"重算={_brief(_want)}——手改统计字段不得出正式报告")
        for _k, _lst in (("semantic_diffs", ev["semantic_diffs"]),
                         ("exempted_diffs", ev["exempted_diffs"]),
                         ("failed_cases", ev["failed_cases"]),
                         ("blocked_reasons", ev["blocked_reasons"])):
            if _k in summary and len(summary.get(_k) or []) != len(_lst):
                problems.append(f"summary 与重算条数不一致（{_k}）: summary={len(summary.get(_k) or [])} "
                                f"重算={len(_lst)}——手改统计字段不得出正式报告")
        if ev.get("bc_info") is not None and "branch_scope" in summary:
            _bs_want = {**ev["bc_info"], "conclusion_scope": ev["conclusion_scope"]}
            if summary["branch_scope"] != _bs_want:
                problems.append(f"summary 与重算不一致（branch_scope）: summary={_brief(summary['branch_scope'])} "
                                f"重算={_brief(_bs_want)}")
        if ev.get("coverage_info") is not None and "coverage_scope" in summary:
            # v1.5.0：覆盖账本摘要进防篡改面（与 branch_scope 同律）
            if summary["coverage_scope"] != ev["coverage_info"]:
                problems.append(f"summary 与重算不一致（coverage_scope）: summary={_brief(summary['coverage_scope'])} "
                                f"重算={_brief(ev['coverage_info'])}")
        if ev.get("forward_conclusion") is not None and "forward_conclusion" in summary \
                and summary["forward_conclusion"] != ev["forward_conclusion"]:
            problems.append(f"summary 与重算不一致（forward_conclusion）: "
                            f"summary={summary['forward_conclusion']!r} 重算={ev['forward_conclusion']!r}")
    return not problems, problems, ev


def collect_field_compares(run_dir: Path) -> list[tuple[str, dict]]:
    """field-compare.json（整 run）与 field-compare-<CASE>/（逐用例）统一收集。"""
    out: list[tuple[str, dict]] = []
    top = run_dir / "field-compare.json"
    if top.is_file():
        d = jload(top)
        if isinstance(d, dict):
            out.append(("全 run", d))
    for p in sorted(run_dir.glob("field-compare-*/field-compare*.json")) + \
             sorted(run_dir.glob("field-compare-*.json")):
        if p.is_file():
            d = jload(p)
            if isinstance(d, dict):
                out.append((p.parent.name if p.parent.name.startswith("field-compare-") else p.stem, d))
    return out


def ensure_human_findings(run_dir: Path) -> Path:
    """人工发现独立文件：首次创建模板，之后机器永不覆盖（v1.3.4 P1）。"""
    p = run_dir / HUMAN_FINDINGS_NAME
    if not p.exists():
        p.write_text(
            "# 产品级发现与跟进（人工记录，机器不覆盖）\n\n"
            "> 按 lessons-learned L22/L23：对拍之外顺带发现的产品缺陷单独编号\n"
            "> （D-xx 缺陷/P 级，O-xx 观察项）；环境级阻塞与产品缺陷分开表述。\n"
            "> 本文件只由执行者手工维护；gen-final-report.py 重跑不会覆盖它。\n\n"
            "| 编号 | 级别 | 现象 | 根因/建议 | 状态 |\n"
            "|---|---|---|---|---|\n"
            "| （示例）D-01 | P2 | … | … | 待跟进 |\n",
            encoding="utf-8")
    return p


def skill_version() -> str:
    """版本号单一事实源：SKILL.md frontmatter（与 write-manifest toolchain 同口径）。"""
    import re
    skill_md = _SCRIPT_DIR.parent / "SKILL.md"
    try:
        head = skill_md.read_text(encoding="utf-8").split("---", 2)
        m = re.search(r"^version:\s*(\S+)", head[1], re.M)
        return m.group(1) if m else "unknown"
    except Exception:
        return "unknown"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--title", default="")
    ap.add_argument("--overwrite", action="store_true",
                    help="允许重写已有机器报告（人工内容在独立 人工发现.md，不受影响）")
    ap.add_argument("--allow-unverified", action="store_true",
                    help="证据核验失败仍生成报告：报告醒目标注'未核验'且不呈现正式结论徽标（审计可见）")
    a = ap.parse_args()
    run_dir = Path(a.run_dir)

    summary = jload(run_dir / "summary.json")
    if not isinstance(summary, dict) or "conclusion" not in summary:
        print(f"✗ 缺 summary.json 或非法（无结论不产报告——fail-closed）: {run_dir}", file=sys.stderr)
        return 2

    # 证据链强制核验（v1.3.4 P1）：手写 summary.json 不再能伪造正式报告
    ok, problems, ev = verify_run_evidence(run_dir, summary)
    verified = ok
    if not ok and not a.allow_unverified:
        print(f"✗ 证据链核验失败，拒绝生成正式报告: {run_dir}", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print("  如确需出仅供排查的草稿，显式加 --allow-unverified（报告会醒目标注未核验）", file=sys.stderr)
        return 2
    if not ok:
        print("⚠ 证据链核验未通过，按 --allow-unverified 生成草稿报告（不呈现正式结论徽标）:",
              file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)

    # v1.3.6 P1：未核验草稿写入独立文件名（不再是正式名 对比测试报告.md）
    out = run_dir / ("对比测试报告.md" if verified else "对比测试报告-未核验草稿.md")
    if out.exists() and not a.overwrite:
        print(f"✗ 报告已存在，拒绝静默覆盖: {out}", file=sys.stderr)
        print("  机器部分确需重生成请加 --overwrite；人工内容在独立文件不被覆盖。", file=sys.stderr)
        return 2

    # 人工内容独立文件（首次建模板，永不覆盖）
    human_findings = ensure_human_findings(run_dir)

    manifest = jload(run_dir / "run-manifest.json") or {}
    cases = jload(run_dir / "case-results.json") or []
    gates = jload(run_dir / "gates.json") or []
    fcs = collect_field_compares(run_dir)
    versions = manifest.get("versions") or {}
    cfg_snap = (manifest.get("config_snapshot") or {})
    contract_ent = cfg_snap.get("contract") if isinstance(cfg_snap.get("contract"), dict) else None
    contract_path = (contract_ent or {}).get("path") if isinstance(contract_ent, dict) else cfg_snap.get("contract")
    # v1.3.6 P1：报告数值一律取自 conclude_core 重算结果（canonical）；仅当评估器不可用时
    # 才回退 summary（此时必为未核验草稿，醒目标注）。summary 只作对照，不再被采信。
    recorded_concl = str(summary.get("conclusion") or "?")
    if ev is not None:
        concl = ev["conclusion"]
        p0_count, p1_count = ev["p0_count"], ev["p1_count"]
        req_done, req_total = ev["required_done"], ev["required_total"]
        n_semantic, n_exempted = len(ev["semantic_diffs"]), len(ev["exempted_diffs"])
        n_failed = len(ev["failed_cases"])
        blocked_reasons = ev["blocked_reasons"]
        bs = ({**ev["bc_info"], "conclusion_scope": ev["conclusion_scope"]}
              if ev.get("bc_info") is not None else None)
        fwd = ev.get("forward_conclusion")
    else:
        concl = recorded_concl
        p0_count, p1_count = summary.get("p0_count"), summary.get("p1_count")
        _rc = summary.get("required_cases") or {}
        req_done, req_total = _rc.get("done", 0), _rc.get("total", 0)
        n_semantic = len(summary.get("semantic_diffs") or [])
        n_exempted = len(summary.get("exempted_diffs") or [])
        n_failed = len(summary.get("failed_cases") or [])
        blocked_reasons = summary.get("blocked_reasons") or []
        bs = summary.get("branch_scope") if isinstance(summary.get("branch_scope"), dict) else None
        fwd = summary.get("forward_conclusion")
    if verified:
        concl_badge = {"PASS": "✅ PASS", "FAIL": "❌ FAIL", "BLOCKED": "⛔ BLOCKED"}.get(concl, concl)
        concl_field = concl
    else:
        # 机器字段=UNVERIFIED；summary 的自述仅作括注（PASS 明示为"summary 自述"）
        concl_field = "UNVERIFIED"
        concl_badge = f"⚠️ UNVERIFIED（summary 自述：{recorded_concl}，证据链核验未通过——不得作为正式结论）"

    L: list[str] = []
    title = a.title or "新老系统对比执行报告"
    rid = manifest.get("run_id") or run_dir.name
    rid_display = rid if str(rid).startswith("run-") else f"run-{rid}"
    L.append(f"# {title}（{rid_display}）")
    L.append("")
    L.append(f"> flow-test-contract v{skill_version()} 契约体系产出；本报告由 gen-final-report.py")
    if verified:
        L.append("> 从 run 目录机器证据自动汇总（账本/用例/对拍/门禁/结论同源，零手工拼接；")
        L.append("> 结论经 conclude_core 纯评估器重算与 summary 一致，账本 sha 全量复算通过）。")
    else:
        L.append("> ⚠ **本报告证据链核验未通过（--allow-unverified 草稿）——不构成正式 PASS/FAIL 证据**。")
        L.append("> 机器证据缺失/被改动或结论重算不一致；核验问题见生成时 stderr 与 §6。")
    L.append(f"> 结论仅绑定 run-id={rid}；账本只增不改，重跑必须新 run-id。")
    L.append("")
    if verified:
        _concl_line = f"**结论**: **{concl_field}**　{concl_badge}"
    else:
        _concl_line = f"**结论**: **UNVERIFIED**（summary 自述：{recorded_concl}）"
    L.append(f"**生成时间**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}　{_concl_line}")
    # v1.4.0：一句话结论（人话陈述三态事实——统计一律取自 conclude_core 重算值）；
    # v1.4.2：未核验草稿不渲染（人话不得为伪造 summary 背书——审计第 1 轮 P1-2）
    _top_diffs = (ev["semantic_diffs"] if ev is not None else (summary.get("semantic_diffs") or []))
    if _fr is not None and verified:
        _one = _fr.one_line_conclusion(concl, req_done=req_done, req_total=req_total,
                                       n_diff=n_semantic, n_exempted=n_exempted, n_failed=n_failed,
                                       blocked_reasons=blocked_reasons, top_diffs=_top_diffs)
        L.append("")
        L.append(f"**一句话结论**：{_one}")
    if not verified:
        L.append("")
        L.append("**证据链核验问题**：")
        for p in problems:
            L.append(f"- {esc(p)}")
    L.append("")

    # 1 Run 信息
    L.append("## 1. Run 信息（run-manifest.json 回填）")
    L.append("")
    L.append("| 项 | 值 |")
    L.append("|---|---|")
    L.append(f"| 契约 | {esc(contract_path)} |")
    L.append(f"| 执行者 / 时间 | {esc(manifest.get('actor'))} / {esc(manifest.get('created_at'))} |")
    L.append(f"| 版本三元组（source/target/flow） | {esc(versions.get('source'))} / {esc(versions.get('target'))} / {esc(versions.get('flow'))} |")
    if versions.get("source") in (None, "") :
        L.append("| 版本绑定 | ⚠ 未绑定（正式 PASS 无效——conclude 已诚实记录 unrecorded） |")
    L.append(f"| git rev / 配置快照 | {esc(manifest.get('git_rev'))} / {esc((cfg_snap.get('hash') or cfg_snap.get('sha') or ''))} |")
    L.append(f"| 测试数据指纹 | {esc(manifest.get('test_data_fingerprint'))} |")
    L.append(f"| 比较器 | {esc(manifest.get('comparator_version'))} |")
    L.append(f"| 证据路径 | {esc('; '.join(map(str, manifest.get('evidence_paths') or [])))} |")
    L.append("")

    # 2 结论速览（v1.3.6 P1：数值一律取自 conclude_core 重算结果，不读 summary 统计）
    L.append("## 2. 结论速览")
    L.append("")
    L.append(f"- conclusion: **{concl_field}**；P0={p0_count} P1={p1_count}；"
             f"必测用例 {req_done}/{req_total}")
    L.append(f"- 语义差异（未豁免）: {n_semantic}；豁免: {n_exempted}；失败用例: {n_failed}")
    # v1.4.0：FAIL 时先给人话差异摘要（最多 3 条，全量明细见 §4）——人先看懂"差在哪"
    if concl == "FAIL" and _fr is not None and _top_diffs:
        L.append("")
        L.append("**差异在哪（最多 3 条人话摘要，全量见 §4）**：")
        for d in _top_diffs[:3]:
            if isinstance(d, dict):
                L.append(f"- {_fr.diff_digest(d)}")
    # 1.3.0（P1）引入分支范围限定；1.3.1（P2）收紧：reverse>0 且正向全 PASS 时顶层
    # conclusion=BLOCKED + forward_conclusion=PASS（信息性）——报告必须如实呈现两者，
    # 防止只读顶层 conclusion 的下游把本 run 误读为全量成功
    if bs and bs.get("conclusion_scope") == "forward_branches_only":
        L.append("")
        if fwd == "PASS":
            L.append(f"> ⚠️ **分支范围限定（不构成全量 PASS）**：取证源共 {bs.get('total_in_source')} 支——"
                     f"正向 {bs.get('formal_cases')} 支已正式执行且全部通过（forward_conclusion=PASS，"
                     f"信息性字段，非正式三态结论）；反向 {bs.get('reverse_explore')} 支仅探索演练未正式验证。"
                     f"正式三态结论为 **{concl}**；反向分支正式结论须另立正式契约并单独 run 绑定。")
        else:
            L.append(f"> ⚠️ **分支范围限定**：取证源共 {bs.get('total_in_source')} 支——"
                     f"正向 {bs.get('formal_cases')} 支已正式执行；"
                     f"反向 {bs.get('reverse_explore')} 支仅探索演练未正式验证。"
                     f"反向分支正式结论须另立正式契约并单独 run 绑定。")
    elif bs and bs.get("conclusion_scope") == "full":
        L.append(f"- 分支范围: 全部 {bs.get('total_in_source')} 支均有正式执行路径（formal_complete=true）")
    # v1.5.0：覆盖账本摘要（任务完成门①——来源→契约→维度→通道→状态）
    cov = ev.get("coverage_info") if ev is not None else None
    if cov is not None and cov.get("declared") is False:
        # v1.6.0 P0-1：两类 PASS 语义——未声明账本 = 已声明契约范围（不构成全流程）
        if concl == "PASS":
            L.append(f"- 覆盖范围: ⚠ **contract_scope_only**（未声明覆盖账本）——本 PASS 为"
                     f"**已声明契约范围**，不构成全流程双端 PASS；scaffold 覆盖账本并全闭环后"
                     f"方可升级为全流程口径")
        else:
            L.append(f"- 覆盖范围: contract_scope_only（未声明覆盖账本）")
    elif cov is not None and not cov.get("error"):
        L.append(f"- 覆盖账本: 要素 {cov.get('total')}（must-cover {cov.get('must_cover')}）｜"
                 f"covered {cov.get('covered')}｜expected_gap {cov.get('expected_gap')}｜"
                 f"ready_for_browser {cov.get('ready_for_browser_run')}｜uncovered {cov.get('uncovered')}｜"
                 f"n/a {cov.get('not_applicable')}　→ **{cov.get('conclusion_scope')}**")
    elif cov is not None and cov.get("error"):
        L.append(f"- 覆盖账本: ⚠ {cov.get('error')}（门禁 fail-closed）")
    if cov is not None and cov.get("declared") and not cov.get("error") and cov.get("blocking_ids"):
        L.append("")
        L.append(f"> ⚠️ **覆盖未闭环（不构成全流程双端 PASS）**：{len(cov['blocking_ids'])} 项必cover 要素未 covered"
                 f"（{cov.get('blocking_by_status', {})}）——取证源未全量进契约；"
                 f"逐项补齐覆盖账本（covered/expected_gap/not_applicable）后新 run-id 重跑。")
    L.append("")

    # 3 用例结果总表
    L.append("## 3. 用例结果总表")
    L.append("")
    if cases:
        _badge = {"PASS": "✅", "FAIL": "❌", "BLOCKED": "⛔", "ERROR": "⛔", "PENDING": "⏳", "SKIPPED": "⏭"}
        L.append("| 用例 | required | 状态 | 原因 |")
        L.append("|---|---|---|---|")
        for c in cases:
            _st = str(c.get("status") or "")
            L.append(f"| {esc(c.get('id'))} | {'★' if c.get('required') else ''} "
                     f"| {_badge.get(_st, '')} {esc(_st)} | {esc(c.get('reason'))} |")
    else:
        L.append("（case-results.json 缺失或为空）")
    L.append("")

    # 4 语义对拍明细（全部 field-compare 汇总）
    L.append("## 4. 语义对拍明细（field-level-compare）")
    L.append("")
    if fcs:
        for name, fc in fcs:
            st = fc.get("stats") or {}
            L.append(f"### {name}　status={esc(fc.get('status'))}　"
                     f"一致 {st.get('match', 0)} / 差异 {st.get('diff', 0)} / 豁免 {st.get('exempted', 0)}"
                     f" / OBSERVE {st.get('observe', 0)} / 覆盖阻断 {st.get('coverage_blockers', 0)}")
            L.append("")
            blocked = fc.get("blocked_reasons") or fc.get("blocked") or []
            if blocked:
                L.append("**BLOCKED 原因（证据不足，禁止下结论）**：")
                L.append("")
                for b in blocked:
                    L.append(f"- {esc(b)}")
                L.append("")
            diffs = fc.get("diffs") or []
            if diffs:
                if _fr is not None:
                    # v1.4.0：按用例分组 + 维度中文化 + 原因人话化（机器原文仍在 field-compare.json）
                    _by_case = _fr.group_by_case(diffs)
                    L.append(f"共 **{len(diffs)}** 处不一致，分布在 **{len(_by_case)}** 个用例"
                             f"（按用例分组；机器原文见 field-compare.json）：")
                    L.append("")
                    for _case_name, _items in _by_case.items():
                        L.append(f"#### 用例 {_case_name}（{len(_items)} 处）")
                        L.append("")
                        L.append("| 维度 | 位置 | 老系统 | 新系统 | 说明 |")
                        L.append("|---|---|---|---|---|")
                        for d in _items:
                            L.append(f"| {esc(_dim_cn(d.get('dim')))} | {esc(_where_of(d.get('key')))} "
                                     f"| {esc(_val(d.get('legacy')))} | {esc(_val(d.get('current')))} "
                                     f"| {esc(_human_reason(d.get('dim'), d.get('reason')))} |")
                        L.append("")
                else:
                    L.append("| 维度 | 键 | legacy | current | 原因 |")
                    L.append("|---|---|---|---|---|")
                    for d in diffs:
                        L.append(f"| {esc(d.get('dim'))} | {esc(d.get('key'))} | {esc(d.get('legacy'))} "
                                 f"| {esc(d.get('current'))} | {esc(d.get('reason'))} |")
                    L.append("")
            ex = fc.get("exempted") or []
            if ex:
                L.append("**豁免差异**（有审批记录，不进结论）：")
                L.append("")
                if _fr is not None:
                    L.append("| 维度 | 位置 | 老系统 | 新系统 | 说明 | 豁免编号 |")
                    L.append("|---|---|---|---|---|---|")
                    for d in ex:
                        L.append(f"| {esc(_dim_cn(d.get('dim')))} | {esc(_where_of(d.get('key')))} "
                                 f"| {esc(_val(d.get('legacy')))} | {esc(_val(d.get('current')))} "
                                 f"| {esc(_human_reason(d.get('dim'), d.get('reason')))} | {esc(d.get('exempted_by'))} |")
                else:
                    L.append("| 键 | 原因 |")
                    L.append("|---|---|")
                    for d in ex:
                        L.append(f"| {esc(d.get('key'))} | {esc(d.get('reason'))} |")
                L.append("")
            ob = fc.get("observe") or []
            if ob:
                L.append("**OBSERVE（观察项，不进结论）**：")
                L.append("")
                for d in ob:
                    L.append(f"- {esc(d.get('key'))}——{esc(d.get('note'))}")
                L.append("")
    else:
        L.append("（无 field-compare 产物——runner BLOCKED 或未达对拍阶段，见 §6 阻塞原因）")
        L.append("")

    # 5 Gate 明细
    L.append("## 5. Gate 明细（健康检查 + 契约声明门禁）")
    L.append("")
    if gates:
        L.append("| Gate | 级别 | 结果 | 说明 |")
        L.append("|---|---|---|---|")
        for g in gates:
            L.append(f"| {esc(g.get('id'))} | {esc(g.get('severity'))} "
                     f"| {'✓' if g.get('passed') else '✗'} | {esc(g.get('note'))} |")
    else:
        L.append("（gates.json 缺失）")
    L.append("")

    # 6 阻塞原因汇总
    brs = blocked_reasons
    L.append("## 6. 阻塞原因汇总（BLOCKED/FAIL 归因）")
    L.append("")
    if brs:
        for b in brs:
            L.append(f"- {esc(b)}")
    elif concl == "PASS":
        L.append("无（全部必测 PASS 且无未豁免语义差异）")
    else:
        L.append("见 §3 用例原因列")
    L.append("")

    # 7 辅助证据声明
    L.append("## 7. 辅助证据（不构成结论）")
    L.append("")
    L.append(f"- 像素 diff: {esc((summary.get('aux_evidence') or {}).get('pixel_diff', 'auxiliary only（永不进结论）'))}")
    shots = sorted(run_dir.glob("screenshots/*/*.png"))
    if shots:
        L.append(f"- 环节截图: {len(shots)} 张（screenshots/{shots[0].parent.name}/…，表单态+提交后态逐环节）")
    else:
        L.append("- 环节截图: 无（api 通道或未开启 browser.screenshots）")
    L.append("")

    # 8 人工发现（独立文件，机器不覆盖——v1.3.4 P1）
    L.append("## 8. 产品级发现与跟进（人工记录）")
    L.append("")
    L.append(f"> 按 lessons-learned L22/L23：对拍之外顺带发现的产品缺陷单独编号（D-xx P级/O-xx 观察），")
    L.append(f"> 环境级阻塞与产品缺陷分开表述。人工内容已拆至独立文件，重生成机器报告不会覆盖：")
    L.append(f"> **[{HUMAN_FINDINGS_NAME}]({HUMAN_FINDINGS_NAME})**（首次生成时自动创建模板，只由执行者维护）。")
    L.append("")
    try:
        human_text = human_findings.read_text(encoding="utf-8")
        def _is_header_or_sep(ln: str) -> bool:
            # 审计第 2 轮 F3：只精确跳表头（首单元格=="编号"）与分隔行——
            # 此前全文子串"编号"匹配会把正文含"编号"二字的合法人工行静默丢弃
            cells = [c.strip() for c in ln.strip().strip("|").split("|")]
            return bool(cells) and (cells[0] == "编号" or set("".join(cells)) <= set("-: "))
        human_rows = [ln for ln in human_text.splitlines()
                      if ln.strip().startswith("|") and "示例" not in ln
                      and not _is_header_or_sep(ln)]
        if human_rows:
            L.append("| 编号 | 级别 | 现象 | 根因/建议 | 状态 |")
            L.append("|---|---|---|---|---|")
            L.extend(human_rows)
        else:
            L.append(f"（暂无人工记录——在 {HUMAN_FINDINGS_NAME} 中补记）")
    except Exception:
        L.append(f"（{HUMAN_FINDINGS_NAME} 不可读）")
    L.append("")

    # 9 复跑指引
    L.append("## 9. 复跑指引")
    L.append("")
    L.append("```bash")
    L.append("# 账本/结论不可覆盖——重跑必须新 run-id（skill 守护规则 3）")
    L.append(f"bash ~/.agents/skills/flow-test-contract/scripts/pipeline.sh \\")
    L.append(f"  --contract <契约路径> \\")
    L.append(f"  --scenario-dir <生成件/flowtrace-scenarios> \\")
    L.append(f"  --rules <生成件/compare-rules.json>   # 可选 --cases C-01 / --drill / --gate-evidence <file>")
    L.append("```")
    L.append("")

    tmp = out.with_name(out.name + ".tmp")
    tmp.write_text("\n".join(L), encoding="utf-8")
    tmp.replace(out)
    if verified:
        print(f"✅ 最终报告（证据链已核验）→ {out}")
    else:
        print(f"⚠ 草稿报告（未核验，不得作为正式结论）→ {out}")
    print(f"   人工发现文件（机器不覆盖）→ {human_findings}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
