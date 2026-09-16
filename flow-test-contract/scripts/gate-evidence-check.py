#!/usr/bin/env python3
"""gate-evidence-check.py v2 —— 契约声明 gate 的证据校验（fail-closed，证据须能证明 gate）。

v2（2026-09-07 第十三轮审计·P0 修复）：通用 file|url 证据只能证明"有个文件/URL 活着"，
不能证明"该 gate 通过"（任意新建文件+哈希即可过 GATE-CANVAS/DEPLOY）。自本轮起：
  - 每个无自动检查器的 gate 必须在契约声明 evidence_schema（validate-contract 立契期强制）；
  - 证据必须**满足该 schema 才算证明**：
      kind=http    url 必须命中 evidence_schema.allowed_urls 白名单（否则即使 200 也不采信）
                   且现场探活 HTTP 200
      kind=report  file_format ∈ json|csv|txt；按 required_fields[{path, op, value}] 断言
                   报告内容（op: eq|contains|regex）；sha256_16 现场复算一致；
                   flow_field（若有）指向的流程编码须 == 契约 meta.flow_code（证据绑定目标流程）
  - 通用校验仍保留：target_env 绑定（设 TARGET_VERSION 时须一致）、generated_at ISO8601
    时限、显式 passed=false=自报未通过
  - 证据条目 kind 与 schema 不符 / 缺 schema 的 gate → passed=false（fail-closed）

gate-evidence.json（run 目录根：docs/<流程>/自动化测试/对比测试/<run-id>/gate-evidence.json，列表）:
  [{ "id": "GATE-CANVAS",
     "type": "file"|"url",              # file→report 类 schema；url→http 类 schema
     "path": "…", "sha256_16": "…",     # file 必填（16 位小写 hex，现场复算）
     "url": "https://…",                # url 必填
     "generated_at": "ISO8601", "target_env": "…", "passed": true }]

用法:
  python3 gate-evidence-check.py <gates-out> <health-results.json> <contract> <gate-evidence.json> <project-root>
退出码: 0=判定完成（gates-out 已写入）；2=校验器内部异常（gates-out 可能未写）。
环境变量: GATE_EVIDENCE_MAX_AGE_SEC（默认 86400）。
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path


def _norm_netloc(hostport: str) -> tuple[str, str, str]:
    """归一 scheme/host/port 用于白名单比较：
    - host 小写；显式默认端口（https:443/http:80）剥除后与省略端口等价
    - 返回 (scheme, host, port_or_empty) —— 三者全同才算同源。"""
    scheme, netloc, _, _, _ = urllib.parse.urlsplit(hostport if "://" in hostport else "https://" + hostport)
    host = (netloc or "").lower()
    port = ""
    if host.startswith("["):
        end = host.find("]")
        if end == -1:
            return scheme, host, port
        host_core, rest = host[: end + 1], host[end + 1 :]
        if rest.startswith(":"):
            port = rest[1:]
        host = host_core
    elif ":" in host:
        host, _, port = host.rpartition(":")
    if (port == "443" and scheme == "https") or (port == "80" and scheme == "http"):
        port = ""
    return scheme, host, port


def _url_allowed(candidate: str, allowed: list[str]) -> bool:
    """白名单 URL 匹配（第十五轮审计·P0 修复）：不再用 startswith 前缀（https://t/api 会
    被 https://t/api.evil/... 绕过）。改为按**解析后的 scheme/host/port** 完全一致
    （urlsplit().hostname/.port 已做大小写/默认端口/IPv6 归一）+ **path 边界明确**：
      - allowed path 以 '/' 结尾（或为空）→ path-prefix 授权：candidate 路径须等于前缀或
        以 前缀/ 开头（防 api.evil 斜杠串接绕过 api）；空/根路径放行一切同源路径
      - 否则 → 精确 path 匹配（scheme/host/port/path 全等；query/fragment 忽略）
    candidate/allowed 均须为合法 http(s) URL。"""
    try:
        cu = urllib.parse.urlsplit(candidate.strip())
    except Exception:
        return False
    if cu.scheme not in ("http", "https") or not cu.hostname:
        return False
    for a in allowed:
        try:
            au = urllib.parse.urlsplit(a.strip())
        except Exception:
            continue
        if au.scheme not in ("http", "https") or not au.hostname:
            continue
        if cu.scheme != au.scheme or (cu.hostname or "").lower() != (au.hostname or "").lower():
            continue  # scheme/host 不一致——不算命中

        def _norm_port(p):
            # 显式默认端口（https:443 / http:80）与省略端口等价
            if p is None:
                return None
            return None if (au.scheme == "https" and p == 443) or (au.scheme == "http" and p == 80) else p

        if _norm_port(cu.port) != _norm_port(au.port):
            continue  # 端口不一致——不算命中
        ap = au.path or ""
        cp = cu.path or ""
        if ap in ("", "/"):
            return True
        if ap.endswith("/"):
            if cp == ap or cp.startswith(ap):
                return True
        elif cp == ap:
            return True
    return False


def _match_op(op: str, actual, expect) -> bool:
    if op in ("gte", "lte"):
        # 数值比较：双方须可数值化（去逗号/百分比/空格），否则断言失败（fail-closed）
        try:
            a = float(str(actual).replace(",", "").replace("%", "").strip())
            x = float(str(expect).replace(",", "").replace("%", "").strip())
        except (TypeError, ValueError):
            return False
        return a >= x if op == "gte" else a <= x
    # 第十三轮·审计修复：标量守卫——eq/contains/regex 要求 actual 是标量（str/int/float/bool）。
    # 若 JSONPath 取到 dict/list，str() 后变成 "{...}" 字符串——contains 子串匹配可被任何
    # 含目标串的 dict 绕开（如 {"any":"DEPLOYED"} 命中 contains "DEPLOYED"）；此路径**结构性拒绝**。
    if isinstance(actual, (dict, list)) or actual is None:
        return False
    a = str(actual)
    if op == "eq":
        return a == str(expect)
    if op == "contains":
        return str(expect) in a
    if op == "regex":
        try:
            return re.search(str(expect), a) is not None
        except re.error:
            return False
    return False


def _verify(e, schema: dict, flow_code: str, expected_env: str, project_root: Path, max_age: float) -> tuple[bool, str]:
    """单条证据按 gate 声明的 schema 校验 → (ok, note)。fail-closed。"""
    if not isinstance(e, dict):
        return False, "证据非对象（结构化证据 required）"
    if e.get("passed") is False:
        return False, "证据自报未通过（passed=false）"
    tenv = e.get("target_env")
    if not isinstance(tenv, str) or not tenv.strip():
        return False, "缺 target_env（证据须绑定目标环境）"
    tenv = tenv.strip()
    if expected_env and tenv != expected_env.strip():
        return False, f"target_env 与本次 TARGET_VERSION 不符: {tenv!r} ≠ {expected_env.strip()!r}"
    ga = e.get("generated_at")
    if not isinstance(ga, str) or not ga.strip():
        return False, "缺 generated_at"
    txt = ga.strip()
    if txt.endswith(("Z", "z")):
        txt = txt[:-1] + "+00:00"
    try:
        t = datetime.fromisoformat(txt)
    except Exception:
        return False, f"generated_at 非 ISO8601: {ga!r}"
    if t.tzinfo is None:
        t = t.astimezone()
    age = (datetime.now(t.tzinfo) - t).total_seconds()
    if age < -300:
        return False, f"generated_at 在未来（伪造）: {ga!r}"
    if age > max_age:
        return False, f"证据已过期（{age / 3600:.1f}h 前 > 窗口 {max_age / 3600:.1f}h；GATE_EVIDENCE_MAX_AGE_SEC 可调）"

    kind = schema.get("kind")
    et = e.get("type")
    if kind == "http":
        if et != "url":
            return False, f"schema=kind:http 要求证据 type=url（得 {et!r}）"
        url = e.get("url")
        if not isinstance(url, str) or not url.strip().lower().startswith(("http://", "https://")):
            return False, "url 证据缺合法 http(s) url"
        allowed = [str(u) for u in (schema.get("allowed_urls") or [])]
        if not _url_allowed(url, allowed):
            return False, f"证据 url 不在本 gate 白名单（scheme/host/port/path 边界不符）: {url[:100]}——不能证明本 gate"
        try:
            with urllib.request.urlopen(url.strip(), timeout=5) as resp:
                code = getattr(resp, "status", None) or resp.getcode()
        except Exception as ex:
            return False, f"证据 url 现场探活失败: {ex}"
        if code != 200:
            return False, f"证据 url 非 200: HTTP {code}"
        return True, f"url={url} HTTP200（白名单内） target_env={tenv} generated_at={ga}"

    if kind == "report":
        if et != "file":
            return False, f"schema=kind:report 要求证据 type=file（得 {et!r}）"
        p, h = e.get("path"), e.get("sha256_16")
        if not isinstance(p, str) or not p.strip():
            return False, "file 证据缺 path"
        if not isinstance(h, str) or not re.fullmatch(r"[0-9a-f]{16}", h):
            return False, "file 证据缺合法 sha256_16（16 位小写十六进制）"
        f = Path(p.strip())
        if not f.is_absolute():
            f = project_root / f
        if not f.is_file():
            return False, f"证据文件不存在: {p}"
        try:
            digest = hashlib.sha256(f.read_bytes()).hexdigest()[:16]
        except Exception as ex:
            return False, f"证据文件不可读: {ex}"
        if digest != h:
            return False, f"证据文件 sha256 不符: 现算 {digest} ≠ 声明 {h}"
        fmt = schema.get("file_format", "json")
        raw = f.read_text(encoding="utf-8", errors="replace")
        doc = None
        try:
            if fmt == "json":
                doc = json.loads(raw)
            elif fmt == "csv":
                rows = list(csv.DictReader(io.StringIO(raw)))
                doc = {"rows": rows}
            else:
                doc = {"text": raw}
        except Exception as ex:
            return False, f"证据文件按 file_format={fmt} 解析失败: {ex}"
        for rf in (schema.get("required_fields") or []):
            path, op, expect = rf.get("path"), rf.get("op"), rf.get("value")
            try:
                cur = _dig(doc, path) if fmt != "txt" else doc.get("text", "")
            except KeyError as ex:
                return False, f"报告缺必证字段 {path}（{ex}）——证据不能证明本 gate"
            if not _match_op(op, cur, expect):
                return False, f"报告字段断言失败: {path} {op} {expect!r}（实际 {str(cur)[:60]!r}）"
        ff = schema.get("flow_field")
        if ff:
            try:
                cur = _dig(doc, ff) if fmt != "txt" else None
            except KeyError:
                return False, f"报告缺流程绑定字段 {ff}（flow_field）"
            if cur is None or str(cur) != flow_code:
                return False, f"报告流程绑定不符: {ff}={cur!r} ≠ 契约 flow_code {flow_code!r}——证据不属于本流程"
        return True, f"file={p} sha256_16={h} 报告断言通过 target_env={tenv} generated_at={ga}"

    return False, f"gate 未声明可识别 evidence_schema（kind={kind!r}）——无 schema 的证据无法证明本 gate"


def _dig(obj, path: str):
    """极简 JSONPath（点号取键，[n] 取数组下标；rows[i].col 兼容 CSV rows）。"""
    cur = obj
    for token in re.findall(r"[^.\[\]]+|\[\d+\]", path):
        if token.startswith("["):
            idx = int(token[1:-1])
            if not isinstance(cur, list) or idx >= len(cur):
                raise KeyError(f"数组越界于 {token}")
            cur = cur[idx]
        else:
            if token == "rows":
                if isinstance(cur, dict) and "rows" in cur:
                    cur = cur["rows"]
                    continue
            if not isinstance(cur, dict) or token not in cur:
                raise KeyError(f"缺键 {token}")
            cur = cur[token]
    return cur


def main() -> None:
    gates_out, health_results, contract, evidence_path, project_root = sys.argv[1:6]
    max_age = float(os.environ.get("GATE_EVIDENCE_MAX_AGE_SEC", "86400"))
    expected_env = os.environ.get("TARGET_VERSION", "")
    # 自动健康检查结果（health-check.py 按契约 environments.health_checks 执行产出）
    items: list[dict] = []
    try:
        raw_h = json.loads(Path(health_results).read_text(encoding="utf-8"))
        if isinstance(raw_h, list):
            items = [g for g in raw_h if isinstance(g, dict)]
    except Exception:
        items = []  # 健康结果缺失/损坏 = 无自动 gate（fail-closed 于下游 GATE-HEALTH 证据/空门禁）
    try:
        import yaml
        c = yaml.safe_load(Path(contract).read_text(encoding="utf-8")) or {}
    except Exception:
        c = {}
    flow_code = str((c.get("meta") or {}).get("flow_code") or "")
    gates_decl = c.get("gates") or []
    ev = {}
    if os.path.exists(evidence_path):
        try:
            raw = json.loads(Path(evidence_path).read_text(encoding="utf-8"))
            if isinstance(raw, list):
                ev = {g.get("id"): g for g in raw if isinstance(g, dict) and isinstance(g.get("id"), str)}
        except Exception:
            pass  # 证据文件损坏 = 无证据（fail-closed）
    auto_ids = {g.get("id") for g in items if isinstance(g.get("id"), str)}
    for g in gates_decl:
        gid = g.get("id") if isinstance(g, dict) else None
        if not isinstance(gid, str) or not gid:
            items.append({"id": "GATE-MALFORMED", "severity": "P0", "passed": False,
                          "note": f"契约 gates 存在缺/非法 id 的条目: {g!r}"})
            continue
        if gid == "GATE-HEALTH" or gid in auto_ids:
            continue
        schema = g.get("evidence_schema") if isinstance(g, dict) else None
        if not isinstance(schema, dict) or not schema.get("kind"):
            items.append({"id": gid, "severity": g.get("severity", "P1"), "passed": False,
                          "note": f"{g.get('check')}——gate 未声明 evidence_schema（立契期应已拦截）；"
                                  "无 schema 的证据无法证明本 gate（fail-closed）"})
            continue
        if gid in ev:
            ok, note = _verify(ev[gid], schema, flow_code, expected_env, Path(project_root), max_age)
        else:
            ok, note = False, "无自动检查器且未提供 gate-evidence.json 结构化证据（fail-closed）"
        items.append({"id": gid, "severity": g.get("severity", "P1"), "passed": bool(ok),
                      "note": f"{g.get('check')}——{note}"})
    Path(gates_out).write_text(json.dumps(items, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[gate-evidence] ⛔ 校验器内部异常（fail-closed）: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
