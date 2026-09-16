#!/usr/bin/env python3
"""run_evidence.py —— run 证据链共享核验模块（1.3.1 P0；1.3.4 P0 全量结论复算）。

此前豁免取证链核验存在两份实现：生成器 exempt 子命令的 _verify_run_dir（全链）与
validate-contract 的 verify_exemption_provenance（简化版：只看目录存在 + fc 现算 sha +
summary 自述结论）。简化版放过"自制 manifest/summary + 手算 sha + 凭空 match"的伪造
八字段豁免——两个自制 JSON 即可通过契约门。现抽取为唯一共享实现：生成器（exempt）、
validator（契约入口）共用，杜绝双实现漂移。

verify_run_dir 五件齐全 + 九重核验（任一不过 → RunEvidenceError，fail-closed）：
  ① 五件证据存在且为实体文件（拒符号链接）：run-manifest.json / summary.json /
     field-compare.json / gates.json / case-results.json（与 conclude 必要证据同口径——
     缺 run-manifest/手写 summary 的"最小伪造 run"在此拒绝）；
  ② 全部可解析（JSON）且容器类型正确；
  ③ run-id 三方一致：manifest.run_id == summary.run_id ∈ {目录名, 去 run- 前缀}；
  ④ **全部 config_snapshot 条目**账本 sha256_16 现算一致（不止五件；契约/规则/场景等登记项
     一并复算——账本登记什么就核验什么），且五件核心证据必须以本 run 目录内路径登记
     （拒诱饵/异地证据）；
  ⑤ **契约快照保护**（1.3.4 P0）：账本登记 contract 条目时，契约文件必须存在且 sha 复算
     一致——契约被删除/被改写后，该 run 的差异不再可作豁免依据；
  ⑥ 账本 toolchain 指纹完整（skill_version + manifest_sha256，非 unrecorded/None——
     无法复现的 run 不得据以豁免）；
  ⑦ **结论全量复算**（1.3.4 P0，核心）：调用与 conclude.py 同一纯评估器
     `conclude_core.evaluate` 重算结论，并与 summary.conclusion 严格比对——
     历史 BLOCKED run 被手工改写为 FAIL 继续充当豁免依据的路径在此封死；
  ⑧ 复算结论 ∈ {PASS, FAIL}（BLOCKED/DRILL 未过完整门禁，不可作豁免依据）；
  ⑨ 底层证据一致性冗余检查（gates/case-results/fc 自洽——诊断信息更明确）。

exemption_binding_problems：豁免 scope/match 必须绑定源 run field-compare.diffs 的真实
条目（scope==dim 或 '*'，match 经与比较器一致的"剥一次前缀"稳定键命中 diff key）——
凭空捏造的精确 match 在此拒绝；OK run（diffs 空）无可绑定差异，任何豁免都非法。

消费方：
  scripts/gen-multibranch-contract.py（exempt 子命令，生成器入口）
  templates/validate-contract.py（契约入口，经 _load_run_evidence 动态加载）
（pipeline 经 validate-contract 间接共用；不得在任何消费方另写简化版核验。）
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path

EVIDENCE_FILES = ("run-manifest.json", "summary.json", "field-compare.json",
                  "gates.json", "case-results.json")
# v1.3.6 P1：豁免来源必须是**契约模式 run**——账本固定最小键集合缺一即拒（此前只校验存在的
# contract 条目，删掉 config_snapshot.contract / evidence_paths 的手改 manifest 仍被接受）。
MIN_CONTRACT_SNAPSHOT_KEYS = ("contract", "rules", "scenarios")


class RunEvidenceError(Exception):
    """run 证据链核验失败（消息可直接呈现给操作者）。"""


def _reject(msg: str):
    raise RunEvidenceError(msg)


def _load_conclude_core():
    """加载纯评估器 conclude_core（与 conclude.py 共享；禁写字节码——skill 目录零副作用）。"""
    here = Path(__file__).resolve().parent
    for cand in (here / "conclude_core.py",
                 here.parent / "scripts" / "conclude_core.py",
                 here.parent.parent / ".flow-test-contract" / "scripts" / "conclude_core.py"):
        if cand.is_file():
            old = sys.dont_write_bytecode
            sys.dont_write_bytecode = True
            try:
                spec = importlib.util.spec_from_file_location("ftc_conclude_core", cand)
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                return mod
            finally:
                sys.dont_write_bytecode = old
    return None



def verify_run_dir(run_dir: Path) -> dict:
    """核验 run 目录证据链（唯一实现；生成器与 validator 共用）。
    ⊢⑨ 重结论全量复算 + 契约快照保护。
    返回 {"run_dir", "manifest", "summary", "fc", "fc_path", "fc_sha16", "gates", "cases"}。"""
    run_dir = Path(run_dir)
    if not run_dir.is_dir():
        _reject(f"run 目录不存在: {run_dir}（豁免必须绑定真实 run，禁止手写证据）")
    paths = {name: run_dir / name for name in EVIDENCE_FILES}
    for name, p in paths.items():
        if p.is_symlink():
            _reject(f"run 证据为符号链接: {name}（证据必须是 run 目录内实体文件，拒绝外链）")
        if not p.is_file():
            _reject(f"run 证据缺失: {name}（账本/结论/对拍/门禁/用例五件齐全才可据以豁免）")
    data = {}
    for name, p in paths.items():
        try:
            data[name] = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            _reject(f"run 证据不可解析（损坏/非 JSON）: {name}: {type(e).__name__}: {e}")
    mf = data["run-manifest.json"]; sm = data["summary.json"]; fc = data["field-compare.json"]
    gates = data["gates.json"]; cases = data["case-results.json"]
    if not all(isinstance(x, dict) for x in (mf, sm, fc)):
        _reject("run 证据结构非法（run-manifest/summary/field-compare 必须为 JSON 对象）")
    if not isinstance(gates, list) or not isinstance(cases, list):
        _reject("run 证据结构非法（gates/case-results 必须为 JSON 列表）")

    # ③ run-id 三方一致（目录名 / manifest / summary）
    rid_dir = run_dir.name
    rid_bare = rid_dir[4:] if rid_dir.startswith("run-") else rid_dir
    rid_mf, rid_sm = str(mf.get("run_id") or ""), str(sm.get("run_id") or "")
    if not rid_mf or rid_mf != rid_sm or rid_mf not in (rid_dir, rid_bare):
        _reject(f"run-id 错配: 目录={rid_dir} 账本={rid_mf!r} 结论={rid_sm!r}（证据不属于同一 run）")

    # ④ 账本登记 + sha 现算一致（config_snapshot 全部条目，不止三件核心证据）
    snap = mf.get("config_snapshot") if isinstance(mf.get("config_snapshot"), dict) else {}
    key_by_file = {"gates.json": "gates", "case-results.json": "case_results",
                   "field-compare.json": "field_compare"}
    for fname, key in key_by_file.items():
        p = paths[fname]
        ent = snap.get(key)
        if not isinstance(ent, dict):
            _reject(f"{fname} 未登记进账本 config_snapshot——证据必须全部入账")
        declared_path = str(ent.get("abs_path") or ent.get("path") or "")
        if not declared_path or Path(declared_path).resolve() != p.resolve():
            _reject(f"{fname} 账本登记路径不是本 run 内实体文件——拒绝诱饵/异地证据")
        actual = hashlib.sha256(p.read_bytes()).hexdigest()[:16]
        if str(ent.get("sha256_16") or "") != actual:
            _reject(f"{fname} 与账本登记 sha 不一致（现算={actual} 账本={ent.get('sha256_16')}）")
    # ④a 契约模式账本最小键集合（v1.3.6 P1）：只校验"存在的 contract 条目"不足以防手改
    # manifest 删除契约/规则/场景登记——缺一即拒，保证豁免来源确实是一次契约模式 run。
    missing_keys = [k for k in MIN_CONTRACT_SNAPSHOT_KEYS if not isinstance(snap.get(k), dict)]
    if missing_keys:
        _reject(f"账本缺契约模式登记键 {missing_keys}——豁免来源必须是契约模式 run"
                f"（config_snapshot 须含 contract/rules/scenarios 登记；只改 manifest 删除登记不可接受）")
    epaths = mf.get("evidence_paths")
    if not isinstance(epaths, list) or not epaths \
            or any(not isinstance(x, str) or not x.strip() for x in epaths):
        _reject("账本 evidence_paths 缺失/为空/含非法条目——豁免来源必须是契约模式 run（证据可追溯）")

    # ⑤ 契约快照保护（1.3.4 P0）：契约文件必须在 snapshot 登记位置存在且 SHA 一致
    contract_ent = snap.get("contract") if isinstance(snap.get("contract"), dict) else None
    if contract_ent:
        cp = Path(str(contract_ent.get("abs_path") or contract_ent.get("path") or ""))
        if not cp.is_file():
            _reject("契约快照文件已不存在——证据链断裂（契约被删除后差异不可再作豁免依据）")
        decl_sha = str(contract_ent.get("sha256_16") or "")
        if decl_sha and hashlib.sha256(cp.read_bytes()).hexdigest()[:16] != decl_sha:
            _reject("契约快照 SHA 不符——契约已被修改，该 run 独有的差异不再可作豁免依据")

    fc_p = paths["field-compare.json"]
    fc_sha = hashlib.sha256(fc_p.read_bytes()).hexdigest()[:16]

    # ⑥ toolchain 指纹（可复现性；v1.3.6：manifest_sha256 须为真实 SHA256 格式，非仅非空）
    tc = mf.get("toolchain")
    if not isinstance(tc, dict) or not str(tc.get("skill_version") or "").strip() \
            or str(tc.get("skill_version")).strip() in ("unrecorded", "None") \
            or not str(tc.get("manifest_sha256") or "").strip():
        _reject("账本 toolchain 指纹缺失/不完整（需 skill_version + manifest_sha256，1.1.0 起强制）"
                "——无法复现的 run 不得据以批量豁免")
    if not re.fullmatch(r"[0-9a-f]{64}", str(tc.get("manifest_sha256") or "").strip()):
        _reject("账本 toolchain.manifest_sha256 非 64 位十六进制 SHA256——仅'非空'不足以防伪造指纹")

    # ⑦ 结论全量复算（1.3.4 P0）：调用与 conclude.py 同一纯评估器
    cc = _load_conclude_core()
    if cc is None:
        _reject("找不到共享评估器 conclude_core.py——无法执行结论复算")

    # 用账本登记的契约路径做交叉核对（快照 SHA 已验或不存在；不存在时传 None 不影响复算）
    cs_contract = snap.get("contract") if isinstance(snap.get("contract"), dict) else None
    contract_path_for_recomp = None
    if cs_contract:
        _cp = Path(str(cs_contract.get("abs_path") or cs_contract.get("path") or ""))
        if _cp.is_file():
            contract_path_for_recomp = str(_cp)
    ev = cc.evaluate(run_dir, contract_path_for_recomp, allowed_run_ids={rid_dir, rid_bare})

    # ⑧ 复算结论只能是 PASS/FAIL（BLOCKED/DRILL 未过完整门禁）
    recomp_concl = ev["conclusion"]
    if recomp_concl not in ("PASS", "FAIL"):
        _reject(f"底层证据重算不一致: 结论全量复算={recomp_concl}——仅 PASS/FAIL 的 run 差异可据以豁免"
                f"（BLOCKED/DRILL 未过完整门禁）；重算原因: {'; '.join(ev['reasons'][:5])}")

    # 复算与 summary 比对（历史 BLOCKED 被改 FAIL，复算会重新判 BLOCKED，此处拦截）
    recorded_concl = str(sm.get("conclusion") or "")
    if recomp_concl != recorded_concl:
        _reject(f"底层证据重算不一致: 结论复算={recomp_concl} ≠ summary={recorded_concl}"
                f"——仅 PASS/FAIL 的 run 差异可据以豁免（summary 与底层证据矛盾——手写/篡改的结论不可据以豁免）")

    # ⑦（冗余）底层证据轻量一致性：与复算不重复但提供更明确的拒绝理由
    if not gates:
        _reject("底层证据重算不一致: gates.json 为空（真实 run 的 gate 记录不可能为空）")
    bad_gates = [str(g.get("id") or "?") for g in gates
                 if not isinstance(g, dict) or (g.get("passed") is not True and not g.get("synthetic"))]
    if bad_gates:
        _reject(f"底层证据重算不一致: gates 存在未过/非法条目 {bad_gates[:5]}"
                f"——summary 结论={recorded_concl} 与底层证据矛盾（conclude 对未过 gate 一律 BLOCKED）")
    if not cases:
        _reject("底层证据重算不一致: case-results.json 为空（真实 run 必有用例结果）")
    seen_ids: set = set()
    for c in cases:
        if not isinstance(c, dict) or not isinstance(c.get("id"), str) or not c.get("id") \
                or c.get("id") in seen_ids:
            _reject("底层证据重算不一致: case-results 存在缺失/重复/非字符串 id 的条目")
        seen_ids.add(c["id"])
        required = c.get("required", True)
        if required and c.get("status") != "PASS":
            _reject(f"底层证据重算不一致: 必测用例 {c.get('id')} 状态={c.get('status')!r}"
                    f"——summary 结论={recorded_concl} 与底层证据矛盾（conclude 对必测非 PASS 一律 BLOCKED）")
    st = fc.get("status")
    diffs = fc.get("diffs") if isinstance(fc.get("diffs"), list) else None
    if st not in ("OK", "FAIL"):
        _reject(f"底层证据重算不一致: field-compare.status={st!r} 非法（只认 OK/FAIL）")
    if st == "OK" and diffs:
        _reject("底层证据重算不一致: field-compare.status=OK 却存在 diffs（证据自相矛盾）")
    if st == "FAIL" and not diffs:
        _reject("底层证据重算不一致: field-compare.status=FAIL 却无差异明细（证据自相矛盾）")

    return {"run_dir": run_dir, "manifest": mf, "summary": sm, "fc": fc,
            "fc_path": fc_p, "fc_sha16": fc_sha, "gates": gates, "cases": cases}


def diff_key_candidates(key: str) -> set:
    """与 field-level-compare.is_exempt 同口径的稳定键候选：完整 key / 剥一次前缀
   （':' 优先，否则首个 '/'）。"""
    cands = {key}
    if ":" in key:
        cands.add(key.split(":", 1)[1])
    elif "/" in key:
        cands.add(key.split("/", 1)[1])
    return cands


def exemption_binding_problems(exemptions: list, fc: dict) -> list[str]:
    """豁免 scope/match 必须绑定源 run field-compare.diffs 的真实条目：
    scope==diff.dim（或 '*'）且 match 命中 diff key 的稳定键候选。返回问题清单（空=全部绑定）。"""
    diffs = fc.get("diffs") if isinstance(fc, dict) else None
    if not isinstance(diffs, list) or not diffs:
        return ["源 run field-compare 无可绑定 diffs 条目——豁免 scope/match 无从对应真实差异"
                "（合法豁免只能源自 FAIL run 真实发生过的差异）"]
    problems: list[str] = []
    diff_entries = [d for d in diffs if isinstance(d, dict)]
    for e in exemptions:
        if not isinstance(e, dict):
            continue
        eid = str(e.get("id") or "?")
        match, scope = str(e.get("match") or ""), str(e.get("scope") or "")
        bound = any((scope in ("*", str(d.get("dim") or "")))
                    and (match in diff_key_candidates(str(d.get("key") or "")))
                    for d in diff_entries)
        if not bound:
            problems.append(f"{eid}: scope={scope!r}/match={match!r} 不对应源 run "
                            f"field-compare.diffs 的任何真实条目（豁免只能豁免真实发生过的差异）")
    return problems
