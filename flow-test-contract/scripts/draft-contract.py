#!/usr/bin/env python3
"""draft-contract.py —— 从经验库生成受控 DRAFT 契约骨架（v1.5.0 任务完成门⑤）。

探索（explore-channel merge）产出 experience.yaml 后，把"人工逐条复制建议"变成一条命令：
  - 同名/归一化同名映射建议 → field_mappings（basis 注记保留，人工核对后可删）
  - 未覆盖字段/按钮/公式/分支 → 全部进 TODO（meta.risk_seeds）+ 覆盖账本骨架（全 uncovered）
  - 产物 status 恒为 DRAFT（schema/生命周期门控保证：DRAFT 禁止正式执行）——
    经验库永远不会越权成为正式结论依据
  - 覆盖账本 uncovered 项必须人工处理（covered/expected_gap/not_applicable）后才可能全量 PASS

产物：DRAFT 契约 yaml + coverage-manifest-draft.yaml（同目录）。已存在默认拒绝覆盖。
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_SCRIPT_DIR))
sys.dont_write_bytecode = True

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：uv run --with pyyaml python3 draft-contract.py …")

VERSION = "draft-contract.py v1（skill v1.7.2）"


def main() -> int:
    ap = argparse.ArgumentParser(prog="draft-contract.py", description="experience.yaml → 受控 DRAFT 契约骨架")
    ap.add_argument("--experience", required=True, help="explore-channel merge 产出的 experience.yaml")
    ap.add_argument("--out", required=True, help="DRAFT 契约输出路径")
    ap.add_argument("--coverage-out", default="", help="覆盖账本骨架输出（缺省与 --out 同目录 coverage-manifest-draft.yaml）")
    ap.add_argument("--flow-name", default="", help="流程中文名（缺省用 flow_code）")
    ap.add_argument("--overwrite", action="store_true")
    a = ap.parse_args()

    try:
        exp = yaml.safe_load(Path(a.experience).read_text(encoding="utf-8")) or {}
    except Exception as e:
        print(f"⛔ 经验库不可读: {e}", file=sys.stderr)
        return 2
    meta_e = exp.get("meta") or {}
    flow_code = str(meta_e.get("flow_code") or "").strip()
    if not flow_code:
        print("⛔ 经验库缺 meta.flow_code", file=sys.stderr)
        return 2
    nodes_e = exp.get("nodes") or []
    if not nodes_e:
        print("⛔ 经验库无节点数据（先跑 explore --apply 再 merge）", file=sys.stderr)
        return 2

    out = Path(a.out)
    if out.exists() and not a.overwrite:
        print(f"⛔ {out} 已存在（--overwrite 放行）", file=sys.stderr)
        return 2

    suggestions = (exp.get("contract_suggestions") or {}).get("field_mappings") or []
    fms: list[dict] = []
    todos: list[str] = []
    for s in suggestions:
        if isinstance(s, dict) and s.get("legacy_field") and s.get("target_field"):
            fms.append({"legacy_field": str(s["legacy_field"]), "target_field": str(s["target_field"]),
                        "normalize": str(s.get("normalize") or "trim"),
                        "tolerance": str(s.get("tolerance") or "exact"),
                        "null_policy": str(s.get("null_policy") or "both_null_equal"),
                        "note": str(s.get("note") or "")})
    mapped_l = {f["legacy_field"] for f in fms}
    mapped_c = {f["target_field"] for f in fms}
    for n in nodes_e:
        seq = n.get("seq")
        for k in (n.get("needs_human") or {}).get("legacy_only") or []:
            todos.append(f"seq{seq} 字段 {k}：仅老系统有——补 target_field 或声明 expected_gap")
        for k in (n.get("needs_human") or {}).get("current_only") or []:
            todos.append(f"seq{seq} 字段 {k}：仅新系统有——补 legacy_field 或声明 expected_gap")
        for c in n.get("field_mapping_candidates") or []:
            if isinstance(c, dict) and c.get("suggest") is False:
                todos.append(f"seq{seq} 映射候选 {c.get('legacy_field')}↔{c.get('target_field')}"
                             f"（{c.get('basis')}）仅提示——人工确认是否纳入")
        rl, rc = (n.get("routes") or {}).get("legacy") or [], (n.get("routes") or {}).get("current") or []
        if rl and rc and sorted(map(str, rl)) != sorted(map(str, rc)):
            todos.append(f"seq{seq} 路由候选不一致 legacy={rl} current={rc}——补 routing 合同或归因")
        if (n.get("node") or {}).get("legacy") != (n.get("node") or {}).get("current"):
            todos.append(f"seq{seq} 双端环节不一致（{n.get('node')}）——跨环节对齐禁止直接纳入映射")

    # 节点链（老系统侧探索实录；current 侧同名对齐由人工核对）
    nodes: list[dict] = []
    seen_nodes: list[str] = []
    for n in nodes_e:
        code = (n.get("node") or {}).get("legacy") or (n.get("node") or {}).get("current")
        if code and str(code) not in seen_nodes:
            seen_nodes.append(str(code))
    for i, code in enumerate(seen_nodes):
        nxt = [seen_nodes[i + 1]] if i + 1 < len(seen_nodes) else []
        nodes.append({"code": str(code), "name": f"TODO 环节 {code}", "form": None,
                      "handlers": [""], "pool": [], "next": nxt, "re_edit": False})

    cases_steps = []
    for n in nodes_e:
        code = (n.get("node") or {}).get("legacy")
        if code:
            cases_steps.append({"node": str(code), "actor": "", "action": "TODO 填写操作语义",
                                "next": str(n.get("advanced_to") or ""), "pick": ""})
    if not cases_steps:
        cases_steps = [{"node": seen_nodes[0] if seen_nodes else "00", "actor": "",
                        "action": "TODO", "next": "", "pick": ""}]

    contract = {
        "meta": {
            "flow_name": a.flow_name or flow_code,
            "flow_code": flow_code,
            "shape": "S2",
            "contract_version": 1,
            "status": "DRAFT",
            "instance_policy": "launch",
            "coverage_manifest": {"path": str((Path(a.coverage_out) if a.coverage_out
                                               else out.parent / "coverage-manifest-draft.yaml"))},
            "sources": [{"id": f"exploration-{meta_e.get('explore_id', 'unknown')}",
                         "kind": "exploration",
                         "detail": f"探索 {meta_e.get('explore_id')}（sides sha 见 experience.yaml meta.sides）；"
                                   f"本契约为骨架——取证三源仍须人工补齐"}],
            "notes": "DRAFT 骨架（draft-contract.py 生成）：TODO 项见 risk_seeds；"
                     "取证三源（Excel/老库/流程逻辑）核对 + gates/health_checks/accounts 补齐后，"
                     "过 validate-contract --level test_ready 才能正式执行。",
            "risk_seeds": todos,
        },
        "environments": {
            "legacy": {"base_url": "", "login_path": ""},
            "current": {"base_url": "", "login_path": ""},
            "health_checks": [],
        },
        "accounts": [],
        "nodes": nodes,
        "forms": [],
        "field_mappings": fms,
        "dict_maps": {},
        "fixtures": [],
        "formulas": [],
        "routing": [],
        "buttons": [],
        "resources": [],
        "post_flow": {},
        "cases": [{"id": "C-01", "kb": "KB-01", "title": "TODO 用例标题",
                   "required": True, "steps": cases_steps, "assertions": [], "notes": ""}],
        "gates": [{"id": "GATE-DEPLOY", "check": "流程已部署且发起人可见", "severity": "P1",
                   "on_fail": "BLOCKED",
                   "evidence_schema": {"kind": "report", "file_format": "json",
                                       "flow_field": "data.flow_code",
                                       "required_fields": [{"path": "data.deployed", "op": "eq", "value": True}]}
                   }],
        "exemptions": [],
        "conclusions": {
            "PASS": "gates 全过 且 required 用例全部执行 且 未豁免语义差异=0 且 覆盖账本无未闭环必cover",
            "FAIL": "存在未豁免语义差异",
            "BLOCKED": "任一 gate 失败 / 必测数据不可用 / 证据缺失 / 覆盖账本未闭环",
        },
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(yaml.safe_dump(contract, allow_unicode=True, sort_keys=False, width=110), encoding="utf-8")

    # 覆盖账本骨架（复用唯一实现）
    cov_out = Path(a.coverage_out) if a.coverage_out else out.parent / "coverage-manifest-draft.yaml"
    import coverage_manifest as cm
    cm_scaffold = cm.scaffold_from_contract(contract, source="exploration")
    # 追加探索发现但未进契约的字段为 uncovered must-cover（防"骨架即遗漏"）
    mapped_pairs = {(f["legacy_field"], f["target_field"]) for f in fms}
    extra = 0
    for n in nodes_e:
        seq = n.get("seq")
        for side_key in ("legacy", "current"):
            for fname in ((n.get("fields") or {}).get(side_key) or {}):
                if (fname, fname) not in mapped_pairs and not any(
                        f["legacy_field"] == fname or f["target_field"] == fname for f in fms):
                    cm_scaffold["elements"].append({
                        "id": f"field-seq{seq}-{side_key}-{fname}", "source": "exploration",
                        "kind": "field", "name": f"seq{seq} {side_key} 字段 {fname}",
                        "contract_ref": "", "dimension": "field",
                        "channel": cm.channel_of_contract(contract), "status": "uncovered",
                        "must_cover": True, "reason": "", "followup": ""})
                    extra += 1
    cov_out.write_text(yaml.safe_dump(cm_scaffold, allow_unicode=True, sort_keys=False, width=110), encoding="utf-8")

    print(f"✅ DRAFT 契约骨架 → {out}")
    print(f"   field_mappings 建议 {len(fms)} 条；TODO {len(todos)} 条（risk_seeds）；"
          f"覆盖账本骨架 {len(cm_scaffold['elements'])} 要素（含探索未覆盖字段 +{extra}，全 uncovered）")
    print("   ⚠ 产物恒为 DRAFT：人工补齐取证三源/账号/gates/health_checks → validate --level test_ready"
          " → 才能正式执行；覆盖账本 uncovered 项须逐项处理，否则全量 PASS 不成立")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[draft-contract] ⛔ 内部异常: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
