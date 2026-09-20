#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SDD 流水线状态机(只读报数 + 清单确认回写)。

用法:
    python sdd_state.py <specs目录> state                    # 状态机 JSON(只读,恒退出码 0)
    python sdd_state.py <specs目录> ready                    # 就绪探测器:现在可立即派发谁(事件驱动派发用)
    python sdd_state.py <specs目录> approve-list --by <谁>    # 清单确认回写

state 是流程的第一条指令:判断"现在该干什么"由脚本报数,不靠 LLM 猜。
状态值:草案 → 已确认 → 实现中 → 已交付。
"""
import json
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sdd_common import load_json, find_spec_dir  # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def _feature_status(specs, fid):
    """读 spec.json 的 status;无 spec 目录返回 no-spec,无 status 字段按草案处理。"""
    d = find_spec_dir(specs, fid)
    if d is None:
        return "no-spec"
    sp = load_json(d / "spec.json")
    return (sp or {}).get("status") or "草案"


def cmd_state(specs):
    fl = load_json(specs / "feature-list.json")
    features = (fl or {}).get("features", [])
    fmap = {f.get("id"): f for f in features}
    questions = ((load_json(specs / "open-questions.json") or {}).get("questions", []))

    def blocking_qs(fid):
        return [q["id"] for q in questions
                if q.get("blocking") == "high" and q.get("status") != "已关闭"
                and fid in set(q.get("features", []))]

    items, counts = [], {}
    for f in features:
        fid = f.get("id")
        if f.get("done"):
            # 既有能力/开工前已交付:不进状态计数,不参与派发(与 ready 探测器同口径)
            items.append({"id": fid, "name": f.get("name", ""), "status": "已交付(既有)",
                          "deps": f.get("deps", []), "depsNotDelivered": [],
                          "blockingOpenQs": [], "nextAction": "既有能力,无需动作"})
            continue
        st = _feature_status(specs, fid)
        counts[st] = counts.get(st, 0) + 1
        dep_block = sorted(d for d in f.get("deps", [])
                           if fmap.get(d, {}).get("done") is not True
                           and _feature_status(specs, d) != "已交付")
        bq = blocking_qs(fid)
        if st == "no-spec":
            action = ("依赖未就绪,排队等前置交付" if dep_block
                      else "依赖已就绪,待补批生成 spec")
        elif st == "草案":
            action = "待确认 spec(set-status --status 已确认)"
        elif st == "已确认":
            action = (f"可开工,但有高阻塞 Q 待裁决:{','.join(bq)}" if bq else "可开工(实现步:开工登记→实现→自查→评审→交付确认)")
        elif st == "实现中":
            action = "实现中(实现→自查→评审→交付确认)"
        else:
            action = "已交付"
        items.append({"id": fid, "name": f.get("name", ""), "status": st,
                      "deps": f.get("deps", []), "depsNotDelivered": dep_block,
                      "blockingOpenQs": bq, "nextAction": action})

    all_delivered = bool(features) and all(
        it["status"] == "已交付" or fmap.get(it["id"], {}).get("done") for it in items)
    open_high = [q["id"] for q in questions
                 if q.get("blocking") == "high" and q.get("status") != "已关闭"]
    if all_delivered:
        pipeline_next = "全部交付:进测试步(场景测试→收尾检查)→复盘"
    elif counts.get("no-spec"):
        pipeline_next = "存在未生成 spec 的 feature:走规范步补批"
    elif counts.get("草案"):
        pipeline_next = "存在草案 spec:走 spec 确认"
    else:
        pipeline_next = "按各 feature nextAction 推进实现"

    print(json.dumps({
        "specs": str(specs),
        "counts": counts,
        "openHighBlockQs": open_high,
        "pipelineNext": pipeline_next,
        "features": items,
    }, ensure_ascii=False, indent=2))
    return 0


def approve_list(specs, by):
    """清单确认回写:feature-list.json status=已确认 + approvedBy/approvedAt,md 状态行同步。"""
    jp = specs / "feature-list.json"
    data = load_json(jp, required=True)
    if data is None:
        return False
    data["status"] = "已确认"
    data["approvedBy"] = by
    data["approvedAt"] = date.today().isoformat()
    jp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    md = specs / "feature-list.md"
    if md.exists():
        lines = md.read_text(encoding="utf-8", errors="ignore").splitlines()
        for i, ln in enumerate(lines):
            if ln.lstrip().startswith("| 状态 |"):
                lines[i] = f"| 状态 | 已确认({by},{date.today().isoformat()}) |"
                break
        md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"[状态回写] feature-list: 已确认 (by={by})")
    return True


def cmd_ready(specs):
    """事件驱动派发探测器:单 feature 粒度报「现在可立即派发」的清单。

    与 state 的区别:state 是全量报数;ready 只回答一个问题——**现在能开工谁**。
    两类就绪:
      readyForSpec      = 依赖全已交付(或 done) 且 自身尚无 spec
      readyForImplement = 依赖全已交付 且 spec 已确认 且 无高阻塞未关 Q
    用法:每收到一个「已交付/已确认」通知后执行一次,有输出即派发,无输出即等待。
    """
    fl = load_json(specs / "feature-list.json")
    features = (fl or {}).get("features", [])
    questions = ((load_json(specs / "open-questions.json") or {}).get("questions", []))

    def status_of(fid, fmap):
        return "已交付" if fmap.get(fid, {}).get("done") else _feature_status(specs, fid)

    fmap = {f.get("id"): f for f in features}
    ready_spec, ready_impl, waiting = [], [], []
    for f in features:
        fid = f.get("id")
        st = _feature_status(specs, fid)
        deps_ok = all(status_of(d, fmap) == "已交付" for d in f.get("deps", []))
        high_open = any(q.get("blocking") == "high" and q.get("status") != "已关闭"
                        and fid in set(q.get("features", []))
                        for q in questions)
        entry = {"id": fid, "name": f.get("name", ""), "deps": f.get("deps", [])}
        if st == "已交付" or fmap.get(fid, {}).get("done"):
            continue
        if deps_ok and st == "no-spec":
            ready_spec.append(entry)
        elif deps_ok and st == "已确认" and not high_open:
            ready_impl.append(entry)
        elif st in ("实现中",):
            waiting.append({**entry, "reason": "实现中"})
        elif not deps_ok:
            waiting.append({**entry, "reason": "依赖未交付",
                            "depsNotDelivered": [d for d in f.get("deps", [])
                                                 if status_of(d, fmap) != "已交付"]})
        elif st == "草案":
            waiting.append({**entry, "reason": "spec 待确认"})
        elif high_open:
            waiting.append({**entry, "reason": "高阻塞 Q 未关"})

    print(json.dumps({
        "specs": str(specs),
        "readyForSpec": ready_spec,
        "readyForImplement": ready_impl,
        "waiting": waiting,
        "dispatchNext": ("生成 spec:" + ",".join(x["id"] for x in ready_spec)) if ready_spec
                        else ("派发实现:" + ",".join(x["id"] for x in ready_impl)) if ready_impl
                        else ("等待:" + ",".join(x["id"] + f"({x['reason']})" for x in waiting))
                        if waiting else "全部交付",
    }, ensure_ascii=False, indent=2))
    return 0


def main():
    args = sys.argv[1:]
    if len(args) < 2 or args[1] not in ("state", "approve-list", "ready"):
        print(__doc__)
        return 2
    specs = Path(args[0])
    if not specs.is_dir():
        print(f"specs 目录不存在: {specs}")
        return 2
    if args[1] == "state":
        return cmd_state(specs)
    if args[1] == "ready":
        return cmd_ready(specs)
    by = args[args.index("--by") + 1] if "--by" in args and args.index("--by") + 1 < len(args) else "user"
    return 0 if approve_list(specs, by) else 1


if __name__ == "__main__":
    sys.exit(main())
