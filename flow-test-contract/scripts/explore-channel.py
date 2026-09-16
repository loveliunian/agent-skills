#!/usr/bin/env python3
"""explore-channel.py v1 —— 首次对比前的自由探索器（v1.4.0 新增）。

解决"初次对比一个流程、契约还没立起来"的冷启动问题：在正式立契/执行之前，先对双端做
**自由探索**，把"点击（按钮）、选择（路由候选+办理人候选）、填写（表单字段与值）、
公式计算（探针值→读回计算值）"四类过程经验如实采集下来，产出机器+人读双格式经验产物；
再用 merge 把双端对齐成经验库（experience.yaml）与立契建议——让后续的立契与双端对比
有据可依，而不是纯手工盲录。

定位与铁律（与 skill 既有哲学一致）：
  - **探索产物是第四取证源（参考物），不是结论源**：探索永不产出 PASS/FAIL；
    契约仍须按取证三源人工立契并过 validate --level test_ready 才能正式执行。
  - **实例隔离与 api-capture 同律**：launch-first 发起本流程新实例，每步绑定 instance_no，
    绝不碰他流程/他实例的真实任务（复用 api-capture.py 的 Api 唯一实现，禁止另写一套 HTTP 逻辑）。
  - **写操作显式门槛**：探索默认只读（--observe-only：登录+待办观察）；要发起实例并推进
    必须显式 --apply（写影响=与一次正式 run 同级：登录/发起/逐环节提交，只碰自己发起的实例）；
    公式探针（--fill）再显式开启（向表单填探针值并预保存）。
  - **fail-closed 但探索可中断**：配置/凭据/launch 失败 → exit 2（零产物）；
    探索中途走不通（无路由/无候选办理人/下一任务在别人名下）→ 如实记录中断原因后
    exit 0——探索的价值恰在发现"哪里走不通"。
    用户 Ctrl+C 中断 → 已采集经验照常落盘后 exit 130。
  - 凭据零明文：只从 actorMap 指定的环境变量读（ftc_env 唯一实现）；日志零请求体。

用法（由 agent 在项目根执行；双端各跑一次 explore，再跑一次 merge）:
  # 1) 只读观察（默认安全模式：不发起实例）
  python3 explore-channel.py explore --systems <runtime>/systems/api/legacy.yaml \
      --flow <流程编码> --outdir docs/<流程>/自动化测试/探索/<explore-id> --observe-only

  # 2) 写探索（发起实例+逐环节推进；--fill 再开公式探针）
  python3 explore-channel.py explore --systems <runtime>/systems/api/current.yaml \
      --flow <流程编码> --outdir docs/<流程>/自动化测试/探索/<explore-id> --apply --fill \
      [--max-steps 12] [--advance first|none] [--actor admin] [--form-data '{"字段":"值"}']

  # 3) 双端经验合并（同一 outdir 下须已有 explore-legacy.json + explore-current.json）
  python3 explore-channel.py merge --explore-dir docs/<流程>/自动化测试/探索/<explore-id>

产出（全部落 --outdir / --explore-dir）:
  explore-legacy.json / explore-current.json   单端探索实录（机器，含 instance_no 可追溯）
  探索发现-legacy.md / 探索发现-current.md     单端人读版（每节点：字段/按钮/路由/候选/探针）
  experience.yaml                              双端对齐经验库（含 field_mapping_candidates + contract_suggestions）
  立契建议.md                                  人读版经验对照与建议（契约仍须人工立契）
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_SCRIPT_DIR))

sys.dont_write_bytecode = True   # 审计 P1-3：动态加载共享库时零字节码（skill 目录零副作用）
import ftc_env  # noqa: E402  凭据解析唯一实现
import ftc_ops_config  # noqa: E402  operations schema 唯一校验实现

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：uv run --with pyyaml python3 explore-channel.py …")


def _load_api_capture():
    """复用 api-capture.py 的 Api/原语（launch-first/实例隔离/选人解析/账本——单一实现）。"""
    spec = importlib.util.spec_from_file_location("ftc_api_capture_for_explore", _SCRIPT_DIR / "api-capture.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("ftc_api_capture_for_explore", mod)
    spec.loader.exec_module(mod)
    return mod


ac = _load_api_capture()
Api, die = ac.Api, ac.die
subst, drop_empty, dig = ac.subst, ac.drop_empty, ac.dig

VERSION = "explore-channel.py v1（skill v1.7.2）"

# 公式探针候选字段的排除启发式：名称像日期/编号/单号/ID/电话的字符串字段不填
_PROBE_EXCLUDE_RE = re.compile(
    r"(日期|时间|编号|单号|证号|code|no$|_id$|id$|date|time|phone|mobile|电话|手机|备注|remark)", re.I)


def _now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _sha16(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()[:16]


def _norm_field(s) -> str:
    """字段名归一化（merge 映射候选用）：去空白/_/-、小写。"""
    return re.sub(r"[\s_\-]+", "", str(s or "")).lower()


def _load_systems(systems: str) -> tuple[dict, str, dict]:
    """systems api 配置加载与前置校验（与 api-capture 同律：占位/channel/operations）。"""
    try:
        cfg = yaml.safe_load(Path(systems).read_text(encoding="utf-8")) or {}
    except Exception as e:
        die(f"systems 配置不可读 {systems}: {e}")
    if not isinstance(cfg, dict):
        die(f"systems 配置须为 YAML 对象: {systems}")
    side = str(cfg.get("id") or "").strip()
    if not side:
        die(f"systems 配置缺 id（侧名）: {systems}")
    if cfg.get("channel") != "api":
        die(f"channel={cfg.get('channel')!r} 非 api——探索器只支持 api 通道（浏览器探索另行录制）")
    if ac._contains_placeholder(cfg):
        die(f"systems 配置含 __F12_RECORD__ 占位（端点未录完）——先按 references/f12-record.md 录端点")
    api_cfg = cfg.get("api")
    if not isinstance(api_cfg, dict):
        die("systems 配置缺 api 块")
    probs = ftc_ops_config.validate_operations(api_cfg.get("operations"))
    if probs:
        die("systems api.operations 配置非法：\n  - " + "\n  - ".join(probs))
    actors = cfg.get("actorMap")
    if not isinstance(actors, dict) or not actors:
        die("systems 配置缺 actorMap")
    return cfg, side, api_cfg


def _login(cfg: dict, systems: str, actor: str):
    actors = cfg["actorMap"]
    amap = actors.get(actor)
    if not isinstance(amap, dict):
        die(f"actor {actor!r} 不在 actorMap——可用: {sorted(actors)}")
    try:
        username, password = ftc_env.resolve_credentials(
            systems, actor, str(amap.get("username") or ""), str(amap.get("password") or ""),
            warn=lambda m: print(f"[explore] {m}"))
    except ftc_env.CredentialError as e:
        die(str(e))
    return username, password


def _config_buttons(api_cfg: dict) -> list[str]:
    """点击经验（配置已知面）：默认提交按钮 + 预保存按钮 + operations 按钮语义 + retryOn 前置按钮。"""
    sm = api_cfg.get("submit") or {}
    out: list[str] = []
    for v in (sm.get("defaultButton"), sm.get("save_with_form_data")):
        if v:
            out.append(str(v))
    ops = api_cfg.get("operations")
    if isinstance(ops, dict):
        out.extend(str(k) for k in ops)
    ro = sm.get("retryOn") or {}
    rules = ro if isinstance(ro, list) else ([ro] if isinstance(ro, dict) else [])
    for r in rules:
        if isinstance(r, dict) and r.get("preButton"):
            out.append(str(r["preButton"]))
    return sorted(set(out))


def _discover_routes(api, api_cfg: dict, token: str, task_id: str) -> tuple[list[dict], list]:
    """选择经验①——路由候选发现：workbench nextNodes（resolver=next-assignees 时）
    + 表单响应声明的 nextStep（form.nextStepPath，多候选逗号拆开）。
    全部来自被测系统实时响应，零编造；都取不到=如实为空（经验库里记 needs_human）。"""
    routes: list[dict] = []
    asg = api_cfg.get("assignee") or {}
    wb_nodes: list = []
    if str(asg.get("resolver") or "") == "next-assignees":
        wb_path = subst(str(asg.get("workbenchPath", "/engine/flow/task/${TASK_ID}/workbench")), {"TASK_ID": task_id})
        st, wb, _h, _t = api.call_full("GET", wb_path, token=token)
        if st == 200 and isinstance(wb, dict):
            try:
                wb_nodes = dig(wb, str(asg.get("nextNodesPath", "data.nextNodes"))) or []
            except KeyError:
                wb_nodes = []
            if not isinstance(wb_nodes, list):
                wb_nodes = []
            for nd in wb_nodes:
                if isinstance(nd, dict):
                    code = str(nd.get("routeCode") or nd.get(str(asg.get("nodeCodeField", "taskElementId"))) or "")
                    nm = str(nd.get("nodeName") or nd.get("name") or "")
                    if code:
                        routes.append({"node": code, "source": "workbench.nextNodes", "note": nm})
    declared = str((api.task_meta.get(task_id) or {}).get("nextStep") or "")
    if declared:
        seen = {r["node"] for r in routes}
        for part in (x.strip() for x in declared.split(",")):
            if part and part not in seen:
                routes.append({"node": part, "source": "form.nextStepPath", "note": "服务端表单声明"})
                seen.add(part)
    return routes, wb_nodes


def _candidate_names(api, api_cfg: dict, token: str, task_id: str, ctx: dict) -> list[str]:
    """选择经验②——下一环节办理人候选姓名（assignee 解析器配置时；取不到=空）。"""
    asg = api_cfg.get("assignee") or {}
    if not str(asg.get("resolver") or ""):
        return []
    try:
        rows, _wb, _node = api.assignee_candidates(token, task_id, ctx)
    except SystemExit:
        raise
    except Exception:
        return []
    if not isinstance(rows, list):
        return []
    nf = str(asg.get("nameField", "name"))
    return [str(r[nf]) for r in rows if isinstance(r, dict) and r.get(nf) is not None]


def _is_num(v) -> bool:
    try:
        float(str(v).replace(",", "").strip())
        return True
    except Exception:
        return False


def _probe_formula(api, api_cfg: dict, token: str, task_id: str, fields: dict, ctx: dict) -> dict:
    """公式计算经验——探针法：向最多 2 个可写数值字段填探针值 → 预保存 → 读回表单 →
    记录"除探针字段外变化的字段"=公式输出候选。只探不判：字段是否真是公式、公式是否
    双端同律，由人工/契约 formulas 断言判定。需要 submit.save_with_form_data 配置
    （先保存才读得到计算值——老系统独立保存接口的系统则暂不支持，如实记录）。
    ctx 须含调用方的实例上下文（INSTANCE_NO/FLOW_CODE/NODE 等）——保存请求体模板
    ${VAR} 全部由此解析，残缺 ctx 会静默发出缺键请求（如 legacy WorkflowFlag）。"""
    sm = api_cfg.get("submit") or {}
    save_btn = str(sm.get("save_with_form_data") or "")
    if not save_btn:
        return {"skipped": "submit.save_with_form_data 未配置——公式探针需要先保存表单才能读回计算值"}
    cands = [k for k, v in (fields or {}).items()
             if isinstance(k, str) and k
             and not _PROBE_EXCLUDE_RE.search(k)
             and (v in (None, "") or (isinstance(v, (int, float)) and not isinstance(v, bool)) or _is_num(v))]
    if not cands:
        return {"skipped": "未找到可填写的数值候选字段（全为日期/编号/文本类）"}
    probes = {k: "100" for k in cands[:2]}   # 最多探 2 个字段——控制写影响面
    path = subst(str(sm.get("path", "")), {"TASK_ID": task_id})
    body = drop_empty(subst(sm.get("body") or {}, {**ctx, "TASK_ID": task_id}))
    body.pop("nextAssigneeId", None)
    body["buttonCode"] = save_btn
    body["formData"] = probes
    st, obj, _h, _t = api.call_full(str(sm.get("method", "POST")), path, body=body, token=token)
    ok_codes = [int(x) for x in (sm.get("successStatus") or [200, 201])]
    if st not in ok_codes or (isinstance(obj, dict) and obj.get("success") is False):
        return {"skipped": f"探针预保存失败: HTTP {st} {path}（不重试不推进——公式经验缺失，其余经验不受影响）"}
    try:
        # 审计第 5 轮 P1-2：读回必须携实例/流程上下文——带 WorkflowFlag/流程身份字段的系统
        # 缺参会导致读回失败或读错上下文（与标准执行路径同参）
        after = api.form_fields(token, task_id,
                                instance_no=str(ctx.get("INSTANCE_NO") or ""),
                                flow_code=str(ctx.get("FLOW_CODE") or ""))
    except SystemExit:
        raise
    except Exception as e:
        return {"skipped": f"探针后读回表单失败: {type(e).__name__}: {e}"}
    changed: dict = {}
    system_fields: dict = {}
    for k, v2 in after.items():
        if k in probes:
            continue
        v1 = (fields or {}).get(k)
        if str(v1) != str(v2) and v2 not in (None, ""):
            # F7：更新时间/最后修改人类系统维护字段会被保存动作本身更新——单独列出，
            # 不冒充公式输出候选
            (system_fields if _PROBE_EXCLUDE_RE.search(str(k)) else changed)[str(k)] = {
                "before": v1, "after": v2}
    out = {"inputs": probes,
           "outputs_candidates": changed,
           "system_field_changes": system_fields,
           "note": "outputs_candidates=探针填值并保存后发生变化的字段（公式输出候选，须人工确认）"}
    if not changed:
        out["note"] += "——本次探针未观察到字段变化（可能字段全只读/公式由服务端另算/保存接口不同步表单）"
    return out


def _observe_only(api, side: str, api_cfg: dict, token: str, actor: str, flow_code: str,
                  outdir: Path, explore_id: str) -> int:
    """只读观察：登录 + 待办清单结构观察（不发起实例、不读他实例表单、不提交）。"""
    td = api_cfg.get("todo") or {}
    fc_path = str(td.get("flowCodePath") or "flowCode")
    node_path = str(td.get("nodePath") or "stepCode")
    tasks = api.todo_tasks(token, actor)
    rows = [t for t in tasks if isinstance(t, dict)]
    nodes: dict[str, int] = {}
    matched = 0
    other_flows: set[str] = set()
    for t in rows:
        try:
            fc = str(dig(t, fc_path))
        except KeyError:
            fc = "?"
        if fc == flow_code:
            matched += 1
            try:
                nd = str(dig(t, node_path))
            except KeyError:
                nd = "?"
            nodes[nd] = nodes.get(nd, 0) + 1
        else:
            other_flows.add(fc)
    data = {
        "version": VERSION, "explore_id": explore_id, "mode": "observe_only",
        "flow_code": flow_code, "side": side, "actor": actor, "created_at": _now_iso(),
        "todo_total": len(rows), "flow_matching": matched, "flow_nodes": dict(sorted(nodes.items())),
        "other_flows_count": len(other_flows),
        "note": "只读观察：未发起实例、未读表单、未提交；要收集填写/公式经验请用 --apply 写探索",
    }
    outdir.mkdir(parents=True, exist_ok=True)
    jf = outdir / f"explore-{side}.json"
    jf.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    md = [f"# 探索发现（{side} 侧·只读观察）", "",
          f"- 流程 {flow_code}：当前账号待办共 {len(rows)} 条，其中本流程 {matched} 条"
          f"（节点分布：{data['flow_nodes'] or '无'}）；他流程 {len(other_flows)} 个。",
          f"- 这是**只读观察**：没有发起实例，收集不到表单/公式经验。要真正探索流程内部，",
          f"  加 `--apply` 做写探索（影响面=与一次正式 run 同级，只碰自己发起的实例）。", ""]
    (outdir / f"探索发现-{side}.md").write_text("\n".join(md), encoding="utf-8")
    print(f"[explore] observe-only 完成：本流程待办 {matched}/{len(rows)} → {jf}")
    return 0


def cmd_explore(a) -> int:
    cfg, side, api_cfg = _load_systems(a.systems)
    flow_code = str(a.flow or "").strip()
    if not flow_code:
        die("缺 --flow <流程编码>（探索必须绑定流程身份）")
    # 写门槛前置（在任何登录/网络动作之前——fail-closed 的顺序也必须 fail-closed）：
    # 探索默认只读；要发起实例并推进必须显式 --apply；只读观察显式 --observe-only
    if a.observe_only and a.fill:
        die("--observe-only（只读）与 --fill（公式探针=写操作）互斥——探针须随 --apply 写探索使用")
    if not a.apply and not a.observe_only:
        die("写探索会发起本流程新实例并逐环节提交（写影响=与一次正式 run 同级）——必须显式 --apply；"
            "只读观察加 --observe-only（登录+待办结构，零写操作）")
    # 审计第 5 轮 P0-2：写探索必须显式 --actor（写操作须可追溯账号；只读观察可缺省）
    if a.apply and not str(a.actor or "").strip():
        die("--apply 写探索必须显式 --actor <账号>（写操作可追溯；缺省会静默取 actorMap 第一个，拒绝）")
    outdir = Path(a.outdir)
    explore_id = a.explore_id or outdir.name or f"explore-{time.strftime('%Y%m%d%H%M%S')}"
    # 审计第 5 轮 IM1：产物防静默覆盖——**本侧**实录已存在即拒（双端共用同一 outdir 是设计；
    # 实例号/人工核验痕迹不可丢）
    existing_side = [q.name for q in (outdir / f"explore-{side}.json", outdir / f"探索发现-{side}.md")
                     if q.exists()]
    if existing_side and not a.overwrite:
        die(f"本侧探索产物已存在（{existing_side}）——默认拒绝覆盖（防丢实例号与人工核验痕迹）；"
            f"确需重探加 --overwrite 或换新 --outdir")
    if a.include_values:
        print("[explore] ⚠ --include-values：产物将包含表单**原始值**（含潜在敏感数据）——"
              "请将产物放私有 runtime 目录（勿提交/勿同步）；默认行为是脱敏为 #sha16:长度")
    actor = str(a.actor or next(iter(cfg["actorMap"])))
    api = Api(api_cfg)
    td = api_cfg.get("todo") or {}
    wait_s = int(api_cfg.get("taskWaitSeconds", 15))

    username, password = _login(cfg, a.systems, actor)
    token = api.login(actor, username, password)

    if a.observe_only:
        return _observe_only(api, side, api_cfg, token, actor, flow_code, outdir, explore_id)

    # —— 写探索（launch-first + 逐环节推进）——
    try:
        form_data_user = json.loads(a.form_data) if a.form_data else {}
        if not isinstance(form_data_user, dict):
            die("--form-data 须为 JSON 对象")
    except json.JSONDecodeError as e:
        die(f"--form-data 不是合法 JSON: {e}")

    instance_no, task_id = api.launch(token, {"USERNAME": username, "PASSWORD": password}, flow_code)
    if (td.get("mode") == "ledger") and task_id:
        api.ledger_register(task_id, str(td.get("firstNode", "00")),
                            api.actor_display.get(actor, str(actor)), str(instance_no), flow_code)
    print(f"[explore] {side} 实例已发起: {instance_no}（launch-first 实例隔离——只碰本实例）")

    steps: list[dict] = []
    interrupted: str | None = None
    exit_code = 0
    current_node = str(td.get("firstNode", "00"))
    seq = 0
    # 审计 P1-4：循环体任何异常（含通道 die 的 SystemExit）→ 如实中断，已采集经验照常落盘
    # （exit 2 仅保留给配置/凭据/launch 失败——与 docstring/exploration.md 口径一致）
    try:
        while seq < a.max_steps:
            seq += 1
            if task_id is None:
                task = api.find_task(token, current_node, wait_s, instance_no, flow_code, actor=actor)
                if task is None:
                    interrupted = f"第 {seq} 步在实例 {instance_no} 中找不到节点 {current_node} 的任务——探索中断"
                    break
                task_id = str(dig(task, td.get("taskIdPath", "taskId")))
            fields = api.form_fields(token, task_id, instance_no=instance_no or "", flow_code=flow_code)
            meta = api.task_meta.get(task_id) or {}
            node_here = str(meta.get("node") or current_node)
            routes, _wb = _discover_routes(api, api_cfg, token, task_id)
            buttons_known = _config_buttons(api_cfg)
            step_notes: list[str] = []

            # 选择经验②：办理人候选（首个路由的候选名单）
            first_route = routes[0]["node"] if routes else ""
            cand_ctx = {"TASK_ID": task_id, "NEXT_NODE": first_route,
                        "INSTANCE_NO": instance_no or "", "FLOW_CODE": flow_code}
            cand_names = _candidate_names(api, api_cfg, token, task_id, cand_ctx)

            # 公式经验：探针（--fill）——ctx 携完整实例上下文（保存请求体模板 ${VAR} 依赖）
            probe = None
            if a.fill:
                _pctx = {"TASK_ID": task_id, "INSTANCE_NO": instance_no or "", "FLOW_CODE": flow_code,
                         "NODE": node_here,
                         "BUTTON": str((api_cfg.get("submit") or {}).get("defaultButton", "提交")),
                         "TODAY": time.strftime("%Y-%m-%d"), "NOW": time.strftime("%Y-%m-%d %H:%M:%S")}
                probe = _probe_formula(api, api_cfg, token, task_id, fields, _pctx)
                if isinstance(probe, dict) and probe.get("skipped"):
                    step_notes.append(f"公式探针未执行：{probe['skipped']}")

            # 审计第 5 轮 P1-1：产物默认脱敏——落盘字段值= #sha16:长度（防敏感值进 docs/共享面）；
            # 原值仅存活于本进程内存（探针/_ECHO_FORM/提交仍用原始 fields）。--include-values 才落原值。
            stored_fields = fields if a.include_values else _redact_fields(fields)
            steps.append({
                "seq": seq, "node": node_here, "task_id": task_id,
                "fields": stored_fields, "field_count": len(fields or {}),
                "buttons_known": buttons_known,
                "routes": routes,
                "assignee_candidates": cand_names,
                "formula_probe": probe,
                "form_data_applied": dict(form_data_user) if form_data_user else None,
                "advanced_to": None,
                "notes": step_notes,
            })
            print(f"[explore] {side} s{seq} 节点{node_here}: 字段 {len(fields or {})}，"
                  f"路由候选 {[r['node'] for r in routes]}，按钮 {buttons_known}"
                  + (f"，公式候选 {len((probe or {}).get('outputs_candidates') or {})} 个" if a.fill else ""))

            # —— 推进（advance=first：走可用路由；none：只探索当前节点【默认】） ——
            # 审计第 5 轮 P0-2：--apply 默认 advance=none——写探索默认只采集不推进；
            # 要自主推进须显式 --advance first。
            if a.advance == "none":
                interrupted = "advance=none（--apply 默认，防非预期流转）：只探索当前节点不提交；要推进显式 --advance first"
                break
            if not routes:
                interrupted = (f"节点 {node_here} 未发现任何路由候选（workbench/表单声明都取不到）——"
                               f"无法自主推进；可配 systems assignee/workbench 或 form.nextStepPath 后重探")
                break
            # 路由：显式 --route 优先（须在候选内——不猜路由）；否则取第一候选
            target = str(a.route or "").strip() or routes[0]["node"]
            if a.route and target not in [r["node"] for r in routes]:
                interrupted = (f"--route {a.route!r} 不在本节点候选 {[r['node'] for r in routes]} 内"
                               f"——拒绝探索性路由（路由须来自被测系统实时候选），探索中断")
                break
            # 办理人：显式 --assignee 优先；否则取第一候选；**都无 = 拒绝空办理人提交**
            # （生产环境空办理人可能触发服务端默认分派→非预期流转，探索前即中断）
            pick = str(a.assignee or "").strip() or (cand_names[0] if cand_names else "")
            if not pick:
                step_notes.append(f"下一环节 {target} 未取得候选办理人且未显式指定 --assignee"
                                  f"——拒绝空办理人提交（防服务端默认分派产生非预期流转），探索在此中断；"
                                  f"确认后可加 --assignee <办理人姓名或ID> 续探")
                interrupted = (f"节点 {node_here} → {target}：无候选办理人且未显式 --assignee"
                               f"——拒绝空办理人提交（api.submit 前中断），探索停止")
                break
            ctx = {
                "USERNAME": username, "PASSWORD": password, "TASK_ID": task_id,
                "INSTANCE_NO": instance_no or "", "NODE": node_here,
                "BUTTON": str((api_cfg.get("submit") or {}).get("defaultButton", "提交")),
                "NEXT_ASSIGNEE": pick,
                "NEXT_NODE": ac.apply_route_map({"nextStep": target}, api_cfg.get("route_map"), flow_code)["nextStep"],
                "_FORM_DATA": dict(form_data_user) if form_data_user else None,
                "_ECHO_FORM": fields if isinstance(fields, dict) else None,
                "FLOW_CODE": flow_code, "_seq": seq,
                "TODAY": time.strftime("%Y-%m-%d"), "NOW": time.strftime("%Y-%m-%d %H:%M:%S"),
            }
            ctx["ASSIGNEE_NAME"] = pick
            uid, matched_name = api.resolve_assignee(token, task_id, pick, ctx) if pick else (None, None)
            if uid is not None:
                ctx["NEXT_ASSIGNEE"] = str(uid)
                if matched_name:
                    ctx["ASSIGNEE_NAME"] = matched_name
            try:
                api.submit(token, task_id, ctx)
            except SystemExit:
                interrupted = (f"节点 {node_here} 提交推进失败（路由 {target}，办理人 {pick or '空'}）——"
                               f"自由探索在此中断（详见上方 api-capture 错误；按钮流等未支持的流转会在此暴露）")
                break
            steps[-1]["advanced_to"] = target
            current_node = target
            task_id = None
            task = api.find_task(token, current_node, wait_s, instance_no, flow_code, actor=actor)
            if task is None:
                interrupted = (f"已在节点 {node_here} 提交推进到 {current_node}，但在账号 {actor} 名下"
                               f"找不到下一步任务——下一办理人可能是别人（用 --actor 指定续探）或流程已办结")
                break
            task_id = str(dig(task, td.get("taskIdPath", "taskId")))

    except SystemExit:
        interrupted = (f"第 {seq + 1} 步通道错误（详见上方 api-capture 错误）——"
                       f"探索中断，已采集 {len(steps)} 步经验照常落盘")
    except Exception as e:  # noqa: BLE001 —— 探索韧性：中途异常不丢已采集经验
        interrupted = (f"第 {seq + 1} 步执行异常（{type(e).__name__}: {e}）——"
                       f"探索中断，已采集 {len(steps)} 步经验照常落盘")
    except KeyboardInterrupt:
        interrupted = f"用户中断（Ctrl+C）——已采集 {len(steps)} 步经验照常落盘"
        exit_code = 130
    if seq >= a.max_steps and interrupted is None:
        interrupted = f"已达 --max-steps={a.max_steps} 上限，主动停止（流程可能未走完——可调大后续探）"

    if not a.include_values:
        steps = [{**st, "formula_probe": _redact_probe(st.get("formula_probe"))} for st in steps]
    data = {
        "version": VERSION, "explore_id": explore_id, "mode": "explore",
        "flow_code": flow_code, "side": side, "actor": actor,
        "instance_no": instance_no, "created_at": _now_iso(),
        "status": "interrupted" if interrupted else "completed",
        "interrupted_reason": interrupted,
        "includes_sensitive_values": bool(a.include_values),
        "options": {"advance": a.advance, "fill": bool(a.fill), "max_steps": a.max_steps,
                    "observe_only": False},
        "steps": steps,
    }
    outdir.mkdir(parents=True, exist_ok=True)
    jf = outdir / f"explore-{side}.json"
    jf.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    _write_explore_md(data, outdir / f"探索发现-{side}.md")
    print(f"[explore] {side} 探索完成（{len(steps)} 步，status={data['status']}）→ {jf}")
    if interrupted:
        print(f"[explore] 中断原因: {interrupted}")
    return exit_code


def _write_explore_md(data: dict, out: Path) -> None:
    md = [f"# 探索发现（{data['side']} 侧·{data['flow_code']}）", "",
          f"- 探索 id：{data['explore_id']}　发起实例：`{data.get('instance_no')}`　账号：{data.get('actor')}",
          f"- 状态：**{data['status']}**" + (f"——{data['interrupted_reason']}" if data.get("interrupted_reason") else ""),
          "- 以下全部为被测系统实时响应的如实记录（自由探索，非正式结论来源）。",
          ("- ⚠ **本产物含表单原始值（--include-values）——放私有 runtime，勿提交/勿同步**"
           if data.get("includes_sensitive_values")
           else "- 字段值已脱敏为 `#sha16:长度`（原值不落盘；--include-values 才保留）"), ""]
    for s in data.get("steps") or []:
        md.append(f"## 第 {s['seq']} 步·节点 {s.get('node')}")
        md.append("")
        if s.get("buttons_known"):
            md.append(f"**可点按钮（配置已知）**：{'、'.join(s['buttons_known'])}")
        if s.get("routes"):
            md.append("")
            md.append("**可去环节（选择）**：" + "；".join(
                f"`{r['node']}`（{r['source']}{('，' + r['note']) if r.get('note') else ''}）" for r in s["routes"]))
        if s.get("assignee_candidates"):
            md.append("")
            md.append(f"**候选办理人**：{'、'.join(s['assignee_candidates'][:10])}"
                      + ("…" if len(s["assignee_candidates"]) > 10 else ""))
        if s.get("advanced_to"):
            md.append("")
            md.append(f"**实际推进**：走 `{s['advanced_to']}`（默认提交按钮）")
        p = s.get("formula_probe")
        if isinstance(p, dict):
            md.append("")
            if p.get("skipped"):
                md.append(f"**公式探针**：未执行——{p['skipped']}")
            else:
                md.append(f"**公式探针**：填 {_pbrief(p.get('inputs'))} → 观察到变化 "
                          + (", ".join(f"`{k}`: {_pbrief(v.get('before'))}→{_pbrief(v.get('after'))}"
                                       for k, v in (p.get("outputs_candidates") or {}).items()) or "（无字段变化）"))
        if s.get("notes"):
            md.append("")
            md.append("备注：" + "；".join(s["notes"]))
        md.append("")
        md.append("**表单字段（填写经验，全部字段与当前值）**：")
        md.append("")
        md.append("| 字段 | 当前值 |")
        md.append("|---|---|")
        for k, v in (s.get("fields") or {}).items():
            md.append(f"| {_esc_md(k)} | {_esc_md(v if v not in (None, '') else '（空）')} |")
        md.append("")
    out.write_text("\n".join(md), encoding="utf-8")


def _redact_value(v) -> str:
    """值脱敏（审计第 5 轮 P1-1）：#<sha256_16>:<长度>；空值统一 ∅（双端可作同值匹配锚点但
    不泄值）。脱敏串仍保序可等值比较——merge 的 same_value 判定在脱敏产物上依然成立。"""
    if v is None or str(v) == "":
        return "∅"
    sv = str(v)
    return "#" + hashlib.sha256(sv.encode("utf-8")).hexdigest()[:16] + ":" + str(len(sv))


def _redact_fields(fields: dict) -> dict:
    return {str(k): _redact_value(v) for k, v in (fields or {}).items()}


def _redact_probe(probe) -> dict:
    """探针产物脱敏：inputs 是探针自填值（100）可保留；outputs/system_changes 的 before/after
    是表单原值——随字段值一起脱敏。"""
    if not isinstance(probe, dict) or probe.get("inputs") is None:
        return probe
    out = dict(probe)
    for key in ("outputs_candidates", "system_field_changes"):
        ch = out.get(key)
        if isinstance(ch, dict):
            out[key] = {k: {"before": _redact_value(v.get("before")),
                            "after": _redact_value(v.get("after"))}
                        for k, v in ch.items() if isinstance(v, dict)}
    return out


def _esc_md(v) -> str:
    """md 表格单元格转义：竖线/换行会破表（审计第 2 轮 F4，与 field-level-compare._md 同族）。"""
    return (str(v).replace("|", "\\|").replace("\n", "\\n").replace("\r", "\\r"))


def _pbrief(v, limit: int = 60) -> str:
    try:
        s = json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else str(v)
    except Exception:
        s = str(v)
    return s if len(s) <= limit else s[: limit - 1] + "…"


# ────────────────────────── merge：双端经验对齐 ──────────────────────────

def _map_fields(lf: dict, cf: dict) -> tuple[list[dict], dict]:
    """同节点双端字段映射候选：同名 > 归一化同名（建议纳入）> 同值（仅提示）；
    其余各自列出待人工。basis 记录判定依据，suggest=false 的一律不自动进契约。"""
    cands: list[dict] = []
    used_c: set[str] = set()
    seen_l: set[str] = set()
    for lk in lf:
        if lk in cf:
            cands.append({"legacy_field": lk, "target_field": lk, "basis": "same_name", "suggest": True})
            used_c.add(lk)
            seen_l.add(lk)
    norm_map: dict[str, list[str]] = {}
    for ck in cf:
        if ck not in used_c:
            norm_map.setdefault(_norm_field(ck), []).append(ck)
    for lk in lf:
        if lk in seen_l:
            continue
        hits = [c for c in norm_map.get(_norm_field(lk), []) if c not in used_c]
        if len(hits) == 1:
            cands.append({"legacy_field": lk, "target_field": hits[0],
                          "basis": "same_name_normalized", "suggest": True})
            used_c.add(hits[0])
            seen_l.add(lk)
    for lk, lv in lf.items():
        if lk in seen_l or lv in (None, "") or str(lv) == "∅":
            continue   # ∅=脱敏空锚（审计第 5 轮 P1-1）——双空字段不构成同值映射证据
        for ck, cv in cf.items():
            if ck in used_c or str(cv) == "∅":
                continue
            if str(cv) == str(lv):
                cands.append({"legacy_field": lk, "target_field": ck, "basis": "same_value", "suggest": False})
                used_c.add(ck)
                seen_l.add(lk)
                break
    needs = {
        "legacy_only": sorted(str(k) for k in lf if k not in seen_l),
        "current_only": sorted(str(k) for k in cf if k not in used_c),
    }
    return cands, needs


def cmd_merge(a) -> int:
    d = Path(a.explore_dir)
    paths = {side: d / f"explore-{side}.json" for side in ("legacy", "current")}
    missing = [s for s, p in paths.items() if not p.is_file()]
    if missing:
        die(f"缺 {'、'.join(missing)} 侧探索实录（{d}/explore-<side>.json）——"
            f"merge 必须双端齐全（单端不成经验）；先对另一侧跑 explore")
    data = {}
    for side, p in paths.items():
        try:
            data[side] = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            die(f"{side} 侧探索实录不可读 {p}: {e}")
    for side, x in data.items():
        if not isinstance(x, dict) or not x.get("flow_code"):
            die(f"{side} 侧探索实录非法（缺 flow_code）")
        if x.get("mode") != "explore":
            die(f"{side} 侧是 {x.get('mode')} 模式（只读观察没有表单/公式经验）——"
                f"merge 需要 --apply 写探索的双端实录")
    fl, fc_ = str(data["legacy"]["flow_code"]), str(data["current"]["flow_code"])
    if fl != fc_:
        die(f"双端流程编码不一致: legacy={fl} current={fc_}——不许跨流程拼经验")
    explore_id = str(data["current"].get("explore_id") or data["legacy"].get("explore_id") or d.name)
    # 审计第 5 轮 IM1：经验库/立契建议防静默覆盖（人工核验痕迹不可丢）
    _mout = Path(a.out) if a.out else (d / "experience.yaml")
    _existing_m = [q.name for q in list(d.glob("experience.yaml")) + list(d.glob("立契建议.md")) if q.exists()]
    if _existing_m and not a.overwrite:
        die(f"merge 产物已存在（{_existing_m}）——默认拒绝覆盖；确需重merge加 --overwrite")

    l_steps = {int(s["seq"]): s for s in data["legacy"].get("steps") or [] if isinstance(s, dict) and s.get("seq")}
    c_steps = {int(s["seq"]): s for s in data["current"].get("steps") or [] if isinstance(s, dict) and s.get("seq")}
    all_seqs = sorted(set(l_steps) | set(c_steps))
    nodes_out: list[dict] = []
    fm_suggest: list[dict] = []
    for seq in all_seqs:
        ls, cs = l_steps.get(seq), c_steps.get(seq)
        lf = dict((ls or {}).get("fields") or {})
        cf = dict((cs or {}).get("fields") or {})
        cands, needs = _map_fields(lf, cf)
        # 审计第 2 轮 F1：双端同 seq 但环节不同（一端中断/路由分歧）= 跨环节对齐——
        # 同名字段可能是不同环节的同名字段，映射建议一律降级为"仅提示"（不自动纳入）
        _ln, _cn = (ls or {}).get("node"), (cs or {}).get("node")
        node_mismatch = bool(ls and cs and _ln is not None and _cn is not None
                             and str(_ln) != str(_cn))
        if node_mismatch:
            for c in cands:
                c["suggest"] = False
        node_entry = {
            "seq": seq,
            "node": {"legacy": _ln, "current": _cn},
            "node_mismatch": node_mismatch,
            "fields": {"legacy": lf, "current": cf},
            "field_mapping_candidates": cands,
            "needs_human": needs,
            "routes": {"legacy": [r.get("node") for r in ((ls or {}).get("routes") or [])],
                       "current": [r.get("node") for r in ((cs or {}).get("routes") or [])]},
            "buttons_known": {"legacy": (ls or {}).get("buttons_known") or [],
                              "current": (cs or {}).get("buttons_known") or []},
            "formula_probes": [p for p in (((ls or {}).get("formula_probe"), (cs or {}).get("formula_probe")))
                               if isinstance(p, dict) and p.get("inputs") is not None],
        }
        nodes_out.append(node_entry)
        for c in cands:
            if c["suggest"]:
                fm_suggest.append({
                    "legacy_field": c["legacy_field"], "target_field": c["target_field"],
                    "normalize": "trim", "tolerance": "exact", "null_policy": "both_null_equal",
                    "note": (f"来源: 探索 {explore_id} seq{seq}（节点 legacy={_ln}/current={_cn}）"
                             f"basis={c['basis']}（立契人核对后可删本注）"),
                })

    routing_suggest = []
    for n in nodes_out:
        lg, cg = n["routes"]["legacy"], n["routes"]["current"]
        if lg:
            routing_suggest.append({"node": str(n["node"]["legacy"] or n["node"]["current"] or ""),
                                    "candidates_legacy": lg})

    experience = {
        "meta": {
            "explore_id": explore_id,
            "flow_code": fl,
            "generated_at": _now_iso(),
            "generator": VERSION,
            "sides": {side: {"explore_file": paths[side].name, "sha256_16": _sha16(paths[side]),
                             "status": data[side].get("status"),
                             "instance_no": data[side].get("instance_no")}
                      for side in ("legacy", "current")},
            "status": "experience-draft",
            "note": "经验库是第四取证源（参考物），不是契约、更不是结论；"
                    "契约仍须人工按取证三源立契并过 validate-contract --level test_ready。",
        },
        "nodes": nodes_out,
        "contract_suggestions": {
            "field_mappings": fm_suggest,
            "routing": routing_suggest,
            "buttons": [],   # 按钮断言涉及 expect_visible/expect_hidden 语义，探索只采集不猜——人工立契
        },
    }
    out_path = Path(a.out) if a.out else (d / "experience.yaml")
    tmp = out_path.with_name(out_path.name + ".tmp")
    tmp.write_text(yaml.safe_dump(experience, allow_unicode=True, sort_keys=False, width=110), encoding="utf-8")
    tmp.replace(out_path)

    # 人读版立契建议
    total_cands = sum(len(n["field_mapping_candidates"]) for n in nodes_out)
    auto_cnt = len(fm_suggest)
    md = [f"# 立契建议（经验库 {explore_id}）", "",
          f"> 流程 {fl}；生成时间 {_now_iso()}；双端探索 sha 已登记在 experience.yaml meta.sides。",
          "> **这只是建议**：契约仍须人工核对取证三源后立契（复制 contract_suggestions 起稿），",
          "> 并过 `validate-contract --level test_ready` 才能正式执行。", "",
          "## 总览", "",
          f"- 探索节点：{len(nodes_out)} 个（按 step 序对齐）；字段映射候选 {total_cands} 条，"
          f"其中**可自动纳入 {auto_cnt} 条**（同名/归一化同名），其余需人工确认。",
          "- 中断情况：" + "；".join(
              f"{side}={data[side].get('status')}" + (f"（{data[side].get('interrupted_reason')}）"
                                                      if data[side].get("interrupted_reason") else "")
              for side in ("legacy", "current")), ""]
    for n in nodes_out:
        md.append(f"## seq {n['seq']}　节点 legacy={n['node']['legacy']} / current={n['node']['current']}")
        md.append("")
        if n.get("node_mismatch"):
            md.append(f"> ⚠ **双端环节不一致**（legacy={n['node']['legacy']} / current={n['node']['current']}，"
                      f"大概率一端在此步前中断或路由分歧）——本节点全部映射建议已降级为仅提示，禁止直接纳入契约。")
            md.append("")
        md.append("| 老系统字段 | 新系统字段 | 判定 | 建议 |")
        md.append("|---|---|---|---|")
        _basis_cn = {"same_name": "同名", "same_name_normalized": "归一化同名", "same_value": "同值"}
        for c in n["field_mapping_candidates"]:
            _adv = ("✅ 可自动纳入" if c["suggest"]
                    else ("⚠ 仅提示（跨环节对齐），禁止直接纳入" if n.get("node_mismatch")
                          else "⚠ 仅提示（同值巧合），人工确认"))
            md.append(f"| {_esc_md(c['legacy_field'])} | {_esc_md(c['target_field'])} "
                      f"| {_basis_cn.get(c['basis'], c['basis'])} | {_adv} |")
        for k in n["needs_human"]["legacy_only"]:
            md.append(f"| {_esc_md(k)} | — | 仅老系统有 | ❓ 待人工（新系统字段名？） |")
        for k in n["needs_human"]["current_only"]:
            md.append(f"| — | {_esc_md(k)} | 仅新系统有 | ❓ 待人工（老系统字段名？） |")
        md.append("")
        if n["routes"]["legacy"] or n["routes"]["current"]:
            md.append(f"- 路由候选：legacy={n['routes']['legacy'] or '（未探到）'}　"
                      f"current={n['routes']['current'] or '（未探到）'}")
        if n["formula_probes"]:
            md.append(f"- 公式探针：{len(n['formula_probes'])} 组（详见 experience.yaml 该节点 formula_probes）")
        md.append("")
    (d / "立契建议.md").write_text("\n".join(md), encoding="utf-8")
    print(f"[explore] merge 完成：experience.yaml（{auto_cnt}/{total_cands} 条映射建议可自动纳入）→ {out_path}")
    print(f"[explore] 立契建议（人读）→ {d / '立契建议.md'}")
    return 0



# ────────────────────────── explore-browser：浏览器只读探索（v1.5.0 任务完成门②） ──────────────────────────

def _load_browser_capture():
    spec = importlib.util.spec_from_file_location("ftc_browser_capture", _SCRIPT_DIR / "browser-capture.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("ftc_browser_capture", mod)
    spec.loader.exec_module(mod)
    return mod


def _parse_snapshot(snap: str) -> dict:
    """a11y 快照 → 结构观察（只读——绝不点击/填写，防提交类副作用）。"""
    import re as _re
    buttons, textboxes, comboboxes, links, headings, others = [], [], [], [], [], []
    for ln in snap.splitlines():
        t = ln.strip()
        if not t.startswith("- "):
            continue
        m = _re.match(r"-\s+(\w+)\s+(?:\"([^\"]*)\")?[^\[]*\[ref=([A-Za-z0-9_]+)\]", t)
        if not m:
            continue
        role, text, ref = m.group(1), (m.group(2) or "").strip(), m.group(3)
        item = {"text": text, "ref": ref}
        if role == "button":
            buttons.append(item)
        elif role in ("textbox", "searchbox"):
            textboxes.append(item)
        elif role in ("combobox", "listbox"):
            comboboxes.append(item)
        elif role == "link":
            links.append(item)
        elif role.startswith("heading"):
            headings.append(item)
        else:
            others.append({"role": role, **item})
        if len(buttons) + len(textboxes) + len(comboboxes) + len(links) + len(headings) + len(others) > 400:
            break  # 快照过大截断（防失控页面）
    return {"buttons": buttons, "textboxes": textboxes, "comboboxes": comboboxes,
            "links": links[:40], "headings": headings[:20], "others": others[:60]}


def cmd_browser_explore(a) -> int:
    """浏览器通道只读探索：登录 → 打开页 → a11y 快照解析（按钮/输入/链接/标题）→ 截图 →
    产出 __UI_RECORD__ 候选（人工核对后才可填入正式 systems browser 配置）+ 覆盖账本要素草稿。
    铁律：零点击零填写（登录本身除外）——按钮流收敢单靠本探索不完成，但它把'已知 BLOCKED'
    变成有截图/候选 ref/覆盖要素的显式完成队列。"""
    try:
        cfg = yaml.safe_load(Path(a.systems).read_text(encoding="utf-8")) or {}
    except Exception as e:
        die(f"systems 配置不可读: {e}")
    if not isinstance(cfg, dict) or cfg.get("channel") != "browser":
        die(f"channel 非 browser——本子命令只做浏览器只读探索: {a.systems}")
    side = str(cfg.get("id") or "browser")
    if ac._contains_placeholder(cfg):
        print("[browser-explore] ⚠ 配置含 __UI_RECORD__ 占位——这正是本探索要帮你收敛的；继续只读探索")
    bcfg_mod = _load_browser_capture()
    outdir = Path(a.outdir)
    label = str(a.label or "page1")
    existing = [q.name for q in (outdir / f"explore-browser-{side}-{label}.json",) if q.exists()]
    if existing and not a.overwrite:
        die(f"本页探索产物已存在（{existing}）——--overwrite 或换 --label")
    actor = str(a.actor or next(iter(cfg.get("actorMap") or {"admin": {}})))
    b = bcfg_mod.Browser(cfg, headed=a.headed)
    username, password = bcfg_mod.actor_credentials(cfg, actor)
    b.open_app()
    login_page = None
    try:
        # 审计第 8 轮 P1-3：登录候选项只允许来自**登录前**快照——登录后页面是业务页，
        # 把业务输入框当 userRef/passRef 会配出灾难性选择器
        try:
            login_page = _parse_snapshot(b.snap())
        except Exception as e:
            print(f"[browser-explore] ⚠ 登录前快照失败（登录候选回退 __UI_RECORD__）: {e}")
        b.login(cfg, actor)
        if a.goto:
            b._run("open", a.goto, timeout=90)
            time.sleep(float(a.wait_seconds))
        snap = b.snap()
        obs = _parse_snapshot(snap)
        title = ""
        mtitle = re.search(r'- page [^\n]*\"([^\"]+)\"', snap) or re.search(r"page [^\n]*'([^']+)'", snap)
        if mtitle:
            title = mtitle.group(1)
        shot = outdir / f"browser-{side}-{label}.png"
        try:
            outdir.mkdir(parents=True, exist_ok=True)
            b._run("screenshot", str(shot))
        except Exception as e:
            shot = None
            print(f"[browser-explore] ⚠ 截图失败（不阻断）: {e}")
    finally:
        if not a.keep_open:
            b.close()
    # UI_RECORD 候选（人工核对后才能进正式配置）
    cands = {
        "meta": {"note": "UI_RECORD 候选——选择器/文案须人工核对后才可填入 systems browser 正式配置；"
                         "本文件由只读探索生成，不替代 UI 录制实测",
                 "generated_by": VERSION, "side": side, "label": label,
                 "goto": a.goto or (cfg.get("browser") or {}).get("baseUrl", ""), "actor": actor},
        "candidates": {
            # 登录候选仅来自登录前快照（login_page）；业务页输入框永不充当登录 ref
            "login": {
                "userRef": ((login_page or {}).get("textboxes") or [{}])[0].get("ref", "__UI_RECORD__"),
                "passRef": ((login_page or {}).get("textboxes")[1:2] or [{}])[0].get("ref", "__UI_RECORD__")
                           if login_page else "__UI_RECORD__",
                "submitRef": ((login_page or {}).get("buttons") or [{}])[-1].get("ref", "__UI_RECORD__")
                             if login_page else "__UI_RECORD__",
                "source": "pre_login_snapshot" if login_page else "unavailable"},
            "buttons": obs["buttons"], "textboxes": obs["textboxes"],
            "comboboxes": obs["comboboxes"], "links": obs["links"], "headings": obs["headings"],
        },
        "coverage_elements": [
            {"id": f"browser-{label}-button-{i}", "source": "browser_explore", "kind": "button",
             "name": b_.get("text") or b_.get("ref"), "contract_ref": "", "dimension": "buttons",
             "channel": "browser", "status": "ready_for_browser_run", "must_cover": True,
             "reason": "", "followup": "import-browser-explore 入账后，浏览器正式 run PASS → promote covered"}
            for i, b_ in enumerate(obs["buttons"])]
    }
    outdir.mkdir(parents=True, exist_ok=True)
    jf = outdir / f"explore-browser-{side}-{label}.json"
    jf.write_text(json.dumps({"version": VERSION, "side": side, "label": label, "actor": actor,
                              "goto": a.goto or "", "page_title": title,
                              "created_at": _now_iso(), "observations": obs,
                              "screenshot": str(shot) if shot else None,
                              "ui_record_candidates": cands}, ensure_ascii=False, indent=2),
                  encoding="utf-8")
    cy = outdir / f"ui-record-candidates-{side}-{label}.yaml"
    cy.write_text(yaml.safe_dump(cands, allow_unicode=True, sort_keys=False, width=110), encoding="utf-8")
    md = [f"# 浏览器只读探索（{side}·{label}）", "",
          f"- 页面：{a.goto or (cfg.get('browser') or {}).get('baseUrl', '')}　账号：{actor}　标题：{title or '（未解析）'}",
          f"- 可见按钮 {len(obs['buttons'])}、输入框 {len(obs['textboxes'])}、下拉 {len(obs['comboboxes'])}、链接 {len(obs['links'])}",
          f"- 截图：{shot or '（失败）'}", "",
          "**按钮清单（点击经验候选——未点击，仅可见性）**：", ""]
    md += [f"- `{b_.get('text') or b_.get('ref')}`（ref={b_.get('ref')}）" for b_ in obs["buttons"][:30]]
    md += ["", "**输入框**："] + [f"- {t_.get('text') or '（无标签）'}（ref={t_.get('ref')}）"
                                  for t_ in obs["textboxes"][:30]]
    md += ["", f"> UI_RECORD 候选 → `{cy.name}`（人工核对后填入 systems browser 配置）；"
               f"> 覆盖要素草稿 {len(cands['coverage_elements'])} 条（ready_for_browser_run/"
               f"must_cover=true——import-browser-explore 入账，未正式 run 前阻断全量 PASS）。", ""]
    (outdir / f"探索发现-browser-{side}-{label}.md").write_text("\n".join(md), encoding="utf-8")
    print(f"[browser-explore] {side}/{label}: 按钮 {len(obs['buttons'])}、输入 {len(obs['textboxes'])} → {jf}")
    return 0


def main() -> None:
    ap = argparse.ArgumentParser(prog="explore-channel.py", description="首次对比前的自由探索器（收集点击/选择/填写/公式经验）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    pe = sub.add_parser("explore", help="单端探索（先 legacy 后 current 各跑一次）")
    pe.add_argument("--systems", required=True, help="systems api 配置（YAML）")
    pe.add_argument("--flow", required=True, help="流程编码（如 WFA_RY_JM_126001）")
    pe.add_argument("--outdir", required=True, help="探索产物目录（建议 docs/<流程>/自动化测试/探索/<explore-id>/）")
    pe.add_argument("--actor", default="", help="探索账号（只读观察可缺省 actorMap 第一个；--apply 必填——写操作须可追溯账号）")
    pe.add_argument("--observe-only", action="store_true", help="只读观察（登录+待办结构；不发起实例）")
    pe.add_argument("--apply", action="store_true",
                    help="写探索（发起实例+逐环节提交；写影响=与一次正式 run 同级，只碰自己发起的实例）")
    pe.add_argument("--fill", action="store_true", help="公式探针：向数值字段填探针值→预保存→读回计算值（需 --apply）")
    pe.add_argument("--advance", choices=("first", "none"), default="none",
                    help="推进策略：none=只探索当前节点不提交（--apply 默认，防非预期流转）；"
                         "first=逐环节走候选路由（须能确定办理人，见 --assignee）")
    pe.add_argument("--route", default="", help="推进时显式指定路由（须在系统实时候选内——不探索性猜路由）")
    pe.add_argument("--assignee", default="", help="推进时显式办理人（姓名或候选 ID；无候选且未指定=拒绝空办理人提交并在 submit 前中断）")
    pe.add_argument("--max-steps", type=int, default=12, help="最多探索步数（默认 12）")
    pe.add_argument("--form-data", default="", help='每步随提交的业务表单数据（JSON 对象，如 \'{"KC":"1001"}\'）')
    pe.add_argument("--explore-id", default="", help="探索 id（缺省取 outdir 目录名）")
    pe.add_argument("--include-values", action="store_true",
                    help="产物保留表单原始值（默认脱敏为 #sha16:长度——防敏感值泄露进 docs/共享面）；"
                         "开启后产物含敏感值，须放私有 runtime 勿提交/同步")
    pe.add_argument("--overwrite", action="store_true", help="允许覆盖同目录已有探索产物（默认拒绝——防丢实例号/人工核验痕迹）")
    pe.set_defaults(func=cmd_explore)

    pm = sub.add_parser("merge", help="双端经验合并 → experience.yaml + 立契建议.md")
    pm.add_argument("--explore-dir", required=True, help="含 explore-legacy.json 与 explore-current.json 的目录")
    pm.add_argument("--out", default="", help="经验库输出路径（缺省 <explore-dir>/experience.yaml）")
    pm.add_argument("--overwrite", action="store_true", help="允许覆盖已有 experience.yaml/立契建议.md（默认拒绝）")
    pm.set_defaults(func=cmd_merge)

    pb = sub.add_parser("explore-browser", help="浏览器只读探索（截图+可见按钮/输入/候选 ref；零点击零填写）")
    pb.add_argument("--systems", required=True, help="systems browser 配置（YAML；__UI_RECORD__ 占位允许——正是待收敛项）")
    pb.add_argument("--actor", default="", help="登录账号（缺省 actorMap 第一个）")
    pb.add_argument("--goto", default="", help="登录后导航到的 URL（缺省停留 baseUrl）")
    pb.add_argument("--label", default="page1", help="页面标签（多页探索用不同 label 分文件）")
    pb.add_argument("--outdir", required=True, help="产物目录（建议同 explore 的探索目录）")
    pb.add_argument("--headed", action="store_true", default=True, help="可见浏览器（默认开）")
    pb.add_argument("--wait-seconds", type=float, default=2.5, help="导航后等待秒数")
    pb.add_argument("--keep-open", action="store_true", help="探索后不关浏览器（续探下页）")
    pb.add_argument("--overwrite", action="store_true")
    pb.set_defaults(func=cmd_browser_explore)

    a = ap.parse_args()
    raise SystemExit(a.func(a))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[explore] ⛔ 内部异常（fail-closed，不产出经验）: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
