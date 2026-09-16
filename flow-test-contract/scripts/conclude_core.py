#!/usr/bin/env python3
"""conclude_core.py —— 结论纯评估器（v1.3.4 P0，conclude.py + run_evidence.py 共享）。

conclude.py 与 run_evidence.py 共用此评估器计算结论；且 run_evidence 据此比对
summary.json 记录的一致性。纯函数，不写任何文件。

evaluate(report_dir, contract_path) → dict:
  conclusion / reasons / p0_count / p1_count / semantic_diffs / exempted_diffs /
  failed_cases / blocked_reasons / conclusion_scope / forward_conclusion /
  ledger_binding / result_ids / snap_verified / manifest / diff_list / exempted /
  gates / cases / bc_info / coverage_info / contract_sha_match / contract_exists /
  required_total / required_done
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

REQUIRED_EVIDENCE = ["run-manifest.json", "gates.json", "field-compare.json", "case-results.json"]
VALID_CASE_STATUS = {"PASS", "FAIL", "BLOCKED", "SKIP", "ERROR"}
VALID_FC_STATUS = {"OK", "FAIL", "BLOCKED"}
MUST_REGISTER_FILES = {"gates": "gates.json", "case_results": "case-results.json", "field_compare": "field-compare.json"}
MUST_REGISTER = {"gates", "case_results", "field_compare"}


def entry_hash(f: Path) -> str:
    """与 write-manifest.hash_entry 同算法：文件 sha256[:16]；目录按 (相对路径+内容) 串联。"""
    if f.is_dir():
        h = hashlib.sha256()
        for x in sorted(f.rglob("*")):
            if x.is_file():
                h.update(str(x.relative_to(f)).encode())
                h.update(x.read_bytes())
        return h.hexdigest()[:16]
    return hashlib.sha256(f.read_bytes()).hexdigest()[:16]


def _load_json(p: Path) -> tuple:
    try:
        return json.loads(p.read_text(encoding="utf-8")), None
    except FileNotFoundError:
        return None, "缺失"
    except Exception as e:
        return None, f"损坏: {e}"


def load_contract_cases(contract_path: Path | str | None) -> dict | None:
    """读取契约 {id: required}；任何解析失败（含重复 YAML 键——防 required/状态双写夹带）
    返回 None（fail-closed）。"""
    if not contract_path:
        return None
    cp = Path(contract_path)
    if not cp.is_file():
        return None
    try:
        import yaml

        class _L(yaml.SafeLoader):
            pass

        def _no_dup(loader, node, deep=False):
            mapping = {}
            for k_node, v_node in node.value:
                key = loader.construct_object(k_node, deep=deep)
                if key in mapping:
                    raise yaml.YAMLError(f"重复 YAML 键: {key!r}")
                mapping[key] = loader.construct_object(v_node, deep=deep)
            return mapping

        _L.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dup)
        c = yaml.load(cp.read_text(encoding="utf-8"), Loader=_L)
        cases = (c or {}).get("cases")
        if not isinstance(cases, list):
            return None
        out = {str(x["id"]): bool(x.get("required", True))
               for x in cases if isinstance(x, dict) and x.get("id")}
        return out if out else None
    except Exception:
        return None


def load_contract_full(contract_path: Path | str | None):
    """读取完整契约 dict（覆盖深度绑定用）；失败返回 None。"""
    if not contract_path:
        return None
    cp = Path(contract_path)
    if not cp.is_file():
        return None
    try:
        import yaml
        c = yaml.safe_load(cp.read_text(encoding="utf-8")) or {}
        return c if isinstance(c, dict) else None
    except Exception:
        return None


def load_coverage_manifest_with_path(contract_path: Path | str | None):
    """同 load_coverage_manifest，另返回账本解析路径（v1.7.4：库存相对路径基准与 validator 一致）。"""
    r = load_coverage_manifest(contract_path)
    resolved = None
    if contract_path and r not in (None, "declared_missing"):
        try:
            import yaml as _y
            c = _y.safe_load(Path(contract_path).read_text(encoding="utf-8")) or {}
            cm = (c.get("meta") or {}).get("coverage_manifest")
            p = cm.get("path") if isinstance(cm, dict) else cm
            if isinstance(p, str) and p.strip():
                _here = Path(__file__).resolve().parent
                if str(_here) not in __import__("sys").path:
                    __import__("sys").path.insert(0, str(_here))
                import coverage_manifest as _cm
                resolved = _cm.resolve_path(Path(contract_path), p)
        except Exception:
            resolved = None
    return r, resolved


def load_branch_coverage(contract_path: Path | str | None) -> dict | None | str:
    """读取契约 meta.branch_coverage；失败返回 'unreadable'。"""
    if not contract_path:
        return None
    cp = Path(contract_path)
    if not cp.is_file():
        return None
    try:
        import yaml
        c = yaml.safe_load(cp.read_text(encoding="utf-8")) or {}
        bc = (c.get("meta") or {}).get("branch_coverage")
        return bc if isinstance(bc, dict) else None
    except Exception:
        return "unreadable"


def load_coverage_manifest(contract_path: Path | str | None):
    """读取契约 meta.coverage_manifest 声明的覆盖账本（v1.5.0 任务完成门①）。

    返回：None=契约未声明（门禁关闭，向后兼容）；"declared_missing"=声明了但文件缺失/
    不可读（fail-closed）；dict=合法加载的账本（结构校验由 coverage_manifest.validate）。"""
    if not contract_path:
        return None
    cp = Path(contract_path)
    if not cp.is_file():
        return None
    try:
        import yaml
        c = yaml.safe_load(cp.read_text(encoding="utf-8")) or {}
        cm = (c.get("meta") or {}).get("coverage_manifest")
    except Exception:
        return "declared_missing"
    if cm is None:
        return None
    p = cm.get("path") if isinstance(cm, dict) else cm
    if not isinstance(p, str) or not p.strip():
        return "declared_missing"
    try:
        _here = Path(__file__).resolve().parent
        if str(_here) not in __import__("sys").path:
            __import__("sys").path.insert(0, str(_here))
        import coverage_manifest as _cm
    except Exception:
        return "declared_missing"  # 账本库不可用=门禁不可用=fail-closed
    # 审计第 8 轮 P1-1：相对路径按契约所在目录解析（与 validator/draft 一致，禁止按 CWD）
    m, err = _cm.load_manifest_for_contract(cp, p)
    if err:
        return "declared_missing"
    return m


def evaluate(report_dir: Path, contract_path: Path | str | None = None,
             allowed_run_ids: set | None = None) -> dict:
    """纯评估器：不写任何文件，返回评估结果 dict 供调用方决策。

    allowed_run_ids：可接受的 manifest.run_id 集合（缺省 {目录名}）。run_evidence 复算
    历史 run 时目录名可能带 `run-` 前缀而账本记录去前缀值，此参数用于放宽该等价形态
    （三方一致性已由 run_evidence 自行核验）。

    返回 key 列表见模块 docstring。"""
    d = Path(report_dir)
    accepted_rids = allowed_run_ids if allowed_run_ids else {d.name}
    reasons: list[str] = []
    p0 = p1 = 0
    bc_info: dict | None = None
    conclusion_scope = None
    forward_conclusion = None

    data = {}
    for name in REQUIRED_EVIDENCE:
        obj, why = _load_json(d / name)
        if why:
            reasons.append(f"必要证据{why}: {name}")
        elif obj in ([], {}, None):
            reasons.append(f"必要证据为空: {name}")
        data[name] = obj

    manifest_in = data.get("run-manifest.json")
    manifest = manifest_in if isinstance(manifest_in, dict) else {}
    gates = data.get("gates.json")
    fc = data.get("field-compare.json")
    fc = fc if isinstance(fc, dict) else {}
    cases = data.get("case-results.json")

    # run-id 一致性（缺失/错配）
    ledger_binding = (isinstance(manifest.get("run_id"), str) and bool(manifest["run_id"])
                      and manifest["run_id"] in accepted_rids)
    if not manifest.get("run_id"):
        reasons.append("run-manifest.json 缺 run_id（账本不完整）")
    elif manifest["run_id"] not in accepted_rids:
        reasons.append(f"run-id 错配: manifest={manifest.get('run_id')} vs 目录={d.name}")

    # 账本防篡改：复算 config_snapshot 全部条目（与 run_evidence 一致：abs_path 优先，fallback path）
    snap = manifest.get("config_snapshot")
    snap_verified: set[str] = set()
    if isinstance(snap, dict) and snap:
        for key, ent in snap.items():
            if (not isinstance(ent, dict) or not ent.get("sha256_16")
                    or not isinstance(ent.get("sha256_16"), str)):
                reasons.append(f"账本登记不完整: {key}（缺 sha256_16 或非字符串）")
                continue
            declared_path = str(ent.get("abs_path") or ent.get("path") or "")
            if not declared_path:
                reasons.append(f"账本登记不完整: {key}（缺 abs_path/path）")
                continue
            f = Path(declared_path)
            if not f.exists():
                reasons.append(f"账本登记文件丢失: {key}={ent.get('path', declared_path)}")
            else:
                try:
                    h = entry_hash(f)
                except Exception as e:
                    reasons.append(f"账本登记文件不可读: {key}（{type(e).__name__}: {e}）")
                    continue
                if h != ent["sha256_16"]:
                    reasons.append(f"账本登记文件 hash 不符（证据被改动）: {key}={ent.get('path', declared_path)}")
                else:
                    snap_verified.add(key)
                    if key in MUST_REGISTER_FILES:
                        try:
                            same = f.resolve() == (d / MUST_REGISTER_FILES[key]).resolve()
                        except Exception:
                            same = False
                        if not same:
                            reasons.append(f"账本登记路径与报告证据不一致（诱饵路径）: {key} → {declared_path} ≠ {d / MUST_REGISTER_FILES[key]}")

    # 契约快照 SHA 复算状态（供 run_evidence 交叉核对；缺失/不符本身已由上方 snap 循环判 BLOCKED）
    contract_sha_match: bool | None = None
    contract_exists_cs: bool | None = None
    cs_contract = snap.get("contract") if isinstance(snap, dict) and isinstance(snap.get("contract"), dict) else None
    if cs_contract:
        cp = Path(str(cs_contract.get("abs_path") or cs_contract.get("path") or ""))
        contract_exists_cs = cp.is_file()
        if contract_exists_cs:
            try:
                contract_sha_match = (hashlib.sha256(cp.read_bytes()).hexdigest()[:16]
                                      == str(cs_contract.get("sha256_16") or ""))
            except Exception:
                contract_sha_match = False

    # v1.7.2 P0-1b：覆盖账本随 run 快照后，结论期复核其哈希——运行后修改账本在此现形
    # （账本文件由 pipeline 经 write-manifest --extra-file coverage_manifest=<path> 入账）
    _cm_snap = snap.get("coverage_manifest") if isinstance(snap, dict) else None
    if isinstance(_cm_snap, dict) and _cm_snap.get("sha256_16"):
        _cm_file = Path(str(_cm_snap.get("abs_path") or _cm_snap.get("path") or ""))
        if not _cm_file.is_file():
            reasons.append(f"覆盖账本丢失（运行后被删除）: {_cm_file}")
        else:
            try:
                _cm_hash = entry_hash(_cm_file)
                if _cm_hash != _cm_snap["sha256_16"]:
                    reasons.append(f"覆盖账本哈希与 run 快照不符（运行后被修改）: {_cm_file}")
            except Exception as e:
                reasons.append(f"覆盖账本不可读: {_cm_file}（{type(e).__name__}: {e}）")

    # evidence_paths 追溯
    epaths = manifest.get("evidence_paths") if isinstance(manifest, dict) else None
    if isinstance(epaths, list) and epaths:
        for ep in epaths:
            if not isinstance(ep, str) or not ep:
                reasons.append(f"账本 evidence_paths 含非字符串条目: {ep!r}")
                continue
            if not Path(ep).exists():
                reasons.append(f"账本 evidence_paths 指向不存在（证据目录断链）: {ep}")

    # gates 校验
    if not isinstance(gates, list):
        reasons.append("gates.json 非列表（证据损坏）")
    else:
        for g in gates:
            if not isinstance(g, dict):
                reasons.append(f"gates 存在非对象条目: {g!r}")
                continue
            if g.get("synthetic") is True:
                continue
            passed = g.get("passed")
            if not isinstance(passed, bool):
                reasons.append(f"gate {g.get('id')} passed 非布尔（{passed!r}）——缺证据/字符串伪装一律 BLOCKED")
            elif passed is False:
                note = str(g.get("note") or "").strip()
                suffix = f"——{note[:160]}" if note else ""
                reasons.append(f"gate 未过: {g.get('id')}({g.get('severity')}){suffix}")
                if g.get("severity") == "P0":
                    p0 += 1
                elif g.get("severity") == "P1":
                    p1 += 1

    # field-compare 校验
    diff_list: list[dict] = []
    exempted: list[dict] = []
    if not isinstance(fc, dict):
        reasons.append("field-compare.json 非对象（证据损坏）")
    else:
        st = fc.get("status")
        cov = fc.get("coverage")
        if cov is not None and not isinstance(cov, list):
            # coverage 为 dict/int 时 [:3] 切片会 TypeError → crash exit 1 被解读为 FAIL
            reasons.append("field-compare.coverage 非列表（证据损坏）")
            cov = []
        if not isinstance(st, str) or st not in VALID_FC_STATUS:
            reasons.append(f"语义对拍状态非法/缺失/非字符串: {st!r}（只认 OK/FAIL/BLOCKED）")
        elif st == "BLOCKED":
            reasons.append("语义对拍 BLOCKED: " + "; ".join(map(str, (cov or [])[:3])))
        raw_diffs = fc.get("diffs")
        raw_exempted = fc.get("exempted")
        if not isinstance(raw_diffs, list):
            reasons.append("field-compare.diffs 缺失或非列表（证据损坏）")
            raw_diffs = []
        if not isinstance(raw_exempted, list):
            reasons.append("field-compare.exempted 缺失或非列表（证据损坏）")
            raw_exempted = []
        if any(not isinstance(x, dict) for x in raw_diffs):
            reasons.append("field-compare.diffs 存在非对象条目（证据损坏）")
            raw_diffs = []
        if any(not isinstance(x, dict) for x in raw_exempted):
            reasons.append("field-compare.exempted 存在非对象条目（证据损坏）")
            raw_exempted = []
        diff_list, exempted = raw_diffs, raw_exempted
        if st == "FAIL" and not diff_list:
            reasons.append("对拍状态 FAIL 但无差异明细（证据自相矛盾）")
        observe = fc.get("observe")
        if observe is not None and not isinstance(observe, list):
            reasons.append("field-compare.observe 非列表（证据损坏）")
            observe = []
        if any(not isinstance(o, dict) for o in (observe or [])):
            reasons.append("field-compare.observe 存在非对象条目（证据损坏）")
            observe = [o for o in observe if isinstance(o, dict)]
        non_optional_observe = [o for o in (observe or []) if o.get("optional") is not True]
        for o in non_optional_observe[:5]:
            reasons.append(f"必测比较项仅 OBSERVE（未满足 合同+fixture+采集 三前提）: {o.get('key')}——{str(o.get('note', ''))[:80]}")
        if len(non_optional_observe) > 5:
            reasons.append(f"…另有 {len(non_optional_observe) - 5} 项非 optional OBSERVE")

    # cases 校验
    failed_cases: list[str] = []
    result_ids: set[str] = set()
    if not isinstance(cases, list):
        reasons.append("case-results.json 非列表（证据损坏）")
        cases = []
    else:
        for c in cases:
            if not isinstance(c, dict):
                reasons.append("case-results 存在非对象条目")
                continue
            cid, cst = c.get("id"), c.get("status")
            if not cid or not isinstance(cid, str):
                reasons.append(f"case-results 存在缺失/非字符串 id 的条目: {cid!r}")
                continue
            if cid in result_ids:
                reasons.append(f"用例 id 重复: {cid}（账目不可信）")
                continue
            result_ids.add(cid)
            if not isinstance(cst, str) or cst not in VALID_CASE_STATUS:
                reasons.append(f"用例 {cid} 状态非法/缺失/非字符串: {cst!r}——一律 BLOCKED")
            if cst == "FAIL":
                failed_cases.append(str(cid))
        required = [c for c in cases if isinstance(c, dict) and c.get("required", True)]
        if not required:
            reasons.append("0 个 required 用例——无可判定必测项，BLOCKED")
        for c in required:
            if c.get("status") != "PASS":
                reasons.append(f"必测用例未 PASS（{c.get('status')}）: {c.get('id')}")

    # 契约交叉核对（contract_path 提供时）
    if contract_path:
        cc = load_contract_cases(contract_path)
        if cc is None:
            reasons.append(f"契约不可读/损坏: {contract_path}（交叉核对失败即 BLOCKED）")
        else:
            for cid in sorted(result_ids):
                if cid not in cc:
                    reasons.append(f"用例 {cid} 未在契约 cases 登记（伪造/串目录）")
            for cid, req in cc.items():
                if cid not in result_ids:
                    reasons.append(f"契约用例 {cid} 未出现在 case-results（场景目录不完整）")
                elif req and not any(isinstance(c, dict) and c.get("id") == cid and c.get("required", True) for c in cases):
                    reasons.append(f"契约必测用例 {cid} 在结果中未标 required（口径漂移）")
        bc = load_branch_coverage(contract_path)
        if isinstance(bc, dict):
            tot = bc.get("total_in_source"); fml = bc.get("formal_cases")
            rev = bc.get("reverse_explore"); skp = bc.get("skipped_unknown_node")
            if not all(isinstance(v, int) for v in (tot, fml, rev, skp)):
                reasons.append("meta.branch_coverage 计数字段非整型——分支覆盖不可核验")
            else:
                if tot != fml + rev + skp:
                    reasons.append(f"分支覆盖计数不自洽: total={tot} ≠ formal={fml}+reverse={rev}+skipped={skp}")
                if skp > 0:
                    reasons.append(f"分支集不完整（{skp}/{tot} 支未知环节被跳过）——{fml} 支通过不构成全分支 PASS；补节点码重新生成后新 run-id 重跑")
                if fml != len(result_ids):
                    reasons.append(f"分支覆盖 formal_cases={fml} 与实际执行用例数 {len(result_ids)} 不符（分母漂移）")
                if rev > 0 and bc.get("formal_complete") is True:
                    reasons.append("branch_coverage 自相矛盾: reverse_explore>0 但 formal_complete=true（重新用当前版本生成器生成契约）")
                bc_info = {
                    "total_in_source": tot, "formal_cases": fml,
                    "reverse_explore": rev, "skipped_unknown_node": skp,
                    "accounted_complete": skp == 0,
                    "formal_complete": skp == 0 and rev == 0,
                }

    # PASS 证据完整性：三件非账本证据必须全部登记且 sha 复算一致
    if not reasons:
        unregistered = MUST_REGISTER - snap_verified
        if unregistered:
            reasons.append(f"账本未登记/未验证必要证据: {sorted(unregistered)}——PASS 需 gates+case_results+field_compare 全部入账且 sha256 复算一致")

    # 正式 PASS 必须绑定真实版本
    if not reasons:
        vers = manifest.get("versions")
        vers_bad = [k for k in ("source", "target", "flow")
                    if not (isinstance(vers, dict) and isinstance(vers.get(k), str)
                            and vers[k].strip() and vers[k].strip() != "unrecorded")]
        if vers_bad:
            reasons.append(f"账本版本未记录或为 unrecorded: {vers_bad}——正式 PASS 须绑定真实 source/target/flow 版本")

    # 结论判定
    if reasons:
        conclusion = "BLOCKED"
    elif diff_list or failed_cases:
        conclusion = "FAIL"
    else:
        conclusion = "PASS"

    # 分支范围限定（reverse_explore>0 且正向全 PASS → BLOCKED + forward_conclusion=PASS）
    conclusion_scope = None
    forward_conclusion = None
    forward_note = ""
    if bc_info is not None:
        if bc_info["formal_complete"]:
            conclusion_scope = "full"
        else:
            conclusion_scope = "forward_branches_only"
            fwd_all_pass = (conclusion == "PASS")
            forward_note = (f"分支范围限定：反向 {bc_info['reverse_explore']} 支仅探索演练未正式验证"
                            f"——正向 {bc_info['formal_cases']} 支{'全部 PASS' if fwd_all_pass else '存在未通过项'}；"
                            f"反向正式结论须另立正式契约（cases[].notes 显式声明特殊流转）单独 run 绑定")
            if fwd_all_pass:
                forward_conclusion = "PASS"
                reasons.append(f"{forward_note}——全量 PASS 不成立（结论降为 BLOCKED；forward_conclusion=PASS 仅为信息性字段，不是正式三态结论）")
                conclusion = "BLOCKED"
            elif conclusion == "FAIL":
                reasons.append(f"{forward_note}（正向 FAIL 维持 FAIL；反向范围未正式验证）")

    # 覆盖账本门禁（v1.5.0 任务完成门①）：契约声明 coverage_manifest 时，
    # 全部 must-cover 要素必须 covered/not_applicable 才允许"全流程双端 PASS"——
    # 否则 PASS 降级 BLOCKED（conclusion_scope=partial），契约遗漏不再能伪装全量通过。
    # （未声明账本的契约行为不变——向后兼容。）
    coverage_info = None
    if contract_path:
        # 审计第 8 轮 P0-1：两类 PASS 语义——未声明账本 = contract_scope_only（已声明契约范围）；
        # 声明且全闭环 = full（全流程范围）。未声明不再静默等同全量。
        coverage_info = {"declared": False, "conclusion_scope": "contract_scope_only"}
        cm, cm_path = load_coverage_manifest_with_path(contract_path)
        if cm == "declared_missing":
            # v1.7.4 P0（审计第 16 轮）：结论在门禁前判定——fail-closed 分支必须显式降级，
            # 否则全绿证据链 + 坏账本 → PASS 照出（fail-open）
            coverage_info = {"error": "declared_missing", "declared": True,
                             "conclusion_scope": "partial"}
            reasons.append("契约声明了 meta.coverage_manifest 但文件缺失/不可读/账本库不可用"
                           "（覆盖门禁 fail-closed）")
            if conclusion == "PASS":
                conclusion = "BLOCKED"
        elif isinstance(cm, dict):
            try:
                _here = Path(__file__).resolve().parent
                if str(_here) not in __import__("sys").path:
                    __import__("sys").path.insert(0, str(_here))
                import coverage_manifest as _cmmod
                _contract_dict = load_contract_full(contract_path)
                # 来源库存（声明时加载——相对账本目录解析，与 validator 一致）
                _inv_decl = (cm.get("meta") or {}).get("source_inventory")
                _inv = None
                _mp = (str(_inv_decl.get("path")) if isinstance(_inv_decl, dict) else
                       (str(_inv_decl) if _inv_decl else None))
                if _mp:
                    _inv, _ierr = _cmmod.load_inventory(
                        _cmmod.resolve_path(Path(contract_path), _mp))
                    if _ierr:
                        _inv = None
                # v1.7.4：单一 validate 承载结构+深度绑定+库存挂靠+反向完整性；
                # manifest_path=账本解析路径（库存相对路径基准与 validator 一致）
                probs = _cmmod.validate(cm, contract=_contract_dict, inventory=_inv,
                                        manifest_path=cm_path)
                if probs:
                    coverage_info = {"error": "invalid", "declared": True,
                                     "conclusion_scope": "partial", "problems": probs[:5]}
                    reasons.append("覆盖账本校验非法（结论期 fail-closed）: "
                                   + "; ".join(probs[:3]))
                    if conclusion == "PASS":
                        conclusion = "BLOCKED"
                else:
                    summ = _cmmod.summarize(cm)
                    summ["declared"] = True   # v1.7.0：declared 标志恒写（promote/报告层判别两类口径）
                    summ["conclusion_scope"] = "full" if not summ["blocking_ids"] else "partial"
                    coverage_info = summ
                    if conclusion == "PASS" and summ["conclusion_scope"] == "partial":
                        det = "；".join(f"{st}={len(ids)}" for st, ids in
                                        summ["blocking_by_status"].items())
                        reasons.append(f"覆盖账本存在未闭环必cover要素（{det}）——取证源未全量进契约，"
                                       f"全流程 PASS 不成立；结论降为 BLOCKED"
                                       f"（补齐覆盖账本后新 run-id 重跑）")
                        conclusion = "BLOCKED"
                    elif summ["conclusion_scope"] == "partial" and conclusion == "FAIL":
                        reasons.append("覆盖账本存在未闭环必cover要素（partial——FAIL 维持，"
                                       "且不得因部分通过宣称全流程一致）")
            except Exception as e:  # 账本评估异常=门禁不可用=fail-closed
                # v1.7.5（审计第 17 轮 P2-1）：except 分支与 declared_missing/invalid 同型——
                # 显式降级 conclusion（此前只 append reasons，全绿证据链下 PASS 照出=形态 fail-open）
                coverage_info = {"error": f"evaluate_failed: {type(e).__name__}: {e}",
                                 "declared": True, "conclusion_scope": "partial"}
                reasons.append(f"覆盖账本评估异常（fail-closed）: {type(e).__name__}: {e}")
                if conclusion == "PASS":
                    conclusion = "BLOCKED"

    required_total = len([c for c in (cases or []) if isinstance(c, dict) and c.get("required", True)])
    required_done = len([c for c in (cases or []) if isinstance(c, dict) and c.get("required", True) and c.get("status") == "PASS"])

    return {
        "conclusion": conclusion,
        "reasons": reasons,
        "p0_count": p0,
        "p1_count": p1,
        "semantic_diffs": diff_list,
        "exempted_diffs": exempted,
        "failed_cases": failed_cases,
        "blocked_reasons": reasons if conclusion == "BLOCKED" else [],
        "conclusion_scope": conclusion_scope,
        "forward_conclusion": forward_conclusion,
        "forward_note": forward_note,
        "ledger_binding": ledger_binding,
        "manifest": manifest,
        "snap_verified": snap_verified,
        "result_ids": result_ids,
        "bc_info": bc_info,
        "coverage_info": coverage_info,
        "contract_sha_match": contract_sha_match,
        "contract_exists": contract_exists_cs,
        "diff_list": diff_list,
        "exempted": exempted,
        "fc": fc,
        "gates": gates,
        "cases": cases,
        "required_total": required_total,
        "required_done": required_done,
    }