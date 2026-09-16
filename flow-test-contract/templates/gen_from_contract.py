#!/usr/bin/env python3
"""gen_from_contract.py —— test-contract.yaml 同源生成器（五产物）。

第六轮审计（2026-09-06）：写盘前结构预检（cases/meta/steps 类型畸形→零写入拒绝，
不再 traceback crash 残留半截产物）+ 顶层异常兜底（干净 exit 1）。

输入: docs/<流程>/自动化测试/test-contract.yaml（唯一机器可读契约）
输出（--outdir，建议 生成件/，勿覆盖人工精修文档）:
  ① 浏览器手工测试用例.md          —— 新系统人工用例骨架（表格由契约填充）
  ② 老系统浏览器对比测试用例.md    —— 老系统对比用例骨架（KB 与 C 同源）
  ③ flowtrace-scenarios/<case>.yaml —— 可执行 FlowTrace 场景（含 fixture_pair_id）
  ④ compare-rules.yaml / .json      —— 字段映射与比较规则（供 field-level-compare.py）
  ⑤ report-skeleton.md + summary.template.json —— 最终报告骨架

用法:
  uv run --with pyyaml,jsonschema python3 <skill>/templates/gen_from_contract.py \
    --contract docs/<流程>/自动化测试/test-contract.yaml \
    --outdir   docs/<流程>/自动化测试/生成件
  （项目部署布局：脚本位于 docs/自动化测试模板/gen_from_contract.py）

规范: 凭据零落盘（accounts 仅 env 引用）；生成件头部强制标注契约版本与 run 门禁。
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：uv run --with pyyaml python3 gen_from_contract.py ...")

import math


def find_nonfinite(o, path="$"):
    """第十轮审计：契约任意位置的 .inf/.nan（YAML 原生浮点）——rules 的 json.dumps 默认
    会写出非标准 JSON 字面量 Infinity（对拍端 exact 路径 inf==inf 假 MATCH）。立契源头
    零写入拒绝（与 validate/对拍端三端同口径）。"""
    if isinstance(o, float) and not math.isfinite(o):
        return [f"{path} = {o!r}（.inf/.nan=非有限数值，对拍端一律 BLOCKED）"]
    if isinstance(o, dict):
        return [m for k, v in o.items() for m in find_nonfinite(v, f"{path}.{k}")]
    if isinstance(o, list):
        return [m for i, v in enumerate(o) for m in find_nonfinite(v, f"{path}[{i}]")]
    return []


def gen_manual_doc(c: dict) -> str:
    m = c["meta"]
    lines = [
        f"# {m['flow_name']} 浏览器手工测试用例（契约生成）",
        "",
        "> 🔒 **受保护文件：100% 由 test-contract.yaml 生成，重新生成会整体覆盖**——人工内容一律写进契约（meta.notes / meta.risk_seeds / cases[].notes / nodes[].note），勿手改本文件（避免双源漂移）。",
        f"> 生成来源: test-contract.yaml（contract_version={m['contract_version']}，{m['shape']} 形态，status={m.get('status','DRAFT')}）。",
        "> **凭据**: 一律 `env` 名引用（`CURRENT_<账号大写>_PWD`），值运行时由 `$RUNTIME_DIR/env` 或显式授权的 `FLOWTEST_DEFAULT_PWD` 提供，本文档不含明文密码。",
        "> **结论门禁**: 执行结果须经 conclude.py 判定 PASS/FAIL/BLOCKED 并落 run-manifest.json；无新 run-id 的全量重跑不得沿用历史结论。",
    ]
    if m.get("notes"):
        lines += ["", f"## 0. 契约备注（meta.notes）", "", m["notes"]]
    if m.get("risk_seeds"):
        lines += ["", "## 0.1 风险种子（meta.risk_seeds）", ""] + [f"- {r}" for r in m["risk_seeds"]]
    lines += ["", "## 1. 节点与处理人（同源表）", "",
              "| 节点 | 名称 | 表单(老) | 办理账号 | 候选池(OPER_USER) | 下一环节 | 备注 |",
              "|---|---|---|---|---|---|---|"]
    acc_names = {a["id"]: a["name"] for a in c.get("accounts", [])}
    for n in c.get("nodes", []):
        hs = "、".join(f"{acc_names.get(h, h)}({h})" for h in n.get("handlers", []))
        note = []
        if n.get("seal"): note.append("盖章:" + str(n["seal"]))
        if n.get("return_mine"): note.append("退回至矿点")
        if n.get("unreachable"): note.append("孤立节点")
        if n.get("must_not_contain"): note.append(f"候选禁含{n['must_not_contain']}")
        lines.append(f"| {n['code']} | {n['name']} | {n.get('form','')} | {hs} | {n.get('pool','')} | {'/'.join(n.get('next',[]))} | {'；'.join(note)} |")
    lines += ["", "## 2. 用例步骤表（C-xx，同源于契约 cases）", ""]
    for case in c.get("cases", []):
        lines += [f"### {case['id']} {case['title']}（KB 对应 {case.get('kb','—')}；required={case.get('required', True)}）", "",
                  "| 步 | 节点 | 办理账号 | 操作 | 提交后 | 选人 |", "|---|---|---|---|---|---|"]
        for i, s in enumerate(case.get("steps", []), 1):
            lines.append(f"| {i} | {s.get('node','-')} | {s.get('actor','-')} | {s.get('action','-')} | {s.get('next','-')} | {s.get('pick','-')} |")
        lines += ["", f"**断言**: {'；'.join(case.get('assertions', []))}"]
        if case.get("notes"):
            lines += ["", f"**契约备注**: {case['notes']}"]
        lines += [""]
    return "\n".join(lines)


def gen_compare_doc(c: dict) -> str:
    m = c["meta"]
    lines = [
        f"# {m['flow_name']} 老系统浏览器对比测试用例（契约生成）",
        "",
        "> 🔒 **受保护文件：100% 由 test-contract.yaml 生成，重新生成会整体覆盖**——人工内容写进契约，勿手改本文件。",
        f"> **生成来源**: test-contract.yaml v{m['contract_version']}（status={m.get('status','DRAFT')}）——KB 用例与手工用例 C-xx 同源。",
        "> **字段值结论规则**: 仅当 field_mappings 存在合同且 fixture 配对（fixture_pair_id）时才可判 一致/不一致；未配对的双端选数只记 OBSERVE。",
        "> **像素 diff**: dual-run-diff.js 输出为辅助证据（evidenceTier=auxiliary），不进入结论。",
        "",
        "## 1. 语义比较合同（field_mappings）", "",
        "| legacy→target | 归一化 | 容差 | 空值策略 | 字典映射 | 脱敏 | fixture 必需 | 公式 |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for f in c.get("field_mappings", []):
        lines.append(f"| {f['legacy_field']}→{f['target_field']} | {f.get('normalize','')} | {f.get('tolerance','')} | {f.get('null_policy','')} | {f.get('dict_map_ref','-')} | {f.get('redact','none')} | {f.get('fixture_pair_required', False)} | {f.get('formula_ref','-')} |")
    lines += ["", "## 2. 公式对拍（formulas）", "", "| # | 公式 | 输入 | 老系统期望 | 容差 | 挂载节点 | 新系统 |", "|---|---|---|---|---|---|---|"]
    for f in c.get("formulas", []):
        lines.append(f"| {f['id']} | {f['expr']} | {json.dumps(f.get('inputs',{}), ensure_ascii=False)} | {f.get('expected_legacy', f.get('expected_delta_legacy','-'))} | {f.get('tolerance','-')} | {'/'.join(f.get('nodes_applied',[]))} | {f.get('current_note','待实测')} |")
    lines += ["", "## 3. 路由/按钮/资源/后置合同", "",
              "- routing: " + json.dumps([{r['node']: r.get('candidates_legacy')} for r in c.get('routing', [])], ensure_ascii=False),
              "- buttons: " + json.dumps(c.get('buttons', []), ensure_ascii=False),
              "- resources: " + json.dumps(c.get('resources', []), ensure_ascii=False),
              "- post_flow: " + json.dumps(c.get('post_flow', {}), ensure_ascii=False), "",
              "## 4. KB 用例（与 C 同源，步骤表见手工骨架）", ""]
    for case in c.get("cases", []):
        lines.append(f"- **{case.get('kb', case['id']+'?')}**（对照 {case['id']}）：{case['title']}——断言：{'；'.join(case.get('assertions', []))}")
    lines += ["", "## 5. 结论门禁", "", "PASS/FAIL/BLOCKED 由 conclude.py 按 conclusions 规则判定（见 run-manifest.json）。", ""]
    return "\n".join(lines)


def gen_scenario(case: dict, c: dict, draft_mark: str = "") -> str:
    """场景用 yaml.safe_dump 产出（防特殊字符串破坏 YAML），头部注释单独前置。"""
    m = c["meta"]
    # 第二十轮（实测反哺）：'任一/any' 占位 actor → meta.observer_actor 具体账号
    # （runner 按 actorMap 查账号，占位符必然 BLOCKED；观察类步骤语义=任一合格用户，
    #   由契约指定具体观察账号落地，场景内替换并注明）
    obs = str(m.get("observer_actor") or "").strip()

    def _actor(a) -> str:
        a = str(a or "").strip()
        if obs and a in ("任一", "any", "ANY"):
            return obs
        return a

    import re as _re

    def _assignee(pick) -> str:
        """机器字段归一化（第二十一轮）：剥『(xx)』『（xx）』注记后缀（常琨(公路)→常琨），
        供 api-capture/适配解析按姓名匹配服务端候选；人工阅读口径见契约与生成文档（保留原注记）。"""
        return _re.sub(r"[（(][^（）()]*[)）]\s*$", "", str(pick or "")).strip()

    doc = {
        "id": f"{m['flow_code']}-{case['id'].lower()}",
        # 第十三轮·审计修复：直接 emit flow_code（不再依赖 rsplit id 反推——flow_code 含连字符时 rsplit 会切错）
        "flow_code": str(m["flow_code"]),
        "case_id": case["id"],  # 契约用例号（runner/conclude 以此与契约 cases 对账）
        "name": f"{m['flow_name']} {case['id']} {case['title']}",
        "flowDef": m["flow_name"],
        "process": "dual-run",  # 双端执行；单端可改 single-current
        "severity": "P1",
        "tags": ["contract", m["shape"], case["id"]],
        "required": bool(case.get("required", True)),
        "steps": [{"seq": i, "node": st.get("node"), "taskName": f"{st.get('node') or '-'} {st.get('action', '')}",
                   "actorAccount": _actor(st.get("actor")),  # 密码运行时经 env 注入（$RUNTIME_DIR/env / 显式授权 FLOWTEST_DEFAULT_PWD 兜底），永不写入场景；'任一'→observer_actor
                   "expectNext": st.get("next"), "expectAssignee": _assignee(st.get("pick")),
                   **({"formData": st["form"]} if isinstance(st.get("form"), dict) and st["form"] else {}),
                   "capture": "form-fields"}  # 双端执行后抓取表单字段值（供 field-level-compare）
                  for i, st in enumerate(case.get("steps", []), 1)],
        "assertions": list(case.get("assertions", [])),
        "compare": {"rules": "compare-rules.yaml", "pixelDiff": "auxiliary"},  # 像素 diff 仅辅助证据
        "instancePolicy": str(m.get("instance_policy") or "launch"),  # 第十三轮：launch=每 run 发起新实例（默认）；reuse=显式声明才复用待办
    }
    fps = [f["fixture_pair_id"] for f in c.get("fixtures", [])]
    if fps:
        doc["fixturePairs"] = fps  # 双端各自选数时必须登记配对，否则字段值只记 OBSERVE
    # 审计第 5 轮 P1-3：reuse 消歧选择器从契约透传进场景（此前 schema/生成链均缺——
    # 文档承诺的 instanceNo/businessKey/fixtureSelector 无法经正式链使用，生成件又禁手改）。
    # 值可为标量或 {legacy, current} 分侧映射（api-capture 按 systems id 取侧值）。
    if str(m.get("instance_policy") or "") == "reuse":
        _sel = {}
        for _k in ("instanceNo", "businessKey", "fixtureSelector"):
            _v = case.get(_k)
            if isinstance(_v, str) and _v.strip():
                _sel[_k] = _v.strip()
            elif isinstance(_v, dict) and _v:
                _bad = {kk: vv for kk, vv in _v.items()
                        if not (isinstance(vv, str) and vv.strip())}
                if _bad:
                    raise SystemExit(f"契约用例 {case['id']} 的 {_k} 分侧值非法（须非空字符串）: {_bad}")
                if not ({"legacy", "current"} <= set(_v)):
                    raise SystemExit(f"契约用例 {case['id']} 的 {_k} 分侧映射须含 legacy 与 current 两键: {_v}")
                _sel[_k] = {kk: vv.strip() for kk, vv in _v.items()}
        if _sel:
            doc.update(_sel)
    header = (f"# 由 test-contract.yaml v{m['contract_version']} 生成（勿手改，重生成覆盖）"
              + (f" {draft_mark}" if draft_mark else "") + "\n")
    return header + yaml.safe_dump(doc, allow_unicode=True, sort_keys=False)


def gen_compare_rules(c: dict, formal: bool = True) -> dict:
    meta = {"flow_code": c["meta"]["flow_code"], "contract_version": c["meta"]["contract_version"]}
    if not formal:
        meta["draft"] = True  # 草稿规则不得进入正式对拍（field-level-compare 可识别）
    return {
        "meta": meta,  # 无时间戳：同契约重生成字节一致
        "field_mappings": c.get("field_mappings", []),
        "dict_maps": c.get("dict_maps", {}),
        "fixtures": c.get("fixtures", []),
        "formulas": c.get("formulas", []),
        "routing": c.get("routing", []),
        "buttons": c.get("buttons", []),
        "resources": c.get("resources", []),
        "post_flow": c.get("post_flow", {}),
        "conclusions": c.get("conclusions", {}),
        "exemptions": c.get("exemptions", []),
        "aux_evidence": {"pixel_diff": "auxiliary only, never a verdict"},
    }


def gen_report_skeleton(c: dict) -> str:
    m = c["meta"]
    return "\n".join([
        f"# {m['flow_name']} 新老对比执行报告（骨架）", "",
        "> 本骨架由契约生成；每次执行以 run-manifest.json 落账，结论三态 PASS/FAIL/BLOCKED 由 conclude.py 判定。", "",
        "## Run 信息（run-manifest.json 回填）",
        "| 项 | 值 |", "|---|---|",
        "| run_id / 执行者 / 时间 |  |",
        "| 源/目标发布版本、流程版本 |  |",
        "| 配置快照 hash / 测试数据指纹 |  |",
        "| 实例号对（legacy↔current） |  |",
        "| 证据路径 / 比较器版本 |  |",
        "", "## 结论", "", "- conclusion: <PASS|FAIL|BLOCKED>", "- P0=__ P1=__；required 用例完成度 __/__", "",
        "## 语义差异（未豁免）", "", "| 维度 | 项 | legacy | current | 合同 | 级别 |", "|---|---|---|---|---|---|",
        "", "## 豁免差异", "", "## 辅助证据（不构成结论）", "",
        "- 像素 diff（evidenceTier=auxiliary）：__ 步，平均相似度 __%", "",
        "## Gate 明细", "",
    ]) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--contract", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--allow-draft", action="store_true",
                    help="允许 DRAFT 契约生成（产物头部打 DRAFT 水印，仅供草稿评审，禁止执行）")
    args = ap.parse_args()

    # fail-closed：生成前强制校验（未过 test_ready 且未显式 --allow-draft → 拒绝生成）
    import subprocess
    vcmd = [sys.executable, str(Path(__file__).parent / "validate-contract.py"),
            "--contract", args.contract, "--level", "test_ready"]
    v = subprocess.run(vcmd, capture_output=True, text=True)
    formal = v.returncode == 0
    if not formal:
        dcmd = [sys.executable, str(Path(__file__).parent / "validate-contract.py"),
                "--contract", args.contract, "--level", "draft"]
        d = subprocess.run(dcmd, capture_output=True, text=True)
        if not args.allow_draft or d.returncode != 0:
            sys.stderr.write(v.stderr or d.stderr)
            sys.exit("⛔ 契约未过校验，拒绝生成（修契约后重试；或 --allow-draft 出草稿）。\n"
                     "   提示：环境需同时带 pyyaml+jsonschema——uv run --with pyyaml,jsonschema python3 gen_from_contract.py …")
    c = yaml.safe_load(Path(args.contract).read_text(encoding="utf-8"))
    # 第六轮审计：写盘前结构预检——畸形 DRAFT 契约（cases 非 list/数值 id/steps 非条目对象等）
    # 此后在生成循环里 traceback crash（exit 1）并残留半截产物；预检不过则零写入拒绝
    struct = []
    if not isinstance(c, dict):
        struct.append(f"契约根节点必须是 mapping（拿到 {type(c).__name__}）")
        c = {}
    m = c.get("meta")
    if not isinstance(m, dict):
        struct.append(f"meta 非对象（拿到 {type(m).__name__ if m is not None else 'NoneType'}）")
    else:
        for k in ("flow_name", "flow_code", "shape", "contract_version"):
            if not m.get(k):
                struct.append(f"meta.{k} 缺失/为空")
    cases = c.get("cases")
    if not isinstance(cases, list):
        struct.append(f"cases 非列表（拿到 {type(cases).__name__}）")
        cases = []
    for i, case in enumerate(cases):
        if not isinstance(case, dict):
            struct.append(f"cases[{i}] 非对象（拿到 {type(case).__name__}）")
            continue
        if not isinstance(case.get("id"), str) or not case.get("id"):
            struct.append(f"cases[{i}].id 必须是非空字符串（拿到 {case.get('id')!r}）")
        if not case.get("title"):
            struct.append(f"cases[{i}].title 缺失/为空")
        steps = case.get("steps")
        if steps and not isinstance(steps, list):
            struct.append(f"cases[{i}].steps 非列表")
        elif isinstance(steps, list):
            bad = [j for j, s in enumerate(steps) if not isinstance(s, dict)]
            if bad:
                struct.append(f"cases[{i}].steps 存在非对象条目: {bad}")
    for key in ("accounts", "nodes"):
        v = c.get(key)
        if v and (not isinstance(v, list) or any(not isinstance(x, dict) for x in v)):
            struct.append(f"{key} 必须是对象列表")
    # 第十轮审计：非有限数值（.inf/.nan）写盘前拒绝——否则 rules.json 携非标准 JSON 常量
    struct += find_nonfinite(c)
    if struct:
        sys.exit("⛔ 契约结构非法，拒绝生成（零写入）:\n  - " + "\n  - ".join(struct))
    out = Path(args.outdir)
    scdir = out / "flowtrace-scenarios"
    if scdir.exists():  # 清理旧场景：契约减少用例后不留僵尸场景被执行
        for old in scdir.glob("*.yaml"):
            old.unlink()
    scdir.mkdir(parents=True, exist_ok=True)
    # 水印以"是否通过 test_ready 正式校验"为准（而非 meta.status 自述）：草稿产物全部盖 DRAFT 水印
    watermark = "" if formal else "\n> ⚠️ **DRAFT 水印**：契约未过 test_ready 校验——本产物仅供草稿评审，禁止用于正式执行与结论。\n"
    draft_mark = "" if formal else "（DRAFT——禁止正式执行）"

    (out / "浏览器手工测试用例.md").write_text(watermark + gen_manual_doc(c), encoding="utf-8")
    (out / "老系统浏览器对比测试用例.md").write_text(watermark + gen_compare_doc(c), encoding="utf-8")
    for case in c.get("cases", []):
        (out / "flowtrace-scenarios" / f"{c['meta']['flow_code']}-{case['id'].lower()}.yaml").write_text(
            gen_scenario(case, c, draft_mark), encoding="utf-8")
    rules = gen_compare_rules(c, formal)
    (out / "compare-rules.yaml").write_text(yaml.safe_dump(rules, allow_unicode=True, sort_keys=False), encoding="utf-8")
    # 第十轮审计：allow_nan=False 双保险——预检漏网时宁可失败也不产出非标准 JSON（Infinity）
    (out / "compare-rules.json").write_text(json.dumps(rules, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
    (out / "report-skeleton.md").write_text(watermark + gen_report_skeleton(c), encoding="utf-8")
    # 第三轮审计：summary 模板也必须带草稿标记（--allow-draft 产物无一例外可辨识）
    tpl = {
        "run_id": "<ts>", "conclusion": "PASS|FAIL|BLOCKED", "p0_count": 0, "p1_count": 0,
        "required_cases": {"total": len([x for x in c.get("cases", []) if x.get("required", True)]), "done": 0},
        "semantic_diffs": [], "exempted_diffs": [], "aux_evidence": {"pixel_diff": "auxiliary"},
        "evidence_paths": [], "comparator_version": "field-level-compare.py v2.10",
    }
    if not formal:
        tpl["draft"] = True
        tpl["draft_note"] = "DRAFT——本模板出自 --allow-draft 草稿生成，禁止用于正式执行与结论"
    (out / "summary.template.json").write_text(json.dumps(tpl, ensure_ascii=False, indent=2), encoding="utf-8")
    n = len(c.get("cases", []))
    # 产物密扫（fail-closed）：任一产物出现明文凭据即整体失败并清空产物，防泄露入库
    # 第七轮审计：补中文关键词（密码/口令/凭据）与全角冒号变体（与 validate 文本扫描同口径）
    import re as _re
    _pat = _re.compile(
        r"(Aa\d{8,}#"
        r"|(?i:[a-z0-9_\-]*(?:password|passwd|pwd|secret|token|credential|apikey|api_key)[a-z0-9_\-]*[\"']?\s*[:：=]\s*(?!CURRENT_|LEGACY_)\S{6,})"
        r"|(?:密码|口令|凭据)\s*[:：=]\s*(?!CURRENT_|LEGACY_)\S{6,}"
        r")")
    leaks = [str(f) for f in sorted(out.rglob("*")) if f.is_file() and _pat.search(f.read_text(encoding="utf-8", errors="ignore"))]
    if leaks:
        for f in out.rglob("*"):
            if f.is_file():
                f.unlink()
        sys.exit(f"⛔ 生成产物检出凭据泄露，已清空 {out}：{leaks}")
    print(f"✅ 生成完成 → {out}\n   手工用例 / 对比用例 / {n} 个场景 / compare-rules(.yaml/.json) / 报告骨架（密扫通过）")


if __name__ == "__main__":
    # 第六轮审计：生成器不 traceback——任何未预期异常折为干净拒绝（exit 1），不残留半截产物误导
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        sys.stderr.write("⛔ 生成失败（fail-closed）: " + traceback.format_exc(limit=2).strip().splitlines()[-1] + "\n")
        sys.stderr.write(f"   {type(e).__name__}: {e}\n   若契约合法请附以上信息反馈；产物目录可能不完整，重新生成前请清理。\n")
        raise SystemExit(1)
