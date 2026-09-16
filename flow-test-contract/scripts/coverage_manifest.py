#!/usr/bin/env python3
"""coverage_manifest.py —— 覆盖账本（v1.5.0 任务完成门①：来源→契约→维度→通道→状态）。

解决"validator 只能验证已声明要素，不能证明取证源全量进契约"的完成度盲区：
每条取证要素（环节/按钮/字段/公式/分支/资源/后置）逐项登记
  来源(source) → 契约位置(contract_ref) → 比较维度(dimension) → 通道(channel) → 状态(status)
只有全部 must-cover 要素 status=covered（或显式 not_applicable），run 才允许"全流程双端
PASS"；否则 conclude_core 把 PASS 降级 BLOCKED（conclusion_scope=partial）——契约遗漏不再
能伪装成全量通过。expected_gap/ready_for_browser_run 构成浏览器缺口的显式完成队列。

状态语义：
  covered               已进契约且有 case/step 承载（必填 contract_ref）
  expected_gap          已声明的非自动化缺口（必填 reason+followup——进浏览器完成队列）
  ready_for_browser_run 已完成 UI 录制/探索，待浏览器正式 run 验证
  uncovered             未覆盖（未声明理由——最危险态，直接阻断全量 PASS）
  not_applicable        明确不适用（必填 reason）

本模块是唯一实现：conclude_core（结论门禁）、validate-contract（立契校验）、
draft-contract（骨架生成）、explore-channel（browser 探索要素产出）共用。禁止另写第二套。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
sys.dont_write_bytecode = True   # 审计第 11 轮 F11-1：动态加载共享模块零字节码（skill 目录零副作用）
from datetime import datetime
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：uv run --with pyyaml python3 coverage_manifest.py …")

VERSION = "coverage_manifest.py v4（skill v1.7.2）"

STATUSES = ("covered", "expected_gap", "ready_for_browser_run", "uncovered", "not_applicable")
KINDS = ("node", "button", "field", "formula", "branch", "resource", "post_flow", "case", "page", "other")
CHANNELS = ("api", "browser", "both", "none")
SOURCES = ("excel", "legacy_db", "flow_logic", "exploration", "browser_explore", "manual")
# 阻断"全流程 PASS"的必cover 状态（not_applicable/covered 不阻断）
BLOCKING_STATUSES = ("uncovered", "expected_gap", "ready_for_browser_run")
# kind → 合法 dimension（审计第 8 轮 P0-2：维度与要素种类一致性可机器判定）
KIND_DIMENSION = {
    "node": {"routing", ""},
    "field": {"field"},
    "formula": {"formula"},
    "branch": {"routing"},
    "button": {"buttons"},
    "resource": {"resources"},
    "post_flow": {"post_flow"},
    "case": {"", "field", "formula", "routing", "buttons", "resources", "post_flow"},
    "page": {"buttons"},
    "other": {"", "field", "formula", "routing", "buttons", "resources", "post_flow"},
}


def resolve_path(contract_path: str | Path, p: str) -> Path:
    """账本路径解析（审计第 8 轮 P1-1）：相对路径一律按**契约所在目录**解析——
    validator/conclude_core/readiness/draft 产出统一走本函数，禁止按 CWD 解析。"""
    pp = Path(p)
    if pp.is_absolute():
        return pp
    return Path(contract_path).resolve().parent / pp if contract_path else pp


def load_manifest_for_contract(contract_path: str | Path, p: str) -> tuple[dict | None, str | None]:
    """按契约目录解析并加载账本（validator/conclude_core/readiness 共用入口）。"""
    return load_manifest(resolve_path(contract_path, p))


def load_manifest(path: str | Path) -> tuple[dict | None, str | None]:
    """读取覆盖账本 YAML；返回 (manifest, error)。error 非 None 时 manifest 为 None。"""
    p = Path(path)
    if not p.is_file():
        return None, f"覆盖账本文件不存在: {p}"
    try:
        m = yaml.safe_load(p.read_text(encoding="utf-8"))
    except Exception as e:
        return None, f"覆盖账本不可解析: {type(e).__name__}: {e}"
    if not isinstance(m, dict):
        return None, "覆盖账本根节点须为对象"
    return m, None


def validate(m: dict, contract: dict | None = None, inventory: dict | None = None,
                 manifest_path: str | Path | None = None) -> list[str]:
    """结构校验（无 contract）+ 深度校验（提供契约时，审计第 8 轮 P0-2）：
    covered 的 contract_ref 解析为 case/step 结构化引用——case 存在、step 存在、
    node 匹配（元素声明 node 时）、kind↔dimension 一致、covered 必填 evidence（run-id/
    探索 id 等真实凭据）、not_applicable 必填 reason+evidence（不能一句话糊弄）。"""
    probs: list[str] = []
    els = m.get("elements")
    if not isinstance(els, list) or not els:
        return ["覆盖账本缺 elements 非空列表"]
    # 契约索引（深度校验用）
    cases_idx: dict[str, dict] = {}
    if isinstance(contract, dict):
        for c in contract.get("cases") or []:
            if isinstance(c, dict) and c.get("id"):
                cases_idx[str(c["id"])] = c
    seen: set = set()
    for i, e in enumerate(els):
        tag = f"elements[{i}]"
        if not isinstance(e, dict):
            probs.append(f"{tag} 非对象")
            continue
        eid = e.get("id")
        if not isinstance(eid, str) or not eid.strip():
            probs.append(f"{tag} 缺非空 id")
            continue
        if eid in seen:
            probs.append(f"{tag} id 重复: {eid}")
        seen.add(eid)
        if e.get("source") not in SOURCES:
            probs.append(f"{eid}: source 非法 {e.get('source')!r}（只认 {'/'.join(SOURCES)}）")
        if e.get("kind") not in KINDS:
            probs.append(f"{eid}: kind 非法 {e.get('kind')!r}（只认 {'/'.join(KINDS)}）")
            continue
        dim = e.get("dimension")
        if dim is None:
            dim = ""
        if dim not in KIND_DIMENSION.get(e.get("kind"), {""}):
            probs.append(f"{eid}: dimension={dim!r} 与 kind={e.get('kind')!r} 不一致"
                         f"（合法: {sorted(KIND_DIMENSION[e['kind']])}）")
        if e.get("channel") not in CHANNELS:
            probs.append(f"{eid}: channel 非法 {e.get('channel')!r}（只认 {'/'.join(CHANNELS)}）")
        st = e.get("status")
        if st not in STATUSES:
            probs.append(f"{eid}: status 非法 {st!r}（只认 {'/'.join(STATUSES)}）")
            continue
        mc = e.get("must_cover")
        if not isinstance(mc, bool):
            probs.append(f"{eid}: must_cover 须为布尔（缺省视 false，但建议显式）")
        ref = str(e.get("contract_ref") or "").strip()
        ev = str(e.get("evidence") or "").strip()
        if st == "covered":
            if not ref:
                probs.append(f"{eid}: status=covered 须填 contract_ref（case[/step]——承载证据）")
            if not ev:
                probs.append(f"{eid}: status=covered 须填 evidence（run-id/探索 id——已验证凭据，"
                             f"审计第 8 轮 P0-2：不能只声明 covered 而不给验证凭据）")
        if st in ("expected_gap", "not_applicable") and not str(e.get("reason") or "").strip():
            probs.append(f"{eid}: status={st} 须填 reason（缺口/不适用的可审计理由）")
        if st == "expected_gap" and not str(e.get("followup") or "").strip():
            probs.append(f"{eid}: status=expected_gap 须填 followup（完成队列的下一步）")
        if st == "not_applicable" and not ev:
            probs.append(f"{eid}: status=not_applicable 须填 evidence（来源依据/审批引用——"
                         f"审计第 8 轮 P0-2：不能只填一句 reason）")
        # v1.7.0 P0-1：covered 元素按 kind 深度绑定到契约真实对象——
        # field→field_mappings 存在该字段；formula→公式 id；button/branch→node 在
        # buttons/routing 断言中；resource→resources id；post_flow→post_flow.code。
        # 没有对应合同维度，"covered"只证明挂到了某一步，不证明真的参与双端对拍。
        if st == "covered" and isinstance(contract, dict) and contract:
            ck = str(e.get("contract_key") or "").strip()
            nd = str(e.get("node") or "").strip()
            kind_e = e.get("kind")
            fms = [f for f in (contract.get("field_mappings") or []) if isinstance(f, dict)]
            if kind_e == "field":
                if not ck:
                    probs.append(f"{eid}: covered field 要素须填 contract_key（契约 field_mappings "
                                 f"的 legacy_field/target_field）——无对应合同维度不构成覆盖")
                elif not (ck in {f.get("legacy_field") for f in fms}
                          or ck in {f.get("target_field") for f in fms}):
                    probs.append(f"{eid}: contract_key={ck!r} 不在契约 field_mappings 中"
                                 f"（field 覆盖必须绑定真实语义合同）")
            elif kind_e == "formula":
                if not ck:
                    probs.append(f"{eid}: covered formula 要素须填 contract_key（契约 formulas 的 id）")
                elif ck not in {f.get("id") for f in (contract.get("formulas") or [])
                                if isinstance(f, dict)}:
                    probs.append(f"{eid}: contract_key={ck!r} 不在契约 formulas 中")
            elif kind_e == "button":
                if not nd:
                    probs.append(f"{eid}: covered button 要素须填 node（契约 buttons 断言的环节）")
                elif nd not in {str(b.get("node")) for b in (contract.get("buttons") or [])
                                if isinstance(b, dict) and b.get("node")}:
                    probs.append(f"{eid}: node={nd!r} 不在契约 buttons 断言中")
            elif kind_e == "branch":
                if not nd:
                    probs.append(f"{eid}: covered branch 要素须填 node（契约 routing 断言的环节）")
                elif nd not in {str(r.get("node")) for r in (contract.get("routing") or [])
                                if isinstance(r, dict) and r.get("node")}:
                    probs.append(f"{eid}: node={nd!r} 不在契约 routing 断言中")
            elif kind_e == "resource":
                if not ck:
                    probs.append(f"{eid}: covered resource 要素须填 contract_key（契约 resources 的 id）")
                elif ck not in {r.get("id") for r in (contract.get("resources") or [])
                                if isinstance(r, dict)}:
                    probs.append(f"{eid}: contract_key={ck!r} 不在契约 resources 中")
            elif kind_e == "post_flow":
                if not (contract.get("post_flow") or {}).get("code"):
                    probs.append(f"{eid}: covered post_flow 要素但契约未声明 post_flow.code")
        # 深度校验：contract_ref → case/step 结构化解析
        if ref and cases_idx:
            parts = ref.split("/")
            cid = parts[0]
            if cid not in cases_idx:
                probs.append(f"{eid}: contract_ref={ref!r} 指向契约不存在的用例 {cid!r}")
                continue
            if len(parts) > 1:
                sm = re.fullmatch(r"s(\d+)", parts[1])
                if not sm:
                    probs.append(f"{eid}: contract_ref 步骤段 {parts[1]!r} 非法（须为 s<序号>，如 C-01/s2）")
                    continue
                idx = int(sm.group(1))
                steps = cases_idx[cid].get("steps") or []
                if not (1 <= idx <= len(steps)):
                    probs.append(f"{eid}: contract_ref={ref!r} 步骤越界（{cid} 共 {len(steps)} 步）")
                    continue
                enode = str(e.get("node") or "").strip()
                if enode:
                    snode = str((steps[idx - 1] or {}).get("node") or "").strip()
                    if snode != enode:
                        probs.append(f"{eid}: contract_ref={ref!r} 步骤节点={snode!r} 与元素 node={enode!r} 不一致"
                                     f"（不能挂在任意合法 case 上）")
    # v1.7.0 P1：来源库存（source inventory）声明时——must-cover 要素必须有 source_ref
    # 与 inventory 登记一致的 source_hash；"人工列出的集合已闭环"≠"真实流程集合已闭环"
    inv_decl = (m.get("meta") or {}).get("source_inventory") if isinstance(m.get("meta"), dict) else None
    if inventory is not None and not inv_decl:
        probs.append("传入了来源库存但账本未声明 meta.source_inventory——库存挂靠校验不生效即无效覆盖"
                     "（声明后 must-cover 逐条挂靠 source_ref/source_hash）")
    inv = inventory
    if inv is None and inv_decl:
        # 库存路径相对**账本文件**所在目录解析（调用方经 manifest_path 传入；无则按 CWD 兜底）
        inv_path = inv_decl.get("path") if isinstance(inv_decl, dict) else inv_decl
        if not isinstance(inv_path, str) or not inv_path.strip():
            probs.append("meta.source_inventory 须为 {path: 库存yaml路径} 或路径字符串")
        else:
            try:
                inv, err = load_inventory(resolve_path(manifest_path, inv_path))
            except Exception as e:
                err = f"{type(e).__name__}: {e}"
            if err:
                probs.append(f"meta.source_inventory: {err}")
                inv = None
    if inv is not None and inv_decl:
        inv_ids = {x.get("id") for x in (inv.get("items") or []) if isinstance(x, dict)}
        for e in els:
            if not isinstance(e, dict) or e.get("must_cover") is not True:
                continue
            sref = str(e.get("source_ref") or "").strip()
            shash = str(e.get("source_hash") or "").strip()
            inv_item = next((x for x in (inv.get("items") or [])
                             if isinstance(x, dict) and str(x.get("id")) == sref), None) if sref else None
            if not sref or inv_item is None:
                probs.append(f"{e.get('id')}: must-cover 要素缺 source_ref 或不在来源库存中"
                             f"（来源全量证明要求逐条挂靠库存）")
            elif not shash:
                probs.append(f"{e.get('id')}: must-cover 要素缺 source_hash（来源指纹）")
            elif shash != str(inv_item.get("source_hash") or "").strip():
                # v1.7.2 P1：指纹必须与库存登记**严格相等**——伪造 hash 不再通过
                probs.append(f"{e.get('id')}: source_hash={shash!r} 与库存登记 "
                             f"{str(inv_item.get('source_hash'))!r} 不符（来源指纹伪造/过期）")
    if inv is not None:
        # v1.7.3 P0：**反向完整性**——每个库存条目须有 ≥1 个覆盖要素挂靠（source_ref 指向它）。
        # 否则 Excel/BPMN 里的要素根本没进账本/契约，"来源全量"仍是假象。
        _refs = {str(e.get("source_ref") or "").strip() for e in els if isinstance(e, dict)}
        for x in (inv.get("items") or []):
            iid = str(x.get("id"))
            if iid not in _refs:
                probs.append(f"来源库存条目 {iid} 无任何覆盖要素挂靠——取证源未全量进入覆盖账本"
                             f"（source-inventory 反向完整性）")
    return probs


def load_inventory(path) -> tuple[dict | None, str | None]:
    """来源库存：Excel/BPMN/flow-tables/browser-explore 导出的要素全集。"""
    pp = Path(path)
    if not pp.is_file():
        return None, f"来源库存文件不存在: {pp}"
    try:
        inv = yaml.safe_load(pp.read_text(encoding="utf-8"))
    except Exception as e:
        return None, f"来源库存不可解析: {type(e).__name__}: {e}"
    if not isinstance(inv, dict) or not isinstance(inv.get("items"), list) or not inv["items"]:
        return None, "来源库存须含非空 items 列表"
    ids = set()
    for i, x in enumerate(inv["items"]):
        if not isinstance(x, dict) or not str(x.get("id") or "").strip():
            return None, f"items[{i}] 缺非空 id"
        if x["id"] in ids:
            return None, f"来源库存 id 重复: {x['id']}"
        ids.add(x["id"])
        if not str(x.get("source_hash") or "").strip():
            return None, f"items[{i}] 缺 source_hash（来源指纹——无指纹不构成全量证明）"
    return inv, None


def _default_dimension(kind) -> str:
    """kind → 默认 dimension（KIND_DIMENSION 中首个非空合法值）。"""
    legal = sorted(KIND_DIMENSION.get(str(kind), {""}) - {""})
    return legal[0] if legal else ""


def summarize(m: dict) -> dict:
    """合法账本 → 计数摘要（含阻断清单）。调用前须 validate 通过。"""
    els = [e for e in (m.get("elements") or []) if isinstance(e, dict)]
    must = [e for e in els if e.get("must_cover") is True]
    blocking = [e for e in must if e.get("status") in BLOCKING_STATUSES]
    by_status: dict[str, int] = {}
    for e in els:
        by_status[str(e.get("status"))] = by_status.get(str(e.get("status")), 0) + 1
    return {
        "total": len(els),
        "must_cover": len(must),
        "covered": by_status.get("covered", 0),
        "expected_gap": by_status.get("expected_gap", 0),
        "ready_for_browser_run": by_status.get("ready_for_browser_run", 0),
        "uncovered": by_status.get("uncovered", 0),
        "not_applicable": by_status.get("not_applicable", 0),
        "blocking_ids": [str(e.get("id")) for e in blocking],
        "blocking_by_status": {
            st: [str(e.get("id")) for e in blocking if e.get("status") == st]
            for st in BLOCKING_STATUSES if any(e.get("status") == st for e in blocking)
        },
    }


def scaffold_from_contract(contract: dict, source: str = "manual") -> dict:
    """从契约生成覆盖账本骨架：环节/按钮/公式/路由/资源/后置/用例逐项建档，
    status 一律 uncovered、must_cover 一律 true——由立契人逐项核实改为 covered/
    expected_gap/not_applicable（宁可 starts-from-uncovered，不允许 starts-from-covered）。"""
    els: list[dict] = []

    def _add(eid, kind, name, channel, dimension="", node="", contract_key=""):
        els.append({"id": eid, "source": source, "kind": kind, "name": name,
                    "node": node, "contract_key": contract_key,
                    "contract_ref": "", "dimension": dimension, "channel": channel,
                    "status": "uncovered", "must_cover": True, "reason": "", "followup": "",
                    "evidence": ""})

    for n in contract.get("nodes") or []:
        if isinstance(n, dict) and n.get("code"):
            _add(f"node-{n['code']}", "node", f"环节 {n['code']} {n.get('name', '')}",
                 "api" if channel_of_contract(contract) == "api" else "both", "routing",
                 node=str(n["code"]))
    for i, f in enumerate(contract.get("field_mappings") or []):
        if isinstance(f, dict):
            _add(f"field-{f.get('legacy_field', i)}", "field",
                 f"{f.get('legacy_field')}→{f.get('target_field')}", channel_of_contract(contract), "field",
                 contract_key=str(f.get("legacy_field", "") or ""))
    for f in contract.get("formulas") or []:
        if isinstance(f, dict) and f.get("id"):
            _add(f"formula-{f['id']}", "formula", str(f.get("expr", f["id"])),
                 channel_of_contract(contract), "formula", contract_key=str(f["id"]))
    for r in contract.get("routing") or []:
        if isinstance(r, dict) and r.get("node"):
            _add(f"branch-{r['node']}", "branch", f"环节 {r['node']} 路由",
                 channel_of_contract(contract), "routing", node=str(r["node"]))
    for b in contract.get("buttons") or []:
        if isinstance(b, dict) and b.get("node"):
            _add(f"button-{b['node']}", "button", f"环节 {b['node']} 按钮可见集", "browser", "buttons",
                 node=str(b["node"]))
    for r in contract.get("resources") or []:
        if isinstance(r, dict) and r.get("id"):
            _add(f"resource-{r['id']}", "resource", str(r["id"]), channel_of_contract(contract), "resources",
                 contract_key=str(r["id"]))
    if (contract.get("post_flow") or {}).get("code"):
        _add("post-flow", "post_flow", "流程后置自动发起", channel_of_contract(contract), "post_flow")
    for c in contract.get("cases") or []:
        if isinstance(c, dict) and c.get("id"):
            _add(f"case-{c['id']}", "case", str(c.get("title") or c["id"]),
                 channel_of_contract(contract), "")
    return {
        "meta": {
            "generator": VERSION,
            "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
            "note": "骨架全部 uncovered/must_cover——逐项核实后改 covered（填 contract_ref）/"
                    "expected_gap（填 reason+followup）/not_applicable（填 reason）；"
                    "conclude_core 按本账本判定'全流程 PASS'是否成立。",
        },
        "elements": els,
    }


def channel_of_contract(contract: dict) -> str:
    return "browser" if str(contract.get("meta", {}).get("shape", "")) == "BROWSER" else "api"


def main() -> int:
    ap = argparse.ArgumentParser(prog="coverage_manifest.py", description="覆盖账本：来源→契约→维度→通道→状态")
    sub = ap.add_subparsers(dest="cmd", required=True)

    ps = sub.add_parser("scaffold", help="从契约生成覆盖账本骨架（全部 uncovered/must_cover）")
    ps.add_argument("--contract", required=True)
    ps.add_argument("--out", required=True)
    ps.add_argument("--source", default="manual", choices=SOURCES)

    pc = sub.add_parser("check", help="结构校验 + 计数摘要（exit 0=结构合法；1=非法）")
    pc.add_argument("--manifest", required=True)
    pc.add_argument("--contract", default="", help="契约路径（提供则做 case/step/node/维度/合同绑定深度校验）")
    pc.add_argument("--inventory", default="", help="来源库存（声明了 source_inventory 的账本会自动校验挂靠）")

    pb = sub.add_parser("import-browser-explore", help="browser 只读探索要素 → 完成队列（ready_for_browser_run/must_cover，去重导入）")
    pb.add_argument("--manifest", required=True)
    pb.add_argument("--explore-dir", required=True, help="含 explore-browser-*.json 的探索目录")
    pb.add_argument("--must-cover", default="true", choices=("true", "false"))

    pi2 = sub.add_parser("import-inventory", help="来源库存 → 账本 reconcile（缺项补 uncovered must-cover+指纹；多 reported）")
    pi2.add_argument("--manifest", required=True)
    pi2.add_argument("--inventory", required=True)
    pp = sub.add_parser("promote", help="浏览器正式 run PASS 后：要素 → covered（须给 contract_ref，evidence=run-id）")
    pp.add_argument("--manifest", required=True)
    pp.add_argument("--contract", required=True, help="契约路径（covered 深度校验用）")
    pp.add_argument("--set", dest="sets", action="append", required=True,
                    help="id=contract_ref（可多次，如 --set button-35=C-01/s3）")
    pp.add_argument("--run-id", required=True, help="源 run 目录（须存在且 summary 结论=PASS）")

    a = ap.parse_args()
    if a.cmd == "scaffold":
        try:
            import yaml as _y
            c = _y.safe_load(Path(a.contract).read_text(encoding="utf-8")) or {}
        except Exception as e:
            print(f"⛔ 契约不可读: {e}", file=sys.stderr)
            return 2
        m = scaffold_from_contract(c, source=a.source)
        out = Path(a.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(yaml.safe_dump(m, allow_unicode=True, sort_keys=False, width=110), encoding="utf-8")
        summ = summarize(m)
        print(f"✅ 覆盖账本骨架 → {out}（{summ['total']} 要素全部 uncovered/must_cover——逐项核实后改状态）")
        return 0
    if a.cmd == "check":
        m, err = load_manifest(a.manifest)
        if err:
            print(f"⛔ {err}", file=sys.stderr)
            return 1
        contract = None
        if getattr(a, "contract", ""):
            try:
                contract = yaml.safe_load(Path(a.contract).read_text(encoding="utf-8")) or {}
            except Exception as e:
                print(f"⛔ 契约不可读: {e}", file=sys.stderr)
                return 1
        inventory = None
        if getattr(a, "inventory", ""):
            inventory, ierr = load_inventory(a.inventory)
            if ierr:
                print(f"⛔ 来源库存不可用: {ierr}", file=sys.stderr)
                return 1
        probs = validate(m, contract=contract, inventory=inventory, manifest_path=a.manifest)
        if probs:
            print("⛔ 覆盖账本校验非法:", file=sys.stderr)
            for x in probs:
                print(f"  - {x}", file=sys.stderr)
            return 1
        if inventory is not None:
            _missing_inv = [str(e.get("id")) for e in (m.get("elements") or [])
                            if isinstance(e, dict) and e.get("must_cover") is True
                            and not str(e.get("source_ref") or "").strip()]
            if _missing_inv:
                print(f"  ⚠ {len(_missing_inv)} 项 must-cover 未挂靠来源库存: {_missing_inv[:8]}")
        summ = summarize(m)
        print(f"✅ 覆盖账本合法：总 {summ['total']}｜must-cover {summ['must_cover']}"
              f"｜covered {summ['covered']}｜expected_gap {summ['expected_gap']}"
              f"｜ready_for_browser {summ['ready_for_browser_run']}"
              f"｜uncovered {summ['uncovered']}｜n/a {summ['not_applicable']}")
        if summ["blocking_ids"]:
            print(f"  ⚠ 未闭环必cover（阻断全量 PASS）: {summ['blocking_ids']}")
        return 0
    if a.cmd == "import-browser-explore":
        m, err = load_manifest(a.manifest)
        if err:
            print(f"⛔ {err}", file=sys.stderr)
            return 2
        probs = validate(m)
        if probs:
            print("⛔ 现有账本结构非法（先修复再导入）:", file=sys.stderr)
            for x in probs[:5]:
                print(f"  - {x}", file=sys.stderr)
            return 2
        d = Path(a.explore_dir)
        # v1.7.2 P1-2：去重键=要素 id（含页面 label+序号，跨页唯一）——不再按 (kind,name)：
        # 两个不同页面的同名按钮（如都有"提交"）互不吞并
        existing = {e.get("id") for e in m.get("elements") or []}
        added, skipped = 0, 0
        for jf in sorted(d.glob("explore-browser-*.json")):
            try:
                j = json.loads(jf.read_text(encoding="utf-8"))
            except Exception:
                continue
            for e in (j.get("ui_record_candidates") or {}).get("coverage_elements") or []:
                if not isinstance(e, dict) or not e.get("id"):
                    continue
                eid = str(e["id"])
                if eid in existing:
                    skipped += 1
                    continue
                m["elements"].append({
                    "id": eid, "source": "browser_explore", "kind": e.get("kind", "button"),
                    "name": e.get("name") or eid, "node": e.get("node", ""),
                    "contract_ref": "",
                    "dimension": e.get("dimension") or _default_dimension(e.get("kind", "button")),
                    "channel": "browser", "status": "ready_for_browser_run",
                    "must_cover": a.must_cover == "true",
                    "reason": "", "followup": "浏览器正式 run 验证后 promote 为 covered",
                    "evidence": f"browser-explore:{jf.stem}"})
                existing.add(eid)
                added += 1
        Path(a.manifest).write_text(
            yaml.safe_dump(m, allow_unicode=True, sort_keys=False, width=110), encoding="utf-8")
        summ = summarize(m)
        print(f"✅ 导入 browser 探索要素 +{added}（去重跳过 {skipped}）→ {a.manifest}"
              f"｜当前未闭环 must-cover {len(summ['blocking_ids'])} 项")
        return 0
    if a.cmd == "import-inventory":
        m, err = load_manifest(a.manifest)
        if err:
            print(f"⛔ {err}", file=sys.stderr)
            return 2
        inv, ierr = load_inventory(a.inventory)
        if ierr:
            print(f"⛔ 来源库存不可用: {ierr}", file=sys.stderr)
            return 2
        existing = {e.get("id") for e in m.get("elements") or []}
        existing_names = {(e.get("kind"), str(e.get("name") or "")) for e in m.get("elements") or []}
        added, reported = 0, 0
        for x in inv.get("items") or []:
            eid = f"inv-{x.get('id')}"
            if eid in existing:
                continue
            m["elements"].append({
                "id": eid, "source": x.get("source", "manual"), "kind": x.get("kind", "other"),
                "name": x.get("name") or x.get("id"), "node": x.get("node", ""),
                "contract_key": x.get("contract_key", ""), "contract_ref": "",
                "dimension": x.get("dimension") or _default_dimension(x.get("kind", "other")),
                "channel": x.get("channel", "none"),
                "status": "uncovered", "must_cover": True, "reason": "", "followup": "",
                "evidence": "", "source_ref": str(x.get("id")), "source_hash": str(x.get("source_hash"))})
            added += 1
            # 已在账本但无挂靠的 must-cover：报告（人工补 source_ref/source_hash）
        for e in m.get("elements") or []:
            if isinstance(e, dict) and e.get("must_cover") is True and not str(e.get("source_ref") or "").strip():
                reported += 1
        m.setdefault("meta", {})["source_inventory"] = {"path": str(Path(a.inventory).resolve())}
        Path(a.manifest).write_text(
            yaml.safe_dump(m, allow_unicode=True, sort_keys=False, width=110), encoding="utf-8")
        print(f"✅ 库存 reconcile：补入 {added} 项 uncovered must-cover（含 source_ref/source_hash）；"
              f"{reported} 项存量 must-cover 待人工补挂靠 → {a.manifest}")
        return 0
    if a.cmd == "promote":
        # v1.7.0 P0-2：promote 全链核验——任意"summary=PASS 的无关目录"不再能关闭浏览器缺口：
        # ①conclude_core 全量重算 PASS（含账本 sha 复算）；②run 账本登记的契约与本 --contract
        # 字节一致；③coverage_scope=full（全流程口径）；④contract_ref 的 case 在 case-results
        # 为 PASS；⑤该 case 双端 capture 存在且 channel 与要素一致。
        rd = Path(a.run_id)
        try:
            import hashlib as _hl
            _here = Path(__file__).resolve().parent
            if str(_here) not in sys.path:
                sys.path.insert(0, str(_here))
            import conclude_core as _cc
        except Exception as e:
            print(f"⛔ 结论评估器不可用: {e}", file=sys.stderr)
            return 2
        try:
            contract = yaml.safe_load(Path(a.contract).read_text(encoding="utf-8")) or {}
        except Exception as e:
            print(f"⛔ 契约不可读: {e}", file=sys.stderr)
            return 2
        summ_j = {}
        try:
            summ_j = json.loads((rd / "summary.json").read_text(encoding="utf-8"))
        except Exception as e:
            print(f"⛔ 源 run 目录不可读/缺 summary: {rd}（{e}）", file=sys.stderr)
            return 2
        manifest_j = json.loads((rd / "run-manifest.json").read_text(encoding="utf-8")) \
            if (rd / "run-manifest.json").is_file() else None
        if not isinstance(manifest_j, dict):
            print("⛔ 源 run 缺完整账本（run-manifest.json）——无账本 run 不得作为 covered 依据", file=sys.stderr)
            return 2
        # ① 中性化全量重算（v1.7.0：去除覆盖门禁后，run 的**执行面**必须全 PASS——
        # 差异/失败用例/gate/账本任一不过即拒；覆盖闭环正是本 promote 要完成的事，
        # 故鸡生蛋的 coverage-scope BLOCKED 不构成拒绝理由。篡改的 summary 在此现形）
        import tempfile as _tf
        with _tf.TemporaryDirectory() as _td:
            _nc = dict(contract)
            _ncm = dict(contract.get("meta") or {})
            _ncm.pop("coverage_manifest", None)
            _nc["meta"] = _ncm
            _ncp = Path(_td) / "neutral.yaml"
            _ncp.write_text(yaml.safe_dump(_nc, allow_unicode=True), encoding="utf-8")
            ev = _cc.evaluate(rd, _ncp)
        if ev["conclusion"] != "PASS":
            print(f"⛔ 源 run 执行面重算={ev['conclusion']} ≠ PASS（summary 自述不作数；"
                  f"覆盖缺口除外）——原因: {'; '.join(ev['reasons'][:3])}", file=sys.stderr)
            return 2
        # ② 契约哈希一致（同一契约的证据才能覆盖本契约的缺口）
        snap_c = (manifest_j.get("config_snapshot") or {}).get("contract") or {}
        cp = str(snap_c.get("abs_path") or snap_c.get("path") or "")
        if not cp or not Path(cp).is_file() \
                or _hl.sha256(Path(cp).read_bytes()).hexdigest()[:16] != str(snap_c.get("sha256_16") or ""):
            print("⛔ 源 run 账本契约哈希不符/缺失——run 与本契约脱节，拒绝 promote", file=sys.stderr)
            return 2
        if Path(cp).resolve() != Path(a.contract).resolve():
            print(f"⛔ 源 run 的契约 {cp} ≠ 本契约 {a.contract}——不许跨契约 promote", file=sys.stderr)
            return 2
        # ③ 源 run 必须处于"覆盖已声明、scope=partial/full"状态——以**重算口径**为准
        # （审计第 12 轮确认落地：summary.json 单文件自述不作数——手改 declared/scope 不得过）
        ev_real = _cc.evaluate(rd, a.contract)
        cs_real = ev_real.get("coverage_info") or {}
        if not cs_real.get("declared") or str(cs_real.get("conclusion_scope") or "") not in ("partial", "full"):
            print(f"⛔ 源 run coverage_scope 重算非法: declared={cs_real.get('declared')!r} "
                  f"scope={cs_real.get('conclusion_scope')!r}——只有声明账本的 partial/full run "
                  f"才存在可晋升的覆盖缺口（summary 自述不作数）", file=sys.stderr)
            return 2
        # ④⑤ case/通道/capture 对证
        cr = json.loads((rd / "case-results.json").read_text(encoding="utf-8")) \
            if (rd / "case-results.json").is_file() else []
        cr_pass = {str(c.get("id")) for c in cr if isinstance(c, dict) and c.get("status") == "PASS"}
        m, err = load_manifest(a.manifest)
        if err:
            print(f"⛔ {err}", file=sys.stderr)
            return 2
        by_id = {e.get("id"): e for e in m.get("elements") or [] if isinstance(e, dict)}
        promoted = 0
        for pair in a.sets:
            eid, _, ref = pair.partition("=")
            e = by_id.get(eid.strip())
            if e is None:
                print(f"⛔ 账本无要素 {eid!r}", file=sys.stderr)
                return 2
            case_id = ref.strip().split("/")[0]
            if case_id not in cr_pass:
                print(f"⛔ 要素 {eid!r} 的目标用例 {case_id!r} 不在源 run PASS 集合 {sorted(cr_pass)}",
                      file=sys.stderr)
                return 2
            _chan = e.get("channel")
            for side in ("legacy", "current"):
                capf = rd / "field-captures" / side / f"{case_id}.json"
                if not capf.is_file():
                    print(f"⛔ 源 run 缺 capture 证据: {capf}——不能证明该 case 真实双端执行", file=sys.stderr)
                    return 2
                if _chan in ("browser", "both"):
                    try:
                        capj = json.loads(capf.read_text(encoding="utf-8"))
                    except Exception:
                        print(f"⛔ capture 不可读: {capf}", file=sys.stderr)
                        return 2
                    if str(capj.get("channel") or "") != "browser":
                        print(f"⛔ {capf} channel={capj.get('channel')!r} ≠ browser——"
                              f"浏览器要素必须由浏览器通道 run 覆盖", file=sys.stderr)
                        return 2
            e["status"] = "covered"
            e["contract_ref"] = ref.strip()
            e["evidence"] = f"run:{rd.name}"
            # 按钮类要素的 node 从目标步骤派生（深度校验要求 node 与契约 buttons 断言对齐）
            _mref = re.fullmatch(r"([^/]+)/s(\d+)", ref.strip())
            if _mfn := _mref:
                _cse = next((x for x in (contract.get("cases") or [])
                             if isinstance(x, dict) and str(x.get("id")) == _mfn.group(1)), None)
                _steps = (_cse or {}).get("steps") or []
                _idx = int(_mfn.group(2))
                if 1 <= _idx <= len(_steps) and e.get("kind") in ("button", "branch") \
                        and not str(e.get("node") or "").strip():
                    e["node"] = str((_steps[_idx - 1] or {}).get("node") or "")
            promoted += 1
        probs = validate(m, contract=contract)
        if probs:
            print("⛔ promote 后账本非法（回退前请修正 contract_ref/node/dimension）:", file=sys.stderr)
            for x in probs[:5]:
                print(f"  - {x}", file=sys.stderr)
            return 2
        Path(a.manifest).write_text(
            yaml.safe_dump(m, allow_unicode=True, sort_keys=False, width=110), encoding="utf-8")
        print(f"✅ promote {promoted} 项 → covered（evidence=run:{rd.name}，全链核验通过）→ {a.manifest}")
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
