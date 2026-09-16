#!/usr/bin/env python3
"""rerun-plan.py —— 重跑计划生成器（v1.5.0 任务完成门⑥）。

从 BLOCKED/FAIL run 的机器证据自动生成"下一步怎么做"：
  阻塞项/失败用例/语义差异/未过 gate → 责任域（env/config/contract/data/product/evidence）
  → 建议修复动作 → 验证命令 → 是否需要新 run-id（恒为是——账本与结论不可复用）。

铁律：计划只读 run 证据生成（rerun_of 绑定源 run-id）；可建议复用只读检查（health/config/
readiness），**绝不允许拼接不同 run 的执行 PASS 形成正式结论**——重跑必须全新 run-id 全量执行。
产出：run 目录内 rerun-plan.json + 重跑计划.md（已存在须 --overwrite）。
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

VERSION = "rerun-plan.py v1（skill v1.7.2）"

# 域判定关键词（顺序敏感：先具体后泛化）
_DOMAIN_RULES: list[tuple[str, list[str]]] = [
    ("evidence", ("证据", "账本", "sha", "manifest", "gate", "时效", "generated_at")),
    ("env", ("凭据", "env", "不可达", "HTTP 5", "超时", "timed out", "网络", "登录失败", "LAUNCH_ELEMENT")),
    ("config", ("operations", "配置", "F12", "systems", "占位", "route_map", "todo.map",
                "elementIdEnv", "successStatus", "channel", "retryOn", "save_with_form_data")),
    ("data", ("找不到任务", "必填", "数据", "fixture", "待办", "数据池", "占用", "实例", "孤儿")),
    ("contract", ("契约", "选择器", "case", "路由矛盾", "field_mappings", "nodes.next")),
    ("product", ("语义差异", "不一致", "diff", "tolerance", "null_policy", "公式", "候选集", "按钮集")),
]

# 域 → 建议动作 + 验证命令（只读/演练级，绝不拼接历史 PASS）
_DOMAIN_ACTIONS = {
    "env": ("修复环境/凭据/要素 ID（$RUNTIME_DIR/env、LAUNCH_ELEMENT_ID_<flow>），核对服务可达",
            ["bash $SKILL/scripts/health-check.py --contract <契约> --out /tmp/health.json",
             "python3 $SKILL/scripts/readiness.py --contract <契约> --systems-dir $RUNTIME_DIR/systems/api --out /tmp/readiness"]),
    "config": ("补齐 systems 通道配置（operations 语义端点/todo.map/route_map/save_with_form_data 等），"
               "按 f12-record.md 录端点",
               ["python3 $SKILL/scripts/legacy-config-check.py --systems-dir $RUNTIME_DIR/systems/api"]),
    "contract": ("修契约（用例路由与 nodes.next 对齐或 notes 显式声明特殊流转；补选择器/字段映射）后重新 gen",
                 ["uv run --with pyyaml,jsonschema python3 $SKILL/templates/validate-contract.py --contract <契约> --level test_ready"]),
    "data": ("清理/续跑测试实例（见 test-data-ledger.json 的 safe_to_clean；绝不自动破坏），"
             "补齐 fixture 数据池，或以 reuse+选择器续办残留实例",
             ["python3 $SKILL/scripts/test-data-ledger.py show --run-dir <本run目录>"]),
    "product": ("逐条核对语义差异（fc.diffs 人话明细见对比测试报告 §4）——确认属产品差异则报缺陷，"
                "属表示层差异且可审计则走 exempt 八字段取证链",
                ["python3 $SKILL/scripts/field-level-compare.py --captures-dir <run>/field-captures "
                 "--rules <生成件>/compare-rules.json --outdir /tmp/refc"]),
    "evidence": ("按契约 gates[].evidence_schema 重打证据（gen-gate-report 骨架 → 填真值 → sha → "
                 "pipeline --gate-evidence 原子注入）",
                 ["python3 $SKILL/scripts/gate-evidence-check.py <gates> <health> <契约> <证据> <项目根>"]),
    "unknown": ("人工归因（把原因贴给执行 agent 分析）", []),
}


def _domain(text: str) -> str:
    t = str(text)
    for dom, kws in _DOMAIN_RULES:
        if any(k.lower() in t.lower() for k in kws):
            return dom
    return "unknown"


def _load(d: Path, name: str):
    try:
        return json.loads((d / name).read_text(encoding="utf-8"))
    except Exception:
        return None


def main() -> int:
    ap = argparse.ArgumentParser(prog="rerun-plan.py", description="从 BLOCKED/FAIL run 生成重跑计划")
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--contract", default="", help="契约路径（提供则计划附立契校验命令）")
    ap.add_argument("--overwrite", action="store_true")
    a = ap.parse_args()
    d = Path(a.run_dir)
    summary = _load(d, "summary.json")
    if not isinstance(summary, dict):
        print("⛔ 缺 summary.json（无结论不生成重跑计划）", file=sys.stderr)
        return 2
    rid = str(summary.get("run_id") or d.name)
    cases = _load(d, "case-results.json") or []
    fc = _load(d, "field-compare.json") or {}
    gates = _load(d, "gates.json") or []

    items: list[dict] = []
    for b in summary.get("blocked_reasons") or []:
        dom = _domain(str(b))
        act, cmds = _DOMAIN_ACTIONS[dom]
        items.append({"source": "blocked", "domain": dom, "detail": str(b)[:300],
                      "action": act, "verify": cmds})
    for cid in summary.get("failed_cases") or []:
        reason = next((str(c.get("reason") or "") for c in cases
                       if isinstance(c, dict) and str(c.get("id")) == str(cid)), "")
        dom = _domain(reason or "用例执行失败")
        act, cmds = _DOMAIN_ACTIONS[dom]
        items.append({"source": "failed_case", "domain": dom, "detail": f"用例 {cid} FAIL：{reason[:220]}",
                      "action": act, "verify": cmds})
    for dfc in (summary.get("semantic_diffs") or [])[:20]:
        if isinstance(dfc, dict):
            act, cmds = _DOMAIN_ACTIONS["product"]
            items.append({"source": "semantic_diff", "domain": "product",
                          "detail": f"[{dfc.get('dim')}] {dfc.get('key')}: legacy={dfc.get('legacy')} "
                                    f"current={dfc.get('current')}（{dfc.get('reason')}）",
                          "action": act, "verify": cmds})
    for g in gates:
        if isinstance(g, dict) and g.get("passed") is False and g.get("synthetic") is not True:
            dom = _domain(f"gate {g.get('id')} {g.get('note', '')}")
            act, cmds = _DOMAIN_ACTIONS["evidence"] if dom in ("evidence", "unknown") else (_DOMAIN_ACTIONS[dom])
            items.append({"source": "gate", "domain": "evidence", "detail": f"gate 未过: {g.get('id')}——{g.get('note', '')}",
                          "action": act, "verify": cmds})
    # 只读检查可复用清单（不算执行 PASS——仅为省时间的预检）
    readonly_checks = [
        {"check": "通道配置结构", "cmd": "python3 $SKILL/scripts/legacy-config-check.py --systems-dir $RUNTIME_DIR/systems/api"},
        {"check": "live readiness（按用例就绪度）", "cmd": f"python3 $SKILL/scripts/readiness.py --contract {a.contract or '<契约>'} --systems-dir $RUNTIME_DIR/systems/api --out /tmp/readiness-{rid}"},
        {"check": "数据账本残留项", "cmd": f"python3 $SKILL/scripts/test-data-ledger.py show --run-dir {d}"},
    ]
    plan = {
        "version": VERSION, "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "rerun_of": rid, "source_conclusion": summary.get("conclusion"),
        "new_run_id_required": True,
        "invariant": "账本/结论不可复用：重跑必须全新 run-id 全量执行；只读检查结果可参考，"
                     "绝不拼接不同 run 的执行 PASS 形成正式结论。",
        "items": items,
        "readonly_prechecks": readonly_checks,
        "cmd_template": ("bash $SKILL/scripts/pipeline.sh --contract <契约> "
                         "--scenario-dir <生成件/flowtrace-scenarios> "
                         "--rules <生成件/compare-rules.json>   # 新 run-id 自动生成"),
    }
    out_json = d / "rerun-plan.json"
    out_md = d / "重跑计划.md"
    for f in (out_json, out_md):
        if f.exists() and not a.overwrite:
            print(f"⛔ {f} 已存在（--overwrite 放行）", file=sys.stderr)
            return 2
    out_json.write_text(json.dumps(plan, ensure_ascii=False, indent=2), encoding="utf-8")
    md = [f"# 重跑计划（rerun_of={rid}）", "",
          f"> 源结论 **{summary.get('conclusion')}**；生成 {plan['generated_at']}。",
          f"> **必须新 run-id 全量重跑**；只读预检可参考，绝不拼接历史 PASS。", "",
          f"## 待办 {len(items)} 项（按责任域）", ""]
    order = {"env": 0, "config": 1, "data": 2, "contract": 3, "evidence": 4, "product": 5, "unknown": 9}
    for it in sorted(items, key=lambda x: order.get(x["domain"], 9)):
        md.append(f"### 【{it['domain']}】{it['source']}")
        md.append(f"- 现象：{it['detail']}")
        md.append(f"- 动作：{it['action']}")
        for c in it["verify"]:
            md.append(f"- 验证：`{c}`")
        md.append("")
    md += ["## 重跑前只读预检（可复用，不算执行 PASS）", ""]
    for rc in readonly_checks:
        md.append(f"- {rc['check']}：`{rc['cmd']}`")
    md += ["", "## 重跑命令", "", "```bash", plan["cmd_template"], "```", ""]
    out_md.write_text("\n".join(md), encoding="utf-8")
    print(f"[rerun-plan] {len(items)} 项待办（rerun_of={rid}）→ {out_md}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[rerun-plan] ⛔ 内部异常: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
