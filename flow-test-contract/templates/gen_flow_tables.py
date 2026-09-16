#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_flow_tables.py — 流程环节表格生成器（多分支总览 / 单分支明细）

数据源（按可用性选择）：
  A. legacy-oracle（推荐/正式）：直连老系统 Oracle（SOURCE_ORACLE_*，与 qianyi/migrator 同源）——
     主表 SETTLE_WORKFLOW_SUB（分支路由边：FLOW_CODE/STEP_ID/FIELD/VALUE/NEXT_STEP_ID/WORKFLOW_SUB_ID）、
     SETTLE_WORKFLOW_STEP（节点定义：名称/顺序）。连接不可达或结构不符 → 明确 BLOCKED（绝不猜测回退）。
  B. snapshot（回退/过渡）：解析既有 Excel 快照转档 md（《23分支节点对应信息.md》同构表），
     保证无 DB 环境可出同构表格；仅建议用于起草，正式产物以 A 为准。

输出（两种产物，markdown）：
  1) 多分支总览表：分支 | T_GK/矿厂 | 发起人(00) | 实际首跳 | 节点数 | 主线路径 | 分支路由表来源说明
  2) 单分支明细表：环节 | 环节名称 | 办理人 | 下一环节候选 | 办理人候选（行=该分支配置的每个环节，
     办理人/候选 = 分支 sheet 语义；未配置环节不出现——老系统该分支此环节不可达）
  注：新老可达性属测试证据列（flow-test-contract 双端采集后填充），本生成器只产结构侧。

用法：
  python3 templates/gen_flow_tables.py --flow WFA_RY_JM_126001 --mode all --outdir /tmp/flowtables
  python3 templates/gen_flow_tables.py --flow WFA_RY_JM_126001 --mode single --branch B-12 --db snapshot \
      --snapshot docs/港口煤发运流程/23分支节点对应信息.md --outdir /tmp/flowtables
  python3 templates/gen_flow_tables.py --selftest        # 无 DB 自检（解析内置样本断言）
"""
from __future__ import annotations
import argparse, json, re, sys
from pathlib import Path
from dataclasses import dataclass, field

STEP_NAME_HINT = {  # 环节编号 → 标准名称（DB 节点名缺失时的兜底；DB 有名称以 DB 为准）
    "00":"数量鉴定单制单","01":"数量鉴定单审核","02":"数量鉴定单负责人","05":"运销科盖章",
    "06":"计量章负责人盖章","10":"质量鉴定单制单","11":"质量鉴定单审核","12":"质量鉴定单负责人",
    "15":"化验章负责人盖章","30":"货运明细表制单","35":"95306货票明细制单",
    "40":"货运发票单制单","41":"(…)铁路到港运费流程","42":"(…)铁路到港运费流程",
    "43":"(…)铁路到港运费流程","44":"(…)铁路到港运费流程","45":"(…)铁路到港运费流程",
    "46":"(…)铁路到港运费流程","47":"(…)铁路到港运费流程","50":"数量单复核",
    "55":"质量单复核","99":"流程结束",
}
NODE_TITLE = {"00":"数量鉴定单制单","01":"数量鉴定单审核","02":"数量鉴定单负责人","05":"运销科盖章",
    "06":"计量章负责人盖章","10":"质量鉴定单制单","11":"质量鉴定单审核","12":"质量鉴定单负责人",
    "15":"化验章负责人盖章","30":"货运明细表制单","35":"95306货票明细制单","40":"货运发票单制单",
    "50":"数量单复核","55":"质量单复核","99":"流程结束"}
FREIGHT_NODES = {"41","42","43","44","45","46","47"}
END_NODE = "99"

@dataclass
class Step:
    code: str
    name: str
    handlers: list[str]          # 办理人（该环节候选）
    next_options: list[str]      # 下一环节可选项（编号，保序）
    next_handlers: dict          # 下一环节 → 办理人候选
    is_freight: bool = False

@dataclass
class Branch:
    key: str                     # 分支键（B-12 或 T_GK 值）
    gk: str                      # T_GK 条件值/矿厂
    initiator: str = ""
    launch_options: list[str] = field(default_factory=list)
    steps: list[Step] = field(default_factory=list)

# ---------------------------------------------------------------- 解析入口
def parse_snapshot_md(text: str) -> list[Branch]:
    """解析《23分支节点对应信息.md》同构转档：## B-XX … 各分支 sheet 行；
    并吸收总览表行（发起人/首跳/节点数/主线路径）做一致性元数据。"""
    branches: dict[str, Branch] = {}
    cur: Branch | None = None
    in_meta = False
    gk_map: dict[str, str] = {}
    for ln in text.splitlines():
        if ln.startswith("| B-") and "| T_GK" not in ln:
            cc = [c.strip() for c in ln.strip().strip("|").split("|")]
            if len(cc) >= 3:
                gk_map[cc[0]] = cc[1]
    for ln in text.splitlines():
        if ln.startswith("## B-"):
            # 总览分支块也可能以 ## B- 开头（总览表行）——但明细块更大且带表格；统一按明细解析，
            # 从题注行吸收 发起人/首跳/主线 等（如有）
            key = ln[3:].split()[0]
            cur = Branch(key=key, gk="")
            branches[key] = cur
            in_meta = True
            continue
        if cur is None:
            continue
        if ln.lstrip().startswith("**发起人") or ln.lstrip().startswith("**发起"):
            m = re.search(r"发起人[（(]?00[）)]?\**\s*[:：]\s*([^|｜]+)", ln)
            if m: cur.initiator = m.group(1).strip()
            continue
        if not ln.startswith("| "):
            continue
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        # 总览表行：| B-XX | 矿厂 | 发起人 | 首跳 | 节点数 | 主线 | … |（第一列非数字）
        if re.match(r"^B-\d\d$", cells[0]) and len(cells) >= 6:
            gk = cells[1] if "T_GK" not in cells[1] else "—"
            if cur: cur.gk = gk or cur.gk
            continue
        if len(cells) < 5 or not re.match(r"^\d+$", cells[0]):
            continue
        m = re.match(r"^(\d+)\s+(.*)$", cells[1])
        if not m:
            continue
        code = m.group(1)
        name = re.sub(r"^[（(][^）)]*[）)]\s*", "", m.group(2)).strip() or STEP_NAME_HINT.get(code, code)
        handler_raw = cells[2]
        opts_raw = cells[3]
        cand_raw = cells[4]
        handlers = [h.strip() for h in re.split(r"[、,，]", handler_raw) if h.strip()]
        opts = []
        for t in re.split(r"[、,，]", opts_raw):
            mm = re.search(r"(?<!\d)(\d{2})(?![\d])", t.strip())
            if mm:
                opts.append(mm.group(1))
        # 候选办理人映射
        nh: dict[str, list[str]] = {}
        for part in re.split(r"[；;]", cand_raw):
            mm = re.match(r"^(\d{2})\s*[→➔-]\s*(.+)$", part.strip())
            if mm:
                nh[mm.group(1)] = [h.strip() for h in re.split(r"[、,，]", mm.group(2)) if h.strip() and "流程结束" not in h]
        cur.steps.append(Step(code=code, name=name, handlers=handlers,
                              next_options=opts, next_handlers=nh,
                              is_freight=code in FREIGHT_NODES))
    out = list(branches.values())
    for b in out:
        if not b.gk and b.key in gk_map:
            b.gk = gk_map[b.key]
    return out

def mainline(b: Branch) -> list[str]:
    """主线路径：从 00 起沿每环节『第一个』下一候选行进至 99/无后继（与老系统 nextSteps 数组顺序一致）。"""
    path, seen = [], set()
    cur = "00"
    by_code = {s.code: s for s in b.steps}
    while cur and cur not in seen and cur in by_code:
        seen.add(cur)
        path.append(cur)
        st = by_code[cur]
        if st.is_freight or not st.next_options or st.next_options == [END_NODE]:
            break
        nxt = st.next_options[0]
        if nxt == END_NODE:
            path.append(END_NODE); break
        cur = nxt
    if path and path[-1] != END_NODE and path[-1] != "99":
        path.append(END_NODE)
    return path

def is_launch(b: Branch) -> bool:
    return any(s.code == "00" for s in b.steps)

def render_overview(branches: list[Branch]) -> str:
    lines = ["| 分支 | 矿厂/T_GK | 发起人(00) | 实际首跳 | 节点数 | 主线路径 | 分支路由来源 |",
             "|---|---|---|---|---|---|---|"]
    for b in branches:
        path = mainline(b)
        first = path[1] if len(path) > 1 else "—"
        if not b.initiator:
            st00 = next((s0 for s0 in b.steps if s0.code == "00"), None)
            b.initiator = "、".join(st00.handlers) if st00 else "—"
        n = len(path) - 1 if path and path[-1] == "99" else len(path)
        lines.append(f"| {b.key} | {b.gk or '—'} | {b.initiator or '—'} | {first} | {n} | "
                     f"{'→'.join(path)} | SETTLE_WORKFLOW_SUB" )
    return "\n".join(lines)

def render_single(b: Branch) -> str:
    lines = [f"# 单分支环节表：{b.key}（{b.gk or '—'}）",
             "",
             f"> 发起人(00)：{b.initiator or '—'}｜实际首跳：{mainline(b)[1] if len(mainline(b))>1 else '—'}｜主线路径：{'→'.join(mainline(b))}",
             "> 数据来源：老系统 Oracle SETTLE_WORKFLOW_SUB/STEP（--db legacy-oracle）；快照回退见表注。",
             "",
             "| 环节 | 环节名称 | 办理人 | 下一环节候选 | 办理人候选 |",
             "|---|---|---|---|---|"]
    for st in b.steps:
        h = "、".join(st.handlers) or "—"
        opts = "、".join(st.next_options) if st.next_options else ("—" if st.is_freight else "99")
        cands = "；".join(f"{k}→{'、'.join(v) if v else '—'}" for k, v in st.next_handlers.items())
        if not cands:
            cands = "—"
        lines.append(f"| {st.code} | {st.name} | {h} | {opts} | {cands} |")
    lines += ["", "> 注：41~47 为跳转结束型运费环节（APPROVE_TYPE=2，提交即办结、自动启动后置流程 WFA_RY_JM_165002）。",
              "> 新可达/老可达为测试证据列：由 flow-test-contract 双端采集对拍后填充（本生成器只产结构侧）。"]
    return "\n".join(lines)

def render_all(branches: list[Branch]) -> str:
    out = ["# 多分支总览（flow-test-contract 生成）", "", render_overview(branches), ""]
    for b in sorted(branches, key=lambda x: x.key):
        out += ["---", render_single(b), ""]
    return "\n".join(out)

# ---------------------------------------------------------------- DB 后端（legacy-oracle）
def db_load(flow_code: str, env) -> list[Branch]:
    """直连老系统 Oracle。列名以 SETTLE_WORKFLOW_SUB/STEP 实际结构为准，先探列再查——
    结构不匹配即抛 RuntimeError（BLOCKED，绝不按猜测继续）。"""
    import os
    host, port, svc = os.getenv("SOURCE_ORACLE_HOST"), os.getenv("SOURCE_ORACLE_PORT"), os.getenv("SOURCE_ORACLE_SERVICE")
    user, pwd = os.getenv("SOURCE_ORACLE_USERNAME"), os.getenv("SOURCE_ORACLE_PASSWORD")
    missing = [k for k, v in {"SOURCE_ORACLE_HOST": host, "SOURCE_ORACLE_PORT": port,
                              "SOURCE_ORACLE_SERVICE": svc, "SOURCE_ORACLE_USERNAME": user,
                              "SOURCE_ORACLE_PASSWORD": pwd}.items() if not v]
    if missing:
        raise RuntimeError("BLOCKED：缺 SOURCE_ORACLE_* 环境变量（" + ",".join(missing) + "）")
    try:
        import oracledb
    except ImportError:
        raise RuntimeError("BLOCKED：缺 oracledb（uv run --with oracledb 或 qianyi .venv 执行）")
    dsn = f"{host}:{port}/{svc}"
    conn = oracledb.connect(user=user, password=pwd, dsn=dsn)
    cur = conn.cursor()
    def cols(t: str) -> set:
        cur.execute("SELECT column_name FROM user_tab_columns WHERE table_name=:1", (t,))
        return {r[0] for r in cur.fetchall()}
    sub_cols, step_cols = cols("SETTLE_WORKFLOW_SUB"), cols("SETTLE_WORKFLOW_STEP")
    need_sub = {"FLOW_CODE", "STEP_ID", "FIELD", "VALUE", "NEXT_STEP_ID"}
    if not need_sub <= sub_cols:
        conn.close()
        raise RuntimeError(f"BLOCKED：SETTLE_WORKFLOW_SUB 缺列 {need_sub - sub_cols}（实测 {sorted(sub_cols)}），结构不符")
    # 节点名称：从 SETTLE_WORKFLOW_STEP（若有 STEP_ID/STEP_NAME/STEP_TITLE 等）+ SUB 里分支行
    name_col = next((c for c in ("STEP_NAME", "STEP_TITLE", "NAME", "STEP_DESC") if c in step_cols), None)
    names: dict[str, str] = {}
    if name_col and "STEP_ID" in step_cols:
        cur.execute(f"SELECT STEP_ID, {name_col} FROM SETTLE_WORKFLOW_STEP WHERE FLOW_CODE=:1", (flow_code,))
        names = {str(r[0]): str(r[1] or "") for r in cur.fetchall()}
    cur.execute("""SELECT STEP_ID, FIELD, VALUE, NEXT_STEP_ID
                   FROM SETTLE_WORKFLOW_SUB
                   WHERE FLOW_CODE=:1 ORDER BY STEP_ID, WORKFLOW_SUB_ID""", (flow_code,))
    rows = cur.fetchall()
    conn.close()
    if not rows:
        raise RuntimeError(f"BLOCKED：FLOW_CODE={flow_code} 在 SETTLE_WORKFLOW_SUB 无行")
    # 组装：按 (STEP_ID, VALUE) 为分支键；VALUE 即矿厂条件值（T_GK）
    by_branch: dict[str, dict] = {}
    order: list[str] = []
    for step_id, field, value, nxt in rows:
        key = str(value or "（默认）")
        if key not in by_branch:
            by_branch[key] = {"steps": {}, "field": field}; order.append(key)
        by_branch[key]["steps"].setdefault(str(step_id), []).append(str(nxt) if nxt is not None else "")
    out: list[Branch] = []
    for key in order:
        d = by_branch[key]
        steps = []
        for code in sorted(d["steps"], key=int):
            opts = [x for x in d["steps"][code] if x]
            steps.append(Step(code=code, name=names.get(code) or STEP_NAME_HINT.get(code, code),
                              handlers=[], next_options=opts, next_handlers={},
                              is_freight=code in FREIGHT_NODES))
        out.append(Branch(key=key, gk=key, steps=steps))
    return out

# ---------------------------------------------------------------- CLI
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flow", default="WFA_RY_JM_126001")
    ap.add_argument("--mode", choices=["multi", "single", "all"], default="all")
    ap.add_argument("--branch", default="", help="single/all 时指定 B-XX（snapshot 键）或 T_GK 值（DB 键）；空=全部")
    ap.add_argument("--db", choices=["legacy-oracle", "snapshot"], default="legacy-oracle")
    ap.add_argument("--snapshot", default="", help="--db snapshot 时给定转档 md 路径")
    ap.add_argument("--outdir", default="", help="输出目录（缺省仅打印）")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        sample = "\n".join([
            "## B-01 木瓜煤矿 - 12 节点",
            "**发起人(00)**：李明(hmliming1)｜**实际首跳**：01",
            "| 步 | 节点 | 办理人 | 下一节点可选项 | 下一节点办理人候选 | 表单 | 公式 | 规则 | 按钮 |",
            "| 1 | 00 数量鉴定单制单 | 李明(hmliming1) | 01、06、10 | 01→李明(hmliming1)；06→李明(hmliming1)；10→梁晨晨(hmliangchenchen) | x | x | x | x |",
            "| 2 | 01 数量鉴定单审核 | 李明(hmliming1) | 02 | 02→许志伟(hmxuzhiwei) | x | x | x | x |",
            "| 3 | 02 数量鉴定单负责人 | 许志伟(hmxuzhiwei) | 99 流程结束 | 99→—（流程结束，无办理人） | x | x | x | x |",
        ])
        bs = parse_snapshot_md(sample)
        assert len(bs) == 1 and bs[0].key == "B-01", "解析分支失败"
        assert mainline(bs[0]) == ["00", "01", "02", "99"], f"主线推导失败 {mainline(bs[0])}"
        assert bs[0].steps[1].next_handlers["02"] == ["许志伟(hmxuzhiwei)"]
        print("selftest OK：快照解析 / 主线推导 / 候选办理人解析")
        return 0
    branches: list[Branch] = []
    if a.db == "snapshot":
        if not a.snapshot or not Path(a.snapshot).exists():
            print("BLOCKED：--db snapshot 需要 --snapshot <转档 md 路径>"); return 2
        branches = parse_snapshot_md(Path(a.snapshot).read_text(encoding="utf-8"))
        if not branches:
            print("BLOCKED：快照未解析到分支（确认格式为《23分支节点对应信息.md》同构）"); return 2
    else:
        import os
        try:
            branches = db_load(a.flow, os.environ)
        except RuntimeError as e:
            print(str(e)); return 2
    sel = [b for b in branches if not a.branch or b.key == a.branch or b.gk == a.branch]
    if not sel:
        print(f"BLOCKED：未找到分支 {a.branch or '(全部)'}"); return 2
    if a.mode == "multi":
        body = render_overview(sel)
    elif a.mode == "single":
        body = "\n\n".join(render_single(b) for b in sel)
    else:
        body = render_all(sel)
    if a.outdir:
        d = Path(a.outdir); d.mkdir(parents=True, exist_ok=True)
        tag = "all" if a.mode == "all" else a.mode
        (d / f"flow-tables-{tag}.md").write_text(body, encoding="utf-8")
        print(f"已生成 {d / f'flow-tables-{tag}.md'}（{len(sel)} 分支，源={a.db}）")
    else:
        print(body)
    return 0

if __name__ == "__main__":
    sys.exit(main())
