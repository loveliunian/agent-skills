#!/usr/bin/env python3
"""gen-multibranch-contract.py — 多分支流程全量契约生成器（数据驱动分支枚举）

目的：一个流程有多少分支（实查于取证源），就生成多少分支的契约 cases——
分支数永不写死。港口煤 WFA_RY_JM_126001 当前实查 23 支（2026-09-09），
其他流程（公路/铁路单分支）分支源缺省为 1。

数据源（全部为既有取证产物，零编造）：
  1) --branches-source <file>   分支定义文件（Python dict 形态：
       'B-01': "launcher|KC|firstNext|user:环节名,user:环节名,..."
     语法见 docs/港口煤发运流程/自动化测试/pcm_run.py branch_def——
     与 TC 用例/老库 SETTLE_WORKFLOW_SUB 同源）。
     解析用 ast（不 import、不执行目标文件——防任意代码执行）。
  2) --template <test-contract.yaml>  已 PASS 的基准契约（B-02）：
     继承 meta/environments/accounts 结构/forms/field_mappings/gates。
  3) --node-map <yaml>          环节名→节点码映射（从模板 nodes 段自动推导，
     未知环节名 → 该分支跳过并进待核实清单——绝不猜码）。
  4) --branch-values <json>     分支级 00 表单值（FYDW/SHDW/DZ/FZ/CS/HCBZ/GHZL/QSF…），
     缺省回退模板 case 的 s1 form 值（K C/FYDW 替换为分支矿厂）。
  5) --user-names <json>        账号→显示名（accounts.name / pick 断言），
     缺省账号 ID 本名 + 警告清单。

反向流转分支（RETURN:/WITHDRAW:/VOID@ 前缀）路由与 nodes.next 矛盾——
按守护规则 6 单独产出 explore 契约（DRAFT，仅 --drill），不进正式全量契约。

豁免（表单回显继承时点差异）不预生成——必须以真实 run 的 field-compare
diffs 为据，用 `exempt` 子命令批量生成（可审计豁免八字段：五字段 +
approval_ref/source_run_id/source_compare_sha256_16；1.3.0 起契约/对拍入口
均强制取证链，历史手工豁免须补链迁移或降 DRAFT）。

子命令：
  gen     生成全分支契约（缺省子命令）
  exempt  从 run 的 field-compare.json diffs 生成豁免 YAML 块（八字段）

用法（项目根执行）：
  python3 gen-multibranch-contract.py gen \
    --branches-source docs/港口煤发运流程/自动化测试/pcm_run.py \
    --template docs/港口煤发运流程/自动化测试/test-contract.yaml \
    --outdir docs/港口煤发运流程/自动化测试/生成件
  python3 gen-multibranch-contract.py exempt \
    --compare docs/港口煤发运流程/自动化测试/对比测试/<run-id>/field-compare.json \
    --approved-by "reviewer" >> 契约exemptions段

铁律：
  - 凭据零明文（accounts 只写 env 键名）
  - 未知环节名/缺失数据 → 跳过 + 清单，绝不猜测补位
  - 生成件受保护：重生成整体覆盖；人工校准（引擎报错回填）写进契约 notes
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

# 共享模块同目录 import：禁写字节码（skill 目录零副作用承诺——不留 __pycache__）
sys.dont_write_bytecode = True
import run_evidence  # noqa: E402  （_verify_run_dir 的唯一实现，见 scripts/run_evidence.py）

try:
    import yaml
except ImportError:
    print("⛔ 缺 pyyaml（pip install pyyaml 或 uv run --with pyyaml）", file=sys.stderr)
    sys.exit(2)

CN_TZ = timezone(timedelta(hours=8))


def _die(msg: str) -> int:
    """fail-closed 统一退出码 2（1 会与用法错误/一般异常混淆——门禁语义须可区分）。"""
    print(msg, file=sys.stderr)
    return 2


def _skill_version() -> str:
    """skill 版本（SKILL.md frontmatter）——进 meta.sources 供追溯生成器版本。"""
    try:
        head = (Path(__file__).resolve().parent.parent / "SKILL.md").read_text(encoding="utf-8").split("---")[1]
        m = re.search(r"^version:\s*(\S+)", head, re.M)
        return m.group(1) if m else "unrecorded"
    except Exception:
        return "unrecorded"

# ---------------------------------------------------------------- 分支源解析

def parse_branches_source(path: Path, var_name: str = "branch_def") -> dict[str, dict]:
    """ast 解析**受控变量**的分支定义 dict：'B-XX': "launcher|KC|firstNext|user:环节,..."。

    1.2.0 P1 收紧：此前 ast.walk 遍历文件内**所有** dict 字面量，只要键像 B-XX 就纳入/覆盖
    ——同文件的样例/缓存/无关字典会静默改变分支集合（遗漏、错误覆盖、额外 case），
    "全量"无法自证。现只在**受控作用域**内解析：
      - <var_name> 为模块级变量名 → 取该变量的 dict 字面量赋值；
      - <var_name> 为函数名（常见形态 `def branch_def(...): defs = {...}`）→ 只在该函数体内
        取 dict 字面量赋值（函数外的样例/缓存 dict 一律不看）；
      - 候选 0 个 → 拒绝（提示 --branches-var）；候选 >1 个 → 拒绝（歧义不猜）；
      - 值必须是 dict 字面量（运行时构造/函数调用不解析——生成器零执行）。
    不 import/不执行目标文件。返回 {分支号: {launcher,kc,first,segments[]}}。
    """
    src = path.read_text(encoding="utf-8")
    tree = ast.parse(src)
    defs: dict[str, str] = {}

    def _dict_assigns(scope_body: list) -> list[ast.AST]:
        """受控作用域内的分支 dict——遇嵌套函数/类体剪枝不下钻（1.2.1：此前 ast.walk
        会把嵌套函数内的 dict 当作外层函数体的定义，"受控作用域"承诺不成立）。"""
        found: list[ast.AST] = []

        def _scan(node: ast.AST) -> None:
            for child in ast.iter_child_nodes(node):
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
                    continue   # 剪枝：嵌套作用域不属于本受控作用域（不下钻）
                tg = []
                if isinstance(child, ast.Assign):
                    tg = child.targets
                elif isinstance(child, ast.AnnAssign):
                    tg = [child.target]
                if tg and any(isinstance(t, ast.Name) for t in tg) and isinstance(child.value, ast.Dict):
                    if any(isinstance(k, ast.Constant) and isinstance(k.value, str)
                           and re.fullmatch(r"B-\w+", k.value) for k in child.value.keys):
                        found.append(child.value)
                _scan(child)   # 仅在非新作用域节点内继续（if/for/try 等控制流）

        for node in scope_body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
                continue   # 受控作用域的直接子作用域同样剪枝
            tg = []
            if isinstance(node, ast.Assign):
                tg = node.targets
            elif isinstance(node, ast.AnnAssign):
                tg = [node.target]
            if tg and any(isinstance(t, ast.Name) for t in tg) and isinstance(node.value, ast.Dict):
                if any(isinstance(k, ast.Constant) and isinstance(k.value, str)
                       and re.fullmatch(r"B-\w+", k.value) for k in node.value.keys):
                    found.append(node.value)
                    continue
            _scan(node)
        return found

    candidates: list[ast.AST] = []
    scope = "module-var"
    # ① 模块级同名变量赋值（限 tree.body 顶层——类体/函数体内的同名赋值不算模块级）
    for node in tree.body:
        targets = []
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, ast.AnnAssign):
            targets = [node.target]
        else:
            continue
        for t in targets:
            if isinstance(t, ast.Name) and t.id == var_name and node.value is not None:
                candidates.append(node.value)
    # ② 同名函数体内的分支 dict（`def branch_def(bl): defs = {...}`）
    if not candidates:
        fns = [n for n in ast.walk(tree)
               if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == var_name]
        if len(fns) > 1:
            raise SystemExit(_die(f"⛔ {path}: 同名函数 {var_name!r} 定义 {len(fns)} 处——歧义不猜，请收敛为唯一定义"))
        if fns:
            scope = f"function:{var_name}"
            candidates = _dict_assigns(fns[0].body)
    if not candidates:
        raise SystemExit(_die(f"⛔ {path}: 未找到分支定义 {var_name!r}（变量或函数皆可；用 --branches-var 指定实际名字。"
                         f"拒绝全文件扫描——样例/缓存 dict 会静默污染分支集合）"))
    if len(candidates) > 1:
        raise SystemExit(_die(f"⛔ {path}: {var_name!r}（{scope}）内有 {len(candidates)} 个分支 dict 候选——歧义不猜，"
                         f"请收敛为单一受控定义"))
    holder = candidates[0]
    if not isinstance(holder, ast.Dict):
        raise SystemExit(_die(f"⛔ {path}: {var_name!r} 不是 dict 字面量（{type(holder).__name__}）——"
                         f"生成器零执行，不解析运行时构造的分支集合"))

    def harvest(d: ast.AST) -> None:
        if isinstance(d, ast.Dict):
            for k, v in zip(d.keys, d.values):
                if not (isinstance(k, ast.Constant) and isinstance(k.value, str)
                        and re.fullmatch(r"B-\w+", k.value)):
                    continue
                # 值必须是字符串常量（1.2.1）：此前非常量值（变量引用/拼接/f-string）被静默
                # 丢弃且不计入 branch_counts——契约会自称"分支总数=N"而实际漏支，正是
                # "全量无法自证"的残留形态。零执行原则下无法求值，故 fail-closed。
                if not (isinstance(v, ast.Constant) and isinstance(v.value, str)):
                    raise SystemExit(_die(
                        f"⛔ {path}: 分支 {k.value} 的值不是字符串常量（{type(v).__name__}）——"
                        f"生成器零执行无法求值；请把该分支定义写为字面量（禁止静默丢弃分支）"))
                defs[k.value] = v.value

    harvest(holder)   # 只解析受控变量的 dict 字面量（不再全文件 ast.walk）
    if not defs:
        raise SystemExit(_die(f"⛔ {path}: {var_name!r} 内无合法分支项（'B-XX': \"launcher|KC|firstNext|steps\"）"))

    branches: dict[str, dict] = {}
    for bid in sorted(defs):
        parts = defs[bid].split("|")
        if len(parts) != 4:
            raise SystemExit(_die(f"⛔ {path}: 分支 {bid} 定义段数 != 4（launcher|KC|firstNext|steps）"))
        launcher, kc, first, seg_str = (p.strip() for p in parts)
        first_action = None
        if first.startswith("VOID@"):
            first_action = "VOID"
            first = first[5:].strip()
        segments = []
        for seg in (s.strip() for s in seg_str.split(",") if s.strip()):
            if ":" not in seg:
                raise SystemExit(_die(f"⛔ {path}: 分支 {bid} 段 {seg!r} 缺 'user:环节' 形态"))
            user, _, node_name = seg.partition(":")
            user = user.strip()
            node_name = node_name.strip()
            action = None
            m = re.match(r"^(RETURN|WITHDRAW):", node_name)
            if m:
                action = m.group(1)
                node_name = node_name[m.end():].strip()
            if user.startswith("VOID@"):
                action = "VOID"
                user = user[5:].strip()
            segments.append({"user": user, "node_name": node_name, "action": action})
        branches[bid] = {"launcher": launcher, "kc": kc, "first": first,
                         "first_action": first_action, "segments": segments}
    return branches


def build_node_map(template: dict) -> dict[str, str]:
    """环节名 → 节点码（自模板 nodes 段，权威字典）。"""
    nm = {}
    for n in template.get("nodes") or []:
        if n.get("name") and n.get("code"):
            nm[n["name"]] = str(n["code"])
    return nm

# ---------------------------------------------------------------- 链构造

def branch_chain(br: dict, node_map: dict[str, str], node_map_norm: dict[str, str] | None = None) -> tuple[list[dict] | None, list[str]]:
    """分支串 → 有序环节链 [{user, node_name, code, action}]。
    环节序列 = first + 各段 node_name（重复段=该环节重办，保留——老链语义）。
    返回 (链, 警告)。无法解析的环节名 → 警告并由调用方跳过该分支。"""
    warns: list[str] = []
    chain: list[dict] = []
    seq_names: list[tuple[str, str | None]] = [(br["first"], br.get("first_action"))]
    for seg in br["segments"]:
        seq_names.append((seg["node_name"], seg["action"]))
        # 段 user 归属：段 i 的 user 办理环节 i（first 的办理人=segments[0].user …）
    # 重算：segments[i].user 办理 seq 环节 i（0 基；末段空环节名=办结步仍占位）
    names = [br["first"]] + [s["node_name"] for s in br["segments"]]
    users = [s["user"] for s in br["segments"]]
    actions = [s["action"] for s in br["segments"]]
    for i, (name, action) in enumerate(seq_names):
        user = users[i] if i < len(users) else None
        if not name:
            continue  # 末段空=办结标记
        if action is None and i > 0:
            action = actions[i - 1] if i - 1 < len(actions) else None
        code = node_map.get(name) or (node_map_norm or {}).get(_norm(name))
        if code is None:
            warns.append(f"未知环节名 {name!r}（无节点码映射）")
        chain.append({"user": user, "node_name": name, "code": code, "action": action})
    return chain, warns

# ---------------------------------------------------------------- gen 子命令

def _norm(name: str) -> str:
    """环节名归一化：剥全角/半角括号后缀（数量鉴定单制单(发起)↔数量鉴定单制单）。"""
    return re.sub(r"[（(][^（）()]*[)）]$", "", name).strip()


def cmd_gen(args, now: str) -> int:
    template_path = Path(args.template)
    # 输入前置校验（1.2.1）：此前不存在/坏 JSON 的输入在 json.loads 处以 rc=1 traceback
    # 逃逸（_src_entry 的存在性校验执行顺序靠后，形同虚设）——统一提前 fail-closed exit 2。
    def _load_json_arg(flag: str, val: str | None) -> dict:
        if not val:
            return {}
        p = Path(val)
        if not p.is_file():
            raise SystemExit(_die(f"⛔ {flag} 文件不存在: {val}"))
        try:
            obj = json.loads(p.read_text(encoding="utf-8"))
        except Exception as e:
            raise SystemExit(_die(f"⛔ {flag} 不是合法 JSON: {val}（{type(e).__name__}: {e}）"))
        if not isinstance(obj, dict):
            raise SystemExit(_die(f"⛔ {flag} 必须是 JSON 对象: {val}（得到 {type(obj).__name__}）"))
        return obj

    if not template_path.is_file():
        raise SystemExit(_die(f"⛔ --template 契约文件不存在: {template_path}"))
    try:
        template = yaml.safe_load(template_path.read_text(encoding="utf-8"))
    except Exception as e:
        raise SystemExit(_die(f"⛔ --template 不是合法 YAML: {template_path}（{type(e).__name__}: {e}）"))
    if not isinstance(template, dict) or not isinstance(template.get("meta"), dict):
        raise SystemExit(_die(f"⛔ --template 结构非法（需含 meta 段）: {template_path}"))
    branches = parse_branches_source(Path(args.branches_source), getattr(args, "branches_var", "branch_def"))
    node_map = build_node_map(template)
    node_extra: dict = _load_json_arg("--node-map-extra", getattr(args, "node_map_extra", None))
    node_map.update(node_extra)
    node_map_norm = {_norm(k): v for k, v in node_map.items()}
    branch_values: dict = _load_json_arg("--branch-values", getattr(args, "branch_values", None))
    user_names: dict = _load_json_arg("--user-names", getattr(args, "user_names", None))

    # 模板基准 case（s1 form 值回退源）
    base_case = next(c for c in template["cases"] if c.get("required"))
    base_s1_form = {}
    for st in base_case["steps"]:
        if st.get("node") == "00" and st.get("form"):
            base_s1_form = dict(st["form"])
            break

    flow_code = template["meta"]["flow_code"]
    contract = json.loads(json.dumps(template, ensure_ascii=False))  # 深拷贝
    contract["meta"]["shape"] = template["meta"].get("shape", "S2")  # 各分支仍为固定链；多分支拓扑声明见 notes
    contract["meta"]["contract_version"] = int(template["meta"].get("contract_version", 1)) + 1
    contract["meta"]["status"] = args.status
    contract["meta"]["notes"] = (template["meta"].get("notes") or "") + (
        f"\n全分支契约（数据驱动枚举，分支数以取证源实查为准）：源={args.branches_source}；"
        f"基准=模板 {template_path.name}（已 PASS 链路）；生成时刻 {now}。"
        "节点 10/35 表单全量必填补齐沿用基准模式（引擎 revision+patch 校验语义，取证坑 14）；"
        "分支级 00 值未取证处回退基准值，首跑以引擎报错为准回填（L36/L41 模式）。"
        "表单回显继承时点差异豁免不预生成——首跑后用 exempt 子命令按真实 diffs 生成。"
        "nodes[].next=全分支链并集拓扑：同节点后继因 DMN 分支路由（发起人分组收窄）而异，"
        "单 case 实际路由以该分支 steps.next 为准（服务端 DMN 终判）。")

    cases: list[dict] = []
    skipped: dict[str, str] = {}
    explore_cases: list[dict] = []
    all_accounts: dict[str, set] = {}

    for bid in sorted(branches):
        br = branches[bid]
        chain, warns = branch_chain(br, node_map, node_map_norm)
        if any(w for w in warns):
            skipped[bid] = "；".join(sorted(set(warns)))
            continue
        if any(st["action"] for st in chain):
            # 反向/作废流转 → explore 契约（DRAFT，仅 --drill；守护规则 6）
            explore_cases.append((bid, br, chain))
            continue
        # —— 正移分支 → 正式 case ——
        bv = branch_values.get(bid, {})
        kc = br["kc"]
        s1_form = dict(base_s1_form)
        s1_form.update({k: v for k, v in bv.items()})
        s1_form["KC"] = kc
        s1_form["FYDW"] = bv.get("FYDW", kc)

        steps = [{"node": "00", "actor": br["launcher"], "action": "发起+必填+基准值+记录",
                  "next": chain[0]["code"], "form": s1_form}]
        if chain and chain[0]["user"]:
            steps[-1]["pick"] = user_names.get(chain[0]["user"], chain[0]["user"])
        for i, st_node in enumerate(chain):
            nxt = chain[i + 1]["code"] if i + 1 < len(chain) else "99"
            step: dict = {"node": st_node["code"], "actor": st_node["user"],
                          "action": step_action(st_node["node_name"]), "next": nxt}
            if i + 1 < len(chain):
                nxt_user = chain[i + 1]["user"]
                if nxt_user:
                    step["pick"] = user_names.get(nxt_user, nxt_user)
            # 全量必填注入（取证坑 14：form 存在即走 SAVE_FORM，须一步补齐）
            if st_node["node_name"] == "质量鉴定单制单":
                step["form"] = _form_10(s1_form, bv, now)
                step["notes"] = "节点10必填全量补齐（引擎 revision+patch 校验；workbench 回显不含继承值）"
            if st_node["node_name"] == "95306货票明细制单":
                step["form"] = _form_35(s1_form, bv)
                step["notes"] = ("api 通道不做 95306 弹窗选行；ZJ=0=空集合计；"
                                 "form 存在即 SAVE_FORM——必填全量补齐")
            if st_node["node_name"] in ("运销科盖章", "计量章负责人盖章", "化验章负责人盖章"):
                step["action"] = "盖章可选"
            if "铁路到港运费流程" in st_node["node_name"]:
                step["action"] = "同意（APPROVE：跳转结束型，提交即办结）"
                step["notes"] = "老链 41~47 语义：提交即办结+自动启动后置流程 WFA_RY_JM_165002（23分支文档实查）；后置流程不在本契约覆盖内"
                step["next"] = "99"
            steps.append(step)
        # 末步 next=99（办结）
        cid = f"C-{bid.split('-')[1]}"
        # case id 必须合 schema `^C-[0-9]+$`（1.2.3）：含字母的分支号（B-9X/B-9Y）直接生成
        # C-9X 会在 validate 阶段被 schema 拒绝——与其产出注定不合规的正式契约，不如在生成
        # 期就明确拒绝，提示改用纯数字分支号（分支号是取证源可控命名）。
        if not re.fullmatch(r"C-[0-9]+", cid):
            raise SystemExit(_die(
                f"⛔ 分支号 {bid} 生成的 case id={cid} 不合契约 schema（要求 ^C-[0-9]+$）——"
                f"请在取证源中改用纯数字分支号（如 B-09），或将该分支移出正式分支集"))
        cases.append({
            "id": cid, "kb": f"KB-{bid.split('-')[1]}",
            "title": f"{bid} {kc} 标准全链路（{len(steps)} 步：00→{'→'.join(s['node'] for s in steps[1:])}→99）",
            "required": True, "steps": steps,
            "assertions": [
                "路径逐环节一致",
                "发起人已办结流程可查流程编号",
            ],
        })
        for st in [ {"user": br["launcher"]}] + [{"user": s["user"]} for s in chain]:
            u = st["user"]
            if u:
                all_accounts.setdefault(u, set())
        for i, st_node in enumerate(chain):
            if st_node["user"]:
                all_accounts[st_node["user"]].add(st_node["node_name"])

    if not cases:
        print("⛔ 无可生成正移分支（全部被跳过/反向）——检查环节名映射", file=sys.stderr)
        return 2
    contract["cases"] = cases

    # nodes 段扩量 + next 重构为全分支链并集（多分支拓扑：同节点后继因 DMN
    # 分支路由而异；单分支实际路由由服务端 DMN 按发起人收窄——notes 已声明）
    name_of = {v: k for k, v in node_map.items()}
    handlers_of: dict[str, set] = {}
    succ: dict[str, set] = {}
    for c in cases:
        seq = [s["node"] for s in c["steps"]] + ["99"]
        for cur, nxt in zip(seq, seq[1:]):
            succ.setdefault(str(cur), set()).add(str(nxt))
        for s in c["steps"]:
            handlers_of.setdefault(str(s["node"]), set()).add(s["actor"])
    existing = {str(n.get("code")): n for n in contract.get("nodes") or []}
    order: list[str] = []
    for n in contract.get("nodes") or []:
        order.append(str(n.get("code")))
    for code in sorted(succ, key=lambda x: (len(x), x)):
        if code not in existing:
            existing[code] = {"code": code, "name": name_of.get(code, code),
                              "form": None, "handlers": sorted(handlers_of.get(code, set())),
                              "pool": [], "re_edit": False,
                              "note": "多分支扩量节点（生成器按分支链并集补入；表单码待该分支首跑核实）"}
            order.append(code)
    contract["nodes"] = [existing[c] for c in order if c in existing]
    for n in contract["nodes"]:
        code = str(n.get("code"))
        if code in succ:
            n["next"] = sorted(succ[code], key=order.index)

    # accounts 扩量（env 键推导：非 [A-Z0-9] 字符 → 下划线，大写）
    tpl_accounts = {a["id"]: a for a in template.get("accounts") or []}
    accounts = []
    for aid in sorted(all_accounts):
        if aid in tpl_accounts:
            accounts.append(tpl_accounts[aid])
            continue
        env_key = "CURRENT_" + re.sub(r"[^A-Z0-9]", "_", aid.upper()) + "_PWD"
        accounts.append({"id": aid, "name": user_names.get(aid, aid), "env": env_key,
                         "role": "/".join(sorted(all_accounts[aid]))})
    contract["accounts"] = accounts

    # 取证源指纹（1.2.0 P1）：正式契约必须能自证"取证源全量"——登记每个输入源的
    # 绝对路径 + SHA256 全长 + 解析口径（受控变量名），以及分支计数三态（总数/正移/反向/跳过）。
    # 无此段的多分支契约只能证明"生成结果"，无法证明输入未被替换/裁剪。
    def _src_entry(role: str, p: str | None, extra: dict | None = None) -> dict | None:
        if not p:
            return None
        pp = Path(p)
        if not pp.is_file():
            raise SystemExit(_die(f"⛔ 取证源不存在: {role}={p}（无法登记指纹，拒绝生成）"))
        ent = {"role": role, "path": str(pp.resolve()),
               "sha256": hashlib.sha256(pp.read_bytes()).hexdigest()}
        if extra:
            ent.update(extra)
        return ent

    # 可选源"未提供"也必须显式登记（1.2.1）：否则读者无法区分"该源确实没用过"与
    # "用了但登记被省略/裁剪"——自证缺口。supplied=false 让"没用过"成为显式断言。
    _optional = (("node_map_extra", getattr(args, "node_map_extra", None), "未提供：未知环节名分支一律跳过（不猜码）"),
                 ("branch_values", getattr(args, "branch_values", None), "未提供：分支级 00 表单值回退基准模板 s1 form"),
                 ("user_names", getattr(args, "user_names", None), "未提供：accounts.name 回退账号 ID 本名"))
    src_entries = [e for e in (
        _src_entry("branches_source", args.branches_source,
                   {"parsed_var": getattr(args, "branches_var", "branch_def"), "parser": "ast-literal(zero-exec)"}),
        _src_entry("template_contract", str(template_path)),
    ) if e]
    for role, val, effect in _optional:
        ent = _src_entry(role, val)
        if ent:
            ent["supplied"] = True
            src_entries.append(ent)
        else:
            src_entries.append({"role": role, "supplied": False, "path": None, "sha256": None, "effect": effect})
    # sources 保持列表形态（schema 约束）：继承模板 sources + 生成输入源指纹逐条追加
    prev_sources = list(template.get("meta", {}).get("sources") or [])
    out_sources = list(prev_sources)
    for i, e in enumerate(src_entries, 1):
        if e.get("supplied") is False:
            out_sources.append({"id": f"MB-{i}", "kind": "doc",
                                "detail": f"多分支生成输入[{e['role']}] supplied=false（{e['effect']}）"})
        else:
            out_sources.append({"id": f"MB-{i}", "kind": "doc",
                                "detail": (f"多分支生成输入[{e['role']}] path={e['path']} "
                                           f"sha256={e['sha256']}")})   # 全长 sha256（机器可重算比对）
    out_sources.append({"id": "MB-GEN", "kind": "doc",
                        "detail": (f"gen-multibranch-contract.py（skill {_skill_version()}）生成于 {now}；"
                                    f"分支计数 总数={len(branches)} 正移={len(cases)} "
                                    f"反向={len(explore_cases)} 跳过={len(skipped)}"
                                    + (f"；跳过明细: {skipped}" if skipped else ""))})
    contract["meta"]["sources"] = out_sources

    # 分支覆盖结构化字段（1.2.3 P0/P1；1.3.0 P1 双态化）：此前只把计数塞进 sources[].detail
    # 自由文本，validator 无法解析、conclude 也无从交叉核验——"取证源 23 支、跳过 2 支、
    # 21/21 通过"就成了名义上的"全分支 PASS"。现落为机器可校验的 meta.branch_coverage，并要求
    # total == formal + reverse + skipped 恒等。完成度拆为双态（1.3.0）：
    #   accounted_complete：全部分支已分类（无未知环节跳过）——账目完整；
    #   formal_complete：且反向分支为 0——所有分支均有正式执行路径。
    # reverse_explore>0 时本契约只覆盖正向分支：conclude 会把结论限定为
    # 『正向分支 PASS / 反向未正式验证』，绝不表述为全分支 PASS。
    contract["meta"]["branch_coverage"] = {
        "total_in_source": len(branches),
        "formal_cases": len(cases),
        "reverse_explore": len(explore_cases),
        "skipped_unknown_node": len(skipped),
        "skipped_detail": {b: why for b, why in sorted(skipped.items())},
        "accounted_complete": len(skipped) == 0,
        "formal_complete": len(skipped) == 0 and len(explore_cases) == 0,
        "complete": len(skipped) == 0,  # 兼容 1.2.x 语义 = accounted_complete（1.3.0 起以双态为准）
        "branches_source": str(Path(args.branches_source).resolve()),
        "branches_var": getattr(args, "branches_var", "branch_def"),
        "generated_at": now,
        "generator_skill_version": _skill_version(),
        "source_fingerprints": [
            {k: v for k, v in e.items() if k in ("role", "path", "sha256", "supplied", "parsed_var", "effect")}
            for e in src_entries
        ],
    }

    # ---------------- P0 门禁（1.2.3）：不完整分支集不得成为正式契约 ----------------
    # 此前 skipped>0 仍产出 status=TEST_READY 且 exit 0——取证源 23 支、跳过 2 支时，
    # 正式契约只有 21 cases，跑完 21/21 即被当作"全分支 PASS"，分母被静默缩小。
    # 现在：TEST_READY 要求 skipped==0；确需保留待核实结果只能显式 --status DRAFT，
    # 且产物文件名强制带 partial 标识，防止被误当正式全量契约使用。
    if skipped and args.status == "TEST_READY":
        raise SystemExit(_die(
            f"⛔ 分支集不完整（{len(skipped)}/{len(branches)} 支因未知环节名被跳过），"
            f"拒绝产出 TEST_READY 正式契约——否则 {len(cases)}/{len(cases)} 通过会被误读为『全分支 PASS』。\n"
            f"   跳过明细: " + "；".join(f"{b}({why})" for b, why in sorted(skipped.items())) + "\n"
            f"   出路二选一：\n"
            f"     ① 实查这些环节的节点码 → --node-map-extra 补入后重新生成（推荐，得正式全量契约）；\n"
            f"     ② 仅需待核实草稿 → 加 --status DRAFT（产物标记 partial，禁止用于正式执行/结论）"))
    if skipped and args.status == "DRAFT":
        stem, _, ext = args.out_name.rpartition(".")
        if "partial" not in (stem or args.out_name):
            args.out_name = f"{stem}.partial.{ext}" if stem else f"{args.out_name}.partial"
        contract["meta"]["notes"] = (contract["meta"].get("notes") or "") + (
            f"\n⚠ PARTIAL：{len(skipped)}/{len(branches)} 支因未知环节名被跳过，本契约非全量——"
            f"禁止用于正式执行与结论；补齐 --node-map-extra 后重新生成方可 TEST_READY。")

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    out = outdir / args.out_name
    out.write_text(yaml.safe_dump(contract, allow_unicode=True, sort_keys=False, width=120),
                   encoding="utf-8")

    # actorMap 增量建议（双端；runtime 私有配置由执行者确认后并入）
    inc = {"_说明": "actorMap 增量建议（生成器输出；确认后并入 skill runtime systems api/{current,legacy}.yaml；凭据键在 $RUNTIME_DIR/env 实存，或以 FLOWTEST_DEFAULT_PWD 统一默认密码兜底）",
           "current": {}, "legacy": {}}
    for aid in sorted(all_accounts):
        if aid in tpl_accounts:
            continue
        k = re.sub(r"[^A-Z0-9]", "_", aid.upper())
        inc["current"][aid] = {"username": f"CURRENT_{k}_USER", "password": f"CURRENT_{k}_PWD"}
        inc["legacy"][aid] = {"username": f"LEGACY_{k}_USER", "password": f"LEGACY_{k}_PWD"}
    (outdir / "actorMap.increment.yaml").write_text(
        yaml.safe_dump(inc, allow_unicode=True, sort_keys=False), encoding="utf-8")

    # 报告
    print(f"✅ 全分支契约 → {out}")
    print(f"   正移分支 case 数: {len(cases)}（分支号 {'、'.join(sorted(c['id'] for c in cases))}）")
    if explore_cases:
        print(f"   反向/作废分支（未进正式契约，守护规则 6）: {'、'.join(b for b, _, _ in explore_cases)}")
        print(f"   ⚠ 本契约 formal_complete=false（{len(explore_cases)} 支反向仅探索未正式化）——"
              f"后续 run 结论将限定为『正向分支 PASS / 反向未正式验证』，"
              f"不得表述为全分支 PASS；如需反向正式结论，请为 RETURN/WITHDRAW/VOID "
              f"建独立正式契约（cases[].notes 显式声明特殊流转）并单独跑 run 绑定结果")
    if skipped:
        print(f"   ⚠ 跳过分支（待人工核实，绝不猜码）: ")
        for b, why in sorted(skipped.items()):
            print(f"     {b}: {why}")
    acc_missing = (_check_env_keys(accounts, Path(args.check_env), set(tpl_accounts))
                   if args.check_env else [])
    if acc_missing:
        print(f"   ⚠ env 缺凭据键 {len(acc_missing)} 个（未设 FLOWTEST_ALLOW_DEFAULT_PWD=1 + FLOWTEST_DEFAULT_PWD 时执行期 BLOCKED；"
              f"补 $RUNTIME_DIR/env 键或显式授权统一默认密码）: {acc_missing[:8]}{'…' if len(acc_missing) > 8 else ''}")
    print(f"   actorMap 增量建议 → {outdir / 'actorMap.increment.yaml'}")
    print(f"   取证源指纹已登记 meta.sources（{len(src_entries)} 源）：分支源 sha={src_entries[0]['sha256'][:16]}"
          f" 分支总数={len(branches)} 正移={len(cases)} 反向={len(explore_cases)} 跳过={len(skipped)}")
    return 0


def step_action(node_name: str) -> str:
    if "审核" in node_name:
        return "SHYJ 审核通过"
    if "复核" in node_name:
        return "复核+提交"
    if "制单" in node_name:
        return "保存+提交"
    if "盖章" in node_name:
        return "盖章可选"
    if "负责人" in node_name:
        return "同人续办"
    return "保存+提交"


def _form_10(s1_form: dict, bv: dict, now: str) -> dict:
    """节点 10（质量鉴定单制单）必填全量（B-02 run-20260909141848 实锤字段集）。"""
    return {
        "CYRQ": "${TODAY}",
        "FYDW": s1_form.get("FYDW", ""),
        "SHDW": bv.get("SHDW", s1_form.get("SHDW", "")),
        "FZ": bv.get("FZ", s1_form.get("FZ", "")),
        "DZ": bv.get("DZ", s1_form.get("DZ", "")),
        "KC": s1_form.get("KC", ""),
        "CS": bv.get("CS", s1_form.get("CS", "")),
        "GHZL": bv.get("GHZL", s1_form.get("GHZL", "")),
        "HCBZ": bv.get("HCBZ", s1_form.get("HCBZ", "")),
        "FYRQ": bv.get("FYRQ", s1_form.get("FYRQ", "")),
    }


def _form_35(s1_form: dict, bv: dict) -> dict:
    """节点 35（95306）必填全量（ZJ=0 空集合计 + 继承字段；run-20260909145913 实锤）。"""
    f = _form_10(s1_form, bv, "")
    f.pop("CYRQ", None)
    f["ZJ"] = "0"
    return f


def _check_env_keys(accounts: list[dict], env_path: Path, inherited_ids: set) -> list[str]:
    """仅核查新增账号的 env 键（模板继承账号的凭据键由 runtime actorMap 映射管理，
    契约 env 键只是校验别名——不重复检查防误报）。"""
    if not env_path.exists():
        return [a["env"] for a in accounts if a["id"] not in inherited_ids]
    env_text = env_path.read_text(encoding="utf-8")
    missing = []
    for a in accounts:
        if a["id"] in inherited_ids:
            continue
        if not re.search(rf"^export {re.escape(a['env'])}=", env_text, re.M):
            missing.append(a["env"])
    return missing

# ---------------------------------------------------------------- exempt 子命令

def _verify_run_dir(run_dir: Path) -> tuple[dict, dict, Path, str]:
    """豁免取证链核验（1.2.0 P1 引入；1.3.1 P0 起委托共享模块 run_evidence.verify_run_dir）。

    核验链（任一不过=fail-closed exit 2，不产出任何豁免）：
      五件证据齐全（账本/结论/对拍/门禁/用例，实体文件拒符号链接）→ JSON 可解析 →
      run-id 三方一致 → fc 已登记账本且 sha 现算一致 → 结论 ∈ PASS/FAIL →
      toolchain 指纹完整 → 底层证据轻量重算（gates 全过/必测全 PASS/fc 状态自洽）。
    唯一实现见 scripts/run_evidence.py（validate-contract 契约入口共用同一份——
    不得在消费方另写简化版核验，1.3.1 P0 教训）。
    返回 (manifest, compare_json, compare_path, compare_sha16)。
    """
    try:
        ev = run_evidence.verify_run_dir(run_dir)
    except run_evidence.RunEvidenceError as e:
        raise SystemExit(_die(f"⛔ {e}"))
    return ev["manifest"], ev["fc"], ev["fc_path"], ev["fc_sha16"]


def cmd_exempt(args) -> int:
    run_dir = Path(args.run_dir).resolve()
    mf, d, fc_p, fc_sha = _verify_run_dir(run_dir)
    diffs = d.get("diffs") or []
    # key 白名单（1.2.1 P0）：此前 diffs[].key 未净化直接 f-string 拼进 YAML——含 `"`/换行的
    # key 可注入出「scope: all / match: "*"」的全局豁免（解析合法、语义被伪造，还自带取证链
    # 字段骗过人工核阅）。现双保险：① 严格白名单拒非法 key；② 输出改 yaml.safe_dump 序列化。
    KEY_RE = re.compile(r"[\w.\-]+/[\w.\-]+/[\w.\-]+(->[\w.\-]+)?")
    bad_keys, keys = [], set()
    for x in diffs:
        if not isinstance(x, dict) or x.get("reason") != args.reason:
            continue
        k = x.get("key")
        if not isinstance(k, str) or not KEY_RE.fullmatch(k):
            bad_keys.append(repr(k)[:80])
            continue
        keys.add(k.split("/", 1)[1])
    if bad_keys:
        raise SystemExit(_die(f"⛔ field-compare diffs 含非法 key（形态须 case/step/field[->field]，"
                              f"禁止引号/换行/路径穿越——防豁免 YAML 注入）: {bad_keys[:5]}"))
    keys = sorted(keys)
    if not keys:
        print("（无匹配 diffs——零豁免生成）")
        return 0
    tc = mf.get("toolchain") or {}
    src_rid = str(mf.get("run_id"))
    vers = mf.get("versions") if isinstance(mf.get("versions"), dict) else {}
    items = []
    for k in keys:
        step, fk = k.split("/", 1)
        fid = fk.split("->")[0]
        items.append({"id": f"EXC-ECHO-{step.upper()}-{fid}", "scope": "field", "match": k,
                      "reason": args.reason_desc, "approved_by": args.approved_by,
                      "approval_ref": args.approval_ref, "source_run_id": src_rid,
                      "source_compare_sha256_16": fc_sha})
    header = (f"  # 由真实 run {src_rid} 的 field-compare diffs 生成（reason={args.reason}，{len(keys)} 条）\n"
              f"  # 取证链：run_dir={run_dir} compare_sha256_16={fc_sha} "
              f"skill={tc.get('skill_version')} flow_version={vers.get('flow')}——人工核阅后并入契约 exemptions[]")
    body = yaml.safe_dump(items, allow_unicode=True, sort_keys=False, width=200, default_flow_style=False)
    print(header)
    print("\n".join("  " + ln if ln.strip() else ln for ln in body.rstrip("\n").split("\n")))
    return 0

# ---------------------------------------------------------------- main

def main() -> int:
    now = datetime.now(CN_TZ).strftime("%Y-%m-%dT%H:%M:%S+08:00")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")

    g = sub.add_parser("gen", help="生成全分支契约（分支数=取证源实查数，不写死）")
    g.add_argument("--branches-source", required=True, help="分支定义文件（dict 形态 'B-XX': 'l|k|f|steps'）")
    g.add_argument("--branches-var", default="branch_def",
                   help="分支源文件中受控变量名（默认 branch_def；1.2.0 起仅解析此变量的 dict 赋值——"
                        "拒绝全文件扫描，避免同一文件样例/缓存值静默污染分支集合）")
    g.add_argument("--template", required=True, help="基准契约（已 PASS）YAML")
    g.add_argument("--outdir", required=True)
    g.add_argument("--out-name", default="test-contract.full.yaml")
    g.add_argument("--branch-values", help="分支级 00 表单值 JSON（{ 'B-XX': {字段: 值} }）")
    g.add_argument("--user-names", help="账号→显示名 JSON")
    g.add_argument("--node-map-extra", help="环节名→节点码补充 JSON（执行者实查后传入；缺=未知环节分支跳过）")
    g.add_argument("--check-env", help="env 文件路径（凭据键存在性核查，缺失=警告清单；"
                                       "缺省跳过——执行期以 $RUNTIME_DIR/env / 显式授权的 FLOWTEST_DEFAULT_PWD 兜底）")
    g.add_argument("--status", default="TEST_READY", choices=["TEST_READY", "DRAFT"])
    g.set_defaults(func=lambda a: cmd_gen(a, now))

    e = sub.add_parser("exempt", help="从真实 run 的 field-compare diffs 批量生成豁免块（强制核验账本链）")
    e.add_argument("--run-dir", required=True,
                   help="run 目录 docs/<流程>/自动化测试/对比测试/<run-id>/（内部核验账本/结论/对拍 sha 一致）")
    e.add_argument("--reason", default="null_policy")
    e.add_argument("--reason-desc", default="表单回显继承时点差异（表示层）：业务值同实例同源一致，环节原始值对拍不受影响")
    e.add_argument("--approved-by", required=True)
    e.add_argument("--approval-ref", required=True, help="审批工单号/签名引用（可追溯，进豁免块 approval_ref）")
    e.set_defaults(func=lambda a: cmd_exempt(a))

    args = ap.parse_args()
    if not getattr(args, "func", None):
        ap.print_help()
        return 2
    return args.func(args)


if __name__ == "__main__":
    # 顶层兜底（1.2.1）：任何未预期异常折为 exit 2——此前 FileNotFoundError/ValueError/
    # AttributeError 等以 rc=1 + traceback 逃逸，与"用法错误/一般异常"语义混淆，
    # 门禁脚本按 rc==2 判"契约拒绝"会误判。
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as _e:
        import traceback

        traceback.print_exc()
        sys.exit(_die(f"⛔ 生成器内部异常（fail-closed，未产出任何契约/豁免）: {type(_e).__name__}: {_e}"))
