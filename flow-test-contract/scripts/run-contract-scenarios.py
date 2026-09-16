#!/usr/bin/env python3
"""run-contract-scenarios.py v2 —— 契约场景执行器（诚实脚手架，fail-closed；通道自持）。

v2.0（2026-09-07 第十二轮·通道自持）：双端执行不再依赖外部 FlowTrace CLI——
  后端选择 FLOWTRACE_RUNNER（默认 api）：
    api  内置 api-capture.py 纯 HTTP 采集（login/todo/launch/form/submit 五原语，
         配置于运行态 systems/api/{legacy,current}.yaml——skill 布局在 $SKILL/runtime/<项目键>/）
    cli  兼容后端：仅当显式设置 FLOWTRACE_CLI 时启用（不再探测 PATH/默认路径——
         外部 FlowTrace 依赖已移除，保留仅为老环境过渡）
    none 无后端 → 全部场景 BLOCKED(runner-unavailable)，诚实阻断
  无论哪个后端，PASS 铁律不变：退出码 0 + 双端采集存在且可采信
  （v1.2 三重校验：执行前清残留 + mtime 时间窗 + run_id/case_id 身份绑定）。

v1.2（2026-09-07 第十一轮审计）：采集证据采信面收紧——预置/遗留采集文件
  可被本次运行冒领（假 PASS 面）：执行前清空 field-captures/、mtime 时间窗、
  采集须带 run_id==本 run-id 与 case_id==本用例 身份标识。
v1.1（2026-09-06 第五轮审计）：顶层异常兜底 exit 2（本执行器只有 0/2 两态）。

产出: <exec-dir>/case-results.json [{id, required, status, reason}]
      （后端真实执行时产 field-captures/{legacy,current}/<case>.json 供对拍/结论）
用法:
  python3 run-contract-scenarios.py --scenario-dir <dir> --exec-dir <dir> --run-id <id> \
      [--systems-dir <runtime>/systems/api]    # api 后端的两侧配置目录（缺省 runtime 推导）
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：uv run --with pyyaml python3 run-contract-scenarios.py …")

SCRIPT_DIR = Path(__file__).resolve().parent
API_CAPTURE = SCRIPT_DIR / "api-capture.py"
BROWSER_CAPTURE = SCRIPT_DIR / "browser-capture.py"
SIDES = ("legacy", "current")


def runtime_root() -> Path:
    """运行态根（ftc-runtime.sh 的 python 镜像，勿单侧改规则）：
    env FLOWTEST_RUNTIME_DIR → skill 布局 $SKILL/runtime/<项目键>-<hash8>/
    → 项目部署布局 <root>/.flow-test-contract/runtime。与 .flowtrace/ 彻底分离。"""
    env = os.environ.get("FLOWTEST_RUNTIME_DIR") or os.environ.get("FLOWTRACE_RUNTIME_DIR")
    if env:
        return Path(env)
    root = os.environ.get("FLOWTEST_PROJECT_ROOT")
    if not root:
        try:
            root = subprocess.run(["git", "-C", os.getcwd(), "rev-parse", "--show-toplevel"],
                                  capture_output=True, text=True).stdout.strip() or os.getcwd()
        except Exception:
            root = os.getcwd()
    rp = str(Path(root).resolve())
    key = re.sub(r"[^A-Za-z0-9._-]", "_", Path(rp).name).rstrip("_") or "proj"
    h = hashlib.sha1(rp.encode()).hexdigest()[:8]
    base = Path(__file__).resolve().parent.parent
    if (base / "assets").is_dir():
        return base / "runtime" / f"{key}-{h}"      # skill 自持布局
    return base / "runtime"                          # 项目部署布局


def detect_runner() -> tuple[str, str | None]:
    """→ (backend, cli_path)。api=默认；browser=浏览器通道（browser-capture.py）；
    cli 仅显式 FLOWTRACE_CLI（自持后不再盲探）。"""
    mode = (os.environ.get("FLOWTEST_RUNNER", os.environ.get("FLOWTRACE_RUNNER", "api")).strip().lower() or "api")
    if mode == "api":
        return "api", None
    if mode == "browser":
        return "browser", None
    if mode == "cli":
        cli = (os.environ.get("FLOWTEST_CLI") or os.environ.get("FLOWTRACE_CLI", "")).strip()
        if cli and (Path(cli).exists() or shutil.which(cli)):
            return "cli", cli
        return "none", None
    return "none", None


def clear_captures(exec_dir: Path) -> None:
    """清空本 run 的采集区（第十一轮）：本执行器独占 exec-dir/field-captures——
    预置/遗留采集文件一律清除，绝不留给本次运行冒领（假 PASS 面）。"""
    cap = exec_dir / "field-captures"
    try:
        if cap.exists():
            shutil.rmtree(cap)
    except Exception as e:
        print(f"[runner] BLOCKED: 采集区清理失败 {cap}（{type(e).__name__}: {e}）——"
              f"历史残留不可采信，拒绝在污染采集区上执行", file=sys.stderr)
        raise SystemExit(2)


def capture_trustworthy(cap: Path, run_id: str, case_id: str, t0: float, problems: list[str]) -> bool:
    """单端采集可采信校验（第十一轮）：存在 + 时间窗 + JSON 对象 + run_id/case_id 身份绑定。"""
    side = cap.parent.name
    if not cap.exists():
        problems.append(f"{side} 侧采集缺失: {cap.name}")
        return False
    try:
        if cap.stat().st_mtime < t0 - 5:  # 5s 时钟容忍
            problems.append(f"{side} 侧采集 mtime 早于本次执行开始（疑似遗留文件）")
            return False
    except OSError as e:
        problems.append(f"{side} 侧采集不可读: {e}")
        return False
    try:
        obj = json.loads(cap.read_text(encoding="utf-8"))
    except Exception as e:
        problems.append(f"{side} 侧采集不可解析为 JSON: {e}")
        return False
    if not isinstance(obj, dict):
        problems.append(f"{side} 侧采集非 JSON 对象")
        return False
    rid = obj.get("run_id", obj.get("runId"))
    cid = obj.get("case_id", obj.get("caseId"))
    if rid is None or cid is None:
        problems.append(f"{side} 侧采集缺 run_id/case_id 身份标识（采集须与本 run-id/用例绑定）")
        return False
    if str(rid) != run_id:
        problems.append(f"{side} 侧 run_id 错配: {rid!r} ≠ {run_id!r}")
        return False
    if str(cid) != case_id:
        problems.append(f"{side} 侧 case_id 错配: {cid!r} ≠ {case_id!r}")
        return False
    return True


def run_api_backend(results: list[dict], systems_dir: Path, run_id: str, exec_dir: Path, t0: float) -> None:
    """api 后端：逐场景 × 双侧调用 api-capture.py；双侧成功且采集可采信 → PASS。"""
    if not API_CAPTURE.exists():
        for r in results:
            r.update(status="BLOCKED", reason=f"api-capture.py 缺失: {API_CAPTURE}")
        return
    if not systems_dir.is_dir():
        for r in results:
            r.update(status="BLOCKED", reason=f"systems api 配置目录不存在: {systems_dir}"
                    "（建 runtime/systems/api/{legacy,current}.yaml 或设 FLOWTEST_SYSTEMS_API_DIR）")
        print(f"[runner] BLOCKED: systems api 配置目录不存在 {systems_dir}", file=sys.stderr)
        return
    cfgs: dict[str, Path | None] = {s: (systems_dir / f"{s}.yaml") for s in SIDES}
    missing = [s for s, p in cfgs.items() if not p.exists()]
    if missing:
        for r in results:
            r.update(status="BLOCKED", reason=f"systems api 配置缺失: {missing}（{systems_dir}）")
        return
    capbase = exec_dir / "field-captures"
    for r in results:
        errs: list[str] = []
        for side in SIDES:
            cmd = [sys.executable, str(API_CAPTURE), "--systems", str(cfgs[side]),
                   "--scenario", r.get("scenario", ""), "--run-id", run_id, "--exec-dir", str(exec_dir)]
            try:
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
                if p.returncode != 0:
                    tail = (p.stderr or p.stdout or "").strip().splitlines()
                    errs.append(f"{side} 侧 api 采集失败: {tail[-1][:600] if tail else f'exit {p.returncode}'}")
            except Exception as e:
                errs.append(f"{side} 侧 api 采集调用失败: {e}")
            if errs:
                break
        if errs:
            r["status"] = "BLOCKED"
            r["reason"] = "；".join(errs)
        else:
            problems: list[str] = []
            ok_l = capture_trustworthy(capbase / "legacy" / f"{r['id']}.json", run_id, str(r["id"]), t0, problems)
            ok_c = capture_trustworthy(capbase / "current" / f"{r['id']}.json", run_id, str(r["id"]), t0, problems)
            if ok_l and ok_c:
                r["status"] = "PASS"
            else:
                r["status"] = "BLOCKED"
                r["reason"] = f"api 双端执行完成但采集不可采信: {'; '.join(problems)[:220]}"
        print(f"[runner] {r['id']} → {r['status']}")


def run_browser_backend(results: list[dict], systems_dir: Path, run_id: str, exec_dir: Path, t0: float) -> None:
    """browser 后端：逐场景 × 双侧调用 browser-capture.py（playwright-cli 驱动）。
    采集采信与 api 后端同律（清残留/mtime/身份三要素）；配置目录 runtime/systems/browser（缺省 runtime 推导）。
    单侧成立即记 BLOCKED 原因（诚实暴露缺口），双侧齐才 PASS。"""
    if not BROWSER_CAPTURE.exists():
        for r in results:
            r.update(status="BLOCKED", reason=f"browser-capture.py 缺失: {BROWSER_CAPTURE}")
        return
    if not systems_dir.is_dir():
        for r in results:
            r.update(status="BLOCKED", reason=f"systems browser 配置目录不存在: {systems_dir}"
                    "（从 skill assets/systems-browser/ 起步拷贝后做 UI 录制）")
        print(f"[runner] BLOCKED: systems browser 配置目录不存在 {systems_dir}", file=sys.stderr)
        return
    cfgs: dict[str, Path] = {s: (systems_dir / f"{s}.yaml") for s in SIDES}
    missing = [s for s, p in cfgs.items() if not p.exists()]
    if missing:
        for r in results:
            r.update(status="BLOCKED", reason=f"systems browser 配置缺失: {missing}（{systems_dir}）")
        return
    capbase = exec_dir / "field-captures"
    for r in results:
        errs: list[str] = []
        for side in SIDES:
            cmd = [sys.executable, str(BROWSER_CAPTURE), "--systems", str(cfgs[side]),
                   "--scenario", r.get("scenario", ""), "--run-id", run_id, "--exec-dir", str(exec_dir)]
            try:
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
                if p.returncode != 0:
                    tail = (p.stderr or p.stdout or "").strip().splitlines()
                    errs.append(f"{side} 侧 browser 采集失败: {tail[-1][:600] if tail else f'exit {p.returncode}'}")
            except Exception as e:
                errs.append(f"{side} 侧 browser 采集调用失败: {e}")
            if errs:
                break
        if errs:
            r["status"] = "BLOCKED"
            r["reason"] = "；".join(errs)
        else:
            problems: list[str] = []
            ok_l = capture_trustworthy(capbase / "legacy" / f"{r['id']}.json", run_id, str(r["id"]), t0, problems)
            ok_c = capture_trustworthy(capbase / "current" / f"{r['id']}.json", run_id, str(r["id"]), t0, problems)
            if ok_l and ok_c:
                r["status"] = "PASS"
            else:
                r["status"] = "BLOCKED"
                r["reason"] = f"browser 双端执行完成但采集不可采信: {'; '.join(problems)[:220]}"
        print(f"[runner] {r['id']} → {r['status']}")


def run_cli_backend(results: list[dict], cli: str, run_id: str, exec_dir: Path, t0: float) -> None:
    """cli 兼容后端（显式 FLOWTRACE_CLI）：$CLI run --scenario <f> --run-id <id>，
    接口以该 CLI 实际为准；裸退出码不采信（同 api 后端的三重采集校验）。"""
    print(f"[runner] 使用 CLI(兼容后端): {cli}")
    capbase = exec_dir / "field-captures"
    for r in results:
        if str(cli).endswith(".js"):
            cmd = ["node", str(cli), "run", "--scenario", r.get("scenario", ""), "--run-id", run_id]
        else:
            cmd = [str(cli), "run", "--scenario", r.get("scenario", ""), "--run-id", run_id]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
            problems: list[str] = []
            if p.returncode != 0:
                r["status"] = "ERROR"
            else:
                ok_l = capture_trustworthy(capbase / "legacy" / f"{r['id']}.json", run_id, str(r["id"]), t0, problems)
                ok_c = capture_trustworthy(capbase / "current" / f"{r['id']}.json", run_id, str(r["id"]), t0, problems)
                r["status"] = "PASS" if (ok_l and ok_c) else "BLOCKED"
            r["reason"] = (p.stderr or p.stdout or "")[:300]
            if r["status"] == "BLOCKED":
                r["reason"] = (f"CLI 退出码 0 但采集证据不可采信: {'; '.join(problems)[:220]}")
        except Exception as e:
            r.update(status="ERROR", reason=f"调用失败: {e}")
        print(f"[runner] {r['id']} → {r['status']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario-dir", required=True)
    ap.add_argument("--exec-dir", required=True)
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--systems-dir", default=os.environ.get("FLOWTRACE_SYSTEMS_API_DIR", ".flowtrace/systems/api"),
                    help="api 后端两侧配置目录（含 legacy.yaml / current.yaml）")
    args = ap.parse_args()

    sdir = Path(args.scenario_dir)
    files = sorted(sdir.glob("*.yaml")) if sdir.exists() else []
    # 第二十一轮：FLOWTRACE_CASES="C-01,C-02" 场景子集过滤（pipeline --cases 透传；
    # 按场景内 case_id 精确匹配，未匹配文件跳过并在 results 汇总 SKIPPED 记录）
    _cases_env = {x.strip().upper() for x in (os.environ.get("FLOWTEST_CASES") or os.environ.get("FLOWTRACE_CASES", "")).split(",") if x.strip()}
    if _cases_env and files:
        _kept, _skipped = [], []
        for f in files:
            try:
                _sc = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
                _cid = str(_sc.get("case_id") or "").upper()
            except Exception:
                _cid = ""
            if _cid and _cid in _cases_env:
                _kept.append(f)
            else:
                _skipped.append(_cid or f.name)
        files = _kept
        if _skipped:
            print(f"[runner] FLOWTRACE_CASES 过滤：跳过 {_skipped}", file=sys.stderr)
    if not files:
        print(f"[runner] BLOCKED: 场景目录为空/不存在 {sdir}", file=sys.stderr)
        results = []
        out = Path(args.exec_dir)
        out.mkdir(parents=True, exist_ok=True)
        clear_captures(out)
        (out / "case-results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
        raise SystemExit(2)
    results = []
    for f in files:
        try:
            sc = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
        except Exception as e:
            results.append({"id": f.stem, "required": True, "status": "BLOCKED", "reason": f"场景损坏: {e}"})
            continue
        # 结果 id 优先用契约用例号 case_id（conclude --contract 交叉核对依赖此字段）
        rid = sc.get("case_id") or sc.get("id") or f.stem
        results.append({"id": str(rid), "required": bool(sc.get("required", True)),
                        "status": "PENDING", "scenario": str(f)})

    exec_dir = Path(args.exec_dir)
    clear_captures(exec_dir)  # 第十一轮：先清残留——本 run 的采集区只允许本 run 的产物
    backend, cli = detect_runner()
    t0 = time.time()  # 采集时间窗起点：早于此的采集文件一律不采信
    if backend == "api":
        print(f"[runner] 后端=api（skill 自持 HTTP 采集；systems={args.systems_dir}）")
        run_api_backend(results, Path(args.systems_dir), args.run_id, exec_dir, t0)
    elif backend == "browser":
        bdir = (os.environ.get("FLOWTEST_SYSTEMS_BROWSER_DIR") or os.environ.get("FLOWTRACE_SYSTEMS_BROWSER_DIR")
                or str(runtime_root() / "systems" / "browser"))
        print(f"[runner] 后端=browser（playwright-cli 浏览器采集；systems={bdir}）")
        run_browser_backend(results, Path(bdir), args.run_id, exec_dir, t0)
    elif backend == "cli":
        run_cli_backend(results, cli, args.run_id, exec_dir, t0)
    else:
        for r in results:
            r.update(status="BLOCKED",
                     reason="runner-unavailable：无可用执行后端（FLOWTRACE_RUNNER=api 需 systems api 配置与可达服务；"
                            "cli 需显式 FLOWTRACE_CLI——诚实阻断，不伪造执行）")
        print("[runner] BLOCKED: 无可用执行后端——全部场景置 BLOCKED", file=sys.stderr)

    out = exec_dir
    out.mkdir(parents=True, exist_ok=True)
    (out / "case-results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[runner] case-results → {out / 'case-results.json'}")
    blocked = any(r.get("required") and r.get("status") in ("BLOCKED", "ERROR", "PENDING") for r in results)
    raise SystemExit(2 if blocked else 0)


if __name__ == "__main__":
    # 第五轮审计：任何未预期异常一律 exit 2（本执行器无 FAIL(1) 语义，crash 不得引入新码）
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        import traceback

        traceback.print_exc()
        print(f"[runner] BLOCKED: 执行器内部异常（fail-closed）: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
