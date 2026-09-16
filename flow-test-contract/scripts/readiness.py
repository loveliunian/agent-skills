#!/usr/bin/env python3
"""readiness.py —— 按用例 live readiness 报告（v1.5.0 任务完成门③，只读零副作用）。

现有 precheck 只回答"skill/配置文件是否存在"；本工具回答"现在真的跑，每个 case 会不会
BLOCKED、卡在哪、谁的责任"：
  - 双端 actor：actorMap 登记 + 凭据 env 是否可见（只查存在性，绝不打印值）
  - 发起要素：LAUNCH_ELEMENT_ID_<flow> / launch.elementIdEnv 是否已设
  - 通道配置：systems api 配置结构 + operations schema（复用 legacy-config-check 实查）
  - 契约自洽：reuse 用例是否有消歧选择器；fixture_pair_required 字段是否有配对登记
  - 按钮语义：契约 buttons 声明的节点是否有 api.operations 承载（缺失=预期 BLOCKED 点）
  - gate 证据：--gate-evidence 给出时校验存在+时效（默认 24h）
输出 readiness-report.json + readiness.md（人读：每 case ✅/⚠/❌ + 精确原因 + 责任域
env/config/contract/data/evidence），exit 0=全部就绪 / 1=存在缺口 / 2=工具自身错误。
只读承诺：不登录、不发业务请求、不写 run 目录（产物只落 --out）。
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_SCRIPT_DIR))
sys.dont_write_bytecode = True

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：uv run --with pyyaml python3 readiness.py …")

import ftc_env  # noqa: E402  审计第 9 轮 F9-1：--live-readonly 凭据解析依赖共享模块（单一实现）

VERSION = "readiness.py v1（skill v1.7.2）"
DOMAINS = ("env", "config", "contract", "data", "evidence")


def _now() -> datetime:
    return datetime.now().astimezone()


def _load_yaml(p: Path):
    try:
        return yaml.safe_load(p.read_text(encoding="utf-8")) or {}, None
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"


def _class_domain(text: str) -> str:
    """原因 → 责任域（启发式；readiness 的检查本身已带域标注，此处兜底）。"""
    t = str(text)
    if any(k in t for k in ("凭据", "env", "LAUNCH_ELEMENT", "账号")):
        return "env"
    if any(k in t for k in ("operations", "配置", "systems", "F12", "channel")):
        return "config"
    if any(k in t for k in ("契约", "fixture", "选择器", "case")):
        return "contract"
    if any(k in t for k in ("数据", "数据池", "占用")):
        return "data"
    return "config"


def check_gate_evidence(path: str, max_age_h: float) -> tuple[str, list[str]]:
    """gate 证据存在性 + 时效（只读）；返回 (状态, 问题)。状态: ok|stale|missing|invalid"""
    p = Path(path)
    if not p.is_file():
        return "missing", [f"gate 证据文件不存在: {p}"]
    try:
        items = json.loads(p.read_text(encoding="utf-8"))
        if not isinstance(items, list) or not items:
            return "invalid", ["gate 证据须为非空 JSON 列表"]
    except Exception as e:
        return "invalid", [f"gate 证据不可解析: {e}"]
    probs: list[str] = []
    for e in items:
        if not isinstance(e, dict) or not e.get("id") or not str(e.get("generated_at") or "").strip():
            probs.append(f"{(e or {}).get('id', '?')}: 缺 id/generated_at")
            continue
        try:
            from datetime import timezone
            ga = datetime.fromisoformat(str(e["generated_at"]))
            if ga.tzinfo is None:
                ga = ga.astimezone()
            age = _now() - ga
            if age > timedelta(hours=max_age_h):
                probs.append(f"{e['id']}: 证据已过期（{age.total_seconds()/3600:.1f}h > {max_age_h}h 时效）")
            if ga - timedelta(minutes=5) > _now():
                probs.append(f"{e['id']}: generated_at 在未来（伪造嫌疑）")
        except Exception as ex:
            probs.append(f"{e['id']}: generated_at 不可解析 ({ex})")
    if any("过期" in x or "未来" in x for x in probs):
        return "stale", probs
    return ("ok", probs) if not probs else ("invalid", probs)


def main() -> int:
    ap = argparse.ArgumentParser(prog="readiness.py", description="按用例 live readiness（只读零副作用）")
    ap.add_argument("--contract", required=True)
    ap.add_argument("--systems-dir", required=True, help="systems api 配置目录（legacy.yaml/current.yaml）")
    ap.add_argument("--gate-evidence", default="", help="gate 证据文件（可选；给出则校验存在+时效）")
    ap.add_argument("--live-readonly", action="store_true",
                    help="追加只读活体检查：api 登录+待办计数（GET，不发起实例不提交）——默认关")
    ap.add_argument("--gate-max-age-hours", type=float, default=24.0)
    ap.add_argument("--out", required=True, help="报告输出目录")
    a = ap.parse_args()

    problems_fatal: list[str] = []
    contract, err = _load_yaml(Path(a.contract))
    if err:
        print(f"⛔ 契约不可读: {err}", file=sys.stderr)
        return 2
    meta = contract.get("meta") or {}
    flow_code = str(meta.get("flow_code") or "")
    policy = str(meta.get("instance_policy") or "launch")

    sides: dict[str, dict] = {}
    for side in ("legacy", "current"):
        sp = Path(a.systems_dir) / f"{side}.yaml"
        cfg, e = _load_yaml(sp)
        sides[side] = {"path": str(sp), "cfg": cfg if e is None else None, "err": e}

    # 通道配置结构实查（复用 legacy-config-check，只读）
    cfg_status: dict[str, str] = {}
    for side, info in sides.items():
        if info["err"] is not None:
            cfg_status[side] = "missing"
            continue
        if (info["cfg"] or {}).get("channel") != "api":
            cfg_status[side] = "non-api"
            continue
        r = subprocess.run([sys.executable, str(_SCRIPT_DIR / "legacy-config-check.py"),
                            "--systems", info["path"]], capture_output=True, text=True, timeout=120)
        cfg_status[side] = "ok" if r.returncode == 0 else "invalid"

    # operations 按钮承载面
    ops_buttons: set[str] = set()
    cur_cfg = (sides.get("current") or {}).get("cfg") or {}
    leg_cfg = (sides.get("legacy") or {}).get("cfg") or {}
    for c in (cur_cfg, leg_cfg):
        ops = ((c.get("api") or {}).get("operations") or {})
        if isinstance(ops, dict):
            ops_buttons |= {str(k) for k in ops if isinstance(k, str)}
    default_btn = {str(((c.get("api") or {}).get("submit") or {}).get("defaultButton") or "")
                   for c in (cur_cfg, leg_cfg)}

    # 发起要素
    launch_env_var = f"LAUNCH_ELEMENT_ID_{flow_code}"
    launch_set = bool(os.environ.get(launch_env_var, "").strip())
    for c in (cur_cfg, leg_cfg):
        el_env = str(((c.get("api") or {}).get("launch") or {}).get("elementIdEnv") or "")
        if el_env and os.environ.get(el_env, "").strip():
            launch_set = True

    fx_ids = {f.get("fixture_pair_id") for f in (contract.get("fixtures") or []) if isinstance(f, dict)}
    btn_nodes = [str(b.get("node")) for b in (contract.get("buttons") or [])
                 if isinstance(b, dict) and b.get("node")]

    gate_status, gate_probs = ("not_provided", [])
    if a.gate_evidence:
        gate_status, gate_probs = check_gate_evidence(a.gate_evidence, a.gate_max_age_hours)

    cases_out: list[dict] = []
    for case in contract.get("cases") or []:
        if not isinstance(case, dict) or not case.get("id"):
            continue
        cid = str(case["id"])
        items: list[dict] = []
        # actor/凭据（env 域）
        for st in case.get("steps") or []:
            actor = str((st or {}).get("actor") or "").strip()
            if not actor:
                continue
            for side, info in sides.items():
                amap = ((info.get("cfg") or {}).get("actorMap") or {}).get(actor)
                if amap is None:
                    if info["cfg"] is not None:
                        items.append({"case": cid, "ok": False, "domain": "config",
                                      "check": f"actor[{side}]",
                                      "detail": f"actor {actor!r} 不在 {side}.yaml actorMap"})
                    continue
                for kind in ("username", "password"):
                    ev = str((amap or {}).get(kind) or "")
                    if ev and not os.environ.get(ev, "").strip():
                        items.append({"case": cid, "ok": False, "domain": "env",
                                      "check": f"credential[{side}.{actor}.{kind}]",
                                      "detail": f"env {ev} 未设置（$RUNTIME_DIR/env 或显式导出）"})
        # 发起要素（env 域）
        if not launch_set:
            items.append({"case": cid, "ok": False, "domain": "env", "check": "launch-element",
                          "detail": f"{launch_env_var} 未设置（或 launch.elementIdEnv 指向的 env 未设）"})
        # 通道配置（config 域）
        for side in ("legacy", "current"):
            if cfg_status.get(side) != "ok":
                items.append({"case": cid, "ok": False, "domain": "config",
                              "check": f"systems[{side}]",
                              "detail": f"{side}.yaml {cfg_status.get(side)}（跑 legacy-config-check 看待录清单）"})
        # reuse 选择器（contract 域）
        if policy == "reuse":
            has_sel = any(str(case.get(k) or "").strip() or isinstance(case.get(k), dict)
                          for k in ("instanceNo", "businessKey", "fixtureSelector"))
            if not has_sel:
                items.append({"case": cid, "ok": False, "domain": "contract", "check": "reuse-selector",
                              "detail": "instance_policy=reuse 但用例未声明任何消歧选择器——多候选即 BLOCKED"})
        # fixture（data 域）
        if case.get("needs_fixture") and not fx_ids:
            items.append({"case": cid, "ok": False, "domain": "data", "check": "fixture",
                          "detail": "用例标注 needs_fixture 但契约 fixtures 为空"})
        # 按钮承载（config 域——buttons 声明的节点缺 operations/默认按钮承载时预警）
        for st in case.get("steps") or []:
            btn = str((st or {}).get("button") or "").strip()
            if btn and btn not in ops_buttons and btn not in default_btn - {""}:
                items.append({"case": cid, "ok": False, "domain": "config", "check": f"button[{btn}]",
                              "detail": f"step.button {btn!r} 未被 api.operations/submit.defaultButton 承载"
                                        f"——该步预期 BLOCKED（配 operations 或走浏览器通道）"})
        cases_out.append({"case": cid, "ready": all(i["ok"] for i in items) if items else True,
                          "items": items})

    # 汇总（case 级 + 全局级）
    global_items: list[dict] = []
    if not flow_code:
        global_items.append({"case": "-", "ok": False, "ready": False, "domain": "contract",
                             "check": "flow_code", "detail": "契约缺 meta.flow_code", "items": []})
    if gate_status != "ok":
        sev = {"not_provided": "⚠ 未提供 gate 证据（正式 run 前须经 pipeline --gate-evidence 注入）",
               "missing": "gate 证据文件不存在",
               "stale": "gate 证据过期/未来时间戳",
               "invalid": "gate 证据结构非法"}.get(gate_status, gate_status)
        global_items.append({"case": "-", "ok": gate_status == "not_provided",
                             "ready": gate_status == "not_provided", "domain": "evidence",
                             "check": "gate-evidence", "items": [],
                             "detail": sev + ("；".join(gate_probs) if gate_probs else "")})
    for gi in global_items:
        cases_out.insert(0, gi)

    # ── v1.6.0 任务可完成 readiness：static_ready（配置/环境） vs task_ready（+覆盖/证据/浏览器） ──
    static_ready = all(c["ready"] for c in cases_out)
    task_items: list[dict] = []
    cov_info = {"declared": False, "conclusion_scope": "contract_scope_only"}
    cm_decl = (contract.get("meta") or {}).get("coverage_manifest")
    if cm_decl:
        try:
            import coverage_manifest as _cm
            _mp = cm_decl.get("path") if isinstance(cm_decl, dict) else cm_decl
            _m, _err = (None, "path 非法")
            if isinstance(_mp, str) and _mp.strip():
                _m, _err = _cm.load_manifest_for_contract(a.contract, _mp)
            if _err:
                task_items.append({"domain": "coverage", "check": "manifest",
                                   "detail": f"覆盖账本不可用: {_err}"})
            else:
                _probs = _cm.validate(_m, contract=contract)
                if _probs:
                    task_items.append({"domain": "coverage", "check": "manifest",
                                       "detail": "覆盖账本深度校验非法: " + "; ".join(_probs[:3])})
                else:
                    _summ = _cm.summarize(_m)
                    cov_info = {"declared": True, **_summ}
                    for st, ids in (_summ.get("blocking_by_status") or {}).items():
                        task_items.append({"domain": "coverage", "check": f"must-cover[{st}]",
                                           "detail": f"{len(ids)} 项未闭环: {ids[:8]}"})
        except Exception as e:
            task_items.append({"domain": "coverage", "check": "manifest",
                               "detail": f"覆盖账本评估异常: {type(e).__name__}: {e}"})
    # v1.7.0：数据租约冲突探针（跨 run registry——并行 run 占用同一 fixture/resource = 任务缺口）
    try:
        import importlib.util as _ilt
        _spec_tl = _ilt.spec_from_file_location("ftc_tdl_rd", _SCRIPT_DIR / "test-data-ledger.py")
        _tdl = _ilt.module_from_spec(_spec_tl)
        _spec_tl.loader.exec_module(_tdl)
        _reg = _tdl._registry_read()
        _want_ids = {str(f.get("fixture_pair_id")) for f in (contract.get("fixtures") or []) if isinstance(f, dict)}
        _want_ids |= {str(r.get("id")) for r in (contract.get("resources") or []) if isinstance(r, dict)}
        _now_dt = _now()
        for e in _reg:
            try:
                exp = datetime.fromisoformat(str(e.get("expires_at")))
            except Exception:
                continue
            if str(e.get("id")) in _want_ids and exp > _now_dt:
                task_items.append({"domain": "data", "check": f"lease[{e.get('id')}]",
                                   "detail": f"测试数据正被其他 run 租约占用（owner={e.get('owner')}，"
                                             f"至 {e.get('expires_at')}）——并行执行将互相污染"})
    except Exception:
        pass  # 探针自身不可用不阻断（registry 属辅助治理面）
    # gate 证据是否确实需要（契约 gates 带 evidence_schema 即需要）
    gates_need_evidence = any(isinstance(g, dict) and g.get("evidence_schema")
                              for g in (contract.get("gates") or []))
    if gates_need_evidence and gate_status != "ok":
        task_items.append({"domain": "evidence", "check": "gate-evidence-required",
                           "detail": f"契约 gates 声明 evidence_schema——正式 run 需要 gate 证据"
                                     f"（当前 {gate_status}；经 pipeline --gate-evidence 注入）"})
    # 浏览器承载（契约按钮断言或覆盖账本 browser 要素 → 需要可用 browser 配置）
    _browser_needed = bool([b for b in (contract.get("buttons") or [])
                            if isinstance(b, dict) and b.get("node")])
    if cm_decl:
        try:
            import coverage_manifest as _cm2
            _mp2 = cm_decl.get("path") if isinstance(cm_decl, dict) else cm_decl
            _m2, _ = _cm2.load_manifest_for_contract(a.contract, _mp2) if _mp2 else (None, None)
            if isinstance(_m2, dict):
                _browser_needed = _browser_needed or any(
                    e.get("channel") in ("browser", "both") for e in (_m2.get("elements") or []))
        except Exception:
            pass
    if _browser_needed:
        # runtime 根解析复用 run-contract-scenarios（连字符文件名——importlib 加载，单一实现）
        try:
            import importlib.util as _ilr
            _spec_rcs = _ilr.spec_from_file_location("ftc_rcs_rd", _SCRIPT_DIR / "run-contract-scenarios.py")
            _rcs = _ilr.module_from_spec(_spec_rcs)
            _spec_rcs.loader.exec_module(_rcs)
            _rt = _rcs.runtime_root()
        except Exception as e:
            _rt = None
            task_items.append({"domain": "config", "check": "browser-config",
                               "detail": f"runtime 根解析失败: {type(e).__name__}: {e}"})
        _bdir = Path(os.environ.get("FLOWTEST_SYSTEMS_BROWSER_DIR",
                                    str(_rt / "systems" / "browser"))) if _rt else None
        _bfiles = [x for x in ([_bdir / f"{y}.yaml" for y in ("legacy", "current")] if _bdir else [])]
        _missing = [str(x) for x in _bfiles if not x.is_file()]
        _placeholder = [str(x) for x in _bfiles if x.is_file()
                        and "__UI_RECORD__" in x.read_text(encoding="utf-8")]
        if _missing:
            task_items.append({"domain": "config", "check": "browser-config",
                               "detail": f"浏览器断言/要素需要 browser 通道，配置缺失: {_missing}"})
        if _placeholder:
            task_items.append({"domain": "config", "check": "browser-config",
                               "detail": f"browser 配置仍含 __UI_RECORD__ 占位（待 UI 录制）: {_placeholder}"
                                         "——explore-browser 探索 + 人工核对可收敛"})
    # --live-readonly：api 登录+待办计数（GET 只读；不发起实例不提交）
    live_results: list[dict] = []
    if a.live_readonly:
        import importlib.util as _ilu
        _spec = _ilu.spec_from_file_location("ftc_ac_rd", _SCRIPT_DIR / "api-capture.py")
        _ac = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(_ac)
        for side, info in sides.items():
            cfgd = info.get("cfg")
            if not isinstance(cfgd, dict):
                continue
            api_cfgd = cfgd.get("api") or {}
            for actor, amap in (cfgd.get("actorMap") or {}).items():
                row = {"side": side, "actor": actor, "ok": False, "todo_count": None, "detail": ""}
                try:
                    user, pwd = ftc_env.resolve_credentials(
                        a.systems_dir, str(actor), str((amap or {}).get("username") or ""),
                        str((amap or {}).get("password") or ""), warn=lambda m: None)
                    _api = _ac.Api(api_cfgd)
                    _tok = _api.login(str(actor), user, pwd)
                    _tasks = _api.todo_tasks(_tok, str(actor))
                    row.update(ok=True, todo_count=len(_tasks) if isinstance(_tasks, list) else None)
                except SystemExit:
                    row["detail"] = "凭据/配置拒绝（见 stderr）"
                except Exception as e:
                    row["detail"] = f"{type(e).__name__}: {e}"[:160]
                if not row["ok"]:
                    task_items.append({"domain": "env", "check": f"live[{side}.{actor}]",
                                       "detail": row["detail"] or "只读活体检查失败"})
                live_results.append(row)

    task_ready = static_ready and not task_items
    report = {
        "version": VERSION, "generated_at": _now().isoformat(timespec="seconds"),
        "contract": str(a.contract), "flow_code": flow_code, "instance_policy": policy,
        "systems": {s: {"path": i["path"], "status": cfg_status.get(s)} for s, i in sides.items()},
        "gate_evidence": {"path": a.gate_evidence or None, "status": gate_status,
                          "problems": gate_probs, "required_by_contract": gates_need_evidence},
        "coverage": cov_info,
        "live_readonly": live_results if a.live_readonly else None,
        "cases": cases_out,
        "task_items": task_items,
        "static_ready": static_ready,
        "task_ready": task_ready,
        "all_ready": task_ready,
    }
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "readiness-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    md = [f"# Live Readiness 报告（{flow_code or '未命名流程'}）", "",
          f"- 生成：{report['generated_at']}　模式：**只读**（未登录、零业务请求、零 run 目录写入）",
          f"- 通道配置：{'；'.join(f'{s}={cfg_status.get(s)}' for s in ('legacy', 'current'))}"
          f"　发起要素：{'已设' if launch_set else '⚠ 未设'}　gate 证据：{gate_status}", "",
          "| 用例 | 就绪 | 缺口（责任域 · 检查 · 说明） |", "|---|---|---|"]
    blocked = 0
    for c in cases_out:
        if c["ready"] and not c["items"]:
            md.append(f"| {c['case']} | ✅ | — |")
            continue
        if not c["ready"]:
            blocked += 1
        rows = "；".join(f"【{i['domain']}】{i['check']}：{i['detail']}" for i in c["items"])
        md.append(f"| {c['case']} | {'✅' if c['ready'] else '❌'} | {rows or '—'} |")
    md += ["", "> 责任域：env=环境/凭据/要素ID　config=systems 通道配置　contract=契约声明　"
               "data=测试数据　evidence=gate 证据　coverage=覆盖账本。", ""]
    md += [f"## 任务级判定（task_ready）", "",
           f"- static_ready：**{'是' if static_ready else '否'}**（上表：配置/环境/契约静态就绪）",
           f"- task_ready：**{'是' if task_ready else '否'}**（另计覆盖账本闭环/gate 证据需求/浏览器承载/活体检查）", ""]
    if task_items:
        md += ["| 任务级缺口 | 责任域 | 检查 | 说明 |", "|---|---|---|---|"]
        md += [f"| | {t['domain']} | {t['check']} | {t['detail']} |" for t in task_items]
        md.append("")
    if live_results:
        md += ["## 只读活体检查（--live-readonly；GET 类，不发起实例）", ""]
        md += ["| 侧 | 账号 | 结果 | 待办数 | 说明 |", "|---|---|---|---|---|"]
        md += [f"| {r['side']} | {r['actor']} | {'✅' if r['ok'] else '❌'} | {r.get('todo_count') if r.get('todo_count') is not None else '—'} | {r.get('detail', '')} |"
               for r in live_results]
        md.append("")
    (out / "readiness.md").write_text("\n".join(md), encoding="utf-8")
    print(f"[readiness] static={'就绪' if static_ready else '缺口'} "
          f"task={'就绪' if task_ready else f'{len(task_items)} 项缺口'} → {out / 'readiness.md'}")
    if not static_ready:
        return 1
    return 0 if task_ready else 3


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[readiness] ⛔ 内部异常: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
