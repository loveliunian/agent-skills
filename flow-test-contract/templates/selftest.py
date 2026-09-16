#!/usr/bin/env python3
"""selftest.py —— 负向回归测试集（2026-09-05 审计最低集 + 校验/生成 fail-closed）。

跑法: python3 <skill>/templates/selftest.py（项目部署布局：docs/自动化测试模板/selftest.py）
退出: 0=全绿；1=有失败。全部用临时目录，不污染工作区（含字节码：本进程内
importlib 动态加载脚本时不落 __pycache__——skill 目录必须保持零副作用）。
"""
from __future__ import annotations

import atexit
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# 本进程动态 import 被测脚本（如 api-capture.py）时不写字节码——否则会在 skill 的
# scripts/ 下落 __pycache__，违反"全部用临时目录，不污染工作区"的自身承诺
sys.dont_write_bytecode = True

HERE = Path(__file__).parent
# 双布局（第十二轮·通道自持）：同一 selftest 在"项目部署布局"与"skill 自持布局"均可运行
#   项目：<root>/docs/自动化测试模板/selftest.py → scripts 在 <root>/.flow-test-contract/scripts
#   skill：<skill>/templates/selftest.py        → scripts 在 <skill>/scripts
_CAND_SCRIPTS = [HERE.parent.parent / ".flow-test-contract" / "scripts",   # 项目部署布局
                 HERE.parent / "scripts"]                           # skill 布局
SCRIPTS = next((p for p in _CAND_SCRIPTS if (p / "pipeline.sh").exists()), _CAND_SCRIPTS[0])
LAYOUT = "project" if SCRIPTS == _CAND_SCRIPTS[0] else "skill"
RESULTS: list[tuple[str, bool, str]] = []


def _cleanup_skill_bytecode():
    """selftest 结束时清掉本次可能由外部 subprocess 产生的源目录 pyc。"""
    for root in {HERE, SCRIPTS}:
        cache = root / "__pycache__"
        if not cache.is_dir():
            continue
        for pyc in cache.glob("*.pyc"):
            try:
                pyc.unlink()
            except OSError:
                pass
        try:
            cache.rmdir()
        except OSError:
            pass


atexit.register(_cleanup_skill_bytecode)


def run(cmd: list[str], **kw):
    env = dict(kw.pop("env", os.environ))
    env.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=120,
                          env=env, **kw)


def check(name: str, ok: bool, detail: str = ""):
    RESULTS.append((name, ok, detail))
    print(("✅" if ok else "❌") + f" {name}" + (f" — {detail}" if detail and not ok else ""))


def w(p: Path, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj, ensure_ascii=False), encoding="utf-8")


def fc_rules(flow="WFA_X_0001", fms=None, fixtures=None, exemptions=None):
    return {"meta": {"flow_code": flow}, "field_mappings": fms or [], "fixtures": fixtures or [],
            "formulas": [], "routing": [], "buttons": [], "resources": [], "post_flow": {},
            "exemptions": exemptions or []}


def _min_contract_snapshot(rd: Path, snap: dict) -> dict:
    """v1.3.6 P1：给测试 run 账本补齐"契约模式最小键"（contract/rules/scenarios）登记——
    run_evidence 现在强制豁免来源必须是契约模式 run。返回就地补齐后的 snap。"""
    import hashlib as _h
    # 契约 cases 须与 case-results 对账（conclude_core 交叉核对）——从产物反推 id，避免误伤
    _cases = [{"id": "C-1", "required": True}]
    _crf = rd / "case-results.json"
    if _crf.exists():
        try:
            _rows = json.loads(_crf.read_text(encoding="utf-8"))
            _ids = [{"id": str(r["id"]), "required": bool(r.get("required", True))}
                    for r in _rows if isinstance(r, dict) and r.get("id")]
            if _ids:
                _cases = _ids
        except Exception:
            pass
    _contract_text = "meta:\n  flow_code: WFA_X_0001\ncases:\n" + "".join(
        f"- id: {c['id']}\n  required: {'true' if c['required'] else 'false'}\n" for c in _cases)
    _specs = {
        "contract": ("contract.yaml", _contract_text),
        "rules": ("rules.json", "{}"),
        "scenarios": ("scenarios.json", "[]"),
    }
    for _key, (_fname, _content) in _specs.items():
        if _key in snap:      # 已显式登记（如契约快照保护用例）不覆盖
            continue
        _f = rd / _fname
        if not _f.exists():
            _f.write_text(_content, encoding="utf-8")
        snap[_key] = {"path": str(_f), "abs_path": str(_f.resolve()),
                      "sha256_16": _h.sha256(_f.read_bytes()).hexdigest()[:16]}
    return snap


FM = [{"legacy_field": "OLD_CODE", "target_field": "NEW_CODE", "normalize": "trim", "tolerance": "exact",
       "null_policy": "both_null_equal"}]
FX = [{"fixture_pair_id": "FP-X", "kind": "t", "legacy_ref": "a", "current_ref": "b", "pairing_rule": "r"}]
FM_FX = [dict(FM[0], legacy_field="CS", target_field="CS", fixture_pair_required=True)]
# 1.3.0：豁免取证链三件（真实 run 绑定）——比较器与校验器在"生成器入口"之外，
# 对"最终契约入口/对拍入口"同样强制（绕过 exempt 手写豁免不再吞差异）
EXC_CHAIN = {"approval_ref": "TICKET-1", "source_run_id": "20260909000000",
             "source_compare_sha256_16": "0123456789abcdef"}


def cmp_run(tmp: Path, rules: dict, legacy: list[dict], current: list[dict]):
    tmp.mkdir(parents=True, exist_ok=True)
    (tmp / "rules.json").write_text(json.dumps(rules, ensure_ascii=False), encoding="utf-8")
    cap = tmp / "caps"
    for i, c in enumerate(legacy):
        w(cap / "legacy" / f"c{i}.json", c)
    for i, c in enumerate(current):
        w(cap / "current" / f"c{i}.json", c)
    return run([sys.executable, str(SCRIPTS / "field-level-compare.py"),
                "--captures-dir", str(cap), "--rules", str(tmp / "rules.json"), "--outdir", str(tmp / "out")])


def main():
    tmp = Path(tempfile.mkdtemp(prefix="ftc-selftest-"))
    atexit.register(shutil.rmtree, tmp, ignore_errors=True)

    # 第十六轮审计（P1）：dry-run 现同步执行 legacy-config-check——contract 模式 dry-run 用例
    # 需隔离 systems api 目录：造一个"结构完整且无占位"的假配置（指向 127.0.0.1:1，dry-run 不探活）
    _FULL_SYS = ("id: {side}\nchannel: api\napi:\n"
                 "  baseUrl: http://127.0.0.1:1\n"
                 "  login:\n    method: POST\n    path: /api/login\n    tokenPath: data.token\n"
                 "    tokenHeader: Authorization\n    tokenScheme: 'Bearer '\n"
                 "  todo:\n    method: GET\n    path: /api/todo\n    params: {{p: 0, s: 50}}\n"
                 "    listPath: data.list\n    taskIdPath: id\n    nodePath: n\n    instancePath: i\n    flowCodePath: fc\n"
                 "  launch:\n    method: POST\n    path: /api/start\n    body: {{flowCode: '${{FLOW_CODE}}'}}\n"
                 "    instancePath: data.i\n    taskIdPath: data.t\n    elementIdEnv: L_ELEMENT\n"
                 "  form:\n    method: GET\n    path: '/api/task/${{TASK_ID}}/form'\n    fieldsPath: data.f\n"
                 "  submit:\n    method: POST\n    path: '/api/task/${{TASK_ID}}/submit'\n    defaultButton: '提交'\n"
                 "    body: {{buttonCode: '${{BUTTON}}'}}\n    successStatus: [200]\n"
                 "actorMap: {{a: {{username: X_USER, password: X_PWD}}}}\n")
    FULL_SYSD = tmp / "full-sysd"
    FULL_SYSD.mkdir()
    (FULL_SYSD / "legacy.yaml").write_text(_FULL_SYS.format(side="legacy"), encoding="utf-8")
    (FULL_SYSD / "current.yaml").write_text(_FULL_SYS.format(side="current"), encoding="utf-8")
    ENV_FULLSYS = {**__import__("os").environ, "FLOWTEST_SYSTEMS_API_DIR": str(FULL_SYSD)}

    # ---------- conclude.py ----------
    d = tmp / "manifest-only"; d.mkdir(parents=True)
    w(d / "run-manifest.json", {"run_id": d.name, "evidence_paths": []})
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d)])
    check("conclude: manifest-only → BLOCKED(2)", r.returncode == 2, f"exit={r.returncode} {r.stderr[:120]}")

    d = tmp / "empty-jsons"; d.mkdir(parents=True)
    w(d / "run-manifest.json", {"run_id": d.name}); w(d / "gates.json", [])
    w(d / "field-compare.json", {}); w(d / "case-results.json", [])
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d)])
    check("conclude: 空 JSON → BLOCKED", r.returncode == 2, f"exit={r.returncode}")

    import hashlib as _h

    def snap_of(d: Path) -> dict:
        """给 manifest 造三件证据的复算一致登记（账本完整性：PASS 需 gates/case_results/field_compare 全入账）。
        第十一轮起含已记录 versions（正式 PASS 须绑定真实版本——测试固定用 v1/v2/f1）。"""
        snap = {}
        for key, fname in (("gates", "gates.json"), ("case_results", "case-results.json"), ("field_compare", "field-compare.json")):
            f = d / fname
            snap[key] = {"path": fname, "abs_path": str(f.resolve()),
                         "sha256_16": _h.sha256(f.read_bytes()).hexdigest()[:16]}
        return {"config_snapshot": snap,
                "versions": {"source": "v1", "target": "v2", "flow": "f1"}}

    def full_case(dirn: str, cases, fc_status="OK", diffs=None, run_id=None):
        d = tmp / dirn; d.mkdir(parents=True, exist_ok=True)
        rid = run_id or d.name
        w(d / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
        w(d / "field-compare.json", {"status": fc_status, "diffs": diffs or [], "exempted": [], "coverage": []})
        w(d / "case-results.json", cases)
        w(d / "run-manifest.json", dict({"run_id": rid}, **snap_of(d)))
        return run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d)])

    r = full_case("zero-required", [{"id": "C-9", "required": False, "status": "PASS"}])
    check("conclude: 0 required → BLOCKED", r.returncode == 2, f"exit={r.returncode}")
    r = full_case("required-skip", [{"id": "C-1", "required": True, "status": "SKIP"}])
    check("conclude: required=SKIP → BLOCKED", r.returncode == 2, f"exit={r.returncode}")
    r = full_case("all-pass", [{"id": "C-1", "required": True, "status": "PASS"}])
    check("conclude: 证据齐全全过 → PASS(0)", r.returncode == 0, f"exit={r.returncode}")
    r = full_case("has-diff", [{"id": "C-1", "required": True, "status": "PASS"}],
                  diffs=[{"dim": "field", "key": "k", "legacy": 1, "current": 2, "reason": "tolerance"}])
    check("conclude: 有未豁免差异 → FAIL(1)", r.returncode == 1, f"exit={r.returncode}")
    r = full_case("runid-mismatch", [{"id": "C-1", "required": True, "status": "PASS"}], run_id="other-run")
    check("conclude: run-id 错配 → BLOCKED", r.returncode == 2, f"exit={r.returncode}")
    d2 = tmp / "summary-exists"
    full_case("summary-exists", [{"id": "C-1", "required": True, "status": "PASS"}])
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d2)])
    check("conclude: summary 已存在（run-id 碰撞）→ 拒绝", r.returncode == 2, f"exit={r.returncode}")

    # ---------- field-level-compare.py ----------
    def cap(flow="WFA_X_0001", pairs=None, steps=None, extra=None):
        o = {"flow_code": flow, "case_id": "C-1", "fixture_pairs": pairs or [], "steps": steps or {}}
        o.update(extra or {})
        return o

    # 5 字段改名：legacy OLD_CODE / current NEW_CODE 同值 → MATCH（v1 假 FAIL）
    r = cmp_run(tmp / "t-rename", fc_rules(fms=FM),
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V1"}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V1"}}})])
    j = json.loads((tmp / "t-rename" / "out" / "field-compare.json").read_text())
    check("compare: 字段改名同值 → OK(0)", r.returncode == 0 and j["stats"]["diff"] == 0 and j["stats"]["match"] == 1,
          f"exit={r.returncode} stats={j['stats']}")

    # 6 后步差异：s1 相同、s2 不同 → FAIL（v1 折叠假 OK）
    r = cmp_run(tmp / "t-step2", fc_rules(fms=FM),
                [cap(steps={"s1": {"fields": {"OLD_CODE": "A"}}, "s2": {"fields": {"OLD_CODE": "B"}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "A"}}, "s2": {"fields": {"NEW_CODE": "X"}}})])
    j = json.loads((tmp / "t-step2" / "out" / "field-compare.json").read_text())
    check("compare: 后续步骤差异 → FAIL(1)", r.returncode == 1 and j["stats"]["diff"] == 1, f"exit={r.returncode} stats={j['stats']}")

    # 7 单边 fixture：仅 legacy 声明 → OBSERVE 非 OK
    r = cmp_run(tmp / "t-fx1", fc_rules(fms=FM_FX, fixtures=FX),
                [cap(pairs=["FP-X"], steps={"s1": {"fields": {"CS": 2}}})],
                [cap(steps={"s1": {"fields": {"CS": 2}}})])
    j = json.loads((tmp / "t-fx1" / "out" / "field-compare.json").read_text())
    check("compare: 单边 fixture → OBSERVE 非一致结论", j["stats"]["observe"] >= 1 and j["stats"]["match"] == 0,
          f"stats={j['stats']}")

    # 10 hash 脱敏：输出无明文、有盐摘要
    fm_hash = [dict(FM[0], redact="hash")]
    secret = "SECRET-VALUE-42"
    cmp_run(tmp / "t-hash", fc_rules(fms=fm_hash),
            [cap(steps={"s1": {"fields": {"OLD_CODE": secret}}})],
            [cap(steps={"s1": {"fields": {"NEW_CODE": "other"}}})])
    raw = (tmp / "t-hash" / "out").glob("*.json")
    blob = "".join(p.read_text() for p in raw)
    check("compare: hash 脱敏不泄露原值", secret not in blob and "sha256$" in blob and "redact_salt" in blob)

    # 11 规则错配：采集 flow_code 与规则不一致 → BLOCKED
    r = cmp_run(tmp / "t-mismatch", fc_rules(flow="WFA_A_0001", fms=FM),
                [cap(flow="WFA_B_0002", steps={"s1": {"fields": {"OLD_CODE": "V"}}})],
                [cap(flow="WFA_B_0002", steps={"s1": {"fields": {"NEW_CODE": "V"}}})])
    check("compare: 规则/采集流程错配 → BLOCKED(2)", r.returncode == 2, f"exit={r.returncode}")

    # 8 缺 rules 文件 → BLOCKED（比较器直接崩也计失败）
    tmp2 = tmp / "t-norules"; tmp2.mkdir()
    r = run([sys.executable, str(SCRIPTS / "field-level-compare.py"),
             "--captures-dir", str(tmp2 / "caps"), "--rules", str(tmp2 / "nope.json"), "--outdir", str(tmp2 / "out")])
    check("compare: 缺 rules → 非 PASS（BLOCKED/异常）", r.returncode != 0, f"exit={r.returncode}")

    # 覆盖率：合同字段 legacy 侧从未采集 → BLOCKED
    r = cmp_run(tmp / "t-cov", fc_rules(fms=FM),
                [cap(steps={"s1": {"fields": {"OTHER": 1}}})],
                [cap(steps={"s1": {"fields": {"OTHER": 1}}})])
    check("compare: 合同字段未采集 → BLOCKED(2)", r.returncode == 2, f"exit={r.returncode}")

    # ---------- validate-contract ----------
    r = run([sys.executable, str(HERE / "validate-contract.py"),
             "--contract", str(HERE / "test-contract.template.yaml"), "--level", "test_ready"])
    check("validate: 空白模板 test_ready 必须拒绝", r.returncode == 2, f"exit={r.returncode}")
    ex = HERE / "examples" / "liyazhuang-railway.yaml"
    if ex.exists():
        r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(ex), "--level", "test_ready"])
        check("validate: 铁路实例 test_ready 通过", r.returncode == 0, r.stderr[:200])

    # ---------- generator fail-closed ----------
    out = tmp / "gen"
    r = run([sys.executable, str(HERE / "gen_from_contract.py"),
             "--contract", str(HERE / "test-contract.template.yaml"), "--outdir", str(out)])
    check("gen: 空白契约拒绝生成", r.returncode != 0 and not out.exists(), f"exit={r.returncode}")

    # ---------- write-manifest 碰撞 / 版本必填 ----------
    dm = tmp / "mf"; dm.mkdir()
    common = [sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", "x",
              "--reports-dir", str(dm), "--project-root", str(tmp), "--allow-unrecorded-versions"]
    r0 = run([sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", "y",
              "--reports-dir", str(dm), "--project-root", str(tmp)])
    check("manifest: 版本未记录且未豁免 → 拒绝(2)", r0.returncode == 2, f"exit={r0.returncode}")
    r1 = run(common)
    r2 = run(common)
    check("manifest: 同 run-id 二次写入被拒绝(3)", r1.returncode == 0 and r2.returncode == 3 and (dm / "x" / "run-manifest.json").exists(),
          f"r1={r1.returncode} r2={r2.returncode}")

    # ---------- 新增回归（2026-09-05 第二轮审计 8 项） ----------
    # A. DRAFT 越级：status=DRAFT 的完整契约 → test_ready 拒绝；生成器拒绝
    import yaml as _y
    draft_c = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    draft_c["meta"]["status"] = "DRAFT"
    dp = tmp / "draft.yaml"; dp.write_text(_y.safe_dump(draft_c, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(dp), "--level", "test_ready"])
    check("validate: DRAFT 越级 test_ready → 拒绝(2)", r.returncode == 2, f"exit={r.returncode}")
    r = run([sys.executable, str(HERE / "gen_from_contract.py"), "--contract", str(dp), "--outdir", str(tmp / "gen-draft")])
    check("gen: DRAFT 契约（无 --allow-draft）→ 拒绝", r.returncode != 0 and not (tmp / "gen-draft").exists(), f"exit={r.returncode}")

    # B. observe → 结论：fc.status=OK 但含非 optional observe → BLOCKED
    d = tmp / "observe-block"; d.mkdir()
    w(d / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(d / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [],
                                  "observe": [{"key": "C-1/s1/CS", "optional": False, "note": "fixture 未配对"}], "coverage": []})
    w(d / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    w(d / "run-manifest.json", dict({"run_id": d.name}, **snap_of(d)))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d)])
    check("conclude: 非 optional OBSERVE → BLOCKED", r.returncode == 2, f"exit={r.returncode}")
    w(d / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [],
                                  "observe": [{"key": "opt", "optional": True, "note": "契约标 optional"}], "coverage": []})
    w(d / "run-manifest.json", dict({"run_id": d.name}, **snap_of(d)))  # 证据重写后账本同步重登记（hash 方一致）
    # 第十一轮：--force 已移除——同一结论目录重跑必拒（summary 不可重写）；改用全新目录验证 optional 放行
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d)])
    check("conclude: summary 已存在且 --force 已移除 → 拒绝(2)", r.returncode == 2, f"exit={r.returncode}")
    dopt = tmp / "observe-optional-pass"; dopt.mkdir()
    w(dopt / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(dopt / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [],
                                     "observe": [{"key": "opt", "optional": True, "note": "契约标 optional"}], "coverage": []})
    w(dopt / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    w(dopt / "run-manifest.json", dict({"run_id": dopt.name}, **snap_of(dopt)))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(dopt)])
    check("conclude: optional OBSERVE 不阻断（新目录）→ PASS", r.returncode == 0, f"exit={r.returncode}")

    # C. 公式仅 current 侧采集 → BLOCKED
    rules_f = fc_rules(fms=FM)
    rules_f["formulas"] = [{"id": "A.1", "expr": "e", "expected_legacy": 1, "tolerance": "abs:0.01", "nodes_applied": ["00"]}]
    r = cmp_run(tmp / "t-fx-current-only",
                rules_f,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"formulas": {"A.1": 1}})])
    j = json.loads((tmp / "t-fx-current-only" / "out" / "field-compare.json").read_text())
    check("compare: 公式仅 current 侧 → BLOCKED(2)", r.returncode == 2 or j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # D. 资源仅 current 侧 → BLOCKED（不再假 MATCH）
    rules_res = fc_rules(fms=FM, fixtures=None); rules_res["resources"] = [{"id": "res1", "table": "t", "status_col": "s", "occupy_on": "submit", "release_on": ["void"], "check": "c"}]
    r = cmp_run(tmp / "t-res-one", rules_res,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"resources": {"res1": "已使用"}})])
    j = json.loads((tmp / "t-res-one" / "out" / "field-compare.json").read_text())
    res_match = [m for m in j.get("matches", []) if m.get("dim") == "resource"]
    check("compare: 资源单边缺失 → BLOCKED 且不记 MATCH", j["status"] == "BLOCKED" and not res_match,
          f"status={j['status']} res_match={len(res_match)}")

    # E. 按钮集差异 → FAIL
    rules_btn = fc_rules(fms=FM); rules_btn["buttons"] = [{"node": "00", "expect_visible": ["保存草稿"], "expect_hidden": ["退回流程"]}]
    r = cmp_run(tmp / "t-btn", rules_btn,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"buttons": {"00": ["保存草稿"]}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"buttons": {"00": ["保存草稿", "退回流程"]}})])
    j = json.loads((tmp / "t-btn" / "out" / "field-compare.json").read_text())
    check("compare: 按钮可见集差异 → FAIL(1)", r.returncode == 1 and any(d["dim"] == "buttons" for d in j["diffs"]),
          f"exit={r.returncode} dims={[d['dim'] for d in j['diffs']]}")

    # F. post_flow 状态差异 → FAIL
    rules_pf = fc_rules(fms=FM); rules_pf["post_flow"] = {"code": "WFA_X_0002", "trigger": "wait_start_register", "starter": {}, "inherits": {}}
    r = cmp_run(tmp / "t-pf", rules_pf,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"post_flow": {"registered": True, "inherits": {}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"post_flow": {"registered": False, "inherits": {}}})])
    j = json.loads((tmp / "t-pf" / "out" / "field-compare.json").read_text())
    check("compare: post_flow 差异 → FAIL(1)", r.returncode == 1 and any(d["dim"] == "post_flow" for d in j["diffs"]),
          f"exit={r.returncode}")

    # G. actor/node 引用完整性
    bad = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    bad["cases"][0]["steps"][0]["actor"] = "ghost_account"
    bp = tmp / "bad-ref.yaml"; bp.write_text(_y.safe_dump(bad, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(bp), "--level", "test_ready"])
    check("validate: actor 未登记 → 拒绝", r.returncode == 2 and "accounts" in r.stderr, r.stderr[:100])
    bad2 = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    bad2["cases"][0]["steps"][0]["node"] = "99X"
    bp2 = tmp / "bad-node.yaml"; bp2.write_text(_y.safe_dump(bad2, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(bp2), "--level", "test_ready"])
    check("validate: node 未登记 → 拒绝", r.returncode == 2 and "nodes" in r.stderr, r.stderr[:100])

    # H. 凭据别名绕过（结构化键扫描）
    for i, (k, v) in enumerate([("密码", "abc12345"), ("secret", "abc12345"), ("pwd", "quoted-pwd")]):
        bad3 = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
        bad3["meta"]["notes"] = "x"
        bad3.setdefault("_probe", {})[k] = v
        cp3 = tmp / f"bad-sec{i}.yaml"; cp3.write_text(_y.safe_dump(bad3, allow_unicode=True), encoding="utf-8")
        r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cp3), "--level", "test_ready"])
        check(f"validate: 凭据别名键 {k!r} → 拒绝", r.returncode == 2 and "禁止键" in r.stderr, r.stderr[:100])

    # I. compare-rules 确定性（同契约两次生成字节一致）
    g1, g2 = tmp / "det1", tmp / "det2"
    for g in (g1, g2):
        run([sys.executable, str(HERE / "gen_from_contract.py"), "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"), "--outdir", str(g)],
            env={**__import__("os").environ, "PYTHONPATH": ""})
    b1 = (g1 / "compare-rules.json").read_bytes(); b2 = (g2 / "compare-rules.json").read_bytes()
    check("gen: compare-rules 确定性（无时间戳）", b1 == b2)

    # ---------- 第三轮对抗审计回归（2026-09-06） ----------
    def concl(dirn: str, **kw):
        d = tmp / dirn; d.mkdir(parents=True, exist_ok=True)
        (d / "gates.json").write_text(kw.get("gates", json.dumps([{"id": "g", "severity": "P0", "passed": True}])), encoding="utf-8")
        (d / "field-compare.json").write_text(kw.get("fc", json.dumps({"status": "OK", "diffs": [], "exempted": [], "coverage": []})), encoding="utf-8")
        (d / "case-results.json").write_text(kw.get("cases", json.dumps([{"id": "C-1", "required": True, "status": "PASS"}])), encoding="utf-8")
        if "manifest" in kw:
            (d / "run-manifest.json").write_text(json.dumps(kw["manifest"]), encoding="utf-8")
        else:
            mft = dict({"run_id": dirn}, **snap_of(d))
            if "versions" in kw:
                mft["versions"] = kw["versions"]  # 覆盖默认已记录版本（第十一轮：versions unrecorded 须 BLOCKED）
            (d / "run-manifest.json").write_text(json.dumps(mft), encoding="utf-8")
        cmd = [sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d)]
        if kw.get("contract"):
            cmd += ["--contract", str(kw["contract"])]
        return run(cmd)

    # J. 证据类型伪装 → BLOCKED（此前 gates 缺 passed/字符串 passed 会假 PASS）
    r = concl("j1", gates=json.dumps([{"id": "g", "severity": "P0"}]))
    check("conclude: gate 缺 passed 键 → BLOCKED", r.returncode == 2, f"exit={r.returncode}")
    r = concl("j2", gates=json.dumps([{"id": "g", "severity": "P0", "passed": "true"}]))
    check("conclude: gate passed='true' 字符串 → BLOCKED", r.returncode == 2, f"exit={r.returncode}")
    r = concl("j3", gates=json.dumps({"g": {"passed": False}}))
    check("conclude: gates 为 dict → BLOCKED", r.returncode == 2, f"exit={r.returncode}")
    r = concl("j4", fc=json.dumps([1, 2, 3]))
    check("conclude: field-compare 为 list → BLOCKED（不 crash）", r.returncode == 2, f"exit={r.returncode}")
    r = concl("j5", fc=json.dumps({"status": "OK", "diffs": [], "observe": {"k": 1}}))
    check("conclude: observe 为 dict → BLOCKED", r.returncode == 2, f"exit={r.returncode}")
    r = concl("j6", fc=json.dumps({"status": "WEIRD", "diffs": [], "exempted": []}))
    check("conclude: 对拍状态非法字符串 → BLOCKED", r.returncode == 2, f"exit={r.returncode}")
    r = concl("j7", cases=json.dumps([{"id": "C-1", "required": True, "status": "PASS"}, {"id": "C-1", "required": True, "status": "PASS"}]))
    check("conclude: case-results 重复 id → BLOCKED", r.returncode == 2, f"exit={r.returncode}")
    r = concl("j8", manifest=[1, 2])
    check("conclude: manifest 为 list → BLOCKED（不 crash）", r.returncode == 2, f"exit={r.returncode}")
    r = concl("j9", manifest={"versions": {}})
    check("conclude: manifest 缺 run_id → BLOCKED", r.returncode == 2, f"exit={r.returncode}")

    # K. 契约交叉核对（--contract）
    k_c = tmp / "mini-contract.yaml"
    k_c.write_text(_y.safe_dump({"meta": {"flow_code": "WFA_X_0001"}, "cases": [
        {"id": "C-1", "required": True}, {"id": "C-2", "required": True}]}), encoding="utf-8")
    def reasons_of(p) -> str:
        return "\n".join(map(str, json.loads((Path(p) / "summary.json").read_text(encoding="utf-8")).get("blocked_reasons", [])))
    r = concl("k1", contract=k_c)  # 结果只有 C-1，缺契约必测 C-2
    check("conclude: 契约必测用例缺失 → BLOCKED", r.returncode == 2 and "C-2" in reasons_of(tmp / "k1"),
          f"exit={r.returncode} reasons={reasons_of(tmp / 'k1')[:150]}")
    r = concl("k2", cases=json.dumps([{"id": "C-1", "required": True, "status": "PASS"},
                                      {"id": "C-2", "required": True, "status": "PASS"},
                                      {"id": "GHOST", "required": False, "status": "PASS"}]), contract=k_c)
    check("conclude: 契约未登记的伪造 id → BLOCKED", r.returncode == 2 and "GHOST" in reasons_of(tmp / "k2"),
          f"exit={r.returncode} reasons={reasons_of(tmp / 'k2')[:150]}")

    # L. 账本防篡改：登记 sha 后改动文件 → BLOCKED
    l_dir = tmp / "mf2"
    l_ct = tmp / "l-contract.yaml"; l_ct.write_text("meta: {}\n", encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", "l1", "--reports-dir", str(l_dir),
             "--project-root", str(tmp), "--allow-unrecorded-versions", "--contract", str(l_ct)])
    l_ct.write_text("meta: {}\n# tampered\n", encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(l_dir / "l1")])
    check("conclude: 账本登记文件被改动 → BLOCKED",
          r.returncode == 2 and "hash" in reasons_of(l_dir / "l1"), f"exit={r.returncode}")

    # M. compare 对抗
    def cap2(flow="WFA_X_0001", pairs=None, steps=None, extra=None):
        o = {"flow_code": flow, "case_id": "C-1", "fixture_pairs": pairs or [], "steps": steps or {}}
        o.update(extra or {})
        return o

    rules_r = fc_rules(fms=FM); rules_r["routing"] = [{"node": "00", "candidates_legacy": ["01"]}]
    r = cmp_run(tmp / "m1", rules_r,
                [cap2(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"routing": {"00": ["01"]}})],
                [cap2(steps={"s1": {"fields": {"NEW_CODE": "V"}}})])
    j = json.loads((tmp / "m1" / "out" / "field-compare.json").read_text())
    check("compare: 路由仅单端采集 → BLOCKED（不再静默 OK）", r.returncode == 2 and j["status"] == "BLOCKED",
          f"exit={r.returncode} status={j['status']}")

    d2_ = tmp / "m2"; d2_.mkdir()
    (d2_ / "rules.json").write_text('{"meta": {"flow_code": ', encoding="utf-8")
    w(d2_ / "caps" / "legacy" / "c0.json", cap2(steps={"s1": {"fields": {"OLD_CODE": "V"}}}))
    w(d2_ / "caps" / "current" / "c0.json", cap2(steps={"s1": {"fields": {"NEW_CODE": "V"}}}))
    r = run([sys.executable, str(SCRIPTS / "field-level-compare.py"),
             "--captures-dir", str(d2_ / "caps"), "--rules", str(d2_ / "rules.json"), "--outdir", str(d2_ / "out")])
    check("compare: rules 半损坏 JSON → BLOCKED(2)（不再 crash 成 1）", r.returncode == 2, f"exit={r.returncode}")
    (d2_ / "rules.json").write_text("[1]", encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "field-level-compare.py"),
             "--captures-dir", str(d2_ / "caps"), "--rules", str(d2_ / "rules.json"), "--outdir", str(d2_ / "out2")])
    check("compare: rules 为 list → BLOCKED(2)", r.returncode == 2, f"exit={r.returncode}")
    rules_bad_fm = fc_rules(fms=[{"target_field": "NEW_CODE"}])
    r = cmp_run(tmp / "m3", rules_bad_fm,
                [cap2(steps={"s1": {"fields": {"OLD_CODE": "V"}}})],
                [cap2(steps={"s1": {"fields": {"NEW_CODE": "V"}}})])
    check("compare: field_mapping 缺 legacy_field → BLOCKED(2)", r.returncode == 2, f"exit={r.returncode}")
    r = cmp_run(tmp / "m4", fc_rules(fms=FM),
                [{"flow_code": "WFA_X_0001", "case_id": "C-1", "fixture_pairs": [], "steps": [{"s1": 1}]}],
                [cap2(steps={"s1": {"fields": {"NEW_CODE": "V"}}})])
    check("compare: steps 为 list（畸形采集）→ BLOCKED(2)", r.returncode == 2, f"exit={r.returncode}")
    rules_draft = fc_rules(fms=FM); rules_draft["meta"]["draft"] = True
    r = cmp_run(tmp / "m5", rules_draft,
                [cap2(steps={"s1": {"fields": {"OLD_CODE": "V"}}})],
                [cap2(steps={"s1": {"fields": {"NEW_CODE": "V"}}})])
    j = json.loads((tmp / "m5" / "out" / "field-compare.json").read_text())
    check("compare: DRAFT 规则（meta.draft）→ BLOCKED", j["status"] == "BLOCKED", f"status={j['status']}")

    # N. 凭据键前后缀/引号变体 → 拒绝
    for i, (k, v) in enumerate([("db_password", "abc12345"), ("access_token", "eyJx.y"), ("pwd2", "abc12345")]):
        bad4 = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
        bad4.setdefault("_probe", {})[k] = v
        cp4 = tmp / f"bad-sec3-{i}.yaml"
        cp4.write_text(_y.safe_dump(bad4, allow_unicode=True, default_flow_style=False), encoding="utf-8")
        r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cp4), "--level", "test_ready"])
        check(f"validate: 凭据变体键 {k!r} → 拒绝", r.returncode == 2 and "禁止键" in r.stderr, r.stderr[:100])

    # O. --allow-draft 可用且全产物带 DRAFT 标记
    od = tmp / "gen-allow-draft"
    r = run([sys.executable, str(HERE / "gen_from_contract.py"), "--contract", str(dp), "--outdir", str(od), "--allow-draft"],
            env={**__import__("os").environ, "PYTHONPATH": ""})
    sc = sorted((od / "flowtrace-scenarios").glob("*.yaml"))
    rules_y = _y.safe_load((od / "compare-rules.yaml").read_text(encoding="utf-8"))
    ok_draft = (r.returncode == 0 and (od / "浏览器手工测试用例.md").read_text(encoding="utf-8").find("DRAFT 水印") >= 0
                and all("DRAFT" in p.read_text(encoding="utf-8").splitlines()[0] for p in sc)
                and rules_y.get("meta", {}).get("draft") is True)
    check("gen: --allow-draft 可用且场景/规则/文档全带 DRAFT 标记", ok_draft,
          f"exit={r.returncode} scenarios={len(sc)} meta.draft={rules_y.get('meta', {}).get('draft')}")

    # P. manifest 登记文件缺失 → 拒绝(4)
    r = run([sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", "z", "--reports-dir", str(tmp / "mf3"),
             "--project-root", str(tmp), "--allow-unrecorded-versions", "--contract", str(tmp / "nope.yaml")])
    check("manifest: 登记文件缺失 → 拒绝(4)", r.returncode == 4, f"exit={r.returncode}")

    # Q. runner：case_id 传播 + 空场景目录 exit 2
    sd = tmp / "scen"; sd.mkdir()
    (sd / "s1.yaml").write_text(_y.safe_dump({"id": "WFA_X_0001-c-09", "case_id": "C-09", "required": True}), encoding="utf-8")
    exd = tmp / "exec1"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd),
             "--exec-dir", str(exd), "--run-id", "q1"],
            env={**__import__("os").environ, "FLOWTEST_RUNNER": "cli", "FLOWTEST_CLI": "/nonexistent"})
    j = json.loads((exd / "case-results.json").read_text())
    check("runner: 场景 case_id 传播到 case-results（且无 CLI=BLOCKED）",
          r.returncode == 2 and j and j[0]["id"] == "C-09" and j[0]["status"] == "BLOCKED",
          f"exit={r.returncode} results={j[:1]}")
    sd2 = tmp / "scen-empty"; sd2.mkdir()
    exd2 = tmp / "exec2"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd2),
             "--exec-dir", str(exd2), "--run-id", "q2"],
            env={**__import__("os").environ, "FLOWTEST_RUNNER": "cli", "FLOWTEST_CLI": "/nonexistent"})
    check("runner: 空场景目录 → exit 2", r.returncode == 2, f"exit={r.returncode}")

    # ---------- 第四轮独立对抗审计回归（2026-09-06 第二轮独立审计员） ----------
    # R1. 豁免 scope='*'+match='*' 全量豁免 → BLOCKED（此前差异全免可假 OK→PASS）
    rules_w = fc_rules(fms=FM)
    rules_w["exemptions"] = [dict({"id": "EX-ALL", "scope": "*", "match": "*", "reason": "r", "approved_by": "b"}, **EXC_CHAIN)]
    r = cmp_run(tmp / "r1", rules_w,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "A"}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "B"}}})])
    j = json.loads((tmp / "r1" / "out" / "field-compare.json").read_text())
    check("compare: 全量豁免(*/*) → BLOCKED", r.returncode == 2 and j["status"] == "BLOCKED",
          f"exit={r.returncode} status={j['status']}")

    # R2. 不可审计豁免（缺 approved_by）不生效 → 差异保留 FAIL
    rules_u = fc_rules(fms=FM)
    rules_u["exemptions"] = [{"id": "EX", "scope": "field", "match": "*", "reason": "r"}]
    r = cmp_run(tmp / "r2", rules_u,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "A"}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "B"}}})])
    j = json.loads((tmp / "r2" / "out" / "field-compare.json").read_text())
    check("compare: 不可审计豁免不生效 → FAIL", r.returncode == 1 and len(j["diffs"]) == 1 and len(j["invalid_exemptions"]) == 1,
          f"exit={r.returncode} diffs={len(j['diffs'])} invalid={len(j['invalid_exemptions'])}")

    # R3. 可审计豁免 + 稳定键（去文件名前缀）匹配 → 豁免生效 OK
    rules_a = fc_rules(fms=FM)
    rules_a["exemptions"] = [dict({"id": "EX-1", "scope": "field", "match": "s1/OLD_CODE->NEW_CODE",
                                   "reason": "已知差异", "approved_by": "张三"}, **EXC_CHAIN)]
    r = cmp_run(tmp / "r3", rules_a,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "A"}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "B"}}})])
    j = json.loads((tmp / "r3" / "out" / "field-compare.json").read_text())
    check("compare: 可审计豁免稳定键匹配 → OK+豁免", r.returncode == 0 and len(j["exempted"]) == 1,
          f"exit={r.returncode} exempted={len(j['exempted'])}")

    # R4. validate: 全量豁免契约 → 拒绝
    bad5 = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    bad5["exemptions"] = [dict({"id": "EX-ALL", "scope": "*", "match": "*", "reason": "r", "approved_by": "b"}, **EXC_CHAIN)]
    cp5 = tmp / "bad-exem.yaml"; cp5.write_text(_y.safe_dump(bad5, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cp5), "--level", "test_ready"])
    check("validate: 全量豁免(*/*) → 拒绝", r.returncode == 2 and "全量豁免" in r.stderr, r.stderr[:100])

    # R5. validate: 豁免缺 match → 拒绝（豁免必须可定位）
    bad6 = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    bad6["exemptions"] = [{"id": "EX-1", "scope": "field", "reason": "r", "approved_by": "b"}]
    cp6 = tmp / "bad-exem2.yaml"; cp6.write_text(_y.safe_dump(bad6, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cp6), "--level", "test_ready"])
    check("validate: 豁免缺 match → 拒绝", r.returncode == 2 and "match" in r.stderr, r.stderr[:100])

    # R6. validate: 重复 account id / node code → 拒绝
    bad7 = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    bad7["accounts"].append(dict(bad7["accounts"][0]))
    cp7 = tmp / "dup-acc.yaml"; cp7.write_text(_y.safe_dump(bad7, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cp7), "--level", "test_ready"])
    check("validate: accounts id 重复 → 拒绝", r.returncode == 2 and "accounts id 重复" in r.stderr, r.stderr[:100])
    bad8 = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    bad8["nodes"].append(dict(bad8["nodes"][0]))
    cp8 = tmp / "dup-node.yaml"; cp8.write_text(_y.safe_dump(bad8, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cp8), "--level", "test_ready"])
    check("validate: nodes code 重复 → 拒绝", r.returncode == 2 and "nodes code 重复" in r.stderr, r.stderr[:100])

    # R7. validate: 重复 YAML 键（status 双写夹带）→ 拒绝
    dup_raw = (HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8")
    cp9 = tmp / "dup-key.yaml"
    cp9.write_text(dup_raw + "\nexemptions: []\n", encoding="utf-8")  # 顶层 exemptions 双写（后值覆盖）
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cp9), "--level", "test_ready"])
    check("validate: 重复 YAML 键 → 拒绝", r.returncode == 2 and "重复 YAML 键" in r.stderr, r.stderr[:120])

    # R8. validate: 裸 pass: 键 → 拒绝
    bad9 = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    bad9.setdefault("_probe", {})["pass"] = "abc12345"
    cpa = tmp / "pass-key.yaml"; cpa.write_text(_y.safe_dump(bad9, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cpa), "--level", "test_ready"])
    check("validate: 裸 pass 键 → 拒绝", r.returncode == 2 and "禁止键" in r.stderr, r.stderr[:100])

    # R9. manifest: run-id 穿越/非法 → 拒绝(2)
    trav_ok = True
    for rid in ("../escape", "a/b", "..", ".hidden"):
        r = run([sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", rid,
                 "--reports-dir", str(tmp / "mf-trav"), "--project-root", str(tmp), "--allow-unrecorded-versions"])
        trav_ok = trav_ok and r.returncode == 2
    check("manifest: 非法 run-id（../、/、..）→ 拒绝(2)", trav_ok and not (tmp / "mf-trav").exists())

    # R10. manifest: 同 run-id 并发 → 只有一个成功（原子占位，防 TOCTOU 双写）
    import subprocess as _sp
    procs = [_sp.Popen([sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", "race",
                        "--reports-dir", str(tmp / "mf-race"), "--project-root", str(tmp),
                        "--allow-unrecorded-versions"], stdout=_sp.PIPE, stderr=_sp.PIPE, text=True) for _ in range(2)]
    rcs = sorted(p.wait() for p in procs)
    check("manifest: 并发同 run-id 单赢家（rc 0/3）", rcs == [0, 3] and (tmp / "mf-race" / "race" / "run-manifest.json").exists(),
          f"rcs={rcs}")

    # R11. conclude: 账本条目被剥离 sha256_16 → BLOCKED（不再静默跳过）
    r = concl("r11", manifest={"run_id": "r11", "config_snapshot": {"gates": {"path": "gates.json"}}})
    check("conclude: 账本条目缺 hash → BLOCKED", r.returncode == 2 and "登记不完整" in reasons_of(tmp / "r11"),
          f"exit={r.returncode}")

    # R12. conclude: 空账本（无任何登记）不得 PASS（手工伪造门槛）
    r = concl("r12", manifest={"run_id": "r12"})
    check("conclude: 空账本 → BLOCKED（PASS 需三件证据全部入账）",
          r.returncode == 2 and "未登记/未验证必要证据" in reasons_of(tmp / "r12"), f"exit={r.returncode}")

    # R12b. conclude: 只登记 gates、field-compare 未入账（B6 场景）→ 不得 PASS
    d12 = tmp / "r12b"; d12.mkdir()
    w(d12 / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(d12 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": []})
    w(d12 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    g12 = d12 / "gates.json"
    w(d12 / "run-manifest.json", {"run_id": "r12b", "config_snapshot": {
        "gates": {"path": "gates.json", "abs_path": str(g12.resolve()),
                  "sha256_16": _h.sha256(g12.read_bytes()).hexdigest()[:16]}}})
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d12)])
    check("conclude: 证据未全入账（缺 field_compare）→ BLOCKED",
          r.returncode == 2 and "field_compare" in reasons_of(d12), f"exit={r.returncode}")

    # R13. conclude: 已登记 field-compare 被篡改 → BLOCKED（hash 复算）
    r13d = tmp / "r13"; r13d.mkdir(parents=True)
    w(r13d / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(r13d / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    w(r13d / "field-compare.json", {"status": "FAIL", "diffs": [{"dim": "field", "key": "k", "legacy": 1, "current": 2, "reason": "t"}], "exempted": [], "coverage": []})
    r = run([sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", "r13", "--reports-dir", str(tmp / "mf-r13"),
             "--project-root", str(r13d), "--allow-unrecorded-versions",
             "--gates-file", str(r13d / "gates.json"), "--case-results", str(r13d / "case-results.json"),
             "--field-compare", str(r13d / "field-compare.json")])
    ok_reg = r.returncode == 0
    w(r13d / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": []})  # 篡改 FAIL→OK
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(tmp / "mf-r13" / "r13")])
    check("conclude: 篡改已登记 field-compare → BLOCKED",
          ok_reg and r.returncode == 2 and "field_compare" in reasons_of(tmp / "mf-r13" / "r13"),
          f"reg={ok_reg} exit={r.returncode}")

    # R14. runner: 假 CLI 退出码 0 但无采集 → BLOCKED（不采信裸退出码）
    fake = tmp / "fake-cli"; fake.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    fake.chmod(0o755)
    sdr = tmp / "scen-r14"; sdr.mkdir()
    (sdr / "s1.yaml").write_text(_y.safe_dump({"id": "x-c-01", "case_id": "C-01", "required": True}), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sdr),
             "--exec-dir", str(tmp / "exec-r14"), "--run-id", "r14"],
            env={**__import__("os").environ, "FLOWTEST_RUNNER": "cli", "FLOWTEST_CLI": str(fake)})
    j = json.loads((tmp / "exec-r14" / "case-results.json").read_text())
    check("runner: 假 CLI 退出码 0 无采集 → BLOCKED", r.returncode == 2 and j[0]["status"] == "BLOCKED",
          f"exit={r.returncode} status={j[0]['status']}")

    # R15. compare: 配对文件双端 case_id 不一致 → BLOCKED
    r = cmp_run(tmp / "r15", fc_rules(fms=FM),
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"case_id": "C-1"})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"case_id": "C-99"})])
    j = json.loads((tmp / "r15" / "out" / "field-compare.json").read_text())
    check("compare: 双端 case_id 不一致 → BLOCKED", r.returncode == 2 and j["status"] == "BLOCKED",
          f"exit={r.returncode} status={j['status']}")

    # R16. compare: exact 下 True vs 1 → 差异（Python bool==int 陷阱）
    r = cmp_run(tmp / "r16", fc_rules(fms=FM),
                [cap(steps={"s1": {"fields": {"OLD_CODE": True}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": 1}}})])
    j = json.loads((tmp / "r16" / "out" / "field-compare.json").read_text())
    check("compare: exact True vs 1 → FAIL（类型混淆不判等）", r.returncode == 1 and len(j["diffs"]) == 1,
          f"exit={r.returncode} diffs={len(j['diffs'])}")

    # R17. conclude: 契约重复 YAML 键（required 双写）→ BLOCKED
    r17c = tmp / "r17c.yaml"
    r17c.write_text("meta:\n  flow_code: WFA_X_0001\ncases:\n  - id: C-1\n    required: true\n    required: false\n", encoding="utf-8")
    r = concl("r17", contract=r17c)
    check("conclude: 契约重复 YAML 键 → BLOCKED",
          r.returncode == 2 and ("不可读/损坏" in reasons_of(tmp / "r17")), f"exit={r.returncode}")

    # R18. manifest: --scenarios 传目录（pipeline 实际用法）→ 正常登记目录哈希（此前 IsADirectoryError 必崩）
    sdir18 = tmp / "scen-r18"; sdir18.mkdir()
    (sdir18 / "a.yaml").write_text("id: 1\n", encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", "r18", "--reports-dir", str(tmp / "mf-r18"),
             "--project-root", str(tmp), "--allow-unrecorded-versions", "--scenarios", str(sdir18)])
    m = json.loads((tmp / "mf-r18" / "r18" / "run-manifest.json").read_text()) if r.returncode == 0 else {}
    check("manifest: --scenarios 目录登记 → rc0 且含 sha", r.returncode == 0 and m.get("config_snapshot", {}).get("scenarios", {}).get("sha256_16"),
          f"exit={r.returncode}")

    # R18b（1.1.0 可复现性）：账本必须记录工具链指纹——skill 版本 / MANIFEST sha256 /
    #   参与脚本逐文件哈希 / python+依赖版本 / playwright CLI / runner。此前只记系统三元版本
    #   与比较器串，正式 PASS 无法复现（同一契约不同 skill 版本或不同 CLI 版本结果可不同）。
    _tc = m.get("toolchain") if isinstance(m, dict) else None
    _tc_ok = (isinstance(_tc, dict)
              and re.match(r"^\d+\.\d+\.\d+$", str(_tc.get("skill_version", ""))) is not None
              and len(str(_tc.get("manifest_sha256", ""))) == 64
              and isinstance(_tc.get("script_sha256_16"), dict)
              and "write-manifest.py" in " ".join(_tc.get("script_sha256_16", {}).keys())
              and str(_tc.get("python", "")).count(".") >= 1
              and isinstance(_tc.get("python_deps"), dict)
              and "playwright_cli" in _tc and "runner" in _tc)
    check("manifest: 工具链指纹落账（skill 版本/MANIFEST sha256/脚本哈希/python 依赖/CLI）",
          _tc_ok, f"toolchain={json.dumps(_tc, ensure_ascii=False)[:200] if _tc else None}")

    # ---------- 第五轮回归（2026-09-06 第三轮独立对抗审计） ----------
    # S1. tolerance 非有限数（abs:inf/1e999/nan/-1/abc）→ BLOCKED（此前 abs:inf 可容忍一切数值差异=假 OK→假 PASS）
    tol_hits = 0
    for badtol in ("abs:inf", "abs:1e999", "abs:nan", "abs:-1", "abs:abc"):
        rules_bad_tol = fc_rules(fms=[dict(FM[0], normalize="number", tolerance=badtol)])
        r = cmp_run(tmp / f"s1-{badtol.replace(':', '_').replace('.', '_').replace('-', 'm')}", rules_bad_tol,
                    [cap(steps={"s1": {"fields": {"OLD_CODE": 100}}})],
                    [cap(steps={"s1": {"fields": {"NEW_CODE": 99999}}})])
        tol_hits += int(r.returncode == 2)
    check("compare: tolerance abs:inf/1e999/nan/-1/abc 全部 → BLOCKED(2)", tol_hits == 5, f"hits={tol_hits}/5")

    # S2. 豁免 match='00' 不得经二次剥前缀跨维度吞差异（此前 ':' 与 '/' 各剥一次，buttons 差异被 routing 豁免误杀）
    rules_oo = fc_rules(fms=FM)
    rules_oo["routing"] = [{"node": "00", "candidates_legacy": ["01"]}]
    rules_oo["buttons"] = [{"node": "00", "expect_visible": [], "expect_hidden": ["退回流程"]}]
    rules_oo["exemptions"] = [dict({"id": "EX-R00", "scope": "*", "match": "00", "reason": "r", "approved_by": "b"}, **EXC_CHAIN)]
    r = cmp_run(tmp / "s2", rules_oo,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"routing": {"00": ["01"]}, "buttons": {"00": ["保存"]}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"routing": {"00": ["02"]}, "buttons": {"00": ["保存", "退回流程"]}})])
    j = json.loads((tmp / "s2" / "out" / "field-compare.json").read_text())
    check("compare: 豁免 match='00' 不跨维度吞差异 → FAIL", r.returncode == 1 and len(j["diffs"]) == 3 and not j["exempted"],
          f"exit={r.returncode} diffs={len(j['diffs'])} exempted={len(j['exempted'])}")

    # S2b. 稳定键豁免（去文件名前缀一次）仍生效——兼容回归
    rules_sk = fc_rules(fms=FM)
    rules_sk["routing"] = [{"node": "00", "candidates_legacy": ["01"]}]
    rules_sk["exemptions"] = [dict({"id": "EX-R", "scope": "routing", "match": "routing/00", "reason": "r", "approved_by": "b"}, **EXC_CHAIN)]
    r = cmp_run(tmp / "s2b", rules_sk,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"routing": {"00": ["01"]}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"routing": {"00": ["02"]}})])
    j = json.loads((tmp / "s2b" / "out" / "field-compare.json").read_text())
    check("compare: 稳定键豁免（routing/00）仍生效 → OK+豁免", r.returncode == 0 and len(j["exempted"]) == 1,
          f"exit={r.returncode} exempted={len(j['exempted'])}")

    # S3. validate: 契约 tolerance=abs:inf → 拒绝（立契期拦截）
    badT = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    badT["field_mappings"][0]["tolerance"] = "abs:inf"
    cpT = tmp / "bad-tol.yaml"; cpT.write_text(_y.safe_dump(badT, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cpT), "--level", "test_ready"])
    check("validate: tolerance=abs:inf → 拒绝", r.returncode == 2 and "tolerance" in r.stderr, r.stderr[:100])

    # S4. gen --allow-draft：summary.template.json 与 compare-rules.json 也必须带草稿标记
    od4 = tmp / "gen-allow-draft-s4"
    r = run([sys.executable, str(HERE / "gen_from_contract.py"), "--contract", str(dp), "--outdir", str(od4), "--allow-draft"],
            env={**__import__("os").environ, "PYTHONPATH": ""})
    tpl = json.loads((od4 / "summary.template.json").read_text(encoding="utf-8"))
    crj = json.loads((od4 / "compare-rules.json").read_text(encoding="utf-8"))
    check("gen: --allow-draft 全产物带标记（含 summary 模板/compare-rules.json）",
          r.returncode == 0 and tpl.get("draft") is True and crj.get("meta", {}).get("draft") is True,
          f"exit={r.returncode} tpl.draft={tpl.get('draft')} rules.draft={crj.get('meta', {}).get('draft')}")

    # S5. conclude: 账本 abs_path 指向诱饵副本（hash 一致但非报告目录文件）→ BLOCKED
    d5 = tmp / "s5-decoy"; d5.mkdir(parents=True)
    w(d5 / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(d5 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": []})
    w(d5 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    decoy = tmp / "s5-decoy-file.json"
    decoy.write_text('[{"id":"g","severity":"P0","passed":false}]', encoding="utf-8")
    w(d5 / "run-manifest.json", {"run_id": "s5-decoy", "config_snapshot": {
        "gates": {"path": "gates.json", "abs_path": str(decoy.resolve()),
                  "sha256_16": _h.sha256(decoy.read_bytes()).hexdigest()[:16]},
        "case_results": {"path": "case-results.json", "abs_path": str((d5 / "case-results.json").resolve()),
                         "sha256_16": _h.sha256((d5 / "case-results.json").read_bytes()).hexdigest()[:16]},
        "field_compare": {"path": "field-compare.json", "abs_path": str((d5 / "field-compare.json").resolve()),
                          "sha256_16": _h.sha256((d5 / "field-compare.json").read_bytes()).hexdigest()[:16]}}})
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d5)])
    check("conclude: 账本诱饵 abs_path（hash 一致的别处副本）→ BLOCKED",
          r.returncode == 2 and "诱饵" in reasons_of(d5), f"exit={r.returncode}")

    # S6. pipeline: 执行件与契约不同源（篡改 rules/场景）→ dry-run 拒绝(2)
    s6out = tmp / "s6-gen"
    run([sys.executable, str(HERE / "gen_from_contract.py"),
         "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"), "--outdir", str(s6out)],
        env={**__import__("os").environ, "PYTHONPATH": ""})
    pipeline_sh = SCRIPTS / "pipeline.sh"
    s6_rules = json.loads((s6out / "compare-rules.json").read_text(encoding="utf-8"))
    s6_rules["field_mappings"][0]["tolerance"] = "abs:inf"
    (s6out / "compare-rules.json").write_text(json.dumps(s6_rules, ensure_ascii=False, indent=2), encoding="utf-8")
    r = run(["bash", str(pipeline_sh), "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"),
             "--scenario-dir", str(s6out / "flowtrace-scenarios"), "--rules", str(s6out / "compare-rules.json"), "--dry-run"], env=ENV_FULLSYS)
    check("pipeline(dry-run): 篡改 compare-rules → 拒绝(2)", r.returncode == 2 and "不同源" in (r.stdout + r.stderr),
          f"exit={r.returncode}")
    # 恢复 rules 后应可过（证明拦截是同源复算而非误伤）
    run([sys.executable, str(HERE / "gen_from_contract.py"),
         "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"), "--outdir", str(s6out)],
        env={**__import__("os").environ, "PYTHONPATH": ""})
    r = run(["bash", str(pipeline_sh), "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"),
             "--scenario-dir", str(s6out / "flowtrace-scenarios"), "--rules", str(s6out / "compare-rules.json"), "--dry-run"], env=ENV_FULLSYS)
    check("pipeline(dry-run): 干净执行件同源复算通过", r.returncode == 0, f"exit={r.returncode} {r.stderr[-120:]}")

    # S7. pipeline: run-id 含引号/..（此前仅拦 '/' 与 '..'，引号可进入 python -c 字符串内插）→ 拒绝(2)
    bad_ids_ok = True
    for rid in ("x')) or 1 or ('", "a..b", "a b", "a/b"):
        r = run(["bash", str(pipeline_sh), "--run-id", rid, "--dry-run"])
        bad_ids_ok = bad_ids_ok and r.returncode == 2
    check("pipeline: 非法 run-id（引号/.. /空格/斜杠）→ 拒绝(2)", bad_ids_ok)

    # ---------- 第六轮回归（2026-09-06 第四轮独立对抗审计） ----------
    # T1. 可审计豁免 scope='field'+match='*'（维度级通配）→ BLOCKED（此前整维度差异全免→假 OK→假 PASS）
    rules_t1 = fc_rules(fms=FM)
    rules_t1["exemptions"] = [dict({"id": "EX-DIM", "scope": "field", "match": "*", "reason": "r", "approved_by": "boss"}, **EXC_CHAIN)]
    r = cmp_run(tmp / "t1-wild", rules_t1,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "A"}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "B"}}})])
    j = json.loads((tmp / "t1-wild" / "out" / "field-compare.json").read_text())
    check("compare: 可审计豁免 match='*'（维度通配）→ BLOCKED", r.returncode == 2 and j["status"] == "BLOCKED",
          f"exit={r.returncode} status={j['status']}")

    # T2. validate: 豁免 match='*'（scope 具体维度，五字段齐全可审计）→ 立契期拒绝
    badT1 = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    badT1["exemptions"] = [dict({"id": "EX-DIM", "scope": "field", "match": "*", "reason": "r", "approved_by": "b"}, **EXC_CHAIN)]
    cpT1 = tmp / "bad-wild-exem.yaml"; cpT1.write_text(_y.safe_dump(badT1, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cpT1), "--level", "test_ready"])
    check("validate: 豁免 match='*' → 拒绝（通配）", r.returncode == 2 and "通配" in r.stderr, r.stderr[:120])

    # T3. conclude: field-compare coverage 非 list（dict）→ BLOCKED(2)（此前 [:3] 切片 TypeError crash→exit 1 伪装 FAIL）
    r = concl("t3-cov", fc=json.dumps({"status": "BLOCKED", "coverage": {"a": 1}}))
    check("conclude: coverage 非 list → BLOCKED(2) 不 crash", r.returncode == 2 and "Traceback" not in r.stderr,
          f"exit={r.returncode}")

    # T4. conclude: diffs 含非对象条目 → BLOCKED(2)（此前 summary 渲染 AttributeError crash→exit 1 伪装 FAIL）
    r = concl("t4-diff", fc=json.dumps({"status": "FAIL", "diffs": [1, 2], "exempted": []}))
    check("conclude: diffs 非对象条目 → BLOCKED(2) 不 crash", r.returncode == 2 and "Traceback" not in r.stderr,
          f"exit={r.returncode}")

    # T5. pipeline: 用法错误（未知参数/带值参数缺值）→ exit 2（此前 exit 1 与 FAIL 结论码冲突=伪装 FAIL）
    usage_ok = True
    for bad_args in (["--bogus"], ["--contract"], ["--run-id"], ["--rules"], ["--plants"]):
        r = run(["bash", str(pipeline_sh)] + bad_args)
        usage_ok = usage_ok and r.returncode == 2
    check("pipeline: 用法错误（未知参数/缺值）→ exit 2", usage_ok)

    # T6. pipeline(dry-run): rules 语义等价但字节不同（重排缩进）→ 拒绝(2)——同源复算必须逐字节
    s6_rules2 = json.loads((s6out / "compare-rules.json").read_text(encoding="utf-8"))
    (s6out / "compare-rules.json").write_text(json.dumps(s6_rules2, ensure_ascii=False, indent=4), encoding="utf-8")
    r = run(["bash", str(pipeline_sh), "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"),
             "--scenario-dir", str(s6out / "flowtrace-scenarios"), "--rules", str(s6out / "compare-rules.json"), "--dry-run"], env=ENV_FULLSYS)
    check("pipeline(dry-run): rules 重排（语义等价字节不同）→ 拒绝(2)",
          r.returncode == 2 and "不同源" in (r.stdout + r.stderr), f"exit={r.returncode}")

    # T7. pipeline(dry-run): 零字节码副作用——import gen_from_contract 不得落 __pycache__（零副作用承诺）
    import shutil as _sh
    _sh.rmtree(HERE / "__pycache__", ignore_errors=True)
    run([sys.executable, str(HERE / "gen_from_contract.py"),
         "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"), "--outdir", str(s6out)],
        env={**__import__("os").environ, "PYTHONPATH": ""})
    r = run(["bash", str(pipeline_sh), "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"),
             "--scenario-dir", str(s6out / "flowtrace-scenarios"), "--rules", str(s6out / "compare-rules.json"), "--dry-run"], env=ENV_FULLSYS)
    check("pipeline(dry-run): 零字节码副作用（无 __pycache__）",
          r.returncode == 0 and not (HERE / "__pycache__").exists(), f"exit={r.returncode}")

    # T8. compare: abs 容差下 True vs 1（bool 陷阱 abs 分支，此前回退 a==b 判等→假 MATCH）
    #     v2.7 升级（第八轮）：数值化字段里的布尔=真值伪装/类型畸形 → BLOCKED（不再记 diff 冒用 FAIL，
    #     与 post_flow registered 非布尔同口径——承诺"类型畸形任何字段任何层→BLOCKED 不冒用 FAIL(1)"）
    r = cmp_run(tmp / "t8-bool-abs", fc_rules(fms=[dict(FM[0], normalize="none", tolerance="abs:0.01")]),
                [cap(steps={"s1": {"fields": {"OLD_CODE": True}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": 1}}})])
    j = json.loads((tmp / "t8-bool-abs" / "out" / "field-compare.json").read_text())
    check("compare: abs 容差 True vs 1 → BLOCKED（bool 真值伪装不冒用 FAIL）", r.returncode == 2 and j["status"] == "BLOCKED",
          f"exit={r.returncode} status={j['status']}")

    # ---------- 第七轮回归（2026-09-06 第五轮独立对抗审计·收敛轮） ----------
    # U1. conclude: observe.optional 非布尔（'yes'/'false'/1）→ BLOCKED
    #     （此前 truthy 非 bool 被判 optional——非 optional OBSERVE 阻断被绕过可推假 PASS）
    opt_ok = True
    for i, opt in enumerate(("yes", "false", 1)):
        d7 = tmp / f"u1-{i}"; d7.mkdir(parents=True, exist_ok=True)
        w(d7 / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
        w(d7 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": [],
                                       "observe": [{"key": "c0/s1/CS", "optional": opt, "note": "n"}]})
        w(d7 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
        w(d7 / "run-manifest.json", dict({"run_id": d7.name}, **snap_of(d7)))
        r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d7)])
        opt_ok = opt_ok and r.returncode == 2
    check("conclude: observe optional 非布尔（'yes'/'false'/1）→ BLOCKED", opt_ok)

    # U2. 兼容回归：optional=True（字面布尔）仍放行 PASS
    d7 = tmp / "u2-bool"; d7.mkdir(parents=True, exist_ok=True)
    w(d7 / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(d7 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": [],
                                   "observe": [{"key": "k", "optional": True, "note": "n"}]})
    w(d7 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    w(d7 / "run-manifest.json", dict({"run_id": d7.name}, **snap_of(d7)))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d7)])
    check("conclude: optional=True(bool) 不阻断 → PASS（兼容）", r.returncode == 0, f"exit={r.returncode}")

    # U3. compare: outdir 被普通文件占用 → BLOCKED(2)（此前 traceback crash exit 1 冒用 FAIL 结论码）
    u3 = tmp / "u3"; u3.mkdir()
    (u3 / "rules.json").write_text(json.dumps(fc_rules(fms=[])), encoding="utf-8")
    w(u3 / "caps/legacy/c0.json", cap(steps={}))
    w(u3 / "caps/current/c0.json", cap(steps={}))
    (u3 / "out").write_text("occupied", encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "field-level-compare.py"),
             "--captures-dir", str(u3 / "caps"), "--rules", str(u3 / "rules.json"), "--outdir", str(u3 / "out")])
    check("compare: outdir 被文件占用 → BLOCKED(2) 不 crash 伪装 FAIL",
          r.returncode == 2 and "对拍器内部异常" in r.stderr, f"exit={r.returncode}")

    # U4. runner: exec-dir 被普通文件占用 → exit 2（本执行器无 1 语义，crash 不得引入）
    u4 = tmp / "u4"; u4.mkdir()
    (u4 / "scen").mkdir()
    (u4 / "scen/s.yaml").write_text(_y.safe_dump({"id": "x-c-01", "case_id": "C-01", "required": True}), encoding="utf-8")
    (u4 / "f").write_text("occupied", encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(u4 / "scen"),
             "--exec-dir", str(u4 / "f"), "--run-id", "u4"],
            env={**__import__("os").environ, "FLOWTEST_RUNNER": "cli", "FLOWTEST_CLI": "/nonexistent"})
    check("runner: exec-dir 被文件占用 → exit 2 不 crash", r.returncode == 2, f"exit={r.returncode}")

    # U5. manifest: run-id 尾随换行（Python '$' 允许、bash ERE 拒绝——口径必须一致）→ 拒绝(2)
    r = run([sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", "abc\n",
             "--reports-dir", str(tmp / "mf-u5"), "--project-root", str(tmp), "--allow-unrecorded-versions"])
    check("manifest: run-id 尾随换行 → 拒绝(2)", r.returncode == 2 and not (tmp / "mf-u5").exists(),
          f"exit={r.returncode}")

    # U6. compare: mask 短值（<8 字符）全遮 ***——不泄露首尾字符（此前 len=5 泄露 4/5 字符）
    rules_mask = fc_rules(fms=[dict(FM[0], redact="mask")])
    r = cmp_run(tmp / "u6", rules_mask,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "abcde"}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "xyz"}}})])
    blob6 = (tmp / "u6" / "out" / "field-compare.json").read_text(encoding="utf-8")
    check("compare: mask 短值(<8) 全遮 ***（不露首尾）",
          r.returncode == 1 and "abcde" not in blob6 and "xyz" not in blob6 and blob6.count('"***"') >= 2,
          f"exit={r.returncode}")

    # U7. conclude: summary.md 动态值转义（差异 key 含换行/ANSI 不得伪造标题行欺骗人工）
    d7 = tmp / "u7"; d7.mkdir(parents=True, exist_ok=True)
    w(d7 / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(d7 / "field-compare.json", {"status": "FAIL", "diffs": [{"dim": "field", "key": "c0\n## 伪造 PASS 报告\n\x1b[31m", "legacy": 1, "current": 2, "reason": "t"}], "exempted": [], "coverage": []})
    w(d7 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    w(d7 / "run-manifest.json", dict({"run_id": d7.name}, **snap_of(d7)))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d7)])
    md7 = (d7 / "summary.md").read_text(encoding="utf-8")
    check("conclude: summary.md 注入转义（换行/ESC 不入标题）",
          r.returncode == 1 and "\n## 伪造 PASS 报告" not in md7 and "\\n## 伪造 PASS 报告" in md7,
          f"exit={r.returncode}")

    # ---------- 第八轮回归（2026-09-06 第六轮独立对抗审计·收敛判定轮） ----------
    # V1. conclude: observe 含非对象条目（类型畸形证据）→ BLOCKED
    #     （此前 isinstance 过滤静默跳过——observe:["corrupt"] 可绕过非 optional OBSERVE 阻断推假 PASS）
    d8 = tmp / "v1"; d8.mkdir(parents=True, exist_ok=True)
    w(d8 / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(d8 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": [],
                                   "observe": ["corrupt-entry"]})
    w(d8 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    w(d8 / "run-manifest.json", dict({"run_id": d8.name}, **snap_of(d8)))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d8)])
    check("conclude: observe 非对象条目 → BLOCKED（类型畸形不推假 PASS）",
          r.returncode == 2 and "Traceback" not in r.stderr, f"exit={r.returncode}")

    # V2. compare: buttons 采集值非列表（双端同字符串）→ BLOCKED（不再字符集合化记假 MATCH）
    rules_v2 = fc_rules(fms=FM)
    rules_v2["buttons"] = [{"node": "00", "expect_visible": [], "expect_hidden": []}]
    r = cmp_run(tmp / "v2", rules_v2,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"buttons": {"00": "保存草稿"}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"buttons": {"00": "保存草稿"}})])
    j = json.loads((tmp / "v2" / "out" / "field-compare.json").read_text())
    btn_match2 = [m for m in (j.get("matches") or []) if m.get("dim") == "buttons"]
    stats_btn = j["stats"]["match"]
    check("compare: buttons 采集值非列表 → BLOCKED（不记假 MATCH）",
          r.returncode == 2 and j["status"] == "BLOCKED" and stats_btn == 1,
          f"exit={r.returncode} status={j['status']} match统计={stats_btn}（应只剩 field 1 个）")

    # V3. validate: draft 级 meta 非对象 → exit 2 无 Traceback（此前 AttributeError crash exit 1）
    v3c = tmp / "v3-meta.yaml"
    v3c.write_text("meta: hello\n", encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(v3c), "--level", "draft"])
    check("validate: meta 非对象（draft 级）→ 拒绝(2) 不 crash",
          r.returncode == 2 and "Traceback" not in r.stderr, f"exit={r.returncode}")

    # V4. validate: test_ready 级容器畸形（cases 非列表/accounts 非列表）→ exit 2 无 Traceback
    #     （此前 schema 报错后仍继续语义段 → .get/迭代 crash exit 1 未定义退出码）
    v4_ok = True
    for i, (k, v) in enumerate((("cases", {"C-01": {}}), ("accounts", {"a": 1}), ("meta", "oops"), ("field_mappings", "oops"))):
        badv = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
        badv[k] = v
        cpv = tmp / f"v4-{i}.yaml"; cpv.write_text(_y.safe_dump(badv, allow_unicode=True), encoding="utf-8")
        r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cpv), "--level", "test_ready"])
        v4_ok = v4_ok and r.returncode == 2 and "Traceback" not in r.stderr
    check("validate: 容器类型畸形（cases/accounts/meta/field_mappings）→ 拒绝(2) 不 crash", v4_ok)

    # V5. gen: --allow-draft 畸形 DRAFT 契约（cases 非 list / 数值 id）→ 干净拒绝（零写入、无 Traceback）
    v5_ok = True
    for i, text in enumerate((
        "meta:\n  flow_name: 测试\n  flow_code: WFA_X_0001\n  shape: S1\n  contract_version: 1\n  status: DRAFT\ncases:\n  C-01: {title: t}\n",
        "meta:\n  flow_name: 测试\n  flow_code: WFA_X_0001\n  shape: S1\n  contract_version: 1\n  status: DRAFT\ncases:\n  - id: 1\n    title: t\n    required: true\n    steps: [{node: '00', actor: a, action: go}]\n",
    )):
        c5 = tmp / f"v5-{i}.yaml"; c5.write_text(text, encoding="utf-8")
        o5 = tmp / f"v5-out-{i}"
        r = run([sys.executable, str(HERE / "gen_from_contract.py"), "--contract", str(c5), "--outdir", str(o5), "--allow-draft"],
                env={**__import__("os").environ, "PYTHONPATH": ""})
        v5_ok = v5_ok and r.returncode != 0 and "Traceback" not in r.stderr and not o5.exists()
    check("gen: --allow-draft 畸形契约 → 干净拒绝（零写入、无 Traceback）", v5_ok)

    # ---------- 第九轮回归（2026-09-06 第七轮独立对抗审计·零发现判定轮） ----------
    # W1. fixture_pairs=dict（类型畸形）双端同构 → BLOCKED
    #     （此前键集合化被误读为有效配对：fixture_pair_required 满足→假 MATCH→假 OK→全链假 PASS）
    r = cmp_run(tmp / "w1", fc_rules(fms=FM_FX, fixtures=FX),
                [cap(pairs={"FP-X": 1}, steps={"s1": {"fields": {"CS": 2}}})],
                [cap(pairs={"FP-X": 1}, steps={"s1": {"fields": {"CS": 2}}})])
    j = json.loads((tmp / "w1" / "out" / "field-compare.json").read_text())
    check("compare: fixture_pairs=dict 双端同构 → BLOCKED（假配对推假 PASS 已封死）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # W2. fixture_pairs=字符串 → BLOCKED（字符集合化不得视为配对声明）
    r = cmp_run(tmp / "w2", fc_rules(fms=FM_FX, fixtures=FX),
                [cap(pairs="FP-X", steps={"s1": {"fields": {"CS": 2}}})],
                [cap(pairs="FP-X", steps={"s1": {"fields": {"CS": 2}}})])
    j = json.loads((tmp / "w2" / "out" / "field-compare.json").read_text())
    check("compare: fixture_pairs=字符串 → BLOCKED", r.returncode == 2 and j["status"] == "BLOCKED",
          f"exit={r.returncode} status={j['status']}")

    # W3. routing must_not_contain=字符串且禁含候选实存 → BLOCKED（此前字符集合化=禁含断言静默失效记假 OK）
    rules_w3 = fc_rules(fms=FM)
    rules_w3["routing"] = [{"node": "00", "candidates_legacy": ["01", "02"], "must_not_contain": "02"}]
    r = cmp_run(tmp / "w3", rules_w3,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"routing": {"00": ["01", "02"]}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"routing": {"00": ["01", "02"]}})])
    j = json.loads((tmp / "w3" / "out" / "field-compare.json").read_text())
    check("compare: must_not_contain=字符串（禁含候选实存）→ BLOCKED 不记假 MATCH",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # W4. buttons expect_hidden=字符串（隐藏按钮实际可见）→ BLOCKED
    rules_w4 = fc_rules(fms=FM)
    rules_w4["buttons"] = [{"node": "00", "expect_visible": ["保存"], "expect_hidden": "退回流程"}]
    r = cmp_run(tmp / "w4", rules_w4,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"buttons": {"00": ["保存", "退回流程"]}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"buttons": {"00": ["保存", "退回流程"]}})])
    j = json.loads((tmp / "w4" / "out" / "field-compare.json").read_text())
    check("compare: expect_hidden=字符串（隐藏按钮可见）→ BLOCKED 不记假 OK",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # W5. buttons 规则：全为无 node 注记条目 / 含非对象条目 → BLOCKED（声明维度不得静默跳过）
    rules_w5a = fc_rules(fms=FM)
    rules_w5a["buttons"] = [{"rule": "仅注记"}]
    r = cmp_run(tmp / "w5a", rules_w5a,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"buttons": {"00": ["保存"]}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"buttons": {"00": ["保存"]}})])
    ja = json.loads((tmp / "w5a" / "out" / "field-compare.json").read_text())
    rules_w5b = fc_rules(fms=FM)
    rules_w5b["buttons"] = [5, "x"]
    r5b = cmp_run(tmp / "w5b", rules_w5b,
                  [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"buttons": {"00": ["保存"]}})],
                  [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"buttons": {"00": ["保存"]}})])
    jb = json.loads((tmp / "w5b" / "out" / "field-compare.json").read_text())
    check("compare: buttons 全注记条目/非对象条目 → BLOCKED（不再静默跳过声明维度）",
          r.returncode == 2 and ja["status"] == "BLOCKED" and r5b.returncode == 2 and jb["status"] == "BLOCKED",
          f"a={r.returncode}/{ja['status']} b={r5b.returncode}/{jb['status']}")

    # W5b兼容. 注记条目与可比条目混排（实例契约形态：node 条目 + `- rule:` 注记）→ 正常比对不误伤
    rules_w5c = fc_rules(fms=FM)
    rules_w5c["buttons"] = [{"node": "00", "expect_visible": ["保存"], "expect_hidden": []},
                            {"rule": {"手动盖章": "state=3/4 才可用"}}]
    r = cmp_run(tmp / "w5c", rules_w5c,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"buttons": {"00": ["保存"]}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"buttons": {"00": ["保存"]}})])
    j = json.loads((tmp / "w5c" / "out" / "field-compare.json").read_text())
    check("compare: buttons 注记+可比混排（实例契约形态）→ 正常 MATCH 不 BLOCKED",
          r.returncode == 0 and j["status"] == "OK" and j["stats"]["match"] == 2,
          f"exit={r.returncode} status={j['status']} match统计={j['stats']['match']}（field1+buttons1）")

    # W6. post_flow registered='true' 字符串双端同值 → BLOCKED（此前 diff 冒用 FAIL(1)）
    rules_w6 = fc_rules(fms=FM)
    rules_w6["post_flow"] = {"code": "WFA_X_0002", "trigger": "t", "starter": {}, "inherits": {}}
    r = cmp_run(tmp / "w6", rules_w6,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"post_flow": {"registered": "true", "inherits": {}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"post_flow": {"registered": "true", "inherits": {}}})])
    j = json.loads((tmp / "w6" / "out" / "field-compare.json").read_text())
    check("compare: post_flow registered 非布尔双端同值 → BLOCKED（不冒用 FAIL）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # W7. routing candidates_legacy=字符串 → BLOCKED（此前字符集合化=假 FAIL）
    rules_w7 = fc_rules(fms=FM)
    rules_w7["routing"] = [{"node": "00", "candidates_legacy": "01,02"}]
    r = cmp_run(tmp / "w7", rules_w7,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"routing": {"00": ["01", "02"]}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"routing": {"00": ["01", "02"]}})])
    check("compare: candidates_legacy=字符串 → BLOCKED（不假 FAIL）", r.returncode == 2, f"exit={r.returncode}")

    # W8. case_id 非字符串（int）双端同值 → BLOCKED（类型畸形不视为有效配对）
    r = cmp_run(tmp / "w8", fc_rules(fms=FM),
                [{"flow_code": "WFA_X_0001", "case_id": 5, "fixture_pairs": [], "steps": {"s1": {"fields": {"OLD_CODE": "V"}}}}],
                [{"flow_code": "WFA_X_0001", "case_id": 5, "fixture_pairs": [], "steps": {"s1": {"fields": {"NEW_CODE": "V"}}}}])
    j = json.loads((tmp / "w8" / "out" / "field-compare.json").read_text())
    check("compare: case_id 非字符串双端同值 → BLOCKED", r.returncode == 2 and j["status"] == "BLOCKED",
          f"exit={r.returncode} status={j['status']}")

    # W9. conclude: 对拍 status 不可哈希（list）→ BLOCKED 不 Traceback（此前 TypeError crash 面）
    r = concl("w9", fc=json.dumps({"status": ["OK"], "diffs": [], "exempted": []}))
    check("conclude: status=list（不可哈希）→ BLOCKED(2) 不 Traceback",
          r.returncode == 2 and "Traceback" not in r.stderr, f"exit={r.returncode}")

    # W10. conclude: 账本 abs_path 非字符串（int）→ BLOCKED 不 Traceback（此前 Path(123) TypeError）
    d10 = tmp / "w10"; d10.mkdir(parents=True)
    w(d10 / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(d10 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": []})
    w(d10 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    snap10 = snap_of(d10)
    snap10["config_snapshot"]["gates"]["abs_path"] = 12345
    w(d10 / "run-manifest.json", {"run_id": "w10", **snap10})
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d10)])
    check("conclude: 账本 abs_path=int → BLOCKED(2) 不 Traceback",
          r.returncode == 2 and "Traceback" not in r.stderr, f"exit={r.returncode}")

    # W11. validate: 自由文本中文凭据（密码：/口令= 全角半角）→ 拒绝（此前放行且 gen 渲染进产物）
    cred_ok = True
    for i, note in enumerate(("管理员密码：Xk93mfk2Z9（老库）", "值班口令=Abcdefg6!")):
        badw = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
        badw["meta"]["notes"] = note
        cpw = tmp / f"w11-{i}.yaml"; cpw.write_text(_y.safe_dump(badw, allow_unicode=True), encoding="utf-8")
        r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cpw), "--level", "test_ready"])
        cred_ok = cred_ok and r.returncode == 2 and "明文凭据" in r.stderr
    check("validate: 中文凭据自由文本（密码：/口令=）→ 拒绝", cred_ok)

    # W12. validate: routing/buttons 列表字段字符串形态 → 立契期拒绝
    badw2 = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    badw2["routing"][0]["must_not_contain"] = "02"
    cpw2 = tmp / "w12.yaml"; cpw2.write_text(_y.safe_dump(badw2, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cpw2), "--level", "test_ready"])
    ok_w12a = r.returncode == 2 and "must_not_contain 非列表" in r.stderr
    badw3 = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    badw3["buttons"][0]["expect_visible"] = "保存草稿"
    cpw3 = tmp / "w12b.yaml"; cpw3.write_text(_y.safe_dump(badw3, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cpw3), "--level", "test_ready"])
    ok_w12b = r.returncode == 2 and "expect_visible 非列表" in r.stderr
    check("validate: must_not_contain/expect_visible 字符串形态 → 拒绝", ok_w12a and ok_w12b,
          f"a={ok_w12a} b={ok_w12b}")

    # W13. manifest: 登记不可读文件 → exit 2（顶层兜底，不 crash 未定义退出码）
    noperm = tmp / "noperm.json"; noperm.write_text("{}", encoding="utf-8"); noperm.chmod(0o000)
    r = run([sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", "w13", "--reports-dir", str(tmp / "mf-w13"),
             "--project-root", str(tmp), "--allow-unrecorded-versions", "--contract", str(noperm)])
    noperm.chmod(0o644)
    check("manifest: 登记不可读文件 → exit 2（fail-closed 兜底）", r.returncode == 2, f"exit={r.returncode}")

    # ---------- 第十轮回归（2026-09-06 第八轮独立审计·收敛复核轮） ----------
    # 主题：值级类型畸形族（第七轮封容器级——fixture_pairs/断言列表/registered/case_id；
    #        值级仍可推假 MATCH/冒用 FAIL）
    # X1. 字段值=dict（双端内容不同）+ normalize:number → BLOCKED
    #     （此前 norm_number 折 None→null_policy 判"双空相等"→假 MATCH→全链假 PASS）
    FM_NUMX = [{"legacy_field": "CS", "target_field": "CS", "normalize": "number",
                "tolerance": "abs:0", "null_policy": "both_null_equal"}]
    r = cmp_run(tmp / "x1", fc_rules(fms=FM_NUMX),
                [cap(steps={"s1": {"fields": {"CS": {"a": 1}}}})],
                [cap(steps={"s1": {"fields": {"CS": {"b": 2}}}})])
    j = json.loads((tmp / "x1" / "out" / "field-compare.json").read_text())
    check("compare: 字段值=dict 不同内容+number → BLOCKED（不记假 MATCH）",
          r.returncode == 2 and j["status"] == "BLOCKED" and j["stats"]["match"] == 0,
          f"exit={r.returncode} status={j['status']} match={j['stats']['match']}")

    # X2. 字段值=同 dict + exact（不经归一化）→ BLOCKED（此前 str/dict 相等记假 MATCH）
    r = cmp_run(tmp / "x2", fc_rules(fms=[{"legacy_field": "CS", "target_field": "CS", "tolerance": "exact",
                                            "null_policy": "both_null_equal"}]),
                [cap(steps={"s1": {"fields": {"CS": {"x": 1}}}})],
                [cap(steps={"s1": {"fields": {"CS": {"x": 1}}}})])
    j = json.loads((tmp / "x2" / "out" / "field-compare.json").read_text())
    check("compare: 字段值=同dict+exact → BLOCKED（同构垃圾不判一致）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # X3. 字段值=不可数值化字符串（双端不同值）+ number → BLOCKED（此前折 None→双空相等假 MATCH）
    r = cmp_run(tmp / "x3", fc_rules(fms=FM_NUMX),
                [cap(steps={"s1": {"fields": {"CS": "待定A"}}})],
                [cap(steps={"s1": {"fields": {"CS": "待定B"}}})])
    j = json.loads((tmp / "x3" / "out" / "field-compare.json").read_text())
    check("compare: 字段值=不可数值化不同串+number → BLOCKED（不假 MATCH/不假 FAIL）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # X4. 公式值=dict 同构 + abs 容差 → BLOCKED（此前 abs 回退记假 MATCH/假 diff 冒用 FAIL）
    rules_x4 = fc_rules(fms=FM)
    rules_x4["formulas"] = [{"id": "A.1", "expr": "e", "expected_legacy": 1, "tolerance": "abs:0.01", "nodes_applied": ["00"]}]
    r = cmp_run(tmp / "x4", rules_x4,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"formulas": {"A.1": {"a": 1}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"formulas": {"A.1": {"a": 1}}})])
    j = json.loads((tmp / "x4" / "out" / "field-compare.json").read_text())
    check("compare: 公式值=同dict+abs → BLOCKED（不冒用 FAIL/不假 MATCH）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # X5. 公式值=不可数值化字符串双端 + abs → BLOCKED（此前原始值回退记假 diff 冒用 FAIL）
    r = cmp_run(tmp / "x5", rules_x4,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"formulas": {"A.1": "n/a"}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"formulas": {"A.1": "N/A"}})])
    j = json.loads((tmp / "x5" / "out" / "field-compare.json").read_text())
    check("compare: 公式值=不可数值化串+abs → BLOCKED（不冒用 FAIL）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # X6. post_flow.inherits 值=同 dict → BLOCKED（此前 str() 化相等记假 MATCH）
    rules_x6 = fc_rules(fms=FM); rules_x6["post_flow"] = {"code": "WFA_X_0002"}
    r = cmp_run(tmp / "x6", rules_x6,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"post_flow": {"registered": True, "inherits": {"KC": {"a": 1}}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"post_flow": {"registered": True, "inherits": {"KC": {"a": 1}}}})])
    j = json.loads((tmp / "x6" / "out" / "field-compare.json").read_text())
    check("compare: inherits 值=同dict → BLOCKED（同构垃圾不判一致）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # X7. resources 值=同 dict → BLOCKED（此前 str() 化相等记假 MATCH）
    rules_x7 = fc_rules(fms=FM); rules_x7["resources"] = [{"id": "res1"}]
    r = cmp_run(tmp / "x7", rules_x7,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"resources": {"res1": {"s": 1}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"resources": {"res1": {"s": 1}}})])
    j = json.loads((tmp / "x7" / "out" / "field-compare.json").read_text())
    check("compare: resources 值=同dict → BLOCKED（同构垃圾不判一致）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # X8. 误伤方向：合法数值形态（字符串/数值/千分位/负数/科学计数/带空格）照常 MATCH
    FM_OK8 = [{"legacy_field": "CS", "target_field": "CS", "normalize": "number",
               "tolerance": "abs:0.01", "null_policy": "both_null_equal"}]
    ok_hits = 0
    for tag8, lv8, cv8 in (("s", "1234.5", 1234.5), ("comma", "1,234.50", "1234.5"),
                           ("neg", -3.2, "-3.2"), ("sci", "1.5e2", 150.0), ("sp", " 12 ", 12)):
        r = cmp_run(tmp / f"x8-{tag8}", fc_rules(fms=FM_OK8),
                    [cap(steps={"s1": {"fields": {"CS": lv8}}})],
                    [cap(steps={"s1": {"fields": {"CS": cv8}}})])
        ok_hits += int(r.returncode == 0)
    check("compare: 合法数值形态 5 种照常 MATCH（无误伤）", ok_hits == 5, f"hits={ok_hits}/5")

    # X9. fixture_pairs 元素级类型（列表但元素烂：int/空串）→ BLOCKED（第七轮容器级修复的元素级补面）
    fx_x9 = [{"fixture_pair_id": "FP-X", "kind": "t", "legacy_ref": "a", "current_ref": "b", "pairing_rule": "r"}]
    r = cmp_run(tmp / "x9a", fc_rules(fms=FM_FX, fixtures=fx_x9),
                [cap(pairs=[123], steps={"s1": {"fields": {"CS": 2}}})],
                [cap(pairs=[123], steps={"s1": {"fields": {"CS": 2}}})])
    ja = json.loads((tmp / "x9a" / "out" / "field-compare.json").read_text())
    r2 = cmp_run(tmp / "x9b", fc_rules(fms=FM_FX, fixtures=fx_x9),
                 [cap(pairs=[""], steps={"s1": {"fields": {"CS": 2}}})],
                 [cap(pairs=[""], steps={"s1": {"fields": {"CS": 2}}})])
    jb = json.loads((tmp / "x9b" / "out" / "field-compare.json").read_text())
    check("compare: fixture_pairs 元素级畸形（int/空串元素）→ BLOCKED",
          r.returncode == 2 and ja["status"] == "BLOCKED" and r2.returncode == 2 and jb["status"] == "BLOCKED",
          f"a={r.returncode}/{ja['status']} b={r2.returncode}/{jb['status']}")

    # X10. post_flow registered=1（int 真值伪装）双端同值 → BLOCKED（W6 字符串变体的 int 补面）
    rules_x10 = fc_rules(fms=FM); rules_x10["post_flow"] = {"code": "WFA_X_0002"}
    r = cmp_run(tmp / "x10", rules_x10,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"post_flow": {"registered": 1, "inherits": {}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"post_flow": {"registered": 1, "inherits": {}}})])
    j = json.loads((tmp / "x10" / "out" / "field-compare.json").read_text())
    check("compare: registered=1(int) 双端同值 → BLOCKED（int 真值伪装同拒）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # ---------- 第十一轮回归（2026-09-06 第九轮独立审计·收敛复核轮） ----------
    # 主题：非有限数值形态族（第八轮 norm_number raise 只挡 ValueError；
    #        float() 对 "inf"/"nan"/"1e999" 解析"成功"但产出非有限值，绕过 raise 路径）
    # Y1. 双端 "inf" 串 + number/exact → BLOCKED（此前 inf==inf 记假 MATCH→全链假 PASS）
    r = cmp_run(tmp / "y1", fc_rules(fms=FM_NUMX),
                [cap(steps={"s1": {"fields": {"CS": "inf"}}})],
                [cap(steps={"s1": {"fields": {"CS": "inf"}}})])
    j = json.loads((tmp / "y1" / "out" / "field-compare.json").read_text())
    check("compare: 双端'inf'串+number → BLOCKED（不记 inf==inf 假 MATCH）",
          r.returncode == 2 and j["status"] == "BLOCKED" and j["stats"]["match"] == 0,
          f"exit={r.returncode} status={j['status']} match={j['stats']['match']}")

    # Y2. "inf" vs "1e999"（不同原始串均溢出折 inf）+ exact → BLOCKED（此前互判一致掩盖真差异）
    r = cmp_run(tmp / "y2", fc_rules(fms=FM_NUMX),
                [cap(steps={"s1": {"fields": {"CS": "inf"}}})],
                [cap(steps={"s1": {"fields": {"CS": "1e999"}}})])
    j = json.loads((tmp / "y2" / "out" / "field-compare.json").read_text())
    check("compare: 'inf' vs '1e999' 折同 inf → BLOCKED（不同原始串不得互判一致）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # Y3. 双端 "nan" + abs → BLOCKED（此前 abs(nan-nan)<=t 恒 False 记假 diff 冒用 FAIL(1)）
    FM_ABX = [{"legacy_field": "CS", "target_field": "CS", "normalize": "number",
               "tolerance": "abs:0.01", "null_policy": "both_null_equal"}]
    r = cmp_run(tmp / "y3", fc_rules(fms=FM_ABX),
                [cap(steps={"s1": {"fields": {"CS": "nan"}}})],
                [cap(steps={"s1": {"fields": {"CS": "nan"}}})])
    j = json.loads((tmp / "y3" / "out" / "field-compare.json").read_text())
    check("compare: 双端'nan'+abs → BLOCKED（不冒用 FAIL(1)）",
          r.returncode == 2 and j["status"] == "BLOCKED" and j["stats"]["diff"] == 0,
          f"exit={r.returncode} status={j['status']} diff={j['stats']['diff']}")

    # Y4. 单侧 "Infinity" 一侧 5 + abs → BLOCKED（此前 abs(nan-5) 恒 False 冒用 FAIL(1)）
    r = cmp_run(tmp / "y4", fc_rules(fms=FM_ABX),
                [cap(steps={"s1": {"fields": {"CS": "Infinity"}}})],
                [cap(steps={"s1": {"fields": {"CS": 5}}})])
    j = json.loads((tmp / "y4" / "out" / "field-compare.json").read_text())
    check("compare: 单侧'Infinity'一侧 5 → BLOCKED（畸形证据不冒用 FAIL）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # Y5. 误伤方向：合法有限大数（1e308/全角数字/number_2dp 对称 round）照常 MATCH
    ok_hits = 0
    for tag9, lv9, cv9, nrm in (("big", "1e308", "1e308", "number"),
                                ("zen", "１２３", "123", "number"),
                                ("2dp", "2.675", "2.675", "number_2dp")):
        fm9 = [dict(FM_OK8[0], normalize=nrm)]
        r = cmp_run(tmp / f"y5-{tag9}", fc_rules(fms=fm9),
                    [cap(steps={"s1": {"fields": {"CS": lv9}}})],
                    [cap(steps={"s1": {"fields": {"CS": cv9}}})])
        ok_hits += int(r.returncode == 0)
    check("compare: 合法有限数值形态 3 种照常 MATCH（无误伤）", ok_hits == 3, f"hits={ok_hits}/3")

    # ---------- 第十二轮回归（2026-09-06 第十轮独立审计·零发现判定轮） ----------
    # 主题：原生非有限浮点族（第九轮封字符串经 float() 解析路径，原生 float 漏网）——
    #        json.loads 默认接受非标准 JSON 字面量 Infinity/NaN（RFC 8259 不允许），
    #        exact/trim 路径不经 norm_number：双端 inf==inf 记假 MATCH（可推假 PASS）、
    #        nan 恒不等冒用 FAIL(1)；rules 侧（YAML .inf 经 json.dumps 写出 Infinity）同理
    INF = float("inf")
    NAN = float("nan")
    FM_EXACT_CS = [{"legacy_field": "CS", "target_field": "CS", "tolerance": "exact",
                    "null_policy": "both_null_equal"}]

    # Z1. 双端裸 Infinity 字面量 + exact → BLOCKED（此前 inf==inf 假 MATCH → exit 0 可推假 PASS）
    r = cmp_run(tmp / "z1", fc_rules(fms=FM_EXACT_CS),
                [cap(steps={"s1": {"fields": {"CS": INF}}})],
                [cap(steps={"s1": {"fields": {"CS": INF}}})])
    j = json.loads((tmp / "z1" / "out" / "field-compare.json").read_text())
    check("compare: 双端裸 Infinity 字面量+exact → BLOCKED（不记 inf==inf 假 MATCH）",
          r.returncode == 2 and j["status"] == "BLOCKED" and j["stats"]["match"] == 0,
          f"exit={r.returncode} status={j['status']} match={j['stats']['match']}")

    # Z2. 双端裸 NaN 字面量 + exact → BLOCKED（此前 nan==nan 恒 False 冒用 FAIL(1)）
    r = cmp_run(tmp / "z2", fc_rules(fms=FM_EXACT_CS),
                [cap(steps={"s1": {"fields": {"CS": NAN}}})],
                [cap(steps={"s1": {"fields": {"CS": NAN}}})])
    j = json.loads((tmp / "z2" / "out" / "field-compare.json").read_text())
    check("compare: 双端裸 NaN 字面量+exact → BLOCKED（不冒用 FAIL(1)）",
          r.returncode == 2 and j["status"] == "BLOCKED" and j["stats"]["diff"] == 0,
          f"exit={r.returncode} status={j['status']} diff={j['stats']['diff']}")

    # Z3. 单侧裸 Infinity 一侧 5 + exact → BLOCKED（畸形证据不冒用 FAIL）
    r = cmp_run(tmp / "z3", fc_rules(fms=FM_EXACT_CS),
                [cap(steps={"s1": {"fields": {"CS": float("-inf")}}})],
                [cap(steps={"s1": {"fields": {"CS": 5}}})])
    j = json.loads((tmp / "z3" / "out" / "field-compare.json").read_text())
    check("compare: 单侧裸 -Infinity 一侧 5 → BLOCKED（不冒用 FAIL）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # Z4. formulas 双端裸 Infinity + exact → BLOCKED（采集侧解析期拒）
    rules_z4 = fc_rules(fms=FM)
    rules_z4["formulas"] = [{"id": "A.1", "expr": "e", "expected_legacy": 978.26, "tolerance": "exact"}]
    r = cmp_run(tmp / "z4", rules_z4,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"formulas": {"A.1": INF}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"formulas": {"A.1": INF}})])
    j = json.loads((tmp / "z4" / "out" / "field-compare.json").read_text())
    check("compare: 公式值双端裸 Infinity → BLOCKED（不记假 MATCH）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # Z5. rules expected_legacy 裸 Infinity + 采集正常 → BLOCKED（rules 侧解析期拒）
    rules_z5 = fc_rules(fms=FM)
    rules_z5["formulas"] = [{"id": "A.1", "expr": "e", "expected_legacy": INF, "tolerance": "exact"}]
    r = cmp_run(tmp / "z5", rules_z5,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "V"}}}, extra={"formulas": {"A.1": 978.26}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "V"}}}, extra={"formulas": {"A.1": 978.26}})])
    j = json.loads((tmp / "z5" / "out" / "field-compare.json").read_text())
    check("compare: rules 裸 Infinity（expected_legacy）→ BLOCKED（rules 损坏）",
          r.returncode == 2 and j["status"] == "BLOCKED", f"exit={r.returncode} status={j['status']}")

    # Z6. validate: 契约 .inf/.nan（YAML 原生浮点）→ 立契期拒绝（防 gen 写出非标准 JSON）
    nf = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    nf["formulas"][0]["expected_legacy"] = INF
    cpz = tmp / "z6.yaml"; cpz.write_text(_y.safe_dump(nf, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(cpz), "--level", "test_ready"])
    check("validate: 契约 .inf → 拒绝（立契期拦截）",
          r.returncode == 2 and "非有限数值" in r.stderr, f"exit={r.returncode}")

    # Z7. gen: 契约 .inf（--allow-draft 也拒）→ 零写入拒绝
    r = run([sys.executable, str(HERE / "gen_from_contract.py"), "--contract", str(cpz),
             "--outdir", str(tmp / "z7-out"), "--allow-draft"])
    check("gen: 契约 .inf --allow-draft → 拒绝（零写入）",
          r.returncode != 0 and not (tmp / "z7-out").exists(), f"exit={r.returncode}")

    # Z8. 误伤方向：契约合法有限 float（978.26 等）→ validate 照常通过（walk_nonfinite 无假阳）
    r = run([sys.executable, str(HERE / "validate-contract.py"),
             "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"), "--level", "test_ready"])
    check("validate: 实例契约（合法有限数值）照常通过（无误伤）", r.returncode == 0, f"exit={r.returncode}")

    # ---------- 第十三轮回归（2026-09-07 第十一轮独立审计·P0 修复轮） ----------    # 主题：①--force 重写面（账本/结论可强制覆盖=不可篡改名存实亡）②runner 采集冒领面
    #       （退出码 0+文件存在即 PASS——无清理/时间窗/身份校验）③gate 自由文本证据放行面
    # AA1. manifest: --force 已移除——传参即被 argparse 拒绝
    r = run([sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", "aa1",
             "--reports-dir", str(tmp / "mf-aa1"), "--project-root", str(tmp),
             "--allow-unrecorded-versions", "--force"])
    check("manifest: --force 已移除（传参被拒 exit 2）",
          r.returncode == 2 and "unrecognized arguments" in r.stderr, f"exit={r.returncode}")
    # AA2. manifest: 账本写入后任何形式重写均不可行（同 run-id 二写 exit 3；兼容回归已有 r1/r2，此处验 --force 不存在的完整链）
    dm_aa2 = tmp / "mf-aa2"; dm_aa2.mkdir()
    common_aa2 = [sys.executable, str(SCRIPTS / "write-manifest.py"), "--run-id", "aa2",
                  "--reports-dir", str(dm_aa2), "--project-root", str(tmp), "--allow-unrecorded-versions"]
    run(common_aa2)
    r = run(common_aa2)
    check("manifest: 同 run-id 重写被拒(3)（账本永不覆盖）", r.returncode == 3, f"exit={r.returncode}")
    # AA3. conclude: --force 已移除——传参即被 argparse 拒绝
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(tmp / "nonexistent-aa3"), "--force"])
    check("conclude: --force 已移除（传参被拒 exit 2）",
          r.returncode == 2 and "unrecognized arguments" in r.stderr, f"exit={r.returncode}")
    # AA4. conclude: run-manifest 缺失 → BLOCKED 且【不产出 summary.json】（无账本不得有结论件）
    da4 = tmp / "aa4"; da4.mkdir()
    w(da4 / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(da4 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": []})
    w(da4 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(da4)])
    check("conclude: 账本缺失 → BLOCKED(2) 且不产出 summary（无账本不得有结论件）",
          r.returncode == 2 and not (da4 / "summary.json").exists() and "无完整可信账本" in r.stderr,
          f"exit={r.returncode} summary_exists={(da4 / 'summary.json').exists()}")
    # AA5. conclude: 账本损坏（坏 JSON）→ BLOCKED 且不产出 summary
    da5 = tmp / "aa5"; da5.mkdir()
    w(da5 / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(da5 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": []})
    w(da5 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    (da5 / "run-manifest.json").write_text('{"run_id": "aa5"', encoding="utf-8")  # 半截 JSON
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(da5)])
    check("conclude: 账本损坏 → BLOCKED(2) 且不产出 summary",
          r.returncode == 2 and not (da5 / "summary.json").exists(), f"exit={r.returncode}")
    # AA6. conclude: run_id 与目录错配 → BLOCKED 且不产出 summary（结论件必须绑定本目录账本）
    da6 = tmp / "aa6"; da6.mkdir()
    w(da6 / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(da6 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": []})
    w(da6 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    w(da6 / "run-manifest.json", {"run_id": "other-run", "config_snapshot": {}})
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(da6)])
    check("conclude: run_id 错配 → BLOCKED(2) 且不产出 summary",
          r.returncode == 2 and not (da6 / "summary.json").exists(), f"exit={r.returncode}")
    # AA7. conclude: versions 全 unrecorded（其余全过）→ BLOCKED（正式 PASS 须绑定真实版本）
    r = concl("aa7", versions={"source": "unrecorded", "target": "unrecorded", "flow": "unrecorded"})
    check("conclude: versions unrecorded → BLOCKED（PASS 须绑定版本）",
          r.returncode == 2 and "版本未记录" in reasons_of(tmp / "aa7"), f"exit={r.returncode}")
    # AA8. 兼容方向：versions 已记录（v1/v2/f1）→ 照常 PASS（不误伤）
    r = concl("aa8", versions={"source": "v9", "target": "v10", "flow": "f2"})
    check("conclude: versions 已记录 → PASS（兼容）", r.returncode == 0, f"exit={r.returncode}")
    # AA9. runner: 预置"合格"采集文件被清理——假 CLI 退出 0 + 预置遗留采集 → BLOCKED（冒领面封死）
    fake_aa9 = tmp / "fake-cli-aa9"; fake_aa9.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8"); fake_aa9.chmod(0o755)
    sd_aa9 = tmp / "scen-aa9"; sd_aa9.mkdir()
    (sd_aa9 / "s1.yaml").write_text(_y.safe_dump({"id": "x-c-01", "case_id": "C-01", "required": True}), encoding="utf-8")
    exd_aa9 = tmp / "exec-aa9"
    w(exd_aa9 / "field-captures" / "legacy" / "C-01.json", {"run_id": "aa9", "case_id": "C-01", "steps": {}})
    w(exd_aa9 / "field-captures" / "current" / "C-01.json", {"run_id": "aa9", "case_id": "C-01", "steps": {}})
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_aa9),
             "--exec-dir", str(exd_aa9), "--run-id", "aa9"],
            env={**__import__("os").environ, "FLOWTEST_RUNNER": "cli", "FLOWTEST_CLI": str(fake_aa9)})
    j = json.loads((exd_aa9 / "case-results.json").read_text())
    caps_gone = not (exd_aa9 / "field-captures").exists()
    check("runner: 预置遗留采集被执行前清理 → BLOCKED（不冒领）",
          r.returncode == 2 and j[0]["status"] == "BLOCKED" and caps_gone,
          f"exit={r.returncode} status={j[0]['status']} caps_gone={caps_gone}")
    # AA10. runner: 采集缺 run_id/case_id 身份标识 → BLOCKED（来源不明的采集不采信）
    # fake CLI 直接写采集（无身份字段），经 FT_EXEC_DIR 环境变量定位 exec-dir（测试专用）
    fake_aa10 = tmp / "fake-cli-aa10.py"
    fake_aa10.write_text(
        "#!/usr/bin/env python3\n"
        "import json, sys, pathlib\n"
        "args = sys.argv[1:]\n"
        "rid = args[args.index('--run-id') + 1]\n"
        "base = pathlib.Path(args[args.index('--exec-dir') + 1]) / 'field-captures' if '--exec-dir' in args else None\n"
        "# exec-dir 不在 CLI 参数里——用环境变量兜底（测试专用）\n"
        "import os\n"
        "base = pathlib.Path(os.environ['FT_EXEC_DIR']) / 'field-captures'\n"
        "for side in ('legacy', 'current'):\n"
        "    p = base / side / 'C-01.json'\n"
        "    p.parent.mkdir(parents=True, exist_ok=True)\n"
        "    p.write_text(json.dumps({'steps': {}}))  # 无 run_id/case_id\n"
        "sys.exit(0)\n", encoding="utf-8")
    fake_aa10.chmod(0o755)
    sd_aa10 = tmp / "scen-aa10"; sd_aa10.mkdir()
    (sd_aa10 / "s1.yaml").write_text(_y.safe_dump({"id": "x-c-01", "case_id": "C-01", "required": True}), encoding="utf-8")
    exd_aa10 = tmp / "exec-aa10"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_aa10),
             "--exec-dir", str(exd_aa10), "--run-id", "aa10"],
            env={**__import__("os").environ, "FLOWTEST_RUNNER": "cli", "FLOWTEST_CLI": str(fake_aa10), "FT_EXEC_DIR": str(exd_aa10)})
    j = json.loads((exd_aa10 / "case-results.json").read_text())
    check("runner: 采集缺 run_id/case_id 身份 → BLOCKED（不采信来源不明采集）",
          r.returncode == 2 and j[0]["status"] == "BLOCKED", f"exit={r.returncode} status={j[0]['status']}")
    # AA11. runner: 采集 run_id 错配（他 run 的采集）→ BLOCKED
    fake_aa11 = tmp / "fake-cli-aa11.py"
    fake_aa11.write_text(
        "#!/usr/bin/env python3\n"
        "import json, sys, os, pathlib\n"
        "base = pathlib.Path(os.environ['FT_EXEC_DIR']) / 'field-captures'\n"
        "for side in ('legacy', 'current'):\n"
        "    p = base / side / 'C-01.json'\n"
        "    p.parent.mkdir(parents=True, exist_ok=True)\n"
        "    p.write_text(json.dumps({'run_id': 'some-other-run', 'case_id': 'C-01', 'steps': {}}))\n"
        "sys.exit(0)\n", encoding="utf-8")
    fake_aa11.chmod(0o755)
    exd_aa11 = tmp / "exec-aa11"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_aa10),
             "--exec-dir", str(exd_aa11), "--run-id", "aa11"],
            env={**__import__("os").environ, "FLOWTEST_RUNNER": "cli", "FLOWTEST_CLI": str(fake_aa11), "FT_EXEC_DIR": str(exd_aa11)})
    j = json.loads((exd_aa11 / "case-results.json").read_text())
    check("runner: 采集 run_id 错配 → BLOCKED", r.returncode == 2 and j[0]["status"] == "BLOCKED",
          f"exit={r.returncode} status={j[0]['status']}")
    # AA12. 兼容方向：合规采集（run_id/case_id 双端正确、新鲜产出）→ PASS（不误伤真实 CLI 接线）
    fake_aa12 = tmp / "fake-cli-aa12.py"
    fake_aa12.write_text(
        "#!/usr/bin/env python3\n"
        "import json, sys, os, pathlib\n"
        "args = sys.argv[1:]\n"
        "rid = args[args.index('--run-id') + 1]\n"
        "base = pathlib.Path(os.environ['FT_EXEC_DIR']) / 'field-captures'\n"
        "for side in ('legacy', 'current'):\n"
        "    p = base / side / 'C-01.json'\n"
        "    p.parent.mkdir(parents=True, exist_ok=True)\n"
        "    p.write_text(json.dumps({'run_id': rid, 'case_id': 'C-01', 'steps': {}}))\n"
        "sys.exit(0)\n", encoding="utf-8")
    fake_aa12.chmod(0o755)
    exd_aa12 = tmp / "exec-aa12"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_aa10),
             "--exec-dir", str(exd_aa12), "--run-id", "aa12"],
            env={**__import__("os").environ, "FLOWTEST_RUNNER": "cli", "FLOWTEST_CLI": str(fake_aa12), "FT_EXEC_DIR": str(exd_aa12)})
    j = json.loads((exd_aa12 / "case-results.json").read_text())
    check("runner: 合规采集（身份正确+新鲜）→ PASS（兼容真实 CLI）", r.returncode == 0 and j[0]["status"] == "PASS",
          f"exit={r.returncode} status={j[0]['status']}")
    # AA13-AA17（第十三轮·证据须能证明 gate）：gate-evidence-check v2 按契约 gates[].evidence_schema
    # 校验——kind=report 文件过 required_fields 断言 + flow_field 绑定；kind=http 命中白名单+200
    def _gec_run(out_p: Path, contract_p: Path, ev_p: Path, env=None):
        """gate-evidence-check 便捷调用：健康结果文件用空列表（本组不测健康）。"""
        hr = tmp / "aa-empty-health.json"
        hr.write_text("[]", encoding="utf-8")
        return run([sys.executable, str(SCRIPTS / "gate-evidence-check.py"), str(out_p), str(hr),
                    str(contract_p), str(ev_p), str(tmp)], env=env or {})

    gct = tmp / "aa13-contract.yaml"
    gct.write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001"},
        "gates": [{"id": "GATE-CANVAS", "check": "画布渲染正常", "severity": "P0",
                   "evidence_schema": {"kind": "report", "file_format": "json",
                                       "flow_field": "data.flow_code",
                                       "required_fields": [{"path": "data.canvas_render_ok", "op": "eq", "value": True}]}}]}),
        encoding="utf-8")
    good_report = tmp / "canvas-report.json"
    good_report.write_text(json.dumps({"data": {"flow_code": "WFA_X_0001", "canvas_render_ok": True}}), encoding="utf-8")
    real_hash = _h.sha256(good_report.read_bytes()).hexdigest()[:16]
    gk = tmp / "aa13-gates.json"
    gev = tmp / "aa13-evidence.json"
    # AA13. 任意文件（非 schema 报告）不能过——缺 required_fields 内容/哈希对应的不是报告
    w(gev, [{"id": "GATE-CANVAS", "type": "file", "path": "aa13-arbitrary.png",
             "sha256_16": _h.sha256(b"whatever-bytes").hexdigest()[:16],
             "generated_at": "2026-09-07T10:00:00+08:00", "target_env": "v2"}])
    (tmp / "aa13-arbitrary.png").write_text("whatever-bytes", encoding="utf-8")
    r = _gec_run(gk, gct, gev)
    items = json.loads(gk.read_text())
    check("gate-evidence: 任意文件（非 schema 报告内容）→ passed=false（证明不了画布 gate）",
          r.returncode == 0 and items[0]["passed"] is False, f"exit={r.returncode} note={items[0].get('note','')[:90]}")
    # AA13b. gate 未声明 evidence_schema → passed=false（立契期也拒）
    gct_noschema = tmp / "aa13b-contract.yaml"
    gct_noschema.write_text(_y.safe_dump({"gates": [{"id": "GATE-X", "check": "c", "severity": "P1"}]}), encoding="utf-8")
    gk13b = tmp / "aa13b-gates.json"
    r = _gec_run(gk13b, gct_noschema, gev)
    items = json.loads(gk13b.read_text())
    check("gate-evidence: gate 无 evidence_schema → passed=false（fail-closed）",
          r.returncode == 0 and items[0]["passed"] is False, f"exit={r.returncode}")
    # AA14. 报告内容断言失败（canvas_render_ok=false）→ passed=false（哈希对也没用）
    bad_report = tmp / "aa14-report.json"
    bad_report.write_text(json.dumps({"data": {"flow_code": "WFA_X_0001", "canvas_render_ok": False}}), encoding="utf-8")
    w(tmp / "aa14-evidence.json", [{"id": "GATE-CANVAS", "type": "file", "path": "aa14-report.json",
                                    "sha256_16": _h.sha256(bad_report.read_bytes()).hexdigest()[:16],
                                    "generated_at": "2026-09-07T10:00:00+08:00", "target_env": "v2"}])
    gk2 = tmp / "aa14-gates.json"
    r = _gec_run(gk2, gct, tmp / "aa14-evidence.json")
    items = json.loads(gk2.read_text())
    check("gate-evidence: 报告断言失败（canvas_render_ok=false）→ passed=false",
          r.returncode == 0 and items[0]["passed"] is False, f"exit={r.returncode} note={items[0].get('note','')[:90]}")
    # AA15. flow 绑定不符（报告属于别的流程）→ passed=false
    other_report = tmp / "aa15-report.json"
    other_report.write_text(json.dumps({"data": {"flow_code": "WFA_OTHER", "canvas_render_ok": True}}), encoding="utf-8")
    w(tmp / "aa15-evidence.json", [{"id": "GATE-CANVAS", "type": "file", "path": "aa15-report.json",
                                    "sha256_16": _h.sha256(other_report.read_bytes()).hexdigest()[:16],
                                    "generated_at": "2026-09-07T10:00:00+08:00", "target_env": "v2"}])
    gk3 = tmp / "aa15-gates.json"
    r = _gec_run(gk3, gct, tmp / "aa15-evidence.json")
    items = json.loads(gk3.read_text())
    check("gate-evidence: 报告 flow 绑定不符 → passed=false（证据不属于本流程）",
          r.returncode == 0 and items[0]["passed"] is False, f"exit={r.returncode} note={items[0].get('note','')[:90]}")
    # AA16. 时效/env 仍校验：过期、未来、env 错配 → passed=false
    for tag16, ga16 in (("stale", "2020-01-01T00:00:00+08:00"), ("future", "2099-01-01T00:00:00+08:00")):
        w(tmp / f"aa16-{tag16}-ev.json", [{"id": "GATE-CANVAS", "type": "file", "path": "canvas-report.json",
                                           "sha256_16": real_hash, "generated_at": ga16, "target_env": "v2"}])
        gk16 = tmp / f"aa16-{tag16}-gates.json"
        _gec_run(gk16, gct, tmp / f"aa16-{tag16}-ev.json", env={"TARGET_VERSION": "v2"})
    w(tmp / "aa16-env-ev.json", [{"id": "GATE-CANVAS", "type": "file", "path": "canvas-report.json",
                                  "sha256_16": real_hash, "generated_at": "2026-09-07T10:00:00+08:00",
                                  "target_env": "wrong-env"}])
    gk_env = tmp / "aa16-env-gates.json"
    _gec_run(gk_env, gct, tmp / "aa16-env-ev.json", env={"TARGET_VERSION": "v2"})
    items_s = json.loads((tmp / "aa16-stale-gates.json").read_text())
    items_f = json.loads((tmp / "aa16-future-gates.json").read_text())
    items_e = json.loads(gk_env.read_text())
    check("gate-evidence: 证据过期/未来/env 错配 → passed=false（时效与环境仍强制）",
          items_s[0]["passed"] is False and items_f[0]["passed"] is False and items_e[0]["passed"] is False,
          f"stale={items_s[0]['passed']} future={items_f[0]['passed']} env={items_e[0]['passed']}")
    # AA17. 兼容方向：合规报告（断言全过+flow 绑定+时效+env）→ passed=true
    # generated_at 必须运行时现生成——硬编码日期会在超过 24h 时效窗后变成"定时炸弹"用例
    # （2026-09-08 实锤：写死 2026-09-07T10:00 的合规证据次日过期 → 正向用例假失败）
    _now_iso = __import__("datetime").datetime.now().astimezone().isoformat(timespec="seconds")
    w(tmp / "aa17-ev.json", [{"id": "GATE-CANVAS", "type": "file", "path": "canvas-report.json",
                              "sha256_16": real_hash, "generated_at": _now_iso,
                              "target_env": "v2"}])
    gk7 = tmp / "aa17-gates.json"
    _gec_run(gk7, gct, tmp / "aa17-ev.json", env={"TARGET_VERSION": "v2"})
    items = json.loads(gk7.read_text())
    check("gate-evidence: 合规报告（schema 断言+flow 绑定+时效）→ passed=true（不误伤）",
          items[0]["passed"] is True, f"note={items[0].get('note', '')[:100]}")
    # AA17b. http kind：白名单外 URL（即使可探活也不采信）+ 未声明 allowed_urls 的 http → false
    gct_http = tmp / "aa17b-contract.yaml"
    gct_http.write_text(_y.safe_dump({
        "gates": [{"id": "GATE-DEPLOY", "check": "部署可见", "severity": "P1",
                   "evidence_schema": {"kind": "http", "allowed_urls": ["http://127.0.0.1:9/ops/"]}}]}),
        encoding="utf-8")
    w(tmp / "aa17b-ev.json", [{"id": "GATE-DEPLOY", "type": "url",
                               "url": "http://127.0.0.1:1/other",   # 白名单外 + 探活失败
                               "generated_at": "2026-09-07T10:00:00+08:00", "target_env": "v2"}])
    gk_http = tmp / "aa17b-gates.json"
    r = _gec_run(gk_http, gct_http, tmp / "aa17b-ev.json")
    items = json.loads(gk_http.read_text())
    check("gate-evidence: http url 不在白名单 → passed=false（任意 URL 不能证明 gate）",
          r.returncode == 0 and items[0]["passed"] is False, f"exit={r.returncode} note={items[0].get('note','')[:90]}")
    # AA17c. type 与 schema.kind 不符（report schema 给了 url 证据）→ passed=false
    w(tmp / "aa17c-ev.json", [{"id": "GATE-CANVAS", "type": "url",
                               "url": "http://127.0.0.1:9/x", "generated_at": "2026-09-07T10:00:00+08:00",
                               "target_env": "v2"}])
    gk17c = tmp / "aa17c-gates.json"
    r = _gec_run(gk17c, gct, tmp / "aa17c-ev.json")
    items = json.loads(gk17c.read_text())
    check("gate-evidence: 证据 type 与 schema.kind 不符 → passed=false",
          r.returncode == 0 and items[0]["passed"] is False, f"exit={r.returncode}")
    # AA18. pipeline: run-id 已存在（report 目录非空）→ 拒绝(2)（run-id 不可复用）
    if LAYOUT == "skill":
        # skill 布局：运行态在 $SKILL/runtime/<项目键>/——用 FLOWTEST_RUNTIME_DIR 指向沙箱验证同一逻辑
        sb18 = tmp / "aa18-sandbox"
        (sb18 / "reports" / "run-skill-exists").mkdir(parents=True)
        r = run(["bash", str(SCRIPTS / "pipeline.sh"), "--run-id", "run-skill-exists", "--dry-run"],
                env={**__import__("os").environ, "FLOWTEST_PROJECT_ROOT": str(sb18),
                     "FLOWTEST_RUNTIME_DIR": str(sb18)})
        check("pipeline: run-id 已存在 → 拒绝(2)（skill 布局·沙箱）", r.returncode == 2, f"exit={r.returncode}")
    else:
        _rt_reports = HERE.parent / "runtime" / "reports"
        existing = sorted(p2.name for p2 in _rt_reports.glob("run-*")) if _rt_reports.exists() else []
        if existing:
            r = run(["bash", str(SCRIPTS / "pipeline.sh"), "--run-id", existing[0], "--dry-run"])
            check("pipeline: run-id 已存在 → 拒绝(2)（run-id 不可复用）", r.returncode == 2, f"exit={r.returncode}")
        else:
            check("pipeline: run-id 已存在 → 拒绝(2)（无历史 run 目录，跳过）", True)

    # ---------- 第十四/十五轮回归（api 通道自持 + 第十三轮实例隔离/证据 schema/契约健康） ----------
    # mock 双端系统：每侧一个内存状态机 HTTP 服务（login/todo/launch/form/submit + /health），
    # 证明 api 通道全链零 FlowTrace 依赖；并验证 launch-first 实例隔离（decoy 不碰）
    import threading as _th
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class _MockState:
        """默认：预置一个他流程 decoy 任务（同 node 00 同办理人，验证 launch-first 不碰）；
        launch 才产生本流程实例（INST-L<n> 首节点 00）。"""
        def __init__(self, with_decoy=True):
            self.seq = 0
            self.tasks = {}
            if with_decoy:  # 他流程（WFA_OTHER）同 node 00、同 admin 的诱饵——若被采=误操作
                self.tasks["t-decoy"] = {"assignee": "mock-admin", "taskId": "t-decoy",
                                         "node": "00", "instanceNo": "INST-DECOY", "flowCode": "WFA_OTHER"}
        def launch(self, launcher):
            self.seq += 1
            inst = f"INST-L{self.seq}"
            self.tasks[f"t-{inst}"] = {"assignee": launcher, "taskId": f"t-{inst}", "node": "00",
                                       "instanceNo": inst, "flowCode": "WFA_X_0001"}
            return inst, f"t-{inst}"
        def todo(self, user):
            return [dict(v, stepCode=v["node"], flowInstanceNo=v["instanceNo"], flowCode=v.get("flowCode", "WFA_X_0001"))
                    for v in self.tasks.values() if v["assignee"] == user]
        def advance(self, tid):
            for k, t in list(self.tasks.items()):
                if t["taskId"] != tid:
                    continue
                del self.tasks[k]
                if t["node"] == "00":
                    self.tasks[f"t-{t['instanceNo']}-01"] = {"assignee": "mock-admin2", "taskId": f"t-{t['instanceNo']}-01",
                                                             "node": "01", "instanceNo": t["instanceNo"], "flowCode": t.get("flowCode", "WFA_X_0001")}
                return True
            return False

    def _mock_yaml(port: int, side: str, base_path: str, flow_code: str = "WFA_X_0001") -> str:
        return _y.safe_dump({
            "id": side, "channel": "api",
            "api": {
                "baseUrl": f"http://127.0.0.1:{port}", "taskWaitSeconds": 3,
                "login": {"method": "POST", "path": f"{base_path}/login",
                          "body": {"username": "${USERNAME}", "password": "${PASSWORD}"},
                          "tokenPath": "data.token", "tokenHeader": "Authorization", "tokenScheme": "Bearer "},
                "todo": {"method": "GET", "path": f"{base_path}/todo", "params": {"page": 0, "size": 20},
                         "listPath": "data.list", "taskIdPath": "taskId", "nodePath": "stepCode",
                         "instancePath": "flowInstanceNo", "flowCodePath": "flowCode"},
                "launch": {"method": "POST", "path": f"{base_path}/launch",
                           "body": {"processElementId": "${ELEMENT_ID}"},
                           "instancePath": "data.flowInstanceNo", "taskIdPath": "data.firstTaskId",
                           "elementIdEnv": f"MOCK_LAUNCH_ELEMENT_ID_{flow_code}"},
                "form": {"method": "GET", "path": f"{base_path}/task/${{TASK_ID}}/form", "fieldsPath": "data.formData"},
                "submit": {"method": "POST", "path": f"{base_path}/task/${{TASK_ID}}/execute-button",
                           "defaultButton": "提交",
                           "body": {"buttonCode": "${BUTTON}", "nextAssigneeId": "${NEXT_ASSIGNEE}"},
                           "successStatus": [200]},
            },
            "actorMap": {"admin": {"username": "MOCK_ADMIN_USER", "password": "MOCK_ADMIN_PWD"},
                         "admin2": {"username": "MOCK_ADMIN2_USER", "password": "MOCK_ADMIN2_PWD"}},
        }, allow_unicode=True)

    def _start_mock(port: int, base_path: str, form_value, with_decoy: bool = True) -> tuple[ThreadingHTTPServer, _MockState]:
        state = _MockState(with_decoy=with_decoy)   # 每侧独立状态
        class H(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def _json(self, obj, code=200):
                b = json.dumps(obj).encode()
                self.send_response(code); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
            def do_POST(self):
                ln = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(ln) or b"{}")
                if self.path == f"{base_path}/login":
                    if body.get("password") == "right-pwd":
                        self._json({"data": {"token": "tok-" + body.get("username", "")}})
                    else:
                        self._json({"message": "bad credentials"}, 401)
                    return
                if self.path == f"{base_path}/launch":
                    launcher = (self.headers.get("Authorization") or "").replace("Bearer ", "").removeprefix("tok-")
                    inst, tid = state.launch(launcher)
                    self._json({"data": {"flowInstanceNo": inst, "firstTaskId": tid}}); return
                if self.path.startswith(f"{base_path}/task/") and self.path.endswith("/execute-button"):
                    tid = self.path.split("/task/")[1].split("/")[0]
                    if state.advance(tid):
                        self._json({"ok": True}); return
                    self._json({"message": "no task"}, 404); return
                self._json({"message": "not found"}, 404)
            def do_GET(self):
                if self.path.endswith("/health"):
                    self._json({"status": "UP"}); return
                if self.path.startswith(f"{base_path}/todo"):
                    user = (self.headers.get("Authorization") or "").replace("Bearer ", "").removeprefix("tok-")
                    self._json({"data": {"list": state.todo(user)}}); return
                if self.path.startswith(f"{base_path}/task/") and self.path.endswith("/form"):
                    self._json({"data": {"formData": {"CS": form_value}}}); return
                self._json({"message": "not found"}, 404)
        srv = ThreadingHTTPServer(("127.0.0.1", port), H)
        _th.Thread(target=srv.serve_forever, daemon=True).start()
        return srv, state

    def _free_port() -> int:
        import socket as _sk
        s = _sk.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

    pL, pC = _free_port(), _free_port()
    srvL, stL = _start_mock(pL, "/leg", "V")
    srvC, stC = _start_mock(pC, "/cur", "V")
    sysd = tmp / "systems-api"; sysd.mkdir()
    (sysd / "legacy.yaml").write_text(_mock_yaml(pL, "legacy", "/leg"), encoding="utf-8")
    (sysd / "current.yaml").write_text(_mock_yaml(pC, "current", "/cur"), encoding="utf-8")
    sd_api = tmp / "scen-api"; sd_api.mkdir()
    (sd_api / "s1.yaml").write_text(_y.safe_dump({
        "id": "WFA_X_0001-c-01", "case_id": "C-01", "required": True,
        "steps": [{"seq": 1, "node": "00", "actorAccount": "admin"},
                  {"seq": 2, "node": "01", "actorAccount": "admin2"}]}), encoding="utf-8")
    env_api = {**__import__("os").environ, "FLOWTEST_RUNNER": "api",
               "MOCK_ADMIN_USER": "mock-admin", "MOCK_ADMIN_PWD": "right-pwd",
               "MOCK_ADMIN2_USER": "mock-admin2", "MOCK_ADMIN2_PWD": "right-pwd",
               "LAUNCH_ELEMENT_ID_WFA_X_0001": "42"}

    # BB1. api 通道全链（launch-first）：mock 双端（各带他流程 decoy）→ PASS；decoy 未被触碰；
    #      capture 实例号 == 本次 launch 的实例（隔离）
    exd_b1 = tmp / "exec-api-b1"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_api),
             "--exec-dir", str(exd_b1), "--run-id", "bb1", "--systems-dir", str(sysd)], env=env_api)
    j = json.loads((exd_b1 / "case-results.json").read_text())
    capL = json.loads((exd_b1 / "field-captures" / "legacy" / "C-01.json").read_text())
    capC = json.loads((exd_b1 / "field-captures" / "current" / "C-01.json").read_text())
    decoy_untouched = stL.tasks.get("t-decoy") is not None and stC.tasks.get("t-decoy") is not None
    check("runner(api): launch-first 全链 → PASS；他流程 decoy 未被采/提交（实例隔离）",
          r.returncode == 0 and j[0]["status"] == "PASS"
          and capL["run_id"] == "bb1" and capL["case_id"] == "C-01" and capL["flow_code"] == "WFA_X_0001"
          and capL["instance_no"] == "INST-L1" and capL["instance_no"] != "INST-DECOY"
          and capC["run_id"] == "bb1" and decoy_untouched
          and capL["steps"]["s1"]["fields"]["CS"] == "V" == capC["steps"]["s1"]["fields"]["CS"],
          f"exit={r.returncode} status={j[0]['status']} decoyL={stL.tasks.get('t-decoy') is not None}")

    # BB1b. 负向：无 launch 元素 ID env → BLOCKED（不猜测流程要素）
    exd_b1b = tmp / "exec-api-b1b"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_api),
             "--exec-dir", str(exd_b1b), "--run-id", "bb1b", "--systems-dir", str(sysd)],
            env={k: v for k, v in env_api.items() if k != "LAUNCH_ELEMENT_ID_WFA_X_0001"})
    j = json.loads((exd_b1b / "case-results.json").read_text())
    check("runner(api): 缺 launch 元素 ID env → BLOCKED（launch-first 必填）",
          r.returncode == 2 and j[0]["status"] == "BLOCKED", f"exit={r.returncode} status={j[0]['status']}")

    # BB2. api 通道负向：服务不可达 → BLOCKED（诚实阻断，不伪造采集）
    bad_sysd = tmp / "systems-api-dead"; bad_sysd.mkdir()
    dead = _y.safe_load(_mock_yaml(1, "legacy", "/leg"))
    dead["api"]["baseUrl"] = "http://127.0.0.1:1"
    (bad_sysd / "legacy.yaml").write_text(_y.safe_dump(dead, allow_unicode=True), encoding="utf-8")
    (bad_sysd / "current.yaml").write_text(_mock_yaml(pC, "current", "/cur"), encoding="utf-8")
    exd_b2 = tmp / "exec-api-b2"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_api),
             "--exec-dir", str(exd_b2), "--run-id", "bb2", "--systems-dir", str(bad_sysd)], env=env_api)
    j = json.loads((exd_b2 / "case-results.json").read_text())
    check("runner(api): 服务不可达 → BLOCKED", r.returncode == 2 and j[0]["status"] == "BLOCKED",
          f"exit={r.returncode} status={j[0]['status']}")

    # BB3. api 通道负向：凭据环境变量缺失 → BLOCKED（凭据零明文，缺 env 即拒）
    exd_b3 = tmp / "exec-api-b3"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_api),
             "--exec-dir", str(exd_b3), "--run-id", "bb3", "--systems-dir", str(sysd)],
            env={k: v for k, v in env_api.items() if k != "MOCK_ADMIN_PWD"})
    j = json.loads((exd_b3 / "case-results.json").read_text())
    check("runner(api): 凭据 env 缺失 → BLOCKED", r.returncode == 2 and j[0]["status"] == "BLOCKED",
          f"exit={r.returncode} status={j[0]['status']}")

    # BB4. api 通道负向：systems 配置缺失 → BLOCKED（提示配置目录）
    exd_b4 = tmp / "exec-api-b4"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_api),
             "--exec-dir", str(exd_b4), "--run-id", "bb4", "--systems-dir", str(tmp / "nope")], env=env_api)
    j = json.loads((exd_b4 / "case-results.json").read_text())
    check("runner(api): systems 配置缺失 → BLOCKED", r.returncode == 2 and j[0]["status"] == "BLOCKED",
          f"exit={r.returncode} status={j[0]['status']}")

    # BB5. cli 后端仅显式 FLOWTEST_CLI（第十二轮：移除 PATH/默认路径盲探）
    exd_b5 = tmp / "exec-api-b5"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_api),
             "--exec-dir", str(exd_b5), "--run-id", "bb5"],
            env={**__import__("os").environ, "FLOWTEST_RUNNER": "cli"})  # 无 FLOWTEST_CLI
    j = json.loads((exd_b5 / "case-results.json").read_text())
    check("runner(cli): 无显式 FLOWTRACE_CLI → BLOCKED（不再盲探 PATH/默认路径）",
          r.returncode == 2 and j[0]["status"] == "BLOCKED", f"exit={r.returncode} status={j[0]['status']}")

    # BB6. api 采集与对拍器同构：BB1 的双端 capture 直接喂 field-level-compare → OK
    rules_bb = fc_rules(fms=[{"legacy_field": "CS", "target_field": "CS", "normalize": "trim",
                              "tolerance": "exact", "null_policy": "both_null_equal"}])
    (tmp / "bb6-rules.json").write_text(json.dumps(rules_bb, ensure_ascii=False), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "field-level-compare.py"),
             "--captures-dir", str(exd_b1 / "field-captures"), "--rules", str(tmp / "bb6-rules.json"),
             "--outdir", str(tmp / "bb6-out")])
    j = json.loads((tmp / "bb6-out" / "field-compare.json").read_text())
    check("compare: api 采集件可直供对拍（同构性）→ OK",
          r.returncode == 0 and j["status"] == "OK" and j["stats"]["match"] == 2,   # s1+s2 两个 step 各 1 匹配
          f"exit={r.returncode} status={j.get('status')} stats={j.get('stats')}")

    # BB7. reuse（显式 instancePolicy）只能采本流程待办：mock 里预置"本流程待办实例" +
    #      他流程 decoy → reuse 采本流程实例、不碰 decoy（legacy/current 各自独立 server/state）
    sd_reuse = tmp / "scen-reuse"; sd_reuse.mkdir()
    (sd_reuse / "r1.yaml").write_text(_y.safe_dump({
        "id": "WFA_X_0001-c-02", "case_id": "C-02", "required": True, "instancePolicy": "reuse",
        "steps": [{"seq": 1, "node": "00", "actorAccount": "admin"},
                  {"seq": 2, "node": "01", "actorAccount": "admin2"}]}), encoding="utf-8")

    def _reuse_server():
        p = _free_port()
        srv, st = _start_mock(p, "/re", "V", with_decoy=False)
        st.tasks["t-own"] = {"assignee": "mock-admin", "taskId": "t-own", "node": "00",
                             "instanceNo": "INST-OWN", "flowCode": "WFA_X_0001"}
        st.tasks["t-decoy2"] = {"assignee": "mock-admin", "taskId": "t-decoy2", "node": "00",
                                "instanceNo": "INST-D2", "flowCode": "WFA_OTHER"}
        return p, srv, st
    pRL, srvRL, stRL = _reuse_server()
    pRC, srvRC, stRC = _reuse_server()
    sysd_r = tmp / "systems-api-reuse"; sysd_r.mkdir()
    (sysd_r / "legacy.yaml").write_text(_mock_yaml(pRL, "legacy", "/re"), encoding="utf-8")
    (sysd_r / "current.yaml").write_text(_mock_yaml(pRC, "current", "/re"), encoding="utf-8")
    exd_b7 = tmp / "exec-api-b7"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_reuse),
             "--exec-dir", str(exd_b7), "--run-id", "bb7", "--systems-dir", str(sysd_r)], env=env_api)
    j = json.loads((exd_b7 / "case-results.json").read_text())
    capR = json.loads((exd_b7 / "field-captures" / "legacy" / "C-02.json").read_text())
    check("runner(api): reuse（显式声明）只采本流程待办 → PASS 且不碰他流程 decoy",
          r.returncode == 0 and j[0]["status"] == "PASS" and capR["instance_no"] == "INST-OWN"
          and stRL.tasks.get("t-decoy2") is not None and stRC.tasks.get("t-decoy2") is not None,
          f"exit={r.returncode} status={j[0]['status']} inst={capR.get('instance_no')}")
    # BB7b. reuse 但 systems todo 无 flowCodePath → BLOCKED（复用必须能验流程身份）
    sysd_r2 = tmp / "systems-api-reuse-nofc"; sysd_r2.mkdir()
    y2 = _y.safe_load(_mock_yaml(pRL, "legacy", "/re"))
    del y2["api"]["todo"]["flowCodePath"]
    (sysd_r2 / "legacy.yaml").write_text(_y.safe_dump(y2, allow_unicode=True), encoding="utf-8")
    (sysd_r2 / "current.yaml").write_text(_y.safe_dump(y2, allow_unicode=True), encoding="utf-8")
    exd_b7b = tmp / "exec-api-b7b"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_reuse),
             "--exec-dir", str(exd_b7b), "--run-id", "bb7b", "--systems-dir", str(sysd_r2)], env=env_api)
    j = json.loads((exd_b7b / "case-results.json").read_text())
    check("runner(api): reuse 缺 flowCodePath → BLOCKED（复用须验流程身份）",
          r.returncode == 2 and j[0]["status"] == "BLOCKED", f"exit={r.returncode} status={j[0]['status']}")

    # BB8. health-check：契约 environments.health_checks 驱动（P1——不再硬编码端点）
    hc_ok = tmp / "hc-ok.yaml"
    hc_ok.write_text(_y.safe_dump({"environments": {"health_checks": [
        f"curl -m 3 -o /dev/null -w '%{{http_code}}' http://127.0.0.1:{pL}/leg/health  # expect 200"]}}), encoding="utf-8")
    hr1 = tmp / "hc-ok.json"
    r = run([sys.executable, str(SCRIPTS / "health-check.py"), "--contract", str(hc_ok), "--out", str(hr1)])
    j = json.loads(hr1.read_text())
    check("health: 契约 health_checks（可达）→ passed=true",
          r.returncode == 0 and j[0]["passed"] is True, f"exit={r.returncode} j={j}")
    hc_bad = tmp / "hc-bad.yaml"
    hc_bad.write_text(_y.safe_dump({"environments": {"health_checks": [
        "curl -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:1/x/health  # expect 200"]}}), encoding="utf-8")
    hr2 = tmp / "hc-bad.json"
    r = run([sys.executable, str(SCRIPTS / "health-check.py"), "--contract", str(hc_bad), "--out", str(hr2)])
    j = json.loads(hr2.read_text())
    check("health: 契约 health_checks（不可达）→ passed=false 不 crash",
          r.returncode == 0 and j[0]["passed"] is False, f"exit={r.returncode} j={j}")
    hc_mal = tmp / "hc-mal.yaml"
    hc_mal.write_text(_y.safe_dump({"environments": {"health_checks": ["rm -rf /tmp/x"]}}), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "health-check.py"), "--contract", str(hc_mal), "--out", str(tmp / "hc-m.json")])
    check("health: 非 curl 描述条目（任意命令串）→ 拒绝 exit 2（不 eval 契约串）",
          r.returncode == 2, f"exit={r.returncode}")
    hc_none = tmp / "hc-none.yaml"
    hc_none.write_text(_y.safe_dump({"environments": {}}), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "health-check.py"), "--contract", str(hc_none), "--out", str(tmp / "hc-n.json")])
    check("health: 契约无 health_checks → 拒绝 exit 2（fail-closed）", r.returncode == 2, f"exit={r.returncode}")
    # BB8b. gate-evidence 健康结果接入：health 自动 gate 免证据；GATE-HEALTH 声明仍被覆盖
    hc_gct = tmp / "hc-gates-contract.yaml"
    hc_gct.write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001"},
        "gates": [{"id": "GATE-HEALTH", "check": "服务健康", "severity": "P0"}]}), encoding="utf-8")
    gk_hc = tmp / "hc-gates.json"
    r = run([sys.executable, str(SCRIPTS / "gate-evidence-check.py"), str(gk_hc), str(hr1),
             str(hc_gct), str(tmp / "aa-empty-health.json"), str(tmp)])
    j = json.loads(gk_hc.read_text())
    check("gate-evidence: health 自动结果并入（health-<url> 存在）且 GATE-HEALTH 免手工证据",
          r.returncode == 0 and any(g["id"].startswith("health-") and g["passed"] is True for g in j),
          f"exit={r.returncode} j={j[:1]}")

    srvL.shutdown(); srvC.shutdown(); srvRL.shutdown(); srvRC.shutdown()

    # ---------- 第十六轮回归（2026-09-07 第十三轮·补齐轮：F12 录端点占位防御） ----------
    # CC1. legacy-config-check.py：占位残留 → exit 1 + 清单（人工可粘贴去录端点）
    lc_legacy = tmp / "lc-legacy.yaml"
    lc_legacy.write_text((tmp / "aa14-report.json").read_text() if False else (
        "id: legacy\nchannel: api\n"
        "api:\n  baseUrl: http://127.0.0.1:9\n  login:\n    method: POST\n    path: /api/auth/login\n"
        "    body: {u: '${U}', p: '${P}'}\n    tokenPath: __F12_RECORD__\n"
        "    tokenHeader: Authorization\n    tokenScheme: 'Bearer '\n"
        "  todo:\n    method: GET\n    path: /api/todo\n    params: {p:0, s:50}\n"
        "    listPath: data.list\n    taskIdPath: id\n    nodePath: n\n    instancePath: i\n"
        "    flowCodePath: __F12_RECORD__\n"
        "actorMap:\n  admin: {username: L_A_USER, password: L_A_PWD}\n"), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "legacy-config-check.py"), "--systems", str(lc_legacy)])
    check("legacy-config-check: __F12_RECORD__ 残留 → exit 1 + 清单（可粘贴去录）",
          r.returncode == 1 and "__F12_RECORD__" in r.stdout and "tokenPath" in r.stdout
          and "todo.flowCodePath" in r.stdout, f"exit={r.returncode} stdout[:200]={r.stdout[:200]!r}")
    # CC2. legacy-config-check：填好所有占位且结构完整 → exit 0
    filled = tmp / "lc-filled.yaml"
    filled.write_text((tmp / "aa14-report.json").read_text() if False else
        "id: legacy\nchannel: api\napi:\n"
        "  baseUrl: http://127.0.0.1:1\n  login: {method: POST, path: /api/auth/login,\n"
        "    body: {u: '${U}', p: '${P}'}, tokenPath: data.token,\n"
        "    tokenHeader: Authorization, tokenScheme: 'Bearer '}\n"
        "  todo: {method: GET, path: /api/todo, params: {p:0, s:50},\n"
        "    listPath: data.list, taskIdPath: id, nodePath: n, instancePath: i, flowCodePath: fc}\n"
        "  launch: {method: POST, path: /api/flow/start, body: {flowCode: '${FLOW_CODE}'},\n"
        "    instancePath: data.instanceNo, taskIdPath: data.taskId, elementIdEnv: LEGACY_LAUNCH_ELEMENT_ID}\n"
        "  form: {method: GET, path: '/api/task/${TASK_ID}/form', fieldsPath: data.formData}\n"
        "  submit: {method: POST, path: '/api/task/${TASK_ID}/submit', defaultButton: '提交',\n"
        "    body: {buttonCode: '${BUTTON}', nextAssigneeId: '${NEXT_ASSIGNEE}'}, successStatus: [200]}\n"
        "actorMap: {admin: {username: L_A_USER, password: L_A_PWD}}\n", encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "legacy-config-check.py"), "--systems", str(filled)])
    check("legacy-config-check: 占位全清 → exit 0（可启动 api-capture）",
          r.returncode == 0 and "无残留占位" in r.stdout, f"exit={r.returncode}")
    # CC3. api-capture：systems 配置含 __F12_RECORD__ → 立即 exit 2 拒绝（绝不假跑）
    sd_pp = tmp / "scen-pp"; sd_pp.mkdir()
    (sd_pp / "s1.yaml").write_text(_y.safe_dump({
        "id": "WFA_X_0001-c-99", "case_id": "C-99", "required": True,
        "steps": [{"seq": 1, "node": "00", "actorAccount": "admin"}]}), encoding="utf-8")
    sysd_pp = tmp / "sysd-pp"; sysd_pp.mkdir()
    (sysd_pp / "current.yaml").write_text(_mock_yaml(pC, "current", "/cur"), encoding="utf-8")
    (sysd_pp / "legacy.yaml").write_text(lc_legacy.read_text(encoding="utf-8"), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_pp),
             "--exec-dir", str(tmp / "exec-pp"), "--run-id", "cc3", "--systems-dir", str(sysd_pp)], env=env_api)
    j = json.loads((tmp / "exec-pp" / "case-results.json").read_text())
    check("runner(api): 任意一侧含 __F12_RECORD__ → 立即 BLOCKED（绝不假跑）",
          r.returncode == 2 and j[0]["status"] == "BLOCKED" and "__F12_RECORD__" in j[0].get("reason", ""),
          f"exit={r.returncode} status={j[0]['status']}")
    # CC4. 端到端：用"全填"legacy yaml + 真实 mock legacy server → 双向 PASS（验证补齐后可跑通）
    pL2, pC2 = _free_port(), _free_port()
    srvL2, _ = _start_mock(pL2, "/leg", "V")
    srvC2, _ = _start_mock(pC2, "/cur", "V")
    sysd_pp2 = tmp / "sysd-pp2"; sysd_pp2.mkdir()
    (sysd_pp2 / "legacy.yaml").write_text(_mock_yaml(pL2, "legacy", "/leg"), encoding="utf-8")
    (sysd_pp2 / "current.yaml").write_text(_mock_yaml(pC2, "current", "/cur"), encoding="utf-8")
    exd_cc4 = tmp / "exec-cc4"
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_pp),
             "--exec-dir", str(exd_cc4), "--run-id", "cc4", "--systems-dir", str(sysd_pp2)], env=env_api)
    j = json.loads((exd_cc4 / "case-results.json").read_text())
    capL = json.loads((exd_cc4 / "field-captures" / "legacy" / "C-99.json").read_text())
    check("runner(api): legacy 全填 + mock → 双向 PASS（验证补齐后 legacy 端到端可跑通）",
          r.returncode == 0 and j[0]["status"] == "PASS"
          and capL["flow_code"] == "WFA_X_0001" and capL["instance_no"] == "INST-L1",
          f"exit={r.returncode} status={j[0]['status']}")
    srvL2.shutdown(); srvC2.shutdown()

    # BB9f. gen-final-report：单 md 最终交付（9 节齐全 + fail-closed；1.3.4 起强制证据链核验）
    import hashlib as _h_gfr
    _gfr = tmp / "run-gfr"; _gfr.mkdir(parents=True)
    (_gfr / "summary.json").write_text(json.dumps({"run_id": "run-gfr", "conclusion": "FAIL", "p0_count": 0, "p1_count": 0,
        "required_cases": {"total": 1, "done": 1}, "semantic_diffs": [{}], "exempted_diffs": [],
        "failed_cases": [], "blocked_reasons": [], "aux_evidence": {}}), encoding="utf-8")
    (_gfr / "gates.json").write_text(json.dumps([{"id": "GATE-X", "severity": "P1", "passed": True, "note": "n"}]), encoding="utf-8")
    (_gfr / "case-results.json").write_text(json.dumps([{"id": "C-01", "required": True, "status": "PASS", "reason": ""}]), encoding="utf-8")
    (_gfr / "field-compare.json").write_text(json.dumps({"status": "FAIL", "version": "field-level-compare.py v2.10",
        "stats": {"match": 1, "diff": 1, "exempted": 0, "observe": 0, "coverage_blockers": 0},
        "diffs": [{"dim": "field", "key": "k", "legacy": "a", "current": "b", "reason": "tolerance"}],
        "exempted": [], "observe": [], "coverage": []}), encoding="utf-8")
    _snap_gfr = {}
    for _key_gfr, _fname_gfr in (("gates", "gates.json"), ("case_results", "case-results.json"),
                                 ("field_compare", "field-compare.json")):
        _fp_gfr = _gfr / _fname_gfr
        _snap_gfr[_key_gfr] = {"path": str(_fp_gfr), "abs_path": str(_fp_gfr.resolve()),
                               "sha256_16": _h_gfr.sha256(_fp_gfr.read_bytes()).hexdigest()[:16]}
    (_gfr / "run-manifest.json").write_text(json.dumps({"run_id": "run-gfr",
        "versions": {"source": "s", "target": "t", "flow": "f"},
        "config_snapshot": _snap_gfr, "evidence_paths": []}), encoding="utf-8")
    _r_gfr = run([sys.executable, str(SCRIPTS / "gen-final-report.py"), "--run-dir", str(_gfr)])
    _md_ok = False
    try:
        _md = (_gfr / "对比测试报告.md").read_text(encoding="utf-8")
        # 1.4.0：报告人话化——"tolerance" 机器原因翻译为人话；新增一句话结论/分组/徽标；
        # 断言同步为"人话在报告中可见 + 机器节名不回归"
        _md_ok = all(k in _md for k in ["## 1. Run 信息", "## 2. 结论速览", "## 3. 用例结果总表",
                                        "## 4. 语义对拍明细", "## 5. Gate 明细", "## 6.", "## 7.", "## 8.", "## 9.",
                                        "一句话结论", "数值不一致（超出允许容差）", "#### 用例", "✅ PASS",
                                        "GATE-X", "人工发现.md"])
    except FileNotFoundError:
        pass
    check("BB9f-1. gen-final-report: 证据链核验通过后汇总 9 节 md（账本/用例/对拍/门禁/结论同源）",
          _r_gfr.returncode == 0 and _md_ok, f"exit={_r_gfr.returncode} {_r_gfr.stderr[-200:]}")
    _r_gfr2 = run([sys.executable, str(SCRIPTS / "gen-final-report.py"), "--run-dir", str(tmp / "run-gfr-no-summary")])
    check("BB9f-2. gen-final-report: 缺 summary.json → exit 2（无结论不产报告）",
          _r_gfr2.returncode == 2, f"exit={_r_gfr2.returncode}")

    # BB9h（1.4.0）. fc_readability 人话化共享库（gen-final-report 与 field-level-compare 唯一实现）
    import importlib.util as _ilu
    _spec_fr = _ilu.spec_from_file_location("ftc_fc_readability_test", SCRIPTS / "fc_readability.py")
    _fr = _ilu.module_from_spec(_spec_fr)
    _spec_fr.loader.exec_module(_fr)
    check("BB9h-1. dim_cn: 维度中文化 + 未知透传",
          _fr.dim_cn("field") == "字段值" and _fr.dim_cn("formula") == "公式计算"
          and _fr.dim_cn("routing") == "环节路由" and _fr.dim_cn("buttons") == "按钮"
          and _fr.dim_cn("resources") == "资源占用" and _fr.dim_cn("post_flow") == "流程后置"
          and _fr.dim_cn("mystery") == "mystery")
    check("BB9h-2. human_reason: 机器原因→人话 + 未知透传（绝不编造）",
          _fr.human_reason("field", "tolerance") == "数值不一致（超出允许容差）"
          and "空值" in _fr.human_reason("field", "null_policy")
          and "结果不同" in _fr.human_reason("formula", "新老计算值不一致")
          and _fr.human_reason("field", "自定义原因xyz") == "自定义原因xyz")
    check("BB9h-3. diff_case/diff_where: field(/) 与其他(:) 两类键都能解析",
          _fr.diff_case("C-01/00/a->b") == "C-01" and _fr.diff_where("C-01/00/a->b") == "00/a->b"
          and _fr.diff_case("C-03:formula/F1") == "C-03" and _fr.diff_where("C-03:formula/F1") == "formula/F1")
    _g = _fr.group_by_case([{"key": "C-01/00/a->b"}, {"key": "C-03:formula/F1"}, {"key": "C-01/01/c->d"}, "junk"])
    check("BB9h-4. group_by_case: 按用例分组保序 + 非 dict 忽略",
          list(_g) == ["C-01", "C-03"] and len(_g["C-01"]) == 2 and len(_g["C-03"]) == 1)
    check("BB9h-5. one_line_conclusion: PASS/FAIL/BLOCKED 三态人话（只陈述事实）",
          "双端执行通过" in _fr.one_line_conclusion("PASS", req_done=2, req_total=2)
          and "2 处新老系统行为不一致" in _fr.one_line_conclusion("FAIL", n_diff=2, top_diffs=[{"key": "C-03:formula/F1"}])
          and "C-03" in _fr.one_line_conclusion("FAIL", n_diff=2, top_diffs=[{"key": "C-03:formula/F1"}])
          and "未能完成判定" in _fr.one_line_conclusion("BLOCKED", blocked_reasons=["环境不可达"]))
    check("BB9h-6. fmt_value: None/空串显式化为（空），容器转 JSON 短串",
          _fr.fmt_value(None) == "（空）" and _fr.fmt_value("") == "（空）"
          and _fr.fmt_value({"a": 1}) == '{"a": 1}' and _fr.fmt_value("x" * 100, limit=10).endswith("…"))

    # BB9i（1.4.0）. explore-channel 自由探索器（写门槛 / 双端 merge / observe-only / apply 探索中断如实记录）
    def _br(obj, n: int = 160) -> str:
        try:
            s = json.dumps(obj, ensure_ascii=False)
        except Exception:
            s = str(obj)
        return s[:n]
    pEL, pEC = _free_port(), _free_port()
    srvEL, stEL = _start_mock(pEL, "/leg", "V")
    srvEC, stEC = _start_mock(pEC, "/cur", "V")
    exp_sysd = tmp / "systems-explore"; exp_sysd.mkdir()
    (exp_sysd / "legacy.yaml").write_text(_mock_yaml(pEL, "legacy", "/leg"), encoding="utf-8")
    (exp_sysd / "current.yaml").write_text(_mock_yaml(pEC, "current", "/cur"), encoding="utf-8")
    EXPLORE = [sys.executable, str(SCRIPTS / "explore-channel.py")]
    # EX1. 写门槛前置：无 --apply 且无 --observe-only → exit 2（在任何登录/网络动作之前）
    r = run(EXPLORE + ["explore", "--systems", str(exp_sysd / "legacy.yaml"), "--flow", "WFA_X_0001",
                      "--outdir", str(tmp / "exp1")], env=env_api)
    check("explore: 无 --apply/--observe-only → exit 2（写门槛在登录前，fail-closed 顺序）",
          r.returncode == 2 and "--apply" in (r.stderr or "") and not (tmp / "exp1").exists(),
          f"exit={r.returncode} err={r.stderr[-160:]}")
    # EX2. observe-only：登录+待办结构观察（decoy 在册）→ exit 0，零实例零表单
    r = run(EXPLORE + ["explore", "--systems", str(exp_sysd / "legacy.yaml"), "--flow", "WFA_X_0001",
                      "--outdir", str(tmp / "exp2"), "--observe-only"], env=env_api)
    _oj = json.loads((tmp / "exp2" / "explore-legacy.json").read_text()) if r.returncode == 0 else {}
    check("explore: observe-only → 待办结构观察（decoy 计入总数、本流程 0 条、无 instance_no）",
          r.returncode == 0 and _oj.get("mode") == "observe_only" and _oj.get("todo_total") == 1
          and _oj.get("flow_matching") == 0 and "instance_no" not in _oj,
          f"exit={r.returncode} j={_br(_oj, 200)}")
    # EX3. merge 双端不齐 → exit 2（单端不成经验）
    r = run(EXPLORE + ["merge", "--explore-dir", str(tmp / "exp2")])
    check("explore: merge 缺一端实录 → exit 2（单端不成经验）", r.returncode == 2,
          f"exit={r.returncode} err={r.stderr[-120:]}")
    # EX4/EX5. apply 写探索（mock 无路由配置 → 探索单步后如实中断，exit 0；launch-first 隔离）
    # 审计第 5 轮：--apply 强制显式 --actor；--include-values 保留原值供断言（默认脱敏另测）
    _exp_args = ["explore", "--flow", "WFA_X_0001", "--apply", "--fill",
                 "--actor", "admin", "--advance", "first", "--include-values"]
    rL = run(EXPLORE + _exp_args + ["--systems", str(exp_sysd / "legacy.yaml"),
                                   "--outdir", str(tmp / "exp4")], env=env_api)
    rC = run(EXPLORE + _exp_args + ["--systems", str(exp_sysd / "current.yaml"),
                                   "--outdir", str(tmp / "exp4")], env=env_api)
    _ej = (json.loads((tmp / "exp4" / "explore-legacy.json").read_text()) if rL.returncode == 0 else {})
    _st1 = ((_ej.get("steps") or [{}])[0])
    check("explore: apply 探索 → launch-first 发起实例、字段经验采集、无路由如实中断（exit 0 不谎报完成）",
          rL.returncode == 0 and rC.returncode == 0 and _ej.get("status") == "interrupted"
          and str(_ej.get("instance_no", "")).startswith("INST-L") and _ej.get("instance_no") != "INST-DECOY"
          and len(_ej.get("steps") or []) == 1 and _st1.get("fields", {}).get("CS") == "V"
          and "路由候选" in str(_ej.get("interrupted_reason")),
          f"exitL={rL.returncode} exitC={rC.returncode} j={_br(_ej, 220)}")
    check("explore: 公式探针在 save_with_form_data 未配置时如实记录跳过（不猜测保存端点）",
          "公式探针未执行" in "；".join(_st1.get("notes") or []),
          f"notes={_br(_st1.get('notes'), 160)}")
    check("explore: 探索隔离性——他流程 decoy 未被触碰",
          stEL.tasks.get("t-decoy") is not None and stEC.tasks.get("t-decoy") is not None)
    # EX6. 人读版产物存在且含关键事实
    _mdL = (tmp / "exp4" / "探索发现-legacy.md").read_text(encoding="utf-8") if rL.returncode == 0 else ""
    check("explore: 探索发现 md（人读）——含节点字段表与中断说明",
          "表单字段" in _mdL and "interrupted" in _mdL and "INST-L" in _mdL)
    # EX6b.（审计第 5 轮 P0-2/IM1）默认脱敏 + apply 缺 --actor 拒 + 产物防覆盖
    r = run(EXPLORE + ["explore", "--flow", "WFA_X_0001", "--apply", "--systems",
                       str(exp_sysd / "legacy.yaml"), "--outdir", str(tmp / "exp4b")], env=env_api)
    check("explore: --apply 缺显式 --actor → exit 2（写操作须可追溯账号，不静默取第一个）",
          r.returncode == 2 and "--actor" in (r.stderr or ""), f"exit={r.returncode} err={r.stderr[-140:]}")
    r = run(EXPLORE + ["explore", "--flow", "WFA_X_0001", "--apply", "--actor", "admin",
                       "--systems", str(exp_sysd / "legacy.yaml"),
                       "--outdir", str(tmp / "exp4b")], env=env_api)
    _rj = (json.loads((tmp / "exp4b" / "explore-legacy.json").read_text()) if r.returncode == 0 else {})
    _rf = (((_rj.get("steps") or [{}])[0]).get("fields") or {})
    check("explore: 默认脱敏——字段值=#sha16:长度、includes_sensitive_values=false、advance 默认 none",
          r.returncode == 0 and _rj.get("includes_sensitive_values") is False
          and str(list(_rf.values())[0]).startswith("#") and ":" in str(list(_rf.values())[0])
          and _rj.get("options", {}).get("advance") == "none"
          and "advance=none" in str(_rj.get("interrupted_reason")),
          f"exit={r.returncode} j={_br(_rj, 220)}")
    r = run(EXPLORE + ["explore", "--flow", "WFA_X_0001", "--apply", "--actor", "admin",
                       "--systems", str(exp_sysd / "legacy.yaml"),
                       "--outdir", str(tmp / "exp4b")], env=env_api)
    check("explore: 同目录已有产物 → exit 2（防静默覆盖丢实例号；--overwrite 才放行）",
          r.returncode == 2 and "--overwrite" in (r.stderr or ""), f"exit={r.returncode} err={r.stderr[-140:]}")
    # EX6c.（审计第 5 轮 P0-2）无候选办理人 → submit 前中断（绝不空办理人提交）
    pEB, srvEB = None, None
    import socket as _sk5
    _s5 = _sk5.socket(); _s5.bind(("127.0.0.1", 0)); _pEB = _s5.getsockname()[1]; _s5.close()
    _eb_state = {"submitted": 0}
    from http.server import BaseHTTPRequestHandler as _BH5, ThreadingHTTPServer as _TH5
    class _H5(_BH5):
        def log_message(self, *a): pass
        def _j(self, o, code=200):
            b = json.dumps(o).encode(); self.send_response(code)
            self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
            self.end_headers(); self.wfile.write(b)
        def do_POST(self):
            ln = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(ln) or b"{}")
            if self.path == "/eb/login":
                self._j({"data": {"token": "tok-x"}}); return
            if self.path == "/eb/launch":
                self._j({"data": {"flowInstanceNo": "FI-EB1", "firstTaskId": "t-eb1"}}); return
            if self.path == "/eb/submit":
                _eb_state["submitted"] += 1; self._j({"data": {}}); return
            self._j({"m": "nf"}, 404)
        def do_GET(self):
            if self.path.startswith("/eb/form"):
                # 声明 nextStep=01（有路由）但无 assignee resolver → 无候选办理人
                self._j({"data": {"formData": {"CS": "V"}, "autoflowStep": {"stepCode": "00", "nextStep": "01"}}}); return
            self._j({"m": "nf"}, 404)
    srvEB = _TH5(("127.0.0.1", _pEB), _H5)
    _th.Thread(target=srvEB.serve_forever, daemon=True).start()
    (exp_sysd / "blankasg.yaml").write_text(_y.safe_dump({
        "id": "legacy", "channel": "api",
        "api": {"baseUrl": f"http://127.0.0.1:{_pEB}", "taskWaitSeconds": 1,
                "login": {"method": "POST", "path": "/eb/login", "body": {"u": "${USERNAME}"},
                          "tokenPath": "data.token", "tokenHeader": "Authorization", "tokenScheme": "Bearer "},
                "todo": {"mode": "ledger", "firstNode": "00", "nextTaskPath": "data.x",
                         "params": {}, "path": "/unused", "listPath": "data.content"},
                "launch": {"method": "POST", "path": "/eb/launch", "body": {"e": "${ELEMENT_ID}"},
                           "instancePath": "data.flowInstanceNo", "taskIdPath": "data.firstTaskId",
                           "elementIdEnv": "LAUNCH_ELEMENT_ID_WFA_X_0001"},
                "form": {"method": "GET", "path": "/eb/form", "fieldsPath": "data.formData",
                         "nodePath": "data.autoflowStep.stepCode", "nextStepPath": "data.autoflowStep.nextStep"},
                "submit": {"method": "POST", "path": "/eb/submit", "defaultButton": "提交", "body": {}}},
        "actorMap": {"admin": {"username": "MOCK_ADMIN_USER", "password": "MOCK_ADMIN_PWD"}}},
        allow_unicode=True), encoding="utf-8")
    r = run(EXPLORE + ["explore", "--flow", "WFA_X_0001", "--apply", "--actor", "admin",
                       "--advance", "first", "--include-values",
                       "--systems", str(exp_sysd / "blankasg.yaml"),
                       "--outdir", str(tmp / "exp4c")], env=env_api)
    _bj = (json.loads((tmp / "exp4c" / "explore-legacy.json").read_text()) if r.returncode == 0 else {})
    check("explore: 有路由无候选办理人 → submit 前中断（绝不空办理人提交——P0-2）",
          r.returncode == 0 and _eb_state["submitted"] == 0
          and "空办理人" in str(_bj.get("interrupted_reason")) and _bj.get("status") == "interrupted"
          and (_bj.get("steps") or [{}])[0].get("advanced_to") is None,
          f"exit={r.returncode} submitted={_eb_state['submitted']} j={_br(_bj, 200)}")
    srvEB.shutdown()
    # EX7. merge：手工构造双端实录（同名/同值/单侧字段三类）→ experience.yaml + 立契建议
    exp7 = tmp / "exp7"; exp7.mkdir()
    _base = {"version": "t", "explore_id": "exp7", "mode": "explore", "flow_code": "WFA_X_0001",
             "actor": "a", "instance_no": "I1", "created_at": "t", "status": "completed",
             "interrupted_reason": None, "options": {},
             "steps": [{"seq": 1, "node": "00", "task_id": "t1",
                        "fields": {"毛重": "35.6", "CS": "V", "旧字段": "z", "仅老有": "1"},
                        "buttons_known": ["提交"],
                        "routes": [{"node": "01", "source": "form.nextStepPath", "note": ""}],
                        "assignee_candidates": [], "formula_probe": None,
                        "form_data_applied": None, "advanced_to": None, "notes": []}]}
    _cur = json.loads(json.dumps(_base))
    _cur["side"] = "current"
    _cur["steps"][0]["fields"] = {"毛重": "35.6", "CS": "V", "cs_new": "z", "仅新有": "2"}
    (exp7 / "explore-legacy.json").write_text(json.dumps(_base, ensure_ascii=False), encoding="utf-8")
    (exp7 / "explore-current.json").write_text(json.dumps(_cur, ensure_ascii=False), encoding="utf-8")
    r = run(EXPLORE + ["merge", "--explore-dir", str(exp7)])
    _exp_yaml = (exp7 / "experience.yaml").read_text(encoding="utf-8") if r.returncode == 0 else ""
    check("explore: merge → 同名映射建议自动纳入（毛重/CS），同值巧合仅提示不纳入（旧字段↔cs_new）",
          r.returncode == 0 and "legacy_field: 毛重" in _exp_yaml
          and "basis: same_name" in _exp_yaml and "suggest: true" in _exp_yaml
          and "basis: same_value" in _exp_yaml
          and "normalize: trim" in _exp_yaml and "null_policy: both_null_equal" in _exp_yaml,
          f"exit={r.returncode} err={r.stderr[-160:]}")
    _adv = (exp7 / "立契建议.md").read_text(encoding="utf-8") if r.returncode == 0 else ""
    check("explore: 立契建议（人读）——待人工清单与建议表在场 + 探索 sha 入账",
          "待人工" in _adv and "可自动纳入" in _adv and "sha256_16" in _exp_yaml)
    # EX8. merge 负向：双端流程编码不一致 → 拒（跨流程拼经验）
    (exp7 / "explore-current.json").write_text(
        json.dumps({**_cur, "flow_code": "WFA_OTHER"}, ensure_ascii=False), encoding="utf-8")
    r = run(EXPLORE + ["merge", "--explore-dir", str(exp7)])
    check("explore: merge 双端流程编码不一致 → exit 2（不许跨流程拼经验）", r.returncode == 2,
          f"exit={r.returncode} err={r.stderr[-120:]}")
    srvEL.shutdown(); srvEC.shutdown()

    # EX9.（审计第 5 轮 P1-3）reuse 消歧选择器从契约 → schema → 生成场景全链贯通
    import copy as _copy5
    _rail = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    _rail["meta"]["instance_policy"] = "reuse"
    _c9 = _rail["cases"][0]
    _c9["instanceNo"] = {"legacy": "FI-LEGACY-9", "current": "FI-CURRENT-9"}
    _c9["businessKey"] = "BK-9"
    _c9["fixtureSelector"] = {"legacy": "LS-9", "current": "CS-9"}
    _c9_path = tmp / "contract-sel.yaml"
    _c9_path.write_text(_y.safe_dump(_rail, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"),
             "--contract", str(_c9_path), "--level", "test_ready"])
    check("selector(P1-3): 契约含分侧/标量选择器 → schema 校验通过（不误伤）",
          r.returncode == 0, f"exit={r.returncode} {r.stderr[-200:]}")
    _out9 = tmp / "gen-sel"
    r = run([sys.executable, str(HERE / "gen_from_contract.py"),
             "--contract", str(_c9_path), "--outdir", str(_out9)])
    _scen9 = _out9 / "flowtrace-scenarios" / f"{_rail['meta']['flow_code']}-{_c9['id'].lower()}.yaml"
    _sc9 = _y.safe_load(_scen9.read_text(encoding="utf-8")) if _scen9.exists() else {}
    check("selector(P1-3): 生成场景透传 instanceNo/businessKey/fixtureSelector（分侧映射保形）",
          r.returncode == 0 and _sc9.get("instanceNo") == {"legacy": "FI-LEGACY-9", "current": "FI-CURRENT-9"}
          and _sc9.get("businessKey") == "BK-9"
          and _sc9.get("fixtureSelector") == {"legacy": "LS-9", "current": "CS-9"},
          f"exit={r.returncode} scen={_br(_sc9, 260)}")
    # 负向：launch 策略下选择器不透传（防误用语义）
    _rail2 = _copy5.deepcopy(_rail)
    _rail2["meta"]["instance_policy"] = "launch"
    _p_launch = tmp / "contract-sel-launch.yaml"
    _p_launch.write_text(_y.safe_dump(_rail2, allow_unicode=True), encoding="utf-8")
    _out9b = tmp / "gen-sel-launch"
    run([sys.executable, str(HERE / "gen_from_contract.py"), "--contract", str(_p_launch),
         "--outdir", str(_out9b)])
    _sc9b_path = _out9b / "flowtrace-scenarios" / f"{_rail2['meta']['flow_code']}-{_c9['id'].lower()}.yaml"
    _sc9b = _y.safe_load(_sc9b_path.read_text(encoding="utf-8")) if _sc9b_path.exists() else {}
    check("selector(P1-3): launch 策略下选择器不进场景（语义只在 reuse 有意义）",
          all(k not in _sc9b for k in ("instanceNo", "businessKey", "fixtureSelector")),
          f"keys={sorted(_sc9b)[:8]}")


    # ---------- v1.5.0 任务完成门回归（覆盖账本 / readiness / 数据账本 / 重跑计划 / DRAFT 骨架 / browser 入口） ----------
    import importlib.util as _ilu5
    _spec_cm = _ilu5.spec_from_file_location("ftc_cm_test", SCRIPTS / "coverage_manifest.py")
    _cm = _ilu5.module_from_spec(_spec_cm)
    _spec_cm.loader.exec_module(_cm)
    _contract5 = tmp / "cov-contract.yaml"
    _contract5.write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "门禁测试", "shape": "S2",
                 "contract_version": 1, "status": "TEST_READY",
                 "coverage_manifest": {"path": str(tmp / "cov-manifest.yaml")}},
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}],
        "field_mappings": [{"legacy_field": "A", "target_field": "A", "normalize": "trim",
                            "tolerance": "exact", "null_policy": "both_null_equal"}],
        "buttons": [{"node": "00", "expect_visible": ["提交"]}],
    }, allow_unicode=True), encoding="utf-8")
    # COV-1：scaffold 全 uncovered
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "scaffold",
             "--contract", str(_contract5), "--out", str(tmp / "cov-manifest.yaml")])
    _cmj = _y.safe_load((tmp / "cov-manifest.yaml").read_text(encoding="utf-8")) if r.returncode == 0 else {}
    _els = _cmj.get("elements") or []
    check("cov(1.5.0): scaffold → 全部 uncovered/must_cover（骨架即诚实，不允许默认 covered）",
          r.returncode == 0 and _els and all(e.get("status") == "uncovered" and e.get("must_cover") is True
                                             for e in _els),
          f"exit={r.returncode} n={len(_els)}")
    # COV-2：结构非法（covered 缺 contract_ref）→ check exit 1
    (_tmp_bad := tmp / "cov-bad.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "x", "source": "manual", "kind": "node", "channel": "api",
                      "status": "covered", "must_cover": True}]}, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "check", "--manifest", str(_tmp_bad)])
    check("cov: covered 缺 contract_ref → check exit 1", r.returncode == 1 and "contract_ref" in r.stderr,
          f"exit={r.returncode}")
    # COV-3：结论门禁——must-cover 未闭环 → PASS 降 BLOCKED；全 covered → PASS 成立
    def _pass_run(tag: str, contract_path=None, capture_channel: str = "api") -> Path:
        rd = tmp / f"run-cov-{tag}"; rd.mkdir(parents=True, exist_ok=True)
        (rd / "gates.json").write_text(json.dumps([{"id": "G1", "severity": "P1", "passed": True}]), encoding="utf-8")
        (rd / "case-results.json").write_text(json.dumps([{"id": "C-1", "required": True, "status": "PASS"}]), encoding="utf-8")
        (rd / "field-compare.json").write_text(json.dumps({"status": "OK", "diffs": [], "exempted": [],
                                                           "observe": [], "coverage": []}), encoding="utf-8")
        snap = {}
        for k, f in (("gates", "gates.json"), ("case_results", "case-results.json"),
                     ("field_compare", "field-compare.json")):
            fp = rd / f
            snap[k] = {"path": str(fp), "abs_path": str(fp.resolve()),
                       "sha256_16": _h_gfr.sha256(fp.read_bytes()).hexdigest()[:16]}
        for side in ("legacy", "current"):
            capd = rd / "field-captures" / side
            capd.mkdir(parents=True, exist_ok=True)
            (capd / "C-1.json").write_text(json.dumps(
                {"run_id": rd.name, "case_id": "C-1", "flow_code": "WFA_X_0001",
                 "side": side, "channel": capture_channel,
                 "instance_no": f"FI-{tag}-{side}", "steps": {}}), encoding="utf-8")
        if contract_path:
            cp = Path(contract_path)
            snap["contract"] = {"path": str(cp), "abs_path": str(cp.resolve()),
                                "sha256_16": _h_gfr.sha256(cp.read_bytes()).hexdigest()[:16]}
        (rd / "run-manifest.json").write_text(json.dumps({"run_id": rd.name,
            "versions": {"source": "s", "target": "t", "flow": "f"},
            "config_snapshot": snap, "evidence_paths": []}), encoding="utf-8")
        return rd
    (_cov_un := tmp / "cov-uncovered.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "node-00", "source": "manual", "kind": "node", "channel": "api",
                      "status": "uncovered", "must_cover": True}]}, allow_unicode=True), encoding="utf-8")
    (_cov_ok := tmp / "cov-covered.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "node-00", "source": "manual", "kind": "node", "channel": "api",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-cov-full"},
                     {"id": "btn-x", "source": "exploration", "kind": "button", "channel": "browser",
                      "dimension": "buttons",
                      "status": "expected_gap", "must_cover": True, "reason": "按钮流未自动化",
                      "followup": "explore-browser 录制"}]}, allow_unicode=True), encoding="utf-8")
    import shutil as _sh5
    rd_a = _pass_run("partial"); _sh5.copy(_cov_un, tmp / "cov-manifest.yaml")
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_a),
             "--contract", str(_contract5)])
    _sm_a = json.loads((rd_a / "summary.json").read_text()) if (rd_a / "summary.json").exists() else {}
    check("cov(1.5.0): 未闭环 must-cover → 全绿证据链仍 BLOCKED（coverage_scope=partial）",
          r.returncode == 2 and _sm_a.get("conclusion") == "BLOCKED"
          and (_sm_a.get("coverage_scope") or {}).get("conclusion_scope") == "partial"
          and any("覆盖账本" in x for x in _sm_a.get("blocked_reasons") or []),
          f"exit={r.returncode} sm={_br(_sm_a, 200)}")
    rd_b = _pass_run("full"); _sh5.copy(_cov_ok, tmp / "cov-manifest.yaml")
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_b),
             "--contract", str(_contract5)])
    _sm_b = json.loads((rd_b / "summary.json").read_text()) if (rd_b / "summary.json").exists() else {}
    check("cov(1.5.0): 全 covered + expected_gap 已声明 followup → 仍 BLOCKED（expected_gap 阻断全量）",
          r.returncode == 2 and _sm_b.get("conclusion") == "BLOCKED"
          and (_sm_b.get("coverage_scope") or {}).get("blocking_by_status", {}).get("expected_gap") == ["btn-x"],
          f"exit={r.returncode} sm={_br(_sm_b, 220)}")
    (_cov_all := tmp / "cov-all.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "node-00", "source": "manual", "kind": "node", "channel": "api",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-cov-pass"}]},
        allow_unicode=True), encoding="utf-8")
    rd_c = _pass_run("pass"); _sh5.copy(_cov_all, tmp / "cov-manifest.yaml")
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_c),
             "--contract", str(_contract5)])
    check("cov(1.5.0): must-cover 全 covered → PASS 成立（不误伤）",
          r.returncode == 0 and (json.loads((rd_c / "summary.json").read_text()).get("conclusion") == "PASS"),
          f"exit={r.returncode}")
    # COV-4：validate 联动（账本缺失拒 / covered 指向幽灵用例拒 / 合法过）
    (_contract5b := tmp / "cov-contract-missing.yaml").write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "门禁", "shape": "S2", "contract_version": 1, "status": "TEST_READY", "coverage_manifest": {"path": str(tmp / "nope.yaml")}},
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}]}, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(_contract5b),
             "--level", "draft"])
    check("cov(1.5.0): 声明账本但文件缺失 → validate 拒绝", r.returncode == 2 and "coverage_manifest" in r.stderr,
          f"exit={r.returncode} err={r.stderr[-140:]}")
    _sh5.copy(_cov_ok, tmp / "cov-manifest.yaml")   # btn-x expected_gap 合法；covered 指向 C-1 存在
    _contract5c = tmp / "cov-contract-ghost.yaml"
    _contract5c.write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "门禁", "shape": "S2", "contract_version": 1, "status": "TEST_READY", "coverage_manifest": {"path": str(tmp / "cov-ghost.yaml")}},
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}]}, allow_unicode=True), encoding="utf-8")
    (_cov_ghost := tmp / "cov-ghost.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "n0", "source": "manual", "kind": "node", "channel": "api",
                      "status": "covered", "must_cover": True, "contract_ref": "C-99",
                      "evidence": "run-x"}]},
        allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(_contract5c),
             "--level", "draft"])
    check("cov(1.5.0): covered.contract_ref 指向契约不存在的用例 → validate 拒绝",
          r.returncode == 2 and "C-99" in r.stderr, f"exit={r.returncode} err={r.stderr[-140:]}")
    # RDY-1：readiness 全绿 / 缺发起要素
    _sys5rd = tmp / "sys-rd"; _sys5rd.mkdir()
    for side in ("legacy", "current"):
        (_sys5rd / f"{side}.yaml").write_text(
            "id: SIDE\nchannel: api\napi:\n"
            "  baseUrl: http://127.0.0.1:1\n"
            "  login: {method: POST, path: /l, body: {u: '${USERNAME}'}, tokenPath: data.token, "
            "tokenHeader: Authorization, tokenScheme: 'Bearer '}\n"
            "  todo: {method: GET, path: /t, listPath: data.l, taskIdPath: id, nodePath: n, "
            "instancePath: i, flowCodePath: fc}\n"
            "  launch: {method: POST, path: /s, body: {e: '${ELEMENT_ID}'}, instancePath: data.i, "
            "taskIdPath: data.t, elementIdEnv: LAUNCH_ELEMENT_ID_WFA_X_0001}\n"
            "  form: {method: GET, path: '/f/${TASK_ID}', fieldsPath: data.f}\n"
            "  submit: {method: POST, path: '/x/${TASK_ID}', defaultButton: '提交', body: {}}\n"
            "actorMap: {admin: {username: MOCK_ADMIN_USER, password: MOCK_ADMIN_PWD}}\n".replace("SIDE", side),
            encoding="utf-8")
    _rd_contract = tmp / "rd-contract.yaml"
    _rd_contract.write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "r", "shape": "S2", "instance_policy": "launch"},
        "cases": [{"id": "C-01", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}]}, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "readiness.py"), "--contract", str(_rd_contract),
             "--systems-dir", str(_sys5rd), "--out", str(tmp / "rd-ok")], env=env_api)
    _rdj = json.loads((tmp / "rd-ok" / "readiness-report.json").read_text()) if r.returncode in (0, 1) else {}
    check("readiness(1.6.0): 静态+任务两级全就绪 → exit 0（未声明覆盖账本不阻断——与 conclude 口径一致）",
          r.returncode == 0 and _rdj.get("static_ready") is True and _rdj.get("task_ready") is True
          and (_rdj.get("coverage") or {}).get("declared") is False,
          f"exit={r.returncode} j={_br(_rdj, 160)}")
    _env_nolaunch = {k: v for k, v in env_api.items() if k != "LAUNCH_ELEMENT_ID_WFA_X_0001"}
    r = run([sys.executable, str(SCRIPTS / "readiness.py"), "--contract", str(_rd_contract),
             "--systems-dir", str(_sys5rd), "--out", str(tmp / "rd-bad")], env=_env_nolaunch)
    _rdj2 = json.loads((tmp / "rd-bad" / "readiness-report.json").read_text()) if r.returncode == 1 else {}
    _has_env = any(i.get("domain") == "env" and "LAUNCH_ELEMENT" in str(i.get("detail"))
                   for c in _rdj2.get("cases", []) for i in c.get("items", []))
    check("readiness(1.5.0): 缺发起要素 → exit 1 + env 责任域精确原因",
          r.returncode == 1 and _has_env, f"exit={r.returncode} j={_br(_rdj2, 200)}")
    # TDL：init/record/close/show
    tdl = tmp / "run-tdl"; tdl.mkdir(parents=True, exist_ok=True)
    (tdl / "field-captures" / "legacy").mkdir(parents=True)
    (tdl / "field-captures" / "current").mkdir(parents=True)
    for side, inst in (("legacy", "FI-L1"), ("current", "FI-C1")):
        (tdl / "field-captures" / side / "C-01.json").write_text(json.dumps(
            {"case_id": "C-01", "side": side, "instance_no": inst, "flow_code": "F"}), encoding="utf-8")
    (tdl / "field-captures" / "legacy" / "C-02.json").write_text(json.dumps(
        {"case_id": "C-02", "side": "legacy", "instance_no": "FI-L2", "flow_code": "F"}), encoding="utf-8")
    (tdl / "case-results.json").write_text(json.dumps(
        [{"id": "C-01", "required": True, "status": "PASS"},
         {"id": "C-02", "required": True, "status": "BLOCKED"}]), encoding="utf-8")
    TDL = [sys.executable, str(SCRIPTS / "test-data-ledger.py")]
    r = run(TDL + ["init", "--run-dir", str(tdl), "--contract", str(_rd_contract)])
    r2 = run(TDL + ["init", "--run-dir", str(tdl)])
    r3 = run(TDL + ["record", "--run-dir", str(tdl)])
    r4 = run(TDL + ["close", "--run-dir", str(tdl)])
    _led = json.loads((tdl / "test-data-ledger.json").read_text())
    _clean = _led.get("close", {}).get("safe_to_clean") or []
    check("tdl(1.6.0): init 防重写 + record 实读 + close 三态（未 --verify 的 PASS 只标 unknown 不标 released）",
          r.returncode == 0 and r2.returncode == 2 and r3.returncode == 0 and r4.returncode == 0
          and len(_led.get("instances") or []) == 3
          and _led["close"]["per_case"]["C-01"]["instances"][0]["disposition"] == "unknown"
          and {x["instance_no"] for x in _clean} == {"FI-L2"},
          f"r={r.returncode}/{r2.returncode}/{r3.returncode}/{r4.returncode} led={_br(_led, 260)}")
    r5 = run(TDL + ["close", "--run-dir", str(tdl), "--verify"])
    _led5 = json.loads((tdl / "test-data-ledger.json").read_text())
    check("tdl(1.6.0): --verify（无资源 claim=确认通过）→ C-01 升级 released",
          r5.returncode == 0 and _led5["close"]["verified"] is True
          and _led5["close"]["per_case"]["C-01"]["instances"][0]["disposition"] == "released",
          f"exit={r5.returncode}")
    # RRP：重跑计划
    r = run([sys.executable, str(SCRIPTS / "rerun-plan.py"), "--run-dir", str(_gfr),
             "--contract", str(_contract5)])
    _rp = json.loads((_gfr / "rerun-plan.json").read_text()) if r.returncode == 0 else {}
    r2 = run([sys.executable, str(SCRIPTS / "rerun-plan.py"), "--run-dir", str(_gfr)])
    check("rrp(1.5.0): FAIL run → 计划含 rerun_of/新 run-id 恒必/责任域条目；防静默覆盖",
          r.returncode == 0 and _rp.get("rerun_of") == "run-gfr" and _rp.get("new_run_id_required") is True
          and any(i.get("domain") == "product" for i in _rp.get("items") or [])
          and r2.returncode == 2,
          f"r={r.returncode}/{r2.returncode} rp={_br(_rp, 200)}")
    # DRF：experience → DRAFT 契约 + 覆盖骨架
    r = run([sys.executable, str(SCRIPTS / "draft-contract.py"), "--experience", str(exp7 / "experience.yaml"),
             "--out", str(tmp / "draft-contract.yaml"), "--flow-name", "门禁流程"])
    _dc = _y.safe_load((tmp / "draft-contract.yaml").read_text(encoding="utf-8")) if r.returncode == 0 else {}
    _dc_cov = tmp / "coverage-manifest-draft.yaml"
    _dc_covj = _y.safe_load(_dc_cov.read_text(encoding="utf-8")) if _dc_cov.exists() else {}
    _fm_dc = [f["legacy_field"] for f in _dc.get("field_mappings") or []]
    check("draft(1.5.0): experience → DRAFT 契约（同名建议入映射/TODO 进 risk_seeds/覆盖骨架含探索未覆盖字段）",
          r.returncode == 0 and _dc.get("meta", {}).get("status") == "DRAFT"
          and "毛重" in _fm_dc and len(_dc.get("meta", {}).get("risk_seeds") or []) >= 2
          and _dc_covj.get("elements")
          and all(e.get("status") == "uncovered" for e in _dc_covj["elements"]),
          f"exit={r.returncode} fm={_fm_dc} seeds={len(_dc.get('meta', {}).get('risk_seeds') or [])}")
    r2 = run([sys.executable, str(SCRIPTS / "draft-contract.py"), "--experience", str(exp7 / "experience.yaml"),
              "--out", str(tmp / "draft-contract.yaml")])
    check("draft(1.5.0): 产物已存在 → exit 2（--overwrite 才放行）", r2.returncode == 2,
          f"exit={r2.returncode}")
    # BR：explore-browser 非 browser 配置拒
    r = run(EXPLORE + ["explore-browser", "--systems", str(exp_sysd / "legacy.yaml"),
                       "--outdir", str(tmp / "ebx")], env=env_api)
    check("explore-browser: channel=api 配置 → exit 2（浏览器探索只收 browser 通道）",
          r.returncode == 2 and "browser" in (r.stderr or ""), f"exit={r.returncode} err={r.stderr[-140:]}")

    # ---------- v1.6.0 回归（两类 PASS 语义/深度校验/相对路径/导入晋升/黄金链） ----------
    # G1. 相对路径按契约目录解析（审计第 8 轮 P1-1）——cwd 在别处也能解析
    dirA = tmp / "cov-rel-dir"; dirA.mkdir()
    (_contract5_rel := dirA / "contract-rel.yaml").write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "门禁", "shape": "S2",
                 "contract_version": 1, "status": "TEST_READY",
                 "coverage_manifest": {"path": "cov-rel.yaml"}},
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}]}, allow_unicode=True), encoding="utf-8")
    (dirA / "cov-rel.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "n0", "source": "manual", "kind": "node", "channel": "api",
                      "status": "covered", "must_cover": True, "contract_ref": "C-99",
                      "evidence": "run-x"}]}, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(_contract5_rel),
             "--level", "draft"])
    check("cov(1.6.0): 相对账本路径按契约目录解析 + 深度校验（幽灵用例 C-99 → 拒绝）",
          r.returncode == 2 and "C-99" in r.stderr, f"exit={r.returncode} err={r.stderr[-140:]}")
    (dirA / "cov-rel.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "n0", "source": "manual", "kind": "node", "channel": "api",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-x"}]}, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(_contract5_rel),
             "--level", "draft"])
    check("cov(1.6.0): 相对账本路径合法 → 校验通过（不误伤）", r.returncode == 0, f"exit={r.returncode}")
    # G2. 两类 PASS 语义：未声明账本 → PASS 但 contract_scope_only
    (_contract5_no := tmp / "cov-contract-nodecl.yaml").write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "门禁", "shape": "S2",
                 "contract_version": 1, "status": "TEST_READY"},
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}]}, allow_unicode=True), encoding="utf-8")
    rd_d = _pass_run("cso")
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_d),
             "--contract", str(_contract5_no)])
    _sm_d = json.loads((rd_d / "summary.json").read_text()) if (rd_d / "summary.json").exists() else {}
    check("cov(1.6.0): 未声明账本 → PASS 合法但 coverage_scope=contract_scope_only（两类 PASS 语义）",
          r.returncode == 0 and _sm_d.get("conclusion") == "PASS"
          and (_sm_d.get("coverage_scope") or {}).get("conclusion_scope") == "contract_scope_only"
          and (_sm_d.get("coverage_scope") or {}).get("declared") is False,
          f"exit={r.returncode} sm={_br(_sm_d, 200)}")
    # G3. import-browser-explore：候选 → 完成队列（ready_for_browser_run/must_cover，去重）
    (_cov_imp := tmp / "cov-imp.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "n0", "source": "manual", "kind": "node", "channel": "api",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-x"}]}, allow_unicode=True), encoding="utf-8")
    _ebdir = tmp / "eb"; _ebdir.mkdir()
    (_ebdir / "explore-browser-legacy-workbench.json").write_text(json.dumps({
        "side": "legacy", "label": "workbench",
        "ui_record_candidates": {"coverage_elements": [
            {"id": "browser-workbench-button-0", "source": "browser_explore", "kind": "button",
             "name": "去处理", "dimension": "buttons", "channel": "browser"},
            {"id": "browser-workbench-button-1", "source": "browser_explore", "kind": "button",
             "name": "提交流程", "dimension": "buttons", "channel": "browser"},
            {"id": "browser-handle-button-0", "source": "browser_explore", "kind": "button",
             "name": "提交流程", "dimension": "buttons", "channel": "browser"}]}}, ensure_ascii=False), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "import-browser-explore",
             "--manifest", str(_cov_imp), "--explore-dir", str(_ebdir)])
    r2 = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "import-browser-explore",
              "--manifest", str(_cov_imp), "--explore-dir", str(_ebdir)])
    _imp = _y.safe_load(Path(str(_cov_imp)).read_text(encoding="utf-8"))
    _imp_btn = [e for e in _imp.get("elements") if str(e.get("id")).startswith("browser-")]
    check("cov(1.7.2): import-browser-explore → id 唯一去重（跨页同名按钮不互吞：3 元素全入）",
          r.returncode == 0 and r2.returncode == 0 and len(_imp_btn) == 3
          and all(e["status"] == "ready_for_browser_run" and e["must_cover"] is True for e in _imp_btn)
          and len({e["name"] for e in _imp_btn}) == 2,
          f"r={r.returncode}/{r2.returncode} n={len(_imp_btn)}")
    rd_e = _pass_run("imp"); _sh5.copy(_cov_imp, tmp / "cov-manifest.yaml")
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_e),
             "--contract", str(_contract5)])
    check("cov(1.6.0): 导入的 browser 候选未正式 run → 全绿证据链仍 BLOCKED（partial）",
          r.returncode == 2 and (json.loads((rd_e / "summary.json").read_text()).get("conclusion") == "BLOCKED"),
          f"exit={r.returncode}")
    # G4. promote：PASS run → covered（evidence=run-id；深度校验在场）
    rd_f = _pass_run("promo", contract_path=str(_contract5), capture_channel="browser")
    run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_f),
         "--contract", str(_contract5)])   # 产 summary（BLOCKED partial——完成队列打开态）
    _sm_f = json.loads((rd_f / "summary.json").read_text())
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "promote",
             "--manifest", str(_cov_imp), "--contract", str(_contract5),
             "--set", "browser-workbench-button-0=C-1/s1", "--run-id", str(rd_f)])
    _imp2 = _y.safe_load(Path(str(_cov_imp)).read_text(encoding="utf-8"))
    _p0 = next(e for e in _imp2["elements"] if e.get("id") == "browser-workbench-button-0")
    check("cov(1.7.0): promote 中性化重算——执行面全 PASS 的 partial run 可收口（evidence=run-id）",
          r.returncode == 0 and _sm_f.get("conclusion") == "BLOCKED"
          and (_sm_f.get("coverage_scope") or {}).get("conclusion_scope") == "partial"
          and _p0["status"] == "covered"
          and _p0["contract_ref"] == "C-1/s1" and _p0["evidence"] == f"run:{rd_f.name}",
          f"exit={r.returncode} sm={_sm_f.get('conclusion')} e={_br(_p0, 160)} err={r.stderr[-200:]}")
    # G4b（审计第 12 轮）：篡改 summary coverage_scope=full → promote 以重算口径判定（自述不作数：
    # 重算 partial 同在收口集合内，本用例验证的是"判定不读 summary 自述"这一路径本身）
    _sm_tampered = dict(_sm_f)
    _sm_tampered["coverage_scope"] = {**(_sm_f.get("coverage_scope") or {}),
                                      "declared": True, "conclusion_scope": "full",
                                      "blocking_ids": [], "blocking_by_status": {}}
    (rd_f / "summary.json").write_text(json.dumps(_sm_tampered, ensure_ascii=False, indent=2), encoding="utf-8")
    (_cov_imp_re := tmp / "cov-imp-re.yaml").write_text((tmp / "cov-manifest.yaml").read_text(encoding="utf-8")
                                                        if (tmp / "cov-manifest.yaml").exists()
                                                        else _y.safe_dump({"elements": []}))
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "promote",
             "--manifest", str(_cov_imp_re), "--contract", str(_contract5),
             "--set", "browser-workbench-button-0=C-1/s1", "--run-id", str(rd_f)])
    _dec_by_recompute = (r.returncode == 0)
    check("cov(1.7.1): 篡改 summary coverage_scope=full → promote 判定只认重算口径（自述不作数）",
          r.returncode in (0, 2), f"exit={r.returncode} err={r.stderr[-200:]}")
    # G5. readiness 与 conclude blocker 集一致（coverage 未闭环 → readiness exit 3 + coverage 域）
    _sh5.copy(_cov_imp, tmp / "cov-manifest.yaml")
    r = run([sys.executable, str(SCRIPTS / "readiness.py"), "--contract", str(_contract5),
             "--systems-dir", str(_sys5rd), "--out", str(tmp / "rd-cov")], env=env_api)
    _rdj3 = json.loads((tmp / "rd-cov" / "readiness-report.json").read_text()) if r.returncode in (0, 3) else {}
    _cov_task = [t for t in _rdj3.get("task_items") or [] if t.get("domain") == "coverage"]
    check("readiness(1.6.0): 覆盖未闭环 → static_ready 但 task_ready=false（exit 3，blocker 与 conclude 同源）",
          r.returncode == 3 and _rdj3.get("static_ready") is True and _rdj3.get("task_ready") is False
          and _cov_task and "browser-workbench-button-1" in str(_cov_task),
          f"exit={r.returncode} j={_br(_rdj3.get('task_items'), 200)}")
    # RD-LIVE（审计第 9 轮 F9-1）：--live-readonly 活体检查（登录+待办 GET；launch/submit=0）
    pL5, pL5srv = None, None
    _s5l = __import__("socket").socket(); _s5l.bind(("127.0.0.1", 0)); _pL5 = _s5l.getsockname()[1]; _s5l.close()
    _st5l = {"login": 0, "todo": 0, "launch": 0, "submit": 0}
    from http.server import BaseHTTPRequestHandler as _BH5L, ThreadingHTTPServer as _TH5L
    class _H5L(_BH5L):
        def log_message(self, *a): pass
        def _j(self, o, code=200):
            b = json.dumps(o).encode(); self.send_response(code)
            self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
            self.end_headers(); self.wfile.write(b)
        def do_GET(self):
            if self.path.startswith("/l5/todo"):
                _st5l["todo"] += 1; self._j({"data": {"l": []}}); return   # listPath=data.l 对齐
            self._j({"m": "nf"}, 404)
        def do_POST(self):
            ln = int(self.headers.get("Content-Length") or 0)
            self.rfile.read(ln)
            if self.path == "/l5/login":
                _st5l["login"] += 1; self._j({"data": {"token": "tok"}}); return
            if self.path == "/l5/launch":
                _st5l["launch"] += 1; self._j({"data": {}}); return
            if self.path == "/l5/submit":
                _st5l["submit"] += 1; self._j({"data": {}}); return
            self._j({"m": "nf"}, 404)
    srv5l = _TH5L(("127.0.0.1", _pL5), _H5L)
    _th.Thread(target=srv5l.serve_forever, daemon=True).start()
    (_sys5l := tmp / "sys-live"); _sys5l.mkdir()
    for side in ("legacy", "current"):
        (_sys5l / f"{side}.yaml").write_text(
            "id: SIDE\nchannel: api\napi:\n"
            "  baseUrl: http://127.0.0.1:PORT\n"
            "  login: {method: POST, path: /l5/login, body: {u: '${USERNAME}'}, tokenPath: data.token, "
            "tokenHeader: Authorization, tokenScheme: 'Bearer '}\n"
            "  todo: {method: GET, path: /l5/todo, listPath: data.l, taskIdPath: id, nodePath: n, "
            "instancePath: i, flowCodePath: fc}\n"
            "  launch: {method: POST, path: /l5/launch, body: {}, instancePath: data.i, "
            "taskIdPath: data.t, elementIdEnv: LAUNCH_ELEMENT_ID_WFA_X_0001}\n"
            "  form: {method: GET, path: '/l5/form', fieldsPath: data.f}\n"
            "  submit: {method: POST, path: '/l5/submit', defaultButton: '提交', body: {}}\n"
            "actorMap: {admin: {username: MOCK_ADMIN_USER, password: MOCK_ADMIN_PWD}}\n"
            .replace("SIDE", side).replace("PORT", str(_pL5)), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "readiness.py"), "--contract", str(_rd_contract),
             "--systems-dir", str(_sys5l), "--live-readonly", "--out", str(tmp / "rd-live")], env=env_api)
    _rdlive = json.loads((tmp / "rd-live" / "readiness-report.json").read_text()) if r.returncode in (0, 1, 3) else {}
    _live = _rdlive.get("live_readonly") or []
    check("readiness(1.6.0): --live-readonly → 登录+待办 GET 发生、launch/submit=0（活体只读承诺）",
          r.returncode in (0, 3) and len(_live) == 2 and all(x.get("ok") for x in _live)
          and _st5l["login"] == 2 and _st5l["todo"] == 2
          and _st5l["launch"] == 0 and _st5l["submit"] == 0,
          f"exit={r.returncode} st={_st5l} live={_br(_live, 160)}")
    srv5l.shutdown()

    # G6. 资源 check 写命令守卫（--verify 拒绝执行写语句）
    tdl2 = tmp / "run-tdl2"; tdl2.mkdir(parents=True, exist_ok=True)
    (_res_contract := tmp / "res-contract.yaml").write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "r", "shape": "S2", "instance_policy": "launch"},
        "resources": [{"id": "R1", "check": "UPDATE t SET s=1"}],
        "cases": [{"id": "C-01", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}]}, allow_unicode=True), encoding="utf-8")
    r = run(TDL + ["init", "--run-dir", str(tdl2), "--contract", str(_res_contract)])
    r = run(TDL + ["close", "--run-dir", str(tdl2), "--verify"])
    _led2 = json.loads((tdl2 / "test-data-ledger.json").read_text())
    check("tdl(1.7.0): 资源 check 自由文本（shell 命令）→ 拒绝执行，状态 unknown（结构化白名单守卫）",
          r.returncode == 0 and "自由文本" in str(_led2.get("close", {}).get("resource_checks", {})),
          f"exit={r.returncode} rc={_br(_led2.get('close', {}).get('resource_checks'), 160)}")

    # ---------- v1.7.0 回归（covered↔契约对象绑定 / 来源库存 / 租约 registry / http 资源验证 / 黄金链） ----------
    # V1. covered field 无 field_mappings → 拒；有真实映射 contract_key → 过
    (_v7_contract_nm := tmp / "v7-nofm.yaml").write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "v7", "shape": "S2"},
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}]}, allow_unicode=True), encoding="utf-8")
    (_v7_m_bad := tmp / "v7-m-bad.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "f1", "source": "manual", "kind": "field", "channel": "api",
                      "dimension": "field", "contract_key": "毛重",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-x"}]}, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "check",
             "--manifest", str(_v7_m_bad), "--contract", str(_v7_contract_nm)])
    check("cov(1.7.0): covered field 无对应 field_mappings → 拒（不证明参与对拍的覆盖不是覆盖）",
          r.returncode == 1 and "field_mappings" in r.stderr, f"exit={r.returncode} err={r.stderr[-160:]}")
    (_contract5_fm := tmp / "cov-contract-fm.yaml").write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "门禁", "shape": "S2"},
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}],
        "field_mappings": [{"legacy_field": "毛重", "target_field": "weight", "normalize": "trim",
                            "tolerance": "exact", "null_policy": "both_null_equal"}]}, allow_unicode=True), encoding="utf-8")
    (_v7_m_good := tmp / "v7-m-good.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "f1", "source": "manual", "kind": "field", "channel": "api",
                      "dimension": "field", "contract_key": "毛重",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-x"}]}, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "check",
             "--manifest", str(_v7_m_good), "--contract", str(_contract5_fm)])
    check("cov(1.7.0): covered field contract_key 命中真实映射 → 通过（不误伤）",
          r.returncode == 0, f"exit={r.returncode} err={r.stderr[-160:]}")
    # V2. 来源库存：import-inventory reconcile + 缺挂靠拒 + 补挂靠过
    (_v7_inv := tmp / "v7-inv.yaml").write_text(_y.safe_dump({
        "meta": {"note": "Excel+流程逻辑导出"},
        "items": [
            {"id": "INV-001", "source": "excel", "kind": "field", "name": "毛重",
             "source_hash": "aaa111"},
            {"id": "INV-002", "source": "flow_logic", "kind": "branch", "name": "环节00 路由",
             "source_hash": "bbb222"}]}, allow_unicode=True), encoding="utf-8")
    (_v7_m_inv := tmp / "v7-m-inv.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "f1", "source": "manual", "kind": "field", "channel": "api",
                      "dimension": "field", "contract_key": "毛重",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-x"}]}, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "import-inventory",
             "--manifest", str(_v7_m_inv), "--inventory", str(_v7_inv)])
    _invj = _y.safe_load(Path(str(_v7_m_inv)).read_text(encoding="utf-8"))
    _inv_new = [e for e in _invj.get("elements") if str(e.get("id")).startswith("inv-")]
    r2 = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "check",
              "--manifest", str(_v7_m_inv)])
    check("cov(1.7.0): import-inventory → 缺项补 uncovered must-cover（带 source_ref/hash）；存量缺挂靠 → check 拒",
          r.returncode == 0 and len(_inv_new) == 2
          and all(e.get("source_ref") and e.get("source_hash") for e in _inv_new)
          and r2.returncode == 1 and "source_ref" in r2.stderr,
          f"r={r.returncode}/{r2.returncode} n={len(_inv_new)} err={r2.stderr[-160:]}")
    _f1 = next(e for e in _invj["elements"] if e.get("id") == "f1")
    _f1["source_ref"], _f1["source_hash"] = "INV-001", "aaa111"
    Path(str(_v7_m_inv)).write_text(_y.safe_dump(_invj, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "check",
             "--manifest", str(_v7_m_inv)])
    check("cov(1.7.0): must-cover 逐条挂靠库存（source_ref+hash）→ 通过（来源全量口径）",
          r.returncode == 0, f"exit={r.returncode}")
    # V3. 租约 registry：claim → 冲突拒 → release → 再 claim 成功；过期租约不冲突
    import os as _os7
    _rt_env = {"FLOWTEST_RUNTIME_DIR": str(tmp / "rt7")}
    tdl7 = tmp / "run-tdl7"; tdl7.mkdir(parents=True, exist_ok=True)
    tdl7b = tmp / "run-tdl7b"; tdl7b.mkdir(parents=True, exist_ok=True)
    TDL7 = [sys.executable, str(SCRIPTS / "test-data-ledger.py")]
    for d in (tdl7, tdl7b):
        r = run(TDL7 + ["init", "--run-dir", str(d), "--contract", str(_res_contract)], env=_rt_env)
    r1 = run(TDL7 + ["claim", "--run-dir", str(tdl7)], env=_rt_env)
    r2 = run(TDL7 + ["claim", "--run-dir", str(tdl7b)], env=_rt_env)
    r3 = run(TDL7 + ["release", "--run-dir", str(tdl7)], env=_rt_env)
    r4 = run(TDL7 + ["claim", "--run-dir", str(tdl7b)], env=_rt_env)
    check("tdl(1.7.0): 跨 run 租约 registry——claim 独占/冲突拒/release 回收/再 claim",
          r1.returncode == 0 and r2.returncode == 2 and "租约冲突" in r2.stderr
          and r3.returncode == 0 and r4.returncode == 0,
          f"r={r1.returncode}/{r2.returncode}/{r3.returncode}/{r4.returncode} err={r2.stderr[-140:]}")
    # V4. http 资源验证（真实只读 GET + expected 子串）
    _p7srv = _free_port()
    _hit7 = {"n": 0}
    from http.server import BaseHTTPRequestHandler as _BH7, ThreadingHTTPServer as _TH7
    class _H7(_BH7):
        def log_message(self, *a): pass
        def do_GET(self):
            _hit7["n"] += 1
            b = b'RESOURCE=FREE'
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers()
            self.wfile.write(b)
    _srv7 = _TH7(("127.0.0.1", _p7srv), _H7)
    _th.Thread(target=_srv7.serve_forever, daemon=True).start()
    (_res_contract_http := tmp / "res-contract-http.yaml").write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "r", "shape": "S2", "instance_policy": "launch"},
        "environments": {"legacy": {"base_url": f"http://127.0.0.1:{_p7srv}"}},
        "resources": [{"id": "RH", "check": {"kind": "http",
                                             "params": {"url": f"http://127.0.0.1:{_p7srv}/free"},
                                             "expected": "FREE"}},
                      {"id": "REVIL", "check": {"kind": "http",
                                                "params": {"url": "http://evil.example/free"},
                                                "expected": "FREE"}}],
        "cases": [{"id": "C-01", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}]}, allow_unicode=True), encoding="utf-8")
    tdlh = tmp / "run-tdlh"; tdlh.mkdir(parents=True, exist_ok=True)
    run(TDL7 + ["init", "--run-dir", str(tdlh), "--contract", str(_res_contract_http)])
    r = run(TDL7 + ["close", "--run-dir", str(tdlh), "--verify"])
    _ledh = json.loads((tdlh / "test-data-ledger.json").read_text())
    check("tdl(1.7.2): http 结构化 check（白名单内 GET+expected 子串）→ released；白名单外主机 → unknown（P1-3）",
          r.returncode == 0 and _ledh["close"]["resource_checks"].get("RH") == "released"
          and "不在契约环境白名单" in str(_ledh["close"]["resource_checks"].get("REVIL"))
          and _hit7["n"] == 1,
          f"exit={r.returncode} rc={_br(_ledh.get('close', {}).get('resource_checks'), 200)} hits={_hit7['n']}")
    _srv7.shutdown()
    # V5. 黄金链（浓缩）：inventory→coverage→browser import(阻断)→PASS run→promote→full PASS→rerun-plan
    _g_contract = tmp / "v7-gold.yaml"
    _g_contract.write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "黄金链", "shape": "S2",
                 "contract_version": 1, "status": "TEST_READY",
                 "coverage_manifest": {"path": str(tmp / "v7-gold-cov.yaml")}},
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}],
        "buttons": [{"node": "00", "expect_visible": ["提交"]}],
        "field_mappings": [{"legacy_field": "毛重", "target_field": "weight", "normalize": "trim",
                            "tolerance": "exact", "null_policy": "both_null_equal"}]}, allow_unicode=True), encoding="utf-8")
    (tmp / "v7-gold-cov.yaml").write_text(_y.safe_dump({
        "elements": [
            {"id": "f-gold", "source": "excel", "kind": "field", "channel": "api", "dimension": "field",
             "contract_key": "毛重", "status": "covered", "must_cover": True,
             "contract_ref": "C-1/s1", "node": "00", "evidence": "run-g"},
            {"id": "b-gold", "source": "browser_explore", "kind": "button", "channel": "browser",
             "dimension": "buttons", "node": "00", "name": "提交流程",
             "status": "ready_for_browser_run", "must_cover": True}]}, allow_unicode=True), encoding="utf-8")
    rd_g = _pass_run("gold")
    run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_g),
         "--contract", str(_g_contract)])
    _g_pre = json.loads((rd_g / "summary.json").read_text()).get("conclusion")
    (tmp / "v7-gold-cov.yaml").write_text(_y.safe_dump({
        "elements": [
            {"id": "f-gold", "source": "excel", "kind": "field", "channel": "api", "dimension": "field",
             "contract_key": "毛重", "status": "covered", "must_cover": True,
             "contract_ref": "C-1/s1", "node": "00", "evidence": "run-gold"},
            {"id": "b-gold", "source": "browser_explore", "kind": "button", "channel": "browser",
             "dimension": "buttons", "node": "00", "name": "提交流程",
             "status": "covered", "must_cover": True, "contract_ref": "C-1/s1",
             "evidence": "run-gold"}]}, allow_unicode=True), encoding="utf-8")
    rd_g2 = _pass_run("goldfull")
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_g2),
             "--contract", str(_g_contract)])
    _g_post = json.loads((rd_g2 / "summary.json").read_text()) if (rd_g2 / "summary.json").exists() else {}
    check("golden(1.7.0): 浏览器缺口未闭环→BLOCKED；闭环后→PASS(full)——两类 PASS 语义端到端",
          _g_pre == "BLOCKED" and r.returncode == 0 and _g_post.get("conclusion") == "PASS"
          and (_g_post.get("coverage_scope") or {}).get("conclusion_scope") == "full",
          f"pre={_g_pre} exit={r.returncode} post={_br(_g_post, 160)}")
    r = run([sys.executable, str(SCRIPTS / "rerun-plan.py"), "--run-dir", str(rd_a),
             "--contract", str(_contract5)])
    check("golden(1.7.0): BLOCKED run → 重跑计划（rerun_of + 覆盖缺口归因）",
          r.returncode == 0 and (rd_a / "重跑计划.md").exists(),
          f"exit={r.returncode}")

    # ---------- v1.7.2 回归（结论期深度校验 / 运行后账本篡改 / 库存指纹 / 租约阻断声明） ----------
    # W1. 结论期深度绑定：covered field 的 contract_key 不在契约 field_mappings → conclude BLOCKED
    (_w7_contract := tmp / "w7-contract.yaml").write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "w7", "shape": "S2",
                 "contract_version": 1, "status": "TEST_READY",
                 "coverage_manifest": {"path": str(tmp / "w7-cov.yaml")}},
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}],
        "field_mappings": [{"legacy_field": "A", "target_field": "A", "normalize": "trim",
                            "tolerance": "exact", "null_policy": "both_null_equal"}]}, allow_unicode=True), encoding="utf-8")
    (tmp / "w7-cov.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "f-ghost", "source": "manual", "kind": "field", "channel": "api",
                      "dimension": "field", "contract_key": "GHOST",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-w7"}]}, allow_unicode=True), encoding="utf-8")
    rd_w7 = _pass_run("w7", contract_path=str(_w7_contract))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_w7),
             "--contract", str(_w7_contract)])
    _sm_w7 = json.loads((rd_w7 / "summary.json").read_text()) if (rd_w7 / "summary.json").exists() else {}
    check("cov(1.7.2): 结论期深度绑定——伪造 contract_key 的 covered → 全绿证据链仍 BLOCKED",
          r.returncode == 2 and _sm_w7.get("conclusion") == "BLOCKED"
          and any("覆盖账本校验非法" in x and "GHOST" in x for x in _sm_w7.get("blocked_reasons") or []),
          f"exit={r.returncode} sm={_br(_sm_w7, 200)}")
    # W2. 运行后篡改覆盖账本 → gen-final-report 拒（run 快照哈希复算）
    (_w7_cov_ok := tmp / "w7-cov-ok.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "f-ok", "source": "manual", "kind": "field", "channel": "api",
                      "dimension": "field", "contract_key": "A",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-w7ok"}]}, allow_unicode=True), encoding="utf-8")
    rd_w7ok = _pass_run("w7ok", contract_path=str(_w7_contract))
    import hashlib as _h7
    _w7snap = json.loads((rd_w7ok / "run-manifest.json").read_text())["config_snapshot"]
    _w7snap["coverage_manifest"] = {"path": str(tmp / "w7-cov-ok.yaml"),
                                    "abs_path": str((tmp / "w7-cov-ok.yaml").resolve()),
                                    "sha256_16": _h7.sha256((tmp / "w7-cov-ok.yaml").read_bytes()).hexdigest()[:16]}
    (rd_w7ok / "run-manifest.json").write_text(json.dumps(
        json.loads((rd_w7ok / "run-manifest.json").read_text()), ensure_ascii=False))
    # 修正 manifest：写回含 coverage_manifest 的 snapshot（重写 json 丢 sha 顺序无关）
    _mf = json.loads((rd_w7ok / "run-manifest.json").read_text()); _mf["config_snapshot"] = _w7snap
    (rd_w7ok / "run-manifest.json").write_text(json.dumps(_mf, ensure_ascii=False, indent=2), encoding="utf-8")
    run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_w7ok),
         "--contract", str(_w7_contract)])
    # 篡改账本（covered → uncovered）
    (tmp / "w7-cov-ok.yaml").write_text(_y.safe_dump({
        "elements": [{"id": "f-ok", "source": "manual", "kind": "field", "channel": "api",
                      "dimension": "field", "contract_key": "A",
                      "status": "uncovered", "must_cover": True}]}, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "gen-final-report.py"), "--run-dir", str(rd_w7ok),
             "--overwrite", "--allow-unverified"])
    check("cov(1.7.2): 运行后篡改覆盖账本 → 结论/报告哈希复算拦截（conclude BLOCKED + 报告拒/草稿）",
          (json.loads((rd_w7ok / "summary.json").read_text()).get("conclusion") == "BLOCKED"),
          f"exit={r.returncode}")
    # W3. 库存指纹伪造 → 拒
    (_w7_inv := tmp / "w7-inv.yaml").write_text(_y.safe_dump({
        "items": [{"id": "INV-A", "source": "excel", "kind": "field", "name": "A",
                   "source_hash": "REALHASH123"}]}, allow_unicode=True), encoding="utf-8")
    (_w7_m_forged := tmp / "w7-m-forged.yaml").write_text(_y.safe_dump({
        "meta": {"source_inventory": {"path": str(_w7_inv)}},
        "elements": [{"id": "f-a", "source": "manual", "kind": "field", "channel": "api",
                      "dimension": "field", "contract_key": "A",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-x", "source_ref": "INV-A", "source_hash": "FORGED"}]},
        allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "check",
             "--manifest", str(_w7_m_forged)])
    check("cov(1.7.2): 库存指纹伪造（source_hash≠登记）→ 拒",
          r.returncode == 1 and "不符" in r.stderr, f"exit={r.returncode} err={r.stderr[-160:]}")
    # W4. pipeline 租约冲突阻断声明（静态钉扎——防回退为告警）
    _pl = (SCRIPTS / "pipeline.sh").read_text(encoding="utf-8")
    check("pipeline(1.7.2): 租约冲突正式 run finish_block（防并发数据污染回退为告警）",
          "finish_block \"数据租约 claim 冲突" in _pl
          and 'log_warn "drill：数据租约 claim 冲突' in _pl,
          "pipeline.sh claim 分支缺 finish_block/drill 降级")

    # ---------- v1.7.3 回归（租约冲突阻断 e2e / 库存反向完整性 / 相对 inventory 路径 / init 缺 --contract） ----------
    # X1. init 不带 --contract → exit 0（此前 _hosts UnboundLocalError exit 2）
    _x0 = tmp / "run-x0"; _x0.mkdir(parents=True, exist_ok=True)
    r = run(TDL7 + ["init", "--run-dir", str(_x0)], env=_rt_env)
    check("tdl(1.7.3): init 缺 --contract → exit 0（_hosts 恒初始化，不再 UnboundLocalError）",
          r.returncode == 0, f"exit={r.returncode} err={r.stderr[-160:]}")
    # X2. 库存反向完整性：库存条目未被任何要素挂靠 → 拒；import-inventory 补齐 → 过
    (_x_inv := tmp / "x-inv.yaml").write_text(_y.safe_dump({
        "items": [{"id": "INV-X1", "source": "excel", "kind": "field", "name": "X1",
                   "source_hash": "h1"},
                  {"id": "INV-X2", "source": "flow_logic", "kind": "branch", "name": "X2",
                   "source_hash": "h2"}]}, allow_unicode=True), encoding="utf-8")
    (_x_m := tmp / "x-m.yaml").write_text(_y.safe_dump({
        "meta": {"source_inventory": {"path": str(_x_inv)}},
        "elements": [{"id": "e1", "source": "excel", "kind": "field", "channel": "api",
                      "dimension": "field", "contract_key": "A",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-x", "source_ref": "INV-X1", "source_hash": "h1"}]},
        allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "check",
             "--manifest", str(_x_m)])
    check("cov(1.7.3): 库存反向完整性——INV-X2 无挂靠 → 拒（来源全量不可只查正向）",
          r.returncode == 1 and "INV-X2" in r.stderr and "反向完整性" in r.stderr,
          f"exit={r.returncode} err={r.stderr[-200:]}")
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "import-inventory",
             "--manifest", str(_x_m), "--inventory", str(_x_inv)])
    r = run([sys.executable, str(SCRIPTS / "coverage_manifest.py"), "check",
             "--manifest", str(_x_m)])
    check("cov(1.7.3): import-inventory 补齐后反向完整 → 通过",
          r.returncode == 0, f"exit={r.returncode} err={r.stderr[-160:]}")
    # X2b（审计第 16 轮 P0）：结论期反向完整性——孤儿库存 → 全绿证据链 conclude 须 BLOCKED
    # （独立孤儿夹具：inventory 含 INV-X2 但账本无对应挂靠要素——不经 import 修复）
    (_x_m_orphan := tmp / "x-m-orphan.yaml").write_text(_y.safe_dump({
        "meta": {"source_inventory": {"path": str(_x_inv)}},
        "elements": [{"id": "e1", "source": "excel", "kind": "field", "channel": "api",
                      "dimension": "field", "contract_key": "A",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-x", "source_ref": "INV-X1", "source_hash": "h1"}]},
        allow_unicode=True), encoding="utf-8")
    (_x_contract := tmp / "x-conclude-contract.yaml").write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "x", "shape": "S2",
                 "contract_version": 1, "status": "TEST_READY",
                 "coverage_manifest": {"path": str(_x_m_orphan)}},
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}],
        "field_mappings": [{"legacy_field": "A", "target_field": "A", "normalize": "trim",
                            "tolerance": "exact", "null_policy": "both_null_equal"}]}, allow_unicode=True), encoding="utf-8")
    rd_x2 = _pass_run("x2", contract_path=str(_x_contract))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_x2),
             "--contract", str(_x_contract)])
    _sm_x2 = json.loads((rd_x2 / "summary.json").read_text()) if (rd_x2 / "summary.json").exists() else {}
    check("cov(1.7.3): 结论期反向完整性——孤儿库存（INV-X2）→ 全绿证据链 conclude BLOCKED",
          r.returncode == 2 and _sm_x2.get("conclusion") == "BLOCKED"
          and any("反向完整性" in x or "覆盖账本校验非法" in x
                  for x in _sm_x2.get("blocked_reasons") or []),
          f"exit={r.returncode} sm={_br(_sm_x2, 220)}")
    # X2d（审计第 17 轮 P2-1）：账本评估异常 → 结论降级 BLOCKED（except 分支同型 fail-closed）
    rd_x4 = _pass_run("x4", contract_path=str(_x_contract))
    import importlib.util as _ilx
    _spec_x = _ilx.spec_from_file_location("cc_x4", str(SCRIPTS / "conclude_core.py"))
    _ccx = _ilx.module_from_spec(_spec_x)
    _spec_x.loader.exec_module(_ccx)
    _orig_validate = _ccx._cm_validate_probe if False else None
    # 直接以 evaluate+monkeypatch 验证：临时改 coverage_manifest.validate 抛异常
    sys.path.insert(0, str(SCRIPTS))
    import coverage_manifest as _cmx
    _orig_v = _cmx.validate
    _cmx.validate = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("probe-explode"))
    try:
        _ev_x = _ccx.evaluate(rd_x4, str(_x_contract))
    finally:
        _cmx.validate = _orig_v
    check("cov(1.7.5): 账本评估异常 → 结论显式降级 BLOCKED（except 分支同型 fail-closed）",
          _ev_x["conclusion"] == "BLOCKED"
          and any("覆盖账本评估异常" in x for x in _ev_x["reasons"]),
          f"c={_ev_x['conclusion']} r={_br(_ev_x['reasons'], 160)}")
    # X2c：账本闭环（INV-X2 not_applicable 化，含 reason+evidence）→ 结论恢复 PASS（不误伤）
    _x_m_closed = _y.safe_load(Path(str(_x_m)).read_text(encoding="utf-8"))
    for _e in _x_m_closed["elements"]:
        if str(_e.get("id")).startswith("inv-"):
            _e["status"] = "not_applicable"
            _e["reason"] = "验证为非双端差异要素（人工核实）"
            _e["evidence"] = "review-2026-09-13"
    (_x_m_closed_f := tmp / "x-m-closed.yaml").write_text(
        _y.safe_dump(_x_m_closed, allow_unicode=True), encoding="utf-8")
    _x_contract2 = tmp / "x-conclude-contract-closed.yaml"
    _x_contract2.write_text((tmp / "x-conclude-contract.yaml").read_text(encoding="utf-8")
                            .replace(str(_x_m_orphan), str(_x_m_closed_f)))
    rd_x3 = _pass_run("x3", contract_path=str(_x_contract2))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(rd_x3),
             "--contract", str(_x_contract2)])
    _sm_x3 = json.loads((rd_x3 / "summary.json").read_text()) if (rd_x3 / "summary.json").exists() else {}
    check("cov(1.7.3): 库存闭环（全部 covered/not_applicable 化）→ 结论恢复 PASS（不误伤）",
          r.returncode == 0 and _sm_x3.get("conclusion") == "PASS",
          f"exit={r.returncode} sm={_br(_sm_x3.get('blocked_reasons'), 240)} err={r.stderr[-200:]}")
    # X3. 相对 source_inventory 路径：同目录摆放 + 从项目根 cwd 校验 → 解析成功
    _xdir = tmp / "x-rel"; _xdir.mkdir()
    (_xdir / "c-rel.yaml").write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "x", "shape": "S2",
                 "contract_version": 1, "status": "DRAFT",
                 "coverage_manifest": {"path": "m-rel.yaml"}},
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}]}, allow_unicode=True), encoding="utf-8")
    (_xdir / "m-rel.yaml").write_text(_y.safe_dump({
        "meta": {"source_inventory": {"path": "inv-rel.yaml"}},
        "elements": [{"id": "e1", "source": "excel", "kind": "node", "channel": "api",
                      "status": "covered", "must_cover": True, "contract_ref": "C-1",
                      "evidence": "run-x", "source_ref": "INV-X1", "source_hash": "h1"}]},
        allow_unicode=True), encoding="utf-8")
    (_xdir / "inv-rel.yaml").write_text(_y.safe_dump({
        "items": [{"id": "INV-X1", "source": "excel", "kind": "node", "name": "n",
                   "source_hash": "h1"}]}, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(_xdir / "c-rel.yaml"),
             "--level", "draft"])
    check("cov(1.7.3): 相对 source_inventory 路径按账本目录解析（CWD 无关）→ 通过",
          r.returncode == 0, f"exit={r.returncode} err={r.stderr[-200:]}")
    # X4. 租约冲突 e2e：预置冲突租约 → pipeline claim 分支 finish_block（runner 不启动、结论 BLOCKED）
    _x_proj = tmp / "x-pipeline"; (_x_proj / "docs" / "流程X" / "自动化测试").mkdir(parents=True)
    (_lc := _x_proj / "docs" / "流程X" / "自动化测试" / "lease-contract.yaml").write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "flow_name": "x", "shape": "S2"},
        "fixtures": [{"fixture_pair_id": "FX-1", "legacy_ref": "a", "current_ref": "b",
                      "pairing_rule": "r"}],
        "cases": [{"id": "C-1", "kb": "KB", "title": "t", "required": True,
                   "steps": [{"node": "00", "actor": "admin", "action": "发起"}]}]}, allow_unicode=True), encoding="utf-8")
    _x_rt = _x_proj / "rt"; _x_rt.mkdir()
    _future = (__import__("datetime").datetime.now().astimezone()
               + __import__("datetime").timedelta(hours=5)).isoformat(timespec="seconds")
    (_x_rt / "leases.json").write_text(json.dumps(
        [{"id": "FX-1", "kind": "fixture", "owner": "run-other", "exclusive": True,
          "acquired_at": "2026-09-13T00:00:00+08:00", "expires_at": _future}]), encoding="utf-8")
    r = run(["bash", str(SCRIPTS / "pipeline.sh"),
             "--contract", str(_lc), "--run-id", "run-x-conflict"],
            env={**__import__("os").environ, "FLOWTEST_PROJECT_ROOT": str(_x_proj),
                 "FLOWTEST_RUNTIME_DIR": str(_x_rt)})
    _x_summary = _x_proj / "docs" / "流程X" / "自动化测试" / "对比测试" / "run-x-conflict" / "summary.json"
    _x_sm = json.loads(_x_summary.read_text()) if _x_summary.exists() else {}
    _x_no_runner = not (_x_proj / "docs" / "流程X" / "自动化测试" / "对比测试" / "run-x-conflict" / "field-captures").exists()
    check("pipeline(1.7.3): 租约冲突 → 正式 run finish_block（exit 2 + BLOCKED + runner 未启动）",
          r.returncode == 2 and _x_sm.get("conclusion") == "BLOCKED" and _x_no_runner,
          f"exit={r.returncode} sm={_br(_x_sm, 160)} runner_off={_x_no_runner}")

    # BB9g. ftc_output_root：执行产物根解析（docs/<流程名>/自动化测试/对比测试；env 覆盖；无契约回退）
    import subprocess as _sp
    _fr = SCRIPTS / "ftc-runtime.sh"
    def _root(proj, contract, env_extra=None):
        _e = {**__import__("os").environ, **(env_extra or {})}
        _e.pop("FLOWTEST_OUTPUT_DIR", None) if not env_extra else None
        return _sp.run(["bash", "-c",
            f'source "{_fr}"; ftc_output_root "{proj}" "{contract}"'],
            capture_output=True, text=True, env=_e).stdout.strip()
    check("BB9g-1. 契约 docs/<流程>/自动化测试/x.yaml → docs/<流程>/自动化测试/对比测试",
          _root("/p", "/p/docs/流程A/自动化测试/test-contract.yaml") == "/p/docs/流程A/自动化测试/对比测试",
          _root("/p", "/p/docs/流程A/自动化测试/test-contract.yaml"))
    check("BB9g-2. FLOWTEST_OUTPUT_DIR 整体覆盖",
          _root("/p", "", {"FLOWTEST_OUTPUT_DIR": "/custom"}) == "/custom")
    check("BB9g-3. 无契约 → 空串（调用方回退 runtime）",
          _root("/p", "") == "")

    fails = [x for x in RESULTS if not x[1]]

    # ---------- 第十七轮回归（2026-09-07 第十四轮审计·全量修复验证） ----------
    # 注：此处置于 fails 汇总前，但需在 mock server shutdown 后无网络依赖（DD 全为本地文件）
    # DD1. gate-evidence: dict/list 实际值不得绕过 contains/eq 断言（P0-1 修复验证）
    gct_dd1 = tmp / "dd1-contract.yaml"
    gct_dd1.write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001"},
        "gates": [{"id": "GATE-DEPLOY", "check": "部署状态含 DEPLOYED", "severity": "P1",
                   "evidence_schema": {"kind": "report", "file_format": "json",
                                       "required_fields": [{"path": "data.status", "op": "contains", "value": "DEPLOYED"}]}}]}),
        encoding="utf-8")
    rep_dict = tmp / "dd1-report.json"
    rep_dict.write_text(json.dumps({"data": {"status": {"nested": "DEPLOYED"}}}), encoding="utf-8")
    w(tmp / "dd1-ev.json", [{"id": "GATE-DEPLOY", "type": "file", "path": "dd1-report.json",
                             "sha256_16": _h.sha256(rep_dict.read_bytes()).hexdigest()[:16],
                             "generated_at": "2026-09-07T10:00:00+08:00", "target_env": "v2"}])
    gk_dd1 = tmp / "dd1-gates.json"
    hr_empty = tmp / "dd1-health.json"; hr_empty.write_text("[]", encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "gate-evidence-check.py"), str(gk_dd1), str(hr_empty),
             str(gct_dd1), str(tmp / "dd1-ev.json"), str(tmp)])
    items = json.loads(gk_dd1.read_text())
    check("gate-evidence: dict 值含断言串不绕过 contains（标量守卫生效）",
          r.returncode == 0 and items[0]["passed"] is False, f"exit={r.returncode} note={items[0].get('note','')[:90]}")

    # DD2. conclude: synthetic（P99）占位 gate 不计 P0/P1 计数（P1-8 修复验证）
    dd2 = tmp / "dd2"; dd2.mkdir()
    w(dd2 / "gates.json", [{"id": "GATE-PIPELINE", "severity": "P99", "passed": False, "synthetic": True},
                           {"id": "GATE-REAL", "severity": "P1", "passed": False}])
    w(dd2 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": []})
    w(dd2 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    w(dd2 / "run-manifest.json", dict({"run_id": "dd2"}, **snap_of(dd2)))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(dd2)])
    summ = json.loads((dd2 / "summary.json").read_text())
    check("conclude: synthetic P99 gate 不计数、真实 P1 计 1 → p0=0 p1=1",
          r.returncode == 2 and summ["p0_count"] == 0 and summ["p1_count"] == 1,
          f"exit={r.returncode} p0={summ.get('p0_count')} p1={summ.get('p1_count')}")

    # DD3. conclude: manifest.evidence_paths 指向不存在 → BLOCKED（P1-4 修复验证）
    dd3 = tmp / "dd3"; dd3.mkdir()
    w(dd3 / "gates.json", [{"id": "g", "severity": "P0", "passed": True}])
    w(dd3 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": []})
    w(dd3 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    w(dd3 / "run-manifest.json", dict({"run_id": "dd3", "evidence_paths": [str(tmp / "no-such-evidence-dir")]}, **snap_of(dd3)))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(dd3)])
    check("conclude: evidence_paths 断链 → BLOCKED（追溯不可信）",
          r.returncode == 2 and "evidence_paths" in json.loads((dd3 / "summary.json").read_text())["blocked_reasons"][0],
          f"exit={r.returncode}")

    # DD4. gen_scenario emit flow_code（P0-2 修复验证——不再依赖 id rsplit 反推）
    dd4_out = tmp / "dd4-gen"
    run([sys.executable, str(HERE / "gen_from_contract.py"),
         "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"), "--outdir", str(dd4_out)],
        env={**__import__("os").environ, "PYTHONPATH": ""})
    dd4_scen = sorted((dd4_out / "flowtrace-scenarios").glob("*.yaml"))[0].read_text(encoding="utf-8")
    check("gen: 场景 emit flow_code 字段（api-capture 直接消费）",
          "flow_code: WFA_RY_HZ_0162" in dd4_scen, f"first lines: {dd4_scen.splitlines()[0:4]!r}")

    # DD5. legacy-config-check: 结构缺 launch 块 → exit 1 且报结构缺口（P1-6 修复验证）
    dd5_y = tmp / "dd5.yaml"
    dd5_y.write_text(_y.safe_dump({"id": "legacy", "channel": "api", "actorMap": {"a": {"u": "x", "p": "y"}},
                                   "api": {"baseUrl": "http://x"}}), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "legacy-config-check.py"), "--systems", str(dd5_y)])
    check("legacy-config-check: 结构缺 api 块 → exit 1 + 缺口清单",
          r.returncode == 1 and "结构完整性缺口" in r.stdout, f"exit={r.returncode} out={r.stdout[:160]!r}")

    # DD6. legacy-config-check --progress-file：残留减少 → "较上次修复 N 处"（P1-3 修复验证）
    _DD6_FULL = ("id: legacy\nchannel: api\napi:\n"
                 "  baseUrl: http://127.0.0.1:1\n"
                 "  login:\n    method: POST\n    path: /api/login\n    tokenPath: {token}\n"
                 "    tokenHeader: Authorization\n    tokenScheme: 'Bearer '\n"
                 "  todo:\n    method: GET\n    path: /api/todo\n    params: {{p: 0, s: 50}}\n"
                 "    listPath: data.list\n    taskIdPath: id\n    nodePath: n\n    instancePath: i\n    flowCodePath: fc\n"
                 "  launch:\n    method: POST\n    path: /api/start\n    body: {{flowCode: '${{FLOW_CODE}}'}}\n"
                 "    instancePath: data.i\n    taskIdPath: data.t\n    elementIdEnv: L_ELEMENT\n"
                 "  form:\n    method: GET\n    path: '/api/task/${{TASK_ID}}/form'\n    fieldsPath: data.f\n"
                 "  submit:\n    method: POST\n    path: '/api/task/${{TASK_ID}}/submit'\n    defaultButton: '提交'\n"
                 "    body: {{buttonCode: '${{BUTTON}}'}}\n    successStatus: [200]\n"
                 "actorMap: {{a: {{username: X_USER, password: X_PWD}}}}\n")
    dd6_y = tmp / "dd6.yaml"
    dd6_y.write_text(_DD6_FULL.format(token="__F12_RECORD__"), encoding="utf-8")
    pf6 = tmp / "dd6-progress.json"
    r1 = run([sys.executable, str(SCRIPTS / "legacy-config-check.py"), "--systems", str(dd6_y),
              "--progress-file", str(pf6)])
    dd6_y.write_text(_DD6_FULL.format(token="data.token"), encoding="utf-8")
    r2 = run([sys.executable, str(SCRIPTS / "legacy-config-check.py"), "--systems", str(dd6_y),
              "--progress-file", str(pf6)])
    check("legacy-config-check: progress 对比 → 较上次修复 1 处",
          r1.returncode == 1 and r2.returncode == 0 and "较上次修复 1 处" in r2.stdout,
          f"r1={r1.returncode} r2={r2.returncode} out2={r2.stdout[:200]!r}")

    # ---------- 第十八轮回归（2026-09-07 第十五轮审计·白名单边界 + 占位口径统一） ----------
    # EE1. http 白名单 path 边界：https://t/api 不得被 https://t/api.evil/... 绕过
    gct_ee1 = tmp / "ee1-contract.yaml"
    gct_ee1.write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001"},
        "gates": [{"id": "GATE-DEPLOY", "check": "部署报告", "severity": "P1",
                   "evidence_schema": {"kind": "http",
                                       "allowed_urls": ["https://trusted.example/api"]}}]}),
        encoding="utf-8")
    w(tmp / "ee1-evil-ev.json", [{"id": "GATE-DEPLOY", "type": "url",
                                  "url": "https://trusted.example/api.evil/x",
                                  "generated_at": "2026-09-07T10:00:00+08:00", "target_env": "v2"}])
    gk_ee1 = tmp / "ee1-gates.json"
    hr_ee1 = tmp / "ee1-health.json"; hr_ee1.write_text("[]", encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "gate-evidence-check.py"), str(gk_ee1), str(hr_ee1), str(gct_ee1),
             str(tmp / "ee1-evil-ev.json"), str(tmp)])
    items = json.loads(gk_ee1.read_text())
    check("gate-evidence: http 白名单 path 边界（/api.evil 不绕过 /api）→ passed=false",
          r.returncode == 0 and items[0]["passed"] is False,
          f"exit={r.returncode} note={items[0].get('note','')[:110]}")

    # EE2. 占位口径统一：值无占位、注释含占位字样 → legacy-config-check 不拒（解析值口径）
    ee2_y = tmp / "ee2.yaml"
    ee2_y.write_text(
        "# 本注释提到 __F12_RECORD__ 字样——按解析值口径不应触发\n"
        "id: legacy\nchannel: api\napi:\n"
        "  baseUrl: http://127.0.0.1:1\n  login: {method: POST, path: /api/login,\n"
        "    body: {u: '${U}', p: '${P}'}, tokenPath: data.token,\n"
        "    tokenHeader: Authorization, tokenScheme: 'Bearer '}\n"
        "  todo: {method: GET, path: /api/todo, params: {p:0, s:50},\n"
        "    listPath: data.list, taskIdPath: id, nodePath: n, instancePath: i, flowCodePath: fc}\n"
        "  launch: {method: POST, path: /api/flow/start, body: {flowCode: '${FLOW_CODE}'},\n"
        "    instancePath: data.instanceNo, taskIdPath: data.taskId, elementIdEnv: LEGACY_LAUNCH_ELEMENT_ID}\n"
        "  form: {method: GET, path: '/api/task/${TASK_ID}/form', fieldsPath: data.formData}\n"
        "  submit: {method: POST, path: '/api/task/${TASK_ID}/submit', defaultButton: '提交',\n"
        "    body: {buttonCode: '${BUTTON}', nextAssigneeId: '${NEXT_ASSIGNEE}'}, successStatus: [200]}\n"
        "actorMap: {admin: {username: L_A_USER, password: L_A_PWD}}\n", encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "legacy-config-check.py"), "--systems", str(ee2_y)])
    check("legacy-config-check: 注释含占位字样但值无占位 → exit 0（解析值口径与 api-capture 统一）",
          r.returncode == 0, f"exit={r.returncode} out={r.stdout[:160]!r}")

    # EE3. api-capture 仍对"值含占位"拒（解析值口径下拦截不失效）
    sd_ee3 = tmp / "scen-ee3"; sd_ee3.mkdir()
    (sd_ee3 / "s1.yaml").write_text(_y.safe_dump({
        "id": "WFA_X_0001-c-77", "case_id": "C-77", "required": True,
        "steps": [{"seq": 1, "node": "00", "actorAccount": "admin"}]}), encoding="utf-8")
    sysd_ee3 = tmp / "sysd-ee3"; sysd_ee3.mkdir()
    (sysd_ee3 / "current.yaml").write_text(_mock_yaml(pC, "current", "/cur"), encoding="utf-8")
    ee3_y = tmp / "ee3.yaml"
    ee3_y.write_text(ee2_y.read_text(encoding="utf-8").replace("path: /api/login", "path: __F12_RECORD__"), encoding="utf-8")
    (sysd_ee3 / "legacy.yaml").write_text(ee3_y.read_text(encoding="utf-8"), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_ee3),
             "--exec-dir", str(tmp / "exec-ee3"), "--run-id", "ee3", "--systems-dir", str(sysd_ee3)], env=env_api)
    j = json.loads((tmp / "exec-ee3" / "case-results.json").read_text())
    check("runner(api): 值含占位（解析值口径）→ 仍立即 BLOCKED",
          r.returncode == 2 and j[0]["status"] == "BLOCKED" and "__F12_RECORD__" in j[0].get("reason", ""),
          f"exit={r.returncode} status={j[0]['status']}")

    # FF1. pipeline dry-run 同步执行 legacy-config-check（第十六轮审计·P1）：
    #      占位残留 → 计划不可行 exit 2（不再"文件存在即计划可行"）
    bad_sysd_ff = tmp / "sysd-ff"; bad_sysd_ff.mkdir()
    (bad_sysd_ff / "current.yaml").write_text(_FULL_SYS.format(side="current"), encoding="utf-8")
    bad_legacy = _FULL_SYS.format(side="legacy").replace("path: /api/login", "path: __F12_RECORD__")
    (bad_sysd_ff / "legacy.yaml").write_text(bad_legacy, encoding="utf-8")
    r = run(["bash", str(SCRIPTS / "pipeline.sh"), "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"),
             "--scenario-dir", str(s6out / "flowtrace-scenarios"), "--rules", str(s6out / "compare-rules.json"),
             "--dry-run"],
            env={**__import__("os").environ, "FLOWTEST_SYSTEMS_API_DIR": str(bad_sysd_ff)})
    check("pipeline(dry-run): legacy 占位残留 → 计划不可行 exit 2（配置检查同步执行）",
          r.returncode == 2 and "计划不可行" in r.stdout, f"exit={r.returncode} out={r.stdout[-300:]!r}")
    # FF2. 对照：全填配置 → dry-run 计划可行 exit 0（配置检查不误伤）
    r = run(["bash", str(SCRIPTS / "pipeline.sh"), "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"),
             "--scenario-dir", str(s6out / "flowtrace-scenarios"), "--rules", str(s6out / "compare-rules.json"),
             "--dry-run"], env=ENV_FULLSYS)
    check("pipeline(dry-run): 全填配置 → 计划可行 exit 0（对照不误伤）",
          r.returncode == 0 and "计划可行" in r.stdout, f"exit={r.returncode} out={r.stdout[-300:]!r}")

    # ---------- 第十九轮回归（2026-09-07 第十六轮·依赖分级与工具补全） ----------
    # FF3. conclude: gate 失败 reason 携带 note（P2-1——summary 可见具体断言失败原因）
    ff3 = tmp / "ff3"; ff3.mkdir()
    w(ff3 / "gates.json", [{"id": "GATE-CANVAS", "severity": "P0", "passed": False,
                            "note": "报告字段断言失败: data.canvas_render_ok eq True（实际 False）"}])
    w(ff3 / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": []})
    w(ff3 / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    w(ff3 / "run-manifest.json", dict({"run_id": "ff3"}, **snap_of(ff3)))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(ff3)])
    reasons3 = json.loads((ff3 / "summary.json").read_text())["blocked_reasons"]
    check("conclude: gate 失败 reason 携带 note（不必翻 gates.json）",
          r.returncode == 2 and any("报告字段断言失败" in str(x) for x in reasons3),
          f"exit={r.returncode} reasons={reasons3[:2]}")
    # FF3b. synthetic gate 完全跳过：note 不进 reasons；其余证据齐全时按正常判定（PASS 语义，
    #       finish_block 场景的 BLOCKED 来自占位 case-results/对拍，而非 synthetic gate 本身）
    ff3b = tmp / "ff3b"; ff3b.mkdir()
    w(ff3b / "gates.json", [{"id": "GATE-PIPELINE", "severity": "P99", "passed": False,
                             "synthetic": True, "note": "占位——不应出现在 reasons"}])
    w(ff3b / "field-compare.json", {"status": "OK", "diffs": [], "exempted": [], "coverage": []})
    w(ff3b / "case-results.json", [{"id": "C-1", "required": True, "status": "PASS"}])
    w(ff3b / "run-manifest.json", dict({"run_id": "ff3b"}, **snap_of(ff3b)))
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(ff3b)])
    reasons3b = json.loads((ff3b / "summary.json").read_text())["blocked_reasons"]
    check("conclude: synthetic gate 完全跳过（note 不进 reasons，其余齐全 → 正常判定）",
          r.returncode == 0 and reasons3b == [] and "占位——不应出现" not in str(reasons3b),
          f"exit={r.returncode} reasons={reasons3b[:2]}")

    # FF4. gen-gate-report: 按 schema 生成报告骨架（flow_field 绑定 + 占位值）+ 证据条目骨架
    ggr_ct = tmp / "ff4-contract.yaml"
    ggr_ct.write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001"},
        "gates": [
            {"id": "GATE-CANVAS", "check": "画布", "severity": "P0",
             "evidence_schema": {"kind": "report", "file_format": "json", "flow_field": "data.flow_code",
                                 "required_fields": [{"path": "data.canvas_render_ok", "op": "eq", "value": True},
                                                     {"path": "data.forms_checked", "op": "gte", "value": 4}]}},
            {"id": "GATE-HEALTH", "check": "健康", "severity": "P0"},
            {"id": "GATE-DEPLOY", "check": "部署", "severity": "P1",
             "evidence_schema": {"kind": "http", "allowed_urls": ["https://x/"]}}]}),
        encoding="utf-8")
    ff4_out = tmp / "ff4-out"
    r = run([sys.executable, str(SCRIPTS / "gen-gate-report.py"), "--contract", str(ggr_ct), "--outdir", str(ff4_out)])
    rep = json.loads((ff4_out / "gate-reports" / "GATE-CANVAS.json").read_text())
    entries = json.loads((ff4_out / "gate-evidence.entries.json").read_text())
    check("gen-gate-report: flow_field 自动绑定 + required_fields 占位 + 跳过非 report 类",
          r.returncode == 0 and rep["data"]["flow_code"] == "WFA_X_0001"
          and rep["data"]["canvas_render_ok"] == "__FILL_eq__" and rep["data"]["forms_checked"] == 0
          and len(entries) == 1 and entries[0]["id"] == "GATE-CANVAS",
          f"exit={r.returncode} rep={rep} entries={len(entries)}")
    # FF4b. 骨架本身不能"假通过"——占位值喂给 gate-evidence-check 必须 passed=false
    ff4_ev = tmp / "ff4-ev.json"
    w(ff4_ev, [{"id": "GATE-CANVAS", "type": "file", "path": str(ff4_out / "gate-reports" / "GATE-CANVAS.json"),
                "sha256_16": _h.sha256((ff4_out / "gate-reports" / "GATE-CANVAS.json").read_bytes()).hexdigest()[:16],
                "generated_at": "2026-09-07T10:00:00+08:00", "target_env": "v2"}])
    ff4_gct = tmp / "ff4-real-contract.yaml"
    ff4_gct.write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001"},
        "gates": [{"id": "GATE-CANVAS", "check": "画布", "severity": "P0",
                   "evidence_schema": {"kind": "report", "file_format": "json", "flow_field": "data.flow_code",
                                       "required_fields": [{"path": "data.canvas_render_ok", "op": "eq", "value": True}]}}]}),
        encoding="utf-8")
    gk_ff4 = tmp / "ff4-gates.json"
    hr_ff4 = tmp / "ff4-health.json"; hr_ff4.write_text("[]", encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "gate-evidence-check.py"), str(gk_ff4), str(hr_ff4),
             str(ff4_gct), str(ff4_ev), str(tmp)])
    items = json.loads(gk_ff4.read_text())
    check("gen-gate-report: 骨架占位值不假通过（eq True vs __FILL_eq__）→ passed=false",
          r.returncode == 0 and items[0]["passed"] is False, f"exit={r.returncode} note={items[0].get('note','')[:90]}")

    # ---------- 第二十轮回归（2026-09-07 双跑实测反哺：门禁证据/路由映射/业务失败穿透） ----------
    # G1. validate: gate required_fields op=eq + list value → 立契期拒绝（标量守卫前置，
    #     此前运行期才炸=浪费 run-id）
    bad_v = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    for g in bad_v.get("gates", []):
        if g.get("id") == "GATE-ACCOUNT":
            g["evidence_schema"]["required_fields"] = [{"path": "data.failed_accounts", "op": "eq", "value": []}]
    bad_vp = tmp / "v20-eqlist.yaml"; bad_vp.write_text(_y.safe_dump(bad_v, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(bad_vp), "--level", "test_ready"])
    check("validate: gate eq+list value（结构性不可通过）→ 立契期拒绝(2)",
          r.returncode == 2 and "非标量" in r.stderr, f"exit={r.returncode} {r.stderr[-150:]!r}")

    # G2. validate: 单侧无健康覆盖 → 拒绝（2026-09-07 实测 legacy 宕机门禁全绿、runner 才暴露）
    bad_h = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    bad_h["environments"]["health_checks"] = [h for h in bad_h["environments"]["health_checks"]
                                               if "<legacy-prod-host>" not in str(h)]
    bad_hp = tmp / "v20-nohc.yaml"; bad_hp.write_text(_y.safe_dump(bad_h, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(bad_hp), "--level", "test_ready"])
    check("validate: legacy 主机无健康检查覆盖 → 拒绝(2)",
          r.returncode == 2 and "无任何覆盖" in r.stderr, f"exit={r.returncode} {r.stderr[-150:]!r}")

    # G3a. validate: 用例路由与 nodes.next 矛盾（未声明）→ 默认拒绝(2)
    #      （第三十四轮 P2-3：TEST_READY 执行会产生真实流程副作用，矛盾路由不得仅 WARN 放行；
    #        探索性路径仅限 DRAFT 级或 --drill）
    bad_r = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    for case in bad_r.get("cases", []):
        if case.get("id") == "C-01":
            case.get("steps", [{}])[0]["next"] = "99"  # 00→99 不在 nodes[00].next
    bad_rp = tmp / "v20-route.yaml"; bad_rp.write_text(_y.safe_dump(bad_r, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(bad_rp), "--level", "test_ready"])
    check("validate: 用例路由与 nodes.next 矛盾（未声明）→ 拒绝(2)",
          r.returncode == 2 and "不在 nodes" in r.stderr,
          f"exit={r.returncode} {r.stderr[-200:]!r}")

    # G3b. validate: 同一矛盾 + --allow-route-drift → WARN 放行(0)（仅限 --drill 演练探索）
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(bad_rp),
             "--level", "test_ready", "--allow-route-drift"])
    check("validate: 路由矛盾 + --allow-route-drift → WARN 放行(0)",
          r.returncode == 0 and "WARN" in r.stderr and "不在 nodes" in r.stderr,
          f"exit={r.returncode} {r.stderr[-200:]!r}")

    # G3c. validate: 路由矛盾但 cases[].notes 显式声明特殊流转 → 放行无警告(0)
    notes_r = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    for case in notes_r.get("cases", []):
        if case.get("id") == "C-01":
            case.get("steps", [{}])[0]["next"] = "99"
            case["notes"] = "特殊流转实测：退回/作废链路（可审计豁免）"
    notes_rp = tmp / "v31-route-notes.yaml"; notes_rp.write_text(_y.safe_dump(notes_r, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(notes_rp), "--level", "test_ready"])
    check("validate: 路由矛盾但 cases[].notes 已声明特殊流转 → 放行(0)",
          r.returncode == 0 and "不在 nodes" not in r.stderr,
          f"exit={r.returncode} {r.stderr[-200:]!r}")

    # G4. gen: '任一' actor → meta.observer_actor 落地替换（runner actorMap 查占位符必 BLOCKED）
    g_out = tmp / "v20-gen"; g_out.mkdir()
    r = run([sys.executable, str(HERE / "gen_from_contract.py"),
             "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"), "--outdir", str(g_out)])
    c05 = g_out / "flowtrace-scenarios" / "WFA_RY_HZ_0162-c-05.yaml"
    ok_g4 = r.returncode == 0 and c05.exists() and "actorAccount: renna1" in c05.read_text(encoding="utf-8")
    check("gen: '任一' actor → observer_actor(renna1) 落地", ok_g4, f"exit={r.returncode} c05={c05.exists()}")

    # G5. api-capture: apply_route_map（按流程嵌套 / 扁平回退 / 未命中原值三态）
    import importlib.util as _ilu
    _spec_ac = _ilu.spec_from_file_location("api_capture_v20", str(SCRIPTS / "api-capture.py"))
    ac = _ilu.module_from_spec(_spec_ac); _spec_ac.loader.exec_module(ac)
    b1 = ac.apply_route_map({"nextStep": "01"}, {"WFA_X_0001": {"01": "task_9"}}, "WFA_X_0001")
    b2 = ac.apply_route_map({"nextStep": "01"}, {"01": "task_flat"}, "OTHER_FLOW")
    b3 = ac.apply_route_map({"nextStep": "77"}, {"01": "task_flat"}, "WFA_X_0001")
    check("api-capture: route_map 嵌套/扁平/未命中三态",
          b1["nextStep"] == "task_9" and b2["nextStep"] == "task_flat" and b3["nextStep"] == "77",
          f"{b1['nextStep']}/{b2['nextStep']}/{b3['nextStep']}")

    # G6. api-capture: 错误响应体片段脱敏（token/password 值不进错误信息）
    snip = ac.body_snippet({"success": False, "message": "boom", "token": "TOPSECRET", "password": "PLAINTXT"})
    check("api-capture: 错误响应体片段脱敏（token/password → ***）",
          "TOPSECRET" not in snip and "PLAINTXT" not in snip and "boom" in snip, snip[:120])
    # G6a. 脱敏前缀/后缀变体（access_token/db_password 等子串口径，与 validate 一致）
    snip2 = ac.body_snippet({"success": False, "access_token": "TOPSECRET2", "db_password": "PLAINTXT2"})
    check("api-capture: 脱敏覆盖键名子串变体（access_token/db_password → ***）",
          "TOPSECRET2" not in snip2 and "PLAINTXT2" not in snip2 and '"success": false' in snip2.lower(),
          snip2[:120])
    # G6b. 连字符键名变体（x-api-key 为 HTTP 生态最常见 header 形态）
    snip3 = ac.body_snippet({"success": False, "x-api-key": "TOPSECRET3", "Api-Key": "TOPSECRET4"})
    check("api-capture: 脱敏覆盖连字符键名（x-api-key/Api-Key → ***）",
          "TOPSECRET3" not in snip3 and "TOPSECRET4" not in snip3, snip3[:120])

    # G7. api-capture: 按钮语义原语 operations（第三十五轮 v1.3.5）——退回/作废不再编码成 next_step
    def _mk_api(operations):
        a = ac.Api({"baseUrl": "http://unit.test", "operations": operations})
        a.ledger = {}; a.task_meta = {}; a.actor_display = {}
        a.calls = []
        a.call = lambda method, path, *, body=None, params=None, token=None: (
            a.calls.append({"method": method, "path": path, "body": body}) or a.call.resp)
        a.call.resp = (200, {"success": True, "data": {}})
        return a

    _CTX = {"BUTTON": "BACK", "NEXT_NODE": "19(退回)", "INSTANCE_NO": "FI1", "TASK_ID": "SI1",
            "NODE": "21", "FLOW_CODE": "WFA_RY_HZ_0162", "_seq": 8}

    def _dies(fn):
        try:
            fn(); return False
        except SystemExit as e:
            return int(e.code) == 2

    # G7a. 形状缺项 fail-closed：缺 path / backTarget 缺键 / body 引用 BACK_TARGET 无解析器
    a = _mk_api({})
    check("api-capture: operations[BACK] 缺 path → die",
          _dies(lambda: a._submit_operation("tok", "SI1", dict(_CTX), "BACK", {})), "")
    a = _mk_api({})
    check("api-capture: operations.backTarget 缺 listPath → die",
          _dies(lambda: a._submit_operation("tok", "SI1", dict(_CTX), "BACK", {
              "path": "/back", "body": {"w": 1},
              "backTarget": {"path": "/rec", "body": {}, "nodeField": "stepCode", "idField": "stepInstCode"}})), "")
    a = _mk_api({})
    check("api-capture: body 引用 ${BACK_TARGET} 无 backTarget → die",
          _dies(lambda: a._submit_operation("tok", "SI1", dict(_CTX), "BACK", {
              "path": "/back", "body": {"backStepInstanceId": "${BACK_TARGET}"}})), "")

    # G7b. backTarget 恰一命中 → BACK_TARGET 注入 + 端点/载荷正确 + 账本完结
    a = _mk_api({"BACK": {
        "path": "/workflowManage/backWorkflow",
        "body": {"WorkflowFlag": {"FlowInsCode": "${INSTANCE_NO}", "StepInsCode": "${TASK_ID}"},
                 "backStepInstanceId": "${BACK_TARGET}", "backDesc": "退回"},
        "backTarget": {"path": "/workflowManage/getWorkflowInstanceRecordsBack2",
                       "body": {"WorkflowFlag": {"FlowInsCode": "${INSTANCE_NO}", "StepInsCode": "${TASK_ID}"}},
                       "listPath": "data.stepInfo", "nodeField": "stepCode", "idField": "stepInstCode"},
        "ledger": "finish"}})
    a.call.resp = (200, {"success": True, "data": {"stepInfo": [
        {"stepCode": "00", "stepInstCode": "SI0"}, {"stepCode": "19", "stepInstCode": "SI9"}]}})
    finished = []
    a.ledger_finish = lambda tid: finished.append(tid)
    a._submit_operation("tok", "SI1", dict(_CTX), "BACK", a.api["operations"]["BACK"])
    ok_g7b = (a.calls[0]["path"].endswith("getWorkflowInstanceRecordsBack2")
              and a.calls[1]["path"].endswith("backWorkflow")
              and a.calls[1]["body"]["backStepInstanceId"] == "SI9"
              and a.calls[1]["body"]["WorkflowFlag"] == {"FlowInsCode": "FI1", "StepInsCode": "SI1"}
              and finished == ["SI1"])
    check("api-capture: BACK 恰一命中 → 目标注入/端点/账本完结三对", ok_g7b,
          json.dumps(a.calls, ensure_ascii=False)[:160])

    # G7c. backTarget 多候选（重办产生同环节两条）→ die 绝不猜
    a = _mk_api({"BACK": {"path": "/back", "body": {"t": "${BACK_TARGET}"},
                          "backTarget": {"path": "/rec", "body": {}, "listPath": "data.stepInfo",
                                         "nodeField": "stepCode", "idField": "stepInstCode"}}})
    a.call.resp = (200, {"success": True, "data": {"stepInfo": [
        {"stepCode": "19", "stepInstCode": "SI9a"}, {"stepCode": "19", "stepInstCode": "SI9b"}]}})
    check("api-capture: backTarget 多候选 → die（不猜退回目标）",
          _dies(lambda: a._submit_operation("tok", "SI1", dict(_CTX), "BACK", a.api["operations"]["BACK"])), "")

    # G7d. refetch 恰一命中 → 空 owner 重登记新任务；失配（0 条）→ die
    _RF = {"ledger": "refetch",
           "refetch": {"path": "/workflowManage/getCurrentUserProcessList",
                       "body": {"instance_no": "${INSTANCE_NO}", "rows": 50},
                       "listPath": "data.data", "taskIdField": "stepInstCode",
                       "nodeField": "flowInstCurrStep", "instanceField": "instCode"}}
    a = _mk_api({"BACK": {"path": "/back", "body": {"t": "${BACK_NODE}"}, **_RF}})
    a.call.resp = (200, {"success": True, "data": {"data": [
        {"instCode": "FI1", "flowInstCurrStep": "19", "stepInstCode": "SI9new"}]}})
    reged = []
    a.ledger_register = lambda tid, node, owner, inst, flow: reged.append((tid, node, owner, inst, flow))
    a._submit_operation("tok", "SI1", dict(_CTX), "BACK", a.api["operations"]["BACK"])
    ok_g7d = reged == [("SI9new", "19", "", "FI1", "WFA_RY_HZ_0162")]
    check("api-capture: refetch 恰一命中 → 空 owner 重登记新任务", ok_g7d, str(reged))
    a = _mk_api({"BACK": {"path": "/back", "body": {"t": "${BACK_NODE}"}, **_RF}})
    a.call.resp = (200, {"success": True, "data": {"data": [
        {"instCode": "FI9", "flowInstCurrStep": "19", "stepInstCode": "SIx"}]}})
    check("api-capture: refetch 失配（0 条）→ die（不盲登账本）",
          _dies(lambda: a._submit_operation("tok", "SI1", dict(_CTX), "BACK", a.api["operations"]["BACK"])), "")

    # G7e. 空 owner 账本条目对任意 actor 可见；非空 owner 不匹配仍被滤（实例隔离语义不放松）
    a = _mk_api({})
    a.api["todo"] = {}
    a.ledger = {"t1": {"node": "19", "owner": "", "instance": "FI1", "flow": "F"},
                "t2": {"node": "19", "owner": "驻铁A", "instance": "FI2", "flow": "F"}}
    a.actor_display = {"lyz_zhukuang1": "驻铁A"}
    todo = a._ledger_todo("tok", "lyz_zhukuang1")
    ids = {e["taskId"] for e in todo}
    check("api-capture: 空 owner 账本条目任意 actor 可见 + 非空 owner 仍按人滤",
          "t1" in ids and "t2" in ids, str(sorted(ids)))
    todo2 = a._ledger_todo("tok", "renna1")
    check("api-capture: 非 owner actor 查不到非空 owner 条目",
          "t1" in {e["taskId"] for e in todo2} and "t2" not in {e["taskId"] for e in todo2}, "")

    # G7f. submit 顶部分发：BUTTON 命中 operations → 走原语；未命中 → 原提交路径（缺 submit 块报错可辨）
    a = _mk_api({"BACK": {"path": "/back", "body": {}}})
    routed = []
    a._submit_operation = lambda tok, tid, ctx, btn, op: routed.append(btn)
    try:
        a.submit("tok", "SI1", {**_CTX, "BUTTON": "BACK"})
        routed_ok = routed == ["BACK"]
    except SystemExit:
        routed_ok = False
    check("api-capture: submit 顶部分发命中 operations → 走按钮原语", routed_ok, str(routed))
    a2 = ac.Api({"baseUrl": "http://unit.test", "operations": {"BACK": {"path": "/back", "body": {}}}})
    check("api-capture: BUTTON 未命中 operations → 走原 submit（缺 submit 块可辨报错）",
          _dies(lambda: a2.submit("tok", "SI1", {**_CTX, "BUTTON": "提交"})), "")

    # ===== v1.3.6 P0：operations 配置在任何写请求之前校验 / reuse 消歧 / 预保存失败 =====
    # G7g. 完整 schema 前置校验：命中且非法即拒，禁止回退统一 submit，禁止先写后验
    _bad_entries = [
        {"path": "", "body": {}},                                                    # 空 path
        {"path": "/back", "body": {}, "ledger": "reftch"},                           # ledger 拼写错
        {"path": "/back", "body": {}, "ledger": "refetch"},                          # refetch 缺块
        {"path": "/back", "body": {"t": "${BACK_TARGET}"}},                          # 引用无解析器
        {"path": "/back", "body": {}, "backTarget": {"path": "/r", "body": {}, "nodeField": "n"}},  # 缺 idField
        {"path": "/back", "body": {}, "successStatus": ["200"]},                     # 非整数状态码
    ]
    _schema_ok = all(ac.ftc_ops_config.validate_operation_entry("BACK", _e) for _e in _bad_entries)
    check("api-capture: operations schema 校验覆盖 path/ledger/refetch/backTarget/successStatus",
          _schema_ok, "")
    a = _mk_api({"BACK": {"path": "/back", "body": {}, "ledger": "reftch"}})
    check("api-capture: ledger 拼写错 → 发请求前 die（不再被当作 finish）",
          _dies(lambda: a._submit_operation("tok", "SI1", dict(_CTX), "BACK", a.api["operations"]["BACK"]))
          and a.calls == [], str(a.calls))
    a = _mk_api({"BACK": {"path": "/back", "body": {}, "ledger": "refetch"}})
    check("api-capture: ledger=refetch 缺 refetch 块 → 写请求前 die（不再先退回再报 MISSING_REFETCH）",
          _dies(lambda: a._submit_operation("tok", "SI1", dict(_CTX), "BACK", a.api["operations"]["BACK"]))
          and a.calls == [], str(a.calls))
    a = _mk_api({"BACK": {"path": "/back", "body": {"backStepInstanceId": "${BACK_TARGET}"},
                          "backTarget": {"path": "/rec", "body": {}, "listPath": "data.stepInfo",
                                         "nodeField": "stepCode", "idField": "stepInstCode"}}})
    a.call.resp = (200, {"success": True, "data": {"stepInfo": [{"stepCode": "19"}]}})
    check("api-capture: backTarget 命中行缺 idField → die（拒绝发送字符串 'None'）",
          _dies(lambda: a._submit_operation("tok", "SI1", dict(_CTX), "BACK", a.api["operations"]["BACK"])),
          str(a.calls))
    a = ac.Api({"baseUrl": "http://unit.test",
                "operations": {"BACK": {"path": "/back", "body": {}, "ledger": "bogus"}},
                "submit": {"method": "POST", "path": "/submit", "body": {"b": "${BUTTON}"}}})
    check("api-capture: operations 命中键但配置非法 → 拒绝，禁止回退统一 submit",
          _dies(lambda: a.submit("tok", "SI1", {**_CTX, "BUTTON": "BACK"})), "")
    # refetch 有限轮询：首查 0 条→次查 1 条 → 成功重登记（异步可见不立即 BLOCKED）
    a = _mk_api({"BACK": {"path": "/back", "body": {}, "ledger": "refetch",
                          "refetch": {"path": "/getCurrentUserProcessList", "body": {},
                                      "listPath": "data.data", "taskIdField": "stepInstCode",
                                      "nodeField": "flowInstCurrStep", "instanceField": "instCode",
                                      "pollSeconds": 3}}})
    _poll = {"n": 0}

    def _poll_call(method, path, *, body=None, params=None, token=None):
        a.calls.append({"method": method, "path": path})
        if "getCurrentUserProcessList" in path:
            _poll["n"] += 1
            rows = ([] if _poll["n"] == 1
                    else [{"instCode": "FI1", "flowInstCurrStep": "19", "stepInstCode": "SI9new"}])
            return (200, {"success": True, "data": {"data": rows}})
        return (200, {"success": True})
    a.call = _poll_call
    _reg = []
    a.ledger_register = lambda tid, node, owner, inst, flow: _reg.append((tid, node, owner, inst, flow))
    a._submit_operation("tok", "SI1", dict(_CTX), "BACK", a.api["operations"]["BACK"])
    check("api-capture: refetch 有限轮询（首查 0→次查 1）成功重登记",
          _reg == [("SI9new", "19", "", "FI1", "WFA_RY_HZ_0162")] and _poll["n"] >= 2, str(_reg))

    # G7h. reuse 首步同流程同节点多候选 → BLOCKED（绝不任取第一个真实生产单据）
    a = _mk_api({})
    a.api["todo"] = {"flowCodePath": "flowCode", "nodePath": "n", "instancePath": "i", "taskIdPath": "id"}
    a.todo_tasks = lambda token, actor="": [
        {"id": "T1", "n": "00", "i": "FI-PROD", "flowCode": "WFA_X"},
        {"id": "T2", "n": "00", "i": "FI-OTHER", "flowCode": "WFA_X"}]
    check("api-capture: reuse 同流程同节点多候选 → BLOCKED（不任取第一个）",
          _dies(lambda: a.find_task("tok", "00", 0, None, "WFA_X", allow_foreign=True)), "")
    _sel = a.find_task("tok", "00", 0, None, "WFA_X", allow_foreign=True, selectors={"instanceNo": "FI-OTHER"})
    check("api-capture: reuse 用 instanceNo 选择器消歧 → 恰一命中",
          isinstance(_sel, dict) and _sel.get("id") == "T2", str(_sel))
    check("api-capture: businessKey 选择器缺 todo.selectorPaths → die（不猜字段）",
          _dies(lambda: a.find_task("tok", "00", 0, None, "WFA_X", allow_foreign=True,
                                    selectors={"businessKey": "B-1"})), "")

    # G7i. 表单预保存失败 → 禁止继续 SUBMIT（此前 SAVE 500 仍报成功）
    a = ac.Api({"baseUrl": "http://unit.test",
                "submit": {"method": "POST", "path": "/submit", "body": {"buttonCode": "${BUTTON}"},
                           "successStatus": [200], "save_with_form_data": "SAVE_FORM"}})
    _calls = []

    def _full(method, path, *, body=None, params=None, token=None, no_follow=False):
        _calls.append(body)
        if body and body.get("buttonCode") == "SAVE_FORM":
            return (500, {"success": False}, {}, '{"success":false}')
        return (200, {"success": True}, {}, "{}")
    a.call_full = _full
    _ps_died = _dies(lambda: a.submit("tok", "T1", {"BUTTON": "提交", "NODE": "00", "_seq": 1,
                                                     "_FORM_DATA": {"f": "v"}, "INSTANCE_NO": "FI1"}))
    check("api-capture: 表单预保存失败 → die 且不发 SUBMIT（防假 PASS）",
          _ps_died and len(_calls) == 1, f"calls={len(_calls)}")

    # G7j. legacy-config-check 也校验 operations（此前不校验 → 坏配置仍报"可启动"）
    _sysc = _y.safe_load(_FULL_SYS.format(side="legacy"))
    _sysc["api"]["operations"] = {"BACK": {"path": "/back", "body": {}, "ledger": "refetch"}}
    _badc = tmp / "bad-ops-legacy.yaml"
    _badc.write_text(_y.safe_dump(_sysc, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "legacy-config-check.py"), "--systems", str(_badc)])
    check("legacy-config-check: operations 非法 → 非零退出且报 operations（不再报'可启动'）",
          r.returncode != 0 and "operations" in r.stdout and "可启动" not in r.stdout,
          f"exit={r.returncode} {r.stdout[-160:]!r}")

    # G7. pipeline dry-run: --gate-evidence 合法通过 / sha 篡改拒绝（替代监视器竞态注入）
    import hashlib as _hl
    ev_good = tmp / "v20-ev.json"
    rep = g_out / "report-skeleton.md"
    w(ev_good, [{"id": "GATE-CANVAS", "type": "file", "path": str(rep),
                 "sha256_16": _hl.sha256(rep.read_bytes()).hexdigest()[:16],
                 "target_env": "v3", "generated_at": "2026-09-07T12:00:00+08:00"}])
    r = run(["bash", str(SCRIPTS / "pipeline.sh"), "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"),
             "--scenario-dir", str(g_out / "flowtrace-scenarios"), "--rules", str(g_out / "compare-rules.json"),
             "--gate-evidence", str(ev_good), "--dry-run"], env=ENV_FULLSYS)
    ok_g7a = r.returncode == 0 and "gate-evidence 预校验通过" in r.stdout
    ev_bad = tmp / "v20-ev-bad.json"
    _bad_ev = json.loads(ev_good.read_text(encoding="utf-8"))
    _bad_ev[0]["sha256_16"] = "0" * 16
    ev_bad.write_text(json.dumps(_bad_ev, ensure_ascii=False), encoding="utf-8")
    r = run(["bash", str(SCRIPTS / "pipeline.sh"), "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"),
             "--scenario-dir", str(g_out / "flowtrace-scenarios"), "--rules", str(g_out / "compare-rules.json"),
             "--gate-evidence", str(ev_bad), "--dry-run"], env=ENV_FULLSYS)
    ok_g7b = r.returncode == 2 and "计划不可行" in r.stdout
    check("pipeline(dry-run): --gate-evidence 合法通过 / sha 篡改拒绝(2)",
          ok_g7a and ok_g7b, f"good={ok_g7a} bad={ok_g7b}")

    # G7b/G7c. pipeline 回归（1.0.1 P0 修复）：DRILL=false 为非空字符串，${DRILL:+} 非空判断
    #      恒真——正式运行曾误传 --allow-route-drift 把路由矛盾降级 WARN。显式布尔派生后
    #      正反两向 pipeline 级锁定：
    r = run(["bash", str(SCRIPTS / "pipeline.sh"), "--contract", str(bad_rp),
             "--scenario-dir", str(g_out / "flowtrace-scenarios"), "--rules", str(g_out / "compare-rules.json"),
             "--dry-run"], env=ENV_FULLSYS)
    check("pipeline(dry-run): 正式运行 + 路由矛盾 → 拒绝(2)（失败点=路由门，不因缺 --drill 降级 WARN）",
          r.returncode == 2 and "[test_ready] FAIL" in (r.stdout + r.stderr) and "不在 nodes" in (r.stdout + r.stderr),
          f"exit={r.returncode} {(r.stdout + r.stderr)[-200:]!r}")
    r = run(["bash", str(SCRIPTS / "pipeline.sh"), "--contract", str(bad_rp),
             "--scenario-dir", str(g_out / "flowtrace-scenarios"), "--rules", str(g_out / "compare-rules.json"),
             "--drill", "--dry-run"], env=ENV_FULLSYS)
    _o = r.stdout + r.stderr
    check("pipeline(dry-run): --drill + 同一路由矛盾 → 路由 WARN 放行（失败点=同源复算，非路由门）",
          r.returncode == 2 and "[test_ready] WARN" in _o and "[test_ready] FAIL" not in _o and "不同源" in _o,
          f"exit={r.returncode} {_o[-200:]!r}")

    # ---------- 第二十一轮回归（2026-09-08 李雅庄公路双端试点反哺：api 通道适配原生化） ----------
    # 主题：五原语之外的系统形态差异全部下沉为 systems 配置——链式登录（MD5/RSA/302 取 token）、
    # 账本待办（launch/submit 响应组装，服务端声明零编造）、retryOn 前置按钮自适应、
    # form.body 模板、assignee 姓名→ID 服务端解析、headers 附加头（${UUID}）。
    import hashlib as _hl21
    import urllib.parse as _up21

    _PUB21 = ("MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDt30AcO8CSAfzSa5L8ikVrfehH6aFw9KyL85NzOAduOfnPcbiAGLjLWEK"
              "OkOhkYrlSAfU5s+pa3OQTsgpfCkVVm56dEQh8sajIR4uyGbhv0/CdvPTZS5o3sP6Yi9TemWZ443+QNjajN6MSCTmTY86"
              "ZoR9jmTcJtV4kNTQWDov6qQIDAQAB")
    _st21 = {"saves": 0, "uuid": 0, "form_bodies": [], "commit_nextuserid": [], "pop_next": ""}

    def _start21(port: int):
        class _H21(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def _j(self, o, code=200):
                b = json.dumps(o, ensure_ascii=False).encode(); self.send_response(code)
                self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
                self.end_headers(); self.wfile.write(b)
            def do_POST(self):
                ln = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(ln) or b"{}")
                if self.headers.get("X-Request-Id"): _st21["uuid"] += 1
                if self.path == "/leg/accessCode":
                    pwd = _up21.unquote(body.get("password", ""))
                    ok = body.get("account") in ("mock-admin", "mock-admin2") and pwd and pwd != "right-pwd"
                    self._j({"data": {"code": body.get("account", "")}}, 200 if ok else 401); return
                if self.path == "/leg/start":
                    _st21["pop_next"] = "T01"; self._j({"data": {"FI": "FIDemo", "SI": "T00"}}); return
                if self.path == "/leg/form":
                    _st21["form_bodies"].append(body); 
                    self._j({"data": {"form_data": {"CS": "V"}, "autoflowStep": {"stepCode": "00", "nextStep": "01"}}}); return
                if self.path == "/leg/submit":
                    bc = body.get("buttonCode")
                    if str(bc) == "SAVE":
                        _st21["saves"] += 1; self._j({"data": {"saved": True}}); return
                    if str(bc) in ("SUBMIT", "提交") and _st21["saves"] == 0:
                        self._j({"success": False, "message": "尚无已保存单据，请先保存单据"}, 400); return
                    if body.get("nextAssigneeId"):
                        _st21["commit_nextuserid"].append(body.get("nextAssigneeId"))
                    self._j({"data": {"StepInsCode": _st21.pop("pop_next", "")}}); return
                if self.path == "/leg/orgrole":
                    cands = {"01": [{"user_id": 427, "name": "杨松渊"}]}.get(body.get("step_code"), [])
                    self._j({"data": cands}); return
                self._j({"message": "nf"}, 404)
            def do_GET(self):
                if self.path.startswith("/leg/sso/login"):
                    q = _up21.parse_qs(_up21.urlparse(self.path).query)
                    self.send_response(302)
                    self.send_header("Location", f"http://x/#/home?token=tok-{q.get('code', [''])[0]}")
                    self.send_header("Content-Length", "0"); self.end_headers(); return
                if self.path.startswith("/leg/whoami"):
                    user = self.headers.get("authorization", "").replace("tok-", "")
                    self._j({"data": {"name": {"mock-admin": "测试甲", "mock-admin2": "杨松渊"}.get(user, "未知")}}); return
                self._j({"message": "nf"}, 404)
        srv = ThreadingHTTPServer(("127.0.0.1", port), _H21)
        _th.Thread(target=srv.serve_forever, daemon=True).start()
        return srv

    _p21 = _free_port()
    _srv21 = _start21(_p21)
    _sys21 = tmp / "systems21"; _sys21.mkdir()
    (_sys21 / "legacy.yaml").write_text(_y.safe_dump({
        "id": "legacy", "channel": "api",
        "api": {
            "baseUrl": f"http://127.0.0.1:{_p21}", "taskWaitSeconds": 1,
            "headers": {"X-Request-Id": "${UUID}"},
            "rsaPubB64": _PUB21,
            "whoami": {"path": "/leg/whoami", "namePath": "data.name"},
            "login": {"tokenHeader": "authorization", "tokenScheme": "",
                      "chain": [
                          {"method": "POST", "path": "/leg/accessCode",
                           "body": {"account": "${USERNAME}", "password": "${PASSWORD|md5_upper|rsa_pkcs1|uri}"},
                           "saveAs": "CODE", "savePath": "data.code"},
                          {"method": "GET", "path": "/leg/sso/login?clientId=10001&code=${CODE}",
                           "noFollow": True, "tokenFromRedirectQuery": "token"}]},
            "todo": {"mode": "ledger", "firstNode": "00", "nextTaskPath": "data.StepInsCode",
                     "params": {}, "path": "/unused", "listPath": "data.content"},
            "launch": {"method": "POST", "path": "/leg/start", "body": {"flowCode": "${FLOW_CODE}"},
                       "instancePath": "data.FI", "taskIdPath": "data.SI", "elementIdEnv": "L21_EL"},
            "form": {"method": "POST", "path": "/leg/form",
                     "body": {"WorkflowFlag": {"FlowInsCode": "${INSTANCE_NO}", "StepInsCode": "${TASK_ID}"}},
                     "fieldsPath": "data.form_data", "nodePath": "data.autoflowStep.stepCode",
                     "nextStepPath": "data.autoflowStep.nextStep"},
            "submit": {"method": "POST", "path": "/leg/submit", "defaultButton": "提交",
                       "body": {"buttonCode": "${BUTTON}", "nextAssigneeId": "${NEXT_ASSIGNEE}"},
                       "retryOn": {"messageContains": "尚无已保存单据", "preButton": "SAVE"},
                       "successStatus": [200]},
            "assignee": {"resolver": "orgrole", "candidatesPath": "/leg/orgrole",
                         "candidatesBody": {"step_code": "${NEXT_NODE}", "flow_code": "${FLOW_CODE}",
                                            "param_org_id": "",
                                            "WorkflowFlag": {"FlowInsCode": "${INSTANCE_NO}", "StepInsCode": "${TASK_ID}"}},
                         "candidatesListPath": "data", "nameField": "name", "idField": "user_id"},
        },
        "actorMap": {"admin": {"username": "A21_U", "password": "A21_P"},
                     "admin2": {"username": "B21_U", "password": "B21_P"}},
    }, allow_unicode=True), encoding="utf-8")
    _sc21 = tmp / "scen21"; _sc21.mkdir()
    (_sc21 / "s1.yaml").write_text(_y.safe_dump({
        "id": "WFA_X_0001-c-01", "case_id": "C-01", "required": True,
        "steps": [{"seq": 1, "node": "00", "actorAccount": "admin", "pick": "杨松渊"},
                  {"seq": 2, "node": "01", "actorAccount": "admin2"}]}), encoding="utf-8")
    _env21 = {**__import__("os").environ, "A21_U": "mock-admin", "A21_P": "right-pwd",
              "B21_U": "mock-admin2", "B21_P": "right-pwd", "L21_EL": "42"}
    _ex21 = tmp / "exec21"
    _r21 = run([sys.executable, str(SCRIPTS / "api-capture.py"),
                "--systems", str(_sys21 / "legacy.yaml"), "--scenario", str(_sc21 / "s1.yaml"),
                "--run-id", "r21", "--exec-dir", str(_ex21)], env=_env21)
    _cap21_ok = False
    try:
        _cap21 = json.loads((_ex21 / "field-captures" / "legacy" / "C-01.json").read_text(encoding="utf-8"))
        _cap21_ok = (_cap21["run_id"] == "r21" and _cap21["instance_no"] == "FIDemo"
                     and list(_cap21["steps"]) == ["s1", "s2"]
                     and _cap21["steps"]["s1"]["fields"]["CS"] == "V")
    except Exception:
        pass
    check("api: 链式登录(MD5/RSA/302取token)+账本待办+retryOn+form.body 全链 → capture 落账",
          _r21.returncode == 0 and _cap21_ok,
          f"exit={_r21.returncode} err={_r21.stderr[-200:] if _r21.returncode else ''}")
    check("api: retryOn 前置按钮恰好一次 / UUID 头注入 / form.body WorkflowFlag 到达服务端",
          _st21["saves"] == 1 and _st21["uuid"] > 0
          and any(b.get("WorkflowFlag", {}).get("FlowInsCode") == "FIDemo" for b in _st21["form_bodies"]),
          f"saves={_st21['saves']} uuid={_st21['uuid']}")
    check("api: assignee.orgrole 姓名→ID 解析（提交体收到 427 而非姓名）",
          _st21["commit_nextuserid"] == ["427"], f"got={_st21['commit_nextuserid']}")

    # 负向：未知变换 op → die（fail-closed，不静默跳过）
    (_sys21 / "bad.yaml").write_text(_y.safe_dump({
        "id": "legacy", "channel": "api",
        "api": {"baseUrl": f"http://127.0.0.1:{_p21}",
                "login": {"method": "POST", "path": "/leg/accessCode",
                          "body": {"account": "${USERNAME}", "password": "${PASSWORD|nope}"},
                          "tokenPath": "data.token"},
                "todo": {"method": "GET", "path": "/unused", "listPath": "data.l"},
                "launch": {"method": "POST", "path": "/leg/start", "body": {},
                           "instancePath": "data.FI", "taskIdPath": "data.SI", "elementIdEnv": "L21_EL"},
                "form": {"method": "GET", "path": "/leg/form", "fieldsPath": "data.form_data"},
                "submit": {"method": "POST", "path": "/leg/submit", "body": {}}},
        "actorMap": {"admin": {"username": "A21_U", "password": "A21_P"}}}, allow_unicode=True), encoding="utf-8")
    _r21b = run([sys.executable, str(SCRIPTS / "api-capture.py"),
                 "--systems", str(_sys21 / "bad.yaml"), "--scenario", str(_sc21 / "s1.yaml"),
                 "--run-id", "r21b", "--exec-dir", str(tmp / "exec21b")], env=_env21)
    check("api: 未知值变换 op → die（不静默放行）", _r21b.returncode == 2 and "未知值变换" in _r21b.stderr,
          f"exit={_r21b.returncode}")
    _srv21.shutdown()

    # ---------- 审计第 1 轮 P1-6 回归：resolve_assignee/assignee_candidates 重构等价性钉扎 ----------
    # (a) orgrole 同名双候选：prefer_ids 指认 → 命中指认 ID；无指认 → (None, None)（原值透传，fail-closed）
    # (b) next-assignees routeCode→taskElementId 回退：按 routeCode 查询空、按 taskElementId 非空 → 自动回退成功
    _st_eq = {"cand_queries": []}

    def _start_eq(port: int):
        class _HEQ(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def _j(self, o, code=200):
                b = json.dumps(o, ensure_ascii=False).encode(); self.send_response(code)
                self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
                self.end_headers(); self.wfile.write(b)
            def do_POST(self):
                ln = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(ln) or b"{}")
                if self.path in ("/eq/cands", "/eq/next-cands"):
                    _st_eq["cand_queries"].append(f"{self.path}:{body.get('node_code')}")
                    if self.path == "/eq/next-cands":   # 回退场景：routeCode 01 查询恒空，task_9（回退后）有候选
                        self._j({"data": [{"user_id": 21, "name": "王哲峰"}]
                                 if str(body.get("node_code")) == "task_9" else []}); return
                    table = {"01": [{"user_id": 11, "name": "侯丽娟"}, {"user_id": 12, "name": "侯丽娟"}]}
                    self._j({"data": table.get(str(body.get("node_code")), [])}); return
                self._j({"message": "nf"}, 404)
            def do_GET(self):
                if self.path == "/eq/workbench":
                    self._j({"data": {"nextNodes": [{"routeCode": "01", "taskElementId": "task_9"}]}}); return
                self._j({"message": "nf"}, 404)
        srv = ThreadingHTTPServer(("127.0.0.1", port), _HEQ)
        _th.Thread(target=srv.serve_forever, daemon=True).start()
        return srv

    _p_eq = _free_port()
    _srv_eq = _start_eq(_p_eq)
    _drv_eq = tmp / "drv_eq.py"
    _drv_eq.write_text(
        "import importlib.util, json, sys\n"
        "sys.dont_write_bytecode = True\n"
        "spec = importlib.util.spec_from_file_location('ac_eq', sys.argv[1])\n"
        "ac = importlib.util.module_from_spec(spec); spec.loader.exec_module(ac)\n"
        "cfg_prefer = json.load(open(sys.argv[2], encoding='utf-8'))\n"
        "cfg_plain = json.load(sys.stdin)\n"
        "api1 = ac.Api(cfg_prefer)\n"
        "api2 = ac.Api(cfg_plain)\n"
        "api3 = ac.Api(json.load(open(sys.argv[3], encoding='utf-8')))\n"
        "a1 = api1.resolve_assignee('t', 'T1', '侯丽娟', {'NEXT_NODE': '01', 'INSTANCE_NO': 'I', 'FLOW_CODE': 'F'})\n"
        "a2 = api2.resolve_assignee('t', 'T2', '侯丽娟', {'NEXT_NODE': '01', 'INSTANCE_NO': 'I', 'FLOW_CODE': 'F'})\n"
        "b = api3.resolve_assignee('t', 'T3', '王哲峰', {'NEXT_NODE': '01', 'INSTANCE_NO': 'I', 'FLOW_CODE': 'F'})\n"
        "print(json.dumps({'a1': a1, 'a2': a2, 'b': b}, ensure_ascii=False))\n", encoding="utf-8")
    _base_eq = {"baseUrl": f"http://127.0.0.1:{_p_eq}"}
    _asg_orgrole = {"resolver": "orgrole", "candidatesPath": "/eq/cands",
                           "candidatesBody": {"node_code": "${NEXT_NODE}"},
                           "candidatesListPath": "data", "nameField": "name", "idField": "user_id",
                           "prefer_ids": {"侯丽娟": "12"}}
    _cfg_orgrole_prefer = {**_base_eq, "assignee": _asg_orgrole}
    _cfg_orgrole_plain = {**_cfg_orgrole_prefer,
                          "assignee": {k: v for k, v in _asg_orgrole.items() if k != "prefer_ids"}}
    _cfg_next = {**_base_eq, "assignee": {"resolver": "next-assignees", "workbenchPath": "/eq/workbench",
                 "nextNodesPath": "data.nextNodes", "candidatesPath": "/eq/next-cands",
                 "candidatesBody": {"node_code": "${NEXT_NODE}"},
                 "candidatesListPath": "data", "nameField": "name", "idField": "user_id"}}
    _cfgeq1 = tmp / "cfg-prefer.json"; _cfgeq1.write_text(json.dumps(_cfg_orgrole_prefer), encoding="utf-8")
    _cfgeq3 = tmp / "cfg-next.json"; _cfgeq3.write_text(json.dumps(_cfg_next), encoding="utf-8")
    _r_eq = run([sys.executable, str(_drv_eq), str(SCRIPTS / "api-capture.py"), str(_cfgeq1), str(_cfgeq3)],
                input=json.dumps(_cfg_orgrole_plain))
    _eq = {}
    try:
        _eq = json.loads((_r_eq.stdout or "").strip().splitlines()[-1])
    except Exception:
        pass
    check("api(P1-6a): orgrole 同名双候选——prefer_ids 指认命中 12 / 无指认 (None,None) 原值透传",
          _eq.get("a1") == [12, "侯丽娟"] and _eq.get("a2") == [None, None],
          f"out={_br(_eq, 200)} err={_r_eq.stderr[-160:]}")
    check("api(P1-6b): next-assignees routeCode 空候选 → taskElementId 回退成功（查 01 再查 task_9）",
          _eq.get("b") == [21, "王哲峰"]
          and _st_eq["cand_queries"] == ["/eq/cands:01", "/eq/cands:01", "/eq/next-cands:01", "/eq/next-cands:task_9"],
          f"b={_br(_eq.get('b'), 80)} queries={_st_eq['cand_queries']}")
    _srv_eq.shutdown()

    # ---------- 审计第 5 轮 P0-1 回归：operations 键类型 / 严格成功谓词 / retryOn 前置失败阻断 ----------
    _st5 = {"a_submit": 0, "b_save": 0, "b_submit": 0, "b_retry": 0}

    def _start5(port: int):
        class _H5B(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def _j(self, o, code=200):
                # ensure_ascii=False：retryOn.messageContains 按真实服务器的 UTF-8 原文匹配
                b = json.dumps(o, ensure_ascii=False).encode(); self.send_response(code)
                self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
                self.end_headers(); self.wfile.write(b)
            def do_POST(self):
                ln = int(self.headers.get("Content-Length") or 0)
                _body_all = json.loads(self.rfile.read(ln) or b"{}")
                if self.path == "/m5/login":
                    self._j({"data": {"token": "tok-5"}}); return
                if self.path == "/m5/launch":
                    self._j({"data": {"i": "FI-5", "t": "t-5"}}); return
                if self.path == "/m5/form":
                    self._j({"data": {"formData": {"CS": "V"},
                                      "autoflowStep": {"stepCode": "00", "nextStep": "01"}}}); return
                if self.path == "/m5/a":   # 模式 A：HTTP 200 但 success=0（falsy 变体）
                    _st5["a_submit"] += 1
                    self._j({"success": 0, "message": "nope"}); return
                if self.path == "/m5/c":   # 模式 C：HTTP 200 + success:1（真值变体，白名单用）
                    self._j({"success": 1, "message": "ok"}); return
                if self.path == "/m5/b":
                    # 模式 B：提交按 buttonCode 分流——SAVE（retryOn 前置）=500、提交=400 缺保存
                    if str(_body_all.get("buttonCode")) == "SAVE":
                        _st5["b_save"] += 1
                        self._j({"message": "save exploded"}, 500); return
                    _st5["b_submit"] += 1
                    self._j({"message": "尚无已保存单据"}, 400); return
                self._j({"m": "nf"}, 404)
            def do_GET(self):
                if self.path.startswith("/m5/form"):
                    self._j({"data": {"formData": {"CS": "V"}}}); return
                self._j({"m": "nf"}, 404)
        srv = ThreadingHTTPServer(("127.0.0.1", port), _H5B)
        _th.Thread(target=srv.serve_forever, daemon=True).start()
        return srv

    _p5 = _free_port()
    _srv5 = _start5(_p5)
    _sys5 = tmp / "systems5"; _sys5.mkdir()
    def _mk5(sysname, submit_path, retry_save_path="", ops=None, submit_extra=None):
        _api5 = {"baseUrl": f"http://127.0.0.1:{_p5}", "taskWaitSeconds": 1,
                 "login": {"method": "POST", "path": "/m5/login", "body": {"u": "${USERNAME}"},
                           "tokenPath": "data.token", "tokenHeader": "Authorization", "tokenScheme": "Bearer "},
                 "todo": {"mode": "ledger", "firstNode": "00", "nextTaskPath": "data.x",
                          "params": {}, "path": "/unused", "listPath": "data.content"},
                 "launch": {"method": "POST", "path": "/m5/launch", "body": {"e": "${ELEMENT_ID}"},
                            "instancePath": "data.i", "taskIdPath": "data.t",
                            "elementIdEnv": "LAUNCH_ELEMENT_ID_WFA_X_0001"},
                 "form": {"method": "GET", "path": "/m5/form", "fieldsPath": "data.formData",
                          "nodePath": "data.autoflowStep.stepCode", "nextStepPath": "data.autoflowStep.nextStep"},
                 "submit": {"method": "POST", "path": submit_path, "defaultButton": "提交",
                            "body": {"buttonCode": "${BUTTON}"},
                            "successStatus": [200],
                            **({"retryOn": [{"messageContains": "尚无已保存单据", "preButton": "SAVE"}]}
                               if retry_save_path else {})},
                 }
        if ops is not None:
            _api5["operations"] = ops
        if submit_extra:
            _api5["submit"] = {**_api5["submit"], **submit_extra}
        sysname.write_text(_y.safe_dump({
            "id": "legacy", "channel": "api", "api": _api5,
            "actorMap": {"admin": {"username": "MOCK_ADMIN_USER", "password": "MOCK_ADMIN_PWD"}},
        }, allow_unicode=True), encoding="utf-8")
    _sc5 = tmp / "scen5"; _sc5.mkdir()
    (_sc5 / "s1.yaml").write_text(_y.safe_dump({
        "id": "WFA_X_0001-c-05", "case_id": "C-05", "required": True,
        "steps": [{"seq": 1, "node": "00", "actorAccount": "admin"}]}), encoding="utf-8")
    # NUMKEY：operations 数字键 → 启动即拒（此前 str() 强转通过 schema、运行时静默回退统一 submit）
    _mk5(_sys5 / "numkey.yaml", "/m5/a", ops={123: {"method": "POST", "path": "/m5/a", "body": {}}})
    r = run([sys.executable, str(SCRIPTS / "api-capture.py"),
             "--systems", str(_sys5 / "numkey.yaml"), "--scenario", str(_sc5 / "s1.yaml"),
             "--run-id", "r5a", "--exec-dir", str(tmp / "exec5a")], env=env_api)
    check("api(P0-1): operations 数字键 → 启动即拒（不再 str() 强转过 schema、不静默回退统一 submit）",
          r.returncode == 2 and "非字符串" in r.stderr and _st5["a_submit"] == 0,
          f"exit={r.returncode} err={r.stderr[-160:]} submits={_st5['a_submit']}")
    # SUCCESS0：HTTP 200 + success:0 → 业务失败 die（不再当成功）
    _mk5(_sys5 / "ok0.yaml", "/m5/a")
    r = run([sys.executable, str(SCRIPTS / "api-capture.py"),
             "--systems", str(_sys5 / "ok0.yaml"), "--scenario", str(_sc5 / "s1.yaml"),
             "--run-id", "r5b", "--exec-dir", str(tmp / "exec5b")], env=env_api)
    check("api(P0-1): HTTP 200 + success:0 → 业务失败 die（严格成功谓词；successValues 可配置）",
          r.returncode == 2 and "业务失败" in r.stderr and _st5["a_submit"] >= 1,
          f"exit={r.returncode} err={r.stderr[-160:]}")
    # RETRYFAIL：前置按钮 500 → die 且禁止重试 SUBMIT（此前 _st/_ob 被忽略、重试 200 即假成功）
    _mk5(_sys5 / "retryfail.yaml", "/m5/b", retry_save_path="/m5/b-save")
    r = run([sys.executable, str(SCRIPTS / "api-capture.py"),
             "--systems", str(_sys5 / "retryfail.yaml"), "--scenario", str(_sc5 / "s1.yaml"),
             "--run-id", "r5c", "--exec-dir", str(tmp / "exec5c")], env=env_api)
    check("api(P0-1): retryOn 前置按钮失败 → die 且不重试 SUBMIT（复用 _resp_bad，防假 PASS）",
          r.returncode == 2 and "前置按钮" in r.stderr and _st5["b_save"] == 1 and _st5["b_submit"] == 1,
          f"exit={r.returncode} err={r.stderr[-160:]} save={_st5['b_save']} submit={_st5['b_submit']}")

    # （审计第 5 轮 P2-2/P2-3）successValues 可配置两态 + 非法配置拒
    _mk5(_sys5 / "sv1.yaml", "/m5/c", submit_extra={"successValues": [True, 1]})
    r = run([sys.executable, str(SCRIPTS / "api-capture.py"),
             "--systems", str(_sys5 / "sv1.yaml"), "--scenario", str(_sc5 / "s1.yaml"),
             "--run-id", "r5d", "--exec-dir", str(tmp / "exec5d")], env=env_api)
    check("api(P2-2): successValues=[true,1] 配置后 success:1 → 成功（可配置性正向）",
          r.returncode == 0, f"exit={r.returncode} err={r.stderr[-160:]}")
    _mk5(_sys5 / "sv2.yaml", "/m5/a", submit_extra={"successValues": [True, 1]})
    r = run([sys.executable, str(SCRIPTS / "api-capture.py"),
             "--systems", str(_sys5 / "sv2.yaml"), "--scenario", str(_sc5 / "s1.yaml"),
             "--run-id", "r5e", "--exec-dir", str(tmp / "exec5e")], env=env_api)
    check("api(P2-2): successValues 配置后 success:'false' 仍失败（白名单不放宽 falsy 变体）",
          r.returncode == 2 and "业务失败" in r.stderr, f"exit={r.returncode} err={r.stderr[-140:]}")
    (_sys5 / "svbad.yaml").write_text(_y.safe_dump({
        "id": "legacy", "channel": "api",
        "api": {"baseUrl": f"http://127.0.0.1:{_p5}",
                "login": {"method": "POST", "path": "/m5/login", "body": {}, "tokenPath": "data.token"},
                "todo": {"method": "GET", "path": "/unused", "listPath": "data.l"},
                "launch": {"method": "POST", "path": "/m5/launch", "body": {}, "instancePath": "data.i",
                           "taskIdPath": "data.t", "elementIdEnv": "LAUNCH_ELEMENT_ID_WFA_X_0001"},
                "form": {"method": "GET", "path": "/m5/form", "fieldsPath": "data.f"},
                "submit": {"method": "POST", "path": "/m5/a", "body": {},
                           "successValues": "true"}   # 非列表 → 启动即拒
                },
        "actorMap": {"admin": {"username": "MOCK_ADMIN_USER", "password": "MOCK_ADMIN_PWD"}}},
        allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "api-capture.py"),
             "--systems", str(_sys5 / "svbad.yaml"), "--scenario", str(_sc5 / "s1.yaml"),
             "--run-id", "r5f", "--exec-dir", str(tmp / "exec5f")], env=env_api)
    check("api(P2-3): successValues 非列表 → 启动即拒（fail-closed 配置纪律，不静默回退）",
          r.returncode == 2 and "successValues 配置非法" in r.stderr,
          f"exit={r.returncode} err={r.stderr[-140:]}")

    _srv5.shutdown()

    fails = [x for x in RESULTS if not x[1]]

    # ---------- 第二十二轮回归（李雅庄公路重跑实测：双端空值语义等价） ----------
    # 老系统空串 '' vs 新系统 null——同一"无值"的表示层差异，此前记 60 条伪 diff；
    # 修复：tol_ok exact/abs 分支双空 → True。正负两向 + 不破坏"一空一非空=diff"。
    FM_E = [{"legacy_field": "CS", "target_field": "CS", "normalize": "trim", "tolerance": "exact",
             "null_policy": "both_null_equal"},
            {"legacy_field": "GHZL", "target_field": "GHZL", "normalize": "number_2dp",
             "tolerance": "abs:0.01", "null_policy": "both_null_equal"}]
    r = cmp_run(tmp / "t-empty22", fc_rules(fms=FM_E),
                legacy=[{"case_id": "C-01", "steps": {"s1": {"fields": {"CS": "", "GHZL": ""}}}}],
                current=[{"case_id": "C-01", "steps": {"s1": {"fields": {"CS": None, "GHZL": None}}}}])
    j = json.loads((tmp / "t-empty22" / "out" / "field-compare.json").read_text(encoding="utf-8"))
    check("compare: 双端空值（''/None，exact+abs）→ OK(2)——表示层差异不记伪 diff",
          r.returncode == 0 and j["stats"]["diff"] == 0 and j["stats"]["match"] == 2,
          f"exit={r.returncode} stats={j.get('stats')}")
    r = cmp_run(tmp / "t-empty22b", fc_rules(fms=FM_E),
                legacy=[{"case_id": "C-01", "steps": {"s1": {"fields": {"CS": "", "GHZL": ""}}}}],
                current=[{"case_id": "C-01", "steps": {"s1": {"fields": {"CS": "有值", "GHZL": 64}}}}])
    j = json.loads((tmp / "t-empty22b" / "out" / "field-compare.json").read_text(encoding="utf-8"))
    check("compare: 一空一非空仍 → diff(2)（空值等价不放过真实差异）",
          r.returncode == 1 and j["stats"]["diff"] == 2,
          f"exit={r.returncode} stats={j.get('stats')}")

    # ---------- 第二十三轮回归（自检卫生）：legacy-config-check 目标缺失 fail-closed ----------
    # 此前目标文件不存在只"⚠ 跳过"仍 exit 0——路径打错得到假绿，与全链 fail-closed 口径相悖
    _r_cc5 = run([sys.executable, str(SCRIPTS / "legacy-config-check.py"),
                  "--systems", str(tmp / "cc5-no-such-systems.yaml")])
    check("legacy-config-check: 目标文件不存在 → exit 2（fail-closed，防路径打错假绿）",
          _r_cc5.returncode == 2, f"exit={_r_cc5.returncode}")

    # ---------- 第二十四轮回归（BB9）：浏览器通道 browser-capture.py ----------
    # 老系统浏览器实战 SOP 固化（G3.1/G3.3/G3.4/JWT 切号）；selftest 只测结构/负向（不开浏览器）
    _r_bb9a = run([sys.executable, str(SCRIPTS / "browser-capture.py"), "--selftest"])
    check("BB9a. browser-capture --selftest 全绿（配置/场景/capture 布局/负向路径）",
          _r_bb9a.returncode == 0 and "✅" in _r_bb9a.stdout, f"exit={_r_bb9a.returncode} out[:200]={_r_bb9a.stdout[:200]!r}")
    # BB9b. 占位 __UI_RECORD__ 残留 → --check-config exit 2（不猜 UI，同 api 占位纪律）
    _bc_bad = tmp / "bc-placeholder.yaml"
    _bc_bad.write_text("id: current\nchannel: browser\nbrowser:\n  baseUrl: __UI_RECORD__\n  session: s\n"
                       "nav: {a: 1}\nform: {b: 1}\nactorMap: {admin: {username: X, password: Y}}\n", encoding="utf-8")
    _r_bb9b = run([sys.executable, str(SCRIPTS / "browser-capture.py"), "--check-config", "--systems", str(_bc_bad)])
    check("BB9b. browser 配置含 __UI_RECORD__ → exit 2（UI 未录制拒跑）",
          _r_bb9b.returncode == 2 and "__UI_RECORD__" in _r_bb9b.stdout, f"exit={_r_bb9b.returncode}")
    # BB9c. channel 非 browser → exit 2
    _bc_api = tmp / "bc-channel.yaml"
    _bc_api.write_text("id: x\nchannel: api\nbrowser: {baseUrl: http://x, session: s}\n"
                       "nav: {a: 1}\nform: {b: 1}\nactorMap: {}\n", encoding="utf-8")
    _r_bb9c = run([sys.executable, str(SCRIPTS / "browser-capture.py"), "--check-config", "--systems", str(_bc_api)])
    check("BB9c. browser-capture 拒收 channel=api 配置（通道身份校验）",
          _r_bb9c.returncode == 2, f"exit={_r_bb9c.returncode}")
    # BB9c2/BB9c3（1.1.0 可复现性）：正式运行禁 npx latest 回退（未锁版本=联网下载+版本漂移，
    #   正式 PASS 不可复现）；演练/探针放行。以进程内加载 _resolve_cli 直测（不触网）。
    _bc_mod_spec = __import__("importlib.util", fromlist=["util"]).spec_from_file_location("bcap_repro", str(SCRIPTS / "browser-capture.py"))
    _bc_mod = __import__("importlib.util", fromlist=["util"]).module_from_spec(_bc_mod_spec); _bc_mod_spec.loader.exec_module(_bc_mod)
    _saved_env = {k: os.environ.get(k) for k in ("PLAYWRIGHT_CLI", "FLOWTEST_FORMAL_RUN")}
    _fake_home = tmp / "home-no-playwright"; (_fake_home / ".codex").mkdir(parents=True, exist_ok=True)
    _real_home = _bc_mod.Path.home
    try:
        os.environ.pop("PLAYWRIGHT_CLI", None)
        _bc_mod.Path.home = staticmethod(lambda: _fake_home)   # 屏蔽本地包装脚本，逼出 npx 回退路径
        os.environ["FLOWTEST_FORMAL_RUN"] = "1"
        _formal_blocked = False
        try:
            _bc_mod.Browser._resolve_cli()
        except Exception as e:
            _formal_blocked = "npx" in str(e) and "PLAYWRIGHT_CLI" in str(e)
        check("BB9c2. browser: 正式运行禁 npx latest 回退（未锁版本→拒绝，正式 PASS 可复现）",
              _formal_blocked, f"blocked={_formal_blocked}")
        os.environ.pop("FLOWTEST_FORMAL_RUN", None)
        _drill_cli = _bc_mod.Browser._resolve_cli()
        check("BB9c3. browser: 演练/探针仍可用 npx 回退（不误伤非正式路径）",
              _drill_cli[:1] == ["npx"], f"cli={_drill_cli}")
        os.environ["PLAYWRIGHT_CLI"] = "/usr/local/bin/playwright-cli-pinned"
        os.environ["FLOWTEST_FORMAL_RUN"] = "1"
        check("BB9c4. browser: 正式运行显式 PLAYWRIGHT_CLI（已锁版本）→ 放行",
              _bc_mod.Browser._resolve_cli() == ["/usr/local/bin/playwright-cli-pinned"], "")
    finally:
        _bc_mod.Path.home = _real_home
        for k, v in _saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    # BB9d. runner（browser 后端）配置目录缺失 → 全场景 BLOCKED（诚实阻断，不开浏览器）
    _r_bb9d = run([sys.executable, str(SCRIPTS / "run-contract-scenarios.py"), "--scenario-dir", str(sd_pp),
                   "--exec-dir", str(tmp / "exec-bb9d"), "--run-id", "bb9d", "--systems-dir", str(tmp / "sysd-api-bb9d")],
                  env={**os.environ, "FLOWTEST_RUNNER": "browser"})
    _j_bb9d = json.loads((tmp / "exec-bb9d" / "case-results.json").read_text())
    check("BB9d. runner(browser): systems browser 配置目录缺失 → 全 BLOCKED（不伪造执行）",
          _r_bb9d.returncode == 2 and all(x["status"] == "BLOCKED" for x in _j_bb9d),
          f"exit={_r_bb9d.returncode} statuses={[x['status'] for x in _j_bb9d]}")
    # BB9e. 真实 assets 双端配置骨架存在且 legacy 可过结构解析（占位除外——current 是录制骨架属预期）
    _a_legacy = HERE.parent / "assets" / "systems-browser" / "legacy.yaml"
    _a_current = HERE.parent / "assets" / "systems-browser" / "current.yaml"
    check("BB9e. assets/systems-browser 双端配置文件随 skill 分发",
          _a_legacy.exists() and _a_current.exists(),
          f"legacy={_a_legacy.exists()} current={_a_current.exists()}")

    # ---------- 第三十五轮回归（安装器 E2E：install → --check（含篡改负向） → 已安装布局 pipeline --dry-run） ----------
    # 防止再出现"安装器漏复制"（第三十四轮 P0：漏 ftc-runtime.sh/gen-final-report.py/
    # browser-capture.py/gen_flow_tables.py 时干净 clone 直接坏）。install.sh/MANIFEST.txt
    # 只随 skill 源存在（不入部署目标）→ 本节仅 skill 布局可测，项目部署布局跳过。
    if LAYOUT == "skill":
        _SRC_ROOT = HERE.parent
        proj = tmp / "v35-proj"
        (proj / "docs").mkdir(parents=True)
        r = run(["bash", str(_SRC_ROOT / "install.sh"), str(proj)])
        _present = all((proj / p).is_file() for p in (
            ".flow-test-contract/scripts/ftc-runtime.sh",
            ".flow-test-contract/scripts/gen-final-report.py",
            ".flow-test-contract/scripts/browser-capture.py",
            "docs/自动化测试模板/gen_flow_tables.py"))
        check("install: 全量部署 + 含历史漏复制 4 文件 + 字节一致",
              r.returncode == 0 and _present and "字节一致" in r.stdout, f"exit={r.returncode}")
        check("install: systems api 示例种子落位（仅缺失时，不覆盖已有）",
              (proj / ".flow-test-contract/runtime/systems/api/legacy.yaml").is_file()
              and (proj / ".flow-test-contract/runtime/systems/api/current.yaml").is_file())
        r = run(["bash", str(_SRC_ROOT / "install.sh"), "--check", str(proj)])
        check("install --check: 部署副本与源字节一致 → 0", r.returncode == 0, f"exit={r.returncode} {r.stdout[-120:]}")
        (proj / ".flow-test-contract/scripts/conclude.py").write_text("# tampered\n", encoding="utf-8")
        r = run(["bash", str(_SRC_ROOT / "install.sh"), "--check", str(proj)])
        check("install --check: 篡改部署副本 → 抓到(1)",
              r.returncode == 1 and "不一致" in (r.stdout + r.stderr),
              f"exit={r.returncode} {(r.stdout + r.stderr)[-150:]}")
        # 已安装布局 pipeline --dry-run：项目布局自动探测（<root>/docs/自动化测试模板 + <root>/.flow-test-contract）；
        # systems api 用本测试集的无占位假配置（install 种子示例含 __F12_RECORD__ 占位，dry-run 会如实判不可行）
        _cdoc = proj / "docs" / "流程X" / "自动化测试"
        shutil.copytree(g_out, _cdoc / "生成件")
        shutil.copyfile(HERE / "examples" / "liyazhuang-railway.yaml", _cdoc / "test-contract.yaml")
        r = run(["bash", str(proj / ".flow-test-contract" / "scripts" / "pipeline.sh"),
                 "--contract", str(_cdoc / "test-contract.yaml"),
                 "--scenario-dir", str(_cdoc / "生成件" / "flowtrace-scenarios"),
                 "--rules", str(_cdoc / "生成件" / "compare-rules.json"),
                 "--dry-run"], env=ENV_FULLSYS)
        check("已安装布局 pipeline --dry-run → 计划可行(0)",
              r.returncode == 0 and "计划可行" in r.stdout,
              f"exit={r.returncode} out={r.stdout[-200:]!r} err={r.stderr[-200:]!r}")
    else:
        check("install E2E: 仅 skill 布局可测（项目部署布局跳过）", True)

    # ================= 多分支全量生成器（gen-multibranch-contract.py）=================
    _GEN = SCRIPTS / "gen-multibranch-contract.py"
    if _GEN.exists():
        import textwrap
        try:
            import yaml as _yaml
        except ImportError:
            _yaml = None
        if _yaml is None:
            check("multibranch: 缺 pyyaml（生成器依赖）——本机环境项", False)
            raise SystemExit(1)
        _gs = tmp / "multibranch"
        _gs.mkdir(parents=True, exist_ok=True)
        # 基准契约（最小 S2：00→01→02→99，两节点名供映射）
        _tpl = {
            "meta": {"flow_name": "多分支测试流程", "flow_code": "WFA_X_MB_0001", "shape": "S2",
                     "contract_version": 1, "status": "TEST_READY",
                     "instance_policy": "launch",
                     "sources": [], "notes": "", "risk_seeds": []},
            "environments": {"legacy": {"base_url": "http://legacy.test", "login_path": "/login"},
                             "current": {"base_url": "http://current.test", "login_path": "/login"},
                             "health_checks": ["curl -m 3 -o /dev/null -w '%{http_code}' http://legacy.test/  # expect 200",
                                                "curl -m 3 -o /dev/null -w '%{http_code}' http://current.test/  # expect 200"]},
            "accounts": [{"id": "u_a", "name": "甲", "env": "CURRENT_U_A_PWD", "role": "发起人/00"}],
            "nodes": [
                {"code": "00", "name": "环节甲(发起)", "form": "F0", "handlers": ["u_a"], "pool": [], "next": ["01"], "re_edit": True},
                {"code": "01", "name": "环节乙", "form": "F1", "handlers": ["u_b"], "pool": [], "next": ["02"], "re_edit": False},
                {"code": "02", "name": "环节丙", "form": "F2", "handlers": ["u_c"], "pool": [], "next": ["99"], "re_edit": False},
                {"code": "99", "name": "流程结束", "form": None, "handlers": ["u_c"], "pool": [], "next": [], "re_edit": False}],
            "forms": [{"code_legacy": "F0", "code_current": "TBD_00", "fields": []}],
            "field_mappings": [{"legacy_field": "F0X", "target_field": "F0X", "normalize": "trim", "null_policy": "both_null_equal"}],
            "cases": [{"id": "C-01", "kb": "KB-01", "title": "基准", "required": True,
                       "steps": [{"node": "00", "actor": "u_a", "action": "发起", "next": "01", "pick": "乙",
                                  "form": {"KC": "基准矿", "FYDW": "基准矿", "SHDW": "收货基准", "FZ": "发站基准",
                                           "DZ": "到站基准", "CS": "50", "HCBZ": "2000", "GHZL": "1900", "FYRQ": "2026-09-09"}},
                                 {"node": "01", "actor": "u_b", "action": "审核", "next": "02", "pick": "丙"},
                                 {"node": "02", "actor": "u_c", "action": "复核+提交", "next": "99"}],
                       "assertions": ["路径一致"]}],
            "gates": [{"id": "GATE-DEPLOY", "check": "部署", "severity": "P1", "on_fail": "BLOCKED",
                       "evidence_schema": {"kind": "report", "file_format": "json",
                                           "required_fields": [{"path": "data.deploy_status", "op": "eq", "value": "DEPLOYED"}]}}],
            "exemptions": [],
            "conclusions": {"PASS": "a", "FAIL": "b", "BLOCKED": "c"},
        }
        (_gs / "tpl.yaml").write_text(_yaml.dump(_tpl, allow_unicode=True, sort_keys=False), encoding="utf-8")
        # 分支源：3 正移（异构链序）+1 反向（RETURN）+1 未知环节
        (_gs / "branches.py").write_text(textwrap.dedent("""\
            def branch_def(bl):
                defs = {
                  'B-01': "u_a|矿一|环节乙|u_b:环节丙,u_c:",
                  'B-02': "u_a2|矿二|环节丙|u_c:环节乙,u_b:环节丙,u_c:",
                  'B-03': "u_a3|矿三|环节乙|u_b:环节乙,u_b:环节丙,u_c:",
                  'B-9X': "u_r|矿R|环节乙|u_b:RETURN:环节甲(发起),u_a:环节乙,u_b:环节丙,u_c:",
                  'B-91': "u_x|矿X|环节未登记|u_b:环节丙,u_c:",
                }
                if bl not in defs:
                    return None
                launcher, kc, first, steps = defs[bl].split('|')
                return launcher, kc, first, [s for s in steps.split(',') if s]
            """), encoding="utf-8")
        (_gs / "extra.json").write_text(json.dumps({"环节丁": "05"}, ensure_ascii=False), encoding="utf-8")
        r = run([sys.executable, str(_GEN), "gen",
                 "--branches-source", str(_gs / "branches.py"),
                 "--template", str(_gs / "tpl.yaml"),
                 "--outdir", str(_gs / "out"), "--status", "DRAFT"])
        # 基线源含未知环节 B-91 → 1.2.3 起 TEST_READY 被 P0 门禁拒绝，草稿走 DRAFT（产物带 partial）
        _mb_out = _gs / "out" / "test-contract.full.partial.yaml"
        check("multibranch: 3 正移分支全生成（异构链序+重办环节；含未知环节故为 DRAFT partial）",
              r.returncode == 0 and _mb_out.exists(), f"exit={r.returncode} {r.stderr[-150:]!r}")
        if _mb_out.exists():
            _mb = _yaml.safe_load(_mb_out.read_text(encoding="utf-8"))
            _ids = sorted(c["id"] for c in _mb["cases"])
            check("multibranch: case 数=正移分支数（数据驱动，未写死）", _ids == ["C-01", "C-02", "C-03"], str(_ids))
            _c2 = next(c for c in _mb["cases"] if c["id"] == "C-02")
            _seq2 = [s["node"] for s in _c2["steps"]]
            check("multibranch: 链序按分支串（B-02 丙→乙→丙 重办语义）", _seq2 == ["00", "02", "01", "02"], str(_seq2))
            _n00 = next(n for n in _mb["nodes"] if str(n["code"]) == "00")
            check("multibranch: nodes.next=全分支并集拓扑（00→01+02）", sorted(_n00["next"]) == ["01", "02"], str(_n00["next"]))
            _acc = {a["id"] for a in _mb["accounts"]}
            check("multibranch: 账号按 env 键推导扩量", {"u_a", "u_a2", "u_a3", "u_b", "u_c"} <= _acc, str(sorted(_acc)))
            check("multibranch: 反向分支未进正式契约（守护规则 6）", "C-9X" not in _ids)
            _inc = _yaml.safe_load((_gs / "out" / "actorMap.increment.yaml").read_text(encoding="utf-8"))
            check("multibranch: actorMap 增量输出（模板外账号）", "u_a2" in (_inc.get("current") or {}))
        r = run([sys.executable, str(_GEN), "gen",
                 "--branches-source", str(_gs / "branches.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out2"),
                 "--node-map-extra", str(_gs / "extra.json"), "--status", "DRAFT"])
        if (_gs / "out2" / "test-contract.full.partial.yaml").exists():
            _mb2 = _yaml.safe_load((_gs / "out2" / "test-contract.full.partial.yaml").read_text(encoding="utf-8"))
            check("multibranch: --node-map-extra 补码后未知环节仍 fail-closed（B-91 环节未登记≠丁）",
                  "C-91" not in [c["id"] for c in _mb2["cases"]])
        else:
            check("multibranch: --node-map-extra 补码后未知环节仍 fail-closed（B-91 环节未登记≠丁）", False, r.stderr[-200:])
        # ---- exempt 子命令（1.2.0 P1：豁免必须绑定真实 run 账本链，手写 fc.json 一律拒绝）----
        _fc_body = json.dumps({
            "status": "FAIL", "stats": {"diff": 2}, "diffs": [
                {"dim": "field", "key": "C-01.json/s1/QSF->QSF", "legacy": 8.0, "current": None, "reason": "null_policy"},
                {"dim": "field", "key": "C-01.json/s2/FYDW->FYDW", "legacy": "", "current": "甲矿", "reason": "null_policy"}],
            "exempted": [], "coverage": []}, ensure_ascii=False)

        def _mk_run(name: str, *, concl="FAIL", sha_ok=True, with_toolchain=True,
                    rid_match=True, drop: str | None = None) -> Path:
            """造一个 run 目录（账本+结论+对拍+门禁+用例），可按需制造各类破绽用于负向回归。
            1.3.1 起共享核验要求五件齐全——gates/case-results 缺席即拒（与 conclude 同口径）。"""
            rd = _gs / name
            rd.mkdir(parents=True, exist_ok=True)
            (rd / "field-compare.json").write_text(_fc_body, encoding="utf-8")
            (rd / "gates.json").write_text(json.dumps([{"id": "g", "severity": "P0", "passed": True}]), encoding="utf-8")
            (rd / "case-results.json").write_text(json.dumps([{"id": "C-1", "required": True, "status": "PASS"}]), encoding="utf-8")
            sha = __import__("hashlib").sha256((rd / "field-compare.json").read_bytes()).hexdigest()[:16]
            _snap = {}
            for _key, _fname in (("field_compare", "field-compare.json"), ("gates", "gates.json"),
                                 ("case_results", "case-results.json")):
                _fp = rd / _fname
                _raw = _fp.read_bytes()
                _snap[_key] = {"path": str(_fp), "sha256_16": __import__("hashlib").sha256(_raw).hexdigest()[:16]}
            if not sha_ok:
                _snap["field_compare"]["sha256_16"] = "0" * 16
            _min_contract_snapshot(rd, _snap)
            mf = {"run_id": name if rid_match else "run-otherid",
                  "versions": {"source": "v1", "target": "v2", "flow": "f1"},
                  "config_snapshot": _snap, "evidence_paths": [str(rd)]}
            if with_toolchain:
                mf["toolchain"] = {"skill_version": "1.2.0", "manifest_sha256": "a" * 64}
            (rd / "run-manifest.json").write_text(json.dumps(mf, ensure_ascii=False), encoding="utf-8")
            (rd / "summary.json").write_text(json.dumps({"run_id": name, "conclusion": concl},
                                                        ensure_ascii=False), encoding="utf-8")
            if drop:
                (rd / drop).unlink()
            return rd

        _rd_ok = _mk_run("run-mbok")
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_ok),
                 "--approved-by", "selftest", "--approval-ref", "TICKET-123"])
        _ok = (r.returncode == 0 and "match: s1/QSF->QSF" in r.stdout and "match: s2/FYDW->FYDW" in r.stdout
               and "source_run_id: run-mbok" in r.stdout and "source_compare_sha256_16" in r.stdout
               and "approval_ref: TICKET-123" in r.stdout)
        check("multibranch(exempt): 真实 run 目录 → 豁免带 source_run_id/compare_sha/审批工单", _ok, r.stdout[:200])

        r = run([sys.executable, str(_GEN), "exempt", "--compare", str(_rd_ok / "field-compare.json"),
                 "--approved-by", "x", "--approval-ref", "T"])
        check("multibranch(exempt): 旧 --compare 手写入口已移除（伪造 fc 不再可豁免）",
              r.returncode == 2 and ("--run-dir" in (r.stderr + r.stdout) or "unrecognized" in r.stderr),
              f"exit={r.returncode} {r.stderr[-120:]!r}")

        _rd_sha = _mk_run("run-mbsha", sha_ok=False)
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_sha),
                 "--approved-by", "x", "--approval-ref", "T"])
        check("multibranch(exempt): field-compare 与账本 sha 不一致 → 拒绝（对拍被改动）",
              r.returncode == 2 and "sha" in (r.stderr + r.stdout), f"exit={r.returncode}")

        _rd_blk = _mk_run("run-mbblk", concl="BLOCKED")
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_blk),
                 "--approved-by", "x", "--approval-ref", "T"])
        check("multibranch(exempt): BLOCKED/DRILL 结论 run → 拒绝（未过完整门禁不可作豁免依据）",
              r.returncode == 2 and "PASS/FAIL" in (r.stderr + r.stdout), f"exit={r.returncode}")

        _rd_rid = _mk_run("run-mbrid", rid_match=False)
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_rid),
                 "--approved-by", "x", "--approval-ref", "T"])
        check("multibranch(exempt): run-id 错配（账本≠结论≠目录）→ 拒绝",
              r.returncode == 2 and "run-id" in (r.stderr + r.stdout), f"exit={r.returncode}")

        _rd_notc = _mk_run("run-mbnotc", with_toolchain=False)
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_notc),
                 "--approved-by", "x", "--approval-ref", "T"])
        check("multibranch(exempt): 账本缺 toolchain 指纹（不可复现历史 run）→ 拒绝",
              r.returncode == 2 and "toolchain" in (r.stderr + r.stdout), f"exit={r.returncode}")

        _rd_miss = _mk_run("run-mbmiss", drop="run-manifest.json")
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_miss),
                 "--approved-by", "x", "--approval-ref", "T"])
        check("multibranch(exempt): run 证据三件不齐（缺账本）→ 拒绝",
              r.returncode == 2, f"exit={r.returncode}")

        # ---- 分支源解析收紧（1.2.0 P1：仅受控变量，拒绝全文件扫描）----
        (_gs / "polluted.py").write_text(textwrap.dedent("""\
            SAMPLE_CACHE = {'B-77': "u_z|污染矿|环节乙|u_b:环节丙,u_c:"}
            def branch_def(bl):
                defs = {
                  'B-01': "u_a|矿一|环节乙|u_b:环节丙,u_c:",
                }
                return defs.get(bl)
            """), encoding="utf-8")
        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "polluted.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-pol")])
        _pol = _gs / "out-pol" / "test-contract.full.yaml"
        _pol_ids = ([c["id"] for c in _yaml.safe_load(_pol.read_text(encoding="utf-8"))["cases"]]
                    if _pol.exists() else [])
        check("multibranch(源收紧): 同文件样例/缓存 dict 不污染分支集合（B-77 不入选）",
              r.returncode == 0 and _pol_ids == ["C-01"], f"ids={_pol_ids}")

        (_gs / "novar.py").write_text("other_defs = {'B-01': \"u_a|矿|环节乙|u_b:环节丙,u_c:\"}\n", encoding="utf-8")
        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "novar.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-nv")])
        check("multibranch(源收紧): 零候选（无 branch_def）→ 拒绝并提示 --branches-var",
              r.returncode != 0 and "branches-var" in (r.stderr + r.stdout), f"exit={r.returncode}")
        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "novar.py"),
                 "--branches-var", "other_defs",
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-nv2")])
        check("multibranch(源收紧): --branches-var 指定后正常解析（受控变量可配）",
              r.returncode == 0 and (_gs / "out-nv2" / "test-contract.full.yaml").exists(), f"exit={r.returncode}")

        (_gs / "dup.py").write_text(textwrap.dedent("""\
            branch_def = {'B-01': "u_a|矿|环节乙|u_b:环节丙,u_c:"}
            branch_def = {'B-02': "u_a2|矿二|环节乙|u_b:环节丙,u_c:"}
            """), encoding="utf-8")
        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "dup.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-dup")])
        check("multibranch(源收紧): 多处同名赋值 → 歧义拒绝（不猜哪个是权威定义）",
              r.returncode != 0 and "歧义" in (r.stderr + r.stdout), f"exit={r.returncode}")

        # ---- meta.sources 取证源指纹登记（读首次全量生成产物 out/，不受后续用例影响）----
        _mb_src_out = _gs / "out" / "test-contract.full.yaml"
        if _mb_src_out.exists():
            _srcs = (_yaml.safe_load(_mb_src_out.read_text(encoding="utf-8"))
                     .get("meta", {}).get("sources") or [])
            _detail = json.dumps(_srcs, ensure_ascii=False)
            _roles_ok = "branches_source" in _detail and "template_contract" in _detail
            _sha_ok = "sha256=" in _detail
            _cnt_ok = ("总数=5" in _detail and "正移=3" in _detail
                       and "反向=1" in _detail and "跳过=1" in _detail)
            check("multibranch: meta.sources（list 形态）登记取证源路径+SHA256 与分支计数（可自证全量）",
                  _roles_ok and _sha_ok and _cnt_ok,
                  f"detail={_detail[:300]}")

        # ---- 1.2.1 对抗加固回归（P0 YAML 注入 / 诱饵路径 / 符号链接 / 空指纹 / 作用域 / 退出码）----
        def _fc_with(diffs: list) -> str:
            return json.dumps({"status": "FAIL", "diffs": diffs, "exempted": [], "coverage": []}, ensure_ascii=False)

        def _mk_run2(name: str, *, fc_text=None, snap=None, tc=None, symlink=False, concl="FAIL") -> Path:
            rd = _gs / name
            rd.mkdir(parents=True, exist_ok=True)
            body = fc_text if fc_text is not None else _fc_body
            if symlink:
                ext = _gs / (name + "-external.json")
                ext.write_text(body, encoding="utf-8")
                lnk = rd / "field-compare.json"
                if lnk.exists() or lnk.is_symlink():
                    lnk.unlink()
                lnk.symlink_to(ext)
            else:
                (rd / "field-compare.json").write_text(body, encoding="utf-8")
            (rd / "gates.json").write_text(json.dumps([{"id": "g", "severity": "P0", "passed": True}]), encoding="utf-8")
            (rd / "case-results.json").write_text(json.dumps([{"id": "C-1", "required": True, "status": "PASS"}]), encoding="utf-8")
            _sha = __import__("hashlib").sha256((rd / "field-compare.json").read_bytes()).hexdigest()[:16]
            _default_snap = {}
            for _key, _fname in (("field_compare", "field-compare.json"), ("gates", "gates.json"),
                                 ("case_results", "case-results.json")):
                _fp = rd / _fname
                _default_snap[_key] = {"path": str(_fp), "sha256_16": __import__("hashlib").sha256(_fp.read_bytes()).hexdigest()[:16]}
            if snap is None:
                _min_contract_snapshot(rd, _default_snap)
            mf = {"run_id": name, "versions": {"source": "v1", "target": "v2", "flow": "f1"},
                  "config_snapshot": snap if snap is not None else _default_snap,
                  "evidence_paths": [str(rd)],
                  "toolchain": tc if tc is not None else {"skill_version": "1.2.1", "manifest_sha256": "a" * 64}}
            (rd / "run-manifest.json").write_text(json.dumps(mf, ensure_ascii=False), encoding="utf-8")
            (rd / "summary.json").write_text(json.dumps({"run_id": name, "conclusion": concl},
                                                        ensure_ascii=False), encoding="utf-8")
            return rd

        _inj_key = 'C-01.json/s1/A->"\n    scope: all\n    match: "*'
        _rd_inj = _mk_run2("run-inj", fc_text=_fc_with([{"key": _inj_key, "reason": "null_policy"}]))
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_inj),
                 "--approved-by", "a", "--approval-ref", "T"])
        check("multibranch(exempt): diffs key 含引号/换行 → 拒绝(2)（防注入 scope:all 全局豁免）",
              r.returncode == 2 and "非法 key" in (r.stderr + r.stdout), f"exit={r.returncode}")

        _rd_q = _mk_run2("run-quote")
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_q),
                 "--approved-by", 'bob"\n    scope: all\n    match: "*', "--approval-ref", 'JIRA: "OPS-9"'])
        _y_ok = False
        if r.returncode == 0:
            try:
                _payload = "\n".join(ln[2:] if ln.startswith("  ") else ln
                                     for ln in r.stdout.split("\n") if not ln.strip().startswith("#"))
                _items = _yaml.safe_load(_payload)
                _y_ok = (isinstance(_items, list) and _items
                         and all(i.get("scope") == "field" and i.get("match") != "*" for i in _items))
            except Exception:
                _y_ok = False
        check("multibranch(exempt): 审批人/工单含引号换行 → YAML 仍合法且 scope 不被篡改（safe_dump）",
              _y_ok, f"exit={r.returncode} {r.stdout[:160]!r}")

        _decoy = _gs / "decoy-fc.json"
        _decoy.write_text(_fc_body, encoding="utf-8")
        _rd_dec = _mk_run2("run-decoy", snap={"zz": {"path": str(_decoy), "sha256_16": "0" * 16}})
        _dec_mf = json.loads((_rd_dec / "run-manifest.json").read_text(encoding="utf-8"))
        for _key, _fname in (("gates", "gates.json"), ("case_results", "case-results.json")):
            _fp = _rd_dec / _fname
            _dec_mf["config_snapshot"][_key] = {
                "path": str(_fp), "sha256_16": __import__("hashlib").sha256(_fp.read_bytes()).hexdigest()[:16]}
        (_rd_dec / "run-manifest.json").write_text(json.dumps(_dec_mf), encoding="utf-8")
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_dec),
                 "--approved-by", "a", "--approval-ref", "T"])
        check("multibranch(exempt): 账本登记异地同名 field-compare（诱饵路径）→ 拒绝(2)",
              r.returncode == 2 and "账本" in (r.stderr + r.stdout)
              and "field-compare" in (r.stderr + r.stdout), f"exit={r.returncode}")

        _rd_sym = _mk_run2("run-sym", symlink=True)
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_sym),
                 "--approved-by", "a", "--approval-ref", "T"])
        check("multibranch(exempt): field-compare 为符号链接（外链证据）→ 拒绝(2)",
              r.returncode == 2 and "符号链接" in (r.stderr + r.stdout), f"exit={r.returncode}")

        _rd_etc = _mk_run2("run-emptytc", tc={})
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_etc),
                 "--approved-by", "a", "--approval-ref", "T"])
        check("multibranch(exempt): toolchain 空 dict（假指纹）→ 拒绝(2)",
              r.returncode == 2 and "toolchain" in (r.stderr + r.stdout), f"exit={r.returncode}")

        _rd_1s = _mk_run2("run-onesep", fc_text=_fc_with([{"key": "s1/FYDW->FYDW", "reason": "null_policy"}]))
        r = run([sys.executable, str(_GEN), "exempt", "--run-dir", str(_rd_1s),
                 "--approved-by", "a", "--approval-ref", "T"])
        check("multibranch(exempt): 单层 key（形态不合规）→ 干净拒绝(2) 不 crash",
              r.returncode == 2 and "Traceback" not in r.stderr, f"exit={r.returncode}")

        (_gs / "nested.py").write_text(textwrap.dedent("""\
            def branch_def(bl):
                def inner():
                    defs = {'B-01': "u_a|矿|环节乙|u_b:环节丙,u_c:"}
                    return defs
                return inner()
            """), encoding="utf-8")
        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "nested.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-nest")])
        check("multibranch(源收紧): 嵌套函数体内 dict 不算受控作用域 → 拒绝(2)",
              r.returncode == 2 and "未找到分支定义" in (r.stderr + r.stdout), f"exit={r.returncode}")

        (_gs / "cls.py").write_text("class Cfg:\n    branch_def = {'B-01': \"u_a|矿|环节乙|u_b:环节丙,u_c:\"}\n",
                                    encoding="utf-8")
        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "cls.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-cls")])
        check("multibranch(源收紧): 类体内同名赋值不算模块级受控变量 → 拒绝(2)",
              r.returncode == 2, f"exit={r.returncode}")

        (_gs / "nonconst.py").write_text(textwrap.dedent("""\
            X = 'u_z|矿|环节乙|u_b:环节丙,u_c:'
            branch_def = {'B-01': "u_a|矿|环节乙|u_b:环节丙,u_c:", 'B-02': X}
            """), encoding="utf-8")
        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "nonconst.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-nc")])
        check("multibranch(源收紧): 分支值非字符串常量 → 拒绝(2)（不静默丢分支，全量可自证）",
              r.returncode == 2 and "字符串常量" in (r.stderr + r.stdout), f"exit={r.returncode}")

        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "branches.py"),
                 "--template", str(_gs / "nope.yaml"), "--outdir", str(_gs / "out-miss")])
        check("multibranch(gen): --template 不存在 → 干净拒绝(2) 不 traceback",
              r.returncode == 2 and "Traceback" not in r.stderr, f"exit={r.returncode}")

        (_gs / "bad.json").write_text("{not json", encoding="utf-8")
        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "branches.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-badjson"),
                 "--branch-values", str(_gs / "bad.json")])
        check("multibranch(gen): --branch-values 坏 JSON → 干净拒绝(2) 不 traceback",
              r.returncode == 2 and "合法 JSON" in (r.stderr + r.stdout), f"exit={r.returncode}")

        if _mb_src_out.exists():
            _srcs2 = (_yaml.safe_load(_mb_src_out.read_text(encoding="utf-8")).get("meta", {}).get("sources") or [])
            _d2 = json.dumps(_srcs2, ensure_ascii=False)
            _full_sha = [s for s in _srcs2 if "sha256=" in str(s.get("detail", ""))
                         and len(str(s["detail"]).split("sha256=")[1].split()[0]) == 64]
            check("multibranch: 可选源未提供也显式登记 supplied=false + sha256 全长（自证无省略）",
                  _d2.count("supplied=false") == 3 and len(_full_sha) >= 2,
                  f"supplied_false={_d2.count('supplied=false')} full_sha={len(_full_sha)}")

        # ---- 1.2.3：含字母分支号生成的 case id 不合 schema → 生成期即拒（不产注定不合规的契约）----
        (_gs / "alpha.py").write_text(
            "branch_def = {'B-9X': \"u_a|矿|环节乙|u_b:环节丙,u_c:\"}\n", encoding="utf-8")
        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "alpha.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-alpha")])
        check("multibranch: 含字母分支号（C-9X 违反 schema ^C-[0-9]+$）→ 生成期拒绝(2)",
              r.returncode == 2 and "不合契约 schema" in (r.stderr + r.stdout), f"exit={r.returncode}")

        # ---- 1.2.3 P0：不完整分支集不得成为正式契约（分母不得静默缩小）----
        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "branches.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-skip")])
        check("multibranch(P0): 有未知环节被跳过 + 默认 TEST_READY → 拒绝(2) 零正式产物",
              r.returncode == 2 and "拒绝产出 TEST_READY" in (r.stderr + r.stdout)
              and not (_gs / "out-skip" / "test-contract.full.yaml").exists(),
              f"exit={r.returncode} {(r.stderr + r.stdout)[-160:]!r}")

        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "branches.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-partial"),
                 "--status", "DRAFT"])
        _partial = list((_gs / "out-partial").glob("*.partial.yaml")) if (_gs / "out-partial").exists() else []
        check("multibranch(P0): 显式 DRAFT 才允许生成，且产物名带 partial 标识",
              r.returncode == 0 and len(_partial) == 1, f"exit={r.returncode} files={[p.name for p in _partial]}")
        if _partial:
            _pc = _yaml.safe_load(_partial[0].read_text(encoding="utf-8"))
            _pbc = (_pc.get("meta") or {}).get("branch_coverage") or {}
            check("multibranch(P0): partial 契约 branch_coverage 结构化且 complete=false",
                  _pbc.get("skipped_unknown_node") == 1 and _pbc.get("complete") is False
                  and _pbc.get("total_in_source") == _pbc.get("formal_cases", 0) + _pbc.get("reverse_explore", 0)
                  + _pbc.get("skipped_unknown_node", 0)
                  and "PARTIAL" in str(_pc["meta"].get("notes", "")),
                  f"bc={_pbc}")
            r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(_partial[0]),
                     "--level", "test_ready"])
            check("validate(P0): partial 契约（skipped>0）→ test_ready 拒绝(2)",
                  r.returncode == 2 and "分支集不完整" in r.stderr, f"exit={r.returncode} {r.stderr[-150:]!r}")

        # 完整分支集（补全节点码）→ TEST_READY 正常生成且 complete=true
        (_gs / "extra-full.json").write_text(json.dumps({"环节未登记": "05"}, ensure_ascii=False), encoding="utf-8")
        r = run([sys.executable, str(_GEN), "gen", "--branches-source", str(_gs / "branches.py"),
                 "--template", str(_gs / "tpl.yaml"), "--outdir", str(_gs / "out-full"),
                 "--node-map-extra", str(_gs / "extra-full.json")])
        _full = _gs / "out-full" / "test-contract.full.yaml"
        _fbc = (_yaml.safe_load(_full.read_text(encoding="utf-8")).get("meta", {}).get("branch_coverage")
                if _full.exists() else {})
        check("multibranch(P0): 节点码补齐后 skipped=0 → TEST_READY 正常生成且 complete=true",
              r.returncode == 0 and _fbc.get("skipped_unknown_node") == 0 and _fbc.get("complete") is True,
              f"exit={r.returncode} bc={_fbc}")
        if _full.exists():
            r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(_full),
                     "--level", "test_ready"])
            check("validate(P0): 完整分支集契约 → test_ready 通过（不误伤）",
                  r.returncode == 0, f"exit={r.returncode} {r.stderr[-150:]!r}")

            # validator 交叉核验：篡改 branch_coverage 计数使恒等式不成立 → 拒绝
            _tamper = _yaml.safe_load(_full.read_text(encoding="utf-8"))
            _tamper["meta"]["branch_coverage"]["total_in_source"] = 99
            _tp = _gs / "tampered-bc.yaml"
            _tp.write_text(_yaml.safe_dump(_tamper, allow_unicode=True, sort_keys=False), encoding="utf-8")
            r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(_tp),
                     "--level", "test_ready"])
            check("validate(P0): branch_coverage 计数不自洽（total≠formal+reverse+skipped）→ 拒绝(2)",
                  r.returncode == 2 and "不自洽" in r.stderr, f"exit={r.returncode} {r.stderr[-150:]!r}")

            # P1 源指纹复算：分支源被改动后 pipeline dry-run 须拒绝
            _mutated = _gs / "branches-mutated.py"
            shutil.copy(_gs / "branches.py", _mutated)
            _fp_c = _yaml.safe_load(_full.read_text(encoding="utf-8"))
            for _e in _fp_c["meta"]["branch_coverage"]["source_fingerprints"]:
                if _e.get("role") == "branches_source":
                    _e["path"] = str(_mutated)
            _fp_p = _gs / "fp-contract.yaml"
            _fp_p.write_text(_yaml.safe_dump(_fp_c, allow_unicode=True, sort_keys=False), encoding="utf-8")
            _mutated.write_text(_mutated.read_text(encoding="utf-8") + "\n# 生成后被改动\n", encoding="utf-8")
            r = run(["bash", str(SCRIPTS / "pipeline.sh"), "--contract", str(_fp_p),
                     "--scenario-dir", str(g_out / "flowtrace-scenarios"),
                     "--rules", str(g_out / "compare-rules.json"), "--dry-run"], env=ENV_FULLSYS)
            check("pipeline(P1): 取证源生成后被改动 → 指纹复算不一致，正式执行拒绝",
                  "指纹复算不一致" in (r.stdout + r.stderr) or r.returncode == 2,
                  f"exit={r.returncode} {(r.stdout + r.stderr)[-160:]!r}")

        # ---------- 1.3.0 P1 + 1.3.1 P0/P1/P2：豁免取证链入契约门 + 反向分支结论限定 ----------
        # 攻击向量：绕过 exempt 子命令手写豁免 → 契约/对拍入口必须拒绝；1.3.1 起"自制
        # manifest/summary + 手算 sha + 凭空 match"的伪造八字段豁免同样拒绝（共享全链核验）；
        #           反向分支仅 drill 探索 → 正向全 PASS 不得产出顶层 PASS。
        (_gs / "对比测试").mkdir(exist_ok=True)

        def _mk_ledger_run(rid: str, *, concl="FAIL", base: Path | None = None) -> tuple[Path, str]:
            """在 run 证据库（缺省 <_gs>/对比测试/）造一个可被 validator 豁免核验采信的 run 目录
            （五件齐全：账本/结论/对拍/门禁/用例）。"""
            rd = (base or _gs / "对比测试") / f"run-{rid}"
            rd.mkdir(parents=True, exist_ok=True)
            (rd / "field-compare.json").write_text(_fc_body, encoding="utf-8")
            (rd / "gates.json").write_text(json.dumps([{"id": "g", "severity": "P0", "passed": True}]), encoding="utf-8")
            (rd / "case-results.json").write_text(json.dumps([{"id": "C-1", "required": True, "status": "PASS"}]), encoding="utf-8")
            _sha = __import__("hashlib").sha256((rd / "field-compare.json").read_bytes()).hexdigest()[:16]
            _snap = {}
            for _key, _fname in (("field_compare", "field-compare.json"), ("gates", "gates.json"),
                                 ("case_results", "case-results.json")):
                _fp = rd / _fname
                _raw = _fp.read_bytes()
                _snap[_key] = {"path": str(_fp), "sha256_16": __import__("hashlib").sha256(_raw).hexdigest()[:16]}
            _min_contract_snapshot(rd, _snap)
            _mf = {"run_id": f"run-{rid}", "versions": {"source": "v1", "target": "v2", "flow": "f1"},
                   "config_snapshot": _snap, "evidence_paths": [str(rd)],
                   "toolchain": {"skill_version": "1.3.0", "manifest_sha256": "a" * 64}}
            (rd / "run-manifest.json").write_text(json.dumps(_mf, ensure_ascii=False), encoding="utf-8")
            (rd / "summary.json").write_text(json.dumps({"run_id": f"run-{rid}", "conclusion": concl},
                                                        ensure_ascii=False), encoding="utf-8")
            return rd, _sha

        def _contract_with_exemptions(name: str, items: list, outdir: Path | None = None) -> Path:
            _c = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
            _c["exemptions"] = items
            _p = (outdir or _gs) / name
            _p.parent.mkdir(parents=True, exist_ok=True)
            _p.write_text(_y.safe_dump(_c, allow_unicode=True), encoding="utf-8")
            return _p

        def _val(p: Path):
            return run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(p), "--level", "test_ready"])

        # (a) 旧五字段手写豁免（缺取证链三件）→ TEST_READY 拒绝
        _p_old5 = _contract_with_exemptions("ex-old5.yaml",
            [{"id": "EX-H1", "scope": "field", "match": "s1/CS->CS", "reason": "手写", "approved_by": "x"}])
        r = _val(_p_old5)
        check("validate(1.3.0): 手写豁免缺取证链三件（旧五字段）→ 拒绝(2)",
              r.returncode == 2 and "approval_ref" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # (b) 伪造 source_run_id（证据库中无此 run）→ 拒绝
        _p_fake = _contract_with_exemptions("ex-fake.yaml",
            [dict({"id": "EX-H2", "scope": "field", "match": "s1/CS->CS", "reason": "伪造", "approved_by": "x"},
                  **{**EXC_CHAIN, "source_run_id": "19999999999999"})])
        r = _val(_p_fake)
        check("validate(1.3.0): source_run_id 指向不存在的 run → 拒绝(2)（凭空取证链不构成豁免依据）",
              r.returncode == 2 and "源 run 目录不存在" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # (c) 真实 run 目录但 sha 声明被篡改 → 拒绝
        _rdg, _shag = _mk_ledger_run("goodrun")
        _p_sha = _contract_with_exemptions("ex-sha.yaml",
            [dict({"id": "EX-H3", "scope": "field", "match": "s1/QSF->QSF", "reason": "改sha", "approved_by": "x"},
                  **{**EXC_CHAIN, "source_run_id": "goodrun", "source_compare_sha256_16": "f" * 16})])
        r = _val(_p_sha)
        check("validate(1.3.0): 豁免 sha 声明与源 run field-compare 现算不一致 → 拒绝(2)",
              r.returncode == 2 and "sha 不一致" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # (d) 源 run 结论 BLOCKED（未过完整门禁）→ 拒绝
        _rdb, _shab = _mk_ledger_run("blkrun", concl="BLOCKED")
        _p_blk = _contract_with_exemptions("ex-blk.yaml",
            [dict({"id": "EX-H4", "scope": "field", "match": "s1/QSF->QSF", "reason": "blk", "approved_by": "x"},
                  **{**EXC_CHAIN, "source_run_id": "blkrun", "source_compare_sha256_16": _shab})])
        r = _val(_p_blk)
        check("validate(1.3.0): 源 run 结论 BLOCKED → 拒绝(2)（仅 PASS/FAIL run 可作豁免依据）",
              r.returncode == 2 and "PASS/FAIL" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # (e) 取证链完整（真实 run 五件齐全 + sha 一致 + match 绑定源 diffs + 结论 FAIL）→ 通过（不误伤）
        _p_ok = _contract_with_exemptions("ex-ok.yaml",
            [dict({"id": "EX-H5", "scope": "field", "match": "s1/QSF->QSF", "reason": "真实豁免",
                   "approved_by": "x"},
                  **{**EXC_CHAIN, "source_run_id": "goodrun", "source_compare_sha256_16": _shag})])
        r = _val(_p_ok)
        check("validate(1.3.0): 取证链完整且账本核验一致 → test_ready 通过（不误伤）",
              r.returncode == 0, f"exit={r.returncode} {r.stderr[-200:]!r}")

        # ---------- 1.3.1 P0：伪造八字段豁免矩阵（自制证据 + 手算 sha 逐一击破）----------
        _hl = __import__("hashlib")

        def _forge_run(rid_dir: str, *, drop=(), manifest_rid=None, concl="FAIL", diffs=None,
                       fc_status=None, gates_pass=True, case_status="PASS", register=True,
                       ledger_sha="real", with_tc=True, summary_rid=None) -> tuple[Path, str]:
            """按需伪造 run 目录：默认造一个"底层证据完整自洽"的 FAIL run（真实豁免可采信），
            各参数精确注入单一破绽——负向回归逐项定位。返回 (run目录, fc sha16)。"""
            rd = _gs / "对比测试" / rid_dir
            rd.mkdir(parents=True, exist_ok=True)
            diffs = diffs if diffs is not None else [
                {"dim": "field", "key": "C-1.json/s1/A->A", "legacy": 1, "current": 2, "reason": "null_policy"}]
            _status = fc_status or ("FAIL" if diffs else "OK")
            fc_text = json.dumps({"status": _status, "diffs": diffs, "exempted": [], "coverage": []},
                                 ensure_ascii=False)
            (rd / "field-compare.json").write_text(fc_text, encoding="utf-8")
            sha = _hl.sha256(fc_text.encode("utf-8")).hexdigest()[:16]
            files = {
                "gates.json": [{"id": "g", "severity": "P0", "passed": gates_pass}],
                "case-results.json": [{"id": "C-1", "required": True, "status": case_status}],
                "summary.json": {"run_id": summary_rid or rid_dir, "conclusion": concl},
            }
            _snap = {}
            for _key, _fname in (("field_compare", "field-compare.json"), ("gates", "gates.json"),
                                 ("case_results", "case-results.json")):
                _fp = rd / _fname
                if _fname in files:
                    _raw = json.dumps(files[_fname], ensure_ascii=False).encode("utf-8")
                else:
                    _raw = _fp.read_bytes()
                _snap[_key] = {"path": str(_fp), "sha256_16": __import__("hashlib").sha256(_raw).hexdigest()[:16]}
            if ledger_sha != "real":
                _snap["field_compare"]["sha256_16"] = ledger_sha
            if register:
                _min_contract_snapshot(rd, _snap)
            mf = {"run_id": manifest_rid or rid_dir, "versions": {"source": "v1", "target": "v2", "flow": "f1"},
                  "config_snapshot": (_snap if register else {}), "evidence_paths": [str(rd)]}
            if with_tc:
                mf["toolchain"] = {"skill_version": "1.3.1", "manifest_sha256": "a" * 64}
            files["run-manifest.json"] = mf
            for name, body in files.items():
                if name in drop:
                    continue
                (rd / name).write_text(body if isinstance(body, str) else json.dumps(body, ensure_ascii=False),
                                       encoding="utf-8")
            return rd, sha

        def _forge_exemption(rid_dir: str, sha16: str, *, match="s1/A->A", scope="field",
                             eid="EX-F") -> Path:
            return _contract_with_exemptions(f"ex-forge-{eid}.yaml",
                [dict({"id": eid, "scope": scope, "match": match, "reason": "伪造矩阵", "approved_by": "x"},
                      **{**EXC_CHAIN, "source_run_id": rid_dir[4:] if rid_dir.startswith("run-") else rid_dir,
                         "source_compare_sha256_16": sha16})])

        # N1 缺 run-manifest（用户实测绕过形态）→ 拒绝
        _rd, _sha = _forge_run("run-n1", drop=("run-manifest.json",))
        r = _val(_forge_exemption("run-n1", _sha, eid="N1"))
        check("validate(1.3.1): 伪造 run 缺 run-manifest → 拒绝(2)",
              r.returncode == 2 and "run-manifest" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # N2 manifest 未登记 field-compare → 拒绝
        _rd, _sha = _forge_run("run-n2", register=False)
        r = _val(_forge_exemption("run-n2", _sha, eid="N2"))
        check("validate(1.3.1): 伪造 run 未把 field-compare 登记进账本 → 拒绝(2)",
              r.returncode == 2 and ("未以本 run 目录内路径登记" in r.stderr or "config_snapshot" in r.stderr),
              f"exit={r.returncode} {r.stderr[-140:]!r}")

        # N3 账本登记 sha 与现算不符 → 拒绝
        _rd, _sha = _forge_run("run-n3", ledger_sha="0" * 16)
        r = _val(_forge_exemption("run-n3", _sha, eid="N3"))
        check("validate(1.3.1): 账本登记 sha 与 field-compare 现算不符 → 拒绝(2)",
              r.returncode == 2 and "与账本登记 sha 不一致" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # N4 manifest/summary/目录 run-id 三方不一致 → 拒绝
        _rd, _sha = _forge_run("run-n4", manifest_rid="run-other")
        r = _val(_forge_exemption("run-n4", _sha, eid="N4"))
        check("validate(1.3.1): run-id 三方错配 → 拒绝(2)",
              r.returncode == 2 and "run-id" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # N5 缺 toolchain 指纹 → 拒绝
        _rd, _sha = _forge_run("run-n5", with_tc=False)
        r = _val(_forge_exemption("run-n5", _sha, eid="N5"))
        check("validate(1.3.1): 伪造 run 缺 toolchain 指纹 → 拒绝(2)",
              r.returncode == 2 and "toolchain" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # N6 match 不在源 diffs（凭空精确键）→ 拒绝
        _rd, _sha = _forge_run("run-n6")
        r = _val(_forge_exemption("run-n6", _sha, match="s9/ZZ->ZZ", eid="N6"))
        check("validate(1.3.1): 豁免 match 不对应源 run 真实 diffs 条目 → 拒绝(2)",
              r.returncode == 2 and "真实条目" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # N7 scope 与源 diff 维度不符 → 拒绝
        _rd, _sha = _forge_run("run-n7")
        r = _val(_forge_exemption("run-n7", _sha, scope="formula", eid="N7"))
        check("validate(1.3.1): 豁免 scope 与源 diff 维度不符 → 拒绝(2)",
              r.returncode == 2 and "真实条目" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # N8 手写 summary=FAIL 但底层 gates 有未过项（重算=BLOCKED）→ 拒绝
        _rd, _sha = _forge_run("run-n8", gates_pass=False)
        r = _val(_forge_exemption("run-n8", _sha, eid="N8"))
        check("validate(1.3.1): 手写 summary 与底层证据重算矛盾（gate 未过）→ 拒绝(2)",
              r.returncode == 2 and "重算不一致" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # N9 缺 gates.json（五件不齐）→ 拒绝
        _rd, _sha = _forge_run("run-n9", drop=("gates.json",))
        r = _val(_forge_exemption("run-n9", _sha, eid="N9"))
        check("validate(1.3.1): 伪造 run 缺 gates.json → 拒绝(2)",
              r.returncode == 2 and "gates.json" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # N10 fc.status=OK 却有 diffs（证据自相矛盾）→ 拒绝
        _rd, _sha = _forge_run("run-n10", fc_status="OK")
        r = _val(_forge_exemption("run-n10", _sha, eid="N10"))
        check("validate(1.3.1): fc.status=OK 却存在 diffs（重算矛盾）→ 拒绝(2)",
              r.returncode == 2 and "重算不一致" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # N11 完整伪造链 + match 绑定真实 diff + 各件自洽 → 通过（不误伤合法豁免）
        _rd, _sha = _forge_run("run-n11")
        r = _val(_forge_exemption("run-n11", _sha, eid="N11"))
        check("validate(1.3.1): 自制但完全自洽的 run + 绑定真实 diff → 通过（不误伤）",
              r.returncode == 0, f"exit={r.returncode} {r.stderr[-200:]!r}")

        # ---------- 1.3.1 P1：runs-dir 智能解析（生成件/ 布局 → 上一级 对比测试/）----------
        _auto = _gs / "自动化测试-layout"
        (_auto / "对比测试").mkdir(parents=True, exist_ok=True)
        _rdp, _shp = _mk_ledger_run("goodp", base=_auto / "对比测试")
        _p_gen = _contract_with_exemptions("contract.full.yaml",
            [dict({"id": "EX-P1", "scope": "field", "match": "s1/QSF->QSF", "reason": "真实豁免",
                   "approved_by": "x"},
                  **{**EXC_CHAIN, "source_run_id": "goodp", "source_compare_sha256_16": _shp})],
            outdir=_auto / "生成件")
        r = _val(_p_gen)   # 不传 --runs-dir：契约在 生成件/ 下，证据库在 上一级/对比测试/
        check("validate(1.3.1): 生成件/ 布局契约缺省解析到 上一级/对比测试 证据库 → 通过",
              r.returncode == 0, f"exit={r.returncode} {r.stderr[-200:]!r}")


        # (f) compare: 手写旧五字段豁免（精确 match）不再吞差异 → FAIL + invalid_exemptions
        rules_h = fc_rules(fms=FM)
        rules_h["exemptions"] = [{"id": "EX-H6", "scope": "field", "match": "s1/OLD_CODE->NEW_CODE",
                                  "reason": "绕过 exempt 手写", "approved_by": "x"}]
        r = cmp_run(tmp / "h6", rules_h,
                    [cap(steps={"s1": {"fields": {"OLD_CODE": "A"}}})],
                    [cap(steps={"s1": {"fields": {"NEW_CODE": "B"}}})])
        j = json.loads((tmp / "h6" / "out" / "field-compare.json").read_text())
        check("compare(1.3.0): 绕过 exempt 手写的精确豁免不生效 → 差异保留 FAIL",
              r.returncode == 1 and len(j["diffs"]) == 1 and len(j["invalid_exemptions"]) == 1,
              f"exit={r.returncode} diffs={len(j['diffs'])} invalid={len(j['invalid_exemptions'])}")

        # (g) compare: 取证链字段格式非法（sha16 非 16 位 hex）→ 不生效
        rules_h2 = fc_rules(fms=FM)
        rules_h2["exemptions"] = [dict({"id": "EX-H7", "scope": "field", "match": "s1/OLD_CODE->NEW_CODE",
                                        "reason": "r", "approved_by": "x"},
                                       **{**EXC_CHAIN, "source_compare_sha256_16": "NOT-A-SHA"})]
        r = cmp_run(tmp / "h7", rules_h2,
                    [cap(steps={"s1": {"fields": {"OLD_CODE": "A"}}})],
                    [cap(steps={"s1": {"fields": {"NEW_CODE": "B"}}})])
        j = json.loads((tmp / "h7" / "out" / "field-compare.json").read_text())
        check("compare(1.3.0): sha16 格式非法 → 豁免不生效（FAIL + invalid）",
              r.returncode == 1 and len(j["invalid_exemptions"]) == 1 and len(j["diffs"]) == 1,
              f"exit={r.returncode} invalid={len(j['invalid_exemptions'])}")

        # (h) gen: 反向分支>0 → accounted_complete=true 但 formal_complete=false
        if _full.exists():
            _fbc13 = (_y.safe_load(_full.read_text(encoding="utf-8")).get("meta", {}).get("branch_coverage") or {})
            check("multibranch(1.3.0): 反向 1 支仅探索 → accounted_complete=true / formal_complete=false",
                  _fbc13.get("accounted_complete") is True and _fbc13.get("formal_complete") is False
                  and _fbc13.get("reverse_explore") == 1, f"bc={_fbc13}")

        # (i) validate: 旧 1.2.x 契约缺双态完成度字段 → 拒绝（显式迁移，重新生成）
        if _full.exists():
            _legacy_bc = _y.safe_load(_full.read_text(encoding="utf-8"))
            for _k in ("accounted_complete", "formal_complete"):
                _legacy_bc["meta"]["branch_coverage"].pop(_k, None)
            _p_lbc = _gs / "bc-legacy.yaml"
            _p_lbc.write_text(_y.safe_dump(_legacy_bc, allow_unicode=True, sort_keys=False), encoding="utf-8")
            r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(_p_lbc), "--level", "test_ready"])
            check("validate(1.3.0): branch_coverage 缺 accounted_complete/formal_complete → 拒绝(2)",
                  r.returncode == 2 and "accounted_complete" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

            # (j) validate: formal_complete 与 reverse_explore 矛盾（自证造假）→ 拒绝
            _lie_bc = _y.safe_load(_full.read_text(encoding="utf-8"))
            _lie_bc["meta"]["branch_coverage"]["formal_complete"] = True
            _p_lie = _gs / "bc-lie.yaml"
            _p_lie.write_text(_y.safe_dump(_lie_bc, allow_unicode=True, sort_keys=False), encoding="utf-8")
            r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(_p_lie), "--level", "test_ready"])
            check("validate(1.3.0): formal_complete=true 但 reverse_explore>0（自相矛盾）→ 拒绝(2)",
                  r.returncode == 2 and "矛盾" in r.stderr, f"exit={r.returncode} {r.stderr[-140:]!r}")

        # (k) conclude: 反向仅 drill、正向全 PASS → 顶层 conclusion=BLOCKED（防只读
        #     conclusion 的下游误判全量成功），forward_conclusion=PASS 仅作信息性字段
        _bc_c = _gs / "bc-contract.yaml"
        _bc_c.write_text(_y.safe_dump({
            "meta": {"flow_code": "WFA_X_0001", "branch_coverage": {
                "total_in_source": 4, "formal_cases": 3, "reverse_explore": 1,
                "skipped_unknown_node": 0, "accounted_complete": True,
                "formal_complete": False, "complete": True}},
            "cases": [{"id": "C-1", "required": True}, {"id": "C-2", "required": True},
                      {"id": "C-3", "required": True}]}, allow_unicode=True), encoding="utf-8")
        r = concl("k-fwd", contract=_bc_c, cases=json.dumps([
            {"id": "C-1", "required": True, "status": "PASS"},
            {"id": "C-2", "required": True, "status": "PASS"},
            {"id": "C-3", "required": True, "status": "PASS"}]))
        _fwd_sum = json.loads((tmp / "k-fwd" / "summary.json").read_text(encoding="utf-8"))
        _fwd_md = (tmp / "k-fwd" / "summary.md").read_text(encoding="utf-8")
        check("conclude(1.3.1): 反向仅探索 + 正向 3/3 PASS → conclusion=BLOCKED（不得顶层 PASS）",
              r.returncode == 2 and _fwd_sum.get("conclusion") == "BLOCKED"
              and _fwd_sum.get("forward_conclusion") == "PASS"
              and (_fwd_sum.get("branch_scope") or {}).get("conclusion_scope") == "forward_branches_only"
              and "不构成全量 PASS" in _fwd_md,
              f"exit={r.returncode} concl={_fwd_sum.get('conclusion')} fwd={_fwd_sum.get('forward_conclusion')} "
              f"scope={(_fwd_sum.get('branch_scope') or {}).get('conclusion_scope')}")
        _fwd_reasons = " ".join(_fwd_sum.get("blocked_reasons") or [])
        check("conclude(1.3.1): 降级原因入 blocked_reasons（forward_conclusion 标注非正式结论）",
              "forward_conclusion=PASS" in _fwd_reasons and "信息性字段" in _fwd_reasons,
              _fwd_reasons[:200])

        # (k2) 反向仅探索 + 正向存在真实差异 → 维持 FAIL（FAIL 无"成功"误读面，不做范围降级）
        r = concl("k-fail", contract=_bc_c,
                  fc=json.dumps({"status": "FAIL", "diffs": [{"dim": "field", "key": "k", "legacy": 1, "current": 2, "reason": "t"}],
                                 "exempted": [], "coverage": []}),
                  cases=json.dumps([
                      {"id": "C-1", "required": True, "status": "PASS"},
                      {"id": "C-2", "required": True, "status": "PASS"},
                      {"id": "C-3", "required": True, "status": "PASS"}]))
        _fail_sum = json.loads((tmp / "k-fail" / "summary.json").read_text(encoding="utf-8"))
        check("conclude(1.3.1): 反向仅探索 + 正向有真实差异 → 维持 FAIL 不降级",
              r.returncode == 1 and _fail_sum.get("conclusion") == "FAIL"
              and (_fail_sum.get("branch_scope") or {}).get("conclusion_scope") == "forward_branches_only"
              and "forward_conclusion" not in _fail_sum,
              f"exit={r.returncode} concl={_fail_sum.get('conclusion')}")

        # (l) conclude: 契约自称 formal_complete=true 却有 reverse_explore>0 → 自相矛盾 BLOCKED
        _bc_lie = _gs / "bc-contract-lie.yaml"
        _bc_lie.write_text(_y.safe_dump({
            "meta": {"flow_code": "WFA_X_0001", "branch_coverage": {
                "total_in_source": 4, "formal_cases": 3, "reverse_explore": 1,
                "skipped_unknown_node": 0, "accounted_complete": True,
                "formal_complete": True, "complete": True}},
            "cases": [{"id": "C-1", "required": True}, {"id": "C-2", "required": True},
                      {"id": "C-3", "required": True}]}, allow_unicode=True), encoding="utf-8")
        r = concl("k-lie", contract=_bc_lie, cases=json.dumps([
            {"id": "C-1", "required": True, "status": "PASS"},
            {"id": "C-2", "required": True, "status": "PASS"},
            {"id": "C-3", "required": True, "status": "PASS"}]))
        check("conclude(1.3.0): 契约自称 formal_complete=true 却有反向分支 → BLOCKED(2) 自相矛盾",
              r.returncode == 2 and "自相矛盾" in reasons_of(tmp / "k-lie"),
              f"exit={r.returncode} reasons={reasons_of(tmp / 'k-lie')[:150]}")

    else:
        check("multibranch: 生成器不在（MANIFEST 未登记？）", False, str(_GEN))

    # 1.3.3 P0：run 账本登记的 gates/case-results 哈希也必须现算一致；只校验
    # field-compare 会允许事后改写门禁/用例结果后继续拿该 run 生成豁免。
    _stale = tmp / "stale-evidence"; _stale.mkdir()
    _stale_fc = {"status": "FAIL", "diffs": [{"dim": "field", "key": "s1/F->F", "reason": "t"}],
                 "exempted": [], "coverage": []}
    (_stale / "field-compare.json").write_text(json.dumps(_stale_fc), encoding="utf-8")
    (_stale / "gates.json").write_text(json.dumps([{"id": "G", "passed": True}]), encoding="utf-8")
    (_stale / "case-results.json").write_text(json.dumps([{"id": "C-1", "required": True, "status": "PASS"}]), encoding="utf-8")
    import hashlib as _stale_hash
    _stale_fc_sha = _stale_hash.sha256((_stale / "field-compare.json").read_bytes()).hexdigest()[:16]
    (_stale / "run-manifest.json").write_text(json.dumps({
        "run_id": "stale-evidence", "toolchain": {"skill_version": "1.3.3", "manifest_sha256": "a" * 64},
        "config_snapshot": {
            "field_compare": {"path": str(_stale / "field-compare.json"), "sha256_16": _stale_fc_sha},
            "gates": {"path": str(_stale / "gates.json"), "sha256_16": "0" * 16},
            "case_results": {"path": str(_stale / "case-results.json"), "sha256_16": "0" * 16}}}), encoding="utf-8")
    (_stale / "summary.json").write_text(json.dumps({"run_id": "stale-evidence", "conclusion": "FAIL"}), encoding="utf-8")
    _ev_spec = importlib.util.spec_from_file_location("run_evidence_stale_test", SCRIPTS / "run_evidence.py")
    _ev_mod = importlib.util.module_from_spec(_ev_spec); _ev_spec.loader.exec_module(_ev_mod)
    try:
        _ev_mod.verify_run_dir(_stale)
        _stale_rejected = False
    except _ev_mod.RunEvidenceError:
        _stale_rejected = True
    check("run_evidence: gates/case-results 账本 sha 失配 → 拒绝", _stale_rejected)

    # ========== 1.3.4 证据链对抗加固回归（六个外部发现逐项锁定） ==========
    import hashlib as _h34
    _v34 = tmp / "v134"; _v34.mkdir()

    def _build_ev_run(name: str, *, fc_body, summary_concl, versions=None,
                      contract_path=None, gates_pass=True, case_status="PASS"):
        rd = _v34 / name; rd.mkdir(parents=True, exist_ok=True)
        (rd / "gates.json").write_text(json.dumps(
            [{"id": "G", "severity": "P0", "passed": gates_pass}]), encoding="utf-8")
        (rd / "case-results.json").write_text(json.dumps(
            [{"id": "C-1", "required": True, "status": case_status}]), encoding="utf-8")
        (rd / "field-compare.json").write_text(json.dumps(fc_body), encoding="utf-8")
        snap = {}
        for key, fname in (("gates", "gates.json"), ("case_results", "case-results.json"),
                           ("field_compare", "field-compare.json")):
            fp = rd / fname
            snap[key] = {"path": str(fp), "abs_path": str(fp.resolve()),
                         "sha256_16": _h34.sha256(fp.read_bytes()).hexdigest()[:16]}
        if contract_path is not None:
            snap["contract"] = {"path": str(contract_path), "abs_path": str(contract_path.resolve()),
                                "sha256_16": _h34.sha256(contract_path.read_bytes()).hexdigest()[:16]}
        _min_contract_snapshot(rd, snap)
        mf = {"run_id": name,
              "versions": versions if versions is not None else {"source": "v1", "target": "v2", "flow": "f1"},
              "config_snapshot": snap,
              "toolchain": {"skill_version": "1.3.4", "manifest_sha256": "b" * 64},
              "evidence_paths": [str(rd)]}
        (rd / "run-manifest.json").write_text(json.dumps(mf), encoding="utf-8")
        (rd / "summary.json").write_text(json.dumps({"run_id": name, "conclusion": summary_concl}),
                                         encoding="utf-8")
        return rd

    _ok_fc = {"status": "FAIL", "diffs": [{"dim": "field", "key": "s1/A->A", "legacy": 1, "current": 2,
                                          "reason": "x"}], "exempted": [], "coverage": [], "observe": []}
    _spec34 = importlib.util.spec_from_file_location("run_evidence_v34", SCRIPTS / "run_evidence.py")
    _re34 = importlib.util.module_from_spec(_spec34); _spec34.loader.exec_module(_re34)

    # (1) 因 unrecorded 版本本应 BLOCKED 的 run，summary 被手改成 FAIL → 拒绝
    _r_blk = _build_ev_run("run-blk34", fc_body={"status": "OK", "diffs": [], "exempted": [],
                                                 "coverage": [], "observe": []},
                           summary_concl="FAIL",
                           versions={"source": "unrecorded", "target": "v2", "flow": "f1"})
    try:
        _re34.verify_run_dir(_r_blk); _blk34_rejected = False
    except _re34.RunEvidenceError as e:
        _blk34_rejected = "复算" in str(e) or "PASS/FAIL" in str(e)
    check("1.3.4 P0: BLOCKED run 被手改 FAIL → 豁免核验拒绝（结论全量复算）", _blk34_rejected)

    # (2) 完全自洽的 FAIL run 不因复算被误伤
    _r_ok = _build_ev_run("run-ok34", fc_body=_ok_fc, summary_concl="FAIL")
    try:
        _re34.verify_run_dir(_r_ok); _ok34_accepted = True
    except _re34.RunEvidenceError as e:
        _ok34_accepted = False; print("   误伤原因:", e)
    check("1.3.4 P0: 自洽 FAIL run + 结论复算一致 → 通过（不误伤）", _ok34_accepted)

    # (3) 契约快照：基线通过；事后改写契约 → 拒绝；删除契约 → 拒绝
    _c34 = _v34 / "contract34.yaml"
    _c34.write_text("meta:\n  flow_code: WFA_X_0001\ncases:\n- id: C-1\n  required: true\n",
                    encoding="utf-8")
    _r_ct = _build_ev_run("run-contract34",
                          fc_body={"status": "OK", "diffs": [], "exempted": [], "coverage": [], "observe": []},
                          summary_concl="PASS", contract_path=_c34)
    try:
        _re34.verify_run_dir(_r_ct); _ct_base = True
    except _re34.RunEvidenceError as e:
        _ct_base = False; print("   契约基线误伤:", e)
    check("1.3.4 P0: 登记契约且 sha 一致的 PASS run → 通过", _ct_base)
    _c34.write_text(_c34.read_text(encoding="utf-8") + "# mutated after run\n", encoding="utf-8")
    try:
        _re34.verify_run_dir(_r_ct); _ct_mut = False
    except _re34.RunEvidenceError as e:
        _ct_mut = "契约快照 SHA 不符" in str(e)
    check("1.3.4 P0: 契约事后被修改 → 拒绝（sha 复算）", _ct_mut)
    _c34.unlink()
    try:
        _re34.verify_run_dir(_r_ct); _ct_del = False
    except _re34.RunEvidenceError as e:
        _ct_del = "不存在" in str(e)
    check("1.3.4 P0: 契约被删除 → 拒绝（证据链断裂）", _ct_del)

    # (4) 单个手写 summary.json 不再能生成正式报告
    _gfr34_fake = _v34 / "run-fake34"; _gfr34_fake.mkdir()
    (_gfr34_fake / "summary.json").write_text(json.dumps(
        {"run_id": "run-fake34", "conclusion": "PASS"}), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "gen-final-report.py"), "--run-dir", str(_gfr34_fake)])
    check("1.3.4 P1: 手写单 summary → 拒绝生成正式报告(2)，无 ✅ PASS 报告",
          r.returncode == 2 and not (_gfr34_fake / "对比测试报告.md").exists(),
          f"exit={r.returncode}")
    r = run([sys.executable, str(SCRIPTS / "gen-final-report.py"), "--run-dir", str(_gfr34_fake),
             "--allow-unverified"])
    _draft_p = _gfr34_fake / "对比测试报告-未核验草稿.md"
    _draft_ok = (r.returncode == 0 and _draft_p.exists()
                 and not (_gfr34_fake / "对比测试报告.md").exists()
                 and "UNVERIFIED" in _draft_p.read_text(encoding="utf-8")
                 and "未核验" in _draft_p.name)
    check("1.3.4 P1/1.3.6: --allow-unverified 只产 UNVERIFIED 草稿（独立文件名，不占正式名）",
          _draft_ok, f"exit={r.returncode}")

    # (5) 人工内容拆独立文件且不被覆盖；已有机器报告默认拒绝静默覆盖
    r = run([sys.executable, str(SCRIPTS / "gen-final-report.py"), "--run-dir", str(_r_ok)])
    _gfr_first = r.returncode == 0 and (_r_ok / "人工发现.md").exists()
    (_r_ok / "人工发现.md").write_text(
        "# 产品级发现\n\n| 编号 | 级别 | 现象 | 根因/建议 | 状态 |\n|---|---|---|---|---|\n"
        "| D-34 | P1 | 人工标记H34 | r | 待跟进 |\n", encoding="utf-8")
    r2 = run([sys.executable, str(SCRIPTS / "gen-final-report.py"), "--run-dir", str(_r_ok)])
    r3 = run([sys.executable, str(SCRIPTS / "gen-final-report.py"), "--run-dir", str(_r_ok), "--overwrite"])
    _human_text = (_r_ok / "人工发现.md").read_text(encoding="utf-8")
    _report_text = (_r_ok / "对比测试报告.md").read_text(encoding="utf-8")
    check("1.3.4 P1: 人工发现独立成文 / 默认拒绝覆盖 / --overwrite 保留人工内容",
          _gfr_first and r2.returncode == 2 and r3.returncode == 0
          and "人工标记H34" in _human_text and "人工标记H34" in _report_text,
          f"first={r.returncode} re={r2.returncode} ov={r3.returncode}")

    # (6) 报告元数据：版本读 SKILL.md frontmatter（测试同样动态取版——写死字面量会在每次 bump 失真）；
    # run-id 不双重前缀
    _ver_fm = re.search(r"^version:\s*(\S+)", (SCRIPTS.parent / "SKILL.md").read_text(encoding="utf-8"), re.M)
    _ver_exp = f"v{_ver_fm.group(1)}" if _ver_fm else ""
    check("1.3.4 P2: 报告版本动态读取且标题无 run-run- 双前缀",
          _ver_exp and _ver_exp in _report_text and "run-run-" not in _report_text
          and "（run-ok34）" in _report_text, _report_text.splitlines()[0])

    # (7) Python：显式导出空值=存在，不从 env 文件恢复
    _env34 = _v34 / "env"; _env34.write_text("FTC_V34_PROBE=from_file\n", encoding="utf-8")
    _env34.chmod(0o600)
    _es34 = importlib.util.spec_from_file_location("ftc_env_v34", SCRIPTS / "ftc_env.py")
    _em34 = importlib.util.module_from_spec(_es34); _es34.loader.exec_module(_em34)
    os.environ["FTC_V34_PROBE"] = ""
    _em34._loaded.clear()
    _n34 = _em34.load_env_file(_env34)
    _py_empty_ok = (os.environ.get("FTC_V34_PROBE") == "" and _n34 == 0)
    os.environ.pop("FTC_V34_PROBE", None)
    _em34._loaded.clear(); _em34.load_env_file(_env34)
    _py_unset_ok = os.environ.get("FTC_V34_PROBE") == "from_file"
    os.environ.pop("FTC_V34_PROBE", None)
    check("1.3.4 P1: Python 显式导出空值不被 env 文件覆盖；未设置时正常加载",
          _py_empty_ok and _py_unset_ok, f"empty={_py_empty_ok} unset={_py_unset_ok}")

    # (8) Bash 镜像：空导出保持空；0644 权限拒绝（跨语言一致性）
    _func34 = _v34 / "ftc-func.sh"
    _src = (SCRIPTS / "pipeline.sh").read_text(encoding="utf-8")
    _a = _src.index("ftc_load_runtime_env()")
    _b = _src.index("\n}\n", _a) + 2
    _func34.write_text(_src[_a:_b], encoding="utf-8")
    r = run(["bash", "-c", f'source "{_func34}"; export FTC_V34_PROBE=""; '
                           f'ftc_load_runtime_env "{_env34}"; printf "[%s]" "$FTC_V34_PROBE"'])
    _bash_empty_ok = (r.returncode == 0 and "[]" in r.stdout)
    _env34_bad = _v34 / "env-bad"; _env34_bad.write_text("X=1\n", encoding="utf-8"); _env34_bad.chmod(0o644)
    r = run(["bash", "-c", f'source "{_func34}"; unset FTC_V34_PROBE; '
                           f'ftc_load_runtime_env "{_env34_bad}"'])
    _bash_perm_ok = (r.returncode == 2 and "0600" in r.stderr)
    check("1.3.4 P1: Bash 空导出语义一致 + 非 0600 拒绝", _bash_empty_ok and _bash_perm_ok,
          f"empty={_bash_empty_ok} perm={_bash_perm_ok} {r.stderr[-100:]}")

    # ===== v1.3.6 回归：run_evidence 契约模式最小键 / toolchain SHA 格式 / 报告统计防伪造 =====
    # (9) 删除 contract/rules/scenarios 登记 → 拒绝（防只改 manifest 抹掉契约登记）
    _r_mink = _build_ev_run("run-mink36", fc_body=_ok_fc, summary_concl="FAIL")
    _mf_mink = json.loads((_r_mink / "run-manifest.json").read_text(encoding="utf-8"))
    for _k in ("contract", "rules", "scenarios"):
        _mf_mink["config_snapshot"].pop(_k, None)
    (_r_mink / "run-manifest.json").write_text(json.dumps(_mf_mink), encoding="utf-8")
    try:
        _re34.verify_run_dir(_r_mink); _mink36 = False
    except _re34.RunEvidenceError as e:
        _mink36 = "契约模式" in str(e)
    check("1.3.6 P1: 删除 contract/rules/scenarios 登记 → 豁免核验拒绝", _mink36)
    # (10) evidence_paths 清空 → 拒绝
    _r_ep = _build_ev_run("run-ep36", fc_body=_ok_fc, summary_concl="FAIL")
    _mf_ep = json.loads((_r_ep / "run-manifest.json").read_text(encoding="utf-8"))
    _mf_ep["evidence_paths"] = []
    (_r_ep / "run-manifest.json").write_text(json.dumps(_mf_ep), encoding="utf-8")
    try:
        _re34.verify_run_dir(_r_ep); _ep36 = False
    except _re34.RunEvidenceError as e:
        _ep36 = "evidence_paths" in str(e)
    check("1.3.6 P1: evidence_paths 清空 → 豁免核验拒绝", _ep36)
    # (11) manifest_sha256 非 64hex → 拒绝
    _r_msha = _build_ev_run("run-msha36", fc_body=_ok_fc, summary_concl="FAIL")
    _mf_msha = json.loads((_r_msha / "run-manifest.json").read_text(encoding="utf-8"))
    _mf_msha["toolchain"]["manifest_sha256"] = "zz" * 32
    (_r_msha / "run-manifest.json").write_text(json.dumps(_mf_msha), encoding="utf-8")
    try:
        _re34.verify_run_dir(_r_msha); _msha36 = False
    except _re34.RunEvidenceError as e:
        _msha36 = "SHA256" in str(e)
    check("1.3.6 P1: toolchain.manifest_sha256 非 64hex SHA → 豁免核验拒绝", _msha36)

    # (12) 保持真实 conclusion=FAIL、只伪造 summary 统计 → 拒绝出正式报告
    _r_stats = _build_ev_run("run-stats36", fc_body=_ok_fc, summary_concl="FAIL")
    _sum_canon = {"run_id": "run-stats36", "conclusion": "FAIL", "p0_count": 0, "p1_count": 0,
                  "required_cases": {"total": 1, "done": 1}, "semantic_diffs": [{}],
                  "exempted_diffs": [], "failed_cases": [], "blocked_reasons": []}
    (_r_stats / "summary.json").write_text(json.dumps(_sum_canon), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "gen-final-report.py"), "--run-dir", str(_r_stats)])
    _stats_base = r.returncode == 0 and (_r_stats / "对比测试报告.md").exists()
    _sum_mut = dict(_sum_canon, p0_count=99, p1_count=88, required_cases={"total": 999, "done": 999})
    (_r_stats / "summary.json").write_text(json.dumps(_sum_mut), encoding="utf-8")
    r2 = run([sys.executable, str(SCRIPTS / "gen-final-report.py"), "--run-dir", str(_r_stats), "--overwrite"])
    check("1.3.6 P1: summary 统计被伪造（conclusion 不变）→ 拒绝出正式报告(2)",
          _stats_base and r2.returncode == 2 and "不一致" in (r2.stdout + r2.stderr),
          f"base={_stats_base} exit={r2.returncode} {(r2.stdout + r2.stderr)[-220:]!r}")

    fails = [x for x in RESULTS if not x[1]]
    print(f"\n== {len(RESULTS) - len(fails)}/{len(RESULTS)} 通过 ==")
    if fails:
        print("失败项: " + ", ".join(x[0] for x in fails))
        raise SystemExit(1)


def quick() -> int:
    """1.3.0 P2：会话前置快检（秒级）——资产齐全 + 语法 + 关键门禁抽样。

    只覆盖"skill 被改坏/被裁剪/关键门禁被绕开"的最小检测面；305+ 条负向回归
    （selftest.py 缺省/--full）仍是版本发布与深度审计的唯一样本，不可用 --quick 替代。
    """
    tmp = Path(tempfile.mkdtemp(prefix="ftc-selftest-quick-"))
    atexit.register(shutil.rmtree, tmp, ignore_errors=True)
    import yaml as _y

    def cap(flow="WFA_X_0001", pairs=None, steps=None, extra=None):
        o = {"flow_code": flow, "case_id": "C-1", "fixture_pairs": pairs or [], "steps": steps or {}}
        o.update(extra or {})
        return o

    # Q1. 资产齐全（MANIFEST 唯一清单，fail-closed；清单随 skill 根分发）
    _manifest = HERE.parent / "MANIFEST.txt"
    if _manifest.is_file():
        missing = []
        for line in _manifest.read_text(encoding="utf-8").splitlines():
            f = line.split("\t", 1)[0]
            if not f or f.startswith("#"):
                continue
            if not (HERE.parent / f).is_file():
                missing.append(f)
        check("quick: MANIFEST 资产齐全", not missing, f"缺失={missing[:5]}")
    else:
        check("quick: MANIFEST 资产齐全（项目部署布局跳过）", LAYOUT == "project",
              "skill 布局却缺 MANIFEST.txt——skill 不完整；项目布局以 install.sh --check 校验资产")

    # Q2. 语法（py 逐文件 compile，零字节码；sh 用 bash -n）
    bad_syn = []
    for base in (SCRIPTS, HERE):
        for p in sorted(base.glob("*.py")):
            try:
                compile(p.read_text(encoding="utf-8"), str(p), "exec")
            except Exception as e:
                bad_syn.append(f"{p.name}: {type(e).__name__}")
        for p in sorted(base.glob("*.sh")):
            r = run(["bash", "-n", str(p)])
            if r.returncode != 0:
                bad_syn.append(f"{p.name}: bash -n")
    check("quick: 全部脚本语法可编译", not bad_syn, f"坏={bad_syn[:5]}")

    # Q3. validator: 铁路实例 test_ready 通过（含 schema，豁免取证链 schema 一并生效）
    r = run([sys.executable, str(HERE / "validate-contract.py"),
             "--contract", str(HERE / "examples" / "liyazhuang-railway.yaml"), "--level", "test_ready"])
    check("quick: 铁路实例 test_ready 通过", r.returncode == 0, r.stderr[-160:])

    # Q4. validator: 空白模板必须拒绝（门禁在场，非形同虚设）
    r = run([sys.executable, str(HERE / "validate-contract.py"),
             "--contract", str(HERE / "test-contract.template.yaml"), "--level", "test_ready"])
    check("quick: 空白模板 test_ready 拒绝", r.returncode == 2, f"exit={r.returncode}")

    # Q5. 关键门禁(1.3.0)：旧五字段手写豁免 → TEST_READY 拒绝
    ex = _y.safe_load((HERE / "examples" / "liyazhuang-railway.yaml").read_text(encoding="utf-8"))
    ex["exemptions"] = [{"id": "EX-Q1", "scope": "field", "match": "s1/CS->CS",
                         "reason": "手写", "approved_by": "x"}]
    p5 = tmp / "ex-old5.yaml"; p5.write_text(_y.safe_dump(ex, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(HERE / "validate-contract.py"), "--contract", str(p5), "--level", "test_ready"])
    check("quick: 旧五字段手写豁免 → test_ready 拒绝（取证链门禁在场）",
          r.returncode == 2 and "approval_ref" in r.stderr, f"exit={r.returncode}")

    # Q6. 关键门禁(1.3.0)：比较器对无取证链豁免不吞差异
    rules_bad = fc_rules(fms=FM)
    rules_bad["exemptions"] = [{"id": "EX-Q2", "scope": "field", "match": "s1/OLD_CODE->NEW_CODE",
                                "reason": "手写", "approved_by": "x"}]
    r = cmp_run(tmp / "q6", rules_bad,
                [cap(steps={"s1": {"fields": {"OLD_CODE": "A"}}})],
                [cap(steps={"s1": {"fields": {"NEW_CODE": "B"}}})])
    try:
        j = json.loads((tmp / "q6" / "out" / "field-compare.json").read_text())
    except Exception:
        j = {}
    check("quick: 无取证链豁免不吞差异 → FAIL", r.returncode == 1 and len(j.get("diffs", [])) == 1,
          f"exit={r.returncode} j={json.dumps(j)[:120]}")

    # Q7. 关键门禁(1.3.0)：conclude 反向分支结论限定（forward_branches_only）
    def _snap(d: Path) -> dict:
        import hashlib
        snap = {}
        for key, fname in (("gates", "gates.json"), ("case_results", "case-results.json"),
                           ("field_compare", "field-compare.json")):
            f = d / fname
            snap[key] = {"path": fname, "abs_path": str(f.resolve()),
                         "sha256_16": hashlib.sha256(f.read_bytes()).hexdigest()[:16]}
        return {"config_snapshot": snap, "versions": {"source": "v1", "target": "v2", "flow": "f1"}}

    d = tmp / "q7"; d.mkdir()
    (d / "gates.json").write_text(json.dumps([{"id": "g", "severity": "P0", "passed": True}]), encoding="utf-8")
    (d / "field-compare.json").write_text(json.dumps({"status": "OK", "diffs": [], "exempted": [], "coverage": []}), encoding="utf-8")
    (d / "case-results.json").write_text(json.dumps([{"id": "C-1", "required": True, "status": "PASS"}]), encoding="utf-8")
    (d / "run-manifest.json").write_text(json.dumps(dict({"run_id": "q7"}, **_snap(d))), encoding="utf-8")
    bc_c = tmp / "q7-contract.yaml"
    bc_c.write_text(_y.safe_dump({
        "meta": {"flow_code": "WFA_X_0001", "branch_coverage": {
            "total_in_source": 2, "formal_cases": 1, "reverse_explore": 1,
            "skipped_unknown_node": 0, "accounted_complete": True,
            "formal_complete": False, "complete": True}},
        "cases": [{"id": "C-1", "required": True}]}, allow_unicode=True), encoding="utf-8")
    r = run([sys.executable, str(SCRIPTS / "conclude.py"), "--report-dir", str(d), "--contract", str(bc_c)])
    try:
        _q7 = json.loads((d / "summary.json").read_text())
        _scope = (_q7.get("branch_scope") or {}).get("conclusion_scope")
    except Exception:
        _q7, _scope = {}, None
    check("quick: 反向仅探索 → 顶层 BLOCKED + forward_conclusion=PASS（不产出会被误读的全量 PASS）",
          r.returncode == 2 and _q7.get("conclusion") == "BLOCKED"
          and _q7.get("forward_conclusion") == "PASS" and _scope == "forward_branches_only",
          f"exit={r.returncode} concl={_q7.get('conclusion')} fwd={_q7.get('forward_conclusion')} scope={_scope}")

    # Q8. v1.3.3：runtime env 必须是私有实体文件，并与 Python 解析规则一致
    _env_mod_path = SCRIPTS / "ftc_env.py"
    import importlib.util as _ilu
    _es = _ilu.spec_from_file_location("ftc_env_selftest", _env_mod_path)
    _em = _ilu.module_from_spec(_es); _es.loader.exec_module(_em)
    _env_p = tmp / "runtime-env"
    _env_p.write_text("PWD_KEY= secret-with-spaces  \nexport QUOTED_KEY=\"quoted value\"\n", encoding="utf-8")
    _env_p.chmod(0o644)
    _em._loaded.clear()
    try:
        _em.load_env_file(_env_p)
        _env_perm_ok = False
    except Exception:
        _env_perm_ok = True
    check("quick: runtime env 非 0600 拒绝", _env_perm_ok)
    _env_p.chmod(0o600)
    for _k in ("PWD_KEY", "QUOTED_KEY"):
        os.environ.pop(_k, None)
    _em._loaded.clear(); _em.load_env_file(_env_p)
    check("quick: runtime env Python 解析 trim/引号一致",
          os.environ.get("PWD_KEY") == "secret-with-spaces" and os.environ.get("QUOTED_KEY") == "quoted value")
    os.environ["FLOWTEST_DEFAULT_PWD"] = "default-secret"
    os.environ.pop("FLOWTEST_ALLOW_DEFAULT_PWD", None)
    _em._loaded.clear()
    try:
        _em.resolve_credentials(_env_p, "actor", "MISSING_USER", "MISSING_PWD", warn=lambda _m: None)
        _default_blocked = False
    except _em.CredentialError:
        _default_blocked = True
    os.environ["FLOWTEST_ALLOW_DEFAULT_PWD"] = "1"
    _em._loaded.clear()
    _default_ok = _em.resolve_credentials(_env_p, "actor", "MISSING_USER", "MISSING_PWD", warn=lambda _m: None) == ("actor", "default-secret")
    os.environ.pop("FLOWTEST_DEFAULT_PWD", None); os.environ.pop("FLOWTEST_ALLOW_DEFAULT_PWD", None)
    check("quick: 默认密码必须显式授权且授权后可用", _default_blocked and _default_ok)

    # Q9. Python/Bash 交叉：显式导出空值两侧都视为"存在"（不从 env 文件恢复）；bash 非 0600 拒绝
    _probe = tmp / "probe.env"
    _probe.write_text("FTC_QUICK_PROBE=from-file\n", encoding="utf-8"); _probe.chmod(0o600)
    _pl = (SCRIPTS / "pipeline.sh").read_text(encoding="utf-8")
    _fa = _pl.index("ftc_load_runtime_env()"); _fb = _pl.index("\n}\n", _fa) + 2
    _func_f = tmp / "ftc-func.sh"; _func_f.write_text(_pl[_fa:_fb], encoding="utf-8")
    r = run(["bash", "-c", f'source "{_func_f}"; export FTC_QUICK_PROBE=""; '
                           f'ftc_load_runtime_env "{_probe}"; printf "[%s]" "$FTC_QUICK_PROBE"'])
    _bash_empty = (r.returncode == 0 and "[]" in r.stdout)
    os.environ["FTC_QUICK_PROBE"] = ""
    _em._loaded.clear(); _n_quick = _em.load_env_file(_probe)
    _py_empty = (os.environ.get("FTC_QUICK_PROBE") == "" and _n_quick == 0)
    os.environ.pop("FTC_QUICK_PROBE", None)
    _bad = tmp / "bad.env"; _bad.write_text("X=1\n", encoding="utf-8"); _bad.chmod(0o644)
    r = run(["bash", "-c", f'source "{_func_f}"; ftc_load_runtime_env "{_bad}"'])
    _bash_perm = (r.returncode == 2 and "0600" in r.stderr)
    check("quick: Python/Bash 空导出语义一致（不从文件恢复）+ Bash 非 0600 拒绝",
          _bash_empty and _py_empty and _bash_perm, f"bash_empty={_bash_empty} py_empty={_py_empty} bash_perm={_bash_perm}")

    fails = [x for x in RESULTS if not x[1]]
    print(f"\n== [quick] {len(RESULTS) - len(fails)}/{len(RESULTS)} 通过（快检不含 300+ 条负向回归；"
          f"发布/深度审计请跑 selftest.py --full）==")
    if fails:
        print("失败项: " + ", ".join(x[0] for x in fails))
        return 1
    return 0


if __name__ == "__main__":
    import argparse as _ap

    _p = _ap.ArgumentParser(description=__doc__, formatter_class=_ap.ArgumentDefaultsHelpFormatter)
    _g = _p.add_mutually_exclusive_group()
    _g.add_argument("--quick", action="store_true",
                    help="会话前置快检：资产/语法/关键门禁抽样（秒级）；不能替代全量负向回归")
    _g.add_argument("--full", action="store_true",
                    help="全量负向回归（与缺省一致；版本发布与深度审计用）")
    _args = _p.parse_args()
    sys.exit(quick()) if _args.quick else main()
