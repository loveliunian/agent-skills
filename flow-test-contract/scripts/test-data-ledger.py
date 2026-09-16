#!/usr/bin/env python3
"""test-data-ledger.py —— 测试数据与残留实例生命周期账本（v1.5.0 任务完成门④）。

解决"中断的 run 留下实例/数据池占用，反复重跑环境越来越脏"：
  init    run 开始前建账（登记契约 fixtures/resources claim）
  record  run 采集完成后登记双端实例号（从 field-captures 实读，零编造）
  close   结论产出后收账：逐 case 标记 released/residual；BLOCKED 生成"可安全清理项"
          （仅列我们 launch 的实例号 + 建议动作，**绝不自动执行破坏性清理**）
  show    查看账本

账本落 run 目录 test-data-ledger.json；同 run-id 只 init 一次（防重写）；record/close
就地更新登记段但保留 append 历史（entries 审计 trail）。本账本是**辅助审计产物**，
不参与结论判定（结论仍只认 conclude_core 证据链）。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
sys.dont_write_bytecode = True   # 审计第 11 轮 F11-1：动态加载共享模块零字节码（skill 目录零副作用）
from datetime import datetime, timedelta
from pathlib import Path

VERSION = "test-data-ledger.py v3（skill v1.7.2）"

_SCRIPT_DIR = Path(__file__).resolve().parent


def _runtime_root() -> Path:
    """运行态根（run-contract-scenarios.runtime_root 唯一实现复用——连字符文件名走 importlib）。"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("ftc_rcs_ld", _SCRIPT_DIR / "run-contract-scenarios.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.runtime_root()


def registry_path() -> Path:
    """跨 run 租约 registry（项目级、私有运行态）：runtime/leases.json。"""
    return _runtime_root() / "leases.json"


def _registry_read() -> list[dict]:
    p = registry_path()
    if not p.is_file():
        return []
    try:
        j = json.loads(p.read_text(encoding="utf-8"))
        return j if isinstance(j, list) else []
    except Exception:
        return []


def _registry_write(entries: list[dict]) -> None:
    p = registry_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + f".tmp-{os.getpid()}")
    tmp.write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, p)   # 原子替换（同目录）
    try:
        p.with_name(p.name + ".lock").unlink(missing_ok=True)
    except Exception:
        pass


def _registry_claim(ledger_claims: list[dict], owner: str, lease_hours: float) -> list[str]:
    """租约 claim：冲突（同 id 活跃租约且 owner 不同）→ 返回冲突清单不写入。"""
    import time as _t
    lock = registry_path().with_suffix(".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(50):
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.close(fd)
            break
        except FileExistsError:
            _t.sleep(0.1)
    else:
        return ["<lock>：租约 registry 锁获取超时——请重试或手工清理 leases.json.lock"]
    try:
        now = datetime.now().astimezone()
        entries = _registry_read()
        conflicts = []
        active: dict[str, dict] = {}
        for e in entries:
            try:
                exp = datetime.fromisoformat(str(e.get("expires_at")))
                if exp > now:
                    active.setdefault(str(e.get("id")), e)
            except Exception:
                pass
        for c in ledger_claims:
            cid = str(c.get("id"))
            hit = active.get(cid)
            if hit and str(hit.get("owner")) != owner:
                conflicts.append(f"{c.get('kind')}:{cid} 已被 {hit.get('owner')} 租约占用"
                                 f"（至 {hit.get('expires_at')}）")
        if conflicts:
            return conflicts
        have = {str(e.get("id")) for e in entries if str(e.get("owner")) == owner}
        for c in ledger_claims:
            cid = str(c.get("id"))
            if cid in have:
                continue
            entries.append({"id": cid, "kind": c.get("kind"), "owner": owner,
                            "acquired_at": _now(),
                            "expires_at": (datetime.now().astimezone()
                                           + timedelta(hours=lease_hours)).isoformat(timespec="seconds"),
                            "exclusive": True})
        _registry_write(entries)
        return []
    finally:
        try:
            lock.unlink(missing_ok=True)
        except Exception:
            pass
LEDGER_NAME = "test-data-ledger.json"


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _load(d: Path) -> dict | None:
    p = d / LEDGER_NAME
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"⛔ 账本不可读 {p}: {e}", file=sys.stderr)
        return None


def _save(d: Path, led: dict) -> None:
    p = d / LEDGER_NAME
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(led, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(p)


def cmd_init(a) -> int:
    d = Path(a.run_dir)
    d.mkdir(parents=True, exist_ok=True)
    if (d / LEDGER_NAME).exists() and not a.overwrite:
        print(f"⛔ 账本已存在: {d / LEDGER_NAME}（防重写；--overwrite 才放行）", file=sys.stderr)
        return 2
    claims: list[dict] = []
    _hosts: set = set()   # v1.7.3：--contract 缺省也初始化（此前 UnboundLocalError exit 2）
    if a.contract:
        try:
            import yaml
            c = yaml.safe_load(Path(a.contract).read_text(encoding="utf-8")) or {}
        except Exception as e:
            print(f"⚠ 契约不可读（claim 段为空）: {e}", file=sys.stderr)
            c = {}
        _lease_base = {"owner": d.name,
                       "acquired_at": _now(),
                       "expires_at": (datetime.now().astimezone()
                                      + timedelta(hours=a.lease_hours)).isoformat(timespec="seconds"),
                       "exclusive": True}
        for f in c.get("fixtures") or []:
            if isinstance(f, dict):
                claims.append({"kind": "fixture", "id": f.get("fixture_pair_id"),
                               "detail": f"legacy={f.get('legacy_ref')} current={f.get('current_ref')}",
                               "rule": f.get("pairing_rule"), "lease": dict(_lease_base)})
        for r in c.get("resources") or []:
            if isinstance(r, dict):
                claims.append({"kind": "resource", "id": r.get("id"),
                               "detail": f"occupy_on={r.get('occupy_on')} release_on={r.get('release_on')}",
                               "check": r.get("check") or "", "lease": dict(_lease_base)})
        for _env in (c.get("environments") or {}).values():
            if isinstance(_env, dict):
                from urllib.parse import urlparse as _up
                _h = (_up(str(_env.get("base_url") or "")).hostname or "").lower()
                if _h:
                    _hosts.add(_h)

    led = {
        "version": VERSION, "run_id": d.name, "contract": a.contract or "",
        "created_at": _now(), "status": "open",
        "allowed_hosts": sorted(_hosts),
        "claims": claims, "instances": [], "events": [{"at": _now(), "action": "init"}],
        "close": None,
    }
    _save(d, led)
    print(f"✅ 数据账本建账（{len(claims)} 条 claim）→ {d / LEDGER_NAME}")
    return 0


def cmd_record(a) -> int:
    d = Path(a.run_dir)
    led = _load(d)
    if led is None:
        print("⛔ 账本不存在（先 init）", file=sys.stderr)
        return 2
    cap = d / "field-captures"
    added = 0
    for side in ("legacy", "current"):
        for f in sorted((cap / side).glob("*.json")) if (cap / side).is_dir() else []:
            try:
                capj = json.loads(f.read_text(encoding="utf-8"))
            except Exception:
                continue
            inst = capj.get("instance_no")
            if not inst:
                continue
            entry = {"case_id": str(capj.get("case_id") or f.stem), "side": side,
                     "instance_no": str(inst), "flow_code": capj.get("flow_code"),
                     "recorded_at": _now()}
            if not any(x.get("case_id") == entry["case_id"] and x.get("side") == side
                       for x in led["instances"]):
                led["instances"].append(entry)
                added += 1
    led["events"].append({"at": _now(), "action": "record", "added": added})
    _save(d, led)
    print(f"✅ 实例登记 +{added}（累计 {len(led['instances'])}）→ {d / LEDGER_NAME}")
    return 0


def cmd_close(a) -> int:
    d = Path(a.run_dir)
    led = _load(d)
    if led is None:
        print("⛔ 账本不存在（先 init）", file=sys.stderr)
        return 2
    cr: list[dict] = []
    try:
        cr = json.loads((d / "case-results.json").read_text(encoding="utf-8"))
    except Exception:
        pass
    status_by_case = {str(c.get("id")): str(c.get("status")) for c in cr if isinstance(c, dict)}
    concl = ""
    try:
        concl = str((json.loads((d / "summary.json").read_text(encoding="utf-8")) or {}).get("conclusion") or "")
    except Exception:
        pass
    # 资源真实状态验证（--verify）：执行契约 resources[].check 只读查询（审计第 8 轮 P1-4：
    # 没有"确认释放"凭据不得标 released——三态 released/residual/unknown 严格分开）
    verify_results: dict[str, str] = {}
    if a.verify:
        # v1.7.0 P0-3：资源只读验证改**结构化白名单适配器**——不再执行契约自由文本命令串
        # （此前 shell=True + 关键词过滤，touch 等任意命令可直接执行）。check 形状：
        #   {kind: sql|http, adapter: <名>, params: {...}, expected: FREE}
        #   sql: params.table/status_col/id_col + env FLOWTEST_SQL_DSN_<ADAPTER大写>（标识符白名单）
        #   http: params.url（GET 只读）+ expected 子串
        for claim in led.get("claims") or []:
            if claim.get("kind") != "resource":
                continue
            rid = str(claim.get("id"))
            chk = claim.get("check")
            if chk in (None, "", {}):
                verify_results[rid] = "unknown（契约 resources[].check 未配置结构化验证）"
                continue
            if not isinstance(chk, dict):
                verify_results[rid] = ("unknown（check 为自由文本——v1.7.0 起已移除任意命令执行，"
                                       "改为结构化 {kind, adapter, params, expected}；请修契约）")
                continue
            kind = str(chk.get("kind") or "")
            params = chk.get("params") or {}
            expected = str(chk.get("expected") or "FREE").strip().upper()
            if kind == "http":
                url = str(params.get("url") or "")
                if not url.startswith(("http://", "https://")):
                    verify_results[rid] = "unknown（http check 的 params.url 非法）"
                    continue
                # v1.7.2 P1-3：URL 白名单+私网/loopback 拒绝+禁重定向——契约不得指向任意地址。
                # 白名单来源=init 时从契约 environments base_url 主机登记的 allowed_hosts。
                from urllib.parse import urlparse as _up
                _pu = _up(url)
                _host = (_pu.hostname or "").lower()
                _allowed = {h.lower() for h in (led.get("allowed_hosts") or [])}
                # 白名单唯一入口：主机必须来自契约 environments 声明（init 登记）。
                # 未声明的任意地址（含 loopback/私网）一律拒绝；loopback 作为测试环境
                # 使用时须由契约 environments 显式声明。
                if not _host or _host not in _allowed:
                    verify_results[rid] = (f"unknown（http check 主机 {_host!r} 不在契约环境白名单 "
                                           f"{sorted(_allowed)}——契约不得指向任意地址"
                                           f"（loopback/私网亦须显式声明））")
                    continue

                import urllib.request as _ur   # 先导入再定义禁重定向 handler
                class _NoRedirect(_ur.HTTPRedirectHandler):
                    def redirect_request(self, *a, **k):
                        return None   # 禁重定向（重定向=白名单绕过面）

                try:
                    _opener = _ur.build_opener(_NoRedirect)
                    with _opener.open(url, timeout=15) as resp:
                        body = resp.read().decode("utf-8", "replace")
                    verify_results[rid] = "released" if expected in body.upper() else "residual"
                except Exception as e:
                    verify_results[rid] = f"unknown（http check 失败 {type(e).__name__}: {e}）"
            elif kind == "sql":
                adapter = str(chk.get("adapter") or "").strip()
                if not re.fullmatch(r"[A-Za-z0-9_]+", adapter or ""):
                    verify_results[rid] = "unknown（sql check 缺合法 adapter 名）"
                    continue
                table = str(params.get("table") or "")
                scol = str(params.get("status_col") or "status")
                rid_col = str(params.get("id_col") or "id")
                if not (re.fullmatch(r"[A-Za-z0-9_.$]+", table)
                        and re.fullmatch(r"[A-Za-z0-9_]+", scol)
                        and re.fullmatch(r"[A-Za-z0-9_]+", rid_col)):
                    verify_results[rid] = "unknown（sql 标识符非法——只允许字母数字下划线/点）"
                    continue
                dsn = os.environ.get(f"FLOWTEST_SQL_DSN_{adapter.upper()}", "")
                if not dsn:
                    verify_results[rid] = (f"unknown（env FLOWTEST_SQL_DSN_{adapter.upper()} 未配置"
                                           f"——无法连接只读验证）")
                    continue
                sql = f"SELECT {scol} FROM {table} WHERE {rid_col} = :rid"
                try:
                    pr = subprocess.run(
                        ["uv", "run", "--with", "oracledb", "python3", "-c",
                         "import sys, oracledb;\n"
                         "con = oracledb.connect(sys.argv[1])\n"
                         "cur = con.cursor(); cur.execute(sys.argv[2], rid=sys.argv[3])\n"
                         "row = cur.fetchone(); print('FREE' if not row else str(row[0]))",
                         dsn, sql, str(claim.get("resource_key") or rid)],
                        capture_output=True, text=True, timeout=120)
                    out = (pr.stdout or "").strip().upper()
                    verify_results[rid] = "released" if out == expected else f"residual（实际 {out[:40]}）"
                except Exception as e:
                    verify_results[rid] = f"unknown（sql check 失败 {type(e).__name__}: {e}）"
            else:
                verify_results[rid] = f"unknown（check.kind {kind!r} 不受支持——只认 sql|http）"
    resources_all_released = (not any(claim.get("kind") == "resource" for claim in led.get("claims") or [])
                              or all(v == "released" for v in verify_results.values()))
    per_case: dict[str, dict] = {}
    safe_to_clean: list[dict] = []
    for inst in led["instances"]:
        cid, side = inst["case_id"], inst["side"]
        cst = status_by_case.get(cid, "UNKNOWN")
        # 三态（审计第 8 轮 P1-4）：released 须"case PASS 且资源确认释放（--verify）"；
        # PASS 但未确认 → unknown（不是 released！）；BLOCKED/ERROR/UNKNOWN → residual
        if cst == "PASS":
            disposition = "released" if (a.verify and resources_all_released) else "unknown"
        else:
            disposition = "residual"
        per_case.setdefault(cid, {"status": cst, "instances": []})
        per_case[cid]["instances"].append({**inst, "disposition": disposition})
        if disposition == "residual":
            safe_to_clean.append({
                "case_id": cid, "side": side, "instance_no": inst["instance_no"],
                "hint": ("由管理员作废（CANCELLED）或下次以 instancePolicy=reuse+instanceNo 选择器"
                         "续跑收尾；本账本绝不自动执行破坏性清理"),
            })
    led["close"] = {
        "at": _now(), "conclusion": concl or "UNKNOWN",
        "verified": bool(a.verify),
        "resource_checks": verify_results,
        "per_case": per_case,
        "safe_to_clean": safe_to_clean,
        "note": "safe_to_clean 仅列本 run launch 的实例与建议动作——清理须人工/管理员执行并回填结果",
    }
    led["status"] = "closed"
    led["events"].append({"at": _now(), "action": "close",
                          "residual": len(safe_to_clean), "conclusion": concl or "UNKNOWN"})
    _save(d, led)
    print(f"✅ 数据账本收账（conclusion={concl or 'UNKNOWN'}，残留待清理 {len(safe_to_clean)}）"
          f"→ {d / LEDGER_NAME}")
    return 0


def cmd_claim(a) -> int:
    d = Path(a.run_dir)
    led = _load(d)
    if led is None:
        print("⛔ 账本不存在（先 init）", file=sys.stderr)
        return 2
    conflicts = _registry_claim(led.get("claims") or [], owner=str(led.get("run_id") or d.name),
                                lease_hours=a.lease_hours)
    if conflicts:
        print("⛔ 租约冲突（另一 run 正占用测试数据——拒绝并行 claim）:", file=sys.stderr)
        for x in conflicts:
            print(f"  - {x}", file=sys.stderr)
        return 2
    led["events"].append({"at": _now(), "action": "claim", "registry": str(registry_path())})
    _save(d, led)
    print(f"✅ 租约 claim 完成（{len(led.get('claims') or [])} 项，registry={registry_path()}）")
    return 0


def cmd_release(a) -> int:
    d = Path(a.run_dir)
    led = _load(d)
    owner = str((led or {}).get("run_id") or d.name)
    before = len(_registry_read())
    entries = [e for e in _registry_read() if str(e.get("owner")) != owner]
    removed = before - len(entries)
    _registry_write(entries)
    if led is not None:
        led["events"].append({"at": _now(), "action": "release", "removed": removed})
        _save(d, led)
    print(f"✅ 租约释放 {removed} 项（owner={owner}）")
    return 0


def cmd_show(a) -> int:
    led = _load(Path(a.run_dir))
    if led is None:
        print("⛔ 账本不存在", file=sys.stderr)
        return 2
    print(json.dumps(led, ensure_ascii=False, indent=2))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="test-data-ledger.py", description="测试数据与残留实例生命周期账本")
    sub = ap.add_subparsers(dest="cmd", required=True)
    pi = sub.add_parser("init", help="run 前建账（fixtures/resources claim）")
    pi.add_argument("--run-dir", required=True)
    pi.add_argument("--contract", default="")
    pi.add_argument("--lease-hours", type=float, default=24.0,
                    help="数据租约时长（小时；到期=其他 run 可检测冲突）")
    pi.add_argument("--overwrite", action="store_true")
    pi.set_defaults(func=cmd_init)
    pr = sub.add_parser("record", help="采集后登记双端实例号（从 field-captures 实读）")
    pr.add_argument("--run-dir", required=True)
    pr.set_defaults(func=cmd_record)
    pc = sub.add_parser("close", help="结论后收账（released/residual + 可安全清理项）")
    pc.add_argument("--run-dir", required=True)
    pc.add_argument("--verify", action="store_true",
                    help="执行契约 resources[].check 只读查询确认真实释放——未确认的 PASS 实例只标 unknown 不标 released")
    pc.set_defaults(func=cmd_close)
    pcl = sub.add_parser("claim", help="跨 run 租约：原子 claim 本 run 的 fixtures/resources（冲突=拒绝）")
    pcl.add_argument("--run-dir", required=True)
    pcl.add_argument("--lease-hours", type=float, default=24.0)
    pcl.set_defaults(func=cmd_claim)
    prel = sub.add_parser("release", help="释放本 run 在 registry 的全部租约")
    prel.add_argument("--run-dir", required=True)
    prel.set_defaults(func=cmd_release)
    ps = sub.add_parser("show", help="查看账本")
    ps.add_argument("--run-dir", required=True)
    ps.set_defaults(func=cmd_show)
    a = ap.parse_args()
    try:
        return a.func(a)
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[test-data-ledger] ⛔ 内部异常: {type(e).__name__}: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
